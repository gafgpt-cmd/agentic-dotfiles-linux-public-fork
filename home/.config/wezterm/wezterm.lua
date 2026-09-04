local wezterm = require("wezterm")
local config = wezterm.config_builder()

-- ---------------------------------------------------------------------------
-- Platform
--
-- This file is shared verbatim between Linux and Windows. Everything visual --
-- palette, tab bar, keys, opacity -- is identical on both; only the things that
-- genuinely cannot be (shell, GPU backend, terminfo, path syntax) branch below.
-- ---------------------------------------------------------------------------
local triple = wezterm.target_triple
local is_windows = triple:find("windows") ~= nil
local is_mac = triple:find("darwin") ~= nil
local is_linux = triple:find("linux") ~= nil
local is_unix = not is_windows

local display_server = os.getenv("AGENTIC_DISPLAY_SERVER")
if display_server == "wayland" then
  config.enable_wayland = true
elseif display_server == "x11" then
  config.enable_wayland = false
end

-- Rose Pine Moon palette, kept here so the tab bar and selection can reuse it.
local rp = {
  base = "#232136",
  surface = "#2a273f",
  overlay = "#393552",
  muted = "#6e6a86",
  subtle = "#908caa",
  text = "#e0def4",
  love = "#eb6f92",
  gold = "#f6c177",
  rose = "#ea9a97",
  pine = "#3e8fb0",
  foam = "#9ccfd8",
  iris = "#c4a7e7",
}

config.color_scheme = "rose-pine-moon"
-- Nerd Font first on both platforms; the trailing entries are the fonts each OS
-- can be relied on to already have, so a fresh machine still renders sanely.
local font_fallback = {
  "Hack Nerd Font",
  "FiraCode Nerd Font",
  "CaskaydiaCove Nerd Font",
  "Symbols Nerd Font Mono",
}
for _, f in ipairs(
  is_windows and { "Cascadia Code", "Consolas", "Segoe UI Emoji" }
    or { "DejaVu Sans Mono", "Noto Color Emoji" }
) do
  table.insert(font_fallback, f)
end
config.font = wezterm.font_with_fallback(font_fallback)
config.font_size = 12.0

-- The scheme's own selection_bg is #44415a, which is nearly the background at
-- this opacity. Use the iris accent instead so selections read at a glance.
config.colors = {
  selection_bg = rp.iris,
  selection_fg = rp.base,
}

-- Keep remote curses applications usable on hosts without WezTerm's terminfo.
-- Windows has no terminfo database, so leave the default there.
if is_unix then
  config.term = "xterm-256color"
end

-- Rendering. WebGpu is smoother than the default OpenGL front end, but
-- enumerate_gpus() also returns software adapters (llvmpipe on Mesa, WARP on
-- Windows). Pick a real GPU explicitly rather than risk rendering on the CPU.
config.front_end = "WebGpu"
config.webgpu_power_preference = "HighPerformance"
-- XFCE 4.16's tasklist implements "Launch New Instance" by executing the
-- window's /proc/<pid>/exe. For nixGL-wrapped apps that resolves to the raw Nix
-- binary, without the wrapper's driver environment (nixGLIntel exports
-- LIBGL_DRIVERS_PATH among others). This build has no usable GL in that state:
-- WebGpu panics inside wgpu's EGL init while creating the first window, and the
-- OpenGL front end fails to create the window at all. It only hands off to the
-- running GUI when DISPLAY matches byte for byte (":0" and ":0.0" do not), so
-- relaunch through the wrapper and quit before any window exists. Limited to
-- the first evaluation in a process so a config reload can never exit a running
-- GUI; the marker variable bounds a misdetection to a single hop.
local is_unwrapped_nix_helper = is_linux
  and wezterm.executable_dir:find("/nix/store/", 1, true) == 1
  and os.getenv("LIBGL_DRIVERS_PATH") == nil
local first_evaluation = not wezterm.GLOBAL.config_evaluated
wezterm.GLOBAL.config_evaluated = true
if
  is_unwrapped_nix_helper
  and first_evaluation
  and wezterm.gui
  and os.getenv("WEZTERM_NIXGL_RELAUNCHED") == nil
then
  wezterm.background_child_process({
    "/usr/bin/env",
    "WEZTERM_NIXGL_RELAUNCHED=1",
    wezterm.home_dir .. "/.nix-profile/bin/wezterm",
    "start",
  })
  os.exit(0)
end
if not is_unwrapped_nix_helper then
  local ok, gpus = pcall(wezterm.gui.enumerate_gpus)
  if ok and gpus then
    local priority
    if is_windows then
      priority = { "Dx12", "Vulkan" }
    elseif is_mac then
      priority = { "Metal" }
    else
      priority = { "Vulkan", "Gl" }
    end
    for _, backend in ipairs(priority) do
      for _, gpu in ipairs(gpus) do
        if gpu.backend == backend and gpu.device_type ~= "Cpu" then
          config.webgpu_preferred_adapter = gpu
          break
        end
      end
      if config.webgpu_preferred_adapter then
        break
      end
    end
  end
end

-- Laptop battery: WezTerm's default easing runs the render loop continuously
-- just to animate the cursor blink. Constant easing at 1fps stops that.
config.animation_fps = 1
config.cursor_blink_ease_in = "Constant"
config.cursor_blink_ease_out = "Constant"

-- No beeping. Flash the cursor instead.
config.audible_bell = "Disabled"
config.notification_handling = "NeverShow"
config.visual_bell = {
  fade_in_function = "EaseIn",
  fade_in_duration_ms = 75,
  fade_out_function = "EaseOut",
  fade_out_duration_ms = 150,
  target = "CursorColor",
}

config.initial_cols = 110
config.initial_rows = 32
config.window_decorations = "RESIZE"
config.window_background_opacity = 0.92
config.window_padding = { left = 8, right = 8, top = 8, bottom = 8 }
config.adjust_window_size_when_changing_font_size = false
config.scrollback_lines = 100000

-- ---------------------------------------------------------------------------
-- Shell
-- ---------------------------------------------------------------------------
if is_unix then
  -- ibus-daemon runs here with --xim, and use_ime defaults to true on X11. XIM
  -- grabs Ctrl+Space, which is the zsh-autosuggestions accept key bound in
  -- shrcfiles/zshrc -- the keystroke never reaches the shell. Turning the IME
  -- off hands key events straight to WezTerm. Dead keys and compose sequences
  -- (needed for Catalan accents) still work: without an IME, WezTerm falls back
  -- to xkbcommon's own compose handling rather than losing them.
  -- Re-enable this only if you start needing a CJK input method here.
  config.use_ime = false

  local zsh_candidates = {
    "/usr/bin/zsh",
    "/bin/zsh",
    "/usr/local/bin/zsh",
    wezterm.home_dir .. "/.nix-profile/bin/zsh",
  }
  local shell = os.getenv("SHELL")
  if shell and shell ~= "" then
    table.insert(zsh_candidates, 1, shell)
  end
  local zsh
  for _, candidate in ipairs(zsh_candidates) do
    if candidate:match("/zsh$") then
      local executable = wezterm.run_child_process({
        "/bin/sh",
        "-c",
        'test -f "$1" && test -x "$1"',
        "wezterm",
        candidate,
      })
      if executable then
        zsh = candidate
        break
      end
    end
  end

  config.launch_menu = {
    {
      label = "Agent workspace (tmux)",
      args = { "tmux", "new-session", "-A", "-s", "main" },
    },
    { label = "Bash", args = { "bash", "-l" } },
  }
  if zsh then
    config.default_prog = { zsh, "-l" }
    config.set_environment_variables = { SHELL = zsh }
    table.insert(config.launch_menu, 2, { label = "Zsh", args = { zsh, "-l" } })
  end
else
  -- Deliberately no default_prog on Windows: pointing it at pwsh.exe hard-fails
  -- if PowerShell 7 is not installed, whereas the built-in default always
  -- resolves. The launch menu offers the better shells instead.
  config.launch_menu = {
    { label = "PowerShell 7", args = { "pwsh.exe", "-NoLogo" } },
    { label = "Windows PowerShell", args = { "powershell.exe", "-NoLogo" } },
    { label = "WSL", args = { "wsl.exe", "--cd", "~" } },
    { label = "Command Prompt", args = { "cmd.exe" } },
  }
end

-- ---------------------------------------------------------------------------
-- Tab bar
--
-- On Linux tmux owns a status bar pinned to the *top* (status-position top) and
-- reports session / window / pane state there. So WezTerm's bar goes to the
-- bottom and reports only what tmux cannot see: which OS window, which WezTerm
-- tab, and which workspace. Retro (non-fancy) mode renders it in the terminal
-- font so it lines up visually with the tmux bar above. Kept identical on
-- Windows for muscle memory, where WezTerm's tabs are the only multiplexer.
-- ---------------------------------------------------------------------------
config.use_fancy_tab_bar = false
config.tab_bar_at_bottom = true
config.hide_tab_bar_if_only_one_tab = false
config.tab_max_width = 32
config.show_new_tab_button_in_tab_bar = false
config.show_tab_index_in_tab_bar = true
config.tab_and_split_indices_are_zero_based = false

config.colors.tab_bar = {
  background = rp.base,
  active_tab = { bg_color = rp.iris, fg_color = rp.base, intensity = "Bold" },
  inactive_tab = { bg_color = rp.base, fg_color = rp.muted },
  inactive_tab_hover = { bg_color = rp.overlay, fg_color = rp.text },
  new_tab = { bg_color = rp.base, fg_color = rp.muted },
  new_tab_hover = { bg_color = rp.overlay, fg_color = rp.text },
}

local function tab_label(tab)
  -- An explicit rename always wins.
  if tab.tab_title and #tab.tab_title > 0 then
    return tab.tab_title
  end
  -- tmux sets the terminal title (see set-titles in ~/.tmux.conf), so inside a
  -- session this is "main:1 nvim" rather than a useless "tmux".
  local title = tab.active_pane.title or ""
  if #title > 0 and title ~= "wezterm" then
    return title
  end
  local proc = tab.active_pane.foreground_process_name or ""
  proc = proc:gsub(".*[/\\]", "") -- handles both path separators
  proc = proc:gsub("%.exe$", "")
  if #proc > 0 then
    return proc
  end
  return "shell"
end

wezterm.on("format-tab-title", function(tab, _, _, _, _, max_width)
  local index = tostring(tab.tab_index + 1)
  local label = tab_label(tab)

  -- Mark background tabs that produced output since you last looked at them.
  local unseen = ""
  if not tab.is_active then
    for _, pane in ipairs(tab.panes) do
      if pane.has_unseen_output then
        unseen = "•"
        break
      end
    end
  end

  local budget = max_width - #index - #unseen - 4
  if budget < 1 then
    budget = 1
  end
  if #label > budget then
    label = wezterm.truncate_right(label, budget - 1) .. "…"
  end

  local fg = tab.is_active and rp.base or rp.gold
  return {
    { Text = " " .. index .. " " },
    { Text = label },
    { Foreground = { Color = fg } },
    { Text = " " .. unseen .. " " },
  }
end)

wezterm.on("update-right-status", function(window, _)
  local cells = {}

  -- Only surfaced when a key table is active, so modal state is never invisible.
  local key_table = window:active_key_table()
  if key_table then
    table.insert(cells, { Foreground = { Color = rp.love } })
    table.insert(cells, { Text = " " .. key_table .. " " })
  end
  if window:leader_is_active() then
    table.insert(cells, { Foreground = { Color = rp.gold } })
    table.insert(cells, { Text = " LEADER " })
  end

  table.insert(cells, { Foreground = { Color = rp.subtle } })
  table.insert(cells, { Text = " " .. window:active_workspace() .. " " })

  window:set_right_status(wezterm.format(cells))
end)

-- ---------------------------------------------------------------------------
-- Hyperlinks
--
-- Agents, compilers, test runners and ripgrep all emit "path/to/file:42".
-- Start from the built-in rules (URLs, email) and add path rules so that output
-- becomes clickable instead of something to retype. delta already emits proper
-- OSC 8 links; these rules cover tools that do not.
-- ---------------------------------------------------------------------------
config.hyperlink_rules = wezterm.default_hyperlink_rules()

-- NOTE: these use [==[ ]==] rather than [[ ]]. The Unix character class ends
-- in "\]]", and a plain long-bracket string would terminate on that "]]",
-- producing a syntax error that wezterm's show-keys silently swallows while
-- falling back to the default config.
local path_body
local path_format
if is_windows then
  -- Drive-letter paths, e.g. C:\Users\User\src\main.rs
  path_body = [==[([A-Za-z]:\\[^\s:*?"<>|]+)]==]
  path_format = "wezterm-file:///$1"
else
  path_body = [==[(/(?:home|root|opt|usr|var|etc|tmp|srv|mnt|media)/[^\s:'"()\[\]]+)]==]
  path_format = "file://$1"
end

-- Most specific first: path with a line number.
table.insert(config.hyperlink_rules, {
  regex = path_body .. [==[:(\d+)]==],
  format = path_format .. "#$2",
})
table.insert(config.hyperlink_rules, {
  regex = path_body,
  format = path_format,
})

-- Open numbered code references in Neovim. Other file links keep their normal
-- desktop handler.
wezterm.on("open-uri", function(window, pane, uri)
  local url = wezterm.url.parse(uri)
  local is_windows_file = url.scheme == "wezterm-file"
  if is_windows_file then
    local path = url.path:gsub("^/", ""):gsub("\\", "/"):gsub("%%5[cC]", "/")
    local fragment = url.fragment and "#" .. url.fragment or ""
    url = wezterm.url.parse("file:///" .. path .. fragment)
  end
  if url.scheme == "file" and url.fragment and url.fragment:match("^%d+$") then
    window:perform_action(
      wezterm.action.SpawnCommandInNewTab({ args = { "nvim", "+" .. url.fragment, url.file_path } }),
      pane
    )
    return false -- suppress default handling
  end
  if is_windows_file and url.scheme == "file" then
    wezterm.open_with(url.file_path)
    return false
  end
end)

-- ---------------------------------------------------------------------------
-- Keys
-- ---------------------------------------------------------------------------
config.keys = {
  -- Reclaim the two bottom rows when you want a clean screenshot or full-height
  -- pager; the bar comes straight back on the next press.
  {
    -- phys: form is required here. Plain key="B"/"b" with CTRL|SHIFT gets
    -- normalized down to CTRL+B, which would swallow page-up in vim/less.
    key = "phys:B",
    mods = "CTRL|SHIFT",
    action = wezterm.action.EmitEvent("toggle-tab-bar"),
  },
}

if is_unix then
  table.insert(config.keys, {
    key = "Enter",
    mods = "CTRL|SHIFT",
    action = wezterm.action.SpawnCommandInNewWindow({
      args = { "tmux", "new-session", "-A", "-s", "main" },
    }),
  })
end

wezterm.on("toggle-tab-bar", function(window)
  local overrides = window:get_config_overrides() or {}
  if overrides.enable_tab_bar == false then
    overrides.enable_tab_bar = nil
  else
    overrides.enable_tab_bar = false
  end
  window:set_config_overrides(overrides)
end)

-- ---------------------------------------------------------------------------
-- Focus treatment: dim unfocused windows, but stay readable at a glance.
-- ---------------------------------------------------------------------------
local UNFOCUSED_FOREGROUND_TEXT_HSB = {
  hue = 1.0,
  saturation = 0.7,
  brightness = 0.75,
}
local UNFOCUSED_WINDOW_BACKGROUND_OPACITY = 0.85

local function same_text_hsb(actual, expected)
  if actual == nil or expected == nil then
    return actual == expected
  end
  return actual.hue == expected.hue
    and actual.saturation == expected.saturation
    and actual.brightness == expected.brightness
end

wezterm.on("window-focus-changed", function(window)
  local overrides = window:get_config_overrides() or {}
  local text_hsb, opacity
  if not window:is_focused() then
    text_hsb = UNFOCUSED_FOREGROUND_TEXT_HSB
    opacity = UNFOCUSED_WINDOW_BACKGROUND_OPACITY
  end

  if same_text_hsb(overrides.foreground_text_hsb, text_hsb)
    and overrides.window_background_opacity == opacity
  then
    return
  end

  overrides.foreground_text_hsb = text_hsb
  overrides.window_background_opacity = opacity
  window:set_config_overrides(overrides)
end)

return config
