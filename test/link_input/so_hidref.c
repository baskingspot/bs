// Refers to so_interpose.c's ip_hidref as hidden, which hides it in the
// whole library, as the ELF gABI and lld merge visibility: the library
// does not export it, and so_preempt.c's definition does not preempt it.
extern int ip_hidref(void) __attribute__((visibility("hidden")));
int ip_hidcall(void) { return ip_hidref(); }
