#!/bin/sh
# fake-railway.sh - test double for the Railway CLI, used ONLY by the infra
# tests (RAILWAY_BIN=./infra/tests/fake-railway.sh). It implements exactly the
# subcommand subset the infra scripts use, records every invocation to
# $FAKE_RAILWAY_LOG with a call class (READ / LOCAL / MUTATE), and keeps
# service/variable state under $FAKE_RAILWAY_STATE_DIR.
#
# SECRET CONTRACT: every `variables set` value - whether it arrived on the
# command line or on stdin - is recorded as <redacted> / <redacted:stdin>.
# The real railway binary must never be given a secret on its command line;
# the scripts pipe generated keys in via stdin for exactly this reason, and
# the tests assert no secret value ever appears in this log.
set -eu

: "${FAKE_RAILWAY_LOG:?FAKE_RAILWAY_LOG is required}"
: "${FAKE_RAILWAY_STATE_DIR:?FAKE_RAILWAY_STATE_DIR is required}"

mkdir -p "$FAKE_RAILWAY_STATE_DIR/services"
state="$FAKE_RAILWAY_STATE_DIR"

log() {
  # log <CLASS> <args...>
  class="$1"; shift
  printf '%s railway %s\n' "$class" "$*" >> "$FAKE_RAILWAY_LOG"
}

current_service() {
  [ -f "$state/current_service" ] || {
    echo "fake-railway: no service selected (railway service <name>)" >&2
    exit 1
  }
  cat "$state/current_service"
}

upsert_var() {
  # upsert_var <service> <KEY> <value-from-stdin-or-arg>
  svc="$1"; key="$2"; value="$3"
  vars="$state/services/$svc/vars"
  if [ -f "$vars" ]; then
    grep -v "^$key=" "$vars" > "$vars.tmp" || true
    mv "$vars.tmp" "$vars"
  fi
  printf '%s=%s\n' "$key" "$value" >> "$vars"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift

case "$cmd" in
  link)
    project=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --project|-p) project="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$project" ] || { echo "fake-railway: link requires --project <id>" >&2; exit 1; }
    log LOCAL link --project "$project"
    printf '%s\n' "$project" > "$state/linked_project"
    echo "Linked to project $project"
    ;;

  status)
    log READ status "$@"
    project=""; [ -f "$state/linked_project" ] && project="$(cat "$state/linked_project")"
    services_json=""
    for d in "$state"/services/*; do
      [ -d "$d" ] || continue
      name="$(basename "$d")"
      services_json="$services_json{\"name\":\"$name\"},"
    done
    services_json="${services_json%,}"
    printf '{"project":{"id":"%s"},"services":[%s]}\n' "$project" "$services_json"
    ;;

  service)
    name="${1:-}"
    [ -n "$name" ] || { echo "fake-railway: service requires a name" >&2; exit 1; }
    log READ service "$name"
    if [ -d "$state/services/$name" ]; then
      printf '%s\n' "$name" > "$state/current_service"
      echo "Service: $name"
    else
      echo "fake-railway: service \"$name\" not found in project" >&2
      exit 1
    fi
    ;;

  add)
    kind=""; name=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --service) kind="service"; name="$2"; shift 2 ;;
        --database) kind="database:$2"; shift 2 ;;
        --name) name="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    case "$kind" in
      service)
        [ -n "$name" ] || { echo "fake-railway: add --service requires a name" >&2; exit 1; }
        log MUTATE add --service "$name"
        mkdir -p "$state/services/$name"
        : > "$state/services/$name/vars"
        echo "Created service $name"
        ;;
      database:postgres)
        [ -n "$name" ] || { echo "fake-railway: add --database postgres requires --name" >&2; exit 1; }
        log MUTATE add --database postgres --name "$name"
        mkdir -p "$state/services/$name"
        printf 'DATABASE_URL=postgres://fake-%s:secret@fake.railway.internal:5432/railway\n' "$name" \
          > "$state/services/$name/vars"
        echo "Created Postgres database $name"
        ;;
      *)
        echo "fake-railway: unsupported add form: $kind" >&2
        exit 1
        ;;
    esac
    ;;

  variables)
    sub="${1:-}"; [ $# -gt 0 ] && shift
    case "$sub" in
      --kv|"")
        svc="$(current_service)"
        log READ variables --kv
        [ -f "$state/services/$svc/vars" ] && cat "$state/services/$svc/vars"
        ;;
      set)
        svc="$(current_service)"
        for assignment in "$@"; do
          case "$assignment" in
            *=*)
              key="${assignment%%=*}"
              value="${assignment#*=}"
              # Values are NEVER logged: the log proves wiring happened
              # without becoming a secret leak of its own.
              log MUTATE variables set "$key=<redacted>"
              upsert_var "$svc" "$key" "$value"
              ;;
            *)
              # Stdin form: the value is piped in (generated keys), never
              # present on any command line.
              key="$assignment"
              value="$(cat)"
              log MUTATE variables set "$key=<redacted:stdin>"
              upsert_var "$svc" "$key" "$value"
              ;;
          esac
        done
        echo "Updated variables on $svc"
        ;;
      *)
        echo "fake-railway: unsupported variables form: $sub" >&2
        exit 1
        ;;
    esac
    ;;

  down)
    name=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --service) name="$2"; shift 2 ;;
        --yes|-y) shift ;;
        *) name="$1"; shift ;;
      esac
    done
    [ -n "$name" ] || { echo "fake-railway: down requires --service <name>" >&2; exit 1; }
    if [ -d "$state/services/$name" ]; then
      log MUTATE down --service "$name"
      rm -rf "$state/services/$name"
      echo "Removed service $name"
    else
      log MUTATE down --service "$name"
      echo "fake-railway: service \"$name\" not found" >&2
      exit 1
    fi
    ;;

  *)
    echo "fake-railway: unsupported subcommand: ${cmd:-<none>}" >&2
    exit 1
    ;;
esac
