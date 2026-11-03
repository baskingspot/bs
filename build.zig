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
    const test_step = b.step("test", "Run zap's unit tests and run tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    const upstream_step = b.step("test-upstream", "Run the run tests with upstream zig, the oracle");
    addRunTests(b, exe, test_step, upstream_step);
    addObjAndRunTests(b, exe, test_step);
    addDiagTests(b, exe, test_step, upstream_step);
    addBuildTest(b, exe);

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
///                               then without again, then as it is, then
///                               once more with nothing changed, all in the
///                               same place reusing its cache, and checks
///                               the last build. The edit builds compare
///                               themselves with full builds
///                               (`ZAP_CACHE_VERIFY`, `ZAP_CACHE_CHECK`).
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
///
/// `test` builds each with zap and checks it; `test-upstream` does the same
/// with upstream zig, so every program is checked against the oracle.
fn addRunTests(b: *std.Build, zap: *std.Build.Step.Compile, test_step: *std.Build.Step, upstream_step: *std.Build.Step) void {
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
            } else if (std.mem.eql(u8, key, "donor-without")) {
                expect.donor_without = std.zig.string_literal.parseAlloc(b.allocator, value) catch std.debug.panic("{s}: bad string", .{src_path});
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

        for ([_]bool{ false, true }) |upstream| {
            const compile = if (upstream) blk: {
                const r = b.addSystemCommand(&.{ upstreamZig(b), "build-exe", "-fno-llvm", "-fno-lld" });
                r.addFileArg(b.path(src_path));
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
                const zap_cmd = b.fmt("\"$5\" build-exe -target x86_64-linux \"$4.d/{s}\" -femit-bin=\"$4\"{s} 2>\"$4.d/log\" || {{ cat \"$4.d/log\" >&2; exit 1; }}", .{ file, lib_flag });
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
                    \\{[lib_after]s}ZAP_CACHE_VERIFY=1 ZAP_CACHE_CHECK=1 {[zap]s}
                    \\{[zap]s}
                , .{ .setup = lib_setup, .file = file, .lib_before = lib_before, .lib_after = lib_after, .zap = zap_cmd }), "sh" });
                r.addFileArg(before);
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
                    \\cp "$1" "$4.d/a/{[file]s}"
                    \\cp "$2" "$4.d/b/{[file]s}"
                    \\fail() {{ cat "$4.d/log" >&2; exit 1; }}
                    \\{[zap]s} --cache-dir "$4.d/la" "$4.d/a/{[file]s}" -femit-bin="$4.d/a/out" 2>"$4.d/log" || fail
                    \\ZAP_CACHE_TIMING=1 ZAP_CACHE_CHECK=1 {[zap]s} --cache-dir "$4.d/lb" "$4.d/b/{[file]s}" -femit-bin="$4" 2>"$4.d/log" || fail
                    \\grep -q "replaying donor" "$4.d/log" || {{ echo "no donor was replayed" >&2; fail; }}
                    \\cp "$4" "$4.d/replayed"
                    \\ZAP_CACHE_VERIFY=full ZAP_CACHE_CHECK=1 {[zap]s} --cache-dir "$4.d/lb" "$4.d/b/{[file]s}" -femit-bin="$4" 2>"$4.d/log" || fail
                    \\cmp "$4" "$4.d/replayed" >&2
                , .{ .file = file, .zap = zap_cmd }), "sh" });
                r.addFileArg(donor);
                r.addFileArg(b.path(src_path));
                r.addFileArg(b.path("test/run/rt.zig"));
                break :blk r;
            } else blk: {
                const r = b.addRunArtifact(zap);
                r.addArgs(&.{ "build-exe", "-target", "x86_64-linux" });
                r.addFileArg(b.path(src_path));
                break :blk r;
            };
            compile.addFileInput(b.path("test/run/rt.zig"));
            const bin = if (!upstream and (expect.rebuild_without.items.len != 0 or expect.lib_edit != null or expect.donor_without != null)) bin: {
                const out = compile.addOutputFileArg(name);
                compile.addArtifactArg(zap);
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
fn addDiagTests(b: *std.Build, zap: *std.Build.Step.Compile, test_step: *std.Build.Step, upstream_step: *std.Build.Step) void {
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
        test_step.dependOn(&run.step);

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
/// stack trace needs the object's debug info. `zap run`: test/obj/args.zig,
/// whose arguments and exit status must pass through.
fn addObjAndRunTests(b: *std.Build, zap: *std.Build.Step.Compile, test_step: *std.Build.Step) void {
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

    const zap_run = b.addRunArtifact(zap);
    zap_run.setName("zap run args");
    zap_run.addArg("run");
    zap_run.addFileArg(b.path("test/obj/args.zig"));
    zap_run.addArg("--global-cache-dir");
    _ = zap_run.addOutputDirectoryArg("run-cache");
    zap_run.addArgs(&.{ "--", "a", "b c", "" });
    zap_run.addCheck(.{ .expect_stdout_exact = "[a][b c][]\n" });
    zap_run.addCheck(.{ .expect_term = .{ .exited = 43 } });
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
    mods_run.addCheck(.{ .expect_stdout_exact = "zap 3 0.17.0-dev 31 31\n" });
    mods_run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&mods_run.step);

    // A module under test that imports itself by its `-M` name. Named
    // "root" like upstream's test runner; the cache check fails if the two
    // modules share a cache key.
    const self_test = b.addRunArtifact(zap);
    self_test.setName("zap test self import");
    self_test.setEnvironmentVariable("ZAP_CACHE_CHECK", "1");
    self_test.addArgs(&.{ "test", "--dep", "self=root" });
    self_test.addPrefixedFileArg("-Mroot=", b.path("test/obj/mod/self.zig"));
    self_test.addArg("--global-cache-dir");
    _ = self_test.addOutputDirectoryArg("self-test-cache");
    self_test.addCheck(.{ .expect_stderr_match = "All 1 tests passed." });
    self_test.addCheck(.{ .expect_term = .{ .exited = 0 } });
    test_step.dependOn(&self_test.step);
}

/// `zap build` end to end: test/build/check.sh builds test/build/hello
/// with zap as the build runner's compiler, in the default global cache,
/// where zap keeps the build runner it compiles once per zap binary.
fn addBuildTest(b: *std.Build, zap: *std.Build.Step.Compile) void {
    const host = b.graph.host.result;
    const step = b.step("test-build", "Check `zap build` end to end on test/build/hello");
    if (host.cpu.arch != .x86_64 or host.os.tag != .linux) return;
    const run = b.addSystemCommand(&.{"sh"});
    run.setName("zap build test/build/hello");
    run.addFileArg(b.path("test/build/check.sh"));
    run.addArtifactArg(zap);
    run.addDirectoryArg(b.path("test/build/hello"));
    _ = run.addOutputDirectoryArg("work");
    run.addCheck(.{ .expect_term = .{ .exited = 0 } });
    step.dependOn(&run.step);
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

/// Upstream zig, the oracle the tests compare zap with: the zig running
/// this build, or under `zap build` (no zig release next to the
/// compiler) `zig` on PATH.
fn upstreamZig(b: *std.Build) []const u8 {
    const io = b.graph.io;
    const zig_exe = b.graph.zig_exe;
    const real = std.Io.Dir.cwd().realPathFileAlloc(io, zig_exe, b.allocator) catch zig_exe;
    if (std.Io.Dir.cwd().access(io, b.pathJoin(&.{ std.fs.path.dirname(real) orelse ".", "lib", "std", "std.zig" }), .{})) |_| return zig_exe else |_| {}
    return b.findProgram(.{ .names = &.{"zig"} }) orelse std.debug.panic("'{s}' is not upstream zig, and no zig is on PATH", .{zig_exe});
}
