#!/bin/sh
# create-stack.sh - idempotent IaC for one watch-only mainnet paykit stack
# (design: mp-btc-design docs/ecommerce/btc-mainnet.md r13, §B.1 "Three
# stacks, no shared database" and §C row 12). Creates NOTHING outside the
# named stack's Railway project and never touches the existing regtest
# service.
#
#   proof       -> project pubky-marketplace-staging    (c991d768...)
#                  service  paykit-server-proof
#                  database paykit-proof-postgres
#   production  -> project pubky-marketplace-production (75faa4fe...)
#                  service  paykit-server-mainnet
#                  database paykit-mainnet-postgres
#
# What it does, all idempotently (a second run issues ZERO mutating calls):
#   1. links the named project and VERIFIES the link before any mutation;
#   2. ensures the Postgres database and the paykit service exist;
#   3. wires the §C.12 variables: PAYKIT_BITCOIN_NETWORK=mainnet,
#      PAYKIT_STACK_ROLE=<role>, PAYKIT_ELECTRUM_ENDPOINT=ssl://bitkit.to:9999
#      (§B.2; the blockstream failover is a manual runbook step, never wired
#      here), PAYKIT_ELECTRUM_POLL_INTERVAL=30s,
#      PAYKIT_BITCOIN_CREATION_ENABLED=true (the §C.16 default),
#      PAYKIT_DATABASE_URL as a Railway reference to THIS stack's database,
#      PAYKIT_IMAGE_DIGEST=<--image-digest> (§C.8: the value the boot line
#      prints is the value you pinned, by construction);
#   4. generates the per-stack trust keys PAYKIT_MASTER_KEY and
#      PAYKIT_REQUEST_SIGNING_KEY ONLY IF ABSENT - never regenerates, never
#      echoes, never writes them to a file: the value is piped on stdin
#      directly into `railway variables set`, so it appears on no command
#      line and in no log. If the installed CLI has no stdin form (the write
#      does not land on readback) the script REFUSES - there is deliberately
#      no argv fallback, because a generated key on a command line leaks into
#      shell history, process tables, and logs; the runbook names the
#      dashboard variable editor as the only alternative channel;
#   5. refuses to run without --image-digest sha256:<64 hex> (§C.8: one
#      pinned digest D across stacks; building "latest" per stack is the
#      NEW-4 failure). The digest is wired as PAYKIT_IMAGE_DIGEST only -
#      this script PROVISIONS, it does NOT deploy or pin: pinning the
#      service's deployment source to the digest is a mandatory manual gate
#      (no verified CLI operation exists), printed as a checklist at the end
#      of every run and blocking the miswiring gate until ticked.
#
# Usage:
#   infra/create-stack.sh <proof|production> \
#     --image-digest sha256:<64 hex> \
#     --locks-public-key pubky<52 z-base-32 chars> \
#     --allowed-origins "https://shop.example,https://www.shop.example" \
#     [--marketplace-trusted-keys "pubky...,pubky..."]
#
# Env:
#   RAILWAY_BIN                    railway binary (tests use the shim)
#   PAYKIT_PROOF_PROJECT_ID        full proof project id (default c991d768)
#   PAYKIT_PRODUCTION_PROJECT_ID   full production project id (default 75faa4fe)
#
# OPERATOR-VERIFY before first real use (Railway CLI spellings this script
# relies on - see infra/README.md):
#   railway link --project <id>          railway add --service <name>
#   railway status --json                railway add --database postgres --name <n>
#   railway service <name>               railway variables --kv
#   railway variables set KEY=VALUE      railway variables set KEY  (value on stdin)
# Pinning the already-built digest D to the service has no verified CLI
# operation: it is a mandatory manual gate in the Railway dashboard (service
# Settings -> Source -> image digest), printed as the final checklist.
set -eu

RAILWAY_BIN="${RAILWAY_BIN:-railway}"

die() { echo "create-stack: error: $*" >&2; exit 1; }

stack=""
image_digest=""
locks_key=""
allowed_origins=""
marketplace_keys=""

while [ $# -gt 0 ]; do
  case "$1" in
    proof|production)
      [ -z "$stack" ] || die "stack given twice"
      stack="$1"; shift ;;
    --image-digest) image_digest="${2:-}"; shift 2 ;;
    --locks-public-key) locks_key="${2:-}"; shift 2 ;;
    --allowed-origins) allowed_origins="${2:-}"; shift 2 ;;
    --marketplace-trusted-keys) marketplace_keys="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$stack" in
  proof)
    project_id="${PAYKIT_PROOF_PROJECT_ID:-c991d768}"
    service="paykit-server-proof"
    database="paykit-proof-postgres"
    role="proof"
    ;;
  production)
    project_id="${PAYKIT_PRODUCTION_PROJECT_ID:-75faa4fe}"
    service="paykit-server-mainnet"
    database="paykit-mainnet-postgres"
    role="production"
    ;;
  *) die "usage: create-stack.sh <proof|production> --image-digest sha256:<64 hex> --locks-public-key pubky... --allowed-origins <csv> [--marketplace-trusted-keys <csv>]" ;;
esac

# §C row 8: the digest is mandatory. A stack without it silently builds
# "latest", which is exactly the three-different-binaries failure the design
# calls NEW-4.
[ -n "$image_digest" ] || die "--image-digest sha256:<64 hex> is required (§C.8: one pinned digest D across stacks)"
printf '%s\n' "$image_digest" | grep -qE '^sha256:[0-9a-f]{64}$' \
  || die "--image-digest must match ^sha256:[0-9a-f]{64}\$ (got '$image_digest')"

[ -n "$locks_key" ] || die "--locks-public-key is required (the Lock Server's credentials.lock_server_public_key)"
case "$locks_key" in
  pubky*) ;;
  *) die "--locks-public-key must be a pubky-prefixed public key" ;;
esac
[ "${#locks_key}" -eq 57 ] || die "--locks-public-key must be 57 characters (pubky + 52 z-base-32)"

[ -n "$allowed_origins" ] || die "--allowed-origins is required (comma-separated exact origins; the fork fails closed on an empty list)"

# --- 1. Link and VERIFY the project before any mutating call --------------
"$RAILWAY_BIN" link --project "$project_id" >/dev/null
linked="$("$RAILWAY_BIN" status --json | sed -n 's/.*"project":{"id":"\([^"]*\)".*/\1/p')"
case "$linked" in
  "$project_id"*) ;;
  *) die "linked project '$linked' does not match expected '$project_id' for stack $stack - refusing to touch anything" ;;
esac

# --- 2. Ensure database and service exist ---------------------------------
if ! "$RAILWAY_BIN" service "$database" >/dev/null 2>&1; then
  "$RAILWAY_BIN" add --database postgres --name "$database" >/dev/null
  "$RAILWAY_BIN" service "$database" >/dev/null
fi
if ! "$RAILWAY_BIN" service "$service" >/dev/null 2>&1; then
  "$RAILWAY_BIN" add --service "$service" >/dev/null
  "$RAILWAY_BIN" service "$service" >/dev/null
fi

# --- 3. Wire the §C.12 variables (only where absent or different) ---------
"$RAILWAY_BIN" service "$service" >/dev/null
current_vars="$("$RAILWAY_BIN" variables --kv)"

get_var() {
  printf '%s\n' "$current_vars" | sed -n "s/^$1=//p" | head -n 1
}

set_var() {
  # set_var KEY VALUE - only on drift, so a second run is a no-op.
  key="$1"; value="$2"
  if [ "$(get_var "$key")" != "$value" ]; then
    "$RAILWAY_BIN" variables set "$key=$value" >/dev/null
    echo "  set $key"
  fi
}

echo "create-stack: wiring $service in project $linked (stack $stack, role $role)"

set_var PAYKIT_BITCOIN_NETWORK mainnet
set_var PAYKIT_STACK_ROLE "$role"
set_var PAYKIT_ELECTRUM_ENDPOINT ssl://bitkit.to:9999
set_var PAYKIT_ELECTRUM_POLL_INTERVAL 30s
set_var PAYKIT_BITCOIN_CREATION_ENABLED true
# Railway reference syntax, not a secret: resolves to THIS stack's database
# and to nothing else.
set_var PAYKIT_DATABASE_URL "\${{$database.DATABASE_URL}}"
set_var PAYKIT_IMAGE_DIGEST "$image_digest"
set_var PAYKIT_TRUSTED_LOCKS_PUBLIC_KEY "$locks_key"
set_var PAYKIT_SETUP_ALLOWED_ORIGINS "$allowed_origins"
if [ -n "$marketplace_keys" ]; then
  set_var MARKETPLACE_TRUSTED_PUBLIC_KEYS "$marketplace_keys"
fi

# --- 4. Per-stack trust keys: generate ONLY if absent, pipe, never echo ---
# PAYKIT_MASTER_KEY must be unpadded base64url of exactly 32 bytes (fork
# config.rs InvalidMasterKey). The value travels: openssl stdout -> railway
# stdin. It is never in this script's argv, never echoed, never on disk.
gen_key() {
  # Generate into a variable FIRST: POSIX sh pipelines return the LAST
  # command's status, so `openssl ... | tr | tr` would mask an openssl
  # failure (both tr stages exit 0 on empty input) and yield an EMPTY key
  # that then passes readback ("" == ""). The bare assignment below lets
  # set -e abort the run on a nonzero openssl before anything is stored.
  raw="$(openssl rand -base64 32)"
  printf '%s' "$raw" | tr '+/' '-_' | tr -d '=\n'
}

for secret_key in PAYKIT_MASTER_KEY PAYKIT_REQUEST_SIGNING_KEY; do
  if [ -z "$(get_var "$secret_key")" ]; then
    secret_value="$(gen_key)"
    # Validate the key format BEFORE any `railway variables set`: exactly 43
    # characters of unpadded base64url. Any anomaly stores NOTHING - an
    # empty or malformed key must never reach Railway, where it would pass
    # readback and leave a stack that cannot boot (InvalidMasterKey).
    [ "${#secret_value}" -eq 43 ] \
      || die "generated $secret_key is not 43 characters; refusing to store it"
    case "$secret_value" in
      *[!A-Za-z0-9_-]*) die "generated $secret_key is not unpadded base64url; refusing to store it" ;;
    esac
    printf '%s' "$secret_value" | "$RAILWAY_BIN" variables set "$secret_key" >/dev/null
    # Readback verification: an installed CLI WITHOUT the stdin form of
    # `variables set KEY` silently stores nothing (or prompts). Detect that
    # here and REFUSE. There is deliberately no fallback that puts the key on
    # a command line - that would leak it into shell history, process tables,
    # and logs. The only alternative channel is the Railway dashboard
    # variable editor (or another verified non-argv channel).
    current_vars="$("$RAILWAY_BIN" variables --kv)"
    [ "$(get_var "$secret_key")" = "$secret_value" ] \
      || die "the installed Railway CLI did not store $secret_key from stdin (no 'railway variables set KEY' stdin form). STOP - do not work around this on a command line. Set $secret_key through Railway's dashboard variable editor (or another verified non-argv channel), then re-run this script; existing keys are never regenerated."
    echo "  generated $secret_key (piped to railway; value never displayed)"
  fi
done

# --- 5. Provisioning summary + the mandatory manual pin gate ----------------
# This script PROVISIONS (objects + variables). It does NOT deploy, and there
# is no verified Railway CLI operation that pins a service's deployment
# source to an image digest - so the pin is a mandatory MANUAL gate between
# provisioning and the miswiring gate. Naming it honestly keeps an operator
# from reading "image: <digest>" above as "deployed at <digest>".
echo "create-stack: $stack stack PROVISIONED (objects and variables only - nothing deployed)."
echo "  project:  $linked"
echo "  service:  $service (role $role, network mainnet, electrum ssl://bitkit.to:9999, poll 30s)"
echo "  database: $database (this stack only - never shared, never promoted)"
echo "  image:    $image_digest (wired as PAYKIT_IMAGE_DIGEST only; NOT yet pinned or deployed)"
echo
echo "MANDATORY MANUAL GATE - deployment pin (no verified CLI operation exists)."
echo "Provisioning is complete; the deployment pin is NOT. The miswiring gate"
echo "and every later proof are BLOCKED until the operator ticks both boxes:"
echo "  [ ] pin the $service deployment source to image digest"
echo "        $image_digest"
echo "      in the Railway dashboard (service Settings -> Source) and redeploy"
echo "  [ ] verify the boot line prints 'image $image_digest' exactly (§C.8;"
echo "      each proof asserts the digest it observed equals D before running)"
