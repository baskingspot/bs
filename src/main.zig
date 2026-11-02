const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const Frontend = @import("Frontend.zig");

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
    /// Arguments after `--` for `zap run`.
    run_args: []const []const u8 = &.{},
    /// `zap test` only: the test runner's root source file (`--test-runner`).
    test_runner: ?[]const u8 = null,
    /// `zap test` only: include only tests whose names contain one of these.
    test_filters: []const []const u8 = &.{},
    /// `zap test` only: build the test binary without running it.
    test_no_exec: bool = false,
};

pub fn main(init: std.process.Init) !void {
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

    var fe: Frontend = try .init(init.gpa, init.io, zig_lib_dir, opts.root_src_path);
    defer fe.deinit();
    var errors: std.zig.ErrorBundle.Wip = try .init(init.gpa);
    defer errors.deinit();
    const ok = try fe.loadAll(&errors);
    var bundle = try errors.toOwnedBundle("");
    defer bundle.deinit(init.gpa);
    if (bundle.errorMessageCount() > 0) {
        try bundle.renderToStderr(init.io, .{}, .auto);
        std.process.exit(1);
    }
    std.debug.assert(ok);

    // Semantic analysis, code generation, and linking are not implemented yet.
    fatal("{s}: semantic analysis is not implemented yet ({d} files lowered to ZIR)", .{ @tagName(command), fe.files.items.len });
}

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
        } else if (std.mem.eql(u8, arg, "--test-runner")) {
            opts.test_runner = nextTestArg(command, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--test-filter")) {
            try test_filters.append(arena, nextTestArg(command, args, &i, arg));
        } else if (std.mem.eql(u8, arg, "--test-no-exec")) {
            if (command != .@"test") fatal("{s} is only valid for 'zap test'", .{arg});
            opts.test_no_exec = true;
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
    _ = @import("link/Atom.zig");
}
