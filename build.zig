const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zap compiles the std library of exactly one Zig release. By default it
    // uses the lib directory of the zig that builds zap, which `.agents/setup`
    // pins to 0.17.0.
    const zig_lib_dir = b.option(
        []const u8,
        "zig-lib-dir",
        "Default Zig 0.17.0 lib directory baked into zap (default: next to the building zig)",
    ) orelse defaultZigLibDir(b);

    const options = b.addOptions();
    options.addOption([]const u8, "zig_lib_dir", zig_lib_dir);

    // `-Dsanitize-thread`: a ThreadSanitizer build of zap, for checking the
    // state CodeGen workers share with the Sema thread (see "Parallel
    // function bodies" in docs/architecture.md). Build it with
    // -Doptimize=ReleaseFast, where libc's malloc is the allocator, which
    // ThreadSanitizer intercepts; std's SafeAllocator hands memory between
    // threads in ways it cannot see, and every reuse then looks like a race.
    const sanitize_thread = b.option(bool, "sanitize-thread", "Build zap with ThreadSanitizer (use with -Doptimize=ReleaseFast)") orelse false;
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .link_libc = if (sanitize_thread) true else null,
    });
    exe_mod.addOptions("build_options", options);
    // The autodocs viewer `-femit-docs` writes (src/Docs.zig).
    const docs_wasm = docsWasm(b, zig_lib_dir);
    exe_mod.addAnonymousImport("docs_wasm", .{ .root_source_file = docs_wasm });
    // The build runner's web UI client, which `zig build --fuzz` serves
    // (src/BuildWeb.zig).
    const build_web_wasm = buildWebWasm(b, zig_lib_dir);
    exe_mod.addAnonymousImport("build_web_wasm", .{ .root_source_file = build_web_wasm });

    const exe = b.addExecutable(.{ .name = "zap", .root_module = exe_mod });
    // Comptime evaluation recurses on the native stack: a 1000-deep
    // comptime recursion (the default branch quota) needs more than the
    // usual 8 MiB. Upstream links zig with the same size.
    exe.stack_size = 46 * 1024 * 1024;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run zap").dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{ .root_module = exe_mod });
    // After zap, as one of its users (`spreadZapUsers`), so that it does
    // not hold a worker when zap's users start.
    unit_tests.step.dependOn(&exe.step);
    takes(b, &unit_tests.step, 7);
    const test_step = b.step("test", "Run zap's unit tests and run tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    const upstream_step = b.step("test-upstream", "Run the run tests with upstream zig, the oracle");
    // A global cache holding the ZIR of the std files that every build
    // lowers, which the tests that need an empty global cache start from
    // instead of spending 5 s of CPU each on AstGen.
    const zir = b.addRunArtifact(exe);
    zir.setName("zap: global cache with std's ZIR");
    zir.addArgs(&.{ "build-exe", "-fno-emit-bin", "-target", "x86_64-linux" });
    zir.addFileArg(b.path("test/run/corpus.zig"));
    zir.addArg("--global-cache-dir");
    const std_zir = zir.addOutputDirectoryArg("global");
    addRunTests(b, exe, test_step, upstream_step, std_zir);
    addObjAndRunTests(b, exe, test_step, std_zir);
    const translate_c = addLinkInputTests(b, exe, test_step, std_zir);
    addDiagTests(b, exe, test_step, upstream_step, std_zir);
    const build_test_step = addBuildTest(b, exe, build_web_wasm, translate_c);
    spreadZapUsers(b, &exe.step, &zir.step, &.{ test_step, build_test_step });

    // Always ReleaseFast: a Debug build of zap says nothing about its speed.
    const bench_link = b.addExecutable(.{ .name = "bench-link", .root_module = b.createModule(.{
        .root_source_file = b.path("src/bench_link.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    }) });
    const bench_intern = b.addExecutable(.{ .name = "bench-intern", .root_module = b.createModule(.{
        .root_source_file = b.path("src/bench_intern.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    }) });
    b.step("bench-intern", "Measure InternPool get() throughput on a Sema-like key mix").dependOn(&b.addRunArtifact(bench_intern).step);
    const bench_cache = b.addExecutable(.{ .name = "bench-cache", .root_module = b.createModule(.{
        .root_source_file = b.path("src/bench_cache.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    }) });
    b.step("bench-cache", "Measure cache storage: manifest, pack, relink from the pack, global store").dependOn(&b.addRunArtifact(bench_cache).step);
    const bench_link_run = b.addRunArtifact(bench_link);
    bench_link_run.addPassthruArgs();
    b.step("bench-link", "Measure link throughput on ~100k synthetic atoms (args: elf (default) or macho)").dependOn(&bench_link_run.step);

    // zap itself, ReleaseFast, generating every function of a build 10
    // more times after analysis (`ZAP_BENCH_CODEGEN`).
    const bench_zap_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_zap_mod.addOptions("build_options", options);
    bench_zap_mod.addAnonymousImport("docs_wasm", .{ .root_source_file = docs_wasm });
    bench_zap_mod.addAnonymousImport("build_web_wasm", .{ .root_source_file = build_web_wasm });
    const bench_zap = b.addExecutable(.{ .name = "zap", .root_module = bench_zap_mod });
    bench_zap.stack_size = exe.stack_size;
    const bench_codegen_run = b.addRunArtifact(bench_zap);
    bench_codegen_run.setEnvironmentVariable("ZAP_BENCH_CODEGEN", "10");
    bench_codegen_run.addArg("build-exe");
    bench_codegen_run.addFileArg(b.path("bench/workloads/hello/hello.zig"));
    bench_codegen_run.addArg("-fno-emit-bin");
    bench_codegen_run.has_side_effects = true;
    b.step("bench-codegen", "Measure the backend per stage, per IR instruction, on the hello workload (others: ZAP_BENCH_CODEGEN=n zap build-exe ...)").dependOn(&bench_codegen_run.step);
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
///                               zap first builds the program with the
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
///                               (`ZAP_CACHE_VERIFY`, `ZAP_CACHE_CHECK`),
///                               whose manifest then replaces theirs; the
///                               next three chain on the edit builds' own
///                               log, and only the last of them compares
///                               itself with a full build.
///   //! rebuild-lib-without: "<lib path>" "<zig string>"
///                               the same edit in a file of zap's lib
///                               directory, of which the builds use a copy
///   //! donor-without: "<zig string>"
///                               zap first builds the program without this
///                               text in another directory, then this one
///                               with an empty local cache and the same
///                               global cache, which replays the first as
///                               a donor; checks that it did, then builds
///                               it in full with the same error codes
///                               (`ZAP_CACHE_VERIFY=full`), which compares
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
///
/// `test` builds each with zap and checks it; `test-upstream` does the same
/// with upstream zig, so every program is checked against the oracle.
/// A run test's `//! flags:` and its source: the path, unless the flags
/// give `-M` modules, whose files become inputs instead.
fn addFlags(b: *std.Build, r: *std.Build.Step.Run, flags: []const []const u8, src_path: []const u8) void {
    var modules = false;
    for (flags) |f| {
        r.addArg(f);
        if (!std.mem.startsWith(u8, f, "-M")) continue;
        modules = true;
        r.addFileInput(b.path(f[std.mem.indexOfScalar(u8, f, '=').? + 1 ..]));
    }
    if (!modules) r.addFileArg(b.path(src_path));
}

fn addRunTests(b: *std.Build, zap: *std.Build.Step.Compile, test_step: *std.Build.Step, upstream_step: *std.Build.Step, std_zir: std.Build.LazyPath) void {
    const io = b.graph.io;
    const host = b.graph.host.result;
    const host_runs_zap_output = host.cpu.arch == .x86_64 and host.os.tag == .linux;
    // The headers are read here, while configuring.
    b.dependOnDirectoryContents(b.path("test/run"));
    var dir = b.root.openDir(io, "test/run", .{ .iterate = true }) catch |err|
        std.debug.panic("unable to open test/run: {t}", .{err});
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch |err| std.debug.panic("unable to list test/run: {t}", .{err})) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig") or std.mem.eql(u8, entry.name, "rt.zig")) continue;
        names.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
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
        } = .{};
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "//! ")) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
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
                const end = 1 + (std.mem.indexOfPos(u8, value, 1, "\" \"") orelse std.debug.panic("{s}: bad {s}", .{ src_path, key }));
                const first = std.zig.string_literal.parseAlloc(b.allocator, value[0..end]) catch std.debug.panic("{s}: bad string", .{src_path});
                const second = std.zig.string_literal.parseAlloc(b.allocator, std.mem.trim(u8, value[end..], " ")) catch std.debug.panic("{s}: bad string", .{src_path});
                if (key[8] == 'r') {
                    expect.rebuild_without.append(b.allocator, .{ first, second }) catch @panic("OOM");
                } else expect.lib_edit = .{ .path = first, .text = second };
            } else if (std.mem.eql(u8, key, "stdout") or std.mem.eql(u8, key, "stderr")) {
                const bytes = std.zig.string_literal.parseAlloc(b.allocator, value) catch std.debug.panic("{s}: bad string", .{src_path});
                if (key[3] == 'o') expect.stdout = bytes else expect.stderr = bytes;
            }
        }
        if (expect.exit == null and expect.signal == null) std.debug.panic("{s}: missing '//! exit:' or '//! signal:' header", .{src_path});
        if (expect.flags.items.len != 0 and (expect.rebuild_without.items.len != 0 or expect.lib_edit != null or expect.donor_without != null or expect.donor_libc))
            std.debug.panic("{s}: '//! flags:' works only without the rebuild and donor headers", .{src_path});

        for ([_]bool{ false, true }) |upstream| {
            const compile = if (upstream) blk: {
                const r = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-fno-llvm", "-fno-lld" });
                if (expect.libc) r.addArgs(&.{ "-target", "x86_64-linux-gnu", "-lc" });
                addFlags(b, r, expect.flags.items, src_path);
                break :blk r;
            } else if (expect.rebuild_without.items.len != 0 or expect.lib_edit != null) blk: {
                // Build the earlier version, then this one at the same path,
                // then the earlier and this one again, each an edit build
                // checked against a full build, then this one with nothing
                // changed (a relink), all from the cache.
                var earlier = source;
                var body_start: usize = 0;
                while (std.mem.startsWith(u8, earlier[body_start..], "//! ")) body_start = std.mem.indexOfScalarPos(u8, earlier, body_start, '\n').? + 1;
                for (expect.rebuild_without.items) |edit| {
                    const at = std.mem.indexOfPos(u8, earlier, body_start, edit[0]) orelse std.debug.panic("{s}: rebuild-without text not found", .{src_path});
                    earlier = b.fmt("{s}{s}{s}", .{ earlier[0..at], edit[1], earlier[at + edit[0].len ..] });
                }
                const files = b.addWriteFiles();
                const before = files.add(file, earlier);
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
                    const at = std.mem.indexOf(u8, lib_src, e.text) orelse std.debug.panic("{s}: rebuild-lib-without text not found", .{src_path});
                    _ = files.add("lib_before", b.fmt("{s}{s}", .{ lib_src[0..at], lib_src[at + e.text.len ..] }));
                    lib_setup = b.fmt("rm -rf \"$4.d/lib\"; cp -rs {s} \"$4.d/lib\"; rm \"$4.d/lib/{s}\"\n", .{ lib_dir, e.path });
                    lib_flag = b.fmt(" --zig-lib-dir \"$4.d/lib\"", .{});
                    lib_before = b.fmt("cp \"$(dirname \"$1\")/lib_before\" \"$4.d/lib/{s}\"\n", .{e.path});
                    lib_after = b.fmt("cp {s}/{s} \"$4.d/lib/{s}\"\n", .{ lib_dir, e.path, e.path });
                }
                // Quiet unless a build fails: the checks print to stderr.
                const target = if (expect.libc) "-target x86_64-linux-gnu -lc" else "-target x86_64-linux";
                const zap_cmd = b.fmt("\"$5\" build-exe {s} \"$4.d/{s}\" -femit-bin=\"$4\"{s} 2>\"$4.d/log\" || {{ cat \"$4.d/log\" >&2; exit 1; }}", .{ target, file, lib_flag });
                // With -lc, a relink from the manifest after the output is
                // gone, which rebuilds the dynamic tables from abilists,
                // must give a full build's bytes.
                const relink_check = if (expect.libc) b.fmt(
                    \\
                    \\rm "$4"
                    \\{[zap]s}
                    \\ZAP_CACHE=off "$5" build-exe {[target]s} "$4.d/{[file]s}" -femit-bin="$4.d/full"
                    \\cmp "$4" "$4.d/full" >&2
                , .{ .zap = zap_cmd, .target = target, .file = file }) else "";
                const r = b.addSystemCommand(&.{ "sh", "-c", b.fmt(
                    \\set -e
                    \\mkdir -p "$4.d"
                    \\cp "$3" "$4.d/rt.zig"
                    \\{[setup]s}cp "$1" "$4.d/{[file]s}"
                    \\{[lib_before]s}{[zap]s}
                    \\cp "$2" "$4.d/{[file]s}"
                    \\{[lib_after]s}ZAP_CACHE_VERIFY=1 ZAP_CACHE_CHECK=1 {[zap]s}
                    \\cp "$1" "$4.d/{[file]s}"
                    \\{[lib_before]s}ZAP_CACHE_VERIFY=1 ZAP_CACHE_CHECK=1 {[zap]s}
                    \\cp "$2" "$4.d/{[file]s}"
                    \\{[lib_after]s}ZAP_CACHE_CHECK=1 {[zap]s}
                    \\cp "$1" "$4.d/{[file]s}"
                    \\{[lib_before]s}ZAP_CACHE_CHECK=1 {[zap]s}
                    \\cp "$2" "$4.d/{[file]s}"
                    \\{[lib_after]s}ZAP_CACHE_VERIFY=1 ZAP_CACHE_CHECK=1 {[zap]s}
                    \\{[zap]s}{[relink_check]s}
                , .{ .setup = lib_setup, .file = file, .lib_before = lib_before, .lib_after = lib_after, .zap = zap_cmd, .relink_check = relink_check }), "sh" });
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
                const r = b.addSystemCommand(&.{ "sh", "-c", b.fmt(
                    \\set -e
                    \\rm -rf "$4.d"
                    \\mkdir -p "$4.d/a"
                    \\cp "$3" "$4.d/a/rt.zig"
                    \\cp "$1" "$4.d/a/{[file]s}"
                    \\log="$4.d/log"
                    \\fail() {{ cat "$log" >&2; exit 1; }}
                    \\nodonor() {{ if grep -q "replaying donor" "$log"; then echo "a build replayed a donor built with other libc settings" >&2; fail; fi; }}
                    \\mkdir -p "$4.d/g1/zap" "$4.d/g2/zap"; cp -r "$6/zap/zir" "$4.d/g1/zap"; cp -r "$6/zap/zir" "$4.d/g2/zap"
                    \\{[static]s} --global-cache-dir "$4.d/g1" --cache-dir "$4.d/l1" "$4.d/a/{[file]s}" -femit-bin="$4.d/s1" 2>"$4.d/log" || fail
                    \\ZAP_CACHE_TIMING=1 ZAP_CACHE_CHECK=1 {[libc]s} --global-cache-dir "$4.d/g1" --cache-dir "$4.d/l2" "$4.d/a/{[file]s}" -femit-bin="$4" 2>"$4.d/log" || fail
                    \\nodonor
                    \\{[libc]s} --global-cache-dir "$4.d/g2" --cache-dir "$4.d/l3" "$4.d/a/{[file]s}" -femit-bin="$4.d/c2" 2>"$4.d/log" || fail
                    \\ZAP_CACHE_TIMING=1 ZAP_CACHE_CHECK=1 {[static]s} --global-cache-dir "$4.d/g2" --cache-dir "$4.d/l4" "$4.d/a/{[file]s}" -femit-bin="$4.d/s2" 2>"$4.d/log" || fail
                    \\nodonor
                    \\"$4.d/s2" 2>"$4.d/log" || fail
                , .{ .file = file, .static = static, .libc = libc }), "sh" });
                r.addFileArg(b.path(src_path));
                r.addFileArg(b.path(src_path));
                r.addFileArg(b.path("test/run/rt.zig"));
                break :blk r;
            } else if (expect.donor_without) |text| blk: {
                const at = std.mem.indexOf(u8, source, text) orelse std.debug.panic("{s}: donor-without text not found", .{src_path});
                const files = b.addWriteFiles();
                const donor = files.add(file, b.fmt("{s}{s}", .{ source[0..at], source[at + text.len ..] }));
                const zap_cmd = b.fmt("\"$5\" build-exe -target x86_64-linux --global-cache-dir \"$4.d/g\"", .{});
                const r = b.addSystemCommand(&.{ "sh", "-c", b.fmt(
                    \\set -e
                    \\rm -rf "$4.d"
                    \\mkdir -p "$4.d/a" "$4.d/b"
                    \\cp "$3" "$4.d/a/rt.zig"
                    \\cp "$3" "$4.d/b/rt.zig"
                    \\cp "$1" "$4.d/{[donor_dir]s}/{[file]s}"
                    \\mkdir -p "$4.d/g/zap"; cp -r "$6/zap/zir" "$4.d/g/zap"
                    \\log="$4.d/log"
                    \\fail() {{ cat "$log" >&2; exit 1; }}
                    \\{[zap]s} --cache-dir "$4.d/la" "$4.d/{[donor_dir]s}/{[file]s}" -femit-bin="$4.d/a/out" 2>"$4.d/log" || fail
                    \\cp "$2" "$4.d/b/{[file]s}"
                    \\ZAP_CACHE_TIMING=1 ZAP_CACHE_CHECK=1 {[zap]s} --cache-dir "$4.d/lb" "$4.d/b/{[file]s}" -femit-bin="$4" 2>"$4.d/log" || fail
                    \\grep -q "replaying donor" "$4.d/log" || {{ echo "no donor was replayed" >&2; fail; }}
                    \\{[mode_check]s}
                    \\cp "$4" "$4.d/replayed"
                    \\ZAP_CACHE_VERIFY=full ZAP_CACHE_CHECK=1 {[zap]s} --cache-dir "$4.d/lb" "$4.d/b/{[file]s}" -femit-bin="$4" 2>"$4.d/log" || fail
                    \\cmp "$4" "$4.d/replayed" >&2
                    \\{[moved]s}
                , .{
                    .file = file,
                    .zap = zap_cmd,
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
                        \\(cd "$4.d/a" && {[zap]s} --cache-dir "$4.d/la2" {[file]s} -femit-bin="$4.d/a/out2") 2>"$4.d/log" || fail
                        \\mkdir -p "$4.d/c" && cp "$4.d/b/{[file]s}" "$4.d/b/rt.zig" "$4.d/c/"
                        \\(cd "$4.d/c" && ZAP_CACHE_TIMING=1 ZAP_CACHE_CHECK=1 {[zap]s} --cache-dir "$4.d/lc" {[file]s} -femit-bin="$4.d/moved") 2>"$4.d/log" || fail
                        \\grep -q "the walk reached" "$4.d/log" || {{ echo "the moved program's donor was not replayed lazily" >&2; fail; }}
                        \\(cd "$4.d/c" && ZAP_CACHE_TIMING=1 {[zap]s} --cache-dir "$4.d/lc" {[file]s} -femit-bin="$4.d/moved") 2>"$4.d/log" || fail
                        \\grep -q "no input changed" "$4.d/log" || {{ echo "the build after the moved program's first build found changes" >&2; fail; }}
                        \\(cd "$4.d/c" && ZAP_CACHE_VERIFY=full ZAP_CACHE_CHECK=1 {[zap]s} --cache-dir "$4.d/lc" {[file]s} -femit-bin="$4.d/moved2") 2>"$4.d/log" || fail
                        \\"$4.d/moved" >"$4.d/moved.out" 2>&1 || true
                        \\"$4.d/moved2" >"$4.d/moved2.out" 2>&1 || true
                        \\cmp "$4.d/moved.out" "$4.d/moved2.out" >&2
                    , .{ .file = file, .zap = zap_cmd }),
                }), "sh" });
                r.addFileArg(donor);
                r.addFileArg(b.path(src_path));
                r.addFileArg(b.path("test/run/rt.zig"));
                break :blk r;
            } else blk: {
                const r = b.addRunArtifact(zap);
                r.addArgs(if (expect.libc) &.{ "build-exe", "-target", "x86_64-linux-gnu", "-lc" } else &.{ "build-exe", "-target", "x86_64-linux" });
                addFlags(b, r, expect.flags.items, src_path);
                break :blk r;
            };
            compile.addFileInput(b.path("test/run/rt.zig"));
            if (!upstream) {
                const uses_std = std.mem.indexOf(u8, source, "@import(\"std\")") != null;
                const edits = expect.rebuild_without.items.len != 0 or expect.lib_edit != null;
                takes(b, &compile.step, if (edits) (if (uses_std) 10 else 1) else if (expect.donor_libc) 12 else if (expect.donor_without != null) (if (uses_std) 8 else 2) else if (uses_std) 2 else 1);
            }
            const bin = if (!upstream and (expect.rebuild_without.items.len != 0 or expect.lib_edit != null or expect.donor_without != null or expect.donor_libc)) bin: {
                const out = compile.addOutputFileArg(name);
                compile.addArtifactArg(zap);
                compile.addDirectoryArg(std_zir);
                break :bin out;
            } else compile.addPrefixedOutputFileArg("-femit-bin=", name);
            // CodeGen on worker threads gives the same output as on the
            // Sema thread (`ZAP_THREADS`); checked on programs that use
            // compiler_rt helpers, constants, error names and generics.
            if (!upstream and isThreadChecked(file)) {
                compile.setEnvironmentVariable("ZAP_THREADS", "4");
                compile.setEnvironmentVariable("ZAP_CACHE", "off");
                const serial = b.addRunArtifact(zap);
                serial.setName(b.fmt("compile {s} (ZAP_THREADS=1)", .{name}));
                serial.addArgs(&.{ "build-exe", "-target", "x86_64-linux" });
                serial.addFileArg(b.path(src_path));
                serial.addFileInput(b.path("test/run/rt.zig"));
                serial.setEnvironmentVariable("ZAP_THREADS", "1");
                serial.setEnvironmentVariable("ZAP_CACHE", "off");
                const serial_bin = serial.addPrefixedOutputFileArg("-femit-bin=", name);
                const same = b.addSystemCommand(&.{"cmp"});
                same.setName(b.fmt("{s}: ZAP_THREADS=4 and 1 build the same", .{name}));
                same.addFileArg(bin);
                same.addFileArg(serial_bin);
                test_step.dependOn(&same.step);
            }
            // A panic in inlined code has the stack trace of the program
            // built without inlining (docs/architecture.md, "Synthetic
            // panic frames"), addresses aside.
            if (!upstream and host_runs_zap_output and isTraceChecked(file)) {
                const plain = b.addRunArtifact(zap);
                plain.setName(b.fmt("compile {s} (ZAP_INLINE=0)", .{name}));
                plain.addArgs(&.{ "build-exe", "-target", "x86_64-linux" });
                plain.addFileArg(b.path(src_path));
                plain.setEnvironmentVariable("ZAP_INLINE", "0");
                plain.setEnvironmentVariable("ZAP_CACHE", "off");
                const plain_bin = plain.addPrefixedOutputFileArg("-femit-bin=", name);
                const same = b.addSystemCommand(&.{ "sh", "-c",
                    \\set -e
                    \\mask() { sed -E 's/0x[0-9a-f]+/0x?/g; s/thread [0-9]+/thread ?/'; }
                    \\{ "$1" 2>&1 >/dev/null; } 2>/dev/null | mask >"$3.inlined" || true
                    \\{ "$2" 2>&1 >/dev/null; } 2>/dev/null | mask >"$3.plain" || true
                    \\diff "$3.plain" "$3.inlined" >&2
                    \\touch "$3"
                , "sh" });
                same.setName(b.fmt("{s}: the trace matches ZAP_INLINE=0's", .{name}));
                same.addFileArg(bin);
                same.addFileArg(plain_bin);
                _ = same.addOutputFileArg("trace");
                test_step.dependOn(&same.step);
            }
            if (!upstream and !host_runs_zap_output) {
                // zap emits x86_64-linux executables; elsewhere only check
                // that they compile.
                test_step.dependOn(&compile.step);
                continue;
            }
            const run = std.Build.Step.Run.create(b, b.fmt("run {s}{s}", .{ name, if (upstream) " (upstream)" else "" }));
            run.addFileArg(bin);
            if (expect.stdout) |out| run.addCheck(.{ .expect_stdout_exact = out });
            if (expect.stderr) |err| run.addCheck(.{ .expect_stderr_exact = err });
            for (expect.stderr_contains.items) |part| run.addCheck(.{ .expect_stderr_match = part });
            run.addCheck(.{ .expect_term = if (expect.signal) |sig| .{ .signal = sig } else .{ .exited = expect.exit.? } });
            (if (upstream) upstream_step else test_step).dependOn(&run.step);
        }
    }
}

fn isTraceChecked(file: []const u8) bool {
    for ([_][]const u8{ "panic_inlined.zig", "panic_trace.zig" }) |f| {
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
/// of `//` comment lines giving zap's exact standard error:
///
///   // error
///   // args: --error-format=json      (optional: more arguments)
///   // <expected stderr line>
///   // ...
///
/// `test` runs `zap build-exe -fno-emit-bin <file>` from test/diag and
/// checks stderr and exit status 1; `test-upstream` checks that upstream
/// zig rejects the program too.
fn addDiagTests(b: *std.Build, zap: *std.Build.Step.Compile, test_step: *std.Build.Step, upstream_step: *std.Build.Step, std_zir: std.Build.LazyPath) void {
    const io = b.graph.io;
    b.dependOnDirectoryContents(b.path("test/diag"));
    var dir = b.root.openDir(io, "test/diag", .{ .iterate = true }) catch |err|
        std.debug.panic("unable to open test/diag: {t}", .{err});
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch |err| std.debug.panic("unable to list test/diag: {t}", .{err})) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const file = b.dupe(entry.name);
        const src_path = b.fmt("test/diag/{s}", .{file});
        b.dependOnFileContents(b.path(src_path));
        const source = dir.readFileAlloc(io, file, b.allocator, .limited(1 << 20)) catch |err|
            std.debug.panic("unable to read {s}: {t}", .{ src_path, err });
        const block = std.mem.lastIndexOf(u8, source, "\n// error\n") orelse
            std.debug.panic("{s}: missing '// error' block", .{src_path});
        var args: []const u8 = "";
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
            if (expected.items.len == 0 and std.mem.startsWith(u8, text, "edit-from: ")) {
                const value = text["edit-from: ".len..];
                const end = 1 + (std.mem.indexOfPos(u8, value, 1, "\" \"") orelse std.debug.panic("{s}: bad edit-from", .{src_path}));
                const now = std.zig.string_literal.parseAlloc(b.allocator, value[0..end]) catch std.debug.panic("{s}: bad string", .{src_path});
                const then = std.zig.string_literal.parseAlloc(b.allocator, value[end + 1 ..]) catch std.debug.panic("{s}: bad string", .{src_path});
                const code = earlier orelse source[0..block];
                const at = std.mem.indexOf(u8, code, now) orelse std.debug.panic("{s}: edit-from text not found", .{src_path});
                earlier = b.fmt("{s}{s}{s}", .{ code[0..at], then, code[at + now.len ..] });
                continue;
            }
            expected.appendSlice(b.allocator, text) catch @panic("OOM");
            expected.append(b.allocator, '\n') catch @panic("OOM");
        }

        const run = b.addRunArtifact(zap);
        run.setName(b.fmt("diag {s}", .{file}));
        run.setCwd(b.path("test/diag"));
        // An explicit target, so the expected diagnostics print on a Mac
        // too, where native aarch64-macos is refused until its CodeGen exists.
        run.addArgs(&.{ "build-exe", "-target", "x86_64-linux", "-fno-emit-bin", file });
        var arg_it = std.mem.tokenizeScalar(u8, args, ' ');
        while (arg_it.next()) |a| run.addArg(a);
        run.addFileInput(b.path(src_path));
        run.setEnvironmentVariable("ZAP_CACHE", "off");
        run.addCheck(.{ .expect_stderr_exact = expected.items });
        run.addCheck(.{ .expect_term = .{ .exited = 1 } });
        takes(b, &run.step, 2);
        test_step.dependOn(&run.step);
        if (earlier) |text| {
            // The same errors from an edit build, whose cache holds the
            // earlier version's build.
            const files = b.addWriteFiles();
            const before = files.add(file, text);
            const edit = b.addSystemCommand(&.{ "sh", "-c", b.fmt(
                \\set -e
                \\before=$(realpath "$1"); now=$(realpath "$2"); zap=$(realpath "$4")
                \\mkdir -p "$3/g/zap"; cp -r "$5/zap/zir" "$3/g/zap"
                \\cd "$3"
                \\cp "$before" {[file]s}
                \\"$zap" build-exe -target x86_64-linux {[file]s} -femit-bin=out --cache-dir l --global-cache-dir g{[args]s} 2>log || {{ cat log >&2; exit 2; }}
                \\cp "$now" {[file]s}
                \\exec "$zap" build-exe -target x86_64-linux {[file]s} -femit-bin=out --cache-dir l --global-cache-dir g{[args]s}
            , .{ .file = file, .args = if (args.len == 0) "" else b.fmt(" {s}", .{args}) }), "sh" });
            edit.setName(b.fmt("diag {s} (edit build)", .{file}));
            edit.addFileArg(before);
            edit.addFileArg(b.path(src_path));
            _ = edit.addOutputDirectoryArg("edit");
            edit.addArtifactArg(zap);
            edit.addDirectoryArg(std_zir);
            // Every line but the reference traces, whose frames for units
            // loaded green the edit build lacks (docs/architecture.md).
            var edit_lines = std.mem.splitScalar(u8, expected.items, '\n');
            while (edit_lines.next()) |line| {
                if (line.len != 0 and !std.mem.startsWith(u8, line, "  ref: ")) edit.addCheck(.{ .expect_stderr_match = b.fmt("{s}\n", .{line}) });
            }
            edit.addCheck(.{ .expect_term = .{ .exited = 1 } });
            takes(b, &edit.step, 5);
            test_step.dependOn(&edit.step);
        }

        const up = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-fno-emit-bin" });
        up.setName(b.fmt("diag {s} (upstream rejects)", .{file}));
        up.addFileArg(b.path(src_path));
        up.addCheck(.{ .expect_stderr_match = "error: " });
        up.addCheck(.{ .expect_term = .{ .exited = 1 } });
        upstream_step.dependOn(&up.step);
    }
}

/// `zap build-obj`: test/obj/lib.zig, linked into test/obj/main.zig by
/// upstream zig, run normally and into a panic in the object's code, whose
/// stack trace needs the object's debug info, and edited through the cache
/// as an object and a library (test/obj/cache.sh). `zap run`: test/obj/args.zig,
/// whose arguments and exit status must pass through.
fn addObjAndRunTests(b: *std.Build, zap: *std.Build.Step.Compile, test_step: *std.Build.Step, std_zir: std.Build.LazyPath) void {
    const host = b.graph.host.result;
    if (host.cpu.arch != .x86_64 or host.os.tag != .linux) return;
    const obj = b.addRunArtifact(zap);
    obj.addArg("build-obj");
    obj.addFileArg(b.path("test/obj/lib.zig"));
    const lib_o = obj.addPrefixedOutputFileArg("-femit-bin=", "lib.o");
    const exe = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-fno-llvm", "-fno-lld" });
    exe.addFileArg(b.path("test/obj/main.zig"));
    exe.addFileArg(lib_o);
    const bin = exe.addPrefixedOutputFileArg("-femit-bin=", "main");

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
    panic.addCheck(.{ .expect_stderr_match = " in zap_overflow (lib.zig)\n    return x + 250;\n" });
    panic.addCheck(.{ .expect_stderr_match = "main.zig:14:39: 0x" });
    panic.addCheck(.{ .expect_term = .{ .signal = .ABRT } });
    test_step.dependOn(&panic.step);

    // With -lc an object stays an ordinary one (its extern is not looked
    // up in glibc) but position-independent, as upstream's, which upstream
    // links into a -lc PIE.
    const lc_obj = b.addRunArtifact(zap);
    lc_obj.addArgs(&.{ "build-obj", "-lc", "-target", "x86_64-linux-gnu" });
    lc_obj.addFileArg(b.path("test/obj/lib.zig"));
    const lc_o = lc_obj.addPrefixedOutputFileArg("-femit-bin=", "lib.o");
    const lc_exe = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-lc", "-fPIE", "-target", "x86_64-linux-gnu" });
    lc_exe.addFileArg(b.path("test/obj/main.zig"));
    lc_exe.addFileArg(lc_o);
    const lc_run = std.Build.Step.Run.create(b, "run obj main (-lc object in a PIE)");
    lc_run.addFileArg(lc_exe.addPrefixedOutputFileArg("-femit-bin=", "main"));
    lc_run.addCheck(.{ .expect_stdout_exact = "20 7 41\n" });
    lc_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&lc_run.step);
    // Shared libraries against glibc are not built yet: a diagnostic, not
    // an executable in a .so's name.
    const lc_so = b.addRunArtifact(zap);
    lc_so.setName("zap build-lib -dynamic -lc (unsupported)");
    lc_so.addArgs(&.{ "build-lib", "-dynamic", "-lc", "-target", "x86_64-linux-gnu", "-fno-emit-bin" });
    lc_so.addFileArg(b.path("test/obj/lib.zig"));
    lc_so.addCheck(.{ .expect_stderr_match = "zap does not link shared libraries against glibc yet" });
    lc_so.addCheck(.{ .expect_term = .{ .exited = 1 } });
    test_step.dependOn(&lc_so.step);

    // The same object built -fPIC, linked by upstream into a static PIE
    // (which relaxes local-dynamic TLS) and into a shared object that a
    // dynamically linked program loads (which keeps it).
    const pic = b.addRunArtifact(zap);
    pic.addArgs(&.{ "build-obj", "-fPIC" });
    pic.addFileArg(b.path("test/obj/lib.zig"));
    const pic_o = pic.addPrefixedOutputFileArg("-femit-bin=", "lib.o");
    const pie = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-fPIE", "-fno-llvm", "-fno-lld" });
    pie.addFileArg(b.path("test/obj/main.zig"));
    pie.addFileArg(pic_o);
    const pie_bin = pie.addPrefixedOutputFileArg("-femit-bin=", "main");
    const pie_run = std.Build.Step.Run.create(b, "run obj main (-fPIC object in a PIE)");
    pie_run.addFileArg(pie_bin);
    pie_run.addCheck(.{ .expect_stdout_exact = "20 7 41\n" });
    pie_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&pie_run.step);
    const pie_panic = std.Build.Step.Run.create(b, "run obj main (-fPIC object in a PIE, panic)");
    pie_panic.addFileArg(pie_bin);
    pie_panic.addArg("panic");
    pie_panic.addCheck(.{ .expect_stderr_match = " in zap_overflow (lib.zig)\n    return x + 250;\n" });
    pie_panic.addCheck(.{ .expect_term = .{ .signal = .ABRT } });
    test_step.dependOn(&pie_panic.step);
    const so = b.addSystemCommand(&.{ upstreamZig(b), "build-lib", "-dynamic", "--name", "zappic" });
    so.addFileArg(pic_o);
    const so_file = so.addPrefixedOutputFileArg("-femit-bin=", "libzappic.so");
    const host_exe = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-lc", "-rdynamic" });
    host_exe.addFileArg(b.path("test/obj/main.zig"));
    host_exe.addFileArg(so_file);
    const host_bin = host_exe.addPrefixedOutputFileArg("-femit-bin=", "main");
    const so_run = b.addSystemCommand(&.{ "sh", "-c", "LD_LIBRARY_PATH=$(dirname \"$1\") exec \"$2\"", "sh" });
    so_run.setName("run obj main (-fPIC object in a shared object)");
    so_run.addFileArg(so_file);
    so_run.addFileArg(host_bin);
    so_run.addCheck(.{ .expect_stdout_exact = "20 7 41\n" });
    so_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&so_run.step);

    // The same library as zap's own shared object, loaded by a program
    // upstream links against it and by a C program with dlopen.
    const zso = b.addRunArtifact(zap);
    zso.addArgs(&.{ "build-lib", "-dynamic", "--name", "zapso" });
    zso.addFileArg(b.path("test/obj/lib.zig"));
    const zso_file = zso.addPrefixedOutputFileArg("-femit-bin=", "libzapso.so");
    const zso_host = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-lc", "-rdynamic" });
    zso_host.addFileArg(b.path("test/obj/main.zig"));
    zso_host.addFileArg(zso_file);
    const zso_host_bin = zso_host.addPrefixedOutputFileArg("-femit-bin=", "main");
    const zso_run = b.addSystemCommand(&.{ "sh", "-c", "LD_LIBRARY_PATH=$(dirname \"$1\") exec \"$2\"", "sh" });
    zso_run.setName("run obj main (zap shared object)");
    zso_run.addFileArg(zso_file);
    zso_run.addFileArg(zso_host_bin);
    zso_run.addCheck(.{ .expect_stdout_exact = "20 7 41\n" });
    zso_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&zso_run.step);
    const dl_host = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-lc", "-rdynamic" });
    dl_host.addFileArg(b.path("test/obj/dl.c"));
    const dl_bin = dl_host.addPrefixedOutputFileArg("-femit-bin=", "dl");
    const dl_run = std.Build.Step.Run.create(b, "run dl.c (dlopen of zap shared object)");
    dl_run.addFileArg(dl_bin);
    dl_run.addFileArg(zso_file);
    dl_run.addCheck(.{ .expect_stdout_exact = "20 7 41\n" });
    dl_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&dl_run.step);

    // A -fPIE object with `main`, which upstream links into a static PIE:
    // std.pie relocates it, reading `_DYNAMIC` PC-relative before then.
    const pie_main = b.addRunArtifact(zap);
    pie_main.addArgs(&.{ "build-obj", "-fPIE" });
    pie_main.addFileArg(b.path("test/obj/args.zig"));
    const pie_main_o = pie_main.addPrefixedOutputFileArg("-femit-bin=", "args.o");
    const pie_exe = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-fPIE", "-fno-llvm", "-fno-lld" });
    pie_exe.addFileArg(pie_main_o);
    const pie_exe_bin = pie_exe.addPrefixedOutputFileArg("-femit-bin=", "args");
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
        const tls = b.addRunArtifact(zap);
        tls.addArgs(&.{ "build-obj", mode });
        tls.addFileArg(b.path("test/obj/tls.zig"));
        const tls_o = tls.addPrefixedOutputFileArg("-femit-bin=", "tls.o");
        const tls_run = if (std.mem.eql(u8, mode, "-fPIC")) run: {
            const tls_so = b.addSystemCommand(&.{ upstreamZig(b), "build-lib", "-dynamic", "--name", "zaptls" });
            tls_so.addFileArg(tls_o);
            const tls_so_file = tls_so.addPrefixedOutputFileArg("-femit-bin=", "libzaptls.so");
            const tls_host = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-lc", "-rdynamic" });
            tls_host.addFileArg(b.path("test/obj/tls_main.zig"));
            tls_host.addFileArg(tls_so_file);
            const r = b.addSystemCommand(&.{ "sh", "-c", "LD_LIBRARY_PATH=$(dirname \"$1\") exec \"$2\"", "sh" });
            r.addFileArg(tls_so_file);
            r.addFileArg(tls_host.addPrefixedOutputFileArg("-femit-bin=", "tls_main"));
            break :run r;
        } else run: {
            const tls_exe = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-fno-llvm", "-fno-lld", if (std.mem.eql(u8, mode, "-fPIE")) "-fPIE" else "-fno-PIE" });
            tls_exe.addFileArg(b.path("test/obj/tls_main.zig"));
            tls_exe.addFileArg(tls_o);
            const r = std.Build.Step.Run.create(b, "run tls_main");
            r.addFileArg(tls_exe.addPrefixedOutputFileArg("-femit-bin=", "tls_main"));
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
        cache.setName(b.fmt("zap {s} cache", .{cmd}));
        cache.addFileArg(b.path("test/obj/cache.sh"));
        cache.addArtifactArg(zap);
        cache.addFileArg(b.path("test/obj/lib.zig"));
        _ = cache.addOutputDirectoryArg("work");
        cache.addArg(cmd);
        cache.addDirectoryArg(std_zir);
        cache.addCheck(.{ .expect_term = .{ .exited = 0 } });
        takes(b, &cache.step, 25);
        test_step.dependOn(&cache.step);
    }

    const zap_run = b.addRunArtifact(zap);
    zap_run.setName("zap run args");
    zap_run.addArg("run");
    zap_run.addFileArg(b.path("test/obj/args.zig"));
    zap_run.addArg("--global-cache-dir");
    _ = zap_run.addOutputDirectoryArg("run-cache");
    zap_run.addArgs(&.{ "--", "a", "b c", "" });
    zap_run.addCheck(.{ .expect_stdout_exact = "[a][b c][]\n" });
    zap_run.addCheck(.{ .expect_term = .{ .exited = 43 } });
    takes(b, &zap_run.step, 5);
    test_step.dependOn(&zap_run.step);

    // Modules rooted at a ZON file and at a plain file.
    const mods = b.addRunArtifact(zap);
    mods.addArgs(&.{ "build-exe", "--dep", "config", "--dep", "version", "--dep", "back" });
    mods.addPrefixedFileArg("-Mapp=", b.path("test/obj/modules.zig"));
    mods.addPrefixedFileArg("-Mconfig=", b.path("test/obj/mod/config.zon"));
    mods.addPrefixedFileArg("-Mversion=", b.path("test/obj/mod/version"));
    mods.addArgs(&.{ "--dep", "app" });
    mods.addPrefixedFileArg("-Mback=", b.path("test/obj/mod/back.zig"));
    const mods_bin = mods.addPrefixedOutputFileArg("-femit-bin=", "modules");
    const mods_run = std.Build.Step.Run.create(b, "run modules");
    mods_run.addFileArg(mods_bin);
    mods_run.addCheck(.{ .expect_stdout_exact = "zap 3 0.17.0-dev 31 31 app\n" });
    mods_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&mods_run.step);

    // `@src()` names the root module by its `-M` name; a second build
    // (`zap run` without `-M`) shares the first one's global cache, so it
    // takes the first as its donor if the donor key lets it.
    const src_app = b.addRunArtifact(zap);
    src_app.setName("zap run @src module app");
    src_app.addArg("run");
    src_app.addPrefixedFileArg("-Mapp=", b.path("test/obj/mod/srcmod.zig"));
    src_app.addArg("--global-cache-dir");
    const src_cache = src_app.addOutputDirectoryArg("src-module-cache");
    src_app.addCheck(.{ .expect_stdout_exact = "app\n" });
    takes(b, &src_app.step, 5);
    const src_stem = b.addRunArtifact(zap);
    src_stem.setName("zap run @src module stem");
    src_stem.addArg("run");
    src_stem.addFileArg(b.path("test/obj/mod/srcmod.zig"));
    src_stem.addArg("--global-cache-dir");
    src_stem.addDirectoryArg(src_cache);
    src_stem.addCheck(.{ .expect_stdout_exact = "srcmod\n" });
    test_step.dependOn(&src_stem.step);

    // A module under test that imports itself by its `-M` name. It is
    // named "root" like upstream's test runner, and another module "main";
    // the cache check fails if a module shares a cache key with the test
    // runner or the module under test.
    const self_test = b.addRunArtifact(zap);
    self_test.setName("zap test self import");
    self_test.setEnvironmentVariable("ZAP_CACHE_CHECK", "1");
    self_test.addArgs(&.{ "test", "--dep", "self=root", "--dep", "main" });
    self_test.addPrefixedFileArg("-Mroot=", b.path("test/obj/mod/self.zig"));
    self_test.addPrefixedFileArg("-Mmain=", b.path("test/obj/mod/seven.zig"));
    self_test.addArg("--global-cache-dir");
    _ = self_test.addOutputDirectoryArg("self-test-cache");
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
    const user_test = b.addRunArtifact(zap);
    user_test.setName("zap test a std user");
    user_test.addArgs(&.{ "test", "--zig-lib-dir", lib_dir, "--test-filter", "Allocating" });
    user_test.addFileArg(b.path("test/obj/writer_test.zig"));
    user_test.addArg("--global-cache-dir");
    const std_cache = user_test.addOutputDirectoryArg("std-test-cache");
    user_test.addCheck(.{ .expect_stderr_match = "All 1 tests passed." });
    const std_test = b.addRunArtifact(zap);
    std_test.setName("zap test std after a std user");
    std_test.setEnvironmentVariable("ZAP_CACHE_CHECK", "1");
    std_test.addArgs(&.{ "test", "--zig-lib-dir", lib_dir, "--test-filter", "Allocating" });
    std_test.addFileArg(.{ .cwd_relative = b.pathJoin(&.{ lib_dir, "std", "std.zig" }) });
    std_test.addArg("--global-cache-dir");
    std_test.addDirectoryArg(std_cache);
    std_test.addCheck(.{ .expect_stderr_match = "tests passed." });
    std_test.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&std_test.step);
}

/// `zap build` end to end: test/build/check.sh builds test/build/hello
/// with zap as the build runner's compiler, in the default global cache,
/// where zap keeps the build runner it compiles once per zap binary. Its
/// first part compiles the runner; the others wait for it and run at once,
/// shape after `translate_c` has compiled translate-c there.
fn addBuildTest(b: *std.Build, zap: *std.Build.Step.Compile, build_web_wasm: std.Build.LazyPath, translate_c: ?*std.Build.Step) *std.Build.Step {
    const host = b.graph.host.result;
    const step = b.step("test-build", "Check `zap build` end to end on test/build/hello");
    if (host.cpu.arch != .x86_64 or host.os.tag != .linux) return step;
    var first: ?*std.Build.Step = null;
    for ([_][]const u8{ "build", "shape", "fuzz", "misc" }, [_]u32{ 32, 5, 20, 8 }) |part, seconds| {
        const run = b.addSystemCommand(&.{"sh"});
        run.setName(b.fmt("zap build test/build/hello ({s})", .{part}));
        run.addFileArg(b.path("test/build/check.sh"));
        run.addArtifactArg(zap);
        run.addDirectoryArg(b.path("test/build/hello"));
        _ = run.addOutputDirectoryArg("work");
        run.addFileArg(build_web_wasm);
        run.addArg(part);
        run.addCheck(.{ .expect_term = .{ .exited = 0 } });
        takes(b, &run.step, seconds);
        if (first) |f| run.step.dependOn(f) else first = &run.step;
        if (std.mem.eql(u8, part, "shape")) if (translate_c) |tc| run.step.dependOn(tc);
        step.dependOn(&run.step);
    }
    return step;
}

/// The build runner starts a ready step on a worker thread only while one
/// of its `-j` workers (default: one fewer than the CPUs) is free, and
/// otherwise runs it at once in the thread that made it ready. When zap is
/// built, that one thread would make the few hundred steps that run zap
/// ready and run most of them itself, one after another, while the other
/// workers sat idle (measured: 1.4 steps busy on average on 4 CPUs).
/// Instead each step that runs zap waits for one of `-j` gates, which wait
/// for zap and then `first`, so that each gate's thread runs its share,
/// dealt heaviest first to the gate with the least work so far by `takes`
/// (the runner shuffles the order each gate runs them in). Their waits on zap and `first` move to the gate: the thread
/// that finished either would run the step otherwise. (A step that waits
/// for another of them, as test/build's parts do, runs on that one's
/// thread.)
fn spreadZapUsers(b: *std.Build, zap: *std.Build.Step, first: *std.Build.Step, roots: []const *std.Build.Step) void {
    const Step = std.Build.Step;
    const workers = @max(1, (std.Thread.getCpuCount() catch 1) -| 1);
    const gates = b.allocator.alloc(*Step, workers) catch @panic("OOM");
    const loads = b.allocator.alloc(usize, workers) catch @panic("OOM");
    for (gates, loads, 0..) |*g, *load, i| {
        const gate = b.allocator.create(Step.TopLevel) catch @panic("OOM");
        gate.* = .{ .step = .init(.{ .tag = .top_level, .name = b.fmt("zap users {d}", .{i}), .owner = b }), .description = "" };
        gate.step.dependOn(first);
        g.* = &gate.step;
        load.* = 0;
    }
    var seen: std.AutoArrayHashMapUnmanaged(*Step, void) = .empty;
    var users: std.ArrayList(*Step) = .empty;
    for (roots) |r| seen.put(b.allocator, r, {}) catch @panic("OOM");
    var i: usize = 0;
    while (i < seen.count()) : (i += 1) {
        const s = seen.keys()[i];
        for (s.dependencies.items) |d| seen.put(b.allocator, d, {}) catch @panic("OOM");
        if (s != first and std.mem.indexOfScalar(*Step, s.dependencies.items, zap) != null) users.append(b.allocator, s) catch @panic("OOM");
    }
    std.mem.sort(*Step, users.items, {}, struct {
        fn heavier(_: void, x: *Step, y: *Step) bool {
            return stepSeconds(x) > stepSeconds(y);
        }
    }.heavier);
    for (users.items) |s| {
        const least = std.mem.indexOfMin(usize, loads);
        for (s.dependencies.items) |*d| {
            if (d.* == zap or d.* == first) d.* = gates[least];
        }
        loads[least] += stepSeconds(s);
    }
}

/// About how many seconds a step that runs zap takes with a Debug zap on a
/// 4-CPU orb, where it is more than 1, for `spreadZapUsers`.
var step_seconds: std.AutoHashMapUnmanaged(*std.Build.Step, u32) = .empty;

fn takes(b: *std.Build, s: *std.Build.Step, seconds: u32) void {
    step_seconds.put(b.allocator, s, seconds) catch @panic("OOM");
}

fn stepSeconds(s: *std.Build.Step) u32 {
    return step_seconds.get(s) orelse 1;
}

fn defaultZigLibDir(b: *std.Build) []const u8 {
    const io = b.graph.io;
    const zig = upstreamZig(b);
    const zig_exe = std.Io.Dir.cwd().realPathFileAlloc(io, zig, b.allocator) catch |err|
        std.debug.panic("unable to resolve zig executable path '{s}': {t}", .{ zig, err });
    return b.pathJoin(&.{ std.fs.path.dirname(zig_exe).?, "lib" });
}

/// lib/docs/wasm of `zig_lib_dir` compiled as upstream's compiler compiles
/// it for `-femit-docs` (`workerDocsWasm`): wasm32, ReleaseSmall, the same
/// CPU features. zap has no wasm backend, so upstream zig builds it, once.
fn docsWasm(b: *std.Build, zig_lib_dir: []const u8) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{
        upstreamZig(b),  "build-exe",
        "-target",       "wasm32-freestanding",
        "-mcpu",         "baseline+atomics+reference_types",
        "-OReleaseSmall", "-fno-entry",
        "-rdynamic",     "--name",
        "main",          "--dep",
        "Walk",
    });
    cmd.addPrefixedFileArg("-Mroot=", .{ .cwd_relative = b.pathJoin(&.{ zig_lib_dir, "docs", "wasm", "main.zig" }) });
    cmd.addPrefixedFileArg("-MWalk=", .{ .cwd_relative = b.pathJoin(&.{ zig_lib_dir, "docs", "wasm", "Walk.zig" }) });
    return cmd.addPrefixedOutputFileArg("-femit-bin=", "main.wasm");
}

/// lib/build-web of `zig_lib_dir` compiled as upstream's build runner
/// compiles it for its web UI (`buildClientWasm` in
/// lib/compiler/Maker/WebServer.zig): wasm32, ReleaseFast, the same CPU
/// features and modules, but stripped. Upstream zig builds it, as
/// `docsWasm`.
fn buildWebWasm(b: *std.Build, zig_lib_dir: []const u8) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{
        upstreamZig(b), "build-exe",
        "-target",      "wasm32-freestanding",
        "-mcpu",        "baseline+atomics+bulk_memory+multivalue+mutable_globals+nontrapping_fptoint+reference_types+sign_ext",
        "-OReleaseFast", "-fno-entry",
        "-rdynamic",    "-fsingle-threaded",
        // Without its DWARF: 0.4 MB in zap instead of 2.4 MB.
        "-fstrip",      "--name",
        "build-web",
        "--dep",        "Walk",
        "--dep",        "html_render",
    });
    cmd.addPrefixedFileArg("-Mroot=", .{ .cwd_relative = b.pathJoin(&.{ zig_lib_dir, "build-web", "main.zig" }) });
    cmd.addPrefixedFileArg("-MWalk=", .{ .cwd_relative = b.pathJoin(&.{ zig_lib_dir, "docs", "wasm", "Walk.zig" }) });
    cmd.addArgs(&.{ "--dep", "Walk" });
    cmd.addPrefixedFileArg("-Mhtml_render=", .{ .cwd_relative = b.pathJoin(&.{ zig_lib_dir, "docs", "wasm", "html_render.zig" }) });
    return cmd.addPrefixedOutputFileArg("-femit-bin=", "build-web.wasm");
}

/// Upstream zig, the oracle the tests compare zap with: the zig running
/// this build, or under `zap build` (no zig release next to the
/// compiler) `zig` on PATH.
/// C objects and archives that zap links into an executable
/// (docs/architecture.md, "Object, archive and shared-library inputs"):
/// upstream's `zig cc` and the system's `cc` compile them, non-PIC and
/// -fPIC, and the program must print what upstream's link of the same
/// inputs prints.
/// Returns the step that compiles translate-c with zap first.
fn addLinkInputTests(b: *std.Build, zap: *std.Build.Step.Compile, test_step: *std.Build.Step, std_zir: std.Build.LazyPath) ?*std.Build.Step {
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
                return c.addPrefixedOutputFileArg("-o", bb.fmt("{s}.o", .{src}));
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
            a.* = ar.addOutputFileArg(b.fmt("lib{s}.a", .{src[0..2]}));
            ar.addFileArg(compile(b, v.cc, src, &.{}));
        }
        const exe = b.addRunArtifact(zap);
        exe.setName(b.fmt("zap build-exe with {s} objects", .{v.name}));
        exe.addArg("build-exe");
        exe.addFileArg(b.path("test/link_input/main.zig"));
        for ([_]std.Build.LazyPath{ lib, tls, tlsie, archives[0] }) |input| exe.addFileArg(input);
        // The second archive by name (`-l`, `-L`).
        exe.addArg("-la2");
        exe.addPrefixedDirectoryArg("-L", archives[1].dirname());
        exe.setEnvironmentVariable("ZAP_CACHE", "off");
        const bin = exe.addPrefixedOutputFileArg("-femit-bin=", "main");
        const run = std.Build.Step.Run.create(b, b.fmt("run zap link of {s} objects", .{v.name}));
        run.addFileArg(bin);
        run.addCheck(.{ .expect_stderr_exact = expect });
        run.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&run.step);
        if (!std.mem.eql(u8, v.name, "zig cc")) continue;
        // The same sources given to zap, which compiles them with upstream's
        // Clang (CSource.zig), the archives too, as libraries of C only.
        for (&archives, [_][]const u8{ "a1", "a2" }) |*a, stem| {
            const lib_c = b.addRunArtifact(zap);
            lib_c.setName(b.fmt("zap build-lib of {s}.c", .{stem}));
            lib_c.addArgs(&.{ "build-lib", "-mcpu", "baseline", "--name", stem });
            lib_c.addFileArg(b.path(b.fmt("test/link_input/{s}.c", .{stem})));
            lib_c.setEnvironmentVariable("ZAP_ZIG", zig);
            a.* = lib_c.addPrefixedOutputFileArg("-femit-bin=", b.fmt("lib{s}.a", .{stem}));
        }
        // Upstream's archive of the same C is the same bytes, with its own
        // linker (with LLD, it writes llvm-ar's format).
        const up_lib = b.addSystemCommand(&.{ zig, "build-lib", "-fno-llvm", "-fno-lld", "-mcpu", "baseline", "--name", "a1" });
        up_lib.addFileArg(b.path("test/link_input/a1.c"));
        const up_a1 = up_lib.addPrefixedOutputFileArg("-femit-bin=", "liba1.a");
        const same = b.addSystemCommand(&.{"cmp"});
        same.setName("zap's archive of C is upstream's");
        same.addFileArg(archives[0]);
        same.addFileArg(up_a1);
        test_step.dependOn(&same.step);
        const src = b.addRunArtifact(zap);
        src.setName("zap build-exe with C sources");
        src.addArgs(&.{ "build-exe", "-cflags", "-fcommon", "--" });
        src.addFileArg(b.path("test/link_input/lib.c"));
        src.addArgs(&.{ "-cflags", "-fPIC", "--" });
        src.addFileArg(b.path("test/link_input/tls.c"));
        src.addFileArg(b.path("test/link_input/tlsie.c"));
        src.addFileArg(b.path("test/link_input/main.zig"));
        for (archives) |input| src.addFileArg(input);
        src.setEnvironmentVariable("ZAP_ZIG", zig);
        const src_bin = src.addPrefixedOutputFileArg("-femit-bin=", "main");
        const src_run = std.Build.Step.Run.create(b, "run zap build of C sources");
        src_run.addFileArg(src_bin);
        src_run.addCheck(.{ .expect_stderr_exact = expect });
        src_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&src_run.step);
    }

    // A C object calling glibc, in a -lc executable: its calls go through
    // stubs, its GOT loads through the imports' slots. Upstream compiles
    // C as -fPIC under -lc.
    const c = b.addSystemCommand(&.{ zig, "cc", "-fPIC", "-c" });
    c.addFileArg(b.path("test/link_input/libc.c"));
    const libc_o = c.addPrefixedOutputFileArg("-o", "libc.o");
    const exe = b.addRunArtifact(zap);
    exe.setName("zap build-exe -lc with a C object");
    exe.addArgs(&.{ "build-exe", "-lc", "-target", "x86_64-linux-gnu" });
    exe.addFileArg(b.path("test/link_input/libc_main.zig"));
    exe.addFileArg(libc_o);
    exe.setEnvironmentVariable("ZAP_CACHE", "off");
    exe.setEnvironmentVariable("ZAP_ZIG", zig);
    const run = std.Build.Step.Run.create(b, "run zap -lc link of a C object");
    run.addFileArg(exe.addPrefixedOutputFileArg("-femit-bin=", "main"));
    run.addCheck(.{ .expect_stdout_exact = "x=21 twice=42 len=3\nbye from atexit\nbye\n" });
    run.addCheck(.{ .expect_stderr_exact = "1 123\n" });
    run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&run.step);
    // The same C as a source of a -lc build, compiled by zap with upstream's
    // Clang and its Debug defaults (ubsan, PIC).
    const src_exe = b.addRunArtifact(zap);
    src_exe.setName("zap build-exe -lc with a C source");
    src_exe.addArgs(&.{ "build-exe", "-lc", "-target", "x86_64-linux-gnu" });
    src_exe.addFileArg(b.path("test/link_input/libc_main.zig"));
    src_exe.addFileArg(b.path("test/link_input/libc.c"));
    src_exe.setEnvironmentVariable("ZAP_ZIG", zig);
    const src_run = std.Build.Step.Run.create(b, "run zap -lc build of a C source");
    src_run.addFileArg(src_exe.addPrefixedOutputFileArg("-femit-bin=", "main"));
    src_run.addCheck(.{ .expect_stdout_exact = "x=21 twice=42 len=3\nbye from atexit\nbye\n" });
    src_run.addCheck(.{ .expect_stderr_exact = "1 123\n" });
    src_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&src_run.step);
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
            const tls_exe = b.addRunArtifact(zap);
            tls_exe.setName(b.fmt("zap build-exe{s} with a {s} -mtls-dialect=gnu2 object", .{ if (v.lc) " -lc" else "", v.name }));
            tls_exe.addArg("build-exe");
            if (v.lc) tls_exe.addArgs(&.{ "-lc", "-target", "x86_64-linux-gnu" });
            tls_exe.addFileArg(b.path("test/link_input/tlsdesc_main.zig"));
            tls_exe.addFileArg(obj.addPrefixedOutputFileArg("-o", "tlsdesc.o"));
            tls_exe.setEnvironmentVariable("ZAP_CACHE", "off");
            const tls_run = std.Build.Step.Run.create(b, b.fmt("run zap{s} link of a {s} -mtls-dialect=gnu2 object", .{ if (v.lc) " -lc" else "", v.name }));
            tls_run.addFileArg(tls_exe.addPrefixedOutputFileArg("-femit-bin=", "tlsdesc"));
            tls_run.addCheck(.{ .expect_stderr_exact = expect_tls });
            tls_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
            test_step.dependOn(&tls_run.step);
        }
    }
    // An executable of C only, as upstream builds one: its main is C's.
    {
        const cexe = b.addRunArtifact(zap);
        cexe.setName("zap build-exe -lc with only C sources");
        cexe.addArgs(&.{ "build-exe", "-lc", "-target", "x86_64-linux-gnu" });
        cexe.addFileArg(b.path("test/link_input/cmain.c"));
        cexe.setEnvironmentVariable("ZAP_ZIG", zig);
        const cexe_run = std.Build.Step.Run.create(b, "run zap -lc build of only C sources");
        cexe_run.addFileArg(cexe.addPrefixedOutputFileArg("-femit-bin=", "cmain"));
        cexe_run.addArg("5");
        cexe_run.addCheck(.{ .expect_stdout_exact = "argc=2 q=478165905515354922\n" });
        cexe_run.addCheck(.{ .expect_term = .{ .exited = 7 } });
        test_step.dependOn(&cexe_run.step);
    }
    // compiler_rt for C: f128 and f16 conversions, comparisons and
    // arithmetic, 128-bit division and lock-based atomics, which zap
    // generates from upstream's compiler_rt (baseline, so that f16 needs
    // it too). Two more objects reference a name nothing defines: one
    // error names both.
    {
        const rt_c = b.addSystemCommand(&.{ zig, "cc", "-mcpu=baseline", "-Wno-atomic-alignment", "-c" });
        rt_c.addFileArg(b.path("test/link_input/rt.c"));
        const rt_o = rt_c.addPrefixedOutputFileArg("-o", "rt.o");
        const rt_exe = b.addRunArtifact(zap);
        rt_exe.setName("zap build-exe with a C object calling compiler_rt");
        rt_exe.addArg("build-exe");
        rt_exe.addFileArg(b.path("test/link_input/rt_main.zig"));
        rt_exe.addFileArg(rt_o);
        rt_exe.setEnvironmentVariable("ZAP_CACHE", "off");
        const rt_run = std.Build.Step.Run.create(b, "run zap link of a C object calling compiler_rt");
        rt_run.addFileArg(rt_exe.addPrefixedOutputFileArg("-femit-bin=", "main"));
        rt_run.addCheck(.{ .expect_stderr_exact = "2.25 1 0 -6 0.375 1024 25 2.5\n" });
        rt_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&rt_run.step);
        const undef = b.addRunArtifact(zap);
        undef.setName("zap build-exe reports an undefined symbol once");
        undef.addArg("build-exe");
        undef.addFileArg(b.path("test/link_input/rt_main.zig"));
        undef.addFileArg(rt_o);
        for ([_][]const u8{ "undef1", "undef2" }) |name| {
            const u = b.addSystemCommand(&.{ zig, "cc", b.fmt("-DUNDEF={s}", .{name}), "-c" });
            u.addFileArg(b.path("test/link_input/undef.c"));
            undef.addFileArg(u.addPrefixedOutputFileArg("-o", b.fmt("{s}.o", .{name})));
        }
        undef.setEnvironmentVariable("ZAP_CACHE", "off");
        _ = undef.addPrefixedOutputFileArg("-femit-bin=", "main");
        undef.addCheck(.{ .expect_stderr_match = "undef1.o, " });
        undef.addCheck(.{ .expect_stderr_match = "undef2.o)\n" });
        undef.addCheck(.{ .expect_stderr_match = "\n1 error\n" });
        undef.addCheck(.{ .expect_term = .{ .exited = 1 } });
        test_step.dependOn(&undef.step);
    }
    {
        const dead = b.addRunArtifact(zap);
        dead.setName("zap build-exe links the data a discarded load reads");
        dead.addArg("build-exe");
        dead.addFileArg(b.path("test/link_input/dead_load.zig"));
        dead.setEnvironmentVariable("ZAP_CACHE", "off");
        _ = dead.addPrefixedOutputFileArg("-femit-bin=", "dead_load");
        dead.addCheck(.{ .expect_stderr_match = "undefined symbol: nope" });
        dead.addCheck(.{ .expect_term = .{ .exited = 1 } });
        test_step.dependOn(&dead.step);
    }
    // A C++ source with -lc++: libc++, libc++abi and libunwind built from
    // the lib directory as upstream builds them, exceptions through C++
    // frames, RTTI, a static constructor and thread_local.
    const cxx_exe = b.addRunArtifact(zap);
    cxx_exe.setName("zap build-exe -lc++ with a C++ source");
    cxx_exe.addArgs(&.{ "build-exe", "-lc++", "-target", "x86_64-linux-gnu" });
    cxx_exe.addFileArg(b.path("test/link_input/cxx_main.zig"));
    cxx_exe.addFileArg(b.path("test/link_input/cxx.cpp"));
    cxx_exe.setEnvironmentVariable("ZAP_ZIG", zig);
    const cxx_run = std.Build.Step.Run.create(b, "run zap -lc++ build of a C++ source");
    cxx_run.addFileArg(cxx_exe.addPrefixedOutputFileArg("-femit-bin=", "main"));
    cxx_run.addCheck(.{ .expect_stdout_exact = "caught: boom at depth 4\ntype: 7Derived\nctor 42, tls tls42!, sum 6\n" });
    cxx_run.addCheck(.{ .expect_stderr_exact = "result 151, link_libcpp true\n" });
    cxx_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&cxx_run.step);

    // translate-c with a system library takes the native include
    // directories (here NIX_CFLAGS_COMPILE's) ahead of the user's
    // -isystem, as upstream's `native_system_include_paths`.
    const tc_native = b.addRunArtifact(zap);
    tc_native.setName("zap translate-c -l<lib> takes the native include directories");
    tc_native.addArgs(&.{ "translate-c", "-lfoo", "-isystem" });
    tc_native.addDirectoryArg(b.path("test/link_input/tc_native/shadow"));
    tc_native.addFileArg(b.path("test/link_input/tc_native/s.h"));
    tc_native.setCwd(b.path("."));
    tc_native.setEnvironmentVariable("NIX_CFLAGS_COMPILE", "-isystem test/link_input/tc_native/sys");
    tc_native.addCheck(.{ .expect_stdout_match = "pub extern fn tcn_native() c_int;" });
    takes(b, &tc_native.step, 13);
    test_step.dependOn(&tc_native.step);
    // SysV aggregates between Zig and C both ways: INTEGER, SSE and mixed
    // eightbytes, odd sizes, MEMORY, registers running out, a function
    // pointer, and variadic aggregates. Upstream prints the same except
    // `zig_va`, whose @cVaArg of aggregates its self-hosted backend gets
    // wrong (32791); C's answer is 55.
    const abi_exe = b.addRunArtifact(zap);
    abi_exe.setName("zap build-exe with C aggregates");
    abi_exe.addArgs(&.{ "build-exe", "-lc", "-target", "x86_64-linux-gnu" });
    abi_exe.addFileArg(b.path("test/link_input/abi_main.zig"));
    abi_exe.addFileArg(b.path("test/link_input/abi.c"));
    abi_exe.setEnvironmentVariable("ZAP_ZIG", zig);
    const abi_run = std.Build.Step.Run.create(b, "run zap build with C aggregates");
    abi_run.addFileArg(abi_exe.addPrefixedOutputFileArg("-femit-bin=", "main"));
    abi_run.addCheck(.{ .expect_stdout_exact = "c_s16 1 2 0.5 1.5 4 5 6\nc_mix 7 0.5 3.25 9.5 10 11 12 13 14 15\nc_dsi 5 1 2 3 4 5 6 7 8 9\nptr 30 60\nzig_mix 103 101.5 102.25\nzig_dsi 0.75 1 2 3\nzig_va 55\n" });
    abi_run.addCheck(.{ .expect_stderr_exact = "2 3 | 14 1 6.5 | 1.5 2.5 3.5 | 3 2 1 | 0.25 { 7, 8, 9 }\nc_va 55\nzig_s16 10 20 0.5 0.25 1 2 3\nzig_mix 3 1.5 2.25 4.5 { 1, 2, 3 } 4 5 6\nzig_dsi 9 1 2 3 4 5 6 7 8 9\n" });
    abi_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&abi_run.step);

    // The Win64 convention (`.x86_64_win`, C's ms_abi) both ways.
    const win_exe = b.addRunArtifact(zap);
    win_exe.setName("zap build-exe with Win64 calls");
    win_exe.addArgs(&.{ "build-exe", "-lc", "-target", "x86_64-linux-gnu" });
    win_exe.addFileArg(b.path("test/link_input/win64_main.zig"));
    win_exe.addFileArg(b.path("test/link_input/win64.c"));
    win_exe.setEnvironmentVariable("ZAP_ZIG", zig);
    const win_run = std.Build.Step.Run.create(b, "run zap build with Win64 calls");
    win_run.addFileArg(win_exe.addPrefixedOutputFileArg("-femit-bin=", "main"));
    win_run.addCheck(.{ .expect_stdout_exact = "c_win_mix 1 2.5 3 4 5.5 6 7 8 9.5 10.5 11 12.5\nva u64 1\nva f64 2.5\nva u64 3\nva f64 4.5\nzig via ptr 32.5\nzig byref 15 77\nzig va 109.75 42\n" });
    win_run.addCheck(.{ .expect_stderr_exact = "byref 42 9 mix 32.5 s8 2 1 u128 80000000000000000\nzig_win_mix 1 2.5 3 4 5.5 6 7 8 9.5 10.5 11 12.5\nsum 42\n" });
    win_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&win_run.step);

    // Bool vectors of 65 to 128 elements as C arguments, one GPR each.
    const vb_exe = b.addRunArtifact(zap);
    vb_exe.setName("zap build-exe with C bool vectors");
    vb_exe.addArgs(&.{ "build-exe", "-lc", "-target", "x86_64-linux-gnu" });
    vb_exe.addFileArg(b.path("test/link_input/vecbool_main.zig"));
    vb_exe.addFileArg(b.path("test/link_input/vecbool.c"));
    vb_exe.setEnvironmentVariable("ZAP_ZIG", zig);
    const vb_run = std.Build.Step.Run.create(b, "run zap build with C bool vectors");
    vb_run.addFileArg(vb_exe.addPrefixedOutputFileArg("-femit-bin=", "main"));
    vb_run.addCheck(.{ .expect_stdout_exact = "c_v 10010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010011\nc_iv 1 2 3 4  10010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010011\nc_v7 1 2 3 4 5 6 7  10010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010011\nc_v 10010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010010011\n" });
    vb_run.addCheck(.{ .expect_stderr_exact = "zig_v 01001010010100101001010010100101001010010100101001010010100101001010010100101001010010100101001010010100101001010010100101001010\nzig_iv -1 -2 -3 -4 01001010010100101001010010100101001010010100101001010010100101001010010100101001010010100101001010010100101001010010100101001010\nzig_v 01001010010100101001010010100101001010010100101001010010100101001010010100101001010010100101001010010100101001010010100101001010\n" });
    vb_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&vb_run.step);

    // GCC's -fPIE reads glibc's data PC-relative: the executable copies
    // `stdout` and `environ` (with its aliases, which glibc's start code
    // sets), and glibc, C and Zig all use the copies.
    if (cc) |gcc| {
        const cc_copy = b.addSystemCommand(&.{ gcc, "-fPIE", "-c" });
        cc_copy.addFileArg(b.path("test/link_input/copy.c"));
        const copy_exe = b.addRunArtifact(zap);
        copy_exe.addArgs(&.{ "build-exe", "-lc", "-target", "x86_64-linux-gnu" });
        copy_exe.addFileArg(b.path("test/link_input/copy_main.zig"));
        copy_exe.addFileArg(cc_copy.addPrefixedOutputFileArg("-o", "copy.o"));
        copy_exe.setEnvironmentVariable("ZAP_CACHE", "off");
        const r = std.Build.Step.Run.create(b, "run zap link of copied glibc data");
        r.addFileArg(copy_exe.addPrefixedOutputFileArg("-femit-bin=", "main"));
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
        const lib_dir = so.addPrefixedOutputFileArg("-o", "libshared.so").dirname();
        const user = b.addSystemCommand(if (cc) |gcc| &.{ gcc, "-fPIE", "-c" } else &.{ zig, "cc", "-c" });
        user.addFileArg(b.path("test/link_input/shared_user.c"));
        const so_exe = b.addRunArtifact(zap);
        so_exe.addArgs(&.{ "build-exe", "-lc", "-lshared" });
        so_exe.addPrefixedDirectoryArg("-L", lib_dir);
        so_exe.addFileArg(b.path("test/link_input/shared_main.zig"));
        so_exe.addFileArg(user.addPrefixedOutputFileArg("-o", "shared_user.o"));
        so_exe.setEnvironmentVariable("ZAP_CACHE", "off");
        const r = std.Build.Step.Run.create(b, "run zap link of a shared library");
        r.addFileArg(so_exe.addPrefixedOutputFileArg("-femit-bin=", "main"));
        r.addCheck(.{ .expect_stderr_exact = "42 143 42 143\n" });
        r.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&r.step);
    }

    // Constructors run in priority order across two objects, before main;
    // the destructor runs only with -lc, whose exit runs the fini array.
    var ctors: [2]std.Build.LazyPath = undefined;
    for (&ctors, [_][]const u8{ "-USECOND", "-DSECOND" }, 0..) |*o, def, i| {
        const cc_ctor = b.addSystemCommand(&.{ zig, "cc", "-fPIC", def, "-c" });
        cc_ctor.addFileArg(b.path("test/link_input/ctor.c"));
        o.* = cc_ctor.addPrefixedOutputFileArg("-o", b.fmt("ctor{d}.o", .{i}));
    }
    for ([_][]const []const u8{ &.{"build-exe"}, &.{ "build-exe", "-lc", "-target", "x86_64-linux-gnu" } }, [_][]const u8{ "", "fini\n" }) |args, fini| {
        const ctor_exe = b.addRunArtifact(zap);
        ctor_exe.addArgs(args);
        ctor_exe.addFileArg(b.path("test/link_input/ctor_main.zig"));
        for (ctors) |o| ctor_exe.addFileArg(o);
        ctor_exe.setEnvironmentVariable("ZAP_CACHE", "off");
        const r = std.Build.Step.Run.create(b, b.fmt("run zap link of C constructors{s}", .{if (fini.len == 0) "" else " with -lc"}));
        r.addFileArg(ctor_exe.addPrefixedOutputFileArg("-femit-bin=", "main"));
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
        o.* = as.addPrefixedOutputFileArg("-o", b.fmt("{s}.o", .{src[0..7]}));
    }
    for ([_][2]usize{ .{ 0, 1 }, .{ 1, 0 } }, [_][]const u8{ "11 11\n", "22 22\n" }) |order, expect_comdat| {
        const comdat_exe = b.addRunArtifact(zap);
        comdat_exe.addArg("build-exe");
        comdat_exe.addFileArg(b.path("test/link_input/comdat_main.zig"));
        for (order) |k| comdat_exe.addFileArg(comdats[k]);
        comdat_exe.setEnvironmentVariable("ZAP_CACHE", "off");
        const r = std.Build.Step.Run.create(b, b.fmt("run zap link of COMDAT groups ({d} first)", .{order[0] + 1}));
        r.addFileArg(comdat_exe.addPrefixedOutputFileArg("-femit-bin=", "main"));
        r.addCheck(.{ .expect_stderr_exact = expect_comdat });
        r.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&r.step);
    }

    // Undefined behavior and a smashed stack in C reach ubsan_rt's and the
    // stack protector's panics.
    const ub = b.addSystemCommand(&.{ zig, "cc", "-fstack-protector-all", "-fno-sanitize=bounds", "-c" });
    ub.addFileArg(b.path("test/link_input/ub.c"));
    const ub_o = ub.addPrefixedOutputFileArg("-o", "ub.o");
    const ub_exe = b.addRunArtifact(zap);
    ub_exe.addArg("build-exe");
    ub_exe.addFileArg(b.path("test/link_input/ub_main.zig"));
    ub_exe.addFileArg(ub_o);
    ub_exe.setEnvironmentVariable("ZAP_CACHE", "off");
    const ub_bin = ub_exe.addPrefixedOutputFileArg("-femit-bin=", "main");
    // The trace shows the C frame's line, from the object's DWARF, and
    // unwinds through it by its .eh_frame FDE.
    const trace_o = [_][]const u8{ "panic: signed integer overflow: 5 + 2147483647 cannot be represented in type 'int'\n", "ub.c:2:34: 0x", " in c_overflow (", "ub_main.zig:10:63: 0x" };
    for ([_]struct { []const u8, []const []const u8 }{ .{ "o", &trace_o }, .{ "s", &.{"panic: stack smashing detected\n"} } }) |case| {
        const r = std.Build.Step.Run.create(b, b.fmt("run zap link of a C object ({s})", .{case[0]}));
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
        cache.setName(b.fmt("zap build-exe with link inputs, cached ({s})", .{part}));
        cache.addFileArg(b.path("test/link_input/cache.sh"));
        cache.addArtifactArg(zap);
        cache.addArg(zig);
        cache.addDirectoryArg(b.path("test/link_input"));
        _ = cache.addOutputDirectoryArg("work");
        cache.addArg(part);
        cache.addDirectoryArg(std_zir);
        cache.addCheck(.{ .expect_term = .{ .exited = 0 } });
        takes(b, &cache.step, if (std.mem.eql(u8, part, "objects")) 38 else 18);
        test_step.dependOn(&cache.step);
    }
    return &tc_native.step;
}

fn upstreamZig(b: *std.Build) []const u8 {
    const io = b.graph.io;
    const zig_exe = b.graph.zig_exe;
    const real = std.Io.Dir.cwd().realPathFileAlloc(io, zig_exe, b.allocator) catch zig_exe;
    if (std.Io.Dir.cwd().access(io, b.pathJoin(&.{ std.fs.path.dirname(real) orelse ".", "lib", "std", "std.zig" }), .{})) |_| return zig_exe else |_| {}
    return b.findProgram(.{ .names = &.{"zig"} }) orelse std.debug.panic("'{s}' is not upstream zig, and no zig is on PATH", .{zig_exe});
}
