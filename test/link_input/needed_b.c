// b, needed only through a (needed_main.zig), which calls back into the
// program's C object (needed_ref.c).
int needed_obj(void);
int needed_b(void) { return 40 + needed_obj(); }
