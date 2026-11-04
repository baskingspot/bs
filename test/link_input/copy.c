/* Reads glibc's data PC-relative, as GCC's -fPIE does, which needs copy
 * relocations (build.zig, `addLinkInputTests`). */
#include <stdio.h>
extern char **environ;
void *c_stdout_addr(void) { return &stdout; }
int c_copy_test(void) {
    fputs("via stdout\n", stdout);
    fflush(stdout);
    return environ != 0 && environ[0] != 0;
}
