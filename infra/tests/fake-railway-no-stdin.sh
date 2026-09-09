#!/bin/sh
# fake-railway-no-stdin.sh - fake-railway.sh variant whose `variables set KEY`
# (the stdin form) silently stores NOTHING, emulating an installed Railway
# CLI that has no stdin form. Used ONLY by infra/tests/create-stack_test.sh
# to prove create-stack.sh detects the missing write via readback and REFUSES
# instead of falling back to putting the generated key on a command line.
# Every other subcommand delegates to fake-railway.sh.
set -eu

: "${FAKE_RAILWAY_LOG:?FAKE_RAILWAY_LOG is required}"

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ "${1:-}" = "variables" ] && [ "${2:-}" = "set" ] && [ $# -ge 3 ]; then
  stdin_only=1
  for assignment in "$@"; do
    case "$assignment" in
      variables|set) ;;
      *=*) stdin_only=0 ;;
      *) ;;
    esac
  done
  if [ "$stdin_only" -eq 1 ]; then
    # Drain stdin so the producer does not block, record the (redacted)
    # attempt, store NOTHING, and report success - the worst-case silent
    # failure the readback verification exists to catch.
    cat >/dev/null
    shift 2
    for key in "$@"; do
      printf '%s railway variables set %s\n' MUTATE "$key=<redacted:stdin-unsupported>" \
        >> "$FAKE_RAILWAY_LOG"
    done
    echo "Updated variables"
    exit 0
  fi
fi

exec "$SELF_DIR/fake-railway.sh" "$@"
