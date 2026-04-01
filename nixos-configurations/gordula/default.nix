# Gordula — Hetzner dedicated server
# Intel i7-8700, 64GB RAM, 2x 1TB NVMe (LVM)
{ config, pkgs, lib, inputs, flakeRoot, ... }:

{
  imports = [
    ./hardware.nix
    ./disko.nix
    inputs.disko.nixosModules.disko
    inputs.comin.nixosModules.comin
    inputs.sops-nix.nixosModules.sops
    (flakeRoot + "/nixos-modules/common.nix")
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
      "github-token" = {};
    };

    # Template: renders a nix.conf snippet with the decrypted token
    templates."nix-access-tokens".content = ''
      access-tokens = github.com=${config.sops.placeholder."github-token"}
    '';
  };

  # Comin auth for private nixcfg repo
  services.comin.remotes = lib.mkForce [{
    name = "origin";
    url = "https://github.com/viking66/nixcfg.git";
    branches.main.name = "main";
    auth.access_token_path = config.sops.secrets."github-token".path;
  }];

  # Nix access token for private GitHub repos (my-list, ralph, nixcfg, etc.)
  nix.extraOptions = ''
    !include ${config.sops.templates."nix-access-tokens".path}
  '';

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
