#!/usr/bin/env bash
set -u

REPO=/home/michael/.no-mistakes/worktrees/fb2ed104bd8c/01M4YNBPYF3W4E8XH139K1034X
cd "$REPO"
. "$REPO/tests/fixtures.sh"
unset FM_TEST_CLAUDE_CONFIG_DIR
export TMUX=fake,1,0

TMP_ROOT=$(fm_test_tmproot offline-local-secondmate-claude-models)

run_model_case() {
  local model=$1 case_dir="$TMP_ROOT/$1" id="offline-claude-$1"
  local home="$TMP_ROOT/$1/home" projects project pool origin main_home fakebin send_log launch_log
  local out status store launch_line treehouse_line
  projects="$home/projects"
  project="$projects/fixture"
  pool="$projects/.treehouse/fixture-r1/1/fixture"
  origin="$case_dir/origin.git"
  main_home="$case_dir/main-home"
  send_log="$case_dir/send.log"
  launch_log="$case_dir/launch.log"
  mkdir -p "$home/data/$id" "$projects" "$home/state" "$home/config" "$main_home/state"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$main_home" > "$home/.fm-secondmate-parent"

  git init --quiet -b main "$project"
  printf 'offline Claude model case: %s\n' "$model" > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  mkdir -p "$(dirname "$pool")"
  git -C "$project" worktree add --quiet --detach "$pool" HEAD

  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mv "$fakebin/tmux" "$fakebin/tmux.orig"
  cat > "$fakebin/tmux" <<'TMUX'
#!/usr/bin/env bash
if [ "${1:-}" = send-keys ] && [ "${4:-}" != -l ]; then
  printf '%s\n' "${4:-}" >> "${FM_FAKE_TMUX_TEXT_LOG:?}"
fi
exec "${0}.orig" "$@"
TMUX
  chmod +x "$fakebin/tmux"
  FM_FAKE_TMUX_TEXT_LOG="$send_log" FM_FAKE_LAUNCH_LOG="$launch_log" export FM_FAKE_TMUX_TEXT_LOG FM_FAKE_LAUNCH_LOG

  out=$(fm_test_run_spawn "$home" "$pool" "$fakebin" "$id" "$project" \
    --harness claude --model "$model" --effort high --scout)
  status=$?
  expect_code 0 "$status" "local secondmate Claude $model spawn failed: $out"
  assert_contains "$out" "spawned $id harness=claude kind=scout" "Claude $model spawn did not complete"
  assert_grep "worktree=$pool" "$home/state/$id.meta" "Claude $model metadata lost its local Treehouse worktree"
  assert_grep "harness=claude" "$home/state/$id.meta" "Claude $model metadata lost its harness"
  assert_grep "model=$model" "$home/state/$id.meta" "Claude $model metadata lost its selected model"
  assert_grep 'effort=high' "$home/state/$id.meta" "Claude model metadata lost its effort"

  treehouse_line=$(grep -F "treehouse --root '$projects' get" "$send_log" | head -n 1)
  [ -n "$treehouse_line" ] || fail "Claude $model did not route Treehouse to its local projects root"
  launch_line=$(grep -F -- "--model '$model' --effort 'high'" "$launch_log" | head -n 1)
  [ -n "$launch_line" ] || fail "Claude $model launch command omitted its selected model or effort"
  store="$home/user-home/.claude.json"
  [ -f "$store" ] || fail "Claude $model spawn did not persist workspace trust"
  grep -Fq "$pool" "$store" || fail "Claude $model trust store omitted its allocated worktree"

  printf '\nmodel=%s\n%s\nTreehouse request: %s\nClaude launch: %s\nmetadata: ' "$model" "$out" "$treehouse_line" "$launch_line"
  grep -E '^(harness|model|effort|worktree)=' "$home/state/$id.meta" | tr '\n' ' '
  printf '\nClaude trust store registered worktree=%s\n' "$pool"
}

printf '# Offline local-secondmate Claude worker launches\n'
for model in sonnet fable opus haiku; do
  run_model_case "$model"
done
printf '\n# all four local-secondmate Claude model cases passed\n'
