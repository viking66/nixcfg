# Media server stack — Usenet automation + Jellyfin
# Services: SABnzbd, Prowlarr, Sonarr, Radarr, Readarr, Bazarr, Recyclarr, Jellyfin, Seerr
#
# Access model:
#   - Jellyfin + Seerr: public via Caddy (HTTPS)
#   - Everything else: Tailscale only (firewall blocks non-Tailscale traffic on these ports)
{ config, pkgs, lib, flakeRoot, ... }:

{
  # ── Unfree packages needed by the media stack ─────────────────────
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [
      "unrar" # SABnzbd needs unrar for extracting RAR archives
    ];

  # ── Shared media group ────────────────────────────────────────────
  # All media services run under this group so they can read/write /media
  users.groups.media = {};

  # ── Directory structure ───────────────────────────────────────────
  # Downloads and media on the same filesystem (/media LVM) for hardlink support
  systemd.tmpfiles.rules = [
    "d /media/downloads 0775 root media -"
    "d /media/downloads/incomplete 0775 root media -"
    "d /media/downloads/complete 0775 root media -"
    "d /media/tv 0775 root media -"
    "d /media/movies 0775 root media -"
    "d /media/books 0775 root media -"
  ];

  # ── SABnzbd — Usenet download client ──────────────────────────────
  # Configure Frugal Usenet servers via the web UI on first launch (http://gordula:8080)
  services.sabnzbd = {
    enable = true;
    group = "media";
  };

  # ── Prowlarr — indexer manager ────────────────────────────────────
  services.prowlarr.enable = true;

  # ── Sonarr — TV show automation ───────────────────────────────────
  services.sonarr = {
    enable = true;
    group = "media";
  };

  # ── Radarr — movie automation ─────────────────────────────────────
  services.radarr = {
    enable = true;
    group = "media";
  };

  # ── Readarr — ebook/audiobook automation ──────────────────────────
  services.readarr = {
    enable = true;
    group = "media";
  };

  # ── Bazarr — subtitle management ─────────────────────────────────
  services.bazarr = {
    enable = true;
    group = "media";
    listenPort = 6767;
  };

  # ── Intel Quick Sync / VAAPI — hardware transcoding ───────────────
  # i7-8700 has UHD 630 (Coffee Lake, Gen 9.5)
  boot.kernelParams = [ "i915.enable_guc=2" ];

  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver    # iHD driver for Broadwell+ (VAAPI)
      intel-compute-runtime # OpenCL for HDR tone mapping
    ];
  };

  environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";

  # ── Jellyfin — media server ──────────────────────────────────────
  # After first launch, configure transcoding in the web UI:
  #   Dashboard → Playback → Transcoding → Intel QuickSync (QSV)
  #   Enable HW decoding for: H.264, HEVC, MPEG2, VP8, VP9
  #   Do NOT enable: VC1, AV1 (not supported on UHD 630)
  services.jellyfin = {
    enable = true;
    group = "media";
  };

  # Jellyfin needs access to the GPU render device for transcoding
  users.users.jellyfin.extraGroups = [ "render" "video" ];

  # ── Seerr — request/browse UI for Jellyfin ─────────────────────
  services.seerr = {
    enable = true;
    port = 5055;
  };

  # ── Recyclarr — TRaSH Guides quality sync ────────────────────────
  # Runs daily to keep Sonarr/Radarr quality profiles in sync with TRaSH Guides
  # After initial deploy, configure with Sonarr/Radarr API keys:
  #   services.recyclarr.configuration = { sonarr = [{ ... }]; radarr = [{ ... }]; };
  services.recyclarr = {
    enable = true;
    schedule = "daily";
  };

  # ── Fail2Ban — protect public-facing Jellyfin ────────────────────
  services.fail2ban.jails.jellyfin = {
    settings = {
      enabled = true;
      filter = "jellyfin";
      port = "http,https";
      maxretry = 5;
    };
  };

  environment.etc."fail2ban/filter.d/jellyfin.conf".text = ''
    [Definition]
    failregex = ^.*Authentication request for .* has been denied \(IP: "<ADDR>"\)\.
  '';

  # ── Caddy — public reverse proxy for Jellyfin + Seerr ────────────
  services.caddy.virtualHosts = {
    "jellyfin.gordula.com" = {
      extraConfig = ''
        reverse_proxy localhost:8096
      '';
    };
    "requests.gordula.com" = {
      extraConfig = ''
        reverse_proxy localhost:5055
      '';
    };
  };
}
