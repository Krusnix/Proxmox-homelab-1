#!/bin/bash
# Grafana + Prometheus: run on homelab1-proxmox as root after the Grafana helper script.
#   bash setup-homelab1.sh [CTID]     (default: the CT named "grafana")
# On this host: installs node exporter (:9100), the NVIDIA GPU exporter (:9835) and the
# Intel iGPU collector (intel_gpu_top -> node exporter), and creates a read-only Proxmox
# API token prometheus@pve!metrics (PVEAuditor).
# In the Grafana CT: installs Prometheus (30 days of history), the Proxmox, UPS (NUT),
# Pi-hole and Plex stream (Tautulli) exporters, points Grafana at Prometheus and loads
# the dashboards. Also scrapes unraid-1 (node exporter :9100, cAdvisor :9180).
# Safe to run again: it replaces the token, rewrites the configs and keeps the
# plex-proxmox token and any Tautulli added by hand.
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
if lspci 2>/dev/null | grep -Ei 'VGA|Display' | grep -qi intel; then
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y -qq --no-install-recommends intel-gpu-tools >/dev/null
  cat > /usr/local/bin/intel-gpu-textfile <<'EOF'
#!/usr/bin/env python3
# Runs intel_gpu_top and writes the Intel iGPU's load for node exporter's textfile
# collector (metrics intel_gpu_*). Started by intel-gpu-textfile.service.
import json, os, subprocess, sys
OUT = os.environ.get('OUT', '/var/lib/prometheus/node-exporter/intel_gpu.prom')
CMD = os.environ.get('CMD', 'intel_gpu_top -J -s 15000').split()

def write(s):
    lines = ['# TYPE intel_gpu_engine_busy_percent gauge']
    for name, e in (s.get('engines') or {}).items():
        lines.append('intel_gpu_engine_busy_percent{engine="%s"} %s' % (name.replace('"', ''), float(e.get('busy', 0))))
    f = s.get('frequency') or {}
    lines.append('# TYPE intel_gpu_frequency_mhz gauge')
    lines += ['intel_gpu_frequency_mhz{type="%s"} %s' % (k, float(f[k])) for k in ('requested', 'actual') if k in f]
    lines += ['# TYPE intel_gpu_rc6_percent gauge', 'intel_gpu_rc6_percent %s' % float((s.get('rc6') or {}).get('value', 0))]
    p = s.get('power') or {}
    lines.append('# TYPE intel_gpu_power_watts gauge')
    lines += ['intel_gpu_power_watts{domain="%s"} %s' % (k.lower(), float(p[k])) for k in ('GPU', 'Package') if k in p]
    lines += ['# TYPE intel_gpu_clients gauge', 'intel_gpu_clients %d' % len(s.get('clients') or {})]
    tmp = OUT + '.tmp'
    with open(tmp, 'w') as fh:
        fh.write('\n'.join(lines) + '\n')
    os.chmod(tmp, 0o644)
    os.replace(tmp, OUT)

os.makedirs(os.path.dirname(OUT), exist_ok=True)
proc = subprocess.Popen(CMD, stdout=subprocess.PIPE)
dec, buf = json.JSONDecoder(), ''
while True:
    data = os.read(proc.stdout.fileno(), 65536)
    if not data:
        break
    buf += data.decode('utf-8', 'replace')
    while True:
        buf = buf.lstrip(' \t\r\n,[]')
        if not buf:
            break
        try:
            obj, end = dec.raw_decode(buf)
        except ValueError:
            if len(buf) > 1000000:
                buf = ''
            break
        buf = buf[end:]
        if isinstance(obj, dict):
            try:
                write(obj)
            except Exception as e:
                print('skipped a sample: %s' % e, file=sys.stderr)
sys.exit(proc.wait() or 1)
EOF
  chmod 755 /usr/local/bin/intel-gpu-textfile
  cat > /etc/systemd/system/intel-gpu-textfile.service <<'EOF'
[Unit]
Description=Intel iGPU load for node exporter (intel_gpu_top)
[Service]
ExecStart=/usr/local/bin/intel-gpu-textfile
Restart=always
RestartSec=30
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable -q intel-gpu-textfile; systemctl restart intel-gpu-textfile
  echo "  Intel iGPU collector started"
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

# ---------- Tautulli API keys: homelab1 from CT 106, plex-proxmox from Homepage's saved keys ----------
TT_HOMELAB1_KEY=$(pct exec 106 -- sed -n 's/^api_key *= *//p' /opt/Tautulli/config.ini 2>/dev/null | head -1 || true)
HP=$(pct list | awk 'NR>1 && $NF=="homepage"{print $1; exit}')
hpvar() {
  [ -n "$HP" ] || return 0
  pct exec "$HP" -- sed -n "s/^HOMEPAGE_VAR_$1='\\(.*\\)'\$/\\1/p" /etc/homepage/vars.env 2>/dev/null | head -1 || true
}
TT_PLEX_KEY=$(hpvar TAUTULLI_PLEXPVE)
TT_PLEX_IP=$(hpvar TAUTULLI2_IP)

umask 077
cat > "$TMP/secrets.env" <<EOF
HOST_IP='$HOST_IP'
PVE_HOMELAB1='$PVE_SECRET'
PH_HOSTS='$PH_HOSTS'
PH_PORTS='$PH_PORTS'
PH_PW='$PH_PW'
TT_HOMELAB1_KEY='$TT_HOMELAB1_KEY'
TT_PLEX_KEY='$TT_PLEX_KEY'
TT_PLEX_URL='http://${TT_PLEX_IP:-192.168.4.198}:8181'
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

# Plex stream exporter: reads get_activity from each Tautulli
cat > /usr/local/bin/tautulli-exporter <<'PYEOF'
#!/usr/bin/env python3
# Plex stream numbers for Prometheus, read from each Tautulli's get_activity API.
# Servers are listed in /etc/tautulli-exporter.conf as "name|url|apikey" (see tautulli-exporter-add).
import json, os, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
CONF = os.environ.get('CONF', '/etc/tautulli-exporter.conf')
PORT = int(os.environ.get('PORT', '9487'))

def servers():
    with open(CONF) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith('#') and line.count('|') >= 2:
                name, url, key = line.split('|', 2)
                yield name, url.rstrip('/'), key

def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0

def lab(**kw):
    return ','.join('%s="%s"' % (k, str(v).replace('\\', '\\\\').replace('"', '\\"').replace('\n', ' ')) for k, v in kw.items())

def collect():
    m = {k: [] for k in ('tautulli_up', 'tautulli_streams', 'tautulli_bandwidth_kbps',
                         'tautulli_user_streams', 'tautulli_video_transcodes')}
    for name, url, key in servers():
        try:
            q = urllib.parse.urlencode({'apikey': key, 'cmd': 'get_activity'})
            with urllib.request.urlopen('%s/api/v2?%s' % (url, q), timeout=6) as r:
                resp = json.load(r)['response']
            d = resp.get('data')
            if resp.get('result') != 'success' or not isinstance(d, dict):
                raise ValueError('bad key or no data')
        except Exception:
            m['tautulli_up'].append((lab(server=name), 0))
            continue
        m['tautulli_up'].append((lab(server=name), 1))
        for dec in ('direct_play', 'direct_stream', 'transcode'):
            m['tautulli_streams'].append((lab(server=name, decision=dec), num(d.get('stream_count_' + dec))))
        for loc in ('lan', 'wan'):
            m['tautulli_bandwidth_kbps'].append((lab(server=name, location=loc), num(d.get(loc + '_bandwidth'))))
        users, hw = {}, {'yes': 0, 'no': 0}
        for s in d.get('sessions') or []:
            u = s.get('friendly_name') or s.get('user') or 'unknown'
            users[u] = users.get(u, 0) + 1
            if s.get('video_decision') == 'transcode':
                hw['yes' if num(s.get('transcode_hw_encoding')) or num(s.get('transcode_hw_decoding')) else 'no'] += 1
        for u, n in users.items():
            m['tautulli_user_streams'].append((lab(server=name, user=u), n))
        for k, n in hw.items():
            m['tautulli_video_transcodes'].append((lab(server=name, hw=k), n))
    out = []
    for metric, rows in m.items():
        out.append('# TYPE %s gauge' % metric)
        out += ['%s{%s} %s' % (metric, l, v) for l, v in rows]
    return '\n'.join(out) + '\n'

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = collect().encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain; version=0.0.4')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass

ThreadingHTTPServer(('127.0.0.1', PORT), H).serve_forever()
PYEOF
cat > /usr/local/bin/tautulli-exporter-add <<'EOS'
#!/bin/sh
# tautulli-exporter-add NAME URL APIKEY   adds or replaces a Tautulli in /etc/tautulli-exporter.conf
CONF=/etc/tautulli-exporter.conf
[ $# -eq 3 ] || { sed -n 2p "$0" | sed 's/^# //'; exit 1; }
touch "$CONF"; grep -v "^$1|" "$CONF" > "$CONF.tmp" || true
printf '%s|%s|%s\n' "$1" "${2%/}" "$3" >> "$CONF.tmp"; mv "$CONF.tmp" "$CONF"
chown root:prometheus "$CONF"; chmod 640 "$CONF"
echo "  Tautulli $1 added"
EOS
chmod 755 /usr/local/bin/tautulli-exporter /usr/local/bin/tautulli-exporter-add
if [ -n "$TT_HOMELAB1_KEY" ]; then /usr/local/bin/tautulli-exporter-add homelab1 http://192.168.4.113:8181 "$TT_HOMELAB1_KEY"; fi
if [ -n "$TT_PLEX_KEY" ]; then /usr/local/bin/tautulli-exporter-add plex-proxmox "$TT_PLEX_URL" "$TT_PLEX_KEY"; fi
[ -f /etc/tautulli-exporter.conf ] || install -m 640 -g prometheus /dev/null /etc/tautulli-exporter.conf
cat > /etc/systemd/system/tautulli-exporter.service <<'EOS'
[Unit]
Description=Plex stream exporter for Prometheus (reads Tautulli)
After=network-online.target
[Service]
User=prometheus
ExecStart=/usr/local/bin/tautulli-exporter
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
      - {targets: ['192.168.5.14:9100'], labels: {instance: unraid-1}}
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
  - job_name: tautulli
    scrape_timeout: 25s
    static_configs: [{targets: ['127.0.0.1:9487']}]
  - job_name: cadvisor
    static_configs:
      - {targets: ['192.168.5.14:9180'], labels: {instance: unraid-1}}
EOS
promtool check config /etc/prometheus/prometheus.yml >/dev/null && echo "  Prometheus config OK"
if grep -q '^ARGS=' /etc/default/prometheus 2>/dev/null; then
  sed -i 's|^ARGS=.*|ARGS="--storage.tsdb.retention.time=30d"|' /etc/default/prometheus
else
  echo 'ARGS="--storage.tsdb.retention.time=30d"' >> /etc/default/prometheus
fi

systemctl daemon-reload
/usr/local/bin/pve-exporter-conf >/dev/null
for s in pve-exporter nut-exporter pihole-exporter tautulli-exporter prometheus; do
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
for d in 1860:node 4260:opnsense 10347:proxmox 14574:nvidia 19308:ups 10176:pihole 14282:docker; do
  id=${d%%:*}; f=/var/lib/grafana/dashboards/${d##*:}.json
  if curl -fsSL -o "$f.new" "https://grafana.com/api/dashboards/$id/revisions/latest/download"; then
    sed -E 's/\$\{DS_[A-Za-z0-9_-]+\}/prometheus/g' "$f.new" > "$f"; rm -f "$f.new"
    echo "    $id  $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("title"))' "$f")"
  else
    rm -f "$f.new"; echo "    !! $id download failed"
  fi
done
# Hand-made dashboards: Plex Streams and Intel iGPU
python3 - /var/lib/grafana/dashboards <<'PYEOF'
#!/usr/bin/env python3
# Writes the two hand-made dashboards (Plex streams, Intel iGPU) into Grafana's dashboard folder.
import json, os, sys
OUT = sys.argv[1] if len(sys.argv) > 1 else '/var/lib/grafana/dashboards'
DS = {'type': 'prometheus', 'uid': 'prometheus'}

def targets(exprs):
    return [{'refId': chr(65 + i), 'datasource': DS, 'expr': e, 'legendFormat': l} for i, (e, l) in enumerate(exprs)]

def graph(title, exprs, x, y, w=12, h=8, unit='short', stack=False, step=False, vmax=None):
    d = {'unit': unit, 'min': 0, 'custom': {
        'drawStyle': 'line', 'lineInterpolation': 'stepAfter' if step else 'linear', 'lineWidth': 1,
        'fillOpacity': 30 if stack else 10, 'showPoints': 'never', 'spanNulls': False,
        'stacking': {'mode': 'normal' if stack else 'none', 'group': 'A'}}}
    if vmax is not None:
        d['max'] = vmax
    elif unit == 'short':      # counts: whole numbers, and a 0-4 scale when nothing is playing
        d['decimals'] = 0
        d['custom']['axisSoftMax'] = 4
    elif unit == 'hertz':
        d['custom']['axisSoftMax'] = 1500000000
    elif unit == 'bps':
        d['custom']['axisSoftMax'] = 10000000
    return {'type': 'timeseries', 'title': title, 'datasource': DS, 'gridPos': {'x': x, 'y': y, 'w': w, 'h': h},
            'targets': targets(exprs), 'fieldConfig': {'defaults': d, 'overrides': []},
            'options': {'legend': {'displayMode': 'list', 'placement': 'bottom', 'showLegend': True},
                        'tooltip': {'mode': 'multi', 'sort': 'desc'}}}

def stat(title, expr, x, y, w=4, h=4, unit='short', decimals=0):
    return {'type': 'stat', 'title': title, 'datasource': DS, 'gridPos': {'x': x, 'y': y, 'w': w, 'h': h},
            'targets': targets([(expr, '')]),
            'fieldConfig': {'defaults': {'unit': unit, 'decimals': decimals, 'noValue': '0'}, 'overrides': []},
            'options': {'reduceOptions': {'calcs': ['lastNotNull'], 'fields': '', 'values': False},
                        'colorMode': 'value', 'graphMode': 'area', 'textMode': 'auto'}}

def dash(uid, title, panels, span='now-24h'):
    for i, p in enumerate(panels, 1):
        p['id'] = i
    d = {'uid': uid, 'title': title, 'tags': ['homelab'], 'timezone': 'browser', 'schemaVersion': 39, 'version': 1,
         'editable': True, 'graphTooltip': 1, 'refresh': '1m', 'time': {'from': span, 'to': 'now'},
         'templating': {'list': []}, 'annotations': {'list': []}, 'links': [], 'panels': panels}
    with open(os.path.join(OUT, uid + '.json'), 'w') as fh:
        json.dump(d, fh, indent=1)
    print('    %s' % title)

S = 'sum(tautulli_streams)'
dash('homelab-plex-streams', 'Plex Streams', [
    stat('Streams now', S, 0, 0),
    stat('Transcoding now', 'sum(tautulli_streams{decision="transcode"})', 4, 0),
    stat('Bandwidth now', 'sum(tautulli_bandwidth_kbps) * 1000', 8, 0, unit='bps', decimals=1),
    stat('Peak streams in this time range', 'max_over_time(%s[$__range:1m])' % S, 12, 0),
    stat('Internet bandwidth now', 'sum(tautulli_bandwidth_kbps{location="wan"}) * 1000', 16, 0, unit='bps', decimals=1),
    stat('Tautullis answering', 'sum(tautulli_up)', 20, 0),
    graph('Streams by server', [('sum by (server) (tautulli_streams)', '{{server}}')], 0, 4, stack=True, step=True),
    graph('Streams by type', [('sum by (decision) (tautulli_streams)', '{{decision}}')], 12, 4, stack=True, step=True),
    graph('Streams by user', [('sum by (user) (tautulli_user_streams)', '{{user}}')], 0, 12, stack=True, step=True),
    graph('Bandwidth', [('sum by (server, location) (tautulli_bandwidth_kbps) * 1000', '{{server}} {{location}}')],
          12, 12, unit='bps', stack=True),
    graph('Video transcodes: GPU or CPU', [('sum by (hw) (tautulli_video_transcodes{hw="yes"})', 'GPU (hardware)'),
                                           ('sum by (hw) (tautulli_video_transcodes{hw="no"})', 'CPU (software)')],
          0, 20, stack=True, step=True),
    graph('Streams by server and type', [('tautulli_streams > 0', '{{server}} {{decision}}')], 12, 20, stack=True, step=True),
])

B = 'intel_gpu_engine_busy_percent'
dash('homelab-intel-gpu', 'Intel iGPU', [
    stat('Video engine now', 'max(%s{engine=~"Video.*", engine!~"VideoEnhance.*"})' % B, 0, 0, w=6, unit='percent', decimals=1),
    stat('Render/3D now', 'max(%s{engine=~"Render.*"})' % B, 6, 0, w=6, unit='percent', decimals=1),
    stat('GPU power now', 'intel_gpu_power_watts{domain="gpu"}', 12, 0, w=6, unit='watt', decimals=1),
    stat('Programs using the iGPU', 'intel_gpu_clients', 18, 0, w=6),
    graph('Engine load (Video = decode/encode, VideoEnhance = scaling/tone mapping)', [(B, '{{engine}}')],
          0, 4, w=24, unit='percent', vmax=100),
    graph('Power (package = whole CPU chip, gpu = graphics part only)',
          [('intel_gpu_power_watts{domain="gpu"}', 'gpu'), ('intel_gpu_power_watts{domain="package"}', 'package (whole CPU)')],
          0, 12, unit='watt'),
    graph('Clock speed (0 when idle)', [('intel_gpu_frequency_mhz * 1000000', '{{type}}')], 12, 12, unit='hertz'),
    graph('Idle time (RC6 sleep state)', [('intel_gpu_rc6_percent', 'idle')], 0, 20, unit='percent', vmax=100),
    graph('Programs using the iGPU', [('intel_gpu_clients', 'clients')], 12, 20, step=True),
], span='now-6h')
PYEOF
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
echo "  Tautullis (1 = answering):"
curl -fsS -m 25 http://127.0.0.1:9487/metrics | sed -n 's/^tautulli_up{server="\([^"]*\)"} /    \1 /p'
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
echo "Intel iGPU engines reporting: $(curl -fsS http://127.0.0.1:9100/metrics | grep -c '^intel_gpu_engine_busy_percent' || true)"
echo "Any 0 above: see SETUP.md (plex-proxmox, OPNsense and unraid-1 each need a step of their own)."
grep -q "^unraid-1|" <(pct exec $CT -- cat /etc/tautulli-exporter.conf) || {
  echo "Unraid's Tautulli isn't added yet (key: grep api_key /mnt/user/appdata/tautulli/config.ini on Unraid):"
  echo "  pct exec $CT -- /usr/local/bin/tautulli-exporter-add unraid-1 http://192.168.5.14:8181 'API-KEY'"; }
