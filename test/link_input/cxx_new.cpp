// A shared library that replaces operator new and counts its calls
// (cxx_new_main.cpp). It is built without the C++ runtime (-nostdlib++),
// whose libc++ build takes upstream a minute, so it aborts where
// libc++'s operator new would throw.
#include <stdlib.h>
static int count;
void *operator new(size_t n) {
    ++count;
    if (void *p = malloc(n)) return p;
    abort();
}
void operator delete(void *p) noexcept { free(p); }
void operator delete(void *p, size_t) noexcept { free(p); }
int new_count() { return count; }
