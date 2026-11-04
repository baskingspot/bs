//! A shared library of Zig, a C source (merge.c), a C object (tls.c) and
//! an archive (so_desc.c), linked by `bs build-lib -dynamic`;
//! so_main.zig loads it.
extern fn c_add(a: c_int, b: c_int) c_int;
extern var c_counter: c_int;
extern fn d_bump(v: c_int) c_int;
export fn z(x: c_int) c_int {
    c_counter += 1;
    return c_add(x, 2) * 2;
}
export fn zd(v: c_int) c_int {
    return d_bump(v);
}
