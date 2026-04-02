{ config, pkgs, lib, inputs, flakeRoot, ... }:

{
  imports = [
    (flakeRoot + "/darwin-modules/common.nix")
  ];

  networking = {
    computerName = "havoc";
    hostName = "havoc";
  };

  ids.gids.nixbld = 30000;

  # Host-specific home-manager config for secrets
  home-manager.users.jason = { config, ... }: {
    sops = {
      defaultSopsFile = flakeRoot + "/secrets/havoc-secrets.yaml";

      secrets = {
        "ssh/id_ed25519" = {
          path = "${config.home.homeDirectory}/.ssh/id_ed25519";
          mode = "0600";
        };
        "ssh/id_rsa" = {
          path = "${config.home.homeDirectory}/.ssh/id_rsa";
          mode = "0600";
        };
        "github/token" = {};
      };

      # Template: renders nix.conf snippet with GitHub access token
      templates."nix-access-tokens" = {
        content = ''
          access-tokens = github.com=${config.sops.placeholder."github/token"}
        '';
      };
    };

    # nix.conf with !include for the sops-rendered access token
    home.file.".config/nix/nix.conf".text = ''
      experimental-features = nix-command flakes
      !include ${config.sops.templates."nix-access-tokens".path}
    '';

    home.file = {
      ".ssh/id_ed25519.pub".source = flakeRoot + "/secrets/id_ed25519.pub";
      ".ssh/id_rsa.pub".source = flakeRoot + "/secrets/id_rsa.pub";
    };
  };
}
