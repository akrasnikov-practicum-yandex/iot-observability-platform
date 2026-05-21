#!/bin/sh
# Registers proxy hosts in Nginx Proxy Manager via its REST API.
# Skips hosts that already exist (idempotent).
set -e

NPM_URL="http://nginx-proxy-manager:81"
EMAIL="${NPM_ADMIN_EMAIL:-admin@example.com}"
PASSWORD="${NPM_ADMIN_PASSWORD:-changeme}"

echo "Waiting for NPM API..."
until curl -sf -o /dev/null "${NPM_URL}/api/"; do
  sleep 5
done

TOKEN=$(curl -sf -X POST "${NPM_URL}/api/tokens" \
  -H "Content-Type: application/json" \
  -d "{\"identity\":\"${EMAIL}\",\"secret\":\"${PASSWORD}\"}" \
  | sed 's/.*"token":"\([^"]*\)".*/\1/')

if [ -z "${TOKEN}" ]; then
  echo "ERROR: NPM auth failed — check NPM_ADMIN_EMAIL / NPM_ADMIN_PASSWORD" >&2
  exit 1
fi

EXISTING=$(curl -sf "${NPM_URL}/api/nginx/proxy-hosts" \
  -H "Authorization: Bearer ${TOKEN}")

create_host() {
  domain=$1 host=$2 port=$3
  if echo "${EXISTING}" | grep -q "\"${domain}\""; then
    echo "skip (exists): ${domain}"
    return
  fi
  curl -sf -X POST "${NPM_URL}/api/nginx/proxy-hosts" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"domain_names\":[\"${domain}\"],
      \"forward_scheme\":\"http\",
      \"forward_host\":\"${host}\",
      \"forward_port\":${port},
      \"access_list_id\":\"0\",
      \"certificate_id\":0,
      \"meta\":{\"letsencrypt_agree\":false,\"dns_challenge\":false},
      \"advanced_config\":\"\",
      \"locations\":[],
      \"block_exploits\":false,
      \"caching_enabled\":false,
      \"allow_websocket_upgrade\":true,
      \"http2_support\":false,
      \"hsts_enabled\":false,
      \"hsts_subdomains\":false,
      \"ssl_forced\":false
    }" > /dev/null
  echo "created: ${domain} -> ${host}:${port}"
}

create_host "grafana.localhost" "grafana" 3000
create_host "minio.localhost"   "minio"   9001
create_host "loki.localhost"    "loki"    3100
