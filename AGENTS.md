# Project notes for agents

Deliberate decisions in this repo - do NOT silently revert them:

- This is a Linux-only port of a macOS nix-darwin repo. Do not reintroduce nix-darwin, nix-homebrew, or `configuration.nix`. Desktop and display-server selection live in `profile.nix`; supported desktop modules are GNOME, XFCE, KDE, and none. Every desktop builds for X11 and Wayland. The macOS-to-Linux mapping is tabled at the end of README.md.
- KDE compatibility owns no KConfig files or keys. Never add broad global-theme application or a non-atomic KDE config writer.
- Standalone home-manager is a deliberate choice over NixOS: the target machines run their own distro (Debian 13/GNOME today) and only the user environment is managed here. Anything needing root or a system service is out of scope.
- GPU applications from nixpkgs need `nixGL` on these non-NixOS hosts. WezTerm and the generated `nvim.desktop` deliberately share the wrapped package; do not restore `Terminal=true`, which routes Neovim through distro-specific terminal adapters. Keep the shared WezTerm config on hardware-selected WebGPU: forcing Linux-wide OpenGL makes the distro WezTerm sluggish, so fix Nix graphics access in the wrapper instead. This repo owns the live WezTerm config: `home/.config/wezterm/wezterm.lua` is the source of truth (shared verbatim with the Windows box) and `manageWezterm` is on, so home-manager symlinks the directory live via `mkOutOfStoreSymlink`.
- `herdr` is not in nixpkgs. It comes from its own upstream flake, pinned by tag in `flake.nix`. Bump the tag, do not vendor it.
- `bootstrap.sh` step 4 uses the distro's zsh, not the Nix one, on purpose: a broken home-manager generation must never remove the login shell of a remote machine. Do not "simplify" it to `~/.nix-profile/bin/zsh`.
- The flake is impure on purpose (`builtins.currentSystem`, `$USER`/`$HOME` via `getEnv`): nothing machine-specific may be committed. Do not "purify" it back to a hardcoded username or system; every nix/home-manager invocation must pass `--impure` (the scripts do).
- New packages go in `home.packages` in `home.nix`. Unfree ones need no extra work: `allowUnfree` is set on `pkgs` in `flake.nix`.
- Config-adoption switches in `profile.nix` default off except `manageWezterm`, which this repo has adopted (see the WezTerm entry above); the desktop still defaults to none. Never flip another without reviewing the matching live target first.
- Pi resources are selective links. Never manage `~/.pi/agent` as a whole or commit credentials, sessions, caches, or downloaded packages.
- Telemetry is opt-out by invariant: keep every variable in `home.sessionVariables` and the Codex config updater/tests. New managed tools require a telemetry audit before addition.
- `home/.config/nvim` is the full pinned Kickstart configuration, not the former minimal stub. `manageNvim` remains off by default; preserve the lock and run `tests/nvim-config.test.sh` plus `tests/nvim-runtime.test.sh` when changing it.
- Never commit `.no-mistakes/` validation evidence to this public repo. `.no-mistakes/` is gitignored; if a validation pipeline stages evidence into a branch, drop it before merging.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
