//! exit: 3
//! targets: x86_64-linux aarch64-linux aarch64-macos
//! rebuild-without: "comptime {\n    asm (\".globl bs_edit_asm_gone\\nbs_edit_asm_gone:\\n    ret\\n\");\n}\n"
//! Edit builds that add a `comptime` block of container-level assembly,
//! then remove it. The block's unit is outdated, so the walk leaves it
//! to analysis, but its namespace's scan no longer makes it: it stayed
//! undecided and reached, and the build linked its assembly still.
comptime {
    asm (".globl bs_edit_asm_gone\nbs_edit_asm_gone:\n    ret\n");
}

pub fn main() u8 {
    return 3;
}
