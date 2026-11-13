#!/bin/bash
# Reverse proxy names for every homelab web UI. Run on homelab1-proxmox as root.
#   DOMAIN=example.com NPM_IP=192.168.4.x NPM_USER=you@mail NPM_PASS='...' bash setup-proxy.sh
#   DOMAIN=example.com NPM_IP=192.168.4.x bash setup-proxy.sh --check   (test every name)
# What it does (safe to re-run; it only adds what's missing):
#   1. Pi-hole CT 102 (192.168.4.145): a local DNS record <name>.DOMAIN -> NPM_IP for each
#      service below. nebula-sync copies them to the other three Pi-holes within the hour.
#   2. Nginx Proxy Manager: one proxy host per name, using the *.DOMAIN certificate you
#      made in the NPM UI first (SSL forced, HTTP/2, websockets on).
#   3. Homepage CT 111: allows home.DOMAIN as a hostname.
set -euo pipefail
: "${DOMAIN:?set DOMAIN}" "${NPM_IP:?set NPM_IP}"
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1

# name  scheme  host  port  [immich|pihole]
HOSTS=$(cat <<HOSTS_EOF
proxy          http  $NPM_IP       81
pve            https 192.168.4.209 8006
plex           http  192.168.4.120 32400
tautulli       http  192.168.4.113 8181
tdarr          http  192.168.4.127 8265
immich         http  192.168.4.163 2283 immich
tunarr         http  192.168.4.235 8000
kometa         http  192.168.4.213 7171
scripts        http  192.168.4.102 3000
ups            http  192.168.4.205 8080
beszel         http  192.168.4.217 8090
uptime         http  192.168.4.134 3001
home           http  192.168.4.126 3000
grafana        http  192.168.4.232 3000
prometheus     http  192.168.4.232 9090
pihole         http  192.168.4.145 80 pihole
pve-plex       https 192.168.4.215 8006
plex-server    http  192.168.4.49  32400
tautulli-plex  http  192.168.4.198 8181
kometa-plex    http  192.168.4.109 7171
ups-plex       http  192.168.4.212 8080
scripts-plex   http  192.168.4.179 3000
pihole-plex    http  192.168.4.48  80 pihole
pihole-nut     http  192.168.4.141 8080 pihole
opnsense       https 192.168.4.1   443
nas            http  192.168.4.180 8181
unraid         http  192.168.5.14  80
pihole-unraid  http  192.168.5.53  80 pihole
plex-unraid    http  192.168.5.14  32400
jellyfin       http  192.168.5.14  8096
tautulli-unraid http 192.168.5.14  8181
seerr          http  192.168.5.14  5055
audiobookshelf http  192.168.5.14  13378
tunarr-unraid  http  192.168.5.14  8001
youtarr        http  192.168.5.14  3011
sonarr         http  192.168.5.14  8989
radarr         http  192.168.5.14  7878
lidarr         http  192.168.5.14  8686
whisparr       http  192.168.5.14  6969
bazarr         http  192.168.5.14  6767
mylar          http  192.168.5.14  8090
lazylibrarian  http  192.168.5.14  5299
prowlarr       http  192.168.5.14  9696
qbittorrent    http  192.168.5.14  8080
sabnzbd        http  192.168.5.14  8085
cleanuparr     http  192.168.5.14  11011
HOSTS_EOF
)
command -v jq >/dev/null || apt-get install -y jq >/dev/null

if [ $CHECK = 1 ]; then
  bad=0
  while read -r n _ _ _ extra; do
    [ -z "$n" ] && continue
    d="$n.$DOMAIN"; path=/; [ "${extra:-}" = pihole ] && path=/admin/
    code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' --resolve "$d:443:$NPM_IP" "https://$d$path" || echo ERR)
    case $code in 2??|3??|401) printf '  ok   %-30s %s\n' "$d" "$code" ;;
      *) printf '  FAIL %-30s %s\n' "$d" "$code"; bad=$((bad+1)) ;; esac
  done <<<"$HOSTS"
  echo "$bad failing. (ERR/000 = TLS or connection problem; 502 = NPM can't reach the app; 400/403 = app rejects the hostname, see SETUP.md)"
  exit 0
fi
: "${NPM_USER:?set NPM_USER}" "${NPM_PASS:?set NPM_PASS}"

### 1. Pi-hole local DNS records (CT 102, via its API)
PRIMARY=$(pct exec 102 -- cat /etc/nebula-sync.env | grep -E '^PRIMARY=' | cut -d= -f2- | tr -d "\"'")
PH_URL=${PRIMARY%%|*}; PH_PW=${PRIMARY#*|}
SID=$(curl -fsS -m 10 -X POST "$PH_URL/api/auth" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg p "$PH_PW" '{password:$p}')" | jq -r '.session.sid')
[ -n "$SID" ] && [ "$SID" != null ] || { echo "Pi-hole login failed at $PH_URL"; exit 1; }
ph() { curl -fsS -m 10 -H "sid: $SID" "$@"; }
current=$(ph "$PH_URL/api/config/dns/hosts" | jq -r '.config.dns.hosts[]')
added=0
while read -r n _; do
  [ -z "$n" ] && continue
  want="$NPM_IP $n.$DOMAIN"
  # drop an old record for this name that points somewhere else
  while read -r old; do
    [ -n "$old" ] && [ "$old" != "$want" ] && ph -X DELETE "$PH_URL/api/config/dns/hosts/$(jq -rn --arg s "$old" '$s|@uri')" >/dev/null && echo "  removed '$old'"
  done < <(grep -E "[[:space:]]$n\.$DOMAIN\$" <<<"$current" || true)
  grep -qxF "$want" <<<"$current" && continue
  ph -X PUT "$PH_URL/api/config/dns/hosts/$(jq -rn --arg s "$want" '$s|@uri')" >/dev/null
  added=$((added+1))
done <<<"$HOSTS"
ph -X DELETE "$PH_URL/api/auth" >/dev/null || true
echo "Pi-hole: $added DNS records added"

### 2. Nginx Proxy Manager proxy hosts
NPM="http://$NPM_IP:81/api"
TOKEN=$(curl -fsS -m 10 -X POST "$NPM/tokens" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg i "$NPM_USER" --arg s "$NPM_PASS" '{identity:$i,secret:$s}')" | jq -r .token)
[ -n "$TOKEN" ] && [ "$TOKEN" != null ] || { echo "NPM login failed"; exit 1; }
npm() { curl -fsS -m 30 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' "$@"; }
CERT=$(npm "$NPM/nginx/certificates" | jq -r --arg w "*.$DOMAIN" '[.[]|select(.domain_names|index($w))][0].id // empty')
[ -n "$CERT" ] || { echo "No certificate for *.$DOMAIN in NPM yet. Make it first (SETUP.md step 3)."; exit 1; }
hostlist=$(npm "$NPM/nginx/proxy-hosts")
existing=$(jq -r '.[].domain_names[]' <<<"$hostlist")
IMMICH_CONF=$'client_max_body_size 50000M;\nproxy_read_timeout 600s;\nproxy_send_timeout 600s;\nsend_timeout 600s;'
# Pi-hole v6 answers 404 on / for a hostname it doesn't know; send / to /admin/
PIHOLE_CONF='location = / { return 301 /admin/; }'
adv_for() { case "${1:-}" in immich) printf '%s' "$IMMICH_CONF" ;; pihole) printf '%s' "$PIHOLE_CONF" ;; esac; }
made=0
while read -r n scheme host port extra; do
  [ -z "$n" ] && continue
  d="$n.$DOMAIN"
  adv=$(adv_for "${extra:-}")
  if grep -qxF "$d" <<<"$existing"; then
    # existing host: only bring its advanced config up to date
    read -r id cur < <(jq -r --arg d "$d" '.[]|select(.domain_names|index($d))|"\(.id) \(.advanced_config|@base64)"' <<<"$hostlist" | head -1)
    if [ "$(base64 -d <<<"$cur")" != "$adv" ]; then
      npm -X PUT "$NPM/nginx/proxy-hosts/$id" -d "$(jq -n --arg a "$adv" '{advanced_config:$a}')" >/dev/null
      echo "  NPM: $d advanced config updated"
    fi
    continue
  fi
  npm -X POST "$NPM/nginx/proxy-hosts" -d "$(jq -n --arg d "$d" --arg s "$scheme" --arg h "$host" \
    --argjson p "$port" --argjson c "$CERT" --arg a "$adv" '{domain_names:[$d], forward_scheme:$s,
    forward_host:$h, forward_port:$p, certificate_id:$c, ssl_forced:true, http2_support:true,
    allow_websocket_upgrade:true, block_exploits:false, caching_enabled:false, hsts_enabled:false,
    hsts_subdomains:false, access_list_id:0, advanced_config:$a, locations:[],
    meta:{letsencrypt_agree:false, dns_challenge:false}}')" >/dev/null
  echo "  NPM: $d -> $scheme://$host:$port"; made=$((made+1))
done <<<"$HOSTS"
echo "NPM: $made proxy hosts added"

### 3. Homepage: allow the new hostname (systemd env wins over the helper's .env)
if pct status 111 >/dev/null 2>&1; then
  want="HOMEPAGE_ALLOWED_HOSTS=192.168.4.126:3000,localhost:3000,127.0.0.1:3000,home.$DOMAIN"
  if ! pct exec 111 -- grep -qxF "$want" /etc/homepage/vars.env; then
    pct exec 111 -- bash -c "f=/etc/homepage/vars.env; sed -i '/^HOMEPAGE_ALLOWED_HOSTS=/d' \$f;
      echo '$want' >> \$f; systemctl restart homepage"
    echo "Homepage: home.$DOMAIN allowed (restarted; give it ~30 s before --check)"
  fi
fi
echo "Done. Now run:  DOMAIN=$DOMAIN NPM_IP=$NPM_IP bash $0 --check"
