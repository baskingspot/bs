//! bs's Zig frontend: upstream's tokenizer, parser and AstGen, vendored so
//! that bs can compile more than the one release its own std carries
//! (docs/slop/zig-0.16.md). Everything in bs that reads syntax trees or
//! ZIR takes these types, not std.zig's.

pub const tokenizer = @import("tokenizer.zig");
pub const Token = tokenizer.Token;
pub const Tokenizer = tokenizer.Tokenizer;
pub const Ast = @import("Ast.zig");
pub const AstGen = @import("AstGen.zig");
pub const AstRlAnnotate = @import("AstRlAnnotate.zig");
pub const BuiltinFn = @import("BuiltinFn.zig");
pub const Zir = @import("Zir.zig");
pub const Zoir = @import("Zoir.zig");
pub const ZonGen = @import("ZonGen.zig");
pub const errors = @import("errors.zig");
/// A hash of this module's sources (tools/frontend_hash.zig): ZIR from one
/// version of them is not ZIR from another.
pub const source_hash: u64 = @import("frontend_hash").hash;
