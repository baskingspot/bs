; LLVM IR as text, compiled by Clang without the preprocessor.
define i32 @ir_mul(i32 %a, i32 %b) {
  %p = mul i32 %a, %b
  %r = add i32 %p, 7
  ret i32 %r
}
