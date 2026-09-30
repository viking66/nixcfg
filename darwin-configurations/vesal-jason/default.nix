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

  # Host-specific home-manager config for secrets and work-only tooling
  home-manager.users.jason = { config, ... }:
    let
      # Use the PostgreSQL build that contains pgvector; adding pgvector as a
      # separate PATH package does not make CREATE EXTENSION vector available.
      hindsightPostgres = pkgs.postgresql_18.withPackages (ps: [ ps.pgvector ]);
      hindsightData = "${config.home.homeDirectory}/.local/state/hindsight-postgres18";
      hindsightDbUrl = "postgresql://jason@127.0.0.1:55432/hindsight";
      hindsightPgStart = pkgs.writeShellScript "hindsight-postgres-start" ''
        set -eu
        mkdir -p ${lib.escapeShellArg hindsightData}
        chmod 700 ${lib.escapeShellArg hindsightData}
        if [ ! -f ${lib.escapeShellArg "${hindsightData}/PG_VERSION"} ]; then
          if [ -n "$(ls -A ${lib.escapeShellArg hindsightData})" ]; then
            echo "Refusing to initialize non-empty PostgreSQL data directory" >&2
            exit 1
          fi
          ${hindsightPostgres}/bin/initdb -L ${hindsightPostgres}/share/postgresql \
            -D ${lib.escapeShellArg hindsightData} -A trust -U jason --no-instructions
          ${hindsightPostgres}/bin/pg_ctl -D ${lib.escapeShellArg hindsightData} \
            -o '-h 127.0.0.1 -p 55432 -k /tmp' -l ${lib.escapeShellArg "${hindsightData}/bootstrap.log"} start
          ${hindsightPostgres}/bin/createdb -h 127.0.0.1 -p 55432 -U jason hindsight
          ${hindsightPostgres}/bin/psql -h 127.0.0.1 -p 55432 -U jason -d hindsight \
            -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION IF NOT EXISTS vector'
          ${hindsightPostgres}/bin/pg_ctl -D ${lib.escapeShellArg hindsightData} -m fast stop
        fi
        exec ${hindsightPostgres}/bin/postgres -D ${lib.escapeShellArg hindsightData} \
          -h 127.0.0.1 -p 55432 -k /tmp
      '';
      hindsightApiStart = pkgs.writeShellScript "hindsight-api-start" ''
        set -eu
        # The embed CLI starts a detached API; retry while PostgreSQL comes up.
        for attempt in $(seq 1 60); do
          if ${hindsightPostgres}/bin/pg_isready -h 127.0.0.1 -p 55432 -q &&
             ${hindsightPostgres}/bin/psql -h 127.0.0.1 -p 55432 -U jason -d hindsight -Atqc 'SELECT 1' >/dev/null 2>&1; then
            break
          fi
          sleep 2
        done
        ${hindsightPostgres}/bin/psql -h 127.0.0.1 -p 55432 -U jason -d hindsight -Atqc 'SELECT 1' >/dev/null
        export HOME=${lib.escapeShellArg config.home.homeDirectory}
        export PATH="${lib.makeBinPath [ pkgs.uv pkgs.nodejs_26 pkgs.curl pkgs.git hindsightPostgres pkgs.coreutils pkgs.rustc pkgs.cargo ]}:$HOME/.local/bin:/usr/bin:/bin"
        export HINDSIGHT_EMBED_API_DATABASE_URL=${lib.escapeShellArg hindsightDbUrl}
        export HINDSIGHT_API_LLM_PROVIDER=openai-codex
        export HINDSIGHT_API_LLM_MODEL=gpt-6-sol
        # Explicitly persist the correct provider/DB in the embed profile:
        # Pi's own daemon-start path reuses and merges this same profile.
        ${pkgs.uv}/bin/uvx hindsight-embed profile create coding-agent --merge --port 9077 \
          --env "HINDSIGHT_EMBED_API_DATABASE_URL=$HINDSIGHT_EMBED_API_DATABASE_URL" \
          --env "HINDSIGHT_API_LLM_PROVIDER=$HINDSIGHT_API_LLM_PROVIDER" \
          --env "HINDSIGHT_API_LLM_MODEL=$HINDSIGHT_API_LLM_MODEL"
        exec ${pkgs.uv}/bin/uvx hindsight-embed -p coding-agent daemon start
      '';
    in
    {
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
      # Global, versioned policies; Pi packages themselves are pinned in settings.json.
      ".pi/agent/pi-permissions.jsonc".source = flakeRoot + "/dotfiles/pi-permissions.jsonc";
      ".pi/agent/sandbox.json".source = flakeRoot + "/dotfiles/pi-sandbox.json";

      # Work git identity override — activated by the `includeIf` block at
      # the bottom of dotfiles/git.config, which triggers on any remote URL
      # matching `**vesal-security/**`. Only exists on this host, so the
      # includeIf is a no-op on havoc. Matches both `git@github.com:...`
      # and the `github-work` SSH alias (any URL containing vesal-security/).
      ".config/git/config-vesal".text = ''
        [user]
            email = jason@vesal.io
      '';
    };

    home.packages = [
      inputs.devenv.packages.${pkgs.stdenv.hostPlatform.system}.devenv
      pkgs.nodejs_26 # Pi (installed separately) and its npx integrations
      pkgs.uv        # Hindsight's Python API via uvx
      pkgs.rustc     # macOS: uv may need to compile litellm
      pkgs.cargo
      hindsightPostgres # Local PostgreSQL 18 + pgvector for Hindsight
    ];

    # Keep the separate Hindsight database at its existing path/port. Never
    # touch the unrelated PostgreSQL 16 service on port 5432.
    launchd.agents.hindsight-postgres = {
      enable = true;
      config = {
        ProgramArguments = [ "${hindsightPgStart}" ];
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 10;
        StandardOutPath = "${config.home.homeDirectory}/.local/state/hindsight-postgres18/launchd.log";
        StandardErrorPath = "${config.home.homeDirectory}/.local/state/hindsight-postgres18/launchd.log";
      };
    };

    # Pi can also start Hindsight on demand. This agent starts it at login,
    # after PostgreSQL is ready; Hindsight's own daemon is long-lived.
    launchd.agents.hindsight-api = {
      enable = true;
      config = {
        ProgramArguments = [ "${hindsightApiStart}" ];
        RunAtLoad = true;
        StandardOutPath = "${config.home.homeDirectory}/.hindsight/coding-agents-logs/launchd-api.log";
        StandardErrorPath = "${config.home.homeDirectory}/.hindsight/coding-agents-logs/launchd-api.log";
      };
    };

    # Work-only alias
    programs.zsh.shellAliases = {
      useflake = ''echo "source_up\nuse flake \"git+ssh://git@github-work/vesal-security/jason\" --refresh" >> .envrc && direnv allow'';
    };
  };
}
