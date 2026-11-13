#!/bin/bash
# Grafana + Prometheus: run on plex-proxmox as root. Installs node exporter (:9100) and
# adds a read-only Proxmox API token (prometheus@pve!metrics, PVEAuditor; re-running
# replaces it). Prints one command to paste on homelab1-proxmox.
set -euo pipefail
apt-get update -qq || true
DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y -qq --no-install-recommends prometheus-node-exporter >/dev/null
systemctl enable -q --now prometheus-node-exporter && echo "node exporter on :9100"
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
echo "pct exec 112 -- pve-exporter-conf plex '$PVE_SECRET'"
echo "------------------------------------------------------------"
