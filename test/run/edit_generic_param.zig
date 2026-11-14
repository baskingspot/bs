//! exit: 0
//! stderr: "routed 8\n"
//! rebuild-replace: "fn serve(port: anytype, named: bool) void {" "fn serve(port: anytype) void {"
//! rebuild-replace: "route(port, named) catch break;" "route(port, false) catch break;"
//! rebuild-replace: ".{ port, true }" ".{port}"
//! An edit build after a thread's generic function gains a parameter, as
//! edit_spawn_param.zig's function that is not generic. The walk enters
//! the old thread's entry point from the old `spawn` instance it takes as
//! reached, whose `@call` instantiates the old `serve`, of type
//! `fn (anytype) void`, by its ZIR, which is the new one: Sema read the
//! second parameter's type past the end of the old type's one. A call of
//! a function that is no longer its declaration's value is refused, as
//! its body is (`Sema.refuseStaleFunc`); the lazy build builds again
//! eagerly.
const std = @import("std");

var routed: u16 = 0;

fn route(port: u16, named: bool) !void {
    routed = port + @intFromBool(named);
    return error.Done;
}

fn serve(port: anytype, named: bool) void {
    while (true) {
        route(port, named) catch break;
    }
}

pub fn main() !void {
    var port: u16 = 7;
    _ = &port;
    const thread = try std.Thread.spawn(.{}, serve, .{ port, true });
    thread.join();
    std.debug.print("routed {d}\n", .{routed});
}
