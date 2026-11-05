// Container-level assembly bs cannot assemble is an error at the `asm`,
// not dropped code.
comptime {
    asm (
        \\.globl f
        \\f: ret
        \\.data
    );
}

comptime {
    asm ("call puts");
}

comptime {
    asm (".globl answer\n.set answer, 42");
}

pub fn main() void {}

// error
// args: -femit-bin=global_asm
// bs-only: upstream's self-hosted backends drop container-level assembly, and its LLVM backend assembles it
// global_asm.zig:4:5: error[unsupported]: bs does not support the assembler directive '.data' yet
//   | asm (
// global_asm.zig:12:5: error[unsupported]: bs does not support asm operand 'puts' yet
//   | asm ("call puts");
// global_asm.zig:16:5: error[unsupported]: bs supports only a symbol as the value of '.set answer, 42' yet
//   | asm (".globl answer\n.set answer, 42");
// 3 errors
