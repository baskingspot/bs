/* C calling compiler_rt's soft-float, 128-bit integer and atomic helpers,
 * which zap generates from upstream's compiler_rt (build.zig,
 * `addLinkInputTests`): f128 and f16 conversions, comparisons and
 * arithmetic, 128-bit division, and a lock-based atomic. */
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
