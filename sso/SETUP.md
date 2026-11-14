# Single sign-on (Authentik) for the homelab

Result: one login at `https://auth.krusnix.net` for the homelab web UIs, LAN and Tailscale only like the proxy.
- **Own SSO button** ("Sign in with authentik"): Proxmox (both hosts), Grafana, Immich, Audiobookshelf, Beszel, Jellyfin.
  Each keeps its local login as a fallback.
- **Authentik login page in front** (NPM forward-auth): Tdarr, Tunarr (both), Kometa (both), Prometheus, the UPS and
  helper-scripts UIs (both hosts), Homepage, Sonarr, Radarr, Lidarr, Whisparr, Bazarr, Mylar, LazyLibrarian, Prowlarr,
  the three Tautullis, qBittorrent, SABnzbd, Cleanuparr. `/api` paths skip the gate on the apps that have an API
  (they still need the app's API key), so phone apps and app-to-app links keep working.
- **Left alone**: Plex (all three), Seerr (family logs in with Plex), NPM, OPNsense, the Pi-holes, the TerraMaster,
  Uptime Kuma, Youtarr, Unraid. They keep their own logins, so a broken Authentik can't lock you out of the tools that fix it.
- Only the `authentik Admins` group can use any of it. Family never needs an Authentik account.
- **If Authentik is down**: the gated names stop loading, but every app still works at its `IP:port`.

## 1. Install Authentik (helper script, on homelab1-proxmox)
- Helper script **authentik** (`ct/authentik.sh`), Advanced: **CT 114**, hostname `authentik`, DHCP. Keep the
  defaults (4 cores, 8 GB RAM, 16 GB disk); it builds from source, which takes 15-30 min and needs the RAM.
- Reserve its IP in OPNsense. (Done 2026-11-13: **192.168.4.229**.)
- The first start runs database migrations ("Server is starting up") for a few minutes.
- Once everything below works: `pct set 114 --memory 4096`. Updates (`update` in the CT console) rebuild from
  source, so raise it back to 8192 before updating.

## 2. Create the admin account and an API token
- Open `http://192.168.4.229:9000/if/flow/initial-setup/` (trailing slash matters). Set the `akadmin` email and
  password, and **Base URL `https://auth.krusnix.net`**.
- **Admin interface → Directory → Users → Create**: your everyday user (e.g. `trent`), then **Groups** tab → add to
  `authentik Admins`. Set its password (user page → Set password). `akadmin` is the break-glass account.
- **Directory → Tokens and App passwords → Create**: identifier `homelab-setup`, user: yours, intent **API Token**,
  Expiring off. Copy the key (eye icon / Copy).

## 3. Run the scripts (on homelab1-proxmox, as root)
```
# copy the new reverse-proxy/setup-proxy.sh and sso/setup-sso.sh to /root first, then:
cd /root
DOMAIN=krusnix.net NPM_IP=192.168.4.156 NPM_USER='<npm email>' NPM_PASS='<npm password>' bash setup-proxy.sh
DOMAIN=krusnix.net NPM_IP=192.168.4.156 NPM_USER='<npm email>' NPM_PASS='<npm password>' \
  AK_TOKEN='<token from step 2>' AK_USER='<your authentik username>' bash setup-sso.sh
DOMAIN=krusnix.net NPM_IP=192.168.4.156 bash setup-sso.sh --check
```
`setup-proxy.sh` adds `auth.krusnix.net` (Pi-hole record + NPM host). `setup-sso.sh` does the rest:
the forward-auth provider + embedded outpost, the OIDC clients, ntfy alerts, the Homepage widget key, the NPM gate on
each gated name, the Proxmox realm on this host and Grafana's login button. Both are safe to re-run, and re-running
`setup-proxy.sh` later no longer wipes the gate. Client IDs/secrets land in `/root/sso-clients.txt`.

Then open `https://auth.krusnix.net` and log in as your user: you'll see an app tile per OIDC app.

## 4. One-time settings in the apps (values from `/root/sso-clients.txt`)
Issuer / "OpenID configuration URL" for app `<slug>` is `https://auth.krusnix.net/application/o/<slug>/`
(discovery: add `.well-known/openid-configuration`).

**Proxmox, homelab1**: done by the script. Login screen → Realm **Authentik SSO** → Login with OpenID.
**Proxmox, plex-proxmox**: run there (replace the two values from the `[proxmox-plex]` block):
```
grep -q auth.krusnix.net /etc/hosts || echo '192.168.4.156 auth.krusnix.net' >> /etc/hosts
pveum realm add authentik --type openid --issuer-url https://auth.krusnix.net/application/o/proxmox-plex/ \
  --client-id '<client id>' --client-key '<client secret>' --username-claim username \
  --scopes 'openid email profile' --autocreate 0 --comment 'Authentik SSO'
pveum user add <you>@authentik && pveum acl modify / --users <you>@authentik --roles Administrator
```
**Grafana**: done by the script. Your SSO user is a new Grafana user (Admin via the group); the old local `admin` still works.

**Immich** (Administration → Settings → Authentication Settings → OAuth): Login with OAuth on; issuer_url
`https://auth.krusnix.net/application/o/immich/`; client_id/secret; leave scope, RS256/none algs and the claim fields at
their defaults (they only apply to new accounts); end_session_endpoint `https://auth.krusnix.net/application/o/immich/end-session/`;
Button text `Login with Authentik`; Auto register **off**; Auto launch off; Mobile redirect URI override **off** (Authentik
accepts `app.immich:///oauth-callback` directly). Keep Password Login enabled. Existing accounts link by matching email.

**Audiobookshelf** (Settings → Authentication → OpenID Connect): Issuer URL from `[audiobookshelf]` → Auto-populate;
Client ID/Secret; Button text `Login with Authentik`; Match existing users by **username**; Auto register off. Allowed
mobile redirect URIs: `audiobookshelf://oauth`. Keep Password Authentication on. Unraid's Docker containers must resolve
`auth.krusnix.net`: if ABS shows "issuer discovery failed", add `--add-host=auth.krusnix.net:192.168.4.156` to the
container's Extra Parameters.

**Beszel** (PocketBase admin `https://beszel.krusnix.net/_/`, superuser login → Collections → users → ⚙ → OAuth2 → on →
Add provider → OpenID Connect): Client ID/Secret; Display name `Authentik`; Auth URL `https://auth.krusnix.net/application/o/authorize/`,
Token URL `.../application/o/token/`, User info URL `.../application/o/userinfo/`. Existing users link by email. If the token
fetch fails, add `192.168.4.156 auth.krusnix.net` to `/etc/hosts` in CT 109.

**Cleanuparr** (Settings → Account → OIDC / SSO): Enable; Provider Name `Authentik`; Issuer URL from `[cleanuparr]`;
Client ID/Secret; Scopes `openid profile email`; Redirect URL `https://cleanuparr.krusnix.net`. Save OIDC Settings.

**Jellyfin** (Dashboard → Plugins → Repositories: add `https://raw.githubusercontent.com/9p4/jellyfin-plugin-sso/manifest-release/manifest.json`,
install **SSO Authentication**, restart): Plugins → SSO-Auth → Add provider: name **authentik** (must match),
OID endpoint = issuer from `[jellyfin]`, client ID/secret, Enabled, Enable authorization by plugin, **Scheme Override `https`**
(NPM talks to Jellyfin over http, so without it the plugin sends an http redirect URI and Authentik shows "Redirect URI Error"). Login at
`https://jellyfin.krusnix.net/sso/OID/start/authentik`. Jellyfin apps on TV/phone keep their normal login.

### Apps behind the gate that have their own login (so you only log in once)
The gate reaches each app from NPM (192.168.4.156), a local address:
- **Sonarr, Radarr, Lidarr, Whisparr, Prowlarr** (Settings → General → Security): Authentication **Forms**,
  Authentication Required **Disabled for Local Addresses**. Newer versions then require **Allowed Hosts** (Settings → General → Host),
  e.g. `sonarr.krusnix.net, 192.168.5.14, localhost, sonarr`; save and restart the app.
- **Bazarr** (Settings → General → Security): Authentication **None**. **Mylar / LazyLibrarian**: clear the HTTP
  username/password. **Cleanuparr**: turn off its login if it has one.
- **Tautulli** (Settings → Web Interface): untick **Use Basic Authentication** / clear the password. API key stays.
- **SABnzbd** (Config → General → Security): clear username and password. API key stays. Without a password SAB
  checks the hostname: Config → Special → `host_whitelist` add `sabnzbd.krusnix.net`, save, restart (use the IP to get in).
- **Bazarr**: clear the Authentication box with its × (no "None" option). **LazyLibrarian**: clear WebServer User and Pass, save, Restart.
- **qBittorrent**: keep its login. Its API uses the same password, and bypassing it for the proxy would open the
  API to anyone on the LAN. You'll log in twice there.

Trade-off: those apps no longer ask for a password when opened by bare `IP:port` on the LAN. Their APIs still need keys.

## 5. Monitoring
- Uptime Kuma: add an **HTTP(s)** monitor `Authentik`, URL `http://192.168.4.229:9000/-/health/live/`, interval 60.
  Add a second one, `https://tdarr.krusnix.net/`, expecting status **302** (Advanced: **Max. Redirects `0`**, Accepted Status Codes `300-399`; with redirects on it follows to the login page and sees 200):
  that catches the gate breaking.
- ntfy (by the script): Authentik's own errors, configuration problems, update notices, and **failed logins** go to the
  phone topic.
- Homepage: Authentik tile with login/user counts (run `homepage/setup-homelab1.sh` again to add the tile).

## Undo / break glass
- One app: remove its Advanced config in NPM (Hosts → Proxy Hosts → ⋮ → Edit → Advanced), or run
  `bash reverse-proxy/setup-proxy.sh` after deleting the `outpost.goauthentik.io` text.
- Everything: every app still answers on `IP:port`. Proxmox/Grafana/Immich/ABS/Beszel local logins still work.
- Locked out of Authentik: log in as `akadmin` at `http://192.168.4.229:9000`. If that's lost too, Authentik can
  print a one-time recovery link (`create_recovery_key`); the exact command for this from-source install hasn't
  been tested yet, so check it before you need it.
