const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // bs compiles the std library of exactly one Zig release. By default it
    // uses the lib directory of the zig that builds bs, which `.agents/setup`
    // pins to 0.17.1.
    const zig_lib_dir = b.option(
        []const u8,
        "zig-lib-dir",
        "Default Zig 0.17.1 lib directory baked into bs (default: next to the building zig)",
    ) orelse defaultZigLibDir(b);

    const options = b.addOptions();
    options.addOption([]const u8, "zig_lib_dir", zig_lib_dir);

    // `-Dsanitize-thread`: a ThreadSanitizer build of bs, for checking the
    // state CodeGen workers share with the Sema thread (see "Parallel
    // function bodies" in docs/slop/architecture.md). Build it with
    // -Doptimize=ReleaseFast, where libc's malloc is the allocator, which
    // ThreadSanitizer intercepts; std's SafeAllocator hands memory between
    // threads in ways it cannot see, and every reuse then looks like a race.
    const sanitize_thread = b.option(bool, "sanitize-thread", "Build bs with ThreadSanitizer (use with -Doptimize=ReleaseFast)") orelse false;
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .link_libc = if (sanitize_thread) true else null,
    });
    exe_mod.addOptions("build_options", options);
    // Upstream's parser and AstGen, vendored (frontend/frontend.zig): a
    // module of their own, outside src/, which ziglint checks as bs's code.
    const frontend: std.Build.Module.Import = .{ .name = "frontend", .module = b.createModule(.{
        .root_source_file = b.path("frontend/frontend.zig"),
        .target = target,
        .optimize = optimize,
    }) };
    exe_mod.addImport(frontend.name, frontend.module);
    // A hash of the frontend's sources, which the ZIR cache's keys include:
    // ZIR one AstGen wrote is not reused by a bs with another.
    const frontend_hash = b.addRunArtifact(b.addExecutable(.{ .name = "frontend_hash", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/frontend_hash.zig"),
        .target = b.graph.host,
    }) }));
    frontend_hash.addDirectoryArg(b.path("frontend"));
    const frontend_hash_zig = frontend_hash.addOutputFileArg("frontend_hash.zig");
    _ = frontend_hash.addDepFileOutputArg("frontend_hash.d");
    frontend.module.addAnonymousImport("frontend_hash", .{ .root_source_file = frontend_hash_zig });
    // The same for the ReleaseFast tools below: a module's own optimize mode
    // decides its unions' layout, and std's runtime_safety follows the
    // root's, so a Debug frontend under a ReleaseFast root fails Ast's
    // size check.
    const frontend_fast: std.Build.Module.Import = .{ .name = "frontend", .module = b.createModule(.{
        .root_source_file = b.path("frontend/frontend.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    }) };
    frontend_fast.module.addAnonymousImport("frontend_hash", .{ .root_source_file = frontend_hash_zig });
    // The autodocs viewer `-femit-docs` writes (src/Docs.zig).
    const docs_wasm = docsWasm(b, zig_lib_dir);
    exe_mod.addAnonymousImport("docs_wasm", .{ .root_source_file = docs_wasm });
    // The build runner's web UI client, which `zig build --fuzz` serves
    // (src/BuildWeb.zig).
    const build_web_wasm = buildWebWasm(b, zig_lib_dir);
    exe_mod.addAnonymousImport("build_web_wasm", .{ .root_source_file = build_web_wasm });
    // Upstream 0.17.1's package fetcher, for `bs build` of Zig 0.16
    // projects (src/Build16.zig).
    const fetch = fetchModule(b, zig_lib_dir);
    exe_mod.addImport("fetch", fetch);

    const exe = b.addExecutable(.{ .name = "bs", .root_module = exe_mod });
    // Comptime evaluation recurses on the native stack: a 1000-deep
    // comptime recursion (the default branch quota) needs more than the
    // usual 8 MiB. The main thread gets what a worker gets (src/main.zig,
    // `thread_stack_size`), not upstream's 46 MiB: it lowers a file
    // whose ZIR is not ready when it first asks for it, and AstGen
    // recurses once per operand of a long `++` chain.
    exe.stack_size = 60 << 20;
    b.installArtifact(exe);

    // The bs the tests run. A Debug build on x86_64 runs a ReleaseSafe bs
    // from zig's own backend instead, as fast to build: the same safety
    // and leak checks, in a third to a half less CPU time per compile (a
    // Debug bs's SafeAllocator takes its memory from page_allocator).
    const test_bs = if (optimize == .debug and target.result.cpu.arch == .x86_64 and !sanitize_thread) test_bs: {
        const mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        });
        for (exe_mod.import_table.keys(), exe_mod.import_table.values()) |name, m| mod.addImport(name, m);
        const t = b.addExecutable(.{ .name = "bs", .root_module = mod, .use_llvm = false });
        t.stack_size = exe.stack_size;
        break :test_bs t;
    } else exe;

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run bs").dependOn(&run_cmd.step);

    // The unit tests' module: bs's, plus inputs upstream zig cross-compiles
    // for the readers' tests, which bs itself does not embed.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .link_libc = if (sanitize_thread) true else null,
    });
    test_mod.addOptions("build_options", options);
    test_mod.addImport(frontend.name, frontend.module);
    test_mod.addAnonymousImport("docs_wasm", .{ .root_source_file = docs_wasm });
    test_mod.addAnonymousImport("build_web_wasm", .{ .root_source_file = build_web_wasm });
    test_mod.addImport("fetch", fetch);
    addMachOInputs(b, test_mod);
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    // After bs, as one of its users (`spreadBsUsers`), so that it does
    // not hold a worker when bs's users start.
    unit_tests.step.dependOn(&test_bs.step);
    takes(b, &unit_tests.step, 7);
    // `test` runs every test. Its parts are steps of their own, which CI
    // runs as parallel jobs (.github/ci.yaml, `just test-steps`).
    const test_step = b.step("test", "Run all of bs's tests (the test-* steps below)");
    const unit_step = b.step("test-unit", "Run bs's unit tests");
    const run_step = b.step("test-run", "Build and run test/run's programs and test/language/zig016.zig");
    const edit_step = b.step("test-edit", "Edit and donor builds: test/run's programs with those headers, test/run's scripts, test/diag's edit builds");
    const cache_step = b.step("test-cache", "Link inputs, objects, lint configs and languages through the cache");
    const link_step = b.step("test-link", "Objects, libraries, C, C++ and libc through bs's linkers");
    const diag_step = b.step("test-diag", "Compile errors: test/diag, test/lint and unsupported languages");
    const test_parts = [_]*std.Build.Step{ unit_step, run_step, edit_step, cache_step, link_step, diag_step };
    for (test_parts) |part| test_step.dependOn(part);
    unit_step.dependOn(&b.addRunArtifact(unit_tests).step);
    const frontend_tests = b.addTest(.{ .root_module = frontend.module });
    unit_step.dependOn(&b.addRunArtifact(frontend_tests).step);
    const upstream_step = b.step("test-upstream", "Run the run tests with upstream zig, the oracle");
    // A global cache holding the ZIR of the std files that every build
    // lowers, which the tests that need an empty global cache start from
    // instead of spending 5 s of CPU each on AstGen.
    const zir = b.addRunArtifact(test_bs);
    zir.setName("bs: global cache with std's ZIR");
    zir.addArgs(&.{ "build-exe", "-fno-emit-bin", "-target", "x86_64-linux" });
    zir.addFileArg(b.path("test/run/corpus.zig"));
    zir.addArg("--global-cache-dir");
    const std_zir = zir.addOutputDirectoryArg2("global", .{});
    addRunTests(b, test_bs, run_step, edit_step, upstream_step, std_zir);
    addObjAndRunTests(b, test_bs, link_step, edit_step, cache_step, std_zir);
    const translate_c = addLinkInputTests(b, test_bs, link_step, cache_step, std_zir);
    if (b.graph.host.result.os.tag == .macos) {
        // On macOS, libc's headers are the SDK's, frameworks included, as
        // upstream's (`xcrun --show-sdk-path`); the lib directory has no
        // frameworks. bs links translate-c itself here, a large program.
        const tc_sdk = b.addRunArtifact(test_bs);
        tc_sdk.setName("bs translate-c takes libc's headers and frameworks from the macOS SDK");
        tc_sdk.addArg("translate-c");
        tc_sdk.addFileArg(b.path("test/link_input/tc_sdk/s.h"));
        tc_sdk.addCheck(.{ .expect_stdout_match = "pub const CFAllocatorRef = ?*const struct___CFAllocator;" });
        takes(b, &tc_sdk.step, 13);
        link_step.dependOn(&tc_sdk.step);
        // The cache and the inputs record: test/obj/macos_cache.sh.
        const rec = b.addSystemCommand(&.{"sh"});
        rec.setName("bs cache and inputs record on aarch64-macos");
        rec.addFileArg(b.path("test/obj/macos_cache.sh"));
        rec.addArtifactArg2(test_bs, .{});
        _ = rec.addOutputDirectoryArg2("work", .{});
        rec.addCheck(.{ .expect_term = .{ .exited = 0 } });
        takes(b, &rec.step, 10);
        cache_step.dependOn(&rec.step);
        // Objects, archives and C sources through the cache:
        // test/link_input/macos_cache.sh.
        const inputs = b.addSystemCommand(&.{"sh"});
        inputs.setName("bs build-exe with link inputs, cached, on aarch64-macos");
        inputs.addFileArg(b.path("test/link_input/macos_cache.sh"));
        inputs.addArtifactArg2(test_bs, .{});
        inputs.addArg(upstreamZig(b));
        inputs.addDirectoryArg2(b.path("test/link_input"), .{});
        _ = inputs.addOutputDirectoryArg2("work", .{});
        inputs.addCheck(.{ .expect_term = .{ .exited = 0 } });
        takes(b, &inputs.step, 30);
        cache_step.dependOn(&inputs.step);
    }
    addDiagTests(b, test_bs, diag_step, edit_step, upstream_step, std_zir);
    // The language a compilation is in (src/language.zig): a version bs
    // does not compile is an error, at the build.zig.zon's field or the
    // flag.
    for ([_]struct { []const []const u8, []const u8 }{
        .{ &.{}, "build.zig.zon:5:28: minimum_zig_version '0.15.2' is not supported: bs compiles Zig 0.16 and 0.17" },
        .{ &.{ "--zig-version", "0.18" }, "--zig-version '0.18': bs compiles Zig 0.16 and 0.17" },
    }) |case| {
        const run = b.addRunArtifact(test_bs);
        run.setName(b.fmt("bs refuses {s}", .{if (case[0].len == 0) "an unsupported minimum_zig_version" else "an unsupported --zig-version"}));
        run.setEnvironmentVariable("BS_ZON_SELECTS", "1");
        run.addArgs(&.{ "build-exe", "-fno-emit-bin" });
        run.addFileArg(b.path("test/language/old/main.zig"));
        run.addArgs(case[0]);
        run.addCheck(.{ .expect_stderr_match = case[1] });
        run.addCheck(.{ .expect_term = .{ .exited = 1 } });
        diag_step.dependOn(&run.step);
    }
    // A Zig 0.16 program means what it means in 0.16: test/language/zig016.sh.
    {
        const z16 = b.addSystemCommand(&.{"sh"});
        z16.setName("bs Zig 0.16 meanings");
        z16.addFileArg(b.path("test/language/zig016.sh"));
        z16.addArtifactArg2(test_bs, .{});
        z16.addFileArg(b.path("test/language/zig016.zig"));
        _ = z16.addOutputDirectoryArg2("work", .{});
        z16.addCheck(.{ .expect_term = .{ .exited = 0 } });
        takes(b, &z16.step, 5);
        run_step.dependOn(&z16.step);
    }
    // Each language's caches are its own: test/language/keys.sh.
    {
        const keys = b.addSystemCommand(&.{"sh"});
        keys.setName("bs language cache keys");
        keys.addFileArg(b.path("test/language/keys.sh"));
        keys.addArtifactArg2(test_bs, .{});
        keys.addFileArg(b.path("bench/workloads/hello/hello.zig"));
        _ = keys.addOutputDirectoryArg2("work", .{});
        keys.addCheck(.{ .expect_term = .{ .exited = 0 } });
        takes(b, &keys.step, 15);
        cache_step.dependOn(&keys.step);
    }
    addLintTests(b, test_bs, diag_step, cache_step, upstream_step, std_zir);
    const build_test_step = addBuildTest(b, test_bs, build_web_wasm, translate_c);
    // The two longest parts in halves, each a CI job of its own.
    const run_halves = halve(b, run_step, &test_bs.step, &zir.step);
    const link_halves = halve(b, link_step, &test_bs.step, &zir.step);
    spreadBsUsers(b, &test_bs.step, &zir.step, &(run_halves ++ link_halves ++ [_]*std.Build.Step{ unit_step, edit_step, cache_step, diag_step, build_test_step }));

    // Always ReleaseFast: a Debug build of bs says nothing about its speed.
    const bench_link = b.addExecutable(.{ .name = "bench-link", .root_module = b.createModule(.{
        .root_source_file = b.path("src/bench_link.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{frontend_fast},
    }) });
    const bench_intern = b.addExecutable(.{ .name = "bench-intern", .root_module = b.createModule(.{
        .root_source_file = b.path("src/bench_intern.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{frontend_fast},
    }) });
    b.step("bench-intern", "Measure InternPool get() throughput on a Sema-like key mix").dependOn(&b.addRunArtifact(bench_intern).step);
    const bench_cache = b.addExecutable(.{ .name = "bench-cache", .root_module = b.createModule(.{
        .root_source_file = b.path("src/bench_cache.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{frontend_fast},
    }) });
    b.step("bench-cache", "Measure cache storage: manifest, pack, relink from the pack, global store").dependOn(&b.addRunArtifact(bench_cache).step);
    const bench_link_run = b.addRunArtifact(bench_link);
    bench_link_run.addPassthruArgs();
    b.step("bench-link", "Measure link throughput on ~100k synthetic atoms (args: elf (default) or macho)").dependOn(&bench_link_run.step);

    // bs itself, ReleaseFast, generating every function of a build 10
    // more times after analysis (`BS_BENCH_CODEGEN`).
    const bench_bs_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_bs_mod.addOptions("build_options", options);
    bench_bs_mod.addImport(frontend_fast.name, frontend_fast.module);
    bench_bs_mod.addAnonymousImport("docs_wasm", .{ .root_source_file = docs_wasm });
    bench_bs_mod.addAnonymousImport("build_web_wasm", .{ .root_source_file = build_web_wasm });
    bench_bs_mod.addImport("fetch", fetch);
    const bench_bs = b.addExecutable(.{ .name = "bs", .root_module = bench_bs_mod });
    bench_bs.stack_size = exe.stack_size;
    const bench_codegen_run = b.addRunArtifact(bench_bs);
    bench_codegen_run.setEnvironmentVariable("BS_BENCH_CODEGEN", "10");
    bench_codegen_run.addArg("build-exe");
    bench_codegen_run.addFileArg(b.path("bench/workloads/hello/hello.zig"));
    bench_codegen_run.addArg("-fno-emit-bin");
    bench_codegen_run.has_side_effects = true;
    b.step("bench-codegen", "Measure the backend per stage, per IR instruction, on the hello workload (others: BS_BENCH_CODEGEN=n bs build-exe ...)").dependOn(&bench_codegen_run.step);

    // C sources on an aarch64-macos host, compiled with upstream's Clang
    // and linked against libSystem, by bs built as for the other tests and
    // by a ReleaseFast bs: only ReleaseFast reused the stack under a slice
    // of C arguments that outlived its function (a482a5f), which crashed
    // every C compile on aarch64-macos.
    if (b.graph.host.result.os.tag == .macos) {
        for ([_]*std.Build.Step.Compile{ exe, bench_bs }, [_][]const u8{ "", " (ReleaseFast bs)" }) |bs, what| {
            const c_exe = b.addRunArtifact(bs);
            c_exe.setName(b.fmt("bs build-exe -lc with a C source on aarch64-macos{s}", .{what}));
            c_exe.addArgs(&.{ "build-exe", "-lc" });
            c_exe.addFileArg(b.path("test/link_input/libc_main.zig"));
            c_exe.addFileArg(b.path("test/link_input/libc.c"));
            c_exe.setEnvironmentVariable("BS_ZIG", upstreamZig(b));
            const c_run = std.Build.Step.Run.create(b, b.fmt("run bs -lc build of a C source on aarch64-macos{s}", .{what}));
            c_run.addFileArg(c_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
            c_run.addCheck(.{ .expect_stdout_exact = "x=21 twice=42 len=3\nbye from atexit\nbye\n" });
            c_run.addCheck(.{ .expect_stderr_exact = "1 123\n" });
            c_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
            link_step.dependOn(&c_run.step);
        }
        // An executable of C only in ReleaseSafe: Clang's function
        // sanitizer puts a prefix before `main` in its section, so the
        // entry point is inside the section's atom.
        const c_exe = b.addRunArtifact(exe);
        c_exe.setName("bs build-exe -OReleaseSafe -lc with only C sources on aarch64-macos");
        c_exe.addArgs(&.{ "build-exe", "-OReleaseSafe", "-lc" });
        c_exe.addFileArg(b.path("test/link_input/cmain.c"));
        c_exe.setEnvironmentVariable("BS_ZIG", upstreamZig(b));
        const c_run = std.Build.Step.Run.create(b, "run bs -OReleaseSafe -lc build of only C sources on aarch64-macos");
        c_run.addFileArg(c_exe.addOutputFileArg2("cmain", .{ .prefix = "-femit-bin=" }));
        c_run.addArg("5");
        c_run.addCheck(.{ .expect_stdout_exact = "argc=2 q=478165905515354922\n" });
        c_run.addCheck(.{ .expect_term = .{ .exited = 7 } });
        link_step.dependOn(&c_run.step);
        // Objective-C sources: one without the runtime, and a class that
        // sends messages through libobjc and Foundation, whose sections
        // the Mach-O linker places for the runtime.
        for ([_][]const u8{ "objc.m", "objc_class.m" }) |src| {
            const objc_exe = b.addRunArtifact(exe);
            objc_exe.setName(b.fmt("bs build-exe -lc with {s} on aarch64-macos", .{src}));
            objc_exe.addArgs(&.{ "build-exe", "-lc", "-lobjc", "-framework", "Foundation" });
            objc_exe.addFileArg(b.path("test/link_input/objc_main.zig"));
            objc_exe.addFileArg(b.path(b.fmt("test/link_input/{s}", .{src})));
            objc_exe.setEnvironmentVariable("BS_ZIG", upstreamZig(b));
            const objc_run = std.Build.Step.Run.create(b, b.fmt("run bs -lc build of {s} on aarch64-macos", .{src}));
            objc_run.addFileArg(objc_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
            objc_run.addCheck(.{ .expect_term = .{ .exited = 3 } });
            link_step.dependOn(&objc_run.step);
        }
    }
}

/// Each `test/run/*.zig` program (other than the shared `rt.zig`) starts
/// with `//!` header lines giving its expected behavior:
///
///   //! exit: <code>            exit status
///   //! stdout: "<zig string>"  exact standard output
///   //! signal: <SIG>           killed by this signal instead
///   //! stderr: "<zig string>"  exact standard error
///   //! stderr-contains: "<zig string>"
///                               standard error contains this (repeatable;
///                               for output with addresses, such as stack
///                               traces)
///   //! rebuild-without: "<zig string>"
///                               bs first builds the program with the
///                               first occurrence of this text after the
///                               headers removed (repeatable: each text;
///                               `rebuild-replace: "<this>" "<earlier>"`
///                               replaces it instead), then as it is,
///                               then without again, then as it is,
///                               without, and as it is, then once more with
///                               nothing changed, all in the same place
///                               reusing its cache, and checks the last
///                               build. The first two edit builds compare
///                               themselves with full builds
///                               (`BS_CACHE_VERIFY`, `BS_CACHE_CHECK`),
///                               whose manifest then replaces theirs; the
///                               next three chain on the edit builds' own
///                               log, and only the last of them compares
///                               itself with a full build.
///   //! rebuild-lib-without: "<lib path>" "<zig string>"
///                               the same edit in a file of bs's lib
///                               directory, of which the builds use a copy
///   //! donor-without: "<zig string>"
///                               bs first builds the program without this
///                               text in another directory, then this one
///                               with an empty local cache and the same
///                               global cache, which replays the first as
///                               a donor; checks that it did, then builds
///                               it in full with the same error codes
///                               (`BS_CACHE_VERIFY=full`), which compares
///                               the nodes, and compares the outputs
///   //! donor-here-without: "<zig string>"
///                               the same, with the donor built at this
///                               program's path, so that the replay loads
///                               the functions in the root file too
///   //! flags: <arguments>      extra arguments for both compilers,
///                               separated by spaces (such as
///                               `-OReleaseSafe`); not with the rebuild
///                               and donor headers. With `-M` modules
///                               (paths from the repository root) they
///                               replace the program's path, which one of
///                               them names
///   //! upstream-stderr: "<zig string>"
///                               what the program writes to stderr when
///                               upstream builds it for x86_64-linux, for
///                               a program that checks something bs does
///                               better than upstream (frame sizes)
///   //! upstream-llvm: true     upstream builds the program with LLVM,
///                               for a program its self-hosted backend
///                               miscompiles or whose container-level
///                               assembly it drops
///   //! targets: <target> ...   the targets the program is for (default
///                               x86_64-linux); with aarch64-macos, an
///                               aarch64-macos host also builds it for
///                               that target and checks it, with its
///                               `rebuild-without` edits as aarch64-linux
///                               does (not lib edits); with aarch64-linux, an
///                               aarch64-linux host, or an x86_64-linux
///                               host with qemu's user-mode emulator
///                               (`qemu-aarch64-static` or `qemu-aarch64`
///                               on PATH), builds it for that target with
///                               bs (`test`) and upstream (`test-upstream`)
///                               and checks both; bs builds it with its
///                               `rebuild-without` edits (not lib edits
///                               or -lc) as an edit build checked against
///                               a full build, then relinks it, which
///                               must give a full build's bytes
///
/// `test` builds each with bs and checks it; `test-upstream` does the same
/// with upstream zig, so every program is checked against the oracle.
/// A run test's `//! flags:` and its source: the path, unless the flags
/// give `-M` modules, whose files become inputs instead.
fn addFlags(b: *std.Build, r: *std.Build.Step.Run, flags: []const []const u8, src_path: []const u8) void {
    var modules = false;
    for (flags) |f| {
        r.addArg(f);
        if (!std.mem.startsWith(u8, f, "-M")) continue;
        modules = true;
        r.addFileInput(b.path(f[std.mem.findScalar(u8, f, '=').? + 1 ..]));
    }
    if (!modules) r.addFileArg(b.path(src_path));
}

/// How this host runs aarch64-linux executables: natively (no prefix),
/// under qemu, or not at all (null). qemu emulates a Cortex-A53, an
/// ARMv8.0 core like the target's generic baseline, so newer instructions
/// (LSE atomics, FEAT_FP16) trap.
fn aarch64LinuxRunner(b: *std.Build) ?[]const []const u8 {
    const host = b.graph.host.result;
    if (host.cpu.arch == .aarch64 and host.os.tag == .linux) return &.{};
    if (host.os.tag != .linux) return null;
    const qemu = b.findProgram(.{ .names = &.{ "qemu-aarch64-static", "qemu-aarch64" } }) orelse return null;
    return b.allocator.dupe([]const u8, &.{ qemu, "-cpu", "cortex-a53" }) catch @panic("OOM");
}

/// `aarch64LinuxRunner` for executables linking glibc: under qemu, with
/// the aarch64 glibc that .agents/setup installs (libc6-arm64-cross) as
/// the emulator's sysroot; null when that is missing too.
fn aarch64LinuxGlibcRunner(b: *std.Build) ?[]const []const u8 {
    const runner = aarch64LinuxRunner(b) orelse return null;
    if (runner.len == 0) return runner;
    const sysroot = "/usr/aarch64-linux-gnu";
    std.Io.Dir.cwd().access(b.graph.io, sysroot ++ "/lib/ld-linux-aarch64.so.1", .{}) catch return null;
    return std.mem.concat(b.allocator, []const u8, &.{ runner, &.{ "-L", sysroot } }) catch @panic("OOM");
}

/// `run_step` takes the programs, and `edit_step` those with rebuild or
/// donor headers.
fn addRunTests(b: *std.Build, bs: *std.Build.Step.Compile, run_step: *std.Build.Step, edit_step: *std.Build.Step, upstream_step: *std.Build.Step, std_zir: std.Build.LazyPath) void {
    const io = b.graph.io;
    const host = b.graph.host.result;
    const host_runs_bs_output = host.cpu.arch == .x86_64 and host.os.tag == .linux;
    const host_runs_macos_output = host.cpu.arch == .aarch64 and host.os.tag == .macos;
    const aarch64_linux_runner = aarch64LinuxRunner(b);
    const aarch64_linux_glibc_runner = aarch64LinuxGlibcRunner(b);
    // The headers are read here, while configuring.
    b.dependOnDirectoryContents(b.path("test/run"));
    var dir = b.root.openDir(io, "test/run", .{ .iterate = true }) catch |err|
        std.debug.panic("unable to open test/run: {t}", .{err});
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch |err| std.debug.panic("unable to list test/run: {t}", .{err})) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig") or std.mem.eql(u8, entry.name, "rt.zig")) continue;
        names.append(b.allocator, b.graph.dupeString(entry.name)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    for (names.items) |file| {
        const name = file[0 .. file.len - ".zig".len];
        const src_path = b.fmt("test/run/{s}", .{file});
        // The directory dependency covers only its entries' names.
        b.dependOnFileContents(b.path(src_path));
        const source = dir.readFileAlloc(io, file, b.allocator, .limited(1 << 20)) catch |err|
            std.debug.panic("unable to read {s}: {t}", .{ src_path, err });
        var expect: struct {
            exit: ?u8 = null,
            signal: ?std.posix.SIG = null,
            stdout: ?[]const u8 = null,
            stderr: ?[]const u8 = null,
            /// `upstream-stderr`: what upstream's build writes instead,
            /// where bs deliberately does better (smaller frames).
            upstream_stderr: ?[]const u8 = null,
            stderr_contains: std.ArrayList([]const u8) = .empty,
            /// Each text, and what the earlier version has instead.
            rebuild_without: std.ArrayList([2][]const u8) = .empty,
            lib_edit: ?struct { path: []const u8, text: []const u8 } = null,
            donor_without: ?[]const u8 = null,
            /// `donor-here`: the donor is built at the same path.
            donor_here: bool = false,
            /// Linked against glibc: `-target x86_64-linux-gnu -lc`.
            libc: bool = false,
            /// `donor-libc`: built with and without `-lc`, in either order,
            /// into one global cache; neither replays the other as a donor.
            donor_libc: bool = false,
            flags: std.ArrayList([]const u8) = .empty,
            /// `upstream-llvm`: upstream builds the program with LLVM, not its
            /// self-hosted backend: for what that miscompiles, and for
            /// container-level assembly, which it drops.
            upstream_llvm: bool = false,
            aarch64_macos: bool = false,
            aarch64_linux: bool = false,
        } = .{};
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "//! ")) break;
            const colon = std.mem.findScalar(u8, line, ':') orelse continue;
            const key = line[4..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " ");
            if (std.mem.eql(u8, key, "exit")) {
                expect.exit = std.fmt.parseInt(u8, value, 10) catch std.debug.panic("{s}: bad exit code", .{src_path});
            } else if (std.mem.eql(u8, key, "signal")) {
                expect.signal = std.meta.stringToEnum(std.posix.SIG, value) orelse std.debug.panic("{s}: bad signal", .{src_path});
            } else if (std.mem.eql(u8, key, "stderr-contains")) {
                const bytes = std.zig.string_literal.parseAlloc(b.allocator, value) catch std.debug.panic("{s}: bad string", .{src_path});
                expect.stderr_contains.append(b.allocator, bytes) catch @panic("OOM");
            } else if (std.mem.eql(u8, key, "libc")) {
                expect.libc = std.mem.eql(u8, value, "true");
            } else if (std.mem.eql(u8, key, "flags")) {
                var flags = std.mem.tokenizeScalar(u8, value, ' ');
                while (flags.next()) |f| expect.flags.append(b.allocator, f) catch @panic("OOM");
            } else if (std.mem.eql(u8, key, "upstream-llvm")) {
                expect.upstream_llvm = std.mem.eql(u8, value, "true");
            } else if (std.mem.eql(u8, key, "donor-libc")) {
                expect.donor_libc = std.mem.eql(u8, value, "true");
            } else if (std.mem.eql(u8, key, "donor-without") or std.mem.eql(u8, key, "donor-here-without")) {
                expect.donor_without = std.zig.string_literal.parseAlloc(b.allocator, value) catch std.debug.panic("{s}: bad string", .{src_path});
                expect.donor_here = key.len != "donor-without".len;
            } else if (std.mem.eql(u8, key, "rebuild-without")) {
                const text = std.zig.string_literal.parseAlloc(b.allocator, value) catch std.debug.panic("{s}: bad string", .{src_path});
                expect.rebuild_without.append(b.allocator, .{ text, "" }) catch @panic("OOM");
            } else if (std.mem.eql(u8, key, "rebuild-replace") or std.mem.eql(u8, key, "rebuild-lib-without")) {
                // Two strings.
                const end = 1 + (std.mem.findPos(u8, value, 1, "\" \"") orelse std.debug.panic("{s}: bad {s}", .{ src_path, key }));
                const first = std.zig.string_literal.parseAlloc(b.allocator, value[0..end]) catch std.debug.panic("{s}: bad string", .{src_path});
                const second = std.zig.string_literal.parseAlloc(b.allocator, std.mem.trim(u8, value[end..], " ")) catch std.debug.panic("{s}: bad string", .{src_path});
                if (key[8] == 'r') {
                    expect.rebuild_without.append(b.allocator, .{ first, second }) catch @panic("OOM");
                } else expect.lib_edit = .{ .path = first, .text = second };
            } else if (std.mem.eql(u8, key, "targets")) {
                var targets = std.mem.tokenizeScalar(u8, value, ' ');
                while (targets.next()) |t| {
                    if (std.mem.eql(u8, t, "aarch64-macos")) {
                        expect.aarch64_macos = true;
                    } else if (std.mem.eql(u8, t, "aarch64-linux")) {
                        expect.aarch64_linux = true;
                    } else if (!std.mem.eql(u8, t, "x86_64-linux")) std.debug.panic("{s}: unknown target '{s}'", .{ src_path, t });
                }
            } else if (std.mem.eql(u8, key, "upstream-stderr")) {
                expect.upstream_stderr = std.zig.string_literal.parseAlloc(b.allocator, value) catch std.debug.panic("{s}: bad string", .{src_path});
            } else if (std.mem.eql(u8, key, "stdout") or std.mem.eql(u8, key, "stderr")) {
                const bytes = std.zig.string_literal.parseAlloc(b.allocator, value) catch std.debug.panic("{s}: bad string", .{src_path});
                if (key[3] == 'o') expect.stdout = bytes else expect.stderr = bytes;
            }
        }
        if (expect.exit == null and expect.signal == null) std.debug.panic("{s}: missing '//! exit:' or '//! signal:' header", .{src_path});
        if (expect.flags.items.len != 0 and (expect.rebuild_without.items.len != 0 or expect.lib_edit != null or expect.donor_without != null or expect.donor_libc))
            std.debug.panic("{s}: '//! flags:' works only without the rebuild and donor headers", .{src_path});
        // `-target native` and `<arch>-native-<abi>` name the host's OS, as
        // upstream resolves them, so these tests need an x86_64-linux host.
        if (!host_runs_bs_output and for (expect.flags.items, 0..) |f, i| {
            if (i > 0 and std.mem.eql(u8, expect.flags.items[i - 1], "-target") and std.mem.find(u8, f, "native") != null) break true;
        } else false) continue;
        const test_step = if (expect.rebuild_without.items.len != 0 or expect.lib_edit != null or expect.donor_without != null or expect.donor_libc) edit_step else run_step;

        for ([_]bool{ false, true }) |upstream| {
            const compile = if (upstream) blk: {
                const r = b.addSystemCommand(&.{ upstreamZig(b), "build-exe" });
                r.addArgs(if (expect.upstream_llvm) &.{"-fllvm"} else &.{ "-fno-llvm", "-fno-lld" });
                if (expect.libc) r.addArgs(&.{ "-target", "x86_64-linux-gnu", "-lc" });
                addFlags(b, r, expect.flags.items, src_path);
                break :blk r;
            } else if (expect.rebuild_without.items.len != 0 or expect.lib_edit != null) blk: {
                // Build the earlier version, then this one at the same path,
                // then the earlier and this one again, each an edit build
                // checked against a full build, then this one with nothing
                // changed (a relink), all from the cache.
                const files = b.addWriteFiles();
                const before = files.add(file, earlierVersion(b, source, expect.rebuild_without.items, src_path));
                // A lib edit: a copy of the lib directory of links, and the
                // edited file's two versions.
                var lib_setup: []const u8 = "";
                var lib_flag: []const u8 = "";
                var lib_before: []const u8 = "";
                var lib_after: []const u8 = "";
                if (expect.lib_edit) |e| {
                    const lib_dir = defaultZigLibDir(b);
                    const lib_src = std.Io.Dir.cwd().readFileAlloc(io, b.pathJoin(&.{ lib_dir, e.path }), b.allocator, .limited(16 << 20)) catch |err|
                        std.debug.panic("{s}: unable to read {s}: {t}", .{ src_path, e.path, err });
                    const at = std.mem.find(u8, lib_src, e.text) orelse std.debug.panic("{s}: rebuild-lib-without text not found", .{src_path});
                    _ = files.add("lib_before", b.fmt("{s}{s}", .{ lib_src[0..at], lib_src[at + e.text.len ..] }));
                    lib_setup = b.fmt("chmod -R u+w \"$4.d/lib\" 2>/dev/null || :; rm -rf \"$4.d/lib\"; cp -rs {s} \"$4.d/lib\"; chmod -R u+w \"$4.d/lib\"; rm \"$4.d/lib/{s}\"\n", .{ lib_dir, e.path });
                    lib_flag = b.fmt(" --zig-lib-dir \"$4.d/lib\"", .{});
                    lib_before = b.fmt("cp \"$(dirname \"$1\")/lib_before\" \"$4.d/lib/{s}\"\n", .{e.path});
                    lib_after = b.fmt("cp {s}/{s} \"$4.d/lib/{s}\"\n", .{ lib_dir, e.path, e.path });
                }
                // Quiet unless a build fails: the checks print to stderr.
                const target = if (expect.libc) "-target x86_64-linux-gnu -lc" else "-target x86_64-linux";
                const bs_cmd = b.fmt("\"$5\" build-exe {s} \"$4.d/{s}\" -femit-bin=\"$4\"{s} 2>\"$4.d/log\" || {{ cat \"$4.d/log\" >&2; exit 1; }}", .{ target, file, lib_flag });
                // With -lc, a relink from the manifest after the output is
                // gone, which rebuilds the dynamic tables from abilists,
                // must give a full build's bytes.
                const relink_check = if (expect.libc) b.fmt(
                    \\
                    \\rm "$4"
                    \\{[bs]s}
                    \\BS_CACHE=off "$5" build-exe {[target]s} "$4.d/{[file]s}" -femit-bin="$4.d/full"
                    \\cmp "$4" "$4.d/full" >&2
                , .{ .bs = bs_cmd, .target = target, .file = file }) else "";
                const r = b.addSystemCommand(&.{
                    "sh", "-c",
                    b.fmt(
                        \\set -e
                        \\mkdir -p "$4.d"
                        \\cp "$3" "$4.d/rt.zig"
                        \\{[setup]s}cp "$1" "$4.d/{[file]s}"
                        \\{[lib_before]s}{[bs]s}
                        \\cp "$2" "$4.d/{[file]s}"
                        \\{[lib_after]s}BS_CACHE_VERIFY=1 BS_CACHE_CHECK=1 {[bs]s}
                        \\cp "$1" "$4.d/{[file]s}"
                        \\{[lib_before]s}BS_CACHE_VERIFY=1 BS_CACHE_CHECK=1 {[bs]s}
                        \\cp "$2" "$4.d/{[file]s}"
                        \\{[lib_after]s}BS_CACHE_CHECK=1 {[bs]s}
                        \\cp "$1" "$4.d/{[file]s}"
                        \\{[lib_before]s}BS_CACHE_CHECK=1 {[bs]s}
                        \\cp "$2" "$4.d/{[file]s}"
                        \\{[lib_after]s}BS_CACHE_VERIFY=1 BS_CACHE_CHECK=1 {[bs]s}
                        \\{[bs]s}{[relink_check]s}
                    , .{ .setup = lib_setup, .file = file, .lib_before = lib_before, .lib_after = lib_after, .bs = bs_cmd, .relink_check = relink_check }),
                    "sh",
                });
                r.addFileArg(before);
                r.addFileArg(b.path(src_path));
                r.addFileArg(b.path("test/run/rt.zig"));
                break :blk r;
            } else if (expect.donor_libc) blk: {
                // Two global caches: static then -lc, and -lc then static.
                // The donor key holds -lc and the glibc version, since
                // CodeGen resolves glibc's names to imports.
                const static = "\"$5\" build-exe -target x86_64-linux";
                const libc = "\"$5\" build-exe -target x86_64-linux-gnu -lc";
                const r = b.addSystemCommand(&.{
                    "sh", "-c",
                    b.fmt(
                        \\set -e
                        \\rm -rf "$4.d"
                        \\mkdir -p "$4.d/a"
                        \\cp "$3" "$4.d/a/rt.zig"
                        \\cp "$1" "$4.d/a/{[file]s}"
                        \\log="$4.d/log"
                        \\fail() {{ cat "$log" >&2; exit 1; }}
                        \\nodonor() {{ if grep -q "replaying donor" "$log"; then echo "a build replayed a donor built with other libc settings" >&2; fail; fi; }}
                        \\mkdir -p "$4.d/g1/bs" "$4.d/g2/bs"; cp -r "$6/bs/zir" "$4.d/g1/bs"; cp -r "$6/bs/zir" "$4.d/g2/bs"
                        \\{[static]s} --global-cache-dir "$4.d/g1" --cache-dir "$4.d/l1" "$4.d/a/{[file]s}" -femit-bin="$4.d/s1" 2>"$4.d/log" || fail
                        \\BS_CACHE_TIMING=1 BS_CACHE_CHECK=1 {[libc]s} --global-cache-dir "$4.d/g1" --cache-dir "$4.d/l2" "$4.d/a/{[file]s}" -femit-bin="$4" 2>"$4.d/log" || fail
                        \\nodonor
                        \\{[libc]s} --global-cache-dir "$4.d/g2" --cache-dir "$4.d/l3" "$4.d/a/{[file]s}" -femit-bin="$4.d/c2" 2>"$4.d/log" || fail
                        \\BS_CACHE_TIMING=1 BS_CACHE_CHECK=1 {[static]s} --global-cache-dir "$4.d/g2" --cache-dir "$4.d/l4" "$4.d/a/{[file]s}" -femit-bin="$4.d/s2" 2>"$4.d/log" || fail
                        \\nodonor
                        \\{[run]s}
                    , .{
                        .file = file,
                        .static = static,
                        .libc = libc,
                        // The static build runs where bs's output does.
                        .run = if (host_runs_bs_output) "\"$4.d/s2\" 2>\"$4.d/log\" || fail" else "",
                    }),
                    "sh",
                });
                r.addFileArg(b.path(src_path));
                r.addFileArg(b.path(src_path));
                r.addFileArg(b.path("test/run/rt.zig"));
                break :blk r;
            } else if (expect.donor_without) |text| blk: {
                const at = std.mem.find(u8, source, text) orelse std.debug.panic("{s}: donor-without text not found", .{src_path});
                const files = b.addWriteFiles();
                const donor = files.add(file, b.fmt("{s}{s}", .{ source[0..at], source[at + text.len ..] }));
                const bs_cmd = b.fmt("\"$5\" build-exe -target x86_64-linux --global-cache-dir \"$4.d/g\"", .{});
                const r = b.addSystemCommand(&.{
                    "sh", "-c",
                    b.fmt(
                        \\set -e
                        \\rm -rf "$4.d"
                        \\mkdir -p "$4.d/a" "$4.d/b"
                        \\cp "$3" "$4.d/a/rt.zig"
                        \\cp "$3" "$4.d/b/rt.zig"
                        \\cp "$1" "$4.d/{[donor_dir]s}/{[file]s}"
                        \\mkdir -p "$4.d/g/bs"; cp -r "$6/bs/zir" "$4.d/g/bs"
                        \\log="$4.d/log"
                        \\fail() {{ cat "$log" >&2; exit 1; }}
                        \\{[bs]s} --cache-dir "$4.d/la" "$4.d/{[donor_dir]s}/{[file]s}" -femit-bin="$4.d/a/out" 2>"$4.d/log" || fail
                        \\cp "$2" "$4.d/b/{[file]s}"
                        \\BS_CACHE_TIMING=1 BS_CACHE_CHECK=1 {[bs]s} --cache-dir "$4.d/lb" "$4.d/b/{[file]s}" -femit-bin="$4" 2>"$4.d/log" || fail
                        \\grep -q "replaying donor" "$4.d/log" || {{ echo "no donor was replayed" >&2; fail; }}
                        \\{[mode_check]s}
                        \\cp "$4" "$4.d/replayed"
                        \\BS_CACHE_VERIFY=full BS_CACHE_CHECK=1 {[bs]s} --cache-dir "$4.d/lb" "$4.d/b/{[file]s}" -femit-bin="$4" 2>"$4.d/log" || fail
                        \\cmp "$4" "$4.d/replayed" >&2
                        \\{[moved]s}
                    , .{
                        .file = file,
                        .bs = bs_cmd,
                        .donor_dir = if (expect.donor_here) "b" else "a",
                        // A donor at this path is replayed lazily; one
                        // elsewhere names other absolute paths, so eagerly.
                        .mode_check = if (expect.donor_here)
                            \\grep -q "the walk reached" "$4.d/log" || { echo "the donor was not replayed lazily" >&2; fail; }
                        else
                            \\grep -q "replaying the donor eagerly" "$4.d/log" || { echo "the donor was not replayed eagerly" >&2; fail; }
                        ,
                        // Built by relative path from its own directory, the
                        // donor in another directory is replayed lazily (a
                        // worktree), and the log records this build's paths:
                        // the next build finds nothing changed. It adds the
                        // donor's missing code as new nodes, which link last,
                        // so only the programs' output is compared.
                        .moved = if (expect.donor_here) "" else b.fmt(
                            \\set -- "$1" "$2" "$3" "$(realpath "$4")" "$(realpath "$5")"
                            \\(cd "$4.d/a" && {[bs]s} --cache-dir "$4.d/la2" {[file]s} -femit-bin="$4.d/a/out2") 2>"$4.d/log" || fail
                            \\mkdir -p "$4.d/c" && cp "$4.d/b/{[file]s}" "$4.d/b/rt.zig" "$4.d/c/"
                            \\(cd "$4.d/c" && BS_CACHE_TIMING=1 BS_CACHE_CHECK=1 {[bs]s} --cache-dir "$4.d/lc" {[file]s} -femit-bin="$4.d/moved") 2>"$4.d/log" || fail
                            \\grep -q "the walk reached" "$4.d/log" || {{ echo "the moved program's donor was not replayed lazily" >&2; fail; }}
                            \\(cd "$4.d/c" && BS_CACHE_TIMING=1 {[bs]s} --cache-dir "$4.d/lc" {[file]s} -femit-bin="$4.d/moved") 2>"$4.d/log" || fail
                            \\grep -q "no input changed" "$4.d/log" || {{ echo "the build after the moved program's first build found changes" >&2; fail; }}
                            \\(cd "$4.d/c" && BS_CACHE_VERIFY=full BS_CACHE_CHECK=1 {[bs]s} --cache-dir "$4.d/lc" {[file]s} -femit-bin="$4.d/moved2") 2>"$4.d/log" || fail
                            \\{[compare]s}
                        , .{
                            .file = file,
                            .bs = bs_cmd,
                            // The programs run where bs's output does.
                            .compare = if (host_runs_bs_output)
                                \\"$4.d/moved" >"$4.d/moved.out" 2>&1 || true
                                \\"$4.d/moved2" >"$4.d/moved2.out" 2>&1 || true
                                \\cmp "$4.d/moved.out" "$4.d/moved2.out" >&2
                            else
                                "",
                        }),
                    }),
                    "sh",
                });
                r.addFileArg(donor);
                r.addFileArg(b.path(src_path));
                r.addFileArg(b.path("test/run/rt.zig"));
                break :blk r;
            } else blk: {
                const r = b.addRunArtifact(bs);
                r.addArgs(if (expect.libc) &.{ "build-exe", "-target", "x86_64-linux-gnu", "-lc" } else &.{ "build-exe", "-target", "x86_64-linux" });
                addFlags(b, r, expect.flags.items, src_path);
                break :blk r;
            };
            compile.addFileInput(b.path("test/run/rt.zig"));
            if (!upstream) {
                const uses_std = std.mem.find(u8, source, "@import(\"std\")") != null;
                const edits = expect.rebuild_without.items.len != 0 or expect.lib_edit != null;
                takes(b, &compile.step, if (edits) (if (uses_std) 10 else 1) else if (expect.donor_libc) 12 else if (expect.donor_without != null) (if (uses_std) 8 else 2) else if (uses_std) 2 else 1);
            }
            const bin = if (!upstream and (expect.rebuild_without.items.len != 0 or expect.lib_edit != null or expect.donor_without != null or expect.donor_libc)) bin: {
                const out = compile.addOutputFileArg2(name, .{});
                compile.addArtifactArg2(bs, .{});
                compile.addDirectoryArg2(std_zir, .{});
                break :bin out;
            } else compile.addOutputFileArg2(name, .{ .prefix = "-femit-bin=" });
            // CodeGen on worker threads gives the same output as on the
            // Sema thread (`BS_THREADS`); checked on programs that use
            // compiler_rt helpers, constants, error names and generics.
            if (!upstream and isThreadChecked(file)) {
                compile.setEnvironmentVariable("BS_THREADS", "4");
                compile.setEnvironmentVariable("BS_CACHE", "off");
                const serial = b.addRunArtifact(bs);
                serial.setName(b.fmt("compile {s} (BS_THREADS=1)", .{name}));
                serial.addArgs(&.{ "build-exe", "-target", "x86_64-linux" });
                serial.addFileArg(b.path(src_path));
                serial.addFileInput(b.path("test/run/rt.zig"));
                serial.setEnvironmentVariable("BS_THREADS", "1");
                serial.setEnvironmentVariable("BS_CACHE", "off");
                const serial_bin = serial.addOutputFileArg2(name, .{ .prefix = "-femit-bin=" });
                const same = b.addSystemCommand(&.{"cmp"});
                same.setName(b.fmt("{s}: BS_THREADS=4 and 1 build the same", .{name}));
                same.addFileArg(bin);
                same.addFileArg(serial_bin);
                test_step.dependOn(&same.step);
            }
            // A panic or an error return in inlined code has the stack or
            // error return trace of the program built without inlining
            // (docs/slop/architecture.md, "Synthetic panic frames"),
            // addresses aside.
            if (!upstream and host_runs_bs_output and isTraceChecked(file)) traceCheck(b, test_step, bs, src_path, name, "x86_64-linux", &.{}, bin);
            if (!upstream and !host_runs_bs_output) {
                // bs emits x86_64-linux executables; elsewhere only check
                // that they compile.
                test_step.dependOn(&compile.step);
                continue;
            }
            const run = std.Build.Step.Run.create(b, b.fmt("run {s}{s}", .{ name, if (upstream) " (upstream)" else "" }));
            run.addFileArg(bin);
            if (expect.stdout) |out| run.addCheck(.{ .expect_stdout_exact = out });
            if (if (upstream) expect.upstream_stderr orelse expect.stderr else expect.stderr) |err| run.addCheck(.{ .expect_stderr_exact = err });
            for (expect.stderr_contains.items) |part| run.addCheck(.{ .expect_stderr_match = part });
            run.addCheck(.{ .expect_term = if (expect.signal) |sig| .{ .signal = sig } else .{ .exited = expect.exit.? } });
            (if (upstream) upstream_step else test_step).dependOn(&run.step);
        }
        if (expect.aarch64_macos and host_runs_macos_output) {
            if (expect.lib_edit != null) std.debug.panic("{s}: aarch64-macos rebuilds take no lib edits", .{src_path});
            // With rebuild headers, as on aarch64-linux: the earlier
            // version, then this one as an edit build checked against a
            // full build, then a relink that must give the bytes of a
            // build without the cache (at a path with the same file name,
            // the code signature's identifier), signed.
            const bin = if (expect.rebuild_without.items.len != 0) blk: {
                const files = b.addWriteFiles();
                const before = files.add(file, earlierVersion(b, source, expect.rebuild_without.items, src_path));
                const r = b.addSystemCommand(&.{
                    "sh", "-c",
                    b.fmt(
                        \\set -e
                        \\out=$3 compiler=$4
                        \\mkdir -p "$out.d"
                        \\cp "$1" "$out.d/{[file]s}"
                        \\bs() {{ "$compiler" build-exe -target aarch64-macos "$out.d/{[file]s}" -femit-bin="$1" 2>"$out.d/log" || {{ cat "$out.d/log" >&2; exit 1; }}; }}
                        \\bs "$out"
                        \\cp "$2" "$out.d/{[file]s}"
                        \\BS_CACHE_VERIFY=1 BS_CACHE_CHECK=1 bs "$out"
                        \\rm "$out"
                        \\bs "$out"
                        \\codesign --verify --strict "$out" >&2
                        \\mkdir -p "$out.d/full"
                        \\BS_CACHE=off bs "$out.d/full/{[name]s}"
                        \\cmp "$out" "$out.d/full/{[name]s}" >&2
                    , .{ .file = file, .name = name }),
                    "sh",
                });
                r.addFileArg(before);
                r.addFileArg(b.path(src_path));
                const out = r.addOutputFileArg2(name, .{});
                r.addArtifactArg2(bs, .{});
                takes(b, &r.step, if (std.mem.find(u8, source, "@import(\"std\")") != null) 4 else 1);
                break :blk out;
            } else blk: {
                const compile = b.addRunArtifact(bs);
                compile.addArgs(&.{ "build-exe", "-target", "aarch64-macos" });
                compile.addFileArg(b.path(src_path));
                break :blk compile.addOutputFileArg2(name, .{ .prefix = "-femit-bin=" });
            };
            const run = std.Build.Step.Run.create(b, b.fmt("run {s} (aarch64-macos)", .{name}));
            run.addFileArg(bin);
            if (expect.stdout) |out| run.addCheck(.{ .expect_stdout_exact = out });
            if (expect.stderr) |err| run.addCheck(.{ .expect_stderr_exact = err });
            for (expect.stderr_contains.items) |part| run.addCheck(.{ .expect_stderr_match = part });
            run.addCheck(.{ .expect_term = if (expect.signal) |sig| .{ .signal = sig } else .{ .exited = expect.exit.? } });
            test_step.dependOn(&run.step);
        }
        // The x86_64 programs' traces check aarch64's stubs too.
        if (isTraceChecked(file)) {
            if (host_runs_macos_output) traceCheck(b, test_step, bs, src_path, name, "aarch64-macos", &.{}, null);
            if (aarch64_linux_runner) |runner| traceCheck(b, test_step, bs, src_path, name, "aarch64-linux", runner, null);
        }
        if (expect.aarch64_linux) for ([_]bool{ false, true }) |upstream| {
            const rebuild = !upstream and expect.rebuild_without.items.len != 0;
            if (rebuild and expect.lib_edit != null) std.debug.panic("{s}: aarch64-linux rebuilds take no lib edits", .{src_path});
            const compile = if (rebuild) blk: {
                // The earlier version, then this one as an edit build
                // checked against a full build, then a relink that must
                // give the bytes of a build without the cache.
                const files = b.addWriteFiles();
                const before = files.add(file, earlierVersion(b, source, expect.rebuild_without.items, src_path));
                const r = b.addSystemCommand(&.{
                    "sh", "-c",
                    b.fmt(
                        \\set -e
                        \\out=$4 compiler=$5
                        \\mkdir -p "$out.d"
                        \\cp "$3" "$out.d/rt.zig"
                        \\cp "$1" "$out.d/{[file]s}"
                        \\bs() {{ "$compiler" build-exe {[target]s} "$out.d/{[file]s}" -femit-bin="$1" 2>"$out.d/log" || {{ cat "$out.d/log" >&2; exit 1; }}; }}
                        \\bs "$out"
                        \\cp "$2" "$out.d/{[file]s}"
                        \\BS_CACHE_VERIFY=1 BS_CACHE_CHECK=1 bs "$out"
                        \\rm "$out"
                        \\bs "$out"
                        \\BS_CACHE=off bs "$out.d/full"
                        \\cmp "$out" "$out.d/full" >&2
                    , .{ .file = file, .target = if (expect.libc) "-target aarch64-linux-gnu -lc" else "-target aarch64-linux" }),
                    "sh",
                });
                r.addFileArg(before);
                r.addFileArg(b.path(src_path));
                r.addFileArg(b.path("test/run/rt.zig"));
                takes(b, &r.step, if (std.mem.find(u8, source, "@import(\"std\")") != null) 4 else 1);
                break :blk r;
            } else if (upstream) b.addSystemCommand(&.{upstreamZig(b)}) else b.addRunArtifact(bs);
            const bin = if (rebuild) blk: {
                const out = compile.addOutputFileArg2(name, .{});
                compile.addArtifactArg2(bs, .{});
                break :blk out;
            } else blk: {
                compile.addArgs(if (expect.libc) &.{ "build-exe", "-target", "aarch64-linux-gnu", "-lc" } else &.{ "build-exe", "-target", "aarch64-linux" });
                if (upstream and expect.upstream_llvm) compile.addArg("-fllvm");
                compile.addFileArg(b.path(src_path));
                break :blk compile.addOutputFileArg2(name, .{ .prefix = "-femit-bin=" });
            };
            const runner = (if (expect.libc) aarch64_linux_glibc_runner else aarch64_linux_runner) orelse {
                if (!upstream) test_step.dependOn(&compile.step);
                continue;
            };
            const run = std.Build.Step.Run.create(b, b.fmt("run {s} (aarch64-linux{s})", .{ name, if (upstream) ", upstream" else "" }));
            run.addArgs(runner);
            run.addFileArg(bin);
            if (expect.stdout) |out| run.addCheck(.{ .expect_stdout_exact = out });
            if (expect.stderr) |err| run.addCheck(.{ .expect_stderr_exact = err });
            // Upstream's LLVM traces name the root module (`in fail
            // (error_trace)`) where bs's name the root file, as upstream's
            // x86_64 backend does.
            for (expect.stderr_contains.items) |part| run.addCheck(.{ .expect_stderr_match = if (upstream)
                std.mem.replaceOwned(u8, b.allocator, part, b.fmt("({s}.zig)", .{name}), b.fmt("({s})", .{name})) catch @panic("OOM")
            else
                part });
            run.addCheck(.{ .expect_term = if (expect.signal) |sig| .{ .signal = sig } else .{ .exited = expect.exit.? } });
            (if (upstream) upstream_step else test_step).dependOn(&run.step);
        };
    }
}

/// `source` with each of `edits` (text, and what the earlier version has
/// instead) undone after its header lines: the earlier version a
/// `rebuild-without` test builds first.
fn earlierVersion(b: *std.Build, source: []const u8, edits: []const [2][]const u8, src_path: []const u8) []const u8 {
    var earlier = source;
    var body_start: usize = 0;
    while (std.mem.startsWith(u8, earlier[body_start..], "//! ")) body_start = std.mem.findScalarPos(u8, earlier, body_start, '\n').? + 1;
    for (edits) |edit| {
        const at = std.mem.findPos(u8, earlier, body_start, edit[0]) orelse std.debug.panic("{s}: rebuild-without text not found", .{src_path});
        earlier = b.fmt("{s}{s}{s}", .{ earlier[0..at], edit[1], earlier[at + edit[0].len ..] });
    }
    return earlier;
}

/// Checks that `src_path`'s stack or error return trace built for `target`
/// is that of the program built without inlining (docs/slop/architecture.md,
/// "Synthetic panic frames"), addresses and thread ids aside; `runner`
/// prefixes the runs. `inlined` is the program as built for `target`
/// already, if a run test built it.
fn traceCheck(b: *std.Build, test_step: *std.Build.Step, bs: *std.Build.Step.Compile, src_path: []const u8, name: []const u8, target: []const u8, runner: []const []const u8, inlined: ?std.Build.LazyPath) void {
    var out: [2]std.Build.LazyPath = undefined;
    for (&out, [_]?[]const u8{ null, "0" }) |*o, inline_env| {
        if (inline_env == null) if (inlined) |bin| {
            o.* = bin;
            continue;
        };
        const c = b.addRunArtifact(bs);
        c.setName(b.fmt("compile {s} for {s}{s}", .{ name, target, if (inline_env != null) " (BS_INLINE=0)" else "" }));
        c.addArgs(&.{ "build-exe", "-target", target });
        c.addFileArg(b.path(src_path));
        if (inline_env) |v| c.setEnvironmentVariable("BS_INLINE", v);
        c.setEnvironmentVariable("BS_CACHE", "off");
        o.* = c.addOutputFileArg2(name, .{ .prefix = "-femit-bin=" });
    }
    const same = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -e
        \\inl=$1 plain=$2 trace=$3
        \\shift 3
        \\mask() { sed -E 's/0x[0-9a-f]+/0x?/g; s/thread [0-9]+/thread ?/'; }
        \\{ "$@" "$inl" 2>&1 >/dev/null; } 2>/dev/null | mask >"$trace.inlined" || true
        \\{ "$@" "$plain" 2>&1 >/dev/null; } 2>/dev/null | mask >"$trace.plain" || true
        \\diff "$trace.plain" "$trace.inlined" >&2
        \\touch "$trace"
        ,
        "sh",
    });
    same.setName(b.fmt("{s}: the trace for {s} matches BS_INLINE=0's", .{ name, target }));
    same.addFileArg(out[0]);
    same.addFileArg(out[1]);
    _ = same.addOutputFileArg2("trace", .{});
    same.addArgs(runner);
    test_step.dependOn(&same.step);
}

fn isTraceChecked(file: []const u8) bool {
    for ([_][]const u8{ "error_inlined.zig", "error_prong_inlined.zig", "panic_inlined.zig", "panic_main_inlined.zig", "panic_module_inlined.zig", "panic_module_nested.zig", "panic_prong_inlined.zig", "panic_switch_inlined.zig", "panic_trace.zig" }) |f| {
        if (std.mem.eql(u8, file, f)) return true;
    }
    return false;
}

fn isThreadChecked(file: []const u8) bool {
    for ([_][]const u8{ "errors.zig", "float.zig", "int128.zig", "std_patterns.zig" }) |f| {
        if (std.mem.eql(u8, file, f)) return true;
    }
    return false;
}

/// Each `test/diag/*.zig` program is a compile error. It ends with a block
/// of `//` comment lines giving bs's exact standard error:
///
///   // error
///   // args: --error-format=json      (optional: more arguments)
///                                    (with `-Mroot=<file>`, in place of the file)
///   // <expected stderr line>
///   // ...
///
/// `test` runs `bs build-exe -fno-emit-bin <file>` from test/diag and
/// checks stderr and exit status 1; `test-upstream` checks that upstream
/// zig rejects the program too.
fn addDiagTests(b: *std.Build, bs: *std.Build.Step.Compile, test_step: *std.Build.Step, edit_step: *std.Build.Step, upstream_step: *std.Build.Step, std_zir: std.Build.LazyPath) void {
    const io = b.graph.io;
    b.dependOnDirectoryContents(b.path("test/diag"));
    var dir = b.root.openDir(io, "test/diag", .{ .iterate = true }) catch |err|
        std.debug.panic("unable to open test/diag: {t}", .{err});
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch |err| std.debug.panic("unable to list test/diag: {t}", .{err})) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const file = b.graph.dupeString(entry.name);
        const src_path = b.fmt("test/diag/{s}", .{file});
        b.dependOnFileContents(b.path(src_path));
        const source = dir.readFileAlloc(io, file, b.allocator, .limited(1 << 20)) catch |err|
            std.debug.panic("unable to read {s}: {t}", .{ src_path, err });
        const block = std.mem.findLast(u8, source, "\n// error\n") orelse
            std.debug.panic("{s}: missing '// error' block", .{src_path});
        var args: []const u8 = "";
        // `bs-only: why`: an error only bs gives, which upstream accepts.
        var bs_only = false;
        // `edit-from: "text" "earlier text"`: also an edit build from the
        // earlier version, which compiles, through the cache.
        var earlier: ?[]const u8 = null;
        var expected: std.ArrayList(u8) = .empty;
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, source[block + "\n// error\n".len ..], "\n"), '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (!std.mem.startsWith(u8, line, "//")) std.debug.panic("{s}: non-comment line after '// error'", .{src_path});
            const text = if (line.len > 2) line[3..] else "";
            if (expected.items.len == 0 and std.mem.startsWith(u8, text, "args: ")) {
                args = text["args: ".len..];
                continue;
            }
            if (expected.items.len == 0 and std.mem.startsWith(u8, text, "bs-only: ")) {
                bs_only = true;
                continue;
            }
            if (expected.items.len == 0 and std.mem.startsWith(u8, text, "edit-from: ")) {
                const value = text["edit-from: ".len..];
                const end = 1 + (std.mem.findPos(u8, value, 1, "\" \"") orelse std.debug.panic("{s}: bad edit-from", .{src_path}));
                const now = std.zig.string_literal.parseAlloc(b.allocator, value[0..end]) catch std.debug.panic("{s}: bad string", .{src_path});
                const then = std.zig.string_literal.parseAlloc(b.allocator, value[end + 1 ..]) catch std.debug.panic("{s}: bad string", .{src_path});
                const code = earlier orelse source[0..block];
                const at = std.mem.find(u8, code, now) orelse std.debug.panic("{s}: edit-from text not found", .{src_path});
                earlier = b.fmt("{s}{s}{s}", .{ code[0..at], then, code[at + now.len ..] });
                continue;
            }
            expected.appendSlice(b.allocator, text) catch @panic("OOM");
            expected.append(b.allocator, '\n') catch @panic("OOM");
        }

        const run = b.addRunArtifact(bs);
        run.setName(b.fmt("diag {s}", .{file}));
        run.setCwd(b.path("test/diag"));
        // An explicit target, so the expected diagnostics print on a Mac
        // too, where native aarch64-macos is refused until its CodeGen exists.
        run.addArgs(&.{ "build-exe", "-target", "x86_64-linux", "-fno-emit-bin" });
        // Arguments that give the root module (`--dep a -Mroot=<file>`)
        // name the file themselves.
        if (std.mem.find(u8, args, "-Mroot=") == null) run.addArg(file);
        var arg_it = std.mem.tokenizeScalar(u8, args, ' ');
        while (arg_it.next()) |a| run.addArg(a);
        run.addFileInput(b.path(src_path));
        run.setEnvironmentVariable("BS_CACHE", "off");
        run.addCheck(.{ .expect_stderr_exact = expected.items });
        run.addCheck(.{ .expect_term = .{ .exited = 1 } });
        takes(b, &run.step, 2);
        test_step.dependOn(&run.step);
        if (earlier) |text| {
            // The same errors from an edit build, whose cache holds the
            // earlier version's build.
            const files = b.addWriteFiles();
            const before = files.add(file, text);
            const edit = b.addSystemCommand(&.{
                "sh", "-c",
                b.fmt(
                    \\set -e
                    \\before=$(realpath "$1"); now=$(realpath "$2"); bs=$(realpath "$4")
                    \\mkdir -p "$3/g/bs"; cp -r "$5/bs/zir" "$3/g/bs"
                    \\cd "$3"
                    \\cp "$before" {[file]s}
                    \\"$bs" build-exe -target x86_64-linux {[file]s} -femit-bin=out --cache-dir l --global-cache-dir g{[args]s} 2>log || {{ cat log >&2; exit 2; }}
                    \\cp "$now" {[file]s}
                    \\exec "$bs" build-exe -target x86_64-linux {[file]s} -femit-bin=out --cache-dir l --global-cache-dir g{[args]s}
                , .{ .file = file, .args = if (args.len == 0) "" else b.fmt(" {s}", .{args}) }),
                "sh",
            });
            edit.setName(b.fmt("diag {s} (edit build)", .{file}));
            edit.addFileArg(before);
            edit.addFileArg(b.path(src_path));
            _ = edit.addOutputDirectoryArg2("edit", .{});
            edit.addArtifactArg2(bs, .{});
            edit.addDirectoryArg2(std_zir, .{});
            // Every line but the reference traces, whose frames for units
            // loaded green the edit build lacks (docs/slop/architecture.md).
            var edit_lines = std.mem.splitScalar(u8, expected.items, '\n');
            while (edit_lines.next()) |line| {
                if (line.len != 0 and !std.mem.startsWith(u8, line, "  ref: ")) edit.addCheck(.{ .expect_stderr_match = b.fmt("{s}\n", .{line}) });
            }
            edit.addCheck(.{ .expect_term = .{ .exited = 1 } });
            takes(b, &edit.step, 5);
            edit_step.dependOn(&edit.step);
        }

        if (bs_only) continue;
        const up = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-fno-emit-bin" });
        up.setName(b.fmt("diag {s} (upstream rejects)", .{file}));
        // The same target as bs's, for a diagnostic that depends on it.
        var up_args = std.mem.tokenizeScalar(u8, args, ' ');
        while (up_args.next()) |a| if (std.mem.eql(u8, a, "-target")) up.addArgs(&.{ a, up_args.next() orelse "" });
        up.addFileArg(b.path(src_path));
        up.addCheck(.{ .expect_stderr_match = "error: " });
        up.addCheck(.{ .expect_term = .{ .exited = 1 } });
        upstream_step.dependOn(&up.step);
    }
}

/// The ziglint rules as compile errors, with a project's `.ziglint.zon`
/// (`src/lint/`). Each `test/lint/*.zig` file is a case under
/// test/lint/.ziglint.zon, and each directory one under its own config,
/// with `main.zig` as its root file. The root file ends with a `// error`
/// block of bs's exact standard error, as a test/diag case's: `test` runs
/// `bs build-obj -fno-emit-bin` on it; `test-upstream` checks that
/// upstream zig, which reads no config, accepts it.
fn addLintTests(b: *std.Build, bs: *std.Build.Step.Compile, test_step: *std.Build.Step, cache_step: *std.Build.Step, upstream_step: *std.Build.Step, std_zir: std.Build.LazyPath) void {
    const io = b.graph.io;
    b.dependOnDirectoryContents(b.path("test/lint"));
    var dir = b.root.openDir(io, "test/lint", .{ .iterate = true }) catch |err|
        std.debug.panic("unable to open test/lint: {t}", .{err});
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch |err| std.debug.panic("unable to list test/lint: {t}", .{err})) |entry| {
        const case_dir, const file = switch (entry.kind) {
            .directory => .{ b.fmt("test/lint/{s}", .{entry.name}), "main.zig" },
            .file => if (std.mem.endsWith(u8, entry.name, ".zig")) .{ "test/lint", b.graph.dupeString(entry.name) } else continue,
            else => continue,
        };
        const src_path = b.fmt("{s}/{s}", .{ case_dir, file });
        const source = dir.readFileAlloc(io, src_path["test/lint/".len..], b.allocator, .limited(1 << 20)) catch |err|
            std.debug.panic("unable to read {s}: {t}", .{ src_path, err });
        const block = std.mem.findLast(u8, source, "\n// error\n") orelse
            std.debug.panic("{s}: missing '// error' block", .{src_path});
        var expected: std.ArrayList(u8) = .empty;
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, source[block + "\n// error\n".len ..], "\n"), '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "//")) std.debug.panic("{s}: non-comment line after '// error'", .{src_path});
            expected.appendSlice(b.allocator, if (line.len > 2) line[3..] else "") catch @panic("OOM");
            expected.append(b.allocator, '\n') catch @panic("OOM");
        }
        const name = if (entry.kind == .directory) entry.name else file;
        const run = b.addRunArtifact(bs);
        run.setName(b.fmt("lint {s}", .{name}));
        run.setCwd(b.path(case_dir));
        run.addArgs(&.{ "build-obj", "-target", "x86_64-linux", "-fno-emit-bin", file });
        run.setEnvironmentVariable("BS_CACHE", "off");
        run.addCheck(.{ .expect_stderr_exact = expected.items });
        run.addCheck(.{ .expect_term = .{ .exited = 1 } });
        takes(b, &run.step, 2);
        test_step.dependOn(&run.step);

        const up = b.addSystemCommand(&.{ upstreamZig(b), "test", "-fno-emit-bin", file });
        up.setName(b.fmt("lint {s} (upstream accepts)", .{name}));
        up.setCwd(b.path(case_dir));
        up.expectExitCode(0);
        upstream_step.dependOn(&up.step);
    }

    // The cache: a build with lint off that succeeded does not let a
    // build with lint on (by default, or by a config) skip as unchanged,
    // nor one config another's build, and turning lint off builds again.
    // A `.bs.zon` decides over a `.ziglint.zon`.
    const added = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -e
        \\bs=$(realpath "$2")
        \\mkdir -p "$1/g/bs"; cp -r "$3/bs/zir" "$1/g/bs"
        \\cd "$1"
        \\: > build.zig
        \\printf 'pub fn main() void {}\nfn Bad() void {}\ntest {\n    _ = &Bad;\n}\n' > main.zig
        \\c="--cache-dir l --global-cache-dir g -target x86_64-linux"
        \\printf '.{ .lint = false }\n' > .bs.zon
        \\"$bs" build-exe main.zig $c
        \\rm .bs.zon
        \\if "$bs" build-exe main.zig $c 2>log; then echo "the build with the defaults passed"; exit 1; fi
        \\grep -q "main.zig:2:4: error\[style, Z001\]: function 'Bad' should be camelCase" log || { cat log; exit 1; }
        \\if "$bs" build-exe main.zig $c 2>log; then echo "the build again passed"; exit 1; fi
        \\printf '.{ .rules = .{ .Z001 = .{ .enabled = false } } }\n' > .ziglint.zon
        \\"$bs" build-exe main.zig $c
        \\printf '.{}\n' > .ziglint.zon
        \\if "$bs" build-exe main.zig $c 2>log; then echo "the build with Z001 on again passed"; exit 1; fi
        \\printf '.{ .lint = .{ .rules = .{ .Z001 = .{ .enabled = false } } } }\n' > .bs.zon
        \\"$bs" build-exe main.zig $c
        \\printf '.{ .lint = false }\n' > .bs.zon
        \\"$bs" build-exe main.zig $c
        \\# Z011 is Sema's: a unit recorded with lint off is analyzed again
        \\# once a config covers its file.
        \\printf 'const lib = @import("lib.zig");\npub fn main() void {\n    lib.thing();\n}\n' > main.zig
        \\printf '/// Deprecated: gone soon.\npub fn thing() void {}\n' > lib.zig
        \\"$bs" build-exe main.zig $c
        \\rm .bs.zon
        \\if "$bs" build-exe main.zig $c 2>log; then echo "the build with a config passed"; exit 1; fi
        \\grep -q "main.zig:3:9: error\[deprecated, Z011\]: 'thing' is deprecated: Deprecated: gone soon." log || { cat log; exit 1; }
        \\# And it reads doc comments, which no source hash covers:
        \\# deprecating a callee in another file fails the next edit build.
        \\printf '/// Does a thing.\npub fn thing() void {}\n' > lib.zig
        \\"$bs" build-exe main.zig $c
        \\printf '/// Deprecated: gone soon.\npub fn thing() void {}\n' > lib.zig
        \\if "$bs" build-exe main.zig $c 2>log; then echo "the build after deprecating passed"; exit 1; fi
        \\grep -q "main.zig:3:9: error\[deprecated, Z011\]: 'thing' is deprecated: Deprecated: gone soon." log || { cat log; exit 1; }
        \\printf '/// Does it again.\npub fn thing() void {}\n' > lib.zig
        \\"$bs" build-exe main.zig $c
        \\# Sema checks every rule it answers, and the report keeps those the
        \\# config turns on: a unit recorded with Z029 off is analyzed again
        \\# when it is turned on.
        \\printf 'fn take(v: u32) u32 {\n    return v;\n}\npub fn main() void {\n    _ = take(@as(u32, 1));\n}\n' > main.zig
        \\printf '.{ .rules = .{ .Z029 = .{ .enabled = false } } }\n' > .ziglint.zon
        \\"$bs" build-exe main.zig $c
        \\printf '.{}\n' > .ziglint.zon
        \\if "$bs" build-exe main.zig $c 2>log; then echo "the build with Z029 on passed"; exit 1; fi
        \\grep -q "main.zig:5:14: error\[style, Z029\]" log || { cat log; exit 1; }
        ,
        "sh",
    });
    added.setName("lint config added and removed (cache)");
    _ = added.addOutputDirectoryArg2("lint-cache", .{});
    added.addArtifactArg2(bs, .{});
    added.addDirectoryArg2(std_zir, .{});
    added.expectExitCode(0);
    takes(b, &added.step, 5);
    cache_step.dependOn(&added.step);
}

/// `bs build-obj`: test/obj/lib.zig, linked into test/obj/main.zig by
/// upstream zig, run normally and into a panic in the object's code, whose
/// stack trace needs the object's debug info, and edited through the cache
/// as an object and a library (test/obj/cache.sh). `bs run`: test/obj/args.zig,
/// whose arguments and exit status must pass through.
/// `edit_step` takes test/run's scripts, and `cache_step` the objects and
/// libraries through the cache.
fn addObjAndRunTests(b: *std.Build, bs: *std.Build.Step.Compile, test_step: *std.Build.Step, edit_step: *std.Build.Step, cache_step: *std.Build.Step, std_zir: std.Build.LazyPath) void {
    // The aarch64-linux object and static library, linked by upstream
    // (with LLD).
    if (aarch64LinuxRunner(b)) |runner| for ([_][]const u8{ "build-obj", "build-lib" }) |cmd| {
        const obj = b.addRunArtifact(bs);
        obj.setName(b.fmt("bs {s} -target aarch64-linux", .{cmd}));
        obj.addArgs(&.{ cmd, "-target", "aarch64-linux" });
        obj.addFileArg(b.path("test/obj/lib.zig"));
        const out = obj.addOutputFileArg2(if (cmd[6] == 'l') "liblib.a" else "lib.o", .{ .prefix = "-femit-bin=" });
        const exe = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-target", "aarch64-linux" });
        exe.addFileArg(b.path("test/obj/main.zig"));
        exe.addFileArg(out);
        const bin = exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" });
        for ([_]bool{ false, true }) |panic| {
            const run = std.Build.Step.Run.create(b, b.fmt("run aarch64-linux {s} main{s}", .{ cmd[6..], if (panic) " (panic)" else "" }));
            run.addArgs(runner);
            run.addFileArg(bin);
            if (panic) {
                run.addArg("panic");
                run.addCheck(.{ .expect_stderr_match = "panic: integer overflow\n" });
                run.addCheck(.{ .expect_stderr_match = "lib.zig:25:14: 0x" });
                run.addCheck(.{ .expect_stderr_match = " in bs_overflow (lib.zig)\n    return x + 250;\n" });
                run.addCheck(.{ .expect_term = .{ .signal = .ABRT } });
            } else {
                run.addCheck(.{ .expect_stdout_exact = "20 7 41\n" });
                run.addCheck(.{ .expect_term = .{ .exited = 0 } });
            }
            test_step.dependOn(&run.step);
        }
    };
    const host = b.graph.host.result;
    if (host.cpu.arch != .x86_64 or host.os.tag != .linux) return;
    const obj = b.addRunArtifact(bs);
    obj.addArg("build-obj");
    obj.addFileArg(b.path("test/obj/lib.zig"));
    const lib_o = obj.addOutputFileArg2("lib.o", .{ .prefix = "-femit-bin=" });
    const exe = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-fno-llvm", "-fno-lld" });
    exe.addFileArg(b.path("test/obj/main.zig"));
    exe.addFileArg(lib_o);
    const bin = exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" });

    const run = std.Build.Step.Run.create(b, "run obj main");
    run.addFileArg(bin);
    run.addCheck(.{ .expect_stdout_exact = "20 7 41\n" });
    run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&run.step);
    const panic = std.Build.Step.Run.create(b, "run obj main (panic)");
    panic.addFileArg(bin);
    panic.addArg("panic");
    panic.addCheck(.{ .expect_stderr_match = "panic: integer overflow\n" });
    panic.addCheck(.{ .expect_stderr_match = "lib.zig:25:14: 0x" });
    panic.addCheck(.{ .expect_stderr_match = " in bs_overflow (lib.zig)\n    return x + 250;\n" });
    panic.addCheck(.{ .expect_stderr_match = "main.zig:14:38: 0x" });
    panic.addCheck(.{ .expect_term = .{ .signal = .ABRT } });
    test_step.dependOn(&panic.step);

    // With -lc an object stays an ordinary one (its extern is not looked
    // up in glibc) but position-independent, as upstream's, which upstream
    // links into a -lc PIE.
    const lc_obj = b.addRunArtifact(bs);
    lc_obj.addArgs(&.{ "build-obj", "-lc", "-target", "x86_64-linux-gnu" });
    lc_obj.addFileArg(b.path("test/obj/lib.zig"));
    const lc_o = lc_obj.addOutputFileArg2("lib.o", .{ .prefix = "-femit-bin=" });
    const lc_exe = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-lc", "-fPIE", "-target", "x86_64-linux-gnu" });
    lc_exe.addFileArg(b.path("test/obj/main.zig"));
    lc_exe.addFileArg(lc_o);
    const lc_run = std.Build.Step.Run.create(b, "run obj main (-lc object in a PIE)");
    lc_run.addFileArg(lc_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
    lc_run.addCheck(.{ .expect_stdout_exact = "20 7 41\n" });
    lc_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&lc_run.step);
    // Shared libraries that link glibc: lib.zig, whose c_twice the program
    // that loads it defines, so_libc.zig with a C source, which call glibc
    // through versioned imports, and so_libc.c alone, a library of C only;
    // upstream links the programs.
    for ([_][]const u8{ "test/obj/lib.zig", "test/link_input/so_libc.zig", "test/link_input/so_libc.c" }, [_][]const u8{ "test/obj/main.zig", "test/link_input/so_libc_main.zig", "test/link_input/so_c_main.zig" }, [_][]const u8{ "bslc", "so_libc", "so_c" }, [_][]const u8{ "", "z[c7:1]\nz[c42:2]\nc bye\n", "c3:1\nc4:2\nc bye\n" }) |lib_src, main_src, name, stderr| {
        const lc_so = b.addRunArtifact(bs);
        lc_so.setName(b.fmt("bs build-lib -dynamic -lc {s}", .{std.Io.Dir.path.basename(lib_src)}));
        lc_so.addArgs(&.{ "build-lib", "-dynamic", "-lc", "-target", "x86_64-linux-gnu", "--name", name });
        lc_so.addFileArg(b.path(lib_src));
        if (std.mem.eql(u8, name, "so_libc")) lc_so.addFileArg(b.path("test/link_input/so_libc.c"));
        lc_so.setEnvironmentVariable("BS_ZIG", upstreamZig(b));
        const lc_so_file = lc_so.addOutputFileArg2(b.fmt("lib{s}.so", .{name}), .{ .prefix = "-femit-bin=" });
        const lc_so_host = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-lc", "-rdynamic" });
        lc_so_host.addFileArg(b.path(main_src));
        lc_so_host.addFileArg(lc_so_file);
        const lc_so_run = b.addSystemCommand(&.{ "sh", "-c", "LD_LIBRARY_PATH=$(dirname \"$1\") exec \"$2\"", "sh" });
        lc_so_run.setName(b.fmt("run {s} (bs shared library linking glibc)", .{std.Io.Dir.path.basename(main_src)}));
        lc_so_run.addFileArg(lc_so_file);
        lc_so_run.addFileArg(lc_so_host.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
        if (stderr.len != 0) lc_so_run.addCheck(.{ .expect_stderr_exact = stderr }) else lc_so_run.addCheck(.{ .expect_stdout_exact = "20 7 41\n" });
        lc_so_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&lc_so_run.step);
    }
    // A version script: glibc's loader finds each export under the node
    // that versions it (a C object's too, through a wildcard), not under
    // another, and nothing that `local: *` hides. A name the script
    // versions that nothing defines is an error at it, as lld's.
    {
        const vs_so = b.addRunArtifact(bs);
        vs_so.setName("bs build-lib -dynamic -lc --version-script");
        vs_so.addArgs(&.{ "build-lib", "-dynamic", "-lc", "-target", "x86_64-linux-gnu", "--name", "so_version", "--version-script" });
        vs_so.addFileArg(b.path("test/link_input/so_version.map"));
        vs_so.addFileArg(b.path("test/link_input/so_version.zig"));
        vs_so.addFileArg(b.path("test/link_input/so_version.c"));
        vs_so.setEnvironmentVariable("BS_ZIG", upstreamZig(b));
        const vs_file = vs_so.addOutputFileArg2("libso_version.so", .{ .prefix = "-femit-bin=" });
        const vs_host = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-lc" });
        vs_host.addFileArg(b.path("test/link_input/so_version_main.zig"));
        const vs_run = std.Build.Step.Run.create(b, "run so_version_main (bs shared library with a version script)");
        vs_run.addFileArg(vs_host.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
        vs_run.addFileArg(vs_file);
        vs_run.addCheck(.{ .expect_stderr_exact = "ver_old@VER_1.0 1\nver_new@VER_1.1 2\nver_new@VER_1.0 none\nver_c_one@VER_1.0 3\nver_hidden none\nc_local_fn none\nc_local_ptr none\n" });
        vs_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&vs_run.step);

        const bad_map = b.addWriteFiles().add("bad.map", "VER_1.0 {\n  global: ver_old; ver_gone;\n  local: *;\n};\n");
        const vs_bad = b.addRunArtifact(bs);
        vs_bad.setName("bs build-lib -dynamic --version-script naming an undefined symbol");
        vs_bad.addArgs(&.{ "build-lib", "-dynamic", "-target", "x86_64-linux", "--version-script" });
        vs_bad.addFileArg(bad_map);
        vs_bad.addFileArg(b.path("test/link_input/so_version.zig"));
        _ = vs_bad.addOutputFileArg2("libbad.so", .{ .prefix = "-femit-bin=" });
        vs_bad.addCheck(.{ .expect_stderr_match = "bad.map:2:20: error[version-script]: version script assignment of 'VER_1.0' to symbol 'ver_gone' failed: 'libbad.so' defines no such symbol" });
        vs_bad.addCheck(.{ .expect_term = .{ .exited = 1 } });
        test_step.dependOn(&vs_bad.step);
    }
    // `--force_undefined`: a forced name pulls the archive member that
    // defines it, as lld's `-u` (its constructor prints, and sees the
    // forced export); without the flag nothing references the member.
    {
        const fu_cc = b.addSystemCommand(&.{ upstreamZig(b), "cc", "-target", "x86_64-linux-gnu", "-c" });
        fu_cc.addFileArg(b.path("test/link_input/force_undefined.c"));
        const fu_o = fu_cc.addOutputFileArg2("force_undefined.o", .{ .prefix = "-o" });
        const fu_ar = b.addSystemCommand(&.{ upstreamZig(b), "ar", "rcs" });
        const fu_a = fu_ar.addOutputFileArg2("libforce_undefined.a", .{});
        fu_ar.addFileArg(fu_o);
        for ([_]bool{ true, false }) |forced| {
            const fu_exe = b.addRunArtifact(bs);
            fu_exe.setName(if (forced) "bs build-exe --force_undefined" else "bs build-exe without --force_undefined");
            fu_exe.addArgs(&.{ "build-exe", "-lc", "-target", "x86_64-linux-gnu" });
            if (forced) fu_exe.addArgs(&.{ "--force_undefined", "keep_me", "--force_undefined", "fu_from_archive" });
            fu_exe.addFileArg(b.path("test/link_input/force_undefined.zig"));
            fu_exe.addFileArg(fu_a);
            fu_exe.setEnvironmentVariable("BS_ZIG", upstreamZig(b));
            const fu_run = std.Build.Step.Run.create(b, if (forced) "run force_undefined (the member pulled)" else "run force_undefined (no member)");
            fu_run.addFileArg(fu_exe.addOutputFileArg2("force_undefined", .{ .prefix = "-femit-bin=" }));
            fu_run.addCheck(.{ .expect_stderr_exact = if (forced) "pulled, keep_me 42\n" else "" });
            fu_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
            test_step.dependOn(&fu_run.step);
        }
    }
    // A shared library that links another shared library, given as an
    // input: DT_NEEDED names it and its functions are imports, as
    // upstream's.
    {
        const so_base = b.addRunArtifact(bs);
        so_base.addArgs(&.{ "build-lib", "-dynamic", "-lc", "-target", "x86_64-linux-gnu", "--name", "so_base" });
        so_base.addFileArg(b.path("test/link_input/so_libc.c"));
        so_base.setEnvironmentVariable("BS_ZIG", upstreamZig(b));
        const base_file = so_base.addOutputFileArg2("libso_base.so", .{ .prefix = "-femit-bin=" });
        const chain = b.addRunArtifact(bs);
        chain.setName("bs build-lib -dynamic -lc with a shared library input");
        chain.addArgs(&.{ "build-lib", "-dynamic", "-lc", "-target", "x86_64-linux-gnu", "--name", "so_chain" });
        chain.addFileArg(b.path("test/link_input/so_chain.c"));
        chain.addFileArg(base_file);
        chain.setEnvironmentVariable("BS_ZIG", upstreamZig(b));
        const chain_file = chain.addOutputFileArg2("libso_chain.so", .{ .prefix = "-femit-bin=" });
        const chain_host = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-lc" });
        chain_host.addFileArg(b.path("test/link_input/so_chain_main.zig"));
        chain_host.addFileArg(chain_file);
        chain_host.addFileArg(base_file);
        const chain_run = b.addSystemCommand(&.{ "sh", "-c", "d=$(mktemp -d) && cp \"$1\" \"$2\" \"$d\" && LD_LIBRARY_PATH=$d \"$3\"; r=$?; rm -rf \"$d\"; exit $r", "sh" });
        chain_run.setName("run so_chain_main.zig (bs shared library linking another)");
        chain_run.addFileArg(chain_file);
        chain_run.addFileArg(base_file);
        chain_run.addFileArg(chain_host.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
        chain_run.addCheck(.{ .expect_stderr_exact = "chain c50:1\nc bye\n" });
        chain_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&chain_run.step);
    }

    // The same object built -fPIC, linked by upstream into a static PIE
    // (which relaxes local-dynamic TLS) and into a shared object that a
    // dynamically linked program loads (which keeps it).
    const pic = b.addRunArtifact(bs);
    pic.addArgs(&.{ "build-obj", "-fPIC" });
    pic.addFileArg(b.path("test/obj/lib.zig"));
    const pic_o = pic.addOutputFileArg2("lib.o", .{ .prefix = "-femit-bin=" });
    const pie = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-fPIE", "-fno-llvm", "-fno-lld" });
    pie.addFileArg(b.path("test/obj/main.zig"));
    pie.addFileArg(pic_o);
    const pie_bin = pie.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" });
    const pie_run = std.Build.Step.Run.create(b, "run obj main (-fPIC object in a PIE)");
    pie_run.addFileArg(pie_bin);
    pie_run.addCheck(.{ .expect_stdout_exact = "20 7 41\n" });
    pie_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&pie_run.step);
    const pie_panic = std.Build.Step.Run.create(b, "run obj main (-fPIC object in a PIE, panic)");
    pie_panic.addFileArg(pie_bin);
    pie_panic.addArg("panic");
    pie_panic.addCheck(.{ .expect_stderr_match = " in bs_overflow (lib.zig)\n    return x + 250;\n" });
    pie_panic.addCheck(.{ .expect_term = .{ .signal = .ABRT } });
    test_step.dependOn(&pie_panic.step);
    // `bs ar` is upstream's `zig ar`, as build scripts run it through
    // `b.graph.zig_exe` (ghostty's combine_archives: `ar -M`).
    const ar = b.addRunArtifact(bs);
    ar.setName("bs ar rcs (upstream's ar)");
    ar.addArgs(&.{ "ar", "rcs" });
    const ar_out = ar.addOutputFileArg2("libbsar.a", .{});
    ar.addFileArg(pic_o);
    const ar_t = b.addRunArtifact(bs);
    ar_t.setName("bs ar t");
    ar_t.addArgs(&.{ "ar", "t" });
    ar_t.addFileArg(ar_out);
    ar_t.addCheck(.{ .expect_stdout_exact = "lib.o\n" });
    test_step.dependOn(&ar_t.step);
    const so = b.addSystemCommand(&.{ upstreamZig(b), "build-lib", "-dynamic", "--name", "bspic" });
    so.addFileArg(pic_o);
    const so_file = so.addOutputFileArg2("libbspic.so", .{ .prefix = "-femit-bin=" });
    const host_exe = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-lc", "-rdynamic" });
    host_exe.addFileArg(b.path("test/obj/main.zig"));
    host_exe.addFileArg(so_file);
    const host_bin = host_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" });
    const so_run = b.addSystemCommand(&.{ "sh", "-c", "LD_LIBRARY_PATH=$(dirname \"$1\") exec \"$2\"", "sh" });
    so_run.setName("run obj main (-fPIC object in a shared object)");
    so_run.addFileArg(so_file);
    so_run.addFileArg(host_bin);
    so_run.addCheck(.{ .expect_stdout_exact = "20 7 41\n" });
    so_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&so_run.step);
    // As upstream's `Config.resolve`: a static library finds its `-l`
    // shared libraries and leaves them out; without `-static` linking one
    // makes the library shared, which bs links only with glibc.
    for ([_]bool{ true, false }) |static| {
        const lsys = b.addSystemCommand(&.{ "sh", "-c", "set -e; z=$(realpath \"$1\") so=$(realpath \"$2\") src=$(realpath \"$4\"); cd \"$5\"; \"$z\" build-lib -L\"$(dirname \"$so\")\" -lbspic $3 -femit-bin=liblsys.a \"$src\"; ar t liblsys.a", "sh" });
        lsys.setName(b.fmt("bs build-lib -lbspic{s}", .{if (static) " -static" else ""}));
        lsys.addArtifactArg2(bs, .{});
        lsys.addFileArg(so_file);
        lsys.addArg(if (static) "-static" else "");
        lsys.addFileArg(b.path("test/obj/lib.zig"));
        _ = lsys.addOutputDirectoryArg2("work", .{});
        if (static) {
            lsys.addCheck(.{ .expect_stdout_exact = "lib.o\n" });
            lsys.addCheck(.{ .expect_term = .{ .exited = 0 } });
        } else {
            lsys.addCheck(.{ .expect_stderr_match = "bs links shared libraries only into executables and shared libraries that link libc (" });
            lsys.addCheck(.{ .expect_term = .{ .exited = 1 } });
        }
        test_step.dependOn(&lsys.step);
    }

    // The same library as bs's own shared object, loaded by a program
    // upstream links against it and by a C program with dlopen.
    const zso = b.addRunArtifact(bs);
    zso.addArgs(&.{ "build-lib", "-dynamic", "--name", "bsso" });
    zso.addFileArg(b.path("test/obj/lib.zig"));
    const zso_file = zso.addOutputFileArg2("libbsso.so", .{ .prefix = "-femit-bin=" });
    const zso_host = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-lc", "-rdynamic" });
    zso_host.addFileArg(b.path("test/obj/main.zig"));
    zso_host.addFileArg(zso_file);
    const zso_host_bin = zso_host.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" });
    const zso_run = b.addSystemCommand(&.{ "sh", "-c", "LD_LIBRARY_PATH=$(dirname \"$1\") exec \"$2\"", "sh" });
    zso_run.setName("run obj main (bs shared object)");
    zso_run.addFileArg(zso_file);
    zso_run.addFileArg(zso_host_bin);
    zso_run.addCheck(.{ .expect_stdout_exact = "20 7 41\n" });
    zso_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&zso_run.step);
    const dl_host = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-lc", "-rdynamic" });
    dl_host.addFileArg(b.path("test/obj/dl.c"));
    const dl_bin = dl_host.addOutputFileArg2("dl", .{ .prefix = "-femit-bin=" });
    const dl_run = std.Build.Step.Run.create(b, "run dl.c (dlopen of bs shared object)");
    dl_run.addFileArg(dl_bin);
    dl_run.addFileArg(zso_file);
    dl_run.addCheck(.{ .expect_stdout_exact = "20 7 41\n" });
    dl_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&dl_run.step);
    // The same host built by bs: -rdynamic exports its c_twice, which
    // the library binds to.
    const bs_dl_host = b.addRunArtifact(bs);
    bs_dl_host.addArgs(&.{ "build-exe", "-lc", "-rdynamic" });
    bs_dl_host.addFileArg(b.path("test/obj/dl.c"));
    const bs_dl_bin = bs_dl_host.addOutputFileArg2("dl", .{ .prefix = "-femit-bin=" });
    const bs_dl_run = std.Build.Step.Run.create(b, "run dl.c (bs -rdynamic host, dlopen of bs shared object)");
    bs_dl_run.addFileArg(bs_dl_bin);
    bs_dl_run.addFileArg(zso_file);
    bs_dl_run.addCheck(.{ .expect_stdout_exact = "20 7 41\n" });
    bs_dl_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&bs_dl_run.step);

    // A -fPIE object with `main`, which upstream links into a static PIE:
    // std.pie relocates it, reading `_DYNAMIC` PC-relative before then.
    const pie_main = b.addRunArtifact(bs);
    pie_main.addArgs(&.{ "build-obj", "-fPIE" });
    pie_main.addFileArg(b.path("test/obj/args.zig"));
    const pie_main_o = pie_main.addOutputFileArg2("args.o", .{ .prefix = "-femit-bin=" });
    const pie_exe = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-fPIE", "-fno-llvm", "-fno-lld" });
    pie_exe.addFileArg(pie_main_o);
    const pie_exe_bin = pie_exe.addOutputFileArg2("args", .{ .prefix = "-femit-bin=" });
    const pie_main_run = std.Build.Step.Run.create(b, "run args (-fPIE object with main in a static PIE)");
    pie_main_run.addFileArg(pie_exe_bin);
    pie_main_run.addArgs(&.{ "a", "b c" });
    pie_main_run.addCheck(.{ .expect_stdout_exact = "[a][b c]\n" });
    pie_main_run.addCheck(.{ .expect_term = .{ .exited = 42 } });
    test_step.dependOn(&pie_main_run.step);

    // A thread-local the host defines (`extern threadlocal`): local-exec
    // in an executable, initial-exec in a PIE, general-dynamic in a shared
    // object.
    for ([_][]const u8{ "-fno-PIC", "-fPIE", "-fPIC" }) |mode| {
        const tls = b.addRunArtifact(bs);
        tls.addArgs(&.{ "build-obj", mode });
        tls.addFileArg(b.path("test/obj/tls.zig"));
        const tls_o = tls.addOutputFileArg2("tls.o", .{ .prefix = "-femit-bin=" });
        const tls_run = if (std.mem.eql(u8, mode, "-fPIC")) run: {
            const tls_so = b.addSystemCommand(&.{ upstreamZig(b), "build-lib", "-dynamic", "--name", "bstls" });
            tls_so.addFileArg(tls_o);
            const tls_so_file = tls_so.addOutputFileArg2("libbstls.so", .{ .prefix = "-femit-bin=" });
            const tls_host = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-lc", "-rdynamic" });
            tls_host.addFileArg(b.path("test/obj/tls_main.zig"));
            tls_host.addFileArg(tls_so_file);
            const r = b.addSystemCommand(&.{ "sh", "-c", "LD_LIBRARY_PATH=$(dirname \"$1\") exec \"$2\"", "sh" });
            r.addFileArg(tls_so_file);
            r.addFileArg(tls_host.addOutputFileArg2("tls_main", .{ .prefix = "-femit-bin=" }));
            break :run r;
        } else run: {
            const tls_exe = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-fno-llvm", "-fno-lld", if (std.mem.eql(u8, mode, "-fPIE")) "-fPIE" else "-fno-PIE" });
            tls_exe.addFileArg(b.path("test/obj/tls_main.zig"));
            tls_exe.addFileArg(tls_o);
            const r = std.Build.Step.Run.create(b, "run tls_main");
            r.addFileArg(tls_exe.addOutputFileArg2("tls_main", .{ .prefix = "-femit-bin=" }));
            break :run r;
        };
        tls_run.setName(b.fmt("run tls_main (extern threadlocal, {s})", .{mode}));
        tls_run.addCheck(.{ .expect_stdout_exact = "5 6 5 6\n" });
        tls_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&tls_run.step);
    }

    // build-obj and build-lib through the cache: test/obj/cache.sh.
    for ([_][]const u8{ "build-obj", "build-lib" }) |cmd| {
        const cache = b.addSystemCommand(&.{"sh"});
        cache.setName(b.fmt("bs {s} cache", .{cmd}));
        cache.addFileArg(b.path("test/obj/cache.sh"));
        cache.addArtifactArg2(bs, .{});
        cache.addFileArg(b.path("test/obj/lib.zig"));
        _ = cache.addOutputDirectoryArg2("work", .{});
        cache.addArg(cmd);
        cache.addDirectoryArg2(std_zir, .{});
        cache.addCheck(.{ .expect_term = .{ .exited = 0 } });
        takes(b, &cache.step, 25);
        cache_step.dependOn(&cache.step);
    }

    // Donors kept per program: test/run/donor_own.sh.
    {
        const donor = b.addSystemCommand(&.{"sh"});
        donor.setName("bs donor own");
        donor.addFileArg(b.path("test/run/donor_own.sh"));
        donor.addArtifactArg2(bs, .{});
        _ = donor.addOutputDirectoryArg2("work", .{});
        donor.addDirectoryArg2(std_zir, .{});
        donor.addCheck(.{ .expect_term = .{ .exited = 0 } });
        takes(b, &donor.step, 15);
        edit_step.dependOn(&donor.step);
    }
    // A donor whose modules give an import name another module:
    // test/run/donor_module_deps.sh.
    {
        const deps = b.addSystemCommand(&.{"sh"});
        deps.setName("bs donor module deps");
        deps.addFileArg(b.path("test/run/donor_module_deps.sh"));
        deps.addArtifactArg2(bs, .{});
        _ = deps.addOutputDirectoryArg2("work", .{});
        deps.addDirectoryArg2(std_zir, .{});
        deps.addCheck(.{ .expect_term = .{ .exited = 0 } });
        takes(b, &deps.step, 10);
        edit_step.dependOn(&deps.step);
    }
    // Donors across musl's -lc: test/run/donor_musl_libc.sh.
    {
        const dm = b.addSystemCommand(&.{"sh"});
        dm.setName("bs donor across musl's -lc");
        dm.addFileArg(b.path("test/run/donor_musl_libc.sh"));
        dm.addArtifactArg2(bs, .{});
        _ = dm.addOutputDirectoryArg2("work", .{});
        dm.addDirectoryArg2(std_zir, .{});
        dm.setEnvironmentVariable("BS_ZIG", upstreamZig(b));
        dm.addCheck(.{ .expect_term = .{ .exited = 0 } });
        // With a cold global cache, libc.a's thousand sources.
        takes(b, &dm.step, 40);
        edit_step.dependOn(&dm.step);
    }
    // A store entry across compilations whose types lay out differently:
    // test/run/store_layout.sh.
    {
        const sl = b.addSystemCommand(&.{"sh"});
        sl.setName("bs store entry across layouts");
        sl.addFileArg(b.path("test/run/store_layout.sh"));
        sl.addArtifactArg2(bs, .{});
        _ = sl.addOutputDirectoryArg2("work", .{});
        sl.addDirectoryArg2(std_zir, .{});
        sl.setEnvironmentVariable("BS_ZIG", upstreamZig(b));
        sl.addCheck(.{ .expect_term = .{ .exited = 0 } });
        takes(b, &sl.step, 15);
        edit_step.dependOn(&sl.step);
    }
    // A compiler_rt edit without its old ZIR: test/run/edit_rt_old_zir.sh.
    {
        const rt = b.addSystemCommand(&.{"sh"});
        rt.setName("bs compiler_rt edit without old ZIR");
        rt.addFileArg(b.path("test/run/edit_rt_old_zir.sh"));
        rt.addArtifactArg2(bs, .{});
        _ = rt.addOutputDirectoryArg2("work", .{});
        rt.addArg(defaultZigLibDir(b));
        rt.addDirectoryArg2(std_zir, .{});
        rt.addCheck(.{ .expect_term = .{ .exited = 0 } });
        takes(b, &rt.step, 15);
        edit_step.dependOn(&rt.step);
    }
    // Edits after a function's type changed: test/run/edit_subject.sh.
    {
        const sj = b.addSystemCommand(&.{"sh"});
        sj.setName("bs edit after a function type change");
        sj.addFileArg(b.path("test/run/edit_subject.sh"));
        sj.addArtifactArg2(bs, .{});
        _ = sj.addOutputDirectoryArg2("work", .{});
        sj.addDirectoryArg2(std_zir, .{});
        sj.addCheck(.{ .expect_term = .{ .exited = 0 } });
        takes(b, &sj.step, 10);
        edit_step.dependOn(&sj.step);
    }
    // An edit to a module with `--dep`s that embeds a file:
    // test/run/edit_embed_dep_key.sh.
    {
        const ek = b.addSystemCommand(&.{"sh"});
        ek.setName("bs edit of a module with --deps that embeds a file");
        ek.addFileArg(b.path("test/run/edit_embed_dep_key.sh"));
        ek.addArtifactArg2(bs, .{});
        _ = ek.addOutputDirectoryArg2("work", .{});
        ek.addDirectoryArg2(std_zir, .{});
        ek.addCheck(.{ .expect_term = .{ .exited = 0 } });
        takes(b, &ek.step, 10);
        edit_step.dependOn(&ek.step);
    }
    // A deleted ZON file that the program imports but does not analyze:
    // test/run/edit_zon_unreferenced.sh.
    {
        const zu = b.addSystemCommand(&.{"sh"});
        zu.setName("bs build after an unanalyzed ZON import is deleted");
        zu.addFileArg(b.path("test/run/edit_zon_unreferenced.sh"));
        zu.addArtifactArg2(bs, .{});
        _ = zu.addOutputDirectoryArg2("work", .{});
        zu.addDirectoryArg2(std_zir, .{});
        zu.addCheck(.{ .expect_term = .{ .exited = 0 } });
        takes(b, &zu.step, 10);
        edit_step.dependOn(&zu.step);
    }
    // An edit to a compiler_rt helper's requester: test/run/edit_rt_request.sh.
    {
        const rq = b.addSystemCommand(&.{"sh"});
        rq.setName("bs compiler_rt requester edit");
        rq.addFileArg(b.path("test/run/edit_rt_request.sh"));
        rq.addArtifactArg2(bs, .{});
        _ = rq.addOutputDirectoryArg2("work", .{});
        rq.addDirectoryArg2(std_zir, .{});
        rq.addCheck(.{ .expect_term = .{ .exited = 0 } });
        takes(b, &rq.step, 10);
        edit_step.dependOn(&rq.step);
    }
    // A test's edit that adds an error name: test/run/edit_error_names_table.sh.
    {
        const en = b.addSystemCommand(&.{"sh"});
        en.setName("bs test edit adding an error name");
        en.addFileArg(b.path("test/run/edit_error_names_table.sh"));
        en.addArtifactArg2(bs, .{});
        _ = en.addOutputDirectoryArg2("work", .{});
        en.addDirectoryArg2(std_zir, .{});
        en.addCheck(.{ .expect_term = .{ .exited = 0 } });
        takes(b, &en.step, 10);
        edit_step.dependOn(&en.step);
    }
    // A deleted `@embedFile`d file: test/run/edit_embed_gone.sh.
    {
        const em = b.addSystemCommand(&.{"sh"});
        em.setName("bs edit around a deleted embedded file");
        em.addFileArg(b.path("test/run/edit_embed_gone.sh"));
        em.addArtifactArg2(bs, .{});
        _ = em.addOutputDirectoryArg2("work", .{});
        em.addDirectoryArg2(std_zir, .{});
        em.addCheck(.{ .expect_term = .{ .exited = 0 } });
        takes(b, &em.step, 10);
        edit_step.dependOn(&em.step);
    }
    // An error in a unit a failing edit no longer reaches:
    // test/run/edit_unreached_error.sh.
    {
        const ue = b.addSystemCommand(&.{"sh"});
        ue.setName("bs edit with an error in a unit no longer reached");
        ue.addFileArg(b.path("test/run/edit_unreached_error.sh"));
        ue.addArtifactArg2(bs, .{});
        _ = ue.addOutputDirectoryArg2("work", .{});
        ue.addDirectoryArg2(std_zir, .{});
        ue.addCheck(.{ .expect_term = .{ .exited = 0 } });
        takes(b, &ue.step, 10);
        edit_step.dependOn(&ue.step);
    }

    const bs_run = b.addRunArtifact(bs);
    bs_run.setName("bs run args");
    bs_run.addArg("run");
    bs_run.addFileArg(b.path("test/obj/args.zig"));
    bs_run.addArgs(&.{ "--", "a", "b c", "" });
    bs_run.addCheck(.{ .expect_stdout_exact = "[a][b c][]\n" });
    bs_run.addCheck(.{ .expect_term = .{ .exited = 43 } });
    takes(b, &bs_run.step, 5);
    test_step.dependOn(&bs_run.step);

    // Modules rooted at a ZON file and at a plain file.
    const mods = b.addRunArtifact(bs);
    mods.addArgs(&.{ "build-exe", "--dep", "config", "--dep", "version", "--dep", "back" });
    mods.addPrefixedFileArg("-Mapp=", b.path("test/obj/modules.zig"));
    mods.addPrefixedFileArg("-Mconfig=", b.path("test/obj/mod/config.zon"));
    mods.addPrefixedFileArg("-Mversion=", b.path("test/obj/mod/version"));
    mods.addArgs(&.{ "--dep", "app" });
    mods.addPrefixedFileArg("-Mback=", b.path("test/obj/mod/back.zig"));
    const mods_bin = mods.addOutputFileArg2("modules", .{ .prefix = "-femit-bin=" });
    const mods_run = std.Build.Step.Run.create(b, "run modules");
    mods_run.addFileArg(mods_bin);
    mods_run.addCheck(.{ .expect_stdout_exact = "bs 3 0.17.0-dev 30 31 app\n" });
    mods_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&mods_run.step);

    // `@src()` names the root module by its `-M` name; a second build
    // (`bs run` without `-M`) shares the first one's global cache, so it
    // takes the first as its donor if the donor key lets it.
    const src_app = b.addRunArtifact(bs);
    src_app.setName("bs run @src module app");
    src_app.addArg("run");
    src_app.addPrefixedFileArg("-Mapp=", b.path("test/obj/mod/srcmod.zig"));
    src_app.addArg("--global-cache-dir");
    const src_cache = src_app.addOutputDirectoryArg2("src-module-cache", .{});
    src_app.addCheck(.{ .expect_stdout_exact = "app\n" });
    takes(b, &src_app.step, 5);
    const src_stem = b.addRunArtifact(bs);
    src_stem.setName("bs run @src module stem");
    src_stem.addArg("run");
    src_stem.addFileArg(b.path("test/obj/mod/srcmod.zig"));
    src_stem.addArg("--global-cache-dir");
    src_stem.addDirectoryArg2(src_cache, .{});
    src_stem.addCheck(.{ .expect_stdout_exact = "srcmod\n" });
    test_step.dependOn(&src_stem.step);

    // -fno-emit-bin: as upstream's, `bs test` compiles the tests and runs
    // nothing; this test fails if it runs.
    const no_bin_test = b.addRunArtifact(bs);
    no_bin_test.setName("bs test -fno-emit-bin");
    no_bin_test.addArgs(&.{ "test", "-fno-emit-bin" });
    no_bin_test.addFileArg(b.path("test/obj/failing_test.zig"));
    no_bin_test.addCheck(.{ .expect_stderr_exact = "" });
    no_bin_test.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&no_bin_test.step);

    // A module under test that imports itself by its `-M` name. It is
    // named "root" like upstream's test runner, and another module "main";
    // the cache check fails if a module shares a cache key with the test
    // runner or the module under test.
    const self_test = b.addRunArtifact(bs);
    self_test.setName("bs test self import");
    self_test.setEnvironmentVariable("BS_CACHE_CHECK", "1");
    self_test.addArgs(&.{ "test", "--dep", "self=root", "--dep", "main" });
    self_test.addPrefixedFileArg("-Mroot=", b.path("test/obj/mod/self.zig"));
    self_test.addPrefixedFileArg("-Mmain=", b.path("test/obj/mod/seven.zig"));
    self_test.addCheck(.{ .expect_stderr_match = "All 2 tests passed." });
    self_test.addCheck(.{ .expect_term = .{ .exited = 0 } });
    takes(b, &self_test.step, 5);
    test_step.dependOn(&self_test.step);

    // Testing std itself after testing a file that uses std, in one global
    // cache: std's containers have tests among their roots only when std
    // is the module under test, so the first build must not be the
    // second's donor. If it were, `Allocating` would load green without
    // the reference that reaches its test, and the cache check would fail.
    const lib_dir = defaultZigLibDir(b);
    const user_test = b.addRunArtifact(bs);
    user_test.setName("bs test a std user");
    user_test.addArgs(&.{ "test", "--zig-lib-dir", lib_dir, "--test-filter", "Allocating" });
    user_test.addFileArg(b.path("test/obj/writer_test.zig"));
    user_test.addArg("--global-cache-dir");
    const std_cache = user_test.addOutputDirectoryArg2("std-test-cache", .{});
    user_test.addCheck(.{ .expect_stderr_match = "All 1 tests passed." });
    const std_test = b.addRunArtifact(bs);
    std_test.setName("bs test std after a std user");
    std_test.setEnvironmentVariable("BS_CACHE_CHECK", "1");
    std_test.addArgs(&.{ "test", "--zig-lib-dir", lib_dir, "--test-filter", "Allocating" });
    std_test.addFileArg(.{ .cwd_relative = b.pathJoin(&.{ lib_dir, "std", "std.zig" }) });
    std_test.addArg("--global-cache-dir");
    std_test.addDirectoryArg2(std_cache, .{});
    std_test.addCheck(.{ .expect_stderr_match = "tests passed." });
    std_test.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&std_test.step);
}

/// `bs build` end to end: test/build/check.sh builds test/build/hello
/// with bs as the build runner's compiler, in the default global cache,
/// where bs keeps the build runner it compiles once per bs binary. Its
/// first part compiles the runner; the others wait for it and run at once,
/// shape after `translate_c` has compiled translate-c there.
fn addBuildTest(b: *std.Build, bs: *std.Build.Step.Compile, build_web_wasm: std.Build.LazyPath, translate_c: ?*std.Build.Step) *std.Build.Step {
    const host = b.graph.host.result;
    const step = b.step("test-build", "Check `bs build` end to end on test/build/hello");
    if (host.cpu.arch != .x86_64 or host.os.tag != .linux) return step;
    var first: ?*std.Build.Step = null;
    for ([_][]const u8{ "build", "shape", "fuzz", "misc", "compiler" }, [_]u32{ 32, 5, 20, 8, 20 }) |part, seconds| {
        const run = b.addSystemCommand(&.{"sh"});
        run.setName(b.fmt("bs build test/build/hello ({s})", .{part}));
        run.addFileArg(b.path("test/build/check.sh"));
        run.addArtifactArg2(bs, .{});
        run.addDirectoryArg2(b.path("test/build/hello"), .{});
        _ = run.addOutputDirectoryArg2("work", .{});
        run.addFileArg(build_web_wasm);
        run.addArg(part);
        run.addCheck(.{ .expect_term = .{ .exited = 0 } });
        takes(b, &run.step, seconds);
        if (first) |f| run.step.dependOn(f) else first = &run.step;
        if (std.mem.eql(u8, part, "shape")) if (translate_c) |tc| run.step.dependOn(tc);
        step.dependOn(&run.step);
    }
    // `bs build` of a Zig 0.16 project: test/build16/check.sh.
    const v0_16 = b.addSystemCommand(&.{"sh"});
    v0_16.setName("bs build test/build16 (Zig 0.16)");
    v0_16.addFileArg(b.path("test/build16/check.sh"));
    v0_16.addArtifactArg2(bs, .{});
    v0_16.addDirectoryArg2(b.path("test/build16"), .{});
    _ = v0_16.addOutputDirectoryArg2("work", .{});
    v0_16.addCheck(.{ .expect_term = .{ .exited = 0 } });
    takes(b, &v0_16.step, 30);
    step.dependOn(&v0_16.step);
    return step;
}

/// The build runner starts a ready step on a worker thread only while one
/// of its `-j` workers (default: one fewer than the CPUs) is free, and
/// otherwise runs it at once in the thread that made it ready. When bs is
/// built, that one thread would make the few hundred steps that run bs
/// ready and run most of them itself, one after another, while the other
/// workers sat idle (measured: 1.4 steps busy on average on 4 CPUs).
/// Instead each step that runs bs waits for one of `-j` gates, which wait
/// for bs and then `first`, so that each gate's thread runs its share,
/// dealt heaviest first to the gate with the least work so far by `takes`
/// (the runner shuffles the order each gate runs them in). The gate is the
/// last of a step's dependencies to finish, so its thread runs the step,
/// not the thread that finished bs or `first`. bs stays a direct
/// dependency: the build runner's configuration numbers steps breadth
/// first, and a step's arguments need the artifact it runs numbered by
/// then. (A step that waits for another of them, as test/build's parts
/// do, runs on that one's thread.)
///
/// Each of them also runs bs with one CodeGen worker beside the Sema
/// thread (`BS_THREADS=2`) unless it sets its own count: the steps keep
/// every CPU busy already, and a Debug bs with a worker per CPU spends a
/// third more CPU on the same build (six builds on a 4-CPU orb: 54 s of
/// CPU at 4, 42 s at 2, 37 s at 1), much of it the system time of
/// unmapping freed memory under SafeAllocator. Two keeps CodeGen on a
/// worker, as any count above one does; the output is the same for
/// every count.
fn spreadBsUsers(b: *std.Build, bs: *std.Build.Step, first: *std.Build.Step, roots: []const *std.Build.Step) void {
    const Step = std.Build.Step;
    const workers = @max(1, (std.Thread.getCpuCount() catch 1) -| 1);
    const gates = b.allocator.alloc(*Step, workers) catch @panic("OOM");
    const loads = b.allocator.alloc(usize, workers) catch @panic("OOM");
    for (gates, 0..) |*g, i| {
        const gate = b.allocator.create(Step.TopLevel) catch @panic("OOM");
        gate.* = .{ .step = .init(.{ .tag = .top_level, .name = b.fmt("bs users {d}", .{i}), .owner = b }), .description = "" };
        gate.step.dependOn(first);
        g.* = &gate.step;
    }
    var seen: std.array_hash_map.Auto(*Step, void) = .empty;
    var users: std.ArrayList(*Step) = .empty;
    // Each root's users are dealt on their own, so that a build of one
    // root (a CI job's) spreads its work over every gate too; a user that
    // an earlier root reaches is that root's.
    for (roots) |root| {
        var i = seen.count();
        seen.put(b.allocator, root, {}) catch @panic("OOM");
        users.clearRetainingCapacity();
        while (i < seen.count()) : (i += 1) {
            const s = seen.keys()[i];
            for (s.dependencies.items) |d| seen.put(b.allocator, d, {}) catch @panic("OOM");
            if (s != first and std.mem.findScalar(*Step, s.dependencies.items, bs) != null) users.append(b.allocator, s) catch @panic("OOM");
        }
        std.mem.sort(*Step, users.items, {}, struct {
            fn heavier(_: void, x: *Step, y: *Step) bool {
                return stepSeconds(x) > stepSeconds(y);
            }
        }.heavier);
        @memset(loads, 0);
        for (users.items) |s| {
            if (s.cast(Step.Run)) |run| {
                if (run.getEnvMap().get("BS_THREADS") == null) run.setEnvironmentVariable("BS_THREADS", "2");
            }
            const least = std.mem.findMin(usize, loads);
            s.dependOn(gates[least]);
            loads[least] += stepSeconds(s);
        }
    }
}

/// Deals `whole`'s dependencies between two new steps, `<whole>-1` and
/// `<whole>-2`, and makes `whole` wait for the halves instead, so that CI
/// runs each half as a job. Dependencies that share a step other than bs
/// and `first` stay together (a runtime library built once, a build and
/// its checks), and the groups go heaviest first to the lighter half by
/// the seconds of their steps (`takes`).
fn halve(b: *std.Build, whole: *std.Build.Step, bs: *std.Build.Step, first: *std.Build.Step) [2]*std.Build.Step {
    const Step = std.Build.Step;
    const deps = whole.dependencies.items;
    // A union-find over the dependencies: `group[i]` leads toward the
    // representative of dependency i's group.
    const group = b.allocator.alloc(usize, deps.len) catch @panic("OOM");
    for (group, 0..) |*g, i| g.* = i;
    const root = struct {
        fn of(g: []usize, i: usize) usize {
            var r = i;
            while (g[r] != r) r = g[r];
            g[i] = r;
            return r;
        }
    }.of;
    // Each step the dependencies reach, and the first dependency that does.
    var owner: std.array_hash_map.Auto(*Step, usize) = .empty;
    var todo: std.ArrayList(*Step) = .empty;
    for (deps, 0..) |d, i| {
        todo.append(b.allocator, d) catch @panic("OOM");
        while (todo.pop()) |s| {
            const gop = owner.getOrPut(b.allocator, s) catch @panic("OOM");
            if (gop.found_existing) {
                group[root(group, i)] = root(group, gop.value_ptr.*);
                continue;
            }
            gop.value_ptr.* = i;
            for (s.dependencies.items) |dd| if (dd != bs and dd != first) todo.append(b.allocator, dd) catch @panic("OOM");
        }
    }
    const seconds = b.allocator.alloc(u64, deps.len) catch @panic("OOM");
    @memset(seconds, 0);
    for (owner.keys(), owner.values()) |s, i| seconds[root(group, i)] += stepSeconds(s);
    var roots: std.ArrayList(usize) = .empty;
    for (group, 0..) |_, i| if (root(group, i) == i) roots.append(b.allocator, i) catch @panic("OOM");
    std.mem.sort(usize, roots.items, seconds, struct {
        fn heavier(w: []const u64, x: usize, y: usize) bool {
            return w[x] > w[y];
        }
    }.heavier);
    const half = b.allocator.alloc(usize, deps.len) catch @panic("OOM");
    var loads = [2]u64{ 0, 0 };
    for (roots.items) |r| {
        half[r] = if (loads[1] < loads[0]) 1 else 0;
        loads[half[r]] += seconds[r];
    }
    const halves = [2]*Step{
        b.step(b.fmt("{s}-1", .{whole.name}), b.fmt("Half of {s}, for a CI job", .{whole.name})),
        b.step(b.fmt("{s}-2", .{whole.name}), b.fmt("The other half of {s}, for a CI job", .{whole.name})),
    };
    for (deps, 0..) |d, i| halves[half[root(group, i)]].dependOn(d);
    whole.dependencies.clearRetainingCapacity();
    for (halves) |h| whole.dependOn(h);
    return halves;
}

/// About how many seconds a step that runs bs takes with a Debug bs on a
/// 4-CPU orb, where it is more than 1, for `spreadBsUsers`.
var step_seconds: std.AutoHashMapUnmanaged(*std.Build.Step, u32) = .empty;

fn takes(b: *std.Build, s: *std.Build.Step, seconds: u32) void {
    step_seconds.put(b.allocator, s, seconds) catch @panic("OOM");
}

fn stepSeconds(s: *std.Build.Step) u32 {
    return step_seconds.get(s) orelse 1;
}

/// Mach-O inputs for src/link/MachOInput.zig's and Archive.zig's tests,
/// as upstream's Clang and llvm-ar write them for aarch64-macos: an object
/// and a Darwin archive of two more, as the imports `macho_input_main.o`
/// and `macho_input_lib.a`.
fn addMachOInputs(b: *std.Build, m: *std.Build.Module) void {
    const zig = upstreamZig(b);
    var objs: [3]std.Build.LazyPath = undefined;
    for ([_][]const u8{ "main", "member", "other" }, [_][]const u8{ "main.o", "macho_input_long_member_name.o", "other.o" }, &objs) |stem, out, *obj| {
        const cc = b.addSystemCommand(&.{ zig, "cc", "-target", "aarch64-macos", "-O2", "-c" });
        cc.addFileArg(b.path(b.fmt("test/link_input/macho_{s}.c", .{stem})));
        cc.addArg("-o");
        obj.* = cc.addOutputFileArg2(out, .{});
    }
    const ar = b.addSystemCommand(&.{ zig, "ar", "--format=darwin", "rcs" });
    const lib = ar.addOutputFileArg2("lib.a", .{});
    ar.addFileArg(objs[1]);
    ar.addFileArg(objs[2]);
    for ([_][]const u8{ "a", "b" }) |x| {
        const cc = b.addSystemCommand(&.{ zig, "cc", "-target", "aarch64-macos", "-c" });
        cc.addFileArg(b.path(b.fmt("test/link_input/macho_objc_{s}.m", .{x})));
        cc.addArg("-o");
        m.addAnonymousImport(b.fmt("macho_input_objc_{s}.o", .{x}), .{ .root_source_file = cc.addOutputFileArg2(b.fmt("objc_{s}.o", .{x}), .{}) });
    }
    m.addAnonymousImport("macho_input_main.o", .{ .root_source_file = objs[0] });
    m.addAnonymousImport("macho_input_lib.a", .{ .root_source_file = lib });
}

fn defaultZigLibDir(b: *std.Build) []const u8 {
    const io = b.graph.io;
    const zig = upstreamZig(b);
    const zig_exe = std.Io.Dir.cwd().realPathFileAlloc(io, zig, b.allocator) catch |err|
        std.debug.panic("unable to resolve zig executable path '{s}': {t}", .{ zig, err });
    return b.pathJoin(&.{ std.Io.Dir.path.dirname(zig_exe).?, "lib" });
}

/// lib/docs/wasm of `zig_lib_dir` compiled as upstream's compiler compiles
/// it for `-femit-docs` (`workerDocsWasm`): wasm32, ReleaseSmall, the same
/// CPU features. bs has no wasm backend, so upstream zig builds it, once.
fn docsWasm(b: *std.Build, zig_lib_dir: []const u8) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{
        upstreamZig(b),   "build-exe",
        "-target",        "wasm32-freestanding",
        "-mcpu",          "baseline+atomics+reference_types",
        "-OReleaseSmall", "-fno-entry",
        "-rdynamic",      "--name",
        "main",           "--dep",
        "Walk",
    });
    cmd.addPrefixedFileArg("-Mroot=", .{ .cwd_relative = b.pathJoin(&.{ zig_lib_dir, "docs", "wasm", "main.zig" }) });
    cmd.addPrefixedFileArg("-MWalk=", .{ .cwd_relative = b.pathJoin(&.{ zig_lib_dir, "docs", "wasm", "Walk.zig" }) });
    return cmd.addOutputFileArg2("main.wasm", .{ .prefix = "-femit-bin=" });
}

/// lib/build-web of `zig_lib_dir` compiled as upstream's build runner
/// compiles it for its web UI (`buildClientWasm` in
/// lib/compiler/Maker/WebServer.zig): wasm32, ReleaseFast, the same CPU
/// features and modules, but stripped. Upstream zig builds it, as
/// `docsWasm`.
fn buildWebWasm(b: *std.Build, zig_lib_dir: []const u8) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{
        upstreamZig(b),  "build-exe",
        "-target",       "wasm32-freestanding",
        "-mcpu",         "baseline+atomics+bulk_memory+multivalue+mutable_globals+nontrapping_fptoint+reference_types+sign_ext",
        "-OReleaseFast", "-fno-entry",
        "-rdynamic",     "-fsingle-threaded",
        // Without its DWARF: 0.4 MB in bs instead of 2.4 MB.
        "-fstrip",       "--name",
        "build-web",     "--dep",
        "Walk",          "--dep",
        "html_render",
    });
    cmd.addPrefixedFileArg("-Mroot=", .{ .cwd_relative = b.pathJoin(&.{ zig_lib_dir, "build-web", "main.zig" }) });
    cmd.addPrefixedFileArg("-MWalk=", .{ .cwd_relative = b.pathJoin(&.{ zig_lib_dir, "docs", "wasm", "Walk.zig" }) });
    cmd.addArgs(&.{ "--dep", "Walk" });
    cmd.addPrefixedFileArg("-Mhtml_render=", .{ .cwd_relative = b.pathJoin(&.{ zig_lib_dir, "docs", "wasm", "html_render.zig" }) });
    return cmd.addOutputFileArg2("build-web.wasm", .{ .prefix = "-femit-bin=" });
}

/// lib/compiler/Maker/Fetch.zig of `zig_lib_dir` and the files it
/// imports, as a module rooted at src/build16/Maker.zig, which stands in
/// for the Maker.zig they import: upstream 0.17.1's package fetcher,
/// unchanged, which bs runs for `bs build` of Zig 0.16 projects, whose
/// packages 0.16's compiler fetched in the same format (src/Build16.zig).
fn fetchModule(b: *std.Build, zig_lib_dir: []const u8) *std.Build.Module {
    const files = b.addWriteFiles();
    for ([_][]const u8{ "Fetch.zig", "Fetch/git.zig", "Package.zig", "Package/Manifest.zig" }) |sub| {
        _ = files.addCopyFile(.{ .cwd_relative = b.pathJoin(&.{ zig_lib_dir, "compiler", "Maker", sub }) }, b.pathJoin(&.{ "Maker", sub }));
    }
    const root = files.addCopyFile(b.path("src/build16/Maker.zig"), "Maker.zig");
    return b.createModule(.{ .root_source_file = root });
}

/// Upstream zig, the oracle the tests compare bs with: the zig running
/// this build, or under `bs build` (no zig release next to the
/// compiler) `zig` on PATH.
/// C objects and archives that bs links into an executable
/// (docs/slop/architecture.md, "Object, archive and shared-library inputs"):
/// upstream's `zig cc` and the system's `cc` compile them, non-PIC and
/// -fPIC, and the program must print what upstream's link of the same
/// inputs prints.
/// Returns the step that compiles translate-c with bs first.
/// `cache_step` takes the inputs through the cache.
fn addLinkInputTests(b: *std.Build, bs: *std.Build.Step.Compile, test_step: *std.Build.Step, cache_step: *std.Build.Step, std_zir: std.Build.LazyPath) ?*std.Build.Step {
    const host = b.graph.host.result;
    if (host.cpu.arch != .x86_64 or host.os.tag != .linux) return null;
    const expect = "44 108 12 gamma hello from C 0 4 9 copied\nthread 712\n712 4 23\nextern data data 30 30\nextern data data 23 111 1\n";
    const zig = upstreamZig(b);
    const cc = b.findProgram(.{ .names = &.{"cc"} });
    // `zig cc`'s Debug objects call ubsan_rt and the stack protector.
    const variants = [_]struct { name: []const u8, cc: []const []const u8 }{
        .{ .name = "zig cc", .cc = &.{ zig, "cc" } },
        .{ .name = "zig cc -fPIC", .cc = &.{ zig, "cc", "-fPIC" } },
        .{ .name = "cc", .cc = &.{cc orelse ""} },
    };
    for (variants) |v| {
        if (v.cc[0].len == 0) continue;
        const compile = struct {
            fn f(bb: *std.Build, args: []const []const u8, src: []const u8, extra: []const []const u8) std.Build.LazyPath {
                const c = bb.addSystemCommand(args);
                c.addArgs(extra);
                c.addArg("-c");
                c.addFileArg(bb.path(bb.fmt("test/link_input/{s}", .{src})));
                return c.addOutputFileArg2(bb.fmt("{s}.o", .{src}), .{ .prefix = "-o" });
            }
        }.f;
        const lib = compile(b, v.cc, "lib.c", &.{"-fcommon"});
        // Thread-locals through the dynamic models, which the link relaxes.
        const tls = compile(b, v.cc, "tls.c", &.{"-fPIC"});
        const tlsie = compile(b, v.cc, "tlsie.c", &.{"-fPIC"});
        // Two archives whose members call each other.
        var archives: [2]std.Build.LazyPath = undefined;
        for (&archives, [_][]const u8{ "a1.c", "a2.c" }) |*a, src| {
            const ar = b.addSystemCommand(&.{ zig, "ar", "rcs" });
            a.* = ar.addOutputFileArg2(b.fmt("lib{s}.a", .{src[0..2]}), .{});
            ar.addFileArg(compile(b, v.cc, src, &.{}));
        }
        const exe = b.addRunArtifact(bs);
        exe.setName(b.fmt("bs build-exe with {s} objects", .{v.name}));
        exe.addArg("build-exe");
        exe.addFileArg(b.path("test/link_input/main.zig"));
        for ([_]std.Build.LazyPath{ lib, tls, tlsie, archives[0] }) |input| exe.addFileArg(input);
        // The second archive by name (`-l`, `-L`).
        exe.addArg("-la2");
        exe.addDirectoryArg2(archives[1].dirname(), .{ .prefix = "-L" });
        exe.setEnvironmentVariable("BS_CACHE", "off");
        const bin = exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" });
        const run = std.Build.Step.Run.create(b, b.fmt("run bs link of {s} objects", .{v.name}));
        run.addFileArg(bin);
        run.addCheck(.{ .expect_stderr_exact = expect });
        run.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&run.step);
        if (!std.mem.eql(u8, v.name, "zig cc")) continue;
        // The same sources given to bs, which compiles them with upstream's
        // Clang (CSource.zig), the archives too, as libraries of C only.
        for (&archives, [_][]const u8{ "a1", "a2" }) |*a, stem| {
            const lib_c = b.addRunArtifact(bs);
            lib_c.setName(b.fmt("bs build-lib of {s}.c", .{stem}));
            lib_c.addArgs(&.{ "build-lib", "-mcpu", "baseline", "--name", stem });
            lib_c.addFileArg(b.path(b.fmt("test/link_input/{s}.c", .{stem})));
            lib_c.setEnvironmentVariable("BS_ZIG", zig);
            a.* = lib_c.addOutputFileArg2(b.fmt("lib{s}.a", .{stem}), .{ .prefix = "-femit-bin=" });
        }
        // Upstream's archive of the same C is the same bytes, with its own
        // linker (with LLD, it writes llvm-ar's format).
        const up_lib = b.addSystemCommand(&.{ zig, "build-lib", "-fno-llvm", "-fno-lld", "-mcpu", "baseline", "--name", "a1" });
        up_lib.addFileArg(b.path("test/link_input/a1.c"));
        const up_a1 = up_lib.addOutputFileArg2("liba1.a", .{ .prefix = "-femit-bin=" });
        const same = b.addSystemCommand(&.{"cmp"});
        same.setName("bs's archive of C is upstream's");
        same.addFileArg(archives[0]);
        same.addFileArg(up_a1);
        test_step.dependOn(&same.step);
        const src = b.addRunArtifact(bs);
        src.setName("bs build-exe with C sources");
        src.addArgs(&.{ "build-exe", "-cflags", "-fcommon", "--" });
        src.addFileArg(b.path("test/link_input/lib.c"));
        src.addArgs(&.{ "-cflags", "-fPIC", "--" });
        src.addFileArg(b.path("test/link_input/tls.c"));
        src.addFileArg(b.path("test/link_input/tlsie.c"));
        src.addFileArg(b.path("test/link_input/main.zig"));
        for (archives) |input| src.addFileArg(input);
        src.setEnvironmentVariable("BS_ZIG", zig);
        const src_bin = src.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" });
        const src_run = std.Build.Step.Run.create(b, "run bs build of C sources");
        src_run.addFileArg(src_bin);
        src_run.addCheck(.{ .expect_stderr_exact = expect });
        src_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&src_run.step);
    }

    // The same inputs for aarch64-linux, from `zig cc` non-PIC and -fPIC
    // and as sources: the link converts aarch64 relocations and relaxes
    // the TLS descriptor and initial-exec sequences to local-exec.
    if (aarch64LinuxRunner(b)) |runner| for ([_][]const u8{ "", "-fPIC", "sources" }) |v| {
        const what = if (v.len == 0) "objects" else if (v[0] == '-') "-fPIC objects" else "C sources";
        const exe = b.addRunArtifact(bs);
        exe.setName(b.fmt("bs build-exe -target aarch64-linux with {s}", .{what}));
        exe.addArgs(&.{ "build-exe", "-target", "aarch64-linux" });
        exe.addFileArg(b.path("test/link_input/main.zig"));
        exe.setEnvironmentVariable("BS_CACHE", "off");
        exe.setEnvironmentVariable("BS_ZIG", zig);
        const objects = [_][]const u8{ "lib.c", "tls.c", "tlsie.c", "a1.c", "a2.c" };
        for (objects) |src| {
            const flags: []const []const u8 = if (std.mem.eql(u8, src, "lib.c")) &.{"-fcommon"} else if (std.mem.startsWith(u8, src, "tls")) &.{"-fPIC"} else &.{};
            if (std.mem.eql(u8, v, "sources")) {
                exe.addArg("-cflags");
                exe.addArgs(flags);
                exe.addArg("--");
                exe.addFileArg(b.path(b.fmt("test/link_input/{s}", .{src})));
                continue;
            }
            const c = b.addSystemCommand(&.{ zig, "cc", "-target", "aarch64-linux", "-c" });
            if (v.len != 0) c.addArg(v);
            c.addArgs(flags);
            c.addFileArg(b.path(b.fmt("test/link_input/{s}", .{src})));
            const o = c.addOutputFileArg2(b.fmt("{s}.o", .{src}), .{ .prefix = "-o" });
            if (src[0] != 'a') {
                exe.addFileArg(o);
                continue;
            }
            const ar = b.addSystemCommand(&.{ zig, "ar", "rcs" });
            const a = ar.addOutputFileArg2(b.fmt("lib{s}.a", .{src[0..2]}), .{});
            ar.addFileArg(o);
            exe.addFileArg(a);
        }
        const run = std.Build.Step.Run.create(b, b.fmt("run bs aarch64-linux link of {s}", .{what}));
        run.addArgs(runner);
        run.addFileArg(exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
        run.addCheck(.{ .expect_stderr_exact = expect });
        run.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&run.step);
    };

    // A static library and an object of objects alone, as libvaxis's C API
    // step makes one: no Zig root and no C sources. The library holds the
    // objects, the object merges them; upstream links a program with each.
    {
        const lib = b.addRunArtifact(bs);
        lib.setName("bs build-lib -static of objects only");
        lib.addArgs(&.{ "build-lib", "-static", "--name", "a12" });
        const obj_only = b.addRunArtifact(bs);
        obj_only.setName("bs build-obj of objects only");
        obj_only.addArgs(&.{ "build-obj", "--name", "a12" });
        for ([_][]const u8{ "a1", "a2" }) |stem| {
            const o = b.addSystemCommand(&.{ zig, "cc", "-c" });
            o.addFileArg(b.path(b.fmt("test/link_input/{s}.c", .{stem})));
            const o_file = o.addOutputFileArg2(b.fmt("{s}.o", .{stem}), .{ .prefix = "-o" });
            lib.addFileArg(o_file);
            obj_only.addFileArg(o_file);
        }
        const outputs = [_]std.Build.LazyPath{
            lib.addOutputFileArg2("liba12.a", .{ .prefix = "-femit-bin=" }),
            obj_only.addOutputFileArg2("a12.o", .{ .prefix = "-femit-bin=" }),
        };
        for (outputs, [_][]const u8{ "library", "object" }) |out, what| {
            const exe = b.addSystemCommand(&.{ zig, "build-exe" });
            exe.addFileArg(b.path("test/link_input/a12_main.zig"));
            exe.addFileArg(out);
            const r = std.Build.Step.Run.create(b, b.fmt("run upstream's link of bs's {s} of objects only", .{what}));
            r.addFileArg(exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
            r.addCheck(.{ .expect_stderr_exact = "12\n" });
            r.addCheck(.{ .expect_term = .{ .exited = 0 } });
            test_step.dependOn(&r.step);
        }
    }

    // A C object calling glibc, in a -lc executable: its calls go through
    // stubs, its GOT loads through the imports' slots. Upstream compiles
    // C as -fPIC under -lc.
    const c = b.addSystemCommand(&.{ zig, "cc", "-fPIC", "-c" });
    c.addFileArg(b.path("test/link_input/libc.c"));
    const libc_o = c.addOutputFileArg2("libc.o", .{ .prefix = "-o" });
    const exe = b.addRunArtifact(bs);
    exe.setName("bs build-exe -lc with a C object");
    exe.addArgs(&.{ "build-exe", "-lc", "-target", "x86_64-linux-gnu" });
    exe.addFileArg(b.path("test/link_input/libc_main.zig"));
    exe.addFileArg(libc_o);
    exe.setEnvironmentVariable("BS_CACHE", "off");
    exe.setEnvironmentVariable("BS_ZIG", zig);
    const run = std.Build.Step.Run.create(b, "run bs -lc link of a C object");
    run.addFileArg(exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
    run.addCheck(.{ .expect_stdout_exact = "x=21 twice=42 len=3\nbye from atexit\nbye\n" });
    run.addCheck(.{ .expect_stderr_exact = "1 123\n" });
    run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&run.step);
    // The same C as a source of a -lc build, compiled by bs with upstream's
    // Clang and its Debug defaults (ubsan, PIC).
    const src_exe = b.addRunArtifact(bs);
    src_exe.setName("bs build-exe -lc with a C source");
    src_exe.addArgs(&.{ "build-exe", "-lc", "-target", "x86_64-linux-gnu" });
    src_exe.addFileArg(b.path("test/link_input/libc_main.zig"));
    src_exe.addFileArg(b.path("test/link_input/libc.c"));
    src_exe.setEnvironmentVariable("BS_ZIG", zig);
    const src_run = std.Build.Step.Run.create(b, "run bs -lc build of a C source");
    src_run.addFileArg(src_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
    src_run.addCheck(.{ .expect_stdout_exact = "x=21 twice=42 len=3\nbye from atexit\nbye\n" });
    src_run.addCheck(.{ .expect_stderr_exact = "1 123\n" });
    src_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&src_run.step);
    // An Objective-C source, which goes to upstream's Clang like C (as
    // upstream, it builds on Linux when it needs no runtime).
    const objc_exe = b.addRunArtifact(bs);
    objc_exe.setName("bs build-exe -lc with an Objective-C source");
    objc_exe.addArgs(&.{ "build-exe", "-lc", "-target", "x86_64-linux-gnu" });
    objc_exe.addFileArg(b.path("test/link_input/objc_main.zig"));
    objc_exe.addFileArg(b.path("test/link_input/objc.m"));
    objc_exe.setEnvironmentVariable("BS_ZIG", zig);
    const objc_run = std.Build.Step.Run.create(b, "run bs -lc build of an Objective-C source");
    objc_run.addFileArg(objc_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
    objc_run.addCheck(.{ .expect_term = .{ .exited = 3 } });
    test_step.dependOn(&objc_run.step);
    // A C source's strong definition replaces a weak export of the Zig
    // code, for the Zig code's references too, as in ld.
    const wdef_exe = b.addRunArtifact(bs);
    wdef_exe.setName("bs build-exe with a C definition over a weak Zig export");
    wdef_exe.addArg("build-exe");
    wdef_exe.addFileArg(b.path("test/link_input/weak_export_main.zig"));
    wdef_exe.addFileArg(b.path("test/link_input/weak_export.c"));
    wdef_exe.setEnvironmentVariable("BS_ZIG", zig);
    const wdef_run = std.Build.Step.Run.create(b, "run bs build with a C definition over a weak Zig export");
    wdef_run.addFileArg(wdef_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
    wdef_run.addCheck(.{ .expect_stderr_exact = "2 20\n" });
    wdef_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&wdef_run.step);
    // musl, linked statically from libc.a and crt1.o that bs builds from
    // the zig lib directory's sources with upstream's Clang: the same C
    // source, an executable of C only, and C++ with -lc++, on x86_64 and
    // under qemu on aarch64.
    for ([_]?[]const []const u8{ &.{}, aarch64LinuxRunner(b) }, [_][]const u8{ "x86_64", "aarch64" }) |runner_opt, arch| {
        const runner = runner_opt orelse continue;
        const target = b.fmt("{s}-linux-musl", .{arch});
        const cases = [_]struct { what: []const u8, lib: []const u8, files: []const []const u8, args: []const []const u8 = &.{}, stdout: []const u8, stderr: []const u8 = "", code: u8 = 0 }{
            .{ .what = "a C source", .lib = "-lc", .files = &.{ "libc_main.zig", "libc.c" }, .stdout = "x=21 twice=42 len=3\nbye from atexit\nbye\n", .stderr = "1 123\n" },
            .{ .what = "only C sources", .lib = "-lc", .files = &.{"cmain.c"}, .args = &.{"5"}, .stdout = "argc=2 q=478165905515354922\n", .code = 7 },
            .{ .what = "a C++ source", .lib = "-lc++", .files = &.{ "cxx_main.zig", "cxx.cpp" }, .stdout = "caught: boom at depth 4\ntype: 7Derived\nctor 42, tls tls42!, sum 6\n", .stderr = "result 151, link_libcpp true\n" },
        };
        // The first builds libc.a, which the others reuse.
        var first: ?*std.Build.Step = null;
        for (cases) |case| {
            const m_exe = b.addRunArtifact(bs);
            m_exe.setName(b.fmt("bs build-exe {s} -target {s} with {s}", .{ case.lib, target, case.what }));
            m_exe.addArgs(&.{ "build-exe", case.lib, "-target", target });
            for (case.files) |f| m_exe.addFileArg(b.path(b.fmt("test/link_input/{s}", .{f})));
            m_exe.setEnvironmentVariable("BS_ZIG", zig);
            // With a cold global cache, libc.a's thousand sources.
            takes(b, &m_exe.step, 40);
            if (first) |f| m_exe.step.dependOn(f) else first = &m_exe.step;
            const m_run = std.Build.Step.Run.create(b, b.fmt("run bs {s} {s} build with {s}", .{ target, case.lib, case.what }));
            m_run.addArgs(runner);
            m_run.addFileArg(m_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
            m_run.addArgs(case.args);
            m_run.addCheck(.{ .expect_stdout_exact = case.stdout });
            m_run.addCheck(.{ .expect_stderr_exact = case.stderr });
            m_run.addCheck(.{ .expect_term = .{ .exited = case.code } });
            test_step.dependOn(&m_run.step);
        }
    }
    // C command lines: flags that upstream 0.17.1's `--verbose-cc` passes
    // for the same build, in its order. Fresh caches, so that every
    // source (the runtime libraries' too) compiles and prints.
    const cc_cases = [_]struct { what: []const u8, args: []const []const u8, flags: []const []const u8 }{
        // ReleaseSafe: UBSan traps, and the stack protector of the LLVM
        // backend upstream compiles release builds' Zig code with.
        .{ .what = "-OReleaseSafe", .args = &.{ "-target", "x86_64-linux-gnu", "-OReleaseSafe" }, .flags = &.{ "libc.c ", " -fsanitize=undefined -fsanitize-trap=undefined -fno-sanitize=function ", " -fstack-protector-strong --param ssp-buffer-size=4 " } },
        // aarch64-linux, whose Zig code upstream compiles with LLVM.
        .{ .what = "-target aarch64-linux-gnu", .args = &.{ "-target", "aarch64-linux-gnu" }, .flags = &.{ "libc.c ", " -fstack-protector-strong --param ssp-buffer-size=4 " } },
        // libc_nonshared.a: glibc's x86 headers, and sections.
        .{ .what = "-target x86_64-linux-gnu", .args = &.{ "-target", "x86_64-linux-gnu" }, .flags = &.{ "libc/glibc/stdlib/atexit.c ", " -ffunction-sections -fdata-sections ", "/libc/include/x86-linux-gnu ", "/libc/include/x86-linux-any " } },
    };
    for (cc_cases) |case| {
        const vcc = b.addRunArtifact(bs);
        vcc.setName(b.fmt("bs --verbose-cc -lc {s} passes upstream's C flags", .{case.what}));
        vcc.addArgs(&.{ "build-exe", "-lc", "--verbose-cc" });
        vcc.addArgs(case.args);
        vcc.addFileArg(b.path("test/link_input/libc_main.zig"));
        vcc.addFileArg(b.path("test/link_input/libc.c"));
        _ = vcc.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" });
        vcc.addArg("--cache-dir");
        _ = vcc.addOutputDirectoryArg("local");
        vcc.addArg("--global-cache-dir");
        _ = vcc.addOutputDirectoryArg("global");
        vcc.setEnvironmentVariable("BS_ZIG", zig);
        for (case.flags) |f| vcc.addCheck(.{ .expect_stderr_match = f });
        vcc.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&vcc.step);
    }
    // The same for aarch64-linux-gnu, as an -fPIC object and a source, and
    // an executable of C only, run under qemu with aarch64 glibc.
    if (aarch64LinuxGlibcRunner(b)) |runner| {
        const a64c = b.addSystemCommand(&.{ zig, "cc", "-target", "aarch64-linux-gnu", "-fPIC", "-c" });
        a64c.addFileArg(b.path("test/link_input/libc.c"));
        const a64_o = a64c.addOutputFileArg2("libc.o", .{ .prefix = "-o" });
        for ([_]bool{ false, true }) |source| {
            const what = if (source) "a C source" else "a C object";
            const a64_exe = b.addRunArtifact(bs);
            a64_exe.setName(b.fmt("bs build-exe -lc -target aarch64-linux-gnu with {s}", .{what}));
            a64_exe.addArgs(&.{ "build-exe", "-lc", "-target", "aarch64-linux-gnu" });
            a64_exe.addFileArg(b.path("test/link_input/libc_main.zig"));
            if (source) a64_exe.addFileArg(b.path("test/link_input/libc.c")) else a64_exe.addFileArg(a64_o);
            a64_exe.setEnvironmentVariable("BS_CACHE", "off");
            a64_exe.setEnvironmentVariable("BS_ZIG", zig);
            const a64_run = std.Build.Step.Run.create(b, b.fmt("run bs aarch64-linux -lc link of {s}", .{what}));
            a64_run.addArgs(runner);
            a64_run.addFileArg(a64_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
            a64_run.addCheck(.{ .expect_stdout_exact = "x=21 twice=42 len=3\nbye from atexit\nbye\n" });
            a64_run.addCheck(.{ .expect_stderr_exact = "1 123\n" });
            a64_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
            test_step.dependOn(&a64_run.step);
        }
        const a64_cexe = b.addRunArtifact(bs);
        a64_cexe.setName("bs build-exe -lc -target aarch64-linux-gnu with only C sources");
        a64_cexe.addArgs(&.{ "build-exe", "-lc", "-target", "aarch64-linux-gnu" });
        a64_cexe.addFileArg(b.path("test/link_input/cmain.c"));
        a64_cexe.setEnvironmentVariable("BS_ZIG", zig);
        const a64_cexe_run = std.Build.Step.Run.create(b, "run bs aarch64-linux -lc build of only C sources");
        a64_cexe_run.addArgs(runner);
        a64_cexe_run.addFileArg(a64_cexe.addOutputFileArg2("cmain", .{ .prefix = "-femit-bin=" }));
        a64_cexe_run.addArg("5");
        a64_cexe_run.addCheck(.{ .expect_stdout_exact = "argc=2 q=478165905515354922\n" });
        a64_cexe_run.addCheck(.{ .expect_term = .{ .exited = 7 } });
        test_step.dependOn(&a64_cexe_run.step);
        // A shared library upstream built, which Zig calls and whose data
        // a non-PIC C object copies (R_AARCH64_COPY).
        const so = b.addSystemCommand(&.{ zig, "cc", "-target", "aarch64-linux-gnu", "-shared", "-fPIC" });
        so.addFileArg(b.path("test/link_input/shared.c"));
        so.addPrefixedFileArg("-Wl,--version-script=", b.path("test/link_input/shared.map"));
        so.addArg("-Wl,-soname,libshared.so");
        const lib_dir = so.addOutputFileArg2("libshared.so", .{ .prefix = "-o" }).dirname();
        const user = b.addSystemCommand(&.{ zig, "cc", "-target", "aarch64-linux-gnu", "-c" });
        user.addFileArg(b.path("test/link_input/shared_user.c"));
        const so_exe = b.addRunArtifact(bs);
        so_exe.setName("bs build-exe -lc -target aarch64-linux-gnu with a shared library");
        so_exe.addArgs(&.{ "build-exe", "-lc", "-target", "aarch64-linux-gnu", "-lshared" });
        so_exe.addDirectoryArg2(lib_dir, .{ .prefix = "-L" });
        so_exe.addFileArg(b.path("test/link_input/shared_main.zig"));
        so_exe.addFileArg(user.addOutputFileArg2("shared_user.o", .{ .prefix = "-o" }));
        so_exe.setEnvironmentVariable("BS_CACHE", "off");
        // The loader under qemu finds the library through the emulated
        // program's LD_LIBRARY_PATH (QEMU_SET_ENV); a cross build has no
        // DT_RUNPATH, as upstream's.
        const so_run = b.addSystemCommand(&.{ "sh", "-c", "d=$1; shift; LD_LIBRARY_PATH=$d QEMU_SET_ENV=LD_LIBRARY_PATH=$d exec \"$@\"", "sh" });
        so_run.setName("run bs aarch64-linux link of a shared library");
        so_run.addDirectoryArg2(lib_dir, .{});
        so_run.addArgs(runner);
        so_run.addFileArg(so_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
        so_run.addCheck(.{ .expect_stderr_exact = "42 143 42 143\n" });
        so_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&so_run.step);
        // A shared library's thread-local from Zig and from C's TLS
        // descriptors (aarch64's general-dynamic) and initial-exec code,
        // through one slot the loader writes (R_AARCH64_TLS_TPREL64).
        const tls_so = b.addSystemCommand(&.{ zig, "cc", "-target", "aarch64-linux-gnu", "-shared", "-fPIC", "-Wl,-soname,libsotls.so" });
        tls_so.addFileArg(b.path("test/link_input/so_tls.c"));
        const tls_dir = tls_so.addOutputFileArg2("libsotls.so", .{ .prefix = "-o" }).dirname();
        const tls_exe = b.addRunArtifact(bs);
        tls_exe.setName("bs build-exe -lc -target aarch64-linux-gnu with a shared library's thread-local");
        tls_exe.addArgs(&.{ "build-exe", "-lc", "-target", "aarch64-linux-gnu", "-lsotls" });
        tls_exe.addDirectoryArg2(tls_dir, .{ .prefix = "-L" });
        tls_exe.addFileArg(b.path("test/link_input/so_tls_main.zig"));
        for ([_][]const []const u8{ &.{ "-fPIC", "-DSUFFIX=_gd" }, &.{ "-fPIC", "-DSUFFIX=_desc" }, &.{ "-fPIC", "-ftls-model=initial-exec", "-DSUFFIX=_ie" } }, [_][]const u8{ "gd", "desc", "ie" }) |flags, name| {
            const tls_user = b.addSystemCommand(&.{ zig, "cc", "-target", "aarch64-linux-gnu", "-c" });
            tls_user.addArgs(flags);
            tls_user.addFileArg(b.path("test/link_input/so_tls_user.c"));
            tls_exe.addFileArg(tls_user.addOutputFileArg2(b.fmt("so_tls_{s}.o", .{name}), .{ .prefix = "-o" }));
        }
        tls_exe.setEnvironmentVariable("BS_CACHE", "off");
        const tls_run = b.addSystemCommand(&.{ "sh", "-c", "d=$1; shift; LD_LIBRARY_PATH=$d QEMU_SET_ENV=LD_LIBRARY_PATH=$d exec \"$@\"", "sh" });
        tls_run.setName("run bs aarch64-linux link of a shared library's thread-local");
        tls_run.addDirectoryArg2(tls_dir, .{});
        tls_run.addArgs(runner);
        tls_run.addFileArg(tls_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
        tls_run.addCheck(.{ .expect_stderr_exact = "main: 3 3 3 3 103\nset: 1114 1114 1114 1114 1214\nthread: 3 3 3 3 103\nafter: 1114 1114 1114 1114 1214\n" });
        tls_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&tls_run.step);
        // GNU indirect functions: their slots (R_AARCH64_IRELATIVE) and
        // stubs.
        const ifunc_c = b.addSystemCommand(&.{ zig, "cc", "-target", "aarch64-linux-gnu", "-fPIC", "-c" });
        ifunc_c.addFileArg(b.path("test/link_input/ifunc.c"));
        const ifunc_exe = b.addRunArtifact(bs);
        ifunc_exe.setName("bs build-exe -lc -target aarch64-linux-gnu with GNU indirect functions");
        ifunc_exe.addArgs(&.{ "build-exe", "-lc", "-target", "aarch64-linux-gnu" });
        ifunc_exe.addFileArg(b.path("test/link_input/ifunc_main.zig"));
        ifunc_exe.addFileArg(ifunc_c.addOutputFileArg2("ifunc.o", .{ .prefix = "-o" }));
        ifunc_exe.setEnvironmentVariable("BS_CACHE", "off");
        const ifunc_run = std.Build.Step.Run.create(b, "run bs aarch64-linux link of GNU indirect functions");
        ifunc_run.addArgs(runner);
        ifunc_run.addFileArg(ifunc_exe.addOutputFileArg2("ifunc", .{ .prefix = "-femit-bin=" }));
        ifunc_run.addCheck(.{ .expect_stderr_exact = "42 42 6 15 9 true true\n" });
        ifunc_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&ifunc_run.step);
        // Weak references nothing defines, imported so that a library
        // preloaded at run time defines them (QEMU_SET_ENV sets the
        // emulated program's LD_PRELOAD).
        const wexe = b.addRunArtifact(bs);
        wexe.setName("bs build-exe -lc -target aarch64-linux-gnu with weak references nothing defines");
        wexe.addArgs(&.{ "build-exe", "-lc", "-target", "aarch64-linux-gnu" });
        wexe.addFileArg(b.path("test/link_input/weak_main.c"));
        wexe.setEnvironmentVariable("BS_ZIG", zig);
        const weak_exe = wexe.addOutputFileArg2("weak_main", .{ .prefix = "-femit-bin=" });
        const plain = std.Build.Step.Run.create(b, "run weak_main (aarch64-linux)");
        plain.addArgs(runner);
        plain.addFileArg(weak_exe);
        plain.addCheck(.{ .expect_stdout_exact = "fn=-1 data=-1 ptr=0\n" });
        test_step.dependOn(&plain.step);
        const def = b.addSystemCommand(&.{ zig, "cc", "-target", "aarch64-linux-gnu", "-shared", "-fPIC" });
        def.addFileArg(b.path("test/link_input/weak_def.c"));
        const preload = b.addSystemCommand(&.{ "sh", "-c", "p=$1; shift; LD_PRELOAD=$p QEMU_SET_ENV=LD_PRELOAD=$p exec \"$@\"", "sh" });
        preload.setName("run weak_main with weak_def preloaded (aarch64-linux)");
        preload.addFileArg(def.addOutputFileArg2("libweak_def.so", .{ .prefix = "-o" }));
        preload.addArgs(runner);
        preload.addFileArg(weak_exe);
        preload.addCheck(.{ .expect_stdout_exact = "fn=42 data=7 ptr=0\n" });
        test_step.dependOn(&preload.step);
        // A C++ source with -lc++: libc++, libc++abi and libunwind built
        // from the zig lib directory for aarch64-linux-gnu; exceptions
        // unwind through libunwind (.eh_frame's and .gcc_except_table's
        // R_AARCH64_PREL64).
        const cxx_exe = b.addRunArtifact(bs);
        cxx_exe.setName("bs build-exe -lc++ -target aarch64-linux-gnu with a C++ source");
        takes(b, &cxx_exe.step, 40);
        cxx_exe.addArgs(&.{ "build-exe", "-lc++", "-target", "aarch64-linux-gnu" });
        cxx_exe.addFileArg(b.path("test/link_input/cxx_main.zig"));
        cxx_exe.addFileArg(b.path("test/link_input/cxx.cpp"));
        cxx_exe.setEnvironmentVariable("BS_ZIG", zig);
        const cxx_run = std.Build.Step.Run.create(b, "run bs aarch64-linux -lc++ build of a C++ source");
        cxx_run.addArgs(runner);
        cxx_run.addFileArg(cxx_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
        cxx_run.addCheck(.{ .expect_stdout_exact = "caught: boom at depth 4\ntype: 7Derived\nctor 42, tls tls42!, sum 6\n" });
        cxx_run.addCheck(.{ .expect_stderr_exact = "result 151, link_libcpp true\n" });
        cxx_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&cxx_run.step);
        addAarch64LinuxSharedTests(b, bs, test_step, runner, &cxx_exe.step);
    }
    // Thread-locals through TLS descriptors (-mtls-dialect=gnu2), which
    // the link relaxes to local-exec: Clang's, with _TLS_MODULE_BASE_
    // (upstream's own linker cannot link those; LLD's output prints the
    // same), and GCC's, static and with -lc.
    {
        const expect_tls = "main: 507 9 5 9 true\nset: 2121 31 21 31 true\nthread: 507 9 5 9 true\nafter: 2121 31 21 31 true\n";
        const tls_variants = [_]struct { name: []const u8, cc: []const []const u8, lc: bool }{
            .{ .name = "zig cc", .cc = &.{ zig, "cc" }, .lc = false },
            .{ .name = "cc -fPIC", .cc = &.{ cc orelse "", "-fPIC" }, .lc = false },
            .{ .name = "cc -fPIC", .cc = &.{ cc orelse "", "-fPIC" }, .lc = true },
        };
        for (tls_variants) |v| {
            if (v.cc[0].len == 0) continue;
            const obj = b.addSystemCommand(v.cc);
            obj.addArgs(&.{ "-mtls-dialect=gnu2", "-c" });
            obj.addFileArg(b.path("test/link_input/tlsdesc.c"));
            const tls_exe = b.addRunArtifact(bs);
            tls_exe.setName(b.fmt("bs build-exe{s} with a {s} -mtls-dialect=gnu2 object", .{ if (v.lc) " -lc" else "", v.name }));
            tls_exe.addArg("build-exe");
            if (v.lc) tls_exe.addArgs(&.{ "-lc", "-target", "x86_64-linux-gnu" });
            tls_exe.addFileArg(b.path("test/link_input/tlsdesc_main.zig"));
            tls_exe.addFileArg(obj.addOutputFileArg2("tlsdesc.o", .{ .prefix = "-o" }));
            tls_exe.setEnvironmentVariable("BS_CACHE", "off");
            const tls_run = std.Build.Step.Run.create(b, b.fmt("run bs{s} link of a {s} -mtls-dialect=gnu2 object", .{ if (v.lc) " -lc" else "", v.name }));
            tls_run.addFileArg(tls_exe.addOutputFileArg2("tlsdesc", .{ .prefix = "-femit-bin=" }));
            tls_run.addCheck(.{ .expect_stderr_exact = expect_tls });
            tls_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
            test_step.dependOn(&tls_run.step);
        }
    }
    // build-obj with a C source and a C object: one merged object
    // (link/ElfMerge.zig), which upstream's linker and bs's link as
    // upstream's own merged object links. Then C++ objects whose COMDAT
    // groups repeat, merged with the second copies dropped, and linked by
    // upstream's `zig c++`: exceptions still unwind through them.
    {
        const tls_o = b.addSystemCommand(&.{ zig, "cc", "-fPIC", "-c" });
        tls_o.addFileArg(b.path("test/link_input/tls.c"));
        const merge = b.addRunArtifact(bs);
        merge.setName("bs build-obj with a C source and a C object");
        merge.addArg("build-obj");
        merge.addFileArg(b.path("test/link_input/merge_lib.zig"));
        merge.addFileArg(b.path("test/link_input/merge.c"));
        merge.addFileArg(tls_o.addOutputFileArg2("tls.o", .{ .prefix = "-o" }));
        merge.setEnvironmentVariable("BS_CACHE", "off");
        merge.setEnvironmentVariable("BS_ZIG", zig);
        const merged = merge.addOutputFileArg2("merged.o", .{ .prefix = "-femit-bin=" });
        const up_exe = b.addSystemCommand(&.{ zig, "build-exe" });
        up_exe.addFileArg(b.path("test/link_input/merge_main.zig"));
        up_exe.addFileArg(merged);
        const bs_exe = b.addRunArtifact(bs);
        bs_exe.addArg("build-exe");
        bs_exe.addFileArg(b.path("test/link_input/merge_main.zig"));
        bs_exe.addFileArg(merged);
        bs_exe.setEnvironmentVariable("BS_CACHE", "off");
        for ([_]*std.Build.Step.Run{ up_exe, bs_exe }, [_][]const u8{ "upstream's", "bs's" }) |link, who| {
            const r = std.Build.Step.Run.create(b, b.fmt("run {s} link of bs's merged object", .{who}));
            r.addFileArg(link.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
            r.addCheck(.{ .expect_stderr_exact = "44 bee 6 712\n" });
            r.addCheck(.{ .expect_term = .{ .exited = 0 } });
            test_step.dependOn(&r.step);
        }
        const cxx = b.addRunArtifact(bs);
        cxx.setName("bs build-obj with C++ objects");
        cxx.addArg("build-obj");
        cxx.addFileArg(b.path("test/link_input/merge_lib.zig"));
        cxx.addFileArg(b.path("test/link_input/merge.c"));
        for ([_][]const u8{ "merge1", "merge2" }) |stem| {
            const o = b.addSystemCommand(&.{ zig, "c++", "-c" });
            o.addFileArg(b.path(b.fmt("test/link_input/{s}.cpp", .{stem})));
            cxx.addFileArg(o.addOutputFileArg2(b.fmt("{s}.o", .{stem}), .{ .prefix = "-o" }));
        }
        cxx.setEnvironmentVariable("BS_CACHE", "off");
        cxx.setEnvironmentVariable("BS_ZIG", zig);
        const cxx_link = b.addSystemCommand(&.{ zig, "c++" });
        cxx_link.addFileArg(cxx.addOutputFileArg2("merged.o", .{ .prefix = "-femit-bin=" }));
        const r = std.Build.Step.Run.create(b, "run upstream's link of bs's merged C++ object");
        r.addFileArg(cxx_link.addOutputFileArg2("main", .{ .prefix = "-o" }));
        r.addCheck(.{ .expect_stdout_exact = "caught neg\n10 8 1 4\n" });
        r.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&r.step);
    }
    // build-lib -dynamic with a C source, a C object (general- and
    // local-dynamic TLS) and an archive (TLS descriptors when GCC builds
    // it), linked into one shared library as upstream links them, which
    // exports the C globals; upstream links a program against it.
    {
        const tls_o = b.addSystemCommand(&.{ zig, "cc", "-fPIC", "-c" });
        tls_o.addFileArg(b.path("test/link_input/tls.c"));
        const desc_o = b.addSystemCommand(if (cc) |gcc| &.{ gcc, "-fPIC", "-mtls-dialect=gnu2", "-c" } else &.{ zig, "cc", "-fPIC", "-c" });
        desc_o.addFileArg(b.path("test/link_input/so_desc.c"));
        const desc_a = b.addSystemCommand(&.{ zig, "ar", "rcs" });
        const desc_lib = desc_a.addOutputFileArg2("libdesc.a", .{});
        desc_a.addFileArg(desc_o.addOutputFileArg2("so_desc.o", .{ .prefix = "-o" }));
        const zso_inputs = b.addRunArtifact(bs);
        zso_inputs.setName("bs build-lib -dynamic with a C source, a C object and an archive");
        zso_inputs.addArgs(&.{ "build-lib", "-dynamic", "--name", "bsinputs" });
        zso_inputs.addFileArg(b.path("test/link_input/so_lib.zig"));
        zso_inputs.addFileArg(b.path("test/link_input/merge.c"));
        zso_inputs.addFileArg(b.path("test/link_input/so_interpose.c"));
        zso_inputs.addFileArg(b.path("test/link_input/so_hidref.c"));
        zso_inputs.addFileArg(tls_o.addOutputFileArg2("tls.o", .{ .prefix = "-o" }));
        zso_inputs.addFileArg(desc_lib);
        zso_inputs.setEnvironmentVariable("BS_ZIG", zig);
        const so_file = zso_inputs.addOutputFileArg2("libbsinputs.so", .{ .prefix = "-femit-bin=" });
        const so_host = b.addSystemCommand(&.{ zig, "build-exe", "-lc" });
        so_host.addFileArg(b.path("test/link_input/so_main.zig"));
        so_host.addFileArg(so_file);
        const r = b.addSystemCommand(&.{ "sh", "-c", "LD_LIBRARY_PATH=$(dirname \"$1\") exec \"$2\"", "sh" });
        r.setName("run so_main (bs shared library with inputs)");
        r.addFileArg(so_file);
        r.addFileArg(so_host.addOutputFileArg2("so_main", .{ .prefix = "-femit-bin=" }));
        r.addCheck(.{ .expect_stderr_exact = "44 bee 6 712 810\nthread: 712 810\n" });
        r.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&r.step);
        // An executable that defines the library's exported thread-locals
        // preempts them.
        const preempt_host = b.addSystemCommand(&.{ zig, "cc" });
        preempt_host.addFileArg(b.path("test/link_input/so_preempt.c"));
        preempt_host.addFileArg(so_file);
        const preempt = b.addSystemCommand(&.{ "sh", "-c", "LD_LIBRARY_PATH=$(dirname \"$1\") exec \"$2\"", "sh" });
        preempt.setName("run so_preempt (thread-locals, functions and data preempting a bs shared library's)");
        preempt.addFileArg(so_file);
        preempt.addFileArg(preempt_host.addOutputFileArg2("so_preempt", .{ .prefix = "-o" }));
        preempt.addCheck(.{ .expect_stdout_exact = "100012 200310 1000 2003\n32 1 202 4\n" });
        preempt.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&preempt.step);
    }
    // An executable of C only, as upstream builds one: its main is C's.
    // It links against glibc 2.12, which lacks functions std's I/O calls:
    // without UBSan, std's panic handler and its I/O stay out, as
    // upstream's crt1.o has none, and with it std's I/O has networking
    // off, as upstream's ubsan_rt.
    for ([_][]const []const u8{ &.{"x86_64-linux-gnu"}, &.{ "x86_64-linux-gnu.2.12", "-fno-sanitize-c" }, &.{"x86_64-linux-gnu.2.12"} }) |args| {
        const cexe = b.addRunArtifact(bs);
        const label = std.mem.join(b.allocator, " ", args) catch @panic("OOM");
        cexe.setName(b.fmt("bs build-exe -lc with only C sources ({s})", .{label}));
        cexe.addArgs(&.{ "build-exe", "-lc", "-target" });
        cexe.addArgs(args);
        cexe.addFileArg(b.path("test/link_input/cmain.c"));
        cexe.setEnvironmentVariable("BS_ZIG", zig);
        const cexe_run = std.Build.Step.Run.create(b, b.fmt("run bs -lc build of only C sources ({s})", .{label}));
        cexe_run.addFileArg(cexe.addOutputFileArg2("cmain", .{ .prefix = "-femit-bin=" }));
        cexe_run.addArg("5");
        cexe_run.addCheck(.{ .expect_stdout_exact = "argc=2 q=478165905515354922\n" });
        cexe_run.addCheck(.{ .expect_term = .{ .exited = 7 } });
        test_step.dependOn(&cexe_run.step);
    }
    // C only with -fsanitize-c=full that calls no `__ubsan_*` handler: no
    // ubsan_rt and no std panic handler, so it links against glibc 2.4,
    // which lacks functions std's I/O calls.
    {
        const nexe = b.addRunArtifact(bs);
        nexe.setName("bs build-exe -lc c_nocheck.c (x86_64-linux-gnu.2.4)");
        nexe.addArgs(&.{ "build-exe", "-lc", "-target", "x86_64-linux-gnu.2.4" });
        nexe.addFileArg(b.path("test/link_input/c_nocheck.c"));
        nexe.setEnvironmentVariable("BS_ZIG", zig);
        const r = std.Build.Step.Run.create(b, "run bs -lc build of c_nocheck.c (x86_64-linux-gnu.2.4)");
        r.addFileArg(nexe.addOutputFileArg2("c_nocheck", .{ .prefix = "-femit-bin=" }));
        r.addCheck(.{ .expect_stdout_exact = "no checks\n" });
        r.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&r.step);
    }
    // Which memcmp C only calls: glibc's (interposable) without UBSan's
    // runtime, compiler_rt's with it, as upstream's compiler_rt archive
    // after libc resolves only names libc lacks unless ubsan_rt pulls it.
    {
        const preload = b.addSystemCommand(&.{ zig, "cc", "-shared", "-fPIC" });
        preload.addFileArg(b.path("test/link_input/plain_c_preload.c"));
        const preload_so = preload.addOutputFileArg2("libplain_preload.so", .{ .prefix = "-o" });
        for ([_]struct { flag: []const u8, out: []const u8 }{ .{ .flag = "-fsanitize-c", .out = "0\n" }, .{ .flag = "-fno-sanitize-c", .out = "42\n" } }) |v| {
            const pexe = b.addRunArtifact(bs);
            pexe.setName(b.fmt("bs build-exe -lc {s} plain_c.c", .{v.flag}));
            pexe.addArgs(&.{ "build-exe", "-lc", "-target", "x86_64-linux-gnu", v.flag });
            pexe.addFileArg(b.path("test/link_input/plain_c.c"));
            pexe.setEnvironmentVariable("BS_ZIG", zig);
            const r = b.addSystemCommand(&.{ "sh", "-c", "LD_PRELOAD=\"$1\" exec \"$2\"", "sh" });
            r.setName(b.fmt("run plain_c ({s}) with a preloaded memcmp", .{v.flag}));
            r.addFileArg(preload_so);
            r.addFileArg(pexe.addOutputFileArg2("plain_c", .{ .prefix = "-femit-bin=" }));
            r.addCheck(.{ .expect_stdout_exact = v.out });
            r.addCheck(.{ .expect_term = .{ .exited = 0 } });
            test_step.dependOn(&r.step);
        }
    }
    // A Zig executable calling libc_nonshared.a's functions: atexit, and
    // stat and fstatat, which glibc before 2.33 has only there.
    {
        const nexe = b.addRunArtifact(bs);
        nexe.setName("bs build-exe -lc calling libc_nonshared.a from Zig");
        nexe.addArgs(&.{ "build-exe", "-lc", "-target", "x86_64-linux-gnu.2.17" });
        nexe.addFileArg(b.path("test/link_input/nonshared_main.zig"));
        nexe.setEnvironmentVariable("BS_ZIG", zig);
        const nexe_run = std.Build.Step.Run.create(b, "run bs -lc build calling libc_nonshared.a from Zig");
        nexe_run.addFileArg(nexe.addOutputFileArg2("nonshared", .{ .prefix = "-femit-bin=" }));
        nexe_run.addCheck(.{ .expect_stdout_exact = "stat -1 -1\nbye\n" });
        nexe_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&nexe_run.step);
    }
    // A C-only executable's weak references to names nothing defines,
    // which a library preloaded at run time defines.
    {
        const wexe = b.addRunArtifact(bs);
        wexe.setName("bs build-exe -lc with weak references nothing defines");
        wexe.addArgs(&.{ "build-exe", "-lc", "-target", "x86_64-linux-gnu" });
        wexe.addFileArg(b.path("test/link_input/weak_main.c"));
        wexe.setEnvironmentVariable("BS_ZIG", zig);
        const weak_exe = wexe.addOutputFileArg2("weak_main", .{ .prefix = "-femit-bin=" });
        const plain = std.Build.Step.Run.create(b, "run weak_main");
        plain.addFileArg(weak_exe);
        plain.addCheck(.{ .expect_stdout_exact = "fn=-1 data=-1 ptr=0\n" });
        test_step.dependOn(&plain.step);
        const def = b.addSystemCommand(&.{ zig, "cc", "-shared", "-fPIC" });
        def.addFileArg(b.path("test/link_input/weak_def.c"));
        const preload = b.addSystemCommand(&.{ "sh", "-c", "LD_PRELOAD=\"$1\" exec \"$2\"", "sh" });
        preload.setName("run weak_main with weak_def preloaded");
        preload.addFileArg(def.addOutputFileArg2("libweak_def.so", .{ .prefix = "-o" }));
        preload.addFileArg(weak_exe);
        preload.addCheck(.{ .expect_stdout_exact = "fn=42 data=7 ptr=0\n" });
        test_step.dependOn(&preload.step);
    }
    // compiler_rt for C: f128 and f16 conversions, comparisons and
    // arithmetic, 128-bit division, lock-based atomics and the CPU model
    // of function multiversioning (data as well as functions), which bs
    // generates from upstream's compiler_rt (baseline, so that f16 needs
    // it too). Two more objects reference a name nothing defines: one
    // error names both.
    {
        const rt_c = b.addSystemCommand(&.{ zig, "cc", "-mcpu=baseline", "-Wno-atomic-alignment", "-c" });
        rt_c.addFileArg(b.path("test/link_input/rt.c"));
        const rt_o = rt_c.addOutputFileArg2("rt.o", .{ .prefix = "-o" });
        const rt_exe = b.addRunArtifact(bs);
        rt_exe.setName("bs build-exe with a C object calling compiler_rt");
        rt_exe.addArg("build-exe");
        rt_exe.addFileArg(b.path("test/link_input/rt_main.zig"));
        rt_exe.addFileArg(rt_o);
        rt_exe.setEnvironmentVariable("BS_CACHE", "off");
        const rt_run = std.Build.Step.Run.create(b, "run bs link of a C object calling compiler_rt");
        rt_run.addFileArg(rt_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
        rt_run.addCheck(.{ .expect_stderr_exact = "2.25 1 0 -6 0.375 1024 25 2.5 56\n" });
        rt_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&rt_run.step);
        const undef = b.addRunArtifact(bs);
        undef.setName("bs build-exe reports an undefined symbol once");
        undef.addArg("build-exe");
        undef.addFileArg(b.path("test/link_input/rt_main.zig"));
        undef.addFileArg(rt_o);
        for ([_][]const u8{ "undef1", "undef2" }) |name| {
            const u = b.addSystemCommand(&.{ zig, "cc", b.fmt("-DUNDEF={s}", .{name}), "-c" });
            u.addFileArg(b.path("test/link_input/undef.c"));
            undef.addFileArg(u.addOutputFileArg2(b.fmt("{s}.o", .{name}), .{ .prefix = "-o" }));
        }
        undef.setEnvironmentVariable("BS_CACHE", "off");
        _ = undef.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" });
        undef.addCheck(.{ .expect_stderr_match = "undef1.o, " });
        undef.addCheck(.{ .expect_stderr_match = "undef2.o)\n" });
        undef.addCheck(.{ .expect_stderr_match = "\n1 error\n" });
        undef.addCheck(.{ .expect_term = .{ .exited = 1 } });
        test_step.dependOn(&undef.step);
    }
    // GNU indirect functions: through a stub and a slot the loader fills
    // (R_X86_64_IRELATIVE) in an executable linking glibc and in a shared
    // library, as upstream's; refused in a static executable, where
    // nothing would call the resolvers.
    {
        const expect_ifunc = "42 42 6 15 9 true true\n";
        const o = b.addSystemCommand(&.{ zig, "cc", "-fPIC", "-c" });
        o.addFileArg(b.path("test/link_input/ifunc.c"));
        const ifunc_o = o.addOutputFileArg2("ifunc.o", .{ .prefix = "-o" });
        const ifunc_exe = b.addRunArtifact(bs);
        ifunc_exe.setName("bs build-exe -lc with GNU indirect functions");
        ifunc_exe.addArgs(&.{ "build-exe", "-lc", "-target", "x86_64-linux-gnu" });
        ifunc_exe.addFileArg(b.path("test/link_input/ifunc_main.zig"));
        ifunc_exe.addFileArg(ifunc_o);
        ifunc_exe.setEnvironmentVariable("BS_CACHE", "off");
        const ifunc_exe_run = std.Build.Step.Run.create(b, "run bs's link of GNU indirect functions");
        ifunc_exe_run.addFileArg(ifunc_exe.addOutputFileArg2("ifunc", .{ .prefix = "-femit-bin=" }));
        ifunc_exe_run.addCheck(.{ .expect_stderr_exact = expect_ifunc });
        ifunc_exe_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&ifunc_exe_run.step);
        const ifunc_lib = b.addRunArtifact(bs);
        ifunc_lib.setName("bs build-lib -dynamic with GNU indirect functions");
        ifunc_lib.addArgs(&.{ "build-lib", "-dynamic", "--name", "bsifunc" });
        ifunc_lib.addFileArg(b.path("test/link_input/ifunc_lib.zig"));
        ifunc_lib.addFileArg(ifunc_o);
        const ifunc_lib_file = ifunc_lib.addOutputFileArg2("libbsifunc.so", .{ .prefix = "-femit-bin=" });
        const ifunc_lib_host = b.addSystemCommand(&.{ zig, "build-exe", "-lc" });
        ifunc_lib_host.addFileArg(b.path("test/link_input/ifunc_main.zig"));
        ifunc_lib_host.addFileArg(ifunc_lib_file);
        const ifunc_lib_run = b.addSystemCommand(&.{ "sh", "-c", "LD_LIBRARY_PATH=$(dirname \"$1\") exec \"$2\"", "sh" });
        ifunc_lib_run.setName("run ifunc_main (bs shared library with GNU indirect functions)");
        ifunc_lib_run.addFileArg(ifunc_lib_file);
        ifunc_lib_run.addFileArg(ifunc_lib_host.addOutputFileArg2("ifunc_main", .{ .prefix = "-femit-bin=" }));
        ifunc_lib_run.addCheck(.{ .expect_stderr_exact = expect_ifunc });
        ifunc_lib_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&ifunc_lib_run.step);
        const ifunc_static = b.addRunArtifact(bs);
        ifunc_static.setName("bs build-exe refuses GNU indirect functions without libc");
        ifunc_static.addArg("build-exe");
        ifunc_static.addFileArg(b.path("test/link_input/ifunc_main.zig"));
        ifunc_static.addFileArg(ifunc_o);
        ifunc_static.setEnvironmentVariable("BS_CACHE", "off");
        _ = ifunc_static.addOutputFileArg2("ifunc", .{ .prefix = "-femit-bin=" });
        ifunc_static.addCheck(.{ .expect_stderr_match = "ifunc.o: bs links GNU indirect functions (STT_GNU_IFUNC, from __attribute__((ifunc)) or __attribute__((target_clones))) only into executables that link libc and shared libraries, whose loader calls their resolvers: c_triple\n" });
        ifunc_static.addCheck(.{ .expect_term = .{ .exited = 1 } });
        test_step.dependOn(&ifunc_static.step);
    }
    {
        const dead = b.addRunArtifact(bs);
        dead.setName("bs build-exe links the data a discarded load reads");
        dead.addArg("build-exe");
        dead.addFileArg(b.path("test/link_input/dead_load.zig"));
        dead.setEnvironmentVariable("BS_CACHE", "off");
        _ = dead.addOutputFileArg2("dead_load", .{ .prefix = "-femit-bin=" });
        dead.addCheck(.{ .expect_stderr_match = "undefined symbol: nope" });
        dead.addCheck(.{ .expect_term = .{ .exited = 1 } });
        test_step.dependOn(&dead.step);
    }
    // A C++ source with -lc++: libc++, libc++abi and libunwind built from
    // the lib directory as upstream builds them, exceptions through C++
    // frames, RTTI, a static constructor and thread_local.
    const cxx_exe = b.addRunArtifact(bs);
    cxx_exe.setName("bs build-exe -lc++ with a C++ source");
    takes(b, &cxx_exe.step, 40);
    cxx_exe.addArgs(&.{ "build-exe", "-lc++", "-target", "x86_64-linux-gnu" });
    cxx_exe.addFileArg(b.path("test/link_input/cxx_main.zig"));
    cxx_exe.addFileArg(b.path("test/link_input/cxx.cpp"));
    cxx_exe.setEnvironmentVariable("BS_ZIG", zig);
    const cxx_run = std.Build.Step.Run.create(b, "run bs -lc++ build of a C++ source");
    cxx_run.addFileArg(cxx_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
    cxx_run.addCheck(.{ .expect_stdout_exact = "caught: boom at depth 4\ntype: 7Derived\nctor 42, tls tls42!, sum 6\n" });
    cxx_run.addCheck(.{ .expect_stderr_exact = "result 151, link_libcpp true\n" });
    cxx_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&cxx_run.step);
    // A shared library of C++ only, versioned: libc++ is built into it,
    // and the loader finds it by its soname, libsxx.so.1, as upstream's.
    // After the executable, to reuse its libc++: builds that run at once
    // each build a runtime library the global cache lacks.
    const so_cxx = b.addRunArtifact(bs);
    so_cxx.setName("bs build-lib -dynamic -lc++ --version with a C++ source");
    so_cxx.addArgs(&.{ "build-lib", "-dynamic", "-lc++", "-target", "x86_64-linux-gnu", "--name", "sxx", "--version", "1.2.3" });
    so_cxx.addFileArg(b.path("test/link_input/so_cxx.cpp"));
    so_cxx.setEnvironmentVariable("BS_ZIG", zig);
    so_cxx.step.dependOn(&cxx_exe.step);
    const so_cxx_file = so_cxx.addOutputFileArg2("libsxx.so.1.2.3", .{ .prefix = "-femit-bin=" });
    const so_cxx_host = b.addSystemCommand(&.{ zig, "build-exe", "-lc" });
    so_cxx_host.addFileArg(b.path("test/link_input/so_cxx_main.zig"));
    so_cxx_host.addFileArg(so_cxx_file);
    const so_cxx_run = b.addSystemCommand(&.{ "sh", "-c", "d=$(mktemp -d) && cp \"$1\" \"$d/libsxx.so.1\" && LD_LIBRARY_PATH=$d \"$2\"; r=$?; rm -rf \"$d\"; exit $r", "sh" });
    so_cxx_run.setName("run so_cxx_main.zig (bs shared library of C++)");
    so_cxx_run.addFileArg(so_cxx_file);
    so_cxx_run.addFileArg(so_cxx_host.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
    so_cxx_run.addCheck(.{ .expect_stderr_exact = "sxx 6 9\n" });
    so_cxx_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&so_cxx_run.step);

    // translate-c with a system library takes the native include
    // directories (here NIX_CFLAGS_COMPILE's) ahead of the user's
    // -isystem, as upstream's `native_system_include_paths`.
    const tc_native = b.addRunArtifact(bs);
    tc_native.setName("bs translate-c -l<lib> takes the native include directories");
    tc_native.addArgs(&.{ "translate-c", "-lfoo", "-isystem" });
    tc_native.addDirectoryArg2(b.path("test/link_input/tc_native/shadow"), .{});
    tc_native.addFileArg(b.path("test/link_input/tc_native/s.h"));
    tc_native.setCwd(b.path("."));
    tc_native.setEnvironmentVariable("NIX_CFLAGS_COMPILE", "-isystem test/link_input/tc_native/sys");
    tc_native.addCheck(.{ .expect_stdout_match = "pub extern fn tcn_native() c_int;" });
    takes(b, &tc_native.step, 13);
    test_step.dependOn(&tc_native.step);
    // With -lc and the native target, libc's headers are the system's,
    // which the C compiler's search path names, as upstream's
    // `LibCInstallation.findNative`; an explicit target takes the lib
    // directory's glibc headers.
    for ([_][]const []const u8{ &.{}, &.{ "-target", "x86_64-linux-gnu" } }, [_][]const u8{ "tcl_system", "tcl_bundled" }) |target, name| {
        const tc_libc = b.addRunArtifact(bs);
        tc_libc.setName(b.fmt("bs translate-c -lc {s} takes libc's headers from {s}", .{ if (target.len == 0) "native" else target[1], if (target.len == 0) "the system" else "the lib directory" }));
        tc_libc.addArgs(&.{ "translate-c", "-lc" });
        tc_libc.addArgs(target);
        tc_libc.addFileArg(b.path("test/link_input/tc_libc/s.h"));
        tc_libc.setCwd(b.path("."));
        tc_libc.setEnvironmentVariable("CC", "sh test/link_input/tc_libc/cc.sh");
        tc_libc.addCheck(.{ .expect_stdout_match = b.fmt("pub extern fn {s}() c_int;", .{name}) });
        takes(b, &tc_libc.step, 13);
        test_step.dependOn(&tc_libc.step);
    }
    // A musl target takes the lib directory's musl headers.
    const tc_musl = b.addRunArtifact(bs);
    tc_musl.setName("bs translate-c -lc -target x86_64-linux-musl takes musl's headers");
    tc_musl.addArgs(&.{ "translate-c", "-lc", "-target", "x86_64-linux-musl" });
    tc_musl.addFileArg(b.path("test/link_input/tc_libc/s.h"));
    tc_musl.addCheck(.{ .expect_stdout_match = "pub extern fn tcl_bundled() c_int;" });
    tc_musl.addCheck(.{ .expect_stdout_match = "generic-musl/features.h" });
    takes(b, &tc_musl.step, 13);
    test_step.dependOn(&tc_musl.step);
    // SysV aggregates between Zig and C both ways: INTEGER, SSE and mixed
    // eightbytes, odd sizes, MEMORY, registers running out, a function
    // pointer, and variadic aggregates. Upstream prints the same except
    // `zig_va`, whose @cVaArg of aggregates its self-hosted backend gets
    // wrong (32791); C's answer is 55.
    const abi_exe = b.addRunArtifact(bs);
    abi_exe.setName("bs build-exe with C aggregates");
    abi_exe.addArgs(&.{ "build-exe", "-lc", "-target", "x86_64-linux-gnu" });
    abi_exe.addFileArg(b.path("test/link_input/abi_main.zig"));
    abi_exe.addFileArg(b.path("test/link_input/abi.c"));
    abi_exe.setEnvironmentVariable("BS_ZIG", zig);
    const abi_run = std.Build.Step.Run.create(b, "run bs build with C aggregates");
    abi_run.addFileArg(abi_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
    abi_run.addCheck(.{ .expect_stdout_exact = "c_s16 1 2 0.5 1.5 4 5 6\nc_mix 7 0.5 3.25 9.5 10 11 12 13 14 15\nc_dsi 5 1 2 3 4 5 6 7 8 9\nptr 30 60\nzig_mix 103 101.5 102.25\nzig_dsi 0.75 1 2 3\nzig_va 55\n" });
    abi_run.addCheck(.{ .expect_stderr_exact = "2 3 | 14 1 6.5 | 1.5 2.5 3.5 | 3 2 1 | 0.25 { 7, 8, 9 }\nc_va 55\nzig_s16 10 20 0.5 0.25 1 2 3\nzig_mix 3 1.5 2.25 4.5 { 1, 2, 3 } 4 5 6\nzig_dsi 9 1 2 3 4 5 6 7 8 9\n" });
    abi_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&abi_run.step);

    // The Win64 convention (`.x86_64_win`, C's ms_abi) both ways.
    const win_exe = b.addRunArtifact(bs);
    win_exe.setName("bs build-exe with Win64 calls");
    win_exe.addArgs(&.{ "build-exe", "-lc", "-target", "x86_64-linux-gnu" });
    win_exe.addFileArg(b.path("test/link_input/win64_main.zig"));
    win_exe.addFileArg(b.path("test/link_input/win64.c"));
    win_exe.setEnvironmentVariable("BS_ZIG", zig);
    const win_run = std.Build.Step.Run.create(b, "run bs build with Win64 calls");
    win_run.addFileArg(win_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
    win_run.addCheck(.{ .expect_stdout_exact = "c_win_mix 1 2.5 3 4 5.5 6 7 8 9.5 10.5 11 12.5\nva u64 1\nva f64 2.5\nva u64 3\nva f64 4.5\nzig via ptr 32.5\nzig byref 15 77\nzig va 109.75 42\n" });
    win_run.addCheck(.{ .expect_stderr_exact = "byref 42 9 mix 32.5 s8 2 1 u128 80000000000000000\nzig_win_mix 1 2.5 3 4 5.5 6 7 8 9.5 10.5 11 12.5\nsum 42\n" });
    win_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&win_run.step);

    // Bool vectors of 65 to 128 elements as C arguments, one GPR each.
    const vb_exe = b.addRunArtifact(bs);
    vb_exe.setName("bs build-exe with C bool vectors");
    vb_exe.addArgs(&.{ "build-exe", "-lc", "-target", "x86_64-linux-gnu" });
    vb_exe.addFileArg(b.path("test/link_input/vecbool_main.zig"));
    vb_exe.addFileArg(b.path("test/link_input/vecbool.c"));
    vb_exe.setEnvironmentVariable("BS_ZIG", zig);
    const vb_run = std.Build.Step.Run.create(b, "run bs build with C bool vectors");
    vb_run.addFileArg(vb_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
    vb_run.addCheck(.{ .expect_stdout_exact = "c_v 10010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010011\nc_iv 1 2 3 4  10010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010011\nc_v7 1 2 3 4 5 6 7  10010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010011\nc_v 10010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010011\n" });
    vb_run.addCheck(.{ .expect_stderr_exact = "zig_v 01001010010100101001010010100101001010010100101001010010100101001010010100101001010010100101001010010100101001010010100101001010\nzig_iv -1 -2 -3 -4 01001010010100101001010010100101001010010100101001010010100101001010010100101001010010100101001010010100101001010010100101001010\nzig_v 01001010010100101001010010100101001010010100101001010010100101001010010100101001010010100101001010010100101001010010100101001010\n" });
    vb_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&vb_run.step);

    // Assembly sources: `.S` through the preprocessor (an include and a
    // `-D` from `-cflags`), `.s` as is, as upstream passes them to Clang.
    // `asm_abs_value`, a global absolute symbol, binds from the other
    // object and from a Zig extern.
    const asm_exe = b.addRunArtifact(bs);
    asm_exe.setName("bs build-exe with assembly sources");
    asm_exe.addArg("build-exe");
    asm_exe.addFileArg(b.path("test/link_input/asm_main.zig"));
    asm_exe.addArgs(&.{ "-cflags", "-DASM_EXTRA=100", "--" });
    asm_exe.addFileArg(b.path("test/link_input/asm_cpp.S"));
    asm_exe.addFileArg(b.path("test/link_input/asm_plain.s"));
    asm_exe.setEnvironmentVariable("BS_ZIG", zig);
    const asm_run = std.Build.Step.Run.create(b, "run bs build with assembly sources");
    asm_run.addFileArg(asm_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
    asm_run.addCheck(.{ .expect_stderr_exact = "142 42 1234 1234\n" });
    asm_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&asm_run.step);

    // LLVM IR sources: `.ll` text and `.bc` bitcode go to Clang without
    // the preprocessor, as upstream's, with `-cflags` (mcl's `.ll` files
    // in evm.zig get C++ flags).
    const bc = b.addSystemCommand(&.{ zig, "cc", "-c", "-emit-llvm" });
    bc.addFileArg(b.path("test/link_input/llvm_ir_bc.c"));
    const ir_exe = b.addRunArtifact(bs);
    ir_exe.setName("bs build-exe with LLVM IR sources");
    ir_exe.addArg("build-exe");
    ir_exe.addFileArg(b.path("test/link_input/llvm_ir_main.zig"));
    ir_exe.addArgs(&.{ "-cflags", "-std=c++20", "-DIR_UNUSED=1", "--" });
    ir_exe.addFileArg(b.path("test/link_input/llvm_ir.ll"));
    ir_exe.addFileArg(bc.addOutputFileArg2("llvm_ir.bc", .{ .prefix = "-o" }));
    ir_exe.setEnvironmentVariable("BS_ZIG", zig);
    const ir_run = std.Build.Step.Run.create(b, "run bs build with LLVM IR sources");
    ir_run.addFileArg(ir_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
    ir_run.addCheck(.{ .expect_stderr_exact = "49 42\n" });
    ir_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&ir_run.step);

    // GCC's -fPIE reads glibc's data PC-relative: the executable copies
    // `stdout` and `environ` (with its aliases, which glibc's start code
    // sets), and glibc, C and Zig all use the copies.
    if (cc) |gcc| {
        const cc_copy = b.addSystemCommand(&.{ gcc, "-fPIE", "-c" });
        cc_copy.addFileArg(b.path("test/link_input/copy.c"));
        const copy_exe = b.addRunArtifact(bs);
        copy_exe.addArgs(&.{ "build-exe", "-lc", "-target", "x86_64-linux-gnu" });
        copy_exe.addFileArg(b.path("test/link_input/copy_main.zig"));
        copy_exe.addFileArg(cc_copy.addOutputFileArg2("copy.o", .{ .prefix = "-o" }));
        copy_exe.setEnvironmentVariable("BS_CACHE", "off");
        const r = std.Build.Step.Run.create(b, "run bs link of copied glibc data");
        r.addFileArg(copy_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
        r.addCheck(.{ .expect_stdout_exact = "via stdout\n" });
        r.addCheck(.{ .expect_stderr_exact = "1 true\n" });
        r.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&r.step);
    }

    // A shared library found by -l and -L, with versioned symbols and a
    // data object that C reads without the GOT (copied, with the alias
    // the library's code uses). The native target puts the -L directory
    // in DT_RUNPATH, so the program finds the library when it runs.
    {
        const so = b.addSystemCommand(&.{ zig, "cc", "-shared", "-fPIC" });
        so.addFileArg(b.path("test/link_input/shared.c"));
        so.addPrefixedFileArg("-Wl,--version-script=", b.path("test/link_input/shared.map"));
        so.addArg("-Wl,-soname,libshared.so");
        const lib_dir = so.addOutputFileArg2("libshared.so", .{ .prefix = "-o" }).dirname();
        const user = b.addSystemCommand(if (cc) |gcc| &.{ gcc, "-fPIE", "-c" } else &.{ zig, "cc", "-c" });
        user.addFileArg(b.path("test/link_input/shared_user.c"));
        const so_exe = b.addRunArtifact(bs);
        so_exe.addArgs(&.{ "build-exe", "-lc", "-lshared" });
        so_exe.addDirectoryArg2(lib_dir, .{ .prefix = "-L" });
        so_exe.addFileArg(b.path("test/link_input/shared_main.zig"));
        so_exe.addFileArg(user.addOutputFileArg2("shared_user.o", .{ .prefix = "-o" }));
        so_exe.setEnvironmentVariable("BS_CACHE", "off");
        const r = std.Build.Step.Run.create(b, "run bs link of a shared library");
        r.addFileArg(so_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
        r.addCheck(.{ .expect_stderr_exact = "42 143 42 143\n" });
        r.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&r.step);
    }

    // A shared library's thread-local, reached from Zig and from C objects
    // of each TLS model (general-dynamic, descriptors, initial-exec), all
    // through one initial-exec slot the loader writes (TPOFF64). Upstream
    // prints the same with LLVM; its own backend miscompiles the Zig read.
    {
        const so = b.addSystemCommand(&.{ zig, "cc", "-shared", "-fPIC", "-Wl,-soname,libsotls.so" });
        so.addFileArg(b.path("test/link_input/so_tls.c"));
        const lib_dir = so.addOutputFileArg2("libsotls.so", .{ .prefix = "-o" }).dirname();
        const so_exe = b.addRunArtifact(bs);
        so_exe.addArgs(&.{ "build-exe", "-lc", "-lsotls" });
        so_exe.addDirectoryArg2(lib_dir, .{ .prefix = "-L" });
        so_exe.addFileArg(b.path("test/link_input/so_tls_main.zig"));
        for ([_][]const []const u8{ &.{ "-fPIC", "-DSUFFIX=_gd" }, &.{ "-fPIC", "-mtls-dialect=gnu2", "-DSUFFIX=_desc" }, &.{ "-fPIC", "-ftls-model=initial-exec", "-DSUFFIX=_ie" } }, [_][]const u8{ "gd", "desc", "ie" }) |flags, name| {
            const user = b.addSystemCommand(&.{ zig, "cc", "-c" });
            user.addArgs(flags);
            user.addFileArg(b.path("test/link_input/so_tls_user.c"));
            so_exe.addFileArg(user.addOutputFileArg2(b.fmt("so_tls_{s}.o", .{name}), .{ .prefix = "-o" }));
        }
        so_exe.setEnvironmentVariable("BS_CACHE", "off");
        const r = std.Build.Step.Run.create(b, "run bs link of a shared library's thread-local");
        r.addFileArg(so_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
        r.addCheck(.{ .expect_stderr_exact = "main: 3 3 3 3 103\nset: 1114 1114 1114 1114 1214\nthread: 3 3 3 3 103\nafter: 1114 1114 1114 1114 1214\n" });
        r.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&r.step);
    }

    // DT_NEEDED liveness: of four shared libraries, the program needs a,
    // which it calls, and b, which a calls without needing it itself; c
    // (defining only a name the program defines) and d (referenced weakly
    // from C) are left out, so their constructors never print. a and b
    // call back into the program's Zig and C definitions, which it
    // exports. Upstream links the same.
    {
        const libs = b.addSystemCommand(&.{
            "sh", "-c",
            \\set -e; z=$1; d=$2; s=$3
            \\for x in a b c; do "$z" cc -shared -fPIC -Wl,-soname,libneeded_$x.so "$s/needed_$x.c" -o "$d/libneeded_$x.so"; done
            \\"$z" cc -shared -fPIC -DNEEDED_D -Wl,-soname,libneeded_d.so "$s/needed_c.c" -o "$d/libneeded_d.so"
            ,
            "sh", zig,
        });
        const lib_dir = libs.addOutputDirectoryArg2("needed", .{});
        libs.addDirectoryArg2(b.path("test/link_input"), .{});
        const so_exe = b.addRunArtifact(bs);
        so_exe.addArgs(&.{ "build-exe", "-lc", "-lneeded_a", "-lneeded_b", "-lneeded_c", "-lneeded_d" });
        so_exe.addDirectoryArg2(lib_dir, .{ .prefix = "-L" });
        so_exe.addFileArg(b.path("test/link_input/needed_main.zig"));
        so_exe.addFileArg(b.path("test/link_input/needed_ref.c"));
        so_exe.setEnvironmentVariable("BS_ZIG", upstreamZig(b));
        so_exe.setEnvironmentVariable("BS_CACHE", "off");
        const r = std.Build.Step.Run.create(b, "run bs link of unneeded shared libraries");
        r.addFileArg(so_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
        r.addCheck(.{ .expect_stdout_exact = "" });
        r.addCheck(.{ .expect_stderr_exact = "42 0\n" });
        r.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&r.step);
    }

    // A library without DT_SONAME that `-l` finds is needed by its file
    // name, and glibc's libraries come before it in a program with Zig
    // code and after it in one of C only, as upstream's linkers order
    // them; run from another directory.
    {
        const libs = b.addSystemCommand(&.{
            "sh", "-c",
            \\set -e; z=$(realpath "$1"); d=$2; s=$(realpath "$3"); b=$(realpath "$4"); zig=$z
            \\"$z" cc -shared -fPIC "$s/dup_lib.c" -o "$d/libdup.so"
            \\cd "$d"
            \\for m in dup_main.zig dup_main.c; do BS_ZIG="$zig" BS_CACHE=off "$b" build-exe -lc "$s/$m" -L. -ldup -femit-bin="$m.exe"; done
            ,
            "sh", upstreamZig(b),
        });
        const dir = libs.addOutputDirectoryArg2("dup", .{});
        libs.addDirectoryArg2(b.path("test/link_input"), .{});
        libs.addArtifactArg2(bs, .{});
        for ([_][]const u8{ "dup_main.zig", "dup_main.c" }, [_][]const u8{ "false\n", "true\n" }) |m, want| {
            const r = b.addSystemCommand(&.{ "sh", "-c", "d=$(realpath \"$1\"); cd / && LD_LIBRARY_PATH=\"$d\" exec \"$d/$2.exe\" 2>&1", "sh" });
            r.setName(b.fmt("run bs link of {s} with a library glibc's definitions precede or follow", .{m}));
            r.addDirectoryArg2(dir, .{});
            r.addArg(m);
            r.addCheck(.{ .expect_stdout_exact = want });
            r.addCheck(.{ .expect_term = .{ .exited = 0 } });
            test_step.dependOn(&r.step);
        }
    }

    // A shared library's operator new replaces libc++'s, which the C++
    // runtime's archive would otherwise supply, as upstream links it.
    // For the C++ executable's target, after it, to reuse its libc++.
    {
        const lib = b.addSystemCommand(&.{ upstreamZig(b), "c++", "-shared", "-fPIC", "-nostdlib++", "-Wl,-soname,libcxxnew.so" });
        lib.addFileArg(b.path("test/link_input/cxx_new.cpp"));
        const lib_file = lib.addOutputFileArg2("libcxxnew.so", .{ .prefix = "-o" });
        const new_exe = b.addRunArtifact(bs);
        new_exe.addArgs(&.{ "build-exe", "-lc", "-lc++", "-target", "x86_64-linux-gnu" });
        new_exe.step.dependOn(&cxx_exe.step);
        new_exe.addFileArg(lib_file);
        new_exe.addFileArg(b.path("test/link_input/cxx_new_main.cpp"));
        new_exe.setEnvironmentVariable("BS_ZIG", upstreamZig(b));
        new_exe.setEnvironmentVariable("BS_CACHE", "off");
        const r = b.addSystemCommand(&.{ "sh", "-c", "LD_LIBRARY_PATH=$(dirname \"$1\") exec \"$2\"", "sh" });
        r.setName("run bs link of a C++ executable with a shared library's operator new");
        r.addFileArg(lib_file);
        r.addFileArg(new_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
        r.addCheck(.{ .expect_stdout_exact = "42 1\n" });
        r.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&r.step);
    }

    // Constructors run in priority order across two objects, before main;
    // the destructor runs only with -lc, whose exit runs the fini array.
    var ctors: [2]std.Build.LazyPath = undefined;
    for (&ctors, [_][]const u8{ "-USECOND", "-DSECOND" }, 0..) |*o, def, i| {
        const cc_ctor = b.addSystemCommand(&.{ zig, "cc", "-fPIC", def, "-c" });
        cc_ctor.addFileArg(b.path("test/link_input/ctor.c"));
        o.* = cc_ctor.addOutputFileArg2(b.fmt("ctor{d}.o", .{i}), .{ .prefix = "-o" });
    }
    for ([_][]const []const u8{ &.{"build-exe"}, &.{ "build-exe", "-lc", "-target", "x86_64-linux-gnu" } }, [_][]const u8{ "", "fini\n" }) |args, fini| {
        const ctor_exe = b.addRunArtifact(bs);
        ctor_exe.addArgs(args);
        ctor_exe.addFileArg(b.path("test/link_input/ctor_main.zig"));
        for (ctors) |o| ctor_exe.addFileArg(o);
        ctor_exe.setEnvironmentVariable("BS_CACHE", "off");
        const r = std.Build.Step.Run.create(b, b.fmt("run bs link of C constructors{s}", .{if (fini.len == 0) "" else " with -lc"}));
        r.addFileArg(ctor_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
        r.addCheck(.{ .expect_stderr_exact = b.fmt("{{ 101, 150, 200, 1, 2 }}\n{s}", .{fini}) });
        r.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&r.step);
    }

    // Two objects with the same COMDAT group, in both orders: the first
    // object's copy is kept, and both objects reach it.
    var comdats: [2]std.Build.LazyPath = undefined;
    for (&comdats, [_][]const u8{ "comdat1.s", "comdat2.s" }) |*o, src| {
        const as = b.addSystemCommand(&.{ zig, "cc", "-c" });
        as.addFileArg(b.path(b.fmt("test/link_input/{s}", .{src})));
        o.* = as.addOutputFileArg2(b.fmt("{s}.o", .{src[0..7]}), .{ .prefix = "-o" });
    }
    for ([_][2]usize{ .{ 0, 1 }, .{ 1, 0 } }, [_][]const u8{ "11 11\n", "22 22\n" }) |order, expect_comdat| {
        const comdat_exe = b.addRunArtifact(bs);
        comdat_exe.addArg("build-exe");
        comdat_exe.addFileArg(b.path("test/link_input/comdat_main.zig"));
        for (order) |k| comdat_exe.addFileArg(comdats[k]);
        comdat_exe.setEnvironmentVariable("BS_CACHE", "off");
        const r = std.Build.Step.Run.create(b, b.fmt("run bs link of COMDAT groups ({d} first)", .{order[0] + 1}));
        r.addFileArg(comdat_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
        r.addCheck(.{ .expect_stderr_exact = expect_comdat });
        r.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&r.step);
    }

    // Undefined behavior and a smashed stack in C reach ubsan_rt's and the
    // stack protector's panics.
    const ub = b.addSystemCommand(&.{ zig, "cc", "-fstack-protector-all", "-fno-sanitize=bounds", "-c" });
    ub.addFileArg(b.path("test/link_input/ub.c"));
    const ub_o = ub.addOutputFileArg2("ub.o", .{ .prefix = "-o" });
    const ub_exe = b.addRunArtifact(bs);
    ub_exe.addArg("build-exe");
    ub_exe.addFileArg(b.path("test/link_input/ub_main.zig"));
    ub_exe.addFileArg(ub_o);
    ub_exe.setEnvironmentVariable("BS_CACHE", "off");
    const ub_bin = ub_exe.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" });
    // The trace shows the C frame's line, from the object's DWARF, and
    // unwinds through it by its .eh_frame FDE.
    const trace_o = [_][]const u8{ "panic: signed integer overflow: 5 + 2147483647 cannot be represented in type 'int'\n", "ub.c:2:34: 0x", " in c_overflow (", "ub_main.zig:10:63: 0x" };
    for ([_]struct { []const u8, []const []const u8 }{ .{ "o", &trace_o }, .{ "s", &.{"panic: stack smashing detected\n"} } }) |case| {
        const r = std.Build.Step.Run.create(b, b.fmt("run bs link of a C object ({s})", .{case[0]}));
        r.addFileArg(ub_bin);
        r.addArg(case[0]);
        for (case[1]) |m| r.addCheck(.{ .expect_stderr_match = m });
        r.addCheck(.{ .expect_term = .{ .signal = .ABRT } });
        test_step.dependOn(&r.step);
    }

    // Objects and archives through the cache: test/link_input/cache.sh,
    // whose parts run at once.
    for ([_][]const u8{ "objects", "c-sources", "lc-objects", "shared", "shared-objects" }) |part| {
        const cache = b.addSystemCommand(&.{"sh"});
        cache.setName(b.fmt("bs build-exe with link inputs, cached ({s})", .{part}));
        cache.addFileArg(b.path("test/link_input/cache.sh"));
        cache.addArtifactArg2(bs, .{});
        cache.addArg(zig);
        cache.addDirectoryArg2(b.path("test/link_input"), .{});
        _ = cache.addOutputDirectoryArg2("work", .{});
        cache.addArg(part);
        cache.addDirectoryArg2(std_zir, .{});
        cache.addCheck(.{ .expect_term = .{ .exited = 0 } });
        takes(b, &cache.step, if (std.mem.eql(u8, part, "objects")) 38 else 18);
        cache_step.dependOn(&cache.step);
    }
    return &tc_native.step;
}

/// aarch64-linux's position-independent code and shared objects, as
/// x86_64's tests above check them, run under qemu with aarch64 glibc
/// (`runner`): bs's shared objects, of Zig, with -lc, C sources, objects,
/// archives and libc++, loaded by programs upstream links and by dlopen;
/// -fPIC and -lc objects in upstream's PIEs and shared objects; and the
/// three models of a thread-local another module defines.
/// `libcxx` builds libc++ for aarch64-linux-gnu, which the C++ library
/// here reuses.
fn addAarch64LinuxSharedTests(b: *std.Build, bs: *std.Build.Step.Compile, test_step: *std.Build.Step, runner: []const []const u8, libcxx: *std.Build.Step) void {
    const zig = upstreamZig(b);
    const gnu = "aarch64-linux-gnu";
    // Runs `exe` with the directory of `lib` on the emulated program's
    // library path: a cross build has no DT_RUNPATH.
    const Run = struct {
        fn withLib(b2: *std.Build, name: []const u8, run_with: []const []const u8, lib: std.Build.LazyPath, exe: std.Build.LazyPath) *std.Build.Step.Run {
            const r = b2.addSystemCommand(&.{ "sh", "-c", "d=$(dirname \"$1\"); shift; LD_LIBRARY_PATH=$d QEMU_SET_ENV=LD_LIBRARY_PATH=$d exec \"$@\"", "sh" });
            r.setName(name);
            r.addFileArg(lib);
            r.addArgs(run_with);
            r.addFileArg(exe);
            return r;
        }
    };
    // test/obj/lib.zig as bs's shared object, without and with -lc, loaded
    // by test/obj/main.zig, which upstream links against it, and by dlopen.
    for ([_]bool{ false, true }) |lc| {
        const so = b.addRunArtifact(bs);
        so.setName(b.fmt("bs build-lib -dynamic{s} -target aarch64-linux", .{if (lc) " -lc" else ""}));
        so.addArgs(if (lc) &.{ "build-lib", "-dynamic", "-lc", "-target", gnu, "--name", "bsso" } else &.{ "build-lib", "-dynamic", "-target", "aarch64-linux", "--name", "bsso" });
        so.addFileArg(b.path("test/obj/lib.zig"));
        so.setEnvironmentVariable("BS_ZIG", zig);
        const so_file = so.addOutputFileArg2("libbsso.so", .{ .prefix = "-femit-bin=" });
        const host = b.addSystemCommand(&.{ zig, "build-exe", "-lc", "-rdynamic", "-target", gnu });
        host.addFileArg(b.path("test/obj/main.zig"));
        host.addFileArg(so_file);
        const r = Run.withLib(b, b.fmt("run obj main (bs aarch64-linux shared object{s})", .{if (lc) ", -lc" else ""}), runner, so_file, host.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
        r.addCheck(.{ .expect_stdout_exact = "20 7 41\n" });
        r.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&r.step);
        if (lc) continue;
        const dl_host = b.addSystemCommand(&.{ zig, "build-exe", "-lc", "-rdynamic", "-target", gnu });
        dl_host.addFileArg(b.path("test/obj/dl.c"));
        const dl_run = std.Build.Step.Run.create(b, "run dl.c (dlopen of bs aarch64-linux shared object)");
        dl_run.addArgs(runner);
        dl_run.addFileArg(dl_host.addOutputFileArg2("dl", .{ .prefix = "-femit-bin=" }));
        dl_run.addFileArg(so_file);
        dl_run.addCheck(.{ .expect_stdout_exact = "20 7 41\n" });
        dl_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&dl_run.step);
    }
    // The same library as a -fPIC object, which upstream links into a
    // static PIE and a shared object, and as a -lc object (PIC) in a -lc
    // PIE.
    for ([_]bool{ false, true }) |lc| {
        const obj = b.addRunArtifact(bs);
        obj.setName(b.fmt("bs build-obj {s} -target aarch64-linux", .{if (lc) "-lc" else "-fPIC"}));
        obj.addArgs(if (lc) &.{ "build-obj", "-lc", "-target", gnu } else &.{ "build-obj", "-fPIC", "-target", "aarch64-linux" });
        obj.addFileArg(b.path("test/obj/lib.zig"));
        const o = obj.addOutputFileArg2("lib.o", .{ .prefix = "-femit-bin=" });
        const pie = b.addSystemCommand(if (lc) &.{ zig, "build-exe", "-fPIE", "-lc", "-target", gnu } else &.{ zig, "build-exe", "-fPIE", "-target", "aarch64-linux" });
        pie.addFileArg(b.path("test/obj/main.zig"));
        pie.addFileArg(o);
        const pie_bin = pie.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" });
        for ([_]bool{ false, true }) |panic| {
            if (lc and panic) continue;
            const r = std.Build.Step.Run.create(b, b.fmt("run obj main (aarch64-linux {s} object in a PIE{s})", .{ if (lc) "-lc" else "-fPIC", if (panic) ", panic" else "" }));
            r.addArgs(runner);
            r.addFileArg(pie_bin);
            if (panic) {
                r.addArg("panic");
                r.addCheck(.{ .expect_stderr_match = " in bs_overflow (lib.zig)\n    return x + 250;\n" });
                r.addCheck(.{ .expect_term = .{ .signal = .ABRT } });
            } else {
                r.addCheck(.{ .expect_stdout_exact = "20 7 41\n" });
                r.addCheck(.{ .expect_term = .{ .exited = 0 } });
            }
            test_step.dependOn(&r.step);
        }
        if (lc) continue;
        const so = b.addSystemCommand(&.{ zig, "build-lib", "-dynamic", "-target", "aarch64-linux", "--name", "bspic" });
        so.addFileArg(o);
        const so_file = so.addOutputFileArg2("libbspic.so", .{ .prefix = "-femit-bin=" });
        const host = b.addSystemCommand(&.{ zig, "build-exe", "-lc", "-rdynamic", "-target", gnu });
        host.addFileArg(b.path("test/obj/main.zig"));
        host.addFileArg(so_file);
        const r = Run.withLib(b, "run obj main (aarch64-linux -fPIC object in a shared object)", runner, so_file, host.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
        r.addCheck(.{ .expect_stdout_exact = "20 7 41\n" });
        r.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&r.step);
    }
    // A thread-local the host defines: local-exec in an executable,
    // initial-exec in a PIE, a TLS descriptor in a shared object.
    for ([_][]const u8{ "-fno-PIC", "-fPIE", "-fPIC" }) |mode| {
        const tls = b.addRunArtifact(bs);
        tls.setName(b.fmt("bs build-obj {s} -target aarch64-linux tls.zig", .{mode}));
        tls.addArgs(&.{ "build-obj", mode, "-target", "aarch64-linux" });
        tls.addFileArg(b.path("test/obj/tls.zig"));
        const tls_o = tls.addOutputFileArg2("tls.o", .{ .prefix = "-femit-bin=" });
        const name = b.fmt("run tls_main (aarch64-linux extern threadlocal, {s})", .{mode});
        const r = if (std.mem.eql(u8, mode, "-fPIC")) run: {
            const so = b.addSystemCommand(&.{ zig, "build-lib", "-dynamic", "-target", "aarch64-linux", "--name", "bstls" });
            so.addFileArg(tls_o);
            const so_file = so.addOutputFileArg2("libbstls.so", .{ .prefix = "-femit-bin=" });
            const host = b.addSystemCommand(&.{ zig, "build-exe", "-lc", "-rdynamic", "-target", gnu });
            host.addFileArg(b.path("test/obj/tls_main.zig"));
            host.addFileArg(so_file);
            break :run Run.withLib(b, name, runner, so_file, host.addOutputFileArg2("tls_main", .{ .prefix = "-femit-bin=" }));
        } else run: {
            const exe = b.addSystemCommand(&.{ zig, "build-exe", "-target", "aarch64-linux", if (std.mem.eql(u8, mode, "-fPIE")) "-fPIE" else "-fno-PIE" });
            exe.addFileArg(b.path("test/obj/tls_main.zig"));
            exe.addFileArg(tls_o);
            const r = std.Build.Step.Run.create(b, name);
            r.addArgs(runner);
            r.addFileArg(exe.addOutputFileArg2("tls_main", .{ .prefix = "-femit-bin=" }));
            break :run r;
        };
        r.addCheck(.{ .expect_stdout_exact = "5 6 5 6\n" });
        r.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&r.step);
    }
    // Shared libraries linking glibc, as x86_64's: with a C source, which
    // calls glibc through versioned imports, and of C only.
    for ([_][]const []const u8{ &.{ "test/link_input/so_libc.zig", "test/link_input/so_libc.c" }, &.{"test/link_input/so_libc.c"} }, [_][]const u8{ "test/link_input/so_libc_main.zig", "test/link_input/so_c_main.zig" }, [_][]const u8{ "so_libc", "so_c" }, [_][]const u8{ "z[c7:1]\nz[c42:2]\nc bye\n", "c3:1\nc4:2\nc bye\n" }) |srcs, main_src, name, stderr| {
        const so = b.addRunArtifact(bs);
        so.setName(b.fmt("bs build-lib -dynamic -lc -target aarch64-linux-gnu {s}", .{std.Io.Dir.path.basename(srcs[0])}));
        so.addArgs(&.{ "build-lib", "-dynamic", "-lc", "-target", gnu, "--name", name });
        for (srcs) |src| so.addFileArg(b.path(src));
        so.setEnvironmentVariable("BS_ZIG", zig);
        const so_file = so.addOutputFileArg2(b.fmt("lib{s}.so", .{name}), .{ .prefix = "-femit-bin=" });
        const host = b.addSystemCommand(&.{ zig, "build-exe", "-lc", "-rdynamic", "-target", gnu });
        host.addFileArg(b.path(main_src));
        host.addFileArg(so_file);
        const r = Run.withLib(b, b.fmt("run {s} (bs aarch64-linux shared library linking glibc)", .{std.Io.Dir.path.basename(main_src)}), runner, so_file, host.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
        r.addCheck(.{ .expect_stderr_exact = stderr });
        r.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&r.step);
    }
    // A shared library with a C source, C objects and an archive (TLS
    // descriptors), whose exported C globals and thread-locals an
    // executable preempts.
    {
        const tls_o = b.addSystemCommand(&.{ zig, "cc", "-target", gnu, "-fPIC", "-c" });
        tls_o.addFileArg(b.path("test/link_input/tls.c"));
        const desc_o = b.addSystemCommand(&.{ zig, "cc", "-target", gnu, "-fPIC", "-c" });
        desc_o.addFileArg(b.path("test/link_input/so_desc.c"));
        const desc_a = b.addSystemCommand(&.{ zig, "ar", "rcs" });
        const desc_lib = desc_a.addOutputFileArg2("libdesc.a", .{});
        desc_a.addFileArg(desc_o.addOutputFileArg2("so_desc.o", .{ .prefix = "-o" }));
        const so = b.addRunArtifact(bs);
        so.setName("bs build-lib -dynamic -target aarch64-linux with a C source, a C object and an archive");
        so.addArgs(&.{ "build-lib", "-dynamic", "-target", "aarch64-linux", "--name", "bsinputs" });
        so.addFileArg(b.path("test/link_input/so_lib.zig"));
        so.addFileArg(b.path("test/link_input/merge.c"));
        so.addFileArg(b.path("test/link_input/so_interpose.c"));
        so.addFileArg(b.path("test/link_input/so_hidref.c"));
        so.addFileArg(tls_o.addOutputFileArg2("tls.o", .{ .prefix = "-o" }));
        so.addFileArg(desc_lib);
        so.setEnvironmentVariable("BS_ZIG", zig);
        const so_file = so.addOutputFileArg2("libbsinputs.so", .{ .prefix = "-femit-bin=" });
        const host = b.addSystemCommand(&.{ zig, "build-exe", "-lc", "-target", gnu });
        host.addFileArg(b.path("test/link_input/so_main.zig"));
        host.addFileArg(so_file);
        const r = Run.withLib(b, "run so_main (bs aarch64-linux shared library with inputs)", runner, so_file, host.addOutputFileArg2("so_main", .{ .prefix = "-femit-bin=" }));
        r.addCheck(.{ .expect_stderr_exact = "44 bee 6 712 810\nthread: 712 810\n" });
        r.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&r.step);
        const preempt_host = b.addSystemCommand(&.{ zig, "cc", "-target", gnu });
        preempt_host.addFileArg(b.path("test/link_input/so_preempt.c"));
        preempt_host.addFileArg(so_file);
        const preempt = Run.withLib(b, "run so_preempt (preempting a bs aarch64-linux shared library's exports)", runner, so_file, preempt_host.addOutputFileArg2("so_preempt", .{ .prefix = "-o" }));
        preempt.addCheck(.{ .expect_stdout_exact = "100012 200310 1000 2003\n32 1 202 4\n" });
        preempt.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&preempt.step);
    }
    // A versioned shared library of C++ only, with libc++ built into it,
    // which the loader finds by its soname.
    {
        const so = b.addRunArtifact(bs);
        so.setName("bs build-lib -dynamic -lc++ --version -target aarch64-linux-gnu with a C++ source");
        so.addArgs(&.{ "build-lib", "-dynamic", "-lc++", "-target", gnu, "--name", "sxx", "--version", "1.2.3" });
        so.addFileArg(b.path("test/link_input/so_cxx.cpp"));
        so.setEnvironmentVariable("BS_ZIG", zig);
        so.step.dependOn(libcxx);
        const so_file = so.addOutputFileArg2("libsxx.so.1.2.3", .{ .prefix = "-femit-bin=" });
        const host = b.addSystemCommand(&.{ zig, "build-exe", "-lc", "-target", gnu });
        host.addFileArg(b.path("test/link_input/so_cxx_main.zig"));
        host.addFileArg(so_file);
        const r = b.addSystemCommand(&.{ "sh", "-c", "d=$(mktemp -d) && cp \"$1\" \"$d/libsxx.so.1\" && shift && LD_LIBRARY_PATH=$d QEMU_SET_ENV=LD_LIBRARY_PATH=$d \"$@\"; r=$?; rm -rf \"$d\"; exit $r", "sh" });
        r.setName("run so_cxx_main.zig (bs aarch64-linux shared library of C++)");
        r.addFileArg(so_file);
        r.addArgs(runner);
        r.addFileArg(host.addOutputFileArg2("main", .{ .prefix = "-femit-bin=" }));
        r.addCheck(.{ .expect_stderr_exact = "sxx 6 9\n" });
        r.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&r.step);
    }
}

fn upstreamZig(b: *std.Build) []const u8 {
    const io = b.graph.io;
    const zig_exe = b.graph.zig_exe;
    const real = std.Io.Dir.cwd().realPathFileAlloc(io, zig_exe, b.allocator) catch zig_exe;
    if (std.Io.Dir.cwd().access(io, b.pathJoin(&.{ std.Io.Dir.path.dirname(real) orelse ".", "lib", "std", "std.zig" }), .{})) |_| return zig_exe else |_| {}
    return b.findProgram(.{ .names = &.{"zig"} }) orelse std.debug.panic("'{s}' is not upstream zig, and no zig is on PATH", .{zig_exe});
}
