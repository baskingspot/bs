// An error in a function whose inferred error set a peer type needs (the
// two calls' error unions merge) is reported, not dropped with the peer
// resolution that analyzed its body.
const Lib = struct { nam: []const u8 };
const libs = [_]Lib{ .{ .name = "m" }, .{ .name = "c" } };

var use_elf = false;
var total: usize = 0;

fn elfLink() !void {
    for (libs) |lib| total += lib.nam.len;
    if (total > 100) return error.TooMany;
}

fn coffLink() !void {
    if (total > 100) return error.Other;
}

fn flush() error{Failed}!void {
    const result = if (use_elf) elfLink() else coffLink();
    result catch return error.Failed;
}

pub fn main() void {
    flush() catch {};
}

// error
// peer_error_set.zig:5:26: error[no-field]: no field named 'name' in struct 'peer_error_set.Lib'
//   | const libs = [_]Lib{ .{ .name = "m" }, .{ .name = "c" } };
//   note peer_error_set.zig:4:13: struct declared here: const Lib = struct { nam: []const u8 };
//   candidates: nam
//   fix? peer_error_set.zig:5:26-5:30: "nam"
//   ref: elfLink peer_error_set.zig:11:10 <- flush peer_error_set.zig:20:40 <- main peer_error_set.zig:25:10 (+3 std frames)
// 1 error
