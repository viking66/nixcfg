{ config, pkgs, lib, ... }:

{
  sops = {
    defaultSopsFile = ../../secrets/havoc-secrets.yaml;
    
    secrets = {
      "ssh/id_ed25519" = {
        path = "${config.home.homeDirectory}/.ssh/id_ed25519";
        mode = "0600";
      };
      "ssh/id_rsa" = {
        path = "${config.home.homeDirectory}/.ssh/id_rsa";
        mode = "0600";
      };
    };
  };
  
  home.file = {
    ".ssh/id_ed25519.pub".source = ../../secrets/id_ed25519.pub;
    ".ssh/id_rsa.pub".source = ../../secrets/id_rsa.pub;
  };
}
