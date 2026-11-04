// Shared libraries for the DT_NEEDED liveness test (needed_main.zig):
// a, which the program calls, which needs b, and which calls back into
// the program's needed_host.
int needed_b(void);
int needed_host(void);
int needed_a(void) { return needed_b() + needed_host(); }
