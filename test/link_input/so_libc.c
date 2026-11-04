// A C source of a shared library that links glibc (so_libc.zig): calls
// glibc through versioned imports (memcpy is GLIBC_2.14) and keeps a
// thread-local of its own.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
__thread int c_calls;
int c_format(char *out, size_t len, int v) {
    char tmp[32];
    int n = snprintf(tmp, sizeof tmp, "c%d:%d", v, ++c_calls);
    if ((size_t)n >= len) return -1;
    memcpy(out, tmp, (size_t)n + 1);
    return n;
}
char *c_dup(const char *s) { return strdup(s); }
