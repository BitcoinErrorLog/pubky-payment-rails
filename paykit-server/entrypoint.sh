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

# Optional marketplace transaction-service trust anchors: when set, requests
# signed by any of these keys are accepted on the signed business routes
# (payment requests, status lookups) exactly like Lock Server signatures.
# MARKETPLACE_TRUSTED_PUBLIC_KEY (one key) and MARKETPLACE_TRUSTED_PUBLIC_KEYS
# (comma-separated list, whitespace tolerated) are mutually exclusive and map
# to the TOML single/list forms the fork accepts. Key values are never logged
# - only the count.
valid_pubky_key() {
  # Canonical pubky public key: 52 z-base-32 characters (a subset of [a-z0-9]).
  [ "${#1}" -eq 52 ] || return 1
  case "$1" in
    *[!a-z0-9]*) return 1 ;;
  esac
  return 0
}

marketplace_section=""
marketplace_key_count=0
if [ -n "${MARKETPLACE_TRUSTED_PUBLIC_KEY:-}" ] && [ -n "${MARKETPLACE_TRUSTED_PUBLIC_KEYS:-}" ]; then
  echo "[paykit-railway] error: MARKETPLACE_TRUSTED_PUBLIC_KEY and MARKETPLACE_TRUSTED_PUBLIC_KEYS are mutually exclusive; set exactly one" >&2
  exit 1
elif [ -n "${MARKETPLACE_TRUSTED_PUBLIC_KEYS:-}" ]; then
  marketplace_keys_toml=""
  for key in $(printf '%s' "$MARKETPLACE_TRUSTED_PUBLIC_KEYS" | tr ',' '\n'); do
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    [ -n "$key" ] || continue
    if ! valid_pubky_key "$key"; then
      echo "[paykit-railway] error: MARKETPLACE_TRUSTED_PUBLIC_KEYS entry $((marketplace_key_count + 1)) is not a 52-character z-base-32 pubky public key" >&2
      exit 1
    fi
    marketplace_key_count=$((marketplace_key_count + 1))
    if [ -z "$marketplace_keys_toml" ]; then
      marketplace_keys_toml="\"$key\""
    else
      marketplace_keys_toml="$marketplace_keys_toml, \"$key\""
    fi
  done
  if [ "$marketplace_key_count" -eq 0 ]; then
    echo "[paykit-railway] error: MARKETPLACE_TRUSTED_PUBLIC_KEYS is set but contains no keys" >&2
    exit 1
  fi
  marketplace_section="[marketplace]
trusted_public_keys = [$marketplace_keys_toml]
"
elif [ -n "${MARKETPLACE_TRUSTED_PUBLIC_KEY:-}" ]; then
  if ! valid_pubky_key "$MARKETPLACE_TRUSTED_PUBLIC_KEY"; then
    echo "[paykit-railway] error: MARKETPLACE_TRUSTED_PUBLIC_KEY is not a 52-character z-base-32 pubky public key" >&2
    exit 1
  fi
  marketplace_key_count=1
  marketplace_section="[marketplace]
trusted_public_key = \"$MARKETPLACE_TRUSTED_PUBLIC_KEY\"
"
fi

# Optional HTTP relay inbox override for the manual claim session loopback;
# the default is the public https://httprelay.pubky.app/inbox.
auth_relay_line=""
if [ -n "${PAYKIT_AUTH_RELAY:-}" ]; then
  auth_relay_line="auth_relay = \"$PAYKIT_AUTH_RELAY\""
fi

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

$marketplace_section
[setup]
allowed_origins = [$origins_toml]

[paykit]
receiver_path = "bitkit/server"
receiver_path_priority = ["bitkit"]
network = "mainnet"
$auth_relay_line

[bitcoin]
network = "regtest"

[electrum]
endpoint = "$electrum_endpoint"
poll_interval = "1s"

[outbox]
poll_interval = "500ms"
EOF

if [ "$marketplace_key_count" -gt 0 ]; then
  echo "[paykit-railway] marketplace trusted signing keys configured: $marketplace_key_count"
fi
echo "[paykit-railway] starting paykit-server (trusted locks key $PAYKIT_TRUSTED_LOCKS_PUBLIC_KEY, electrum $electrum_endpoint)"
if [ "${PAYKIT_ENTRYPOINT_RENDER_ONLY:-0}" = "1" ]; then
  echo "[paykit-railway] PAYKIT_ENTRYPOINT_RENDER_ONLY=1: wrote $config_path, not starting server"
  exit 0
fi
exec /usr/local/bin/paykit-server
