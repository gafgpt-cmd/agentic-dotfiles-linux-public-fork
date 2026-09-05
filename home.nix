{ config, pkgs, lib, codexPrivacy, nixgl, pi-pkg, profile, wezterm-pkg, ... }:

let
  dotfiles = "${config.home.homeDirectory}/.dotfiles";
  privacyVariables = {
    DO_NOT_TRACK = "1";
    DISABLE_TELEMETRY = "1";
    DISABLE_ERROR_REPORTING = "1";
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
    OTEL_SDK_DISABLED = "true";
    OTEL_TRACES_EXPORTER = "none";
    OTEL_METRICS_EXPORTER = "none";
    OTEL_LOGS_EXPORTER = "none";
    PI_TELEMETRY = "0";
    PI_SKIP_VERSION_CHECK = "1";
    GNHF_TELEMETRY = "0";
    NO_MISTAKES_TELEMETRY = "0";
    LAVISH_AXI_TELEMETRY = "0";
    HOMEBREW_NO_ANALYTICS = "1";
    NEXT_TELEMETRY_DISABLED = "1";
    ASTRO_TELEMETRY_DISABLED = "1";
    TURBO_TELEMETRY_DISABLED = "1";
    DOTNET_CLI_TELEMETRY_OPTOUT = "1";
    POWERSHELL_TELEMETRY_OPTOUT = "1";
    CHECKPOINT_DISABLE = "1";
    SCARF_NO_ANALYTICS = "true";
    HF_HUB_DISABLE_TELEMETRY = "1";
    DVC_NO_ANALYTICS = "true";
  };
  displayVariables = {
    AGENTIC_DISPLAY_SERVER = profile.displayServer;
  };
  weztermWrapped = config.lib.nixGL.wrap wezterm-pkg;
  # batch: one control surface for long-running background work (built on pueue).
  # Relocatable core; atlas-specific bindings stay with the atlas project.
  batch = pkgs.stdenv.mkDerivation {
    name = "batch-control";
    src = ./home/batch;
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      mkdir -p $out/libexec/batch $out/bin
      cp $src/batch.sh $src/batch-exec.sh $src/board.py $out/libexec/batch/
      chmod +x $out/libexec/batch/batch.sh $out/libexec/batch/batch-exec.sh
      ln -s $out/libexec/batch/batch.sh $out/bin/batch
    '';
  };
  # Taken from the environment so no username or home path is ever committed.
  # Needs --impure (rebuild.sh and bootstrap.sh pass it); pure eval sees "".
  fromEnv = name:
    let v = builtins.getEnv name; in
    if v == "" then
      throw "Environment variable ${name} is empty. Run ./rebuild.sh, or pass --impure to home-manager/nix."
    else v;
in

{
  imports =
    lib.optionals (profile.desktop == "gnome") [ ./gnome.nix ]
    ++ lib.optionals (profile.desktop == "xfce") [ ./xfce.nix ]
    ++ lib.optionals (profile.desktop == "kde") [ ./kde.nix ];

  assertions = [
    {
      assertion = builtins.elem profile.desktop [ "none" "gnome" "xfce" "kde" ];
      message = "profile.desktop must be one of: none, gnome, xfce, kde";
    }
    {
      assertion = builtins.elem profile.displayServer [ "auto" "x11" "wayland" ];
      message = "profile.displayServer must be one of: auto, x11, wayland";
    }
  ];

  home.username = fromEnv "USER";
  home.homeDirectory = fromEnv "HOME";
  home.stateVersion = "24.11";
  home.packages = with pkgs; [
    # cli i use constantly
    ripgrep   # fast search
    fd        # fast find
    fzf       # fuzzy finder
    jq        # json on the command line
    git
    gh
    lazygit
    tmux
    mise
    uv
    shellcheck
    shfmt
    pueue     # background job supervisor (engine behind `batch`)
    batch     # `batch` control surface for long-running background work
    typescript
    mosh      # ssh that survives roaming/sleep; also provides mosh-server for inbound
    neovim
    pi-pkg
    # apps that were Homebrew casks/brews on macOS
    weztermWrapped
    # herdr: native self-updating release in ~/.local/bin, not built from source here
    # the font everything renders in
    nerd-fonts.hack
  ];
  targets.genericLinux.nixGL.packages = nixgl.packages;
  fonts.fontconfig.enable = true;
  home.sessionVariables = privacyVariables // displayVariables
    // lib.optionalAttrs profile.manageShell { EDITOR = "nvim"; };
  # Graphical apps inherit privacy controls without requiring ownership of a custom shell.
  systemd.user.sessionVariables = privacyVariables // displayVariables;

  # The former weekly check-upstream-deps timer lived here. It is superseded by
  # doctor-franken's unified Monday maintenance plus kun-port-sync, which
  # disabled it on every install while each home-manager switch re-enabled it.
  # One schedule owns updates now; do not add a second timer here.

  # Codex analytics defaults to on, so environment-wide OTEL controls are not enough.
  home.activation.disableCodexTelemetry = config.lib.dag.entryAfter [ "writeBoundary" ] ''
    run ${codexPrivacy}/bin/ensure-codex-privacy
  '';

  # Put the profiles on PATH ourselves instead of trusting the Nix installer's
  # shell hook. Determinate writes that hook to /etc/zshrc, which Debian's zsh
  # never reads (it uses /etc/zsh/zshrc), so an interactive shell ends up with a
  # bare /usr/bin PATH and none of the packages above.
  home.sessionPath = [
    "$HOME/.local/bin"           # prefer the current native Claude release
    "$HOME/.nix-profile/bin"          # everything in home.packages
    "/nix/var/nix/profiles/default/bin" # nix itself
  ];

  # Standalone home-manager doesn't ship its own CLI unless asked; rebuild.sh needs it.
  programs.home-manager.enable = true;

  programs.zsh = {
    enable = profile.manageShell;
    autosuggestion.enable = true;      # ghost text from history
    syntaxHighlighting.enable = true;  # commands turn green when valid
    initContent = ''
      bindkey '^f' autosuggest-accept
    '';
    shellAliases = {
      ".." = "cd ..";
      add = "git add .";
      push = "git push";
      pull = "git pull";
      m = "git switch main";
      cc = "claude";
      co = "codex";
      # herdr refuses to update from inside one of its own sessions; run the
      # updater detached through the user service manager, then hand the live
      # sessions over to the new binary.
      herdr-update = "systemd-run --user --wait --pipe --collect --quiet -- $HOME/.local/bin/herdr update --handoff";
    };
  };

  programs.starship = {
    enable = profile.manageShell;
    settings = {
      add_newline = false;
      format = "$directory$git_branch$git_status$cmd_duration$line_break$character";
      character = {
        success_symbol = "[❯](purple)";
        error_symbol = "[❯](red)";
      };
      cmd_duration.format = "[$duration]($style) ";
    };
  };

  # The distro launcher requests a generic terminal, whose WezTerm adapter
  # passes `-e` as the child program. Bypass it with the wrapped binary.
  home.file.".local/share/applications/nvim.desktop" = lib.mkIf profile.manageWezterm {
    text = ''
      [Desktop Entry]
      Type=Application
      Name=Neovim
      GenericName=Text Editor
      Comment=Edit text files
      TryExec=${weztermWrapped}/bin/wezterm
      Exec=${weztermWrapped}/bin/wezterm start -- ${pkgs.neovim}/bin/nvim %F
      Icon=nvim
      Terminal=false
      Categories=Utility;TextEditor;
      StartupNotify=false
      MimeType=text/english;text/plain;text/x-makefile;text/x-c++hdr;text/x-c++src;text/x-chdr;text/x-csrc;text/x-java;text/x-moc;text/x-pascal;text/x-tcl;text/x-tex;application/x-shellscript;text/x-c;text/x-c++;
    '';
  };

  # Edit-in-place: the real file stays in my repo, ~/.config just points at it.
  home.file.".config/wezterm" = lib.mkIf profile.manageWezterm {
    source = config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/wezterm";
  };
  home.file.".config/nvim" = lib.mkIf profile.manageNvim {
    source = config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/nvim";
  };
  home.file.".config/herdr" = lib.mkIf profile.manageHerdr {
    source = config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/herdr";
  };
  home.file.".claude/settings.json" = lib.mkIf profile.manageClaudeSettings {
    source = config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.claude/settings.json";
  };
  home.file.".claude/statusline-command.sh" = lib.mkIf profile.manageClaudeSettings {
    source = config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.claude/statusline-command.sh";
  };
  # General agent skill — always deployed, independent of the Claude-settings
  # toggle, so activating it never touches settings.json / statusline.
  home.file.".claude/skills/git-orient".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.claude/skills/git-orient";

  # Pi credentials and runtime state stay local. Only authored resources are linked.
  home.file.".pi/agent/themes" = lib.mkIf profile.managePiResources {
    source = config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.pi/agent/themes";
  };
  home.file.".pi/agent/extensions" = lib.mkIf profile.managePiResources {
    source = config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.pi/agent/extensions";
  };
  home.file.".pi/agent/models.json" = lib.mkIf profile.managePiResources {
    source = config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.pi/agent/models.json";
  };
  home.file.".pi/agent/settings.json" = lib.mkIf profile.managePiResources {
    source = config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.pi/agent/settings.json";
  };

  home.file.".claude/CLAUDE.md" = lib.mkIf profile.manageAgentInstructions {
    source = config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/AGENTS.md";
  };
  home.file.".codex/AGENTS.md" = lib.mkIf profile.manageAgentInstructions {
    source = config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/AGENTS.md";
  };
  home.file.".config/opencode/AGENTS.md" = lib.mkIf profile.manageAgentInstructions {
    source = config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/AGENTS.md";
  };
}
