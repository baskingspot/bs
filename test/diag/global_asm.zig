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

pub fn main() void {}

// error
// args: -femit-bin=global_asm
// bs-only: upstream's self-hosted backends drop container-level assembly, and its LLVM backend assembles it
// global_asm.zig:4:5: error[unsupported]: bs does not support the assembler directive '.data' yet
//   | asm (
// global_asm.zig:12:5: error[unsupported]: bs does not support asm operand 'puts' yet
//   | asm ("call puts");
// 2 errors
