//! exit: 0
//! stderr: "routed 8\n"
//! rebuild-replace: "fn serve(port: u16, named: bool) void {" "fn serve(port: u16) void {"
//! rebuild-replace: "route(port, named) catch break;" "route(port, false) catch break;"
//! rebuild-replace: ".{ port, true }" ".{port}"
//! An edit build after a thread's function gains a parameter (parcel's
//! fake server, given `named: bool`). The walk enters the old thread's
//! entry point from the old `spawn` instance it takes as reached, and its
//! records name the old `serve`, of type `fn (u16) void`, whose body is
//! now the new ZIR: Sema read `named`'s type past the end of the old
//! parameter types ("expected type 'bool', found 'i16'"), and the error's
//! unit, keyed by its declaration, looked reached. A function no longer
//! its declaration's value is not analyzed (`Zcu.isStaleFunc`); the lazy
//! build builds again eagerly.
const std = @import("std");

var routed: u16 = 0;

fn route(port: u16, named: bool) !void {
    routed = port + @intFromBool(named);
    return error.Done;
}

fn serve(port: u16, named: bool) void {
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
