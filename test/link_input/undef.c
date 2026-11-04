/* Calls a function nothing defines, twice, so that bs reports it once
 * for every object that references it (build.zig, compiled as undef1.o
 * and undef2.o). */
extern int nope(int);
int UNDEF(int x) { return nope(x) + nope(x + 1); }
