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

  # Workaround: the NixOS sabnzbd module's preStart config_merge.py crashes
  # if sabnzbd.ini doesn't exist yet (first boot). Seed with minimal config
  # that binds to all interfaces and allows access from Tailscale.
  systemd.services.sabnzbd.preStart = lib.mkBefore ''
    if [ ! -f /var/lib/sabnzbd/sabnzbd.ini ]; then
      cat > /var/lib/sabnzbd/sabnzbd.ini << 'SABCFG'
    [misc]
    host = 0.0.0.0
    port = 8080
    inet_exposure = 4
    host_whitelist = gordula, gordula.tail1993ce.ts.net,
    download_dir = /media/downloads/incomplete
    complete_dir = /media/downloads/complete
    SABCFG
    fi
  '';

  # ── Prowlarr — indexer manager ────────────────────────────────────
  services.prowlarr.enable = true;

  # ── Sonarr — TV show automation ───────────────────────────────────
  services.sonarr = {
    enable = true;
    group = "media";
    settings.auth.method = "Forms";
  };

  # ── Radarr — movie automation ─────────────────────────────────────
  services.radarr = {
    enable = true;
    group = "media";
    settings.auth.method = "Forms";
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

  # ── Inotify limits — needed for Jellyfin real-time library monitoring ──
  boot.kernel.sysctl = {
    "fs.inotify.max_user_watches" = 524288;
    "fs.inotify.max_user_instances" = 512;
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

  # ── Dashboard — internal link page (Tailscale only) ───────────────
  services.caddy.virtualHosts.":9000" = {
    extraConfig = ''
      bind 0.0.0.0
      header Content-Type "text/html; charset=utf-8"
      respond `<!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Gordula</title>
        <style>
          * { margin: 0; padding: 0; box-sizing: border-box; }
          body { font-family: -apple-system, system-ui, sans-serif; background: #0f0f0f; color: #e0e0e0; padding: 2rem; }
          h1 { font-size: 1.5rem; margin-bottom: 1.5rem; color: #fff; }
          .section { margin-bottom: 1.5rem; }
          .section h2 { font-size: 0.85rem; text-transform: uppercase; letter-spacing: 0.05em; color: #888; margin-bottom: 0.5rem; }
          .links { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 0.5rem; }
          a { display: block; padding: 0.75rem 1rem; background: #1a1a1a; border-radius: 6px; color: #60a5fa; text-decoration: none; font-size: 0.95rem; transition: background 0.15s; }
          a:hover { background: #252525; }
          a span { display: block; font-size: 0.75rem; color: #666; margin-top: 0.2rem; }
        </style>
      </head>
      <body>
        <h1>Gordula</h1>
        <div class="section">
          <h2>Public</h2>
          <div class="links">
            <a href="https://jellyfin.gordula.com">Jellyfin<span>Media server</span></a>
            <a href="https://requests.gordula.com">Seerr<span>Request media</span></a>
            <a href="https://mylist.gordula.com">My List<span>TV tracker</span></a>
          </div>
        </div>
        <div class="section">
          <h2>Media Management</h2>
          <div class="links">
            <a href="http://gordula:8080">SABnzbd<span>Download client</span></a>
            <a href="http://gordula:9696">Prowlarr<span>Indexer manager</span></a>
            <a href="http://gordula:8989">Sonarr<span>TV shows</span></a>
            <a href="http://gordula:7878">Radarr<span>Movies</span></a>
            <a href="http://gordula:8787">Readarr<span>Books</span></a>
            <a href="http://gordula:6767">Bazarr<span>Subtitles</span></a>
          </div>
        </div>
      </body>
      </html>` 200
    '';
  };
}
