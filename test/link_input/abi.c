// SysV aggregates between C and Zig (build.zig, "bs build-exe with C
// aggregates"): each value is checked on the receiving side, so a wrong
// register or eightbyte shows as a wrong line.
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>

typedef struct { uint64_t a, b; } S16;      // INTEGER, INTEGER
typedef struct { double x, y; } D2;         // SSE, SSE
typedef struct { float x, y, z; } F3;       // SSE, SSE (4 bytes)
typedef struct { uint32_t a; float f; double d; } MIX; // INTEGER, SSE
typedef struct { double d; uint8_t c[3]; } DSI; // SSE, INTEGER (3 bytes)
typedef struct { uint8_t a, b, c; } S3;     // INTEGER (3 bytes)
typedef struct { uint64_t a, b, c; } S24;   // MEMORY
typedef struct { uint8_t p[16]; } SL;       // { ptr, len }-like bytes

extern S16 zig_s16(S16, D2, F3);
extern MIX zig_mix(MIX, DSI, S3);
extern DSI zig_dsi(int, S16, S16, S16, MIX); // the last S16 does not fit
extern double zig_va(int n, ...);

S16 c_s16(S16 s, D2 d, F3 f) {
    printf("c_s16 %lu %lu %g %g %g %g %g\n", s.a, s.b, d.x, d.y, f.x, f.y, f.z);
    return (S16){ s.a + 1, s.b + 1 };
}
MIX c_mix(MIX m, DSI d, S3 s) {
    printf("c_mix %u %g %g %g %u %u %u %u %u %u\n", m.a, m.f, m.d, d.d, d.c[0], d.c[1], d.c[2], s.a, s.b, s.c);
    return (MIX){ m.a * 2, m.f * 2, m.d * 2 };
}
F3 c_f3(void) { return (F3){ 1.5f, 2.5f, 3.5f }; }
S24 c_s24(S24 s) { return (S24){ s.c, s.b, s.a }; }
DSI c_dsi(int i, S16 a, S16 b, S16 c, MIX m) {
    printf("c_dsi %d %lu %lu %lu %lu %lu %lu %u %g %g\n", i, a.a, a.b, b.a, b.b, c.a, c.b, m.a, m.f, m.d);
    return (DSI){ 0.25, { 7, 8, 9 } };
}
double c_va(int n, ...) {
    va_list ap;
    va_start(ap, n);
    double sum = 0;
    for (int i = 0; i < n; i++) {
        MIX m = va_arg(ap, MIX);
        D2 d = va_arg(ap, D2);
        sum += m.a + m.f + m.d + d.x + d.y;
    }
    va_end(ap);
    return sum;
}

// C calls Zig, directly and through a pointer.
void c_calls_zig(S16 (*f)(S16, D2, F3)) {
    S16 r = f((S16){ 10, 20 }, (D2){ 0.5, 0.25 }, (F3){ 1, 2, 3 });
    printf("ptr %lu %lu\n", r.a, r.b);
    MIX m = zig_mix((MIX){ 3, 1.5f, 2.25 }, (DSI){ 4.5, { 1, 2, 3 } }, (S3){ 4, 5, 6 });
    printf("zig_mix %u %g %g\n", m.a, m.f, m.d);
    DSI d = zig_dsi(9, (S16){ 1, 2 }, (S16){ 3, 4 }, (S16){ 5, 6 }, (MIX){ 7, 8, 9 });
    printf("zig_dsi %g %u %u %u\n", d.d, d.c[0], d.c[1], d.c[2]);
    printf("zig_va %g\n", zig_va(2, (MIX){ 1, 2, 3 }, (D2){ 4, 5 }, (MIX){ 6, 7, 8 }, (D2){ 9, 10 }));
    fflush(stdout);
}
