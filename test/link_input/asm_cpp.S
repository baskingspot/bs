// Preprocessed assembly: an include, a define from the command line.
#include "asm.h"
	.text
	.globl asm_cpp_add
	.type asm_cpp_add, @function
asm_cpp_add:
	lea ASM_ADD(%rdi), %rax
#ifdef ASM_EXTRA
	add $ASM_EXTRA, %rax
#endif
	ret
	.globl asm_cpp_abs
	.type asm_cpp_abs, @function
asm_cpp_abs:
	movabs $asm_abs_value, %rax
	ret
	.section .note.GNU-stack, "", @progbits
