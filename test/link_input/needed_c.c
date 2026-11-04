// c, which only defines what the program defines too, and d, which the
// program references only weakly (needed_ref.c): neither is needed, so
// neither loads and neither constructor prints.
#include <stdio.h>
#ifdef NEEDED_D
__attribute__((constructor)) static void init(void) { puts("d loaded"); }
int needed_d(void) { return 4; }
#else
__attribute__((constructor)) static void init(void) { puts("c loaded"); }
int needed_host(void) { return 100; }
#endif
