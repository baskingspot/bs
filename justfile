# bs: a fast Debug-mode compiler for Zig 0.17. `just --list` shows the recipes.
# AGENTS.md holds the working conventions.

[private]
default:
    @just --list

[doc("Build bs into zig-out/bin/bs. Time it with -Doptimize=ReleaseFast")]
[group("build")]
build *ARGS:
    zig build {{ ARGS }}

[doc("A ReleaseFast bs for TARGET (such as x86_64-linux-musl, aarch64-linux-musl, or aarch64-macos), cross-compiled and installed to DIR/bin. The release workflow ships it")]
[group("build")]
release-build TARGET DIR:
    zig build install -Doptimize=ReleaseFast -Dtarget={{ TARGET }} --prefix {{ DIR }}

[doc("Unit tests, run tests, and the end-to-end checks in build.zig")]
[group("test")]
test *ARGS:
    zig build test --summary failures {{ ARGS }}

[doc("The conformance measure: upstream's test/behavior compiled by bs (tools/conformance/run.py)")]
[group("test")]
conformance *ARGS:
    tools/conformance/run.py {{ ARGS }}

[doc("Order checks: behavior built four ways on one thread, std built with the comptime evaluator off, eager, and off; each checked node by node against the build before (BS_CACHE_VERIFY=full) and required to give the same binary. Pass --bs <path> to skip building bs")]
[group("test")]
sched-check *ARGS:
    BS_CACHE_CHECK=1 tools/conformance/run.py --default-runner --edit-verify --sched-check {{ ARGS }}
    BS_CACHE_CHECK=1 tools/conformance/run.py --std --sched-check {{ ARGS }}

[doc("Lint Zig, Python, shell, Nix, Markdown, the workflows, and this justfile: zig fmt, ruff, shellcheck, nix fmt, oxfmt, actionlint, zizmor, and just --fmt")]
[group("lint")]
lint:
    zig fmt --check src build.zig build.zig.zon tools bench
    ruff check
    ruff format --check
    shellcheck .agents/setup tools/*.sh test/*/*.sh
    nix fmt -- --ci
    oxfmt --check README.md AGENTS.md CHANGELOG.md .github
    actionlint
    zizmor .
    just --fmt --check

[doc("ziglint with the rules in .ziglint.zon. CI shows it without blocking until its findings are worked down")]
[group("lint")]
ziglint:
    ziglint

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src build.zig build.zig.zon tools bench
    ruff format
    nix fmt
    oxfmt README.md AGENTS.md CHANGELOG.md .github
    just --fmt

[doc("What CI blocks on: the tests and lint")]
[group("ci")]
ci: test lint
