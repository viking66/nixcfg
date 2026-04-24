# Athena — second-brain / PKM agent.
#
# Same shape as Scribe (microvm on gordula, Telegram channel, ttyd, OAuth):
# the new pieces are a headless Obsidian instance, the obsidian-local-rest-api
# plugin, an MCP bridge so Claude can use Obsidian's graph/tag/frontmatter
# features, and a dispatcher that fires scheduled tasks from a vault-tracked
# schedule file.
{ config, pkgs, lib, inputs, flakeRoot, ... }:

let
  vmName = "athena";
  hostIP = "10.233.3.1";
  guestIP = "10.233.3.2";
  subnet = "10.233.3.0/24";
  bridge = "virbr-athena";
  tapId = "vm-athena";
  guestMAC = "02:00:00:00:03:02";
  wanInterface = "eno1";

  # Guest-side ports (internal to the VM).
  obsidianPort = 27123;   # Local REST API plugin
  ttydPort     = 7682;    # web terminal (different from scribe's 7681)

  skeletonDir = flakeRoot + "/nixos-modules/athena/skeleton";

  # Pinned Obsidian Local REST API plugin — release 3.6.1. Hashes from
  # `openssl dgst -sha256 -binary | base64` on the release assets.
  restApiPluginVersion = "3.6.1";
  restApiPlugin = pkgs.runCommand "obsidian-local-rest-api-${restApiPluginVersion}" { } ''
    mkdir -p $out
    install -m 0644 ${pkgs.fetchurl {
      url = "https://github.com/coddingtonbear/obsidian-local-rest-api/releases/download/${restApiPluginVersion}/main.js";
      hash = "sha256-7z5zqg3VsEXz9GnVnPelpq7XCScNhvh9bISgQFZhsr4=";
    }} $out/main.js
    install -m 0644 ${pkgs.fetchurl {
      url = "https://github.com/coddingtonbear/obsidian-local-rest-api/releases/download/${restApiPluginVersion}/manifest.json";
      hash = "sha256-f8SUGFKSR6M8mF7oidWjWPEuztG9L+PLCNmruB2TiJ0=";
    }} $out/manifest.json
    install -m 0644 ${pkgs.fetchurl {
      url = "https://github.com/coddingtonbear/obsidian-local-rest-api/releases/download/${restApiPluginVersion}/styles.css";
      hash = "sha256-nBHUcyA4Spr5fKZ+eDhPm/4bRlENYR3j58hQdCXSDfs=";
    }} $out/styles.css
  '';

  athenaRestart = pkgs.writeShellScriptBin "athena-restart" ''
    exec /run/wrappers/bin/sudo -n /run/current-system/sw/bin/systemctl --no-block restart athena.service
  '';

  # Send a Telegram DM to the user. Uses the bot token and user ID from env
  # (set via EnvironmentFile for scripts that need them). Claude's agent
  # loop can run `athena-notify "text"` from its Bash tool.
  athenaNotify = pkgs.writeShellScriptBin "athena-notify" ''
    set -eu
    if [ $# -lt 1 ]; then
      echo "usage: athena-notify <message>" >&2
      exit 2
    fi
    msg="$*"
    : "''${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN not set}"
    : "''${TELEGRAM_USER_ID:?TELEGRAM_USER_ID not set}"
    ${pkgs.curl}/bin/curl -fsS --max-time 15 \
      -X POST "https://api.telegram.org/bot''${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=''${TELEGRAM_USER_ID}" \
      --data-urlencode "text=''${msg}" \
      > /dev/null
  '';

  # Append an entry to _AI/schedule.md and commit+push. Format validation is
  # minimal: we just check it starts with "- " and has two "|" separators.
  athenaSchedule = pkgs.writeShellScriptBin "athena-schedule" ''
    set -eu
    if [ $# -lt 1 ]; then
      echo "usage: athena-schedule '<line>'  (line must start with '- ' and have time|kind|payload)" >&2
      exit 2
    fi
    line="$*"
    case "$line" in
      "- "*"|"*"|"*) : ;;
      *) echo "athena-schedule: bad format. Expected '- <time-spec> | <notify|prompt> | <payload>'" >&2; exit 2 ;;
    esac
    vault=/var/lib/athena/vault
    sched="$vault/_AI/schedule.md"
    [ -f "$sched" ] || { echo "athena-schedule: schedule file missing at $sched" >&2; exit 1; }
    printf '%s\n' "$line" >> "$sched"
    cd "$vault"
    ${pkgs.git}/bin/git add _AI/schedule.md
    ${pkgs.git}/bin/git -c user.name=athena -c user.email=athena@gordula.local \
      commit -m "schedule: $line" --quiet
    ${pkgs.git}/bin/git push --quiet origin main
    echo "scheduled: $line"
  '';

  # Dispatcher: parses schedule.md and fires due entries. Designed to run
  # every minute via systemd.timer. Uses a sidecar state file to avoid
  # double-firing single-shot `at` entries.
  athenaDispatcher = pkgs.writeShellScriptBin "athena-dispatcher" ''
    set -eu
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gnused pkgs.gawk pkgs.curl pkgs.gnugrep pkgs.util-linux pkgs.git athenaNotify ]}:$PATH
    vault=/var/lib/athena/vault
    sched="$vault/_AI/schedule.md"
    state=/var/lib/athena/dispatcher-state
    mkdir -p "$state"
    [ -f "$sched" ] || { exit 0; }

    # Prevent overlapping runs (if previous dispatcher is still working).
    exec 9>"$state/lock"
    flock -n 9 || { exit 0; }

    now_ts=$(date +%s)
    now_iso=$(date +"%Y-%m-%d %H:%M")
    now_hm=$(date +"%H:%M")
    now_wd=$(date +"%A" | tr '[:upper:]' '[:lower:]')

    # Iterate schedule entries. Skip comments and blanks.
    grep -E '^- ' "$sched" | while IFS= read -r raw; do
      line=''${raw#- }
      timespec=$(printf '%s' "$line" | awk -F'\\s*\\|\\s*' '{print $1}')
      kind=$(printf '%s' "$line"    | awk -F'\\s*\\|\\s*' '{print $2}')
      payload=$(printf '%s' "$line" | awk -F'\\s*\\|\\s*' '{for (i=3;i<=NF;i++){printf "%s", $i; if (i<NF) printf " | "}}')

      due=0
      case "$timespec" in
        "at "*)
          target=''${timespec#at }
          # Single-shot: check state file.
          hash=$(printf '%s' "$line" | sha256sum | cut -c1-16)
          fired="$state/fired-$hash"
          [ -e "$fired" ] && continue
          # Compare as datetimes.
          target_ts=$(date -d "$target" +%s 2>/dev/null || echo 0)
          [ "$target_ts" -gt 0 ] || continue
          if [ "$now_ts" -ge "$target_ts" ] && [ $((now_ts - target_ts)) -lt 300 ]; then
            due=1
            touch "$fired"
          fi
          ;;
        "every day "*)
          hm=''${timespec#every day }
          [ "$now_hm" = "$hm" ] && due=1
          ;;
        "every "*)
          rest=''${timespec#every }
          first=$(printf '%s' "$rest" | awk '{print $1}')
          hm=$(printf '%s' "$rest" | awk '{print $2}')
          case "$first" in
            monday|tuesday|wednesday|thursday|friday|saturday|sunday)
              [ "$now_wd" = "$first" ] && [ "$now_hm" = "$hm" ] && due=1
              ;;
            *)
              # "every HH:MM" — every N hours. Only fire when minute matches and hour is a multiple.
              hm=$first
              target_h=$(printf '%s' "$hm" | cut -d: -f1 | sed 's/^0//')
              target_m=$(printf '%s' "$hm" | cut -d: -f2 | sed 's/^0//')
              now_h=$(date +%H | sed 's/^0//')
              now_m=$(date +%M | sed 's/^0//')
              if [ "$now_m" = "$target_m" ] && [ $((now_h % ''${target_h:-1})) -eq 0 ]; then
                due=1
              fi
              ;;
          esac
          ;;
      esac

      [ "$due" = 1 ] || continue

      case "$kind" in
        notify)
          athena-notify "$payload" || echo "notify failed for: $line" >&2
          ;;
        prompt)
          promptfile="$vault/_AI/$payload"
          [ -f "$promptfile" ] || { echo "missing prompt: $promptfile" >&2; continue; }
          # Invoke Claude non-interactively. Runs as the athena user via
          # systemd-run so it stays in its own cgroup and can't corrupt
          # the main athena.service's tmux session.
          systemd-run --quiet --pipe --user=athena --same-dir --unit="athena-run-$(date +%s)" \
            --property="Environment=HOME=/var/lib/athena/home" \
            --property="Environment=CLAUDE_CODE_OAUTH_TOKEN=''${CLAUDE_CODE_OAUTH_TOKEN:-}" \
            --property="Environment=TELEGRAM_BOT_TOKEN=''${TELEGRAM_BOT_TOKEN:-}" \
            --property="Environment=TELEGRAM_USER_ID=''${TELEGRAM_USER_ID:-}" \
            --property="Environment=GITHUB_TOKEN=''${GITHUB_TOKEN:-}" \
            --property="WorkingDirectory=$vault" \
            -- /var/lib/athena/home/.local/bin/claude --print --dangerously-skip-permissions \
            "$(cat "$promptfile")" \
            || echo "prompt run failed for: $line" >&2
          ;;
      esac
    done

    flock -u 9
  '';
in
{
  imports = [ inputs.microvm.nixosModules.host ];

  # Obsidian is unfree; allowUnfree is set on the guest's own nixpkgs
  # instance (see microvm.vms.athena.pkgs below). Nothing unfree on the host.

  # Secrets for Athena. Materialize into /var/lib/athena-secrets/env, mirrors
  # the pattern from scribe (symlink-to-rendered breaks over virtiofs).
  sops.secrets = {
    "athena/claude-code-oauth-token" = {};
    "athena/telegram-bot-token" = {};
    "athena/telegram-user-id" = {};    # numeric id, used by athena-notify
    "athena/github-pat" = {};
    "athena/obsidian-api-key" = {};
  };

  sops.templates."athena-env" = {
    content = ''
      CLAUDE_CODE_OAUTH_TOKEN=${config.sops.placeholder."athena/claude-code-oauth-token"}
      TELEGRAM_BOT_TOKEN=${config.sops.placeholder."athena/telegram-bot-token"}
      TELEGRAM_USER_ID=${config.sops.placeholder."athena/telegram-user-id"}
      GITHUB_TOKEN=${config.sops.placeholder."athena/github-pat"}
      OBSIDIAN_API_KEY=${config.sops.placeholder."athena/obsidian-api-key"}
    '';
    mode = "0440";
    owner = "root";
    group = "root";
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/athena-secrets 0700 root root -"
  ];

  systemd.services.athena-env-materialize = {
    description = "Materialize athena env file at the VM's virtiofs share";
    wantedBy = [ "microvm@${vmName}.service" ];
    before = [ "microvm@${vmName}.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -D -m 0440 -o root -g root \
        /run/secrets/rendered/athena-env \
        /var/lib/athena-secrets/env
    '';
  };

  # ------------------------------------------------------------------------
  # Host networking: dedicated bridge + NAT + egress-only firewall
  # ------------------------------------------------------------------------
  systemd.network.netdevs."20-${bridge}" = {
    netdevConfig = {
      Kind = "bridge";
      Name = bridge;
    };
  };

  systemd.network.networks."25-${bridge}" = {
    matchConfig.Name = bridge;
    networkConfig = {
      Address = "${hostIP}/24";
      ConfigureWithoutCarrier = true;
    };
  };

  systemd.network.networks."30-${tapId}" = {
    matchConfig.Name = tapId;
    networkConfig = {
      Bridge = bridge;
    };
  };

  # NAT module is already enabled by scribe.nix. Extend its internal list.
  networking.nat.internalInterfaces = [ bridge ];

  networking.firewall.extraCommands = ''
    iptables -I INPUT -i ${bridge} -m conntrack --ctstate NEW -j DROP
    iptables -I FORWARD -i ${wanInterface} -d ${subnet} -m conntrack --ctstate NEW -j DROP
  '';
  networking.firewall.extraStopCommands = ''
    iptables -D INPUT -i ${bridge} -m conntrack --ctstate NEW -j DROP 2>/dev/null || true
    iptables -D FORWARD -i ${wanInterface} -d ${subnet} -m conntrack --ctstate NEW -j DROP 2>/dev/null || true
  '';

  # Web terminal reverse-proxy (tailscale-only via host firewall).
  services.caddy.virtualHosts.":${toString ttydPort}" = {
    extraConfig = ''
      bind 0.0.0.0
      reverse_proxy ${guestIP}:${toString ttydPort}
    '';
  };

  # Auto-restart the VM on guest config changes.
  systemd.services."microvm@${vmName}".restartTriggers = [
    config.microvm.vms."${vmName}".config.config.system.build.toplevel
  ];

  # ------------------------------------------------------------------------
  # The guest
  # ------------------------------------------------------------------------
  microvm.vms."${vmName}" = {
    specialArgs = { inherit inputs flakeRoot; };

    # microvm guests use their own nixpkgs instance; host-level nixpkgs.config
    # doesn't propagate. Pass in a configured instance so Obsidian (unfree)
    # builds inside the guest.
    pkgs = import inputs.nixpkgs {
      system = "x86_64-linux";
      config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "obsidian" ];
    };

    config = { config, pkgs, lib, ... }: {
      networking.hostName = vmName;
      system.stateVersion = "24.11";
      time.timeZone = "America/Chicago";  # Jason's local time for "every day HH:MM"

      # nixpkgs.config lives on the host; microvm passes the host's nixpkgs
      # into the guest, so allowUnfreePredicate from the host applies here too.

      microvm = {
        hypervisor = "qemu";
        vcpu = 2;
        mem = 3072;
        vsock.cid = 4;  # scribe uses 3; 0-2 reserved by Linux.

        volumes = [{
          image = "athena-data.img";
          mountPoint = "/var/lib/athena";
          size = 20480;
          fsType = "ext4";
        }];

        shares = [
          {
            source = "/var/lib/athena-secrets";
            mountPoint = "/run/athena-secrets";
            tag = "athena-secrets";
            proto = "virtiofs";
          }
        ];

        interfaces = [{
          type = "tap";
          id = tapId;
          mac = guestMAC;
        }];
      };

      # Guest networking
      systemd.network.enable = true;
      networking.useNetworkd = true;
      networking.useDHCP = false;
      systemd.network.networks."20-eth" = {
        matchConfig.MACAddress = guestMAC;
        networkConfig = {
          Address = "${guestIP}/24";
          Gateway = hostIP;
          DNS = [ "1.1.1.1" "9.9.9.9" ];
        };
      };

      # SSH on the guest (bridge-only; WAN blocked by host FORWARD rule).
      services.openssh = {
        enable = true;
        openFirewall = true;
        settings = {
          PermitRootLogin = "no";
          PasswordAuthentication = false;
        };
      };
      networking.firewall = {
        enable = true;
        allowedTCPPorts = [ ttydPort ];
      };
      users.users.athena.openssh.authorizedKeys.keys = [
        (builtins.readFile (flakeRoot + "/secrets/id_ed25519.pub"))
      ];

      # Claude Code binary dropped into HOME — same pattern as scribe.
      programs.nix-ld.enable = true;

      environment.systemPackages = with pkgs; [
        nodejs_20
        bun
        git
        cacert
        curl
        tmux
        ttyd
        xorg-server        # Xvfb lives here
        obsidian
        athenaRestart
        athenaNotify
        athenaSchedule
        athenaDispatcher
        coreutils
        gnused
        gawk
        gnugrep
        util-linux             # flock
        openssh
      ];

      # Skeleton and plugin baked into the guest image (same reasoning as
      # scribe: host /nix/store paths get GC'd out from under a long-running
      # virtiofs).
      environment.etc."athena-skeleton".source = skeletonDir;
      environment.etc."obsidian-local-rest-api".source = restApiPlugin;

      users.users.athena = {
        isNormalUser = true;
        home = "/var/lib/athena/home";
        createHome = true;
        uid = 2001;
        extraGroups = [ "systemd-journal" ];
      };
      users.groups.athena.gid = 2001;

      systemd.tmpfiles.rules = [
        "d /var/lib/athena 0755 athena athena -"
      ];

      # athena user needs to restart its own service (athena-restart helper).
      security.sudo = {
        enable = true;
        extraRules = [{
          users = [ "athena" ];
          commands = [{
            command = "/run/current-system/sw/bin/systemctl --no-block restart athena.service";
            options = [ "NOPASSWD" ];
          }];
        }];
      };

      # ----- Xvfb -----
      systemd.services.xvfb = {
        description = "Virtual framebuffer for headless Obsidian";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.xorg-server}/bin/Xvfb :99 -screen 0 1280x1024x24 -nolisten tcp";
          Restart = "always";
          RestartSec = 5;
        };
      };

      # ----- Obsidian (headless) -----
      systemd.services.obsidian = {
        description = "Obsidian desktop (headless, serves Local REST API)";
        wantedBy = [ "multi-user.target" ];
        after = [ "xvfb.service" "athena.service" ];  # vault needs to exist
        wants = [ "xvfb.service" ];
        requires = [ "xvfb.service" ];
        serviceConfig = {
          User = "athena";
          Group = "athena";
          Restart = "always";
          RestartSec = 10;
          Environment = [
            "DISPLAY=:99"
            "HOME=/var/lib/athena/home"
          ];
          EnvironmentFile = "/run/athena-secrets/env";
        };
        preStart = ''
          set -e
          export HOME=/var/lib/athena/home
          vault=/var/lib/athena/vault
          mkdir -p "$vault/.obsidian/plugins/obsidian-local-rest-api"
          mkdir -p "$HOME/.config/obsidian"

          # Symlink plugin files from the Nix store (immutable).
          for f in main.js manifest.json styles.css; do
            ln -sfn /etc/obsidian-local-rest-api/$f \
              "$vault/.obsidian/plugins/obsidian-local-rest-api/$f"
          done

          # Write plugin config (API key from env). Field names per
          # obsidian-local-rest-api 3.6.1 types.ts — it's insecurePort (not
          # insecureServerPort, which I had wrong). Disable the HTTPS server
          # to skip self-signed cert generation on first boot.
          : "''${OBSIDIAN_API_KEY:?OBSIDIAN_API_KEY not in env}"
          umask 077
          cat > "$vault/.obsidian/plugins/obsidian-local-rest-api/data.json" <<EOF
          {
            "apiKey": "$OBSIDIAN_API_KEY",
            "enableInsecureServer": true,
            "insecurePort": ${toString obsidianPort},
            "enableSecureServer": false,
            "bindingHost": "127.0.0.1"
          }
          EOF

          # Enable the plugin.
          cat > "$vault/.obsidian/community-plugins.json" <<'EOF'
          ["obsidian-local-rest-api"]
          EOF

          # Per-vault app.json: suppress file-delete dialog AND mark the vault
          # as trusted. Setting `trustedVault: true` here is documented to
          # matter in 1.12+ in addition to the user-scope trustedVaults map
          # (belt and suspenders — one of the two should bypass the "Trust
          # author and enable plugins" dialog).
          cat > "$vault/.obsidian/app.json" <<'EOF'
          { "promptDelete": false, "trustedVault": true }
          EOF

          # Seed ~/.config/obsidian/obsidian.json so Obsidian:
          #   - knows to open our vault on launch (without this file, passing
          #     the vault as a CLI arg isn't enough — Obsidian lands on the
          #     vault picker)
          #   - treats the vault as trusted (top-level `trustedVaults` map
          #     keyed by vault id; this bypasses the "Trust author and enable
          #     plugins" dialog we can't click headlessly)
          if [ ! -f "$HOME/.config/obsidian/obsidian.json" ]; then
            ts=$(date +%s)000
            cat > "$HOME/.config/obsidian/obsidian.json" <<EOF
          {
            "vaults": {
              "athena": {
                "path": "$vault",
                "ts": $ts,
                "open": true
              }
            },
            "trustedVaults": {
              "athena": true
            }
          }
          EOF
          fi

          # Clean Electron singleton locks from prior ungraceful shutdown.
          rm -f "$HOME/.config/obsidian/Singleton"* 2>/dev/null || true
        '';
        script = ''
          # Match the rup12.net-verified pattern: just --no-sandbox, no GPU
          # flags. Add --enable-logging=stderr so renderer errors surface in
          # journald instead of being swallowed by Electron.
          exec ${pkgs.obsidian}/bin/obsidian \
            --no-sandbox \
            --enable-logging=stderr --v=1 \
            /var/lib/athena/vault
        '';
      };

      # ----- Obsidian MCP -----
      systemd.services.obsidian-mcp = {
        description = "cyanheads/obsidian-mcp-server bridging Claude to Obsidian's REST API";
        wantedBy = [ "multi-user.target" ];
        after = [ "obsidian.service" ];
        wants = [ "obsidian.service" ];
        serviceConfig = {
          User = "athena";
          Group = "athena";
          Restart = "always";
          RestartSec = 10;
          EnvironmentFile = "/run/athena-secrets/env";
          Environment = [
            "HOME=/var/lib/athena/home"
            "OBSIDIAN_BASE_URL=http://127.0.0.1:${toString obsidianPort}"
            "OBSIDIAN_VERIFY_SSL=false"
            "OBSIDIAN_ENABLE_CACHE=true"
            "OBSIDIAN_VAULT_NAME=athena"
            "MCP_TRANSPORT_TYPE=stdio"
            "PATH=/var/lib/athena/home/.npm-global/bin:/run/current-system/sw/bin:/run/wrappers/bin"
            "NPM_CONFIG_PREFIX=/var/lib/athena/home/.npm-global"
          ];
        };
        preStart = ''
          set -e
          export HOME=/var/lib/athena/home
          export NPM_CONFIG_PREFIX="$HOME/.npm-global"
          mkdir -p "$HOME/.npm-global/bin"
          if [ ! -x "$HOME/.npm-global/bin/obsidian-mcp-server" ]; then
            ${pkgs.nodejs_20}/bin/npm install -g obsidian-mcp-server
          fi
          # Wait for Obsidian REST API to be reachable.
          for i in $(seq 1 60); do
            if ${pkgs.curl}/bin/curl -fsS -o /dev/null \
              -H "Authorization: Bearer $OBSIDIAN_API_KEY" \
              http://127.0.0.1:${toString obsidianPort}/; then
              break
            fi
            sleep 2
          done
        '';
        script = ''
          export OBSIDIAN_API_KEY="$OBSIDIAN_API_KEY"
          exec "$HOME/.npm-global/bin/obsidian-mcp-server"
        '';
      };

      # ----- Claude Code + Telegram channel -----
      systemd.services.athena = {
        description = "Claude Code second-brain agent";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" "var-lib-athena.mount" "athena-bootstrap.service" ];
        wants = [ "network-online.target" "athena-bootstrap.service" ];

        serviceConfig = {
          User = "athena";
          Group = "athena";
          EnvironmentFile = "/run/athena-secrets/env";
          Restart = "always";
          RestartSec = 10;

          ProtectSystem = "strict";
          ProtectHome = false;
          PrivateTmp = true;
          ReadWritePaths = [ "/var/lib/athena" ];
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          LockPersonality = true;

          Environment = [
            "HOME=/var/lib/athena/home"
            "PATH=/var/lib/athena/home/.local/bin:/var/lib/athena/home/.npm-global/bin:/run/current-system/sw/bin:/run/wrappers/bin"
            "NPM_CONFIG_PREFIX=/var/lib/athena/home/.npm-global"
          ];
        };

        preStart = ''
          set -e
          umask 077
          export HOME=/var/lib/athena/home
          export NPM_CONFIG_PREFIX="$HOME/.npm-global"
          mkdir -p "$HOME/.local/bin" "$HOME/.npm-global/bin" "$HOME/.claude"

          if [ ! -x "$HOME/.local/bin/claude" ]; then
            ${pkgs.curl}/bin/curl -fsSL https://claude.ai/install.sh | sh
          fi

          # Telegram plugin's .env (channel plugin requires the file, not just env).
          mkdir -p "$HOME/.claude/channels/telegram"
          install -m 0600 /dev/null "$HOME/.claude/channels/telegram/.env"
          printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TELEGRAM_BOT_TOKEN" \
            > "$HOME/.claude/channels/telegram/.env"

          # Register the Obsidian MCP server for Claude Code (stdio to local binary).
          "$HOME/.local/bin/claude" mcp remove obsidian --scope user 2>/dev/null || true
          "$HOME/.local/bin/claude" mcp add --scope user --transport stdio obsidian \
            -e "OBSIDIAN_API_KEY=$OBSIDIAN_API_KEY" \
            -e "OBSIDIAN_BASE_URL=http://127.0.0.1:${toString obsidianPort}" \
            -e "OBSIDIAN_VERIFY_SSL=false" \
            -- "$HOME/.npm-global/bin/obsidian-mcp-server" || true
        '';

        script = ''
          export HOME=/var/lib/athena/home
          sock=/var/lib/athena/tmux.sock
          ${pkgs.tmux}/bin/tmux -S "$sock" kill-server 2>/dev/null || true
          rm -f "$sock"
          ${pkgs.tmux}/bin/tmux -S "$sock" new-session -d -s athena \
            -c /var/lib/athena/vault -x 120 -y 40 \
            "$HOME/.local/bin/claude --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions"
          chmod 660 "$sock" 2>/dev/null || true
          while ${pkgs.tmux}/bin/tmux -S "$sock" has-session -t athena 2>/dev/null; do
            sleep 5
          done
        '';
      };

      # ----- Bootstrap: clone/init vault, seed skeleton -----
      systemd.services.athena-bootstrap = {
        description = "Clone or initialize the athena vault on first boot";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" "var-lib-athena.mount" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = "athena";
          Group = "athena";
          EnvironmentFile = "/run/athena-secrets/env";
          RemainAfterExit = true;
        };
        script = ''
          set -e
          umask 077
          vault=/var/lib/athena/vault
          if [ ! -d "$vault/.git" ]; then
            mkdir -p "$vault"
            cd "$vault"
            ${pkgs.git}/bin/git init -b main
            ${pkgs.git}/bin/git remote add origin \
              "https://oauth2:$GITHUB_TOKEN@github.com/viking66/athena.git"
            if ! ${pkgs.git}/bin/git pull origin main 2>/dev/null; then
              # Fresh repo — seed from skeleton.
              cp -r /etc/athena-skeleton/. "$vault/"
              # The pre-commit file is a hook; move it, don't commit it at root.
              install -m 0755 /etc/athena-skeleton/pre-commit "$vault/.git/hooks/pre-commit"
              rm -f "$vault/pre-commit"
              cd "$vault"
              ${pkgs.git}/bin/git add -A
              ${pkgs.git}/bin/git -c user.name=athena -c user.email=athena@gordula.local \
                commit -m "initial vault skeleton" --quiet
              ${pkgs.git}/bin/git push -u origin main --quiet
            fi
          fi
          # Always re-install the hook from the Nix store (updates propagate).
          install -m 0755 /etc/athena-skeleton/pre-commit "$vault/.git/hooks/pre-commit"
          ${pkgs.git}/bin/git -C "$vault" config user.name "athena"
          ${pkgs.git}/bin/git -C "$vault" config user.email "athena@gordula.local"
          ${pkgs.git}/bin/git -C "$vault" remote set-url origin \
            "https://oauth2:$GITHUB_TOKEN@github.com/viking66/athena.git"
        '';
      };

      # ----- ttyd web terminal (browser admin) -----
      systemd.services.ttyd-athena = {
        description = "ttyd web terminal attached to the athena tmux session";
        wantedBy = [ "multi-user.target" ];
        after = [ "athena.service" ];
        serviceConfig = {
          User = "athena";
          Group = "athena";
          Restart = "always";
          RestartSec = 5;
        };
        script = ''
          exec ${pkgs.ttyd}/bin/ttyd \
            --port ${toString ttydPort} \
            --interface 0.0.0.0 \
            --writable \
            ${pkgs.tmux}/bin/tmux -S /var/lib/athena/tmux.sock attach -t athena
        '';
      };

      # ----- Dispatcher: every minute, run scheduled items -----
      systemd.timers.athena-dispatcher = {
        description = "Fire athena scheduled tasks every minute";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1min";
          OnUnitActiveSec = "1min";
          AccuracySec = "5s";
          Unit = "athena-dispatcher.service";
        };
      };

      systemd.services.athena-dispatcher = {
        description = "Run any athena scheduled tasks that are due";
        after = [ "athena.service" ];
        serviceConfig = {
          Type = "oneshot";
          User = "athena";
          Group = "athena";
          EnvironmentFile = "/run/athena-secrets/env";
          Environment = [
            "HOME=/var/lib/athena/home"
            "PATH=/var/lib/athena/home/.local/bin:/run/current-system/sw/bin:/run/wrappers/bin"
          ];
        };
        script = ''exec ${athenaDispatcher}/bin/athena-dispatcher'';
      };
    };
  };
}
