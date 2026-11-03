// Built by zap with build-obj and linked into main.zig by upstream zig:
// exported functions and data, an import from the other object,
// thread-locals, and debug info that a panic's stack trace reads.
var counter: u32 = 10;
export var shared: u64 = 7;
threadlocal var calls: u32 = 3;

fn helper(x: u32) u32 {
    counter += x;
    calls += 1;
    return counter + calls;
}

export fn zap_add(a: u32, b: u32) u32 {
    return helper(a) + b;
}

extern fn c_twice(x: u32) u32;

export fn zap_call_c(x: u32) u32 {
    return c_twice(x) + 1;
}

export fn zap_overflow(x: u8) u8 {
    return x + 250;
}
