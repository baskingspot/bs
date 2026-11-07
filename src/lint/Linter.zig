//! ziglint's syntax rules, run on a file's AST: the rules of ziglint
//! 0.8.1's `Linter` in its simple mode (no `TypeResolver`), so that their
//! findings are ziglint's for the same source. Every rule runs, whatever
//! the config says, and `// ziglint-ignore:` comments are applied here:
//! the findings depend only on the source and the file's name, so the
//! frontend caches them by content (`lint/facts.zig`), and the report step
//! (`lint/Config.zig`) applies the config's switches.
//!
//! Ported from rockorager/ziglint v0.8.1 (f6a3fc2), src/Linter.zig:
//!
//! MIT License
//!
//! Copyright (c) 2026 Tim Culverhouse
//!
//! Permission is hereby granted, free of charge, to any person obtaining a
//! copy of this software and associated documentation files (the
//! "Software"), to deal in the Software without restriction, including
//! without limitation the rights to use, copy, modify, merge, publish,
//! distribute, sublicense, and/or sell copies of the Software, and to
//! permit persons to whom the Software is furnished to do so, subject to
//! the following conditions:
//!
//! The above copyright notice and this permission notice shall be included
//! in all copies or substantial portions of the Software.
//!
//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
//! OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//! MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
//! IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
//! CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
//! TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
//! SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

const std = @import("std");
const Ast = std.zig.Ast;
const rules = @import("rules.zig");

const Linter = @This();

/// Temporaries and the findings' contexts; the caller frees them together.
allocator: std.mem.Allocator,
source: [:0]const u8,
/// The file's path, for its base name (Z009, Z012, Z021).
path: []const u8,
tree: Ast,
diagnostics: std.ArrayList(Diagnostic) = .empty,
seen_imports: std.StringHashMapUnmanaged(Ast.TokenIndex) = .empty,
allocated_contexts: std.ArrayList([]const u8) = .empty,
public_types: std.StringHashMapUnmanaged(void) = .empty,
imported_types: std.StringHashMapUnmanaged(void) = .empty,
import_bindings: std.StringHashMapUnmanaged(ImportInfo) = .empty,
used_identifiers: std.StringHashMapUnmanaged(void) = .empty,
current_fn_return_type: Ast.Node.OptionalIndex = .none,
parent_map: []Ast.Node.OptionalIndex = &.{},
/// Byte offset of each line's start, built on the first ignore check of a
/// file that has an ignore comment; empty for one that has none.
line_starts: std.ArrayList(u32) = .empty,
has_ignores: bool = false,

/// The rules' version, in the name of the frontend's cached findings
/// (`Frontend.lintFindings`): bump it when a rule changes.
pub const version: u32 = 1;

/// Z024's facts record every line longer than this, whatever the config's
/// limit; a config with a lower one makes the report step scan the source
/// (`longLines`).
pub const long_line_min = 80;

const ImportInfo = struct {
    name_token: Ast.TokenIndex,
    is_pub: bool,
    is_discard: bool,
};

pub const Diagnostic = struct {
    /// 1-based, as ziglint's.
    line: u32,
    column: u32,
    /// Byte offset of the finding in the source.
    offset: u32,
    rule: rules.Rule,
    context: []const u8 = "",
};

/// Lints `tree`, parsed from `source` without errors, and returns its
/// findings, in `arena`.
pub fn run(arena: std.mem.Allocator, source: [:0]const u8, tree: Ast, path: []const u8) []const Diagnostic {
    std.debug.assert(tree.errors.len == 0);
    var self: Linter = .{ .allocator = arena, .source = source, .path = path, .tree = tree };
    self.has_ignores = std.mem.find(u8, source, "// ziglint-ignore:") != null;
    self.lint();
    return self.diagnostics.items;
}

fn lint(self: *Linter) void {
    self.checkLineLength(long_line_min);
    self.checkFileAsStruct();

    self.buildPublicTypesMap();
    self.collectAllIdentifiers();
    self.buildParentMap();

    for (self.tree.rootDecls()) |node| {
        self.visitNode(node);
    }

    self.checkUnusedImports();
    self.checkAliasUsage();
    self.checkThisBuiltin();
    self.checkInlineImports();
    self.checkCatchReturnAll();
    self.checkEmptyCatchAll();
    self.checkPrintLiteralArgs();
}

fn collectAllIdentifiers(self: *Linter) void {
    for (0..self.tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const tag = self.tree.nodeTag(node);
        switch (tag) {
            .identifier => {
                const name = self.tree.tokenSlice(self.tree.nodeMainToken(node));
                self.track(&self.used_identifiers, name);
            },
            .field_access => {
                // Walk field_access chain, tracking all field names and root identifier
                var current = node;
                while (self.tree.nodeTag(current) == .field_access) {
                    const data = self.tree.nodeData(current).node_and_token;
                    const field_name = self.tree.tokenSlice(data[1]);
                    self.track(&self.used_identifiers, field_name);
                    current = data[0];
                }
                if (self.tree.nodeTag(current) == .identifier) {
                    const name = self.tree.tokenSlice(self.tree.nodeMainToken(current));
                    self.track(&self.used_identifiers, name);
                }
            },
            else => {},
        }
    }
}

fn checkUnusedImports(self: *Linter) void {
    var it = self.import_bindings.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        // Skip pub re-exports - they're intentionally exposed
        if (info.is_pub) continue;

        // Discarded imports `_ = @import(...)` are always unused
        if (info.is_discard) {
            const loc = self.tree.tokenLocation(0, info.name_token);
            self.report(loc, .Z013, name);
            continue;
        }

        // Check if the bound name is used elsewhere
        if (!self.used_identifiers.contains(name)) {
            const loc = self.tree.tokenLocation(0, info.name_token);
            self.report(loc, .Z013, name);
        }
    }
}

const Alias = struct {
    name: []const u8,
    rhs_node: Ast.Node.Index,
};

/// Reports qualified paths that have a top-level alias, such as
/// `std.testing.expect(...)` when `const testing = std.testing;` exists.
/// The alias declaration itself is never reported; the qualified use is.
fn checkAliasUsage(self: *Linter) void {
    var aliases: std.ArrayList(Alias) = .empty;
    defer aliases.deinit(self.allocator);
    self.collectAliases(&aliases);
    if (aliases.items.len == 0) return;

    for (0..self.tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (self.tree.nodeTag(node) != .field_access) continue;
        if (!isIdentifierPath(&self.tree, node)) continue;

        const alias = findMatchingAlias(&self.tree, aliases.items, node) orelse continue;
        if (node == alias.rhs_node) continue;

        // Tests often compare an alias to its source, e.g.
        // `expectEqual(alias, path)`. Replacing the path there would make the
        // comparison vacuous, so skip when the alias is another argument.
        if (self.isAliasComparison(node, alias.name)) continue;

        // A longer path can match a more specific alias. Report the outermost
        // match so one expression does not produce two diagnostics.
        if (self.parent_map[@backingInt(node)].unwrap()) |parent| {
            if (self.tree.nodeTag(parent) == .field_access and
                findMatchingAlias(&self.tree, aliases.items, parent) != null)
            {
                continue;
            }
        }

        const root = identifierPathRoot(&self.tree, node);
        const loc = self.tree.tokenLocation(0, self.tree.nodeMainToken(root));
        const path = self.getNodeSource(node);
        const context = self.allocator.print("{s}\x00{s}", .{ alias.name, path }) catch continue;
        self.trackContext(context);
        self.report(loc, .Z035, context);
    }
}

const TokenRange = struct {
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
};

/// Returns the token range holding a call's arguments, excluding the callee.
fn callArgsRange(self: *Linter, call: Ast.Node.Index) ?TokenRange {
    switch (self.tree.nodeTag(call)) {
        .call_one, .call_one_comma => {
            const data = self.tree.nodeData(call).node_and_opt_node;
            const arg = data[1].unwrap() orelse return null;
            return .{ .first = self.tree.firstToken(arg), .last = self.tree.lastToken(arg) };
        },
        .call, .call_comma => {
            var buf: [1]Ast.Node.Index = undefined;
            const full_call = self.tree.fullCall(&buf, call) orelse return null;
            if (full_call.ast.params.len == 0) return null;
            return .{
                .first = self.tree.firstToken(full_call.ast.params[0]),
                .last = self.tree.lastToken(full_call.ast.params[full_call.ast.params.len - 1]),
            };
        },
        else => return null,
    }
}

/// True when the candidate appears in a call argument or equality that also
/// mentions the alias by name outside the candidate. Replacing the path then
/// would make a test such as `expectEqual(alias, path)` compare the alias to
/// itself.
fn isAliasComparison(self: *Linter, candidate: Ast.Node.Index, alias_name: []const u8) bool {
    const candidate_first = self.tree.firstToken(candidate);
    const candidate_last = self.tree.lastToken(candidate);

    for (0..self.tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        switch (self.tree.nodeTag(node)) {
            .call_one, .call_one_comma, .call, .call_comma => {
                const args = self.callArgsRange(node) orelse continue;
                if (candidate_first < args.first or candidate_last > args.last) continue;
                if (self.rangeMentionsAlias(args.first, args.last, candidate, alias_name)) return true;
            },
            .equal_equal, .bang_equal => {
                const first = self.tree.firstToken(node);
                const last = self.tree.lastToken(node);
                if (candidate_first < first or candidate_last > last) continue;
                if (self.rangeMentionsAlias(first, last, candidate, alias_name)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn rangeMentionsAlias(self: *Linter, first: Ast.TokenIndex, last: Ast.TokenIndex, candidate: Ast.Node.Index, alias_name: []const u8) bool {
    const candidate_first = self.tree.firstToken(candidate);
    const candidate_last = self.tree.lastToken(candidate);

    for (0..self.tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (self.tree.nodeTag(node) != .identifier) continue;

        const token = self.tree.nodeMainToken(node);
        if (token < first or token > last) continue;
        if (token >= candidate_first and token <= candidate_last) continue;
        if (std.mem.eql(u8, self.tree.tokenSlice(token), alias_name)) return true;
    }
    return false;
}

fn collectAliases(self: *Linter, aliases: *std.ArrayList(Alias)) void {
    for (self.tree.rootDecls()) |node| {
        const var_decl = self.tree.fullVarDecl(node) orelse continue;
        if (!std.mem.eql(u8, self.tree.tokenSlice(var_decl.ast.mut_token), "const")) continue;

        const init_node = var_decl.ast.init_node.unwrap() orelse continue;
        if (self.tree.nodeTag(init_node) != .field_access) continue;
        if (!isIdentifierPath(&self.tree, init_node)) continue;

        const name = self.tree.tokenSlice(var_decl.ast.mut_token + 1);
        if (std.mem.eql(u8, name, "_")) continue;

        aliases.append(self.allocator, .{ .name = name, .rhs_node = init_node }) catch return;
    }
}

fn findMatchingAlias(tree: *const Ast, aliases: []const Alias, node: Ast.Node.Index) ?Alias {
    for (aliases) |alias| {
        if (pathsEqual(tree, node, alias.rhs_node)) return alias;
    }
    return null;
}

/// Compares two identifier paths by name, ignoring whitespace and comments.
fn pathsEqual(tree: *const Ast, a: Ast.Node.Index, b: Ast.Node.Index) bool {
    const a_tag = tree.nodeTag(a);
    if (a_tag != tree.nodeTag(b)) return false;

    return switch (a_tag) {
        .identifier => std.mem.eql(
            u8,
            tree.tokenSlice(tree.nodeMainToken(a)),
            tree.tokenSlice(tree.nodeMainToken(b)),
        ),
        .field_access => blk: {
            const a_data = tree.nodeData(a).node_and_token;
            const b_data = tree.nodeData(b).node_and_token;
            if (!std.mem.eql(u8, tree.tokenSlice(a_data[1]), tree.tokenSlice(b_data[1]))) break :blk false;
            break :blk pathsEqual(tree, a_data[0], b_data[0]);
        },
        else => false,
    };
}

fn identifierPathRoot(tree: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
    var current = node;
    while (tree.nodeTag(current) == .field_access) {
        current = tree.nodeData(current).node_and_token[0];
    }
    return current;
}

/// Returns true when every node in the expression is an identifier or a field
/// access on one, i.e. the expression names an existing declaration.
fn isIdentifierPath(tree: *const Ast, node: Ast.Node.Index) bool {
    var current = node;
    while (true) {
        switch (tree.nodeTag(current)) {
            .identifier => return true,
            .field_access => current = tree.nodeData(current).node_and_token[0],
            else => return false,
        }
    }
}

fn buildParentMap(self: *Linter) void {
    self.parent_map = self.allocator.alloc(Ast.Node.OptionalIndex, self.tree.nodes.len) catch return;
    @memset(self.parent_map, .none);

    for (0..self.tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));

        // Handle nodes with potentially many children directly
        const tag = self.tree.nodeTag(node);
        switch (tag) {
            .block, .block_semicolon => {
                var buf: [2]Ast.Node.Index = undefined;
                const stmts = self.tree.blockStatements(&buf, node) orelse continue;
                for (stmts) |stmt| {
                    self.parent_map[@backingInt(stmt)] = node.toOptional();
                }
                continue;
            },
            .container_decl,
            .container_decl_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            .tagged_union,
            .tagged_union_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            => {
                var buf: [2]Ast.Node.Index = undefined;
                const container = self.tree.fullContainerDecl(&buf, node) orelse continue;
                for (container.ast.members) |member| {
                    self.parent_map[@backingInt(member)] = node.toOptional();
                }
                continue;
            },
            else => {},
        }

        // Use ChildList for nodes with bounded children
        const children = self.getNodeChildren(node);
        for (children.slice()) |child| {
            self.parent_map[@backingInt(child)] = node.toOptional();
        }
    }
}

const ChildList = struct {
    items: [8]Ast.Node.Index = undefined,
    len: usize = 0,

    fn append(self: *ChildList, item: Ast.Node.Index) void {
        if (self.len < 8) {
            self.items[self.len] = item;
            self.len += 1;
        }
    }

    fn slice(self: *const ChildList) []const Ast.Node.Index {
        return self.items[0..self.len];
    }
};

fn getNodeChildren(self: *Linter, node: Ast.Node.Index) ChildList {
    var children: ChildList = .{};
    const tag = self.tree.nodeTag(node);

    switch (tag) {
        // fn_decl: node_and_node = [fn_proto, body]
        .fn_decl => {
            const pair = self.tree.nodeData(node).node_and_node;
            children.append(pair[0]);
            children.append(pair[1]);
        },

        // test_decl: opt_token_and_node = [name_token, block]
        .test_decl => {
            const data = self.tree.nodeData(node).opt_token_and_node;
            children.append(data[1]);
        },

        // Var decl types - use fullVarDecl for safe access
        .simple_var_decl, .aligned_var_decl, .local_var_decl, .global_var_decl => {
            const var_decl = self.tree.fullVarDecl(node) orelse return children;
            if (var_decl.ast.type_node.unwrap()) |n| children.append(n);
            if (var_decl.ast.init_node.unwrap()) |n| children.append(n);
        },

        // Builtin calls - opt_node_and_opt_node
        .builtin_call_two, .builtin_call_two_comma => {
            const data = self.tree.nodeData(node).opt_node_and_opt_node;
            if (data[0].unwrap()) |n| children.append(n);
            if (data[1].unwrap()) |n| children.append(n);
        },

        // Container declarations (structs, enums, unions) - use fullContainerDecl for safe access
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => {
            var buf: [2]Ast.Node.Index = undefined;
            const container = self.tree.fullContainerDecl(&buf, node) orelse return children;
            for (container.ast.members) |member| {
                children.append(member);
            }
        },

        // Block - use blockStatements for safe access
        .block, .block_semicolon => {
            var buf: [2]Ast.Node.Index = undefined;
            const stmts = self.tree.blockStatements(&buf, node) orelse return children;
            for (stmts) |stmt| children.append(stmt);
        },

        .block_two, .block_two_semicolon => {
            const data = self.tree.nodeData(node).opt_node_and_opt_node;
            if (data[0].unwrap()) |n| children.append(n);
            if (data[1].unwrap()) |n| children.append(n);
        },

        // If expressions
        .if_simple, .@"if" => {
            const full_if = self.tree.fullIf(node) orelse return children;
            children.append(full_if.ast.cond_expr);
            children.append(full_if.ast.then_expr);
            if (full_if.ast.else_expr.unwrap()) |n| children.append(n);
        },

        // While loops
        .while_simple, .while_cont, .@"while" => {
            const full_while = self.tree.fullWhile(node) orelse return children;
            children.append(full_while.ast.cond_expr);
            children.append(full_while.ast.then_expr);
            if (full_while.ast.else_expr.unwrap()) |n| children.append(n);
        },

        // For loops
        .for_simple, .@"for" => {
            const full_for = self.tree.fullFor(node) orelse return children;
            children.append(full_for.ast.then_expr);
            if (full_for.ast.else_expr.unwrap()) |n| children.append(n);
        },

        // 0.17: an errdefer's payload is in its expression, as a defer's.
        .@"defer", .@"errdefer" => {
            children.append(self.tree.nodeData(node).node);
        },

        // field_access: node_and_token = [lhs, field_token]
        .field_access => {
            const data = self.tree.nodeData(node).node_and_token;
            children.append(data[0]);
        },

        // assign: node_and_node = [lhs, rhs]
        .assign => {
            const data = self.tree.nodeData(node).node_and_node;
            children.append(data[0]);
            children.append(data[1]);
        },

        // call_one: node_and_opt_node = [callee, arg]
        .call_one, .call_one_comma => {
            const data = self.tree.nodeData(node).node_and_opt_node;
            children.append(data[0]);
            if (data[1].unwrap()) |arg| children.append(arg);
        },

        // call: sub_range = [callee, args...]
        .call, .call_comma => {
            var buf: [1]Ast.Node.Index = undefined;
            const full_call = self.tree.fullCall(&buf, node) orelse return children;
            children.append(full_call.ast.fn_expr);
            for (full_call.ast.params) |param| children.append(param);
        },

        // try: node = [inner_expr]
        .@"try" => {
            children.append(self.tree.nodeData(node).node);
        },

        // catch: node_and_node = [lhs, rhs]
        .@"catch" => {
            const data = self.tree.nodeData(node).node_and_node;
            children.append(data[0]); // The expression being caught
            children.append(data[1]); // The catch body
        },

        else => {},
    }

    return children;
}

fn checkThisBuiltin(self: *Linter) void {
    for (0..self.tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const tag = self.tree.nodeTag(node);

        // Look for @This() calls
        if (tag != .builtin_call_two and tag != .builtin_call_two_comma) continue;
        const main_token = self.tree.nodeMainToken(node);
        const builtin_name = self.tree.tokenSlice(main_token);
        if (!std.mem.eql(u8, builtin_name, "@This")) continue;

        // Found @This() - check if it's valid
        const loc = self.tree.tokenLocation(0, main_token);

        // Check 1: Is it in the form `const X = @This();`?
        const parent = self.parent_map[@backingInt(node)].unwrap() orelse {
            // Z020: inline @This()
            self.report(loc, .Z020, self.findEnclosingStructName(node) orelse "");
            continue;
        };

        const parent_tag = self.tree.nodeTag(parent);

        // Allow @This() as a function argument (e.g., testing.refAllDecls(@This()))
        if (parent_tag == .call_one or parent_tag == .call_one_comma or
            parent_tag == .call or parent_tag == .call_comma)
        {
            continue;
        }

        const const_decl_info: ?struct { name: []const u8 } = switch (parent_tag) {
            .simple_var_decl, .aligned_var_decl, .local_var_decl, .global_var_decl => blk: {
                const var_decl = self.tree.fullVarDecl(parent) orelse break :blk null;
                const mut_token = self.tree.tokenSlice(var_decl.ast.mut_token);
                const init_node = var_decl.ast.init_node.unwrap() orelse break :blk null;
                if (!std.mem.eql(u8, mut_token, "const") or init_node != node) break :blk null;
                const name_token = var_decl.ast.mut_token + 1;
                break :blk .{ .name = self.tree.tokenSlice(name_token) };
            },
            else => null,
        };

        if (const_decl_info == null) {
            // Z020: inline @This()
            self.report(loc, .Z020, self.findEnclosingStructName(node) orelse "");
            continue;
        }

        const alias_name = const_decl_info.?.name;

        // Check 2: Is the enclosing struct anonymous?
        const struct_name = self.findEnclosingStructName(node);
        if (struct_name) |name| {
            // Z019: @This() in named struct
            self.report(loc, .Z019, name);
            continue;
        }

        // Check 3: If at file level, alias should match filename or be Self
        if (self.isAtFileLevel(node)) {
            const basename = std.Io.Dir.path.basename(self.path);
            const expected = if (std.mem.endsWith(u8, basename, ".zig"))
                basename[0 .. basename.len - 4]
            else
                basename;

            // Allow "Self" or the filename (case-insensitive)
            const is_self = std.mem.eql(u8, alias_name, "Self");
            const matches_filename = std.ascii.eqlIgnoreCase(alias_name, expected);
            if (!is_self and !matches_filename) {
                // Z021: alias doesn't match filename or Self (only for file-as-struct)
                if (self.hasTopLevelFields()) {
                    const context = self.allocator.alloc(u8, alias_name.len + 1 + expected.len) catch continue;
                    @memcpy(context[0..alias_name.len], alias_name);
                    context[alias_name.len] = 0;
                    @memcpy(context[alias_name.len + 1 ..], expected);
                    self.trackContext(context);
                    self.report(loc, .Z021, context);
                }
            }
        } else {
            // Check 4: In anonymous/local struct, alias must be "Self"
            if (!std.mem.eql(u8, alias_name, "Self")) {
                self.report(loc, .Z022, alias_name);
            }
        }
    }
}

fn checkInlineImports(self: *Linter) void {
    for (0..self.tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const tag = self.tree.nodeTag(node);

        // Look for @import() calls
        if (tag != .builtin_call_two and tag != .builtin_call_two_comma) continue;
        const main_token = self.tree.nodeMainToken(node);
        const builtin_name = self.tree.tokenSlice(main_token);
        if (!std.mem.eql(u8, builtin_name, "@import")) continue;

        // Walk up through field_access chain to find var decl
        // e.g., `const Rule = @import("rules.zig").Rule;`
        var current = node;
        while (true) {
            const parent = self.parent_map[@backingInt(current)].unwrap() orelse {
                const loc = self.tree.tokenLocation(0, main_token);
                self.report(loc, .Z028, "");
                break;
            };

            const parent_tag = self.tree.nodeTag(parent);
            switch (parent_tag) {
                .field_access => {
                    // Continue walking up through field access chain
                    current = parent;
                    continue;
                },
                .call_one, .call_one_comma, .call, .call_comma => {
                    // Continue walking up only when the chain is the callee being
                    // called, e.g. `const log = @import("log.zig").scoped(.mod);`.
                    // When the import chain is an argument (`foo(@import("x").y)`)
                    // the callee is unrelated, so the import stays inline.
                    var call_buf: [1]Ast.Node.Index = undefined;
                    const call = self.tree.fullCall(&call_buf, parent) orelse {
                        const loc = self.tree.tokenLocation(0, main_token);
                        self.report(loc, .Z028, "");
                        break;
                    };
                    if (call.ast.fn_expr != current) {
                        const loc = self.tree.tokenLocation(0, main_token);
                        self.report(loc, .Z028, "");
                        break;
                    }
                    current = parent;
                    continue;
                },
                .simple_var_decl, .aligned_var_decl, .local_var_decl, .global_var_decl => {
                    const var_decl = self.tree.fullVarDecl(parent) orelse {
                        const loc = self.tree.tokenLocation(0, main_token);
                        self.report(loc, .Z028, "");
                        break;
                    };
                    const mut_token = self.tree.tokenSlice(var_decl.ast.mut_token);
                    const init_node = var_decl.ast.init_node.unwrap() orelse {
                        const loc = self.tree.tokenLocation(0, main_token);
                        self.report(loc, .Z028, "");
                        break;
                    };
                    // Must be `const` and the init must be our current node (or an ancestor)
                    if (!std.mem.eql(u8, mut_token, "const") or init_node != current) {
                        const loc = self.tree.tokenLocation(0, main_token);
                        self.report(loc, .Z028, "");
                        break;
                    }
                    // Check that the var decl is at file level (not inside a function)
                    // Allow imports in test blocks
                    if (!self.isAtFileLevel(parent) and !self.isInTestBlock(parent)) {
                        const loc = self.tree.tokenLocation(0, main_token);
                        self.report(loc, .Z028, "");
                    }
                    break;
                },
                .assign => {
                    // Allow `_ = @import(...)` pattern for pulling in tests
                    const data = self.tree.nodeData(parent).node_and_node;
                    const lhs = data[0];
                    if (self.tree.nodeTag(lhs) == .identifier) {
                        const lhs_name = self.tree.tokenSlice(self.tree.nodeMainToken(lhs));
                        if (std.mem.eql(u8, lhs_name, "_")) {
                            // Discard imports are only used to pull declarations
                            // into a test build.
                            if (self.isInTestBlock(parent)) break;
                        }
                    }
                    const loc = self.tree.tokenLocation(0, main_token);
                    self.report(loc, .Z028, "");
                    break;
                },
                else => {
                    const loc = self.tree.tokenLocation(0, main_token);
                    self.report(loc, .Z028, "");
                    break;
                },
            }
        }
    }
}

fn hasTopLevelFields(self: *Linter) bool {
    for (self.tree.rootDecls()) |node| {
        const tag = self.tree.nodeTag(node);
        if (tag == .container_field_init or tag == .container_field) {
            return true;
        }
    }
    return false;
}

fn isAtFileLevel(self: *Linter, start_node: Ast.Node.Index) bool {
    var current = start_node;

    while (true) {
        const parent_opt = self.parent_map[@backingInt(current)];
        const parent = parent_opt.unwrap() orelse return true; // No parent = root level
        const parent_tag = self.tree.nodeTag(parent);

        // If we hit a container, fn, or test, we're not at file level
        switch (parent_tag) {
            .container_decl,
            .container_decl_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            .tagged_union,
            .tagged_union_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            .fn_decl,
            .test_decl,
            => return false,
            else => {},
        }

        current = parent;
    }
}

fn isInTestBlock(self: *Linter, start_node: Ast.Node.Index) bool {
    var current = start_node;

    while (true) {
        const parent_opt = self.parent_map[@backingInt(current)];
        const parent = parent_opt.unwrap() orelse return false;
        const parent_tag = self.tree.nodeTag(parent);

        if (parent_tag == .test_decl) return true;
        if (parent_tag == .fn_decl) return false; // Functions block test scope

        current = parent;
    }
}

fn findEnclosingStructName(self: *Linter, start_node: Ast.Node.Index) ?[]const u8 {
    var current = start_node;
    var enclosing_container: ?Ast.Node.Index = null;

    // First pass: find the enclosing container
    while (true) {
        const parent_opt = self.parent_map[@backingInt(current)];
        const parent = parent_opt.unwrap() orelse break;
        const parent_tag = self.tree.nodeTag(parent);

        const is_container = switch (parent_tag) {
            .container_decl,
            .container_decl_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            .tagged_union,
            .tagged_union_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            => true,
            else => false,
        };

        if (is_container) {
            enclosing_container = parent;
            break;
        }

        current = parent;
    }

    const container = enclosing_container orelse return self.findContainingTopLevelStructName(start_node);

    // Second pass: check if container is inside a function/test block
    // If so, the struct name isn't accessible from inside, so @This() is valid
    current = container;
    while (true) {
        const parent_opt = self.parent_map[@backingInt(current)];
        const parent = parent_opt.unwrap() orelse break;
        const parent_tag = self.tree.nodeTag(parent);

        if (parent_tag == .fn_decl or parent_tag == .test_decl) {
            return null; // Local struct - name not accessible
        }

        current = parent;
    }

    // Container is at module level - check if it's named
    const container_parent_opt = self.parent_map[@backingInt(container)];
    const container_parent = container_parent_opt.unwrap() orelse return null;
    const container_parent_tag = self.tree.nodeTag(container_parent);

    return switch (container_parent_tag) {
        .simple_var_decl, .aligned_var_decl, .local_var_decl, .global_var_decl => blk: {
            const var_decl = self.tree.fullVarDecl(container_parent) orelse break :blk null;
            const name_token = var_decl.ast.mut_token + 1;
            break :blk self.tree.tokenSlice(name_token);
        },
        else => null, // Anonymous (returned, passed as arg, etc.)
    };
}

fn findContainingTopLevelStructName(self: *Linter, node: Ast.Node.Index) ?[]const u8 {
    const node_token = self.tree.nodeMainToken(node);
    for (self.tree.rootDecls()) |decl| {
        const var_decl = self.tree.fullVarDecl(decl) orelse continue;
        const init_node = var_decl.ast.init_node.unwrap() orelse continue;
        var buf: [2]Ast.Node.Index = undefined;
        _ = self.tree.fullContainerDecl(&buf, init_node) orelse continue;
        if (node_token < self.tree.firstToken(init_node) or node_token > self.tree.lastToken(init_node)) continue;
        return self.tree.tokenSlice(var_decl.ast.mut_token + 1);
    }
    return null;
}

/// Find the enclosing container (struct/union/enum) for a given node
fn findEnclosingContainer(self: *Linter, start_node: Ast.Node.Index) Ast.Node.OptionalIndex {
    var current = start_node;

    while (true) {
        const parent_opt = self.parent_map[@backingInt(current)];
        const parent = parent_opt.unwrap() orelse return .none;
        const parent_tag = self.tree.nodeTag(parent);

        const is_container = switch (parent_tag) {
            .container_decl,
            .container_decl_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            .tagged_union,
            .tagged_union_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            => true,
            else => false,
        };

        if (is_container) {
            return parent.toOptional();
        }

        current = parent;
    }
}

fn checkFileAsStruct(self: *Linter) void {
    // Check if file has top-level fields (container fields at root level)
    var has_top_level_fields = false;
    for (self.tree.rootDecls()) |node| {
        const tag = self.tree.nodeTag(node);
        if (tag == .container_field_init or tag == .container_field) {
            has_top_level_fields = true;
            break;
        }
    }

    if (!has_top_level_fields) return;

    // File has top-level fields, check if filename is PascalCase
    const basename = std.Io.Dir.path.basename(self.path);
    const name = if (std.mem.endsWith(u8, basename, ".zig"))
        basename[0 .. basename.len - 4]
    else
        basename;

    if (!isPascalCase(name)) {
        self.report(.{ .line = 0, .column = 0, .line_start = 0, .line_end = 0 }, .Z009, basename);
    }
}

fn buildPublicTypesMap(self: *Linter) void {
    for (self.tree.rootDecls()) |node| {
        const tag = self.tree.nodeTag(node);
        switch (tag) {
            .simple_var_decl, .aligned_var_decl, .local_var_decl, .global_var_decl => {
                const var_decl = self.tree.fullVarDecl(node) orelse continue;
                const name_token = var_decl.ast.mut_token + 1;
                const name = self.tree.tokenSlice(name_token);

                // Track imported types (field access ending in PascalCase, e.g., std.mem.Allocator)
                if (self.isImportedType(var_decl)) {
                    self.track(&self.imported_types, name);
                    continue;
                }

                if (!self.isPublicDecl(node)) continue;
                if (!self.isTypeDecl(var_decl)) continue;

                self.track(&self.public_types, name);
            },
            else => {},
        }
    }
}

fn isImportedType(self: *Linter, var_decl: Ast.full.VarDecl) bool {
    const init_node = var_decl.ast.init_node.unwrap() orelse return false;

    // ziglint's resolver answers these from the file alone: an `@import`
    // of std, builtin or a `.zig` file (which must exist for the program
    // to compile), and a builtin that returns a type.
    if (self.isFileLocalType(init_node)) return true;

    // Fallback: check if it's a field access ending in PascalCase
    const tag = self.tree.nodeTag(init_node);
    return switch (tag) {
        .field_access => blk: {
            const data = self.tree.nodeData(init_node).node_and_token;
            const field_name = self.tree.tokenSlice(data[1]);
            break :blk isPascalCase(field_name);
        },
        else => false,
    };
}

/// Whether `node` is one of the type expressions whose type ziglint's
/// `TypeResolver.typeOf` answers without another file: `@import("std")`,
/// `@import("builtin")`, `@import("<path>.zig")`, or a builtin call that
/// returns a type.
fn isFileLocalType(self: *Linter, node: Ast.Node.Index) bool {
    switch (self.tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {},
        else => return false,
    }
    const name = self.tree.tokenSlice(self.tree.nodeMainToken(node));
    if (isTypeReturningBuiltin(name)) return true;
    if (!std.mem.eql(u8, name, "@import")) return false;
    var buf: [2]Ast.Node.Index = undefined;
    const params = self.tree.builtinCallParams(&buf, node) orelse return false;
    if (params.len == 0) return false;
    const raw = self.tree.tokenSlice(self.tree.nodeMainToken(params[0]));
    if (raw.len < 2 or raw[0] != '"') return false;
    const path = raw[1 .. raw.len - 1];
    return std.mem.eql(u8, path, "std") or std.mem.eql(u8, path, "builtin") or std.mem.endsWith(u8, path, ".zig");
}

fn isPublicDecl(self: *Linter, node: Ast.Node.Index) bool {
    const main_token = self.tree.nodeMainToken(node);
    if (main_token == 0) return false;
    const prev_token = main_token - 1;
    const prev_slice = self.tree.tokenSlice(prev_token);
    return std.mem.eql(u8, prev_slice, "pub");
}

fn isTypeDecl(self: *Linter, var_decl: Ast.full.VarDecl) bool {
    const init_node = var_decl.ast.init_node.unwrap() orelse return false;
    return self.isTypeExpression(init_node);
}

fn isTypeExpression(self: *Linter, node: Ast.Node.Index) bool {
    const tag = self.tree.nodeTag(node);
    return switch (tag) {
        // Container types (struct, enum, union)
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => true,
        // Pointer types (e.g., *anyopaque, *T)
        .ptr_type_aligned,
        .ptr_type_sentinel,
        .ptr_type,
        .ptr_type_bit_range,
        => true,
        // Optional types (e.g., ?T)
        .optional_type => true,
        // Array types (e.g., [N]T)
        .array_type,
        .array_type_sentinel,
        => true,
        // Error union types (e.g., E!T)
        .error_union => true,
        // Error set declarations (e.g., error{A, B})
        .error_set_decl => true,
        // Error set merges (e.g., `frame.EncodeError || error{ Unexpected }`).
        // The parser emits merge_error_sets for every `||` between expressions,
        // including runtime booleans, so both operands must themselves be type
        // expressions to keep values out of public_types.
        .merge_error_sets => blk: {
            const data = self.tree.nodeData(node).node_and_node;
            break :blk self.isTypeExpression(data[0]) and self.isTypeExpression(data[1]);
        },
        // Function types
        .fn_proto,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto_simple,
        => true,
        // Builtin type constructors
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => blk: {
            const token = self.tree.tokenSlice(self.tree.nodeMainToken(node));
            break :blk isTypeReturningBuiltin(token);
        },
        // Identifier referencing another type (type alias)
        .identifier => blk: {
            const name = self.tree.tokenSlice(self.tree.nodeMainToken(node));
            break :blk isPascalCase(name) or isBuiltinType(name);
        },
        // Labeled blocks (comptime type construction, e.g., `key: { break :key @Type(...); }`)
        .block_two, .block_two_semicolon, .block, .block_semicolon => true,
        // Switch expressions (comptime type selection, e.g., `switch (os) { .linux => T1, else => T2 }`)
        .@"switch", .switch_comma => true,
        // If expressions (comptime type selection)
        .@"if", .if_simple => true,
        // Generic type instantiation (e.g., ArrayList(T), HashMap(K, V))
        .call_one, .call_one_comma, .call, .call_comma => true,
        // Field access (e.g., std.AutoHashMapUnmanaged)
        .field_access => blk: {
            const data = self.tree.nodeData(node).node_and_token;
            const field_name = self.tree.tokenSlice(data[1]);
            break :blk isPascalCase(field_name);
        },
        else => false,
    };
}

fn isPrivateTypeRef(self: *Linter, name: []const u8, enclosing_container: Ast.Node.OptionalIndex) bool {
    if (!isPascalCase(name)) return false;
    if (isBuiltinType(name)) return false;
    if (self.public_types.contains(name)) return false;
    if (self.imported_types.contains(name)) return false;
    // Don't flag Self type (type matching filename for file-as-struct pattern)
    if (self.isSelfType(name)) return false;
    // A type pub in any enclosing container is nameable alongside this
    // function, and so is an enclosing container itself: self-referencing
    // methods like `fn send(self: *Connection)` are not private exposures.
    var container_opt = enclosing_container;
    while (container_opt.unwrap()) |container| {
        if (self.containerOwnName(container)) |own| {
            if (std.mem.eql(u8, own, name)) return false;
        }
        if (self.isThisAliasInContainer(name, container)) return false;
        if (self.isPublicInContainer(name, container.toOptional())) return false;
        container_opt = self.findEnclosingContainer(container);
    }
    return true;
}

/// True when `name` is declared in `container` as `const name = @This()` —
/// an alias for the container itself, so references to it are container-self
/// references, not private-type exposures.
fn isThisAliasInContainer(self: *Linter, name: []const u8, container: Ast.Node.Index) bool {
    var members_buf: [2]Ast.Node.Index = undefined;
    const members = self.getContainerMembers(container, &members_buf) orelse return false;
    for (members) |member| {
        switch (self.tree.nodeTag(member)) {
            .simple_var_decl, .aligned_var_decl, .local_var_decl, .global_var_decl => {},
            else => continue,
        }
        const var_decl = self.tree.fullVarDecl(member) orelse continue;
        const name_token = var_decl.ast.mut_token + 1;
        if (!std.mem.eql(u8, self.tree.tokenSlice(name_token), name)) continue;
        const init_node = var_decl.ast.init_node.unwrap() orelse continue;
        switch (self.tree.nodeTag(init_node)) {
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {},
            else => continue,
        }
        if (std.mem.eql(u8, self.tree.tokenSlice(self.tree.nodeMainToken(init_node)), "@This")) return true;
    }
    return false;
}

/// Name of the decl a container belongs to (`const Foo = struct {...}` → Foo),
/// or null for anonymous containers.
fn containerOwnName(self: *Linter, container: Ast.Node.Index) ?[]const u8 {
    const parent = self.parent_map[@backingInt(container)].unwrap() orelse return null;
    const var_decl = self.tree.fullVarDecl(parent) orelse return null;
    const name_token = var_decl.ast.mut_token + 1;
    return self.tree.tokenSlice(name_token);
}

/// Check if a type name is declared as `pub const` within the given container
fn isPublicInContainer(self: *Linter, name: []const u8, container_opt: Ast.Node.OptionalIndex) bool {
    const container = container_opt.unwrap() orelse return false;
    var members_buf: [2]Ast.Node.Index = undefined;
    const members = self.getContainerMembers(container, &members_buf) orelse return false;

    for (members) |member| {
        const tag = self.tree.nodeTag(member);
        switch (tag) {
            .simple_var_decl, .aligned_var_decl, .local_var_decl, .global_var_decl => {
                // Check if this is a pub declaration
                if (!self.isPublicDecl(member)) continue;

                // Check if the name matches
                const var_decl = self.tree.fullVarDecl(member) orelse continue;
                const name_token = var_decl.ast.mut_token + 1;
                const decl_name = self.tree.tokenSlice(name_token);
                if (std.mem.eql(u8, decl_name, name)) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Get the member declarations of a container node.
///
/// For containers with at most two members, fullContainerDecl stores the
/// members in `buf`, so the returned slice points into it: the buffer must
/// outlive every use of the result. Keeping it inside this function handed
/// callers a dangling stack slice (CI crashed reading garbage node indices).
fn getContainerMembers(
    self: *Linter,
    node: Ast.Node.Index,
    buf: *[2]Ast.Node.Index,
) ?[]const Ast.Node.Index {
    // fullContainerDecl covers every container shape (struct, enum, union,
    // tagged union, with/without args), so member lookups cannot miss a
    // variant the way a hand-rolled tag switch can.
    const container = self.tree.fullContainerDecl(buf, node) orelse return null;
    return container.ast.members;
}

fn isSelfType(self: *Linter, name: []const u8) bool {
    const basename = std.Io.Dir.path.basename(self.path);
    const stem = if (std.mem.endsWith(u8, basename, ".zig"))
        basename[0 .. basename.len - 4]
    else
        basename;
    return std.mem.eql(u8, name, stem);
}

fn isBuiltinType(name: []const u8) bool {
    const builtins = [_][]const u8{
        "u8",           "u16",            "u32",  "u64",      "u128",    "usize",
        "i8",           "i16",            "i32",  "i64",      "i128",    "isize",
        "f16",          "f32",            "f64",  "f80",      "f128",    "bool",
        "void",         "noreturn",       "type", "anyerror", "anytype", "anyframe",
        "comptime_int", "comptime_float",
    };
    for (builtins) |b| {
        if (std.mem.eql(u8, name, b)) return true;
    }
    return false;
}

const ParamKind = enum {
    type_param,
    comptime_value,
    allocator,
    io,
    other,

    fn order(self: ParamKind) u8 {
        return switch (self) {
            .type_param => 0,
            .comptime_value => 1,
            .allocator => 2,
            .io => 3,
            .other => 4,
        };
    }

    fn name(self: ParamKind) []const u8 {
        return switch (self) {
            .type_param => "type",
            .allocator => "Allocator",
            .io => "Io",
            .comptime_value => "comptime",
            .other => "other",
        };
    }
};

fn checkArgumentOrder(self: *Linter, node: Ast.Node.Index) void {
    var buf: [1]Ast.Node.Index = undefined;
    const fn_proto = self.tree.fullFnProto(&buf, node) orelse return;

    var max_order: u8 = 0;
    var max_kind: ParamKind = .type_param;
    var max_token: Ast.TokenIndex = 0;
    var is_first = true;

    var it = fn_proto.iterate(&self.tree);
    while (it.next()) |param| {
        // Skip first param if it's a receiver (type refers to @This() or container type)
        if (is_first) {
            is_first = false;
            if (self.isReceiverParam(param)) continue;
        }

        const kind = self.classifyParam(param);

        // Runtime value params take any position: std's own corpus
        // interleaves them freely (std.fmt.format(writer, comptime fmt,
        // args), std.fmt.allocPrint(gpa, comptime fmt, args)). The rule
        // orders the structural kinds among themselves — a total order
        // including "other" flagged every writer-first and
        // ctx-then-callback API.
        if (kind == .other) continue;

        const current_order = kind.order();

        if (current_order < max_order) {
            // This parameter is out of order
            const token = param.name_token orelse
                (if (param.type_expr) |te| self.tree.nodeMainToken(te) else continue);
            const loc = self.tree.tokenLocation(0, token);

            const context = self.allocator.print("{s}\x00{s}", .{
                kind.name(),
                max_kind.name(),
            }) catch continue;
            self.trackContext(context);
            self.report(loc, .Z023, context);
        }

        if (current_order >= max_order) {
            max_order = current_order;
            max_kind = kind;
            max_token = param.name_token orelse max_token;
        }
    }
}

fn isComptimeParam(self: *Linter, param: Ast.full.FnProto.Param) bool {
    const comptime_token = param.comptime_noalias orelse return false;
    const token_tag = self.tree.tokenTag(comptime_token);
    return token_tag == .keyword_comptime;
}

fn classifyParam(self: *Linter, param: Ast.full.FnProto.Param) ParamKind {
    const type_node = param.type_expr orelse return .other;
    const base_kind = self.classifyTypeNode(type_node);

    if (base_kind == .type_param) return .type_param;
    if (self.isComptimeParam(param)) return .comptime_value;

    return base_kind;
}

fn isReceiverParam(self: *Linter, param: Ast.full.FnProto.Param) bool {
    const type_node = param.type_expr orelse return false;

    // Fallback: check for @This() or Self
    return self.typeRefersToThis(type_node);
}

fn unwrapPointerType(self: *Linter, node: Ast.Node.Index) Ast.Node.Index {
    const tag = self.tree.nodeTag(node);
    return switch (tag) {
        .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => blk: {
            const ptr_type = self.tree.fullPtrType(node) orelse break :blk node;
            break :blk self.unwrapPointerType(ptr_type.ast.child_type);
        },
        else => node,
    };
}

fn typeRefersToThis(self: *Linter, node: Ast.Node.Index) bool {
    const tag = self.tree.nodeTag(node);
    return switch (tag) {
        .builtin_call_two => blk: {
            const main_token = self.tree.nodeMainToken(node);
            const builtin_name = self.tree.tokenSlice(main_token);
            break :blk std.mem.eql(u8, builtin_name, "@This");
        },
        .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => blk: {
            const ptr_type = self.tree.fullPtrType(node) orelse break :blk false;
            break :blk self.typeRefersToThis(ptr_type.ast.child_type);
        },
        .identifier => blk: {
            const name = self.tree.tokenSlice(self.tree.nodeMainToken(node));
            break :blk std.mem.eql(u8, name, "Self");
        },
        else => false,
    };
}

fn classifyTypeNode(self: *Linter, type_node: Ast.Node.Index) ParamKind {
    // Check for `type` (comptime type parameter)
    if (self.tree.nodeTag(type_node) == .identifier) {
        const type_name = self.tree.tokenSlice(self.tree.nodeMainToken(type_node));
        if (std.mem.eql(u8, type_name, "type")) return .type_param;
    }

    // Fallback: check for field access chains like std.mem.Allocator or std.Io
    const path = self.getFieldAccessPath(type_node) orelse return .other;
    return self.classifyPath(path);
}

fn classifyPath(self: *Linter, path: []const u8) ParamKind {
    _ = self;
    if (std.mem.eql(u8, path, "std.mem.Allocator") or
        std.mem.eql(u8, path, "mem.Allocator") or
        std.mem.eql(u8, path, "Allocator"))
    {
        return .allocator;
    }

    if (std.mem.eql(u8, path, "std.Io") or
        std.mem.eql(u8, path, "Io"))
    {
        return .io;
    }

    return .other;
}

fn getFieldAccessPath(self: *Linter, node: Ast.Node.Index) ?[]const u8 {
    var parts: [8][]const u8 = undefined;
    var count: usize = 0;

    var current = node;
    while (true) {
        const tag = self.tree.nodeTag(current);
        if (tag == .field_access) {
            const data = self.tree.nodeData(current).node_and_token;
            if (count < parts.len) {
                parts[parts.len - 1 - count] = self.tree.tokenSlice(data[1]);
                count += 1;
            }
            current = data[0];
        } else if (tag == .identifier) {
            if (count < parts.len) {
                parts[parts.len - 1 - count] = self.tree.tokenSlice(self.tree.nodeMainToken(current));
                count += 1;
            }
            break;
        } else {
            return null;
        }
    }

    if (count == 0) return null;

    // Build the path string
    var total_len: usize = 0;
    for (parts[parts.len - count ..]) |p| {
        total_len += p.len + 1;
    }

    const result = self.allocator.alloc(u8, total_len - 1) catch return null;
    var pos: usize = 0;
    for (parts[parts.len - count ..], 0..) |p, i| {
        if (i > 0) {
            result[pos] = '.';
            pos += 1;
        }
        @memcpy(result[pos..][0..p.len], p);
        pos += p.len;
    }

    self.trackContext(result);
    return result;
}

fn checkExposedPrivateType(self: *Linter, node: Ast.Node.Index) void {
    var buf: [1]Ast.Node.Index = undefined;
    const fn_proto = self.tree.fullFnProto(&buf, node) orelse return;

    if (!self.isPublicDecl(node)) return;

    // Find enclosing container (struct/union/enum) if any
    const enclosing_container = self.findEnclosingContainer(node);

    // Collect generic type parameter names
    var generic_params: [16][]const u8 = undefined;
    var generic_count: usize = 0;
    var it = fn_proto.iterate(&self.tree);
    while (it.next()) |param| {
        const type_node = param.type_expr orelse continue;
        if (self.tree.nodeTag(type_node) == .identifier) {
            const type_name = self.tree.tokenSlice(self.tree.nodeMainToken(type_node));
            if (std.mem.eql(u8, type_name, "type")) {
                if (param.name_token) |name_tok| {
                    if (generic_count < 16) {
                        generic_params[generic_count] = self.tree.tokenSlice(name_tok);
                        generic_count += 1;
                    }
                }
            }
        }
    }

    // Check return type
    if (fn_proto.ast.return_type.unwrap()) |ret_node| {
        self.checkTypeNodeForPrivateWithGenerics(ret_node, fn_proto, generic_params[0..generic_count], enclosing_container);
    }

    // Check parameter types
    var it2 = fn_proto.iterate(&self.tree);
    while (it2.next()) |param| {
        const type_node = param.type_expr orelse continue;
        // Skip generic parameters (comptime T: type)
        if (self.tree.nodeTag(type_node) == .identifier) {
            const type_name = self.tree.tokenSlice(self.tree.nodeMainToken(type_node));
            if (std.mem.eql(u8, type_name, "type")) continue;
        }
        self.checkTypeNodeForPrivateWithGenerics(type_node, fn_proto, generic_params[0..generic_count], enclosing_container);
    }
}

fn checkTypeNodeForPrivateWithGenerics(
    self: *Linter,
    type_node: Ast.Node.Index,
    fn_proto: Ast.full.FnProto,
    generic_params: []const []const u8,
    enclosing_container: Ast.Node.OptionalIndex,
) void {
    self.checkTypeNodeForPrivateImpl(type_node, fn_proto, generic_params, false, enclosing_container);
}

fn checkTypeNodeForPrivateImpl(
    self: *Linter,
    type_node: Ast.Node.Index,
    fn_proto: Ast.full.FnProto,
    generic_params: []const []const u8,
    is_error_position: bool,
    enclosing_container: Ast.Node.OptionalIndex,
) void {
    const tag = self.tree.nodeTag(type_node);

    switch (tag) {
        .identifier => {
            const type_name = self.tree.tokenSlice(self.tree.nodeMainToken(type_node));
            // Skip generic type parameters
            for (generic_params) |gp| {
                if (std.mem.eql(u8, type_name, gp)) return;
            }
            if (self.isPrivateTypeRef(type_name, enclosing_container)) {
                self.reportPrivateType(fn_proto, type_name, is_error_position);
            }
        },
        .optional_type => {
            const child = self.tree.nodeData(type_node).node;
            self.checkTypeNodeForPrivateImpl(child, fn_proto, generic_params, is_error_position, enclosing_container);
        },
        .error_union => {
            const data = self.tree.nodeData(type_node).node_and_node;
            self.checkTypeNodeForPrivateImpl(data[0], fn_proto, generic_params, true, enclosing_container);
            self.checkTypeNodeForPrivateImpl(data[1], fn_proto, generic_params, false, enclosing_container);
        },
        // Pointer types (e.g., *Hidden, []Hidden, [*]const Hidden)
        .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => {
            if (self.tree.fullPtrType(type_node)) |ptr| {
                self.checkTypeNodeForPrivateImpl(ptr.ast.child_type, fn_proto, generic_params, is_error_position, enclosing_container);
            }
        },
        // Array types (e.g., [4]Hidden)
        .array_type, .array_type_sentinel => {
            if (self.tree.fullArrayType(type_node)) |arr| {
                self.checkTypeNodeForPrivateImpl(arr.ast.elem_type, fn_proto, generic_params, is_error_position, enclosing_container);
            }
        },
        else => {},
    }
}

fn reportPrivateType(self: *Linter, fn_proto: Ast.full.FnProto, type_name: []const u8, is_error: bool) void {
    const name_token = fn_proto.name_token orelse return;
    const loc = self.tree.tokenLocation(0, name_token);
    const rule: rules.Rule = if (is_error) .Z015 else .Z012;
    self.report(loc, rule, type_name);
}

fn visitNode(self: *Linter, node: Ast.Node.Index) void {
    const tag = self.tree.nodeTag(node);

    switch (tag) {
        .fn_decl => self.checkFnDecl(node),
        .simple_var_decl, .aligned_var_decl, .local_var_decl, .global_var_decl => {
            self.checkVarDecl(node);
        },
        .@"return" => self.checkReturn(node),
        .call_one, .call_one_comma, .call, .call_comma => {
            self.checkCallArgs(node);
            self.checkRedundantAsInCallArgs(node);

            self.checkCompoundAssert(node);
        },
        .array_init_one,
        .array_init_one_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init,
        .array_init_comma,
        => {
            self.checkRedundantAsInArrayInit(node);
        },
        .struct_init_one,
        .struct_init_one_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        .struct_init,
        .struct_init_comma,
        => {
            self.checkRedundantAsInStructInit(node);
        },
        else => {},
    }

    self.visitChildren(node);
}

fn visitChildren(self: *Linter, node: Ast.Node.Index) void {
    const tag = self.tree.nodeTag(node);
    switch (tag) {
        .fn_decl => {
            const data = self.tree.nodeData(node).node_and_node;
            // Track the function's return type for checks inside the body
            var buf: [1]Ast.Node.Index = undefined;
            const fn_proto = self.tree.fullFnProto(&buf, node);
            const prev_return_type = self.current_fn_return_type;
            if (fn_proto) |proto| {
                self.current_fn_return_type = proto.ast.return_type;
            }
            self.visitNode(data[0]);
            self.visitNode(data[1]);
            self.current_fn_return_type = prev_return_type;
        },
        .block, .block_semicolon => {
            var buf: [2]Ast.Node.Index = undefined;
            const stmts = self.tree.blockStatements(&buf, node) orelse return;
            for (stmts) |stmt| self.visitNode(stmt);
        },
        .block_two, .block_two_semicolon => {
            const data = self.tree.nodeData(node).opt_node_and_opt_node;
            if (data[0].unwrap()) |n| self.visitNode(n);
            if (data[1].unwrap()) |n| self.visitNode(n);
        },
        // Assignments - visit both sides to catch calls in RHS like `_ = deprecatedFunc()`
        .assign => {
            const data = self.tree.nodeData(node).node_and_node;
            self.visitNode(data[0]);
            self.visitNode(data[1]);
        },
        // Variable declarations - visit both type annotation and init node
        .simple_var_decl, .aligned_var_decl, .local_var_decl, .global_var_decl => {
            const var_decl = self.tree.fullVarDecl(node) orelse return;
            // Visit type annotation (e.g., for `var x: std.ArrayListUnmanaged(u8)` to catch deprecated calls)
            if (var_decl.ast.type_node.unwrap()) |type_node| self.visitNode(type_node);
            if (var_decl.ast.init_node.unwrap()) |init_node| self.visitNode(init_node);
        },
        // Container declarations (structs, enums, unions) - visit members
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => {
            var buf: [2]Ast.Node.Index = undefined;
            const container = self.tree.fullContainerDecl(&buf, node) orelse return;
            for (container.ast.members) |member| {
                self.visitNode(member);
            }
        },
        else => {
            // For all other node types, use getNodeChildren to visit children
            const children = self.getNodeChildren(node);
            for (children.slice()) |child| {
                self.visitNode(child);
            }
        },
    }
}

fn checkFnDecl(self: *Linter, node: Ast.Node.Index) void {
    var buf: [1]Ast.Node.Index = undefined;
    const fn_proto = self.tree.fullFnProto(&buf, node) orelse return;

    const name_token = fn_proto.name_token orelse return;
    const name = self.tree.tokenSlice(name_token);

    const returns_type = if (fn_proto.ast.return_type.unwrap()) |ret| blk: {
        break :blk self.tree.nodeTag(ret) == .identifier and
            std.mem.eql(u8, self.tree.tokenSlice(self.tree.nodeMainToken(ret)), "type");
    } else false;

    if (returns_type) {
        if (!isPascalCase(name)) {
            const loc = self.tree.tokenLocation(0, name_token);
            self.report(loc, .Z005, name);
        }
    } else {
        if (!isValidFunctionName(name)) {
            const loc = self.tree.tokenLocation(0, name_token);
            self.report(loc, .Z001, name);
        }
    }

    // Check for underscore prefix
    if (hasUnderscorePrefix(name)) {
        const loc = self.tree.tokenLocation(0, name_token);
        self.report(loc, .Z031, name);
    }

    // Check for acronym casing
    if (checkAcronymCasing(self.allocator, name)) |suggestion| {
        const context = self.allocator.alloc(u8, name.len + 1 + suggestion.len) catch {
            self.allocator.free(suggestion);
            return;
        };
        @memcpy(context[0..name.len], name);
        context[name.len] = 0;
        @memcpy(context[name.len + 1 ..], suggestion);
        self.trackContext(context);
        self.trackContext(suggestion);
        const loc = self.tree.tokenLocation(0, name_token);
        self.report(loc, .Z032, context);
    }

    self.checkExposedPrivateType(node);
    self.checkArgumentOrder(node);
    self.checkDeinitUndefined(node, fn_proto);
}

fn checkDeinitUndefined(self: *Linter, node: Ast.Node.Index, fn_proto: Ast.full.FnProto) void {
    // Only check functions named "deinit"
    const name_token = fn_proto.name_token orelse return;
    const name = self.tree.tokenSlice(name_token);
    if (!std.mem.eql(u8, name, "deinit")) return;

    // Check if first parameter is a pointer type
    var param_it = fn_proto.iterate(&self.tree);
    const first_param = param_it.next() orelse return;
    const param_type = first_param.type_expr orelse return;
    if (!self.isPointerType(param_type)) return;

    // Get the parameter name (usually "self")
    const param_name = if (first_param.name_token) |t| self.tree.tokenSlice(t) else return;

    // Get function body
    const body_node = self.tree.nodeData(node).node_and_node[1];

    const has_deferred_invalidation = self.hasDeferSelfUndefined(body_node, param_name);
    const lifetime = self.analyzeReceiverLifetime(body_node, param_name, false);

    // A deferred write would run after the receiver's allocation is freed.
    if (lifetime.deferred_invalidation_after_destroy) {
        const loc = self.tree.tokenLocation(0, name_token);
        self.reportDeinitUndefined(loc, param_name, "deferred invalidation runs after receiver destruction");
        return;
    }

    if (lifetime.invalidation_after_destroy) {
        const loc = self.tree.tokenLocation(0, name_token);
        self.reportDeinitUndefined(loc, param_name, "invalidates receiver after destruction");
        return;
    }

    // `defer self.* = undefined;` handles every path that reaches the defer.
    if (has_deferred_invalidation) return;

    // Check for returns reached before this receiver is invalidated.
    if (self.hasUnsafeReturn(body_node, param_name, false)) {
        const loc = self.tree.tokenLocation(0, name_token);
        self.reportDeinitUndefined(loc, param_name, "has early return before invalidation");
        return;
    }

    // Destroying a heap-allocated receiver also ends its lifetime. Requiring an
    // invalidating write afterward would introduce a use-after-free.
    if (self.lastStatementIsSelfDestroy(body_node, param_name)) return;

    if (self.lastStatementIsSelfUndefined(body_node, param_name)) return;

    // None of the valid patterns found
    const loc = self.tree.tokenLocation(0, name_token);
    self.reportDeinitUndefined(loc, param_name, "");
}

fn reportDeinitUndefined(self: *Linter, loc: Ast.Location, param_name: []const u8, reason: []const u8) void {
    const context = self.allocator.print("{s}\x00{s}", .{ param_name, reason }) catch return;
    self.allocated_contexts.append(self.allocator, context) catch {
        self.allocator.free(context);
        return;
    };
    self.report(loc, .Z030, context);
}

fn isPointerType(self: *Linter, node: Ast.Node.Index) bool {
    const tag = self.tree.nodeTag(node);
    return switch (tag) {
        .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => true,
        else => false,
    };
}

fn hasDeferSelfUndefined(self: *Linter, body_node: Ast.Node.Index, param_name: []const u8) bool {
    // Iterate through all nodes looking for defer
    var buf: [2]Ast.Node.Index = undefined;
    const stmts = self.tree.blockStatements(&buf, body_node) orelse return false;

    for (stmts) |stmt| {
        if (self.isDeferSelfUndefined(stmt, param_name)) return true;
    }
    return false;
}

fn isDeferSelfUndefined(self: *Linter, node: Ast.Node.Index, param_name: []const u8) bool {
    if (self.tree.nodeTag(node) != .@"defer") return false;
    return self.isSelfUndefinedAssign(self.tree.nodeData(node).node, param_name);
}

fn hasUnsafeReturn(self: *Linter, node: Ast.Node.Index, param_name: []const u8, invalidated_before: bool) bool {
    const tag = self.tree.nodeTag(node);
    if (tag == .@"return") return !invalidated_before;

    switch (tag) {
        .@"if", .if_simple => {
            const full_if = self.tree.fullIf(node) orelse return false;
            if (self.hasUnsafeReturn(full_if.ast.then_expr, param_name, invalidated_before)) return true;
            if (full_if.ast.else_expr.unwrap()) |else_node| {
                if (self.hasUnsafeReturn(else_node, param_name, invalidated_before)) return true;
            }
        },
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            var block_buf: [2]Ast.Node.Index = undefined;
            const block_stmts = self.tree.blockStatements(&block_buf, node) orelse return false;
            var invalidated = invalidated_before;
            for (block_stmts) |stmt| {
                if (self.hasUnsafeReturn(stmt, param_name, invalidated)) return true;
                if (self.isSelfUndefinedAssign(stmt, param_name) or self.isSelfDestroyCall(stmt, param_name)) {
                    invalidated = true;
                }
            }
        },
        else => {},
    }
    return false;
}

fn lastStatementIsSelfUndefined(self: *Linter, body_node: Ast.Node.Index, param_name: []const u8) bool {
    var buf: [2]Ast.Node.Index = undefined;
    const stmts = self.tree.blockStatements(&buf, body_node) orelse return false;
    if (stmts.len == 0) return false;

    const last_stmt = stmts[stmts.len - 1];
    return self.isSelfUndefinedAssign(last_stmt, param_name);
}

fn lastStatementIsSelfDestroy(self: *Linter, body_node: Ast.Node.Index, param_name: []const u8) bool {
    var buf: [2]Ast.Node.Index = undefined;
    const stmts = self.tree.blockStatements(&buf, body_node) orelse return false;
    if (stmts.len == 0) return false;

    return self.isSelfDestroyCall(stmts[stmts.len - 1], param_name);
}

const ReceiverLifetime = struct {
    can_fallthrough: bool = true,
    destroyed_on_fallthrough: bool = false,
    saw_destroy: bool = false,
    invalidation_after_destroy: bool = false,
    deferred_invalidation_after_destroy: bool = false,
};

fn analyzeReceiverLifetime(
    self: *Linter,
    node: Ast.Node.Index,
    param_name: []const u8,
    destroyed_before: bool,
) ReceiverLifetime {
    if (self.isSelfUndefinedAssign(node, param_name)) return .{
        .destroyed_on_fallthrough = destroyed_before,
        .invalidation_after_destroy = destroyed_before,
    };
    if (self.isSelfDestroyCall(node, param_name)) return .{
        .destroyed_on_fallthrough = true,
        .saw_destroy = true,
    };
    if (self.tree.nodeTag(node) == .@"return") return .{ .can_fallthrough = false };

    switch (self.tree.nodeTag(node)) {
        .@"if", .if_simple => {
            const full_if = self.tree.fullIf(node) orelse return .{};
            const then_result = self.analyzeReceiverLifetime(full_if.ast.then_expr, param_name, destroyed_before);
            const else_result = if (full_if.ast.else_expr.unwrap()) |else_node|
                self.analyzeReceiverLifetime(else_node, param_name, destroyed_before)
            else
                ReceiverLifetime{ .destroyed_on_fallthrough = destroyed_before };

            return .{
                .can_fallthrough = then_result.can_fallthrough or else_result.can_fallthrough,
                .destroyed_on_fallthrough = (then_result.can_fallthrough and then_result.destroyed_on_fallthrough) or
                    (else_result.can_fallthrough and else_result.destroyed_on_fallthrough),
                .saw_destroy = then_result.saw_destroy or else_result.saw_destroy,
                .invalidation_after_destroy = then_result.invalidation_after_destroy or
                    else_result.invalidation_after_destroy,
                .deferred_invalidation_after_destroy = then_result.deferred_invalidation_after_destroy or
                    else_result.deferred_invalidation_after_destroy,
            };
        },
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            var block_buf: [2]Ast.Node.Index = undefined;
            const block_stmts = self.tree.blockStatements(&block_buf, node) orelse return .{};
            var result: ReceiverLifetime = .{ .destroyed_on_fallthrough = destroyed_before };
            var has_deferred_invalidation = false;
            for (block_stmts) |stmt| {
                if (!result.can_fallthrough) break;
                if (self.isDeferSelfUndefined(stmt, param_name)) {
                    has_deferred_invalidation = true;
                    result.deferred_invalidation_after_destroy = result.deferred_invalidation_after_destroy or
                        result.destroyed_on_fallthrough;
                    continue;
                }
                const stmt_result = self.analyzeReceiverLifetime(stmt, param_name, result.destroyed_on_fallthrough);
                result.can_fallthrough = stmt_result.can_fallthrough;
                result.destroyed_on_fallthrough = stmt_result.destroyed_on_fallthrough;
                result.saw_destroy = result.saw_destroy or stmt_result.saw_destroy;
                result.invalidation_after_destroy = result.invalidation_after_destroy or
                    stmt_result.invalidation_after_destroy;
                result.deferred_invalidation_after_destroy = result.deferred_invalidation_after_destroy or
                    stmt_result.deferred_invalidation_after_destroy or
                    (has_deferred_invalidation and stmt_result.saw_destroy);
            }
            return result;
        },
        else => return .{ .destroyed_on_fallthrough = destroyed_before },
    }
}

fn isSelfDestroyCall(self: *Linter, node: Ast.Node.Index, param_name: []const u8) bool {
    var buf: [1]Ast.Node.Index = undefined;
    const call = self.tree.fullCall(&buf, node) orelse return false;
    if (call.ast.params.len != 1) return false;

    const fn_expr = call.ast.fn_expr;
    if (self.tree.nodeTag(fn_expr) != .field_access) return false;
    const field_access = self.tree.nodeData(fn_expr).node_and_token;
    if (!std.mem.eql(u8, self.tree.tokenSlice(field_access[1]), "destroy")) return false;

    const arg = call.ast.params[0];
    if (self.tree.nodeTag(arg) != .identifier) return false;
    return std.mem.eql(u8, self.tree.tokenSlice(self.tree.nodeMainToken(arg)), param_name);
}

fn isSelfUndefinedAssign(self: *Linter, node: Ast.Node.Index, param_name: []const u8) bool {
    if (self.tree.nodeTag(node) != .assign) return false;

    const assign_data = self.tree.nodeData(node).node_and_node;
    const lhs = assign_data[0];
    const rhs = assign_data[1];

    // LHS must be deref (self.*)
    if (self.tree.nodeTag(lhs) != .deref) return false;

    // The dereferenced expression must be the parameter name
    const deref_inner = self.tree.nodeData(lhs).node;
    if (self.tree.nodeTag(deref_inner) != .identifier) return false;
    const deref_name = self.tree.tokenSlice(self.tree.nodeMainToken(deref_inner));
    if (!std.mem.eql(u8, deref_name, param_name)) return false;

    // RHS must be undefined
    if (self.tree.nodeTag(rhs) != .identifier) return false;
    const rhs_name = self.tree.tokenSlice(self.tree.nodeMainToken(rhs));
    return std.mem.eql(u8, rhs_name, "undefined");
}

fn checkVarDecl(self: *Linter, node: Ast.Node.Index) void {
    const var_decl = self.tree.fullVarDecl(node) orelse return;

    const name_token = var_decl.ast.mut_token + 1;
    const name = self.tree.tokenSlice(name_token);

    if (name.len > 0 and name[0] == '_' and name.len > 1 and name[1] != '_') {
        if (var_decl.ast.init_node != .none) {
            const loc = self.tree.tokenLocation(0, name_token);
            self.report(loc, .Z002, name);
        }
    }

    if (!isSnakeCase(name) and !isTypeAlias(self, var_decl) and !isFunctionAlias(self, var_decl)) {
        const loc = self.tree.tokenLocation(0, name_token);
        self.report(loc, .Z006, name);
    }

    // Check for underscore prefix
    if (hasUnderscorePrefix(name)) {
        const loc = self.tree.tokenLocation(0, name_token);
        self.report(loc, .Z031, name);
    }

    // Check that error sets are PascalCase
    if (var_decl.ast.init_node.unwrap()) |init_node| {
        if (self.tree.nodeTag(init_node) == .error_set_decl and !isPascalCase(name)) {
            const loc = self.tree.tokenLocation(0, name_token);
            self.report(loc, .Z014, name);
        }
    }

    if (var_decl.ast.type_node == .none) {
        if (var_decl.ast.init_node.unwrap()) |init_node| {
            if (isExplicitStructInit(self.tree.nodeTag(init_node))) {
                var buf: [2]Ast.Node.Index = undefined;
                const struct_init = self.tree.fullStructInit(&buf, init_node) orelse return;
                const type_node = struct_init.ast.type_expr.unwrap() orelse return;
                const type_source = self.getNodeSource(type_node);
                const context = self.allocator.print("{s}\x00{s}", .{ name, type_source }) catch return;
                self.allocated_contexts.append(self.allocator, context) catch {
                    self.allocator.free(context);
                    return;
                };
                const loc = self.tree.tokenLocation(0, var_decl.ast.mut_token);
                self.report(loc, .Z004, context);
            }
        }
    }

    // Check for acronym casing (for type aliases)
    if (isTypeAlias(self, var_decl)) {
        if (checkAcronymCasing(self.allocator, name)) |suggestion| {
            const context = self.allocator.alloc(u8, name.len + 1 + suggestion.len) catch {
                self.allocator.free(suggestion);
                return;
            };
            @memcpy(context[0..name.len], name);
            context[name.len] = 0;
            @memcpy(context[name.len + 1 ..], suggestion);
            self.trackContext(context);
            self.trackContext(suggestion);
            const loc = self.tree.tokenLocation(0, name_token);
            self.report(loc, .Z032, context);
        }
    }

    // Check for redundant words (disabled by default)
    if (isTypeAlias(self, var_decl)) {
        if (findRedundantWord(name)) |word| {
            const context = self.allocator.alloc(u8, name.len + 1 + word.len) catch return;
            @memcpy(context[0..name.len], name);
            context[name.len] = 0;
            @memcpy(context[name.len + 1 ..], word);
            self.trackContext(context);
            const loc = self.tree.tokenLocation(0, name_token);
            self.report(loc, .Z033, context);
        }
    }

    self.checkDupeImport(var_decl, name_token);
    self.trackImportBinding(node, var_decl, name_token);
    self.checkRedundantAsInVarDecl(var_decl);
}

fn checkRedundantAsInVarDecl(self: *Linter, var_decl: Ast.full.VarDecl) void {
    // Need both a type annotation and an init expression
    const type_node = var_decl.ast.type_node.unwrap() orelse return;
    const init_node = var_decl.ast.init_node.unwrap() orelse return;

    // Get the declared type name
    const decl_type_name = self.getTypeNodeName(type_node) orelse return;

    // Get the @as type from init expression
    const as_type_name = self.getAsTypeName(init_node) orelse return;

    // Compare types
    if (std.mem.eql(u8, decl_type_name, as_type_name)) {
        const loc = self.tree.tokenLocation(0, self.tree.nodeMainToken(init_node));
        self.report(loc, .Z018, as_type_name);
    }
}

fn trackImportBinding(self: *Linter, node: Ast.Node.Index, var_decl: Ast.full.VarDecl, name_token: Ast.TokenIndex) void {
    const init_node = var_decl.ast.init_node.unwrap() orelse return;

    // Check if this is a @import call
    const main_token = self.tree.nodeMainToken(init_node);
    const builtin_name = self.tree.tokenSlice(main_token);
    if (!std.mem.eql(u8, builtin_name, "@import")) return;

    const name = self.tree.tokenSlice(name_token);
    const is_discard = std.mem.eql(u8, name, "_");
    const is_pub = self.isPublicDecl(node);

    self.import_bindings.put(self.allocator, name, .{
        .name_token = name_token,
        .is_pub = is_pub,
        .is_discard = is_discard,
        // ziglint-ignore: Z026 -- import tracking must survive OOM mid-lint
    }) catch {};
}

fn checkDupeImport(self: *Linter, var_decl: Ast.full.VarDecl, name_token: Ast.TokenIndex) void {
    const init_node = var_decl.ast.init_node.unwrap() orelse return;

    // Check if this is a @import call
    const main_token = self.tree.nodeMainToken(init_node);
    const builtin_name = self.tree.tokenSlice(main_token);
    if (!std.mem.eql(u8, builtin_name, "@import")) return;

    // Get the import argument
    var buf: [2]Ast.Node.Index = undefined;
    const params = self.tree.builtinCallParams(&buf, init_node) orelse return;
    if (params.len == 0) return;

    const arg_token = self.tree.nodeMainToken(params[0]);
    const import_path = self.tree.tokenSlice(arg_token);

    // Check for duplicate
    if (self.seen_imports.get(import_path)) |_| {
        const loc = self.tree.tokenLocation(0, name_token);
        self.report(loc, .Z007, import_path);
    } else {
        // ziglint-ignore: Z026 -- import tracking must survive OOM mid-lint
        self.seen_imports.put(self.allocator, import_path, name_token) catch {};
    }
}

fn checkReturn(self: *Linter, node: Ast.Node.Index) void {
    const return_expr = self.tree.nodeData(node).opt_node.unwrap() orelse return;
    self.checkRedundantType(return_expr, true);

    self.checkReturnTry(node, return_expr);

    self.checkRedundantAsInReturn(node, return_expr);
}

fn checkReturnTry(self: *Linter, return_node: Ast.Node.Index, return_expr: Ast.Node.Index) void {
    // Check if the return expression is a try
    if (self.tree.nodeTag(return_expr) != .@"try") return;

    // Get the inner expression being tried
    const try_expr = self.tree.nodeData(return_expr).node;
    const expr_source = self.getNodeSource(try_expr);
    const truncated = truncateExpr(expr_source);

    const loc = self.tree.tokenLocation(0, self.tree.nodeMainToken(return_node));
    self.report(loc, .Z017, truncated);
}

fn checkCatchReturnAll(self: *Linter) void {
    for (0..self.tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (self.tree.nodeTag(node) != .@"catch") continue;

        const data = self.tree.nodeData(node).node_and_node;
        const rhs = data[1];

        if (self.tree.nodeTag(rhs) != .@"return") continue;

        // Must have a capture payload: `catch |err|`
        const catch_token = self.tree.nodeMainToken(node);
        const pipe_token = catch_token + 1;
        if (self.tree.tokenTag(pipe_token) != .pipe) continue;

        const payload_token = pipe_token + 1;
        const payload_name = self.tree.tokenSlice(payload_token);

        // The return expression must be an identifier matching the payload
        const return_expr = self.tree.nodeData(rhs).opt_node.unwrap() orelse continue;
        if (self.tree.nodeTag(return_expr) != .identifier) continue;
        const return_name = self.tree.tokenSlice(self.tree.nodeMainToken(return_expr));

        if (!std.mem.eql(u8, payload_name, return_name)) continue;

        const loc = self.tree.tokenLocation(0, catch_token);
        self.report(loc, .Z025, payload_name);
    }
}

fn checkEmptyCatchAll(self: *Linter) void {
    for (0..self.tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (self.tree.nodeTag(node) != .@"catch") continue;

        const data = self.tree.nodeData(node).node_and_node;
        const rhs = data[1];

        if (!self.isEmptyBlock(rhs)) continue;

        // Skip if under a defer node
        if (self.isUnderDefer(node)) continue;

        const catch_token = self.tree.nodeMainToken(node);
        const loc = self.tree.tokenLocation(0, catch_token);
        self.report(loc, .Z026, "");
    }
}

fn checkPrintLiteralArgs(self: *Linter) void {
    for (0..self.tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const tag = self.tree.nodeTag(node);
        if (tag != .call and tag != .call_comma) continue;

        var call_buf: [1]Ast.Node.Index = undefined;
        const call = self.tree.fullCall(&call_buf, node) orelse continue;
        if (call.ast.params.len != 2) continue;

        const callee = call.ast.fn_expr;
        if (self.tree.nodeTag(callee) != .field_access) continue;
        const callee_data = self.tree.nodeData(callee).node_and_token;
        const method_token = callee_data[1];
        if (!std.mem.eql(u8, self.tree.tokenSlice(method_token), "print")) continue;

        if (!self.isFormatlessStringLiteral(call.ast.params[0])) continue;
        if (!self.isEmptyArgsTuple(call.ast.params[1])) continue;
        if (!self.isIoWriterExpr(node, callee_data[0])) continue;

        const loc = self.tree.tokenLocation(0, method_token);
        self.report(loc, .Z034, "");
    }
}

/// Returns true when the argument is a string literal with no format
/// placeholders. Doubled braces are literal braces, not placeholders.
fn isFormatlessStringLiteral(self: *Linter, node: Ast.Node.Index) bool {
    return switch (self.tree.nodeTag(node)) {
        .string_literal => blk: {
            const raw = self.tree.tokenSlice(self.tree.nodeMainToken(node));
            if (raw.len < 2) break :blk false;
            break :blk !hasFormatPlaceholder(raw[1 .. raw.len - 1], true);
        },
        .multiline_string_literal => blk: {
            const first = self.tree.firstToken(node);
            const last = self.tree.lastToken(node);
            var token = first;
            while (token <= last) : (token += 1) {
                const raw = self.tree.tokenSlice(token);
                // Multiline string bodies do not process backslash escapes.
                const body = if (std.mem.startsWith(u8, raw, "\\\\")) raw[2..] else raw;
                if (hasFormatPlaceholder(body, false)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn hasFormatPlaceholder(raw: []const u8, escapes: bool) bool {
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (escapes and c == '\\') {
            i += 2;
            continue;
        }
        if ((c == '{' or c == '}') and i + 1 < raw.len and raw[i + 1] == c) {
            i += 2;
            continue;
        }
        if (c == '{' or c == '}') return true;
        i += 1;
    }
    return false;
}

/// `.{}` is an anonymous empty struct init. A named empty struct (`Foo{}`)
/// also works as an args tuple but is not what this rule targets.
fn isEmptyArgsTuple(self: *Linter, node: Ast.Node.Index) bool {
    var init_buf: [2]Ast.Node.Index = undefined;
    const struct_init = self.tree.fullStructInit(&init_buf, node) orelse return false;
    return struct_init.ast.fields.len == 0 and struct_init.ast.type_expr.unwrap() == null;
}

fn isIoWriterExpr(self: *Linter, use_site: Ast.Node.Index, expr: Ast.Node.Index) bool {
    const tag = self.tree.nodeTag(expr);
    switch (tag) {
        .identifier => {
            const name = self.tree.tokenSlice(self.tree.nodeMainToken(expr));
            const type_node = self.lookupScopedTypeNode(use_site, name) orelse return false;
            return self.isIoWriterType(type_node);
        },
        .address_of => {
            const inner = self.tree.nodeData(expr).node;
            return self.isIoWriterExpr(use_site, inner);
        },
        .field_access => {
            const data = self.tree.nodeData(expr).node_and_token;
            const field_name = self.tree.tokenSlice(data[1]);
            const field_type = self.lookupReceiverFieldType(use_site, data[0], field_name) orelse return false;
            return self.isIoWriterType(field_type);
        },
        else => return false,
    }
}

/// Finds a parameter or local declaration with an explicit type annotation.
/// Declarations are searched from the innermost block outward; a nested
/// function cannot capture outer locals, so the search stops there.
fn lookupScopedTypeNode(self: *Linter, use_site: Ast.Node.Index, name: []const u8) ?Ast.Node.Index {
    var current = use_site;
    var reached_fn = false;
    while (true) {
        const parent = self.parent_map[@backingInt(current)].unwrap() orelse break;
        switch (self.tree.nodeTag(parent)) {
            .block, .block_semicolon => {
                var block_buf: [2]Ast.Node.Index = undefined;
                if (self.tree.blockStatements(&block_buf, parent)) |stmts| {
                    if (self.findVarDeclTypeIn(stmts, use_site, name)) |type_node| return type_node;
                }
            },
            .block_two, .block_two_semicolon => {
                const data = self.tree.nodeData(parent).opt_node_and_opt_node;
                if (data[0].unwrap()) |stmt| {
                    if (self.findVarDeclTypeIn(&.{stmt}, use_site, name)) |type_node| return type_node;
                }
                if (data[1].unwrap()) |stmt| {
                    if (self.findVarDeclTypeIn(&.{stmt}, use_site, name)) |type_node| return type_node;
                }
            },
            .fn_decl => {
                reached_fn = true;
                if (self.findParamTypeNode(parent, name)) |type_node| return type_node;
                break;
            },
            else => {},
        }
        current = parent;
    }

    // The parent map does not connect every wrapper (switch prongs, return
    // expressions). Fall back to the innermost function that contains the
    // use site.
    if (!reached_fn) {
        if (self.findEnclosingFnByToken(use_site)) |fn_decl| {
            if (self.findParamTypeNode(fn_decl, name)) |type_node| return type_node;
            return self.findLocalTypeNodeNear(fn_decl, use_site, name);
        }
    }
    return self.findTopLevelTypeNode(name);
}

fn findEnclosingFnByToken(self: *Linter, use_site: Ast.Node.Index) ?Ast.Node.Index {
    const use_token = self.tree.nodeMainToken(use_site);
    var best: ?Ast.Node.Index = null;
    var best_start: Ast.TokenIndex = 0;
    for (0..self.tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (self.tree.nodeTag(node) != .fn_decl) continue;
        const start = self.tree.firstToken(node);
        const end = self.tree.lastToken(node);
        if (start <= use_token and use_token <= end and (best == null or start >= best_start)) {
            best = node;
            best_start = start;
        }
    }
    return best;
}

/// Nearest preceding local with this name inside the function. Shadowing is
/// forbidden in Zig, so at most one declaration can be in scope.
fn findLocalTypeNodeNear(self: *Linter, fn_decl: Ast.Node.Index, use_site: Ast.Node.Index, name: []const u8) ?Ast.Node.Index {
    const use_token = self.tree.nodeMainToken(use_site);
    const fn_start = self.tree.firstToken(fn_decl);
    const fn_end = self.tree.lastToken(fn_decl);

    var found: ?Ast.Node.Index = null;
    var found_token: Ast.TokenIndex = 0;
    for (0..self.tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const var_decl = self.tree.fullVarDecl(node) orelse continue;
        const name_token = var_decl.ast.mut_token + 1;
        if (!std.mem.eql(u8, self.tree.tokenSlice(name_token), name)) continue;
        const decl_token = self.tree.nodeMainToken(node);
        if (decl_token < fn_start or decl_token > fn_end) continue;
        if (decl_token > use_token) continue;
        if (found == null or decl_token > found_token) {
            found = var_decl.ast.type_node.unwrap();
            found_token = decl_token;
        }
    }
    return found;
}

fn findVarDeclTypeIn(self: *Linter, stmts: []const Ast.Node.Index, use_site: Ast.Node.Index, name: []const u8) ?Ast.Node.Index {
    for (stmts) |stmt| {
        const var_decl = self.tree.fullVarDecl(stmt) orelse continue;
        const name_token = var_decl.ast.mut_token + 1;
        if (!std.mem.eql(u8, self.tree.tokenSlice(name_token), name)) continue;
        // A declaration after the use cannot be the referent.
        if (self.tree.nodeMainToken(stmt) > self.tree.nodeMainToken(use_site)) continue;
        return var_decl.ast.type_node.unwrap();
    }
    return null;
}

fn findParamTypeNode(self: *Linter, fn_decl: Ast.Node.Index, name: []const u8) ?Ast.Node.Index {
    var proto_buf: [1]Ast.Node.Index = undefined;
    const fn_proto = self.tree.fullFnProto(&proto_buf, fn_decl) orelse return null;
    var it = fn_proto.iterate(&self.tree);
    while (it.next()) |param| {
        const name_token = param.name_token orelse continue;
        if (!std.mem.eql(u8, self.tree.tokenSlice(name_token), name)) continue;
        return param.type_expr;
    }
    return null;
}

fn findTopLevelTypeNode(self: *Linter, name: []const u8) ?Ast.Node.Index {
    const var_decl = self.findTopLevelVarDecl(name) orelse return null;
    return var_decl.ast.type_node.unwrap();
}

fn findTopLevelVarDecl(self: *Linter, name: []const u8) ?Ast.full.VarDecl {
    for (self.tree.rootDecls()) |decl| {
        const var_decl = self.tree.fullVarDecl(decl) orelse continue;
        const name_token = var_decl.ast.mut_token + 1;
        if (!std.mem.eql(u8, self.tree.tokenSlice(name_token), name)) continue;
        return var_decl;
    }
    return null;
}

/// Resolves `base.field` for `self.field` and for fields of a user type that
/// the current file declares. Standard-library field types are not resolved.
fn lookupReceiverFieldType(self: *Linter, use_site: Ast.Node.Index, base: Ast.Node.Index, field_name: []const u8) ?Ast.Node.Index {
    if (self.tree.nodeTag(base) != .identifier) return null;
    const base_name = self.tree.tokenSlice(self.tree.nodeMainToken(base));

    var container: Ast.Node.Index = undefined;
    if (std.mem.eql(u8, base_name, "self") or std.mem.eql(u8, base_name, "Self")) {
        container = self.findEnclosingContainer(use_site).unwrap() orelse return null;
    } else {
        const base_type = self.lookupScopedTypeNode(use_site, base_name) orelse return null;
        const unwrapped = self.stripTypeWrappers(base_type);
        if (self.tree.nodeTag(unwrapped) != .identifier) return null;
        const type_name = self.tree.tokenSlice(self.tree.nodeMainToken(unwrapped));
        container = self.findTopLevelContainerDecl(type_name) orelse return null;
    }
    return self.findContainerFieldTypeNode(container, field_name);
}

fn findTopLevelContainerDecl(self: *Linter, name: []const u8) ?Ast.Node.Index {
    const var_decl = self.findTopLevelVarDecl(name) orelse return null;
    const init_node = var_decl.ast.init_node.unwrap() orelse return null;
    var container_buf: [2]Ast.Node.Index = undefined;
    if (self.tree.fullContainerDecl(&container_buf, init_node) == null) return null;
    return init_node;
}

fn findContainerFieldTypeNode(self: *Linter, container_node: Ast.Node.Index, field_name: []const u8) ?Ast.Node.Index {
    var container_buf: [2]Ast.Node.Index = undefined;
    const container = self.tree.fullContainerDecl(&container_buf, container_node) orelse return null;
    for (container.ast.members) |member| {
        const field = self.tree.fullContainerField(member) orelse continue;
        if (!std.mem.eql(u8, self.tree.tokenSlice(field.ast.main_token), field_name)) continue;
        return field.ast.type_expr.unwrap();
    }
    return null;
}

fn stripTypeWrappers(self: *Linter, type_node: Ast.Node.Index) Ast.Node.Index {
    var node = type_node;
    while (true) {
        switch (self.tree.nodeTag(node)) {
            .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => {
                const ptr = self.tree.fullPtrType(node) orelse return node;
                node = ptr.ast.child_type;
            },
            .optional_type => node = self.tree.nodeData(node).node,
            .error_union => node = self.tree.nodeData(node).node_and_node[0],
            else => return node,
        }
    }
}

fn isIoWriterType(self: *Linter, type_node: Ast.Node.Index) bool {
    const unwrapped = self.stripTypeWrappers(type_node);

    // Unit tests and files without semantic analysis use the syntactic path.
    return self.isIoWriterTypePath(unwrapped, 0);
}

/// Syntactic fallback for `std.Io.Writer`, including local aliases such as
/// `const Writer = std.Io.Writer;` and `const Io = std.Io;`.
fn isIoWriterTypePath(self: *Linter, node: Ast.Node.Index, depth: u8) bool {
    if (depth > 8) return false;
    switch (self.tree.nodeTag(node)) {
        .identifier => {
            const name = self.tree.tokenSlice(self.tree.nodeMainToken(node));
            const alias_init = self.findTopLevelAliasInit(name) orelse return false;
            return self.isIoWriterTypePath(self.stripTypeWrappers(alias_init), depth + 1);
        },
        .field_access => {
            const data = self.tree.nodeData(node).node_and_token;
            if (!std.mem.eql(u8, self.tree.tokenSlice(data[1]), "Writer")) return false;
            return self.isStdIoRef(data[0], depth + 1);
        },
        else => return false,
    }
}

fn isStdIoRef(self: *Linter, node: Ast.Node.Index, depth: u8) bool {
    if (depth > 8) return false;
    switch (self.tree.nodeTag(node)) {
        .identifier => {
            const name = self.tree.tokenSlice(self.tree.nodeMainToken(node));
            if (self.findTopLevelAliasInit(name)) |alias_init| {
                return self.isStdIoRef(self.stripTypeWrappers(alias_init), depth + 1);
            }
            // `Io.Writer` is the conventional alias for `std.Io.Writer`.
            return std.mem.eql(u8, name, "Io");
        },
        .field_access => {
            const data = self.tree.nodeData(node).node_and_token;
            if (!std.mem.eql(u8, self.tree.tokenSlice(data[1]), "Io")) return false;
            return self.isStdImportRef(data[0], depth + 1);
        },
        else => return false,
    }
}

fn isStdImportRef(self: *Linter, node: Ast.Node.Index, depth: u8) bool {
    if (depth > 8) return false;
    if (self.tree.nodeTag(node) != .identifier) return false;
    const name = self.tree.tokenSlice(self.tree.nodeMainToken(node));
    if (std.mem.eql(u8, name, "std")) return true;
    const alias_init = self.findTopLevelAliasInit(name) orelse return false;
    return self.isStdImportCall(alias_init);
}

fn isStdImportCall(self: *Linter, node: Ast.Node.Index) bool {
    const tag = self.tree.nodeTag(node);
    if (tag != .builtin_call_two and tag != .builtin_call_two_comma) return false;
    const main_token = self.tree.nodeMainToken(node);
    if (!std.mem.eql(u8, self.tree.tokenSlice(main_token), "@import")) return false;

    var params_buf: [2]Ast.Node.Index = undefined;
    const params = self.tree.builtinCallParams(&params_buf, node) orelse return false;
    if (params.len != 1) return false;
    if (self.tree.nodeTag(params[0]) != .string_literal) return false;
    return std.mem.eql(u8, self.tree.tokenSlice(self.tree.nodeMainToken(params[0])), "\"std\"");
}

fn findTopLevelAliasInit(self: *Linter, name: []const u8) ?Ast.Node.Index {
    const var_decl = self.findTopLevelVarDecl(name) orelse return null;
    return var_decl.ast.init_node.unwrap();
}

fn isEmptyBlock(self: *Linter, node: Ast.Node.Index) bool {
    const tag = self.tree.nodeTag(node);
    return switch (tag) {
        .block_two, .block_two_semicolon => {
            const block_data = self.tree.nodeData(node).opt_node_and_opt_node;
            return block_data[0] == .none and block_data[1] == .none;
        },
        .block, .block_semicolon => {
            var buf: [2]Ast.Node.Index = undefined;
            const stmts = self.tree.blockStatements(&buf, node) orelse return true;
            return stmts.len == 0;
        },
        else => false,
    };
}

fn isUnderDefer(self: *Linter, node: Ast.Node.Index) bool {
    if (self.parent_map.len == 0) return false;
    var current = node;
    while (true) {
        const parent_opt = self.parent_map[@backingInt(current)];
        const parent = parent_opt.unwrap() orelse return false;
        const tag = self.tree.nodeTag(parent);
        if (tag == .@"defer" or tag == .@"errdefer") return true;
        current = parent;
    }
}

fn checkRedundantAsInReturn(self: *Linter, return_node: Ast.Node.Index, return_expr: Ast.Node.Index) void {
    // Get the @as type from return expression
    const as_type_name = self.getAsTypeName(return_expr) orelse return;

    // Get function's return type
    const fn_return_type = self.current_fn_return_type.unwrap() orelse return;
    const fn_return_name = self.getTypeNodeName(fn_return_type) orelse return;

    // Compare types
    if (std.mem.eql(u8, as_type_name, fn_return_name)) {
        const loc = self.tree.tokenLocation(0, self.tree.nodeMainToken(return_node));
        self.report(loc, .Z018, as_type_name);
    }
}

fn getAsTypeName(self: *Linter, node: Ast.Node.Index) ?[]const u8 {
    const tag = self.tree.nodeTag(node);
    if (tag != .builtin_call_two and tag != .builtin_call_two_comma and
        tag != .builtin_call and tag != .builtin_call_comma) return null;

    const main_token = self.tree.nodeMainToken(node);
    const builtin_name = self.tree.tokenSlice(main_token);
    if (!std.mem.eql(u8, builtin_name, "@as")) return null;

    var buf: [2]Ast.Node.Index = undefined;
    const params = self.tree.builtinCallParams(&buf, node) orelse return null;
    if (params.len < 1) return null;

    return self.getTypeNodeName(params[0]);
}

fn getTypeNodeName(self: *Linter, type_node: Ast.Node.Index) ?[]const u8 {
    const tag = self.tree.nodeTag(type_node);
    return switch (tag) {
        .identifier => self.tree.tokenSlice(self.tree.nodeMainToken(type_node)),
        else => null,
    };
}

fn checkRedundantAsInCallArgs(self: *Linter, node: Ast.Node.Index) void {
    var call_buf: [1]Ast.Node.Index = undefined;
    const call = self.tree.fullCall(&call_buf, node) orelse return;
    const params = call.ast.params;
    if (params.len == 0) return;

    // Resolve the called function's prototype and determine param offset
    const resolved = self.resolveCalledFnProto(call.ast.fn_expr) orelse return;
    const fn_tree = resolved.tree;
    var fn_buf: [1]Ast.Node.Index = undefined;
    const fn_proto = fn_tree.fullFnProto(&fn_buf, resolved.fn_node) orelse return;

    // For method calls (field_access), skip the receiver param
    const skip_receiver = self.tree.nodeTag(call.ast.fn_expr) == .field_access;

    var it = fn_proto.iterate(fn_tree);
    var param_idx: usize = 0;

    if (skip_receiver) {
        _ = it.next();
    }

    while (it.next()) |param| : (param_idx += 1) {
        if (param_idx >= params.len) break;
        const arg = params[param_idx];

        const as_type_name = self.getAsTypeName(arg) orelse continue;
        const type_node = param.type_expr orelse continue;
        const param_type_name = self.getTypeNodeNameFromTree(fn_tree, type_node) orelse continue;

        if (std.mem.eql(u8, as_type_name, param_type_name)) {
            const loc = self.tree.tokenLocation(0, self.tree.nodeMainToken(arg));
            self.report(loc, .Z029, as_type_name);
        }
    }
}

const ResolvedFnProto = struct {
    tree: *const Ast,
    fn_node: Ast.Node.Index,
};

fn resolveCalledFnProto(self: *Linter, callee_expr: Ast.Node.Index) ?ResolvedFnProto {
    const tag = self.tree.nodeTag(callee_expr);
    switch (tag) {
        .identifier => {
            const fn_name = self.tree.tokenSlice(self.tree.nodeMainToken(callee_expr));
            for (self.tree.rootDecls()) |decl_node| {
                if (self.tree.nodeTag(decl_node) != .fn_decl) continue;
                var buf: [1]Ast.Node.Index = undefined;
                const fn_proto = self.tree.fullFnProto(&buf, decl_node) orelse continue;
                const name_token = fn_proto.name_token orelse continue;
                if (std.mem.eql(u8, self.tree.tokenSlice(name_token), fn_name)) {
                    return .{ .tree = &self.tree, .fn_node = decl_node };
                }
            }
        },
        else => {},
    }
    return null;
}

fn checkRedundantAsInArrayInit(self: *Linter, node: Ast.Node.Index) void {
    var buf: [2]Ast.Node.Index = undefined;
    const array_init = self.tree.fullArrayInit(&buf, node) orelse return;
    const type_expr = array_init.ast.type_expr.unwrap() orelse return;

    // Get the element type from the array type expression
    const elem_type_name = self.getArrayElemTypeName(type_expr) orelse return;

    for (array_init.ast.elements) |elem| {
        const as_type_name = self.getAsTypeName(elem) orelse continue;
        if (std.mem.eql(u8, as_type_name, elem_type_name)) {
            const loc = self.tree.tokenLocation(0, self.tree.nodeMainToken(elem));
            self.report(loc, .Z029, as_type_name);
        }
    }
}

fn getArrayElemTypeName(self: *Linter, type_expr: Ast.Node.Index) ?[]const u8 {
    const type_tag = self.tree.nodeTag(type_expr);
    return switch (type_tag) {
        .array_type, .array_type_sentinel => {
            const array_type = self.tree.fullArrayType(type_expr) orelse return null;
            return self.getTypeNodeName(array_type.ast.elem_type);
        },
        else => null,
    };
}

fn getTypeNodeNameFromTree(_: *Linter, tree: *const Ast, type_node: Ast.Node.Index) ?[]const u8 {
    const tag = tree.nodeTag(type_node);
    return switch (tag) {
        .identifier => tree.tokenSlice(tree.nodeMainToken(type_node)),
        else => null,
    };
}

fn checkRedundantAsInStructInit(self: *Linter, node: Ast.Node.Index) void {
    var buf: [2]Ast.Node.Index = undefined;
    const struct_init = self.tree.fullStructInit(&buf, node) orelse return;
    if (struct_init.ast.fields.len == 0) return;

    // Determine the struct type name
    const struct_type_name = self.resolveStructInitTypeName(node, struct_init) orelse return;

    for (struct_init.ast.fields) |field_value| {
        const as_type_name = self.getAsTypeName(field_value) orelse continue;

        // Get field name: token before '=' before the value expression
        const value_main_token = self.tree.nodeMainToken(field_value);
        if (value_main_token < 2) continue;
        const field_name_token = value_main_token - 2;
        if (self.tree.tokenTag(field_name_token) != .identifier) continue;
        const field_name = self.tree.tokenSlice(field_name_token);

        const field_type_name = self.findContainerFieldType(struct_type_name, field_name) orelse continue;
        if (std.mem.eql(u8, as_type_name, field_type_name)) {
            const loc = self.tree.tokenLocation(0, self.tree.nodeMainToken(field_value));
            self.report(loc, .Z029, as_type_name);
        }
    }
}

fn resolveStructInitTypeName(self: *Linter, node: Ast.Node.Index, struct_init: Ast.full.StructInit) ?[]const u8 {
    // Case 1: explicit type expression (e.g., Foo{ .x = 1 })
    if (struct_init.ast.type_expr.unwrap()) |type_expr| {
        return self.getTypeNodeName(type_expr);
    }

    // Case 2: anonymous init — walk parent_map to find type context
    if (self.parent_map.len == 0) return null;
    const parent = self.parent_map[@backingInt(node)].unwrap() orelse return null;
    const parent_tag = self.tree.nodeTag(parent);
    switch (parent_tag) {
        .simple_var_decl, .aligned_var_decl, .local_var_decl, .global_var_decl => {
            const var_decl = self.tree.fullVarDecl(parent) orelse return null;
            const type_node = var_decl.ast.type_node.unwrap() orelse return null;
            return self.getTypeNodeName(type_node);
        },
        else => return null,
    }
}

fn findContainerFieldType(self: *Linter, struct_type_name: []const u8, field_name: []const u8) ?[]const u8 {
    return self.findContainerFieldTypeInTree(&self.tree, struct_type_name, field_name);
}

fn findContainerFieldTypeInTree(self: *Linter, tree: *const Ast, struct_type_name: []const u8, field_name: []const u8) ?[]const u8 {
    _ = self;
    for (tree.rootDecls()) |decl_node| {
        const tag = tree.nodeTag(decl_node);
        switch (tag) {
            .simple_var_decl, .aligned_var_decl, .local_var_decl, .global_var_decl => {
                const var_decl = tree.fullVarDecl(decl_node) orelse continue;
                const name_token = var_decl.ast.mut_token + 1;
                if (!std.mem.eql(u8, tree.tokenSlice(name_token), struct_type_name)) continue;
                const init_node = var_decl.ast.init_node.unwrap() orelse continue;

                var container_buf: [2]Ast.Node.Index = undefined;
                const container = tree.fullContainerDecl(&container_buf, init_node) orelse continue;
                for (container.ast.members) |member| {
                    const field = tree.fullContainerField(member) orelse continue;
                    if (!std.mem.eql(u8, tree.tokenSlice(field.ast.main_token), field_name)) continue;
                    const type_node = field.ast.type_expr.unwrap() orelse return null;
                    const field_type_tag = tree.nodeTag(type_node);
                    return switch (field_type_tag) {
                        .identifier => tree.tokenSlice(tree.nodeMainToken(type_node)),
                        else => null,
                    };
                }
            },
            else => {},
        }
    }
    return null;
}

fn checkCallArgs(self: *Linter, node: Ast.Node.Index) void {
    var call_buf: [1]Ast.Node.Index = undefined;
    const call = self.tree.fullCall(&call_buf, node) orelse return;
    const resolved = self.resolveCalledFnProto(call.ast.fn_expr) orelse return;

    var fn_buf: [1]Ast.Node.Index = undefined;
    const fn_proto = resolved.tree.fullFnProto(&fn_buf, resolved.fn_node) orelse return;
    var param_it = fn_proto.iterate(resolved.tree);
    if (self.tree.nodeTag(call.ast.fn_expr) == .field_access) _ = param_it.next();

    for (call.ast.params) |arg| {
        const param = param_it.next() orelse break;
        const param_type = param.type_expr orelse continue;

        var struct_buf: [2]Ast.Node.Index = undefined;
        const struct_init = self.tree.fullStructInit(&struct_buf, arg) orelse continue;
        const arg_type = struct_init.ast.type_expr.unwrap() orelse continue;

        // Anonymous initialization is only safe when the parameter provides the
        // same concrete result type. Generic and unresolved calls are skipped.
        const arg_type_source = self.getNodeSource(arg_type);
        const param_type_source = getNodeSourceFromTree(resolved.tree, param_type);
        if (!std.mem.eql(u8, arg_type_source, param_type_source)) continue;

        self.checkRedundantType(arg, false);
    }
}

/// Reports every deprecated call in the file.
///
/// Z011 sweeps the node table instead of the recursive `visitNode` walk. That
/// walk stops at function signatures, container fields, and type-only
/// positions, so `std.meta.Int()` in a return type or struct field would
/// otherwise go unreported.
/// Whether doc comment `text` marks its declaration deprecated (Z011).
pub fn containsDeprecated(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.ascii.startsWithIgnoreCase(line, "deprecated")) {
            if (line.len == "deprecated".len) return true;
            const separator = line["deprecated".len];
            if (separator == ':' or separator == ';' or separator == ',' or separator == '.' or separator == ' ') return true;
        }
        if (std.ascii.startsWithIgnoreCase(line, "this function is deprecated")) return true;
    }
    return false;
}

fn checkCompoundAssert(self: *Linter, node: Ast.Node.Index) void {
    var buf: [1]Ast.Node.Index = undefined;
    const call = self.tree.fullCall(&buf, node) orelse return;

    const fn_expr = call.ast.fn_expr;
    if (!self.isStdDebugAssert(fn_expr)) return;

    // Check if argument is a compound bool_and or bool_or
    if (call.ast.params.len == 0) return;
    const arg = call.ast.params[0];
    const arg_tag = self.tree.nodeTag(arg);

    // Only flag `and` - `assert(a or b)` is not equivalent to `assert(a); assert(b);`
    if (arg_tag != .bool_and) return;

    const loc = self.tree.tokenLocation(0, self.tree.nodeMainToken(node));
    self.report(loc, .Z016, "and");
}

fn isStdDebugAssert(self: *Linter, node: Ast.Node.Index) bool {
    if (self.isStdDebugAssertField(node)) return true;
    if (self.tree.nodeTag(node) != .identifier) return false;

    const name = self.tree.tokenSlice(self.tree.nodeMainToken(node));
    for (self.tree.rootDecls()) |decl| {
        const var_decl = self.tree.fullVarDecl(decl) orelse continue;
        const name_token = var_decl.ast.mut_token + 1;
        if (!std.mem.eql(u8, self.tree.tokenSlice(name_token), name)) continue;
        const init_node = var_decl.ast.init_node.unwrap() orelse return false;
        return self.isStdDebugAssertField(init_node);
    }
    return false;
}

fn isStdDebugAssertField(self: *Linter, node: Ast.Node.Index) bool {
    if (self.tree.nodeTag(node) != .field_access) return false;
    const assert_access = self.tree.nodeData(node).node_and_token;
    if (!std.mem.eql(u8, self.tree.tokenSlice(assert_access[1]), "assert")) return false;

    const debug_node = assert_access[0];
    if (self.tree.nodeTag(debug_node) != .field_access) return false;
    const debug_access = self.tree.nodeData(debug_node).node_and_token;
    if (!std.mem.eql(u8, self.tree.tokenSlice(debug_access[1]), "debug")) return false;

    return self.isStdImport(debug_access[0]);
}

fn isStdImport(self: *Linter, node: Ast.Node.Index) bool {
    if (self.tree.nodeTag(node) == .identifier) {
        const name = self.tree.tokenSlice(self.tree.nodeMainToken(node));
        for (self.tree.rootDecls()) |decl| {
            const var_decl = self.tree.fullVarDecl(decl) orelse continue;
            const name_token = var_decl.ast.mut_token + 1;
            if (!std.mem.eql(u8, self.tree.tokenSlice(name_token), name)) continue;
            const init_node = var_decl.ast.init_node.unwrap() orelse return false;
            return self.isDirectStdImport(init_node);
        }
        return false;
    }

    return self.isDirectStdImport(node);
}

fn isDirectStdImport(self: *Linter, node: Ast.Node.Index) bool {
    const main_token = self.tree.nodeMainToken(node);
    if (!std.mem.eql(u8, self.tree.tokenSlice(main_token), "@import")) return false;
    var buf: [2]Ast.Node.Index = undefined;
    const params = self.tree.builtinCallParams(&buf, node) orelse return false;
    if (params.len != 1) return false;
    return std.mem.eql(u8, self.tree.tokenSlice(self.tree.nodeMainToken(params[0])), "\"std\"");
}

fn checkRedundantType(self: *Linter, node: Ast.Node.Index, check_field_access: bool) void {
    const tag = self.tree.nodeTag(node);

    if (isExplicitStructInit(tag)) {
        var buf: [2]Ast.Node.Index = undefined;
        const struct_init = self.tree.fullStructInit(&buf, node) orelse return;
        const type_node = struct_init.ast.type_expr.unwrap() orelse return;
        const type_token = self.tree.nodeMainToken(type_node);
        const loc = self.tree.tokenLocation(0, type_token);
        // Get the fields part (everything after the type name)
        const full_expr = self.getNodeSource(node);
        const type_name = self.tree.tokenSlice(type_token);
        // Find where the type name ends and extract the { ... } part
        const brace_start = std.mem.find(u8, full_expr, "{") orelse return;
        const fields_part = truncateExpr(full_expr[brace_start..]);
        const full_truncated = truncateExpr(full_expr);
        const msg = self.allocator.print(".{s}\x00{s}", .{ fields_part, full_truncated }) catch return;
        self.allocated_contexts.append(self.allocator, msg) catch {
            self.allocator.free(msg);
            return;
        };
        _ = type_name;
        self.report(loc, .Z010, msg);
    } else if (check_field_access and tag == .field_access) {
        // Only flag if the LHS is a PascalCase identifier (likely a type/enum)
        const data = self.tree.nodeData(node).node_and_token;
        const lhs = data[0];
        if (self.tree.nodeTag(lhs) != .identifier) return;
        const lhs_name = self.tree.tokenSlice(self.tree.nodeMainToken(lhs));
        if (!isPascalCase(lhs_name)) return;

        // Skip error sets - explicit Error.X is often preferred for clarity.
        // ziglint's resolver knows a root declaration's error set from the
        // file alone.
        if (self.findTopLevelVarDecl(lhs_name)) |decl| if (decl.ast.init_node.unwrap()) |init| {
            switch (self.tree.nodeTag(init)) {
                .error_set_decl, .merge_error_sets => return,
                else => {},
            }
        };

        const field_token = data[1];
        const field_name = self.tree.tokenSlice(field_token);
        const loc = self.tree.tokenLocation(0, self.tree.nodeMainToken(lhs));
        // Full expression is "Type.field"
        const full_expr = truncateExpr(self.getNodeSource(node));
        const msg = self.allocator.print(".{s}\x00{s}", .{ field_name, full_expr }) catch return;
        self.allocated_contexts.append(self.allocator, msg) catch {
            self.allocator.free(msg);
            return;
        };
        self.report(loc, .Z010, msg);
    }
}

fn getNodeSource(self: *Linter, node: Ast.Node.Index) []const u8 {
    return getNodeSourceFromTree(&self.tree, node);
}

fn getNodeSourceFromTree(tree: *const Ast, node: Ast.Node.Index) []const u8 {
    const token_starts = tree.tokens.items(.start);
    const first_token = tree.firstToken(node);
    const last_token = tree.lastToken(node);
    const start = token_starts[first_token];
    const end = token_starts[last_token] + tree.tokenSlice(last_token).len;
    return tree.source[start..end];
}

fn truncateExpr(expr: []const u8) []const u8 {
    const max_len = 32;
    if (expr.len <= max_len) return expr;
    // Find a good break point (after opening brace if present)
    if (std.mem.find(u8, expr[0..@min(max_len, expr.len)], "{")) |brace| {
        return expr[0 .. brace + 1];
    }
    return expr[0..max_len];
}

fn isExplicitStructInit(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .struct_init,
        .struct_init_comma,
        .struct_init_one,
        .struct_init_one_comma,
        => true,
        else => false,
    };
}

fn isValidFunctionName(name: []const u8) bool {
    if (name.len == 0) return false;
    // Must start with lowercase letter
    if (name[0] >= 'A' and name[0] <= 'Z') return false;
    // Leading underscore is allowed (private/internal convention)
    if (name[0] == '_') return true;

    // No underscores allowed in camelCase (except leading)
    for (name) |c| {
        if (c == '_') return false;
    }

    return true;
}

fn isPascalCase(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] < 'A' or name[0] > 'Z') return false;
    for (name) |c| {
        if (c == '_') return false;
    }
    return true;
}

fn isSnakeCase(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == '_') return true;
    for (name) |c| {
        if (c >= 'A' and c <= 'Z') return false;
    }
    return true;
}

/// Returns true if the identifier has an underscore prefix (but not just `_` or `__`).
fn hasUnderscorePrefix(name: []const u8) bool {
    if (name.len < 2) return false;
    if (name[0] != '_') return false;
    // Allow `__` double-underscore prefix (e.g., `__builtin`)
    if (name[1] == '_') return false;
    return true;
}

/// Checks if a name has incorrect acronym casing (e.g., XMLParser instead of XmlParser).
/// Returns the suggested fix if there's an issue, null otherwise.
fn checkAcronymCasing(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    if (name.len < 2) return null;

    // Find sequences of 2+ uppercase letters that should be title-cased
    // XMLParser -> XmlParser (XML at start)
    // readXML -> readXml (XML at end)
    // HTTPSConnection -> HttpsConnection (HTTPS at start)
    // getHTTPSConnection -> getHttpsConnection (HTTPS in middle)

    var result = allocator.alloc(u8, name.len) catch return null;
    @memcpy(result, name);
    var has_issue = false;

    var i: usize = 0;
    while (i < name.len) {
        if (isUppercase(name[i])) {
            // Found start of potential acronym
            const start = i;
            var end = i + 1;
            while (end < name.len and isUppercase(name[end])) {
                end += 1;
            }

            const acronym_len = end - start;
            if (acronym_len >= 2) {
                // We have 2+ consecutive uppercase letters
                // Check if this is at the end or followed by lowercase
                if (end < name.len and isLowercase(name[end])) {
                    // e.g., "XMLParser" - the last letter of "XML" is part of "Parser"
                    // Convert all but last uppercase to lowercase: "XmlParser"
                    for (start + 1..end - 1) |j| {
                        result[j] = toLowercase(name[j]);
                    }
                    if (acronym_len > 2) has_issue = true;
                } else {
                    // At end or followed by non-alpha (e.g., "readXML" or "XML123")
                    // Convert all but first to lowercase: "readXml" or "Xml123"
                    for (start + 1..end) |j| {
                        result[j] = toLowercase(name[j]);
                    }
                    if (acronym_len >= 2) has_issue = true;
                }
            }
            i = end;
        } else {
            i += 1;
        }
    }

    if (has_issue) {
        return result;
    } else {
        allocator.free(result);
        return null;
    }
}

fn isUppercase(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

fn isLowercase(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

fn toLowercase(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

/// Words that are considered redundant in identifier names per the Zig style guide.
const redundant_words = [_][]const u8{
    "Value",
    "Data",
    "Context",
    "Manager",
    "State",
    "utils",
    "misc",
    "Util",
    "Utils",
    "Misc",
};

/// Checks if a name contains a redundant word and returns it if found.
fn findRedundantWord(name: []const u8) ?[]const u8 {
    // Check if the name contains any redundant word as a complete word boundary
    for (redundant_words) |word| {
        if (containsWordBoundary(name, word)) {
            return word;
        }
    }
    return null;
}

/// Returns true if name contains word at a word boundary (start, end, or camelCase boundary).
fn containsWordBoundary(name: []const u8, word: []const u8) bool {
    if (word.len > name.len) return false;

    // Check if name equals word exactly
    if (std.mem.eql(u8, name, word)) return true;

    // Check if name starts with word followed by uppercase or end
    if (std.mem.startsWith(u8, name, word)) {
        if (word.len == name.len) return true;
        const next = name[word.len];
        // Word boundary: followed by uppercase (camelCase) or non-alpha
        if (isUppercase(next) or (!isLowercase(next) and !isUppercase(next))) return true;
    }

    // Check if name ends with word preceded by lowercase
    if (std.mem.endsWith(u8, name, word) and name.len > word.len) {
        const prev = name[name.len - word.len - 1];
        if (isLowercase(prev)) return true;
    }

    // Check for word in middle with camelCase boundaries
    var i: usize = 1;
    while (i + word.len <= name.len) {
        if (std.mem.startsWith(u8, name[i..], word)) {
            const prev = name[i - 1];
            // Must be preceded by lowercase (camelCase boundary)
            if (isLowercase(prev)) {
                if (i + word.len == name.len) return true;
                const next = name[i + word.len];
                // Must be followed by uppercase or non-alpha
                if (isUppercase(next) or (!isLowercase(next) and !isUppercase(next))) return true;
            }
        }
        i += 1;
    }

    return false;
}

/// Returns true if the identifier is a primitive type (e.g., i32, u8, f64, bool, etc.)
/// Builtins that return a type (ziglint's `TypeResolver.isTypeReturningBuiltin`).
fn isTypeReturningBuiltin(name: []const u8) bool {
    const builtins = [_][]const u8{
        "@This",  "@TypeOf",  "@Vector",    "@Frame", "@EnumLiteral",
        "@Int",   "@Pointer", "@Struct",    "@Enum",  "@Union",
        "@Tuple", "@Fn",      "@FieldType", "@Type",
    };
    for (builtins) |b| {
        if (std.mem.eql(u8, name, b)) return true;
    }
    return false;
}

fn isPrimitiveType(name: []const u8) bool {
    const primitives = [_][]const u8{
        "bool",     "true",         "false",          "null",        "undefined",
        "noreturn", "void",         "anyopaque",      "anyerror",    "anytype",
        "anyframe", "comptime_int", "comptime_float", "isize",       "usize",
        "c_char",   "c_short",      "c_ushort",       "c_int",       "c_uint",
        "c_long",   "c_ulong",      "c_longlong",     "c_ulonglong", "c_longdouble",
        "f16",      "f32",          "f64",            "f80",         "f128",
    };
    for (primitives) |p| {
        if (std.mem.eql(u8, name, p)) return true;
    }
    // Check for integer types: i{N}, u{N} where N is digits
    if (name.len >= 2 and (name[0] == 'i' or name[0] == 'u')) {
        for (name[1..]) |c| {
            if (c < '0' or c > '9') return false;
        }
        return true;
    }
    return false;
}

fn isTypeAlias(self: *Linter, var_decl: Ast.full.VarDecl) bool {
    const init_node = var_decl.ast.init_node.unwrap() orelse return false;

    const tag = self.tree.nodeTag(init_node);
    return switch (tag) {
        .identifier => blk: {
            const token = self.tree.tokenSlice(self.tree.nodeMainToken(init_node));
            break :blk std.mem.eql(u8, token, "type") or isPascalCase(token) or isPrimitiveType(token);
        },
        .field_access => blk: {
            const data = self.tree.nodeData(init_node).node_and_token;
            const field_name = self.tree.tokenSlice(data[1]);
            break :blk isPascalCase(field_name);
        },
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => blk: {
            const token = self.tree.tokenSlice(self.tree.nodeMainToken(init_node));
            break :blk std.mem.eql(u8, token, "@import") or isTypeReturningBuiltin(token);
        },
        .call_one, .call_one_comma => blk: {
            // Check if calling a PascalCase function (type constructor)
            const callee = self.tree.nodeData(init_node).node_and_opt_node[0];
            const callee_tag = self.tree.nodeTag(callee);
            if (callee_tag == .identifier) {
                const fn_name = self.tree.tokenSlice(self.tree.nodeMainToken(callee));
                break :blk isPascalCase(fn_name);
            } else if (callee_tag == .field_access) {
                const data = self.tree.nodeData(callee).node_and_token;
                const field_name = self.tree.tokenSlice(data[1]);
                break :blk isPascalCase(field_name);
            }
            break :blk false;
        },
        .call, .call_comma => blk: {
            // Check if calling a PascalCase function (type constructor)
            const callee = self.tree.nodeData(init_node).node_and_extra[0];
            const callee_tag = self.tree.nodeTag(callee);
            if (callee_tag == .identifier) {
                const fn_name = self.tree.tokenSlice(self.tree.nodeMainToken(callee));
                break :blk isPascalCase(fn_name);
            } else if (callee_tag == .field_access) {
                const data = self.tree.nodeData(callee).node_and_token;
                const field_name = self.tree.tokenSlice(data[1]);
                break :blk isPascalCase(field_name);
            }
            break :blk false;
        },
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        .error_set_decl,
        .merge_error_sets,
        // Type expressions
        .array_type,
        .array_type_sentinel,
        .ptr_type_aligned,
        .ptr_type_sentinel,
        .ptr_type,
        .ptr_type_bit_range,
        .optional_type,
        .error_union,
        .fn_proto,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto_simple,
        => true,
        .block_two,
        .block_two_semicolon,
        .block,
        .block_semicolon,
        .@"if",
        .if_simple,
        .@"switch",
        .switch_comma,
        => blk: {
            // These expressions can return either types or values.
            // Use PascalCase name as heuristic for type alias.
            const name_token = var_decl.ast.mut_token + 1;
            const name = self.tree.tokenSlice(name_token);
            break :blk isPascalCase(name);
        },
        else => false,
    };
}

/// Checks if the variable declaration is a function alias (assigning a camelCase identifier).
/// Function aliases are allowed to use camelCase names.
fn isFunctionAlias(self: *Linter, var_decl: Ast.full.VarDecl) bool {
    const init_node = var_decl.ast.init_node.unwrap() orelse return false;
    const tag = self.tree.nodeTag(init_node);
    return switch (tag) {
        .identifier => blk: {
            const token = self.tree.tokenSlice(self.tree.nodeMainToken(init_node));
            break :blk isCamelCase(token);
        },
        .field_access => blk: {
            const data = self.tree.nodeData(init_node).node_and_token;
            const field_name = self.tree.tokenSlice(data[1]);
            break :blk isCamelCase(field_name);
        },
        else => false,
    };
}

fn isCamelCase(name: []const u8) bool {
    if (name.len == 0) return false;
    // Must start with lowercase letter
    if (name[0] < 'a' or name[0] > 'z') return false;
    // No underscores allowed
    for (name) |c| {
        if (c == '_') return false;
    }
    return true;
}

fn isIgnored(self: *Linter, line: usize, rule: rules.Rule) bool {
    if (!self.has_ignores) return false;
    if (self.line_starts.items.len == 0) {
        self.line_starts.append(self.allocator, 0) catch return false;
        for (self.source, 0..) |c, i| {
            if (c == '\n') self.line_starts.append(self.allocator, @intCast(i + 1)) catch return false;
        }
    }
    return ignoredAt(self.source, self.line_starts.items, line, rule);
}

/// Whether 0-based line `line` of `source`, whose lines start at
/// `line_starts`, is covered by a `// ziglint-ignore:` comment naming
/// `rule`: on the line itself, or on the run of `//` lines right above it.
pub fn ignoredAt(source: []const u8, line_starts: []const u32, line: usize, rule: rules.Rule) bool {
    // Check inline comment on current line
    if (lineHasIgnore(lineText(source, line_starts, line), rule)) return true;

    // Check preceding comment-only lines (walk back through consecutive comments)
    var check_line = line;
    while (check_line > 0) {
        check_line -= 1;
        const prev_line = lineText(source, line_starts, check_line);
        const trimmed = std.mem.trimStart(u8, prev_line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "//")) break;
        if (lineHasIgnore(prev_line, rule)) return true;
    }

    return false;
}

fn lineHasIgnore(line_text: []const u8, rule: rules.Rule) bool {
    if (std.mem.find(u8, line_text, "// ziglint-ignore:")) |idx| {
        const ignore_part = line_text[idx + 18 ..];
        if (std.mem.find(u8, ignore_part, rule.code()) != null) return true;
    }
    return false;
}

fn lineText(source: []const u8, line_starts: []const u32, line: usize) []const u8 {
    if (line >= line_starts.len) return "";
    const line_start = line_starts[line];
    const line_end = std.mem.findScalarPos(u8, source, line_start, '\n') orelse source.len;
    return source[line_start..line_end];
}

/// Z024: every line longer than `max_len` bytes. Its context is the
/// line's length in decimal; the report step adds the limit.
fn checkLineLength(self: *Linter, max_len: u32) void {
    var line_num: usize = 0;
    var line_start: usize = 0;

    while (line_start <= self.source.len) {
        const end = std.mem.findScalarPos(u8, self.source, line_start, '\n');
        // The last line counts only if it is not empty (not terminated with a newline).
        if (end == null and line_start == self.source.len) break;
        const line_end = end orelse self.source.len;
        const line_len = sourceLineByteLength(self.source, line_start, line_end);
        if (line_len > max_len) {
            if (self.allocator.print("{}", .{line_len})) |context| {
                if (!self.isIgnored(line_num, .Z024)) self.diagnostics.append(self.allocator, .{
                    .line = @intCast(line_num + 1),
                    .column = max_len + 1,
                    .offset = @intCast(line_start),
                    .rule = .Z024,
                    .context = context,
                    // ziglint-ignore: Z026 -- on OOM the diagnostic is dropped, not the pass
                }) catch {};
            } else |_| {}
        }
        line_num += 1;
        line_start = line_end + 1;
    }
}

/// Z024 for a limit below `long_line_min`, which the facts do not cover:
/// the lines of `source` longer than `max_len`, not ignored, as findings.
pub fn longLines(arena: std.mem.Allocator, source: [:0]const u8, max_len: u32) []const Diagnostic {
    var self: Linter = .{ .allocator = arena, .source = source, .path = "", .tree = undefined };
    self.has_ignores = std.mem.find(u8, source, "// ziglint-ignore:") != null;
    self.checkLineLength(max_len);
    return self.diagnostics.items;
}

fn sourceLineByteLength(source: []const u8, start: usize, end: usize) usize {
    const content_end = if (end > start and source[end - 1] == '\r') end - 1 else end;
    return content_end - start;
}

/// Void-map bookkeeping (seen identifiers, public/imported types). The lint
/// pass must survive OOM, so put failures are swallowed here, once.
fn track(self: *Linter, map: *std.StringHashMapUnmanaged(void), key: []const u8) void {
    // ziglint-ignore: Z026 -- bookkeeping must survive OOM mid-lint
    map.put(self.allocator, key, {}) catch {};
}

/// Diagnostic-context strings live in the arena; registering one must
/// survive OOM the same way.
fn trackContext(self: *Linter, context: []const u8) void {
    // ziglint-ignore: Z026 -- bookkeeping must survive OOM mid-lint
    self.allocated_contexts.append(self.allocator, context) catch {};
}

fn report(self: *Linter, loc: Ast.Location, rule: rules.Rule, context: []const u8) void {
    if (self.isIgnored(loc.line, rule)) return;

    self.diagnostics.append(self.allocator, .{
        .line = @intCast(loc.line + 1),
        .column = @intCast(loc.column + 1),
        .offset = @intCast(loc.line_start + loc.column),
        .rule = rule,
        .context = context,
        // ziglint-ignore: Z026 -- on OOM the diagnostic is dropped, not the pass
    }) catch {};
}

/// The findings as the frontend caches them (`Frontend.lintFacts`), by the
/// file's content and name: `facts_magic`, then per finding its rule,
/// line, column, offset and context length as little-endian u32s, and the
/// context.
pub const facts_magic = "bslint01";

pub fn encode(gpa: std.mem.Allocator, findings: []const Diagnostic) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, facts_magic);
    for (findings) |f| {
        for ([_]u32{ @backingInt(f.rule), f.line, f.column, f.offset, @intCast(f.context.len) }) |v| {
            try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
        }
        try out.appendSlice(gpa, f.context);
    }
    return out.toOwnedSlice(gpa);
}

/// The findings `encode` wrote into `bytes`, their contexts pointing into
/// it; null if `bytes` is not such a record.
pub fn decode(arena: std.mem.Allocator, bytes: []const u8) !?[]const Diagnostic {
    if (!std.mem.startsWith(u8, bytes, facts_magic)) return null;
    var list: std.ArrayList(Diagnostic) = .empty;
    var pos: usize = facts_magic.len;
    while (pos < bytes.len) {
        if (bytes.len - pos < 20) return null;
        var v: [5]u32 = undefined;
        for (&v, 0..) |*x, i| x.* = std.mem.readInt(u32, bytes[pos + 4 * i ..][0..4], .little);
        pos += 20;
        if (bytes.len - pos < v[4]) return null;
        const rule = std.enums.fromInt(rules.Rule, v[0]) orelse return null;
        try list.append(arena, .{ .rule = rule, .line = v[1], .column = v[2], .offset = v[3], .context = bytes[pos..][0..v[4]] });
        pos += v[4];
    }
    return list.items;
}
