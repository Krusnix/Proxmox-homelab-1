#!/bin/bash
# Homepage dashboard: run on homelab1-proxmox as root after the Homepage helper script.
#   bash setup-homelab1.sh [CTID]     (default: the CT named "homepage")
# Writes the dashboard config into the Homepage CT, creates a read-only Proxmox API token,
# and copies the keys it can find on this host (Plex, Tautulli, Tdarr, Pi-holes) into
# /etc/homepage/vars.env inside the CT (outside /opt/homepage, so helper-script updates
# keep it). Safe to run again: it rewrites the config files, replaces the Proxmox token,
# and keeps any keys you've added by hand.
set -euo pipefail

CT="${1:-$(pct list | awk 'NR>1 && $NF=="homepage"{print $1; exit}')}"
[ -n "$CT" ] || { echo "No CT named 'homepage' found. Run: bash $0 <CTID>"; exit 1; }
pct exec "$CT" -- test -d /opt/homepage/config || { echo "CT $CT has no /opt/homepage/config"; exit 1; }
echo "Homepage CT: $CT"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ---------- helper inside the CT: homepage-setvar ----------
cat > "$TMP/homepage-setvar" <<'EOF'
#!/bin/sh
# homepage-setvar NAME VALUE   sets HOMEPAGE_VAR_NAME in /etc/homepage/vars.env
# homepage-setvar --missing    lists the variables the config uses that aren't set yet
# homepage-setvar --restart    restarts Homepage so new values take effect
ENV=/etc/homepage/vars.env
mkdir -p /etc/homepage; [ -f "$ENV" ] || install -m 600 /dev/null "$ENV"
case "${1:-}" in
  --restart) systemctl restart homepage && echo "Homepage restarted"; exit ;;
  --missing)
    for v in $(grep -oh 'HOMEPAGE_VAR_[A-Z0-9_]*' /opt/homepage/config/*.yaml | sort -u); do
      grep -q "^$v='..*'" "$ENV" || echo "$v"
    done; exit ;;
  ""|-*) sed -n '2,4s/^# //p' "$0"; exit 1 ;;
esac
name="HOMEPAGE_VAR_${1#HOMEPAGE_VAR_}"; val="${2:-}"
[ -n "$val" ] || { echo "No value given for $name"; exit 1; }
case "$val" in *"'"*) echo "Values can't contain a single quote"; exit 1 ;; esac
tmp=$(mktemp)
grep -v "^$name=" "$ENV" > "$tmp" || true
printf "%s='%s'\n" "$name" "$val" >> "$tmp"
cat "$tmp" > "$ENV"; rm -f "$tmp"; chmod 600 "$ENV"
echo "set $name"
EOF

# ---------- settings.yaml ----------
cat > "$TMP/settings.yaml" <<'EOF'
title: Homelab
description: homelab1-proxmox and plex-proxmox
theme: dark
color: slate
headerStyle: clean
statusStyle: dot
hideVersion: true
useEqualHeights: true
target: _blank
layout:
  Network:
    style: row
    columns: 4
  Proxmox:
    style: row
    columns: 4
  Media (homelab1):
    style: row
    columns: 3
  plex-proxmox:
    style: row
    columns: 3
  unraid-1 Media:
    style: row
    columns: 4
  unraid-1 Arrs:
    style: row
    columns: 4
  unraid-1 Downloads:
    style: row
    columns: 4
  Storage:
    style: row
    columns: 3
  Monitoring:
    style: row
    columns: 3
EOF

# ---------- widgets.yaml (top bar) ----------
cat > "$TMP/widgets.yaml" <<'EOF'
- datetime:
    text_size: xl
    format:
      dateStyle: long
      timeStyle: short
      hour12: true
- search:
    provider: duckduckgo
    target: _blank
EOF

# ---------- bookmarks.yaml ----------
cat > "$TMP/bookmarks.yaml" <<'EOF'
- Admin:
    - Tailscale:
        - icon: tailscale.svg
          href: https://login.tailscale.com/admin/machines
    - ntfy alerts:
        - icon: ntfy.svg
          href: https://ntfy.sh/homelab1-alerts-3d1ef2b124a1
    - Runbook:
        - icon: si-github
          href: https://github.com/Krusnix/Proxmox-homelab-1/blob/main/RUNBOOK.md
    - Helper scripts:
        - icon: proxmox.svg
          href: https://community-scripts.github.io/ProxmoxVE/
EOF

# ---------- services.yaml ----------
cat > "$TMP/services.yaml" <<'EOF'
- Network:
    - OPNsense:
        icon: opnsense.svg
        href: https://opnsense.krusnix.net
        description: Router, firewall, DHCP
        ping: 192.168.4.1
        widget:
          type: opnsense
          url: https://192.168.4.1
          username: '{{HOMEPAGE_VAR_OPNSENSE_KEY}}'
          password: '{{HOMEPAGE_VAR_OPNSENSE_SECRET}}'
    - Pi-hole CT 102:
        icon: pi-hole.svg
        href: https://pihole.krusnix.net/admin/
        description: 192.168.4.145 (nebula-sync primary)
        siteMonitor: http://192.168.4.145/admin/
        widget:
          type: pihole
          url: http://192.168.4.145
          version: 6
          key: '{{HOMEPAGE_VAR_PIHOLE_145}}'
    - Pi-hole .48:
        icon: pi-hole.svg
        href: https://pihole-plex.krusnix.net/admin/
        description: 192.168.4.48 (plex-proxmox CT 102)
        siteMonitor: http://192.168.4.48/admin/
        widget:
          type: pihole
          url: http://192.168.4.48
          version: 6
          key: '{{HOMEPAGE_VAR_PIHOLE_48}}'
    - Pi-hole Unraid:
        icon: pi-hole.svg
        href: https://pihole-unraid.krusnix.net/admin/
        description: 192.168.5.53 (Unraid docker)
        siteMonitor: http://192.168.5.53/admin/
        widget:
          type: pihole
          url: http://192.168.5.53
          version: 6
          key: '{{HOMEPAGE_VAR_PIHOLE_5_53}}'
    - Pi-hole .141:
        icon: pi-hole.svg
        href: https://pihole-nut.krusnix.net/admin/
        description: 192.168.4.141 (also the NUT server)
        siteMonitor: http://192.168.4.141:8080/admin/
        widget:
          type: pihole
          url: http://192.168.4.141:8080
          version: 6
          key: '{{HOMEPAGE_VAR_PIHOLE_141}}'

- Proxmox:
    - homelab1-proxmox:
        icon: proxmox.svg
        href: https://pve.krusnix.net
        description: 192.168.4.209
        siteMonitor: https://192.168.4.209:8006
        widget:
          type: proxmox
          url: https://192.168.4.209:8006
          username: 'homepage@pve!dashboard'
          password: '{{HOMEPAGE_VAR_PVE_HOMELAB1}}'
    - plex-proxmox:
        icon: proxmox.svg
        href: https://pve-plex.krusnix.net
        description: '{{HOMEPAGE_VAR_PLEXPVE_IP}}'
        siteMonitor: 'https://{{HOMEPAGE_VAR_PLEXPVE_IP}}:8006'
        widget:
          type: proxmox
          url: 'https://{{HOMEPAGE_VAR_PLEXPVE_IP}}:8006'
          username: 'homepage@pve!dashboard'
          password: '{{HOMEPAGE_VAR_PVE_PLEXPVE}}'
    - UPS:
        icon: nut.svg
        href: https://ups.krusnix.net
        description: CyberPower via PVE-UPS (CT 101) and NUT on .141
        siteMonitor: http://192.168.4.205:8080/api/health
        widget:
          type: customapi
          url: http://192.168.4.205:8080/api/status
          refreshInterval: 30000
          mappings:
            - field: ups.0.power_source
              label: Power
            - field: ups.0.battery_charge_pct
              label: Battery
              format: percent
            - field: ups.0.load_pct
              label: Load
              format: percent
            - field: ups.0.runtime_remaining_min
              label: Runtime
              format: number
              suffix: min
    - Helper scripts:
        icon: proxmox.svg
        href: https://scripts.krusnix.net
        description: pve-scripts-local (CT 100)
        siteMonitor: http://192.168.4.102:3000

- Media (homelab1):
    - Plex:
        icon: plex.svg
        href: https://plex.krusnix.net/web
        description: CT 103, 192.168.4.120
        siteMonitor: http://192.168.4.120:32400/identity
        widget:
          type: plex
          url: http://192.168.4.120:32400
          key: '{{HOMEPAGE_VAR_PLEX_HOMELAB1}}'
    - Tautulli:
        icon: tautulli.svg
        href: https://tautulli.krusnix.net
        description: CT 106, watches homelab1 Plex
        siteMonitor: http://192.168.4.113:8181
        widget:
          type: tautulli
          url: http://192.168.4.113:8181
          key: '{{HOMEPAGE_VAR_TAUTULLI_HOMELAB1}}'
          enableUser: true
          showEpisodeNumber: true
    - Tdarr:
        icon: tdarr.svg
        href: https://tdarr.krusnix.net
        description: CT 104, transcode queue
        siteMonitor: http://192.168.4.127:8265
        widget:
          type: tdarr
          url: http://192.168.4.127:8265
          key: '{{HOMEPAGE_VAR_TDARR}}'
    - Immich:
        icon: immich.svg
        href: https://immich.krusnix.net
        description: CT 105, photos
        siteMonitor: http://192.168.4.163:2283/api/server/ping
        widget:
          type: immich
          url: http://192.168.4.163:2283
          key: '{{HOMEPAGE_VAR_IMMICH}}'
          version: 2
    - Tunarr:
        icon: tunarr.svg
        href: https://tunarr.krusnix.net
        description: CT 107, live TV channels
        siteMonitor: http://192.168.4.235:8000
    - Kometa:
        icon: kometa.png
        href: https://kometa.krusnix.net
        description: CT 108, collections and overlays (runs 05:00)
        siteMonitor: http://192.168.4.213:7171

- plex-proxmox:
    - Plex:
        icon: plex.svg
        href: https://plex-server.krusnix.net/web
        description: plex-proxmox, 192.168.4.49
        siteMonitor: http://192.168.4.49:32400/identity
        widget:
          type: plex
          url: http://192.168.4.49:32400
          key: '{{HOMEPAGE_VAR_PLEX_PLEXPVE}}'
    - Tautulli:
        icon: tautulli.svg
        href: https://tautulli-plex.krusnix.net
        description: plex-proxmox CT 105, watches plex-server
        siteMonitor: 'http://{{HOMEPAGE_VAR_TAUTULLI2_IP}}:8181'
        widget:
          type: tautulli
          url: 'http://{{HOMEPAGE_VAR_TAUTULLI2_IP}}:8181'
          key: '{{HOMEPAGE_VAR_TAUTULLI_PLEXPVE}}'
          enableUser: true
          showEpisodeNumber: true
    - Kometa:
        icon: kometa.png
        href: https://kometa-plex.krusnix.net
        description: plex-proxmox CT 104
        siteMonitor: http://192.168.4.109:7171
    - PVE-UPS:
        icon: nut.svg
        href: https://ups-plex.krusnix.net
        description: plex-proxmox CT 101 (shuts this host down on low battery)
        siteMonitor: http://192.168.4.212:8080/api/health
    - Helper scripts:
        icon: proxmox.svg
        href: https://scripts-plex.krusnix.net
        description: plex-proxmox CT 100
        siteMonitor: http://192.168.4.179:3000

- unraid-1 Media:
    - Plex:
        icon: plex.svg
        href: https://plex-unraid.krusnix.net/web
        description: unraid-1 Plex
        server: unraid-1
        container: Plex-Media-Server
    - Jellyfin:
        icon: jellyfin.svg
        href: https://jellyfin.krusnix.net
        server: unraid-1
        container: Jellyfin
    - Tautulli:
        icon: tautulli.svg
        href: https://tautulli-unraid.krusnix.net
        description: watches unraid-1 Plex
        server: unraid-1
        container: tautulli
    - Seerr:
        icon: seerr.svg
        href: https://seerr.krusnix.net
        description: requests
        server: unraid-1
        container: Seerr
    - Audiobookshelf:
        icon: audiobookshelf.svg
        href: https://audiobookshelf.krusnix.net
        server: unraid-1
        container: audiobookshelf
    - Tunarr:
        icon: tunarr.svg
        href: https://tunarr-unraid.krusnix.net
        server: unraid-1
        container: Tunarr
    - Youtarr:
        icon: youtarr.png
        href: https://youtarr.krusnix.net
        server: unraid-1
        container: Youtarr
    - Kometa:
        icon: kometa.png
        description: runs on a schedule, no web UI
        server: unraid-1
        container: kometa
    - Pi-hole:
        icon: pi-hole.svg
        description: 192.168.5.53, see the Network group
        server: unraid-1
        container: pihole-v6-unbound

- unraid-1 Arrs:
    - Sonarr:
        icon: sonarr.svg
        href: https://sonarr.krusnix.net
        server: unraid-1
        container: sonarr
    - Radarr:
        icon: radarr.svg
        href: https://radarr.krusnix.net
        server: unraid-1
        container: radarr
    - Lidarr:
        icon: lidarr.svg
        href: https://lidarr.krusnix.net
        server: unraid-1
        container: lidarr
    - Whisparr:
        icon: whisparr.svg
        href: https://whisparr.krusnix.net
        server: unraid-1
        container: whisparr
    - Bazarr:
        icon: bazarr.svg
        href: https://bazarr.krusnix.net
        description: subtitles
        server: unraid-1
        container: bazarr
    - Mylar3:
        icon: mylar.png
        href: https://mylar.krusnix.net
        description: comics
        server: unraid-1
        container: mylar3
    - LazyLibrarian:
        icon: lazylibrarian.png
        href: https://lazylibrarian.krusnix.net
        description: books
        server: unraid-1
        container: lazylibrarian
    - Prowlarr:
        icon: prowlarr.svg
        href: https://prowlarr.krusnix.net
        description: indexers
        server: unraid-1
        container: prowlarr
    - Recyclarr:
        icon: recyclarr.svg
        description: syncs quality profiles, no web UI
        server: unraid-1
        container: recyclarr

- unraid-1 Downloads:
    - Gluetun:
        icon: gluetun.svg
        description: VPN for qBittorrent and SABnzbd
        server: unraid-1
        container: binhex-official-gluetun
    - qBittorrent:
        icon: qbittorrent.svg
        href: https://qbittorrent.krusnix.net
        description: through Gluetun
        server: unraid-1
        container: binhex-qbittorrent
    - SABnzbd:
        icon: sabnzbd.svg
        href: https://sabnzbd.krusnix.net
        description: through Gluetun
        server: unraid-1
        container: sabnzbd
    - Cleanuparr:
        icon: cleanuparr.png
        href: https://cleanuparr.krusnix.net
        server: unraid-1
        container: Cleanuparr
    - cross-seed:
        icon: cross-seed.png
        server: unraid-1
        container: cross-seed
    - FlareSolverr:
        icon: flaresolverr.svg
        server: unraid-1
        container: flaresolverr
    - MariaDB:
        icon: mariadb.svg
        server: unraid-1
        container: MariaDB-Official

- Storage:
    - Unraid:
        icon: unraid.svg
        href: https://unraid.krusnix.net
        description: unraid-1, 192.168.5.14 (media share)
        ping: 192.168.5.14
        widget:
          type: unraid
          url: '{{HOMEPAGE_VAR_UNRAID_URL}}'
          key: '{{HOMEPAGE_VAR_UNRAID_KEY}}'
          fields: ["status", "cpu", "memoryPercent", "arrayUsedPercent"]
    - TerraMaster:
        icon: terramaster.svg
        href: https://nas.krusnix.net
        description: F4-210, 192.168.4.180 (backups, nas-public)
        ping: 192.168.4.180

- Monitoring:
    - Beszel:
        icon: beszel.svg
        href: https://beszel.krusnix.net
        description: CT 109, CPU, memory, disk
        siteMonitor: http://192.168.4.217:8090
        widget:
          type: beszel
          url: http://192.168.4.217:8090
          username: '{{HOMEPAGE_VAR_BESZEL_USER}}'
          password: '{{HOMEPAGE_VAR_BESZEL_PASS}}'
          version: 2
    - Uptime Kuma:
        icon: uptime-kuma.svg
        href: https://uptime.krusnix.net
        description: CT 110, up/down checks
        siteMonitor: http://192.168.4.134:3001
        widget:
          type: uptimekuma
          url: http://192.168.4.134:3001
          slug: homelab
    - Grafana:
        icon: grafana.svg
        href: https://grafana.krusnix.net
        description: CT 112, graphs and 30 days of history
        siteMonitor: http://192.168.4.232:3000
        widget:
          type: prometheus
          url: http://192.168.4.232:9090
    - Nginx Proxy Manager:
        icon: nginx-proxy-manager.svg
        href: https://proxy.krusnix.net
        description: CT 113, https://<name>.krusnix.net for every UI
        siteMonitor: http://192.168.4.156:81
    - Authentik:
        icon: authentik.svg
        href: https://auth.krusnix.net
        description: CT 114, single sign-on
        siteMonitor: http://192.168.4.229:9000/-/health/live/
        widget:
          type: authentik
          version: 2
          url: http://192.168.4.229:9000
          key: '{{HOMEPAGE_VAR_AUTHENTIK_KEY}}'
    - ntfy:
        icon: ntfy.svg
        href: https://ntfy.sh/homelab1-alerts-3d1ef2b124a1
        description: Latest alert on the phone topic
        widget:
          type: ntfy
          url: https://ntfy.sh
          topic: homelab1-alerts-3d1ef2b124a1
EOF

# Empty files the skeleton ships with, so Homepage doesn't show example content.
# Docker on unraid-1, read through the read-only socket-proxy container on port 2375.
cat > "$TMP/docker.yaml" <<'EOF'
unraid-1:
  host: 192.168.5.14
  port: 2375
EOF
: > "$TMP/kubernetes.yaml"; : > "$TMP/proxmox.yaml"

for f in settings widgets bookmarks services docker kubernetes proxmox; do
  pct exec "$CT" -- sh -c "[ -f /opt/homepage/config/$f.yaml ] && cp -n /opt/homepage/config/$f.yaml /opt/homepage/config/$f.yaml.orig || true"
  pct push "$CT" "$TMP/$f.yaml" "/opt/homepage/config/$f.yaml"
done
pct push "$CT" "$TMP/homepage-setvar" /usr/local/bin/homepage-setvar --perms 755
# Keys live in /etc/homepage/vars.env, loaded by a systemd drop-in (single-quoted values are taken literally).
pct exec "$CT" -- sh -c 'mkdir -p /etc/homepage /etc/systemd/system/homepage.service.d
  [ -f /etc/homepage/vars.env ] || install -m 600 /dev/null /etc/homepage/vars.env
  printf "[Service]\nEnvironmentFile=-/etc/homepage/vars.env\n" > /etc/systemd/system/homepage.service.d/vars.conf
  systemctl daemon-reload'
echo "Config written to CT $CT:/opt/homepage/config (originals kept as *.orig)"

# ping needs iputils-ping inside the CT
pct exec "$CT" -- sh -c 'command -v ping >/dev/null || { apt-get -qq update && apt-get -qq install -y iputils-ping >/dev/null; }'

# ---------- keys ----------
setvar() {  # setvar NAME VALUE
  if [ -n "${2:-}" ]; then
    pct exec "$CT" -- /usr/local/bin/homepage-setvar "$1" "$2" >/dev/null && echo "  $1: set"
  else
    echo "  $1: not found"
  fi
}
echo "Keys:"

# Read-only Proxmox API token (PVEAuditor). Re-running replaces it.
pveum user add homepage@pve --comment "Homepage dashboard, read-only" 2>/dev/null || true
pveum acl modify / --users homepage@pve --roles PVEAuditor
pveum user token remove homepage@pve dashboard 2>/dev/null || true
PVE_SECRET=$(pveum user token add homepage@pve dashboard --privsep 0 --comment "Homepage" --output-format json \
  | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')
setvar PVE_HOMELAB1 "$PVE_SECRET"

PREFS="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml"
PLEX_TOKEN=$(pct exec 103 -- sed -n 's/.*PlexOnlineToken="\([^"]*\)".*/\1/p' "$PREFS" 2>/dev/null || true)
setvar PLEX_HOMELAB1 "$PLEX_TOKEN"

TAUTULLI_KEY=$(pct exec 106 -- sed -n 's/^api_key *= *//p' /opt/Tautulli/config.ini 2>/dev/null | head -1 || true)
setvar TAUTULLI_HOMELAB1 "$TAUTULLI_KEY"

TDARR_KEY=$( (. /root/.ntfy-checks.env 2>/dev/null; echo "${TDARR_KEY:-}") )
setvar TDARR "$TDARR_KEY"

# Pi-hole passwords from nebula-sync's env file in CT 102 (PRIMARY / REPLICAS = "url|password,...")
NS_LIST=$(pct exec 102 -- cat /etc/nebula-sync.env 2>/dev/null | grep -E '^(PRIMARY|REPLICAS)=' \
  | cut -d= -f2- | tr -d "\"'" | tr ',' '\n' || true)
pw_for() {
  printf '%s\n' "$NS_LIST" | awk -F'|' -v ip="$1" '{h=$1; sub(/^[a-z]+:\/\//,"",h); sub(/[:\/].*$/,"",h);
    if (h==ip) {sub(/^[^|]*\|/,""); print; exit}}'
}
echo "  (nebula-sync Pi-hole URLs: $(printf '%s\n' "$NS_LIST" | cut -d'|' -f1 | tr '\n' ' '))"
setvar PIHOLE_145 "$(pw_for 192.168.4.145)"
setvar PIHOLE_48 "$(pw_for 192.168.4.48)"
setvar PIHOLE_5_53 "$(pw_for 192.168.5.53)"
setvar PIHOLE_141 "$(pw_for 192.168.4.141)"

setvar UNRAID_URL "http://192.168.5.14"

pct exec "$CT" -- /usr/local/bin/homepage-setvar --restart
IP=$(pct exec "$CT" -- hostname -I | awk '{print $1}')
MAC=$(pct config "$CT" | sed -n 's/^net0:.*hwaddr=\([^,]*\).*/\1/p')
echo
echo "Dashboard: http://$IP:3000   (CT $CT, MAC $MAC: reserve this in OPNsense)"
echo "Still to add (run inside the CT: pct enter $CT):"
pct exec "$CT" -- /usr/local/bin/homepage-setvar --missing | sed 's/^/  /'
