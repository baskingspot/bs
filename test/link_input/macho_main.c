// MachOInput's test input (src/link/MachOInput.zig): a static function, a
// constructor, and a GOT load of a variable another object defines.
extern int second;
__attribute__((noinline)) static int helper(int x) { return x * 3; }
__attribute__((constructor)) static void init(void) { second += 1; }
int read_second(void) { return helper(second); }
