#include <string.h>
int c_overflow(int x) { return x + 2147483647; }
void c_smash(const char *s) { char b[8]; for (int i = 0; s[i]; i++) ((volatile char *)b)[i] = s[i]; }
