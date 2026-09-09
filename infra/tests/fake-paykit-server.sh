#!/bin/sh
# fake-paykit-server.sh - test double for the fork binary, used ONLY by the
# miswiring-gate tests. It emulates the ONE behaviour the gate asserts
# (ps-w1-1 paykit-server/src/startup.rs + persistence/deployment.rs):
#
#   connect -> migrate -> DeploymentStore::initialize -> bind.
#
# The "database" is a state file $FAKE_DB_DIR/<db>, where <db> is the path
# component of PAYKIT_DATABASE_URL (postgres://host/<db>), holding the
# invariants a first boot adopted:
#
#   network=regtest
#   role=proof
#
# Behaviour:
#   - state file missing           -> "Error: postgres connection failed", exit 1
#     (StartupError::Connection).
#   - network or role mismatch     -> "Error: deployment initialization failed",
#     exit 1 - the fork's exact StartupError::Deployment display string, emitted
#     before the listener binds (anyhow prints it on stderr).
#   - full match                   -> simulated successful boot: sleeps forever.
#     A real server that boots here means the invariant machinery is BROKEN;
#     the gate must detect the still-running process, kill it, and fail.
set -eu

: "${PAYKIT_CONFIG:?PAYKIT_CONFIG is required}"
: "${PAYKIT_DATABASE_URL:?PAYKIT_DATABASE_URL is required}"
: "${FAKE_DB_DIR:?FAKE_DB_DIR is required}"

db="${PAYKIT_DATABASE_URL##*/}"
state="$FAKE_DB_DIR/$db"
[ -f "$state" ] || {
  echo "Error: postgres connection failed" >&2
  exit 1
}

config_network="$(awk '/^\[bitcoin\]/{f=1} f && /^network = /{gsub(/"/, "", $3); print $3; exit}' "$PAYKIT_CONFIG")"
config_role="$(sed -n 's/^stack_role = "\(.*\)"$/\1/p' "$PAYKIT_CONFIG")"
db_network="$(sed -n 's/^network=\(.*\)$/\1/p' "$state")"
db_role="$(sed -n 's/^role=\(.*\)$/\1/p' "$state")"

if [ "$config_network" != "$db_network" ] || [ "$config_role" != "$db_role" ]; then
  echo "Error: deployment initialization failed" >&2
  exit 1
fi

# Invariants match: a real server would bind and serve. Sleep until the gate
# kills us (short sleeps so SIGTERM takes effect promptly).
while :; do sleep 1; done
