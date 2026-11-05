// An archive member that nothing references: `--force_undefined
// fu_from_archive` pulls it, and its constructor then says whether the
// program's `keep_me` is in the image, through a weak reference, which
// neither keeps nor pulls anything.
#include <stdio.h>

extern unsigned keep_me(void) __attribute__((weak));

int fu_from_archive(void) {
    return 7;
}

__attribute__((constructor)) static void init(void) {
    fprintf(stderr, "pulled, keep_me %u\n", keep_me ? keep_me() : 0);
}
