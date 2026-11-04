int a1(int);
int a2(int x) { return x <= 0 ? 0 : 10 + a1(x - 1); }
int unused_member_fn(void) { return 1; }
