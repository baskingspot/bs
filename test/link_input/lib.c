#include <stddef.h>
extern int zig_add(int a, int b);
extern const char *zig_name;
static int counter = 5;
int c_common_var;
const char *c_greeting = "hello from C";
/* PAD */
const char c_msg[] = "extern data";
int c_arr[4] = {10, 20, 30, 40};
struct pair { long a, b; } c_pairs[3] = {{1, 2}, {3, 4}, {5, 6}};
static const char *strs[] = {"alpha", "beta", "gamma"};
__attribute__((weak)) int c_weak_hook(void);
int c_sum_pairs(void) {
    long s = 0;
    for (int i = 0; i < 3; i++) s += c_pairs[i].a * c_pairs[i].b;
    return (int)s;
}
int c_call_zig(int x) { counter += x; return zig_add(counter, 100); }
size_t c_len(const char *s) { size_t n = 0; while (s[n]) n++; return n; }
const char *c_str(int i) { return strs[i]; }
int c_has_hook(void) { return c_weak_hook ? 1 : 0; }
int c_zig_name_len(void) { return (int)c_len(zig_name); }
void c_copy(char *dst, const char *src, size_t n) { struct big { char b[200]; } x; __builtin_memcpy(&x, src, n < 200 ? n : 200); __builtin_memcpy(dst, &x, n < 200 ? n : 200); }
