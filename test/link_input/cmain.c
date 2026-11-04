// An executable of C only: bs's start code calls this main, and the
// 128-bit division is compiler_rt's __udivti3.
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    unsigned __int128 a = (unsigned __int128)strtoul(argv[1], 0, 10) << 70;
    printf("argc=%d q=%llu\n", argc, (unsigned long long)(a / 12345));
    return 7;
}
