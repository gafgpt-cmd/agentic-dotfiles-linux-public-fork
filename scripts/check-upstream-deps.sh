#!/usr/bin/env bash
# Weekly upstream dependency check for the medical-research toolchain.
# Deployed by home-manager as a systemd user timer. Zero tokens — just version comparison.
# Writes to ~/.local/state/upstream-checks.log (XDG state dir).
set -euo pipefail

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/upstream-checks"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$(date +%Y-%m-%d).log"
exec >> "$LOG" 2>&1
echo "=== $(date -Iseconds) ==="

check() {
    local name="$1" installed="$2" latest="$3"
    if [ "$installed" = "$latest" ]; then
        echo "  OK  $name v${installed}"
    elif [ -z "$latest" ] || [ "$latest" = "UNKNOWN" ]; then
        echo "  ?   $name v${installed} (could not reach upstream)"
    else
        echo "  NEW $name v${installed} → v${latest}"
        echo "      update: $4"
    fi
}

# 1. academic-research-skills (Claude Code plugin — installed from GitHub, not npm)
ARS_INSTALLED=$(python3 -c "
import json, pathlib
d = json.loads(pathlib.Path.home().joinpath('.claude/plugins/installed_plugins.json').read_text())
ars = d.get('plugins', {}).get('academic-research-skills@academic-research-skills', [])
print(ars[0].get('gitCommitSha', ars[0].get('version', '?'))[:12] if ars else 'NOT_INSTALLED')
" 2>/dev/null || echo "NOT_INSTALLED")
ARS_REPO="https://api.github.com/repos/Imbad0202/academic-research-skills/commits/main"
ARS_LATEST=$(curl -sf "$ARS_REPO" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['sha'][:12])" 2>/dev/null || echo "UNKNOWN")
check "academic-research-skills" "$ARS_INSTALLED" "$ARS_LATEST" \
    "claude plugins update academic-research-skills@academic-research-skills"

# 2. pi-subagents
PI_INSTALLED=$(npm list -g pi-subagents --depth=0 2>/dev/null | grep pi-subagents | grep -oP '\d+\.\d+\.\d+' || echo "?")
PI_LATEST=$(npm view pi-subagents version 2>/dev/null || echo "UNKNOWN")
check "pi-subagents" "$PI_INSTALLED" "$PI_LATEST" "npm update -g pi-subagents"

# 3. Claude Code
CC_INSTALLED=$(claude --version 2>/dev/null | head -1 | grep -oP '[\d.]+' || echo "?")
check "claude-code" "$CC_INSTALLED" "(check manually)" "npm update -g @anthropic-ai/claude-code"

# Summary
NEW_COUNT=$(grep -c "^  NEW" "$LOG" || true)
if [ "$NEW_COUNT" -gt 0 ]; then
    echo ""
    echo "⚠ $NEW_COUNT update(s) available — review $LOG"
    # Desktop notification if available
    if command -v notify-send &>/dev/null; then
        notify-send "Upstream updates" "$NEW_COUNT tool update(s) available" --urgency=low 2>/dev/null || true
    fi
fi

echo "=== done ==="
