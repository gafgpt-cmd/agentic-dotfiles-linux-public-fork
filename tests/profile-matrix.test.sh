#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(dotfiles_test_tmproot profile-matrix)
cleanup() { dotfiles_test_cleanup "$TMP_ROOT"; }
trap cleanup EXIT

matrix=$(dotfiles_nix eval --json --impure "path:$ROOT#lib.profileMatrix")

# The desktop-less profile is the yardstick for "owns nothing of this desktop".
neutral_files=$(dotfiles_hm_targets "$(dotfiles_hm_profile)")
neutral_activation=$(dotfiles_nix eval --json --impure \
  "path:$ROOT#homeConfigurations.default.config.home.activation" --apply builtins.attrNames | jq -S .)

# Positive control: the same needles do trip once a profile adopts those paths.
adopted_files=$(dotfiles_hm_targets "$(dotfiles_hm_profile '
  desktop = "gnome"; manageShell = true; manageNvim = true; manageWezterm = true;
  manageHerdr = true; managePiResources = true; manageClaudeSettings = true;
  manageAgentInstructions = true;
')")
for target in "${DOTFILES_ADOPTABLE_PATHS[@]}"; do
  dotfiles_owns "$adopted_files" "$target" \
    || fail "adopting everything no longer owns ~/$target, so the per-profile guard cannot fail"
done

expected_profiles='["gnome-wayland","gnome-x11","kde-wayland","kde-x11","xfce-wayland","xfce-x11"]'
[ "$(jq -c 'keys' <<<"$matrix")" = "$expected_profiles" ] \
  || fail "flake does not expose the complete desktop/session matrix"

for desktop in gnome xfce kde; do
  for session in x11 wayland; do
    profile="$desktop-$session"
    managed=$(jq -c --arg p "$profile" '.[$p].managedFiles' <<<"$matrix" | dotfiles_normalize_targets)
    [ "$(jq -r --arg p "$profile" '.[$p].desktop' <<<"$matrix")" = "$desktop" ] \
      || fail "$profile exports the wrong desktop"
    [ "$(jq -r --arg p "$profile" '.[$p].displayServer' <<<"$matrix")" = "$session" ] \
      || fail "$profile exports the wrong display server"
    [ "$(jq -r --arg p "$profile" '.[$p].graphicalDisplayServer' <<<"$matrix")" = "$session" ] \
      || fail "$profile does not export its display server to graphical applications"

    dconf_count=$(jq --arg p "$profile" '.[$p].dconfKeys | length' <<<"$matrix")
    xfconf_count=$(jq --arg p "$profile" '.[$p].xfconfKeys | length' <<<"$matrix")
    gtk_enabled=$(jq -r --arg p "$profile" '.[$p].gtkEnabled' <<<"$matrix")

    case "$desktop" in
      gnome)
        if ! { [ "$dconf_count" -gt 0 ] && [ "$xfconf_count" -eq 0 ]; }; then
          fail "$profile does not isolate GNOME settings"
        fi
        ;;
      xfce)
        if ! { [ "$dconf_count" -eq 0 ] && [ "$xfconf_count" -gt 0 ] && [ "$gtk_enabled" = false ]; }; then
          fail "$profile does not isolate XFCE settings"
        fi
        if [ "$session" = wayland ]; then
          xfconf_keys=$(jq -r --arg p "$profile" '.[$p].xfconfKeys[]' <<<"$matrix")
          assert_not_contains "$xfconf_keys" xfwm4 "XFCE Wayland profile configures the X11-only window manager"
          assert_not_contains "$xfconf_keys" xsettings "XFCE Wayland profile configures XSettings"
        fi
        ;;
      kde)
        if ! { [ "$dconf_count" -eq 0 ] && [ "$xfconf_count" -eq 0 ] && [ "$gtk_enabled" = false ]; }; then
          fail "$profile does not preserve existing KDE settings"
        fi
        # KConfig stays user-owned: no plasma-manager module, and the footprint
        # is byte-for-byte the desktop-less one, so nothing new writes ~/.config.
        [ "$(jq -r --arg p "$profile" '.[$p].plasmaManaged' <<<"$matrix")" = false ] \
          || fail "$profile hands KDE settings to plasma-manager"
        [ "$managed" = "$neutral_files" ] \
          || fail "$profile manages files the desktop-less profile does not"
        [ "$(jq -S --arg p "$profile" '.[$p].activationEntries' <<<"$matrix")" = "$neutral_activation" ] \
          || fail "$profile adds an activation step that could write KConfig"
        ;;
    esac

    for target in "${DOTFILES_PROTECTED_PATHS[@]}"; do
      if dotfiles_owns "$managed" "$target"; then
        fail "$profile unexpectedly adopts ~/$target"
      fi
    done
  done
done

# The profiles above only publish AGENTIC_DISPLAY_SERVER. Close the loop by
# loading the real WezTerm config against a stub of the wezterm module and
# reading back the backend it picked.
find_lua() {
  local candidate store
  for candidate in lua lua5.4 lua5.3 lua5.2 luajit; do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  store=$(dotfiles_nix build --no-link --print-out-paths --impure --expr \
    "(builtins.getFlake \"path:$ROOT\").inputs.nixpkgs.legacyPackages.\${builtins.currentSystem}.lua")
  printf '%s/bin/lua\n' "$store"
}

lua_bin=$(find_lua)
test_home="$TMP_ROOT/home"
mkdir -p "$test_home/.nix-profile/bin"
printf '#!/bin/sh\n' >"$test_home/.nix-profile/bin/zsh"
chmod +x "$test_home/.nix-profile/bin/zsh"
bad_shell="$test_home/non-executable/zsh"
mkdir -p "$(dirname "$bad_shell")"
printf '#!/bin/sh\n' >"$bad_shell"
harness="$TMP_ROOT/wezterm-harness.lua"
cat >"$harness" <<'LUA'
local handlers = {}
package.preload["wezterm"] = function()
  return {
    action = {
      EmitEvent = function() return {} end,
      SpawnCommandInNewTab = function(command) return command end,
      SpawnCommandInNewWindow = function() return {} end,
    },
    config_builder = function() return {} end,
    default_hyperlink_rules = function() return {} end,
    executable_dir = "/usr/bin",
    font_with_fallback = function(families) return families end,
    GLOBAL = {},
    gui = { enumerate_gpus = function() return {} end },
    home_dir = os.getenv("HOME"),
    on = function(event, callback) handlers[event] = callback end,
    run_child_process = function(args)
      local path = args[#args]
      local ok, _, code = os.execute(string.format('test -f %q && test -x %q', path, path))
      return ok == true or ok == 0 or code == 0, "", ""
    end,
    target_triple = os.getenv("WEZTERM_TARGET") or "x86_64-unknown-linux-gnu",
    truncate_right = function(text) return text end,
  }
end
local config = assert(loadfile(os.getenv("WEZTERM_CONFIG")))()
if os.getenv("WEZTERM_PROBE") == "shell" then
  io.write(config.default_prog and config.default_prog[1] or "default", "\n")
else
  io.write(tostring(config.enable_wayland), "\n")
end
LUA

wezterm_backend() { # wezterm_backend [display-server]
  local config="$ROOT/home/.config/wezterm/wezterm.lua"
  if [ "$#" -eq 0 ]; then
    env -u AGENTIC_DISPLAY_SERVER HOME="$test_home" WEZTERM_CONFIG="$config" "$lua_bin" "$harness"
  else
    env HOME="$test_home" AGENTIC_DISPLAY_SERVER="$1" WEZTERM_CONFIG="$config" "$lua_bin" "$harness"
  fi
}

wezterm_shell=$(env -u SHELL HOME="$test_home" WEZTERM_PROBE=shell \
  WEZTERM_CONFIG="$ROOT/home/.config/wezterm/wezterm.lua" "$lua_bin" "$harness")
case "$wezterm_shell" in
  */zsh) : ;;
  *) fail "WezTerm does not select an available zsh when SHELL is unset" ;;
esac
wezterm_shell=$(env SHELL="$bad_shell" HOME="$test_home" WEZTERM_PROBE=shell \
  WEZTERM_CONFIG="$ROOT/home/.config/wezterm/wezterm.lua" "$lua_bin" "$harness")
[ "$wezterm_shell" != "$bad_shell" ] \
  || fail "WezTerm selects a non-executable SHELL"

[ "$(wezterm_backend wayland)" = true ] || fail "WezTerm does not enable native Wayland on a Wayland profile"
[ "$(wezterm_backend x11)" = false ] || fail "WezTerm does not force X11 on an X11 profile"
[ "$(wezterm_backend auto)" = nil ] || fail "the auto profile overrides WezTerm's own backend detection"
[ "$(wezterm_backend)" = nil ] || fail "WezTerm picks a backend when no profile is exported"

pass "GNOME and XFCE isolate settings; KDE preserves them; all evaluate on X11 and Wayland"
