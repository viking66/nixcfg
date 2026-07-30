{ config, pkgs, lib, inputs, flakeRoot, ... }:

{
  imports = [
    inputs.home-manager.darwinModules.home-manager
  ];

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "backup";
    extraSpecialArgs = { inherit inputs flakeRoot; };
    sharedModules = [
      inputs.sops-nix.homeManagerModules.sops
    ];
  };

  nixpkgs.hostPlatform = "aarch64-darwin";
  system.configurationRevision = inputs.self.rev or inputs.self.dirtyRev or null;
  system.stateVersion = 6;

  system.primaryUser = "jason";

  homebrew = {
    enable = true;
    onActivation = {
      autoUpdate = true;
      cleanup = "zap";
      upgrade = true;
    };

    taps = [
      "yakitrak/yakitrak"
    ];

    caskArgs = {
      appdir = "/Applications";
    };

    casks = [
      "ghostty"
      "obsidian"
    ];

    brews = [
      "yakitrak/yakitrak/obsidian-cli"
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
      accept-flake-config = true;
    };

    # No linux-builder. nixpkgs dropped x86_64-darwin, which also removed the
    # aarch64-darwin -> x86_64-linux entry from nixos/lib/qemu-common.nix, so
    # `pkgs.darwin.linux-builder-x86_64` no longer evaluates here. The NixOS
    # hosts build themselves via comin, so nothing on this Mac needs to produce
    # Linux closures.
  };

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

  environment.systemPackages = with pkgs; [
    mosh
  ];

  # Ensure UTF-8 locale is set for all sessions including non-interactive
  # SSH commands (required by mosh-server).
  environment.variables.LANG = "en_US.UTF-8";

  programs.zsh.enable = true;

  launchd.user.agents.no-finder = {
    command = "${pkgs.coreutils}/bin/killall Finder";
    serviceConfig = {
      RunAtLoad = true;
      KeepAlive = false;
    };
  };
}
