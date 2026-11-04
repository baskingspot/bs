// The program's weak reference to d (needed_main.zig), which keeps no
// library needed, and a definition b calls back into.
__attribute__((weak)) int needed_d(void);
int needed_has_d(void) { return needed_d != 0; }
int needed_obj(void) { return 1; }
