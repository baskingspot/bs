/* Defines `wfn` strongly over weak_export_main.zig's weak export. */
int wfn(void) { return 2; }
int c_wfn(void) { return wfn() * 10; }
