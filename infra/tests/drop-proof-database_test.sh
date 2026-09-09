#!/bin/sh
# Tests for ../drop-proof-database.sh against the fake Railway CLI shim
# (RAILWAY_BIN=./infra/tests/fake-railway.sh). Run from the repo root:
#   sh infra/tests/drop-proof-database_test.sh
set -u

cd "$(dirname "$0")/../.."
SCRIPT="infra/drop-proof-database.sh"
export RAILWAY_BIN=./infra/tests/fake-railway.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok - $1"; }
not_ok() { fail=$((fail + 1)); echo "FAIL - $1"; }

reset_state() {
  rm -rf "$TMP/state"
  export FAKE_RAILWAY_STATE_DIR="$TMP/state"
  export FAKE_RAILWAY_LOG="$TMP/calls.log"
  : > "$FAKE_RAILWAY_LOG"
  mkdir -p "$FAKE_RAILWAY_STATE_DIR/services/paykit-server-proof" \
           "$FAKE_RAILWAY_STATE_DIR/services/paykit-proof-postgres" \
           "$FAKE_RAILWAY_STATE_DIR/services/paykit-server" \
           "$FAKE_RAILWAY_STATE_DIR/services/paykit-postgres"
  if [ "${1:-proof}" = "none" ]; then
    printf 'PAYKIT_BITCOIN_NETWORK=mainnet\n' \
      > "$FAKE_RAILWAY_STATE_DIR/services/paykit-server-proof/vars"
  else
    printf 'PAYKIT_STACK_ROLE=%s\nPAYKIT_BITCOIN_NETWORK=mainnet\n' "${1:-proof}" \
      > "$FAKE_RAILWAY_STATE_DIR/services/paykit-server-proof/vars"
  fi
  : > "$FAKE_RAILWAY_STATE_DIR/services/paykit-proof-postgres/vars"
}

mutate_count() { grep -c '^MUTATE ' "$FAKE_RAILWAY_LOG" || true; }

run_drop() {
  env "$@" sh "$SCRIPT" --i-understand-this-drops-the-proof-database >"$TMP/out" 2>"$TMP/err"
}

# 1. No acknowledgement flag: refuses, zero mutating calls.
reset_state
if env PAYKIT_PROOF_DROP_CONFIRM=c991d768 sh "$SCRIPT" >"$TMP/out" 2>"$TMP/err"; then
  not_ok "refuses without --i-understand-this-drops-the-proof-database"
elif grep -q "requires --i-understand-this-drops-the-proof-database" "$TMP/err" \
  && [ "$(mutate_count)" -eq 0 ]; then
  ok "refuses without --i-understand-this-drops-the-proof-database"
else
  not_ok "refuses without --i-understand-this-drops-the-proof-database"
fi

# 2. Flag but no env confirmation: refuses.
reset_state
if sh "$SCRIPT" --i-understand-this-drops-the-proof-database >"$TMP/out" 2>"$TMP/err"; then
  not_ok "refuses without PAYKIT_PROOF_DROP_CONFIRM"
elif grep -q "PAYKIT_PROOF_DROP_CONFIRM=<exact proof project id> is required" "$TMP/err" \
  && [ "$(mutate_count)" -eq 0 ]; then
  ok "refuses without PAYKIT_PROOF_DROP_CONFIRM"
else
  not_ok "refuses without PAYKIT_PROOF_DROP_CONFIRM"
fi

# 3. Wrong confirm value (self-attack 1: production's id pasted in): refuses.
reset_state
if run_drop PAYKIT_PROOF_DROP_CONFIRM=75faa4fe; then
  not_ok "refuses when the confirm value is the PRODUCTION project id"
elif grep -q "does not match the proof project id" "$TMP/err" \
  && [ "$(mutate_count)" -eq 0 ]; then
  ok "refuses when the confirm value is the PRODUCTION project id"
else
  not_ok "refuses when the confirm value is the PRODUCTION project id"
fi

# 4. Target stack role is production (self-attack 3): refuses.
reset_state production
if run_drop PAYKIT_PROOF_DROP_CONFIRM=c991d768; then
  not_ok "refuses when the target service role is production"
elif grep -q "resolves PAYKIT_STACK_ROLE='production', not 'proof'" "$TMP/err" \
  && [ "$(mutate_count)" -eq 0 ]; then
  ok "refuses when the target service role is production"
else
  not_ok "refuses when the target service role is production"
fi

# 5. Target stack role missing entirely: refuses.
reset_state none
if run_drop PAYKIT_PROOF_DROP_CONFIRM=c991d768; then
  not_ok "refuses when the target service has no PAYKIT_STACK_ROLE"
elif grep -q "has no PAYKIT_STACK_ROLE" "$TMP/err" \
  && [ "$(mutate_count)" -eq 0 ]; then
  ok "refuses when the target service has no PAYKIT_STACK_ROLE"
else
  not_ok "refuses when the target service has no PAYKIT_STACK_ROLE"
fi

# 6. Dry run: all guards pass, plan printed, exit 0, ZERO mutating calls,
#    and the shim warning is loud (self-attack 5).
reset_state
if run_drop PAYKIT_PROOF_DROP_CONFIRM=c991d768 \
  && grep -q "DELETE database service paykit-proof-postgres" "$TMP/out" \
  && grep -q "DRY RUN - NO ACTION TAKEN" "$TMP/out" \
  && grep -q "NOT the" "$TMP/out" && grep -q "real railway binary" "$TMP/out" \
  && [ "$(mutate_count)" -eq 0 ] \
  && [ -d "$FAKE_RAILWAY_STATE_DIR/services/paykit-proof-postgres" ]; then
  ok "dry run prints the plan, warns about the shim, and mutates nothing"
else
  not_ok "dry run prints the plan, warns about the shim, and mutates nothing"
fi

# 7. Execute: exactly ONE mutating call, against the proof database only.
reset_state
if env PAYKIT_PROOF_DROP_CONFIRM=c991d768 \
    sh "$SCRIPT" --i-understand-this-drops-the-proof-database --execute >"$TMP/out" 2>"$TMP/err" \
  && [ "$(mutate_count)" -eq 1 ] \
  && grep -q '^MUTATE railway down --service paykit-proof-postgres$' "$FAKE_RAILWAY_LOG" \
  && [ ! -d "$FAKE_RAILWAY_STATE_DIR/services/paykit-proof-postgres" ] \
  && [ -d "$FAKE_RAILWAY_STATE_DIR/services/paykit-server-proof" ] \
  && [ -d "$FAKE_RAILWAY_STATE_DIR/services/paykit-postgres" ] \
  && grep -q "EXECUTED - paykit-proof-postgres deleted" "$TMP/out"; then
  ok "execute issues exactly one delete, against paykit-proof-postgres only"
else
  not_ok "execute issues exactly one delete, against paykit-proof-postgres only"
  sed 's/^/  out: /' "$TMP/out"; sed 's/^/  err: /' "$TMP/err"
  sed 's/^/  log: /' "$FAKE_RAILWAY_LOG"
fi

# 8. Missing database in the project: refuses before the plan.
reset_state
rm -rf "$FAKE_RAILWAY_STATE_DIR/services/paykit-proof-postgres"
if run_drop PAYKIT_PROOF_DROP_CONFIRM=c991d768; then
  not_ok "refuses when paykit-proof-postgres is absent from the project"
elif grep -q "database paykit-proof-postgres not found" "$TMP/err" \
  && [ "$(mutate_count)" -eq 0 ]; then
  ok "refuses when paykit-proof-postgres is absent from the project"
else
  not_ok "refuses when paykit-proof-postgres is absent from the project"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
