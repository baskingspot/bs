// The Win64 convention (ms_abi) between C and Zig (build.zig, "zap
// build-exe with Win64 calls"): by-reference structs and results, mixed
// positions, a 16-byte integer, variadic calls, and Zig functions C calls
// directly and through a pointer.
#include <stdint.h>
#include <stdio.h>
#include <stdarg.h>
#define MS __attribute__((ms_abi))
typedef struct { int val; int arr[15]; } ByRef;
typedef struct { uint8_t a, b, c; } S3;
typedef struct { uint32_t a, b; } S8;
typedef struct { double x, y; } D2;
MS ByRef c_win_byref(ByRef in) { in.val += 41; return in; }
MS double c_win_mix(int a, double b, S8 s, float c, S3 t, D2 d, long long e, double f) {
    printf("c_win_mix %d %g %u %u %g %u %u %u %g %g %lld %g\n", a, b, s.a, s.b, c, t.a, t.b, t.c, d.x, d.y, e, f);
    return a + b + c + e + f;
}
MS S8 c_win_s8(S8 s) { return (S8){ s.b, s.a }; }
MS unsigned __int128 c_win_u128(unsigned __int128 x) { return x + 1; }
MS void c_win_va(int n, ...) {
    __builtin_ms_va_list ap;
    __builtin_ms_va_start(ap, n);
    for (int i = 0; i < n; i++) {
        if (i % 2 == 0) printf("va u64 %llu\n", (unsigned long long)__builtin_va_arg(ap, uint64_t));
        else printf("va f64 %g\n", __builtin_va_arg(ap, double));
    }
    __builtin_ms_va_end(ap);
}
typedef MS double (*ZigFn)(int, double, S8, float, S3, D2, long long, double);
extern MS ByRef zig_win_byref(ByRef);
void c_calls(ZigFn f) {
    printf("zig via ptr %g\n", f(1, 2.5, (S8){3, 4}, 5.5f, (S3){6, 7, 8}, (D2){9.5, 10.5}, 11, 12.5));
    ByRef b = { 5 }; b.arr[14] = 77;
    ByRef r = zig_win_byref(b);
    printf("zig byref %d %d\n", r.val, r.arr[14]);
    fflush(stdout);
}
