# Assembly as is: no preprocessor.
	.text
	.globl asm_plain_mul
	.type asm_plain_mul, @function
asm_plain_mul:
	mov %rdi, %rax
	imul %rsi, %rax
	ret
	# A global absolute symbol, which asm_cpp.S and the Zig code bind to.
	.globl asm_abs_value
	.set asm_abs_value, 0x1234
	.section .note.GNU-stack, "", @progbits
