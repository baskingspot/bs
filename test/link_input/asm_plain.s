# Assembly as is: no preprocessor.
	.text
	.globl asm_plain_mul
	.type asm_plain_mul, @function
asm_plain_mul:
	mov %rdi, %rax
	imul %rsi, %rax
	ret
	.section .note.GNU-stack, "", @progbits
