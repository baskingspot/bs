// A program of C only, which upstream links with lld: dup_lib.c's
// library comes before glibc's, so getpid is the library's.
#include <stdio.h>
#include <unistd.h>
int main(void) {
    printf("%s\n", getpid() == 4242 ? "true" : "false");
    return 0;
}
