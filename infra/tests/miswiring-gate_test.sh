#!/bin/sh
# Tests for ../miswiring-gate.sh. The "server" is the fake fork binary
# (infra/tests/fake-paykit-server.sh) emulating the adopt-once/refuse boot
# contract; "databases" are invariant state files under a temp dir. Run from
# the repo root:
#   sh infra/tests/miswiring-gate_test.sh
set -u

cd "$(dirname "$0")/../.."
GATE="infra/miswiring-gate.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export FAKE_DB_DIR="$TMP/dbs"
mkdir -p "$FAKE_DB_DIR"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok - $1"; }
not_ok() { fail=$((fail + 1)); echo "FAIL - $1"; }

KEY_L="pubkynruz6nicigk91bctyw7ueq1tshd9wb3qfkeqgmcicghpmjrnsquy"

# init_db <name> <network> <role> - a database a first boot initialised.
init_db() { printf 'network=%s\nrole=%s\n' "$2" "$3" > "$FAKE_DB_DIR/$1"; }

init_db regtest-db regtest proof
init_db proof-db mainnet proof

run_gate() {
  # run_gate <role> <db> [timeout-seconds] [extra env KEY=VALUE ...] -
  # output lands in $TMP/gate.out / $TMP/gate.err and is appended to
  # $TMP/all.out / $TMP/all.err (for the never-printed checks).
  role="$1"; db="$2"; timeout=5
  if [ $# -ge 3 ]; then timeout="$3"; shift 3; else shift 2; fi
  env -i PATH="$PATH" HOME="$HOME" \
    FAKE_DB_DIR="$FAKE_DB_DIR" \
    PAYKIT_SERVER_BIN=./infra/tests/fake-paykit-server.sh \
    GATE_TIMEOUT_SECONDS="$timeout" \
    PAYKIT_TRUSTED_LOCKS_PUBLIC_KEY="$KEY_L" \
    PAYKIT_SETUP_ALLOWED_ORIGINS="https://shop.example" \
    PAYKIT_MASTER_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" \
    GATE_DATABASE_URL="postgres://fake.railway.internal:5432/$db" \
    ${1:+"$@"} \
    sh "$GATE" --role "$role" >"$TMP/gate.out" 2>"$TMP/gate.err"
  code=$?
  cat "$TMP/gate.out" >> "$TMP/all.out"
  cat "$TMP/gate.err" >> "$TMP/all.err"
  return $code
}
: > "$TMP/all.out"
: > "$TMP/all.err"

# 1. §B.1 case one: a mainnet config pointed at a REGTEST-initialised
#    database must refuse with StartupError::Deployment.
if run_gate proof regtest-db \
  && grep -q "PASS - mainnet/proof config refused to boot" "$TMP/gate.out" \
  && grep -q "deployment initialization failed" "$TMP/gate.out"; then
  ok "mainnet config on a regtest-initialised database refuses (Deployment)"
else
  not_ok "mainnet config on a regtest-initialised database refuses (Deployment)"
  sed 's/^/  out: /' "$TMP/gate.out"; sed 's/^/  err: /' "$TMP/gate.err"
fi

# 2. §B.1 case two: a PROOF database under a PRODUCTION config (role
#    mismatch) must refuse the same way.
if run_gate production proof-db \
  && grep -q "PASS - mainnet/production config refused to boot" "$TMP/gate.out"; then
  ok "proof database under a production config refuses (Deployment)"
else
  not_ok "proof database under a production config refuses (Deployment)"
  sed 's/^/  out: /' "$TMP/gate.out"; sed 's/^/  err: /' "$TMP/gate.err"
fi

# 3. The gate is not vacuous: a database that MATCHES the config lets the
#    server "boot" (the fake sleeps like a serving process), and the gate
#    must detect the live process, kill it, and FAIL.
if run_gate proof proof-db; then
  not_ok "gate fails when the server boots against a matching database"
elif grep -q "STILL RUNNING" "$TMP/gate.err"; then
  sleep 2
  if pgrep -f fake-paykit-server >/dev/null 2>&1; then
    not_ok "gate fails (and kills the server) when booting would succeed"
    pkill -f fake-paykit-server 2>/dev/null
  else
    ok "gate fails (and kills the server) when booting would succeed"
  fi
else
  not_ok "gate fails (and kills the server) when booting would succeed"
  sed 's/^/  err: /' "$TMP/gate.err"
fi

# 4. GATE_DATABASE_URL is never printed, on any path.
if ! grep -q "fake.railway.internal" "$TMP/all.out" "$TMP/all.err" 2>/dev/null \
  && ! grep -q "regtest-db\|proof-db" "$TMP/all.out" "$TMP/all.err" 2>/dev/null; then
  ok "the wrong database URL is never printed"
else
  not_ok "the wrong database URL is never printed"
fi

# 5. Missing --role / missing GATE_DATABASE_URL refuse before doing anything.
if sh "$GATE" >"$TMP/gate.out" 2>"$TMP/gate.err"; then
  not_ok "missing --role refuses"
elif grep -q "usage:" "$TMP/gate.err"; then
  ok "missing --role refuses"
else
  not_ok "missing --role refuses"
fi

if env GATE_TIMEOUT_SECONDS=5 \
    PAYKIT_SERVER_BIN=./infra/tests/fake-paykit-server.sh \
    PAYKIT_TRUSTED_LOCKS_PUBLIC_KEY="$KEY_L" \
    PAYKIT_SETUP_ALLOWED_ORIGINS="https://shop.example" \
    PAYKIT_MASTER_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" \
    sh "$GATE" --role proof >"$TMP/gate.out" 2>"$TMP/gate.err"; then
  not_ok "missing GATE_DATABASE_URL refuses"
elif grep -q "GATE_DATABASE_URL is required" "$TMP/gate.err"; then
  ok "missing GATE_DATABASE_URL refuses"
else
  not_ok "missing GATE_DATABASE_URL refuses"
fi

# 6. A non-Deployment boot failure (e.g. unreachable database -> the fake's
#    StartupError::Connection string) is a gate FAILURE, not a pass: only the
#    exact Deployment refusal is evidence.
if run_gate proof no-such-db; then
  not_ok "connection failure is not accepted as a deployment refusal"
elif grep -q "NOT the exact" "$TMP/gate.err" \
  && grep -q "StartupError::Deployment refusal line" "$TMP/gate.err"; then
  ok "connection failure is not accepted as a deployment refusal"
else
  not_ok "connection failure is not accepted as a deployment refusal"
  sed 's/^/  err: /' "$TMP/gate.err"
fi

# 7 (P1-3). The marker phrase EMBEDDED in unrelated text must FAIL the gate:
# the match is anchored to the fork's complete error line, so a substring
# carrying "deployment initialization failed" proves nothing. (This exact
# line passed the pre-fix substring grep.)
if run_gate proof regtest-db 5 \
    FAKE_SERVER_FORCE_STDERR='Error: connection refused; expected marker was deployment initialization failed but invariant was not evaluated'; then
  not_ok "marker phrase embedded in unrelated text fails the gate"
elif grep -q "NOT the exact" "$TMP/gate.err"; then
  ok "marker phrase embedded in unrelated text fails the gate"
else
  not_ok "marker phrase embedded in unrelated text fails the gate"
  sed 's/^/  err: /' "$TMP/gate.err"
fi

# 8 (P1-3). Even the EXACT refusal line is void when a connection-failure
# signature is also present: the boot never evaluated the invariant.
if run_gate proof regtest-db 5 \
    FAKE_SERVER_FORCE_STDERR="$(printf 'Error: deployment initialization failed\nError: postgres connection failed')"; then
  not_ok "connection-failure signature on stderr voids the refusal line"
elif grep -q "StartupError::Connection" "$TMP/gate.err"; then
  ok "connection-failure signature on stderr voids the refusal line"
else
  not_ok "connection-failure signature on stderr voids the refusal line"
  sed 's/^/  err: /' "$TMP/gate.err"
fi

# 9 (P2-1). A refusal landing AFTER the loop's last liveness check but BEFORE
# the window closes (delay 2.5s, timeout 3s) must be reaped and judged on its
# exit code - not misclassified as STILL RUNNING.
if run_gate proof regtest-db 3 FAKE_SERVER_DELAY_SECONDS=2.5 \
  && grep -q "PASS - mainnet/proof config refused to boot" "$TMP/gate.out"; then
  ok "a refusal landing between the last liveness check and the timeout is reaped, not misclassified"
else
  not_ok "a refusal landing between the last liveness check and the timeout is reaped, not misclassified"
  sed 's/^/  out: /' "$TMP/gate.out"; sed 's/^/  err: /' "$TMP/gate.err"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
