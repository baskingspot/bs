// C only, with nothing UBSan checks: with -fsanitize-c=full it calls no
// `__ubsan_*` handler, so the program links neither ubsan_rt nor std's
// panic handler and its I/O, as upstream's, and links against glibc 2.4.
#include <stdio.h>
int main(void) {
    puts("no checks");
    return 0;
}
