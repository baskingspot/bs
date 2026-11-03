// Built by zap with build-obj and linked into tls_main.zig by upstream zig:
// a thread-local that the other object defines.
extern threadlocal var host_tls: u32;

export fn zap_tls_bump() u32 {
    host_tls += 1;
    return host_tls;
}
