# A COMDAT group that comdat1.s and comdat2.s both define, with different
# contents: the link keeps the first object's copy, and both objects'
# calls reach it (build.zig, `addLinkInputTests`). Each function has an
# FDE: the dropped copy's goes with it, which moves the next FDE's CIE.
	.section .text.comdat_value,"axG",@progbits,comdat_value,comdat
	.globl comdat_value
	.type comdat_value,@function
comdat_value:
	.cfi_startproc
	movl $1, %eax
	ret
	.cfi_endproc
	.section .rodata.comdat_table,"aG",@progbits,comdat_value,comdat
	.globl comdat_table
comdat_table:
	.quad comdat_value
	.text
	.globl comdat_call1
	.type comdat_call1,@function
comdat_call1:
	.cfi_startproc
	movq comdat_table(%rip), %rax
	call *%rax
	movl %eax, %ecx
	call comdat_value
	imull $10, %ecx
	addl %ecx, %eax
	ret
	.cfi_endproc
	.section .note.GNU-stack,"",@progbits
