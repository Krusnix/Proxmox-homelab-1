# homelab1-proxmox rebuild runbook

Last updated 2026-11-12. Covers the Proxmox host rebuilt on 2026-11-08 and the LXCs on it.

## Host

| Item | Value |
|---|---|
| Hostname | homelab1-proxmox.internal |
| IP | 192.168.4.209/22, gateway and DNS 192.168.4.1 (OPNsense) |
| Hardware | i7-12700H, 62 GB RAM, 1 TB NVMe (LVM, no redundancy) |
| PVE | 9.x, standalone, community post-install script run |
| Remote access | Tailscale: OPNsense is the subnet router + exit node; host, CT 102 and CT 103 are plain tailnet devices (see below) |

### GPU drivers (host)

- Intel iGPU: in-kernel i915. `renderD128` = Intel, `card1` = Intel.
- NVIDIA RTX 3070 Ti: driver **620.70.06**, open kernel modules via DKMS. nouveau blacklisted, `nvidia-persistenced` on, `/etc/modules-load.d/nvidia.conf`, udev rule `70-nvidia.rules`. `renderD129` = NVIDIA.
- The installer is kept at `/root/nvidia` for installing the matching userspace driver in LXCs (`--no-kernel-module`).
- **If the host NVIDIA driver is updated, reinstall the same version in CT 103 (Plex), CT 104 (Tdarr), CT 105 (Immich) and CT 107 (Tunarr).**

### Network shares (PVE storages)

| Storage | Source | Host path | LXC mount |
|---|---|---|---|
| unraid-data | `//192.168.5.14/data` (Unraid, SMB) | `/mnt/pve/unraid-data` | `/unraid` |
| nas-public | `//192.168.4.180/public` (TerraMaster, SMB) | `/mnt/pve/nas-public` | `/nas` |

Both are mounted with `uid=100000,gid=110000`, mode 0775. Inside unprivileged LXCs, create group `nasshare` with gid **10000** (maps to host gid 110000) and add the service user to it.

### Backups (nightly vzdump + rsync to TerraMaster)

Set up 2026-11-10. Each container is backed up to a local volume every night, and a hook script then copies that folder to the TerraMaster over rsync. Nothing is written over the SMB share.

- **Local volume:** 200 GB thin LV `pve/backup-local` (ext4) mounted at `/mnt/backup-local` (fstab: `/dev/pve/backup-local /mnt/backup-local ext4 defaults,discard 0 2`). PVE storage `backup-local` (dir, content `backup`, `is_mountpoint yes`).
- **Job `nightly-cts`** (Datacenter → Backup): 01:00 daily, all guests, snapshot mode, zstd, `keep-daily=3`, notes `{{guestname}}`, hook `--script /usr/local/bin/vzdump-rsync.sh`.
- **What's skipped:** bind mounts (`/unraid`, `/nas`) are never included, and CT 104's `/tdarr_cache` is `backup=0`. Only container disks are backed up.
- **Off-box copy:** TerraMaster (192.168.4.180) rsync module `proxmox-homelab-backup` (no "s"), account `krusnix`, password in `/etc/rsync-terramaster.pass` (mode 600, password only). The sync uses `--delete`, so the TerraMaster keeps the same 3 nights as the local disk (TerraMaster SSH is off, so nothing can prune there separately). Log: `/var/log/vzdump-rsync.log`. The other modules (`proxmox-plex-backup`, `unraid-backups`) belong to other machines; don't sync into them.
- Size reference (first full run 2026-11-10, ~8 min): **39 GB per night**. CT 105 Immich 27 GB, CT 103 Plex 6.9 GB, CT 104 Tdarr 1.5 GB, CT 107 Tunarr 1.1 GB, the rest under 700 MB each. 3 nights ≈ 120 GB of the 196 GB volume, so there's room for Immich to grow. Revisit retention if the volume passes ~75%.

Rebuild:

```bash
lvcreate -V 200G -T pve/data -n backup-local
mkfs.ext4 -L backup-local /dev/pve/backup-local
mkdir -p /mnt/backup-local
echo '/dev/pve/backup-local /mnt/backup-local ext4 defaults,discard 0 2' >> /etc/fstab
systemctl daemon-reload && mount /mnt/backup-local
pvesm add dir backup-local --path /mnt/backup-local --content backup --is_mountpoint yes
install -m 600 /dev/null /etc/rsync-terramaster.pass   # then put the rsync password in it

cat > /usr/local/bin/vzdump-rsync.sh <<'EOS'
#!/bin/bash
# vzdump hook: mirror local backups to the TerraMaster after the job ends.
# Sends an ntfy alert if the copy is skipped or fails.
[ "$1" = "job-end" ] || exit 0
NTFY=https://ntfy.sh/homelab1-alerts-3d1ef2b124a1
LOG=/var/log/vzdump-rsync.log
SRC=/mnt/backup-local/dump/
alert() {
  curl -fsS -m 15 -H "Title: homelab1 backup copy to TerraMaster failed" \
    -H "Priority: high" -H "Tags: floppy_disk" -d "$1" "$NTFY" >/dev/null \
    || echo "$(date '+%F %T') ntfy alert failed" >> "$LOG"
}
if ! mountpoint -q /mnt/backup-local; then
  echo "backup-local not mounted, skipping sync"; alert "backup-local is not mounted, so nothing was copied."; exit 1
fi
if [ -z "$(ls -A "$SRC" 2>/dev/null)" ]; then
  echo "$SRC is empty, skipping sync"; alert "$SRC is empty, so nothing was copied."; exit 1
fi
echo "$(date '+%F %T') sync start" >> "$LOG"
rsync -rt --delete --password-file=/etc/rsync-terramaster.pass \
  "$SRC" rsync://krusnix@192.168.4.180/proxmox-homelab-backup/dump/ >> "$LOG" 2>&1
rc=$?
echo "$(date '+%F %T') sync end rc=$rc" >> "$LOG"
[ $rc -eq 0 ] || alert "rsync exited with code $rc. Last log lines:
$(tail -n 5 "$LOG")"
exit $rc
EOS
chmod 755 /usr/local/bin/vzdump-rsync.sh

pvesh create /cluster/backup --id nightly-cts --schedule "01:00" --all 1 --storage backup-local \
  --mode snapshot --compress zstd --prune-backups keep-daily=3 --notes-template "{{guestname}}" \
  --script /usr/local/bin/vzdump-rsync.sh --notification-mode notification-system --enabled 1
```

The guards in the script stop `--delete` from wiping the TerraMaster copy if the local volume is missing or empty. A failed or skipped sync sends its own ntfy alert and also makes the job fail, so it shows up in the task log and the Proxmox notification too (you may get two pings for one failure). Alerts were added 2026-11-11; see [ntfy alerts](#ntfy-alerts-proxmox-backups-ups).

Restore after a host rebuild: pull the files back with `rsync -rt --password-file=/etc/rsync-terramaster.pass rsync://krusnix@192.168.4.180/proxmox-homelab-backup/dump/ /mnt/backup-local/dump/`, then `pct restore <ctid> /mnt/backup-local/dump/vzdump-lxc-<ctid>-<date>.tar.zst --storage local-lvm` (or pick the backup under backup-local → Backups in the UI). Afterwards, check the container's bind mounts and CT 104's `/tdarr_cache` disk. Their contents aren't in the archive, so re-add any that are missing from the restored config.

### Tailscale

Set up 2026-11-10, copied from how plex-proxmox does it.

- **OPNsense** (tailnet 100.87.156.126) is the only subnet router and exit node. It advertises `192.168.4.0/23`, which covers 192.168.4.x and 192.168.5.x (Unraid). Nothing on this host advertises routes or runs as an exit node, and `net.ipv4.ip_forward` stays 0.
- Tailscale 1.104.6 from the official apt repo (`pkgs.tailscale.com/stable/debian trixie`), installed by hand rather than via `install.sh`.
- Every node is a plain client: `tailscale up --hostname=<name> --accept-dns=false --accept-routes=false`. No serve, funnel or SSH. Tailscale shows the names with a hyphen (`*-homelab-1`, MagicDNS `<name>.tail6e0a9a.ts.net`) even though `--hostname` was `*homelab1`.

| Node | Where | Tailnet IP | Use |
|---|---|---|---|
| proxmox-homelab-1 | host | 100.94.106.106 | Proxmox UI at `https://100.94.106.106:8006` |
| pihole-homelab-1 | CT 102 | 100.116.175.64 | Pi-hole |
| plex-homelab-1 | CT 103 | 100.92.231.97 | Plex |

- CT 102 and CT 103 need TUN access for Tailscale. Append to `/etc/pve/lxc/<id>.conf`, then `pct reboot <id>`:
  ```
  lxc.cgroup2.devices.allow: c 10:200 rwm
  lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
  ```
  Pre-change backups: `/root/102.conf.bak-202611101913`, `/root/103.conf.bak-202611101913`.
- **Tailnet DNS → Pi-hole:** in the Tailscale admin console under DNS, add custom nameserver `192.168.4.145` and turn on Override DNS servers. Pi-hole's `dns.listeningMode` is `ALL`, so it answers tailnet clients. `--accept-dns=false` on the Pi-hole node keeps Pi-hole on its own Unbound.
- OPNsense UI from the tailnet: its tailnet IP or `192.168.4.1` via the subnet route. If it doesn't load, add a pass rule on the Tailscale interface to "This Firewall" on 443.
- On a rebuild, delete the old devices in the Tailscale admin first, or the new ones get a `-1` added to their names.

## LXCs

All installed with the Proxmox community helper scripts, then configured by hand.

| CT | Name | IP | Notes |
|---|---|---|---|
| 100 | pve-scripts-local | 192.168.4.102 (DHCP reserved) | Helper-script web UI |
| 101 | pve-ups | 192.168.4.205:8080 (DHCP reserved) | PVE-UPS: UPS alerts via NUT on 192.168.4.141 |
| 102 | pihole | 192.168.4.145 | Pi-hole + Unbound on 5335 (DoT to 8.8.8.8/8.8.4.4), nebula-sync primary |
| 103 | plex | 192.168.4.120 | Both GPUs, /unraid + /nas |
| 104 | tdarr | 192.168.4.127:8265 | Both GPUs, /unraid + /nas |
| 105 | immich | 192.168.4.163:2283 (DHCP reserved) | Both GPUs, /unraid |
| 106 | tautulli | 192.168.4.113:8181 (DHCP reserved) | Plex stats, no GPU or shares |
| 107 | tunarr | 192.168.4.235:8000 | Live TV channels for Plex, both GPUs |
| 108 | kometa | 192.168.4.213 (DHCP reserved) | Plex collections/overlays, no GPU or shares |
| 109 | beszel | 192.168.4.217:8090 (DHCP reserved) | Resource monitoring hub (CPU/memory/disk alerts) |
| 110 | uptimekuma | 192.168.4.134:3001 (DHCP reserved) | Service up/down checks |

### CT 102 Pi-hole and nebula-sync

- One of 4 Pi-holes (.145, .48, .5.53 on Unraid as docker `pihole-v6-unbound`, .141), all v6 with Unbound on `127.0.0.1#5335`.
- nebula-sync 0.11.3 (installed 2026-11-10) runs in CT 102 hourly and pushes to the other three. Config: `/etc/nebula-sync.env`. It uses selective sync with every section on **except the web server** (full mode would move .141's UI to port 80, where Apache runs). It excludes `misc.dnsmasq_lines` (the API can't write it) and `dns.dnssec` (missing on .141's older build). `CLIENT_SKIP_TLS_VERIFICATION=true` for .141's self-signed cert. Logs: `journalctl -u nebula-sync`.
- **plex.direct:** Unbound's `private-address` rules blank `*.plex.direct` answers, which breaks Plex sign-in for apps like Tunarr. Each Pi-hole has `misc.dnsmasq_lines` = `server=/plex.direct/1.1.1.1`, `server=/plex.direct/9.9.9.9`, set by hand on each (`pihole-FTL --config misc.dnsmasq_lines '[...]'`; on Unraid via the `FTLCONF_misc_dnsmasq_lines` template variable, `;`-separated). A rebuilt Pi-hole needs it again.
- Teleporter backups of all four from 2026-11-10: `/root/pihole-backups-2026-11-10/` in CT 102.

### CT 103 Plex

- 32 GB disk. `mp0` unraid-data → `/unraid`, `mp1` nas-public → `/nas`. `plex` user in `nasshare`.
- Both GPUs passed through; NVIDIA 620.70.06 userspace installed with `--no-kernel-module`.
- Remote access: OPNsense NAT WAN:32420 → 192.168.4.120:32400. If remote access breaks with a cert error, stop Plex, move `Cache/cert-v2.p12` aside, restart.

### CT 104 Tdarr

- Debian 13, Tdarr server 3.06.00, **8 cores / 16 GB RAM / 1 GB swap** (raised from 2 cores / 6 GB on 2026-11-10; see below). `/unraid` and `/nas` mounted. Transcode cache is a local 250 GB disk, `mp2: local-lvm:250,mp=/tdarr_cache,backup=0` (added 2026-11-10), set as "Transcode cache" `/tdarr_cache` on all four libraries (Movies, TV, Youtube, Private). The old `/temp` → `/unraid/tdarr_cache` link is unused.
- Both GPUs; NVIDIA libs 620.70.06 (held with `apt-mark hold`).
- Server auth on; node API key in `/opt/tdarr/configs/Tdarr_Node_Config.json`.
- Why the cache is local: with the cache on the CIFS share, Tdarr logged `Input/output error (os error 5)` whenever it deleted the work folder of a job that had died (OOM-killed ffmpeg, node crash). The share itself was healthy (0 reconnects, clean network). Run `pct fstrim 104` now and then to give freed cache space back to local-lvm.
- Custom plugin: `Tdarr_Plugin_AV1_HDR_Remove.js`. Old backup: `/unraid/dump/tdarr-backup`.
- **AV1 encodes run on the CPU.** The custom plugin uses `libsvtav1` (neither GPU can encode AV1), even on the "NVIDIA Node"'s GPU worker slots. Keep that node at **2 GPU transcode workers, 0 CPU**: each 1080p encode uses ~0.7 GB RAM, a 4K HDR tonemap ~2.5 GB. At 2 cores / 6 GB it ran out of memory and stalled.
- `tdarr-node.service` drop-in `/etc/systemd/system/tdarr-node.service.d/killmode.conf` sets `KillMode=mixed`. Without it (the default `KillMode=process`), a node crash or restart leaves its ffmpeg encodes running as orphans that pile up.

### CT 105 Immich

Installed 2026-11-10 with the Immich helper script (Immich 3.3.6).

**Container config** (`pct config 105`):

```
cores: 4
memory: 8192   # raised from 6144 on 2026-11-10 for CPU AV1 transcodes
swap: 1024
unprivileged: 1
features: nesting=1,keyctl=1
rootfs: local-lvm:vm-105-disk-0,size=50G
mp0: /mnt/pve/unraid-data,mp=/unraid
dev0: /dev/dri/renderD128,gid=992   # Intel render
dev1: /dev/dri/card1,gid=44         # Intel card
dev2: /dev/dri/renderD129,gid=992   # NVIDIA render
dev3-dev9: /dev/nvidia0, nvidiactl, nvidia-modeset, nvidia-uvm, nvidia-uvm-tools,
           /dev/nvidia-caps/nvidia-cap1, nvidia-cap2   (all gid=44)
net0: vmbr0, dhcp, MAC BC:24:11:B5:13:3C (.163 reserved in OPNsense)
onboot: 1
```

**Steps after the helper script:**

1. The script creates a 20 GB disk; resize root to 50 GB (`pct resize 105 rootfs 50G`). Thumbnails and Postgres live there.
2. Add `mp0` unraid-data → `/unraid` and the device lines above.
3. In the CT: `groupadd -g 10000 nasshare`; add `immich` to `video`, `render`, `nasshare`.
4. Install NVIDIA 620.70.06 userspace in the CT from `/root/nvidia` with `--no-kernel-module`.
5. Storage layout. `/opt/immich/.env` keeps `IMMICH_MEDIA_LOCATION=/opt/immich/upload`. Inside it, `library`, `upload`, `profile` and `backups` are symlinks to `/unraid/media/pictures/immich/<same name>` (each folder needs its `.immich` marker file). `thumbs` and `encoded-video` stay on local disk.
6. `pct reboot 105`, then check `nvidia-smi` as the immich user, `ls -l /dev/dri`, and `http://<ip>:2283/api/server/ping` → `pong`.

**Web UI settings:**

- Admin account: `krusnix` (created 2026-11-10).
- External library "krusnix": import path `/unraid/media/pictures` (34,618 assets, 1,299 videos at first scan). Exclusions: `**/@eaDir/**`, `**/._*`, `**/#recycle/**`, `**/#snapshot/**`, `**/.stversions/**`, `**/.stfolder/**` and **`**/immich/**`**. The last one matters: phone uploads land in `/unraid/media/pictures/immich`, which is inside the import path, so without it every upload is indexed twice.
- Storage template on: `{{y}}/{{MM}}/{{dd}}/{{filename}}` (applies to uploads only, not the external library).
- Video transcoding (Administration → Settings → Video Transcoding): Acceleration API **NVENC**, target codec **AV1**, accepted codecs AV1, hardware decoding off. **Neither GPU can encode AV1** (3070 Ti Laptop is Ampere, the Alder Lake iGPU has no AV1 encode), so Immich falls back to software `libsvtav1` on the CPU. Trent kept AV1 on purpose, same as Tdarr.
- Side effect: each CPU AV1 transcode uses 1-5 GB of RAM. On 2026-11-10 the initial backlog pinned CT 105 at its original 6 GB limit with swap full, and ffmpeg was OOM-killed (24 kills; Immich restarts the job on its own). Fixed the same evening with `pct set 105 -memory 8192 -swap 1024` (live, no reboot); no OOM kills since. If they come back, the host has room for 12 GB, or switch the target to HEVC/H.264 (NVENC can encode those) with AV1, HEVC and H.264 accepted.
- Proxmox's "Memory usage" figure leaves out page cache, so it can show ~50% while the container is really at its limit. Check `cat /sys/fs/cgroup/lxc/105/memory.events` on the host for `oom_kill`.
- Machine learning runs the OpenVINO build (Intel iGPU or CPU). NVIDIA for ML would need the CUDA build of immich-ml.

**Photos on Unraid:** `/mnt/user/data/media/pictures` (share `data`), about 77 GB.

### CT 106 Tautulli

Installed 2026-11-10 with the Tautulli helper script, defaults kept.

- Unprivileged, 2 cores / 1 GB RAM / 512 MB swap, 4 GB disk on local-lvm, `nesting=1,keyctl=1`, starts on boot.
- No GPU and no mountpoints. It only talks to the Plex API.
- net0: vmbr0, DHCP, MAC `BC:24:11:FB:C4:09`, IP 192.168.4.113, reserved in OPNsense.
- Web UI: `http://192.168.4.113:8181`. Service: `systemctl status tautulli`. Config: `/opt/Tautulli/config.ini`.
- Setup wizard: sign in with Plex, server `homelab-1` at 192.168.4.120:32400, SSL off.
- Check: `curl http://192.168.4.120:32400/identity` from inside the CT returns 200.

### CT 107 Tunarr

Installed 2026-11-10 with the Tunarr helper script (Tunarr 2026.11.2), hardware acceleration set to "all GPUs".

- Both GPUs. Intel: iHD driver, VAAPI/QSV (`vainfo --display drm --device /dev/dri/renderD128`). NVIDIA: 620.70.06 userspace libs from NVIDIA's CUDA apt repo (no `nvidia-smi` in the CT, NVENC works).
- net0: vmbr0, DHCP, MAC `BC:24:11:03:6F:D4`, IP 192.168.4.235. Reserve it in OPNsense.
- Web UI: `http://192.168.4.235:8000` (redirects to `/web`). Service: `systemctl status tunarr`. Binary: `/opt/tunarr/tunarr`.
- Plex: Settings → Media Sources → add Plex (sign in), server 192.168.4.120:32400. Then add Tunarr as a DVR tuner in Plex Live TV.
- **Install quirks:** the helper script failed at `mv tunarr* tunarr` (the file already had that name) and would have failed again fetching a `gpl-7.1` ffmpeg. The rest was finished by hand: ErsatzTV-ffmpeg `ffmpeg-n8.1.2-etv.8-linux64-gpl-8.1.tar.xz` (SHA256 checked), linked to `/usr/bin/ffmpeg` and `/usr/bin/ffprobe` (no ffplay), and the upstream `tunarr.service` enabled. The helper's update command may not recognize this ffmpeg build, so check ffmpeg after updating.

### CT 108 Kometa

Installed 2026-11-10 with the Kometa helper script (Kometa 2.5.4), defaults kept.

- Unprivileged, 2 cores / 4 GB RAM / 512 MB swap, 8 GB disk on local-lvm, starts on boot.
- No GPU and no mountpoints. It only talks to the Plex and TMDb APIs.
- net0: vmbr0, DHCP, MAC `BC:24:11:45:7C:EF`, IP 192.168.4.213, reserved in OPNsense.
- Install: `/opt/kometa` (Python venv in `.venv`, version in `/opt/kometa/VERSION`). Config: `/opt/kometa/config/config.yml`, logs in `/opt/kometa/config/logs/`.
- Services: `kometa.service` (waits and runs daily at 05:00) and `kometa-quickstart.service` (config builder web UI at `http://192.168.4.213:7171`).
- Config: `plex.url` is `http://192.168.4.120:32400`, with the Plex token and TMDb key set. Plex libraries are Movies, TV Shows, Music, Photos and Youtube. Tautulli for Kometa is `http://192.168.4.113:8181`, and its API key is in CT 106 `/opt/Tautulli/config.ini`.
- One-off run: `cd /opt/kometa && .venv/bin/python kometa.py --run`.
- **Status 2026-11-10:** the config was still the helper template, with an Anime library that doesn't exist, a missing `Music.yml`, and Radarr/Sonarr/Tautulli/notifier sections pointing at 192.168.1.12. Trent will configure it later.

### Monitoring: CT 109 Beszel and CT 110 Uptime Kuma

Added 2026-11-11 after Tdarr (CT 104) ran out of memory unnoticed. Both installed with helper scripts, defaults kept, and covered by the nightly vzdump backups.

- **Alerts** go to the ntfy app on Trent's phone, topic `homelab1-alerts-3d1ef2b124a1` on `https://ntfy.sh` (no account). Both tools send to it.
- **CT 109 Beszel** (`http://192.168.4.217:8090`), MAC `BC:24:11:4B:96:99`, reserved in OPNsense.
  - Notifications: Settings → Notifications → Webhook URL `ntfy://ntfy.sh/homelab1-alerts-3d1ef2b124a1`.
  - Agents (Add System → **Binary** tab → "Copy Linux command", listen port 45876) on the host `homelab1-proxmox` (192.168.4.209), Plex (.120), Tdarr (.127) and Immich (.163). For a CT, run the command inside it: `pct enter <id>` then paste, or `pct exec <id> -- bash -c '<command>'`. Each system has its own token.
  - Alerts on all four: Status, Memory > 90% for 5 min, Disk > 85%. CPU > 95% for 10 min on the host only, because Plex scans and Tdarr CPU encodes run their CTs at 100% on purpose.
  - Containers report the host's load average and temperature, so only alert on those for the host.
- **CT 110 Uptime Kuma** (`http://192.168.4.134:3001`), SQLite database, MAC `BC:24:11:53:49:A8`, reserved in OPNsense.
  - Notification: type ntfy, server `https://ntfy.sh`, same topic, priority 3 (DOWN events 5), "Default enabled" on.
  - HTTP monitors: Proxmox `https://192.168.4.209:8006` (ignore TLS), Plex `http://192.168.4.120:32400/identity`, Tdarr `:8265`, Immich `http://192.168.4.163:2283/api/server/ping`, Tautulli `:8181`, Tunarr `:8000`, Kometa `:7171`, Beszel `:8090`.
  - DNS monitors (resolve google.com): Pi-holes 192.168.4.145, 192.168.4.48, 192.168.5.53, 192.168.4.141.
  - Ping monitors: OPNsense 192.168.4.1, Unraid 192.168.5.14, TerraMaster 192.168.4.180, pve-ups 192.168.4.205.

### ntfy alerts: Proxmox, backups, UPS

Added 2026-11-11. Same phone topic as Beszel and Uptime Kuma: `homelab1-alerts-3d1ef2b124a1` on `https://ntfy.sh`.

- **Backup copy to TerraMaster:** the hook script `/usr/local/bin/vzdump-rsync.sh` (above) curls ntfy when the sync is skipped (volume unmounted or empty) or rsync fails, with the last log lines.
- **Proxmox notifications** (Datacenter → Notifications): webhook target `ntfy` and matcher `ntfy-problems`. The matcher sends anything with severity warning or error (backup job failures, replication, fencing) plus all `system-mail` (smartd disk warnings and other mail to root) to ntfy. Successful backups and package-update notices stay on mail-to-root only. Job `nightly-cts` uses `notification-mode notification-system`.

  ```bash
  b64() { printf '%s' "$1" | base64 -w0; }
  pvesh create /cluster/notifications/endpoints/webhook --name ntfy --method post \
    --url https://ntfy.sh/homelab1-alerts-3d1ef2b124a1 \
    --header "name=Title,value=$(b64 '{{ title }}')" \
    --header "name=Tags,value=$(b64 'proxmox,{{ severity }}')" \
    --header "name=Priority,value=$(b64 'high')" \
    --body "$(b64 '{{ message }}')" --comment "ntfy phone alerts"
  pvesh create /cluster/notifications/matchers --name ntfy-problems --target ntfy --mode any \
    --match-severity warning,error --match-field exact:type=system-mail \
    --comment "warnings, errors, SMART/system mail to ntfy"
  pvesh set /cluster/backup/nightly-cts --notification-mode notification-system
  pvesh create /cluster/notifications/targets/ntfy/test   # sends a test ping
  ```

- **UPS:** CT 101 runs PVE-UPS ([ffind-dev/pve-ups](https://github.com/ffind-dev/pve-ups), service `pve-usv`, web UI `http://192.168.4.205:8080`, config `/etc/pve-usv/config.yaml`). It is not NUT itself. It reads the CyberPower UPS from the NUT server at `192.168.4.141:3493`, UPS name `cyberpower`, no login (the UPS's USB cable goes to that box). Settings: UPS device Read via NUT with those values; Notifications → webhook format ntfy, URL `https://ntfy.sh/homelab1-alerts-3d1ef2b124a1`, severity warning and above. The ntfy webhook is only set here, not on plex-proxmox's PVE-UPS (which reads the same UPS), to avoid double alerts.

### ntfy alerts: Tdarr, Plex/Tautulli, Immich, Unraid, OPNsense

Added 2026-11-11 (second batch). Same topic `homelab1-alerts-3d1ef2b124a1`. Failures use priority 4-5 (sound). Activity pings (Plex stream starts, Tdarr queue empty) use priority 2, which shows in the app without sound or buzz.

**Tdarr and Immich (poller on the Proxmox host).** Neither app can push to ntfy itself, so a cron job on the host reads their APIs every 10 minutes and pings when the failed count goes up (Tdarr transcode errors, Immich failed jobs) or the Tdarr queue drops to 0.

1. API keys. Tdarr: Tools → API Keys → create one. Immich: account menu → Account Settings → API Keys → new key for admin `krusnix`, name `ntfy-checks`, with only `job.read` (and `queue.read` if listed) ticked.
2. Check the APIs answer before installing (both should print JSON):

   ```bash
   apt install -y jq
   curl -s -H "x-api-key: <tdarr key>" -H 'Content-Type: application/json' \
     -d '{"data":{"collection":"StatisticsJSONDB","mode":"getById","docID":"statistics"}}' \
     http://192.168.4.127:8265/api/v2/cruddb | jq '{table1Count, table3Count}'
   curl -s -H "x-api-key: <immich key>" http://192.168.4.163:2283/api/queues | jq '[.. | .failed? | numbers] | add'
   # if /api/queues gives 404, try /api/jobs
   # Checked 2026-11-11: Tdarr returned table1Count 1606 / table3Count 69, Immich /api/queues returned 52 failed.
   ```

3. Keys go in `/root/.ntfy-checks.env` (`chmod 600`):

   ```bash
   TDARR_KEY=...
   IMMICH_KEY=...
   ```

4. Script `/usr/local/bin/ntfy-app-checks.sh` (`chmod 755`):

   ```bash
   #!/bin/bash
   # Polls Tdarr and Immich and pings ntfy when failures rise or the Tdarr queue empties.
   set -u
   . /root/.ntfy-checks.env
   NTFY=https://ntfy.sh/homelab1-alerts-3d1ef2b124a1
   STATE=/var/lib/ntfy-checks; mkdir -p "$STATE"
   LOG=/var/log/ntfy-checks.log

   notify() {  # notify <priority> <tags> <title> <message>
     curl -fsS -m 20 -H "Priority: $1" -H "Tags: $2" -H "Title: $3" -d "$4" "$NTFY" >/dev/null \
       || echo "$(date '+%F %T') ntfy send failed: $3" >> "$LOG"
   }
   # compare <name> <new value>: prints the old value and saves the new one
   swap() { local f="$STATE/$1" old; old=$(cat "$f" 2>/dev/null || echo "$2"); echo "$2" > "$f"; echo "$old"; }

   # Tdarr: table1Count = transcode queue, table3Count = transcode errors
   if t=$(curl -fsS -m 20 -H "x-api-key: $TDARR_KEY" -H 'Content-Type: application/json' \
       -d '{"data":{"collection":"StatisticsJSONDB","mode":"getById","docID":"statistics"}}' \
       http://192.168.4.127:8265/api/v2/cruddb); then
     q=$(jq -r '.table1Count // empty' <<<"$t"); e=$(jq -r '.table3Count // empty' <<<"$t")
     if [ -n "$e" ]; then old=$(swap tdarr_errors "$e")
       [ "$e" -gt "$old" ] && notify 4 warning "Tdarr: $((e-old)) transcode(s) failed" \
         "Error/cancelled count is now $e. Check http://192.168.4.127:8265 (Transcode: Error/Cancelled tab)."
     fi
     if [ -n "$q" ]; then old=$(swap tdarr_queue "$q")
       [ "$q" -eq 0 ] && [ "$old" -gt 0 ] && notify 2 white_check_mark "Tdarr queue empty" "All queued transcodes are done."
     fi
   else echo "$(date '+%F %T') Tdarr API unreachable" >> "$LOG"   # Uptime Kuma alerts on Tdarr down
   fi

   # Immich: sum of failed jobs across all queues (/api/queues on new versions, /api/jobs on old)
   for path in queues jobs; do
     i=$(curl -fsS -m 20 -H "x-api-key: $IMMICH_KEY" "http://192.168.4.163:2283/api/$path") && break
   done
   f=$(jq -r '[.. | .failed? | numbers] | add // empty' <<<"${i:-null}" 2>/dev/null)
   if [ -n "$f" ]; then old=$(swap immich_failed "$f")
     [ "$f" -gt "$old" ] && notify 4 warning "Immich: $((f-old)) job(s) failed" \
       "Failed jobs now $f. Check Administration → Job Queues at http://192.168.4.163:2283."
   else echo "$(date '+%F %T') Immich API unreachable or no counts" >> "$LOG"
   fi
   ```

5. Cron: `echo '*/10 * * * * root /usr/local/bin/ntfy-app-checks.sh' > /etc/cron.d/ntfy-app-checks`. Run it once by hand: the first run only records the counts and sends nothing. `/var/log/ntfy-checks.log` should stay empty.

Clearing failed jobs in either app lowers the count, which doesn't alert; the next failure after that does.

**Plex via Tautulli (CT 106).** Tautulli's built-in **ntfy** agent (Settings → Notification Agents → Add → ntfy). Priority is per agent, so there are two:

- Agent 1 (outages): host `https://ntfy.sh`, no token, topic `homelab1-alerts-3d1ef2b124a1`, priority 5. Triggers: Plex Server Down, Plex Server Back Up, Plex Remote Access Down, Plex Remote Access Back Up.
- Agent 2 (streams): Duplicate of agent 1 with priority 2 and only the Playback Start trigger.
- Default text per trigger is kept. Test with the agent's Test Notifications tab.

**Unraid (192.168.5.14).** Settings → Notification Settings:

- Turn on array status notifications and "Notification entity → Agents" for Warnings and Alerts (not Notices, which include every finished parity check and update).
- Agent: the built-in **ntfy.sh** agent (Unraid 7.x). URL `https://ntfy.sh`, topic `homelab1-alerts-3d1ef2b124a1`, title Subject, message Description + Content. The token field is required, so Trent made a free ntfy.sh account and uses its access token (`tk_...`); the topic is still public, so other senders need no token. Set up and tested 2026-11-11.
- Disk temperature thresholds are in Settings → Disk Settings (warning/critical per disk type). SMART and parity errors arrive as warnings/alerts on their own.
- Test: Settings → Notification Settings → Test, or on the Unraid shell `/usr/local/emhttp/webGui/scripts/notify -i warning -s "test" -d "ntfy test"`.

**OPNsense (192.168.4.1): main WAN down / back up.** OPNsense's Monit can only email, so it runs scripts that curl ntfy. Gateways: `WAN_DHCP` (main, monitor 1.1.1.1), `WAN_DHCP6`, `WAN2_DHCP` (Verizon Home Internet backup, normally down: the plan only allows seven manually started 24-hour sessions a month), `PROTON_GW` (VPN). Because WAN2 is normally down, the stock `gateway_alert.php` check (now at `/usr/local/opnsense/scripts/monit/gateway_alert.php`; the old `scripts/OPNsense/Monit/` path makes Monit fail to reload) stays failed forever and never alerts, so a custom check watches `WAN_DHCP` only. Don't disable WAN2 gateway monitoring: the failover groups need it.

1. In the OPNsense shell (`sh`), `/root/ntfy-alert.sh`, `chmod 755`. Use the full path to curl: Monit runs scripts with a minimal PATH that lacks `/usr/local/bin`.

   ```sh
   #!/bin/sh
   # Sends an ntfy ping. Called by Monit (sets MONIT_SERVICE, MONIT_EVENT, MONIT_DESCRIPTION).
   # Retries for up to an hour, since ntfy.sh is unreachable while the WAN is down.
   (
   i=0
   while [ $i -lt 120 ]; do
     /usr/local/bin/curl -fsS -m 20 -H "Title: OPNsense: ${MONIT_SERVICE} ${MONIT_EVENT}" -H "Priority: 5" \
       -H "Tags: globe_with_meridians" -d "${MONIT_DESCRIPTION} (at $(date '+%F %T'))" \
       https://ntfy.sh/homelab1-alerts-3d1ef2b124a1 >/dev/null && exit 0
     i=$((i+1)); sleep 30
   done
   ) >/dev/null 2>&1 &
   ```

2. `/root/wan-check.sh`, `chmod 755`:

   ```sh
   #!/bin/sh
   # Monit check: exit 1 only when the main WAN (WAN_DHCP) is down. Ignores WAN2 and the VPN.
   # Sends its own "back up" ping the first time WAN is OK after an outage.
   FLAG=/var/run/wan-check.down
   out=$(/usr/local/sbin/pluginctl -r return_gateways_status | /usr/local/bin/python3 -c '
   import json, sys
   g = json.load(sys.stdin)["dpinger"].get("WAN_DHCP", {})
   s = g.get("status", "missing")
   print("WAN_DHCP status=%s loss=%s delay=%s" % (s, g.get("loss"), g.get("delay")))
   sys.exit(1 if s in ("down", "force_down", "missing") else 0)
   ')
   rc=$?
   echo "$out"
   if [ $rc -ne 0 ]; then
     touch "$FLAG"
   elif [ -f "$FLAG" ]; then
     rm -f "$FLAG"
     MONIT_SERVICE=WAN MONIT_EVENT="back up" MONIT_DESCRIPTION="$out" /root/ntfy-alert.sh
   fi
   exit $rc
   ```

3. Services → Monit → General Settings: enable Monit (polling 60s). No mail server needed.
4. Service Tests Settings → test `GatewayAlert`: Condition `status != 0`, Action `Execute`, Path `/root/ntfy-alert.sh`.
5. Service Settings → built-in `Gateway_Alert` entry: Enable service checks, Type Custom, Path `/root/wan-check.sh`, Tests `GatewayAlert`. Delete the lowercase duplicate `gateway_alert`. Apply, then `monit -t -c /usr/local/etc/monitrc` → "Control file syntax OK"; `monit status Gateway_Alert` shows the last output.
6. Test: System → Gateways → Configuration → WAN_DHCP → "Mark Gateway as Down", save/apply, wait for the ping; untick for the "back up" ping. Both tested OK 2026-11-11.

Firmware updates are manual on OPNsense (System → Firmware), so there's nothing to alert on there. Uptime Kuma already pings OPNsense's LAN address.

### ntfy alerts: disk space, NVMe health, updates

Added 2026-11-12 (third batch). Same topic `homelab1-alerts-3d1ef2b124a1`. Both scripts run on the host from cron and log ntfy send failures to `/var/log/ntfy-checks.log`. A paste-ready installer is in the project files at `ntfy-disk-updates/install.sh`.

**What was already covered.** smartd runs on the host with the Debian default `DEVICESCAN ... -m root -M exec /usr/share/smartmontools/smartd-runner`, so a SMART failure mails root. Root's mail goes through `proxmox-mail-forward` into the notification system as `type=system-mail`, which the `ntfy-problems` matcher sends to ntfy. Beszel alerts at Disk > 85% for the host root and the rootfs of CT 103/104/105 only.

To re-test the smartd path (should give one ping titled with the smartd test message):

```bash
systemctl is-active smartd; grep -v '^\s*#' /etc/smartd.conf | grep .
sed -i 's/^DEVICESCAN/& -M test/' /etc/smartd.conf && systemctl restart smartd
# wait for the ping, then undo:
sed -i 's/ -M test//' /etc/smartd.conf && systemctl restart smartd
```

**Disk space and NVMe health, hourly:** `/usr/local/bin/ntfy-disk-checks.sh`, cron `/etc/cron.d/ntfy-disk-checks` (`17 * * * *`). It alerts (priority 4) once when something reaches 85% and sends a quiet "Disk OK" (priority 2) when it drops back. State files are in `/var/lib/ntfy-checks/disk/` (one file per item that is over the limit). It checks:

- Host filesystems from `df` (`/`, `/mnt/backup-local`, `/boot/efi`). The SMB shares are skipped (Unraid and the TerraMaster alert on their own).
- LVM thin pools, data and metadata (`pve/data` is local-lvm, which nothing else watches). A full thin pool corrupts every CT on it, so treat this alert as urgent.
- Every running CT's own disks via `pct exec <id> -- df` (rootfs and disks like CT 104 `/tdarr_cache`). CT 103/104/105 rootfs overlap with Beszel, so those can ping twice.
- The NVMe: SMART failed or `critical_warning` set (priority 5), new media errors (priority 5), and wear (`percentage_used`) at 80%.

**Updates waiting, weekly:** `/usr/local/bin/ntfy-update-checks.sh`, cron `/etc/cron.d/ntfy-update-checks` (Sundays 09:00, host time America/Chicago). It runs `apt-get update` on the host and in every running CT (or `apk` on Alpine), counts what `dist-upgrade` would install, and sends one ping listing each machine with updates. Priority 3, or 4 if any are security updates. It sends nothing when everything is current, and lists stopped CTs as not checked.

- If a CT has NVIDIA package updates, the ping says so. The CT drivers must stay at the host's version (620.70.06), so hold those packages (`apt-mark hold <pkg>`) rather than upgrading. CT 104's are already held.
- It only sees apt/apk packages (Plex comes from Plex's apt repo, so it's covered). Apps the helper scripts installed outside apt (Tdarr, Immich, Tunarr, Kometa, Tautulli, Beszel, Uptime Kuma) don't show up; update those with `update` in the CT console.
- Proxmox's own daily "package updates available" notice is severity info, so it still goes to mail only.

```bash
# /usr/local/bin/ntfy-disk-checks.sh
#!/bin/bash
# Hourly: pings ntfy when a filesystem, thin pool or CT disk passes 85%,
# or the NVMe reports a critical warning, new media errors or heavy wear.
# Each problem alerts once when it starts and once when it clears.
set -u
NTFY=https://ntfy.sh/homelab1-alerts-3d1ef2b124a1
LIMIT=85        # % full
WEAR_LIMIT=80   # NVMe "percentage used" (rated endurance)
STATE=/var/lib/ntfy-checks/disk; mkdir -p "$STATE"
LOG=/var/log/ntfy-checks.log
DF_SKIP="-x tmpfs -x devtmpfs -x cifs -x smb3 -x nfs -x nfs4 -x fuse -x fuse.lxcfs -x overlay -x squashfs -x efivarfs"

notify() {  # notify <priority> <tags> <title> <message>
  curl -fsS -m 20 -H "Priority: $1" -H "Tags: $2" -H "Title: $3" -d "$4" "$NTFY" >/dev/null \
    || echo "$(date '+%F %T') ntfy send failed: $3" >> "$LOG"
}
# flag <key> <0|1> <title if bad> <message if bad> <title when cleared>
flag() {
  local f="$STATE/$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
  if [ "$2" -eq 1 ]; then
    [ -e "$f" ] || { touch "$f"; notify 4 warning "$3" "$4"; }
  elif [ -e "$f" ]; then
    rm -f "$f"; notify 2 white_check_mark "$5" "Back under the limit."
  fi
}
pct_check() {  # pct_check <key> <percent> <label>
  local p=${2%%[.%]*}; [ -n "$p" ] || return
  [ -t 1 ] && printf '%4s%%  %s\n' "$p" "$3"   # table when run by hand
  flag "$1" $([ "$p" -ge "$LIMIT" ] && echo 1 || echo 0) \
    "Disk ${p}% full: $3" "$3 is at ${p}% (alert limit ${LIMIT}%)." "Disk OK: $3"
}
df_rows() { tail -n +2 | awk '{print $5, $6}'; }

# Host filesystems (/, /mnt/backup-local, /boot/efi ...). SMB shares are skipped.
df -P $DF_SKIP 2>/dev/null | df_rows | while read -r p m; do
  pct_check "host$m" "$p" "host $m"
done

# LVM thin pools (local-lvm = pve/data): data and metadata
lvs --noheadings --nosuffix -o vg_name,lv_name,data_percent,metadata_percent -S 'lv_attr=~^t' 2>/dev/null |
while read -r vg lv d md; do
  pct_check "thin-$vg-$lv-data" "$d" "thin pool $vg/$lv (data)"
  pct_check "thin-$vg-$lv-meta" "$md" "thin pool $vg/$lv (metadata)"
done

# Every running CT's own disks (rootfs and mpX like /tdarr_cache). Bind-mounted shares are skipped.
for id in $(pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1}'); do
  name=$(pct config "$id" | awk '/^hostname:/ {print $2}')
  timeout 60 pct exec "$id" -- df -P $DF_SKIP 2>/dev/null | df_rows | while read -r p m; do
    pct_check "ct$id$m" "$p" "CT $id $name $m"
  done
done

# NVMe health (smartd also mails on SMART failure; this adds wear and media errors)
for dev in $(ls /dev/nvme* 2>/dev/null | grep -E '^/dev/nvme[0-9]+$'); do
  j=$(smartctl -j -H -A "$dev" 2>/dev/null)
  h=$(jq -c '.nvme_smart_health_information_log // empty' <<<"$j" 2>/dev/null)
  if [ -z "$h" ]; then echo "$(date '+%F %T') smartctl read failed on $dev" >> "$LOG"; continue; fi
  cw=$(jq -r '.critical_warning // 0' <<<"$h"); used=$(jq -r '.percentage_used // 0' <<<"$h")
  me=$(jq -r '.media_errors // 0' <<<"$h");     ok=$(jq -r '.smart_status.passed // true' <<<"$j")
  k=$(basename "$dev")
  bad=0; { [ "$cw" != 0 ] || [ "$ok" = false ]; } && bad=1
  [ "$bad" = 1 ] && [ ! -e "$STATE/$k-health" ] && notify 5 rotating_light "NVMe $dev health FAILING" \
    "critical_warning=$cw, SMART passed=$ok. Run: smartctl -a $dev. Check backups are current."
  if [ "$bad" = 1 ]; then touch "$STATE/$k-health"; else rm -f "$STATE/$k-health"; fi
  flag "$k-wear" $([ "$used" -ge "$WEAR_LIMIT" ] && echo 1 || echo 0) \
    "NVMe $dev wear ${used}%" "$dev has used ${used}% of its rated endurance. Plan a replacement." "NVMe wear OK"
  old=$(cat "$STATE/$k-media_errors" 2>/dev/null || echo "$me"); echo "$me" > "$STATE/$k-media_errors"
  [ "$me" -gt "$old" ] && notify 5 rotating_light "NVMe $dev: $((me-old)) new media error(s)" \
    "Media/data integrity errors now $me. Run: smartctl -a $dev"
done
exit 0
```

```bash
# /usr/local/bin/ntfy-update-checks.sh
#!/bin/bash
# Weekly: refreshes package lists on the host and every running CT and pings ntfy
# with what has updates waiting. Only covers apt/apk packages, not apps the
# helper scripts installed outside apt (use each CT's `update` command for those).
set -u
NTFY=https://ntfy.sh/homelab1-alerts-3d1ef2b124a1
LOG=/var/log/ntfy-checks.log

# Prints "<updates> <security> <nvidia>" or "ERR <reason>". Plain sh so it runs in any CT.
CHECK='if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq >/dev/null 2>&1 || { echo "ERR apt update failed"; exit 0; }
  s=$(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | grep "^Inst ")
  echo "$(printf "%s" "$s" | grep -c .) $(printf "%s" "$s" | grep -ci security) $(printf "%s" "$s" | grep -ci nvidia)"
elif command -v apk >/dev/null 2>&1; then
  apk update -q >/dev/null 2>&1 || { echo "ERR apk update failed"; exit 0; }
  echo "$(apk version -l "<" 2>/dev/null | tail -n +2 | grep -c .) 0 0"
else echo "ERR no apt or apk"; fi'

total=0; sec=0; err=0; lines=""; warn=""
add() {  # add <label> <output of CHECK>
  set -- "$1" $2
  if [ "$2" = ERR ]; then err=1; lines+="$1: ${*:3}"$'\n'; return; fi
  [ "${2:-0}" -gt 0 ] 2>/dev/null || return
  total=$((total+$2)); sec=$((sec+$3))
  lines+="$1: $2$([ "$3" -gt 0 ] && echo " ($3 security)")"$'\n'
  [ "$4" -gt 0 ] && warn+="$1 has NVIDIA package updates: the driver must stay 620.70.06 to match the host, so hold them (apt-mark hold) instead of upgrading."$'\n'
}

add "host" "$(timeout 600 sh -c "$CHECK")"
for id in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
  name=$(pct config "$id" | awk '/^hostname:/ {print $2}')
  if [ "$(pct status "$id" | awk '{print $2}')" != running ]; then lines+="CT $id $name: not checked (stopped)"$'\n'; continue; fi
  add "CT $id $name" "$(timeout 600 pct exec "$id" -- sh -c "$CHECK" 2>/dev/null || echo 'ERR no answer')"
done

[ "$total" -gt 0 ] || [ "$err" = 1 ] || exit 0     # nothing waiting and no errors: stay quiet
prio=3; [ "$sec" -gt 0 ] && prio=4; [ -n "$warn" ] && prio=4
msg="$lines${warn:+$'\n'$warn}
Host: Datacenter -> homelab1-proxmox -> Updates (or apt update && apt dist-upgrade). CTs: run update in each CT's console."
curl -fsS -m 20 -H "Priority: $prio" -H "Tags: package" -H "Title: Updates waiting: $total package(s), $sec security" \
  -d "$msg" "$NTFY" >/dev/null || echo "$(date '+%F %T') ntfy send failed: weekly updates" >> "$LOG"
```

Install: save both with `chmod 755`, then

```bash
echo '17 * * * * root /usr/local/bin/ntfy-disk-checks.sh' > /etc/cron.d/ntfy-disk-checks
echo '0 9 * * 0 root /usr/local/bin/ntfy-update-checks.sh' > /etc/cron.d/ntfy-update-checks
```

Run each once by hand. Run from a terminal, the disk script prints every item it checked with its %. To test the send path with one quiet ping: `touch /var/lib/ntfy-checks/disk/host_ && /usr/local/bin/ntfy-disk-checks.sh` should give "Disk OK: host /".

Installed and tested 2026-11-12: first disk run showed everything under 85% (highest CT 105 Immich at 74%), the update check found nothing waiting, and both the "Disk OK" test and the smartd `-M test` ping arrived on the phone.
