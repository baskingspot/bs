{
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

      # bs runs on x86_64 Linux and Apple Silicon macOS.
      systems = [
        "x86_64-linux"
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
          # bs compiles exactly one Zig release, so the toolchain is that
          # release's official build, checked by sha256 as .agents/setup
          # checks it, not nixpkgs' zig. Keep the two in step.
          version = "0.17.1";
          # The org's pull-through cache in front of the Zig community mirrors.
          # The sha256 below still checks the bytes, so the mirror is not a
          # trust anchor.
          mirror = "https://zig.baskingspot.dev";
          host =
            {
              x86_64-linux = {
                name = "x86_64-linux";
                sha256 = "3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a";
              };
              aarch64-darwin = {
                name = "aarch64-macos";
                sha256 = "75f1bc7a1e9852f17ec9a0c1895f767c4ec56d46bc8a834920eece1d0359dd8d";
              };
            }
            .${system};

          # The binary needs its lib/ beside it: bs finds its std there
          # (`zig env`), and the build finds upstream zig by it.
          zig = pkgs.stdenvNoCC.mkDerivation {
            pname = "zig";
            inherit version;
            src = pkgs.fetchurl {
              url = "${mirror}/zig-${host.name}-${version}.tar.xz";
              inherit (host) sha256;
            };
            dontConfigure = true;
            dontBuild = true;
            dontFixup = true;
            installPhase = ''
              mkdir -p $out/bin
              cp -r . $out/zig-${version}
              ln -s $out/zig-${version}/zig $out/bin/zig
            '';
          };

          # The release's source tree, for upstream/: test/behavior for the
          # conformance measure, and upstream's compiler source to read.
          zigSrc = pkgs.stdenvNoCC.mkDerivation {
            pname = "zig-src";
            inherit version;
            src = pkgs.fetchurl {
              url = "${mirror}/zig-${version}.tar.xz";
              sha256 = "1e89bf06610b769a8c77676c6c8d54b093a0db60f4891f2f91014829012f0e24";
            };
            dontConfigure = true;
            dontBuild = true;
            dontFixup = true;
            # Upstream's code, compiled by the conformance measure with
            # lint off: a .bs.zon at the root and beside each build.zig,
            # where bs's search for a config stops (as .agents/setup).
            installPhase = ''
              cp -r . $out
              find $out -name build.zig -exec sh -c \
                'echo ".{ .lint = false }" > "$(dirname "$1")/.bs.zon"' _ {} \;
              echo '.{ .lint = false }' > $out/.bs.zon
            '';
          };
        in
        {
          packages.zig = zig;

          devShells.default = pkgs.mkShell {
            inputsFrom = [
              config.devShells.base
              config.devShells.shell
            ];
            packages = [
              zig
              inputs.mattware.packages.${system}.ziglint
              pkgs.python3
              pkgs.ruff
            ]
            # Runs aarch64-linux test binaries on x86_64-linux, as
            # .agents/setup's qemu-user-static does in orbs.
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.qemu-user ];
            env.ZIG_SRC = zigSrc;
            shellHook = ''
              if [ ! -e upstream ] || [ -L upstream ]; then
                ln -sfn "$ZIG_SRC" upstream
              fi
            '';
          };
        };
    };
}
