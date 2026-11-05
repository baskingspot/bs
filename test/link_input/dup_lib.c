// A shared library with no DT_SONAME that defines a name glibc defines
// too (dup_main.zig, dup_main.c).
int getpid(void) { return 4242; }
