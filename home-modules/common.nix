{ config, pkgs, lib, flakeRoot, ... }:

let
  isDarwin = pkgs.stdenv.isDarwin;
in
{
  home = {
    username = "jason";
    homeDirectory = if isDarwin then "/Users/jason" else "/home/jason";
    stateVersion = "24.05";
  };

  targets.darwin.defaults = lib.mkIf isDarwin {
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
      initContent = builtins.readFile (flakeRoot + "/dotfiles/zshrc");
    };
  };

  home.file = {
    ".config/atuin/config.toml".text = ''
      encryption = "age"
      enter_accept = true
    '';
    ".dir_colors".source = flakeRoot + "/dotfiles/dir_colors";
    ".config/fourmolu.yaml".source = flakeRoot + "/dotfiles/fourmolu.yaml";
    ".config/ghostty/config".source = flakeRoot + "/dotfiles/ghostty.config";
    ".config/git/config".source = flakeRoot + "/dotfiles/git.config";
    ".config/git/ignore".source = flakeRoot + "/dotfiles/git.ignore";
    ".config/helix/config.toml".source = flakeRoot + "/dotfiles/helix.config.toml";
    ".config/helix/languages.toml".source = flakeRoot + "/dotfiles/helix.languages.toml";
    ".config/nix/nix.conf".text = ''
      experimental-features = nix-command flakes
    '';
    ".ssh/config".source = flakeRoot + "/dotfiles/ssh.config";
    ".config/starship.toml".source = flakeRoot + "/dotfiles/starship.toml";
    ".config/tmux/tmux.conf".source = flakeRoot + "/dotfiles/tmux.conf";

    "bin" = {
      source = flakeRoot + "/bin";
      recursive = true;
      executable = true;
    };
  };
}
