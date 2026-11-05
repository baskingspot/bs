//! exit: 0
//! flags: -mcpu=x86_64_v2+lzcnt+movbe+prfchw+rdrnd+rdseed+clflushopt+rdpid+sha
//! targets: x86_64-linux
//! stdout: "x=1 tsc_nonzero=true\nincl 0xffffffff\nbswapq 0x807060504030201\npopcntq 8\nbsf 4 bsr 6\nimulq -42\ncmovz 7 sete 1\nlock xaddq 10 15\nlock cmpxchgq 1 99\nrep stosb abababababab0000\nrep movsb hello\nbts 32 bt 1\nshldq 0x1f\nxchgq 2 1\nmovzx 255 movsx -1\nadc 0x1 0x0\nmem 0x7 0xfffffff8 0x40 1 0\ncqo -1\nflags 2\nmxcsr 0x1f80 fpucw 0x37f\npshufb 66656463626139380036353433323130\npcmpeqb 0xdf7f ptest 1\npinsrd { 1, 2, 99, 4 } pextrd 4 palignr { 2, 99, 4, 5 } pmovzxbw { 255, 1, 2, 3, 4, 5, 6, 128 }\n476 instructions as upstream assembles them\n"

// Inline assembly's general-purpose instructions (wamr's `mfence` and
// `incl`, corpus round 5) and SSE through SSE4.2 and SHA ones in their
// register forms (evm.zig's `pshufb`), as upstream's assembler takes
// them: run, and
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
    .{ "addpd %%xmm9, %%xmm2", "\x66\x41\x0f\x58\xd1" },
    .{ "addps %%xmm9, %%xmm2", "\x41\x0f\x58\xd1" },
    .{ "addsd %%xmm9, %%xmm10", "\xf2\x45\x0f\x58\xd1" },
    .{ "addss %%xmm9, %%xmm10", "\xf3\x45\x0f\x58\xd1" },
    .{ "andnpd %%xmm9, %%xmm2", "\x66\x41\x0f\x55\xd1" },
    .{ "andnps %%xmm9, %%xmm2", "\x41\x0f\x55\xd1" },
    .{ "andpd %%xmm9, %%xmm2", "\x66\x41\x0f\x54\xd1" },
    .{ "andps %%xmm9, %%xmm2", "\x41\x0f\x54\xd1" },
    .{ "blendpd $27, %%xmm9, %%xmm12", "\x66\x45\x0f\x3a\x0d\xe1\x1b" },
    .{ "blendps $27, %%xmm9, %%xmm12", "\x66\x45\x0f\x3a\x0c\xe1\x1b" },
    .{ "blendvpd %%xmm0, %%xmm1, %%xmm2", "\x66\x0f\x38\x15\xd1" },
    .{ "blendvpd %%xmm9, %%xmm10", "\x66\x45\x0f\x38\x15\xd1" },
    .{ "blendvps %%xmm0, %%xmm1, %%xmm2", "\x66\x0f\x38\x14\xd1" },
    .{ "blendvps %%xmm1, %%xmm2", "\x66\x0f\x38\x14\xd1" },
    .{ "cmppd $1, %%xmm1, %%xmm2", "\x66\x0f\xc2\xd1\x01" },
    .{ "cmpps $1, %%xmm1, %%xmm2", "\x0f\xc2\xd1\x01" },
    .{ "cmpsd $1, %%xmm1, %%xmm2", "\xf2\x0f\xc2\xd1\x01" },
    .{ "cmpss $1, %%xmm1, %%xmm2", "\xf3\x0f\xc2\xd1\x01" },
    .{ "comisd %%xmm9, %%xmm10", "\x66\x45\x0f\x2f\xd1" },
    .{ "comiss %%xmm9, %%xmm10", "\x45\x0f\x2f\xd1" },
    .{ "cvtdq2pd %%xmm9, %%xmm10", "\xf3\x45\x0f\xe6\xd1" },
    .{ "cvtdq2ps %%xmm9, %%xmm2", "\x41\x0f\x5b\xd1" },
    .{ "cvtpd2dq %%xmm9, %%xmm10", "\xf2\x45\x0f\xe6\xd1" },
    .{ "cvtpd2ps %%xmm9, %%xmm10", "\x66\x45\x0f\x5a\xd1" },
    .{ "cvtps2dq %%xmm9, %%xmm2", "\x66\x41\x0f\x5b\xd1" },
    .{ "cvtps2pd %%xmm9, %%xmm10", "\x45\x0f\x5a\xd1" },
    .{ "cvtsd2si %%xmm1, %%eax", "\xf2\x0f\x2d\xc1" },
    .{ "cvtsd2si %%xmm1, %%rax", "\xf2\x48\x0f\x2d\xc1" },
    .{ "cvtsd2ss %%xmm9, %%xmm10", "\xf2\x45\x0f\x5a\xd1" },
    .{ "cvtsi2sd %%r9d, %%xmm1", "\xf2\x41\x0f\x2a\xc9" },
    .{ "cvtsi2sd %%rax, %%xmm1", "\xf2\x48\x0f\x2a\xc8" },
    .{ "cvtsi2ss %%eax, %%xmm1", "\xf3\x0f\x2a\xc8" },
    .{ "cvtsi2ss %%rax, %%xmm1", "\xf3\x48\x0f\x2a\xc8" },
    .{ "cvtss2sd %%xmm9, %%xmm10", "\xf3\x45\x0f\x5a\xd1" },
    .{ "cvtss2si %%xmm1, %%eax", "\xf3\x0f\x2d\xc1" },
    .{ "cvtss2si %%xmm1, %%rax", "\xf3\x48\x0f\x2d\xc1" },
    .{ "cvttpd2dq %%xmm9, %%xmm10", "\x66\x45\x0f\xe6\xd1" },
    .{ "cvttps2dq %%xmm9, %%xmm2", "\xf3\x41\x0f\x5b\xd1" },
    .{ "cvttsd2si %%xmm1, %%eax", "\xf2\x0f\x2c\xc1" },
    .{ "cvttsd2si %%xmm1, %%rax", "\xf2\x48\x0f\x2c\xc1" },
    .{ "cvttss2si %%xmm1, %%eax", "\xf3\x0f\x2c\xc1" },
    .{ "cvttss2si %%xmm1, %%rax", "\xf3\x48\x0f\x2c\xc1" },
    .{ "divpd %%xmm9, %%xmm2", "\x66\x41\x0f\x5e\xd1" },
    .{ "divps %%xmm9, %%xmm2", "\x41\x0f\x5e\xd1" },
    .{ "divsd %%xmm9, %%xmm10", "\xf2\x45\x0f\x5e\xd1" },
    .{ "divss %%xmm9, %%xmm10", "\xf3\x45\x0f\x5e\xd1" },
    .{ "dppd $27, %%xmm9, %%xmm12", "\x66\x45\x0f\x3a\x41\xe1\x1b" },
    .{ "dpps $27, %%xmm9, %%xmm12", "\x66\x45\x0f\x3a\x40\xe1\x1b" },
    .{ "extractps $1, %%xmm1, %%r9d", "\x66\x41\x0f\x3a\x17\xc9\x01" },
    .{ "insertps $1, %%xmm1, %%xmm2", "\x66\x0f\x3a\x21\xd1\x01" },
    .{ "maxpd %%xmm9, %%xmm2", "\x66\x41\x0f\x5f\xd1" },
    .{ "maxps %%xmm9, %%xmm2", "\x41\x0f\x5f\xd1" },
    .{ "maxsd %%xmm9, %%xmm10", "\xf2\x45\x0f\x5f\xd1" },
    .{ "maxss %%xmm9, %%xmm10", "\xf3\x45\x0f\x5f\xd1" },
    .{ "minpd %%xmm9, %%xmm2", "\x66\x41\x0f\x5d\xd1" },
    .{ "minps %%xmm9, %%xmm2", "\x41\x0f\x5d\xd1" },
    .{ "minsd %%xmm9, %%xmm10", "\xf2\x45\x0f\x5d\xd1" },
    .{ "minss %%xmm9, %%xmm10", "\xf3\x45\x0f\x5d\xd1" },
    .{ "movapd %%xmm9, %%xmm2", "\x66\x41\x0f\x28\xd1" },
    .{ "movaps %%xmm9, %%xmm2", "\x41\x0f\x28\xd1" },
    .{ "movd %%eax, %%xmm9", "\x66\x44\x0f\x6e\xc8" },
    .{ "movd %%xmm1, %%r9d", "\x66\x41\x0f\x7e\xc9" },
    .{ "movdqa %%xmm9, %%xmm2", "\x66\x41\x0f\x6f\xd1" },
    .{ "movdqu %%xmm9, %%xmm2", "\xf3\x41\x0f\x6f\xd1" },
    .{ "movhlps %%xmm9, %%xmm2", "\x41\x0f\x12\xd1" },
    .{ "movlhps %%xmm9, %%xmm2", "\x41\x0f\x16\xd1" },
    .{ "movmskpd %%xmm1, %%r9d", "\x66\x44\x0f\x50\xc9" },
    .{ "movmskpd %%xmm1, %%rax", "\x66\x0f\x50\xc1" },
    .{ "movmskps %%xmm1, %%r9d", "\x44\x0f\x50\xc9" },
    .{ "movmskps %%xmm1, %%rax", "\x0f\x50\xc1" },
    .{ "movsd %%xmm9, %%xmm2", "\xf2\x41\x0f\x10\xd1" },
    .{ "movss %%xmm9, %%xmm2", "\xf3\x41\x0f\x10\xd1" },
    .{ "movupd %%xmm9, %%xmm2", "\x66\x41\x0f\x10\xd1" },
    .{ "movups %%xmm9, %%xmm2", "\x41\x0f\x10\xd1" },
    .{ "mulpd %%xmm9, %%xmm2", "\x66\x41\x0f\x59\xd1" },
    .{ "mulps %%xmm9, %%xmm2", "\x41\x0f\x59\xd1" },
    .{ "mulsd %%xmm9, %%xmm10", "\xf2\x45\x0f\x59\xd1" },
    .{ "mulss %%xmm9, %%xmm10", "\xf3\x45\x0f\x59\xd1" },
    .{ "orpd %%xmm9, %%xmm2", "\x66\x41\x0f\x56\xd1" },
    .{ "orps %%xmm9, %%xmm2", "\x41\x0f\x56\xd1" },
    .{ "pabsb %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x1c\xd1" },
    .{ "pabsd %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x1e\xd1" },
    .{ "pabsw %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x1d\xd1" },
    .{ "packssdw %%xmm9, %%xmm2", "\x66\x41\x0f\x6b\xd1" },
    .{ "packsswb %%xmm9, %%xmm2", "\x66\x41\x0f\x63\xd1" },
    .{ "packusdw %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x2b\xd1" },
    .{ "packuswb %%xmm9, %%xmm2", "\x66\x41\x0f\x67\xd1" },
    .{ "paddb %%xmm9, %%xmm2", "\x66\x41\x0f\xfc\xd1" },
    .{ "paddd %%xmm9, %%xmm2", "\x66\x41\x0f\xfe\xd1" },
    .{ "paddq %%xmm9, %%xmm2", "\x66\x41\x0f\xd4\xd1" },
    .{ "paddsb %%xmm9, %%xmm2", "\x66\x41\x0f\xec\xd1" },
    .{ "paddsw %%xmm9, %%xmm2", "\x66\x41\x0f\xed\xd1" },
    .{ "paddusb %%xmm9, %%xmm2", "\x66\x41\x0f\xdc\xd1" },
    .{ "paddusw %%xmm9, %%xmm2", "\x66\x41\x0f\xdd\xd1" },
    .{ "paddw %%xmm9, %%xmm2", "\x66\x41\x0f\xfd\xd1" },
    .{ "palignr $27, %%xmm9, %%xmm12", "\x66\x45\x0f\x3a\x0f\xe1\x1b" },
    .{ "pand %%xmm9, %%xmm2", "\x66\x41\x0f\xdb\xd1" },
    .{ "pandn %%xmm9, %%xmm2", "\x66\x41\x0f\xdf\xd1" },
    .{ "pblendvb %%xmm0, %%xmm1, %%xmm2", "\x66\x0f\x38\x10\xd1" },
    .{ "pblendvb %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x10\xd1" },
    .{ "pblendw $27, %%xmm9, %%xmm12", "\x66\x45\x0f\x3a\x0e\xe1\x1b" },
    .{ "pcmpeqb %%xmm9, %%xmm2", "\x66\x41\x0f\x74\xd1" },
    .{ "pcmpeqd %%xmm9, %%xmm2", "\x66\x41\x0f\x76\xd1" },
    .{ "pcmpeqq %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x29\xd1" },
    .{ "pcmpeqw %%xmm9, %%xmm2", "\x66\x41\x0f\x75\xd1" },
    .{ "pcmpgtb %%xmm9, %%xmm2", "\x66\x41\x0f\x64\xd1" },
    .{ "pcmpgtd %%xmm9, %%xmm2", "\x66\x41\x0f\x66\xd1" },
    .{ "pcmpgtq %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x37\xd1" },
    .{ "pcmpgtw %%xmm9, %%xmm2", "\x66\x41\x0f\x65\xd1" },
    .{ "pextrb $3, %%xmm1, %%r9d", "\x66\x41\x0f\x3a\x14\xc9\x03" },
    .{ "pextrd $3, %%xmm1, %%r9d", "\x66\x41\x0f\x3a\x16\xc9\x03" },
    .{ "pextrq $1, %%xmm1, %%r9", "\x66\x49\x0f\x3a\x16\xc9\x01" },
    .{ "pextrw $3, %%xmm1, %%r9d", "\x66\x44\x0f\xc5\xc9\x03" },
    .{ "phaddd %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x02\xd1" },
    .{ "phaddsw %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x03\xd1" },
    .{ "phaddw %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x01\xd1" },
    .{ "phminposuw %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x41\xd1" },
    .{ "phsubd %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x06\xd1" },
    .{ "phsubsw %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x07\xd1" },
    .{ "phsubw %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x05\xd1" },
    .{ "pinsrb $3, %%r9d, %%xmm1", "\x66\x41\x0f\x3a\x20\xc9\x03" },
    .{ "pinsrd $3, %%eax, %%xmm9", "\x66\x44\x0f\x3a\x22\xc8\x03" },
    .{ "pinsrq $1, %%rax, %%xmm9", "\x66\x4c\x0f\x3a\x22\xc8\x01" },
    .{ "pinsrw $3, %%r9d, %%xmm1", "\x66\x41\x0f\xc4\xc9\x03" },
    .{ "pmaddubsw %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x04\xd1" },
    .{ "pmaddwd %%xmm9, %%xmm2", "\x66\x41\x0f\xf5\xd1" },
    .{ "pmaxsb %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x3c\xd1" },
    .{ "pmaxsd %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x3d\xd1" },
    .{ "pmaxsw %%xmm9, %%xmm2", "\x66\x41\x0f\xee\xd1" },
    .{ "pmaxub %%xmm9, %%xmm2", "\x66\x41\x0f\xde\xd1" },
    .{ "pmaxud %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x3f\xd1" },
    .{ "pmaxuw %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x3e\xd1" },
    .{ "pminsb %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x38\xd1" },
    .{ "pminsd %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x39\xd1" },
    .{ "pminsw %%xmm9, %%xmm2", "\x66\x41\x0f\xea\xd1" },
    .{ "pminub %%xmm9, %%xmm2", "\x66\x41\x0f\xda\xd1" },
    .{ "pminud %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x3b\xd1" },
    .{ "pminuw %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x3a\xd1" },
    .{ "pmovmskb %%xmm1, %%r9", "\x66\x44\x0f\xd7\xc9" },
    .{ "pmovmskb %%xmm9, %%eax", "\x66\x41\x0f\xd7\xc1" },
    .{ "pmovsxbd %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x21\xd1" },
    .{ "pmovsxbq %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x22\xd1" },
    .{ "pmovsxbw %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x20\xd1" },
    .{ "pmovsxdq %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x25\xd1" },
    .{ "pmovsxwd %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x23\xd1" },
    .{ "pmovsxwq %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x24\xd1" },
    .{ "pmovzxbd %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x31\xd1" },
    .{ "pmovzxbq %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x32\xd1" },
    .{ "pmovzxbw %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x30\xd1" },
    .{ "pmovzxdq %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x35\xd1" },
    .{ "pmovzxwd %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x33\xd1" },
    .{ "pmovzxwq %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x34\xd1" },
    .{ "pmuldq %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x28\xd1" },
    .{ "pmulhrsw %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x0b\xd1" },
    .{ "pmulhuw %%xmm9, %%xmm2", "\x66\x41\x0f\xe4\xd1" },
    .{ "pmulhw %%xmm9, %%xmm2", "\x66\x41\x0f\xe5\xd1" },
    .{ "pmulld %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x40\xd1" },
    .{ "pmullw %%xmm9, %%xmm2", "\x66\x41\x0f\xd5\xd1" },
    .{ "pmuludq %%xmm9, %%xmm2", "\x66\x41\x0f\xf4\xd1" },
    .{ "por %%xmm9, %%xmm2", "\x66\x41\x0f\xeb\xd1" },
    .{ "psadbw %%xmm9, %%xmm2", "\x66\x41\x0f\xf6\xd1" },
    .{ "pshufb %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x00\xd1" },
    .{ "pshufd $27, %%xmm9, %%xmm12", "\x66\x45\x0f\x70\xe1\x1b" },
    .{ "pshufhw $27, %%xmm9, %%xmm12", "\xf3\x45\x0f\x70\xe1\x1b" },
    .{ "pshuflw $27, %%xmm9, %%xmm12", "\xf2\x45\x0f\x70\xe1\x1b" },
    .{ "psignb %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x08\xd1" },
    .{ "psignd %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x0a\xd1" },
    .{ "psignw %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x09\xd1" },
    .{ "pslld $3, %%xmm10", "\x66\x41\x0f\x72\xf2\x03" },
    .{ "pslld %%xmm9, %%xmm2", "\x66\x41\x0f\xf2\xd1" },
    .{ "pslldq $3, %%xmm10", "\x66\x41\x0f\x73\xfa\x03" },
    .{ "psllq $3, %%xmm10", "\x66\x41\x0f\x73\xf2\x03" },
    .{ "psllq %%xmm9, %%xmm2", "\x66\x41\x0f\xf3\xd1" },
    .{ "psllw $3, %%xmm10", "\x66\x41\x0f\x71\xf2\x03" },
    .{ "psllw %%xmm9, %%xmm2", "\x66\x41\x0f\xf1\xd1" },
    .{ "psrad $3, %%xmm10", "\x66\x41\x0f\x72\xe2\x03" },
    .{ "psrad %%xmm9, %%xmm2", "\x66\x41\x0f\xe2\xd1" },
    .{ "psraw $3, %%xmm10", "\x66\x41\x0f\x71\xe2\x03" },
    .{ "psraw %%xmm9, %%xmm2", "\x66\x41\x0f\xe1\xd1" },
    .{ "psrld $3, %%xmm10", "\x66\x41\x0f\x72\xd2\x03" },
    .{ "psrld %%xmm9, %%xmm2", "\x66\x41\x0f\xd2\xd1" },
    .{ "psrldq $3, %%xmm10", "\x66\x41\x0f\x73\xda\x03" },
    .{ "psrlq $3, %%xmm10", "\x66\x41\x0f\x73\xd2\x03" },
    .{ "psrlq %%xmm9, %%xmm2", "\x66\x41\x0f\xd3\xd1" },
    .{ "psrlw $3, %%xmm10", "\x66\x41\x0f\x71\xd2\x03" },
    .{ "psrlw %%xmm9, %%xmm2", "\x66\x41\x0f\xd1\xd1" },
    .{ "psubb %%xmm9, %%xmm2", "\x66\x41\x0f\xf8\xd1" },
    .{ "psubd %%xmm9, %%xmm2", "\x66\x41\x0f\xfa\xd1" },
    .{ "psubq %%xmm9, %%xmm2", "\x66\x41\x0f\xfb\xd1" },
    .{ "psubsb %%xmm9, %%xmm2", "\x66\x41\x0f\xe8\xd1" },
    .{ "psubsw %%xmm9, %%xmm2", "\x66\x41\x0f\xe9\xd1" },
    .{ "psubusb %%xmm9, %%xmm2", "\x66\x41\x0f\xd8\xd1" },
    .{ "psubusw %%xmm9, %%xmm2", "\x66\x41\x0f\xd9\xd1" },
    .{ "psubw %%xmm9, %%xmm2", "\x66\x41\x0f\xf9\xd1" },
    .{ "ptest %%xmm9, %%xmm2", "\x66\x41\x0f\x38\x17\xd1" },
    .{ "punpckhbw %%xmm9, %%xmm2", "\x66\x41\x0f\x68\xd1" },
    .{ "punpckhdq %%xmm9, %%xmm2", "\x66\x41\x0f\x6a\xd1" },
    .{ "punpckhqdq %%xmm9, %%xmm2", "\x66\x41\x0f\x6d\xd1" },
    .{ "punpckhwd %%xmm9, %%xmm2", "\x66\x41\x0f\x69\xd1" },
    .{ "punpcklbw %%xmm9, %%xmm2", "\x66\x41\x0f\x60\xd1" },
    .{ "punpckldq %%xmm9, %%xmm2", "\x66\x41\x0f\x62\xd1" },
    .{ "punpcklqdq %%xmm9, %%xmm2", "\x66\x41\x0f\x6c\xd1" },
    .{ "punpcklwd %%xmm9, %%xmm2", "\x66\x41\x0f\x61\xd1" },
    .{ "pxor %%xmm9, %%xmm2", "\x66\x41\x0f\xef\xd1" },
    .{ "roundpd $27, %%xmm9, %%xmm12", "\x66\x45\x0f\x3a\x09\xe1\x1b" },
    .{ "roundps $27, %%xmm9, %%xmm12", "\x66\x45\x0f\x3a\x08\xe1\x1b" },
    .{ "roundsd $1, %%xmm1, %%xmm2", "\x66\x0f\x3a\x0b\xd1\x01" },
    .{ "roundss $1, %%xmm1, %%xmm2", "\x66\x0f\x3a\x0a\xd1\x01" },
    .{ "sha1msg1 %%xmm1, %%xmm2", "\x0f\x38\xc9\xd1" },
    .{ "sha1msg2 %%xmm1, %%xmm2", "\x0f\x38\xca\xd1" },
    .{ "sha1nexte %%xmm1, %%xmm2", "\x0f\x38\xc8\xd1" },
    .{ "sha1rnds4 $1, %%xmm1, %%xmm2", "\x0f\x3a\xcc\xd1\x01" },
    .{ "sha256msg1 %%xmm1, %%xmm2", "\x0f\x38\xcc\xd1" },
    .{ "sha256msg2 %%xmm1, %%xmm2", "\x0f\x38\xcd\xd1" },
    .{ "sha256rnds2 %%xmm0, %%xmm1, %%xmm2", "\x0f\x38\xcb\xd1" },
    .{ "sha256rnds2 %%xmm1, %%xmm2", "\x0f\x38\xcb\xd1" },
    .{ "shufpd $27, %%xmm9, %%xmm12", "\x66\x45\x0f\xc6\xe1\x1b" },
    .{ "shufps $27, %%xmm9, %%xmm12", "\x45\x0f\xc6\xe1\x1b" },
    .{ "sqrtpd %%xmm9, %%xmm2", "\x66\x41\x0f\x51\xd1" },
    .{ "sqrtps %%xmm9, %%xmm2", "\x41\x0f\x51\xd1" },
    .{ "sqrtsd %%xmm9, %%xmm10", "\xf2\x45\x0f\x51\xd1" },
    .{ "sqrtss %%xmm9, %%xmm10", "\xf3\x45\x0f\x51\xd1" },
    .{ "subpd %%xmm9, %%xmm2", "\x66\x41\x0f\x5c\xd1" },
    .{ "subps %%xmm9, %%xmm2", "\x41\x0f\x5c\xd1" },
    .{ "subsd %%xmm9, %%xmm10", "\xf2\x45\x0f\x5c\xd1" },
    .{ "subss %%xmm9, %%xmm10", "\xf3\x45\x0f\x5c\xd1" },
    .{ "ucomisd %%xmm9, %%xmm10", "\x66\x45\x0f\x2e\xd1" },
    .{ "ucomiss %%xmm9, %%xmm10", "\x45\x0f\x2e\xd1" },
    .{ "unpckhpd %%xmm9, %%xmm2", "\x66\x41\x0f\x15\xd1" },
    .{ "unpckhps %%xmm9, %%xmm2", "\x41\x0f\x15\xd1" },
    .{ "unpcklpd %%xmm9, %%xmm2", "\x66\x41\x0f\x14\xd1" },
    .{ "unpcklps %%xmm9, %%xmm2", "\x41\x0f\x14\xd1" },
    .{ "xorpd %%xmm9, %%xmm2", "\x66\x41\x0f\x57\xd1" },
    .{ "xorps %%xmm9, %%xmm2", "\x41\x0f\x57\xd1" },
    .{ "emms", "\x0f\x77" },
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

    // evm.zig's scanner: pshufb with the table tied to the output; an
    // index with its top bit set zeroes its lane.
    const Lanes = @Vector(16, u8);
    const table: Lanes = "0123456789abcdef".*;
    const indices: Lanes = .{ 15, 14, 13, 12, 11, 10, 9, 8, 0x80, 6, 5, 4, 3, 2, 1, 0 };
    const shuffled: [16]u8 = asm ("pshufb %[indices], %[out]"
        : [out] "=x" (-> Lanes),
        : [table] "0" (table),
          [indices] "x" (indices),
    );
    try out.print("pshufb {x}\n", .{&shuffled});
    var va: Lanes = "hello, world!!!!".*;
    asm ("pcmpeqb %[b], %[a]"
        : [a] "+x" (va),
        : [b] "x" (@as(Lanes, "hello, World!?!!".*)),
    );
    const eq_mask = asm ("pmovmskb %[a], %[m]"
        : [m] "=r" (-> u32),
        : [a] "x" (va),
    );
    var zf: u8 = 0;
    asm ("ptest %[a], %[a]\n setz %[z]"
        : [z] "=r" (zf),
        : [a] "x" (@as(Lanes, @splat(0))),
    );
    try out.print("pcmpeqb 0x{x} ptest {d}\n", .{ eq_mask, zf });
    var v4: @Vector(4, u32) = .{ 1, 2, 3, 4 };
    asm ("pinsrd $2, %[x], %[v]"
        : [v] "+x" (v4),
        : [x] "r" (@as(u32, 99)),
    );
    const lane3 = asm ("pextrd $3, %[v], %[d]"
        : [d] "=r" (-> u32),
        : [v] "x" (v4),
    );
    const aligned: @Vector(4, u32) = asm ("palignr $4, %[lo], %[hi]"
        : [hi] "=x" (-> @Vector(4, u32)),
        : [_] "0" (@as(@Vector(4, u32), .{ 5, 6, 7, 8 })),
          [lo] "x" (v4),
    );
    const widened: @Vector(8, u16) = asm ("pmovzxbw %[s], %[d]"
        : [d] "=x" (-> @Vector(8, u16)),
        : [s] "x" (@as(Lanes, .{ 0xff, 1, 2, 3, 4, 5, 6, 0x80, 9, 9, 9, 9, 9, 9, 9, 9 })),
    );
    try out.print("pinsrd {any} pextrd {d} palignr {any} pmovzxbw {any}\n", .{ v4, lane3, aligned, widened });

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
