#!/bin/sh
# Tests for ../create-stack.sh against the fake Railway CLI shim
# (RAILWAY_BIN=./infra/tests/fake-railway.sh). Run from the repo root:
#   sh infra/tests/create-stack_test.sh
set -u

cd "$(dirname "$0")/../.."
SCRIPT="infra/create-stack.sh"
export RAILWAY_BIN=./infra/tests/fake-railway.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export FAKE_RAILWAY_STATE_DIR="$TMP/state"
export FAKE_RAILWAY_LOG="$TMP/calls.log"
: > "$FAKE_RAILWAY_LOG"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok - $1"; }
not_ok() { fail=$((fail + 1)); echo "FAIL - $1"; }

KEY_L="pubkynruz6nicigk91bctyw7ueq1tshd9wb3qfkeqgmcicghpmjrnsquy"
DIGEST="sha256:$(printf 'a%.0s' $(seq 64))"
DIGEST2="sha256:$(printf 'b%.0s' $(seq 64))"

mutate_count() { grep -c '^MUTATE ' "$FAKE_RAILWAY_LOG" || true; }

run_proof() {
  sh "$SCRIPT" proof --image-digest "$1" \
    --locks-public-key "$KEY_L" \
    --allowed-origins "https://shop.example" \
    --marketplace-trusted-keys "$KEY_L" >"$TMP/out" 2>"$TMP/err"
}

svc_vars() { cat "$FAKE_RAILWAY_STATE_DIR/services/$1/vars"; }

# 1. First proof run creates both objects and wires every §C.12 variable.
if run_proof "$DIGEST" \
  && [ -d "$FAKE_RAILWAY_STATE_DIR/services/paykit-server-proof" ] \
  && [ -d "$FAKE_RAILWAY_STATE_DIR/services/paykit-proof-postgres" ] \
  && svc_vars paykit-server-proof | grep -q '^PAYKIT_BITCOIN_NETWORK=mainnet$' \
  && svc_vars paykit-server-proof | grep -q '^PAYKIT_STACK_ROLE=proof$' \
  && svc_vars paykit-server-proof | grep -q '^PAYKIT_ELECTRUM_ENDPOINT=ssl://bitkit.to:9999$' \
  && svc_vars paykit-server-proof | grep -q '^PAYKIT_ELECTRUM_POLL_INTERVAL=30s$' \
  && svc_vars paykit-server-proof | grep -q '^PAYKIT_BITCOIN_CREATION_ENABLED=true$' \
  && svc_vars paykit-server-proof | grep -q '^PAYKIT_DATABASE_URL=${{paykit-proof-postgres.DATABASE_URL}}$' \
  && svc_vars paykit-server-proof | grep -q "^PAYKIT_IMAGE_DIGEST=$DIGEST\$" \
  && svc_vars paykit-server-proof | grep -q "^PAYKIT_SETUP_ALLOWED_ORIGINS=https://shop.example\$" \
  && svc_vars paykit-server-proof | grep -q "^MARKETPLACE_TRUSTED_PUBLIC_KEYS=$KEY_L\$" \
  && grep -q '^MUTATE railway add --database postgres --name paykit-proof-postgres$' "$FAKE_RAILWAY_LOG" \
  && grep -q '^MUTATE railway add --service paykit-server-proof$' "$FAKE_RAILWAY_LOG"; then
  ok "first proof run creates service + database and wires §C.12 variables"
else
  not_ok "first proof run creates service + database and wires §C.12 variables"
fi

# 2. Idempotency: a second run issues ZERO mutating calls.
before="$(mutate_count)"
if run_proof "$DIGEST" && [ "$(mutate_count)" -eq "$before" ]; then
  ok "second run is idempotent (0 mutating calls)"
else
  not_ok "second run is idempotent (0 mutating calls)"
fi

# 3. Secrets: generated exactly once, real-format, and NEVER in the call log.
master_key="$(svc_vars paykit-server-proof | sed -n 's/^PAYKIT_MASTER_KEY=//p')"
signing_key="$(svc_vars paykit-server-proof | sed -n 's/^PAYKIT_REQUEST_SIGNING_KEY=//p')"
if [ "${#master_key}" -eq 43 ] && [ "${#signing_key}" -eq 43 ] && [ "$master_key" != "$signing_key" ]; then
  ok "PAYKIT_MASTER_KEY and PAYKIT_REQUEST_SIGNING_KEY generated (43-char base64url, distinct)"
else
  not_ok "PAYKIT_MASTER_KEY and PAYKIT_REQUEST_SIGNING_KEY generated (43-char base64url, distinct)"
fi

if ! grep -q "$master_key" "$FAKE_RAILWAY_LOG" \
  && ! grep -q "$signing_key" "$FAKE_RAILWAY_LOG" \
  && grep -q '^MUTATE railway variables set PAYKIT_MASTER_KEY=<redacted:stdin>$' "$FAKE_RAILWAY_LOG" \
  && grep -q '^MUTATE railway variables set PAYKIT_REQUEST_SIGNING_KEY=<redacted:stdin>$' "$FAKE_RAILWAY_LOG" \
  && ! grep -E '^MUTATE railway variables set [A-Z_]+=[^<]' "$FAKE_RAILWAY_LOG" >/dev/null; then
  ok "call log redacts every variable value; secrets piped via stdin"
else
  not_ok "call log redacts every variable value; secrets piped via stdin"
fi

# 4. Keys are NEVER regenerated once present (even with a different digest).
run_proof "$DIGEST2" >/dev/null 2>&1
if [ "$(svc_vars paykit-server-proof | sed -n 's/^PAYKIT_MASTER_KEY=//p')" = "$master_key" ] \
  && [ "$(grep -c 'variables set PAYKIT_MASTER_KEY' "$FAKE_RAILWAY_LOG")" -eq 1 ]; then
  ok "existing trust keys are never regenerated"
else
  not_ok "existing trust keys are never regenerated"
fi

# 5. Refuses without --image-digest (§C.8).
if sh "$SCRIPT" production --locks-public-key "$KEY_L" \
    --allowed-origins "https://shop.example" >"$TMP/out" 2>"$TMP/err"; then
  not_ok "refuses without --image-digest"
elif grep -q "image-digest sha256:<64 hex> is required" "$TMP/err"; then
  ok "refuses without --image-digest"
else
  not_ok "refuses without --image-digest"
fi

# 6. Refuses a malformed digest.
if sh "$SCRIPT" proof --image-digest "latest" \
    --locks-public-key "$KEY_L" \
    --allowed-origins "https://shop.example" >"$TMP/out" 2>"$TMP/err"; then
  not_ok "refuses a malformed --image-digest"
elif grep -q 'must match \^sha256:\[0-9a-f\]{64}' "$TMP/err"; then
  ok "refuses a malformed --image-digest"
else
  not_ok "refuses a malformed --image-digest"
fi

# 7. Production stack targets its own project/service/database/role.
: > "$FAKE_RAILWAY_LOG"
if sh "$SCRIPT" production --image-digest "$DIGEST" \
    --locks-public-key "$KEY_L" \
    --allowed-origins "https://shop.example" >"$TMP/out" 2>"$TMP/err" \
  && [ -d "$FAKE_RAILWAY_STATE_DIR/services/paykit-server-mainnet" ] \
  && [ -d "$FAKE_RAILWAY_STATE_DIR/services/paykit-mainnet-postgres" ] \
  && svc_vars paykit-server-mainnet | grep -q '^PAYKIT_STACK_ROLE=production$' \
  && svc_vars paykit-server-mainnet | grep -q '^PAYKIT_DATABASE_URL=${{paykit-mainnet-postgres.DATABASE_URL}}$' \
  && grep -q 'link --project 75faa4fe' "$FAKE_RAILWAY_LOG"; then
  ok "production stack targets project 75faa4fe with role production"
else
  not_ok "production stack targets project 75faa4fe with role production"
fi

# 8. The regtest service is never touched: BOTH absence assertions must hold
#    (a `||` here would let one forbidden call hide behind the other).
if ! grep -q 'paykit-postgres' "$FAKE_RAILWAY_LOG" \
  && ! grep -Eq '(add|down).*paykit-server$' "$FAKE_RAILWAY_LOG"; then
  ok "no call touches the existing regtest service or database"
else
  not_ok "no call touches the existing regtest service or database"
fi

# 8b. Mutation proof for assertion 8: a SINGLE forbidden regtest call must
#     fail the conjunction. (Checked on a copy so the real log stays usable.)
cp "$FAKE_RAILWAY_LOG" "$TMP/mutated.log"
printf 'MUTATE railway down --service paykit-server\n' >> "$TMP/mutated.log"
if ! grep -q 'paykit-postgres' "$TMP/mutated.log" \
  && ! grep -Eq '(add|down).*paykit-server$' "$TMP/mutated.log"; then
  not_ok "mutation proof: one forbidden regtest call fails the conjunction"
else
  ok "mutation proof: one forbidden regtest call fails the conjunction"
fi

# 9. The final step is named honestly: provisioning is done, the deployment
#    pin is a MANDATORY MANUAL GATE (no verified CLI operation), blocking the
#    miswiring gate until the operator ticks the checklist.
if grep -q "PROVISIONED (objects and variables only - nothing deployed)" "$TMP/out" \
  && grep -q "MANDATORY MANUAL GATE - deployment pin" "$TMP/out" \
  && grep -q "\[ \] pin the paykit-server-mainnet deployment source to image digest" "$TMP/out" \
  && grep -q "$DIGEST" "$TMP/out" \
  && grep -q "miswiring gate" "$TMP/out" && grep -q "BLOCKED" "$TMP/out"; then
  ok "pin step is named as a mandatory manual gate with an operator checklist"
else
  not_ok "pin step is named as a mandatory manual gate with an operator checklist"
fi

# 10 (P1-4). A CLI without the stdin form of `variables set KEY` must be
#     detected via readback and REFUSED - there is no argv fallback that
#     would put the generated key on a command line.
rm -rf "$FAKE_RAILWAY_STATE_DIR"
: > "$FAKE_RAILWAY_LOG"
if RAILWAY_BIN=./infra/tests/fake-railway-no-stdin.sh sh "$SCRIPT" proof \
    --image-digest "$DIGEST" \
    --locks-public-key "$KEY_L" \
    --allowed-origins "https://shop.example" >"$TMP/out10" 2>"$TMP/err10"; then
  not_ok "CLI without the stdin variables-set form is refused (no argv fallback)"
elif grep -q "did not store PAYKIT_MASTER_KEY from stdin" "$TMP/err10" \
  && grep -q "dashboard variable editor" "$TMP/err10" \
  && ! grep -Eq 'variables set PAYKIT_(MASTER|REQUEST_SIGNING)_KEY=[^<]' "$FAKE_RAILWAY_LOG"; then
  ok "CLI without the stdin variables-set form is refused (no argv fallback)"
else
  not_ok "CLI without the stdin variables-set form is refused (no argv fallback)"
  sed 's/^/  out: /' "$TMP/out10"; sed 's/^/  err: /' "$TMP/err10"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
