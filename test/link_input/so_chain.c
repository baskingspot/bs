// A shared library of C that links another (so_libc.c's): its call to
// c_format is an import that the loader finds through DT_NEEDED.
#include <stdio.h>
int c_format(char *out, size_t len, int v);
int chain(int v) {
    char buf[32];
    int n = c_format(buf, sizeof buf, v * 10);
    fprintf(stderr, "chain %s\n", buf);
    return n;
}
