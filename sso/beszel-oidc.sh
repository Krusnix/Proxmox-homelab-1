#!/bin/bash
# Turn on "Login with Authentik" in Beszel (PocketBase) without the admin UI.
# Run on homelab1-proxmox after setup-sso.sh:  bash beszel-oidc.sh
# Asks for the Beszel/PocketBase superuser email + password; reads the client ID/secret from /root/sso-clients.txt.
set -euo pipefail
B=${BESZEL_URL:-http://192.168.4.217:8090}; AUTH=https://auth.krusnix.net/application/o
get() { awk -v s="[beszel]" -v k="$1" '$0==s{f=1;next} /^\[/{f=0} f && index($0,k":"){sub(/^[^:]*:[ ]*/,"");print;exit}' /root/sso-clients.txt; }
ID=$(get 'client id'); SECRET=$(get 'client secret')
[ -n "$ID" ] && [ -n "$SECRET" ] || { echo "No [beszel] block in /root/sso-clients.txt (run setup-sso.sh first)"; exit 1; }
read -rp "Beszel superuser email: " U; read -rsp "Password: " P; echo
TOKEN=$(curl -fsS -X POST "$B/api/collections/_superusers/auth-with-password" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg i "$U" --arg p "$P" '{identity:$i,password:$p}')" | jq -r .token)
[ -n "$TOKEN" ] && [ "$TOKEN" != null ] || { echo "Superuser login failed"; exit 1; }
curl -fsS -X PATCH "$B/api/collections/users" -H "Authorization: $TOKEN" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg id "$ID" --arg s "$SECRET" --arg a "$AUTH" '{oauth2:{enabled:true,providers:[{name:"oidc",
    displayName:"Authentik",clientId:$id,clientSecret:$s,authURL:($a+"/authorize/"),tokenURL:($a+"/token/"),
    userInfoURL:($a+"/userinfo/"),pkce:true}]}}')" | jq -c '{oauth2_enabled:.oauth2.enabled, providers:[.oauth2.providers[].name]}'
pct exec 109 -- grep -q auth.krusnix.net /etc/hosts 2>/dev/null || pct exec 109 -- bash -c "echo '192.168.4.156 auth.krusnix.net' >> /etc/hosts"
echo "Done. Log out of Beszel; the login page now has an Authentik button."
