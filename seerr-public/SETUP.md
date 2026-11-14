# Seerr on the internet (Cloudflare Tunnel, Seerr only)

Result: family and friends open `https://seerr.krusnix.net` from anywhere, with no Tailscale, and sign in with
their Plex account. Nothing else in the homelab becomes reachable.

**How:** a small `cloudflared` container (CT 115) makes an outbound connection to Cloudflare. Cloudflare sends
requests for `seerr.krusnix.net`, and only that name, down the tunnel straight to Seerr on Unraid
(`192.168.5.14:5055`). No port is opened on OPNsense, your home IP stays hidden, and NPM (with its 46 hosts) is
never in the internet path. At home and on Tailscale the Pi-holes keep answering `seerr.krusnix.net` with NPM,
so the same address works everywhere.

**Login:** Seerr's own "Sign in with Plex", no Authentik and no Cloudflare Access in front. Only people you
already share Plex with can get in, family already knows that login, and an extra gate would mean two logins
plus Authentik accounts for everyone. Cloudflare rules below cut off most junk traffic before it reaches Seerr.

## 1. Seerr settings first (Seerr UI, ~2 min)
- **Settings → General**: Application URL `https://seerr.krusnix.net`; **Enable Proxy Support** on (so Seerr logs
  the visitor's real IP instead of the tunnel's). Save.
- **Settings → Users**: **Enable Local Sign-In** off (first check you can sign in with Plex as the admin; if any
  family member uses a local Seerr account, leave it on). **Enable New Plex Sign-In** on lets anyone you share
  Plex with log in the first time; turn it off if you'd rather import users by hand (Users → Import Plex Users).
- Keep the Unraid container on auto-update (it is public now).

## 2. Install the cloudflared container (helper script, on homelab1-proxmox)
- Helper script **Cloudflared** (`ct/cloudflared.sh`), Advanced: **CT 115**, hostname `cloudflared`, defaults
  (1 core, 512 MB, 2 GB), DHCP. It only installs the `cloudflared` package from Cloudflare's apt repo.
- Reserve its IP in OPNsense (Services → DHCPv4 → LAN, by MAC) and tell me the IP and MAC for the runbook.

## 3. Create the tunnel (Cloudflare dashboard, ~5 min)
1. dash.cloudflare.com → **Zero Trust** (first time: pick a team name and the **Free** plan).
2. **Networks → Tunnels** (some accounts call it Connectors) → **Create a tunnel** → **Cloudflared**, name
   `homelab1-seerr` → Save.
3. On the install page choose **Debian**, copy the `sudo cloudflared service install eyJ...` line, and run it in
   CT 115 without `sudo` (`pct enter 115`, paste). Within a few seconds the dashboard shows the connector
   **Healthy**.
4. Next → **Public hostname** (or **Published application routes**) → Add:
   - Subdomain `seerr`, Domain `krusnix.net`, Path empty
   - Service Type **HTTP**, URL `192.168.5.14:5055`
   - Save. Cloudflare creates the `seerr` DNS record itself (proxied, orange cloud). Add no other hostnames.

The token in that install line is the tunnel's only secret. It lives in `/etc/systemd/system/cloudflared.service`
in CT 115 (and in its backups). If it leaks: Tunnel → Configure → Refresh token, then re-run the install line.

## 4. Cloudflare protection rules (krusnix.net zone, ~3 min)
**Security → WAF → Custom rules → Create rule**
- Name `seerr-country`. Field Hostname equals `seerr.krusnix.net` **and** Country is not in `United States`
  (add any country where family lives or travels). Action **Block**.

**Security → WAF → Rate limiting rules → Create rule** (the free plan allows one)
- Name `seerr-login`. Hostname equals `seerr.krusnix.net` **and** URI Path starts with `/api/v1/auth`.
  Same IP, **20 requests per 10 seconds**, Action **Block** for 10 seconds.

Optional: **Security → Bots → Bot Fight Mode** on.

## 5. Tunnel health in Uptime Kuma (CT 115, ~1 min)
Let Uptime Kuma read cloudflared's `/ready` page (200 while it holds a tunnel connection, 503 when it doesn't):
```bash
pct exec 115 -- bash -c 'mkdir -p /etc/systemd/system/cloudflared.service.d &&
printf "[Service]\nEnvironment=TUNNEL_METRICS=0.0.0.0:20241\n" > /etc/systemd/system/cloudflared.service.d/metrics.conf &&
systemctl daemon-reload && systemctl restart cloudflared && sleep 3 && curl -s localhost:20241/ready; echo'
```
Expect `{"status":200,"readyConnections":4,...}` (2 to 4 is fine). In Uptime Kuma add an **HTTP(s)** monitor
`Cloudflare tunnel (Seerr)`, URL `http://<CT 115 IP>:20241/ready`, with the ntfy notification.

Uptime Kuma's existing Seerr check still goes through NPM (Pi-hole answers the name locally), so this is the
check that covers the internet path.

## 6. Test
- Phone on cellular with Wi-Fi **and Tailscale off**: `https://seerr.krusnix.net` → Seerr login → Sign in with
  Plex works, a request goes through.
- Same phone: `https://sonarr.krusnix.net`, `https://auth.krusnix.net`, `https://pve.krusnix.net` must **not**
  load (no DNS record publicly). That's the "only Seerr" check.
- At home: `https://seerr.krusnix.net` still works (via NPM).
- Optional: from cellular, `nslookup seerr.krusnix.net 1.1.1.1` returns Cloudflare addresses (104.x / 172.x), not
  your home IP.

## Undo
Zero Trust → Tunnels → `homelab1-seerr` → Delete (this removes the public route), then delete the `seerr` DNS
record in the krusnix.net zone and `pct destroy 115`. The LAN/Tailscale address keeps working through NPM.
