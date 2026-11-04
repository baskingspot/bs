// A GNU indirect function (target_clones makes one), which zap refuses
// to link until it calls resolvers at startup.
__attribute__((target_clones("avx2", "default"))) int c_triple(int x) { return x * 3; }
