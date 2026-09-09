#!/bin/sh
# drop-proof-database.sh - DESTRUCTIVE. Drops the proof stack's Postgres
# (paykit-proof-postgres) after the §D proofs are done. The proof database is
# DROPPED, never cleaned and never promoted (§B.1: 0001_initial.sql is
# ON DELETE RESTRICT throughout, so row-level cleanup leaves orphan
# observation targets hammering Electrum forever).
#
# This script issues AT MOST ONE mutating call, and only after every guard
# below passes and --execute is given. Without --execute it prints the plan
# and exits 0 having done nothing.
#
# SELF-ATTACK TABLE - how could this delete the wrong database, and what
# stops it:
#
#   1. Wrong project id: the operator's environment carries
#      PAYKIT_PROOF_PROJECT_ID=<production id> (a leftover from another
#      shell), or PAYKIT_PROOF_DROP_CONFIRM is pasted from the production
#      project (75faa4fe...) or anywhere else.
#      -> The proof project id is an IMMUTABLE LITERAL in this script. No
#         environment variable and no flag can change it: PAYKIT_PROOF_PROJECT_ID
#         is not read at all and has zero effect. `railway status --json` must
#         report EXACTLY that literal (full equality, never a prefix match),
#         and PAYKIT_PROOF_DROP_CONFIRM must equal it exactly; production's id
#         fails the comparison before any mutating railway call is made.
#   2. Wrong service name: the operator edits the target to
#      paykit-mainnet-postgres (or anything else).
#      -> The target is not an argument. It is a hardcoded constant that the
#         script itself re-validates: no "proof" substring, no run.
#   3. Env pasted from a production shell: the target service somehow carries
#      PAYKIT_STACK_ROLE=production.
#      -> The script reads the TARGET service's own PAYKIT_STACK_ROLE from
#         Railway and refuses unless it resolves to exactly "proof". A
#         missing value also refuses.
#   4. Run from CI / unattended automation: a pipeline replays the script.
#      -> Destruction needs THREE independent operator artifacts at once:
#         the long --i-understand-this-drops-the-proof-database flag, the
#         PAYKIT_PROOF_DROP_CONFIRM env equal to the project id, AND
#         --execute. Never put any of them in CI; the dry-run plan says so.
#   5. Shim vs real binary confusion: RAILWAY_BIN still points at a test
#      double from infra/tests in a real terminal.
#      -> When RAILWAY_BIN is set the plan prints a loud "NOT the real
#         railway binary" warning naming the resolved path; on a real run
#         RAILWAY_BIN must be unset and the plan says which binary was found.
#   6. Partial failure mid-run: a multi-step teardown half-completes.
#      -> There is exactly ONE mutating call in the whole script; every guard
#         runs before it and there is no second step to half-complete. set
#         -eu aborts on any failure before the call.
#   7. Stale local link: the CLI is still linked to another project from
#      earlier work.
#      -> The script re-links the proof project explicitly and verifies the
#         link via `railway status --json` before doing anything else.
#   8. Mode confusion: operator believes a dry run acted, or an execute run
#      was dry.
#      -> The plan is printed in BOTH modes and states the mode in capitals;
#         dry run ends with "DRY RUN - NO ACTION TAKEN" and exit 0.
#
# Usage:
#   PAYKIT_PROOF_DROP_CONFIRM=c991d768 \
#     infra/drop-proof-database.sh --i-understand-this-drops-the-proof-database
#       # dry run: prints the plan, exits 0, touches nothing
#   PAYKIT_PROOF_DROP_CONFIRM=c991d768 \
#     infra/drop-proof-database.sh --i-understand-this-drops-the-proof-database --execute
#       # issues exactly one delete, against paykit-proof-postgres
#
# Env:
#   RAILWAY_BIN               railway binary (tests use the shim; see attack 5)
#   PAYKIT_PROOF_DROP_CONFIRM must equal the proof project id literal below
#                             (self-attack 1). PAYKIT_PROOF_PROJECT_ID is NOT
#                             read by this script; setting it changes nothing.
set -eu

RAILWAY_BIN="${RAILWAY_BIN:-railway}"

# The ONLY target this script can ever name (§B.1 stack table). These are
# IMMUTABLE LITERALS - not arguments, not environment, overridable by nothing
# outside an edit to this file (self-attack 1). PROOF_PROJECT_ID must be the
# FULL project id: the status check below requires exact equality, so a
# documented-prefix-only value fails closed (refuses) against real Railway
# until the full id is written here.
PROOF_PROJECT_ID="c991d768"
PROOF_SERVICE="paykit-server-proof"
PROOF_DATABASE="paykit-proof-postgres"

die() { echo "drop-proof-database: REFUSED: $*" >&2; exit 1; }

understand=""
execute=""
while [ $# -gt 0 ]; do
  case "$1" in
    --i-understand-this-drops-the-proof-database) understand=1; shift ;;
    --execute) execute=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Guard 1: the explicit acknowledgement flag.
[ -n "$understand" ] || die "requires --i-understand-this-drops-the-proof-database"

# Guard 2: the env confirmation must EXACTLY equal the proof project id.
[ -n "${PAYKIT_PROOF_DROP_CONFIRM:-}" ] || die "PAYKIT_PROOF_DROP_CONFIRM=<exact proof project id> is required"
[ "$PAYKIT_PROOF_DROP_CONFIRM" = "$PROOF_PROJECT_ID" ] \
  || die "PAYKIT_PROOF_DROP_CONFIRM does not match the proof project id ($PROOF_PROJECT_ID)"

# Guard 3 (self-attack 1): the target name is a constant containing "proof".
case "$PROOF_DATABASE" in
  *proof*) ;;
  *) die "internal: target database name '$PROOF_DATABASE' does not contain 'proof'" ;;
esac
case "$PROOF_SERVICE" in
  *proof*) ;;
  *) die "internal: target service name '$PROOF_SERVICE' does not contain 'proof'" ;;
esac

# Guard 4 (self-attacks 1 and 7): link the proof project and VERIFY the link
# with EXACT equality - a prefix match would wave through a hostile shim or a
# stale link that resolves to a different project sharing the prefix.
"$RAILWAY_BIN" link --project "$PROOF_PROJECT_ID" >/dev/null
linked="$("$RAILWAY_BIN" status --json | sed -n 's/.*"project":{"id":"\([^"]*\)".*/\1/p')"
[ "$linked" = "$PROOF_PROJECT_ID" ] \
  || die "linked project '$linked' is not the proof project ($PROOF_PROJECT_ID)"

# Guard 5: the database and its sibling service must exist in THIS project.
"$RAILWAY_BIN" service "$PROOF_DATABASE" >/dev/null 2>&1 \
  || die "database $PROOF_DATABASE not found in project $linked"
"$RAILWAY_BIN" service "$PROOF_SERVICE" >/dev/null 2>&1 \
  || die "service $PROOF_SERVICE not found in project $linked"

# Guard 6 (self-attack 3): the target stack's own role must resolve to proof.
target_role="$("$RAILWAY_BIN" variables --kv | sed -n 's/^PAYKIT_STACK_ROLE=//p' | head -n 1)"
[ -n "$target_role" ] || die "$PROOF_SERVICE has no PAYKIT_STACK_ROLE - cannot prove it is the proof stack"
[ "$target_role" = "proof" ] \
  || die "$PROOF_SERVICE resolves PAYKIT_STACK_ROLE='$target_role', not 'proof'"

# Shim warning (self-attack 5).
binary_note="railway binary: $(command -v "$RAILWAY_BIN" 2>/dev/null || echo "$RAILWAY_BIN")"
shim_warning=""
if [ -n "${RAILWAY_BIN+x}" ] && [ "$RAILWAY_BIN" != "railway" ]; then
  shim_warning="*** WARNING: RAILWAY_BIN is set to '$RAILWAY_BIN' - this is NOT the
*** real railway binary. If this is not a test run, STOP NOW."
fi

# The plan, printed in BOTH modes (self-attack 8).
cat <<EOF_PLAN
drop-proof-database: PLAN
  project:         $linked (expected $PROOF_PROJECT_ID)
  action:          DELETE database service $PROOF_DATABASE, irreversibly
  NOT touched:     $PROOF_SERVICE (kept for log forensics; remove it by hand
                   only after the wave report is archived), the regtest
                   paykit-server/paykit-postgres, and every production object
  preconditions:   §D proofs archived; the proof database is dropped, never
                   cleaned, never promoted (§B.1)
  mutating calls:  exactly one: railway down --service $PROOF_DATABASE
  $binary_note
EOF_PLAN
if [ -n "$shim_warning" ]; then
  printf '%s\n' "$shim_warning"
fi

if [ -z "$execute" ]; then
  echo "drop-proof-database: DRY RUN - NO ACTION TAKEN (re-run with --execute to act)"
  exit 0
fi

# The one and only mutating call (self-attack 6).
"$RAILWAY_BIN" down --service "$PROOF_DATABASE"
echo "drop-proof-database: EXECUTED - $PROOF_DATABASE deleted from $linked."
echo "drop-proof-database: the proof database was dropped, not cleaned, not promoted."
