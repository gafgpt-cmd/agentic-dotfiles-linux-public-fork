#!/usr/bin/env bash
# upstream-sync: read-only check of how far the upstream(s) this Linux port
# tracks have moved ahead, so an agent (or cron) knows when a sync pass is due.
# Never merges, checks out, or pushes. Triage results by CONTENT — see SKILL.md.
set -euo pipefail

usage() {
  cat <<'EOF'
check-upstream.sh — read-only: report how far the tracked upstream(s) moved ahead.
  --notify          desktop notification if ahead (needs notify-send)
  --include-taffin  also check the secondary upstream (GuillaumeTaffin/dotfiles-linux)
  --quiet           notify/counts only, suppress the report text
  -h, --help        this help
Never merges, checks out, or pushes. The subject list is a hint only; a port
has rewritten SHAs so most "new" commits are already ported — triage by content.
EOF
}

NOTIFY=0; INCLUDE_TAFFIN=0; QUIET=0
for arg in "$@"; do
  case "$arg" in
    --notify) NOTIFY=1 ;;
    --include-taffin) INCLUDE_TAFFIN=1 ;;
    --quiet) QUIET=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

# Resolve the repo from this script's real path (works via the deployed symlink too).
SELF="$(readlink -f "$0")"
REPO="$(cd "$(dirname "$SELF")" && git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO" ] || { echo "upstream-sync: cannot locate git repo from $SELF" >&2; exit 1; }

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }

REPORT_AHEAD=0
check_remote() {
  local remote="$1" label="$2" ref="" r ahead last
  REPORT_AHEAD=0
  if ! git -C "$REPO" remote get-url "$remote" >/dev/null 2>&1; then
    say "- $label ($remote): remote not configured, skipping"; return 0
  fi
  if ! git -C "$REPO" fetch --quiet "$remote" 2>/dev/null; then
    say "- $label ($remote): fetch failed (offline?)"; return 0
  fi
  for r in "$remote/main" "$remote/master"; do
    if git -C "$REPO" rev-parse --verify "refs/remotes/$r" >/dev/null 2>&1; then ref="$r"; break; fi
  done
  [ -n "$ref" ] || { say "- $label ($remote): no main/master branch"; return 0; }
  ahead="$(git -C "$REPO" rev-list --count "HEAD..$ref" 2>/dev/null || echo 0)"
  REPORT_AHEAD="$ahead"
  if [ "$ahead" -gt 0 ]; then
    last="$(git -C "$REPO" log -1 --format='%cs %s' "$ref" 2>/dev/null || true)"
    say ""
    say ">> $label ($remote): $ahead commit(s) ahead of your HEAD. latest: $last"
    say "   new subjects (HINT ONLY — most may already be ported; triage by content):"
    git -C "$REPO" log --format='     %h %s' "HEAD..$ref" 2>/dev/null | head -30 | while IFS= read -r l; do say "$l"; done
  else
    say "- $label ($remote): up to date"
  fi
}

say "upstream-sync . $REPO . branch $(git -C "$REPO" branch --show-current 2>/dev/null)"
check_remote kun "Kun (primary)";           KUN_AHEAD="$REPORT_AHEAD"
TAFFIN_AHEAD=0
if [ "$INCLUDE_TAFFIN" = 1 ]; then
  check_remote upstream "Taffin (secondary)"; TAFFIN_AHEAD="$REPORT_AHEAD"
fi

TOTAL=$(( KUN_AHEAD + TAFFIN_AHEAD ))
if [ "$NOTIFY" = 1 ] && [ "$TOTAL" -gt 0 ] && command -v notify-send >/dev/null 2>&1; then
  msg="Kun +$KUN_AHEAD"
  [ "$INCLUDE_TAFFIN" = 1 ] && msg="$msg, Taffin +$TAFFIN_AHEAD"
  notify-send "dotfiles: upstream moved ahead" "$msg. Run the upstream-sync skill to triage what is worth porting."
fi
say ""
say "PORT, not a fork: never merge/rebase upstream. Cherry-pick + adapt. See SKILL.md."
exit 0
