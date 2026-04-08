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

  # Include the home-manager-rendered access-tokens snippet so the nix daemon
  # can fetch private GitHub flake inputs (e.g. viking66/my-list). The file is
  # produced by the sops template defined inside `home-manager.users.jason`
  # below — system-level sops-nix on darwin doesn't actually run secret/template
  # activation, so all sops work has to live at the home-manager level.
  nix.extraOptions = ''
    !include /Users/jason/.config/nix/access-tokens.conf
  '';

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
        "viking66-github/token" = {};
      };

      templates."nix-access-tokens" = {
        path = "${config.home.homeDirectory}/.config/nix/access-tokens.conf";
        content = ''
          access-tokens = github.com=${config.sops.placeholder."viking66-github/token"}
        '';
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
