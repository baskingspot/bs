//! An object of Zig, C (merge.c) and a C object (tls.c), merged by
//! `bs build-obj` (link/ElfMerge.zig); merge_main.zig links it.
extern fn c_add(a: c_int, b: c_int) c_int;
extern var c_counter: c_int;
export fn z(x: c_int) c_int {
    c_counter += 1;
    return c_add(x, 2) * 2;
}
