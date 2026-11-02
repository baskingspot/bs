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

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{ .name = "zap", .root_module = exe_mod });
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
}

/// Each `test/run/*.zig` program (other than the shared `rt.zig`) starts
/// with `//!` header lines giving its expected behavior:
///
///   //! exit: <code>            exit status
///   //! stdout: "<zig string>"  exact standard output
///   //! signal: <SIG>           killed by this signal instead (zap)
///   //! stderr: "<zig string>"  exact standard error
///   //! upstream-signal: <SIG>  the signal under upstream zig, where it
///                               differs (upstream's panic handler needs
///                               std.start, which these programs bypass)
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
        const source = dir.readFileAlloc(io, file, b.allocator, .limited(1 << 20)) catch |err|
            std.debug.panic("unable to read {s}: {t}", .{ src_path, err });
        var expect: struct {
            exit: ?u8 = null,
            signal: ?std.posix.SIG = null,
            upstream_signal: ?std.posix.SIG = null,
            stdout: ?[]const u8 = null,
            stderr: ?[]const u8 = null,
        } = .{};
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "//! ")) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const key = line[4..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " ");
            if (std.mem.eql(u8, key, "exit")) {
                expect.exit = std.fmt.parseInt(u8, value, 10) catch std.debug.panic("{s}: bad exit code", .{src_path});
            } else if (std.mem.eql(u8, key, "signal") or std.mem.eql(u8, key, "upstream-signal")) {
                const sig = std.meta.stringToEnum(std.posix.SIG, value) orelse std.debug.panic("{s}: bad signal", .{src_path});
                if (key[0] == 's') expect.signal = sig else expect.upstream_signal = sig;
            } else if (std.mem.eql(u8, key, "stdout") or std.mem.eql(u8, key, "stderr")) {
                const bytes = std.zig.string_literal.parseAlloc(b.allocator, value) catch std.debug.panic("{s}: bad string", .{src_path});
                if (key[3] == 'o') expect.stdout = bytes else expect.stderr = bytes;
            }
        }
        if (expect.exit == null and expect.signal == null) std.debug.panic("{s}: missing '//! exit:' or '//! signal:' header", .{src_path});

        for ([_]bool{ false, true }) |upstream| {
            const compile = if (upstream) blk: {
                const r = b.addSystemCommand(&.{ b.graph.zig_exe, "build-exe", "-fno-llvm", "-fno-lld" });
                r.addFileArg(b.path(src_path));
                break :blk r;
            } else blk: {
                const r = b.addRunArtifact(zap);
                r.addArg("build-exe");
                r.addFileArg(b.path(src_path));
                break :blk r;
            };
            compile.addFileInput(b.path("test/run/rt.zig"));
            const bin = compile.addPrefixedOutputFileArg("-femit-bin=", name);
            if (!upstream and !host_runs_zap_output) {
                // zap emits x86_64-linux executables; elsewhere only check
                // that they compile.
                test_step.dependOn(&compile.step);
                continue;
            }
            const run = std.Build.Step.Run.create(b, b.fmt("run {s}{s}", .{ name, if (upstream) " (upstream)" else "" }));
            run.addFileArg(bin);
            if (expect.stdout) |out| run.addCheck(.{ .expect_stdout_exact = out });
            if (upstream and expect.upstream_signal != null) {
                run.addCheck(.{ .expect_term = .{ .signal = expect.upstream_signal.? } });
            } else {
                if (expect.stderr) |err| run.addCheck(.{ .expect_stderr_exact = err });
                run.addCheck(.{ .expect_term = if (expect.signal) |sig| .{ .signal = sig } else .{ .exited = expect.exit.? } });
            }
            (if (upstream) upstream_step else test_step).dependOn(&run.step);
        }
    }
}

fn defaultZigLibDir(b: *std.Build) []const u8 {
    const io = b.graph.io;
    const zig_exe = std.Io.Dir.cwd().realPathFileAlloc(io, b.graph.zig_exe, b.allocator) catch |err|
        std.debug.panic("unable to resolve zig executable path '{s}': {t}", .{ b.graph.zig_exe, err });
    return b.pathJoin(&.{ std.fs.path.dirname(zig_exe).?, "lib" });
}
