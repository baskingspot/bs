// Loads test/obj/lib.zig, built by bs as a shared object, with dlopen,
// and prints what main.zig prints. c_twice is the import the library
// resolves against this program (linked with -rdynamic).
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>

unsigned c_twice(unsigned x) { return 2 * x; }

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    void *lib = dlopen(argv[1], RTLD_NOW);
    if (!lib) {
        fprintf(stderr, "%s\n", dlerror());
        return 1;
    }
    unsigned (*bs_add)(unsigned, unsigned) = (unsigned (*)(unsigned, unsigned))dlsym(lib, "bs_add");
    unsigned (*bs_call_c)(unsigned) = (unsigned (*)(unsigned))dlsym(lib, "bs_call_c");
    uint64_t *shared = (uint64_t *)dlsym(lib, "shared");
    unsigned a = bs_add(5, 1);
    unsigned c = bs_call_c(20);
    printf("%u %llu %u\n", a, (unsigned long long)*shared, c);
    return 0;
}
