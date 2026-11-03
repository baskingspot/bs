//! exit: 5
//! `extern threadlocal var` and `@extern` with `.is_thread_local` naming a
//! thread-local the program exports itself: both reach this thread's copy.
export threadlocal var t: u32 = 3;
const E = struct {
    extern threadlocal var t: u32;
};

pub fn main() u8 {
    E.t += 1;
    const p = @extern(*u32, .{ .name = "t", .is_thread_local = true });
    p.* += 1;
    return @intCast(t);
}
