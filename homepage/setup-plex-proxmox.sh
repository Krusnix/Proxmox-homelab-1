#!/bin/bash
# Homepage dashboard: run on plex-proxmox as root. Changes nothing except adding a
# read-only Proxmox API token (homepage@pve!dashboard, PVEAuditor; re-running replaces it).
# Prints "homepage-setvar" lines to paste into the Homepage CT on homelab1-proxmox.
set -euo pipefail

pveum user add homepage@pve --comment "Homepage dashboard, read-only" 2>/dev/null || true
pveum acl modify / --users homepage@pve --roles PVEAuditor
pveum user token remove homepage@pve dashboard 2>/dev/null || true
PVE_SECRET=$(pveum user token add homepage@pve dashboard --privsep 0 --comment "Homepage" --output-format json \
  | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')
HOST_IP=$(ip -4 -o addr show vmbr0 | awk '{sub(/\/.*/,"",$4); print $4; exit}')

PREFS="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml"
PLEX_TOKEN=""; TAUTULLI_KEY=""; TAUTULLI_IP=""
echo "Running CTs:"
for id in $(pct list | awk 'NR>1 && $2=="running"{print $1}'); do
  name=$(pct config "$id" | sed -n 's/^hostname: //p')
  ip=$(pct exec "$id" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
  echo "  CT $id  $name  $ip"
  if [ -z "$PLEX_TOKEN" ] && pct exec "$id" -- test -f "$PREFS" 2>/dev/null; then
    PLEX_TOKEN=$(pct exec "$id" -- sed -n 's/.*PlexOnlineToken="\([^"]*\)".*/\1/p' "$PREFS")
  fi
  if [ -z "$TAUTULLI_KEY" ] && pct exec "$id" -- test -f /opt/Tautulli/config.ini 2>/dev/null; then
    TAUTULLI_KEY=$(pct exec "$id" -- sed -n 's/^api_key *= *//p' /opt/Tautulli/config.ini | head -1)
    TAUTULLI_IP=$ip
  fi
done

echo
echo "Node name: $(hostname)   IP: $HOST_IP"
[ -n "$PLEX_TOKEN" ] || echo "Plex token: not found"
[ -n "$TAUTULLI_KEY" ] || echo "Tautulli key: not found"
echo
echo "Paste these into the Homepage CT on homelab1-proxmox (pct enter <homepage CT>):"
echo "------------------------------------------------------------"
echo "homepage-setvar PLEXPVE_IP '$HOST_IP'"
echo "homepage-setvar PVE_PLEXPVE '$PVE_SECRET'"
[ -n "$PLEX_TOKEN" ] && echo "homepage-setvar PLEX_PLEXPVE '$PLEX_TOKEN'"
[ -n "$TAUTULLI_IP" ] && echo "homepage-setvar TAUTULLI2_IP '$TAUTULLI_IP'"
[ -n "$TAUTULLI_KEY" ] && echo "homepage-setvar TAUTULLI_PLEXPVE '$TAUTULLI_KEY'"
echo "homepage-setvar --restart"
echo "------------------------------------------------------------"
