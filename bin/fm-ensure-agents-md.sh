#!/usr/bin/env bash
# Ensure a project worktree follows the agent-memory file convention.
# AGENTS.md is the real project-intrinsic knowledge file; CLAUDE.md points at
# it for compatibility, as a relative symlink when this worktree's git will
# actually materialize one, or as a real regular-file duplicate kept in sync
# otherwise (see claude_symlink_unsafe() below). Creates a minimal AGENTS.md
# skeleton when neither file exists, promotes a real CLAUDE.md file when it
# is the only file present, and refuses to clobber distinct real files or
# wrong symlinks.
# Owns the canonical "## Maintaining this file" self-governance wording for
# project AGENTS.md files, injecting it idempotently into created skeletons,
# promoted CLAUDE.md files, and any existing AGENTS.md that still lacks it.
# Refuses a case-variant real memory file such as a lowercase agents.md, whose
# CLAUDE.md symlink would carry an uppercase literal target that dangles on a
# case-sensitive filesystem (issue #389).
# Never converts an already-real, regular CLAUDE.md into a symlink. Git on
# Windows checkouts commonly runs with core.symlinks=false, where a tracked
# symlink materializes on checkout as a plain text file containing its link
# target rather than a real symlink, so any agent that reads CLAUDE.md
# silently stops seeing project instructions. A project may already have hit
# and reverted exactly that (see the site-feasibility project's
# docs/STATUS.md:187 at the time this was written); re-promoting its real
# CLAUDE.md back into a symlink would reintroduce the same silent breakage,
# so promotion always copies instead, regardless of whether this worktree's
# own filesystem happens to support symlinks.
# This is a worktree utility for crewmates, not a supervision script, so it does
# not call fm-guard.sh.
# Usage: fm-ensure-agents-md.sh [repo-or-worktree-dir]
set -eu

usage() {
  echo "usage: fm-ensure-agents-md.sh [repo-or-worktree-dir]" >&2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac
[ "$#" -le 1 ] || { usage; exit 1; }

DIR=${1:-.}
[ -d "$DIR" ] || { echo "error: not a directory: $DIR" >&2; exit 1; }
DIR=$(cd "$DIR" && pwd -P)
cd "$DIR"

AGENTS=AGENTS.md
CLAUDE=CLAUDE.md

write_maintenance_section() {
  cat <<'EOF'
## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
EOF
}

write_maintenance_section_with_eol() {
  local eol=$1 line
  while IFS= read -r line; do
    printf '%s%s' "$line" "$eol"
  done < <(write_maintenance_section)
}

# Idempotently append the canonical self-governance section to AGENTS.md when it
# is absent. Sets MAINT_INJECTED=1 when it appends and 0 when the section is
# already present, so callers can report whether the file changed.
MAINT_INJECTED=0
ensure_maintenance_section() {
  MAINT_INJECTED=0
  if grep -Fqx '## Maintaining this file' "$AGENTS" ||
    grep -Fqx $'## Maintaining this file\r' "$AGENTS"; then
    return 0
  fi
  local eol=$'\n' sep=''
  if LC_ALL=C grep -q $'\r$' "$AGENTS"; then
    eol=$'\r\n'
  fi
  if [ -s "$AGENTS" ]; then
    if [ -n "$(tail -c 1 "$AGENTS")" ]; then
      sep="${eol}${eol}"
    else
      sep=$eol
    fi
  fi
  {
    printf '%s' "$sep"
    write_maintenance_section_with_eol "$eol"
  } >> "$AGENTS"
  MAINT_INJECTED=1
}

write_skeleton() {
  cat > "$AGENTS" <<'EOF'
# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.
EOF
  ensure_maintenance_section
}

is_correct_claude_symlink() {
  [ -L "$CLAUDE" ] || return 1
  target=$(readlink "$CLAUDE")
  case "$target" in
    "$AGENTS"|"./$AGENTS") return 0 ;;
  esac
  [ -e "$AGENTS" ] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$CLAUDE" "$AGENTS" <<'PY'
import os
import sys
sys.exit(0 if os.path.realpath(sys.argv[1]) == os.path.realpath(sys.argv[2]) else 1)
PY
    return $?
  fi
  return 1
}

# Remove the symlink probe and drop the cleanup traps installed for it, so the
# rest of the run is back to the script's default signal handling.
clear_probe() {
  rm -f "$1" 2>/dev/null || true
  trap - EXIT INT TERM
}

# Decide whether a CLAUDE.md symlink written in $DIR can be trusted to
# survive as a real symlink for the next checkout of this repository, rather
# than degrading into a plain-text stub holding the link target (the
# site-feasibility regression described above). Returns success (0 = "true",
# unsafe) when a symlink should NOT be created here. Two independent,
# empirically-checked signals feed this rather than guessing from the path:
#   - git's own effective core.symlinks for this exact repository. Git
#     probes filesystem symlink support at clone/init time and records the
#     result; an explicit "false" is git's own record that it will
#     materialize a tracked symlink here as a plain text file on checkout,
#     so it is trusted outright without a second-guessing probe.
#   - a live filesystem probe: actually create and remove a throwaway
#     symlink in $DIR. This catches worktrees where git has not recorded
#     core.symlinks (a bare `git init`, or a git version that leaves it
#     unset when true) and any other reason symlink creation might fail or
#     silently degrade to a regular file.
# Either signal alone is enough to call it unsafe; both must pass for a
# symlink to be created.
claude_symlink_unsafe() {
  local core_symlinks probe
  core_symlinks=$(git -C "$DIR" config --bool core.symlinks 2>/dev/null || true)
  if [ "$core_symlinks" = "false" ]; then
    return 0
  fi
  probe="$DIR/.fm-ensure-agents-md.symlink-probe.$$"
  rm -f "$probe" 2>/dev/null || true
  trap 'rm -f "$probe" 2>/dev/null || true' EXIT
  trap 'rm -f "$probe" 2>/dev/null || true; trap - INT; kill -INT $$' INT
  trap 'rm -f "$probe" 2>/dev/null || true; trap - TERM; kill -TERM $$' TERM
  if ! ln -s "probe-target" "$probe" 2>/dev/null; then
    clear_probe "$probe"
    return 0
  fi
  if [ ! -L "$probe" ]; then
    clear_probe "$probe"
    return 0
  fi
  clear_probe "$probe"
  return 1
}

# Point CLAUDE.md at AGENTS.md. AGENTS.md must already hold its final content
# (including any injected maintenance section) before this runs, so a
# real-file duplicate starts in sync with it.
create_claude() {
  if claude_symlink_unsafe; then
    cp "$AGENTS" "$CLAUDE"
  else
    ln -s "$AGENTS" "$CLAUDE"
  fi
}

# Refresh a real (non-symlink) CLAUDE.md so its content matches AGENTS.md
# again, e.g. after ensure_maintenance_section appended to AGENTS.md. A no-op
# when CLAUDE.md is a symlink, since it already resolves live.
sync_claude() {
  [ -L "$CLAUDE" ] && return 0
  cp "$AGENTS" "$CLAUDE"
}

# Refuse a case-variant real memory file (issue #389). On a case-insensitive
# filesystem an existing lowercase agents.md satisfies every [ -e AGENTS.md ]
# test below, so the script would emit a CLAUDE.md symlink whose uppercase
# literal target dangles once the tree is checked out on a case-sensitive
# filesystem. Reading the real directory entries catches the mismatch on both
# filesystem kinds; surface it for manual reconciliation instead of linking blindly.
for entry in *; do
  if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
    continue
  fi
  if [ "$entry" != "$AGENTS" ]; then
    case "$entry" in
      [Aa][Gg][Ee][Nn][Tt][Ss].[Mm][Dd])
        echo "conflict: memory file is named $entry in $DIR but the convention is AGENTS.md; rename it to AGENTS.md so CLAUDE.md links portably" >&2
        exit 1
        ;;
    esac
  fi
done

if [ -L "$AGENTS" ]; then
  echo "conflict: AGENTS.md is a symlink in $DIR; expected AGENTS.md to be the real file" >&2
  exit 1
fi
if [ -e "$AGENTS" ] && [ ! -f "$AGENTS" ]; then
  echo "conflict: AGENTS.md exists in $DIR but is not a regular file" >&2
  exit 1
fi

if [ -e "$AGENTS" ]; then
  if [ -L "$CLAUDE" ]; then
    if is_correct_claude_symlink; then
      ensure_maintenance_section
      if [ "$MAINT_INJECTED" -eq 1 ]; then
        echo "updated: added ## Maintaining this file to AGENTS.md in $DIR"
      else
        echo "unchanged: AGENTS.md with CLAUDE.md -> AGENTS.md in $DIR"
      fi
      exit 0
    fi
    echo "conflict: CLAUDE.md is a symlink in $DIR but does not point to AGENTS.md" >&2
    exit 1
  fi
  if [ ! -e "$CLAUDE" ]; then
    ensure_maintenance_section
    create_claude
    if [ -L "$CLAUDE" ]; then
      if [ "$MAINT_INJECTED" -eq 1 ]; then
        echo "updated: added ## Maintaining this file to AGENTS.md and symlinked CLAUDE.md -> AGENTS.md in $DIR"
      else
        echo "symlinked: CLAUDE.md -> AGENTS.md in $DIR"
      fi
    else
      if [ "$MAINT_INJECTED" -eq 1 ]; then
        echo "updated: added ## Maintaining this file to AGENTS.md and created a real CLAUDE.md kept in sync with it in $DIR (symlinks unreliable here)"
      else
        echo "synced: created a real CLAUDE.md kept in sync with AGENTS.md in $DIR (symlinks unreliable here)"
      fi
    fi
    exit 0
  fi
  if [ -f "$CLAUDE" ]; then
    if cmp -s "$AGENTS" "$CLAUDE"; then
      ensure_maintenance_section
      sync_claude
      if [ "$MAINT_INJECTED" -eq 1 ]; then
        echo "updated: added ## Maintaining this file to AGENTS.md and CLAUDE.md in $DIR"
      else
        echo "unchanged: AGENTS.md and CLAUDE.md are real, synced files in $DIR"
      fi
      exit 0
    fi
    echo "conflict: both AGENTS.md and CLAUDE.md are real files in $DIR with different content; reconcile them manually" >&2
    exit 1
  fi
  echo "conflict: CLAUDE.md exists in $DIR but is not a regular file or symlink" >&2
  exit 1
fi

if [ -L "$CLAUDE" ]; then
  if is_correct_claude_symlink; then
    write_skeleton
    echo "created: AGENTS.md and kept CLAUDE.md -> AGENTS.md in $DIR"
    exit 0
  fi
  echo "conflict: CLAUDE.md is a symlink in $DIR but AGENTS.md is missing and the link does not point to AGENTS.md" >&2
  exit 1
fi

if [ -e "$CLAUDE" ]; then
  if [ -f "$CLAUDE" ]; then
    # A real, regular CLAUDE.md already here is deliberate project content.
    # Promote it into the AGENTS.md convention by copying, never by moving
    # it into a symlink target: see the file header for why an already-real
    # CLAUDE.md is never turned into a symlink here.
    cp "$CLAUDE" "$AGENTS"
    ensure_maintenance_section
    sync_claude
    echo "promoted: copied CLAUDE.md content into AGENTS.md and kept CLAUDE.md as a real file in $DIR"
    exit 0
  fi
  echo "conflict: CLAUDE.md exists in $DIR but is not a regular file or symlink" >&2
  exit 1
fi

write_skeleton
create_claude
if [ -L "$CLAUDE" ]; then
  echo "created: AGENTS.md and CLAUDE.md -> AGENTS.md in $DIR"
else
  echo "created: AGENTS.md and a real CLAUDE.md kept in sync with it in $DIR (symlinks unreliable here)"
fi
