#!/usr/bin/env bash
# Record and manage a cloud worker task in this Firstmate home.
#
# Usage:
#   bin/fm-cloud-task.sh record <task-id> --repo <owner/repo> --prompt-file <path>
#   bin/fm-cloud-task.sh bind <task-id> --trigger <trigger-id> [--session <session-id>]
#   bin/fm-cloud-task.sh retire <task-id>
#   bin/fm-cloud-task.sh has-record
#
# record requires config/cloud-workers and publishes state/<task-id>.meta with
# kind=cloud before moving an applicable backlog row to In flight.
# bind stores the RemoteTrigger id and optional cloud-session id on that record.
# retire removes the record and completes an applicable backlog transition,
# preserving an open captain-held row; manual or absent backlog transitions
# retain the home's existing local-backlog policy.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 2
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 2
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
umask 077

# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

META_LOCK=
META_TMP=
cleanup() {
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  [ -z "$META_LOCK" ] || fm_lock_release "$META_LOCK" || true
}
trap cleanup EXIT

fail() {
  printf 'fm-cloud-task: %s\n' "$*" >&2
  exit 2
}

usage() {
  cat <<'EOF'
Usage: fm-cloud-task.sh record <task-id> --repo <owner/repo> --prompt-file <path>
       fm-cloud-task.sh bind <task-id> --trigger <trigger-id> [--session <session-id>]
       fm-cloud-task.sh retire <task-id>
       fm-cloud-task.sh has-record
EOF
}

cloud_opted_in() {
  [ -f "$CONFIG/cloud-workers" ] && [ ! -L "$CONFIG/cloud-workers" ]
}

cloud_meta_valid() {  # <meta-path>
  local meta=$1
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  LC_ALL=C awk -F= '
    $1 == "kind" { kind_count++; kind = substr($0, index($0, "=") + 1) }
    $1 == "repo" { repo_count++; repo = substr($0, index($0, "=") + 1) }
    $1 == "prompt_file" { prompt_count++; prompt = substr($0, index($0, "=") + 1) }
    $1 == "spawn_gen" { gen_count++; gen = substr($0, index($0, "=") + 1) }
    END {
      exit !(kind_count == 1 && kind == "cloud" && repo_count == 1 && repo != "" &&
             prompt_count == 1 && prompt != "" && gen_count == 1 &&
             gen ~ /^[A-Za-z0-9._-]+$/)
    }
  ' "$meta" 2>/dev/null
}

has_valid_cloud_record() {
  local meta
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    cloud_meta_valid "$meta" && return 0
  done
  return 1
}

acquire_task_lock() {  # <task-id>
  local meta="$STATE/$1.meta"
  META_LOCK=$(fm_meta_lock_path "$meta") || fail "invalid task id $1"
  fm_lock_acquire_wait "$META_LOCK" || fail "could not lock task $1"
}

resolve_prompt_file() {  # <path>
  local raw=$1 dir base
  [ -n "$raw" ] || fail "--prompt-file requires a path"
  case "$raw" in *$'\n'*|*$'\r'*|*$'\t'*) fail "prompt path contains a control character" ;; esac
  case "$raw" in
    */*) dir=${raw%/*}; base=${raw##*/}; [ -n "$dir" ] || dir=/ ;;
    *) dir=.; base=$raw ;;
  esac
  [ -n "$base" ] && [ "$base" != . ] && [ "$base" != .. ] || fail "invalid prompt file path: $raw"
  dir=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P) || fail "prompt directory cannot be resolved: $raw"
  raw="$dir/$base"
  [ -f "$raw" ] && [ -r "$raw" ] && [ ! -L "$raw" ] || fail "prompt file must be a readable regular file: $raw"
  printf '%s\n' "$raw"
}

validate_repo() {  # <owner/repo>
  local repo=$1 owner name
  local LC_ALL=C
  case "$repo" in */*) ;; *) fail "--repo must be OWNER/REPO" ;; esac
  owner=${repo%%/*}
  name=${repo#*/}
  [ -n "$owner" ] && [ -n "$name" ] || fail "--repo must be OWNER/REPO"
  case "$name" in */*) fail "--repo must be OWNER/REPO" ;; esac
  case "$owner$name" in *[!A-Za-z0-9_.-]*) fail "--repo contains unsupported characters" ;; esac
}

validate_cloud_id() {  # <label> <value>
  local label=$1 value=$2
  local LC_ALL=C
  case "$value" in
    ''|*[!A-Za-z0-9._:-]*) fail "$label must contain only letters, digits, dot, underscore, colon, or hyphen" ;;
  esac
}

record_task() {
  local id=$1 repo='' prompt_arg='' prompt_file='' gen backlog_rc
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) [ "$#" -ge 2 ] || fail "--repo requires OWNER/REPO"; repo=$2; shift 2 ;;
      --prompt-file) [ "$#" -ge 2 ] || fail "--prompt-file requires a path"; prompt_arg=$2; shift 2 ;;
      *) fail "unknown record argument: $1" ;;
    esac
  done
  fm_task_id_creation_valid "$id" || fail "invalid task id: $id"
  validate_repo "$repo"
  prompt_file=$(resolve_prompt_file "$prompt_arg")
  cloud_opted_in || fail "cloud workers are disabled; create $CONFIG/cloud-workers to opt in"
  fm_backlog_directory_present "$STATE" "state directory" || fail "$FM_BACKLOG_TRANSITION_ERROR"
  acquire_task_lock "$id"
  local meta="$STATE/$id.meta" marker="$STATE/$id.backlog-close"
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    fail "task record already exists at $meta"
  fi
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    fail "task $id has a pending backlog close at $marker"
  fi
  local backlog_applies=0 skip_reason=
  if fm_backlog_transition_applies "$CONFIG" "$DATA" cloud; then
    backlog_applies=1
    if ! fm_backlog_row_probe "$DATA" "$id"; then
      [ "$FM_BACKLOG_ROW_RESULT" != not_found ] || fail "backlog item $id is required before recording a cloud task"
      fail "could not read backlog item $id: ${FM_BACKLOG_ROW_ERROR:-$FM_BACKLOG_TRANSITION_ERROR}"
    fi
    fm_backlog_row_dispatchable "$FM_BACKLOG_ROW_STATE" \
      || fail "backlog item $id is not dispatchable in state $FM_BACKLOG_ROW_STATE"
  else
    backlog_rc=$?
    case "$backlog_rc" in
      1) skip_reason=$FM_BACKLOG_TRANSITION_SKIP ;;
      *) fail "backlog transition preflight failed: $FM_BACKLOG_TRANSITION_ERROR" ;;
    esac
  fi
  gen="c$(date +%s).${BASHPID:-$$}.$RANDOM"
  META_TMP="$STATE/.$id.meta.cloud.${BASHPID:-$$}"
  [ ! -e "$META_TMP" ] && [ ! -L "$META_TMP" ] || fail "temporary task record already exists at $META_TMP"
  if ! {
    printf 'kind=cloud\nrepo=%s\nprompt_file=%s\nspawn_gen=%s\n' "$repo" "$prompt_file" "$gen"
  } > "$META_TMP"; then
    fail "could not stage cloud task record for $id"
  fi
  fm_backlog_atomic_transition publish "$META_TMP" "$meta" "task record" "$STATE" \
    || fail "could not publish cloud task record: $FM_BACKLOG_TRANSITION_ERROR"
  META_TMP=
  if [ "$backlog_applies" = 1 ]; then
    fm_backlog_atomic_transition dispatch "$meta" "$DATA" "$id" "$STATE" \
      || fail "cloud task $id was recorded but its backlog could not move to In flight: $FM_BACKLOG_TRANSITION_ERROR"
  fi
  if [ -n "$skip_reason" ]; then
    printf 'recorded cloud task %s for %s (backlog transition skipped: %s)\n' "$id" "$repo" "$skip_reason"
  else
    printf 'recorded cloud task %s for %s\n' "$id" "$repo"
  fi
}

bind_task() {
  local id=$1 trigger='' session='' session_set=0 meta tmp
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --trigger) [ "$#" -ge 2 ] || fail "--trigger requires an id"; trigger=$2; shift 2 ;;
      --session) [ "$#" -ge 2 ] || fail "--session requires an id"; session=$2; session_set=1; shift 2 ;;
      *) fail "unknown bind argument: $1" ;;
    esac
  done
  fm_task_id_creation_valid "$id" || fail "invalid task id: $id"
  validate_cloud_id "trigger id" "$trigger"
  [ "$session_set" = 0 ] || validate_cloud_id "session id" "$session"
  fm_backlog_directory_present "$STATE" "state directory" || fail "$FM_BACKLOG_TRANSITION_ERROR"
  acquire_task_lock "$id"
  meta="$STATE/$id.meta"
  cloud_meta_valid "$meta" || fail "task $id has no valid kind=cloud record"
  fm_backlog_meta_spawn_gen "$meta" "$STATE" || fail "$FM_BACKLOG_TRANSITION_ERROR"
  tmp=$(mktemp "$STATE/.$id.meta.cloud.XXXXXX") || fail "could not stage cloud task binding for $id"
  META_TMP=$tmp
  if ! awk -F= '$1 != "trigger_id" && $1 != "session_id"' "$meta" > "$tmp"; then
    fail "could not read cloud task record for $id"
  fi
  {
    printf 'trigger_id=%s\n' "$trigger"
    [ "$session_set" = 0 ] || printf 'session_id=%s\n' "$session"
  } >> "$tmp" || fail "could not write cloud task binding for $id"
  fm_backlog_atomic_transition publish "$tmp" "$meta" "task record" "$STATE" \
    || fail "could not publish cloud task binding: $FM_BACKLOG_TRANSITION_ERROR"
  META_TMP=
  printf 'bound cloud task %s to trigger %s\n' "$id" "$trigger"
}

retire_task() {
  local id=$1 meta marker op backlog_rc
  fm_task_id_creation_valid "$id" || fail "invalid task id: $id"
  fm_backlog_directory_present "$STATE" "state directory" || fail "$FM_BACKLOG_TRANSITION_ERROR"
  acquire_task_lock "$id"
  meta="$STATE/$id.meta"
  marker="$STATE/$id.backlog-close"
  cloud_meta_valid "$meta" || fail "task $id has no valid kind=cloud record"
  fm_backlog_meta_spawn_gen "$meta" "$STATE" || fail "$FM_BACKLOG_TRANSITION_ERROR"
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    fail "task $id already has a pending backlog close at $marker"
  fi
  if fm_backlog_transition_applies "$CONFIG" "$DATA" cloud; then
    if ! fm_backlog_row_probe "$DATA" "$id"; then
      [ "$FM_BACKLOG_ROW_RESULT" != not_found ] || fail "backlog item $id is missing; refusing to retire its cloud task record"
      fail "could not read backlog item $id: ${FM_BACKLOG_ROW_ERROR:-$FM_BACKLOG_TRANSITION_ERROR}"
    fi
    op=close
    local -a flags=()
    if [ "${FM_BACKLOG_ROW_STATE%% *}" != "done" ] && [ "$FM_BACKLOG_ROW_HOLD_KIND" = captain ]; then
      op=retain
      flags=(--retain)
    fi
    fm_backlog_close_marker_write "$STATE" "$id" "$DATA" "$FM_BACKLOG_META_SPAWN_GEN" \
      "${flags[@]+"${flags[@]}"}" || fail "could not record the pending backlog close: $FM_BACKLOG_TRANSITION_ERROR"
    fm_backlog_atomic_transition "$op" "$meta" "$marker" "$DATA" "$id" "$STATE" \
      || fail "cloud task $id has a pending backlog close that needs recovery: $FM_BACKLOG_TRANSITION_ERROR"
  else
    backlog_rc=$?
    case "$backlog_rc" in
      1) fm_backlog_atomic_transition remove "$meta" "task record" "$STATE" \
           || fail "could not remove cloud task record: $FM_BACKLOG_TRANSITION_ERROR" ;;
      *) fail "backlog transition preflight failed: $FM_BACKLOG_TRANSITION_ERROR" ;;
    esac
  fi
  printf 'retired cloud task %s\n' "$id"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  has-record)
    [ "$#" -eq 1 ] || fail "usage: has-record"
    has_valid_cloud_record
    ;;
  record)
    [ "$#" -ge 2 ] || fail "usage: record <task-id> --repo <owner/repo> --prompt-file <path>"
    task_id=$2; shift 2
    record_task "$task_id" "$@"
    ;;
  bind)
    [ "$#" -ge 2 ] || fail "usage: bind <task-id> --trigger <trigger-id> [--session <session-id>]"
    task_id=$2; shift 2
    bind_task "$task_id" "$@"
    ;;
  retire)
    [ "$#" -eq 2 ] || fail "usage: retire <task-id>"
    retire_task "$2"
    ;;
  *) fail "usage: record, bind, retire, or --help" ;;
esac
