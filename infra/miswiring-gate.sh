#!/bin/sh
# miswiring-gate.sh - the scripted negative pre-cutover check from §B.1
# ("Negative miswiring gate, tested not assumed") and §C row 13: a mainnet
# paykit config pointed at a database initialised for a DIFFERENT network or
# stack role MUST exit before binding, with StartupError::Deployment.
#
# What the fork exposes (read-only check against ps-w1-1): the binary has NO
# --check-deployment hook - paykit-server/src/main.rs runs the full boot, and
# the deployment-invariant refusal is startup.rs StartupError::Deployment,
# whose display string is "deployment initialization failed", printed by
# anyhow on stderr as the process exits non-zero BEFORE the listener binds
# (initialize_database runs before TcpListener::bind). The check is also
# secret-free by design (startup.rs: "Secret-free failures"), so stderr is
# safe to surface.
#
# The gate therefore is: render the real entrypoint config for the intended
# stack -> boot the real image's binary against the WRONG database URL ->
# assert (a) non-zero exit, (b) the Deployment string on stderr, (c) the
# process did NOT survive to serve. A process still running after the timeout
# means it booted against the wrong database: the invariant machinery is
# broken and the cutover STOPPED.
#
# The two checks from §B.1:
#   1. proof gate (before proofs):      --role proof,    GATE_DATABASE_URL =
#      the existing REGTEST paykit-postgres DATABASE_URL (network mismatch:
#      mainnet config on a regtest-initialised database).
#   2. production gate (before cutover): --role production, GATE_DATABASE_URL =
#      the PROOF paykit-proof-postgres DATABASE_URL (role mismatch: proof
#      database under a production config).
#
# Usage:
#   export PAYKIT_TRUSTED_LOCKS_PUBLIC_KEY=pubky...   # the stack's real value
#   export PAYKIT_SETUP_ALLOWED_ORIGINS="https://..."  # the stack's real value
#   export PAYKIT_MASTER_KEY=<the stack's real value>  # see note below
#   GATE_DATABASE_URL=<the WRONG database's URL, from `railway variables --kv`
#                      on that database's service> \
#     infra/miswiring-gate.sh --role <proof|production>
#
# Use the stack's REAL variables (export them from `railway variables`, never
# paste them into the command line) so the ONLY mismatched invariant is the
# intended one; the deployment check runs before Crypto::from_master_key
# (startup.rs order), so on the expected refusal path the master key is never
# used. GATE_DATABASE_URL is never printed.
#
# Env:
#   PAYKIT_SERVER_BIN       binary to boot (default /usr/local/bin/paykit-server,
#                           i.e. run inside the pinned image; tests use a fake)
#   PAYKIT_ENTRYPOINT       entrypoint to render with (default: the repo's
#                           paykit-server/entrypoint.sh next to this script)
#   GATE_TIMEOUT_SECONDS    boot-refusal window (default 15)
#
# Exit: 0 = the server REFUSED as designed (gate passed). 1 = anything else
# (wrong error, clean exit, or - worst - a live process that had to be killed).
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PAYKIT_SERVER_BIN="${PAYKIT_SERVER_BIN:-/usr/local/bin/paykit-server}"
PAYKIT_ENTRYPOINT="${PAYKIT_ENTRYPOINT:-$SCRIPT_DIR/../paykit-server/entrypoint.sh}"
GATE_TIMEOUT_SECONDS="${GATE_TIMEOUT_SECONDS:-15}"

die() { echo "miswiring-gate: error: $*" >&2; exit 1; }

role=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role) role="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$role" in
  proof|production) ;;
  *) die "usage: GATE_DATABASE_URL=... miswiring-gate.sh --role <proof|production>" ;;
esac

[ -n "${GATE_DATABASE_URL:-}" ] || die "GATE_DATABASE_URL is required (the WRONG database's URL; never printed)"
[ -x "$PAYKIT_ENTRYPOINT" ] || [ -f "$PAYKIT_ENTRYPOINT" ] || die "entrypoint not found at $PAYKIT_ENTRYPOINT"
: "${PAYKIT_TRUSTED_LOCKS_PUBLIC_KEY:?export the real PAYKIT_TRUSTED_LOCKS_PUBLIC_KEY of the stack}"
: "${PAYKIT_SETUP_ALLOWED_ORIGINS:?export the real PAYKIT_SETUP_ALLOWED_ORIGINS of the stack}"
: "${PAYKIT_MASTER_KEY:?export the real PAYKIT_MASTER_KEY of the stack (unused on the expected refusal path)}"

TMP="$(mktemp -d)"
server_pid=""
cleanup() {
  [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "miswiring-gate: rendering a mainnet/$role config via $PAYKIT_ENTRYPOINT"
PAYKIT_BITCOIN_NETWORK=mainnet \
PAYKIT_STACK_ROLE="$role" \
PAYKIT_ELECTRUM_POLL_INTERVAL=30s \
PAYKIT_ELECTRUM_ENDPOINT=ssl://bitkit.to:9999 \
PAYKIT_DATABASE_URL=postgres://render-only.invalid/unused \
PAYKIT_CONFIG="$TMP/config.toml" \
PAYKIT_ENTRYPOINT_RENDER_ONLY=1 \
  sh "$PAYKIT_ENTRYPOINT" >/dev/null

grep -q '^network = "mainnet"$' "$TMP/config.toml" || die "rendered config lost network=mainnet"
grep -q "^stack_role = \"$role\"\$" "$TMP/config.toml" || die "rendered config lost stack_role=$role"

echo "miswiring-gate: booting $PAYKIT_SERVER_BIN against the wrong database"
echo "miswiring-gate: expecting refusal with StartupError::Deployment within ${GATE_TIMEOUT_SECONDS}s"
PAYKIT_CONFIG="$TMP/config.toml" \
PAYKIT_DATABASE_URL="$GATE_DATABASE_URL" \
PAYKIT_MASTER_KEY="$PAYKIT_MASTER_KEY" \
  "$PAYKIT_SERVER_BIN" >"$TMP/server.out" 2>"$TMP/server.err" &
server_pid=$!

elapsed=0
exit_code=""
while [ "$elapsed" -lt "$GATE_TIMEOUT_SECONDS" ]; do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    wait "$server_pid" || exit_code=$?
    exit_code="${exit_code:-0}"
    break
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

if [ -z "$exit_code" ]; then
  echo "miswiring-gate: FAIL - the server is STILL RUNNING after ${GATE_TIMEOUT_SECONDS}s:" >&2
  echo "miswiring-gate: it BOOTED against a database initialised for a different" >&2
  echo "miswiring-gate: network/role. The deployment-invariant machinery is broken;" >&2
  echo "miswiring-gate: STOP the cutover. (killed pid $server_pid)" >&2
  kill "$server_pid" 2>/dev/null || true
  server_pid=""
  exit 1
fi
server_pid=""

if [ "$exit_code" -eq 0 ]; then
  echo "miswiring-gate: FAIL - the server exited 0 against the wrong database" >&2
  exit 1
fi

if ! grep -q "deployment initialization failed" "$TMP/server.err"; then
  echo "miswiring-gate: FAIL - non-zero exit ($exit_code) but NOT StartupError::Deployment:" >&2
  sed 's/^/miswiring-gate: stderr: /' "$TMP/server.err" >&2
  exit 1
fi

echo "miswiring-gate: PASS - mainnet/$role config refused to boot against the"
echo "miswiring-gate: wrong database before binding, with StartupError::Deployment"
echo "miswiring-gate: (\"deployment initialization failed\", exit $exit_code)."
