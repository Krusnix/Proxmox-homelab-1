# homelab1-proxmox rebuild runbook

Last updated 2026-11-10. Covers the Proxmox host rebuilt on 2026-11-08 and the LXCs on it.

## Host

| Item | Value |
|---|---|
| Hostname | homelab1-proxmox.internal |
| IP | 192.168.4.209/22, gateway and DNS 192.168.4.1 (OPNsense) |
| Hardware | i7-12700H, 62 GB RAM, 1 TB NVMe (LVM, no redundancy) |
| PVE | 9.x, standalone, community post-install script run |
| Remote access | Tailscale on the host |

### GPU drivers (host)

- Intel iGPU: in-kernel i915. `renderD128` = Intel, `card1` = Intel.
- NVIDIA RTX 3070 Ti: driver **620.70.06**, open kernel modules via DKMS. nouveau blacklisted, `nvidia-persistenced` on, `/etc/modules-load.d/nvidia.conf`, udev rule `70-nvidia.rules`. `renderD129` = NVIDIA.
- The installer is kept at `/root/nvidia` for installing the matching userspace driver in LXCs (`--no-kernel-module`).
- **If the host NVIDIA driver is updated, reinstall the same version in CT 103 (Plex), CT 104 (Tdarr) and CT 105 (Immich).**

### Network shares (PVE storages)

| Storage | Source | Host path | LXC mount |
|---|---|---|---|
| unraid-data | `//192.168.5.14/data` (Unraid, SMB) | `/mnt/pve/unraid-data` | `/unraid` |
| nas-public | `//192.168.4.180/public` (TerraMaster, SMB) | `/mnt/pve/nas-public` | `/nas` |

Both are mounted with `uid=100000,gid=110000`, mode 0775. Inside unprivileged LXCs, create group `nasshare` with gid **10000** (maps to host gid 110000) and add the service user to it.

## LXCs

All installed with the Proxmox community helper scripts, then configured by hand.

| CT | Name | IP | Notes |
|---|---|---|---|
| 100 | pve-scripts-local | 192.168.4.102 (DHCP reserved) | Helper-script web UI |
| 101 | pve-ups | 192.168.4.205 (DHCP reserved) | UPS monitoring |
| 102 | pihole | 192.168.4.145 | Pi-hole + Unbound on 5335 (DoT to 8.8.8.8/8.8.4.4) |
| 103 | plex | 192.168.4.120 | Both GPUs, /unraid + /nas |
| 104 | tdarr | 192.168.4.127:8265 | Both GPUs, /unraid + /nas |
| 105 | immich | 192.168.4.163:2283 | Both GPUs, /unraid |

### CT 103 Plex

- 32 GB disk. `mp0` unraid-data → `/unraid`, `mp1` nas-public → `/nas`. `plex` user in `nasshare`.
- Both GPUs passed through; NVIDIA 620.70.06 userspace installed with `--no-kernel-module`.
- Remote access: OPNsense NAT WAN:32420 → 192.168.4.120:32400. If remote access breaks with a cert error, stop Plex, move `Cache/cert-v2.p12` aside, restart.

### CT 104 Tdarr

- Debian 13, Tdarr server 3.06.00, 2 cores / 6 GB. `/unraid` and `/nas` mounted, `/temp` → `/unraid/tdarr_cache`.
- Both GPUs; NVIDIA libs 620.70.06 (held with `apt-mark hold`).
- Server auth on; node API key in `/opt/tdarr/configs/Tdarr_Node_Config.json`.
- Custom plugin: `Tdarr_Plugin_AV1_HDR_Remove.js`. Old backup: `/unraid/dump/tdarr-backup`.

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
net0: vmbr0, dhcp
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

- Photos: existing folders under `/unraid/media/pictures` (Camera, Camera Roll, etc.) are added as External Libraries, so Immich indexes them in place without moving anything.
- Video transcoding: Administration → Video Transcoding → Hardware Acceleration. QSV with preferred device `renderD128` (Intel), or NVENC (NVIDIA).
- Target video codec must be H.264 or HEVC, with H.264 and HEVC accepted. Neither GPU can encode AV1, so an AV1 target falls back to the CPU.
- Machine learning runs the OpenVINO build (Intel iGPU or CPU). NVIDIA for ML would need the CUDA build of immich-ml.

**Photos on Unraid:** `/mnt/user/data/media/pictures` (share `data`), about 77 GB.
