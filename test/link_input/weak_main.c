// Weak references to names nothing at link time defines. A C-only
// executable imports them for its GOT loads and calls, as lld does, so a
// library preloaded at run time (weak_def.c) defines them; the pointers
// in data stay 0, as lld resolves them.
#include <stdio.h>
__attribute__((weak)) int weak_fn(void);
__attribute__((weak)) extern int weak_data;
int (*volatile weak_ptr)(void) = weak_fn;
int main(void) {
    printf("fn=%d data=%d ptr=%d\n", weak_fn ? weak_fn() : -1, &weak_data ? weak_data : -1, weak_ptr ? 1 : 0);
    return 0;
}
