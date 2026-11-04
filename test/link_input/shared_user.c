/* Reads and writes the shared library's data object PC-relative, as
 * GCC's -fPIE does: the executable copies it, and the library's code,
 * through its alias, uses the copy (build.zig, `addLinkInputTests`). */
extern int shared_counter;
extern int shared_get(void);
int c_shared(void) { shared_counter += 100; return shared_get(); }
