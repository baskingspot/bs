//! `-target x86_64-native-gnu` (revo's build passes it) is the host's OS
//! with the gnu ABI: x86_64-linux-gnu with that target's default glibc,
//! which links nothing without -lc.
//! flags: -target x86_64-native-gnu
//! exit: 0
const builtin = @import("builtin");

pub fn main() u8 {
    const glibc = builtin.os.version_range.linux.glibc;
    if (builtin.os.tag != .linux or builtin.abi != .gnu or builtin.link_libc) return 1;
    if (glibc.major != 2 or glibc.minor != 31) return 2;
    if (builtin.link_mode != .static) return 3;
    return 0;
}
