#include <stdlib.h>
#ifdef TCL_SYSTEM_LIBC
int tcl_system(void);
#else
int tcl_bundled(void);
#endif
