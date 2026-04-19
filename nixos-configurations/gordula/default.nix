# Gordula — Hetzner dedicated server
# Intel i7-8700, 64GB RAM, 2x 1TB NVMe (LVM)
{ config, pkgs, lib, inputs, flakeRoot, ... }:

let
  my-list = inputs.my-list.packages.x86_64-linux.default;
in
{
  imports = [
    ./hardware.nix
    ./disko.nix
    inputs.disko.nixosModules.disko
    inputs.comin.nixosModules.comin
    inputs.sops-nix.nixosModules.sops
    (flakeRoot + "/nixos-modules/common.nix")
    (flakeRoot + "/nixos-modules/media.nix")
    (flakeRoot + "/nixos-modules/scribe.nix")
  ];

  networking.hostName = "gordula";

  # Legacy BIOS boot — disko auto-populates grub.devices from EF02 partition
  boot.loader.grub.enable = true;

  # Network — Hetzner dedicated, static IPv4 with off-link gateway
  networking.useNetworkd = true;
  networking.useDHCP = false;
  systemd.network.enable = true;
  systemd.network.networks."30-wan" = {
    matchConfig.MACAddress = "30:9c:23:d3:50:6e";
    networkConfig = {
      DHCP = "no";
      IPv6AcceptRA = false;
    };
    address = [
      "46.4.52.96/32"
      "2a01:4f8:140:11fc::2/64"
    ];
    routes = [
      {
        Destination = "0.0.0.0/0";
        Gateway = "46.4.52.65";
        GatewayOnLink = true;
      }
      { Gateway = "fe80::1"; }
    ];
  };

  # SOPS — age key + secrets
  sops = {
    defaultSopsFile = flakeRoot + "/secrets/gordula-secrets.yaml";
    age.keyFile = "/var/lib/sops-nix/gordula-age-key.txt";

    secrets = {
      "github/token" = {};
      "my-list/tmdb-api-key" = {};
      "my-list/LITESTREAM_ACCESS_KEY_ID" = {};
      "my-list/LITESTREAM_SECRET_ACCESS_KEY" = {};
    };

    # Template: renders a nix.conf snippet with the decrypted token
    templates."nix-access-tokens".content = ''
      access-tokens = github.com=${config.sops.placeholder."github/token"}
    '';

    # Template: Litestream environment file with B2 credentials
    templates."litestream-env".content = ''
      LITESTREAM_ACCESS_KEY_ID=${config.sops.placeholder."my-list/LITESTREAM_ACCESS_KEY_ID"}
      LITESTREAM_SECRET_ACCESS_KEY=${config.sops.placeholder."my-list/LITESTREAM_SECRET_ACCESS_KEY"}
    '';
  };

  # Comin auth for private nixcfg repo
  services.comin.remotes = lib.mkForce [{
    name = "origin";
    url = "https://github.com/viking66/nixcfg.git";
    branches.main.name = "main";
    auth.access_token_path = config.sops.secrets."github/token".path;
  }];

  # Nix access token for private GitHub repos (my-list, ralph, nixcfg, etc.)
  nix.extraOptions = ''
    !include ${config.sops.templates."nix-access-tokens".path}
  '';

  # my-list — TV show tracking app
  systemd.services.my-list = {
    description = "my-list TV tracker";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      User = "my-list";
      Group = "my-list";
      StateDirectory = "my-list";
      Restart = "on-failure";
      RestartSec = 5;
      LoadCredential = "tmdb-api-key:${config.sops.secrets."my-list/tmdb-api-key".path}";
    };

    script = ''
      export TMDB_API_KEY=$(cat "$CREDENTIALS_DIRECTORY/tmdb-api-key")
      export MY_LIST_DB_PATH="/var/lib/my-list/my-list.db"
      export MY_LIST_BASE_URL="https://mylist.gordula.com"
      export MY_LIST_VERSION="${inputs.my-list.rev or "unknown"}"
      export MY_LIST_BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      exec ${my-list}/bin/my-list
    '';
  };

  # Litestream — continuous SQLite backup to Backblaze B2
  services.litestream = {
    enable = true;
    environmentFile = config.sops.templates."litestream-env".path;
    settings = {
      dbs = [
        {
          path = "/var/lib/my-list/my-list.db";
          replicas = [
            {
              url = "s3://my-list-backups/my-list.db";
              endpoint = "https://s3.eu-central-003.backblazeb2.com";
              retention = "168h";
              retention-check-interval = "1h";
              snapshot-interval = "24h";
            }
          ];
        }
      ];
    };
  };

  # Dani's birthday card (one-off static site)
  services.caddy.virtualHosts."dani-birthday-2026.gordula.com" = {
    extraConfig = ''
      root * ${flakeRoot}/static/dani-birthday-2026
      file_server
    '';
  };

  # Static user for my-list (needed so Litestream can share DB access)
  users.users.my-list = {
    isSystemUser = true;
    group = "my-list";
  };
  users.groups.my-list = {};

  # Run Litestream as the my-list user so it can access the DB
  systemd.services.litestream.after = [ "my-list.service" ];
  systemd.services.litestream.wants = [ "my-list.service" ];
  systemd.services.litestream.serviceConfig.User = lib.mkForce "my-list";
  systemd.services.litestream.serviceConfig.Group = lib.mkForce "my-list";

  # SSH access — ed25519 key from havoc
  users.users.jason = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      (builtins.readFile (flakeRoot + "/secrets/id_ed25519.pub"))
    ];
  };

  # Disable root login, password auth
  users.users.root.hashedPassword = "!";
  security.sudo.wheelNeedsPassword = false;

  system.stateVersion = "24.11";
}
