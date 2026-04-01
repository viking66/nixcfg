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
            program = toString (pkgs.writeShellScript "switch" ''
              set -e
              HOSTNAME=$(hostname -s)
              echo "Detected hostname: $HOSTNAME"

              # Check if running as root
              if [ "$EUID" -ne 0 ]; then
                echo "This script must be run with sudo:"
                echo "  sudo nix run .#switch"
                exit 1
              fi

              # darwin-rebuild applies both darwin config and home-manager
              # (home-manager is integrated as a darwin module)
              echo "Applying Darwin + Home Manager configuration..."
              darwin-rebuild switch --flake .#$HOSTNAME
            '');
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
