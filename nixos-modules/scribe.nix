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

  scribeRestart = pkgs.writeShellScriptBin "scribe-restart" ''
    exec sudo -n ${pkgs.systemd}/bin/systemctl restart scribe.service
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

  # Render the three secrets into a single EnvironmentFile at a stable path
  # that we virtiofs-share into the guest. systemd reads EnvironmentFile as
  # root before dropping privileges, so the scribe user in the guest never
  # needs read access to the file itself.
  sops.templates."scribe-env" = {
    content = ''
      CLAUDE_CODE_OAUTH_TOKEN=${config.sops.placeholder."scribe/claude-code-oauth-token"}
      TELEGRAM_BOT_TOKEN=${config.sops.placeholder."scribe/telegram-bot-token"}
      GITHUB_TOKEN=${config.sops.placeholder."scribe/github-pat"}
    '';
    path = "/var/lib/scribe-secrets/env";
    mode = "0440";
    owner = "root";
    group = "root";
  };

  # Dedicated directory for the env file so the virtiofs share exposes nothing
  # else. Root-only on the host.
  systemd.tmpfiles.rules = [
    "d /var/lib/scribe-secrets 0700 root root -"
  ];

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

  # Firewall: drop NEW connections initiated by the guest to the host. We
  # must use conntrack state — a blanket DROP would also break replies to
  # host-initiated flows (ping, admin SSH if we enable it later, etc.). Guest
  # can still egress to the WAN via NAT (FORWARD chain, unaffected). Guest
  # CANNOT reach host services (my-list, caddy, jellyfin, etc.).
  networking.firewall.extraCommands = ''
    iptables -I INPUT -i ${bridge} -m conntrack --ctstate NEW -j DROP
  '';
  networking.firewall.extraStopCommands = ''
    iptables -D INPUT -i ${bridge} -m conntrack --ctstate NEW -j DROP 2>/dev/null || true
  '';

  # ------------------------------------------------------------------------
  # Host sudoers: let scribe user (INSIDE the VM) trigger a restart.
  # The rule is for the VM's internal sudoers, configured in the guest below.
  # No host-side sudoers changes needed here.
  # ------------------------------------------------------------------------

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

      # No public SSH on the guest; no open ports at all (Claude dials out to
      # Telegram and the Anthropic API, nothing dials in).
      networking.firewall.enable = true;

      # Packages inside the guest. Claude Code itself is NOT pinned here —
      # it's installed by ExecStartPre via its native installer into the
      # scribe user's HOME on the persistent volume so it can self-update.
      environment.systemPackages = with pkgs; [
        nodejs_20     # runtime for claude and afterwriting
        git
        cacert
        curl
        tmux
        scribeRestart
        coreutils
        gnused
        openssh       # for git over SSH if we ever want it; not required
      ];

      # The scribe user. Home lives on the persistent volume so Claude's
      # self-installed binary, npm cache, and channel pairing state survive
      # reboots.
      users.users.scribe = {
        isNormalUser = true;
        home = "/var/lib/scribe/home";
        createHome = true;
        uid = 2000;
      };
      users.groups.scribe.gid = 2000;

      # Narrow sudoers rule: the scribe user can restart its own service
      # without a password. That is the ONLY thing it can do as root.
      security.sudo = {
        enable = true;
        extraRules = [{
          users = [ "scribe" ];
          commands = [{
            command = "/run/current-system/sw/bin/systemctl restart scribe.service";
            options = [ "NOPASSWD" ];
          }];
        }];
      };

      # The main service.
      systemd.services.scribe = {
        description = "Claude Code screenwriting agent";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" "var-lib-scribe.mount" ];
        wants = [ "network-online.target" ];

        # systemd reads EnvironmentFile as root, then drops to scribe.
        serviceConfig = {
          User = "scribe";
          Group = "scribe";
          WorkingDirectory = "/var/lib/scribe/vault";
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
        # (anthropics/claude-code#40726). We run it inside a detached tmux
        # session to give it a real pty, then block until the session ends
        # so systemd tracks the lifetime correctly. Attach for debugging
        # or first-run pairing with:
        #   machinectl shell scribe@     (or SSH into the VM if enabled)
        #   sudo -u scribe tmux -L scribe attach -t scribe
        script = ''
          export HOME=/var/lib/scribe/home
          # Clean up any stale server from a prior crash.
          ${pkgs.tmux}/bin/tmux -L scribe kill-server 2>/dev/null || true
          ${pkgs.tmux}/bin/tmux -L scribe new-session -d -s scribe -x 120 -y 40 \
            "$HOME/.local/bin/claude --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions"
          # Block until claude exits (tmux session goes away).
          while ${pkgs.tmux}/bin/tmux -L scribe has-session -t scribe 2>/dev/null; do
            sleep 5
          done
        '';
      };
    };
  };
}
