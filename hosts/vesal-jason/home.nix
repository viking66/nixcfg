{ config, pkgs, lib, ... }:

{
  sops = {
    defaultSopsFile = ../../secrets/vesal-jason-secrets.yaml;
    
    secrets = {
      "ssh/gh_id_ed25519" = {
        path = "${config.home.homeDirectory}/.ssh/gh_id_ed25519";
        mode = "0600";
      };
    };
  };
  
  home.file = {
    ".ssh/gh_id_ed25519.pub".source = ../../secrets/gh_id_ed25519.pub;
  };
}
