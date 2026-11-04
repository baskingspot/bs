#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
extern int zig_twice(int);
static char buf[64];
const char *c_fmt(int x) {
    snprintf(buf, sizeof buf, "x=%d twice=%d len=%zu", x, zig_twice(x), strlen("abc"));
    return buf;
}
int c_errno(void) { errno = 0; strtol("99999999999999999999999", 0, 10); return errno == ERANGE; }
void c_puts(const char *s) { puts(s); fflush(stdout); }
int c_qsort(void) { int a[] = {3, 1, 2}; int cmp(const void *x, const void *y); qsort(a, 3, sizeof(int), cmp); return a[0] * 100 + a[1] * 10 + a[2]; }
int cmp(const void *x, const void *y) { return *(const int *)x - *(const int *)y; }
// The image's handle, which only crtbegin.o or the linker defines.
extern void *__dso_handle;
int __cxa_atexit(void (*f)(void *), void *arg, void *dso);
static void bye(void *s) { puts(s); fflush(stdout); }
void c_atexit(void) { __cxa_atexit(bye, "bye", &__dso_handle); }
