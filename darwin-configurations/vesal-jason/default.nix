{ config, pkgs, lib, inputs, flakeRoot, ... }:

{
  imports = [
    (flakeRoot + "/darwin-modules/common.nix")
  ];

  networking = {
    computerName = "vesal-jason";
    hostName = "vesal-jason";
  };

  ids.gids.nixbld = 350;

  homebrew.casks = [
    "1password"
    "1password-cli"
  ];

  # Host-specific home-manager config for secrets and work-only aliases
  home-manager.users.jason = { config, ... }: {
    sops = {
      defaultSopsFile = flakeRoot + "/secrets/vesal-jason-secrets.yaml";

      secrets = {
        "ssh/gh_id_ed25519" = {
          path = "${config.home.homeDirectory}/.ssh/gh_id_ed25519";
          mode = "0600";
        };
      };
    };

    home.file = {
      ".ssh/gh_id_ed25519.pub".source = flakeRoot + "/secrets/gh_id_ed25519.pub";
    };

    home.packages = [ pkgs.devenv ];

    # Work-only alias
    programs.zsh.shellAliases = {
      useflake = ''echo "source_up\nuse flake \"git+ssh://git@github-work/vesal-security/jason\" --refresh" >> .envrc && direnv allow'';
    };
  };
}
