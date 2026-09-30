{
  description = "Jason's system config";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    ez-configs = {
      # Upstream HEAD plus ehllie/ez-configs#27 (stdenv.is* deprecation fix).
      # Switch back to github:ehllie/ez-configs once that PR merges.
      url = "github:magistau/ez-configs/dc144599881813cdfacef08da8ef33c0ab47f798";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
    };

    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    my-list = {
      url = "github:viking66/my-list";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    qmd = {
      url = "github:tobi/qmd";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # devenv pinned directly from upstream until nixos-unstable catches up.
    # As of 2026-07-30 nixos-unstable still ships 2.0.6, so this input is
    # still required.
    #
    # Bumped 2.1 -> 2.2 for two features the intel-app devenv wants:
    #   - `devenv up` attaches to an already-running process manager instead of
    #     failing, plus `devenv processes attach` / `start <name>` and a
    #     `devenv down` shorthand.
    #   - `--from` + `devenv allow` bind a directory to an out-of-tree config,
    #     which is how intel-app worktrees can share one devenv.nix instead of
    #     each getting a copy that silently goes stale.
    # Breaking changes to be aware of: x86_64-darwin support was dropped (this
    # host is aarch64), and auto-activation now keys on devenv.nix rather than
    # devenv.yaml.
    #
    # Bumped 2.2 -> 2.3 on 2026-09-22 for portless: `process.proxy.enable` puts
    # a shared Pingora proxy on port 80 and serves each process at
    # `<process>.<project>.localhost`, which removes the "which of my stacks owns
    # port 8002" problem that costs real time with several worktrees running.
    #
    # ONE THING TO KNOW BEFORE TURNING THE PROXY ON, measured rather than read:
    # the hostname derives from the PROJECT NAME, and two projects sharing a name
    # collide. The second refuses to start with "hostname web.spike.localhost is
    # already owned by another project" — it fails closed rather than silently
    # crossing traffic, but it does not start. Since every intel-app worktree is
    # the same project, `name` has to derive from `config.devenv.root` before
    # `process.proxy.enable` is any use here. Verified both halves with two
    # throwaway projects on 2026-09-22.
    #
    # The proxy needed no sudo on macOS, despite the release notes mentioning it
    # for port 80 on Linux.
    #
    # REMOVE THIS INPUT once `pkgs.devenv.version` in the resolved nixpkgs
    # is >= 2.3. To check after a `nix flake update`:
    #   nix eval .#nixosConfigurations.<host>.pkgs.devenv.version
    # or for the home-manager packages set:
    #   nix eval nixpkgs#devenv.version --override-input nixpkgs ./flake.lock
    # When you remove this, also revert the `home.packages` line in
    # darwin-configurations/vesal-jason/default.nix back to `pkgs.devenv`,
    # and drop the devenv cache from `nixConfig` below.
    #
    # nixpkgs deliberately does NOT follow ours. devenv builds a static,
    # unity-build fork of Nix, and following our nixpkgs means compiling it
    # locally against whatever Meson we lock. Meson 1.12.1 (nixpkgs b4fd65b)
    # breaks that build: src/libstore has a `build/` subdirectory, and Meson
    # resolves `build/build-log.cc` against the `build` build dir. With
    # devenv's own pinned nixpkgs, devenv.cachix.org serves the binary.
    devenv.url = "github:cachix/devenv/v2.3";
  };

  # Lets the first `nix run .#switch` substitute devenv, before the system
  # nix.conf knows about this cache. accept-flake-config is on in
  # darwin-modules/common.nix, and root and jason are both trusted.
  nixConfig = {
    extra-substituters = [ "https://devenv.cachix.org" ];
    extra-trusted-public-keys = [
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
    ];
  };

  outputs = inputs@{ self, nixpkgs, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "aarch64-darwin" "x86_64-linux" ];

      imports = [
        inputs.ez-configs.flakeModule
      ];

      ezConfigs = {
        root = ./.;
        globalArgs = { inherit inputs; flakeRoot = ./.; };

        darwin.hosts = {
          havoc = {
            userHomeModules = [ "jason" ];
          };
          vesal-jason = {
            userHomeModules = [ "jason" ];
          };
        };

        nixos.hosts = {
          gordula = {
            userHomeModules = [ "jason" ];
          };
        };

        home.users.jason = {
          passInOsConfig = true;
        };
      };

      # Per-system outputs (apps for switching)
      perSystem = { pkgs, system, ... }: {
        apps = {
          switch = {
            type = "app";
            program = toString (pkgs.writeShellScript "switch" (
              if pkgs.stdenv.hostPlatform.isDarwin then ''
                set -e

                # macOS sudo keeps the caller's $HOME, so `sudo nix run` warns
                # that $HOME is not owned by root. Run `nix run .#switch` as the
                # user instead and escalate here with a root $HOME.
                if [ "$EUID" -ne 0 ]; then
                  exec sudo -H "$0" "$@"
                fi

                HOSTNAME=$(hostname -s)
                echo "Detected hostname: $HOSTNAME"

                # Resolve the invoking user's home (sudo sets HOME=/var/root).
                ACTUAL_USER="''${SUDO_USER:-$USER}"
                KEY_PATH="/Users/$ACTUAL_USER/.config/sops/age/key.txt"

                if [ ! -f "$KEY_PATH" ]; then
                  cat >&2 <<EOF

                ERROR: sops age key not found at $KEY_PATH

                Copy your AGE secret key (AGE-SECRET-KEY-1...) to the clipboard,
                then run:

                  mkdir -p "$(dirname "$KEY_PATH")" && pbpaste > "$KEY_PATH" && chmod 600 "$KEY_PATH"

                EOF
                  exit 1
                fi

                KEY_PERMS=$(${pkgs.coreutils}/bin/stat -c '%a' "$KEY_PATH")
                if [ "$KEY_PERMS" != "600" ]; then
                  cat >&2 <<EOF

                ERROR: sops age key at $KEY_PATH has insecure permissions ($KEY_PERMS)

                Fix with:

                  chmod 600 "$KEY_PATH"

                EOF
                  exit 1
                fi

                # darwin-rebuild applies both darwin config and home-manager
                # (home-manager is integrated as a darwin module)
                echo "Applying Darwin + Home Manager configuration..."
                darwin-rebuild switch --flake .#$HOSTNAME
              '' else ''
                set -e
                HOSTNAME=$(hostname -s)
                echo "Detected hostname: $HOSTNAME"

                if [ "$EUID" -ne 0 ]; then
                  echo "This script must be run with sudo:"
                  echo "  sudo nix run .#switch"
                  exit 1
                fi

                KEY_PATH="/var/lib/sops-nix/key.txt"

                if [ ! -f "$KEY_PATH" ]; then
                  cat >&2 <<EOF

                ERROR: sops age key not found at $KEY_PATH

                Paste your AGE secret key (AGE-SECRET-KEY-1...) into the
                following command, then press Ctrl-D:

                  sudo install -d -m 0755 /var/lib/sops-nix && sudo install -m 0400 /dev/stdin /var/lib/sops-nix/key.txt

                EOF
                  exit 1
                fi

                KEY_PERMS=$(${pkgs.coreutils}/bin/stat -c '%a' "$KEY_PATH")
                if [ "$KEY_PERMS" != "400" ]; then
                  cat >&2 <<EOF

                ERROR: sops age key at $KEY_PATH has insecure permissions ($KEY_PERMS)

                Fix with:

                  sudo chmod 400 "$KEY_PATH"

                EOF
                  exit 1
                fi

                echo "Applying NixOS configuration..."
                nixos-rebuild switch --flake .#$HOSTNAME
              ''
            ));
          };

          switch-home = {
            type = "app";
            program = toString (pkgs.writeShellScript "switch-home" ''
              set -e
              HOSTNAME=$(hostname -s)
              echo "Applying Home Manager configuration for jason@$HOSTNAME..."
              ${inputs.home-manager.packages.${system}.home-manager}/bin/home-manager switch --flake .#jason@$HOSTNAME
            '');
          };
        };
      };
    };
}
