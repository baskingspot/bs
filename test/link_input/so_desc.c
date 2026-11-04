// Thread-locals of a shared library through TLS descriptors when built
// with GCC's -mtls-dialect=gnu2, linked from an archive (so_lib.zig).
__thread int d_tls = 5;
static __thread int d_local = 7;
int d_bump(int v) { d_tls += v; d_local += v; return d_tls * 100 + d_local; }
