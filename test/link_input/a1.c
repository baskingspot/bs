int a2(int);
int a1(int x) { return x <= 0 ? 0 : 1 + a2(x - 1); }
