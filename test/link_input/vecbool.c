// Bool vectors of 65 to 128 elements between C and Zig (build.zig, "zap
// build-exe with C bool vectors"): one GPR per element, the rest on the
// stack, with all, some, or none of the GPRs left, both ways.
#include <stdbool.h>
#include <stdio.h>
typedef bool V __attribute__((ext_vector_type(128)));
static void show(const char *n, V v) {
    printf("%s ", n);
    for (int i = 0; i < 128; i++) putchar(v[i] ? '1' : '0');
    putchar('\n');
}
void c_v(V v) { show("c_v", v); }
void c_iv(long a, long b, long c, V v, long d) { printf("c_iv %ld %ld %ld %ld ", a, b, c, d); show("", v); }
void c_v7(long a, long b, long c, long d, long e, long f, V v, long g) { printf("c_v7 %ld %ld %ld %ld %ld %ld %ld ", a, b, c, d, e, f, g); show("", v); }
void zig_v(V v);
void zig_iv(long a, long b, long c, V v, long d);
void c_calls_zig(void) {
    V v = {0};
    for (int i = 0; i < 128; i++) v[i] = (i * 7 + 3) % 5 < 2;
    zig_v(v);
    zig_iv(-1, -2, -3, v, -4);
    void (*p)(V) = zig_v;
    p(v);
}
