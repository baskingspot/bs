/* C calling compiler_rt's soft-float, 128-bit integer and atomic helpers,
 * which zap generates from upstream's compiler_rt (build.zig,
 * `addLinkInputTests`): f128 and f16 conversions, comparisons and
 * arithmetic, 128-bit division, a lock-based atomic, and function
 * multiversioning's CPU model. */
typedef struct { long a[4]; } big;
static big shared_big;
__float128 rt_widen(double d) { return d; }
double rt_narrow(__float128 q) { return q; }
int rt_eq(__float128 a, __float128 b) { return a == b; }
int rt_lt(__float128 a, __float128 b) { return a < b; }
__float128 rt_mul(__float128 a, __float128 b) { return a * b; }
long long rt_to_int(__float128 q) { return (long long)q; }
float rt_half_up(_Float16 h) { return h; }
_Float16 rt_half_down(float f) { return f; }
unsigned long long rt_div(unsigned __int128 a, unsigned __int128 b) { return (unsigned long long)(a / b); }
long rt_atomic(long x) {
    big b = { { x, 2 * x, 3 * x, 4 * x } };
    __atomic_store(&shared_big, &b, __ATOMIC_SEQ_CST);
    big out;
    __atomic_load(&shared_big, &out, __ATOMIC_SEQ_CST);
    return out.a[0] + out.a[3];
}
/* __builtin_cpu_init calls __cpu_indicator_init and
 * __builtin_cpu_supports reads __cpu_model and __cpu_features2, which
 * compiler_rt defines (fmv.zig) as zeros; the writes show that the reads
 * reach the same variables. */
extern struct { unsigned vendor, type, subtype, features[1]; } __cpu_model;
extern unsigned __cpu_features2[4];
int rt_cpu(void) {
    __builtin_cpu_init();
    int before = __builtin_cpu_supports("avx2") + 2 * __builtin_cpu_supports("avx512vp2intersect") + 4 * __builtin_cpu_is("intel");
    __cpu_model.features[0] |= 1u << 10;
    __cpu_model.vendor = 1;
    for (int i = 0; i < 4; i++) __cpu_features2[i] = ~0u;
    return before + 8 * __builtin_cpu_supports("avx2") + 16 * __builtin_cpu_supports("avx512vp2intersect") + 32 * __builtin_cpu_is("intel");
}
