# homelab1-proxmox rebuild runbook

Last updated 2026-11-13. Covers the Proxmox host rebuilt on 2026-11-08 and the LXCs on it.

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

Because of `uid=100000`, every file on these mounts is owned by root inside the CTs. Service users can create and write files through `nasshare`, but they can't set a file's timestamps (`utime` → `EPERM`), because Linux only lets a file's owner do that. Apps that need to set timestamps need their own mount owned by their user (see CT 105 Immich below).

The SMB password for `krusnix` lives in `/etc/pve/priv/storage/unraid-data.pw` (one line). If the Unraid password changes, the running mount keeps working until the next reboot or remount, then fails. Save the new password with `pvesm set unraid-data --username krusnix --password`. Without `--username`, it says "ignoring password parameter" but still overwrites the file. Or write the file directly, then check it with `smbclient //192.168.5.14/data -U krusnix --password="$(cat /etc/pve/priv/storage/unraid-data.pw)" -m SMB3 -c ls`. Updated 2026-11-13 after the password had been changed on Unraid.

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

# Added 2026-11-13: skip Plex's rebuildable previews and cache (paths only exist in CT 103).
pvesh set /cluster/backup/nightly-cts \
  --exclude-path "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Media/?*" \
  --exclude-path "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Cache/?*"
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
| 111 | homepage | 192.168.4.126:3000 (DHCP reserved) | Homepage dashboard: every service on both hosts and unraid-1 |
| 112 | grafana | 192.168.4.232:3000 (DHCP reserved) | Grafana + Prometheus: graphs and 30 days of history |
| 113 | npm | 192.168.4.156:81 (DHCP reserved) | Nginx Proxy Manager: `https://<name>.krusnix.net` for every web UI, LAN + Tailscale only |

### CT 102 Pi-hole and nebula-sync

- One of 4 Pi-holes (.145, .48, .5.53 on Unraid as docker `pihole-v6-unbound`, .141), all v6 with Unbound on `127.0.0.1#5335`.
- nebula-sync 0.11.3 (installed 2026-11-10) runs in CT 102 hourly and pushes to the other three. Config: `/etc/nebula-sync.env`. It uses selective sync with every section on **except the web server** (full mode would move .141's UI to port 80, where Apache runs). It excludes `misc.dnsmasq_lines` (the API can't write it) and `dns.dnssec` (missing on .141's older build). `CLIENT_SKIP_TLS_VERIFICATION=true` for .141's self-signed cert. Logs: `journalctl -u nebula-sync`.
- **plex.direct:** Unbound's `private-address` rules blank `*.plex.direct` answers, which breaks Plex sign-in for apps like Tunarr. Each Pi-hole has `misc.dnsmasq_lines` = `server=/plex.direct/1.1.1.1`, `server=/plex.direct/9.9.9.9`, set by hand on each (`pihole-FTL --config misc.dnsmasq_lines '[...]'`; on Unraid via the `FTLCONF_misc_dnsmasq_lines` template variable, `;`-separated). A rebuilt Pi-hole needs it again.
- Teleporter backups of all four from 2026-11-10: `/root/pihole-backups-2026-11-10/` in CT 102.

### CT 103 Plex

- 82 GB disk (grown from 32 GB on 2026-11-13 with `pct resize 103 rootfs +50G`, then `pct fstrim 103`). `mp0` unraid-data → `/unraid`, `mp1` nas-public → `/nas`. `plex` user in `nasshare`.
- Both GPUs passed through; NVIDIA 620.70.06 userspace installed with `--no-kernel-module`.
- Analysis settings kept on purpose (2026-11-13): video previews, chapter thumbnails, loudness, ad markers and voice activity on "as soon as possible"; intro/credits on the default (scheduled). ~92% of the library is AV1, so previews come in at ~25 files (~300 MiB) a day; the full library would need ~100–170 GiB. 82 GB leaves ~63 GB free, roughly 200 days. Check `df -h /` in CT 103 now and then (the hourly ntfy disk check alerts at 85%); grow again in steps, since a CT disk can't be shrunk.
- Nightly backup skips Plex's `Media/` (previews) and `Cache/` (see Backups), which cut CT 103's backup from 10.5 to 7.3 GB. After a restore, Plex regenerates previews.
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
mp1: /mnt/immich-data,mp=/immich-data   # own CIFS mount owned by immich, added 2026-11-13
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
5. Storage layout. `/opt/immich/.env` keeps `IMMICH_MEDIA_LOCATION=/opt/immich/upload`. Inside it, `library`, `upload`, `profile` and `backups` are symlinks to `/immich-data/<same name>` (each folder needs its `.immich` marker file). `thumbs` and `encoded-video` stay on local disk.
   - `/immich-data` is a separate host CIFS mount of the same Unraid folder (`/unraid/media/pictures/immich`), owned by host uid **100999** (= `immich`, uid 999 in the CT). Immich sets each uploaded file's date with `utime`, which only the owner can do. On the shared `/unraid` mount (owned by root) every phone upload failed with `EPERM: operation not permitted, utime` in `/var/log/immich/web.log`, and the app showed "Failed to upload asset". Fixed 2026-11-13.
   - Host `/etc/fstab` line (credentials file `/root/.smb-unraid-immich`, mode 600, with `username=krusnix` and `password=...` lines copied from `/etc/pve/priv/storage/unraid-data.pw`):

     ```
     //192.168.5.14/data/media/pictures/immich /mnt/immich-data cifs credentials=/root/.smb-unraid-immich,vers=3.1.1,uid=100999,forceuid,gid=110000,forcegid,file_mode=0775,dir_mode=0775,soft,nounix,_netdev,nofail 0 0
     ```

   - Then `mount /mnt/immich-data`, `pct stop 105`, `pct set 105 -mp1 /mnt/immich-data,mp=/immich-data`, `pct start 105`, and `ln -sfn /immich-data/<name> /opt/immich/upload/<name>` for the four folders. Test as immich: `touch -d 2020-01-01 /opt/immich/upload/upload/.t` must succeed. The whole fix is scripted in `fix-upload-mount.sh` (project files `immich-uploads/`).
   - If the Unraid password changes, update `/root/.smb-unraid-immich` too.
   - After running the helper script's `update`, check `ls -l /opt/immich/upload/` in the CT. If the four symlinks point back at `/unraid/...`, uploads will fail the same way again.
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

### CT 111 Homepage dashboard

Added 2026-11-12. One page at `http://192.168.4.126:3000` with a tile for every service on homelab1-proxmox, plex-proxmox, unraid-1 (including its Docker containers), the Pi-holes, OPNsense, the NAS boxes, the UPS and ntfy. Tiles open each web UI in a new tab at its `https://<name>.krusnix.net` address (since 2026-11-13, via CT 113; status checks and widgets still use the IPs, so they keep working if the proxy is down), show a status dot, and most show live numbers.

- **Install:** helper script `ct/homepage.sh`, defaults (Debian 13, 2 cores, 4 GB, 6 GB disk), hostname `homepage`, DHCP reserved in OPNsense at .126.
- **Config:** run [`homepage/setup-homelab1.sh`](homepage/setup-homelab1.sh) on homelab1-proxmox as root. It writes `/opt/homepage/config/*.yaml` in the CT (services, settings, widgets, bookmarks, docker), creates the read-only API token `homepage@pve!dashboard` (PVEAuditor), and copies the Plex token (CT 103), Tautulli key (CT 106), Tdarr key (`/root/.ntfy-checks.env`) and Pi-hole passwords (nebula-sync env in CT 102). Re-running it rewrites the config, replaces the token and keeps the other keys. To change the layout, edit the script here and re-run it rather than editing the CT by hand.
- **plex-proxmox:** run [`homepage/setup-plex-proxmox.sh`](homepage/setup-plex-proxmox.sh) there (192.168.4.215, node `plex-proxmox`). It adds the same read-only token and prints `homepage-setvar` lines to paste into the Homepage CT (host IP, token, plex-server Plex token, Tautulli .198 key).
- **Keys:** stored as `HOMEPAGE_VAR_*` in `/etc/homepage/vars.env` in the CT, loaded by the drop-in `/etc/systemd/system/homepage.service.d/vars.conf`. That's outside `/opt/homepage`, so the helper's `update` keeps them. Set with `homepage-setvar NAME 'value'`, apply with `homepage-setvar --restart`, list gaps with `homepage-setvar --missing`. Keys made by hand: Immich (`server.statistics` only), OPNsense (user `homepage`, privileges Diagnostics: System Activity + Reporting: Traffic), Unraid (VIEWER role), Beszel login. Uptime Kuma reads its status page with slug `homelab`.
- **UPS tile:** reads PVE-UPS's public `http://192.168.4.205:8080/api/status` (battery, load, runtime, power source).
- **unraid-1 Docker:** Unraid runs the `socket-proxy` container (`wollomatic/socket-proxy`), host port 2375, Allowed Clients `192.168.4.126`, Allow GET `(/v1\..{1,2})?/(_ping|version|info|containers/json|containers/[^/]+/(json|stats))`, Allow HEAD `(/v1\..{1,2})?/_ping`, POST empty (read-only). Homepage's `docker.yaml` calls that server `unraid-1`; tiles use the container names exactly as Docker shows them.
- If the Homepage IP ever changes, update the socket-proxy Allowed Clients and `HOMEPAGE_ALLOWED_HOSTS` in `/opt/homepage/.env`.

### CT 112 Grafana and Prometheus

Added 2026-11-13. Grafana at `http://192.168.4.232:3000` graphs both Proxmox hosts, the NVIDIA GPU, the Intel iGPU, the UPS, the four Pi-holes, OPNsense, unraid-1 (host and Docker containers) and Plex streams on all three Plex servers. Prometheus in the same CT (`http://192.168.4.232:9090/targets`) scrapes every 30 s and keeps 30 days. Dashboards only: alerts stay with ntfy, Beszel and Uptime Kuma.

- **Install:** helper script `ct/grafana.sh`, Advanced: CT 112, hostname `grafana`, 2 cores, 4 GB, 20 GB disk, DHCP. MAC `BC:24:11:50:53:A5`, reserved in OPNsense at .232 (the plex-proxmox firewall rule depends on this address). First login `admin` / `admin`.
- **Config:** run [`grafana/setup-homelab1.sh`](grafana/setup-homelab1.sh) on homelab1-proxmox as root. Safe to re-run. It:
  - installs `prometheus-node-exporter` (:9100) and `nvidia_gpu_exporter` (:9835, `/usr/local/bin`, unit `nvidia_gpu_exporter.service`) on the host;
  - installs `intel-gpu-tools` and `/usr/local/bin/intel-gpu-textfile` (unit `intel-gpu-textfile.service`) on the host: it runs `intel_gpu_top -J` and writes `intel_gpu_*` metrics to `/var/lib/prometheus/node-exporter/intel_gpu.prom`, which node exporter serves;
  - creates the read-only API token `prometheus@pve!metrics` (PVEAuditor) and replaces it on each run;
  - in the CT: Prometheus from apt, `prometheus-pve-exporter` in the venv `/opt/pve-exporter` (127.0.0.1:9221, reads both hosts), `nut_exporter` (127.0.0.1:9199, NUT server 192.168.4.141, ups `cyberpower`) `pihole_exporter` (127.0.0.1:9617, all four Pi-holes, passwords copied from the nebula-sync env in CT 102) and `/usr/local/bin/tautulli-exporter` (127.0.0.1:9487, a small Python script that reads `get_activity` from each Tautulli in `/etc/tautulli-exporter.conf`; the homelab1 key comes from CT 106 and the plex-proxmox key from Homepage's `/etc/homepage/vars.env` in CT 111);
  - provisions the Prometheus data source (uid `prometheus`) and the grafana.com dashboards 1860 Node Exporter Full (the two Proxmox hosts), 4260 Node Exporter BSD (OPNsense: it is FreeBSD, so 1860 shows no memory data for it), 10347 Proxmox via Prometheus, 14574 Nvidia GPU Metrics, 19308 NUT, 10176 Pi-hole Exporter and 14282 cAdvisor (unraid-1 containers), plus three hand-made dashboards the script generates, **Homelab Overview** (one screen: sources down, UPS, Plex streams, internet traffic, host CPU/memory/disk, both GPUs, Pi-holes, busiest CTs and Unraid containers), **Plex Streams** and **Intel iGPU**, into the folder **Homelab**. It then lists any overview query that returns no data;
  - prints which targets are up.
- **plex-proxmox:** run [`grafana/setup-plex-proxmox.sh`](grafana/setup-plex-proxmox.sh) there. It installs node exporter, allows 192.168.4.232 to reach port 9100 (the Proxmox firewall is enabled on that host; the rule is under plex-proxmox → Firewall), adds the same token and prints a `pct exec 112 -- /usr/local/bin/pve-exporter-conf plex '<token>'` line to paste on homelab1-proxmox.
- **unraid-1 (192.168.5.14):** two things on Unraid, then it shows in Node Exporter Full as `unraid-1` and in the cAdvisor dashboard.
  - Apps → install the **Prometheus Node Exporter** plugin (ich777). It listens on :9100.
  - cAdvisor for per-container numbers, from the Unraid terminal (host port 9180):
    ```bash
    docker run -d --name=cadvisor --restart=unless-stopped -p 9180:8080 --privileged --device=/dev/kmsg \
      -v /:/rootfs:ro -v /var/run:/var/run:ro -v /sys:/sys:ro -v /var/lib/docker/:/var/lib/docker:ro -v /dev/disk/:/dev/disk:ro \
      gcr.io/cadvisor/cadvisor:v0.49.1 --docker_only=true --housekeeping_interval=30s
    ```
  - Unraid's Tautulli: `pct exec 112 -- /usr/local/bin/tautulli-exporter-add unraid-1 http://192.168.5.14:8181 '<API key>'` on homelab1-proxmox . Read the key from Unraid with `grep api_key /mnt/user/appdata/tautulli/config.ini` (a key copied from the web page was rejected once). The script keeps it on re-runs.
- **OPNsense:** System → Firmware → Plugins → install `os-node_exporter`, then Services → Prometheus Exporter: Enabled, listen address `192.168.4.1`, port `9100`, tick CPU, Execution, Filesystem, Load Average, Memory, Network Interface, Current Time and Device Statistics (Interrupts, NTP and ZFS off), Save.
- **Files in the CT:** `/etc/prometheus/prometheus.yml` (targets), `/etc/default/prometheus` (retention), `/etc/prometheus/pve-tokens.env` (both API tokens; `pve-exporter-conf` rebuilds `pve.yml` from it), `/etc/pihole-exporter.env` (Pi-hole passwords), `/etc/tautulli-exporter.conf` (Tautulli `name|url|key` lines), `/var/lib/grafana/dashboards/*.json`, `/etc/grafana/provisioning/{datasources/prometheus.yml,dashboards/homelab.yml}`. Services: `prometheus`, `pve-exporter`, `nut-exporter`, `pihole-exporter`, `tautulli-exporter`, `grafana-server`.
- **Updates:** the helper's `update` covers Grafana and apt covers Prometheus. The three exporters are fixed at the version the script downloaded; re-run the script to pull the latest.
- **Homepage:** Grafana tile in the Monitoring group, showing Prometheus targets up/down.
- If a Pi-hole password changes, re-run the script (it reads them from nebula-sync again).

### CT 113 Nginx Proxy Manager (reverse proxy, `*.krusnix.net`)

Added 2026-11-13. Every web UI on homelab1, plex-proxmox, unraid-1 and the network gear has an HTTPS name such as `https://immich.krusnix.net`, `https://pve.krusnix.net` or `https://sonarr.krusnix.net`, with a real Let's Encrypt wildcard certificate. **LAN and Tailscale only:** no port forwards and no public DNS records. The Pi-holes answer the names (tailnet DNS already points at Pi-hole .145, and OPNsense routes 192.168.4.0/23 to the tailnet). The full name → app list is at the top of [`reverse-proxy/setup-proxy.sh`](reverse-proxy/setup-proxy.sh).

- **Domain:** `krusnix.net`, registered at Cloudflare Registrar (renews about $11/yr). Cloudflare is only the DNS host for the certificate challenge; the zone has no records.
- **Cloudflare API token:** `npm-homelab1` (My Profile → API Tokens), Zone → DNS → Edit on krusnix.net only, no expiry, no IP filter. NPM uses it to renew. The token itself is in Trent's password manager and in NPM; it is not stored here.
- **Install:** helper script `ct/nginxproxymanager.sh`, Advanced: CT 113, hostname `npm`, defaults, DHCP. Reserved in OPNsense at .156 (the Pi-hole records point at this address). Admin UI `http://192.168.4.156:81` (v2.17.0 at install); first login creates the admin user.
- **Certificate:** Certificates → Add Certificate → Let's Encrypt via DNS: `krusnix.net` + `*.krusnix.net`, ECDSA 256, provider Cloudflare, credentials `dns_cloudflare_api_token = <token>`. Auto-renews every ~60 days (first one valid to 2027-02-11).
- **Names:** on homelab1-proxmox, run
  ```bash
  DOMAIN=krusnix.net NPM_IP=192.168.4.156 NPM_USER='<npm login>' NPM_PASS='<npm password>' bash setup-proxy.sh
  DOMAIN=krusnix.net NPM_IP=192.168.4.156 bash setup-proxy.sh --check
  ```
  It adds a Pi-hole local DNS record per name on CT 102 via the Pi-hole API (password from `/etc/nebula-sync.env`; nebula-sync copies `dns.hosts` to the other three Pi-holes within the hour; to push now: `pct exec 102 -- systemd-run --wait -P -p EnvironmentFile=/etc/nebula-sync.env /usr/local/bin/nebula-sync run`, not `source`, which breaks on the passwords), a proxy host per name in NPM via its API (wildcard cert, Force SSL, HTTP/2, websockets on), and `HOMEPAGE_ALLOWED_HOSTS` in CT 111 `/etc/homepage/vars.env` so Homepage answers on `home.krusnix.net`. Safe to re-run: it only adds what's missing and brings the advanced config of existing hosts in line. To add a service, add a line to the list and re-run. `--check` requests every name through NPM and should print `0 failing` (all 46 passed 2026-11-13).
- **Per-host extras the script sets:** Immich gets `client_max_body_size 50000M` and 600 s timeouts (large phone uploads). The four Pi-holes get `location = / { return 301 /admin/; }` because Pi-hole v6 returns 404 on `/` for a hostname it doesn't know.
- **Apps that check the hostname** (OPNsense alternate hostname set 2026-11-13), if a browser shows "DNS rebind" / "host not allowed": OPNsense → System → Settings → Administration → Alternate Hostnames `opnsense.krusnix.net`; qBittorrent → WebUI → Server domains; SABnzbd → Config → Special → `host_whitelist`; Unraid → Management Access → Use SSL/TLS must not be Strict.
- **Rebuild:** reinstall CT 113 at .156, recreate the certificate, re-run the script. The Pi-hole records survive in Pi-hole's Teleporter / nebula-sync.

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

### ntfy alerts: logins, Tailscale, Kometa, Pi-hole sync, TerraMaster

Added 2026-11-12 (fourth batch). Same topic `homelab1-alerts-3d1ef2b124a1`. Paste-ready installers are in the project files under `ntfy-batch4/` (`install-proxmox.sh`, `install-terramaster.sh`, `opnsense-login-check.sh`, `SETUP.md`). Tested 2026-11-12: nebula-sync failure ping, Proxmox SSH login ping, OPNsense login ping, Kometa check (OK on the 2026-11-11 run), Tailscale table, TerraMaster check (all disks SMART PASSED, "reconnected" ping).

| Alert | Where it runs | When |
|---|---|---|
| Proxmox SSH and web UI logins (and failures) | host, `ntfy-login-watch.service` | live |
| Tailscale server offline 2 checks in a row, any key expiring within 7 days | host cron `/etc/cron.d/ntfy-tailscale-checks` | every 10 min |
| Kometa 05:00 run missing or not finished | host cron `/etc/cron.d/ntfy-kometa-check` | daily 08:00 |
| TerraMaster RAID degraded/rebuilding, SMART, bad sectors, disk > 50°C, volume > 85% | host cron `/etc/cron.d/ntfy-nas-checks` | every 30 min |
| nebula-sync failed | CT 102, nebula-sync's own webhook | each hourly sync |
| OPNsense web UI and SSH logins (and failures) | OPNsense Monit `LoginCheck` | every 60 s |

**Proxmox logins.** The watcher follows `journalctl -u ssh` and `/var/log/pveproxy/access.log` (`POST /api2/json/access/ticket`, 200 = login, other = failure). An open web UI tab renews its ticket every 15 minutes, so a web login pings once per IP and stays quiet until that IP is idle for 2 hours. Failures ping at most once per 10 minutes per IP. Logins over Tailscale or from 192.168.5.x show as `192.168.4.1` because they come through OPNsense.

`/usr/local/bin/ntfy-login-watch.sh`:

```bash
#!/bin/bash
# Runs as a service. Pings ntfy on Proxmox SSH logins and web UI logins, and on failed attempts.
# A web UI tab renews its ticket every ~15 min, so a web login from an IP pings once,
# then stays quiet until that IP has been idle for 2 hours.
set -u
NTFY=https://ntfy.sh/homelab1-alerts-3d1ef2b124a1
STATE=/run/ntfy-login-watch; mkdir -p "$STATE"
LOG=/var/log/ntfy-checks.log
QUIET_WEB=7200   # sliding window per IP for successful web logins
QUIET=600        # per IP for SSH logins and for failed attempts

notify() {  # notify <priority> <tags> <title> <message>
  curl -fsS -m 20 -H "Priority: $1" -H "Tags: $2" -H "Title: $3" -d "$4" "$NTFY" >/dev/null \
    || echo "$(date '+%F %T') ntfy send failed: $3" >> "$LOG"
}
# due <key> <seconds> <sliding 0|1>: true when <key> hasn't fired within <seconds>.
# sliding=1 also restarts the quiet period on every hit (used for web sessions).
due() {
  local f="$STATE/$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' _)" now last
  now=$(date +%s); last=$(cat "$f" 2>/dev/null || echo 0)
  if [ $((now-last)) -ge "$2" ]; then echo "$now" > "$f"; return 0; fi
  [ "$3" = 1 ] && echo "$now" > "$f"; return 1
}
RE_WEB='"POST /api2/json/access/ticket[^"]*" ([0-9]{3})'
RE_SSH_OK='Accepted ([^ ]+) for ([^ ]+) from ([^ ]+)'
RE_SSH_BAD='(Failed [a-z-]+ for (invalid user )?|Invalid user )([^ ]*) from ([^ ]+)'

{ journalctl -f -n0 -o cat -u ssh.service -u sshd.service &
  tail -n0 -F /var/log/pveproxy/access.log 2>/dev/null &
  wait; } |
while IFS= read -r l; do
  if [[ $l =~ $RE_WEB ]]; then
    code=${BASH_REMATCH[1]}; ip=${l%% *}; ip=${ip#::ffff:}
    if [ "$code" = 200 ]; then
      due "web-ok-$ip" $QUIET_WEB 1 && notify 3 key "Proxmox web UI login from $ip" "$l"
    else
      due "web-bad-$ip" $QUIET 0 && notify 4 warning "Proxmox web UI login FAILED from $ip" "HTTP $code: $l"
    fi
  elif [[ $l =~ $RE_SSH_OK ]]; then
    u=${BASH_REMATCH[2]}; ip=${BASH_REMATCH[3]}
    due "ssh-ok-$u-$ip" $QUIET 0 && notify 3 key "Proxmox SSH login: $u from $ip" "$l"
  elif [[ $l =~ $RE_SSH_BAD ]]; then
    ip=${BASH_REMATCH[4]}
    due "ssh-bad-$ip" $QUIET 0 && notify 4 warning "Proxmox SSH login FAILED from $ip" "$l"
  fi
done
```

`/etc/systemd/system/ntfy-login-watch.service` (`systemctl enable --now ntfy-login-watch`):

```ini
[Unit]
Description=ntfy alerts on Proxmox SSH and web UI logins
After=network-online.target pveproxy.service
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/ntfy-login-watch.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

**Tailscale.** `WATCH=` lists the server nodes (OPNsense, both Proxmox hosts, both Pi-holes, both Plex). Phones, laptops, the Fire TV and the travel router aren't watched for offline. On 2026-11-12 none of the 15 tailnet devices showed a key expiry. Run the script by hand to see the table.

`/usr/local/bin/ntfy-tailscale-checks.sh`:

```bash
#!/bin/bash
# Every 10 min: pings ntfy when a watched tailnet device is offline 2 checks in a row
# (and again when it's back), and once when any device's key is within 7 days of expiring.
set -u
NTFY=https://ntfy.sh/homelab1-alerts-3d1ef2b124a1
# Tailnet names (first part of the MagicDNS name) to watch for offline. Phones/laptops left out on purpose.
WATCH="opnsense proxmox-homelab-1 pihole-homelab-1 plex-homelab-1 proxmox-plexserver pihole-plex-server plex-server"
EXPIRY_DAYS=7
STATE=/var/lib/ntfy-checks/tailscale; mkdir -p "$STATE"
LOG=/var/log/ntfy-checks.log

notify() {  # notify <priority> <tags> <title> <message>
  curl -fsS -m 20 -H "Priority: $1" -H "Tags: $2" -H "Title: $3" -d "$4" "$NTFY" >/dev/null \
    || echo "$(date '+%F %T') ntfy send failed: $3" >> "$LOG"
}
j=$(timeout 30 tailscale status --json 2>/dev/null)
if [ "$(jq -r '.BackendState // empty' <<<"$j" 2>/dev/null)" != Running ]; then
  echo "$(date '+%F %T') tailscale not running on the host, skipped" >> "$LOG"; exit 0
fi
now=$(date +%s)
[ -t 1 ] && printf '%-26s %-7s %-6s %s\n' NAME ONLINE WATCH KEY_EXPIRY
jq -r '([.Self] + ((.Peer // {}) | [.[]]))[]
  | [ (if (.DNSName // "") != "" then (.DNSName | split(".")[0]) else .HostName end),
      .HostName, (.Online | tostring), (.KeyExpiry // ""), (.LastSeen // "") ] | join("|")' <<<"$j" |
while IFS='|' read -r name host online exp last; do
  w=no; [[ " $WATCH " == *" $name "* ]] && w=yes
  [ -t 1 ] && printf '%-26s %-7s %-6s %s\n' "$name" "$online" "$w" "${exp:-never}"
  if [ "$w" = yes ]; then
    f="$STATE/$name.offline"; n=$(cat "$f" 2>/dev/null || echo 0)
    if [ "$online" = true ]; then
      [ "$n" -ge 2 ] && notify 2 white_check_mark "Tailscale: $name back online" "$name is reachable on the tailnet again."
      rm -f "$f"
    else
      n=$((n+1)); echo "$n" > "$f"
      [ "$n" -eq 2 ] && notify 4 warning "Tailscale: $name offline" \
        "$name ($host) has been offline in Tailscale for 10+ minutes. Last seen: ${last:-unknown}."
    fi
  fi
  if [ -n "$exp" ] && e=$(date -d "$exp" +%s 2>/dev/null) && [ "$e" -gt 0 ]; then
    k="$STATE/$name.expiry"; left=$(( (e-now)/86400 ))
    if [ "$e" -le "$now" ]; then
      [ "$(cat "$k" 2>/dev/null)" = "expired $exp" ] || { echo "expired $exp" > "$k"
        notify 5 rotating_light "Tailscale key EXPIRED: $name" \
          "$name dropped off the tailnet when its key expired ($exp). Log it in again with: tailscale up --force-reauth"; }
    elif [ "$e" -lt $((now + EXPIRY_DAYS*86400)) ]; then
      [ "$(cat "$k" 2>/dev/null)" = "soon $exp" ] || { echo "soon $exp" > "$k"
        notify 4 key "Tailscale key expires in ${left} day(s): $name" \
          "Key expires $exp. Renew with: tailscale up --force-reauth on $name, or for a server use Disable key expiry in the Tailscale admin (Machines → ... menu)."; }
    else rm -f "$k"
    fi
  fi
done
exit 0
```

**Kometa.** Only reads CT 108's `meta.log`; the config is left alone. A finished run ends with a `Finished 05:00 Run` banner and a `Start Time ... Run Time` line. Errors inside a finished run (the helper template's missing Anime library etc., 29 on 2026-11-11) don't alert.

`/usr/local/bin/ntfy-kometa-check.sh`:

```bash
#!/bin/bash
# Daily 08:00: checks that Kometa's 05:00 run in CT 108 happened and finished.
# Only reads Kometa's log; doesn't touch its config.
set -u
NTFY=https://ntfy.sh/homelab1-alerts-3d1ef2b124a1
CT=108; L=/opt/kometa/config/logs/meta.log
LOG=/var/log/ntfy-checks.log
fail() {
  [ -t 1 ] && echo "FAIL: $1 -- $2"
  curl -fsS -m 20 -H "Priority: 4" -H "Tags: warning" -H "Title: Kometa: $1" \
    -d "$2 Logs: CT 108 $L, or journalctl -u kometa." "$NTFY" >/dev/null \
    || echo "$(date '+%F %T') ntfy send failed: Kometa $1" >> "$LOG"
  exit 0
}
[ "$(pct status $CT 2>/dev/null | awk '{print $2}')" = running ] || fail "CT $CT is not running" "The container is stopped, so the 05:00 run didn't happen."
pct exec $CT -- systemctl is-active -q kometa.service || fail "service stopped" "kometa.service isn't running in CT 108, so no daily run."
mt=$(pct exec $CT -- stat -c %Y "$L" 2>/dev/null) || fail "no log" "$L is missing."
[ "$mt" -ge "$(date -d 'today 05:00' +%s)" ] || fail "05:00 run didn't happen" "meta.log was last written $(date -d @"$mt" '+%F %H:%M')."
body=$(pct exec $CT -- cat "$L")
fin=$(grep -E 'Finished .*Run|Run Time:' <<<"$body" | tail -1 | sed 's/^[^|]*| *//; s/ *|$//')
errs=$(grep -cE '\[(ERROR|CRITICAL)\]' <<<"$body")
[ -n "$fin" ] || fail "05:00 run didn't finish" "No Finished/Run Time line in today's meta.log ($errs error lines). Last line: $(tail -1 <<<"$body" | cut -c1-200)"
[ -t 1 ] && echo "OK: $fin ($errs error/critical lines, not alerted)"
exit 0
```

**TerraMaster (192.168.4.180).** TOS 4.2.44 on an F4-210 (aarch64, 1 GB), RAID 5 `md0` over sdb-sde (sda is the boot flash; md8/md9 are TOS system mirrors that always show `[24/4]`). SSH is on in Control Panel → Terminal & SNMP, **port 9222**, local network only.

- The host logs in as **krusnix** with key `/root/.ssh/terramaster` (`ssh-copy-id -p 9222 -i /root/.ssh/terramaster.pub krusnix@192.168.4.180`). Don't use root: TOS locks root after 5 failed logins (it happened during setup).
- `smartctl` needs root, so `/etc/sudoers` on the NAS has `krusnix ALL=(root) NOPASSWD: /usr/sbin/smartctl` appended (backup `/etc/sudoers.bak`). TOS has no `visudo` or `/etc/sudoers.d`, so edit it from an open `sudo -s` shell and test with `su krusnix -c 'sudo -n /usr/sbin/smartctl -H /dev/sdb'` before closing it.
- A TOS update may reset the key or sudoers line. The check then pings "TerraMaster checks can't log in" (or logs "SMART health unreadable" in `/var/log/ntfy-checks.log`); redo the two steps above.
- Sleeping disks are skipped (`smartctl -n standby`).

`/usr/local/bin/ntfy-nas-checks.sh`:

```bash
#!/bin/bash
# Every 30 min: SSHes into the TerraMaster (TOS 4, 4 disks, RAID5 md0) and pings ntfy when
# a RAID array is degraded or rebuilding, a disk fails SMART or gains bad sectors, a disk runs
# hot, or the volume passes 85%. Each problem alerts when it starts and when it clears.
# Sleeping disks are skipped (smartctl -n standby), so this never wakes them.
set -u
NTFY=https://ntfy.sh/homelab1-alerts-3d1ef2b124a1
NAS="ssh -p 9222 -i /root/.ssh/terramaster -o BatchMode=yes -o ConnectTimeout=15 krusnix@192.168.4.180"
DISKS=4; LIMIT=85; TEMP_LIMIT=50
STATE=/var/lib/ntfy-checks/nas; mkdir -p "$STATE"
LOG=/var/log/ntfy-checks.log

notify() {  # notify <priority> <tags> <title> <message>
  curl -fsS -m 20 -H "Priority: $1" -H "Tags: $2" -H "Title: $3" -d "$4" "$NTFY" >/dev/null \
    || echo "$(date '+%F %T') ntfy send failed: $3" >> "$LOG"
}
# flag <key> <0|1> <priority> <title if bad> <message if bad> <title when cleared>
flag() {
  local f="$STATE/$1"
  if [ "$2" -eq 1 ]; then
    [ -e "$f" ] || { touch "$f"; notify "$3" warning "$4" "$5"; }
  elif [ -e "$f" ]; then
    rm -f "$f"; notify 2 white_check_mark "$6" "Back to normal."
  fi
}

# Runs on the TerraMaster (busybox sh). Prints MD / SMART / DF lines.
REMOTE='
for m in $(awk "/^md/ {print \$1}" /proc/mdstat); do
  st=$(awk -v m=$m "\$1==m {getline; print \$NF; exit}" /proc/mdstat)
  act=$(awk -v m=$m "\$1==m {f=1; next} f && (/^md/ || /^\$/) {exit} f && /recovery|resync|reshape/ {print \$2; exit}" /proc/mdstat)
  echo "MD $m $(echo $st | tr -cd U | wc -c) $st ${act:-idle}"
done
for d in $(grep -o "sd[a-z]*" /proc/mdstat | sort -u); do
  out=$(sudo -n /usr/sbin/smartctl -H -A -n standby /dev/$d 2>&1)
  if echo "$out" | grep -qi "STANDBY\|SLEEP"; then echo "SMART $d standby"; continue; fi
  h=$(echo "$out" | awk -F: "/overall-health|Health Status/ {gsub(/ /,\"\",\$2); print \$2}")
  a() { echo "$out" | awk -v n=$1 "\$2==n {print \$10+0; f=1} END {if (!f) print 0}"; }
  echo "SMART $d ${h:-UNKNOWN} $(a Reallocated_Sector_Ct) $(a Current_Pending_Sector) $(a Offline_Uncorrectable) $(a Temperature_Celsius)"
done
df -P /mnt/md0 | awk "NR==2 {print \"DF\", \$6, \$5}"
'

if ! out=$($NAS "$REMOTE" 2>&1); then
  flag nas-ssh 1 3 "TerraMaster checks can't log in" \
    "SSH to 192.168.4.180:9222 failed: $(tail -1 <<<"$out"). SSH may be off, or a TOS update removed the key (re-run ssh-copy-id from the runbook)." "TerraMaster checks reconnected"
  exit 0
fi
flag nas-ssh 0 3 "" "" "TerraMaster checks reconnected"
[ -t 1 ] && echo "$out"

while read -r kind a b c d e f; do
  case "$kind" in
    MD)  # a=array b=U count c=[UUUU] d=activity
      flag "md-$a-degraded" $([ "$b" -lt "$DISKS" ] && echo 1 || echo 0) 5 "TerraMaster RAID $a DEGRADED" \
        "$a shows $c: only $b of $DISKS disks active. Check Storage Manager at http://192.168.4.180:8181 and replace the failed disk." "TerraMaster RAID $a healthy"
      flag "md-$a-sync" $([ "$d" != idle ] && echo 1 || echo 0) 3 "TerraMaster RAID $a: $d running" \
        "$a is doing a $d. It's slower until it finishes; don't pull disks." "TerraMaster RAID $a $d finished" ;;
    SMART)  # a=disk b=health c=realloc d=pending e=uncorrectable f=temp
      [ "$b" = standby ] && continue
      sb=1; case "$b" in PASSED|OK) sb=0 ;; UNKNOWN) sb=0; echo "$(date '+%F %T') NAS $a SMART health unreadable" >> "$LOG" ;; esac
      flag "smart-$a" $sb 5 \
        "TerraMaster disk $a SMART: $b" "Disk $a reports SMART health $b. Back up and plan a replacement." "TerraMaster disk $a SMART OK"
      bad=$((c+d+e)); old=$(cat "$STATE/$a-badsectors" 2>/dev/null || echo "$bad"); echo "$bad" > "$STATE/$a-badsectors"
      [ "$bad" -gt "$old" ] && notify 4 warning "TerraMaster disk $a: new bad sectors" \
        "Reallocated $c, pending $d, uncorrectable $e (was $old total). Watch it; replace if it keeps rising."
      flag "temp-$a" $([ "$f" -ge "$TEMP_LIMIT" ] && echo 1 || echo 0) 4 "TerraMaster disk $a at ${f}°C" \
        "Disk $a is at ${f}°C (limit $TEMP_LIMIT). Check the fan and airflow." "TerraMaster disk $a temperature OK" ;;
    DF)  # a=mount b=percent
      p=${b%\%}
      flag "df-md0" $([ "$p" -ge "$LIMIT" ] && echo 1 || echo 0) 4 "TerraMaster volume ${p}% full" \
        "$a is at ${p}% (alert limit ${LIMIT}%)." "TerraMaster volume back under ${LIMIT}%" ;;
  esac
done <<<"$out"
exit 0
```

**nebula-sync (CT 102).** nebula-sync 0.11.3 has failure webhooks. Added to `/etc/nebula-sync.env`, then `systemctl restart nebula-sync`:

```
WEBHOOK_SYNC_FAILURE_URL="https://ntfy.sh/homelab1-alerts-3d1ef2b124a1"
WEBHOOK_SYNC_FAILURE_HEADERS="Title:Pi-hole sync failed,Priority:4,Tags:warning"
WEBHOOK_SYNC_FAILURE_BODY="nebula-sync on CT 102 could not sync the Pi-holes. Check: journalctl -u nebula-sync -n 50"
```

Test without touching the real config (one run against a wrong primary password):

```bash
cp /etc/nebula-sync.env /root/ns-test.env
sed -i -e 's/^\(PRIMARY="\{0,1\}[^|]*|\)[^"]*/\1wrong-password/' -e '/^CRON=/d' /root/ns-test.env
systemd-run --wait -P -p EnvironmentFile=/root/ns-test.env /usr/local/bin/nebula-sync run; rm -f /root/ns-test.env
```

**OPNsense logins.** Logins are in the audit log (`/var/log/audit/latest.log` → `audit_YYYYMMDD.log`, about 50 MB a day, so don't grep all of `/var/log/audit/*.log`). Web: `/index.php: Successful login for user 'root' from: ...`; SSH: `sshd-session ... Accepted publickey for root from ...`. The script reads only the bytes added since its last run.

`/root/login-check.sh` (`chmod 755`, run once by hand to record the log ends):

```sh
#!/bin/sh
# OPNsense: save as /root/login-check.sh, chmod 755. Monit runs it every 60 s.
# Pings ntfy for each web UI or SSH login and failed attempt added to the logs since the last run.
# Reads only the new bytes (the audit log can be 50 MB a day). Always exits 0.
NTFY=https://ntfy.sh/homelab1-alerts-3d1ef2b124a1
STATE=/var/db/login-check; mkdir -p $STATE
PAT="Successful login for user|authentication error|could not authenticate|sshd-session.*(Accepted |Failed |Invalid user )"
send() {  # send <priority> <tags> <title> <message>
  /usr/local/bin/curl -fsS -m 20 -H "Priority: $1" -H "Tags: $2" -H "Title: $3" -d "$4" $NTFY >/dev/null 2>&1
}
for f in /var/log/audit/latest.log /var/log/system/latest.log; do
  [ -f "$f" ] || continue
  real=$(realpath "$f"); key=$STATE/$(echo "$f" | tr / _)
  size=$(stat -f %z "$real")
  set -- $(cat "$key" 2>/dev/null)          # last run: <file> <byte offset>
  if [ -z "$1" ]; then off=$size            # first run: skip old lines
  elif [ "$1" = "$real" ] && [ "$2" -le "$size" ]; then off=$2
  else off=0; fi                            # new day's file
  echo "$real $size" > "$key"
  [ "$off" -lt "$size" ] || continue
  tail -c +$((off+1)) "$real" | head -c $((size-off)) | grep -E "$PAT" | head -5 | while IFS= read -r l; do
    msg=$(echo "$l" | sed 's/^.*\] //')
    case "$msg" in
      *error*|*Failed*|*Invalid*|*"could not"*) send 4 warning "OPNsense login FAILED" "$msg" ;;
      *) send 3 key "OPNsense login" "$msg" ;;
    esac
  done
done
exit 0
```

Services → Monit → Service Settings → `LoginCheck`: Type Custom, Path `/root/login-check.sh`, Tests `GatewayAlert` (OPNsense won't save a Custom check without a test; it never fires because the script always exits 0).

**plex-proxmox Plex (192.168.4.49).** Tautulli watches one server, so plex-proxmox has its own Tautulli: **CT 105 on plex-proxmox** (helper script, DHCP reserved in OPNsense, MAC `BC:24:11:6B:9E:4B`, web UI on port 8181), connected to plex-server. It has the same two ntfy agents as homelab1's CT 106 (outages priority 5: Plex Server Down/Back Up, Remote Access Down/Back Up; streams priority 2: Playback Start), with subjects prefixed `plex-server:`. Both agents' test notifications worked 2026-11-12. Not to be confused with homelab1's CT 105 (Immich).

## plex-proxmox host: CPU fixes

plex-proxmox (192.168.4.215) only has 4 cores, so background loops show up fast. Found 2026-11-13 after the host sat at ~99% CPU from 21:32 the night before.

**pve-auto-hook (community dependency-check add-on).** It ships `pve-auto-hook.path` with `PathExistsGlob=/etc/pve/qemu-server/*.conf` and `/etc/pve/lxc/*.conf`. Guest configs always exist, so systemd re-ran the oneshot `pve-auto-hook.service` (`/usr/local/bin/pve-apply-hookscript.sh`) back to back forever (~950 runs, ~0.8 core, constant `pct`/`qm` churn). The path unit is disabled and replaced by a 15-minute timer:

```bash
systemctl disable --now pve-auto-hook.path
systemctl stop pve-auto-hook.service
cat > /etc/systemd/system/pve-auto-hook.timer <<'UNIT'
[Unit]
Description=Apply dependency-check hookscript to new guests every 15 min

[Timer]
OnBootSec=5min
OnCalendar=*:0/15
Unit=pve-auto-hook.service

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload && systemctl enable --now pve-auto-hook.timer
```

New guests get the `local:snippets/dependency-check.sh` hookscript within 15 minutes instead of instantly. If the add-on is reinstalled or updated, check that it hasn't re-enabled `pve-auto-hook.path`.

**iptag (community IP-Tag add-on).** `LOOP_INTERVAL` in `/opt/iptag/iptag.conf` raised from 300 to 1800 (backup `iptag.conf.bak-20261113`), then `systemctl restart iptag`. Each pass runs `pct exec <id> -- ip -4 addr show` on every CT.

**ping-instances (community monitor-all add-on).** Left as is. It only watches guests tagged `mon-restart`, and none are.

**Plex (CT 103 on plex-proxmox, data in `/srv/plex`, 40 GB appdata LV).** The host is an Intel N150 and ~15,000 of ~16,000 videos are AV1, which Plex decodes in software for analysis. With every analysis task on "as soon as possible", Plex kept two cores busy around the clock, and video preview thumbnails (~11 MB per file, ~170 GB for the whole library at ~20 files/day) would have filled the appdata disk. Changed 2026-11-13 through Plex's settings API (no restart), same as Settings > Library in the web UI:

- `GenerateBIFBehavior=never` (video preview thumbnails off; the 14 GB already made were kept)
- `scheduled` (Butler window 23:00 to 02:00) for `GenerateChapterThumbBehavior`, `LoudnessAnalysisBehavior`, `GenerateIntroMarkerBehavior`, `GenerateCreditsMarkerBehavior`, `GenerateAdMarkerBehavior`, `GenerateVADBehavior`, `MusicAnalysisBehavior`
- `logDebug=0` (debug logs were rotating every 30 to 60 minutes)

From inside CT 103: `curl -X PUT "http://127.0.0.1:32400/:/prefs?GenerateBIFBehavior=never&X-Plex-Token=$TOKEN"` (token is `PlexOnlineToken` in `Preferences.xml`). Result: host went from 0% to ~95% idle, and the HA VM's CPU fell from ~86% to ~4% (it was mostly waiting on the starved host). Expect higher CPU overnight while the loudness/marker backlog works through.

Undo:

```bash
systemctl disable --now pve-auto-hook.timer && systemctl enable --now pve-auto-hook.path
cp -a /opt/iptag/iptag.conf.bak-20261113 /opt/iptag/iptag.conf && systemctl restart iptag
```
