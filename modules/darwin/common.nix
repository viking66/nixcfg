{ config, pkgs, lib, ... }:

{
  system.primaryUser = "jason";

  homebrew = {
    enable = true;
    onActivation = {
      autoUpdate = true;
      cleanup = "zap";
      upgrade = true;
    };
    
    taps = [
      "homebrew/bundle"
    ];

    caskArgs = {
      appdir = "/Applications";
    };
    
    casks = [
      "ghostty"
    ];
    
    brews = [
    ];
  };

  nix = {
    enable = true;
    package = pkgs.nixVersions.latest;
    
    settings = {
      build-users-group = "nixbld";
      experimental-features = "nix-command flakes";
      bash-prompt-prefix = "(nix:$name) ";
      max-jobs = "auto";
      substituters = [
        "https://cache.nixos.org"
        "https://cache.lix.systems"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "cache.lix.systems:aBnZUw8zA7H35Cz2RyKFVs3H4PlGTLawyY5KRbvJR8o="
      ];
      extra-nix-path = "nixpkgs=flake:nixpkgs";
      trusted-users = [ "jason" ];
      builders-use-substitutes = true;
    };
    
    linux-builder = {
      enable = true;
      maxJobs = 4;
      supportedFeatures = [ "kvm" "benchmark" "big-parallel" ];
      package = pkgs.darwin.linux-builder-x86_64;
      systems = [ "x86_64-linux" ];
    };
  };

  ids.gids.nixbld = 30000;

  power.sleep = {
    allowSleepByPowerButton = true;
    computer = 20;
    display = 10;
    harddisk = 10;
  };

  security.pam.services.sudo_local.touchIdAuth = true;

  users.users.jason = {
    name = "jason";
    home = "/Users/jason";
    shell = pkgs.zsh;
  };

  programs.zsh.enable = true;

  launchd.user.agents.no-finder = {
    command = "${pkgs.coreutils}/bin/killall Finder";
    serviceConfig = {
      RunAtLoad = true;
      KeepAlive = false;
    };
  };
}
