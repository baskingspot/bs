const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const Frontend = @import("Frontend.zig");
const Zcu = @import("Zcu.zig");
const Ir = @import("Ir.zig");
const Emit = @import("Emit.zig");
const Incremental = @import("Incremental.zig");
const Builtin = @import("Builtin.zig");

pub const zig_version = "0.17.0";

const usage =
    \\Usage: zap [command] [options]
    \\
    \\zap is a fast Debug-mode compiler for Zig 0.17.0.
    \\
    \\Commands:
    \\  build-exe        Create executable from source
    \\  build-obj        Create object from source
    \\  run              Create executable and run immediately
    \\  test             Perform unit testing
    \\  version          Print the Zig version zap compiles
    \\  help             Print this help and exit
    \\
;

pub const Command = enum { build_exe, build_obj, run, @"test" };

/// Options shared by the compile commands. Spelled like `zig build-exe`.
pub const Options = struct {
    command: Command,
    root_src_path: []const u8,
    name: ?[]const u8 = null,
    emit_bin: union(enum) { default, path: []const u8, none } = .default,
    target: ?[]const u8 = null,
    zig_lib_dir: ?[]const u8 = null,
    /// `--cache-dir` and `--global-cache-dir`.
    cache_dir: ?[]const u8 = null,
    global_cache_dir: ?[]const u8 = null,
    /// Arguments after `--` for `zap run`.
    run_args: []const []const u8 = &.{},
    /// `zap test` only: the test runner's root source file (`--test-runner`).
    test_runner: ?[]const u8 = null,
    /// `zap test` only: include only tests whose names contain one of these.
    test_filters: []const []const u8 = &.{},
    /// `zap test` only: build the test binary without running it.
    test_no_exec: bool = false,
    /// Print the typed IR of every analyzed function to stdout
    /// (`--debug-dump-ir`, for zap's own tests and debugging).
    dump_ir: bool = false,
};

pub fn main(init: std.process.Init) !void {
    var stages: Stages = .{ .io = init.io, .last = .now(init.io, .awake) };
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) fatalUsage();
    const cmd = args[1];
    const command: Command = if (std.mem.eql(u8, cmd, "build-exe"))
        .build_exe
    else if (std.mem.eql(u8, cmd, "build-obj"))
        .build_obj
    else if (std.mem.eql(u8, cmd, "run"))
        .run
    else if (std.mem.eql(u8, cmd, "test"))
        .@"test"
    else if (std.mem.eql(u8, cmd, "version")) {
        try Io.File.stdout().writeStreamingAll(init.io, zig_version ++ "\n");
        return;
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try Io.File.stdout().writeStreamingAll(init.io, usage);
        return;
    } else fatal("unknown command: {s}", .{cmd});

    const opts = try parseOptions(arena, command, args[2..]);
    const zig_lib_dir = opts.zig_lib_dir orelse init.environ_map.get("ZIG_LIB_DIR") orelse build_options.zig_lib_dir;
    if (opts.target) |t| {
        const supported = [_][]const u8{ "native", "x86_64-linux", "x86_64-linux-none", "aarch64-macos", "aarch64-macos-none" };
        for (supported) |s| {
            if (std.mem.eql(u8, t, s)) break;
        } else fatal("unsupported target '{s}'; zap supports x86_64-linux and aarch64-macos", .{t});
    }

    const cache_dirs = Frontend.resolveCacheDirs(arena, init.io, init.environ_map, .{
        .local = opts.cache_dir,
        .global = opts.global_cache_dir,
        .local_is_global = command == .run,
    });
    const is_test = command == .@"test";
    const builtin_dir = try Builtin.writeToCache(arena, init.io, try std.fs.path.join(arena, &.{ cache_dirs.global, "zap" }), .{
        .output_mode = if (command == .build_obj) .Obj else .Exe,
        .is_test = is_test,
    });
    // The on-disk cache: a build whose inputs did not change relinks the
    // last build's Atoms and skips everything else.
    const run_test = is_test and !opts.test_no_exec;
    const stem = opts.name orelse if (is_test) "test" else std.fs.path.stem(opts.root_src_path);
    const out_path: ?[]const u8 = switch (opts.emit_bin) {
        .none => if (run_test) try testBinPath(arena, init.io, try std.fs.path.join(arena, &.{ cache_dirs.local, "zap" }), stem) else null,
        .path => |p| p,
        .default => if (run_test) try testBinPath(arena, init.io, try std.fs.path.join(arena, &.{ cache_dirs.local, "zap" }), stem) else stem,
    };
    if (run_test) try Io.Dir.cwd().createDirPath(init.io, std.fs.path.dirname(out_path.?).?);
    const use_cache = out_path != null and !opts.dump_ir and (command == .build_exe or is_test) and
        !std.mem.eql(u8, init.environ_map.get("ZAP_CACHE") orelse "", "off");
    var inc: ?Incremental = if (use_cache) try Incremental.open(init.gpa, init.io, cache_dirs, args[1..], zig_lib_dir, "x86_64-linux", init.environ_map.get("ZAP_CACHE_TIMING") != null) else null;
    defer if (inc) |*i| i.close();
    if (inc) |*i| i.check = init.environ_map.get("ZAP_CACHE_CHECK") != null;
    stages.on = init.environ_map.get("ZAP_TIMING") != null;
    if (inc) |*i| if (try i.relinkIfUnchanged(Io.Dir.cwd(), out_path.?)) {
        if (run_test) try runTest(init, out_path.?);
        return;
    };

    const test_runner = opts.test_runner orelse try std.fs.path.join(arena, &.{ zig_lib_dir, "compiler", "test_runner.zig" });
    var fe: Frontend = try .init(init.gpa, init.io, zig_lib_dir, .{
        .root_src_path = if (is_test) test_runner else opts.root_src_path,
        .builtin_dir = builtin_dir,
        .main_src_path = if (is_test) opts.root_src_path else null,
    });
    defer fe.deinit();
    try fe.enableCache(cache_dirs);
    var errors: std.zig.ErrorBundle.Wip = try .init(init.gpa);
    defer errors.deinit();
    stages.mark("setup and cache check");
    const ok = try fe.loadAll(&errors);
    stages.mark("frontend");
    if (init.environ_map.get("ZAP_FRONTEND_TIMING") != null) fe.printStats();
    var bundle = try errors.toOwnedBundle("");
    defer bundle.deinit(init.gpa);
    if (bundle.errorMessageCount() > 0) {
        try bundle.renderToStderr(init.io, .{}, .auto);
        std.process.exit(1);
    }
    std.debug.assert(ok);

    var zcu: Zcu = try .init(init.gpa, init.io, &fe);
    defer zcu.deinit();
    zcu.is_test = is_test;
    zcu.test_filters = opts.test_filters;
    if (inc) |*i| try i.seedErrors(&zcu);
    if (opts.dump_ir) {
        var stdout_buf: [4096]u8 = undefined;
        var stdout = Io.File.stdout().writerStreaming(init.io, &stdout_buf);
        var sink: DumpSink = .{ .w = &stdout.interface };
        try zcu.analyzeAll(&sink);
        try stdout.interface.flush();
        exitOnErrors(init, &zcu);
        return;
    }
    if (command != .build_exe and command != .@"test") fatal("{s}: zap only implements build-exe and test so far", .{@tagName(command)});

    var emit: Emit = .init(init.gpa, &zcu);
    defer emit.deinit();
    try zcu.analyzeAll(&emit);
    stages.markSplit("sema", "codegen", emit.codegen_ns);
    if (is_test) @import("Sema.zig").populateTestFunctions(&zcu) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
    exitOnErrors(init, &zcu);
    const bin_path = out_path orelse return;
    const ready = try emit.finish();
    stages.mark("emit");
    exitOnErrors(init, &zcu);
    if (!ready) std.process.exit(1);
    // The cache records the build while it links, and keeps the record
    // only if the link succeeds.
    if (inc) |*i| i.startRecord(&fe, &zcu, &emit);
    const linked = try emit.link(init.io, Io.Dir.cwd(), bin_path);
    stages.mark("link");
    if (inc) |*i| try i.finishRecord(linked);
    stages.mark("cache record (after the link)");
    stages.print();
    if (!linked) std.process.exit(1);
    if (run_test) try runTest(init, out_path.?);
}

fn runTest(init: std.process.Init, path: []const u8) !void {
    var child = try std.process.spawn(init.io, .{ .argv = &.{path} });
    const term = try child.wait(init.io);
    switch (term) {
        .exited => |code| if (code != 0) std.process.exit(code),
        else => fatal("the test binary terminated unexpectedly: {any}", .{term}),
    }
}

fn testBinPath(arena: std.mem.Allocator, io: Io, cache_dir: []const u8, stem: []const u8) ![]const u8 {
    var r: [8]u8 = undefined;
    io.random(&r);
    return std.fmt.allocPrint(arena, "{s}/tmp/{s}-{x}", .{ cache_dir, stem, &r });
}

/// `ZAP_TIMING`: wall time per stage of a build.
const Stages = struct {
    io: Io,
    on: bool = false,
    last: Io.Timestamp,
    buf: [512]u8 = undefined,
    len: usize = 0,
    total_ns: u64 = 0,

    fn mark(s: *Stages, name: []const u8) void {
        s.markSplit(name, "", 0);
    }

    /// Ends a stage, of which `part_ns` went to `part`.
    fn markSplit(s: *Stages, name: []const u8, part: []const u8, part_ns: u64) void {
        const t = Io.Timestamp.now(s.io, .awake);
        const ns: u64 = @intCast(s.last.durationTo(t).nanoseconds);
        s.last = t;
        s.total_ns += ns;
        if (!s.on) return;
        const ms = struct {
            fn f(x: u64) f64 {
                return @as(f64, @floatFromInt(x)) / 1e6;
            }
        }.f;
        const out = if (part.len == 0)
            std.fmt.bufPrint(s.buf[s.len..], "{s}{s} {d:.1}", .{ if (s.len == 0) "" else ", ", name, ms(ns) })
        else
            std.fmt.bufPrint(s.buf[s.len..], "{s}{s} {d:.1}, {s} {d:.1}", .{ if (s.len == 0) "" else ", ", name, ms(ns -| part_ns), part, ms(part_ns) });
        s.len += (out catch return).len;
    }

    fn print(s: *Stages) void {
        if (s.on) std.debug.print("zap: {d:.1} ms in main: {s}\n", .{ @as(f64, @floatFromInt(s.total_ns)) / 1e6, s.buf[0..s.len] });
    }
};

fn exitOnErrors(init: std.process.Init, zcu: *Zcu) void {
    if (zcu.errors.items.len == 0) return;
    renderErrors(init, zcu) catch {};
    std.process.exit(1);
}

fn renderErrors(init: std.process.Init, zcu: *Zcu) !void {
    var wip: std.zig.ErrorBundle.Wip = try .init(init.gpa);
    defer wip.deinit();
    try zcu.renderErrors(&wip);
    var bundle = try wip.toOwnedBundle("");
    defer bundle.deinit(init.gpa);
    try bundle.renderToStderr(init.io, .{}, .auto);
}

const DumpSink = struct {
    w: *Io.Writer,

    pub fn function(s: *DumpSink, zcu: *Zcu, ir: *const Ir) !void {
        try @import("Ir/print.zig").dump(ir, &zcu.ip, s.w);
    }
};

fn parseOptions(arena: std.mem.Allocator, command: Command, args: []const []const u8) !Options {
    var root: ?[]const u8 = null;
    var opts: Options = .{ .command = command, .root_src_path = undefined };
    var test_filters: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            if (command != .run) fatal("unexpected '--' outside of 'zap run'", .{});
            opts.run_args = args[i + 1 ..];
            break;
        } else if (std.mem.startsWith(u8, arg, "-femit-bin=")) {
            opts.emit_bin = .{ .path = arg["-femit-bin=".len..] };
        } else if (std.mem.eql(u8, arg, "-fno-emit-bin")) {
            opts.emit_bin = .none;
        } else if (std.mem.eql(u8, arg, "--name")) {
            opts.name = nextArg(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "-target")) {
            opts.target = nextArg(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--zig-lib-dir")) {
            opts.zig_lib_dir = nextArg(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--cache-dir")) {
            opts.cache_dir = nextArg(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--global-cache-dir")) {
            opts.global_cache_dir = nextArg(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--test-runner")) {
            opts.test_runner = nextTestArg(command, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--test-filter")) {
            try test_filters.append(arena, nextTestArg(command, args, &i, arg));
        } else if (std.mem.eql(u8, arg, "--test-no-exec")) {
            if (command != .@"test") fatal("{s} is only valid for 'zap test'", .{arg});
            opts.test_no_exec = true;
        } else if (std.mem.eql(u8, arg, "--debug-dump-ir")) {
            opts.dump_ir = true;
        } else if (std.mem.eql(u8, arg, "-ODebug")) {
            // The only mode zap supports.
        } else if (std.mem.startsWith(u8, arg, "-O")) {
            fatal("zap only supports Debug builds; use upstream zig for '{s}'", .{arg});
        } else if (std.mem.startsWith(u8, arg, "-")) {
            fatal("unsupported option: {s}", .{arg});
        } else if (root == null) {
            root = arg;
        } else {
            fatal("unexpected extra parameter: {s}", .{arg});
        }
    }
    opts.root_src_path = root orelse fatal("expected a root source file", .{});
    opts.test_filters = test_filters.items;
    return opts;
}

fn nextTestArg(command: Command, args: []const []const u8, i: *usize, flag: []const u8) []const u8 {
    if (command != .@"test") fatal("{s} is only valid for 'zap test'", .{flag});
    return nextArg(args, i, flag);
}

fn nextArg(args: []const []const u8, i: *usize, flag: []const u8) []const u8 {
    i.* += 1;
    if (i.* >= args.len) fatal("expected parameter after {s}", .{flag});
    return args[i.*];
}

fn fatalUsage() noreturn {
    std.debug.print("{s}", .{usage});
    std.process.exit(1);
}

pub fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ format ++ "\n", args);
    std.process.exit(1);
}

test {
    _ = Frontend;
    _ = @import("cache.zig");
    _ = @import("link/Atom.zig");
    _ = @import("link/Elf.zig");
    _ = @import("codegen/x86_64/Encoder.zig");
    _ = @import("link/MachO.zig");
    _ = @import("codegen/aarch64/Encoder.zig");
    _ = @import("InternPool.zig");
    _ = Zcu;
    _ = @import("Sema.zig");
    _ = Ir;
    _ = Emit;
}
