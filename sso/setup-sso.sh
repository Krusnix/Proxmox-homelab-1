#!/bin/bash
# Single sign-on with Authentik (CT 114). Run on homelab1-proxmox as root, after
# reverse-proxy/setup-proxy.sh has added auth.DOMAIN and you've done SETUP.md steps 1-2.
#   DOMAIN=krusnix.net NPM_IP=192.168.4.156 NPM_USER=you@mail NPM_PASS='...' \
#   AK_TOKEN='<authentik API token>' AK_USER=trent bash setup-sso.sh
#   DOMAIN=krusnix.net NPM_IP=192.168.4.156 bash setup-sso.sh --check
#   DOMAIN=krusnix.net NPM_IP=192.168.4.156 NPM_USER=.. NPM_PASS=.. bash setup-sso.sh --undo-gate
#     (removes the Authentik gate from every GATED name in NPM; nothing else changes)
# What it does (safe to re-run; it only adds what's missing):
#   1. Authentik: a forward-auth provider for every name under DOMAIN (embedded outpost),
#      an OIDC client per app with its own SSO button, all limited to "authentik Admins",
#      ntfy alerts for errors, failed logins and updates, and a read-only key for Homepage.
#   2. NPM: puts the Authentik login in front of the GATED names below. /api paths
#      skip it where phone apps or other apps need them (they still need the app's API key).
#   3. Proxmox (this host): an "authentik" login realm, with AK_USER@authentik as Administrator.
#   4. Grafana (CT 112): "Sign in with authentik" button. Admins group -> Grafana Admin.
#   5. Writes every OIDC client ID/secret to /root/sso-clients.txt (root only) for the
#      apps you set up by hand (SETUP.md step 4).
set -euo pipefail
: "${DOMAIN:?set DOMAIN}" "${NPM_IP:?set NPM_IP}"
AK_IP=${AK_IP:-192.168.4.229}
AUTH="auth.$DOMAIN"
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1
UNDO=0; [ "${1:-}" = "--undo-gate" ] && UNDO=1
NTFY_TOPIC=homelab1-alerts-3d1ef2b124a1

# name  bypass   (bypass: none | arr | prowlarr | api)
GATED=$(cat <<'EOF'
tdarr          none
tunarr         none
tunarr-unraid  none
kometa         none
kometa-plex    none
prometheus     none
ups            none
ups-plex       none
scripts        none
scripts-plex   none
home           none
sonarr         arr
radarr         arr
lidarr         arr
whisparr       arr
bazarr         api
mylar          api
lazylibrarian  api
prowlarr       prowlarr
tautulli       api
tautulli-plex  api
tautulli-unraid api
qbittorrent    api
sabnzbd        api
cleanuparr     api
EOF
)
command -v jq >/dev/null || apt-get install -y jq >/dev/null

if [ $CHECK = 1 ]; then
  bad=0
  live=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://$AK_IP:9000/-/health/live/" || echo ERR)
  echo "Authentik health: $live"
  while read -r n bp; do
    [ -z "$n" ] && continue
    d="$n.$DOMAIN"
    loc=$(curl -s -o /dev/null -m 15 -w '%{http_code} %{redirect_url}' --resolve "$d:443:$NPM_IP" "https://$d/" || echo ERR)
    case "$loc" in
      "302 "*outpost.goauthentik.io*|"302 https://$AUTH"*) r="gated" ;;
      *) r="NOT GATED ($loc)"; bad=$((bad+1)) ;;
    esac
    if [ "$bp" != none ]; then
      a=$(curl -s -o /dev/null -m 15 -w '%{http_code} %{redirect_url}' --resolve "$d:443:$NPM_IP" "https://$d/api" || echo ERR)
      case "$a" in *goauthentik*|*"$AUTH"*) r="$r, /api GATED (should skip)"; bad=$((bad+1)) ;; *) r="$r, /api skips ($a)";; esac
    fi
    printf '  %-28s %s\n' "$d" "$r"
  done <<<"$GATED"
  echo "$bad problems."
  exit 0
fi
: "${NPM_USER:?set NPM_USER}" "${NPM_PASS:?set NPM_PASS}"
[ $UNDO = 1 ] || : "${AK_TOKEN:?set AK_TOKEN}" "${AK_USER:?set AK_USER (your Authentik username)}"

if [ $UNDO = 0 ]; then
### 0. Every machine that talks to Authentik must resolve auth.DOMAIN to the proxy
ensure_host() {   # ensure_host [CTID]
  local run=(bash -c); [ -n "${1:-}" ] && run=(pct exec "$1" -- bash -c)
  "${run[@]}" "getent hosts $AUTH | grep -q '^$NPM_IP' || { sed -i '/[[:space:]]$AUTH\$/d' /etc/hosts; echo '$NPM_IP $AUTH' >> /etc/hosts; echo '  /etc/hosts: $AUTH added ${1:+in CT $1}'; }"
}
ensure_host
for ct in 105 112; do pct status $ct 2>/dev/null | grep -q running && ensure_host $ct; done
# push the auth record to the other three Pi-holes now instead of within the hour
pct exec 102 -- test -f /etc/nebula-sync.env 2>/dev/null &&
  pct exec 102 -- systemd-run --wait -q -P -p EnvironmentFile=/etc/nebula-sync.env /usr/local/bin/nebula-sync run >/dev/null 2>&1 &&
  echo "  Pi-holes: synced (auth.$DOMAIN on all four)" || true
curl -fsS -m 10 -o /dev/null "https://$AUTH/-/health/live/" || {
  echo "https://$AUTH isn't answering through the proxy. Run reverse-proxy/setup-proxy.sh first."; exit 1; }

### 1. Authentik
AK="http://$AK_IP:9000/api/v3"
ak() { curl -sS --fail-with-body -m 30 -H "Authorization: Bearer $AK_TOKEN" -H 'Content-Type: application/json' "$@"; }
enc() { jq -rn --arg s "$1" '$s|@uri'; }
ak "$AK/core/users/me/" >/dev/null || { echo "Authentik API login failed (check AK_TOKEN)"; exit 1; }
flow() { ak "$AK/flows/instances/?slug=$1" | jq -r '.results[0].pk // empty'; }
AUTHZ=$(flow default-provider-authorization-implicit-consent)
INVAL=$(flow default-provider-invalidation-flow)
[ -n "$AUTHZ" ] && [ -n "$INVAL" ] || { echo "Default Authentik flows not found"; exit 1; }
CERT=$(ak "$AK/crypto/certificatekeypairs/?has_key=true&name=$(enc 'authentik Self-signed Certificate')" | jq -r '.results[0].pk // empty')
SCOPES=$(ak "$AK/propertymappings/provider/scope/?page_size=200" | jq -c '[.results[]
  | select((.managed // "") | startswith("goauthentik.io/providers/oauth2/scope-"))
  | select(.scope_name|IN("openid","email","profile","offline_access"))|.pk]')
[ "$(jq length <<<"$SCOPES")" -ge 3 ] || { echo "Authentik scope mappings (openid/email/profile) not found: $SCOPES"; exit 1; }
ADMINS=$(ak "$AK/core/groups/?name=$(enc 'authentik Admins')" | jq -r '.results[0].pk // empty')
[ -n "$ADMINS" ] || { echo "Group 'authentik Admins' not found"; exit 1; }

# app SLUG NAME PROVIDER_PK LAUNCH_URL: application + "admins only" binding
app() {
  local id
  id=$(ak "$AK/core/applications/?slug=$1" | jq -r '.results[0].pk // empty')
  if [ -z "$id" ]; then
    id=$(ak -X POST "$AK/core/applications/" -d "$(jq -n --arg s "$1" --arg n "$2" --argjson p "$3" --arg u "$4" \
      '{slug:$s,name:$n,provider:$p,meta_launch_url:$u,policy_engine_mode:"any"}')" | jq -r .pk)
    echo "  Authentik: application $2" >&2
  fi
  if [ "$(ak "$AK/policies/bindings/?target=$id" | jq --arg g "$ADMINS" '[.results[]|select(.group==$g)]|length')" = 0 ]; then
    ak -X POST "$AK/policies/bindings/" -d "$(jq -n --arg t "$id" --arg g "$ADMINS" '{target:$t,group:$g,order:0,enabled:true}')" >/dev/null
  fi
}

# Forward auth for every name under DOMAIN, served by the embedded outpost
FA=$(ak "$AK/providers/proxy/?name=homelab-forward-auth" | jq -r '.results[0].pk // empty')
if [ -z "$FA" ]; then
  FA=$(ak -X POST "$AK/providers/proxy/" -d "$(jq -n --arg a "$AUTHZ" --arg i "$INVAL" --arg h "https://$AUTH" --arg c "$DOMAIN" \
    '{name:"homelab-forward-auth",authorization_flow:$a,invalidation_flow:$i,mode:"forward_domain",
      external_host:$h,cookie_domain:$c,access_token_validity:"hours=24"}')" | jq -r .pk)
  echo "  Authentik: forward-auth provider"
fi
app homelab-forward-auth "Homelab (forward auth)" "$FA" "https://home.$DOMAIN"
OUT=$(ak "$AK/outposts/instances/?managed__iexact=goauthentik.io%2Foutposts%2Fembedded" | jq '.results[0]')
OUT_ID=$(jq -r .pk <<<"$OUT")
if ! jq -e --argjson p "$FA" '.providers|index($p)' <<<"$OUT" >/dev/null || [ "$(jq -r .config.authentik_host <<<"$OUT")" != "https://$AUTH" ]; then
  ak -X PATCH "$AK/outposts/instances/$OUT_ID/" -d "$(jq --argjson p "$FA" --arg h "https://$AUTH" \
    '{providers:((.providers+[$p])|unique), config:(.config+{authentik_host:$h})}' <<<"$OUT")" >/dev/null
  echo "  Authentik: embedded outpost serves the forward-auth provider"
fi

# OIDC clients. Redirect URI lists: "mode url" per line.
oidc() {   # oidc SLUG NAME LAUNCH_URL <<< redirect lines
  local slug=$1 name=$2 url=$3 uris pk
  uris=$(jq -Rn '[inputs|select(length>0)|split(" ")|{matching_mode:.[0],url:.[1]}]')
  pk=$(ak "$AK/providers/oauth2/?name=$slug" | jq -r '.results[0].pk // empty')
  if [ -z "$pk" ]; then
    pk=$(ak -X POST "$AK/providers/oauth2/" -d "$(jq -n --arg n "$slug" --arg a "$AUTHZ" --arg i "$INVAL" \
      --arg k "$CERT" --argjson s "$SCOPES" --argjson r "$uris" \
      '{name:$n,authorization_flow:$a,invalidation_flow:$i,client_type:"confidential",redirect_uris:$r,
        property_mappings:$s,signing_key:(if $k=="" then null else $k end),sub_mode:"hashed_user_id",
        include_claims_in_id_token:true,grant_types:["authorization_code","refresh_token"]}')" | jq -r .pk)
    echo "  Authentik: OIDC client $slug" >&2
  else
    ak -X PATCH "$AK/providers/oauth2/$pk/" -d "$(jq -n --argjson r "$uris" --argjson s "$SCOPES" '{redirect_uris:$r,property_mappings:$s,grant_types:["authorization_code","refresh_token"]}')" >/dev/null
  fi
  app "$slug" "$name" "$pk" "$url"
  ak "$AK/providers/oauth2/$pk/" | jq -r --arg s "$slug" --arg i "https://$AUTH/application/o/$slug/" \
    '"[\($s)]\n  issuer:        \($i)\n  client id:     \(.client_id)\n  client secret: \(.client_secret)\n"'
}
D=${DOMAIN//./\\.}
CLIENTS=$(
oidc proxmox "Proxmox (homelab1)" "https://pve.$DOMAIN" <<EOF
regex ^https://(pve\.$D|192\.168\.4\.209:8006)/?$
EOF
oidc proxmox-plex "Proxmox (plex-proxmox)" "https://pve-plex.$DOMAIN" <<EOF
regex ^https://(pve-plex\.$D|192\.168\.4\.215:8006)/?$
EOF
oidc grafana "Grafana" "https://grafana.$DOMAIN" <<EOF
strict https://grafana.$DOMAIN/login/generic_oauth
EOF
oidc immich "Immich" "https://immich.$DOMAIN" <<EOF
strict app.immich:///oauth-callback
strict https://immich.$DOMAIN/auth/login
strict https://immich.$DOMAIN/user-settings
strict https://immich.$DOMAIN/api/oauth/mobile-redirect
EOF
oidc audiobookshelf "Audiobookshelf" "https://audiobookshelf.$DOMAIN" <<EOF
regex ^https://audiobookshelf\.$D(/audiobookshelf)?/auth/openid/(callback|mobile-redirect)$
strict audiobookshelf://oauth
EOF
oidc beszel "Beszel" "https://beszel.$DOMAIN" <<EOF
strict https://beszel.$DOMAIN/api/oauth2-redirect
EOF
oidc jellyfin "Jellyfin" "https://jellyfin.$DOMAIN" <<EOF
regex ^https://jellyfin\.$D/sso/OID/(redirect|r)/authentik$
EOF
)
install -m 600 /dev/null /root/sso-clients.txt
printf '%s\n' "$CLIENTS" > /root/sso-clients.txt
echo "  OIDC client IDs/secrets: /root/sso-clients.txt"
get() { awk -v s="[$1]" -v k="$2" '$0==s{f=1;next} /^\[/{f=0} f && index($0,k":"){sub(/^[^:]*:[ ]*/,"");print;exit}' /root/sso-clients.txt; }

# ntfy alerts: errors, config problems, updates (built-in rules) + failed logins
MAP=$(ak "$AK/propertymappings/notification/?name=ntfy-homelab" | jq -r '.results[0].pk // empty')
if [ -z "$MAP" ]; then
  MAP=$(ak -X POST "$AK/propertymappings/notification/" -d "$(jq -n --arg t "$NTFY_TOPIC" '{name:"ntfy-homelab",
    expression:("return {\"topic\": \""+$t+"\", \"title\": \"Authentik: \" + str(notification.severity), \"message\": notification.body[:1000], \"tags\": [\"key\"]}")}')" | jq -r .pk)
fi
TR=$(ak "$AK/events/transports/?name=ntfy" | jq -r '.results[0].pk // empty')
if [ -z "$TR" ]; then
  TR=$(ak -X POST "$AK/events/transports/" -d "$(jq -n --arg m "$MAP" '{name:"ntfy",mode:"webhook",webhook_url:"https://ntfy.sh/",webhook_mapping_body:$m,send_once:true}')" 2>/dev/null | jq -r '.pk // empty') ||
  TR=$(ak -X POST "$AK/events/transports/" -d "$(jq -n --arg m "$MAP" '{name:"ntfy",mode:"webhook",webhook_url:"https://ntfy.sh/",webhook_mapping:$m,send_once:true}')" | jq -r .pk)
  echo "  Authentik: ntfy transport"
fi
POL=$(ak "$AK/policies/event_matcher/?name=login-failed" | jq -r '.results[0].pk // empty')
[ -n "$POL" ] || POL=$(ak -X POST "$AK/policies/event_matcher/" -d '{"name":"login-failed","action":"login_failed"}' | jq -r .pk)
RULE=$(ak "$AK/events/rules/?name=ntfy-login-failed" | jq -r '.results[0].pk // empty')
if [ -z "$RULE" ]; then
  RULE=$(ak -X POST "$AK/events/rules/" -d "$(jq -n --arg t "$TR" --arg g "$ADMINS" '{name:"ntfy-login-failed",severity:"warning",transports:[$t],destination_group:$g}')" 2>/dev/null | jq -r '.pk // empty') ||
  RULE=$(ak -X POST "$AK/events/rules/" -d "$(jq -n --arg t "$TR" --arg g "$ADMINS" '{name:"ntfy-login-failed",severity:"warning",transports:[$t],group:$g}')" | jq -r .pk)
  ak -X POST "$AK/policies/bindings/" -d "$(jq -n --arg t "$RULE" --arg p "$POL" '{target:$t,policy:$p,order:0,enabled:true}')" >/dev/null
fi
for r in default-notify-exception default-notify-configuration-error default-notify-update; do
  R=$(ak "$AK/events/rules/?name=$r" | jq '.results[0] // empty')
  [ -n "$R" ] || continue
  jq -e --arg t "$TR" '.transports|index($t)' <<<"$R" >/dev/null && continue
  ak -X PATCH "$AK/events/rules/$(jq -r .pk <<<"$R")/" -d "$(jq --arg t "$TR" '{transports:((.transports+[$t])|unique)}' <<<"$R")" >/dev/null
  echo "  Authentik: $r -> ntfy"
done

# Read-only-ish token for the Homepage widget
if pct status 111 2>/dev/null | grep -q running && ! pct exec 111 -- grep -q "^HOMEPAGE_VAR_AUTHENTIK_KEY='..*'" /etc/homepage/vars.env 2>/dev/null; then
  ME=$(ak "$AK/core/users/me/" | jq -r .user.pk)
  ak "$AK/core/tokens/homepage/" >/dev/null 2>&1 || ak -X POST "$AK/core/tokens/" -d "$(jq -n --argjson u "$ME" \
    '{identifier:"homepage",intent:"api",user:$u,expiring:false,description:"Homepage widget"}')" >/dev/null
  KEY=$(ak "$AK/core/tokens/homepage/view_key/" | jq -r .key)
  if pct exec 111 -- /usr/local/bin/homepage-setvar AUTHENTIK_KEY "$KEY" >/dev/null &&
     pct exec 111 -- /usr/local/bin/homepage-setvar --restart >/dev/null; then
    echo "  Homepage: Authentik widget key set"
  else
    echo "  Homepage: couldn't set the Authentik key (run homepage/setup-homelab1.sh first, then re-run this)"
  fi
fi

fi  # UNDO = 0
### 2. NPM: Authentik login in front of the gated names
NPM="http://$NPM_IP:81/api"
TOKEN=$(curl -fsS -m 10 -X POST "$NPM/tokens" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg i "$NPM_USER" --arg s "$NPM_PASS" '{identity:$i,secret:$s}')" | jq -r .token)
[ -n "$TOKEN" ] && [ "$TOKEN" != null ] || { echo "NPM login failed"; exit 1; }
npm() { curl -fsS -m 30 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' "$@"; }
hostlist=$(npm "$NPM/nginx/proxy-hosts")
fa_conf() {   # fa_conf BYPASS
  local re=""
  case "$1" in
    arr)      re='^/(api|feed|ping)(/|$)' ;;
    prowlarr) re='^/(api|feed|ping|[0-9]+/(api|download))(/|$)' ;;
    api)      re='^/api(/|$)' ;;
  esac
  cat <<EOF
# Authentik forward auth (sso/setup-sso.sh)
proxy_buffers 8 16k;
proxy_buffer_size 32k;
port_in_redirect off;
EOF
  [ -n "$re" ] && cat <<EOF
# API calls skip the login page; the app still checks its API key
location ~ $re {
  proxy_set_header Upgrade \$http_upgrade;
  proxy_set_header Connection \$http_connection;
  proxy_http_version 1.1;
  include /etc/nginx/conf.d/include/proxy.conf;
}
EOF
  cat <<EOF
location / {
  auth_request /outpost.goauthentik.io/auth/nginx;
  error_page 401 = @goauthentik_proxy_signin;
  auth_request_set \$auth_cookie \$upstream_http_set_cookie;
  add_header Set-Cookie \$auth_cookie;
  auth_request_set \$authentik_username \$upstream_http_x_authentik_username;
  auth_request_set \$authentik_email \$upstream_http_x_authentik_email;
  proxy_set_header X-authentik-username \$authentik_username;
  proxy_set_header X-authentik-email \$authentik_email;
  proxy_set_header Upgrade \$http_upgrade;
  proxy_set_header Connection \$http_connection;
  proxy_http_version 1.1;
  include /etc/nginx/conf.d/include/proxy.conf;
}
location /outpost.goauthentik.io {
  proxy_pass http://$AK_IP:9000/outpost.goauthentik.io;
  proxy_set_header Host \$host;
  proxy_set_header X-Original-URL \$scheme://\$http_host\$request_uri;
  add_header Set-Cookie \$auth_cookie;
  auth_request_set \$auth_cookie \$upstream_http_set_cookie;
  proxy_pass_request_body off;
  proxy_set_header Content-Length "";
}
location @goauthentik_proxy_signin {
  internal;
  add_header Set-Cookie \$auth_cookie;
  return 302 /outpost.goauthentik.io/start?rd=\$scheme://\$http_host\$request_uri;
}
EOF
}
if [ $UNDO = 1 ]; then
  while read -r n _; do
    [ -z "$n" ] && continue
    id=$(jq -r --arg d "$n.$DOMAIN" '.[]|select(.domain_names|index($d))|.id' <<<"$hostlist" | head -1)
    [ -n "$id" ] || continue
    npm -X PUT "$NPM/nginx/proxy-hosts/$id" -d '{"advanced_config":""}' >/dev/null && echo "  NPM: $n.$DOMAIN gate removed"
  done <<<"$GATED"
  exit 0
fi
changed=0
while read -r n bp; do
  [ -z "$n" ] && continue
  id=""; cur=""
  d="$n.$DOMAIN"; want=$(fa_conf "$bp")
  read -r id cur < <(jq -r --arg d "$d" '.[]|select(.domain_names|index($d))|"\(.id) \(.advanced_config|@base64)"' <<<"$hostlist" | head -1) || true
  [ -n "${id:-}" ] || { echo "  NPM: no proxy host for $d (run reverse-proxy/setup-proxy.sh)"; continue; }
  [ "$(base64 -d <<<"$cur")" = "$want" ] && continue
  npm -X PUT "$NPM/nginx/proxy-hosts/$id" -d "$(jq -n --arg a "$want" '{advanced_config:$a}')" >/dev/null
  echo "  NPM: $d now behind Authentik"; changed=$((changed+1))
done <<<"$GATED"
echo "NPM: $changed hosts updated"

### 3. Proxmox realm on this host
if ! pveum realm list --output-format json | jq -e '.[]|select(.realm=="authentik")' >/dev/null; then
  pveum realm add authentik --type openid --issuer-url "https://$AUTH/application/o/proxmox/" \
    --client-id "$(get proxmox 'client id')" --client-key "$(get proxmox 'client secret')" \
    --username-claim username --scopes "openid email profile" --autocreate 0 --comment "Authentik SSO"
  echo "  Proxmox: realm 'authentik' added"
fi
pveum user list --output-format json | jq -e --arg u "$AK_USER@authentik" '.[]|select(.userid==$u)' >/dev/null ||
  { pveum user add "$AK_USER@authentik" --comment "Authentik SSO"; pveum acl modify / --users "$AK_USER@authentik" --roles Administrator
    echo "  Proxmox: $AK_USER@authentik is Administrator"; }

### 4. Grafana (CT 112)
if pct status 112 2>/dev/null | grep -q running; then
  cat > /tmp/grafana-sso.env <<EOF
GF_SERVER_ROOT_URL=https://grafana.$DOMAIN/
GF_AUTH_GENERIC_OAUTH_ENABLED=true
GF_AUTH_GENERIC_OAUTH_NAME=authentik
GF_AUTH_GENERIC_OAUTH_CLIENT_ID=$(get grafana 'client id')
GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=$(get grafana 'client secret')
GF_AUTH_GENERIC_OAUTH_SCOPES=openid profile email
GF_AUTH_GENERIC_OAUTH_AUTH_URL=https://$AUTH/application/o/authorize/
GF_AUTH_GENERIC_OAUTH_TOKEN_URL=https://$AUTH/application/o/token/
GF_AUTH_GENERIC_OAUTH_API_URL=https://$AUTH/application/o/userinfo/
GF_AUTH_GENERIC_OAUTH_LOGIN_ATTRIBUTE_PATH=preferred_username
GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH="contains(groups, 'authentik Admins') && 'Admin' || 'Viewer'"
GF_AUTH_SIGNOUT_REDIRECT_URL=https://$AUTH/application/o/grafana/end-session/
EOF
  pct push 112 /tmp/grafana-sso.env /etc/grafana/sso.env --perms 640; rm -f /tmp/grafana-sso.env
  pct exec 112 -- bash -c 'chgrp grafana /etc/grafana/sso.env; mkdir -p /etc/systemd/system/grafana-server.service.d
    printf "[Service]\nEnvironmentFile=/etc/grafana/sso.env\n" > /etc/systemd/system/grafana-server.service.d/sso.conf
    systemctl daemon-reload; systemctl restart grafana-server'
  echo "  Grafana: SSO on (local admin login still works)"
fi

cat <<EOF

Done. Next:
  - Test:  DOMAIN=$DOMAIN NPM_IP=$NPM_IP bash $0 --check
  - plex-proxmox Proxmox realm + the apps you set up by hand: SETUP.md step 4
    (client IDs/secrets are in /root/sso-clients.txt)
EOF
