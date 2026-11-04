// Reads and writes a shared library's thread-local, compiled once per TLS
// model: general-dynamic (-fPIC), descriptors (-mtls-dialect=gnu2) and
// initial-exec (-ftls-model=initial-exec), with SUFFIX naming the copy.
#define CAT2(a, b) a##b
#define CAT(a, b) CAT2(a, b)
extern __thread int so_tls;
int CAT(get, SUFFIX)(void) { return so_tls; }
void CAT(add, SUFFIX)(int v) { so_tls += v; }
