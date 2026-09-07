#!/usr/bin/env bash
# batch — one control surface for long-running background work, built on pueue (the job engine).
# Any command becomes a fail-hard, runtime-capped, progress-reporting job with a live board,
# detail view, and full process control. Self-describing: run `batch help`.
#
# WORKFLOW (a fresh agent needs nothing else):
#   batch run <group> <label> -- <cmd...>   enqueue a job (fail-hard; capped by BATCH_TIMEOUT=3600s)
#                                           the job may print  @progress <done>/<total> <msg>
#   batch board [group]                     live board: progress bar + table (Ctrl-C to exit)
#   batch ls [group]                        one-shot status
#   batch view <id>                         full captured output of one job
#   batch follow <id>                       stream one job live
#   batch wall [group]                      native Herdr live-pane wall (one pane per running job)
#   batch agents                            compact live dashboard of every agent (one glance)
#   batch subagents [show <id>]             pi/hermes Claude subagents across sessions (+ drill-in)
#   batch pick                              pick an agent from a list; preview + follow its output
#   batch watch [stop|status]               auto-open/refresh the wall whenever bots are running
#   batch retry <group|id>                  restart failed job(s)
#   batch parallel <group> <n>              set how many run at once in a group
#   batch pause|resume <group>              hold / release a group
#   batch kill <id>                         stop a running job
#   batch clean                             drop finished jobs from the queue
#
# Everything persists in the pueued daemon (survives your shell). Raw engine: `pueue <cmd>`.
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
EXEC="$DIR/batch-exec.sh"

die(){ echo "batch: $*" >&2; exit 1; }
command -v pueue >/dev/null 2>&1 || die "pueue not found on PATH (~/.local/bin). Install it first."
need_daemon(){ pgrep -x pueued >/dev/null 2>&1 || { pueued -d >/dev/null 2>&1 & sleep 1; }; pueue status >/dev/null 2>&1 || die "pueued not reachable"; }
ensure_group(){ pueue group --json 2>/dev/null | python3 -c "import sys,json;print('yes' if sys.argv[1] in json.load(sys.stdin).get('groups',{}) else 'no')" "$1" 2>/dev/null | grep -q yes || pueue group add "$1" >/dev/null 2>&1 || true; }

cmd="${1:-board}"; shift || true

case "$cmd" in
  run)
    [ $# -ge 3 ] || die "usage: batch run <group> <label> -- <cmd...>"
    need_daemon
    group="$1"; label="$2"; shift 2; [ "${1:-}" = "--" ] && shift
    [ $# -ge 1 ] || die "no command given after --"
    ensure_group "$group"
    id=$(pueue add --group "$group" --label "$label" --print-task-id --escape -- \
          bash "$EXEC" "$label" -- "$@") || die "enqueue failed"
    echo "queued: group=$group label=$label id=$id"
    w=$HOME/firstmate/state/atlas-runs/agent-watch.sh; [ -x "$w" ] && bash "$w" ensure >/dev/null 2>&1 || true
    ;;
  ls)   need_daemon; pueue status ${1:+--group "$1"} ;;
  view) need_daemon; [ $# -ge 1 ] || die "usage: batch view <id>"; pueue log "$1" --full 2>/dev/null || pueue log "$1" ;;
  follow) need_daemon; [ $# -ge 1 ] || die "usage: batch follow <id>"; exec pueue follow "$1" ;;
  wall)
    # Herdr-default (it's inside your view); --wezterm for a native window; --raw for full tail
    hd=$HOME/firstmate/state/atlas-runs/herdr-wall.sh
    wz=$HOME/firstmate/state/atlas-runs/wezterm-wall.sh
    use_wz=0
    for a in "$@"; do case "$a" in --raw) export RAW=1;; --wezterm) use_wz=1;; --herdr) use_wz=0;; esac; done
    if [ "$use_wz" = 1 ] && [ -x "$wz" ]; then exec bash "$wz"
    elif [ -x "$hd" ]; then exec bash "$hd"
    else die "no wall tool present (atlas-local)"; fi ;;
  agents) a=$HOME/firstmate/state/atlas-runs/agent-board.py; [ -f "$a" ] && exec python3 "$a" || die "agent-board.py not present (atlas-local tool)" ;;
  subagents) s=$HOME/firstmate/state/atlas-runs/subagents.py; [ -f "$s" ] && exec python3 "$s" "$@" || die "subagents.py not present (atlas-local tool)" ;;
  pick) p=$HOME/firstmate/state/atlas-runs/agent-pick.sh; [ -x "$p" ] && exec bash "$p" || die "agent-pick.sh not present (atlas-local tool)" ;;
  watch) w=$HOME/firstmate/state/atlas-runs/agent-watch.sh; [ -x "$w" ] && exec bash "$w" "${1:-run}" || die "agent-watch.sh not present (atlas-local tool)" ;;
  retry)
    need_daemon; [ $# -ge 1 ] || die "usage: batch retry <group|id>"
    if [[ "$1" =~ ^[0-9]+$ ]]; then pueue restart --in-place "$1"; else
      ids=$(pueue status --json | python3 -c "
import sys,json
g=sys.argv[1]; d=json.load(sys.stdin)
def failed(s):
    return isinstance(s,dict) and 'Done' in s and s['Done'].get('result')!='Success'
print(' '.join(k for k,t in d['tasks'].items() if t.get('group')==g and failed(t.get('status'))))" "$1")
      [ -n "$ids" ] && pueue restart --in-place $ids || echo "no failed jobs in group '$1'"
    fi ;;
  parallel) need_daemon; [ $# -ge 2 ] || die "usage: batch parallel <group> <n>"; pueue parallel -g "$1" "$2" ;;
  pause) need_daemon; pueue pause --group "$1" ;;
  resume|start) need_daemon; pueue start --group "$1" ;;
  kill) need_daemon; [ $# -ge 1 ] || die "usage: batch kill <id>"; pueue kill "$1" ;;
  clean) need_daemon; pueue clean ;;
  help|-h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
  board)
    need_daemon; group="${1:-}"; refresh="${BATCH_REFRESH:-3}"
    trap 'exit 0' INT
    while :; do
      json=$(pueue status --json 2>/dev/null) || { echo "pueued not reachable"; sleep "$refresh"; continue; }
      clear
      printf '%s' "$json" | python3 "$DIR/board.py" "$group"
      sleep "$refresh"
    done ;;
  *) die "unknown command '$cmd' — run: batch help" ;;
esac
