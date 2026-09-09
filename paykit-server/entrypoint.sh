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
#
# Variables (design: mp-btc-design docs/ecommerce/btc-mainnet.md r13, §B.1/§C):
#
#   Required, no default:
#     PAYKIT_TRUSTED_LOCKS_PUBLIC_KEY  pubky key of the Lock Server (above).
#     PAYKIT_DATABASE_URL              postgres://... for THIS stack only -
#                                      never shared across networks or roles.
#     PAYKIT_MASTER_KEY                unpadded base64url of exactly 32 bytes,
#                                      per-stack (never echoed or persisted here).
#     PAYKIT_SETUP_ALLOWED_ORIGINS     comma-separated exact origins.
#     PAYKIT_STACK_ROLE                production|proof. Required on every
#                                      network: the fork's DeploymentInvariants
#                                      adopts it once on first boot and refuses
#                                      every later mismatch, so a database can
#                                      never be booted by the wrong role.
#   Optional, with defaults:
#     PAYKIT_BITCOIN_NETWORK           regtest (default) | mainnet | testnet |
#                                      signet; any other value fails closed
#                                      before the config is written.
#     PAYKIT_ELECTRUM_POLL_INTERVAL    1s (default); must match ^[0-9]+(ms|s|m)$
#                                      and be >= 30s when the network is not
#                                      regtest (30s for the mainnet stacks).
#     PAYKIT_ELECTRUM_ENDPOINT         tcp://fulcrum.railway.internal:50001
#                                      (default, regtest); the mainnet stacks
#                                      use ssl://bitkit.to:9999 per §B.2, with
#                                      ssl://electrum.blockstream.info:50002
#                                      as documented failover only.
#     PAYKIT_BITCOIN_CREATION_ENABLED  true|false; unset renders nothing and the
#                                      fork default (true) applies. The §C.16
#                                      kill switch: false refuses new payment
#                                      requests while activate/void/resolve and
#                                      existing-invoice observation keep working.
#     PAYKIT_LISTEN_ADDR               [::]:3001 (default).
#     PAYKIT_AUTH_RELAY                unset (default) = the public
#                                      https://httprelay.pubky.app/inbox.
#     MARKETPLACE_TRUSTED_PUBLIC_KEY / MARKETPLACE_TRUSTED_PUBLIC_KEYS
#                                      unset (default) = no marketplace trust
#                                      anchors; the two forms are mutually
#                                      exclusive. Only the count is logged.
#     PAYKIT_CONFIG                    /home/paykit/paykit-server.toml (default).
#     PAYKIT_ENTRYPOINT_RENDER_ONLY    0 (default); 1 writes the config and
#                                      exits without starting the server.
#     PAYKIT_IMAGE_DIGEST              sha256:... the operator pinned this
#                                      service to (§C.8: one digest D across
#                                      stacks). IMAGE_DIGEST is a fallback for
#                                      a Dockerfile-baked value; "unknown" if
#                                      neither is set. Printed once at boot,
#                                      never any secret.
set -eu

: "${PAYKIT_TRUSTED_LOCKS_PUBLIC_KEY:?PAYKIT_TRUSTED_LOCKS_PUBLIC_KEY is required}"
: "${PAYKIT_DATABASE_URL:?PAYKIT_DATABASE_URL is required}"
: "${PAYKIT_MASTER_KEY:?PAYKIT_MASTER_KEY is required}"
: "${PAYKIT_SETUP_ALLOWED_ORIGINS:?PAYKIT_SETUP_ALLOWED_ORIGINS is required (comma-separated origins)}"

if [ -z "${PAYKIT_STACK_ROLE:-}" ]; then
  echo "[paykit-railway] PAYKIT_STACK_ROLE is required (production|proof)" >&2
  exit 1
fi

electrum_endpoint="${PAYKIT_ELECTRUM_ENDPOINT:-tcp://fulcrum.railway.internal:50001}"
listen_addr="${PAYKIT_LISTEN_ADDR:-[::]:3001}"
bitcoin_network="${PAYKIT_BITCOIN_NETWORK:-regtest}"
electrum_poll_interval="${PAYKIT_ELECTRUM_POLL_INTERVAL:-1s}"

case "$bitcoin_network" in
  mainnet|testnet|signet|regtest) ;;
  *)
    echo "[paykit-railway] PAYKIT_BITCOIN_NETWORK must be one of mainnet|testnet|signet|regtest (got '$bitcoin_network')" >&2
    exit 1
    ;;
esac

if ! printf '%s\n' "$electrum_poll_interval" | awk '/^[0-9]+(ms|s|m)$/ { found = 1 } END { exit !found }'; then
  echo "[paykit-railway] PAYKIT_ELECTRUM_POLL_INTERVAL must match ^[0-9]+(ms|s|m)$ (got '$electrum_poll_interval')" >&2
  exit 1
fi

# The >=30s floor for non-regtest networks: match the TWO-char "ms" suffix
# BEFORE the one-char "s"/"m" suffixes (every "ms" value also ends in "s";
# taking the last char only strips ONE character, coercing e.g. "30ms" to
# 30 "seconds" and waving a 30ms cadence through the floor). Integer compare
# per unit, no awk. The regex gate above guarantees ^[0-9]+(ms|s|m)$, so
# poll_num is always a non-negative integer here.
if [ "$bitcoin_network" != "regtest" ]; then
  poll_floor_ok=1
  case "$electrum_poll_interval" in
    *ms)
      poll_num=${electrum_poll_interval%ms}
      [ "$poll_num" -ge 30000 ] || poll_floor_ok=0
      ;;
    *s)
      poll_num=${electrum_poll_interval%s}
      [ "$poll_num" -ge 30 ] || poll_floor_ok=0
      ;;
    *m)
      # Any whole minute is >= 60s: always above the floor.
      ;;
  esac
  if [ "$poll_floor_ok" -eq 0 ]; then
    echo "[paykit-railway] PAYKIT_ELECTRUM_POLL_INTERVAL must be at least 30s when PAYKIT_BITCOIN_NETWORK is not regtest (got '$electrum_poll_interval')" >&2
    exit 1
  fi
fi

stack_role_line=""
case "$PAYKIT_STACK_ROLE" in
  production|proof) ;;
  *)
    echo "[paykit-railway] PAYKIT_STACK_ROLE must be one of production|proof (got '$PAYKIT_STACK_ROLE')" >&2
    exit 1
    ;;
esac
stack_role_line="[deployment]
stack_role = \"$PAYKIT_STACK_ROLE\"
"

creation_enabled_line=""
if [ -n "${PAYKIT_BITCOIN_CREATION_ENABLED:-}" ]; then
  case "$PAYKIT_BITCOIN_CREATION_ENABLED" in
    true|false) ;;
    *)
      echo "[paykit-railway] PAYKIT_BITCOIN_CREATION_ENABLED must be one of true|false (got '$PAYKIT_BITCOIN_CREATION_ENABLED')" >&2
      exit 1
      ;;
  esac
  creation_enabled_line="creation_enabled = $PAYKIT_BITCOIN_CREATION_ENABLED"
fi

electrum_host="${electrum_endpoint#*://}"
electrum_host="${electrum_host##*@}"

# §C row 8: one pinned image digest D across every stack, printed on every
# boot line so each proof can assert it observed exactly D. Railway exposes no
# image-digest deploy variable for Dockerfile builds, so the IaC script wires
# PAYKIT_IMAGE_DIGEST from the same digest the service is pinned to; a
# Dockerfile-baked IMAGE_DIGEST is honored as a fallback. Never a secret.
image_digest="${PAYKIT_IMAGE_DIGEST:-${IMAGE_DIGEST:-unknown}}"

# Optional marketplace transaction-service trust anchors: when set, requests
# signed by any of these keys are accepted on the signed business routes
# (payment requests, status lookups) exactly like Lock Server signatures.
# MARKETPLACE_TRUSTED_PUBLIC_KEY (one key) and MARKETPLACE_TRUSTED_PUBLIC_KEYS
# (comma-separated list, whitespace tolerated) are mutually exclusive and map
# to the TOML single/list forms the fork accepts. Key values are never logged
# - only the count.
valid_pubky_key() {
  # Parser contract (proven against the fork's config parser in
  # BitcoinErrorLog/paykit-server @ 37ffdd4): exactly 57 characters - the
  # "pubky" prefix plus a 52-character body in the z-base-32 alphabet
  # ybndrfg8ejkmcpqxot1uwisza345h769. Bare 52-char keys are rejected by the
  # fork parser (InvalidTrustedMarketplacePublicKey), so they are rejected
  # here too: accepting one would render TOML the server refuses to boot with.
  [ "${#1}" -eq 57 ] || return 1
  case "$1" in
    pubky*) ;;
    *) return 1 ;;
  esac
  case "${1#pubky}" in
    *[!ybndrfg8ejkmcpqxot1uwisza345h769]*) return 1 ;;
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
  # Split on commas with a set -f / while-read loop (no word splitting or
  # glob expansion of key material). The here-document keeps the loop in the
  # current shell so marketplace_key_count/marketplace_keys_toml survive;
  # the `|| [ -n "$key" ]` guard preserves a final line without a newline.
  # Empty entries (double/leading/trailing commas, whitespace-only entries)
  # fail fast with their 1-based entry index - never the value - instead of
  # being silently skipped: a skipped entry would boot the server with fewer
  # trust anchors than the operator configured. A trailing comma is caught
  # STRUCTURALLY before the loop (command substitution strips trailing
  # newlines, which would hide the empty final entry); no sentinel value is
  # used anywhere, so no key material can ever collide with one.
  case "$MARKETPLACE_TRUSTED_PUBLIC_KEYS" in
    *,)
      empty_entry_index=$(( $(printf '%s' "$MARKETPLACE_TRUSTED_PUBLIC_KEYS" | tr -cd ',' | wc -c) + 1 ))
      echo "[paykit-railway] error: MARKETPLACE_TRUSTED_PUBLIC_KEYS entry $empty_entry_index is empty; remove empty entries from the comma-separated list" >&2
      exit 1
      ;;
  esac
  entry_index=0
  set -f
  while IFS= read -r key || [ -n "$key" ]; do
    entry_index=$((entry_index + 1))
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    if [ -z "$key" ]; then
      echo "[paykit-railway] error: MARKETPLACE_TRUSTED_PUBLIC_KEYS entry $entry_index is empty; remove empty entries from the comma-separated list" >&2
      exit 1
    fi
    if ! valid_pubky_key "$key"; then
      echo "[paykit-railway] error: MARKETPLACE_TRUSTED_PUBLIC_KEYS entry $entry_index is not a 57-character pubky-prefixed z-base-32 public key" >&2
      exit 1
    fi
    marketplace_key_count=$((marketplace_key_count + 1))
    if [ -z "$marketplace_keys_toml" ]; then
      marketplace_keys_toml="\"$key\""
    else
      marketplace_keys_toml="$marketplace_keys_toml, \"$key\""
    fi
  done <<EOF_KEYS
$(printf '%s' "$MARKETPLACE_TRUSTED_PUBLIC_KEYS" | tr ',' '\n')
EOF_KEYS
  set +f
  if [ "$marketplace_key_count" -eq 0 ]; then
    echo "[paykit-railway] error: MARKETPLACE_TRUSTED_PUBLIC_KEYS is set but contains no keys" >&2
    exit 1
  fi
  marketplace_section="[marketplace]
trusted_public_keys = [$marketplace_keys_toml]
"
elif [ -n "${MARKETPLACE_TRUSTED_PUBLIC_KEY:-}" ]; then
  if ! valid_pubky_key "$MARKETPLACE_TRUSTED_PUBLIC_KEY"; then
    echo "[paykit-railway] error: MARKETPLACE_TRUSTED_PUBLIC_KEY is not a 57-character pubky-prefixed z-base-32 public key" >&2
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
network = "$bitcoin_network"
EOF

if [ -n "$creation_enabled_line" ]; then
  printf '%s\n' "$creation_enabled_line" >> "$config_path"
fi

printf '\n' >> "$config_path"
cat >> "$config_path" <<EOF
[electrum]
endpoint = "$electrum_endpoint"
poll_interval = "$electrum_poll_interval"

[outbox]
poll_interval = "500ms"
EOF

printf '%s' "$stack_role_line" >> "$config_path"

if [ "$marketplace_key_count" -gt 0 ]; then
  echo "[paykit-railway] marketplace trusted signing keys configured: $marketplace_key_count"
fi
echo "[paykit-railway] starting paykit-server (image $image_digest, network $bitcoin_network, stack_role $PAYKIT_STACK_ROLE, poll_interval $electrum_poll_interval, electrum $electrum_host)"
if [ "${PAYKIT_ENTRYPOINT_RENDER_ONLY:-0}" = "1" ]; then
  echo "[paykit-railway] PAYKIT_ENTRYPOINT_RENDER_ONLY=1: wrote $config_path, not starting server"
  exit 0
fi
exec /usr/local/bin/paykit-server
