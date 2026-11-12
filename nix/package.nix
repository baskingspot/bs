# bs itself, for `nix run github:baskingspot/bs` and the Cachix cache.
#
# ReleaseFast and stripped, as the release binaries are: a Debug bs is about
# 10x slower, and nothing here is built to be debugged.
#
# The version comes from build.zig.zon, which is what `bs --version` prints
# and what release-prep.py rewrites. If that line ever stops matching, this
# evaluation fails instead of shipping a stale version.
{
  lib,
  stdenvNoCC,
  makeWrapper,
  # The pinned upstream releases, from nix/toolchain.nix.
  zig,
  zigOld,
}:
let
  version = lib.head (
    builtins.match ''[ ]*\.version = "([^"]+)".*'' (
      lib.findFirst (line: lib.hasInfix ".version = " line) "" (
        lib.splitString "\n" (builtins.readFile ../build.zig.zon)
      )
    )
  );
  # The whole tree: build.zig's configure step opens test/ and tools/ while
  # it declares its steps, whether or not this build runs them, so trimming
  # the source makes the configure step panic.
  src = ../.;
in
stdenvNoCC.mkDerivation {
  pname = "bs";
  inherit version src;
  nativeBuildInputs = [
    zig
    makeWrapper
  ];
  dontConfigure = true;
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-global
    zig build install --prefix $out -Doptimize=ReleaseFast -Dstrip \
      --cache-dir $TMPDIR/zig-local
    runHook postInstall
  '';
  # bs compiles Zig 0.17.1's std with the zig beside it, and hands C and C++
  # to that zig's `cc`, so the binary is useless without the release it was
  # built against. Wrapped, `nix run` works on a machine with no zig.
  postFixup = ''
    wrapProgram $out/bin/bs \
      --prefix PATH : ${lib.makeBinPath [ zig ]} \
      --set BS_ZIG_0_16 ${zigOld}/zig
  '';
  meta = {
    description = "Fast Debug-mode compiler for Zig 0.17 and 0.16";
    homepage = "https://baskingspot.dev";
    mainProgram = "bs";
  };
}
