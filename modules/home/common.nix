{ config, pkgs, lib, ... }:

{
  imports = [
    ./sops.nix
  ];

  targets.darwin.defaults = {
    NSGlobalDomain = {
      AppleICUForce24HourTime = true;
      AppleInterfaceStyle = "Dark";
      AppleKeyboardUIMode = 3;
      AppleShowScrollBars = "WhenScrolling";
      "com.apple.swipescrolldirection" = false;
      "com.apple.trackpad.scaling" = 2.0;
    };

    "com.apple.controlcenter" = {
      BatteryShowPercentage = true;
      Bluetooth = true;
    };

    "com.apple.dock" = {
      appswitcher-all-displays = true;
      autohide = true;
      show-recents = false;
      static-only = true;
      tilesize = 26;
    };

    "com.apple.finder" = {
      QuitMenuItem = true;
      ShowPathbar = true;
      _FXShowPosixPathInTitle = true;
    };

    "com.apple.loginwindow" = {
      GuestEnabled = false;
    };

    "com.apple.magicmouse" = {
      MouseButtonMode = "TwoButton";
    };

    "com.apple.menuextra.clock" = {
      Show24Hour = true;
      ShowDate = 1;
      ShowSeconds = true;
    };

    "com.apple.screencapture" = {
      location = "~/Downloads/screenshots";
    };

    "com.apple.screensaver" = {
      askForPassword = true;
    };

    "com.apple.trackpad" = {
      TrackpadRightClick = true;
    };

    "com.apple.WindowManager" = {
      EnableTiledWindowMargins = false;
    };
  };

  home.sessionVariables = {
    NIX_SHELL_PRESERVE_PROMPT = 1;
    FONTCONFIG_FILE = "${pkgs.fontconfig.out}/etc/fonts/fonts.conf";
    FONTCONFIG_PATH = "${pkgs.fontconfig.out}/etc/fonts";
    EDITOR = "hx";
  };

  fonts.fontconfig.enable = true;

  home.packages = with pkgs; [
    age
    atuin
    bat
    cargo
    comma
    coreutils
    curl
    delta
    fd
    fontconfig
    git
    helix
    home-manager
    inconsolata
    moreutils
    ripgrep
    starship
    tree
    tmux
    wget
    zlib
  ];

  programs = {
    nix-index.enable = true;

    direnv = {
      enable = true;
      enableZshIntegration = true;
      nix-direnv.enable = true;
    };

    zsh = {
      enable = true;
      initContent = builtins.readFile ../../dotfiles/zshrc;
    };
  };

  home.file = {
    ".config/atuin/config.toml".text = ''
      encryption = "age"
      enter_accept = true
    '';
    ".dir_colors".source = ../../dotfiles/dir_colors;
    ".config/fourmolu.yaml".source = ../../dotfiles/fourmolu.yaml;
    ".config/ghostty/config".source = ../../dotfiles/ghostty.config;
    ".config/git/config".source = ../../dotfiles/git.config;
    ".config/git/ignore".source = ../../dotfiles/git.ignore;
    ".config/helix/config.toml".source = ../../dotfiles/helix.config.toml;
    ".config/helix/languages.toml".source = ../../dotfiles/helix.languages.toml;
    ".config/nix/nix.conf".text = ''
      experimental-features = nix-command flakes
    '';
    ".ssh/config".source = ../../dotfiles/ssh.config;
    ".config/starship.toml".source = ../../dotfiles/starship.toml;
    ".config/tmux/tmux.conf".source = ../../dotfiles/tmux.conf;

    "bin" = {
      source = ../../bin;
      recursive = true;
      executable = true;
    };
  };
}
