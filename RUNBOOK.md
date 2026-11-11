# homelab1-proxmox rebuild runbook

Last updated 2026-11-11. Covers the Proxmox host rebuilt on 2026-11-08 and the LXCs on it.

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
| 101 | pve-ups | 192.168.4.205 (DHCP reserved) | UPS monitoring |
| 102 | pihole | 192.168.4.145 | Pi-hole + Unbound on 5335 (DoT to 8.8.8.8/8.8.4.4), nebula-sync primary |
| 103 | plex | 192.168.4.120 | Both GPUs, /unraid + /nas |
| 104 | tdarr | 192.168.4.127:8265 | Both GPUs, /unraid + /nas |
| 105 | immich | 192.168.4.163:2283 | Both GPUs, /unraid |
| 106 | tautulli | 192.168.4.113:8181 (DHCP reserved) | Plex stats, no GPU or shares |
| 107 | tunarr | 192.168.4.235:8000 | Live TV channels for Plex, both GPUs |
| 108 | kometa | 192.168.4.213 (DHCP reserved) | Plex collections/overlays, no GPU or shares |

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

- Debian 13, Tdarr server 3.06.00, **8 cores / 16 GB RAM / 1 GB swap** (raised from 2 cores / 6 GB on 2026-11-10; see below). `/unraid` and `/nas` mounted, `/temp` → `/unraid/tdarr_cache`.
- Both GPUs; NVIDIA libs 620.70.06 (held with `apt-mark hold`).
- Server auth on; node API key in `/opt/tdarr/configs/Tdarr_Node_Config.json`.
- Custom plugin: `Tdarr_Plugin_AV1_HDR_Remove.js`. Old backup: `/unraid/dump/tdarr-backup`.
- **AV1 encodes run on the CPU.** The custom plugin uses `libsvtav1` (neither GPU can encode AV1), even on the "NVIDIA Node"'s GPU worker slots. Keep that node at **2 GPU transcode workers, 0 CPU**: each 1080p encode uses ~0.7 GB RAM, a 4K HDR tonemap ~2.5 GB. At 2 cores / 6 GB it ran out of memory and stalled.
- `tdarr-node.service` drop-in `/etc/systemd/system/tdarr-node.service.d/killmode.conf` sets `KillMode=mixed`. Without it (the default `KillMode=process`), a node crash or restart leaves its ffmpeg encodes running as orphans that pile up.

### CT 105 Immich

Installed 2026-11-10 with the Immich helper script (Immich 3.3.6).

**Container config** (`pct config 105`):

```
cores: 4
memory: 6144
swap: 512
unprivileged: 1
features: nesting=1,keyctl=1
rootfs: local-lvm:vm-105-disk-0,size=50G
mp0: /mnt/pve/unraid-data,mp=/unraid
dev0: /dev/dri/renderD128,gid=992   # Intel render
dev1: /dev/dri/card1,gid=44         # Intel card
dev2: /dev/dri/renderD129,gid=992   # NVIDIA render
dev3-dev9: /dev/nvidia0, nvidiactl, nvidia-modeset, nvidia-uvm, nvidia-uvm-tools,
           /dev/nvidia-caps/nvidia-cap1, nvidia-cap2   (all gid=44)
net0: vmbr0, dhcp, MAC BC:24:11:B5:13:3C (reserve .163 in OPNsense)
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
- Side effect: each CPU AV1 transcode uses 1-5 GB of RAM. On 2026-11-10 the initial backlog pinned CT 105 at its 6 GB limit with swap full, and ffmpeg was OOM-killed (24 kills; Immich restarts the job on its own). If that becomes a problem, either `pct set 105 -memory 8192 -swap 1024`, or switch the target to HEVC/H.264 (NVENC can encode those) with AV1, HEVC and H.264 accepted.
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
