// A shared library's thread-locals (test/link_input/so_tls_main.zig).
__thread int so_tls = 3;
static __thread int so_priv = 100;
int so_get(void) { return so_tls + so_priv; }
