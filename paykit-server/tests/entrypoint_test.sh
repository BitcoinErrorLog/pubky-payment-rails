#!/bin/sh
# Tests for the marketplace trust-anchor templating in ../entrypoint.sh.
#
# Runs the entrypoint in render-only mode (PAYKIT_ENTRYPOINT_RENDER_ONLY=1)
# against real-format throwaway fixtures - 57-char `pubky`-prefixed z-base-32
# keys derived from random one-off seeds with
# ../tools/derive-marketplace-pubkey (the seeds were discarded immediately;
# these public keys identify nothing). Every successfully rendered config is
# parsed with python3's tomllib (Python >= 3.11), and the rendered keys are
# validated against the REAL fork parser contract (see the P3 section at the
# bottom).
set -u

cd "$(dirname "$0")"
ENTRYPOINT="../entrypoint.sh"

# Throwaway real-format fixtures (random seeds, since discarded; never real
# key material). Form: "pubky" + 52 z-base-32 chars = 57 chars, exactly what
# the fork config parser accepts.
KEY_A="pubky87q1j1ftjnnjbekx46wmg1ixyd6rbxzsiyb3ksuphwdgtku3mmey"
KEY_B="pubky6p418m9j7huogm1ny9xk56fzq55kdyer7uortacww1k7nxxxgspy"
KEY_L="pubkynruz6nicigk91bctyw7ueq1tshd9wb3qfkeqgmcicghpmjrnsquy"
# Same key material without the `pubky` prefix: the fork parser REJECTS this
# bare 52-char form (InvalidTrustedMarketplacePublicKey), so the entrypoint
# must reject it too rather than render TOML the server cannot boot with.
KEY_A_BARE="${KEY_A#pubky}"

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

# Every marketplace key rendered into the TOML must match the exact form the
# fork parser accepts: ^pubky[ybndrfg8ejkmcpqxot1uwisza345h769]{52}$ .
rendered_keys_match_parser_form() {
  python3 - "$TMP/config.toml" <<'PY'
import re, sys, tomllib
with open(sys.argv[1], "rb") as f:
    cfg = tomllib.load(f)
marketplace = cfg.get("marketplace", {})
keys = []
if "trusted_public_key" in marketplace:
    keys.append(marketplace["trusted_public_key"])
keys.extend(marketplace.get("trusted_public_keys", []))
assert keys, "no marketplace keys rendered"
form = re.compile(r"^pubky[ybndrfg8ejkmcpqxot1uwisza345h769]{52}$")
assert all(form.match(k) for k in keys), keys
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
elif grep -q "entry 2 is not a 57-character" "$TMP/err" \
  && ! grep -q "$KEY_A" "$TMP/err"; then
  ok "malformed MARKETPLACE_TRUSTED_PUBLIC_KEYS entry fails"
else
  not_ok "malformed MARKETPLACE_TRUSTED_PUBLIC_KEYS entry fails"
fi

# 4b. Bare 52-char z-base-32 key (no `pubky` prefix): the fork parser rejects
# this form, so the entrypoint must reject it in BOTH env forms.
if run_render "$TMP/out" "$TMP/err" MARKETPLACE_TRUSTED_PUBLIC_KEY="$KEY_A_BARE"; then
  not_ok "bare 52-char MARKETPLACE_TRUSTED_PUBLIC_KEY is rejected"
elif run_render "$TMP/out" "$TMP/err" MARKETPLACE_TRUSTED_PUBLIC_KEYS="$KEY_A_BARE"; then
  not_ok "bare 52-char MARKETPLACE_TRUSTED_PUBLIC_KEY is rejected"
elif grep -q "57-character pubky-prefixed" "$TMP/err"; then
  ok "bare 52-char MARKETPLACE_TRUSTED_PUBLIC_KEY is rejected"
else
  not_ok "bare 52-char MARKETPLACE_TRUSTED_PUBLIC_KEY is rejected"
fi

# 4c. Empty middle entry ("a,,b"): fail fast, naming the 1-based entry index
# and never any key value - a silently skipped entry would boot the server
# with fewer trust anchors than configured.
if run_render "$TMP/out" "$TMP/err" MARKETPLACE_TRUSTED_PUBLIC_KEYS="$KEY_A,,$KEY_B"; then
  not_ok "empty middle MARKETPLACE_TRUSTED_PUBLIC_KEYS entry fails"
elif grep -q "entry 2 is empty" "$TMP/err" \
  && ! grep -q "$KEY_A" "$TMP/err" && ! grep -q "$KEY_B" "$TMP/err"; then
  ok "empty middle MARKETPLACE_TRUSTED_PUBLIC_KEYS entry fails"
else
  not_ok "empty middle MARKETPLACE_TRUSTED_PUBLIC_KEYS entry fails"
fi

# 4d. Trailing comma: same fail-fast contract, at the final entry index.
if run_render "$TMP/out" "$TMP/err" MARKETPLACE_TRUSTED_PUBLIC_KEYS="$KEY_A,$KEY_B,"; then
  not_ok "trailing comma in MARKETPLACE_TRUSTED_PUBLIC_KEYS fails"
elif grep -q "entry 3 is empty" "$TMP/err" \
  && ! grep -q "$KEY_A" "$TMP/err" && ! grep -q "$KEY_B" "$TMP/err"; then
  ok "trailing comma in MARKETPLACE_TRUSTED_PUBLIC_KEYS fails"
else
  not_ok "trailing comma in MARKETPLACE_TRUSTED_PUBLIC_KEYS fails"
fi

# 4e. Whitespace around keys and commas stays tolerated: " a , b " is 2 keys.
if run_render "$TMP/out" "$TMP/err" MARKETPLACE_TRUSTED_PUBLIC_KEYS=" $KEY_A , $KEY_B " \
  && grep -q "^trusted_public_keys = \[\"$KEY_A\", \"$KEY_B\"\]$" "$TMP/config.toml" \
  && toml_parses \
  && grep -q "marketplace trusted signing keys configured: 2" "$TMP/out"; then
  ok "whitespace-padded MARKETPLACE_TRUSTED_PUBLIC_KEYS still accepts 2 keys"
else
  not_ok "whitespace-padded MARKETPLACE_TRUSTED_PUBLIC_KEYS still accepts 2 keys"
fi

# 5. Neither set: no [marketplace] section, config still parses.
if run_render "$TMP/out" "$TMP/err" \
  && ! grep -q "\[marketplace\]" "$TMP/config.toml" \
  && toml_parses; then
  ok "neither variable set emits no [marketplace] section"
else
  not_ok "neither variable set emits no [marketplace] section"
fi

# 6 (P3). Rendered-key contract against the REAL fork parser. The fork
# binary has no --check-config flag and this session cannot add an env-path
# TOML loader test to the fork, so the proof is two-part:
#   (a) local: every key the entrypoint renders matches
#       ^pubky[ybndrfg8ejkmcpqxot1uwisza345h769]{52}$ - the only form the
#       fork parser accepts;
#   (b) fork: re-run the fork's own parser contract test
#       (marketplace_config_trusted_public_key_accepts_prefixed_and_rejects_bare_forms,
#       fork commit 37ffdd4) which proves that exact form PARSES and the bare
#       52-char form is REJECTED by Config::from_toml_and_environment.
FORK_DIR="${PAYKIT_SERVER_FORK_DIR:-/Users/johncarvalho/work/paykit-server-fork}"
if run_render "$TMP/out" "$TMP/err" MARKETPLACE_TRUSTED_PUBLIC_KEYS="$KEY_A, $KEY_B" \
  && toml_parses \
  && rendered_keys_match_parser_form; then
  ok "rendered marketplace keys match ^pubky[z-base-32]{52}\$ (parser-accepted form)"
else
  not_ok "rendered marketplace keys match ^pubky[z-base-32]{52}\$ (parser-accepted form)"
fi

if [ -f "$FORK_DIR/Cargo.toml" ]; then
  if cargo test -q -p paykit-server --manifest-path "$FORK_DIR/Cargo.toml" \
      --test config marketplace_config >"$TMP/forktest.log" 2>&1; then
    ok "fork parser contract test passes (prefixed parses, bare rejected; $FORK_DIR)"
  else
    not_ok "fork parser contract test passes (prefixed parses, bare rejected; $FORK_DIR)"
    cat "$TMP/forktest.log" >&2
  fi
else
  echo "SKIP - fork parser validation: no fork checkout at $FORK_DIR"
  echo "       (set PAYKIT_SERVER_FORK_DIR; full parse-forms proof lives in fork commit 37ffdd4)"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
