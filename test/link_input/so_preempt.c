// An executable defining thread-locals that the shared library from
// so_lib.zig also defines and exports (tls.c's general-dynamic tls_gd,
// so_desc.c's d_tls): the loader binds the library's references to the
// executable's, as with upstream's library.
#include <stdio.h>
__thread int tls_gd = 1000;
__thread int d_tls = 2000;
int c_tls(void);
int d_bump(int v);
int main(void) {
    int a = c_tls();
    int b = d_bump(3);
    printf("%d %d %d %d\n", a, b, tls_gd, d_tls);
    return 0;
}
