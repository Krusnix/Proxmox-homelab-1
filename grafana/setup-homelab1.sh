#!/bin/bash
# Grafana + Prometheus: run on homelab1-proxmox as root after the Grafana helper script.
#   bash setup-homelab1.sh [CTID]     (default: the CT named "grafana")
# On this host: installs node exporter (:9100) and the NVIDIA GPU exporter (:9835), and
# creates a read-only Proxmox API token prometheus@pve!metrics (PVEAuditor).
# In the Grafana CT: installs Prometheus (30 days of history), the Proxmox, UPS (NUT) and
# Pi-hole exporters, points Grafana at Prometheus and loads the dashboards.
# Safe to run again: it replaces the token, rewrites the configs and keeps the
# plex-proxmox token if it was already added.
set -euo pipefail

CT="${1:-$(pct list | awk 'NR>1 && $NF=="grafana"{print $1; exit}')}"
[ -n "$CT" ] || { echo "No CT named 'grafana' found. Run: bash $0 <CTID>"; exit 1; }
pct exec "$CT" -- test -d /etc/grafana || { echo "CT $CT has no /etc/grafana"; exit 1; }
HOST_IP=$(ip -4 -o addr show vmbr0 | awk '{sub(/\/.*/,"",$4); print $4; exit}')
echo "Grafana CT: $CT   host: $HOST_IP"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Downloads the linux amd64 asset of a project's latest GitHub release and installs the
# binary called $1 to /usr/local/bin. Same function is used inside the CT.
cat > "$TMP/ghbin.sh" <<'EOF'
ghbin() { # name repo
  local name=$1 repo=$2 url d; d=$(mktemp -d)
  url=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" \
    | grep -oE '"browser_download_url": *"[^"]+"' | cut -d'"' -f4 \
    | grep -E 'linux[-_.](amd64|x86_64)(\.tar\.gz)?$' | head -1)
  [ -n "$url" ] || { echo "  !! no linux amd64 download found for $repo"; return 1; }
  curl -fsSL -o "$d/dl" "$url" || { echo "  !! download failed: $url"; return 1; }
  if tar -xzf "$d/dl" -C "$d" 2>/dev/null; then
    install -m 755 "$(find "$d" -type f -name "$name*" ! -name dl | head -1)" "/usr/local/bin/$name"
  else
    install -m 755 "$d/dl" "/usr/local/bin/$name"
  fi
  rm -rf "$d"; echo "  $name installed from ${url##*/}"
}
EOF
. "$TMP/ghbin.sh"

# ---------- this host: node exporter + NVIDIA exporter ----------
echo "Host exporters:"
apt-get update -qq || true
DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y -qq --no-install-recommends prometheus-node-exporter >/dev/null
systemctl enable -q --now prometheus-node-exporter && echo "  node exporter on :9100"
if command -v nvidia-smi >/dev/null && ghbin nvidia_gpu_exporter utkuozdemir/nvidia_gpu_exporter; then
  cat > /etc/systemd/system/nvidia_gpu_exporter.service <<'EOF'
[Unit]
Description=NVIDIA GPU exporter for Prometheus
After=network-online.target
[Service]
ExecStart=/usr/local/bin/nvidia_gpu_exporter --web.listen-address=:9835
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable -q nvidia_gpu_exporter; systemctl restart nvidia_gpu_exporter
  echo "  NVIDIA exporter on :9835"
fi

# ---------- read-only Proxmox token ----------
pveum user add prometheus@pve --comment "Prometheus metrics, read-only" 2>/dev/null || true
pveum acl modify / --users prometheus@pve --roles PVEAuditor
pveum user token remove prometheus@pve metrics 2>/dev/null || true
PVE_SECRET=$(pveum user token add prometheus@pve metrics --privsep 0 --comment "Grafana CT" --output-format json \
  | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')
[ -n "$PVE_SECRET" ] || { echo "Could not create the Proxmox token"; exit 1; }

# ---------- Pi-hole passwords from nebula-sync (CT 102) ----------
NS_LIST=$(pct exec 102 -- cat /etc/nebula-sync.env 2>/dev/null | grep -E '^(PRIMARY|REPLICAS)=' \
  | cut -d= -f2- | tr -d "\"'" | tr ',' '\n' || true)
pw_for() {
  printf '%s\n' "$NS_LIST" | awk -F'|' -v ip="$1" '{h=$1; sub(/^[a-z]+:\/\//,"",h); sub(/[:\/].*$/,"",h);
    if (h==ip) {sub(/^[^|]*\|/,""); print; exit}}'
}
# host:port per Pi-hole (.141 serves its API on 8080)
PH_HOSTS="192.168.4.145,192.168.4.48,192.168.5.53,192.168.4.141"
PH_PORTS="80,80,80,8080"
PH_PW="$(pw_for 192.168.4.145),$(pw_for 192.168.4.48),$(pw_for 192.168.5.53),$(pw_for 192.168.4.141)"

umask 077
cat > "$TMP/secrets.env" <<EOF
HOST_IP='$HOST_IP'
PVE_HOMELAB1='$PVE_SECRET'
PH_HOSTS='$PH_HOSTS'
PH_PORTS='$PH_PORTS'
PH_PW='$PH_PW'
EOF

# ---------- inside the CT ----------
cat > "$TMP/in-ct.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
. /root/.gstack/ghbin.sh; . /root/.gstack/secrets.env
umask 022   # pct exec inherits the caller's umask
export DEBIAN_FRONTEND=noninteractive
echo "In the CT:"
apt-get update -qq
apt-get -o DPkg::Lock::Timeout=600 install -y -qq --no-install-recommends prometheus python3-venv curl >/dev/null
echo "  Prometheus $(prometheus --version 2>&1 | awk 'NR==1{print $3}')"

# Proxmox exporter (one copy here reads both hosts)
[ -x /opt/pve-exporter/bin/pve_exporter ] || python3 -m venv /opt/pve-exporter
/opt/pve-exporter/bin/pip install -q --upgrade prometheus-pve-exporter
TOK=/etc/prometheus/pve-tokens.env
[ -f "$TOK" ] || install -m 600 /dev/null "$TOK"
PLEX=$(sed -n "s/^PLEX='\(.*\)'$/\1/p" "$TOK")
printf "HOMELAB1='%s'\nPLEX='%s'\n" "$PVE_HOMELAB1" "$PLEX" > "$TOK"
cat > /usr/local/bin/pve-exporter-conf <<'EOS'
#!/bin/sh
# pve-exporter-conf                 rebuilds /etc/prometheus/pve.yml from pve-tokens.env
# pve-exporter-conf plex 'TOKEN'    stores the plex-proxmox token first
TOK=/etc/prometheus/pve-tokens.env
if [ "${1:-}" = plex ] && [ -n "${2:-}" ]; then
  sed -i "/^PLEX=/d" "$TOK"; printf "PLEX='%s'\n" "$2" >> "$TOK"
fi
. "$TOK"
mod() { printf '%s:\n  user: prometheus@pve\n  token_name: metrics\n  token_value: %s\n  verify_ssl: false\n' "$1" "$2"; }
{ mod default "$HOMELAB1"; mod homelab1 "$HOMELAB1"; [ -n "$PLEX" ] && mod plexproxmox "$PLEX"; } > /etc/prometheus/pve.yml
chown root:prometheus /etc/prometheus/pve.yml; chmod 640 /etc/prometheus/pve.yml
systemctl restart pve-exporter && echo "pve-exporter restarted"
EOS
chmod 755 /usr/local/bin/pve-exporter-conf
cat > /etc/systemd/system/pve-exporter.service <<'EOS'
[Unit]
Description=Proxmox VE exporter for Prometheus
After=network-online.target
[Service]
User=prometheus
ExecStart=/opt/pve-exporter/bin/pve_exporter --config.file /etc/prometheus/pve.yml --web.listen-address 127.0.0.1:9221
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOS

# UPS (NUT server at 192.168.4.141, ups "cyberpower") and Pi-hole exporters
ghbin nut_exporter DRuggeri/nut_exporter || true
cat > /etc/systemd/system/nut-exporter.service <<'EOS'
[Unit]
Description=NUT (UPS) exporter for Prometheus
After=network-online.target
[Service]
DynamicUser=yes
ExecStart=/usr/local/bin/nut_exporter --nut.server=192.168.4.141 --nut.vars_enable= --web.listen-address=127.0.0.1:9199
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOS
ghbin pihole_exporter eko/pihole-exporter || true
umask 077
cat > /etc/pihole-exporter.env <<EOS
PIHOLE_PROTOCOL=http,http,http,http
PIHOLE_HOSTNAME=$PH_HOSTS
PIHOLE_PORT=$PH_PORTS
PIHOLE_PASSWORD=$PH_PW
PORT=9617
EOS
umask 022
cat > /etc/systemd/system/pihole-exporter.service <<'EOS'
[Unit]
Description=Pi-hole exporter for Prometheus
After=network-online.target
[Service]
DynamicUser=yes
EnvironmentFile=/etc/pihole-exporter.env
ExecStart=/usr/local/bin/pihole_exporter
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOS

# Prometheus config
cat > /etc/prometheus/prometheus.yml <<EOS
global:
  scrape_interval: 30s
  evaluation_interval: 30s
scrape_configs:
  - job_name: prometheus
    static_configs: [{targets: ['127.0.0.1:9090']}]
  - job_name: node
    static_configs:
      - {targets: ['$HOST_IP:9100'], labels: {instance: homelab1-proxmox}}
      - {targets: ['192.168.4.215:9100'], labels: {instance: plex-proxmox}}
      - {targets: ['192.168.4.1:9100'], labels: {instance: opnsense}}
  - job_name: pve
    metrics_path: /pve
    static_configs:
      - {targets: ['$HOST_IP'], labels: {__param_module: homelab1}}
      - {targets: ['192.168.4.215'], labels: {__param_module: plexproxmox}}
    relabel_configs:
      - {source_labels: [__address__], target_label: __param_target}
      - {source_labels: [__param_target], target_label: instance}
      - {target_label: __address__, replacement: '127.0.0.1:9221'}
  - job_name: nvidia
    static_configs:
      - {targets: ['$HOST_IP:9835'], labels: {instance: homelab1-proxmox}}
  - job_name: ups
    metrics_path: /ups_metrics
    params: {ups: [cyberpower]}
    static_configs:
      - {targets: ['127.0.0.1:9199'], labels: {instance: cyberpower}}
  - job_name: pihole
    static_configs: [{targets: ['127.0.0.1:9617']}]
EOS
promtool check config /etc/prometheus/prometheus.yml >/dev/null && echo "  Prometheus config OK"
if grep -q '^ARGS=' /etc/default/prometheus 2>/dev/null; then
  sed -i 's|^ARGS=.*|ARGS="--storage.tsdb.retention.time=30d"|' /etc/default/prometheus
else
  echo 'ARGS="--storage.tsdb.retention.time=30d"' >> /etc/default/prometheus
fi

systemctl daemon-reload
/usr/local/bin/pve-exporter-conf >/dev/null
for s in pve-exporter nut-exporter pihole-exporter prometheus; do
  systemctl enable -q "$s" 2>/dev/null || true; systemctl restart "$s" || echo "  !! $s failed to start"
done

# Grafana: data source + dashboards from grafana.com
mkdir -p /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards /var/lib/grafana/dashboards
cat > /etc/grafana/provisioning/datasources/prometheus.yml <<'EOS'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
    jsonData: {timeInterval: 30s}
EOS
cat > /etc/grafana/provisioning/dashboards/homelab.yml <<'EOS'
apiVersion: 1
providers:
  - name: homelab
    folder: Homelab
    type: file
    allowUiUpdates: true
    options: {path: /var/lib/grafana/dashboards}
EOS
echo "  Dashboards:"
for d in 1860:node 10347:proxmox 14574:nvidia 19308:ups 10176:pihole; do
  id=${d%%:*}; f=/var/lib/grafana/dashboards/${d##*:}.json
  if curl -fsSL -o "$f.new" "https://grafana.com/api/dashboards/$id/revisions/latest/download"; then
    sed -E 's/\$\{DS_[A-Za-z0-9_-]+\}/prometheus/g' "$f.new" > "$f"; rm -f "$f.new"
    echo "    $id  $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("title"))' "$f")"
  else
    rm -f "$f.new"; echo "    !! $id download failed"
  fi
done
chown -R grafana:grafana /var/lib/grafana/dashboards
chown root:grafana /etc/grafana/provisioning/datasources/prometheus.yml /etc/grafana/provisioning/dashboards/homelab.yml
chmod 640 /etc/grafana/provisioning/datasources/prometheus.yml /etc/grafana/provisioning/dashboards/homelab.yml
chmod -R a+rX /opt/pve-exporter
systemctl restart grafana-server

echo "  Waiting 45 s for the first scrapes..."; sleep 45
echo "  Targets (1 = up, 0 = down):"
curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=up' | python3 -c '
import json,sys
for r in sorted(json.load(sys.stdin)["data"]["result"], key=lambda r:(r["metric"]["job"], r["metric"]["instance"])):
    print("    %s  %-10s %s" % (r["value"][1], r["metric"]["job"], r["metric"]["instance"]))'
echo "  Pi-holes answering: $(curl -fsS http://127.0.0.1:9617/metrics | grep -c '^pihole_status' || true) of 4"
EOF

pct exec "$CT" -- mkdir -p /root/.gstack
pct exec "$CT" -- chmod 700 /root/.gstack
for f in ghbin.sh secrets.env in-ct.sh; do pct push "$CT" "$TMP/$f" "/root/.gstack/$f" --perms 600; done
pct exec "$CT" -- bash /root/.gstack/in-ct.sh
pct exec "$CT" -- rm -f /root/.gstack/secrets.env

IP=$(pct exec "$CT" -- hostname -I | awk '{print $1}')
MAC=$(pct config "$CT" | sed -n 's/^net0:.*hwaddr=\([^,]*\).*/\1/p')
echo
echo "Grafana:    http://$IP:3000   (first login admin / admin, it asks for a new password)"
echo "Prometheus: http://$IP:9090/targets"
echo "CT $CT, MAC $MAC: reserve $IP in OPNsense."
echo "plex-proxmox and opnsense show 0 until their steps in SETUP.md are done."
