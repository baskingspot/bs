// C only: without UBSan's runtime its memcmp is glibc's, imported, so a
// preloaded library's interposes it (plain_c_preload.c); with UBSan's
// runtime it is compiler_rt's, as upstream links them.
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
    printf("%d\n", memcmp(argv[0], argv[argc - 1], 1));
    return 0;
}
