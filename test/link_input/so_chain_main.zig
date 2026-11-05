//! Loads so_chain.c's shared library, which links so_libc.c's.
extern fn chain(v: c_int) c_int;

pub fn main() void {
    if (chain(5) != 5) @panic("chain");
}
