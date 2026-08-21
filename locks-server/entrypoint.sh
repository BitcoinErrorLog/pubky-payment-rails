#!/bin/sh
# Railway Lock Server entrypoint, adapted from the payments-env overlay
# (overlay/locks-server-entrypoint-paykit.sh) with the differences a hosted
# staging-network deployment requires:
#
#   1. The signing identity is injected via LOCKS_KEYPAIR_SEED instead of
#      being generated into a shared volume: on Railway there is no volume
#      shared with the Paykit Server, and Paykit's trusted Locks key is
#      immutable deployment metadata, so the identity must be stable and
#      known before either service deploys.
#   2. [pubky] network = "mainnet": the Lock Server resolves identities via
#      the Pubky SDK's default relays (pkarr.pubky.app / pkarr.pubky.org),
#      which are exactly the relays the official staging Pubky network
#      (homeserver.staging.pubky.app) publishes to. App users on the staging
#      network can therefore be creators/readers directly.
#   3. [pkdns] advertises the Railway public HTTPS domain (ICANN record) and
#      publishes through the public pkarr relays.
#   4. The Paykit Server is reached over Railway private networking.
set -eu

: "${LOCKS_KEYPAIR_SEED:?LOCKS_KEYPAIR_SEED is required (keypair-seed:<base64url-32B>)}"
: "${LOCKS_PUBLIC_KEY:?LOCKS_PUBLIC_KEY is required (pubky<z-base32> derived from the seed)}"
: "${LOCKS_PUBLIC_DOMAIN:?LOCKS_PUBLIC_DOMAIN is required (Railway public domain, no scheme)}"
: "${PUBKY_LOCK_DATABASE_URL:?PUBKY_LOCK_DATABASE_URL is required}"
: "${PUBKY_LOCK_CREATOR_AUTH_ENCRYPTION_KEY:?PUBKY_LOCK_CREATOR_AUTH_ENCRYPTION_KEY is required}"

service_home="/var/lib/pubky-lock/.pubky-lock"
secret_path="$service_home/secret.sess"
config_path="/var/lib/pubky-lock/config.railway.toml"

paykit_server_url="${LOCKS_PAYKIT_SERVER_URL:-http://paykit-server.railway.internal:3001}"
paykit_min_confirmations="${LOCKS_PAYKIT_MIN_CONFIRMATIONS:-1}"
bind_addr="${LOCKS_BIND_ADDR:-[::]:3000}"
runtime_environment="${LOCKS_RUNTIME_ENVIRONMENT:-staging}"
public_ip="${LOCKS_PKDNS_PUBLIC_IP:-127.0.0.1}"
allowed_origins="${LOCKS_ALLOWED_RETURN_ORIGINS:?LOCKS_ALLOWED_RETURN_ORIGINS is required (comma-separated origins)}"

mkdir -p "$service_home"
umask 077
printf '%s' "$LOCKS_KEYPAIR_SEED" > "$secret_path"

origins_toml="$(printf '%s' "$allowed_origins" | awk -F',' '{
  out = "";
  for (i = 1; i <= NF; i++) {
    gsub(/^[ \t]+|[ \t]+$/, "", $i);
    if ($i != "") out = out (out == "" ? "" : ", ") "\"" $i "\"";
  }
  print out;
}')"

cat > "$config_path" <<EOF
bind_addr = "$bind_addr"

[credentials]
lock_server_secret_key = "$secret_path"
lock_server_public_key = "$LOCKS_PUBLIC_KEY"
max_ttl_seconds = 900

[database]
url_env = "PUBKY_LOCK_DATABASE_URL"
max_connections = 10
run_migrations_on_startup = true

[worker]
enabled = true
poll_interval_ms = 250
claim_timeout_seconds = 60
worker_id = "railway-worker"

[runtime]
environment = "$runtime_environment"

[creator_authority_acquisition]
enabled = true
method = "legacy-connect"
frontend_session_ttl_seconds = 86400
frontend_session_code_ttl_seconds = 120

[creator_authority_acquisition.legacy_connect]
allowed_return_origins = [$origins_toml]

[secrets]
creator_authority_key_env = "PUBKY_LOCK_CREATOR_AUTH_ENCRYPTION_KEY"

[logging]
level = "${LOCKS_LOG_LEVEL:-info}"

[pubky]
network = "mainnet"

[pkdns]
public_ip = "$public_ip"
public_icann_http_port = 443
icann_domain = "$LOCKS_PUBLIC_DOMAIN"
pkarr_relays = ["https://pkarr.pubky.app", "https://pkarr.pubky.org"]
key_republisher_interval_seconds = 3600

[paykit]
server_url = "$paykit_server_url"
minimum_confirmations = $paykit_min_confirmations

[rate_limits.verification_submission]
enabled = true
max_requests = 60
window_seconds = 60

[content_locks]
max_resource_bytes = 10000000
max_resources = 10
max_total_resource_bytes = 100000000
EOF

echo "[locks-railway] starting locks-server (identity $LOCKS_PUBLIC_KEY, domain $LOCKS_PUBLIC_DOMAIN)"
exec locks-server --config "$config_path"
