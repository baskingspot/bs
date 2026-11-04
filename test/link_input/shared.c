/* A shared library that zap's executables import from (build.zig,
 * `addLinkInputTests`): versioned functions, and a data object with an
 * alias that the library's own code uses. */
int shared_counter = 41;
extern int shared_counter_alias __attribute__((alias("shared_counter")));
int shared_get(void) { return ++shared_counter_alias; }
int shared_twice(int x) { return 2 * x; }
