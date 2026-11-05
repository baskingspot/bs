// An error in a function whose body is analyzed for its inferred error set
// while an inline call reaches it carries no "called inline here" frames:
// the function is analyzed on its own, as upstream reports it.
fn parse() !void {
    @compileError("uh oh");
}

inline fn run() !void {
    return parse();
}

pub fn main() !void {
    try run();
}

// error
// error_set_body.zig:5:5: error[compile-error]: uh oh
//   | @compileError("uh oh");
//   ref: main error_set_body.zig:9:17 (+3 std frames)
// 1 error
