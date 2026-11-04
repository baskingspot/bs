// GNU indirect functions: target_clones makes one whose resolver reads
// compiler_rt's CPU model, and an explicit ifunc whose resolver picks
// an implementation. C calls them and takes their addresses.
__attribute__((target_clones("avx2", "default"))) int c_triple(int x) { return x * 3; }

static int add_one(int x) { return x + 1; }
static int add_two(int x) { return x + 2; }
static int (*resolve_add(void))(int) { return sizeof(void *) == 8 ? add_two : add_one; }
int c_add(int x) __attribute__((ifunc("resolve_add")));

int c_call(int x) { return c_triple(x) + c_add(x); }
int (*c_triple_ptr(void))(int) { return c_triple; }
int (*const c_add_ptr)(int) = c_add;
