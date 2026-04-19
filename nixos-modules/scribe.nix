# Scribe — sandboxed Claude Code for collaborative screenwriting.
#
# A microvm.nix guest running Claude Code with the Telegram channel plugin.
# Jason drives it from Telegram; the VM pushes the resulting screenplay vault
# to a private GitHub repo (viking66/scribe).
#
# Threat model: Claude runs with --dangerously-skip-permissions and must be
# isolated from the host (sops age key, SSH keys, Litestream creds, media
# stack). Isolation is a microvm (kernel-level boundary) plus egress-only
# networking (cannot reach any host-bound service).
{ config, pkgs, lib, inputs, flakeRoot, ... }:

let
  vmName = "scribe";
  hostIP = "10.233.2.1";
  guestIP = "10.233.2.2";
  subnet = "10.233.2.0/24";
  bridge = "virbr-scribe";
  tapId = "vm-scribe";
  guestMAC = "02:00:00:00:02:02";
  # Verified via `ip link` on gordula 2026-04-18. `enp0s31f6` is the altname.
  wanInterface = "eno1";

  skeletonDir = flakeRoot + "/nixos-modules/scribe/skeleton";

  # Full bybren-llc "Words To Film By" bundle: 24 skills + 10 agents +
  # 20+ slash commands. Read-only symlinked into the scribe user's HOME as
  # user-scope Claude Code resources. See .claude/README.md inside for docs.
  bybrenBundle = pkgs.fetchFromGitHub {
    owner = "bybren-llc";
    repo = "story-systems-template";
    rev = "e4ddd291a5d708737c2e7a97d541fd7f837d195c";
    hash = "sha256-+Rg1Oo5gw6/TYxtBvd0zbPosMaqcZQnfMT8ZlkM8atE=";
  };

  # Must invoke the same systemctl path the sudoers rule allows
  # (/run/current-system/sw/bin/systemctl), not the /nix/store/ path ${pkgs.systemd}
  # would resolve to — sudo matches on command string, not resolved symlink.
  # --no-block because when Claude itself calls scribe-restart, the sudo
  # process is in scribe.service's cgroup; a blocking systemctl restart
  # would wait for its own cgroup to be killed, hanging forever. --no-block
  # queues the request with systemd and returns immediately.
  scribeRestart = pkgs.writeShellScriptBin "scribe-restart" ''
    exec sudo -n /run/current-system/sw/bin/systemctl --no-block restart scribe.service
  '';
in
{
  imports = [ inputs.microvm.nixosModules.host ];

  # Secrets declared on the host. Values are encrypted in
  # secrets/gordula-secrets.yaml. See scribe README for one-time setup.
  sops.secrets = {
    "scribe/claude-code-oauth-token" = {};
    "scribe/telegram-bot-token" = {};
    "scribe/github-pat" = {};
  };

  # Render the three secrets into a single EnvironmentFile. sops-nix
  # renders templates at /run/secrets/rendered/<name> as real files; a
  # .path override would create a SYMLINK to that, which breaks across
  # virtiofs (the symlink's target is a host-side path the guest can't
  # resolve). Instead we render at the default location and materialize
  # a real copy at the shared path via a oneshot below.
  sops.templates."scribe-env" = {
    content = ''
      CLAUDE_CODE_OAUTH_TOKEN=${config.sops.placeholder."scribe/claude-code-oauth-token"}
      TELEGRAM_BOT_TOKEN=${config.sops.placeholder."scribe/telegram-bot-token"}
      GITHUB_TOKEN=${config.sops.placeholder."scribe/github-pat"}
    '';
    mode = "0440";
    owner = "root";
    group = "root";
  };

  # Dedicated directory for the materialized env file so the virtiofs share
  # exposes nothing else. Root-only on the host.
  systemd.tmpfiles.rules = [
    "d /var/lib/scribe-secrets 0700 root root -"
  ];

  # Copy the rendered template to the shared location as a real file so
  # virtiofs can serve its bytes to the guest (symlinks into /run/secrets/
  # don't resolve inside the VM). Ordered before the microvm so the file
  # is present when qemu starts. Re-runs at boot and when sops changes.
  systemd.services.scribe-env-materialize = {
    description = "Materialize scribe env file at the VM's virtiofs share";
    wantedBy = [ "microvm@scribe.service" ];
    before = [ "microvm@scribe.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -D -m 0440 -o root -g root \
        /run/secrets/rendered/scribe-env \
        /var/lib/scribe-secrets/env
    '';
  };

  # ------------------------------------------------------------------------
  # Host networking: bridge + NAT + egress-only firewall
  # ------------------------------------------------------------------------

  # Internal bridge for the VM. The guest's tap attaches here. Host side gets
  # the gateway IP (10.233.2.1).
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
    # IP forwarding is enabled globally via boot.kernel.sysctl below.
  };

  # Attach microvm tap devices to the bridge. microvm.nix creates a tap named
  # `vm-<tapId>` per interface at VM start; we enslave it to our bridge.
  systemd.network.networks."30-${tapId}" = {
    matchConfig.Name = tapId;
    networkConfig = {
      Bridge = bridge;
    };
  };

  # IPv4 forwarding + MASQUERADE for guest egress to the WAN.
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  # Kernel modules needed for VSOCK admin channel into the guest.
  boot.kernelModules = [ "vhost_vsock" ];

  networking.nat = {
    enable = true;
    internalInterfaces = [ bridge ];
    externalInterface = wanInterface;
  };

  # Firewall:
  #   1. Drop NEW connections from guest to host (guest can't reach host
  #      services — my-list, caddy, jellyfin, etc.).
  #   2. Drop NEW connections from the WAN into the guest subnet (the
  #      guest's sshd on 10.233.2.2 is not reachable from the internet).
  # Both use conntrack state — reply traffic (ESTABLISHED/RELATED) flows
  # freely so host-initiated admin SSH to the guest works.
  networking.firewall.extraCommands = ''
    iptables -I INPUT -i ${bridge} -m conntrack --ctstate NEW -j DROP
    iptables -I FORWARD -i ${wanInterface} -d ${subnet} -m conntrack --ctstate NEW -j DROP
  '';
  networking.firewall.extraStopCommands = ''
    iptables -D INPUT -i ${bridge} -m conntrack --ctstate NEW -j DROP 2>/dev/null || true
    iptables -D FORWARD -i ${wanInterface} -d ${subnet} -m conntrack --ctstate NEW -j DROP 2>/dev/null || true
  '';

  # ------------------------------------------------------------------------
  # Host sudoers: let scribe user (INSIDE the VM) trigger a restart.
  # The rule is for the VM's internal sudoers, configured in the guest below.
  # No host-side sudoers changes needed here.
  # ------------------------------------------------------------------------

  # Caddy reverse proxy so Jason can reach the scribe tmux session over
  # Tailscale from any browser (including iPhone Safari — no SSH client
  # needed). Follows the existing internal-service pattern on gordula:
  # port on the host, reachable via `http://gordula:7681`, blocked from
  # the public internet because 7681 isn't in networking.firewall.allowedTCPPorts.
  services.caddy.virtualHosts.":7681" = {
    extraConfig = ''
      bind 0.0.0.0
      reverse_proxy ${guestIP}:7681
    '';
  };

  # Auto-restart the VM when its guest config changes. microvm.nix rebuilds
  # the VM image on config change but does NOT restart running VMs by
  # default. Tying restartTriggers to the guest toplevel makes
  # switch-to-configuration (what comin runs) restart us automatically —
  # critical when Jason deploys from his phone with no SSH on hand.
  systemd.services."microvm@${vmName}".restartTriggers = [
    config.microvm.vms."${vmName}".config.config.system.build.toplevel
  ];

  # ------------------------------------------------------------------------
  # The VM itself
  # ------------------------------------------------------------------------
  microvm.vms."${vmName}" = {
    specialArgs = { inherit inputs flakeRoot; };

    config = { config, pkgs, lib, ... }: {
      # microvm.nix injects its own module automatically via microvm.vms.
      networking.hostName = vmName;
      system.stateVersion = "24.11";
      time.timeZone = "UTC";

      microvm = {
        hypervisor = "qemu";
        vcpu = 2;
        # microvm.nix warns that exactly 2048 MiB causes QEMU to hang; pick a
        # value that isn't a power of 2. See microvm-nix/microvm.nix#171.
        mem = 3072;
        # VSOCK admin channel. Host uses `microvm -s scribe` to SSH in via
        # virtio-vsock (CID 3; CIDs 0-2 are reserved by Linux). Independent
        # of the network — works even if the bridge is misconfigured.
        vsock.cid = 3;

        # Persistent volume for /var/lib/scribe (vault + Claude HOME +
        # npm cache + Telegram pairing state).
        volumes = [{
          image = "scribe-data.img";
          mountPoint = "/var/lib/scribe";
          size = 20480;  # 20 GiB
          fsType = "ext4";
        }];

        # Read-only virtiofs share of the host's rendered secrets directory.
        # Contains only /var/lib/scribe-secrets/env. The guest mounts it at
        # /run/scribe-secrets/. systemd reads EnvironmentFile= as root (in
        # the guest) before dropping to the scribe user.
        shares = [
          {
            source = "/var/lib/scribe-secrets";
            mountPoint = "/run/scribe-secrets";
            tag = "scribe-secrets";
            proto = "virtiofs";
          }
          # Read-only share of the vault skeleton so the guest can seed a
          # fresh repo on first boot without needing network at that moment.
          {
            source = toString skeletonDir;
            mountPoint = "/run/scribe-skeleton";
            tag = "scribe-skeleton";
            proto = "virtiofs";
          }
          # Pinned bybren-llc screenwriting bundle: skills/, agents/, commands/.
          {
            source = "${bybrenBundle}/.claude";
            mountPoint = "/run/scribe-bybren";
            tag = "scribe-bybren";
            proto = "virtiofs";
          }
        ];

        interfaces = [{
          type = "tap";
          id = tapId;
          mac = guestMAC;
        }];
      };

      # Guest networking: static IP on the bridge, default route via host.
      # Using systemd-networkd for consistency with the host.
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

      # sshd on the guest so Jason can attach to the tmux session (first-run
      # Telegram pairing, ad-hoc debugging). The host-side FORWARD drop above
      # keeps this unreachable from the public internet — only gordula itself
      # can connect to 10.233.2.2:22.
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
        allowedTCPPorts = [ 7681 ];  # ttyd web terminal (reachable only via host-side Caddy)
      };

      # Pubkey login for the scribe user — same ed25519 key gordula already
      # trusts for jason.
      users.users.scribe.openssh.authorizedKeys.keys = [
        (builtins.readFile (flakeRoot + "/secrets/id_ed25519.pub"))
      ];

      # Packages inside the guest. Claude Code itself is NOT pinned here —
      # it's installed by ExecStartPre via its native installer into the
      # scribe user's HOME on the persistent volume so it can self-update.
      environment.systemPackages = with pkgs; [
        nodejs_20     # runtime for claude and afterwriting
        bun           # required by the claude-plugins-official Telegram plugin's .mcp.json
        git
        cacert
        curl
        tmux
        ttyd          # web terminal for reaching the tmux from a browser
        scribeRestart
        coreutils
        gnused
        openssh       # for git over SSH if we ever want it; not required
      ];

      # Claude Code's installer drops a generic-linux dynamically-linked
      # binary into the user's HOME. NixOS's pure store has no
      # /lib64/ld-linux-x86-64.so.2, so these binaries won't run without
      # a stub dynamic linker. nix-ld provides one.
      programs.nix-ld.enable = true;

      # The scribe user. Home lives on the persistent volume so Claude's
      # self-installed binary, npm cache, and channel pairing state survive
      # reboots.
      users.users.scribe = {
        isNormalUser = true;
        home = "/var/lib/scribe/home";
        createHome = true;
        uid = 2000;
        # journal read so we can debug scribe.service over SSH without sudo.
        extraGroups = [ "systemd-journal" ];
      };
      users.groups.scribe.gid = 2000;

      # The persistent volume mounts at /var/lib/scribe owned by root
      # (fresh ext4 default). preStart runs as scribe and needs to write
      # there. Chown on every boot via tmpfiles — safe because it only
      # touches the top-level dir, not files scribe created inside.
      systemd.tmpfiles.rules = [
        "d /var/lib/scribe 0755 scribe scribe -"
      ];

      # Narrow sudoers rule: the scribe user can restart its own service
      # without a password. That is the ONLY thing it can do as root.
      # Command must match EXACTLY what scribe-restart invokes — sudo does
      # not do path resolution, so the --no-block flag is part of the match.
      security.sudo = {
        enable = true;
        extraRules = [{
          users = [ "scribe" ];
          commands = [{
            command = "/run/current-system/sw/bin/systemctl --no-block restart scribe.service";
            options = [ "NOPASSWD" ];
          }];
        }];
      };

      # ttyd — serves the scribe tmux session over HTTP on port 7681. Reached
      # only via host-side Caddy on gordula port 7681 (Tailscale-gated by
      # host firewall). Writable (can type into Claude's TUI).
      systemd.services.ttyd-scribe = {
        description = "ttyd web terminal attached to the scribe tmux session";
        wantedBy = [ "multi-user.target" ];
        after = [ "scribe.service" ];
        serviceConfig = {
          User = "scribe";
          Group = "scribe";
          Restart = "always";
          RestartSec = 5;
        };
        script = ''
          exec ${pkgs.ttyd}/bin/ttyd \
            --port 7681 \
            --interface 0.0.0.0 \
            --writable \
            ${pkgs.tmux}/bin/tmux -S /var/lib/scribe/tmux.sock attach -t scribe
        '';
      };

      # The main service.
      systemd.services.scribe = {
        description = "Claude Code screenwriting agent";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" "var-lib-scribe.mount" ];
        wants = [ "network-online.target" ];

        # systemd reads EnvironmentFile as root, then drops to scribe.
        # Do NOT set WorkingDirectory — the vault path is created by
        # preStart, and a missing WorkingDirectory fails the service with
        # "Result: resources" before preStart runs. tmux gets -c explicitly
        # below to make claude start in the vault.
        serviceConfig = {
          User = "scribe";
          Group = "scribe";
          EnvironmentFile = "/run/scribe-secrets/env";
          Restart = "always";
          RestartSec = 10;

          # Hardening. Note: we do NOT set NoNewPrivileges because the
          # scribe-restart helper uses sudo.
          ProtectSystem = "strict";
          ProtectHome = false;  # scribe's HOME is under /var/lib/scribe
          PrivateTmp = true;
          ReadWritePaths = [ "/var/lib/scribe" ];
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictSUIDSGID = false;  # sudo needs SUID
          LockPersonality = true;

          # PATH needs to include Claude's self-installed binary and npm-global.
          Environment = [
            "HOME=/var/lib/scribe/home"
            "PATH=/var/lib/scribe/home/.local/bin:/var/lib/scribe/home/.npm-global/bin:/run/current-system/sw/bin:/run/wrappers/bin"
            "NPM_CONFIG_PREFIX=/var/lib/scribe/home/.npm-global"
          ];
        };

        # Bootstrap steps: install Claude Code + afterwriting if missing,
        # clone or init the vault repo, seed skeleton files if empty.
        preStart = ''
          set -e
          umask 077

          export HOME=/var/lib/scribe/home
          export NPM_CONFIG_PREFIX="$HOME/.npm-global"
          mkdir -p "$HOME/.local/bin" "$HOME/.npm-global/bin" "$HOME/.claude/skills"

          # Install Claude Code (native installer, self-updating) if absent.
          if [ ! -x "$HOME/.local/bin/claude" ]; then
            echo "Installing Claude Code..."
            ${pkgs.curl}/bin/curl -fsSL https://claude.ai/install.sh | sh
          fi

          # Install afterwriting if absent. Cached on the persistent volume
          # so only first boot needs network for this.
          if [ ! -x "$HOME/.npm-global/bin/afterwriting" ]; then
            echo "Installing afterwriting..."
            ${pkgs.nodejs_20}/bin/npm install -g afterwriting
          fi

          # Symlink the bybren-llc bundle subdirs (skills, agents, commands)
          # into the user-level ~/.claude/ so they apply to every Claude
          # session. Each is an RO symlink into /nix/store via virtiofs —
          # upgrades happen by bumping the bybrenBundle rev in scribe.nix.
          mkdir -p "$HOME/.claude"
          for subdir in skills agents commands; do
            ln -sfn "/run/scribe-bybren/$subdir" "$HOME/.claude/$subdir"
          done

          # Materialize the Telegram plugin's .env file from the bot token
          # in our service environment. The plugin requires this file to
          # exist even though the env var is set — "takes precedence" in the
          # upstream docs is misleading. Written every boot so the token
          # stays in sync with sops.
          mkdir -p "$HOME/.claude/channels/telegram"
          install -m 0600 /dev/null "$HOME/.claude/channels/telegram/.env"
          printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TELEGRAM_BOT_TOKEN" \
            > "$HOME/.claude/channels/telegram/.env"

          # Initialize the vault if not present.
          vault="/var/lib/scribe/vault"
          if [ ! -d "$vault/.git" ]; then
            echo "Initializing vault at $vault..."
            mkdir -p "$vault"
            cd "$vault"
            ${pkgs.git}/bin/git init -b main
            ${pkgs.git}/bin/git remote add origin "https://oauth2:$GITHUB_TOKEN@github.com/viking66/scribe.git"
            # Try to pull in case the repo already has content.
            if ! ${pkgs.git}/bin/git pull origin main 2>/dev/null; then
              # Empty repo: seed from skeleton.
              cp -r /run/scribe-skeleton/. "$vault/"
              install -m 0755 /run/scribe-skeleton/pre-commit "$vault/.git/hooks/pre-commit"
              ${pkgs.git}/bin/git add -A
              ${pkgs.git}/bin/git -c user.name=scribe -c user.email=scribe@gordula.local commit -m "initial vault skeleton"
              ${pkgs.git}/bin/git push -u origin main
            fi
          fi

          # Always refresh the pre-commit hook from the skeleton (in case
          # we update it in the nixcfg).
          install -m 0755 /run/scribe-skeleton/pre-commit "$vault/.git/hooks/pre-commit"

          # Git identity.
          ${pkgs.git}/bin/git -C "$vault" config user.name "scribe"
          ${pkgs.git}/bin/git -C "$vault" config user.email "scribe@gordula.local"

          # Refresh the remote URL with the current token every boot (in case
          # the PAT was rotated via sops).
          ${pkgs.git}/bin/git -C "$vault" remote set-url origin \
            "https://oauth2:$GITHUB_TOKEN@github.com/viking66/scribe.git"
        '';

        # Claude Code's --channels flag crashes headlessly with no pty
        # (anthropics/claude-code#40726). Run it inside a detached tmux
        # session to give it a real pty. The service has PrivateTmp=true
        # so we place the socket under the persistent volume instead of
        # /tmp — that way an admin SSH session can attach:
        #   ssh -J jason@gordula scribe@10.233.2.2
        #   tmux -S /var/lib/scribe/tmux.sock attach -t scribe
        # (Detach with Ctrl-b d; Claude keeps running.)
        script = ''
          export HOME=/var/lib/scribe/home
          sock=/var/lib/scribe/tmux.sock
          # Clean up any stale socket/server from a prior crash.
          ${pkgs.tmux}/bin/tmux -S "$sock" kill-server 2>/dev/null || true
          rm -f "$sock"
          ${pkgs.tmux}/bin/tmux -S "$sock" new-session -d -s scribe \
            -c /var/lib/scribe/vault -x 120 -y 40 \
            "$HOME/.local/bin/claude --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions"
          # Make the socket world-read for the scribe group so interactive
          # attaches over SSH can reach it (the service user and SSH user
          # are both scribe so this is purely belt-and-suspenders).
          chmod 660 "$sock" 2>/dev/null || true
          # Block until claude exits (tmux session goes away).
          while ${pkgs.tmux}/bin/tmux -S "$sock" has-session -t scribe 2>/dev/null; do
            sleep 5
          done
        '';
      };
    };
  };
}
