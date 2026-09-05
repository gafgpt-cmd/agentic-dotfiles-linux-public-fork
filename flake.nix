{
  description = "dotfiles (Linux)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # Nix GUI packages need the host's graphics drivers outside NixOS.
    nixgl.url = "github:nix-community/nixGL";
    nixgl.inputs.nixpkgs.follows = "nixpkgs";

    # The stable 26.05 snapshot still has Pi 0.75. Calm is proved against 0.84.
    nixpkgs-pi.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Keep WezTerm current without moving the whole user environment to unstable.
    nixpkgs-wezterm.url = "github:NixOS/nixpkgs/nixos-unstable";

    # herdr isn't in nixpkgs; upstream ships its own flake, Linux included.
    herdr.url = "github:herdrdev/herdr";
  };

  outputs = inputs@{ self, nixpkgs, nixpkgs-pi, nixpkgs-wezterm, home-manager, nixgl, herdr }:
    let
      # Impure on purpose: the same clone must work on any machine, any user,
      # any CPU arch, with nothing machine-specific committed here. The scripts
      # pass --impure; without it currentSystem (and $USER/$HOME in home.nix)
      # are unavailable and evaluation fails with a clear error.
      system = builtins.currentSystem;
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true; # claude-code
      };
      pi-pkg = nixpkgs-pi.legacyPackages.${system}.pi-coding-agent;
      wezterm-pkg = nixpkgs-wezterm.legacyPackages.${system}.wezterm;
      profile = import ./profile.nix;
      profileMatrix = {
        gnome-x11 = profile // { desktop = "gnome"; displayServer = "x11"; };
        gnome-wayland = profile // { desktop = "gnome"; displayServer = "wayland"; };
        xfce-x11 = profile // { desktop = "xfce"; displayServer = "x11"; };
        xfce-wayland = profile // { desktop = "xfce"; displayServer = "wayland"; };
        kde-x11 = profile // { desktop = "kde"; displayServer = "x11"; };
        kde-wayland = profile // { desktop = "kde"; displayServer = "wayland"; };
      };
      codexPrivacy = pkgs.writeShellApplication {
        name = "ensure-codex-privacy";
        runtimeInputs = [ (pkgs.python3.withPackages (ps: [ ps.tomlkit ])) ];
        text = ''
          exec python ${./scripts/ensure-codex-privacy.py} "$@"
        '';
      };
      mkHome = selectedProfile: home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = {
          herdr-pkg = herdr.packages.${system}.default;
          profile = selectedProfile;
          inherit codexPrivacy nixgl pi-pkg wezterm-pkg;
        };
        modules = [ ./home.nix ];
      };
      matrixConfigurations = builtins.mapAttrs (_: mkHome) profileMatrix;
      homeConfigurations = { default = mkHome profile; } // matrixConfigurations;
    in
    {
      inherit homeConfigurations;

      lib.profileMatrix = builtins.mapAttrs (name: configuration:
        let cfg = configuration.config; in {
          desktop = profileMatrix.${name}.desktop;
          displayServer = cfg.home.sessionVariables.AGENTIC_DISPLAY_SERVER;
          graphicalDisplayServer = cfg.systemd.user.sessionVariables.AGENTIC_DISPLAY_SERVER;
          dconfKeys = builtins.attrNames cfg.dconf.settings;
          xfconfKeys = builtins.attrNames cfg.xfconf.settings;
          gtkEnabled = cfg.gtk.enable;
          managedFiles = map (file: file.target) (builtins.filter (file: file.enable) (builtins.attrValues cfg.home.file));
          activationEntries = builtins.attrNames cfg.home.activation;
          plasmaManaged = cfg.programs ? plasma;
        }
      ) matrixConfigurations;

      checks.${system} = builtins.mapAttrs (_: configuration: configuration.activationPackage) homeConfigurations;

      packages.${system} = {
        ensure-codex-privacy = codexPrivacy;
        pi = pi-pkg;
        wezterm-raw = wezterm-pkg;
      };
    };
}
