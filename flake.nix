{
  # The org's binary cache, so `nix run` fetches bs instead of building it.
  # Nix asks once whether to accept these settings from a flake.
  nixConfig = {
    extra-substituters = [ "https://baskingspot.cachix.org" ];
    extra-trusted-public-keys = [
      "baskingspot.cachix.org-1:4KDZc1xfJdL8VGAOZo1SkOgZlqMNH+thBzux9J66EjU="
    ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.follows = "baskingspot/flake-parts";
    baskingspot = {
      url = "github:baskingspot/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    mattware.follows = "baskingspot/mattware";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = with inputs.baskingspot.flakeModules; [
        base
        shell
      ];

      # bs runs on x86_64 Linux and Apple Silicon macOS, and builds for
      # aarch64 Linux too, so a native aarch64 Linux host gets a shell.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      perSystem =
        {
          pkgs,
          config,
          system,
          ...
        }:
        let
          # The pinned upstream Zig releases: 0.17.1 builds bs, 0.16.0 is the
          # release before, for BS_ZIG_0_16 (nix/toolchain.nix).
          toolchain = import ./nix/toolchain.nix { inherit pkgs system; };
        in
        {
          packages.zig = toolchain.zig;
          packages.default = pkgs.callPackage ./nix/package.nix { inherit (toolchain) zig; };

          devShells.default = pkgs.mkShell {
            inputsFrom = [
              config.devShells.base
              config.devShells.shell
            ];
            packages = [
              toolchain.zig
              inputs.mattware.packages.${system}.ziglint
              pkgs.python3
              pkgs.ruff
            ]
            # Runs aarch64-linux test binaries here, as .agents/setup's
            # qemu-user-static does in orbs. A native aarch64 host needs no
            # emulator.
            ++ pkgs.lib.optionals (pkgs.stdenv.hostPlatform.isLinux && pkgs.stdenv.hostPlatform.isx86_64) [
              pkgs.qemu-user
            ];
            env.ZIG_SRC = toolchain.zigSrc;
            env.ZIG_SRC_0_16 = toolchain.zigOldSrc;
            env.BS_ZIG_0_16 = "${toolchain.zigOld}/zig";
            shellHook = ''
              if [ ! -e upstream ] || [ -L upstream ]; then
                ln -sfn "$ZIG_SRC" upstream
              fi
              if [ ! -e upstream-0.16 ] || [ -L upstream-0.16 ]; then
                ln -sfn "$ZIG_SRC_0_16" upstream-0.16
              fi
            '';
          };
        };
    };
}
