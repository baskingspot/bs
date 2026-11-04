// Thread-locals through TLS descriptors (-mtls-dialect=gnu2): C's own, a
// static one through _TLS_MODULE_BASE_, and Zig's.
_Thread_local int c_tls = 5;
static _Thread_local int c_local = 7;
extern _Thread_local int z_tls;
int c_get(void) { return c_tls * 100 + c_local; }
void c_set(int v) { c_tls = v; c_local = v + 1; }
int c_get_z(void) { return z_tls; }
void c_set_z(int v) { z_tls = v; }
int *c_addr(void) { return &c_tls; }
