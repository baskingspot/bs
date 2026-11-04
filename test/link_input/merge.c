// Merged into an object with merge_lib.zig by `bs build-obj`
// (link/ElfMerge.zig).
int c_counter = 5;
static int helper(int v) { return v + 1; }
int c_add(int a, int b) { return helper(a) + b - 1; }
const char *c_name(void) { return "bee"; }
