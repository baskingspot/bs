// Exports of a bs shared library that an executable may preempt
// (so_preempt.c), reached through the PLT, the GOT and absolute addresses
// with an addend. The protected and hidden ones bind in the library, as
// does ip_hidref, which so_hidref.c refers to as hidden.
int ip_data[2] = {1, 2};
int ip_value(void) { return 1; }
__attribute__((visibility("protected"))) int ip_prot(void) { return 10; }
__attribute__((visibility("hidden"))) int ip_hidden = 20;
int *const ip_second = &ip_data[1];
int (*const ip_fn)(void) = ip_value;
int ip_call(void) { return ip_value() + ip_prot() + ip_hidden; }
int *ip_addr(void) { return ip_data; }
int ip_table(void) { return *ip_second + ip_fn(); }
int ip_hidref(void) { return 4; }
