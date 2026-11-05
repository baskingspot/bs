// An executable defining thread-locals that the shared library from
// so_lib.zig also defines and exports (tls.c's general-dynamic tls_gd,
// so_desc.c's d_tls): the loader binds the library's references to the
// executable's, as with upstream's library. Likewise for so_interpose.c's
// functions and data, except its protected function and the function
// so_hidref.c hides.
#include <stdio.h>
__thread int tls_gd = 1000;
__thread int d_tls = 2000;
int c_tls(void);
int d_bump(int v);
int ip_data[2] = {100, 200};
int ip_value(void) { return 2; }
int ip_prot(void) { return 30; }
int ip_call(void);
int *ip_addr(void);
int ip_table(void);
int ip_hidref(void) { return 400; }
int ip_hidcall(void);
int main(void) {
    int a = c_tls();
    int b = d_bump(3);
    printf("%d %d %d %d\n", a, b, tls_gd, d_tls);
    printf("%d %d %d %d\n", ip_call(), ip_addr() == ip_data, ip_table(), ip_hidcall());
    return 0;
}
