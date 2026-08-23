#!/usr/bin/env bash
# Fail-hard, runtime-capped wrapper that turns any command into a well-behaved batch job.
# pueue captures stdout/stderr (view with `batch view <id>`); this wrapper guarantees:
#   - hard runtime cap (no silent zombies)         BATCH_TIMEOUT (default 3600s)
#   - loud, machine-detectable failure              nonzero exit -> pueue marks Failed(code)
#   - structured start/done/fail + progress markers  @batch / @progress lines
# Jobs report progress by printing:  @progress <done>/<total> <message>
# Usage (run by pueue):  batch-exec.sh <label> -- <cmd> [args...]
set -uo pipefail
label="$1"; shift
[ "${1:-}" = "--" ] && shift
CAP="${BATCH_TIMEOUT:-3600}"
start=$(date +%s)
echo "@batch start label=$label cap=${CAP}s at=$(date -Is)"
set +e
timeout --signal=TERM --kill-after=20 "$CAP" "$@"
rc=$?
set -e
dur=$(( $(date +%s) - start ))
if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
  echo "@batch FAIL label=$label reason=timeout cap=${CAP}s dur=${dur}s"; exit 124
elif [ "$rc" -ne 0 ]; then
  echo "@batch FAIL label=$label reason=exit rc=$rc dur=${dur}s"; exit "$rc"
fi
echo "@batch done label=$label dur=${dur}s at=$(date -Is)"
