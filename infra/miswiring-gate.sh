#!/bin/sh
# miswiring-gate.sh - the scripted negative pre-cutover check from §B.1
# ("Negative miswiring gate, tested not assumed") and §C row 13: a mainnet
# paykit config pointed at a database initialised for a DIFFERENT network or
# stack role MUST exit before binding, with StartupError::Deployment.
#
# What the fork exposes (read-only check against the deploy-target hardening
# line, ps-w1-1 @ 8762fa2): the binary has NO --check-deployment hook -
# paykit-server/src/main.rs runs the full boot, and the deployment-invariant
# refusal is StartupError::Deployment (startup.rs L23-25), whose thiserror
# display string is "deployment initialization failed". main() returns
# anyhow::Result and initialize_database is awaited with `?` (main.rs L27),
# so the process exits non-zero BEFORE the listener binds with exactly this
# line on stderr (anyhow's "Error: " prefix + the display string):
#
#   Error: deployment initialization failed
#
# The gate anchors on that COMPLETE line (grep with ^...$), never a
# substring: the phrase embedded in any other text proves nothing. And a
# stderr carrying the connection-failure signature (StartupError::Connection,
# startup.rs L17-19: "postgres connection failed") is ALWAYS a gate failure,
# even if the refusal line is also present: a boot that could not reach the
# database never evaluated the invariant. The check is secret-free by design
# (startup.rs: "Secret-free failures"), so stderr is safe to surface.
#
# The gate therefore is: render the real entrypoint config for the intended
# stack -> boot the real image's binary against the WRONG database URL ->
# assert (a) non-zero exit, (b) the exact anchored Deployment line on stderr,
# (c) no connection-failure signature on stderr, (d) the process did NOT
# survive to serve. A process still running after the timeout means it booted
# against the wrong database: the invariant machinery is broken and the
# cutover STOPPED.
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
#   export GATE_DATABASE_URL="$(railway variables --kv \
#     | sed -n 's/^DATABASE_URL=//p')"   # the WRONG database's service selected
#   infra/miswiring-gate.sh --role <proof|production>
#
# GATE_DATABASE_URL is exported on its own line, NEVER given as an env-prefix
# inline assignment (`GATE_DATABASE_URL=... command`): the inline form is
# part of the typed command line, so the URL - credentials and all - lands
# verbatim in the operator's interactive shell history file.
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
  *) die "usage: miswiring-gate.sh --role <proof|production> (export GATE_DATABASE_URL first - never the inline env-prefix form; it lands in shell history)" ;;
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
  # The window closed between liveness checks: the loop's last kill -0 may
  # predate the exit by up to a second (a fast-exiting or slow-refusing
  # binary must not be misclassified as surviving). Reap FIRST; only a
  # process that is still alive right now is "STILL RUNNING".
  if kill -0 "$server_pid" 2>/dev/null; then
    echo "miswiring-gate: FAIL - the server is STILL RUNNING after ${GATE_TIMEOUT_SECONDS}s:" >&2
    echo "miswiring-gate: it BOOTED against a database initialised for a different" >&2
    echo "miswiring-gate: network/role. The deployment-invariant machinery is broken;" >&2
    echo "miswiring-gate: STOP the cutover. (killed pid $server_pid)" >&2
    kill "$server_pid" 2>/dev/null || true
    server_pid=""
    exit 1
  fi
  wait "$server_pid" || exit_code=$?
  exit_code="${exit_code:-0}"
fi
server_pid=""

if [ "$exit_code" -eq 0 ]; then
  echo "miswiring-gate: FAIL - the server exited 0 against the wrong database" >&2
  exit 1
fi

# The refusal marker is the fork's COMPLETE error line, anchored: anyhow
# prints "Error: " + StartupError::Deployment's display string. A substring
# match would pass on the phrase embedded in unrelated text.
if ! grep -q '^Error: deployment initialization failed$' "$TMP/server.err"; then
  echo "miswiring-gate: FAIL - non-zero exit ($exit_code) but NOT the exact" >&2
  echo "miswiring-gate: StartupError::Deployment refusal line" >&2
  echo "miswiring-gate: 'Error: deployment initialization failed' on stderr:" >&2
  sed 's/^/miswiring-gate: stderr: /' "$TMP/server.err" >&2
  exit 1
fi

# A connection-failure signature anywhere on stderr voids the pass: the boot
# never reached the invariant, so the refusal line proves nothing.
if grep -q "postgres connection failed" "$TMP/server.err"; then
  echo "miswiring-gate: FAIL - stderr carries the StartupError::Connection" >&2
  echo "miswiring-gate: signature ('postgres connection failed'): the database" >&2
  echo "miswiring-gate: was unreachable and the deployment invariant was never" >&2
  echo "miswiring-gate: evaluated. This is not evidence of a refusal:" >&2
  sed 's/^/miswiring-gate: stderr: /' "$TMP/server.err" >&2
  exit 1
fi

echo "miswiring-gate: PASS - mainnet/$role config refused to boot against the"
echo "miswiring-gate: wrong database before binding, with StartupError::Deployment"
echo "miswiring-gate: ('Error: deployment initialization failed', exit $exit_code)."
