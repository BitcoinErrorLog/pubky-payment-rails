#!/bin/sh
# Tests for the marketplace trust-anchor templating in ../entrypoint.sh.
#
# Runs the entrypoint in render-only mode (PAYKIT_ENTRYPOINT_RENDER_ONLY=1)
# against fake 52-character z-base-32-looking fixtures - never real keys -
# and asserts the emitted TOML form and exit behaviour. Every successfully
# rendered config is also parsed with python3's tomllib (Python >= 3.11).
set -u

cd "$(dirname "$0")"
ENTRYPOINT="../entrypoint.sh"

# Fake fixtures: 52 chars from the z-base-32 alphabet, not real keys.
KEY_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
KEY_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
KEY_L="cccccccccccccccccccccccccccccccccccccccccccccccccccc"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

ok() { pass=$((pass + 1)); echo "ok - $1"; }
not_ok() { fail=$((fail + 1)); echo "FAIL - $1"; }

# Render the config with the given marketplace env; all other required
# variables get dummy non-secret values. Usage: run_render out err [env...]
run_render() {
  out="$1"; err="$2"; shift 2
  env -i PATH="$PATH" \
    PAYKIT_TRUSTED_LOCKS_PUBLIC_KEY="$KEY_L" \
    PAYKIT_DATABASE_URL="postgres://dummy/dummy" \
    PAYKIT_MASTER_KEY="dummy" \
    PAYKIT_SETUP_ALLOWED_ORIGINS="https://example.invalid" \
    PAYKIT_CONFIG="$TMP/config.toml" \
    PAYKIT_ENTRYPOINT_RENDER_ONLY=1 \
    "$@" sh "$ENTRYPOINT" >"$out" 2>"$err"
}

toml_parses() {
  python3 - "$TMP/config.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    tomllib.load(f)
PY
}

# 1. Single-key form.
if run_render "$TMP/out" "$TMP/err" MARKETPLACE_TRUSTED_PUBLIC_KEY="$KEY_A" \
  && grep -q "^trusted_public_key = \"$KEY_A\"$" "$TMP/config.toml" \
  && ! grep -q "trusted_public_keys" "$TMP/config.toml" \
  && toml_parses \
  && python3 - "$TMP/config.toml" "$KEY_A" <<'PY'
import sys, tomllib
cfg = tomllib.load(open(sys.argv[1], "rb"))
assert cfg["marketplace"]["trusted_public_key"] == sys.argv[2], cfg
PY
then
  ok "single MARKETPLACE_TRUSTED_PUBLIC_KEY emits trusted_public_key"
else
  not_ok "single MARKETPLACE_TRUSTED_PUBLIC_KEY emits trusted_public_key"
fi

# 2. Two-key list form (whitespace around the comma tolerated).
if run_render "$TMP/out" "$TMP/err" MARKETPLACE_TRUSTED_PUBLIC_KEYS="$KEY_A,  $KEY_B" \
  && grep -q "^trusted_public_keys = \[\"$KEY_A\", \"$KEY_B\"\]$" "$TMP/config.toml" \
  && ! grep -q "^trusted_public_key = \"$KEY_A\"$" "$TMP/config.toml" \
  && toml_parses \
  && python3 - "$TMP/config.toml" "$KEY_A" "$KEY_B" <<'PY'
import sys, tomllib
cfg = tomllib.load(open(sys.argv[1], "rb"))
assert cfg["marketplace"]["trusted_public_keys"] == [sys.argv[2], sys.argv[3]], cfg
PY
then
  ok "MARKETPLACE_TRUSTED_PUBLIC_KEYS emits trusted_public_keys list"
else
  not_ok "MARKETPLACE_TRUSTED_PUBLIC_KEYS emits trusted_public_keys list"
fi

# 2b. Logs mention only the key count, never key values.
if grep -q "marketplace trusted signing keys configured: 2" "$TMP/out" \
  && ! grep -q "$KEY_A" "$TMP/out" \
  && ! grep -q "$KEY_B" "$TMP/out"; then
  ok "list form logs the key count and no key values"
else
  not_ok "list form logs the key count and no key values"
fi

# 3. Both variables set: fail non-zero, clear message, no key values logged.
if run_render "$TMP/out" "$TMP/err" \
    MARKETPLACE_TRUSTED_PUBLIC_KEY="$KEY_A" \
    MARKETPLACE_TRUSTED_PUBLIC_KEYS="$KEY_B"; then
  not_ok "both MARKETPLACE_TRUSTED_PUBLIC_KEY(S) set fails"
elif grep -q "mutually exclusive" "$TMP/err" \
  && ! grep -q "$KEY_A" "$TMP/err" && ! grep -q "$KEY_B" "$TMP/err" \
  && ! grep -q "$KEY_A" "$TMP/out" && ! grep -q "$KEY_B" "$TMP/out"; then
  ok "both MARKETPLACE_TRUSTED_PUBLIC_KEY(S) set fails"
else
  not_ok "both MARKETPLACE_TRUSTED_PUBLIC_KEY(S) set fails"
fi

# 4. Malformed list entry: fail non-zero, no key values logged.
if run_render "$TMP/out" "$TMP/err" MARKETPLACE_TRUSTED_PUBLIC_KEYS="$KEY_A,notakey"; then
  not_ok "malformed MARKETPLACE_TRUSTED_PUBLIC_KEYS entry fails"
elif grep -q "entry 2 is not a 52-character" "$TMP/err" \
  && ! grep -q "$KEY_A" "$TMP/err"; then
  ok "malformed MARKETPLACE_TRUSTED_PUBLIC_KEYS entry fails"
else
  not_ok "malformed MARKETPLACE_TRUSTED_PUBLIC_KEYS entry fails"
fi

# 5. Neither set: no [marketplace] section, config still parses.
if run_render "$TMP/out" "$TMP/err" \
  && ! grep -q "\[marketplace\]" "$TMP/config.toml" \
  && toml_parses; then
  ok "neither variable set emits no [marketplace] section"
else
  not_ok "neither variable set emits no [marketplace] section"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
