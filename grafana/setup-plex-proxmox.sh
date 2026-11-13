#!/bin/bash
# Grafana + Prometheus: run on plex-proxmox as root. Installs node exporter (:9100), allows
# the Grafana CT (192.168.4.232, or $1) to reach it if the Proxmox firewall is on, and adds a
# read-only Proxmox API token (prometheus@pve!metrics, PVEAuditor; re-running replaces it).
# Prints one command to paste on homelab1-proxmox.
set -euo pipefail
apt-get update -qq || true
DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y -qq --no-install-recommends prometheus-node-exporter >/dev/null
systemctl enable -q --now prometheus-node-exporter && echo "node exporter on :9100"
# If the Proxmox firewall is on, let the Grafana CT (and only it) reach node exporter.
GRAFANA_IP="${1:-192.168.4.232}"
if pve-firewall status 2>/dev/null | grep -q enabled; then
  if pvesh get "/nodes/$(hostname)/firewall/rules" --output-format json | grep -q '"dport":"9100"'; then
    echo "firewall rule for :9100 already there"
  else
    pvesh create "/nodes/$(hostname)/firewall/rules" --type in --action ACCEPT --source "$GRAFANA_IP" \
      --proto tcp --dport 9100 --enable 1 --comment "Prometheus node exporter, Grafana CT on homelab1"
    echo "firewall: allowed $GRAFANA_IP to :9100"
  fi
fi
pveum user add prometheus@pve --comment "Prometheus metrics, read-only" 2>/dev/null || true
pveum acl modify / --users prometheus@pve --roles PVEAuditor
pveum user token remove prometheus@pve metrics 2>/dev/null || true
PVE_SECRET=$(pveum user token add prometheus@pve metrics --privsep 0 --comment "Grafana CT on homelab1" --output-format json \
  | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')
[ -n "$PVE_SECRET" ] || { echo "Could not create the Proxmox token"; exit 1; }
command -v nvidia-smi >/dev/null && echo "Note: this host has an NVIDIA GPU; tell Claude if you want it graphed too."
echo
echo "Paste this on homelab1-proxmox (112 = the Grafana CT):"
echo "------------------------------------------------------------"
echo "pct exec 112 -- /usr/local/bin/pve-exporter-conf plex '$PVE_SECRET'"
echo "------------------------------------------------------------"
