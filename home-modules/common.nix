{ config, pkgs, lib, inputs, flakeRoot, ... }:

let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

  # Two of mcp-nixos's tests walk the real /nix/store, pick whichever file they
  # happen to find first, and assert the literal word "Error" is absent from the
  # tool output. Any store path containing that word (highlight.pack.js, most
  # compilers' test data, ...) fails the build. The result depends on store
  # contents, so it is flaky rather than a real regression.
  #
  # Drop this once upstream stops asserting on arbitrary store file contents:
  #   https://github.com/utensils/mcp-nixos/blob/main/tests/test_store.py
  mcp-nixos-untested-store-reads = pkgs.mcp-nixos.overridePythonAttrs (old: {
    disabledTests = (old.disabledTests or [ ]) ++ [
      "test_read_text_file"
      "test_read_truncates_with_limit"
    ];
  });

  rexDefaults = {
    "Onboarding.firstRun" = "not-needed";
    "Workspace.darkThemeID" = "custom-B297F63A-21DC-4B6B-82C1-A7A7127ACE5B"; # Nord
    "Workspace.lightThemeID" = "merino-light";
    "Workspace.inactivePaneFadeMode" = "both";
    "Workspace.paneDensity" = "compact";
    "Workspace.shellIconTheme" = "default";
    "Workspace.showsActivePaneBorder" = true;
    "Workspace.showsPaneHeaders" = false;
    "Workspace.tabIconCount" = 1;
    "Workspace.tabIconTintMode" = "off";
    "Workspace.terminalFontName" = "Inconsolata";
    "Workspace.terminalFontPointSize" = 11.0;
    "Workspace.terminalFontSmoothing" = true;
    "Workspace.terminalImproveTextContrast" = true;
    "Workspace.terminalSmoothScrolling" = false;
    "Workspace.usesStandardInactiveWindowPaneStyles" = true;
    # Lets rex -C <client> do client.* drive the app from scripts and the CLI.
    "rex.client.remoteControl" = true;
    "rex.server.automatic-restart-enabled" = true;
    "rex.server.tailnet-enabled" = true;
  };
in
{
  imports = [ inputs.nix-index-database.homeModules.nix-index ];

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

    # Rex keeps its Settings window here until it reads settings from a file.
    # The custom themes are a data value, written by rexThemes below.
    "com.superlogical.rex" = rexDefaults;
  };

  # Rex stores custom themes as one JSON data value, which
  # targets.darwin.defaults can't express. Quit Rex before switching, or it may
  # write its in-memory copy back over this.
  home.activation.rexThemes = lib.mkIf isDarwin (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run /usr/bin/defaults write com.superlogical.rex Workspace.customThemes -data \
        "$(${pkgs.jq}/bin/jq -cj . ${flakeRoot + "/dotfiles/rex.themes.json"} | /usr/bin/xxd -p | tr -d '\n')"
    ''
  );

  # The defaults above overwrite any change made in Rex's Settings window.
  # List those changes before the switch resets them, so they can be copied
  # into rexDefaults. Prints only; never fails the switch.
  home.activation.rexSettingsDrift = lib.mkIf isDarwin (
    lib.hm.dag.entryBetween [ "setDarwinDefaults" ] [ "writeBoundary" ] ''
      ${pkgs.jq}/bin/jq -r 'to_entries[] | [.key, (.value | if type == "boolean" then (if . then "1" else "0" end) elif type == "number" then . + 0 | tostring else tostring end)] | @tsv' \
        ${pkgs.writeText "rex-defaults.json" (builtins.toJSON rexDefaults)} |
      while IFS=$'\t' read -r key want; do
        have=$(/usr/bin/defaults read com.superlogical.rex "$key" 2>/dev/null) || have="(unset)"
        if [ "$have" != "$want" ]; then
          echo "Rex setting changed outside Nix, resetting it: $key is $have, Nix has $want" >&2
        fi
      done
    ''
  );

  # Reload Rex's init.lua once the new one is linked. Skipped when no Rex
  # server is running, so a switch never starts one. A config error is
  # printed but doesn't fail the switch.
  home.activation.reloadRexConfig = lib.mkIf isDarwin (
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      rex="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
      if [ -x "$rex" ] && "$rex" --autostart=false server status > /dev/null 2>&1; then
        run "$rex" --autostart=false config reload || echo "rex config reload reported errors" >&2
      fi
    ''
  );

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
    coreutils
    curl
    delta
    fd
    fontconfig
    git
    helix
    home-manager
    inconsolata
    mcp-nixos-untested-store-reads
    moreutils
    inputs.qmd.packages.${pkgs.stdenv.hostPlatform.system}.default
    ripgrep
    starship
    tree
    tmux
    vscode-langservers-extracted
    wget
    zlib
  ];

  programs = {
    nix-index.enable = true;
    nix-index-database.comma.enable = true;

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
    ".config/rex/init.lua".source = flakeRoot + "/dotfiles/rex.init.lua";
    # Ghostty-format Nord, for Import Theme File on a Mac without Ghostty.
    ".config/rex/themes/Nord".source = flakeRoot + "/dotfiles/rex.theme.nord";
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
