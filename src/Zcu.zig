//! Semantic analysis state for one compilation: analysis units, their
//! dependencies, namespaces, and diagnostics. Drives Sema over the units
//! reachable from the root file.
//!
//! The skeleton analyzes on one thread. Units resolve on demand through the
//! `ensure*` functions, which are also where a unit's state lives; that state
//! is the synchronization point once function bodies run in parallel.

const std = @import("std");
const frontend = @import("frontend");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Ast = frontend.Ast;
const Zir = frontend.Zir;

const Frontend = @import("Frontend.zig");
const Language = @import("language.zig").Language;
const compiler_rt_exports = @import("compiler_rt_exports.zig");
const cache = @import("cache.zig");
const InternPool = @import("InternPool.zig");
const Ir = @import("Ir.zig");
const Replay = @import("Replay.zig");
const Sema = @import("Sema.zig");
const diag = @import("diag.zig");
const print = @import("Ir/print.zig");
const Incremental = @import("Incremental.zig");
const cpu_mod = @import("cpu.zig");
const Linter = @import("lint/Linter.zig");
const lint_rules = @import("lint/rules.zig");

const Zcu = @This();

gpa: Allocator,
io: Io,
fe: *Frontend,
/// The Zig language the compilation's sources are in
/// (`Frontend.syntax_language`), fixed for its lifetime.
language: Language,
ip: InternPool,
/// Root struct type of each file, `.none` until imported.
file_root_types: std.ArrayList(InternPool.Index) = .empty,
namespaces: std.ArrayList(Namespace) = .empty,
/// Dependencies recorded per unit by `Sema.declareDependency`. Nothing
/// persists them yet; the on-disk cache (milestone 6) will.
deps: std.array_hash_map.Auto(AnalUnit, []const Dependee) = .empty,
/// For units some of whose `deps` only the comptime evaluator's lowering
/// read (see "Comptime evaluator" in docs/slop/architecture.md): the indices of
/// those, ascending. Such an edge counts for invalidation, but the unit
/// does not resolve its dependee itself. Arena-allocated.
conditional_deps: std.AutoHashMapUnmanaged(AnalUnit, []const u32) = .empty,
/// What each unit whose analysis failed had read before it did, without
/// conditional dependencies (`recordFailedDeps`): the units a failing
/// build reaches through it, for `Replay.errorsReached`. Arena-allocated.
failed_deps: std.AutoHashMapUnmanaged(AnalUnit, []const Dependee) = .empty,
/// Empty dependee maps with their capacity kept, for Sema's per-unit sets
/// (`Sema.takeDepMap`), so that each of the many units does not grow a
/// fresh one. Per analysis thread once Sema runs in parallel.
dep_maps: std.ArrayList(Incremental.DependeeMap) = .empty,
/// Recently interned strings by the address of their bytes, for
/// `Sema.getString` (allocated on first use). Sema-only.
string_cache: []StringCacheEntry = &.{},
/// The pointer `Sema.navRef` makes to each resolved declaration, which
/// code takes again and again. Sema-only.
nav_ptrs: std.AutoHashMapUnmanaged(InternPool.NavIndex, InternPool.Index) = .empty,
/// The container types each tuple type holds by value, through arrays,
/// optionals, error unions and tuples, each once, in the order a walk of
/// its fields first meets them (`Sema.tupleContainers`): a ZON import's
/// type can be a tuple of thousands of tuples. Sema-only.
tuple_containers: std.AutoHashMapUnmanaged(InternPool.Index, []const InternPool.Index) = .empty,
/// The const pointer `Sema.analyzeRef` makes to each comptime-known value:
/// code evaluated again and again takes the same values' addresses
/// (`@typeInfo(T).@"struct".fields`, a method call on a constant).
/// Sema-only.
uav_refs: std.AutoHashMapUnmanaged(InternPool.Index, InternPool.Index) = .empty,
/// `*const T` for each `T` that `Sema.analyzeRef` took a reference of.
/// Sema-only.
ref_ptr_types: std.AutoHashMapUnmanaged(InternPool.Index, InternPool.Index) = .empty,
/// Analysis state of runtime function bodies.
funcs: std.array_hash_map.Auto(InternPool.Index, FuncState) = .empty,
func_queue: std.ArrayList(InternPool.Index) = .empty,
/// Declarations whose address code took (`ensureNavTy`), whose values
/// `analyzeAll` resolves later, as upstream queues a `nav_val` unit.
nav_queue: std.ArrayList(InternPool.NavIndex) = .empty,
/// Structs whose layout this build resolved and that have non-`comptime`
/// field defaults: their `struct_defaults` units, which `analyzeAll`
/// analyzes whether or not anything reads a default (`queueDefaults`).
defaults_queue: std.ArrayList(InternPool.Index) = .empty,
/// Nonzero while something is resolved that may be done without (an
/// inlining decision a replay makes out of order, `Replay`'s
/// `func_inline`): a dependency loop then ends that instead of being
/// reported (`error.Speculation`).
speculating: u32 = 0,
/// Whether the check of `std.lang.panic`'s handlers is running or found a
/// bad one (`Sema.checkPanicHandlers`); a good result is memoized.
panic_handlers: enum { idle, checking, bad } = .idle,
/// What each unit in progress asked for, innermost last: the edges a
/// dependency loop's error reports (`Sema.failDepLoop`).
dep_stack: std.ArrayList(Sema.DepFrame) = .empty,
/// The dependencies a unit's first phase recorded when it ran on its own
/// (`ensureNavTy`), which the rest of the unit declares first instead of
/// analyzing the phase again.
phase_deps: std.AutoHashMapUnmanaged(AnalUnit, PhaseDeps) = .empty,
/// Which unit queued which function (`queueFuncFrom`), for the on-disk
/// cache: a unit loaded from it queues them again.
func_refs: std.array_hash_map.Auto(FuncRef, void) = .empty,
/// For each analyzed unit, the first unit that referred to it and where:
/// the reference trace of its errors.
referenced_by: std.AutoHashMapUnmanaged(AnalUnit, Reference) = .empty,
next_func: usize = 0,
/// `BS_SCHED_FUZZ=sema:<seed>`: `analyzeAll` takes its roots and queues
/// in a random order, and a random item of the declarations, defaults and
/// functions queued, as parallel analysis would. The cache's records must
/// not change, only the link order (`BS_CACHE_VERIFY=full` compares them).
sched_rng: ?std.Random.DefaultPrng = null,
/// The inlinable functions (Emit, `codegen/inline.zig`): their size and
/// the `func_inline` result hash, and the functions that are not
/// inlinable but return a slice of an argument's length (`ret_len`). A
/// function not here is not inlinable and has no `ret_len`.
inline_results: std.AutoHashMapUnmanaged(InternPool.Index, InlineResult) = .empty,
/// The `func_inline` result of a function that is not inlinable is this
/// `^ 1`: the inlining variant (`Emit.inlineSalt`).
inline_salt: cache.Hash = 0,
/// `std.lang.returnError` once Sema has emitted a call to it (`.none`
/// before): a body whose only kept call is to it still inlines
/// (`codegen/inline.zig`).
return_error: InternPool.Index = .none,
/// Function bodies analyzed out of queue order (to resolve an inferred
/// error set), waiting to be passed to the sink.
ready_irs: std.ArrayList(Ir) = .empty,
/// `comptime` declarations, analyzed once each.
comptime_decls: std.array_hash_map.Auto(ComptimeDecl, enum { queued, done }) = .empty,
/// Memoized comptime calls, keyed by `Sema.comptimeCallKey`.
comptime_memo: std.AutoHashMapUnmanaged(InternPool.Hash, Memo) = .empty,
/// The comptime evaluator's state of each function called at comptime,
/// and of each generic function per specialization (see `Sema.bcCall`).
/// In memory only, like function IR.
comptime_bodies: std.AutoHashMapUnmanaged(InternPool.Hash, ComptimeBody) = .empty,
/// Comptime loops the evaluator does not take over from the walker (see
/// `Sema.bcOsr`), by file and the first instruction of the loop body.
comptime_osr_off: std.AutoHashMapUnmanaged(OsrLoop, void) = .empty,
/// Whether an aggregate value refers to a comptime allocation, cached for
/// `Sema.refersToComptimeAlloc`: comptime calls check every argument, and
/// large tables are passed again and again. A pure function of the value.
comptime_alloc_refs: std.AutoHashMapUnmanaged(InternPool.Index, bool) = .empty,
/// The value of each string literal (`Sema.stringLiteral`), by its bytes,
/// which point into the interned string with the sentinel. A pure cache:
/// the walker evaluates the same literals again and again.
string_literals: std.StringHashMapUnmanaged(InternPool.Index) = .empty,
/// Walker runs of a function before it is lowered for the comptime
/// evaluator; 0 turns the evaluator off (`BS_COMPTIME_EVAL`).
comptime_eval_threshold: u32 = 4,
/// `BS_UNIT_TIMING=n`: analysis time per unit, for `printUnitTiming`.
unit_timing: ?UnitTiming = null,
/// Errors each function instance returns, for inferred error sets.
/// Arena-allocated.
inferred_errors: std.AutoHashMapUnmanaged(InternPool.Index, []const InternPool.String) = .empty,
/// Function instances whose inferred error set is `anyerror`.
anyerror_ies: std.AutoHashMapUnmanaged(InternPool.Index, void) = .empty,
/// The largest `@setEvalBranchQuota` of the callers that instantiated each
/// generic function instance, which its body runs with, as upstream.
/// Not a recorded dependency: an edit that lowers a caller's quota leaves
/// a cached instance green (upstream's order dependence, ziglang/zig#22410).
branch_quotas: std.AutoHashMapUnmanaged(InternPool.Index, u32) = .empty,
exports: std.ArrayList(Export) = .empty,
/// Container-level assembly (`comptime { asm (...); }`), in analysis
/// order, which Emit assembles into the module's code
/// (src/codegen/global_asm.zig).
global_asm: std.ArrayList(GlobalAsm) = .empty,
/// Files read by `@embedFile`, each once; `Dependee.embed_file` indexes it.
embed_files: std.array_hash_map.String(EmbedFile) = .empty,
/// Zig 0.16's `@cImport`: translates C source for a module's C flags
/// (main sets it, to `TranslateC.cImport`); null where nothing can.
c_importer: ?CImporter = null,
/// What this build's `@cImport`s translated, in analysis order. Files
/// that no dependency records were read: a build that imports C is not
/// recorded in the on-disk cache (main's `cimport` marker).
c_imports: std.ArrayList(CImport) = .empty,
/// translate-c's errors (ErrorBundle message bodies) of the failed
/// `@cImport`s, reported after Sema's, as upstream's.
c_import_errors: std.ArrayList([]const u8) = .empty,
/// compiler_rt functions that CodeGen calls and the functions and
/// variables the link resolves names to, by the stable key of their
/// declaration; `analyzeAll` resolves each to its declaration (`.none`
/// until then) and queues a function's body.
rt_helpers: std.array_hash_map.String(InternPool.NavIndex) = .empty,
/// `bs test`: collect the main module's tests into `builtin.test_functions`.
is_test: bool = false,
/// `-fsingle-threaded`: `threadlocal` variables are ordinary globals, as
/// upstream (std's start code sets up no thread pointer then).
single_threaded: bool = false,
/// `-mcpu`: the CPU code is generated for, whose features say which vector
/// operations the backend lowers natively (`codegen/vector.zig`).
cpu: std.Target.Cpu = cpu_mod.baseline,
/// `-lc`: `extern "c"` declarations may be used (`Sema.checkExternLibName`).
link_libc: bool = false,
/// `-lc++`: `extern "c++"` and `extern "unwind"` declarations may be used.
link_libcpp: bool = false,
/// `bs test --test-filter`: keep only named tests whose fqn contains one.
test_filters: []const []const u8 = &.{},
/// Test declarations to run, in discovery order.
test_functions: std.ArrayList(InternPool.NavIndex) = .empty,
errors: std.ArrayList(ErrorMsg) = .empty,
/// `@compileLog` lines in analysis order (`Sema.zirCompileLog`). Like an
/// error, any fails the build.
compile_logs: std.ArrayList(CompileLog) = .empty,
/// The files the project's lint config covers, a bit per file index;
/// empty with lint off. Sema checks the ziglint rules it answers in code
/// from these files (docs/slop/ziglint-in-bs.md).
lint_covered: std.bit_set.Dynamic = .{},
/// Those rules' findings, in analysis order, possibly repeated (an
/// instance of a generic function finds what another did). Like an error,
/// any fails the build, after analysis.
lint_findings: std.ArrayList(LintFinding) = .empty,
/// The deprecated declarations of each file Z011 looked one up in
/// (`deprecation`), in `deprecations_arena`, under `deprecations_mutex`:
/// the cache's record reads them on every core.
deprecations: std.AutoHashMapUnmanaged(u32, []const Linter.Deprecation) = .empty,
deprecations_arena: std.heap.ArenaAllocator,
deprecations_mutex: Io.Mutex = .init,
/// Which units' analysis evaluated a container declaration or `@import`
/// whose namespace has `effects` (`Sema.createContainerType`). The cache
/// makes an edit build analyze such a unit again rather than load it,
/// unless loading it makes the type anyway (see `Incremental.record`).
effect_uses: std.array_hash_map.Auto(EffectUse, void) = .empty,
/// Each unit's candidate names for the types it made (`offerName`),
/// including those a memo hit made again, for the cache: an edit build
/// offers the loaded units' candidates again (docs/slop/architecture.md, "Type
/// names"). The value is the template, in `arena`.
name_offers: std.array_hash_map.Auto(NameOffer, InternPool.Template) = .empty,
/// Which types' names each unit's analysis rendered into a value
/// (`@typeName`), for the cache, which must analyze such a unit again if a
/// name it read changed.
name_reads: std.array_hash_map.Auto(NameRead, void) = .empty,
/// Whether a name that analysis read changed afterwards (`offerName`).
name_read_changed: bool = false,
/// In a build redone because one did, the final names of the first
/// attempt, by type stable hash; types get them as `TypeName.pinned`.
name_pins: ?*const NamePins = null,
/// In an edit build, the last build's results: each `ensure*` and the
/// function queue load a unit from it, if it is green, before analyzing it.
replay: ?*Replay = null,
/// Owns diagnostic text and namespace tables.
arena: std.heap.ArenaAllocator,

/// A type's name as one creator would give it (`InternPool.TypeName`).
pub const NameCandidate = struct {
    creator: InternPool.Hash,
    template: InternPool.Template,
};

pub const NameOffer = struct { unit: AnalUnit, ty: InternPool.Index, creator: InternPool.Hash };
pub const NameRead = struct { unit: AnalUnit, ty: InternPool.Index };
pub const NamePins = std.AutoHashMapUnmanaged(InternPool.Hash, []const u8);

pub const Export = struct {
    target: union(enum) {
        nav: InternPool.NavIndex,
        /// An anonymous constant, as in `@export(&comptime_value, ...)`.
        uav: InternPool.Index,
    },
    name: InternPool.String,
    /// The unit whose analysis made the export (`@export`), or null for an
    /// `export` declaration, which the namespace scan makes.
    unit: ?AnalUnit,
    /// From `@export`'s options; an `export` declaration is strong and
    /// default. Objects and shared objects write them (see
    /// "Position-independent code" in docs/slop/architecture.md).
    linkage: std.lang.GlobalLinkage = .strong,
    visibility: std.lang.SymbolVisibility = .default,
    /// Where the export is made, for a collision's error: the `@export`
    /// call, or the `export` keyword of the declaration, token `keyword`
    /// of `node` (after `pub`), as upstream.
    file: u32,
    node: Ast.Node.Index,
    keyword: ?u1 = null,

    fn span(x: Export, zcu: *Zcu) !Ast.Span {
        const tree = try zcu.fe.tree(@fromBackingInt(x.file));
        const k = x.keyword orelse return tree.nodeToSpan(x.node);
        return tree.tokenToSpan(tree.firstToken(x.node) + k);
    }
};

/// A block of container-level assembly. Like an `@export`, an effect of
/// the unit whose analysis ran it, which the cache analyzes again rather
/// than load (`Incremental`).
pub const GlobalAsm = struct {
    unit: AnalUnit,
    source: InternPool.String,
    /// The `asm` expression, where its errors go.
    file: u32,
    span: Ast.Span,
};

pub const FuncState = enum { queued, in_progress, done, failed };

pub const EffectUse = struct { unit: AnalUnit, ty: InternPool.Index };

pub const FuncRef = struct { from: AnalUnit, func: InternPool.Index };
pub const Reference = struct { from: AnalUnit, file: u32, src: Sema.Src };

/// A function body lowered to IR for the comptime evaluator, with the
/// dependencies its lowering declared, which every unit that runs it
/// declares too.
/// A memoized comptime call's result, with the dependencies the call
/// declared, which a unit that reuses the result declares too.
/// Arena-allocated.
pub const Memo = struct {
    result: InternPool.Index,
    deps: []const MemoDep,
    /// The container types with effects the call evaluated, which a unit
    /// that reuses the result notes too (`effect_uses`).
    effects: []const InternPool.Index,
    /// The functions the call referred to, which a unit that reuses the
    /// result refers to too (`func_refs`).
    funcs: []const InternPool.Index,
    /// The names the call offered, which a unit that reuses the result
    /// offers too (`name_offers`).
    names: []const MemoName = &.{},
    /// The types whose names the call read (`name_reads`).
    name_reads: []const InternPool.Index = &.{},
    /// The backward branches the call took, and the largest
    /// `@setEvalBranchQuota` it ran, which a hit counts and applies.
    branch_count: u32 = 0,
    branch_quota: u32 = 0,
};

/// A name offer (`name_offers`), its template in `arena`.
pub const MemoName = struct { ty: InternPool.Index, creator: InternPool.Hash, template: InternPool.Template };

pub const MemoDep = struct {
    dependee: Dependee,
    /// Read only by a lowering for the comptime evaluator.
    conditional: bool,
};

pub const Bytecode = struct {
    ir: Ir,
    /// Every unit that runs the body declares these as conditional
    /// dependencies; its `comptime_dep` instructions declare the ones the
    /// run reaches as plain dependencies.
    deps: []const Dependee,
    /// The indices of the `deps` no `comptime_dep` instruction marks (read
    /// outside any runtime block of the body), which every run declares as
    /// plain dependencies.
    entry_deps: []const u32,
    /// The container types with effects lowering evaluated (see
    /// `effect_uses`): a run notes those its `comptime_effect`
    /// instructions reach, and those at `entry_effects` (evaluated outside
    /// any runtime block of the body).
    effects: []const InternPool.Index,
    entry_effects: []const u32,
    /// For a generic function's specialization, per parameter: its type,
    /// and its value if the body has it comptime-known. Empty otherwise.
    params: []const BytecodeParam,
    /// Instructions whose values the evaluator keeps in its frame: an
    /// `alloc` used only by `load` and `store` to it, which stays out of
    /// comptime memory, and an `*_with_overflow` read only by
    /// `struct_field_val`, which is never interned as a tuple.
    in_frame: std.bit_set.Dynamic,
    /// Per instruction: the integer type of up to 64 bits its value has
    /// (for a frame-kept `alloc`, the value it holds; for a frame-kept
    /// `*_with_overflow`, the wrapped result), which the evaluator holds
    /// unboxed; `ty == .none` for other values.
    ints: []const BcInt,

    pub fn destroy(b: *Bytecode, gpa: Allocator) void {
        b.ir.deinit(gpa);
        gpa.free(b.ints);
        gpa.free(b.deps);
        gpa.free(b.entry_deps);
        gpa.free(b.effects);
        gpa.free(b.entry_effects);
        gpa.free(b.params);
        b.in_frame.deinit(gpa);
        gpa.destroy(b);
    }
};

pub const OsrLoop = struct { file: u32, inst: u32 };

/// An integer type of 1 to 64 bits, for the evaluator's unboxed integers.
pub const BcInt = struct {
    ty: InternPool.Index = .none,
    bits: u8 = 0,
    signed: bool = false,

    /// The value whose two's complement's low 64 bits are `raw`.
    pub fn value(t: BcInt, raw: u64) i128 {
        return if (t.signed) @as(i64, @bitCast(raw)) else raw;
    }

    /// `x` wrapped to the type.
    pub fn wrap(t: BcInt, x: i128) i128 {
        const shift: u7 = @intCast(128 - @as(u8, t.bits));
        const low = @as(u128, @bitCast(x)) << shift;
        return if (t.signed) @as(i128, @bitCast(low)) >> shift else @intCast(low >> shift);
    }
};

pub const BytecodeParam = struct {
    ty: InternPool.Index,
    /// `.none` for a parameter the body takes as an `arg`.
    val: InternPool.Index,
};

pub const ComptimeBody = union(enum) {
    /// Not lowered yet: the walker ran the function `runs` times, and
    /// lowering is (re)tried at `next_try` runs, or once declaration
    /// `blocker` is resolved.
    cold: struct { runs: u32, next_try: u32, blocker: InternPool.NavIndex = .none },
    ready: *Bytecode,
    /// The evaluator does not run this function (any more: a run aborted
    /// where the walker succeeded; runs still in progress keep the body).
    off: ?*Bytecode,
};

pub const ComptimeDecl = struct {
    file: u32,
    inst: Zir.Inst.Index,
    namespace: u32,
    /// Position among the namespace's `comptime` declarations; with the
    /// namespace's key, the unit's stable key.
    ordinal: u32,
};

/// Sema's unit of work, caching, and parallelism.
pub const AnalUnit = union(enum) {
    nav_val: InternPool.NavIndex,
    type_layout: InternPool.Index,
    func: InternPool.Index,
    comptime_decl: ComptimeDecl,
    /// The default values of a declared struct's non-`comptime` fields,
    /// evaluated after its layout, which they may read.
    struct_defaults: InternPool.Index,
};

/// What a unit read from another unit. Recorded only through
/// `Sema.declareDependency`.
pub const Dependee = union(enum) {
    /// The value of a declaration (for a function: its signature, since the
    /// function value does not depend on its body).
    nav_val: InternPool.NavIndex,
    /// The type of a declaration.
    nav_ty: InternPool.NavIndex,
    /// The fields and layout of a struct type.
    type_layout: InternPool.Index,
    /// The body of a function, read by comptime calls.
    func_body: InternPool.Index,
    /// The resolved inferred error set of a function instance.
    func_ies: InternPool.Index,
    /// Whether a function instance is inlinable, and its body if so
    /// (`inline_results`). Recorded by Emit for each call it may inline.
    func_inline: InternPool.Index,
    /// Whether namespace `namespace` has a declaration named `name`. Recorded
    /// by name lookups and `@hasDecl`, so adding an unrelated declaration
    /// does not invalidate the unit.
    namespace_name: struct { namespace: u32, name: InternPool.String },
    /// The names of all declarations of namespace `namespace` (`@typeInfo`
    /// lists them).
    namespace: u32,
    /// The contents of `embed_files[index]` (`@embedFile`).
    embed_file: u32,
    /// The default values of a struct's non-`comptime` fields.
    struct_defaults: InternPool.Index,
    /// Whether a declaration's doc comment marks it deprecated, and how
    /// (`deprecation`): Z011 reads it, and doc comments are not in ZIR,
    /// so no source hash covers them.
    deprecation: InternPool.NavIndex,
};

/// A file read by `@embedFile`.
pub const EmbedFile = struct {
    /// Stable key: the module's name and the file's path in it,
    /// `module:sub/path`.
    key: []const u8,
    module: Frontend.Module.Index,
    sub_path: []const u8,
    /// `cache.hash` of the contents.
    hash: u128,
    /// Arena-allocated, without a sentinel.
    bytes: []const u8,
};

pub const Namespace = struct {
    file: u32,
    /// The nearest lexically enclosing namespace that is not inside a
    /// function, or `none` for a file's root. Lookups from this namespace
    /// continue there: AstGen tunnels every reference to a declaration of
    /// a namespace inside a function (`maybe_generic`) through a capture,
    /// so a nested type never finds a name in such a namespace by walking
    /// up. Skipping them makes the parent the same whichever instance of
    /// an enclosing generic type created the type (docs/slop/architecture.md,
    /// "Type names").
    parent: u32,
    /// Whether the type's ZIR is inside a function declaration (or test),
    /// as AstGen's `within_fn`.
    in_fn: bool = false,
    /// The type it belongs to, whose name prefixes its declarations'.
    owner_type: InternPool.Index,
    /// Stable key prefix of declarations in this namespace.
    key: []const u8,
    /// `key` and the separator before a declaration's name: its
    /// declarations' keys are this and their names.
    decl_prefix: []const u8,
    /// `key` without the captures of any type, its own or an enclosing
    /// one's: the declarations' path from the file, which the keys of the
    /// types they make extend with those types' own captures
    /// (`Sema.anonTypeKey`).
    path: []const u8,
    /// Named declarations in ZIR order. `.none` for one not created yet:
    /// a declaration's nav is made when it is first looked up
    /// (`Zcu.declNav`), since most of a namespace's declarations are never
    /// used. Exported ones are made at once.
    decls: std.array_hash_map.Auto(InternPool.String, InternPool.NavIndex) = .empty,
    /// The `declaration` instruction of each of `decls`.
    decl_insts: std.ArrayList(Zir.Inst.Index) = .empty,
    /// Whether creating it queued `comptime`, exported or test
    /// declarations: effects beyond the type itself.
    effects: bool = false,

    pub const none = std.math.maxInt(u32);
};

pub const ErrorMsg = struct {
    file: u32,
    span: Ast.Span,
    /// `file` is an `embed_files` index (an imported ZON file).
    embed: bool = false,
    msg: []const u8,
    code: diag.Code = .unclassified,
    notes: []const Note = &.{},
    /// The unit whose analysis failed, whose references `diagnostics`
    /// follows for the reference trace.
    unit: ?AnalUnit = null,
    /// Names close to the one a failed lookup asked for (in `arena`).
    candidates: []const []const u8 = &.{},
    /// What replaced the missing API (`diag.migrationHint`), static.
    hint: ?[]const u8 = null,
    /// A fix in `file` (in `arena`).
    fix: ?diag.RawFix = null,
    /// Rendered without a location (a dependency loop's); `file` and
    /// `span` only sort it.
    no_loc: bool = false,
    /// Reported by code generation (`Emit.addError`), which reports an
    /// error in inline assembly once for each function the inliner copied
    /// it into; `diagnostics` keeps one.
    codegen: bool = false,

    /// `count` repeats of the same note in a row (a recursive call's
    /// frames) render once, as upstream. `call` marks a call-site frame of
    /// the comptime or inline call chain.
    pub const Note = struct { file: u32, span: Ast.Span, msg: []const u8, count: u32 = 1, call: ?diag.CallKind = null, decl: bool = false, embed: bool = false, no_loc: bool = false };
};

/// A translation of Zig 0.16's `@cImport` (`TranslateC.cImport`), in
/// memory that outlives the Zcu.
pub const CImport = struct {
    /// The directory of its `cimport.zig`.
    dir: []const u8,
    /// The files translate-c read, zero-separated, `cimport.h` first.
    inputs: []const u8,
    /// An ErrorBundle message body, when translate-c reported errors.
    errors: ?[]const u8,
};

pub const CImporter = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, c_src: []const u8, cc_argv: []const []const u8) anyerror!CImport,
};

pub fn init(gpa: Allocator, io: Io, fe: *Frontend) !Zcu {
    var zcu: Zcu = .{
        .gpa = gpa,
        .io = io,
        .fe = fe,
        .language = fe.syntax_language,
        .ip = try .init(gpa, io, 1),
        .arena = .init(gpa),
        .deprecations_arena = .init(gpa),
    };
    errdefer zcu.deinit();
    try zcu.file_root_types.appendNTimes(gpa, .none, fe.files.items.len);
    try fe.reserveCImports();
    return zcu;
}

pub fn deinit(zcu: *Zcu) void {
    const gpa = zcu.gpa;
    for (zcu.namespaces.items) |*ns| {
        ns.decls.deinit(gpa);
        ns.decl_insts.deinit(gpa);
    }
    zcu.namespaces.deinit(gpa);
    zcu.deps.deinit(gpa);
    if (zcu.unit_timing) |*t| t.ns.deinit(gpa);
    zcu.func_refs.deinit(gpa);
    zcu.referenced_by.deinit(gpa);
    zcu.funcs.deinit(gpa);
    zcu.func_queue.deinit(gpa);
    zcu.inline_results.deinit(gpa);
    for (zcu.ready_irs.items) |*ir| ir.deinit(gpa);
    zcu.ready_irs.deinit(gpa);
    zcu.comptime_decls.deinit(gpa);
    zcu.comptime_memo.deinit(gpa);
    zcu.conditional_deps.deinit(gpa);
    zcu.failed_deps.deinit(gpa);
    for (zcu.dep_maps.items) |*m| m.deinit(gpa);
    zcu.dep_maps.deinit(gpa);
    gpa.free(zcu.string_cache);
    zcu.nav_queue.deinit(gpa);
    zcu.defaults_queue.deinit(gpa);
    zcu.phase_deps.deinit(gpa);
    zcu.nav_ptrs.deinit(gpa);
    zcu.tuple_containers.deinit(gpa);
    zcu.uav_refs.deinit(gpa);
    zcu.ref_ptr_types.deinit(gpa);
    zcu.effect_uses.deinit(gpa);
    zcu.name_offers.deinit(gpa);
    zcu.name_reads.deinit(gpa);
    var bodies = zcu.comptime_bodies.valueIterator();
    while (bodies.next()) |b| switch (b.*) {
        .ready => |r| r.destroy(gpa),
        .off => |o| if (o) |r| r.destroy(gpa),
        .cold => {},
    };
    zcu.comptime_bodies.deinit(gpa);
    zcu.comptime_alloc_refs.deinit(gpa);
    zcu.string_literals.deinit(gpa);
    zcu.comptime_osr_off.deinit(gpa);
    zcu.inferred_errors.deinit(gpa);
    zcu.anyerror_ies.deinit(gpa);
    zcu.branch_quotas.deinit(gpa);
    zcu.exports.deinit(gpa);
    zcu.global_asm.deinit(gpa);
    zcu.embed_files.deinit(gpa);
    zcu.c_imports.deinit(gpa);
    zcu.c_import_errors.deinit(gpa);
    zcu.rt_helpers.deinit(gpa);
    zcu.test_functions.deinit(gpa);
    zcu.errors.deinit(gpa);
    zcu.dep_stack.deinit(gpa);
    zcu.compile_logs.deinit(gpa);
    zcu.lint_covered.deinit(gpa);
    zcu.lint_findings.deinit(gpa);
    zcu.deprecations.deinit(gpa);
    zcu.deprecations_arena.deinit();
    zcu.file_root_types.deinit(gpa);
    zcu.ip.deinit();
    zcu.arena.deinit();
    zcu.* = undefined;
}

pub const tid: InternPool.Tid = .main;

pub const StringCacheEntry = struct { ptr: usize, string: InternPool.String };

pub const PhaseDeps = struct { deps: []const Dependee, conditional: []const bool };

/// Reads file `sub_path` of module `module` for `@embedFile`, once per
/// compilation; returns its `embed_files` index.
pub fn embedFile(zcu: *Zcu, module: Frontend.Module.Index, sub_path: []const u8) !u32 {
    const arena = zcu.arena.allocator();
    const mod = zcu.fe.module(module);
    const key = try arena.print("{s}:{s}", .{ mod.name, sub_path });
    if (zcu.embed_files.getIndex(key)) |i| return @intCast(i);
    const path = try Io.Dir.path.join(arena, &.{ mod.root_dir, sub_path });
    const bytes = try Io.Dir.cwd().readFileAlloc(zcu.fe.io, path, arena, .unlimited);
    try zcu.embed_files.put(zcu.gpa, key, .{ .key = key, .module = module, .sub_path = key[mod.name.len + 1 ..], .hash = cache.hash(0, bytes), .bytes = bytes });
    return @intCast(zcu.embed_files.count() - 1);
}

pub fn file(zcu: *const Zcu, index: u32) *const Frontend.File {
    return zcu.fe.file(@fromBackingInt(index));
}

/// A ziglint finding of Sema's: rule `rule` at byte `offset` of file
/// `file`, with `Linter.Diagnostic`'s context (in `arena`).
pub const LintFinding = struct { file: u32, offset: u32, rule: lint_rules.Rule, context: []const u8 };

/// Whether the lint config covers file `index`.
pub fn lintCovers(zcu: *const Zcu, index: u32) bool {
    return index < zcu.lint_covered.bit_length and zcu.lint_covered.isSet(index);
}

/// Declaration `nav`'s doc comment if it marks it deprecated (Z011), else
/// empty, from its file's table (`Frontend.deprecations`). Thread-safe.
pub fn deprecation(zcu: *Zcu, nav_index: InternPool.NavIndex) ![]const u8 {
    const nav = zcu.ip.getNav(nav_index);
    const table = table: {
        zcu.deprecations_mutex.lockUncancelable(zcu.io);
        defer zcu.deprecations_mutex.unlock(zcu.io);
        const gop = try zcu.deprecations.getOrPut(zcu.gpa, nav.file);
        if (!gop.found_existing) gop.value_ptr.* = zcu.fe.deprecations(zcu.deprecations_arena.allocator(), @fromBackingInt(nav.file)) catch |err| {
            zcu.deprecations.removeByPtr(gop.key_ptr);
            return err;
        };
        break :table gop.value_ptr.*;
    };
    const line = zcu.file(nav.file).zir.getDeclaration(nav.zir_inst).src_line;
    const i = std.sort.lowerBound(Linter.Deprecation, table, line, struct {
        fn order(l: u32, d: Linter.Deprecation) std.math.Order {
            return std.math.order(l, d.line);
        }
    }.order);
    return if (i < table.len and table[i].line == line) table[i].doc else "";
}

/// The stable unit-key prefix of a file: module name and path within it,
/// with the path left out for the module's root file. That is what
/// `@import("<module>")` names whatever file the module's root is, so that
/// a cache entry recorded by another compilation (a donor, see
/// `Incremental.useDonor`) refers to this compilation's root file: std's
/// `@import("root")` is the main example.
pub fn fileKey(zcu: *Zcu, index: u32) ![]const u8 {
    const f = zcu.file(index);
    const mod = zcu.fe.module(f.module);
    const sub_path = if (std.mem.eql(u8, f.sub_path, mod.root_file)) "" else f.sub_path;
    return zcu.arena.allocator().print("{s}:{s}", .{ mod.name, sub_path });
}

/// The display name of a file's root struct, as upstream renders it: the path
/// within its module, without extension, with slashes as dots.
pub fn fileFqn(zcu: *Zcu, index: u32) ![]const u8 {
    const sub_path = zcu.file(index).sub_path;
    const noext = sub_path[0 .. sub_path.len - Io.Dir.path.extension(sub_path).len];
    const fqn = try zcu.arena.allocator().dupe(u8, noext);
    std.mem.replaceScalar(u8, fqn, '/', '.');
    return fqn;
}

/// The root file of module `mod`, if anything loaded it.
pub fn moduleRootFile(zcu: *Zcu, mod: Frontend.Module.Index) ?u32 {
    return zcu.moduleFile(mod, zcu.fe.module(mod).root_file);
}

/// The loaded file `sub_path` of module `mod`, if any.
pub fn moduleFile(zcu: *Zcu, mod: Frontend.Module.Index, sub_path: []const u8) ?u32 {
    var buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const key = std.mem.print(&buf, "{d}:{s}", .{ @backingInt(mod), sub_path }) catch return null;
    const index = zcu.fe.file_map.get(key) orelse return null;
    return @backingInt(index);
}

// ---------------------------------------------------------------------------
// Diagnostics

pub fn addError(zcu: *Zcu, file_index: u32, span: Ast.Span, comptime fmt: []const u8, args: anytype) !void {
    return zcu.addErrorCode(file_index, span, comptime diag.formatCode(fmt), fmt, args);
}

/// `addError` with a code other than its format's (`diag.formatCode`).
pub fn addErrorCode(zcu: *Zcu, file_index: u32, span: Ast.Span, code: diag.Code, comptime fmt: []const u8, args: anytype) !void {
    const msg = try zcu.arena.allocator().print(fmt, args);
    try zcu.errors.append(zcu.gpa, .{ .file = file_index, .span = span, .msg = msg, .code = code });
}

/// Adds an error in embedded file `embed_index` (an imported ZON file).
pub fn addEmbedError(zcu: *Zcu, embed_index: u32, span: Ast.Span, code: diag.Code, comptime fmt: []const u8, args: anytype) !void {
    const msg = try zcu.arena.allocator().print(fmt, args);
    try zcu.errors.append(zcu.gpa, .{ .file = embed_index, .embed = true, .span = span, .msg = msg, .code = code });
}

/// Adds a note in embedded file `embed_index` to the most recent error.
pub fn addEmbedNote(zcu: *Zcu, embed_index: u32, span: Ast.Span, comptime fmt: []const u8, args: anytype) !void {
    try zcu.appendNote(.{ .file = embed_index, .embed = true, .span = span, .msg = try zcu.arena.allocator().print(fmt, args) });
}

/// Adds a note to the most recent error.
pub fn addNote(zcu: *Zcu, file_index: u32, span: Ast.Span, comptime fmt: []const u8, args: anytype) !void {
    try zcu.appendNote(.{ .file = file_index, .span = span, .msg = try zcu.arena.allocator().print(fmt, args) });
}

/// Adds a note pointing at a declaration to the most recent error; it shows
/// the declaration's source line.
pub fn addDeclNote(zcu: *Zcu, file_index: u32, span: Ast.Span, comptime fmt: []const u8, args: anytype) !void {
    try zcu.appendNote(.{ .file = file_index, .span = span, .msg = try zcu.arena.allocator().print(fmt, args), .decl = true });
}

/// Fails on two strong exports of one name, as upstream's
/// `processExports`: an error at the later export, with a note at the
/// first.
pub fn checkExportCollisions(zcu: *Zcu) !void {
    var first: std.AutoHashMapUnmanaged(InternPool.String, usize) = .empty;
    defer first.deinit(zcu.gpa);
    for (zcu.exports.items, 0..) |x, i| {
        if (x.linkage != .strong) continue;
        const gop = try first.getOrPut(zcu.gpa, x.name);
        if (!gop.found_existing) {
            gop.value_ptr.* = i;
            continue;
        }
        const other = zcu.exports.items[gop.value_ptr.*];
        try zcu.addError(x.file, try x.span(zcu), "exported symbol collision: {s}", .{zcu.ip.stringSlice(x.name)});
        try zcu.addNote(other.file, try other.span(zcu), "other symbol here", .{});
    }
}

/// Adds a call-site frame of the comptime or inline call chain to the most
/// recent error.
pub fn addCallFrame(zcu: *Zcu, file_index: u32, span: Ast.Span, kind: diag.CallKind) !void {
    try zcu.appendNote(.{ .file = file_index, .span = span, .msg = switch (kind) {
        .@"inline" => "called inline here",
        .@"comptime" => "called at comptime here",
        .generic => "generic function instantiated here",
    }, .call = kind });
}

pub fn appendNote(zcu: *Zcu, note: ErrorMsg.Note) !void {
    const arena = zcu.arena.allocator();
    const e = &zcu.errors.items[zcu.errors.items.len - 1];
    if (e.notes.len != 0) {
        const last = e.notes[e.notes.len - 1];
        if (last.file == note.file and last.embed == note.embed and last.span.main == note.span.main and std.mem.eql(u8, last.msg, note.msg)) {
            @constCast(&e.notes[e.notes.len - 1]).count += 1;
            return;
        }
    }
    const notes = try arena.alloc(ErrorMsg.Note, e.notes.len + 1);
    @memcpy(notes[0..e.notes.len], e.notes);
    notes[e.notes.len] = note;
    e.notes = notes;
}

fn diagLoc(zcu: *const Zcu, arena: Allocator, paths: diag.Paths, file_index: u32, span: Ast.Span) !diag.Loc {
    const f = zcu.file(file_index);
    return paths.loc(arena, f.display_path, try zcu.fe.source(@fromBackingInt(file_index)), span.start, span.main, span.end, f.module == zcu.fe.module(f.module).builtin_mod);
}

/// `diagLoc` in a Zcu file, or in an embedded file when `embed`.
fn diagLocIn(zcu: *const Zcu, arena: Allocator, paths: diag.Paths, file_index: u32, embed: bool, span: Ast.Span) !diag.Loc {
    if (!embed) return zcu.diagLoc(arena, paths, file_index, span);
    const e = zcu.embed_files.values()[file_index];
    const path = try Io.Dir.path.join(arena, &.{ zcu.fe.module(e.module).root_dir, e.sub_path });
    return paths.loc(arena, path, e.bytes, span.start, span.main, span.end, false);
}

/// One `@compileLog` call's output line, made by `unit` at `span` of `file`.
pub const CompileLog = struct { unit: AnalUnit, file: u32, span: Ast.Span, text: []const u8 };

/// Whether the build failed: an error, or a `@compileLog` call.
pub fn failed(zcu: *const Zcu) bool {
    return zcu.errors.items.len != 0 or zcu.compile_logs.items.len != 0;
}

/// This compilation's errors as diagnostics: AstGen errors of files loaded
/// during analysis first, then Sema's, then `@compileLog`'s.
pub fn diagnostics(zcu: *const Zcu, arena: Allocator, paths: diag.Paths) ![]diag.Diagnostic {
    var out: std.ArrayList(diag.Diagnostic) = .empty;
    for (zcu.fe.late_errors.items) |b| try diag.fromBundle(arena, paths, b, &out);
    // By location, as upstream sorts them, rather than in analysis order,
    // which can change with the order functions are generated in.
    const errors = try arena.dupe(ErrorMsg, zcu.errors.items);
    std.sort.block(ErrorMsg, errors, zcu, struct {
        fn lessThan(z: *const Zcu, a: ErrorMsg, b: ErrorMsg) bool {
            if (a.file != b.file) return std.mem.order(u8, z.file(a.file).display_path, z.file(b.file).display_path) == .lt;
            if (a.span.main != b.span.main) return a.span.main < b.span.main;
            return std.mem.order(u8, a.msg, b.msg) == .lt;
        }
    }.lessThan);
    for (errors, 0..) |e, k| {
        // Once each: the backend reports an error in inline assembly in
        // every function the inliner copied it into. Sema's repeats (one
        // per vector element or operand) stay, as upstream reports them.
        if (k != 0 and e.codegen) {
            const p = errors[k - 1];
            if (p.codegen and p.file == e.file and p.embed == e.embed and std.meta.eql(p.span, e.span) and p.code == e.code and
                p.notes.len == 0 and e.notes.len == 0 and std.mem.eql(u8, p.msg, e.msg)) continue;
        }
        var notes: std.ArrayList(diag.Note) = try .initCapacity(arena, e.notes.len + 1);
        for (e.notes) |en| notes.appendAssumeCapacity(.{ .loc = if (en.no_loc) null else try zcu.diagLocIn(arena, paths, en.file, en.embed, en.span), .msg = en.msg, .count = en.count, .call = en.call, .decl = en.decl });
        var raw_fix = e.fix;
        if (e.fix == null) if (try zcu.argumentOrigin(arena, paths, e)) |o| {
            if (o.note.msg) |msg| notes.appendAssumeCapacity(.{ .loc = try zcu.diagLoc(arena, paths, o.file, o.note.span), .msg = msg, .decl = o.note.decl });
            if (o.note.fix) |f| {
                raw_fix = f;
                raw_fix.?.file = o.file;
            }
        };
        const fixes: []const diag.Fix = if (raw_fix) |f| fixes: {
            const fix_file = f.file orelse e.file;
            const fix = try paths.fix(arena, zcu.file(fix_file).display_path, try zcu.fe.source(@fromBackingInt(fix_file)), f) orelse break :fixes &.{};
            break :fixes try arena.dupe(diag.Fix, &.{fix});
        } else &.{};
        try out.append(arena, .{ .code = e.code, .loc = if (e.no_loc) null else try zcu.diagLocIn(arena, paths, e.file, e.embed, e.span), .msg = e.msg, .notes = notes.items, .refs = try zcu.referenceTrace(arena, paths, e.unit), .candidates = e.candidates, .hint = e.hint, .fixes = fixes });
    }
    if (zcu.compile_logs.items.len != 0) try zcu.compileLogDiagnostics(arena, paths, &out);
    for (zcu.c_import_errors.items) |body| try diag.fromBundle(arena, paths, try std.zig.Server.allocErrorBundle(arena, body), &out);
    return out.items;
}

/// For error `e` raised in std inside a generic function that the user's
/// code called with an error union or optional where it meant the payload
/// (a `print` argument or `free`'s slice without `try`): where that
/// argument comes from in the user's file, and the fix there
/// (`diag.originNote`). The function is the first in the reference trace
/// that a file outside the Zig lib directory refers to. An argument inside
/// a tuple counts only if the error names its type (`for type 'E![]u8'`).
fn argumentOrigin(zcu: *const Zcu, arena: Allocator, paths: diag.Paths, e: ErrorMsg) !?struct { file: u32, note: diag.OriginNote } {
    const ip = &zcu.ip;
    if (e.embed or e.no_loc) return null;
    _, const in_lib = try paths.display(arena, zcu.file(e.file).display_path);
    if (!in_lib) return null;
    var unit = e.unit orelse return null;
    const site = while (zcu.referenced_by.get(unit)) |r| : (unit = r.from) {
        _, const lib = try paths.display(arena, zcu.file(r.file).display_path);
        if (!lib) break r;
    } else return null;
    const func = ip.keyAs(.func, switch (unit) {
        .func => |f| f,
        else => return null,
    }) orelse return null;
    if (func.generic_owner == .none) return null;
    const params = ip.keyPayload(.func_type, func.ty).param_types;
    const Arg = struct { param: usize, field: ?usize, ty: InternPool.Index };
    var found: ?Arg = null;
    var count: usize = 0;
    for (params, 0..) |p, i| {
        if (ip.keyTag(p) == .error_union_type or ip.keyTag(p) == .opt_type) {
            found = .{ .param = i, .field = null, .ty = p };
            count += 1;
        } else if (ip.keyAs(.tuple_type, p)) |t| for (t.types, 0..) |ft, j| {
            if (ip.keyTag(ft) != .error_union_type and ip.keyTag(ft) != .opt_type) continue;
            const quoted = try arena.print("'{s}'", .{try print.typeAlloc(ip, ft, arena)});
            if (std.mem.find(u8, e.msg, quoted) == null) continue;
            found = .{ .param = i, .field = j, .ty = ft };
            count += 1;
        };
    }
    if (count != 1) return null;
    const arg = found.?;
    // The instance's type has its runtime parameters only: the call's
    // argument is the one at the `arg.param`th runtime parameter.
    var call_param = arg.param;
    var runtime: usize = 0;
    for (func.comptime_args, 0..) |c, i| if (c == .none) {
        if (runtime == arg.param) {
            call_param = i;
            break;
        }
        runtime += 1;
    };
    const n_params = @max(params.len, func.comptime_args.len);
    const tree = try zcu.fe.tree(@fromBackingInt(site.file));
    const span = site.src.span(tree);
    const node = diag.callArgument(tree, span.start, span.end, n_params, call_param, arg.field) orelse return null;
    const node_span = tree.nodeToSpan(node);
    const origin = diag.valueOrigin(tree, node_span.start, node_span.end, .self) orelse return null;
    const kind: diag.OriginKind = if (ip.keyTag(arg.ty) == .opt_type) .optional else .error_union;
    const note = try diag.originNote(arena, tree, origin, kind, diag.fnReturnsError(tree, tree.firstToken(node)), true) orelse return null;
    return .{ .file = site.file, .note = note };
}

/// `@compileLog`'s output, as upstream: each logging unit's lines
/// together, units in source order (the first call of each). With no
/// other error, it is the error "found compile log statement" at the first
/// unit's first call, the others' as "also here" notes; else the output
/// rides on the last error.
fn compileLogDiagnostics(zcu: *const Zcu, arena: Allocator, paths: diag.Paths, out: *std.ArrayList(diag.Diagnostic)) !void {
    // The first log of each unit, in order of appearance.
    var firsts: std.ArrayList(usize) = .empty;
    for (zcu.compile_logs.items, 0..) |l, i| {
        for (firsts.items) |f| {
            if (std.meta.eql(zcu.compile_logs.items[f].unit, l.unit)) break;
        } else try firsts.append(arena, i);
    }
    const Ctx = struct {
        zcu: *const Zcu,
        const Self = @This();
        fn lessThan(c: Self, a: usize, b: usize) bool {
            const la = c.zcu.compile_logs.items[a];
            const lb = c.zcu.compile_logs.items[b];
            const order = std.mem.order(u8, c.zcu.file(la.file).display_path, c.zcu.file(lb.file).display_path);
            return order == .lt or (order == .eq and la.span.start < lb.span.start);
        }
    };
    std.mem.sort(usize, firsts.items, Ctx{ .zcu = zcu }, Ctx.lessThan);
    var lines: std.ArrayList([]const u8) = .empty;
    for (firsts.items) |f| {
        const unit = zcu.compile_logs.items[f].unit;
        for (zcu.compile_logs.items) |l| if (std.meta.eql(l.unit, unit)) try lines.append(arena, l.text);
    }
    if (out.items.len != 0) {
        out.items[out.items.len - 1].log = lines.items;
        return;
    }
    const first = zcu.compile_logs.items[firsts.items[0]];
    // One note per other logging unit; units logging at the same place in
    // a row (instantiations of one function) share a note with a count.
    var notes: std.ArrayList(diag.Note) = .empty;
    var prev = first;
    for (firsts.items[1..]) |f| {
        const l = zcu.compile_logs.items[f];
        if (notes.items.len != 0 and l.file == prev.file and l.span.start == prev.span.start) {
            notes.items[notes.items.len - 1].count += 1;
        } else {
            try notes.append(arena, .{ .loc = try zcu.diagLoc(arena, paths, l.file, l.span), .msg = "also here" });
        }
        prev = l;
    }
    try out.append(arena, .{
        .code = .@"compile-log",
        .loc = try zcu.diagLoc(arena, paths, first.file, first.span),
        .msg = "found compile log statement",
        .notes = notes.items,
        .refs = try zcu.referenceTrace(arena, paths, first.unit),
        .log = lines.items,
    });
}

/// The chain of first references that led analysis to `unit`, nearest
/// first, until a unit nothing referred to (a root: `main`'s caller in
/// std, an export, a test, a `comptime` block).
fn referenceTrace(zcu: *const Zcu, arena: Allocator, paths: diag.Paths, start: ?AnalUnit) ![]const diag.Ref {
    var frames: std.ArrayList(diag.Ref) = .empty;
    var unit = start orelse return &.{};
    while (zcu.referenced_by.get(unit)) |r| {
        // A unit refers to another only before that one's analysis
        // ends, but bound the walk anyway.
        if (frames.items.len == 256) break;
        const tree = try zcu.fe.tree(@fromBackingInt(r.file));
        try frames.append(arena, .{ .name = try zcu.unitName(arena, r.from), .loc = try zcu.diagLoc(arena, paths, r.file, r.src.span(tree)) });
        unit = r.from;
    }
    return frames.items;
}

/// A unit's name as the reference trace shows it: a declaration's or a
/// type's name, or `comptime`.
fn unitName(zcu: *const Zcu, arena: Allocator, unit: AnalUnit) ![]const u8 {
    const ip = &zcu.ip;
    return switch (unit) {
        .nav_val => |nav| ip.stringSlice(ip.getNav(nav).name),
        .func => |func| ip.stringSlice(ip.getNav(ip.keyPayload(.func, func).owner_nav).name),
        .type_layout, .struct_defaults => |ty| if (ip.containerType(ty) == null) "type" else try print.typeAlloc(ip, ty, arena),
        .comptime_decl => "comptime",
    };
}

// ---------------------------------------------------------------------------
// Files and namespaces

/// The root struct type of a file, creating it (and its namespace) on first use.
pub fn fileRootType(zcu: *Zcu, file_index: u32) !InternPool.Index {
    if (zcu.file_root_types.items[file_index] != .none) return zcu.file_root_types.items[file_index];
    const key = try zcu.fileKey(file_index);
    const ty = try zcu.createContainerType(.@"struct", file_index, .main_struct_inst, &.{}, .{ .creator = 0, .template = .{ .bytes = try zcu.fileFqn(file_index) } }, key, Namespace.none, null);
    assert(zcu.ip.stableHash(ty) == InternPool.rootStructHash(key));
    zcu.file_root_types.items[file_index] = ty;
    return ty;
}

pub const ContainerKind = enum { @"struct", @"enum", @"union", @"opaque" };

/// The end of a container type's stable key: the stable hashes of its
/// captures, `(h1,h2)`, or nothing if it has none.
pub fn writeCaptures(ip: *const InternPool, w: *Io.Writer, captures: []const InternPool.Index) Io.Writer.Error!void {
    if (captures.len == 0) return;
    try w.writeAll("(");
    for (captures, 0..) |c, i| {
        if (i != 0) try w.writeAll(",");
        if (c != .none) try w.print("{x}", .{ip.stableHash(c)});
    }
    try w.writeAll(")");
}

/// Interns a declared container type of `kind`, offering it name `name`
/// (`offerName`), with stable key `key`, which ends with the type's captures
/// (`writeCaptures`). If it is new, creates its namespace, lists its
/// declarations (their navs are made on lookup, `declNav`), and queues its
/// `comptime`, exported and test declarations. A type made by
/// `@Struct`, `@Union`, or `@Enum` passes its `reified_layout`; it has no
/// declarations.
pub fn createContainerType(
    zcu: *Zcu,
    kind: ContainerKind,
    file_index: u32,
    inst: Zir.Inst.Index,
    captures: []const InternPool.Index,
    name: NameCandidate,
    key: []const u8,
    parent_ns: u32,
    reified_layout: ?std.lang.Type.ContainerLayout,
) !InternPool.Index {
    const ip = &zcu.ip;
    const zir = &zcu.file(file_index).zir;
    const decls: []const Zir.Inst.Index, const layout: std.lang.Type.ContainerLayout = if (reified_layout) |l| .{ &.{}, l } else switch (kind) {
        .@"struct" => blk: {
            const d = zir.getStructDecl(inst);
            break :blk .{ d.decls, d.layout };
        },
        .@"enum" => .{ zir.getEnumDecl(inst).decls, .auto },
        .@"union" => blk: {
            const d = zir.getUnionDecl(inst);
            break :blk .{ d.decls, d.kind.layout() };
        },
        .@"opaque" => .{ zir.getOpaqueDecl(inst).decls, .auto },
    };
    // Look up first so an existing type keeps its namespace.
    const info = try ip.createContainerInfo(tid, .{ .namespace = Namespace.none, .layout = layout });
    const container: InternPool.ContainerType = .{
        .file = file_index,
        .zir_inst = inst,
        .captures = captures,
        .name = undefined,
        .key = try ip.getString(tid, key),
        .info = info,
    };
    const ty = try zcu.internNamed(switch (kind) {
        .@"struct" => .{ .struct_type = container },
        .@"enum" => .{ .enum_type = container },
        .@"union" => .{ .union_type = container },
        .@"opaque" => .{ .opaque_type = container },
    }, name);
    const si = ip.structInfo(ty);
    if (si.namespace != Namespace.none) return ty;

    const ns_index: u32 = @intCast(zcu.namespaces.items.len);
    si.namespace = ns_index;
    const in_fn = parent_ns != Namespace.none and (zcu.namespaces.items[parent_ns].in_fn or zcu.inFnDecl(parent_ns, inst));
    const arena = zcu.arena.allocator();
    // The caller's names may live in a Sema arena.
    const decl_prefix = try std.mem.concat(arena, u8, &.{ key, if (parent_ns == Namespace.none) ":" else "." });
    const ns_key = decl_prefix[0..key.len];
    var caps: Io.Writer.Allocating = .init(zcu.gpa);
    defer caps.deinit();
    writeCaptures(ip, &caps.writer, captures) catch return error.OutOfMemory;
    assert(std.mem.endsWith(u8, key, caps.written()));
    try zcu.namespaces.append(zcu.gpa, .{
        .file = file_index,
        .parent = if (parent_ns != Namespace.none and zcu.namespaces.items[parent_ns].in_fn) zcu.namespaces.items[parent_ns].parent else parent_ns,
        .in_fn = in_fn,
        .owner_type = ty,
        .key = ns_key,
        .decl_prefix = decl_prefix,
        .path = ns_key[0 .. key.len - caps.written().len],
    });
    const collect_tests = zcu.is_test and zcu.file(file_index).module == zcu.fe.main_module;
    const effects = zcu.comptime_decls.count() + zcu.exports.items.len + zcu.test_functions.items.len;
    var comptime_ordinal: u32 = 0;
    var unnamed_tests: u32 = 0;
    // compiler_rt's export blocks are not analyzed, except the stack
    // protector's when it is a root (`Frontend.ubsan_rt`).
    const f = zcu.file(file_index);
    const skip_comptime = f.module == .compiler_rt and !(zcu.fe.ubsan_rt != null and std.mem.eql(u8, f.sub_path, Frontend.ssp_sub_path));
    for (decls) |decl_inst| {
        const d = zir.getDeclaration(decl_inst);
        const simple: []const u8 = switch (d.kind) {
            .@"comptime" => {
                if (skip_comptime) continue;
                try zcu.comptime_decls.put(zcu.gpa, .{ .file = file_index, .inst = decl_inst, .namespace = ns_index, .ordinal = comptime_ordinal }, .queued);
                comptime_ordinal += 1;
                continue;
            },
            .unnamed_test, .@"test", .decltest => blk: {
                if (!collect_tests) continue;
                if (d.kind == .unnamed_test) {
                    defer unnamed_tests += 1;
                    break :blk try arena.print("test_{d}", .{unnamed_tests});
                }
                break :blk try arena.print("{t}.{s}", .{ d.kind, zir.nullTerminatedString(d.name) });
            },
            .@"const", .@"var" => {
                const ns = &zcu.namespaces.items[ns_index];
                const decl_name = try ip.getString(tid, zir.nullTerminatedString(d.name));
                // AstGen rejects duplicate names.
                try ns.decls.putNoClobber(zcu.gpa, decl_name, .none);
                try ns.decl_insts.append(zcu.gpa, decl_inst);
                if (d.linkage == .@"export") {
                    const nav = try zcu.declNav(ns_index, ns.decls.count() - 1);
                    try zcu.exports.append(zcu.gpa, .{ .target = .{ .nav = nav }, .name = decl_name, .unit = null, .file = file_index, .node = zir.instructions.items(.data)[@backingInt(decl_inst)].declaration.src_node, .keyword = @intFromBool(d.is_pub) });
                }
                continue;
            },
        };
        const nav = try zcu.createDeclNav(ns_index, decl_inst, &d, simple);
        // Upstream's filter semantics: unnamed tests always run; named
        // ones only if their fqn contains some filter.
        if (d.kind != .unnamed_test and zcu.test_filters.len > 0) {
            var aw: Io.Writer.Allocating = .init(zcu.gpa);
            defer aw.deinit();
            print.writeNavName(ip, nav, &aw.writer, .read) catch return error.OutOfMemory;
            const decl_fqn = aw.written();
            for (zcu.test_filters) |filter| {
                if (std.mem.find(u8, decl_fqn, filter) != null) break;
            } else continue;
        }
        try zcu.test_functions.append(zcu.gpa, nav);
    }
    zcu.namespaces.items[ns_index].effects = zcu.comptime_decls.count() + zcu.exports.items.len + zcu.test_functions.items.len != effects;
    return ty;
}

/// The nav of declaration `i` of namespace `ns_index` (an index into its
/// `decls`), created if it was not yet.
pub fn declNav(zcu: *Zcu, ns_index: u32, i: usize) !InternPool.NavIndex {
    const ns = &zcu.namespaces.items[ns_index];
    if (ns.decls.values()[i] != .none) return ns.decls.values()[i];
    const inst = ns.decl_insts.items[i];
    const d = zcu.file(ns.file).zir.getDeclaration(inst);
    const nav = try zcu.createDeclNav(ns_index, inst, &d, zcu.ip.stringSlice(ns.decls.keys()[i]));
    // `createDeclNav` appends nothing to `namespaces`.
    ns.decls.values()[i] = nav;
    return nav;
}

/// The declaration named `name` in namespace `ns_index`, if any
/// (`declNav`).
pub fn findDecl(zcu: *Zcu, ns_index: u32, name: InternPool.String) !?InternPool.NavIndex {
    const i = zcu.namespaces.items[ns_index].decls.getIndex(name) orelse return null;
    const result = try zcu.declNav(ns_index, i);
    return result;
}

/// Whether declaration `i` of namespace `ns` is `pub`, without creating
/// its nav.
pub fn declIsPub(zcu: *const Zcu, ns: *const Namespace, i: usize) bool {
    const nav = ns.decls.values()[i];
    if (nav != .none) return zcu.ip.getNav(nav).is_pub;
    return zcu.file(ns.file).zir.getDeclaration(ns.decl_insts.items[i]).is_pub;
}

/// The stable key of declaration `i` of namespace `ns` (its nav's `key`),
/// without creating its nav: built in `buf` if it has none.
pub fn declKey(zcu: *const Zcu, gpa: Allocator, ns: *const Namespace, i: usize, buf: *std.ArrayList(u8)) ![]const u8 {
    const nav = ns.decls.values()[i];
    if (nav != .none) return zcu.ip.stringSlice(zcu.ip.getNav(nav).key);
    buf.clearRetainingCapacity();
    try buf.appendSlice(gpa, ns.decl_prefix);
    try buf.appendSlice(gpa, zcu.ip.stringSlice(ns.decls.keys()[i]));
    return buf.items;
}

fn createDeclNav(zcu: *Zcu, ns_index: u32, decl_inst: Zir.Inst.Index, d: *const Zir.Inst.Declaration.Unwrapped, simple: []const u8) !InternPool.NavIndex {
    const ip = &zcu.ip;
    const ns = &zcu.namespaces.items[ns_index];
    var buf: [256]u8 = undefined;
    const len = ns.decl_prefix.len + simple.len;
    const decl_key = if (len <= buf.len) buf[0..len] else try zcu.gpa.alloc(u8, len);
    defer if (len > buf.len) zcu.gpa.free(decl_key);
    @memcpy(decl_key[0..ns.decl_prefix.len], ns.decl_prefix);
    @memcpy(decl_key[ns.decl_prefix.len..], simple);
    var hasher: InternPool.Hasher = .init("nav");
    hasher.bytes(decl_key);
    return ip.createNav(tid, .{
        .name = try ip.getString(tid, simple),
        .parent = ns.owner_type,
        .key = try ip.getString(tid, decl_key),
        .file = ns.file,
        .zir_inst = decl_inst,
        .namespace = ns_index,
        .hash = hasher.final(),
        .is_pub = d.is_pub,
        .has_type = d.type_body != null and d.linkage != .@"extern",
        .linkage = d.linkage,
        .is_const = d.kind != .@"var",
        .is_threadlocal = d.is_threadlocal and !zcu.single_threaded,
    });
}

/// Interns `key`, a container type or named tuple whose `name` is to be
/// filled in, and offers it `name` (`offerName`).
pub fn internNamed(zcu: *Zcu, key: InternPool.Key, name: NameCandidate) !InternPool.Index {
    const ip = &zcu.ip;
    const slot = try ip.createName(tid, .{ .creator = name.creator, .template = name.template });
    var k = key;
    switch (k) {
        .struct_type, .enum_type, .union_type, .opaque_type => |*c| c.name = slot,
        .tuple_type => |*t| t.name = slot,
        else => unreachable,
    }
    const ty = try ip.get(tid, k);
    const named = ip.nameOf(ty);
    if (named != ip.typeName(slot)) {
        try zcu.offerName(ty, name);
        return ty;
    }
    named.ty = ty;
    named.template = try zcu.dupeTemplate(name.template);
    if (zcu.name_pins) |pins| named.pinned = pins.get(ip.stableHash(ty));
    return ty;
}

/// Offers container type or named tuple `ty` name `name`: the type takes
/// it if its creator is less than the creator of the name it has, so that
/// every build names a type the same however its analysis is ordered
/// (docs/slop/architecture.md, "Type names").
pub fn offerName(zcu: *Zcu, ty: InternPool.Index, name: NameCandidate) !void {
    const cur = zcu.ip.nameOf(ty);
    if (name.creator >= cur.creator) return;
    // A read name changed if it renders differently: an edit build offers
    // a type made from a result, whose recorded name has no holes, the
    // template it was rendered from (`Replay.contributeNames`).
    const before = if (cur.read and cur.pinned == null) try nameAlloc(&zcu.ip, ty, zcu.gpa) else null;
    defer if (before) |b| zcu.gpa.free(b);
    cur.creator = name.creator;
    cur.template = try zcu.dupeTemplate(name.template);
    if (before) |b| {
        const after = try nameAlloc(&zcu.ip, ty, zcu.gpa);
        defer zcu.gpa.free(after);
        if (!std.mem.eql(u8, b, after)) zcu.name_read_changed = true;
    }
}

fn nameAlloc(ip: *const InternPool, ty: InternPool.Index, gpa: Allocator) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    print.writeTypeName(ip, ty, &aw.writer, .render) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

pub fn dupeTemplate(zcu: *Zcu, t: InternPool.Template) !InternPool.Template {
    const arena = zcu.arena.allocator();
    return .{ .bytes = try arena.dupe(u8, t.bytes), .holes = try arena.dupe(InternPool.Template.Hole, t.holes) };
}

/// Settles the names of the types analysis made, which nothing may change
/// afterwards: an edit build first offers the loaded units' candidates.
/// Returns the names to pin if analysis read a name that then changed and
/// the build must be redone (in `pin_arena`), else null.
pub fn finalizeNames(zcu: *Zcu, pin_arena: Allocator) !?*const NamePins {
    if (zcu.replay) |r| try r.contributeNames(zcu);
    if (!zcu.name_read_changed) return null;
    // Redone builds pin every type the first attempt made; one that only
    // the second attempt makes and reads, after which it is renamed, is
    // left as it is (not seen yet).
    if (zcu.name_pins != null) return null;
    const pins = try pin_arena.create(NamePins);
    pins.* = .empty;
    const ip = &zcu.ip;
    var aw: Io.Writer.Allocating = .init(pin_arena);
    for (0..ip.locals.len) |local| for (ip.localNames(local)) |name| {
        if (name.ty == .none) continue;
        aw.clearRetainingCapacity();
        print.writeTypeName(ip, name.ty, &aw.writer, .render) catch return error.OutOfMemory;
        try pins.put(pin_arena, ip.stableHash(name.ty), try pin_arena.dupe(u8, aw.written()));
    };
    return pins;
}

/// Whether ZIR instruction `inst`, of a type made in namespace `ns_index`
/// (not inside a function), is inside one of the namespace's function or
/// test declarations. A declaration's instructions, nested ones included,
/// run from its `declaration` instruction to the end of its value body;
/// field expressions lie outside every declaration.
fn inFnDecl(zcu: *Zcu, ns_index: u32, inst: Zir.Inst.Index) bool {
    const ns = &zcu.namespaces.items[ns_index];
    const zir = &zcu.file(ns.file).zir;
    const owner = zcu.ip.containerType(ns.owner_type).?;
    const decls: []const Zir.Inst.Index = switch (zir.instructions.items(.tag)[@backingInt(owner.zir_inst)]) {
        .extended => switch (zir.instructions.items(.data)[@backingInt(owner.zir_inst)].extended.opcode) {
            .struct_decl => zir.getStructDecl(owner.zir_inst).decls,
            .enum_decl => zir.getEnumDecl(owner.zir_inst).decls,
            .union_decl => zir.getUnionDecl(owner.zir_inst).decls,
            .opaque_decl => zir.getOpaqueDecl(owner.zir_inst).decls,
            else => return false,
        },
        else => return false,
    };
    // The last declaration that starts before `inst`.
    var lo: usize = 0;
    var hi: usize = decls.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (@backingInt(decls[mid]) < @backingInt(inst)) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return false;
    const d = zir.getDeclaration(decls[lo - 1]);
    const last = for ([_]?[]const Zir.Inst.Index{ d.value_body, d.type_body }) |b| {
        if (b) |body| if (body.len != 0) break body[body.len - 1];
    } else return false;
    if (@backingInt(inst) > @backingInt(last)) return false;
    return switch (d.kind) {
        .unnamed_test, .@"test", .decltest => true,
        .@"comptime", .@"var" => false,
        .@"const" => for (d.value_body orelse return false) |i| switch (zir.instructions.items(.tag)[@backingInt(i)]) {
            .func, .func_inferred, .func_fancy => break true,
            else => {},
        } else false,
    };
}

pub fn namespacePtr(zcu: *Zcu, index: u32) *Namespace {
    return &zcu.namespaces.items[index];
}

// ---------------------------------------------------------------------------
// Units

pub fn recordDeps(zcu: *Zcu, unit: AnalUnit, deps: []const Dependee, conditional: []const u32) !void {
    // In the arena: a small gpa allocation per unit pins allocator pages
    // for the whole compilation.
    try zcu.deps.put(zcu.gpa, unit, try zcu.arena.allocator().dupe(Dependee, deps));
    if (conditional.len != 0) {
        try zcu.conditional_deps.put(zcu.gpa, unit, try zcu.arena.allocator().dupe(u32, conditional));
    } else _ = zcu.conditional_deps.remove(unit);
    _ = zcu.failed_deps.remove(unit);
}

/// Records what `unit` read before its analysis failed (`failed_deps`):
/// `deps` with `conditional[i]` set for each conditional one.
pub fn recordFailedDeps(zcu: *Zcu, unit: AnalUnit, deps: []const Dependee, conditional: []const bool) !void {
    const arena = zcu.arena.allocator();
    var plain: std.ArrayList(Dependee) = .empty;
    for (deps, conditional) |d, c| if (!c) try plain.append(arena, d);
    try zcu.failed_deps.put(zcu.gpa, unit, plain.items);
}

/// Renders a unit's stable key, which does not depend on analysis order or
/// in-memory indices.
pub fn unitKey(zcu: *Zcu, unit: AnalUnit, w: *Io.Writer) !void {
    const ip = &zcu.ip;
    switch (unit) {
        .nav_val => |nav| try w.writeAll(ip.stringSlice(ip.getNav(nav).key)),
        .type_layout => |ty| try w.print("{s}@layout", .{ip.stringSlice(ip.containerType(ty).?.key)}),
        .struct_defaults => |ty| try w.print("{s}@defaults", .{ip.stringSlice(ip.containerType(ty).?.key)}),
        .func => |func| {
            const f = ip.keyPayload(.func, func);
            try w.writeAll(ip.stringSlice(ip.getNav(f.owner_nav).key));
            if (f.generic_owner != .none) try w.print("__{x}", .{ip.stableHash(func)});
        },
        .comptime_decl => |c| {
            const ns = &zcu.namespaces.items[c.namespace];
            try w.print("{s}{s}comptime#{d}", .{ ns.key, if (ns.parent == Namespace.none) ":" else ".", c.ordinal });
        },
    }
}

pub const UnitTiming = struct {
    /// How many units `printUnitTiming` prints.
    top: u32,
    /// Time spent in the units the innermost unit in progress analyzed in
    /// turn, which `ns` does not count against it.
    nested_ns: u64 = 0,
    ns: std.array_hash_map.Auto(AnalUnit, u64) = .empty,

    /// Starts timing a unit (`Sema.create`); pass the result to `stop`.
    pub fn start(t: *UnitTiming, io: Io) [2]u64 {
        defer t.nested_ns = 0;
        return .{ @intCast(Io.Timestamp.now(io, .awake).nanoseconds), t.nested_ns };
    }

    pub fn stop(t: *UnitTiming, gpa: Allocator, io: Io, unit: AnalUnit, started: [2]u64) void {
        const ns = @as(u64, @intCast(Io.Timestamp.now(io, .awake).nanoseconds)) - started[0];
        const gop = t.ns.getOrPutValue(gpa, unit, 0) catch return;
        gop.value_ptr.* += ns -| t.nested_ns;
        t.nested_ns = started[1] + ns;
    }
};

/// Prints the `BS_UNIT_TIMING` slowest units to stderr.
pub fn printUnitTiming(zcu: *Zcu) void {
    const t = if (zcu.unit_timing) |*t| t else return;
    const C = struct {
        v: []const u64,
        const Self = @This();
        pub fn lessThan(c: Self, a: usize, b: usize) bool {
            return c.v[a] > c.v[b];
        }
    };
    t.ns.sortUnstable(C{ .v = t.ns.values() });
    var total: u64 = 0;
    var by_kind: std.EnumArray(std.meta.Tag(AnalUnit), [2]u64) = .initFill(.{ 0, 0 });
    for (t.ns.keys(), t.ns.values()) |unit, v| {
        total += v;
        const k = by_kind.getPtr(unit);
        k[0] += 1;
        k[1] += v;
    }
    std.debug.print("unit timing: {d} units, {d:.1} ms", .{ t.ns.count(), @as(f64, @floatFromInt(total)) / 1e6 });
    var it = by_kind.iterator();
    while (it.next()) |k| std.debug.print("; {s} {d}: {d:.1} ms", .{ @tagName(k.key), k.value[0], @as(f64, @floatFromInt(k.value[1])) / 1e6 });
    std.debug.print("\n", .{});
    for (t.ns.keys()[0..@min(t.top, t.ns.count())], t.ns.values()[0..@min(t.top, t.ns.count())]) |unit, ns| {
        var buf: [256]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        zcu.unitKey(unit, &w) catch {}; // ziglint-ignore: Z026 -- only names a unit in a message
        std.debug.print("{d:>9.2} ms  {s} {s}\n", .{ @as(f64, @floatFromInt(ns)) / 1e6, @tagName(unit), w.buffered() });
    }
}

/// The error for a unit found in progress: a dependency loop, or while
/// `speculating`, the end of the speculation.
fn loop(zcu: *const Zcu) Sema.CompileError {
    return if (zcu.speculating != 0) error.Speculation else error.DependencyLoop;
}

/// Resolves the type and alignment of a declaration, which taking its
/// address needs, without its value when the declaration states its type,
/// as upstream's `nav_ty` unit: `var x: S = .{ .p = &y }; var y = &x;`
/// then resolves from either end. The value is queued for `analyzeAll`.
pub fn ensureNavTy(zcu: *Zcu, nav_index: InternPool.NavIndex) Sema.CompileError!void {
    const nav = zcu.ip.getNav(nav_index);
    switch (nav.ty_status) {
        .resolved => return,
        .failed => return error.AnalysisFail,
        .resolving => return zcu.loop(),
        .unresolved => {},
    }
    switch (nav.status) {
        .resolved => return,
        .failed => return error.AnalysisFail,
        .unresolved, .resolving => {},
    }
    // Otherwise the type is the value's.
    if (!nav.has_type) return zcu.ensureNavVal(nav_index);
    if (nav.status == .unresolved) try zcu.nav_queue.append(zcu.gpa, nav_index);
    nav.ty_status = .resolving;
    Sema.analyzeNavTy(zcu, nav_index) catch |err| {
        nav.ty_status = if (err == error.Speculation) .unresolved else .failed;
        return err;
    };
    nav.ty_status = .resolved;
}

/// Resolves the value of a declaration (its `nav_val` unit).
pub fn ensureNavVal(zcu: *Zcu, nav_index: InternPool.NavIndex) Sema.CompileError!void {
    const nav = zcu.ip.getNav(nav_index);
    switch (nav.status) {
        .resolved => return,
        .failed => return error.AnalysisFail,
        .resolving => return zcu.loop(),
        .unresolved => {},
    }
    nav.status = .resolving;
    if (zcu.replay) |r| if (r.loadNav(nav_index)) {
        nav.status = .resolved;
        if (nav.linkage == .@"export" and zcu.ip.indexToKey(nav.val) == .func) _ = try zcu.queueFunc(nav.val);
        return;
    };
    Sema.analyzeNavVal(zcu, nav_index) catch |err| {
        nav.status = if (err == error.Speculation) .unresolved else .failed;
        return err;
    };
    nav.status = .resolved;
    if (nav.linkage == .@"export" and zcu.ip.keyTag(nav.val) == .func) _ = try zcu.queueFunc(nav.val);
}

/// Resolves the fields and layout of a struct type (its `type_layout` unit).
pub fn ensureStructLayout(zcu: *Zcu, ty: InternPool.Index) Sema.CompileError!void {
    const info = zcu.ip.structInfo(ty);
    switch (info.status) {
        .have_layout => return if (info.defaults_status == .none) zcu.queueDefaults(ty),
        .failed => return error.AnalysisFail,
        .field_types_wip, .layout_wip => return zcu.loop(),
        .none, .have_field_types => {},
    }
    const status = info.status;
    if (zcu.replay) |r| {
        info.status = .layout_wip;
        if (r.loadLayout(ty)) return zcu.queueDefaults(ty);
        info.status = status;
    }
    Sema.analyzeStructLayout(zcu, ty) catch |err| {
        info.status = if (err == error.Speculation) status else .failed;
        return err;
    };
    try zcu.queueDefaults(ty);
}

/// Queues the `struct_defaults` unit of `ty`, whose layout was resolved,
/// if it is a declared struct with non-`comptime` field defaults. As
/// upstream, a struct's defaults are analyzed once its layout is, whether
/// or not anything reads one, so a bad default is an error. The layout
/// unit is the defaults unit's first reference.
fn queueDefaults(zcu: *Zcu, ty: InternPool.Index) !void {
    const ip = &zcu.ip;
    const info = ip.structInfo(ty);
    if (info.defaults_status != .none or ip.keyTag(ty) != .struct_type) return;
    info.defaults_status = .queued;
    const key = ip.containerType(ty).?;
    const code = &zcu.file(key.file).zir;
    const inst = code.instructions.get(@backingInt(key.zir_inst));
    if (inst.tag != .extended or inst.data.extended.opcode != .struct_decl) return;
    const decl = code.getStructDecl(key.zir_inst);
    var it = decl.iterateFields();
    while (it.next()) |field| {
        if (field.is_comptime or field.default_body == null) continue;
        try zcu.defaults_queue.append(zcu.gpa, ty);
        const gop = try zcu.referenced_by.getOrPut(zcu.gpa, .{ .struct_defaults = ty });
        if (!gop.found_existing) gop.value_ptr.* = .{ .from = .{ .type_layout = ty }, .file = key.file, .src = .{ .base = decl.src_node, .loc = .{ .node = .zero } } };
        return;
    }
}

/// Resolves the default values of a struct whose layout is resolved (its
/// `struct_defaults` unit).
pub fn ensureStructDefaults(zcu: *Zcu, ty: InternPool.Index) Sema.CompileError!void {
    const info = zcu.ip.structInfo(ty);
    switch (info.defaults_status) {
        .resolved => return,
        .failed => return error.AnalysisFail,
        .wip => return zcu.loop(),
        .none, .queued => {},
    }
    const prev = info.defaults_status;
    info.defaults_status = .wip;
    if (zcu.replay) |r| if (r.loadDefaults(ty)) {
        info.defaults_status = .resolved;
        return;
    };
    Sema.analyzeStructDefaults(zcu, ty) catch |err| {
        info.defaults_status = if (err == error.Speculation) prev else .failed;
        return err;
    };
    info.defaults_status = .resolved;
}

/// Resolves the inferred error set of function instance `func`, analyzing
/// its body if that has not happened yet; null if it is `anyerror`.
pub fn ensureFuncIes(zcu: *Zcu, func: InternPool.Index) Sema.CompileError!?[]const InternPool.String {
    const gop = try zcu.funcs.getOrPut(zcu.gpa, func);
    const gop_existed = gop.found_existing;
    if (!gop.found_existing) gop.value_ptr.* = .queued;
    switch (gop.value_ptr.*) {
        .done => {},
        .failed => return error.AnalysisFail,
        .in_progress => return zcu.loop(),
        .queued => {
            gop.value_ptr.* = .in_progress;
            if (zcu.replay) |r| if (r.loadFunc(func)) {
                zcu.funcs.getPtr(func).?.* = .done;
                return if (zcu.anyerror_ies.contains(func)) null else zcu.inferred_errors.get(func) orelse &.{};
            };
            var ir = Sema.analyzeFuncBody(zcu, func) catch |err| {
                // Unqueued again if this call added it.
                if (err == error.Speculation) {
                    if (gop_existed) zcu.funcs.getPtr(func).?.* = .queued else _ = zcu.funcs.orderedRemove(func);
                } else zcu.funcs.getPtr(func).?.* = .failed;
                return err;
            };
            errdefer ir.deinit(zcu.gpa);
            zcu.funcs.getPtr(func).?.* = .done;
            try zcu.ready_irs.append(zcu.gpa, ir);
        },
    }
    if (zcu.anyerror_ies.contains(func)) return null;
    return zcu.inferred_errors.get(func) orelse &.{};
}

/// Queues `func` on behalf of unit `from`, which refers to it (a call, a
/// reference to its declaration, a coercion to a function pointer, an
/// export), and records the reference.
/// Returns whether `func` was queued now, for the first time.
pub fn queueFuncFrom(zcu: *Zcu, from: AnalUnit, func: InternPool.Index) !bool {
    try zcu.func_refs.put(zcu.gpa, .{ .from = from, .func = func }, {});
    return zcu.queueFunc(func);
}

/// Returns whether `func` was queued now, for the first time.
pub fn queueFunc(zcu: *Zcu, func: InternPool.Index) !bool {
    const gop = try zcu.funcs.getOrPut(zcu.gpa, func);
    if (gop.found_existing) return false;
    gop.value_ptr.* = .queued;
    try zcu.func_queue.append(zcu.gpa, func);
    return true;
}

pub const InlineResult = struct {
    /// `not_inlinable` for a function here only for its `ret_len`.
    size: u32,
    hash: cache.Hash,
    /// One more than the argument that is the length of every slice the
    /// function returns (`inline.retLen`); 0 for none.
    ret_len: u32 = 0,
    /// No `loop` in it or its inlined callees (`inline.nested_loop_factor`).
    straight: bool = false,

    pub const not_inlinable = std.math.maxInt(u32);
    /// In its `func_inline` node's first result word, above the size (but
    /// for `not_inlinable`); a record without it reads as having a loop.
    pub const straight_bit: u32 = 1 << 31;

    /// Mixed into the `func_inline` result, so callers that read
    /// `ret_len` change with it.
    pub fn retLenHash(ret_len: u32) cache.Hash {
        return if (ret_len == 0) 0 else cache.hash(ret_len, "ret_len");
    }

    /// Its first result word.
    pub fn sizeWord(res: InlineResult) u32 {
        return if (res.straight) res.size | straight_bit else res.size;
    }

    /// From its first result word, `size` and `straight`.
    pub fn fromWord(word: u32) struct { u32, bool } {
        if (word == not_inlinable) return .{ word, false };
        return .{ word & ~straight_bit, word & straight_bit != 0 };
    }
};

pub const FuncBody = union(enum) {
    /// Its analysis failed.
    failed,
    /// Analysis is in progress, or would have to wait for a speculation.
    busy,
    /// Loaded from the cache, or already handed to the sink.
    done,
    /// Analyzed now or earlier, its IR not handed to the sink yet; the
    /// caller owns it now.
    analyzed: Ir,
};

/// Brings `func` to the end of its analysis out of queue order, as
/// `ensureFuncIes` does, for Emit to decide whether calls of it inline.
pub fn takeFuncBody(zcu: *Zcu, func: InternPool.Index) !FuncBody {
    const gop = try zcu.funcs.getOrPut(zcu.gpa, func);
    const gop_existed = gop.found_existing;
    if (!gop.found_existing) gop.value_ptr.* = .queued;
    switch (gop.value_ptr.*) {
        .failed => return .failed,
        .in_progress => return .busy,
        .done => {
            for (zcu.ready_irs.items, 0..) |ir, i| if (ir.func == func) return .{ .analyzed = zcu.ready_irs.orderedRemove(i) };
            return .done;
        },
        .queued => {
            gop.value_ptr.* = .in_progress;
            if (zcu.replay) |r| if (r.loadFunc(func)) {
                zcu.funcs.getPtr(func).?.* = .done;
                return .done;
            };
            const ir = Sema.analyzeFuncBody(zcu, func) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Speculation => {
                    if (gop_existed) zcu.funcs.getPtr(func).?.* = .queued else _ = zcu.funcs.orderedRemove(func);
                    return .busy;
                },
                else => {
                    zcu.funcs.getPtr(func).?.* = .failed;
                    return .failed;
                },
            };
            zcu.funcs.getPtr(func).?.* = .done;
            return .{ .analyzed = ir };
        },
    }
}

/// Adds dependencies Sema does not record to the ones it recorded for
/// `unit` (`recordDeps`).
pub fn addDeps(zcu: *Zcu, unit: AnalUnit, more: []const Dependee) !void {
    if (more.len == 0) return;
    const old = zcu.deps.get(unit) orelse &.{};
    try zcu.deps.put(zcu.gpa, unit, try std.mem.concat(zcu.arena.allocator(), Dependee, &.{ old, more }));
}

/// The stable key of compiler_rt function `name`, declared in
/// `lib/compiler_rt/<file>`, or with an empty `file_name` in
/// `lib/compiler_rt.zig`, the module's root: the key of its function unit
/// (its symbol), whose file part is empty for the root (`fileKey`).
pub fn compilerRtKey(buf: *[128]u8, file_name: []const u8, name: []const u8) []const u8 {
    if (file_name.len == 0) return std.mem.print(buf, "compiler_rt::{s}", .{name}) catch unreachable;
    return std.mem.print(buf, "compiler_rt:compiler_rt/{s}:{s}", .{ file_name, name }) catch unreachable;
}

/// The file and declaration names `compilerRtKey` made `key` from.
pub fn compilerRtKeyParts(key: []const u8) struct { []const u8, []const u8 } {
    const rest = key["compiler_rt:".len..];
    const colon = std.mem.findScalarLast(u8, rest, ':').?;
    const path = rest[0..colon];
    return .{ if (std.mem.startsWith(u8, path, "compiler_rt/")) path["compiler_rt/".len..] else "", rest[colon + 1 ..] };
}

/// Requests compiler_rt function `key` (`compilerRtKey`) and returns the
/// key, owned by `rt_helpers`. Only that declaration and what it reaches
/// are analyzed, never compiler_rt's `comptime` export blocks.
pub fn requestCompilerRtKey(zcu: *Zcu, key: []const u8) ![]const u8 {
    const gop = try zcu.rt_helpers.getOrPut(zcu.gpa, key);
    if (!gop.found_existing) {
        gop.key_ptr.* = try zcu.arena.allocator().dupe(u8, key);
        gop.value_ptr.* = .none;
    }
    return gop.key_ptr.*;
}

pub const RtExport = struct { file: []const u8, decl: []const u8 };

/// `language`'s compiler_rt exports (src/compiler_rt_exports.zig).
pub fn compilerRtExports(language: Language) []const compiler_rt_exports.Export {
    return switch (language) {
        .zig_0_16 => &compiler_rt_exports.zig_0_16,
        .zig_0_17 => &compiler_rt_exports.zig_0_17,
    };
}

/// The compiler_rt function or variable exporting `name` (`__eqtf2`,
/// `__udivti3`, `sinf`, `sqrtf128`, `memcpy`, `__cpu_model`, ...) in
/// `language`'s lib directory, or null if its compiler_rt does not export
/// `name`. For `@extern` references and C objects, which upstream
/// resolves against the compiler_rt it links. The tables are upstream's
/// export lists (src/compiler_rt_exports.zig); the memory functions are
/// the ones upstream exports in Debug builds (not `.small`).
pub fn compilerRtExport(language: Language, name: []const u8) ?RtExport {
    const maps = comptime blk: {
        var m: [2]std.StaticStringMap(RtExport) = undefined;
        for (&m, [2]Language{ .zig_0_16, .zig_0_17 }) |*map, l| {
            const list = compilerRtExports(l);
            @setEvalBranchQuota(200 * list.len);
            var kvs: [list.len]struct { []const u8, RtExport } = undefined;
            for (&kvs, list) |*kv, e| kv.* = .{ e[0], .{ .file = e[1], .decl = e[2] } };
            map.* = .initComptime(kvs);
        }
        break :blk m;
    };
    return maps[@backingInt(language)].get(name);
}

/// The declaration in `language`'s compiler_rt of function `name` in
/// `file_name`, as the backends name it in 0.17's (`compilerRtKey`): the
/// same in 0.17; in 0.16, which keeps compiler_rt in other files, the
/// declaration exporting the same symbol. A declaration of `language`'s
/// own (a key from the cache's manifest) stays as it is.
pub fn compilerRtDecl(language: Language, file_name: []const u8, name: []const u8) RtExport {
    const same: RtExport = .{ .file = file_name, .decl = name };
    if (language == .zig_0_17) return same;
    for (compilerRtExports(language)) |e| if (std.mem.eql(u8, e[1], file_name) and std.mem.eql(u8, e[2], name)) return same;
    // A declaration is named after the symbol it exports (`sqrtq`, which
    // 0.17 exports as `sqrtf128` only), else after one of its aliases
    // (`__cmptf2` for `__lttf2`).
    if (compilerRtExport(language, name)) |e| return e;
    for (compilerRtExports(.zig_0_17)) |e| if (std.mem.eql(u8, e[1], file_name) and std.mem.eql(u8, e[2], name)) {
        if (compilerRtExport(language, e[0])) |found| return found;
    };
    return same;
}
test compilerRtDecl {
    // Every function 0.17's backends can name has its 0.16 declaration:
    // the one exporting the same symbol, in 0.16's other files.
    const t = std.testing;
    for (compilerRtExports(.zig_0_17)) |e| {
        const d = compilerRtDecl(.zig_0_16, e[1], e[2]);
        const in_0_16 = for (compilerRtExports(.zig_0_16)) |o| {
            if (std.mem.eql(u8, o[1], d.file) and std.mem.eql(u8, o[2], d.decl)) break true;
        } else false;
        if (!in_0_16) {
            // Only what 0.16 does not have at all.
            try t.expect(compilerRtExport(.zig_0_16, e[0]) == null);
            try t.expect(compilerRtExport(.zig_0_16, e[2]) == null);
        }
    }
    const lt = compilerRtDecl(.zig_0_16, "comparef.zig", "__cmptf2");
    try t.expectEqualStrings("cmptf2.zig", lt.file);
    const sqrt = compilerRtDecl(.zig_0_16, "sqrt.zig", "sqrtq");
    try t.expectEqualStrings("sqrtq", sqrt.decl);
    const float = compilerRtDecl(.zig_0_16, "float_from_int.zig", "__floatsidf");
    try t.expectEqualStrings("floatsidf.zig", float.file);
    try t.expectEqualStrings("comparef.zig", compilerRtDecl(.zig_0_17, "comparef.zig", "__cmptf2").file);
}

/// The files analysis starts from: builtin, std (whose start code imports
/// the root module), under `bs test` the module under test, with
/// `-ffuzz` the fuzzer's root (for its exports) and its std, and with C
/// objects ubsan_rt and compiler_rt's stack protector (for theirs), and
/// with musl zigc.
pub fn rootFiles(zcu: *Zcu) [8]?u32 {
    const fuzzer = if (zcu.linksFuzzer()) zcu.fe.fuzzer_root else null;
    const ubsan_rt = zcu.fe.ubsan_rt;
    return .{
        0,
        zcu.moduleRootFile(.std),
        zcu.moduleRootFile(zcu.fe.main_module),
        if (fuzzer) |r| zcu.moduleRootFile(r) else null,
        if (fuzzer) |r| zcu.moduleRootFile(zcu.fe.module(r).std_mod) else null,
        if (ubsan_rt) |r| zcu.moduleRootFile(r) else null,
        if (ubsan_rt != null) zcu.moduleFile(.compiler_rt, Frontend.ssp_sub_path) else null,
        if (zcu.fe.zigc) |z| zcu.moduleRootFile(z) else null,
    };
}

/// Whether the fuzzer, with `-ffuzz`, joins the analysis: in a test, or in
/// an executable whose root file declares the callbacks it makes
/// (`runner_test_run`), as a program that drives it does. Upstream links
/// the fuzzer as a library, which only such a program draws members
/// from.
fn linksFuzzer(zcu: *Zcu) bool {
    if (zcu.fe.fuzzer_root == null) return false;
    if (zcu.is_test) return true;
    const f = zcu.moduleRootFile(zcu.fe.main_module) orelse return false;
    const zir = &zcu.file(f).zir;
    for (zir.getStructDecl(.main_struct_inst).decls) |inst| {
        const d = zir.getDeclaration(inst);
        switch (d.kind) {
            .@"const", .@"var" => if (std.mem.eql(u8, zir.nullTerminatedString(d.name), "runner_test_run")) return true,
            else => {},
        }
    }
    return false;
}

fn resolveCompilerRt(zcu: *Zcu, key: []const u8) !void {
    const no_span: Ast.Span = .{ .start = 0, .end = 0, .main = 0 };
    const rest = key["compiler_rt:".len..];
    const colon = std.mem.findScalarLast(u8, rest, ':').?;
    const name = rest[colon + 1 ..];
    // compiler_rt's files load on demand, like its analysis.
    const sub_path = if (colon == 0) zcu.fe.module(.compiler_rt).root_file else rest[0..colon];
    const file_index = zcu.fe.loadFile(.compiler_rt, sub_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return zcu.addError(0, no_span, "unable to load compiler_rt file '{s}': {t}", .{ sub_path, err }),
    } orelse return zcu.addError(0, no_span, "compiler_rt file '{s}' not found", .{sub_path});
    try zcu.file_root_types.appendNTimes(zcu.gpa, .none, zcu.fe.files.items.len - zcu.file_root_types.items.len);
    try zcu.fe.reserveCImports();
    var ty = try zcu.fileRootType(@backingInt(file_index));
    // A dotted name is in a nested container (fmv.zig's `x86`).
    var parts = std.mem.splitScalar(u8, name, '.');
    const nav = while (true) {
        const part = parts.next().?;
        const nav = try zcu.findDecl(zcu.ip.structInfo(ty).namespace, try zcu.ip.getString(tid, part)) orelse
            return zcu.addError(@backingInt(file_index), no_span, "compiler_rt has no declaration '{s}'", .{name});
        if (parts.peek() == null) break nav;
        zcu.ensureNavVal(nav) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        ty = zcu.ip.getNav(nav).val;
    };
    zcu.rt_helpers.getPtr(key).?.* = nav;
    zcu.ensureNavVal(nav) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    // A variable's data is lowered with the other declarations'
    // (`Emit.finish`).
    const val = zcu.ip.getNav(nav).val;
    if (zcu.ip.keyTag(val) == .func) _ = try zcu.queueFunc(val);
}

/// Hands a function's IR to the sink: a sink with `functionOwned` keeps it
/// (Emit gives it to a CodeGen worker); `function` borrows it.
fn sinkFunction(zcu: *Zcu, sink: anytype, ir: Ir) !void {
    if (@hasDecl(@TypeOf(sink.*), "functionOwned")) return sink.functionOwned(zcu, ir);
    var owned = ir;
    defer owned.deinit(zcu.gpa);
    try sink.function(zcu, &owned);
}

/// Analyzes the root file's `comptime` and exported declarations and
/// everything they reach. Each runtime function body is passed to
/// `sink.function(ir)` (or `sink.functionOwned`) as soon as it is analyzed.
/// A sink with `sync` is called when the function queue is empty; it may
/// request compiler_rt functions then (Emit: CodeGen runs behind Sema and
/// hands its requests over there), which are analyzed in turn.
pub fn analyzeAll(zcu: *Zcu, sink: anytype) !void {
    // Upstream's analysis roots: std (whose start code imports the root
    // module) and, under `bs test`, the module under test.
    var roots = zcu.rootFiles();
    if (zcu.sched_rng) |*rng| rng.random().shuffle(?u32, &roots);
    for (roots) |root| if (root) |f| {
        _ = try zcu.fileRootType(f);
    };
    // A lazy edit build also walks the last build's graph from them.
    const lazy = if (zcu.replay) |r| r.lazy else false;
    if (lazy) try zcu.replay.?.startWalk();
    var queues: Queues = .{};
    while (true) {
        if (lazy and zcu.replay.?.walking()) {
            try zcu.replay.?.walk();
            continue;
        }
        // In this order, or in a random one each time under `sched_rng`.
        var kinds = std.enums.values(Queues.Kind)[0..].*;
        if (zcu.sched_rng) |*rng| rng.random().shuffle(Queues.Kind, &kinds);
        const worked = for (kinds) |kind| {
            if (try queues.step(zcu, sink, kind)) break true;
        } else false;
        if (worked) continue;
        if (@hasDecl(@TypeOf(sink.*), "sync")) try sink.sync(zcu);
        if (queues.pending(zcu)) continue;
        if (lazy and try zcu.replay.?.settle()) continue;
        break;
    }
}

/// `analyzeAll`'s work: how far it got through each queue.
const Queues = struct {
    comptime_decls: usize = 0,
    exports: usize = 0,
    tests: usize = 0,
    navs: usize = 0,
    defaults: usize = 0,
    rt: usize = 0,

    /// Taken in this order, each until it is empty, unless `sched_rng`
    /// shuffles them.
    const Kind = enum { comptime_decl, @"export", @"test", nav, defaults, rt, ready_ir, func };

    fn pending(q: *const Queues, zcu: *const Zcu) bool {
        return q.comptime_decls < zcu.comptime_decls.count() or q.exports < zcu.exports.items.len or
            q.tests < zcu.test_functions.items.len or q.navs < zcu.nav_queue.items.len or
            q.defaults < zcu.defaults_queue.items.len or q.rt < zcu.rt_helpers.count() or
            zcu.ready_irs.items.len != 0 or zcu.next_func < zcu.func_queue.items.len;
    }

    /// Does one item of `kind`'s queue, or returns false if it is empty.
    /// Under `sched_rng`, a random one of the declarations, defaults,
    /// ready functions and functions queued; the others keep their order
    /// (the last of several exports of a name wins; a `comptime` block's
    /// effects are in order).
    fn step(q: *Queues, zcu: *Zcu, sink: anytype, kind: Kind) !bool {
        switch (kind) {
            .comptime_decl => {
                if (q.comptime_decls == zcu.comptime_decls.count()) return false;
                const c = zcu.comptime_decls.keys()[q.comptime_decls];
                q.comptime_decls += 1;
                if (zcu.replay) |r| if (r.loadComptime(c)) return true;
                Sema.analyzeComptimeDecl(zcu, c) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {},
                };
            },
            .@"export" => {
                if (q.exports == zcu.exports.items.len) return false;
                const e = zcu.exports.items[q.exports];
                q.exports += 1;
                if (e.target != .nav) return true;
                zcu.ensureNavVal(e.target.nav) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return true,
                };
                // An exported function is emitted whether or not it is called.
                const val = zcu.ip.getNav(e.target.nav).val;
                if (zcu.ip.keyTag(val) == .func) _ = try zcu.queueFunc(val);
            },
            .@"test" => {
                if (q.tests == zcu.test_functions.items.len) return false;
                const nav = zcu.test_functions.items[q.tests];
                q.tests += 1;
                zcu.ensureNavVal(nav) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return true,
                };
                _ = try zcu.queueFunc(zcu.ip.getNav(nav).val);
            },
            .nav => {
                if (q.navs == zcu.nav_queue.items.len) return false;
                zcu.pickNext(InternPool.NavIndex, zcu.nav_queue.items, q.navs);
                const nav = zcu.nav_queue.items[q.navs];
                q.navs += 1;
                zcu.ensureNavVal(nav) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {},
                };
            },
            .defaults => {
                if (q.defaults == zcu.defaults_queue.items.len) return false;
                zcu.pickNext(InternPool.Index, zcu.defaults_queue.items, q.defaults);
                const ty = zcu.defaults_queue.items[q.defaults];
                q.defaults += 1;
                zcu.ensureStructDefaults(ty) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {},
                };
            },
            .rt => {
                if (q.rt == zcu.rt_helpers.count()) return false;
                const key = zcu.rt_helpers.keys()[q.rt];
                q.rt += 1;
                try zcu.resolveCompilerRt(key);
            },
            .ready_ir => {
                if (zcu.ready_irs.items.len == 0) return false;
                zcu.pickNext(Ir, zcu.ready_irs.items, 0);
                try zcu.sinkFunction(sink, zcu.ready_irs.orderedRemove(0));
            },
            .func => {
                if (zcu.next_func == zcu.func_queue.items.len) return false;
                zcu.pickNext(InternPool.Index, zcu.func_queue.items, zcu.next_func);
                const func = zcu.func_queue.items[zcu.next_func];
                zcu.next_func += 1;
                const state = zcu.funcs.getPtr(func).?;
                if (state.* != .queued) return true;
                state.* = .in_progress;
                if (zcu.replay) |r| if (r.loadFunc(func)) {
                    zcu.funcs.getPtr(func).?.* = .done;
                    return true;
                };
                // Analysis can grow `funcs`, so the state is looked up again after.
                const ir = Sema.analyzeFuncBody(zcu, func) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        zcu.funcs.getPtr(func).?.* = .failed;
                        return true;
                    },
                };
                zcu.funcs.getPtr(func).?.* = .done;
                try zcu.sinkFunction(sink, ir);
            },
        }
        return true;
    }
};

/// Under `sched_rng`, swaps a random item of `items[next..]` to `next`.
fn pickNext(zcu: *Zcu, comptime T: type, items: []T, next: usize) void {
    const rng = if (zcu.sched_rng) |*r| r else return;
    if (next >= items.len) return;
    std.mem.swap(T, &items[next], &items[next + rng.random().uintLessThan(usize, items.len - next)]);
}
