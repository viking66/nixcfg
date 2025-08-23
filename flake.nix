{
  description = "Jason's system config";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    
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
  };

  outputs = { self, nixpkgs, nix-darwin, home-manager, sops-nix, ... }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
      
      mkDarwinConfig = hostname: nix-darwin.lib.darwinSystem {
        inherit system;
        modules = [
          ./modules/darwin/common.nix
          ./hosts/${hostname}/darwin.nix
          {
            system.configurationRevision = self.rev or self.dirtyRev or null;
            system.stateVersion = 6;
            nixpkgs.hostPlatform = system;
          }
        ];
      };
      
      mkHomeConfig = hostname: home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          sops-nix.homeManagerModules.sops
          ./modules/home/common.nix
          ./hosts/${hostname}/home.nix
          {
            home = {
              username = "jason";
              homeDirectory = "/Users/jason";
              stateVersion = "24.05";
            };
          }
        ];
      };
    in
    {
      darwinConfigurations = {
        havoc = mkDarwinConfig "havoc";
        vesal-jason = mkDarwinConfig "vesal-jason";
      };
      
      homeConfigurations = {
        "jason@havoc" = mkHomeConfig "havoc";
        "jason@vesal-jason" = mkHomeConfig "vesal-jason";
      };
      
      apps.${system} = {
        # Auto-detect based on hostname
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
            
            # Get the actual user (not root)
            ACTUAL_USER="$SUDO_USER"
            if [ -z "$ACTUAL_USER" ]; then
              echo "Could not determine actual user"
              exit 1
            fi
            
            # Run darwin-rebuild with preserved environment
            echo "Applying Darwin configuration..."
            darwin-rebuild switch --flake .#$HOSTNAME
            
            # Run home-manager as the actual user
            echo "Applying Home Manager configuration as user $ACTUAL_USER..."
            sudo -u "$ACTUAL_USER" ${home-manager.packages.${system}.home-manager}/bin/home-manager switch --flake .#$ACTUAL_USER@$HOSTNAME
          '');
        };
        
        switch-havoc = {
          type = "app";
          program = toString (pkgs.writeShellScript "switch-havoc" ''
            set -e
            
            if [ "$EUID" -ne 0 ]; then
              echo "This script must be run with sudo:"
              echo "  sudo nix run .#switch-havoc"
              exit 1
            fi
            
            ACTUAL_USER="$SUDO_USER"
            if [ -z "$ACTUAL_USER" ]; then
              echo "Could not determine actual user"
              exit 1
            fi
            
            echo "Switching to havoc configuration..."
            ${nix-darwin.packages.${system}.darwin-rebuild}/bin/darwin-rebuild switch --flake .#havoc
            echo "Applying Home Manager configuration as user $ACTUAL_USER..."
            sudo -u "$ACTUAL_USER" ${home-manager.packages.${system}.home-manager}/bin/home-manager switch --flake .#$ACTUAL_USER@havoc
          '');
        };
        
        switch-vesal-jason = {
          type = "app";
          program = toString (pkgs.writeShellScript "switch-vesal-jason" ''
            set -e
            
            if [ "$EUID" -ne 0 ]; then
              echo "This script must be run with sudo:"
              echo "  sudo nix run .#switch-vesal-jason"
              exit 1
            fi
            
            ACTUAL_USER="$SUDO_USER"
            if [ -z "$ACTUAL_USER" ]; then
              echo "Could not determine actual user"
              exit 1
            fi
            
            echo "Switching to vesal-jason configuration..."
            ${nix-darwin.packages.${system}.darwin-rebuild}/bin/darwin-rebuild switch --flake .#vesal-jason
            echo "Applying Home Manager configuration as user $ACTUAL_USER..."
            sudo -u "$ACTUAL_USER" ${home-manager.packages.${system}.home-manager}/bin/home-manager switch --flake .#$ACTUAL_USER@vesal-jason
          '');
        };
        
        switch-home = {
          type = "app";
          program = toString (pkgs.writeShellScript "switch-home" ''
            set -e
            HOSTNAME=$(hostname -s)
            echo "Applying Home Manager configuration for jason@$HOSTNAME..."
            ${home-manager.packages.${system}.home-manager}/bin/home-manager switch --flake .#jason@$HOSTNAME
          '');
        };
      };
    };
}
