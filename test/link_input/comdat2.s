# A COMDAT group that comdat1.s and comdat2.s both define, with different
# contents: the link keeps the first object's copy, and both objects'
# calls reach it (build.zig, `addLinkInputTests`).
	.section .text.comdat_value,"axG",@progbits,comdat_value,comdat
	.globl comdat_value
	.type comdat_value,@function
comdat_value:
	movl $2, %eax
	ret
	.section .rodata.comdat_table,"aG",@progbits,comdat_value,comdat
	.globl comdat_table
comdat_table:
	.quad comdat_value
	.text
	.globl comdat_call2
	.type comdat_call2,@function
comdat_call2:
	movq comdat_table(%rip), %rax
	call *%rax
	movl %eax, %ecx
	call comdat_value
	imull $10, %ecx
	addl %ecx, %eax
	ret
	.section .note.GNU-stack,"",@progbits
