#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(dotfiles_test_tmproot linux-config)
cleanup() { dotfiles_test_cleanup "$TMP_ROOT"; }
trap cleanup EXIT

command -v nix >/dev/null 2>&1 || fail "these tests need nix on PATH"

hm_eval() { dotfiles_nix eval --json --impure "path:$ROOT#homeConfigurations.default.config.$1" "${@:2}"; }

for script in "$ROOT/bootstrap.sh" "$ROOT/rebuild.sh" "$ROOT/home/.claude/statusline-command.sh"; do
  bash -n "$script" || fail "$(basename "$script") has invalid shell syntax"
done

shellcheck "$ROOT/bootstrap.sh" "$ROOT/rebuild.sh" "$ROOT/home/.claude/statusline-command.sh" \
  || fail "shellcheck failed"

# --- entry points: run them and assert what they actually do ------------------
# Every case below stops the script before it can switch a generation, so no
# live Home Manager configuration is ever activated by this suite.

fake_bin="$TMP_ROOT/bin"
mkdir -p "$fake_bin"
printf '#!/bin/sh\necho Darwin\n' >"$fake_bin/uname"
chmod +x "$fake_bin/uname"

for entry in bootstrap.sh rebuild.sh; do
  darwin_home="$TMP_ROOT/darwin-$entry"
  mkdir -p "$darwin_home"
  out=$(PATH="$fake_bin:$PATH" HOME="$darwin_home" bash "$ROOT/$entry" 2>&1) && status=0 || status=$?
  [ "$status" = 1 ] || fail "$entry does not refuse to run on a non-Linux host"
  assert_contains "$out" 'Linux-only' "$entry does not say why it refused on a non-Linux host"
  assert_contains "$out" 'github.com/kunchenguid/dotfiles' "$entry does not point macOS users at the nix-darwin repo"
  if [ -e "$darwin_home/.dotfiles" ] || [ -L "$darwin_home/.dotfiles" ]; then
    fail "$entry claimed ~/.dotfiles on a non-Linux host"
  fi

  # An existing ~/.dotfiles is somebody else's clone: never repoint it.
  claimed_home="$TMP_ROOT/claimed-$entry"
  mkdir -p "$claimed_home"
  printf 'someone elses clone\n' >"$claimed_home/.dotfiles"
  out=$(HOME="$claimed_home" bash "$ROOT/$entry" 2>&1) && status=0 || status=$?
  [ "$status" = 1 ] || fail "$entry does not refuse to replace an existing ~/.dotfiles"
  assert_contains "$out" 'Refusing to replace existing' "$entry does not explain the refusal"
  assert_not_contains "$out" 'BOOTSTRAP FAILED' "$entry aborted before it could reach the ~/.dotfiles guard"
  [ "$(cat "$claimed_home/.dotfiles")" = 'someone elses clone' ] \
    || fail "$entry overwrote an existing ~/.dotfiles"
done

# Reaching the guard above means bootstrap.sh read profile.nix successfully, so
# it both enabled nix-command and evaluated impurely.

# rebuild.sh hands the switch to home-manager: intercept it instead of running it.
switch_home="$TMP_ROOT/switch-home"
mkdir -p "$switch_home/.nix-profile/bin"
ln -s "$ROOT" "$switch_home/.dotfiles"
cat >"$switch_home/.nix-profile/bin/home-manager" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" >"$HOME/switch-args"
printf '%s\n' "$NIX_CONFIG" >"$HOME/switch-nix-config"
STUB
chmod +x "$switch_home/.nix-profile/bin/home-manager"
HOME="$switch_home" bash "$ROOT/rebuild.sh" || fail "rebuild.sh failed on a healthy ~/.dotfiles pointer"
switch_args=$(cat "$switch_home/switch-args")
for expected in switch -b backup --impure --flake; do
  assert_contains "$switch_args" "$expected" "rebuild.sh does not pass $expected to home-manager"
done
assert_contains "$switch_args" "$ROOT#default" "rebuild.sh switches to another flake output"
assert_contains "$(cat "$switch_home/switch-nix-config")" 'experimental-features = nix-command flakes' \
  "rebuild.sh does not enable flakes for the home-manager child process"

# --- telemetry: assert the evaluated configuration, not the source text -------

session_vars=$(hm_eval home.sessionVariables)
graphical_vars=$(hm_eval systemd.user.sessionVariables)

while IFS='=' read -r key value; do
  [ -n "$key" ] || continue
  jq -e --arg k "$key" --arg v "$value" '.[$k] == $v' >/dev/null <<<"$session_vars" \
    || fail "shell sessions do not get $key=$value"
  jq -e --arg k "$key" --arg v "$value" '.[$k] == $v' >/dev/null <<<"$graphical_vars" \
    || fail "graphical sessions do not get $key=$value"
done <<'VARS'
DO_NOT_TRACK=1
DISABLE_TELEMETRY=1
DISABLE_ERROR_REPORTING=1
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
OTEL_SDK_DISABLED=true
OTEL_TRACES_EXPORTER=none
OTEL_METRICS_EXPORTER=none
OTEL_LOGS_EXPORTER=none
PI_TELEMETRY=0
PI_SKIP_VERSION_CHECK=1
GNHF_TELEMETRY=0
NO_MISTAKES_TELEMETRY=0
LAVISH_AXI_TELEMETRY=0
HOMEBREW_NO_ANALYTICS=1
NEXT_TELEMETRY_DISABLED=1
ASTRO_TELEMETRY_DISABLED=1
TURBO_TELEMETRY_DISABLED=1
DOTNET_CLI_TELEMETRY_OPTOUT=1
POWERSHELL_TELEMETRY_OPTOUT=1
CHECKPOINT_DISABLE=1
SCARF_NO_ANALYTICS=true
HF_HUB_DISABLE_TELEMETRY=1
DVC_NO_ANALYTICS=true
VARS

jq -e '.enableInstallTelemetry == false and .enableAnalytics == false' >/dev/null \
  <"$ROOT/home/.pi/agent/settings.json" || fail "Pi install telemetry or analytics is still on"

# --- Codex privacy: run the real activation entry against temp CODEX_HOMEs ----

jq -e 'index("disableCodexTelemetry")' >/dev/null \
  <<<"$(hm_eval home.activation --apply builtins.attrNames)" \
  || fail "the Codex privacy entry does not run during activation"

codex_privacy=$(dotfiles_nix build --no-link --print-out-paths --impure "path:$ROOT#ensure-codex-privacy")/bin/ensure-codex-privacy
[ -x "$codex_privacy" ] || fail "the Codex privacy activation entry did not build"

codex_toml() { dotfiles_nix eval --json --impure --expr "builtins.fromTOML (builtins.readFile \"$1\")"; }
run_codex_privacy() { # run_codex_privacy <codex-home>
  HOME="$TMP_ROOT/codex" CODEX_HOME="$1" "$codex_privacy"
}
assert_codex_private() { # assert_codex_private <config.toml> <context>
  local parsed
  parsed=$(codex_toml "$1")
  jq -e '
    .analytics.enabled == false
    and .otel.exporter == "none"
    and .otel.trace_exporter == "none"
    and .otel.metrics_exporter == "none"
    and .otel.log_user_prompt == false
  ' >/dev/null <<<"$parsed" || fail "Codex telemetry stays on $2"
}

fresh="$TMP_ROOT/codex/fresh"
mkdir -p "$TMP_ROOT/codex"
run_codex_privacy "$fresh" || fail "the Codex privacy entry failed on a machine that never ran Codex"
assert_codex_private "$fresh/config.toml" "for a fresh Codex home"
[ "$(stat -c %a "$fresh")" = 700 ] || fail "the Codex home is not private"
[ "$(stat -c %a "$fresh/config.toml")" = 600 ] || fail "a new Codex config is not private"

before=$(cat "$fresh/config.toml")
run_codex_privacy "$fresh" || fail "the Codex privacy entry is not re-runnable"
[ "$(cat "$fresh/config.toml")" = "$before" ] || fail "the Codex privacy entry rewrites an already private config"

existing="$TMP_ROOT/codex/existing"
mkdir -p "$existing"
cat >"$existing/config.toml" <<'TOML'
model = "gpt-5"

[analytics]
enabled = true

[otel]
exporter = "otlp"
TOML
chmod 644 "$existing/config.toml"
run_codex_privacy "$existing" || fail "the Codex privacy entry failed on an existing config"
assert_codex_private "$existing/config.toml" "when the user had opted in"
jq -e '.model == "gpt-5"' >/dev/null <<<"$(codex_toml "$existing/config.toml")" \
  || fail "the Codex privacy entry dropped unrelated user settings"
[ "$(stat -c %a "$existing/config.toml")" = 644 ] || fail "the Codex privacy entry changed the config's mode"

linked="$TMP_ROOT/codex/linked"
mkdir -p "$linked"
printf 'model = "gpt-5"\n' >"$TMP_ROOT/codex/user-owned.toml"
ln -s "$TMP_ROOT/codex/user-owned.toml" "$linked/config.toml"
if run_codex_privacy "$linked" 2>/dev/null; then
  fail "the Codex privacy entry followed a symlinked config"
fi
[ "$(cat "$TMP_ROOT/codex/user-owned.toml")" = 'model = "gpt-5"' ] \
  || fail "the Codex privacy entry wrote through a symlink"

if run_codex_privacy relative/codex 2>/dev/null; then
  fail "the Codex privacy entry accepted a relative CODEX_HOME"
fi

# --- baseline ownership: only WezTerm is adopted -------------------------------

safe_profile=$(dotfiles_hm_profile 'manageWezterm = false;')
safe_files=$(dotfiles_hm_targets "$safe_profile")
for target in "${DOTFILES_ADOPTABLE_PATHS[@]}"; do
  if dotfiles_owns "$safe_files" "$target"; then
    fail "the all-off profile unexpectedly adopts ~/$target"
  fi
done
wezterm_profile=$(dotfiles_hm_profile 'manageWezterm = true;')

[ "$(hm_eval programs.zsh.enable)" = false ] || fail "safe profile takes over the shell"
[ "$(hm_eval programs.starship.enable)" = false ] || fail "safe profile takes over the prompt"
[ "$(hm_eval home.sessionVariables --apply 'v: v ? EDITOR')" = false ] \
  || fail "safe profile overrides EDITOR outside a managed shell"
[ "$(hm_eval home.sessionVariables.AGENTIC_DISPLAY_SERVER)" = '"auto"' ] \
  || fail "safe profile forces a display server on the terminal"

jq -e '
  .cc == "claude" and .co == "codex"
  and ([.[] | select(test("dangerously-skip-permissions|--full-auto"))] | length) == 0
' >/dev/null <<<"$(hm_eval programs.zsh.shellAliases)" || fail "an unattended agent alias is back"

jq -e 'index("pi-coding-agent") == null' >/dev/null \
  <<<"$(hm_eval home.packages --apply 'ps: map (p: p.pname or p.name) ps')" \
  || fail "the host Pi package is shadowed by Home Manager"

# Standalone Home Manager packages cannot see a non-NixOS host's graphics
# stack directly. The installed WezTerm must therefore differ from raw nixpkgs.
raw_wezterm=$(dotfiles_nix eval --raw --impure \
  "path:$ROOT#homeConfigurations.default.pkgs.wezterm.outPath")
managed_wezterm=$(dotfiles_nix eval --raw --impure \
  "path:$ROOT#homeConfigurations.default.config.home.packages" --apply '
    ps: let
      matches = builtins.filter (p: (p.pname or p.name) == "wezterm") ps;
    in if builtins.length matches == 1
       then (builtins.head matches).outPath
       else throw "expected exactly one WezTerm package"
  ')
[ "$managed_wezterm" != "$raw_wezterm" ] \
  || fail "WezTerm is not GPU-wrapped for a non-NixOS host"

nvim_desktop=$(dotfiles_nix eval --raw --impure --expr \
  "($wezterm_profile).config.home.file.\".local/share/applications/nvim.desktop\".text") \
  || fail "the Neovim desktop launcher is not defined"
managed_nvim=$(dotfiles_nix eval --raw --impure \
  "path:$ROOT#homeConfigurations.default.pkgs.neovim.outPath")
desktop_file="$TMP_ROOT/nvim.desktop"
printf '%s' "$nvim_desktop" >"$desktop_file"
python3 - "$desktop_file" "$managed_wezterm/bin/wezterm" "$managed_nvim/bin/nvim" <<'PY' \
  || fail "the Neovim desktop launcher does not invoke wrapped WezTerm directly"
import configparser
import shlex
import sys

parser = configparser.RawConfigParser(interpolation=None, strict=True)
parser.optionxform = str
with open(sys.argv[1], encoding="utf-8") as desktop:
    parser.read_file(desktop)
entry = parser["Desktop Entry"]
assert entry.getboolean("Terminal") is False
assert shlex.split(entry["Exec"]) == [
    sys.argv[2], "start", "--", sys.argv[3], "%F"
]
PY

jq -e . "$ROOT/home/.claude/settings.json" "$ROOT/home/.pi/agent/models.json" \
  "$ROOT/home/.pi/agent/settings.json" "$ROOT/home/.pi/agent/themes/rose-pine-moon.json" >/dev/null \
  || fail "managed JSON is invalid"

managed_files=$(hm_eval home.file --apply 'fs: map (f: f.target) (builtins.attrValues fs)' \
  | dotfiles_normalize_targets)
dotfiles_owns "$managed_files" ".config/wezterm" \
  || fail "the baseline profile no longer owns the canonical WezTerm config"
dotfiles_owns "$managed_files" ".local/share/applications/nvim.desktop" \
  || fail "WezTerm adoption no longer owns the Neovim desktop launcher"
adopted_files=$(dotfiles_hm_targets "$(dotfiles_hm_profile '
  manageShell = true; manageNvim = true; manageWezterm = true; manageHerdr = true;
  managePiResources = true; manageClaudeSettings = true; manageAgentInstructions = true;
')")

for target in "${DOTFILES_ADOPTABLE_PATHS[@]}"; do
  dotfiles_owns "$adopted_files" "$target" \
    || fail "adopting everything no longer owns ~/$target, so the guard below cannot fail"
done
for target in "${DOTFILES_PROTECTED_PATHS[@]}"; do
  if dotfiles_owns "$managed_files" "$target"; then
    fail "safe profile unexpectedly owns ~/$target"
  fi
done
[ "$(hm_eval xfconf.settings)" = '{}' ] || fail "safe profile changes XFCE settings"
[ "$(hm_eval dconf.settings)" = '{}' ] || fail "safe profile changes GNOME settings"

pass "entry points guard themselves, telemetry is off, Codex stays private, and baseline ownership stays narrow"
