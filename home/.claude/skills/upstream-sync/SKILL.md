---
name: upstream-sync
description: "Check the upstreams this Linux port tracks, triage which of their new commits are worth porting, and nudge when they move ahead. Use when asked to sync/update from upstream, check if the fork is behind, port an upstream change, or set up upstream monitoring for this repo."
---

# upstream-sync

This repo is a **Linux + standalone home-manager PORT** of `kunchenguid/dotfiles` (macOS / nix-darwin). NOT a clean fork. History was rewritten (email scrub), so its commit SHAs differ from upstream even where content is identical.

Upstream git remotes:
- `kun` = github.com/kunchenguid/dotfiles — **PRIMARY**, active. Track this.
- `upstream` = github.com/GuillaumeTaffin/dotfiles-linux — **SECONDARY**, owner unsure it's wanted. Do NOT track by default; only when explicitly asked (`--include-taffin`).

## Rule zero
NEVER `git merge` or `git rebase` an upstream branch into this repo. It is a port: a raw merge drags in macOS-only code (nix-darwin, homebrew, `configuration.nix`, `macos_*`) and reintroduces things `AGENTS.md` forbids. Integration is **selective: adapt one change at a time, by hand, through the normal branch + commit + PR flow.**

## The count lies
`git log HEAD..kun/main` counts by SHA. Because this is a port with rewritten history, MOST "new" commits are already here in spirit. Triage by CONTENT, never by count or subject alone — read the actual diff AND the fork's current file before deciding.

## Check status / nudge
`bash <skill-dir>/check-upstream.sh` (`--notify` = desktop notification, `--include-taffin` = also secondary). Read-only fetch + report. Cron wiring at the bottom.

## Triage each new upstream commit → one bucket
- **macOS-only** → skip. nix-darwin, homebrew, `configuration.nix`, `macos_*`, cask lists.
- **already ported** → skip. Read the fork's current file; if present in spirit, done. Most land here.
- **conflicts with a deliberate decision** → skip + flag. Check the `AGENTS.md` "do NOT silently revert" list (no `configuration.nix`; nvim is the pinned Kickstart tree, not the rose-pine stub; `@AGENTS.md` import not a `CLAUDE.md` symlink; manageWezterm adopted; etc.).
- **portable + missing** → PORT it (below).

## Porting safely (do not break the repo)
1. Branch first. Add/adapt by hand — never cherry-pick a raw upstream commit (it carries macOS assumptions and old SHAs).
2. Re-read `AGENTS.md` before touching wezterm, nvim, `home.nix`, `flake.nix`, `profile.nix`, or Pi resources.
3. Build before commit: `nix build --no-link --impure .#homeConfigurations.default.activationPackage`, then the repo tests in `tests/`.
4. One theme per commit, message = what + why. Through the commit/PR flow. Never force-push, never blind-merge.
5. Show the human the diff before it lands.

## Nudge (weekly cron + desktop notification)
```
(crontab -l 2>/dev/null; echo '0 9 * * 1 bash ~/.dotfiles/home/.claude/skills/upstream-sync/check-upstream.sh --notify >> ~/.cache/upstream-sync.log 2>&1') | crontab -
```
Log: `~/.cache/upstream-sync.log`. Stop it by removing that line via `crontab -e`.
