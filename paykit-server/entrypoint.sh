#!/bin/sh
# Railway Paykit Server entrypoint. Generates the closed-schema TOML config
# from environment, following the generated-config contract the payments-env
# overlay used (paykit-server docs/local-locks-demo.md), with the hosted
# staging-network differences:
#
#   - [locks] trusted_public_key is injected via env: it must be the deployed
#     Lock Server's credentials.lock_server_public_key (immutable deployment
#     metadata - if the Lock Server identity ever changes, the Paykit database
#     must be reset coherently, exactly like the compose lock-home volume note).
#   - [paykit] network = "mainnet": the Paykit SDK resolves identities via the
#     default public pkarr relays, which the official staging Pubky network
#     publishes to, so staging app users can be creators/readers.
#   - [bitcoin] network = "regtest" and [electrum] points at the private
#     Fulcrum endpoint. REGTEST ONLY.
set -eu

: "${PAYKIT_TRUSTED_LOCKS_PUBLIC_KEY:?PAYKIT_TRUSTED_LOCKS_PUBLIC_KEY is required}"
: "${PAYKIT_DATABASE_URL:?PAYKIT_DATABASE_URL is required}"
: "${PAYKIT_MASTER_KEY:?PAYKIT_MASTER_KEY is required}"
: "${PAYKIT_SETUP_ALLOWED_ORIGINS:?PAYKIT_SETUP_ALLOWED_ORIGINS is required (comma-separated origins)}"

electrum_endpoint="${PAYKIT_ELECTRUM_ENDPOINT:-tcp://fulcrum.railway.internal:50001}"
listen_addr="${PAYKIT_LISTEN_ADDR:-[::]:3001}"

origins_toml="$(printf '%s' "$PAYKIT_SETUP_ALLOWED_ORIGINS" | awk -F',' '{
  out = "";
  for (i = 1; i <= NF; i++) {
    gsub(/^[ \t]+|[ \t]+$/, "", $i);
    if ($i != "") out = out (out == "" ? "" : ", ") "\"" $i "\"";
  }
  print out;
}')"

config_path="${PAYKIT_CONFIG:-/home/paykit/paykit-server.toml}"
export PAYKIT_CONFIG="$config_path"

cat > "$config_path" <<EOF
[http]
listen_addr = "$listen_addr"

[locks]
trusted_public_key = "$PAYKIT_TRUSTED_LOCKS_PUBLIC_KEY"

[setup]
allowed_origins = [$origins_toml]

[paykit]
receiver_path = "bitkit/server"
receiver_path_priority = ["bitkit"]
network = "mainnet"

[bitcoin]
network = "regtest"

[electrum]
endpoint = "$electrum_endpoint"
poll_interval = "1s"

[outbox]
poll_interval = "500ms"
EOF

echo "[paykit-railway] starting paykit-server (trusted locks key $PAYKIT_TRUSTED_LOCKS_PUBLIC_KEY, electrum $electrum_endpoint)"
exec /usr/local/bin/paykit-server
