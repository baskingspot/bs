/* Constructors and a destructor, compiled twice (SECOND set or not); the
 * link orders the constructors by priority across both objects. */
extern int ctor_log[8];
extern int ctor_n;
static void rec(int v) { ctor_log[ctor_n++] = v; }
#ifndef SECOND
int ctor_log[8];
int ctor_n;
__attribute__((constructor(200))) static void c200(void) { rec(200); }
__attribute__((constructor)) static void c_first(void) { rec(1); }
__attribute__((constructor(101))) static void c101(void) { rec(101); }
/* Runs only where exit runs the fini array: with -lc. */
__attribute__((destructor)) static void fini(void) {
    long r;
    __asm__ volatile("syscall" : "=a"(r) : "a"(1), "D"(2), "S"("fini\n"), "d"(5) : "rcx", "r11", "memory");
}
#else
__attribute__((constructor(150))) static void c150(void) { rec(150); }
__attribute__((constructor)) static void c_second(void) { rec(2); }
#endif
