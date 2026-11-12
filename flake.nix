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
          # bs compiles two Zig releases, so the toolchains are those
          # releases' official builds, checked by sha256 as .agents/setup
          # checks them, not nixpkgs' zig. Keep the two in step. 0.17.1
          # builds bs; 0.16.0, the release before, is only found through
          # BS_ZIG_0_16 (docs/slop/zig-0.16.md).
          version = "0.17.1";
          oldVersion = "0.16.0";
          # The org's pull-through cache in front of the Zig community mirrors.
          # The sha256 below still checks the bytes, so the mirror is not a
          # trust anchor.
          mirror = "https://zig.baskingspot.dev";
          host =
            {
              x86_64-linux = {
                name = "x86_64-linux";
                sha256 = "3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a";
                oldSha256 = "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00";
              };
              aarch64-linux = {
                name = "aarch64-linux";
                sha256 = "a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795";
                oldSha256 = "ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17";
              };
              aarch64-darwin = {
                name = "aarch64-macos";
                sha256 = "75f1bc7a1e9852f17ec9a0c1895f767c4ec56d46bc8a834920eece1d0359dd8d";
                oldSha256 = "b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489";
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
            installPhase = "cp -r . $out";
          };

          # The release before's binary, for BS_ZIG_0_16, and its source
          # tree, for upstream-0.16/.
          zigOld = pkgs.stdenvNoCC.mkDerivation {
            pname = "zig";
            version = oldVersion;
            src = pkgs.fetchurl {
              url = "${mirror}/zig-${host.name}-${oldVersion}.tar.xz";
              sha256 = host.oldSha256;
            };
            dontConfigure = true;
            dontBuild = true;
            dontFixup = true;
            installPhase = "cp -r . $out";
          };
          zigOldSrc = pkgs.stdenvNoCC.mkDerivation {
            pname = "zig-src";
            version = oldVersion;
            src = pkgs.fetchurl {
              url = "${mirror}/zig-${oldVersion}.tar.xz";
              sha256 = "43186959edc87d5c7a1be7b7d2a25efffd22ce5807c7af99067f86f99641bfdf";
            };
            dontConfigure = true;
            dontBuild = true;
            dontFixup = true;
            installPhase = "cp -r . $out";
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
            # Runs aarch64-linux test binaries here, as .agents/setup's
            # qemu-user-static does in orbs. A native aarch64 host needs no
            # emulator.
            ++ pkgs.lib.optionals (pkgs.stdenv.hostPlatform.isLinux && pkgs.stdenv.hostPlatform.isx86_64) [
              pkgs.qemu-user
            ];
            env.ZIG_SRC = zigSrc;
            env.ZIG_SRC_0_16 = zigOldSrc;
            env.BS_ZIG_0_16 = "${zigOld}/zig";
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
