#!/usr/bin/env bash
# Behavior tests for cloud-task recording, backlog transitions, binding, and retirement.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLOUD_TASK="$ROOT/bin/fm-cloud-task.sh"
TMP_ROOT=$(fm_test_tmproot fm-cloud-task-tests)
PRIMARY="$TMP_ROOT/primary"
STATE="$PRIMARY/state"
DATA="$PRIMARY/data"
CONFIG="$PRIMARY/config"
FAKEBIN="$TMP_ROOT/fakebin"
PROMPT="$DATA/cloud-task/brief.md"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

mkdir -p "$STATE" "$DATA/cloud-task" "$CONFIG" "$FAKEBIN" "$PRIMARY/bin"
printf '# cloud task fixture\n' > "$PRIMARY/AGENTS.md"
printf 'backend = "markdown"\n' > "$PRIMARY/.tasks.toml"
touch "$DATA/backlog.md"
printf 'Complete the cloud task.\n' > "$PROMPT"
git -C "$PRIMARY" init -q

cat > "$FAKEBIN/tasks-axi" <<'EOF'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version) printf 'tasks-axi 0.2.5\n' ;;
  update) [ "${2:-}" != --help ] || { printf '%s\n' '--archive-body'; exit 0; }; exit 1 ;;
  mv) [ "${2:-}" != --help ] || { printf '%s\n' '[<id>...]'; exit 0; }; exit 1 ;;
  show)
    id=${2:-}
    if [ ! -f "$CLOUD_TEST_DATA/$id.state" ]; then
      printf '%s\n' 'code: NOT_FOUND'
      exit 1
    fi
    printf '  state: %s\n  held: no\n  blocked: no\n' "$(cat "$CLOUD_TEST_DATA/$id.state")"
    ;;
  start) printf 'in_flight\n' > "$CLOUD_TEST_DATA/${2:?}.state" ;;
  done) printf 'done\n' > "$CLOUD_TEST_DATA/${2:?}.state" ;;
  reopen) printf 'queued\n' > "$CLOUD_TEST_DATA/${2:?}.state" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKEBIN/tasks-axi"

cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
[ "${1:-}" = pr ] && [ "${2:-}" = view ] || exit 1
printf '%s\n' "${CLOUD_TEST_PR_STATE:-OPEN}"
EOF
chmod +x "$FAKEBIN/gh"

run_cloud() {
  env -u TASKS_AXI_BACKEND -u TASKS_AXI_FILE \
    PATH="$FAKEBIN:$PATH" \
    FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" \
    FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" CLOUD_TEST_DATA="$DATA" \
    CLOUD_TEST_PR_STATE="${CLOUD_TEST_PR_STATE:-OPEN}" \
    "$CLOUD_TASK" "$@"
}

test_record_requires_opt_in() {
  local rc=0
  run_cloud record cloud-task --repo example/project --prompt-file "$PROMPT" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "record without config/cloud-workers must refuse, got $rc"
  [ ! -e "$STATE/cloud-task.meta" ] || fail "record without opt-in published a task record"
  grep -F 'config/cloud-workers' "$ERR" >/dev/null \
    || fail "opt-in refusal did not name config/cloud-workers: $(cat "$ERR")"
  pass "record requires the local cloud-workers opt-in"
}

test_record_requires_a_backlog_item_when_the_gate_applies() {
  local rc=0
  : > "$CONFIG/cloud-workers"
  run_cloud record cloud-task --repo example/project --prompt-file "$PROMPT" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "record without a gated backlog row must refuse, got $rc"
  [ ! -e "$STATE/cloud-task.meta" ] || fail "record without a backlog row published a task record"
  grep -F 'backlog item cloud-task is required' "$ERR" >/dev/null \
    || fail "missing-row refusal did not name the required backlog item: $(cat "$ERR")"
  pass "record refuses a missing backlog item when automatic transitions apply"
}

test_record_bind_and_retire_pair_the_backlog_and_task_record() {
  local rc=0
  printf 'queued\n' > "$DATA/cloud-task.state"
  run_cloud record cloud-task --repo example/project --prompt-file "$PROMPT" > "$OUT" 2> "$ERR" \
    || fail "record failed: $(cat "$ERR")"
  [ "$(cat "$DATA/cloud-task.state")" = in_flight ] || fail "record did not move the backlog row to In flight"
  grep -Fx 'kind=cloud' "$STATE/cloud-task.meta" >/dev/null || fail "task record lacks kind=cloud"
  grep -Fx 'repo=example/project' "$STATE/cloud-task.meta" >/dev/null || fail "task record lacks repo"
  grep -Fx "prompt_file=$PROMPT" "$STATE/cloud-task.meta" >/dev/null || fail "task record lacks the resolved prompt path"
  grep -E '^spawn_gen=[A-Za-z0-9._-]+$' "$STATE/cloud-task.meta" >/dev/null || fail "task record lacks a spawn generation"

  run_cloud bind cloud-task --trigger trigger-123 --session session-456 > "$OUT" 2> "$ERR" \
    || fail "bind failed: $(cat "$ERR")"
  grep -Fx 'trigger_id=trigger-123' "$STATE/cloud-task.meta" >/dev/null || fail "bind did not store the trigger id"
  grep -Fx 'session_id=session-456' "$STATE/cloud-task.meta" >/dev/null || fail "bind did not store the session id"
  env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$ROOT/bin/fm-subagent-pretool-check.sh" --claude --tool RemoteTrigger > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "recorded cloud task did not release RemoteTrigger: $(cat "$ERR")"

  printf '%s\n' 'pr=https://github.com/example/project/pull/123' >> "$STATE/cloud-task.meta"
  rc=0
  CLOUD_TEST_PR_STATE=MERGED run_cloud retire cloud-task --pr-merged > "$OUT" 2> "$ERR" \
    || fail "retire failed: $(cat "$ERR")"
  [ ! -e "$STATE/cloud-task.meta" ] || fail "retire left the cloud task record live"
  [ ! -e "$STATE/cloud-task.backlog-close" ] || fail "retire left a completed close marker"
  [ "$(cat "$DATA/cloud-task.state")" = "done" ] || fail "retire did not close the backlog item"
  env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$ROOT/bin/fm-subagent-pretool-check.sh" --claude --tool RemoteTrigger > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "retired cloud task still released RemoteTrigger, got $rc"
  grep -F 'bin/fm-cloud-task.sh' "$ERR" >/dev/null || fail "post-retirement denial did not point at fm-cloud-task.sh"
  pass "record, bind, and retire maintain the task record and backlog together"
}

test_abandoned_cloud_task_returns_backlog_item_to_queued() {
  local id=abandoned-cloud-task rc=0
  printf 'queued\n' > "$DATA/$id.state"
  run_cloud record "$id" --repo example/project --prompt-file "$PROMPT" > "$OUT" 2> "$ERR" \
    || fail "record failed: $(cat "$ERR")"
  printf '%s\n' 'pr=https://github.com/example/project/pull/456' >> "$STATE/$id.meta"
  run_cloud retire "$id" --pr-merged > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "unmerged PR was accepted as merged, got $rc"
  [ "$(cat "$DATA/$id.state")" = in_flight ] \
    || fail "failed merge confirmation changed the backlog item"
  [ -f "$STATE/$id.meta" ] || fail "failed merge confirmation removed the cloud task record"
  [ ! -e "$STATE/$id.backlog-close" ] \
    || fail "failed merge confirmation published a backlog transition"
  rc=0
  run_cloud retire "$id" > "$OUT" 2> "$ERR" \
    || fail "abandoned retire failed: $(cat "$ERR")"
  [ "$(cat "$DATA/$id.state")" = queued ] \
    || fail "abandoned retire did not return the backlog item to Queued"
  [ ! -e "$STATE/$id.meta" ] || fail "abandoned retire left the cloud task record live"
  [ ! -e "$STATE/$id.backlog-close" ] || fail "abandoned retire left a pending backlog marker"
  pass "abandoned cloud retirement returns its backlog item to Queued"
}

test_record_requires_opt_in
test_record_requires_a_backlog_item_when_the_gate_applies
test_record_bind_and_retire_pair_the_backlog_and_task_record
test_abandoned_cloud_task_returns_backlog_item_to_queued
