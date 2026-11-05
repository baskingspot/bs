//! `-target x86_64-native-gnu` (revo's build passes it) is the host's OS
//! with the gnu ABI: x86_64-linux-gnu with that target's default glibc,
//! which links nothing without -lc. `--export=` (fizzy's plugin
//! libraries pass it) exports only from a WebAssembly link.
//! flags: -target x86_64-native-gnu --export=fingerprint
//! exit: 0
const builtin = @import("builtin");

export fn fingerprint() u32 {
    return 7;
}

pub fn main() u8 {
    const glibc = builtin.os.version_range.linux.glibc;
    if (builtin.os.tag != .linux or builtin.abi != .gnu or builtin.link_libc) return 1;
    if (glibc.major != 2 or glibc.minor != 31) return 2;
    if (builtin.link_mode != .static) return 3;
    return 0;
}
