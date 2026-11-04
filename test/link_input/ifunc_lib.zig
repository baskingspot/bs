//! The Zig root of a shared library holding ifunc.c's indirect
//! functions, which it calls too.
extern fn c_triple(x: c_int) c_int;
export fn z_triple(x: c_int) c_int {
    return c_triple(x);
}
