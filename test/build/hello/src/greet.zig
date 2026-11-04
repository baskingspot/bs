pub const word = "hello";

/// The fuzz test calls it; build.zig builds this module with
/// `.fuzz = false`, so `--fuzz` leaves its branch uninstrumented (check.sh).
pub fn pick(n: usize) []const u8 {
    return if (n == 0) "nobody" else word;
}
