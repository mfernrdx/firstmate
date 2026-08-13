#!/usr/bin/env bash
# Behavior tests for bin/fm-ensure-agents-md.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-ensure-agents-md)

test_created_agents_md_includes_self_governance() {
  local repo agents
  repo="$TMP_ROOT/new-project"
  mkdir -p "$repo"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 || fail "fm-ensure-agents-md.sh failed for empty project"
  agents="$repo/AGENTS.md"
  assert_present "$agents" "AGENTS.md was not created"
  assert_present "$repo/CLAUDE.md" "CLAUDE.md symlink was not created"
  [ -L "$repo/CLAUDE.md" ] || fail "CLAUDE.md is not a symlink"
  assert_grep "## Maintaining this file" "$agents" "self-governance section heading missing"
  assert_grep "Keep this file for knowledge useful to almost every future agent session in this project." "$agents" \
    "self-governance section lost the future-session bar"
  assert_grep "Do not repeat what the codebase already shows; point to the authoritative file or command instead." "$agents" \
    "self-governance section lost pointer-over-copy guidance"
  assert_grep "Prefer rewriting or pruning existing entries over appending new ones." "$agents" \
    "self-governance section lost rewrite-or-prune guidance"
  assert_grep "When updating this file, preserve this bar for all agents and keep entries concise." "$agents" \
    "self-governance section lost all-agents maintenance guidance"
  pass "fm-ensure-agents-md.sh: created AGENTS.md includes self-governance section"
}

test_promoted_claude_md_stays_real_not_symlink() {
  # Requirement: a repo that already has a real, regular CLAUDE.md must
  # never be converted into a symlink arrangement by this helper (the
  # site-feasibility regression). Promotion must copy, not move+symlink,
  # and the result must stay idempotent on a re-run.
  local repo agents out count
  repo="$TMP_ROOT/claude-project"
  mkdir -p "$repo"
  cat > "$repo/CLAUDE.md" <<'EOF'
# Existing agent memory

Run tests with `make test`.
EOF
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 || fail "fm-ensure-agents-md.sh failed for CLAUDE.md promotion"
  agents="$repo/AGENTS.md"
  assert_present "$agents" "AGENTS.md was not created during promotion"
  [ ! -L "$repo/CLAUDE.md" ] || fail "CLAUDE.md was converted into a symlink during promotion"
  [ -f "$repo/CLAUDE.md" ] || fail "CLAUDE.md is no longer a real file after promotion"
  assert_grep "Run tests with \`make test\`." "$agents" \
    "promotion lost existing CLAUDE.md content"
  assert_grep "Run tests with \`make test\`." "$repo/CLAUDE.md" \
    "promotion lost CLAUDE.md's own original content"
  count=$(grep -Fc "## Maintaining this file" "$agents")
  [ "$count" -eq 1 ] || fail "promotion wrote $count self-governance sections"
  assert_grep "Keep this file for knowledge useful to almost every future agent session in this project." "$agents" \
    "promoted AGENTS.md missing self-governance wording"
  cmp -s "$agents" "$repo/CLAUDE.md" \
    || fail "promoted AGENTS.md and CLAUDE.md are not kept in sync"
  # Re-run must stay idempotent: still no symlink, reported unchanged.
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on idempotent re-run after promotion"
  assert_contains "$out" "unchanged:" "idempotent re-run after promotion did not report unchanged"
  [ ! -L "$repo/CLAUDE.md" ] || fail "idempotent re-run turned CLAUDE.md into a symlink"
  pass "fm-ensure-agents-md.sh: promoted CLAUDE.md stays a real file, never a symlink, and is idempotent"
}

test_promoted_claude_md_without_trailing_newline_keeps_blank_separator() {
  local repo agents before
  repo="$TMP_ROOT/no-trailing-newline-project"
  mkdir -p "$repo"
  printf '# Existing agent memory\n\nRun tests with make test.' > "$repo/CLAUDE.md"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 || fail "fm-ensure-agents-md.sh failed for newline-less CLAUDE.md promotion"
  agents="$repo/AGENTS.md"
  assert_grep "Run tests with make test." "$agents" \
    "newline-less promotion lost or mangled the last content line"
  assert_grep "## Maintaining this file" "$agents" \
    "newline-less promotion did not append the self-governance section"
  before=$(grep -B1 -Fx '## Maintaining this file' "$agents" | head -n 1)
  [ -z "$before" ] || fail "self-governance heading not preceded by a blank line (got: $before)"
  [ ! -L "$repo/CLAUDE.md" ] || fail "newline-less promotion converted CLAUDE.md into a symlink"
  pass "fm-ensure-agents-md.sh: newline-less promotion keeps a blank separator line"
}

test_existing_agents_md_with_symlink_gains_self_governance() {
  local repo agents out count
  repo="$TMP_ROOT/existing-symlinked-project"
  mkdir -p "$repo"
  printf '# Existing agent memory\n\nBuild with make.\n' > "$repo/AGENTS.md"
  ln -s AGENTS.md "$repo/CLAUDE.md"
  agents="$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed for existing AGENTS.md with symlink"
  assert_contains "$out" "updated:" "injection into existing AGENTS.md did not report an update"
  assert_grep "Build with make." "$agents" "injection dropped existing AGENTS.md content"
  assert_grep "## Maintaining this file" "$agents" "existing AGENTS.md did not gain the self-governance section"
  count=$(grep -Fc "## Maintaining this file" "$agents")
  [ "$count" -eq 1 ] || fail "injection wrote $count self-governance sections"
  [ -L "$repo/CLAUDE.md" ] || fail "CLAUDE.md is no longer a symlink after injection"
  # Re-run must be a byte-exact no-op reporting unchanged.
  cp "$agents" "$repo/.after-first"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on idempotent re-run"
  assert_contains "$out" "unchanged:" "idempotent re-run did not report unchanged"
  diff "$repo/.after-first" "$agents" >/dev/null \
    || fail "idempotent re-run modified AGENTS.md"
  pass "fm-ensure-agents-md.sh: existing symlinked AGENTS.md gains the section idempotently"
}

test_existing_agents_md_without_claude_gains_section_and_symlink() {
  local repo agents out count
  repo="$TMP_ROOT/existing-bare-project"
  mkdir -p "$repo"
  printf '# Existing agent memory\n\nDeploy with kubectl.\n' > "$repo/AGENTS.md"
  agents="$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed for existing AGENTS.md without CLAUDE.md"
  assert_contains "$out" "updated:" "injection without CLAUDE.md did not report an update"
  [ -L "$repo/CLAUDE.md" ] || fail "CLAUDE.md symlink was not created"
  assert_grep "Deploy with kubectl." "$agents" "injection dropped existing AGENTS.md content"
  count=$(grep -Fc "## Maintaining this file" "$agents")
  [ "$count" -eq 1 ] || fail "injection wrote $count self-governance sections"
  pass "fm-ensure-agents-md.sh: existing AGENTS.md without CLAUDE.md gains section and symlink"
}

test_existing_agents_md_with_section_reports_unchanged() {
  local repo agents out
  repo="$TMP_ROOT/fully-formed-project"
  mkdir -p "$repo"
  # Build a fully-formed project (AGENTS.md with the section + correct symlink).
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 \
    || fail "fm-ensure-agents-md.sh failed building the fully-formed fixture"
  agents="$repo/AGENTS.md"
  cp "$agents" "$repo/.before"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on already-formed project"
  assert_contains "$out" "unchanged:" "already-formed project was not reported unchanged"
  diff "$repo/.before" "$agents" >/dev/null \
    || fail "already-formed AGENTS.md was modified"
  pass "fm-ensure-agents-md.sh: AGENTS.md that already has the section stays unchanged"
}

test_existing_crlf_agents_md_with_section_stays_unchanged() {
  local repo agents out count
  repo="$TMP_ROOT/crlf-formed-project"
  mkdir -p "$repo"
  printf '%s\r\n' \
    '# Existing agent memory' \
    '' \
    '## Maintaining this file' \
    '' \
    'Keep this file for knowledge useful to almost every future agent session in this project.' \
    'Do not repeat what the codebase already shows; point to the authoritative file or command instead.' \
    'Prefer rewriting or pruning existing entries over appending new ones.' \
    'When updating this file, preserve this bar for all agents and keep entries concise.' > "$repo/AGENTS.md"
  ln -s AGENTS.md "$repo/CLAUDE.md"
  agents="$repo/AGENTS.md"
  cp "$agents" "$repo/.before"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on CRLF AGENTS.md with the section"
  assert_contains "$out" "unchanged:" "complete CRLF AGENTS.md was not reported unchanged"
  cmp -s "$repo/.before" "$agents" \
    || fail "complete CRLF AGENTS.md was modified"
  count=$(LC_ALL=C grep -a -c '## Maintaining this file' "$agents")
  [ "$count" -eq 1 ] || fail "complete CRLF AGENTS.md has $count self-governance sections"
  pass "fm-ensure-agents-md.sh: CRLF AGENTS.md with the section stays unchanged"
}

test_existing_crlf_agents_md_without_section_preserves_crlf() {
  local repo agents out
  repo="$TMP_ROOT/crlf-injected-project"
  mkdir -p "$repo"
  printf '%s\r\n' \
    '# Existing agent memory' \
    '' \
    'Run tests with make test.' > "$repo/AGENTS.md"
  ln -s AGENTS.md "$repo/CLAUDE.md"
  agents="$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed injecting into CRLF AGENTS.md"
  assert_contains "$out" "updated:" "CRLF AGENTS.md injection did not report an update"
  printf '%s\r\n' \
    '# Existing agent memory' \
    '' \
    'Run tests with make test.' \
    '' \
    '## Maintaining this file' \
    '' \
    'Keep this file for knowledge useful to almost every future agent session in this project.' \
    'Do not repeat what the codebase already shows; point to the authoritative file or command instead.' \
    'Prefer rewriting or pruning existing entries over appending new ones.' \
    'When updating this file, preserve this bar for all agents and keep entries concise.' > "$repo/.expected"
  cmp -s "$repo/.expected" "$agents" \
    || fail "CRLF AGENTS.md injection did not preserve CRLF line endings"
  cp "$agents" "$repo/.after-first"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 \
    || fail "fm-ensure-agents-md.sh failed on idempotent CRLF re-run"
  cmp -s "$repo/.after-first" "$agents" \
    || fail "idempotent CRLF re-run modified AGENTS.md"
  pass "fm-ensure-agents-md.sh: CRLF injection preserves line endings idempotently"
}

test_windows_style_repo_promotion_never_symlinks_claude_md() {
  # The concrete site-feasibility regression: a repo checked out where git
  # will not materialize symlinks (core.symlinks=false, as git records on a
  # native Windows checkout) already has a real CLAUDE.md. Running the
  # helper must not reproduce the reverted bug by turning it into a symlink.
  local repo agents out
  repo="$TMP_ROOT/site-feasibility-shaped"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config core.symlinks false
  cat > "$repo/CLAUDE.md" <<'EOF'
# site-feasibility agent memory

Build with the Windows toolchain.
EOF
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed for the site-feasibility-shaped repo"
  agents="$repo/AGENTS.md"
  assert_present "$agents" "AGENTS.md was not created for the site-feasibility-shaped repo"
  [ ! -L "$repo/CLAUDE.md" ] || fail "a CLAUDE.md symlink was created on a core.symlinks=false repo"
  [ -f "$repo/CLAUDE.md" ] || fail "CLAUDE.md is no longer a real file"
  assert_grep "Build with the Windows toolchain." "$repo/CLAUDE.md" \
    "original CLAUDE.md content was lost"
  assert_grep "Build with the Windows toolchain." "$agents" \
    "promoted AGENTS.md missing the original CLAUDE.md content"
  pass "fm-ensure-agents-md.sh: never symlinks CLAUDE.md on a core.symlinks=false (Windows-shaped) repo"
}

test_symlinks_unreliable_creates_real_synced_claude_md() {
  # No CLAUDE.md yet, but this repo's git will not materialize symlinks:
  # the helper must still succeed and produce a usable, real CLAUDE.md
  # instead of a symlink that would dangle as a text stub on checkout.
  local repo agents out
  repo="$TMP_ROOT/unsafe-symlink-fresh"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config core.symlinks false
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed for a core.symlinks=false repo"
  agents="$repo/AGENTS.md"
  assert_present "$agents" "AGENTS.md was not created for a core.symlinks=false repo"
  assert_present "$repo/CLAUDE.md" "CLAUDE.md was not created for a core.symlinks=false repo"
  [ ! -L "$repo/CLAUDE.md" ] || fail "a CLAUDE.md symlink was created on a core.symlinks=false repo"
  cmp -s "$agents" "$repo/CLAUDE.md" \
    || fail "real CLAUDE.md is not kept in sync with AGENTS.md"
  assert_grep "## Maintaining this file" "$repo/CLAUDE.md" \
    "real CLAUDE.md missing the self-governance section"
  # Re-run must stay idempotent.
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on idempotent re-run for a core.symlinks=false repo"
  assert_contains "$out" "unchanged:" "idempotent re-run on a core.symlinks=false repo did not report unchanged"
  pass "fm-ensure-agents-md.sh: symlinks-unreliable repo gets a real, synced CLAUDE.md and stays idempotent"
}

test_symlinks_unreliable_agents_only_creates_real_claude_md() {
  # AGENTS.md already exists (no CLAUDE.md yet) on a repo whose git will not
  # materialize symlinks: the CLAUDE.md this helper adds must be real too.
  local repo agents out
  repo="$TMP_ROOT/unsafe-symlink-agents-only"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config core.symlinks false
  printf '# Existing agent memory\n\nDeploy with the release script.\n' > "$repo/AGENTS.md"
  agents="$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed adding CLAUDE.md on a core.symlinks=false repo"
  [ ! -L "$repo/CLAUDE.md" ] || fail "a CLAUDE.md symlink was created on a core.symlinks=false repo"
  cmp -s "$agents" "$repo/CLAUDE.md" \
    || fail "real CLAUDE.md is not kept in sync with existing AGENTS.md"
  pass "fm-ensure-agents-md.sh: adds a real, synced CLAUDE.md when only AGENTS.md exists and symlinks are unreliable"
}

test_both_real_files_with_different_content_still_conflicts() {
  # A genuine conflict - two real files that were never synced by this
  # helper - must still be refused rather than silently merged.
  local repo out rc
  repo="$TMP_ROOT/genuine-conflict"
  mkdir -p "$repo"
  printf '# AGENTS content\n' > "$repo/AGENTS.md"
  printf '# different CLAUDE content\n' > "$repo/CLAUDE.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for distinct real AGENTS.md and CLAUDE.md"
  assert_contains "$out" "conflict:" "distinct real files did not report a conflict"
  assert_present "$repo/AGENTS.md" "AGENTS.md was disturbed by the conflict check"
  assert_present "$repo/CLAUDE.md" "CLAUDE.md was disturbed by the conflict check"
  assert_grep "different CLAUDE content" "$repo/CLAUDE.md" "CLAUDE.md content was overwritten"
  pass "fm-ensure-agents-md.sh: refuses two real files with different content"
}

test_lowercase_agents_md_refuses_case_fragile_symlink() {
  local repo out rc
  repo="$TMP_ROOT/lowercase-project"
  mkdir -p "$repo"
  printf '# project memory\n' > "$repo/agents.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for a lowercase agents.md"
  assert_contains "$out" "conflict:" "lowercase agents.md did not report a conflict"
  assert_contains "$out" "agents.md" "conflict message did not name the offending file"
  assert_absent "$repo/CLAUDE.md" "a case-fragile CLAUDE.md symlink was created for lowercase agents.md"
  [ ! -L "$repo/CLAUDE.md" ] || fail "a case-fragile CLAUDE.md symlink was created for lowercase agents.md"
  assert_present "$repo/agents.md" "the real lowercase agents.md was disturbed"
  pass "fm-ensure-agents-md.sh: refuses a case-variant lowercase agents.md (issue #389)"
}

test_created_agents_md_includes_self_governance
test_promoted_claude_md_stays_real_not_symlink
test_promoted_claude_md_without_trailing_newline_keeps_blank_separator
test_existing_agents_md_with_symlink_gains_self_governance
test_existing_agents_md_without_claude_gains_section_and_symlink
test_existing_agents_md_with_section_reports_unchanged
test_existing_crlf_agents_md_with_section_stays_unchanged
test_existing_crlf_agents_md_without_section_preserves_crlf
test_windows_style_repo_promotion_never_symlinks_claude_md
test_symlinks_unreliable_creates_real_synced_claude_md
test_symlinks_unreliable_agents_only_creates_real_claude_md
test_both_real_files_with_different_content_still_conflicts
test_lowercase_agents_md_refuses_case_fragile_symlink
