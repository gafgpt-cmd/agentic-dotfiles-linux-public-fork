#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(dotfiles_test_tmproot wezterm-raw-helper)
cleanup() { dotfiles_test_cleanup "$TMP_ROOT"; }
trap cleanup EXIT

config="$ROOT/home/.config/wezterm/wezterm.lua"
raw_bin=${WEZTERM_RAW_BIN:-}

if [ -z "$raw_bin" ]; then
  raw_out=$(dotfiles_nix build --no-link --print-out-paths --impure "path:$ROOT#wezterm-raw") \
    || fail "the raw WezTerm flake package did not build"
  raw_bin="$raw_out/bin/wezterm"
fi

[ -x "$raw_bin" ] || fail "the raw WezTerm binary is not executable"

if ! stderr=$(env \
  -u LIBGL_DRIVERS_PATH \
  -u LD_LIBRARY_PATH \
  RUST_BACKTRACE=1 \
  WEZTERM_NIXGL_RELAUNCHED=1 \
  "$raw_bin" --config-file "$config" show-keys 2>&1 >/dev/null); then
  printf '%s\n' "$stderr" >&2
  fail "raw Nix helper failed while loading the WezTerm config"
fi

panic_marker="called \`Option::unwrap()\` on a \`None\` value"
egl_marker='wgpu-hal-25.0.2/src/gles/egl.rs'
case "$stderr" in
  *"$panic_marker"* | *"$egl_marker"*)
    fail "raw Nix helper panicked in EGL while loading the WezTerm config"
    ;;
esac

uri_config="$TMP_ROOT/wezterm-uri.lua"
uri_proof="$TMP_ROOT/uri-proof"
cat >"$uri_config" <<'LUA'
local real_wezterm = require("wezterm")
local handlers = {}
local action = setmetatable({
  SpawnCommandInNewTab = function(command) return command end,
}, { __index = real_wezterm.action })
local wezterm = setmetatable({
  action = action,
  on = function(event, callback) handlers[event] = callback end,
}, { __index = real_wezterm })
package.loaded["wezterm"] = wezterm
local config = assert(loadfile(os.getenv("WEZTERM_MAIN_CONFIG")))()
local captured
local result = handlers["open-uri"]({
  perform_action = function(_, value) captured = value end,
}, {}, [[wezterm-file:///C:\Users\User\My%20File.lua#42]])
assert(result == false)
assert(captured.args[1] == "nvim")
assert(captured.args[2] == "+42")
assert(captured.args[3] == "/C:/Users/User/My File.lua")
local proof = assert(io.open(os.getenv("WEZTERM_URI_PROOF"), "w"))
proof:write(table.concat(captured.args, "\t"), "\n")
proof:close()
return config
LUA

env \
  -u LIBGL_DRIVERS_PATH \
  -u LD_LIBRARY_PATH \
  WEZTERM_NIXGL_RELAUNCHED=1 \
  WEZTERM_MAIN_CONFIG="$config" \
  WEZTERM_URI_PROOF="$uri_proof" \
  "$raw_bin" --config-file "$uri_config" show-keys >/dev/null 2>&1
[ -f "$uri_proof" ] || fail "the real WezTerm URL parser did not handle the Windows file hyperlink"
[ "$(<"$uri_proof")" = $'nvim\t+42\t/C:/Users/User/My File.lua' ] \
  || fail "the Windows file hyperlink did not preserve its decoded path and line"

pass "raw WezTerm config avoids EGL panic and parses file hyperlinks"
