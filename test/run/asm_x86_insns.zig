//! exit: 0
//! flags: -mcpu=x86_64_v2+lzcnt+movbe+prfchw+rdrnd+rdseed+clflushopt+rdpid
//! targets: x86_64-linux
//! stdout: "x=1 tsc_nonzero=true\nincl 0xffffffff\nbswapq 0x807060504030201\npopcntq 8\nbsf 4 bsr 6\nimulq -42\ncmovz 7 sete 1\nlock xaddq 10 15\nlock cmpxchgq 1 99\nrep stosb abababababab0000\nrep movsb hello\nbts 32 bt 1\nshldq 0x1f\nxchgq 2 1\nmovzx 255 movsx -1\nadc 0x1 0x0\nmem 0x7 0xfffffff8 0x40 1 0\ncqo -1\nflags 2\nmxcsr 0x1f80 fpucw 0x37f\n241 instructions as upstream assembles them\n"

// Inline assembly's general-purpose instructions (wamr's `mfence` and
// `incl`, corpus round 5), as upstream's assembler takes them: run, and
// each of the forms below assembled alone and compared with the bytes
// upstream assembles it to, which are GNU as's too except where upstream
// differs (a `lock` or `rep` prefix before 0x66, `popf` as the 16-bit
// form, `int $3` as `cd 03`, the size suffixes of `clflushb` and
// `prefetcht0b`). The CPU has the features of the instructions that need
// them; the program runs only the x86-64-v2 ones.
const std = @import("std");

var x: u32 = 0;

fn Probe(comptime insn: []const u8) type {
    return struct {
        fn f() callconv(.naked) void {
            asm volatile (insn ++ "\n int3\n int3\n int3\n int3");
        }
    };
}

const insns = .{
    .{ "adcb $1, %%al", "\x14\x01" },
    .{ "adcl $1000, %%eax", "\x15\xe8\x03\x00\x00" },
    .{ "adcl $1000, %%ecx", "\x81\xd1\xe8\x03\x00\x00" },
    .{ "adcl (%%rdi), %%eax", "\x13\x07" },
    .{ "adcq $0, %%rax", "\x48\x83\xd0\x00" },
    .{ "adcq $1, (%%rdi)", "\x48\x83\x17\x01" },
    .{ "adcq %%r10, %%rax", "\x4c\x11\xd0" },
    .{ "addl $1000, %%eax", "\x05\xe8\x03\x00\x00" },
    .{ "addq $1, %%rax", "\x48\x83\xc0\x01" },
    .{ "andb $1, %%al", "\x24\x01" },
    .{ "bsfl %%ecx, %%eax", "\x0f\xbc\xc1" },
    .{ "bsfq %%rcx, %%rax", "\x48\x0f\xbc\xc1" },
    .{ "bsfw %%cx, %%ax", "\x66\x0f\xbc\xc1" },
    .{ "bsr %%rcx, %%rax", "\x48\x0f\xbd\xc1" },
    .{ "bsrq %%rcx, %%rax", "\x48\x0f\xbd\xc1" },
    .{ "bswap %%r12", "\x49\x0f\xcc" },
    .{ "bswapl %%eax", "\x0f\xc8" },
    .{ "bswapq %%r8", "\x49\x0f\xc8" },
    .{ "bswapq %%rax", "\x48\x0f\xc8" },
    .{ "btcq $1, %%rax", "\x48\x0f\xba\xf8\x01" },
    .{ "btl %%ecx, %%eax", "\x0f\xa3\xc8" },
    .{ "btq $3, %%rax", "\x48\x0f\xba\xe0\x03" },
    .{ "btq $3, (%%rdi)", "\x48\x0f\xba\x27\x03" },
    .{ "btrq %%rcx, %%rax", "\x48\x0f\xb3\xc8" },
    .{ "btsl %%eax, (%%rdi)", "\x0f\xab\x07" },
    .{ "btsq $5, %%rax", "\x48\x0f\xba\xe8\x05" },
    .{ "btw %%ax, %%cx", "\x66\x0f\xa3\xc1" },
    .{ "cbw", "\x66\x98" },
    .{ "cdq", "\x99" },
    .{ "cdqe", "\x48\x98" },
    .{ "clc", "\xf8" },
    .{ "cld", "\xfc" },
    .{ "clflush (%%rdi)", "\x0f\xae\x3f" },
    .{ "clflushb (%%rdi)", "\x0f\xae\x3f" },
    .{ "clflushoptb (%%rdi)", "\x66\x0f\xae\x3f" },
    .{ "cli", "\xfa" },
    .{ "cmc", "\xf5" },
    .{ "cmovaq %%rcx, %%rax", "\x48\x0f\x47\xc1" },
    .{ "cmovbq (%%rdi), %%rax", "\x48\x0f\x42\x07" },
    .{ "cmovge %%ecx, %%eax", "\x0f\x4d\xc1" },
    .{ "cmovl %%rcx, %%rax", "\x48\x0f\x4c\xc1" },
    .{ "cmovnel %%ecx, %%eax", "\x0f\x45\xc1" },
    .{ "cmovnge %%eax, %%ecx", "\x0f\x4c\xc8" },
    .{ "cmovpe %%eax, %%ecx", "\x0f\x4a\xc8" },
    .{ "cmovzq %%rcx, %%rax", "\x48\x0f\x44\xc1" },
    .{ "cmovzw %%cx, %%ax", "\x66\x0f\x44\xc1" },
    .{ "cmpb $10, (%%rsi)", "\x80\x3e\x0a" },
    .{ "cmpl $1000, %%eax", "\x3d\xe8\x03\x00\x00" },
    .{ "cmpq $0, (%%rdi)", "\x48\x83\x3f\x00" },
    .{ "cmpsl", "\xa7" },
    .{ "cmpxchgb %%cl, (%%rdi)", "\x0f\xb0\x0f" },
    .{ "cmpxchgl %%ecx, (%%rdi)", "\x0f\xb1\x0f" },
    .{ "cmpxchgq %%rcx, %%rdx", "\x48\x0f\xb1\xca" },
    .{ "cmpxchgq %%rcx, (%%rdi)", "\x48\x0f\xb1\x0f" },
    .{ "cpuid", "\x0f\xa2" },
    .{ "cqo", "\x48\x99" },
    .{ "crc32b %%cl, %%eax", "\xf2\x0f\x38\xf0\xc1" },
    .{ "crc32q %%rcx, %%rax", "\xf2\x48\x0f\x38\xf1\xc1" },
    .{ "cwd", "\x66\x99" },
    .{ "cwde", "\x98" },
    .{ "decl %%eax", "\xff\xc8" },
    .{ "decq %%r9", "\x49\xff\xc9" },
    .{ "decw %%r10w", "\x66\x41\xff\xca" },
    .{ "divl (%%rdi)", "\xf7\x37" },
    .{ "divq (%%rdi)", "\x48\xf7\x37" },
    .{ "endbr64", "\xf3\x0f\x1e\xfa" },
    .{ "fldcw (%%rdi)", "\xd9\x2f" },
    .{ "fnclex", "\xdb\xe2" },
    .{ "fninit", "\xdb\xe3" },
    .{ "fnstcw (%%rdi)", "\xd9\x3f" },
    .{ "fwait", "\x9b" },
    .{ "fxrstor (%%rdi)", "\x0f\xae\x0f" },
    .{ "fxrstor64 (%%rdi)", "\x48\x0f\xae\x0f" },
    .{ "fxsave (%%rdi)", "\x0f\xae\x07" },
    .{ "fxsave64 (%%rdi)", "\x48\x0f\xae\x07" },
    .{ "hlt", "\xf4" },
    .{ "idivl (%%rdi)", "\xf7\x3f" },
    .{ "idivq %%rcx", "\x48\xf7\xf9" },
    .{ "imul %%ecx, %%eax", "\x0f\xaf\xc1" },
    .{ "imull $3, %%ecx, %%eax", "\x6b\xc1\x03" },
    .{ "imull $300, %%ecx, %%eax", "\x69\xc1\x2c\x01\x00\x00" },
    .{ "imull %%ecx", "\xf7\xe9" },
    .{ "imulq $3, %%rcx, %%rax", "\x48\x6b\xc1\x03" },
    .{ "imulq %%rcx", "\x48\xf7\xe9" },
    .{ "imulq %%rcx, %%rax", "\x48\x0f\xaf\xc1" },
    .{ "imulq (%%rdi), %%rax", "\x48\x0f\xaf\x07" },
    .{ "imulw $300, %%cx, %%ax", "\x66\x69\xc1\x2c\x01" },
    .{ "inc %%rcx", "\x48\xff\xc1" },
    .{ "inc %%spl", "\x40\xfe\xc4" },
    .{ "incb %%al", "\xfe\xc0" },
    .{ "incb %%sil", "\x40\xfe\xc6" },
    .{ "incl %%eax", "\xff\xc0" },
    .{ "incl %%esp", "\xff\xc4" },
    .{ "incl (%%rdi)", "\xff\x07" },
    .{ "incq %%rax", "\x48\xff\xc0" },
    .{ "incq 8(%%rdi)", "\x48\xff\x47\x08" },
    .{ "incw %%ax", "\x66\xff\xc0" },
    .{ "int $0x80", "\xcd\x80" },
    .{ "int $3", "\xcd\x03" },
    .{ "int3", "\xcc" },
    .{ "lahf", "\x9f" },
    .{ "ldmxcsr (%%rdi)", "\x0f\xae\x17" },
    .{ "leave", "\xc9" },
    .{ "leaveq", "\xc9" },
    .{ "lfence", "\x0f\xae\xe8" },
    .{ "lock addl $1, (%%rdi)", "\xf0\x83\x07\x01" },
    .{ "lock andq %%rax, (%%rdi)", "\xf0\x48\x21\x07" },
    .{ "lock btsq $3, (%%rdi)", "\xf0\x48\x0f\xba\x2f\x03" },
    .{ "lock btsq %%rax, (%%rdi)", "\xf0\x48\x0f\xab\x07" },
    .{ "lock cmpxchgq %%rcx, (%%rdi)", "\xf0\x48\x0f\xb1\x0f" },
    .{ "lock decq (%%rdi)", "\xf0\x48\xff\x0f" },
    .{ "lock incl (%%rdi)", "\xf0\xff\x07" },
    .{ "lock incw (%%rdi)", "\xf0\x66\xff\x07" },
    .{ "lock negq (%%rdi)", "\xf0\x48\xf7\x1f" },
    .{ "lock notl (%%rdi)", "\xf0\xf7\x17" },
    .{ "lock orl $0, (%%rsp)", "\xf0\x83\x0c\x24\x00" },
    .{ "lock orq $0, (%%rsp)", "\xf0\x48\x83\x0c\x24\x00" },
    .{ "lock xaddq %%rax, (%%rdi)", "\xf0\x48\x0f\xc1\x07" },
    .{ "lock xaddw %%ax, (%%rdi)", "\xf0\x66\x0f\xc1\x07" },
    .{ "lodsb", "\xac" },
    .{ "lodsq", "\x48\xad" },
    .{ "lzcntq %%rcx, %%rax", "\xf3\x48\x0f\xbd\xc1" },
    .{ "mfence", "\x0f\xae\xf0" },
    .{ "movbel %%eax, (%%rdi)", "\x0f\x38\xf1\x07" },
    .{ "movbeq (%%rdi), %%rax", "\x48\x0f\x38\xf0\x07" },
    .{ "movsb", "\xa4" },
    .{ "movsd", "\xa5" },
    .{ "movsq", "\x48\xa5" },
    .{ "movsx %%al, %%eax", "\x0f\xbe\xc0" },
    .{ "movsx %%cl, %%rax", "\x48\x0f\xbe\xc1" },
    .{ "movsx %%cx, %%eax", "\x0f\xbf\xc1" },
    .{ "movsxd %%eax, %%rax", "\x48\x63\xc0" },
    .{ "movzx %%al, %%eax", "\x0f\xb6\xc0" },
    .{ "movzx %%al, %%r8", "\x4c\x0f\xb6\xc0" },
    .{ "movzx %%ax, %%rcx", "\x48\x0f\xb7\xc8" },
    .{ "mulb %%cl", "\xf6\xe1" },
    .{ "mulq (%%rdi)", "\x48\xf7\x27" },
    .{ "negb %%al", "\xf6\xd8" },
    .{ "negl (%%rdi)", "\xf7\x1f" },
    .{ "nop", "\x90" },
    .{ "notq (%%rdi)", "\x48\xf7\x17" },
    .{ "notw %%ax", "\x66\xf7\xd0" },
    .{ "orq $-1, %%rax", "\x48\x83\xc8\xff" },
    .{ "pause", "\xf3\x90" },
    .{ "popcnt %%rcx, %%rax", "\xf3\x48\x0f\xb8\xc1" },
    .{ "popcntl %%ecx, %%eax", "\xf3\x0f\xb8\xc1" },
    .{ "popcntq %%rcx, %%rax", "\xf3\x48\x0f\xb8\xc1" },
    .{ "popcntw %%cx, %%ax", "\x66\xf3\x0f\xb8\xc1" },
    .{ "popf", "\x66\x9d" },
    .{ "popfq", "\x9d" },
    .{ "popfw", "\x66\x9d" },
    .{ "popq %%r12", "\x41\x5c" },
    .{ "prefetchntab (%%rdi)", "\x0f\x18\x07" },
    .{ "prefetcht0b (%%rdi)", "\x0f\x18\x0f" },
    .{ "prefetcht1b (%%rdi)", "\x0f\x18\x17" },
    .{ "prefetcht2b (%%rdi)", "\x0f\x18\x1f" },
    .{ "prefetchwb (%%rdi)", "\x0f\x0d\x0f" },
    .{ "pushfq", "\x9c" },
    .{ "pushq $5", "\x6a\x05" },
    .{ "pushq %%r12", "\x41\x54" },
    .{ "rclq $1, %%rax", "\x48\xd1\xd0" },
    .{ "rdpid %%rax", "\xf3\x0f\xc7\xf8" },
    .{ "rdrand %%eax", "\x0f\xc7\xf0" },
    .{ "rdrand %%rax", "\x48\x0f\xc7\xf0" },
    .{ "rdseed %%rax", "\x48\x0f\xc7\xf8" },
    .{ "rdtsc", "\x0f\x31" },
    .{ "rdtscp", "\x0f\x01\xf9" },
    .{ "rep movsb", "\xf3\xa4" },
    .{ "rep movsl", "\xf3\xa5" },
    .{ "rep movsq", "\xf3\x48\xa5" },
    .{ "rep movsw", "\xf3\x66\xa5" },
    .{ "rep stosb", "\xf3\xaa" },
    .{ "rep stosq", "\xf3\x48\xab" },
    .{ "rep stosw", "\xf3\x66\xab" },
    .{ "repe cmpsb", "\xf3\xa6" },
    .{ "repne scasb", "\xf2\xae" },
    .{ "repnz cmpsq", "\xf2\x48\xa7" },
    .{ "repz scasb", "\xf3\xae" },
    .{ "retq", "\xc3" },
    .{ "rorl $8, %%eax", "\xc1\xc8\x08" },
    .{ "sahf", "\x9e" },
    .{ "sarq $1, %%rax", "\x48\xd1\xf8" },
    .{ "sbb %%edx, %%edx", "\x19\xd2" },
    .{ "sbbl %%eax, (%%rdi)", "\x19\x07" },
    .{ "sbbq %%rcx, %%rax", "\x48\x19\xc8" },
    .{ "scasw", "\x66\xaf" },
    .{ "seta %%al", "\x0f\x97\xc0" },
    .{ "setb %%r8b", "\x41\x0f\x92\xc0" },
    .{ "setcb %%al", "\x0f\x92\xc0" },
    .{ "sete %%al", "\x0f\x94\xc0" },
    .{ "sete %%sil", "\x40\x0f\x94\xc6" },
    .{ "setg %%al", "\x0f\x9f\xc0" },
    .{ "setl %%dl", "\x0f\x9c\xc2" },
    .{ "setnae %%al", "\x0f\x92\xc0" },
    .{ "setne %%cl", "\x0f\x95\xc1" },
    .{ "setne %%r15b", "\x41\x0f\x95\xc7" },
    .{ "setnz %%al", "\x0f\x95\xc0" },
    .{ "setp %%al", "\x0f\x9a\xc0" },
    .{ "setpo %%al", "\x0f\x9b\xc0" },
    .{ "setzb (%%rdi)", "\x0f\x94\x07" },
    .{ "sfence", "\x0f\xae\xf8" },
    .{ "shl %%cl, %%rax", "\x48\xd3\xe0" },
    .{ "shld %%cl, %%rcx, %%rax", "\x48\x0f\xa5\xc8" },
    .{ "shldl $31, %%ecx, %%eax", "\x0f\xa4\xc8\x1f" },
    .{ "shldq $4, %%rcx, %%rax", "\x48\x0f\xa4\xc8\x04" },
    .{ "shldq $4, %%rcx, (%%rdi)", "\x48\x0f\xa4\x0f\x04" },
    .{ "shlq $1, %%rax", "\x48\xd1\xe0" },
    .{ "shlq $1, (%%rdi)", "\x48\xd1\x27" },
    .{ "shlq $3, (%%rdi)", "\x48\xc1\x27\x03" },
    .{ "stc", "\xf9" },
    .{ "std", "\xfd" },
    .{ "sti", "\xfb" },
    .{ "stmxcsr (%%rdi)", "\x0f\xae\x1f" },
    .{ "stmxcsrl (%%rdi)", "\x0f\xae\x1f" },
    .{ "stosl", "\xab" },
    .{ "stosq", "\x48\xab" },
    .{ "subl $1000, %%eax", "\x2d\xe8\x03\x00\x00" },
    .{ "syscall", "\x0f\x05" },
    .{ "testb $1, %%al", "\xa8\x01" },
    .{ "testl $1000, %%eax", "\xa9\xe8\x03\x00\x00" },
    .{ "testl %%eax, (%%rdi)", "\x85\x07" },
    .{ "testq $1, (%%rdi)", "\x48\xf7\x07\x01\x00\x00\x00" },
    .{ "testw $1, %%ax", "\x66\xa9\x01\x00" },
    .{ "ud2", "\x0f\x0b" },
    .{ "wait", "\x9b" },
    .{ "xaddl %%ecx, (%%rdi)", "\x0f\xc1\x0f" },
    .{ "xaddq %%rax, %%rcx", "\x48\x0f\xc1\xc1" },
    .{ "xchg %%ax, %%cx", "\x66\x91" },
    .{ "xchg %%r8, %%rax", "\x49\x90" },
    .{ "xchg %%rax, %%rcx", "\x48\x91" },
    .{ "xchgb %%al, %%cl", "\x86\xc1" },
    .{ "xchgl %%eax, %%ecx", "\x91" },
    .{ "xchgl %%ecx, %%eax", "\x91" },
    .{ "xchgl %%r8d, %%eax", "\x41\x90" },
    .{ "xchgq %%rax, (%%rdi)", "\x48\x87\x07" },
    .{ "xchgq %%rbx, %%rbx", "\x48\x87\xdb" },
    .{ "xchgq %%rcx, %%rax", "\x48\x91" },
    .{ "xchgq (%%rdi), %%rax", "\x48\x87\x07" },
    .{ "xchgw %%ax, %%ax", "\x66\x90" },
    .{ "xgetbv", "\x0f\x01\xd0" },
    .{ "xorl $0x80, %%eax", "\x35\x80\x00\x00\x00" },
};

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    const out = &w.interface;

    // wamr's fences and cycle counter.
    x = 1;
    asm volatile ("mfence" ::: .{ .memory = true });
    asm volatile ("lfence" ::: .{ .memory = true });
    asm volatile ("sfence" ::: .{ .memory = true });
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    try out.print("x={d} tsc_nonzero={}\n", .{ x, (@as(u64, hi) << 32 | lo) != 0 });

    // A suffix resizes a named register: a dword `inc` zeroes the top half.
    var a: u64 = 0xffff_ffff_ffff_fffe;
    asm ("incl %[a]"
        : [a] "+r" (a),
    );
    try out.print("incl 0x{x}\n", .{a});
    var b: u64 = 0x0102030405060708;
    asm ("bswapq %[b]"
        : [b] "+r" (b),
    );
    try out.print("bswapq 0x{x}\n", .{b});
    const pop = asm ("popcntq %[s], %[d]"
        : [d] "=r" (-> u64),
        : [s] "r" (@as(u64, 0xf0f0)),
    );
    try out.print("popcntq {d}\n", .{pop});
    const fwd = asm ("bsfq %[s], %[d]"
        : [d] "=r" (-> u64),
        : [s] "r" (@as(u64, 0x50)),
    );
    const rev = asm ("bsrq %[s], %[d]"
        : [d] "=r" (-> u64),
        : [s] "r" (@as(u64, 0x50)),
    );
    try out.print("bsf {d} bsr {d}\n", .{ fwd, rev });
    const prod = asm ("imulq $-7, %[s], %[d]"
        : [d] "=r" (-> i64),
        : [s] "r" (@as(i64, 6)),
    );
    try out.print("imulq {d}\n", .{prod});
    var sel: u64 = 3;
    var eq: u8 = 0;
    asm (
        \\ testq %[z], %[z]
        \\ cmovzq %[a], %[d]
        \\ sete %[e]
        : [d] "+r" (sel),
          [e] "=r" (eq),
        : [z] "r" (@as(u64, 0)),
          [a] "r" (@as(u64, 7)),
    );
    try out.print("cmovz {d} sete {d}\n", .{ sel, eq });
    var counter: u64 = 10;
    var add: u64 = 5;
    asm volatile ("lock xaddq %[v], (%%rdi)"
        : [v] "+r" (add),
        : [p] "{rdi}" (&counter),
        : .{ .memory = true });
    try out.print("lock xaddq {d} {d}\n", .{ add, counter });
    var cell: u64 = 42;
    var expected: u64 = 42;
    var swapped: u8 = 0;
    asm volatile (
        \\ lock cmpxchgq %[new], (%%rdi)
        \\ sete %[ok]
        : [exp] "+{rax}" (expected),
          [ok] "=r" (swapped),
        : [new] "r" (@as(u64, 99)),
          [p] "{rdi}" (&cell),
        : .{ .memory = true });
    try out.print("lock cmpxchgq {d} {d}\n", .{ swapped, cell });
    var bytes: [8]u8 = @splat(0);
    var dst: [*]u8 = &bytes;
    var n: usize = 6;
    asm volatile ("rep stosb"
        : [d] "+{rdi}" (dst),
          [n] "+{rcx}" (n),
        : [v] "{al}" (@as(u8, 0xab)),
        : .{ .memory = true });
    try out.print("rep stosb {x}\n", .{&bytes});
    var copy: [5]u8 = undefined;
    var to: [*]u8 = &copy;
    var from: [*]const u8 = "hello";
    n = 5;
    asm volatile ("rep movsb"
        : [d] "+{rdi}" (to),
          [s] "+{rsi}" (from),
          [n] "+{rcx}" (n),
        :
        : .{ .memory = true });
    try out.print("rep movsb {s}\n", .{&copy});
    var bits: u64 = 0;
    var bit: u8 = 0;
    asm (
        \\ btsq $5, %[b]
        \\ btq $5, %[b]
        \\ setc %[c]
        : [b] "+r" (bits),
          [c] "=r" (bit),
    );
    try out.print("bts {d} bt {d}\n", .{ bits, bit });
    var high: u64 = 1;
    asm ("shldq $4, %[s], %[d]"
        : [d] "+r" (high),
        : [s] "r" (@as(u64, 0xf000_0000_0000_0000)),
    );
    try out.print("shldq 0x{x}\n", .{high});
    var p: u64 = 1;
    var q: u64 = 2;
    asm ("xchgq %[p], %[q]"
        : [p] "+r" (p),
          [q] "+r" (q),
    );
    try out.print("xchgq {d} {d}\n", .{ p, q });
    const zx = asm ("movzx %[s], %[d]"
        : [d] "=r" (-> u32),
        : [s] "r" (@as(u8, 0xff)),
    );
    const sx = asm ("movsx %[s], %[d]"
        : [d] "=r" (-> i32),
        : [s] "r" (@as(u8, 0xff)),
    );
    try out.print("movzx {d} movsx {d}\n", .{ zx, sx });
    // A 128-bit add: all ones plus one carries into the high half.
    var sum_lo: u64 = 0xffff_ffff_ffff_ffff;
    var sum_hi: u64 = 0;
    asm (
        \\ addq %[b_lo], %[a_lo]
        \\ adcq %[b_hi], %[a_hi]
        : [a_lo] "+r" (sum_lo),
          [a_hi] "+r" (sum_hi),
        : [b_lo] "r" (@as(u64, 1)),
          [b_hi] "r" (@as(u64, 0)),
    );
    try out.print("adc 0x{x} 0x{x}\n", .{ sum_hi, sum_lo });
    // Memory operands, sized by the suffix.
    var m: [5]u32 = .{ 6, 7, 8, 9, 0 };
    var nz: u8 = 0;
    asm volatile (
        \\ incl (%%rdi)
        \\ notl 4(%%rdi)
        \\ shll $3, 8(%%rdi)
        \\ testl $1, 12(%%rdi)
        \\ setnz %[nz]
        \\ setzb 16(%%rdi)
        : [nz] "=r" (nz),
        : [m] "{rdi}" (&m),
        : .{ .memory = true });
    try out.print("mem 0x{x} 0x{x} 0x{x} {d} {d}\n", .{ m[0], m[1], m[2], nz, m[4] });
    var dividend: i64 = -5;
    const high_part = asm ("cqo"
        : [hi] "={rdx}" (-> i64),
        : [lo] "{rax}" (dividend),
    );
    _ = &dividend;
    try out.print("cqo {d}\n", .{high_part});
    const flags = asm volatile (
        \\ std
        \\ cld
        \\ pushfq
        \\ popq %[f]
        : [f] "=r" (-> u64),
    );
    try out.print("flags {d}\n", .{flags & 0x402});
    var mxcsr: u32 = 0;
    var fpucw: u16 = 0;
    asm volatile (
        \\ stmxcsr (%%rdi)
        \\ ldmxcsr (%%rdi)
        \\ fnstcw (%%rsi)
        :
        : [m] "{rdi}" (&mxcsr),
          [c] "{rsi}" (&fpucw),
        : .{ .memory = true });
    try out.print("mxcsr 0x{x} fpucw 0x{x}\n", .{ mxcsr, fpucw });

    var ok: u32 = 0;
    inline for (insns) |row| {
        const code: [*]const u8 = @ptrFromInt(@intFromPtr(&Probe(row[0]).f));
        const want = row[1];
        if (std.mem.eql(u8, code[0..want.len], want) and std.mem.eql(u8, code[want.len..][0..4], "\xcc\xcc\xcc\xcc")) {
            ok += 1;
        } else {
            try out.print("{s}: {x}, upstream {x}\n", .{ row[0], code[0 .. want.len + 4], want });
        }
    }
    try out.print("{d} instructions as upstream assembles them\n", .{ok});
    try out.flush();
}
