{
  description = "Jason's system config";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    ez-configs = {
      url = "github:ehllie/ez-configs";
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
              if pkgs.stdenv.isDarwin then ''
                set -e
                HOSTNAME=$(hostname -s)
                echo "Detected hostname: $HOSTNAME"

                if [ "$EUID" -ne 0 ]; then
                  echo "This script must be run with sudo:"
                  echo "  sudo nix run .#switch"
                  exit 1
                fi

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
