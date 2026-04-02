# Shared NixOS server configuration
{ config, pkgs, lib, inputs, flakeRoot, ... }:

{
  imports = [
    inputs.home-manager.nixosModules.home-manager
  ];

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = { inherit inputs flakeRoot; };
    sharedModules = [
      inputs.sops-nix.homeManagerModules.sops
    ];
  };

  # Nix settings
  nix = {
    settings = {
      experimental-features = "nix-command flakes";
      trusted-users = [ "jason" ];
      auto-optimise-store = true;
    };
  };

  # Locale & timezone
  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  # SSH — only accessible via Tailscale, not public internet
  services.openssh = {
    enable = true;
    openFirewall = false;  # Don't auto-open port 22 in public firewall
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };

  # Firewall — SSH only via Tailscale (port 22 not public)
  networking.firewall = {
    allowedTCPPorts = [ 80 443 ];
    allowedUDPPorts = [ 41641 ];        # Tailscale WireGuard
    trustedInterfaces = [ "tailscale0" ]; # Allow all traffic over Tailscale (including SSH)
  };

  # Kernel hardening for public-facing server
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.rp_filter" = 1;
    "net.ipv4.conf.default.rp_filter" = 1;
    "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
  };

  # SSH brute force protection
  services.fail2ban.enable = true;

  # Base packages
  environment.systemPackages = with pkgs; [
    git
    helix
    htop
    tmux
    curl
    jq
  ];

  # Caddy reverse proxy — automatic HTTPS via Let's Encrypt
  services.caddy = {
    enable = true;
    virtualHosts."mylist.gordula.com" = {
      extraConfig = ''
        reverse_proxy localhost:3000
      '';
    };
  };

  # Tailscale for admin access
  services.tailscale.enable = true;

  # Comin — GitOps pull-based deployment
  # Base config here; auth token added per-host (see gordula host config)
  services.comin = {
    enable = true;
    remotes = [{
      name = "origin";
      url = "https://github.com/viking66/nixcfg.git";
      branches.main.name = "main";
    }];
  };

  # Automatic garbage collection
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
}
