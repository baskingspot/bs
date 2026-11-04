// A shared library that replaces operator new and counts its calls
// (cxx_new_main.cpp).
#include <cstdlib>
#include <new>
static int count;
void *operator new(std::size_t n) {
    ++count;
    if (void *p = std::malloc(n)) return p;
    throw std::bad_alloc();
}
void operator delete(void *p) noexcept { std::free(p); }
void operator delete(void *p, std::size_t) noexcept { std::free(p); }
int new_count() { return count; }
