//! Turns analyzed functions into Atoms and links them: the sink that
//! `Zcu.analyzeAll` hands each function's IR to. Owns every Atom's memory
//! until the link, lowers the data the code refers to (declarations,
//! anonymous constants), and assigns error codes, which
//! reach machine code only through `value*` relocations.
//!
//! CodeGen runs on a pool of workers behind the Sema thread (`Pool`), each
//! generating into its own worker Emit. Their output is merged into the
//! main Emit in the order Sema handed the functions over, which makes the
//! result that of generating each function right after its analysis
//! (see "Parallel function bodies" in docs/slop/architecture.md).

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("InternPool.zig");
const Index = InternPool.Index;
const Ir = @import("Ir.zig");
const Type = @import("Type.zig");
const Zcu = @import("Zcu.zig");
const Diag = @import("diag.zig");
const VersionScript = @import("link/VersionScript.zig");
const Atom = @import("link/Atom.zig");
const print = @import("Ir/print.zig");
const SymbolKey = Atom.SymbolKey;
const Elf = @import("link/Elf.zig");
const ElfObject = @import("link/ElfObject.zig");
const ElfDynamic = @import("link/ElfDynamic.zig");
const Glibc = @import("link/Glibc.zig");
const ElfInput = @import("link/ElfInput.zig");
const MachOInput = @import("link/MachOInput.zig");
const MachODylib = @import("link/MachODylib.zig");
const ElfShared = @import("link/ElfShared.zig");
const CSource = @import("CSource.zig");
const CodeGen = @import("codegen/x86_64/CodeGen.zig");
const CodeGenA64 = @import("codegen/aarch64/CodeGen.zig");
const global_asm = @import("codegen/global_asm.zig");
const MachO = @import("link/MachO.zig");
const MachOObject = @import("link/MachOObject.zig");
const Ssa = @import("codegen/Ssa.zig");
const inline_ir = @import("codegen/inline.zig");
const rewrite = @import("codegen/rewrite.zig");
const prove = @import("codegen/prove.zig");
const sroa = @import("codegen/sroa.zig");
const unroll = @import("codegen/unroll.zig");
const forward = @import("codegen/forward.zig");
const Sema = @import("Sema.zig");
const cache = @import("cache.zig");
const Builtin = @import("Builtin.zig");

const Emit = @This();

gpa: Allocator,
/// Owns atom bytes, relocations, and names.
arena: std.heap.ArenaAllocator,
zcu: *Zcu,
atoms: std.ArrayList(Atom) = .empty,
/// Debug info of the function atoms, in atom order.
debug: std.ArrayList(Atom.Debug) = .empty,
/// Content-addressed atoms already emitted.
content_keys: std.AutoHashMapUnmanaged(SymbolKey, void) = .empty,
/// Declarations whose data the code refers to; lowered by `finish`.
navs: std.array_hash_map.Auto(InternPool.NavIndex, void) = .empty,
/// How many of `navs` were lowered (`lowerNavs`).
navs_done: usize = 0,
/// A lazy edit build (`Replay.lazy`): `finish` lowers only this build's
/// data, and the link's own atoms come from the cache.
lazy: bool = false,
/// Error names referenced by `value*` relocations.
errors: std.array_hash_map.Auto(InternPool.String, void) = .empty,
/// External symbols the code reads the address of (`@extern`), by name,
/// and whether every reference is weak. `finish` writes each one's slot.
externs: std.array_hash_map.String(bool) = .empty,
/// For each bound slot at offset 0, its `externAddrKey` and where the
/// slot binds the symbol, for `link` (`lowerExternSlots`).
aliases: std.ArrayList(Alias) = .empty,
/// The global symbols container-level assembly defines, by the name Zig
/// code and C objects know them by, at offsets in its atoms
/// (codegen/global_asm.zig).
asm_symbols: std.array_hash_map.String(ExternTarget) = .empty,
/// Whether code reads `error_name_table`.
uses_error_names: bool = false,
/// Compile errors that codegen reports (unsupported constructs), rendered
/// like Sema's.
failed: bool = false,
/// The entry symbol, once `finish` found it.
entry: ?SymbolKey = null,
/// Whether the output is a relocatable object (`bs build-obj`): it needs
/// no entry, its exports are symbols for other objects, and symbols it
/// does not define are imported from them.
obj: bool = false,
/// How code reaches thread-locals: `.pic` is position-independent code
/// that may end up in a shared object (`-fPIC`), which uses the
/// local-dynamic model; `.pie` and `.none` use local-exec. `.pic` and
/// `.pie` images put .rodata with absolute addresses in .data.rel.ro.
pic: enum { none, pic, pie } = .none,
/// Whether the output is a shared object (`bs build-lib -dynamic`), with
/// `obj` set too: it needs no entry, its exports are its dynamic symbols,
/// and symbols that neither it nor compiler_rt defines are imported from
/// the modules that load it.
shared: bool = false,
/// The shared object's DT_SONAME.
soname: ?[]const u8 = null,
/// A shared object's version script (`--version-script`), and whether it
/// may name what nothing defines (`--undefined-version`).
version_script: ?*const VersionScript = null,
allow_undefined_version: bool = false,
/// The input objects' definitions the version script makes local, which
/// no longer reach the exports.
version_locals: []const []const u8 = &.{},
/// An aarch64-macos dylib's install name (`-install_name`; else its
/// output path, as upstream's) and current version (`--version`, else
/// 1.0.0), for LC_ID_DYLIB.
install_name: ?[]const u8 = null,
dylib_version: u32 = 0x10000,
/// The dylibs an aarch64-macos image links against besides libSystem:
/// an import one of them exports binds to the first such, else to
/// libSystem. `runpath`'s directories become LC_RPATHs.
macho_libs: []const MachODylib = &.{},
/// The diagnostic of a failed link that the compiler reports as an error
/// (`linkFailed`), not on stderr.
link_diagnostic: ?Diag.Diagnostic = null,
/// `--stack`: the executable's main thread stack size.
stack_size: u64 = 16 * 1024 * 1024,
/// aarch64-macos: the minimum macOS, LC_BUILD_VERSION's.
macos_min: std.SemanticVersion = Builtin.macos_default.min,
/// aarch64-macos: the SDK's version (`main.Options.macos_sdk`),
/// LC_BUILD_VERSION's.
macos_sdk: ?std.SemanticVersion = null,
/// `-fstrip`: link no debug info.
strip: bool = false,
/// `-fentry=<symbol>`, if given.
entry_name: ?[]const u8 = null,
/// `-ffuzz`: CodeGen instruments the main module family's functions with
/// coverage points (docs/slop/architecture.md, "Fuzzing").
fuzz: bool = false,
/// An executable that links glibc (`-lc`): names neither the compilation
/// nor compiler_rt exports resolve to glibc's symbols, imported.
glibc: ?*const Glibc = null,
/// Such an executable's shared library inputs, whose symbols come before
/// glibc's (`Glibc.dynamicOptions`), and its DT_RUNPATH.
shared_libs: []const ElfShared = &.{},
runpath: ?[]const u8 = null,
/// The program is C only, which upstream links with lld rather than its
/// own linker (`Glibc.dynamicOptions`).
lld: bool = false,
/// `-rdynamic`: a dynamic executable exports all its definitions.
rdynamic: bool = false,
/// Plain C against glibc or libSystem (`main.plainC`): names the libc
/// defines resolve to it before compiler_rt, as upstream's compiler_rt
/// archive after libc leaves them (`memset`, `memcpy`, libm's functions).
libc_first: bool = false,
/// With `libc_first` on aarch64-macos: the names libSystem's stub exports
/// to arm64, without the leading underscore (link/Tbd.zig).
libsystem: ?*const std.StringHashMapUnmanaged(void) = null,
/// An executable's object and archive inputs, which `sync` pulls archive
/// members for and `finish` converts into atoms.
inputs: ?Inputs = null,
/// A lazy edit build with link inputs, whose relink from the manifest
/// converts them and binds the externs (`Incremental.linkFrom`): a
/// declaration's data cannot bind to them here, so `externDataTarget` sets
/// `needs_inputs` and the build goes eager (`Incremental.finishLazy`).
inputs_deferred: bool = false,
needs_inputs: bool = false,
/// An executable with object, archive or C inputs, eager or lazy, set
/// before the workers start: an `extern threadlocal` may name one of the
/// inputs' (`tlsTarget`).
has_inputs: bool = false,
/// C sources compiling while the build analyzes (CSource.zig): the first
/// `sync` waits for them and adds their objects to `inputs`, before it
/// pulls archive members and compiler_rt for them.
c_batch: ?*CSource.Batch = null,
/// In an object, the symbols other objects define, by name. On
/// aarch64-macos, the symbols libSystem defines.
imports: std.array_hash_map.String(ImportFlags) = .empty,
/// The imports the executable copies (R_X86_64_COPY) and their sizes, a
/// subset of `imports`, for data C objects reach without the GOT.
copies: std.array_hash_map.String(u64) = .empty,
/// In an object, its exports, once `finish` found them; in an executable
/// with link inputs or shared libraries, its Zig exports.
exports: std.ArrayList(ElfObject.Export) = .empty,
/// An executable's input objects' global definitions, when it has shared
/// libraries, which may name them (`Glibc.dynamicOptions`).
input_exports: []const ElfDynamic.Export = &.{},
/// What produced each atom, for the on-disk cache (`Incremental`).
atom_owners: std.ArrayList(Owner) = .empty,
/// After `finish`, parallel to `atoms`: where each atom's name comes from
/// a type's (`nameAtoms`), for the cache, which renames a loaded atom when
/// the type's final name changes.
atom_names: std.ArrayList(AtomName) = .empty,
/// Content-addressed atoms each unit referred to.
content_uses: std.ArrayList(ContentUse) = .empty,
/// What each unit's code requested besides its atoms (declarations' data,
/// error codes, external symbols, compiler_rt helpers, the error name
/// table), possibly repeated, for the on-disk cache: a unit loaded from it
/// requests them again.
unit_refs: std.ArrayList(UnitRef) = .empty,
/// What the link's own atoms requested (`unit_refs` without a unit).
link_refs: std.ArrayList(@FieldType(UnitRef, "ref")) = .empty,
/// The content atoms the link's own atoms used (`content_uses` without a
/// unit).
link_content_uses: std.ArrayList(SymbolKey) = .empty,
/// The owner of atoms added now.
owner: Owner = .link,
/// `uavKey`'s results, by value and alignment. Each one's lowering
/// requested `uav_refs[refs_start..][0..refs_len]` and used the content
/// atoms `uav_uses[uses_start..][0..uses_len]`, which a later owner of a
/// hit records again, as lowering anew would.
uav_memo: std.AutoHashMapUnmanaged(struct { val: Index, alignment: u64 }, UavMemo) = .empty,
uav_refs: std.ArrayList(@FieldType(UnitRef, "ref")) = .empty,
uav_uses: std.ArrayList(SymbolKey) = .empty,
/// Lowerings in progress that record into `uav_refs` and `uav_uses`.
uav_capturing: u32 = 0,
/// `exportTarget` calls, whose results can change while analysis runs: a
/// lowering that made one is not memoized.
export_lookups: u32 = 0,
/// The error codes `finish` assigned, for `link`.
error_values: std.ArrayList(Elf.Value) = .empty,
/// The inputs' symbols within their atoms, for `link` (in `inputs`' arena).
input_symbols: []const Elf.LocalSymbol = &.{},
/// Their unwind and debug sections (`Elf.Options.input_sections`).
input_sections: []const Elf.InputSection = &.{},
/// Time spent in `CodeGen.generate`, for `BS_TIMING`.
codegen_ns: u64 = 0,
/// `BS_BENCH_CODEGEN`: a copy of every function's IR, which
/// `benchCodegen` generates again after analysis.
bench_irs: ?std.ArrayList(Ir) = null,
/// The SSA form of the function being generated, reused for the next.
ssa: Ssa = .{},
/// `rewrite.run`'s arrays, reused for the next function.
rewrite_scratch: rewrite.Scratch = .{},
/// `sroa.run`'s, likewise.
sroa_scratch: sroa.Scratch = .{},
/// `prove.run`'s arrays, on a worker, reused for the next function.
prove_scratch: prove.Scratch = .{},
/// `forward.run`'s arrays, on a worker, reused for the next function.
forward_scratch: std.ArrayList(u32) = .empty,
/// Whether `prove.run` removes the checks it proves (`BS_PROVE=off`
/// turns it off, to compare a program's behavior with and without).
prove_on: bool = true,
/// Whether `forward.run` forwards copies and loads (`BS_FORWARD=off`
/// turns it off, to compare a program's behavior with and without).
forward_on: bool = true,
/// Per-stage backend time and size, for `BS_TIMING` and bench-codegen.
codegen_stats: CodeGenStats = .{},
/// The CodeGen workers, on the main Emit (`startPool`).
pool: ?*Pool = null,
/// Whether analysis still runs: the main Emit collects compiler_rt
/// requests in `rt_pending` until then.
analyzing: bool = false,
/// How many of `inputs`' objects `pullInputs` requested compiler_rt for.
inputs_requested: usize = 0,
/// Compiler_rt functions requested while analysis runs, which `sync`
/// hands to the Zcu once its function queue is empty, in request order.
/// So the point where Sema learns of them does not depend on when CodeGen
/// ran.
rt_pending: std.array_hash_map.String(void) = .empty,
/// The exports snapshot last handed to a worker (`exportsSnapshot`), and
/// how many of its declarations were not resolved yet.
export_snap: ExportsView = .{ .list = &.{}, .resolved = &.{} },
export_snap_unresolved: u32 = 0,
/// Whether this is a worker's Emit, whose output `mergeOut` moves into the
/// main Emit. A worker changes nothing shared: what would (compiler_rt
/// requests, imports, compile errors) is logged for the merge.
is_worker: bool = false,
/// On a worker: requests that change state shared beyond this Emit, in
/// order.
side: std.ArrayList(Side) = .empty,
/// On a worker: the compiler_rt keys requested, owned.
rt_keys: std.StringHashMapUnmanaged(void) = .empty,
/// On a worker: compile errors CodeGen reported (`addError`).
codegen_errors: std.ArrayList(Zcu.ErrorMsg) = .empty,
/// On a worker: the exports as they were when Sema handed over the
/// function being generated.
exports_view: ExportsView = .{ .list = &.{}, .resolved = &.{} },

/// Whether calls of small functions are inlined (`codegen/inline.zig`),
/// with which budget, and whether only callees that cannot panic are
/// (`Scan.panics`). The rest of this group is the Sema thread's: a
/// function's candidate callees are decided before it is generated
/// (`inlineFate`), bringing them to the end of their analysis out of
/// queue order if needed, as a function's inferred error set is.
inlining: bool = false,
inline_safe: bool = false,
inline_budget: u32 = inline_ir.budget,
/// Each decided function's fate.
inline_fates: std.AutoHashMapUnmanaged(Index, Fate) = .empty,
/// The inlinable bodies, already inlined into themselves.
inline_bodies: std.ArrayList(Ir) = .empty,
/// The functions whose fate is being decided, which a cycle of calls
/// reaches again.
inline_active: std.ArrayList(Index) = .empty,
/// Each function seen so far that returns a slice whose length is one of
/// its arguments: that argument (`inline_ir.retLen`), recorded before its
/// callees are decided, so a cycle of calls reads it too.
ret_lens: std.AutoHashMapUnmanaged(Index, u32) = .empty,

/// The CodeGen workers. Sema hands each analyzed function over as a job
/// (`functionOwned`); workers take jobs in order, and `mergeJobs` waits
/// for all jobs handed over and merges their output in job order. Jobs not
/// handed over yet when a merge comes, and with no threads every job, are
/// generated on the Sema thread into its own Emit, `workers[threads]`; the
/// merge is the same. A unit the cache loads is a job too, done when it is
/// made: its output goes into the last Emit, `loads` (`beginLoad`), so a
/// load does not wait for the jobs before it, and CodeGen stays parallel
/// in a build that loads and analyzes units in turn.
pub const Pool = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    /// Signaled when a job is added or the pool stops.
    work: std.Io.Condition = .init,
    /// Signaled when the last job handed over has finished.
    idle: std.Io.Condition = .init,
    /// Jobs handed over since the last merge, in analysis order. Only the
    /// Sema thread adds or removes jobs; workers take and fill them under
    /// `mutex`.
    jobs: std.ArrayList(Job) = .empty,
    /// Jobs not handed over yet, after `jobs`: the Sema thread hands them
    /// over in batches (`batch_len`), since waking a worker costs about as
    /// much as a small function's CodeGen.
    batch: std.ArrayList(Job) = .empty,
    /// The jobs in `batch` with IR to generate (not loads).
    batch_irs: usize = 0,
    /// Where the load being made (`beginLoad`) started in `loads`.
    load_start: Marks = undefined,
    taken: usize = 0,
    /// Workers waiting for `work`.
    sleeping: usize = 0,
    finished: usize = 0,
    stop: bool = false,
    /// A worker's error (out of memory), returned by the next merge.
    err: ?Allocator.Error = null,
    workers: []Emit,
    threads: usize = 0,
    group: std.Io.Group = .init,
    /// `BS_SCHED_FUZZ=<seed>`: random delays and yields where workers take
    /// jobs and the Sema thread hands them over, random batch lengths, and
    /// merges that sometimes wait for workers instead of generating the
    /// jobs not handed over yet. The output must not change; a difference
    /// from `BS_THREADS=1` is a dependence on timing. Which worker takes
    /// which job varies, but each worker's jobs stay ascending, which the
    /// merge relies on (`mergeOut`).
    fuzz: ?u64 = null,
    /// `BS_SCHED_FUZZ=late`: jobs are handed over only when analysis
    /// waits for CodeGen (`mergeJobs`), and run there, on the Sema thread:
    /// CodeGen sees everything analysis resolved meanwhile, where
    /// `BS_THREADS=1` sees only what was resolved when each function was.
    /// The output must not change; a difference is code that depends on
    /// when a declaration's type, value, or layout was resolved.
    late: bool = false,
    /// The Sema thread's random state and batch length under `fuzz`.
    fuzz_rng: std.Random.DefaultPrng = .init(0),
    batch_target: usize = batch_len,
};

const Fate = union(enum) {
    no,
    yes: struct {
        size: u32,
        hash: cache.Hash,
        /// No `loop` (`Zcu.InlineResult.straight`).
        straight: bool,
        /// Index into `inline_bodies`, or `no_body` for a function loaded
        /// from the cache whose body no caller generated now needed yet.
        body: u32,
    },
};

const no_body = std.math.maxInt(u32);

/// What deciding a function's fate came to: a fate, or not yet, because a
/// cycle of calls reached a function being decided (which makes every
/// function on the cycle not inlinable) or because analysis is busy with
/// the function (an edit build's check, which then analyzes its caller).
pub const FateResult = union(enum) { fate: Fate, cycle, busy };

const Job = struct {
    ir: Ir,
    exports: ExportsView,
    /// Set when the job finished: the worker that generated it, and what
    /// it added to that worker's lists.
    worker: u32 = 0,
    out: Out = undefined,
    /// A job the Sema thread generated already (no threads), or a load:
    /// nothing for a worker to do.
    done: bool = false,
};

/// The lengths of a worker's output lists.
const Marks = struct { atoms: u32, debug: u32, content_uses: u32, unit_refs: u32, side: u32, errors: u32 };

const Out = struct { start: Marks, end: Marks, failed: bool };

const Side = union(enum) {
    rt: []const u8,
};

/// How an object refers to an imported symbol.
pub const ImportFlags = struct {
    /// Every reference is weak.
    weak: bool = false,
    /// Some reference is PC-relative (`pcrelTarget`), so the final link
    /// must define the symbol in its module: GNU as's `.hidden`.
    hidden: bool = false,
    /// A thread-local (`tlsTarget`).
    tls: bool = false,

    /// The flags of a symbol referred to both ways.
    pub fn merge(a: ImportFlags, b: ImportFlags) ImportFlags {
        return .{ .weak = a.weak and b.weak, .hidden = a.hidden or b.hidden, .tls = a.tls or b.tls };
    }

    /// As the cache stores them (`Manifest.LinkSymbol.flags`).
    pub fn bits(f: ImportFlags) u3 {
        return @as(u3, @intFromBool(f.weak)) | @as(u3, @intFromBool(f.hidden)) << 1 | @as(u3, @intFromBool(f.tls)) << 2;
    }

    pub fn fromBits(b: u3) ImportFlags {
        return .{ .weak = b & 1 != 0, .hidden = b & 2 != 0, .tls = b & 4 != 0 };
    }
};

/// `Zcu.exports` as CodeGen may read them: a worker's snapshot, taken when
/// Sema handed over its function, or the live list on the main Emit.
pub const ExportsView = struct {
    list: []const Zcu.Export,
    /// Whether each export's declaration was resolved when the snapshot
    /// was taken; null: read its status now.
    resolved: ?[]const bool = null,
};

pub const CodeGenStats = struct {
    /// The rewrite rules (`rewrite.run`, on the Sema thread), and the
    /// instructions and branches they folded.
    rewrite_ns: u64 = 0,
    folds: u64 = 0,
    /// Forwarding copies and loads (`forward.run`, on the workers), and
    /// the copies and loads forwarded.
    forward_ns: u64 = 0,
    forwarded: u64 = 0,
    /// Proving checks (`prove.run`, on the workers), and the checks
    /// proven.
    prove_ns: u64 = 0,
    checks: u64 = 0,
    proven: u64 = 0,
    /// Scalar replacement (`sroa.run`, on the Sema thread), and the
    /// structs it split into their fields.
    sroa_ns: u64 = 0,
    splits: u64 = 0,
    /// Building the SSA form from the IR.
    build_ns: u64 = 0,
    /// Liveness and register allocation.
    alloc_ns: u64 = 0,
    /// Lowering and encoding the SSA form, and making the Atom.
    emit_ns: u64 = 0,
    functions: u64 = 0,
    ir_insts: u64 = 0,
    /// Machine code of the functions, and their frames' slots and
    /// outgoing argument areas.
    code_bytes: u64 = 0,
    frame_bytes: u64 = 0,

    pub fn print(s: CodeGenStats, label: []const u8) void {
        const per = struct {
            fn f(ns: u64, n: u64) f64 {
                return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(@max(n, 1)));
            }
        }.f;
        const ms = struct {
            fn f(ns: u64) f64 {
                return @as(f64, @floatFromInt(ns)) / 1e6;
            }
        }.f;
        std.debug.print("{s}: {d} functions, {d} IR instructions; rewrite {d:.1} ms ({d:.1} ns/IR, {d} folds), sroa {d:.1} ms ({d:.1} ns/IR, {d} splits), forward {d:.1} ms ({d:.1} ns/IR, {d} forwarded), prove {d:.1} ms ({d:.1} ns/IR, {d} of {d} checks proven), ssa build {d:.1} ms ({d:.1} ns/IR), regalloc {d:.1} ms ({d:.1} ns/IR), emit {d:.1} ms ({d:.1} ns/IR), total {d:.1} ns/IR; {d:.2} code bytes/IR, {d:.0} frame bytes/function\n", .{
            label,
            s.functions,
            s.ir_insts,
            ms(s.rewrite_ns),
            per(s.rewrite_ns, s.ir_insts),
            s.folds,
            ms(s.sroa_ns),
            per(s.sroa_ns, s.ir_insts),
            s.splits,
            ms(s.forward_ns),
            per(s.forward_ns, s.ir_insts),
            s.forwarded,
            ms(s.prove_ns),
            per(s.prove_ns, s.ir_insts),
            s.proven,
            s.checks,
            ms(s.build_ns),
            per(s.build_ns, s.ir_insts),
            ms(s.alloc_ns),
            per(s.alloc_ns, s.ir_insts),
            ms(s.emit_ns),
            per(s.emit_ns, s.ir_insts),
            per(s.build_ns + s.alloc_ns + s.emit_ns, s.ir_insts),
            per(s.code_bytes, s.ir_insts),
            per(s.frame_bytes, s.functions),
        });
    }
};

/// An atom's name is type `parent`'s name, which is its first
/// `prefix_len` bytes, and the rest; `parent` is `.none` for a name that
/// comes from no type.
pub const AtomName = struct { parent: Index = .none, prefix_len: u32 = 0 };

pub const Owner = union(enum) {
    unit: Zcu.AnalUnit,
    /// A content-addressed constant, shared by the units that use it.
    content,
    /// Code the link needs regardless of units (the error name table).
    link,
    /// An executable's object and archive inputs, converted, and the
    /// glibc data they copy (`convertInputs`): every build with inputs
    /// converts them again, so the cache records none, and they link
    /// last, where a relink from the cache appends them.
    input,
};

const UavMemo = struct { key: SymbolKey, refs_start: u32, refs_len: u32, uses_start: u32, uses_len: u32 };

pub const ContentUse = struct { unit: Zcu.AnalUnit, key: SymbolKey };

pub const UnitRef = struct {
    unit: Zcu.AnalUnit,
    ref: union(enum) {
        nav: InternPool.NavIndex,
        err: InternPool.String,
        /// `useExtern`; the name is owned by `externs`.
        ext: struct { name: []const u8, weak: bool },
        /// `useImport`; the name is owned by `imports`.
        import: struct { name: []const u8, flags: ImportFlags },
        /// `requestCompilerRt`'s key, owned by the Emit that requested it.
        rt: []const u8,
        error_names,
    },
};

pub fn init(gpa: Allocator, zcu: *Zcu) Emit {
    return .{ .gpa = gpa, .arena = .init(gpa), .zcu = zcu };
}

pub fn deinit(emit: *Emit) void {
    const gpa = emit.gpa;
    emit.atoms.deinit(gpa);
    emit.debug.deinit(gpa);
    emit.content_keys.deinit(gpa);
    emit.navs.deinit(gpa);
    emit.errors.deinit(gpa);
    emit.externs.deinit(gpa);
    emit.aliases.deinit(gpa);
    emit.asm_symbols.deinit(gpa);
    emit.imports.deinit(gpa);
    emit.copies.deinit(gpa);
    emit.exports.deinit(gpa);
    emit.atom_owners.deinit(gpa);
    emit.atom_names.deinit(gpa);
    emit.content_uses.deinit(gpa);
    emit.unit_refs.deinit(gpa);
    emit.link_refs.deinit(gpa);
    emit.link_content_uses.deinit(gpa);
    emit.ssa.deinit(gpa);
    emit.rewrite_scratch.deinit(gpa);
    emit.prove_scratch.deinit(gpa);
    emit.forward_scratch.deinit(gpa);
    emit.sroa_scratch.deinit(gpa);
    if (emit.bench_irs) |*irs| {
        for (irs.items) |*ir| ir.deinit(gpa);
        irs.deinit(gpa);
    }
    emit.uav_memo.deinit(gpa);
    emit.uav_refs.deinit(gpa);
    emit.uav_uses.deinit(gpa);
    emit.error_values.deinit(gpa);
    emit.rt_pending.deinit(gpa);
    emit.side.deinit(gpa);
    emit.rt_keys.deinit(gpa);
    emit.codegen_errors.deinit(gpa);
    emit.inline_fates.deinit(gpa);
    for (emit.inline_bodies.items) |*b| b.deinit(gpa);
    emit.inline_bodies.deinit(gpa);
    emit.inline_active.deinit(gpa);
    emit.ret_lens.deinit(gpa);
    if (emit.pool) |pool| {
        stopWorkers(pool);
        for (pool.workers) |*w| w.deinit();
        gpa.free(pool.workers);
        for (pool.batch.items) |*job| if (!job.done) job.ir.deinit(gpa);
        pool.batch.deinit(gpa);
        pool.jobs.deinit(gpa);
        gpa.destroy(pool);
    }
    emit.arena.deinit();
    emit.* = undefined;
}

/// Ends the worker threads once they finished the jobs left, which frees
/// their IR. Their Emits stay: the main Emit's atoms point into them.
fn stopWorkers(pool: *Pool) void {
    const io = pool.io;
    pool.mutex.lockUncancelable(io);
    pool.stop = true;
    pool.work.broadcast(io);
    pool.mutex.unlock(io);
    pool.group.await(io) catch {}; // ziglint-ignore: Z026 -- bs never cancels this group
}

/// Starts CodeGen workers on `threads` threads besides the Sema thread; 0
/// generates each function on the Sema thread, with the same output.
pub fn startPool(emit: *Emit, threads: usize, fuzz: ?u64, late: bool) !void {
    const gpa = emit.gpa;
    const io = emit.zcu.io;
    // One per thread, the Sema thread's, and the loads'.
    const workers = try gpa.alloc(Emit, threads + 2);
    errdefer gpa.free(workers);
    for (workers) |*w| {
        w.* = .init(gpa, emit.zcu);
        w.is_worker = true;
        w.obj = emit.obj;
        w.fuzz = emit.fuzz;
        w.prove_on = emit.prove_on;
        w.forward_on = emit.forward_on;
        w.pic = emit.pic;
        w.shared = emit.shared;
        w.glibc = emit.glibc;
        w.shared_libs = emit.shared_libs;
        w.has_inputs = emit.has_inputs;
    }
    const pool = try gpa.create(Pool);
    pool.* = .{ .io = io, .workers = workers, .fuzz = fuzz, .late = late };
    if (fuzz) |seed| pool.fuzz_rng = .init(seed);
    emit.pool = pool;
    emit.analyzing = true;
    for (0..threads) |i| {
        pool.group.concurrent(io, workerMain, .{ pool, i }) catch break;
        pool.threads += 1;
    }
}

fn workerMain(pool: *Pool, index: usize) void {
    Type.codegen_worker = true;
    const io = pool.io;
    const w = &pool.workers[index];
    var rng: std.Random.DefaultPrng = .init((pool.fuzz orelse 0) +% (index + 1) *% 0x9e3779b97f4a7c15);
    pool.mutex.lockUncancelable(io);
    defer pool.mutex.unlock(io);
    while (true) {
        while (pool.taken == pool.jobs.items.len and !pool.stop) {
            pool.sleeping += 1;
            pool.work.waitUncancelable(io, &pool.mutex);
            pool.sleeping -= 1;
        }
        if (pool.taken == pool.jobs.items.len) return;
        const i = pool.taken;
        pool.taken += 1;
        const job = pool.jobs.items[i];
        if (job.done) {
            pool.finished += 1;
            if (pool.finished == pool.jobs.items.len) pool.idle.signal(io);
            continue;
        }
        pool.mutex.unlock(io);
        if (pool.fuzz != null) fuzzDelay(io, rng.random());
        const out = runJob(w, job.ir, job.exports);
        pool.mutex.lockUncancelable(io);
        if (out) |o| {
            pool.jobs.items[i].out = o;
        } else |err| {
            if (pool.err == null) pool.err = err;
            pool.jobs.items[i].out = .{ .start = w.marks(), .end = w.marks(), .failed = false };
        }
        pool.jobs.items[i].worker = @intCast(index);
        pool.finished += 1;
        if (pool.finished == pool.jobs.items.len) pool.idle.signal(io);
    }
}

fn marks(w: *const Emit) Marks {
    return .{
        .atoms = @intCast(w.atoms.items.len),
        .debug = @intCast(w.debug.items.len),
        .content_uses = @intCast(w.content_uses.items.len),
        .unit_refs = @intCast(w.unit_refs.items.len),
        .side = @intCast(w.side.items.len),
        .errors = @intCast(w.codegen_errors.items.len),
    };
}

/// Generates a job's function into worker Emit `w`, and frees its IR.
fn runJob(w: *Emit, ir: Ir, exports: ExportsView) Allocator.Error!Out {
    var owned = ir;
    defer owned.deinit(w.gpa);
    w.exports_view = exports;
    w.failed = false;
    const start = w.marks();
    try w.generateFunction(&owned);
    return .{ .start = start, .end = w.marks(), .failed = w.failed };
}

/// Sink callback from `Zcu.analyzeAll`, which hands over the IR: generates
/// the function, on a worker if there is a pool, with the calls it
/// inlines inlined.
pub fn functionOwned(emit: *Emit, zcu: *Zcu, ir: Ir) !void {
    _ = zcu;
    if (!emit.inlining) return emit.submit(ir, if (emit.pool != null) try emit.exportsSnapshot() else undefined);
    _ = try emit.inlineProcess(ir, .generate);
}

/// A callee of `ir`'s function cannot be decided now: a function to
/// generate goes back to the Zcu (`ready_irs`), which hands it over again
/// once its analysis queue moves on; a body is made again when asked for.
fn handBack(emit: *Emit, ir: *Ir, owned: *bool, mode: ProcessMode) Allocator.Error!bool {
    if (mode == .generate) {
        try emit.zcu.ready_irs.append(emit.gpa, ir.*);
        owned.* = false;
    }
    return false;
}

const ProcessMode = enum {
    /// Generate the function, unless a callee cannot be decided now: then
    /// hand the IR back to the Zcu (`ready_irs`) for later.
    generate,
    /// Only make its inlinable body: it was loaded from the cache. A
    /// callee that cannot be decided now leaves it without one for now.
    body,
};

/// Decides what `ir`'s function inlines and whether it is inlinable,
/// splices the inlinable callees in, and hands it on as `mode` says.
/// Returns false if a callee could not be decided now (in progress, or
/// waiting on a speculation): every decision reads only decided fates, so
/// it is a function of the program, not of the order functions finish in.
fn inlineProcess(emit: *Emit, ir_in: Ir, mode: ProcessMode) Allocator.Error!bool {
    const gpa = emit.gpa;
    const zcu = emit.zcu;
    var ir = ir_in;
    var ir_owned = true;
    defer if (ir_owned) ir.deinit(gpa);
    const func = ir.func;
    try emit.inline_active.append(gpa, func);
    defer emit.inline_active.items.len -= 1;

    var sites: std.ArrayList(inline_ir.Site) = .empty;
    defer sites.deinit(gpa);
    var s = try inline_ir.scan(gpa, zcu, &ir, &sites);
    if (emit.inline_safe and s.panics) s.inlinable = false;
    const ret_len = inline_ir.retLen(&zcu.ip, &ir);
    if (ret_len) |k| try emit.ret_lens.put(gpa, func, k);
    // Every candidate call reads its callee's `func_inline`, inlined or
    // not: an edit that makes the callee inlinable changes the caller.
    var deps: std.ArrayList(Zcu.Dependee) = .empty;
    defer deps.deinit(gpa);
    var seen: std.AutoHashMapUnmanaged(Index, void) = .empty;
    defer seen.deinit(gpa);
    for (sites.items, 0..) |site, i| {
        // Functions with hundreds of calls (big switches) are common.
        const dup = if (i < 16) for (sites.items[0..i]) |prev| {
            if (prev.callee == site.callee) break true;
        } else false else (try seen.getOrPut(gpa, site.callee)).found_existing;
        if (i == 15) for (sites.items[0..16]) |prev| try seen.put(gpa, prev.callee, {});
        if (!dup) try deps.append(gpa, .{ .func_inline = site.callee });
    }
    var splices: std.ArrayList(inline_ir.Splice) = .empty;
    defer splices.deinit(gpa);
    // Each splice's body until `inline_bodies` is final.
    var bodies: std.ArrayList(u32) = .empty;
    defer bodies.deinit(gpa);
    var callee_hash: cache.Hash = 0;
    var size = s.size;
    var straight = s.straight;
    var all = s.inlinable;
    // The callees of calls that stay calls that return a slice of an
    // argument's length, for prove.
    var ret_lens: std.ArrayList(Ir.RetLen) = .empty;
    defer ret_lens.deinit(gpa);
    for (sites.items) |site| {
        const fate = switch (try emit.inlineFate(site.callee)) {
            .fate => |f| f,
            .cycle => Fate.no,
            .busy => return emit.handBack(&ir, &ir_owned, mode),
        };
        const yes = switch (fate) {
            .no => {
                all = false;
                try emit.keepRetLen(&ret_lens, site.callee);
                continue;
            },
            .yes => |y| if (y.size <= emit.inline_budget * inline_ir.factor(site.loops, y.straight)) y else {
                all = false;
                try emit.keepRetLen(&ret_lens, site.callee);
                continue;
            },
        };
        const body = emit.inlineBody(site.callee) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // As for a busy fate.
            error.Busy => return emit.handBack(&ir, &ir_owned, mode),
        } orelse {
            all = false;
            try emit.keepRetLen(&ret_lens, site.callee);
            continue;
        };
        size += yes.size;
        straight = straight and yes.straight;
        callee_hash = cache.hash(@truncate(callee_hash), std.mem.asBytes(&yes.hash)) ^ callee_hash;
        try bodies.append(gpa, body);
        try splices.append(gpa, .{ .site = site, .body = undefined });
    }
    // Up to the loop budget: a caller decides per site.
    const inlinable = all and size <= emit.inline_budget * inline_ir.nested_loop_factor;
    // Of its own body, before the splices.
    const loaded = emit.inline_fates.contains(func);
    const own_hash: cache.Hash = if (inlinable and !loaded) try inline_ir.hashBody(gpa, &zcu.ip, &ir) else 0;
    // `inline_bodies` is final now.
    for (splices.items, bodies.items) |*sp, b| sp.body = &emit.inline_bodies.items[b];
    // Sema recorded the rest of them.
    if (mode != .body) try zcu.addDeps(.{ .func = func }, deps.items);
    if (splices.items.len != 0) try inline_ir.splice(gpa, &ir, splices.items);

    if (loaded) {
        const fate = emit.inline_fates.getPtr(func).?;
        // A function loaded from the cache: make its body.
        if (mode == .body and inlinable and fate.* == .yes) {
            try emit.inline_bodies.append(gpa, ir);
            ir_owned = false;
            fate.yes.body = @intCast(emit.inline_bodies.items.len - 1);
        }
        return true;
    }
    const ret_len1: u32 = if (ret_len) |k| k + 1 else 0;
    if (inlinable) {
        const hash = cache.hash(size | if (straight) Zcu.InlineResult.straight_bit else 0, std.mem.asBytes(&[2]cache.Hash{ own_hash, callee_hash })) ^ emit.inlineSalt() ^ Zcu.InlineResult.retLenHash(ret_len1);
        var copy = ir.instructions.toMultiArrayList();
        try emit.inline_bodies.append(gpa, .{
            .instructions = (try copy.clone(gpa)).slice(),
            .extra = try gpa.dupe(u32, ir.extra),
            .func = func,
            .main_block = ir.main_block,
            .rbrace_line = ir.rbrace_line,
            .rbrace_column = ir.rbrace_column,
        });
        try emit.inline_fates.put(gpa, func, .{ .yes = .{ .size = size, .hash = hash, .straight = straight, .body = @intCast(emit.inline_bodies.items.len - 1) } });
        try zcu.inline_results.put(gpa, func, .{ .size = size, .hash = hash, .ret_len = ret_len1, .straight = straight });
    } else {
        try emit.inline_fates.put(gpa, func, .no);
        // Its callers' calls read its `ret_len` (`func_inline`).
        if (ret_len1 != 0) try zcu.inline_results.put(gpa, func, .{
            .size = Zcu.InlineResult.not_inlinable,
            .hash = emit.inlineSalt() ^ 1 ^ Zcu.InlineResult.retLenHash(ret_len1),
            .ret_len = ret_len1,
        });
    }
    if (mode == .body) return true;
    ir.ret_lens = try ret_lens.toOwnedSlice(gpa);
    ir_owned = false;
    try emit.submit(ir, if (emit.pool != null) try emit.exportsSnapshot() else undefined);
    return true;
}

/// Adds `callee` to `list` if it returns a slice of an argument's length.
fn keepRetLen(emit: *const Emit, list: *std.ArrayList(Ir.RetLen), callee: Index) Allocator.Error!void {
    const k = emit.ret_lens.get(callee) orelse return;
    for (list.items) |r| if (r.callee == callee) return;
    try list.append(emit.gpa, .{ .callee = callee, .arg = k });
}

/// Mixed into every `func_inline` result, so a different budget or
/// variant changes every caller's.
fn inlineSalt(emit: *const Emit) cache.Hash {
    return cache.hash(emit.inline_budget, if (emit.inline_safe) "safe" else "full");
}

/// Turns inlining on, with `budget` and the variant (`inline_safe`).
pub fn enableInlining(emit: *Emit, budget: u32, safe: bool) void {
    emit.inlining = true;
    emit.inline_budget = budget;
    emit.inline_safe = safe;
    emit.zcu.inline_salt = emit.inlineSalt();
}

/// Decides whether `func` is inlinable, bringing it to the end of its
/// analysis first if needed.
pub fn inlineFate(emit: *Emit, func: Index) Allocator.Error!FateResult {
    if (emit.inline_fates.get(func)) |f| return .{ .fate = f };
    if (std.mem.findScalar(Index, emit.inline_active.items, func) != null) return .cycle;
    switch (try emit.zcu.takeFuncBody(func)) {
        .busy => return .busy,
        .failed => try emit.inline_fates.put(emit.gpa, func, .no),
        // Loaded from the cache: its recorded result.
        .done => {
            const res = emit.zcu.inline_results.get(func);
            try emit.inline_fates.put(emit.gpa, func, if (res) |r| if (r.size != Zcu.InlineResult.not_inlinable)
                .{ .yes = .{ .size = r.size, .hash = r.hash, .straight = r.straight, .body = no_body } }
            else
                .no else .no);
            if (res) |r| if (r.ret_len != 0) try emit.ret_lens.put(emit.gpa, func, r.ret_len - 1);
        },
        .analyzed => |ir| if (!try emit.inlineProcess(ir, .generate)) return .busy,
    }
    return .{ .fate = emit.inline_fates.get(func).? };
}

/// The inlinable body of `func`, whose fate is `yes`; for one loaded from
/// the cache, Sema analyzes it again (as it did, and recording nothing
/// new) and its own callees are inlined into it. Null if that failed;
/// `error.Busy` if it would have to wait for a speculation (a replay
/// deciding a fate while the reader is in progress, `Replay.ensure`).
fn inlineBody(emit: *Emit, func: Index) error{ OutOfMemory, Busy }!?u32 {
    const yes = emit.inline_fates.get(func).?.yes;
    if (yes.body != no_body) return yes.body;
    // What Sema records is the cache's already, which a lazy build reads
    // from the manifest only for units without dependencies here.
    const zcu = emit.zcu;
    const unit: Zcu.AnalUnit = .{ .func = func };
    const deps = zcu.deps.get(unit);
    const conditional = zcu.conditional_deps.get(unit);
    defer {
        if (deps) |d| zcu.deps.putAssumeCapacity(unit, d) else _ = zcu.deps.orderedRemove(unit);
        if (conditional) |c| zcu.conditional_deps.putAssumeCapacity(unit, c) else _ = zcu.conditional_deps.remove(unit);
    }
    const ir = Sema.analyzeFuncBody(zcu, func) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Speculation => return error.Busy,
        else => return null,
    };
    if (!try emit.inlineProcess(ir, .body)) return error.Busy;
    const b = emit.inline_fates.get(func).?.yes.body;
    return if (b == no_body) null else b;
}

/// Generates a function whose inlining is done.
fn submit(emit: *Emit, ir_in: Ir, exports: ExportsView) !void {
    const zcu = emit.zcu;
    var ir = ir_in;
    {
        const t0 = std.Io.Timestamp.now(zcu.io, .awake);
        _ = try unroll.run(emit.gpa, &zcu.ip, Zcu.tid, &ir);
        emit.codegen_stats.splits += try sroa.run(emit.gpa, &zcu.ip, Zcu.tid, &ir, &emit.sroa_scratch);
        const t1 = std.Io.Timestamp.now(zcu.io, .awake);
        emit.codegen_stats.sroa_ns += @intCast(t0.durationTo(t1).nanoseconds);
        const st = try rewrite.run(emit.gpa, &zcu.ip, Zcu.tid, &ir, &emit.rewrite_scratch, emit.sroa_scratch.seeds.items);
        emit.codegen_stats.rewrite_ns += @intCast(t1.durationTo(.now(zcu.io, .awake)).nanoseconds);
        emit.codegen_stats.folds += st.folds + st.branches;
    }
    if (emit.bench_irs) |*irs| {
        var list = ir.instructions.toMultiArrayList();
        try irs.append(emit.gpa, .{
            .instructions = (try list.clone(emit.gpa)).slice(),
            .extra = try emit.gpa.dupe(u32, ir.extra),
            .func = ir.func,
            .main_block = ir.main_block,
            .rbrace_line = ir.rbrace_line,
            .rbrace_column = ir.rbrace_column,
        });
    }
    const pool = emit.pool orelse {
        var owned = ir;
        defer owned.deinit(emit.gpa);
        return emit.generateFunction(&owned);
    };
    if (pool.threads == 0 and !pool.late) {
        const t0 = std.Io.Timestamp.now(zcu.io, .awake);
        defer emit.codegen_ns += @intCast(t0.durationTo(.now(zcu.io, .awake)).nanoseconds);
        const out = try runJob(&pool.workers[0], ir, exports);
        try pool.batch.append(emit.gpa, .{ .ir = undefined, .exports = exports, .out = out, .done = true });
        return;
    }
    try pool.batch.append(emit.gpa, .{ .ir = ir, .exports = exports });
    pool.batch_irs += 1;
    if (pool.batch_irs >= pool.batch_target and !pool.late) try publish(pool, emit.gpa);
    if (pool.fuzz != null) fuzzDelay(pool.io, pool.fuzz_rng.random());
}

/// Under `BS_SCHED_FUZZ`: sometimes sleeps up to half a millisecond,
/// sometimes yields.
fn fuzzDelay(io: std.Io, random: std.Random) void {
    switch (random.uintLessThan(u8, 8)) {
        0, 1 => io.sleep(.{ .nanoseconds = random.uintLessThan(u32, 500_000) }, .awake) catch {}, // ziglint-ignore: Z026 -- only jitter for the test
        2, 3 => std.Thread.yield() catch {}, // ziglint-ignore: Z026 -- only jitter for the test
        else => {},
    }
}

/// How many jobs the Sema thread hands over at once.
const batch_len = 16;

fn publish(pool: *Pool, gpa: Allocator) !void {
    pool.mutex.lockUncancelable(pool.io);
    defer pool.mutex.unlock(pool.io);
    try pool.jobs.appendSlice(gpa, pool.batch.items);
    pool.batch.clearRetainingCapacity();
    pool.batch_irs = 0;
    if (pool.fuzz != null) pool.batch_target = 1 + pool.fuzz_rng.random().uintLessThan(usize, 32);
    if (pool.sleeping != 0) pool.work.broadcast(pool.io);
}

/// Sink callback from `Zcu.analyzeAll` when its function queue is empty:
/// waits for CodeGen, merges its output, and hands the compiler_rt
/// functions requested so far to the Zcu.
pub fn sync(emit: *Emit, zcu: *Zcu) !void {
    try emit.mergeJobs();
    if (emit.c_batch) |b| {
        emit.c_batch = null;
        const in = emit.inputs.?;
        const result = try b.wait();
        // In `CSource.objectPaths` order, as the cache's relink links them.
        for ([2][]const CSource.Object{ result.objects, result.runtime_objects }) |list| for (list) |o| in.addObject(o.path, o.bytes) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            // As `convertInputs` reports the inputs' problems.
            else => try zcu.addError(0, .{ .start = 0, .end = 0, .main = 0 }, "{s}", .{try emit.allocator().print("unable to link '{s}': {t}", .{ o.path, err })}),
        };
        for ((try b.wait()).archives) |a| in.addArchive(a.path, a.bytes, true) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => try zcu.addError(0, .{ .start = 0, .end = 0, .main = 0 }, "{s}", .{try emit.allocator().print("unable to link '{s}': {t}", .{ a.path, err })}),
        };
    }
    if (emit.inputs) |in| switch (in) {
        inline else => |p| try emit.pullInputs(p),
    };
    for (emit.rt_pending.keys()) |key| _ = try zcu.requestCompilerRtKey(key);
    emit.rt_pending.clearRetainingCapacity();
}

/// Pulls the archive members the inputs and the Zig code's externs need so
/// far, and requests the compiler_rt functions that the new objects call
/// and nothing else defines, so that analysis generates them.
fn pullInputs(emit: *Emit, in: anytype) !void {
    const ctx: InputResolver = .{ .emit = emit };
    // The symbols, not their offset slots' names.
    var wanted: std.ArrayList([]const u8) = .empty;
    defer wanted.deinit(emit.gpa);
    for (emit.externs.keys()) |slot| try wanted.append(emit.gpa, parseExternSlot(slot)[0]);
    const first = try in.pull(wanted.items, ctx);
    if (first == emit.inputs_requested) return;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(emit.gpa);
    try in.undefinedSince(emit.inputs_requested, &names, emit.gpa);
    emit.inputs_requested = in.objects.items.len;
    // As the link's own requests (`.link` refs), which the cache's link
    // node keeps, so an edit build can tell whether the inputs need more.
    std.debug.assert(emit.owner == .link);
    for (names.items) |name| if (!emit.libcFirst(name)) {
        _ = try emit.requestCompilerRtExport(name);
    };
}

/// Link inputs: ELF objects and archives on x86_64-linux, Mach-O ones on
/// aarch64-macos, with the same entry points.
pub const Inputs = union(enum) {
    elf: *ElfInput,
    macho: *MachOInput,

    pub fn addObject(in: Inputs, path: []const u8, bytes: []const u8) !void {
        switch (in) {
            inline else => |p| try p.addObject(path, bytes),
        }
    }

    /// `runtime`: ELF's runtime archives, which the link adds last.
    pub fn addArchive(in: Inputs, path: []const u8, bytes: []const u8, runtime: bool) !void {
        switch (in) {
            .elf => |p| try p.addArchive(path, bytes, runtime),
            .macho => |p| try p.addArchive(path, bytes),
        }
    }
};

/// How names the objects reference but do not define resolve on the Zig
/// side (`ElfInput.convert`).
const InputResolver = struct {
    emit: *Emit,

    pub fn zigExport(r: InputResolver, name: []const u8) !?SymbolKey {
        if (r.emit.asm_symbols.get(name)) |t| if (t.addend == 0) return t.key;
        return r.emit.userExport(name);
    }

    /// compiler_rt's, and the bounds of the init and fini arrays.
    pub fn rtExport(r: InputResolver, name: []const u8) !?SymbolKey {
        if (arrayBound(name)) |key| return key;
        if (Zcu.compilerRtExport(name) == null or r.emit.libcFirst(name)) return null;
        return r.emit.rtExport(name);
    }

    /// With `-lc`, the shared libraries' and glibc's symbols, imported. A
    /// shared object imports every name nothing in it defines, as its
    /// Zig code does (`exportTarget`). On aarch64-macos, every name is
    /// libSystem's, as the Zig code's are.
    pub fn importSym(r: InputResolver, name: []const u8, weak: bool) !?SymbolKey {
        if (r.emit.zcu.ip.target == .aarch64_macos) {
            const result = try r.emit.useImport(name, .{ .weak = weak });
            return result;
        }
        if (r.emit.shared and std.mem.eql(u8, name, "_DYNAMIC")) return ElfDynamic.dynamic_key; // ziglint-ignore: Z010 -- a declaration of ElfDynamic, not of SymbolKey
        if (!r.emit.shared and !r.emit.libraryDefines(name)) return null;
        const result = try r.emit.useImport(name, .{ .weak = weak, .tls = r.emit.sharedTls(name) });
        return result;
    }

    /// The executable's copy of a shared library's data object `name`, an
    /// import already (`importSym`), or null if it is not one. The copy
    /// takes the import's key, so every reference to the import uses it.
    /// A weak name that nothing defines, which a C-only executable
    /// imports for its GOT loads and calls, as lld does; null where it
    /// resolves to 0, as in upstream's own links of Zig code.
    pub fn weakImport(r: InputResolver, name: []const u8) !?SymbolKey {
        if (!r.emit.lld or r.emit.shared) return null;
        const result = try r.emit.useImport(name, .{ .weak = true });
        return result;
    }

    pub fn copySym(r: InputResolver, name: []const u8) !?SymbolKey {
        // A shared object copies nothing: its data references to another
        // module's symbols go through the GOT.
        if (r.emit.shared) return null;
        const size: u64 = if (Glibc.sharedSymbol(r.emit.shared_libs, name)) |s|
            if (s.sym.object) s.sym.size else 0
        else s: {
            const sym = r.emit.glibc.?.get(name).?;
            break :s if (sym.object) sym.size else 0;
        };
        if (size == 0) return null;
        try r.emit.copies.put(r.emit.gpa, r.emit.imports.getKey(name).?, size);
        return importKey(name);
    }
};

/// Converts the inputs into atoms, after the externs' slots took their
/// definitions. Returns false after reporting what it could not link.
fn convertInputs(emit: *Emit, inputs: Inputs) !bool {
    const in = switch (inputs) {
        .elf => |p| p,
        .macho => |p| return emit.convertMachOInputs(p),
    };
    // What a version script makes local is hidden, as lld makes it: the
    // objects reach it directly, not through the loader, and it is local
    // in .symtab and out of the exports.
    if (emit.shared) if (emit.version_script) |vs| {
        var locals: std.ArrayList([]const u8) = .empty;
        var defs = in.defs.keyIterator();
        var commons = in.commons.keys();
        while (true) {
            const name = if (defs.next()) |k| k.* else if (commons.len > 0) n: {
                defer commons = commons[1..];
                break :n commons[0];
            } else break;
            if (vs.place(name) != VersionScript.local) continue;
            const v = try in.visibility.getOrPut(in.arena, name);
            if (!v.found_existing or v.value_ptr.* != 1) v.value_ptr.* = 2;
            try locals.append(emit.allocator(), name);
        }
        emit.version_locals = locals.items;
    };
    const converted = try in.convert(InputResolver{ .emit = emit });
    for (in.errors.items) |msg| try emit.zcu.addError(0, .{ .start = 0, .end = 0, .main = 0 }, "{s}", .{msg});
    if (in.errors.items.len != 0) return false;
    emit.owner = .input;
    defer emit.owner = .link;
    for (converted.atoms) |atom| try emit.addAtom(atom);
    for (emit.copies.keys(), emit.copies.values()) |name, size| try emit.addAtom(.{
        .key = importKey(name),
        .name = name,
        .section = .bss,
        // As the object's own alignment, which abilists does not give:
        // the largest power of two dividing its size, up to 32.
        .alignment = .fromByteUnits(@as(u64, 1) << @min(@ctz(size), 5)),
        .zero_fill = size,
    });
    try emit.error_values.appendSlice(emit.gpa, converted.values);
    emit.input_symbols = converted.symbols;
    emit.input_sections = converted.sections;
    // A shared object exports the objects' globals too, as upstream's.
    if (emit.shared) try emit.exports.appendSlice(emit.gpa, try in.dynamicExports(InputResolver{ .emit = emit }));
    if (!emit.shared and (emit.shared_libs.len != 0 or emit.rdynamic)) emit.input_exports = try in.dynamicExports(InputResolver{ .emit = emit });
    return true;
}

/// `convertInputs` for Mach-O inputs, which have no sections to copy and
/// no shared libraries to copy data from.
fn convertMachOInputs(emit: *Emit, in: *MachOInput) !bool {
    const converted = try in.convert(InputResolver{ .emit = emit });
    for (in.errors.items) |msg| try emit.zcu.addError(0, .{ .start = 0, .end = 0, .main = 0 }, "{s}", .{msg});
    if (in.errors.items.len != 0) return false;
    emit.owner = .input;
    defer emit.owner = .link;
    for (converted.atoms) |atom| try emit.addAtom(atom);
    try emit.error_values.appendSlice(emit.gpa, converted.values);
    emit.input_symbols = converted.symbols;
    // A dylib exports the objects' globals too, as upstream's.
    if (emit.shared) try emit.exports.appendSlice(emit.gpa, try in.dynamicExports(InputResolver{ .emit = emit }));
    return true;
}

/// Generates a function into this Emit.
fn generateFunction(emit: *Emit, ir: *const Ir) Allocator.Error!void {
    emit.owner = .{ .unit = .{ .func = ir.func } };
    defer emit.owner = .link;
    const io = emit.zcu.io;
    const t0 = std.Io.Timestamp.now(io, .awake);
    defer emit.codegen_ns += @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
    // The IR is this job's own.
    if (emit.forward_on) emit.codegen_stats.forwarded += try forward.run(emit.gpa, &emit.zcu.ip, @constCast(ir), &emit.forward_scratch);
    const t1 = std.Io.Timestamp.now(io, .awake);
    emit.codegen_stats.forward_ns += @intCast(t0.durationTo(t1).nanoseconds);
    const st: prove.Stats = if (!emit.prove_on) .{} else try prove.run(emit.gpa, &emit.zcu.ip, @constCast(ir), &emit.prove_scratch, emit.fuzz);
    emit.codegen_stats.prove_ns += @intCast(t1.durationTo(.now(io, .awake)).nanoseconds);
    emit.codegen_stats.checks += st.checks;
    emit.codegen_stats.proven += st.proven;
    const generate = switch (emit.zcu.ip.target) {
        .x86_64_linux => &CodeGen.generate,
        .aarch64_macos, .aarch64_linux => &CodeGenA64.generate,
    };
    generate(emit, ir) catch |err| switch (err) {
        error.CodegenFail => emit.failed = true,
        else => |e| return e,
    };
}

/// Merges the output of the jobs handed over so far, in job order, once
/// they have finished. On the Sema thread, before anything else writes to
/// the main Emit (`syncPending`), so the result does not depend on when
/// the workers ran.
fn mergeJobs(emit: *Emit) Allocator.Error!void {
    const pool = emit.pool orelse return;
    if (pool.jobs.items.len + pool.batch.items.len == 0) return;
    const io = pool.io;
    const t0 = std.Io.Timestamp.now(io, .awake);
    defer emit.codegen_ns += @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
    // Jobs not handed over yet run here, while the workers finish theirs,
    // rather than wake a worker and wait: an edit build, which loads most
    // units from the cache, merges after nearly every function it
    // generates.
    if (pool.fuzz != null and pool.threads != 0 and pool.fuzz_rng.random().boolean()) try publish(pool, emit.gpa);
    const own: u32 = @intCast(pool.threads);
    for (pool.batch.items) |*job| if (!job.done) {
        job.out = try runJob(&pool.workers[own], job.ir, job.exports);
        job.worker = own;
        job.done = true;
    };
    if (pool.jobs.items.len != 0) {
        pool.mutex.lockUncancelable(io);
        while (pool.finished < pool.jobs.items.len) pool.idle.waitUncancelable(io, &pool.mutex);
        pool.mutex.unlock(io);
    }
    if (pool.err) |err| return err;
    for (pool.jobs.items) |*job| try emit.mergeOut(&pool.workers[job.worker], job.out);
    for (pool.batch.items) |*job| try emit.mergeOut(&pool.workers[job.worker], job.out);
    pool.batch.clearRetainingCapacity();
    pool.batch_irs = 0;
    pool.mutex.lockUncancelable(io);
    pool.jobs.clearRetainingCapacity();
    pool.taken = 0;
    pool.finished = 0;
    pool.mutex.unlock(io);
    // The workers are idle until the Sema thread hands over more.
    for (pool.workers) |*w| {
        w.atoms.clearRetainingCapacity();
        w.atom_owners.clearRetainingCapacity();
        w.debug.clearRetainingCapacity();
        w.content_uses.clearRetainingCapacity();
        w.unit_refs.clearRetainingCapacity();
        w.side.clearRetainingCapacity();
        w.codegen_errors.clearRetainingCapacity();
        inline for (@typeInfo(CodeGenStats).@"struct".field_names) |name| @field(emit.codegen_stats, name) += @field(w.codegen_stats, name);
        w.codegen_stats = .{};
    }
}

/// Merges what one job added to worker Emit `w`, as if it had been
/// generated into this Emit. A worker deduplicates content-addressed atoms
/// and memoizes constants itself; since a worker's jobs are in job order,
/// the first job to use a constant has its atom, which this keeps unless
/// an earlier job's or a loaded unit's is here already, and a request that
/// a worker repeats from its memo was made by an earlier job.
fn mergeOut(emit: *Emit, w: *const Emit, out: Out) Allocator.Error!void {
    const gpa = emit.gpa;
    const zcu = emit.zcu;
    // A loaded unit's atoms can be next (`syncPending`).
    const saved = emit.owner;
    defer emit.owner = saved;
    for (w.side.items[out.start.side..out.end.side]) |s| switch (s) {
        .rt => |key| _ = try emit.requestRtKey(key),
    };
    var d = out.start.debug;
    for (out.start.atoms..out.end.atoms) |i| {
        const atom = w.atoms.items[i];
        const owner = w.atom_owners.items[i];
        if (owner == .content and (try emit.content_keys.getOrPut(gpa, atom.key)).found_existing) continue;
        if (d < out.end.debug and w.debug.items[d].atom == i) {
            var dbg = w.debug.items[d];
            dbg.atom = @intCast(emit.atoms.items.len);
            try emit.debug.append(gpa, dbg);
            d += 1;
        }
        emit.owner = owner;
        try emit.appendAtom(atom);
    }
    try emit.content_uses.appendSlice(gpa, w.content_uses.items[out.start.content_uses..out.end.content_uses]);
    const refs = w.unit_refs.items[out.start.unit_refs..out.end.unit_refs];
    try emit.unit_refs.appendSlice(gpa, refs);
    for (refs) |ur| switch (ur.ref) {
        .nav => |n| try emit.navs.put(gpa, n, {}),
        .err => |e| try emit.errors.put(gpa, e, {}),
        .ext => |x| {
            const gop = try emit.externs.getOrPut(gpa, x.name);
            if (!gop.found_existing) {
                gop.value_ptr.* = x.weak;
            } else if (!x.weak) gop.value_ptr.* = false;
        },
        .import => |x| {
            const gop = try emit.imports.getOrPut(gpa, x.name);
            gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.merge(x.flags) else x.flags;
        },
        // In `side`.
        .rt => {},
        .error_names => emit.uses_error_names = true,
    };
    for (w.codegen_errors.items[out.start.errors..out.end.errors]) |e| {
        var copy = e;
        copy.msg = try zcu.arena.allocator().dupe(u8, e.msg);
        try zcu.errors.append(zcu.gpa, copy);
    }
    if (out.failed) emit.failed = true;
}

/// Merges CodeGen's pending output before the main Emit changes in
/// another way, as the serial order has it.
fn syncPending(emit: *Emit) Allocator.Error!void {
    if (emit.pool) |pool| if (pool.jobs.items.len + pool.batch.items.len != 0) try emit.mergeJobs();
}

/// Starts a job for unit `unit`, which the cache loads: returns the Emit
/// its atoms and requests go to, with `unit` as owner, until `endLoad`.
/// That is the pool's `loads` Emit, whose output `mergeOut` moves into
/// this one in job order, as it does a worker's; without a pool, this
/// Emit. Only the Sema thread loads.
pub fn beginLoad(emit: *Emit, unit: Zcu.AnalUnit) *Emit {
    const pool = emit.pool orelse {
        emit.owner = .{ .unit = unit };
        return emit;
    };
    const l = &pool.workers[pool.workers.len - 1];
    l.owner = .{ .unit = unit };
    pool.load_start = l.marks();
    return l;
}

/// How many atoms loaded units' jobs hold before a merge waits for the
/// functions handed over before them.
const max_pending_loads = 8192;

/// Ends the load `beginLoad` started: a job done already.
pub fn endLoad(emit: *Emit) !void {
    const pool = emit.pool orelse {
        emit.owner = .link;
        return;
    };
    const index: u32 = @intCast(pool.workers.len - 1);
    const l = &pool.workers[index];
    l.owner = .link;
    const out: Out = .{ .start = pool.load_start, .end = l.marks(), .failed = false };
    if (std.meta.eql(out.start, out.end)) return;
    try pool.batch.append(emit.gpa, .{ .ir = undefined, .exports = undefined, .worker = index, .out = out, .done = true });
    // With no function waiting for CodeGen the merge waits for nothing.
    // Merging then, or once `loads` holds many atoms, keeps it from
    // holding a whole build's.
    if ((pool.jobs.items.len == 0 and pool.batch_irs == 0) or l.atoms.items.len >= max_pending_loads) try emit.mergeJobs();
}

/// The exports for a job handed over now: copied when they changed, so
/// that a worker reads them as they were, whenever it runs.
fn exportsSnapshot(emit: *Emit) !ExportsView {
    const ip = &emit.zcu.ip;
    const xs = emit.zcu.exports.items;
    const snap = emit.export_snap;
    if (snap.list.len == xs.len) {
        if (emit.export_snap_unresolved == 0) return snap;
        for (snap.list, snap.resolved.?) |x, r| {
            if (!r and ip.getNav(x.target.nav).status == .resolved) break;
        } else return snap;
    }
    const arena = emit.allocator();
    const list = try arena.dupe(Zcu.Export, xs);
    const resolved = try arena.alloc(bool, xs.len);
    var unresolved: u32 = 0;
    for (list, resolved) |x, *r| {
        r.* = x.target != .nav or ip.getNav(x.target.nav).status == .resolved;
        unresolved += @intFromBool(!r.*);
    }
    emit.export_snap = .{ .list = list, .resolved = resolved };
    emit.export_snap_unresolved = unresolved;
    return emit.export_snap;
}

/// The exports CodeGen sees (`ExportsView`).
pub fn exportsView(emit: *const Emit) ExportsView {
    return if (emit.is_worker) emit.exports_view else .{ .list = emit.zcu.exports.items };
}

/// `Zcu.addError`, from CodeGen: a worker keeps the error for the merge.
pub fn addError(emit: *Emit, file_index: u32, span: std.zig.Ast.Span, comptime fmt: []const u8, args: anytype) !void {
    if (!emit.is_worker) return emit.zcu.addError(file_index, span, fmt, args);
    try emit.codegen_errors.append(emit.gpa, .{
        .file = file_index,
        .span = span,
        .msg = try emit.allocator().print(fmt, args),
        .code = comptime Diag.formatCode(fmt),
    });
}

/// `BS_BENCH_CODEGEN=n`: generates every function captured during
/// analysis again, `runs` times, each into a fresh Emit, and prints the
/// fastest run's stages. Code generation reads the Zcu without changing
/// what a later build of the same functions produces.
pub fn benchCodegen(emit: *Emit, runs: u32) !void {
    const irs = emit.bench_irs orelse return;
    var best: ?CodeGenStats = null;
    for (0..runs) |_| {
        var e: Emit = .init(emit.gpa, emit.zcu);
        defer e.deinit();
        e.fuzz = emit.fuzz;
        e.prove_on = emit.prove_on;
        e.forward_on = emit.forward_on;
        for (irs.items) |*ir| try e.generateFunction(ir);
        const s = e.codegen_stats;
        if (best == null or s.build_ns + s.alloc_ns + s.emit_ns < best.?.build_ns + best.?.alloc_ns + best.?.emit_ns) best = s;
    }
    if (best) |s| s.print("bench-codegen (fastest run)");
}

/// Lowers the remaining data and orders the atoms for `link`. Returns
/// false (after reporting errors to the Zcu) if it could not. Afterwards
/// the atoms and the Zcu are only read, so the cache can record the build
/// while it links.
pub fn finish(emit: *Emit) !bool {
    const zcu = emit.zcu;
    const ip = &zcu.ip;
    try emit.mergeJobs();
    emit.analyzing = false;
    // The compiler_rt variables the link resolved names to (fmv.zig's
    // `__cpu_model`), as their functions are queued (`resolveCompilerRt`).
    for (zcu.rt_helpers.values()) |nav_index| {
        if (nav_index == .none) continue;
        const nav = ip.getNav(nav_index);
        if (nav.status == .resolved and ip.keyTag(nav.val) != .func) try emit.navs.put(emit.gpa, nav_index, {});
    }
    // The threads go back to the Io for the cache's recording and the
    // link, which run concurrently.
    if (emit.pool) |pool| stopWorkers(pool);
    if (emit.lazy) {
        try emit.lowerNavs();
        if (emit.failed) return false;
        try groupByOwner(emit.gpa, &emit.atoms, &emit.atom_owners, &emit.debug);
        try emit.nameAtoms();
        return true;
    }
    // Before the slots, which can bind to its symbols.
    if (!try global_asm.assembleAll(emit)) return false;
    // Before the declarations: a slot can request an exported one.
    if (!try emit.lowerExternSlots()) return false;
    if (emit.inputs) |in| if (!try emit.convertInputs(in)) return false;
    // An executable's too, with inputs: the cache resolves their
    // references to Zig's exports again when it relinks; and with shared
    // libraries, which may name them (`Glibc.dynamicOptions`).
    if (emit.obj or emit.inputs != null or emit.shared_libs.len != 0) try emit.findExports();
    try emit.lowerNavs();
    if (emit.uses_error_names) try emit.emitErrorNameTable();

    // On macOS, libSystem's start calls the C `main` that std.start
    // exports.
    const entry_name = emit.entry_name orelse if (ip.target == .aarch64_macos) "main" else "_start";
    var entry: ?SymbolKey = null;
    for (zcu.exports.items) |e| {
        if (e.target != .nav) continue;
        const nav = ip.getNav(e.target.nav);
        if (nav.status != .resolved) continue;
        if (std.mem.eql(u8, ip.stringSlice(e.name), entry_name) and ip.keyTag(nav.val) == .func) {
            entry = try emit.funcKey(nav.val);
        }
    }
    if (emit.failed) return false;
    // An entry point an object defines: C's `main` in an executable whose
    // `main` is C's (`main.Options.c_root`), which dyld calls, or the
    // `_start` of an object that `bs test-obj` built. At an alias when it
    // is inside its section's atom.
    const Def = struct { key: SymbolKey, offset: u64 };
    if (entry == null) if (emit.inputs) |in| if (switch (in) {
        inline else => |p| if (try p.lookup(entry_name)) |t| Def{ .key = t.key, .offset = t.offset } else null,
    }) |t| {
        if (t.offset == 0) entry = t.key else {
            const key: SymbolKey = .fromName("bs.entry");
            try emit.aliases.append(emit.gpa, .{ .key = key, .target = t.key, .addend = @intCast(t.offset) });
            entry = key;
        }
    };
    emit.entry = entry;
    if (entry == null and !emit.obj) {
        try zcu.addError(0, .{ .start = 0, .end = 0, .main = 0 }, "bs requires the root file to export '{s}' (std.start is not supported yet)", .{entry_name});
        return false;
    }

    try groupByOwner(emit.gpa, &emit.atoms, &emit.atom_owners, &emit.debug);
    try emit.nameAtoms();
    // An object's symbols by name, not in the order analysis or the
    // cache's loading found them, so that the object is a function of its
    // atoms as the link order is (`groupByOwner`).
    if (emit.obj) {
        std.mem.sortUnstable(ElfObject.Export, emit.exports.items, {}, struct {
            fn lessThan(_: void, a: ElfObject.Export, b: ElfObject.Export) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);
        const Names = struct {
            keys: []const []const u8,
            const Self = @This();
            pub fn lessThan(c: Self, a: usize, b: usize) bool {
                return std.mem.lessThan(u8, c.keys[a], c.keys[b]);
            }
        };
        emit.imports.sort(Names{ .keys = emit.imports.keys() });
    }

    // Error codes: the order names were first interned, starting at 1.
    for (emit.errors.keys()) |name| {
        try emit.error_values.append(emit.gpa, .{ .key = errorKey(ip, name), .value = try ip.errorValue(name) });
    }
    try emit.error_values.append(emit.gpa, .{ .key = errors_len, .value = ip.error_names.items.len - 1 });
    return true;
}

/// The name of a declaration's atom until `nameAtoms`: CodeGen runs while
/// analysis can still rename the types names come from
/// (docs/slop/architecture.md, "Type names").
pub const name_later: []const u8 = "(named later)";

/// Names the atoms of declarations and functions, those this build made
/// and those it loaded, from the final names (docs/slop/architecture.md, "Type
/// names"). A function's symbol name is upstream's: the declaration's
/// qualified name, with `__func_` and a stable hash for an instance of a
/// generic function (upstream numbers them by InternPool index), or its
/// export name. Names may repeat, like upstream's local symbols; the
/// atom's key is its identity. Fills `atom_names`.
fn nameAtoms(emit: *Emit) !void {
    const ip = &emit.zcu.ip;
    const arena = emit.allocator();
    try emit.atom_names.resize(emit.gpa, emit.atoms.items.len);
    @memset(emit.atom_names.items, .{});
    // The last export of a declaration names its function.
    var exported: std.AutoHashMapUnmanaged(InternPool.NavIndex, InternPool.String) = .empty;
    defer exported.deinit(emit.gpa);
    for (emit.zcu.exports.items) |x| if (x.target == .nav) try exported.put(emit.gpa, x.target.nav, x.name);
    // Declarations share their parents' names.
    var parents: std.AutoHashMapUnmanaged(Index, []const u8) = .empty;
    defer parents.deinit(emit.gpa);
    var aw: std.Io.Writer.Allocating = .init(emit.gpa);
    defer aw.deinit();
    for (emit.atoms.items, emit.atom_owners.items, emit.atom_names.items) |*atom, owner, *info| {
        const nav_index, const func_index: Index = switch (owner) {
            .unit => |unit| switch (unit) {
                .nav_val => |nav| .{ nav, .none },
                // Not the coverage arrays (`addCoverage`).
                .func => |f| if (atom.section == .text) .{ ip.keyPayload(.func, f).owner_nav, f } else continue,
                else => continue,
            },
            .content, .link, .input => continue,
        };
        const generic = func_index != .none and ip.keyPayload(.func, func_index).generic_owner != .none;
        if (func_index != .none and !generic) if (exported.get(nav_index)) |name| {
            atom.name = ip.stringSlice(name);
            continue;
        };
        const nav = ip.getNav(nav_index);
        const gop = try parents.getOrPut(emit.gpa, nav.parent);
        if (!gop.found_existing) {
            aw.clearRetainingCapacity();
            print.writeTypeName(ip, nav.parent, &aw.writer, .render) catch return error.OutOfMemory;
            gop.value_ptr.* = try arena.dupe(u8, aw.written());
        }
        info.* = .{ .parent = nav.parent, .prefix_len = @intCast(gop.value_ptr.len) };
        atom.name = if (generic)
            try arena.print("{s}.{s}__func_{x:0>8}", .{ gop.value_ptr.*, ip.stringSlice(nav.name), @as(u32, @truncate(ip.stableHash(func_index))) })
        else
            try arena.print("{s}.{s}", .{ gop.value_ptr.*, ip.stringSlice(nav.name) });
    }
}

/// Links the atoms `finish` prepared into `sub_path`. Returns false, after
/// printing the error, if the link failed.
pub fn link(emit: *Emit, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !bool {
    var diag: Elf.Diagnostic = .{};
    // Source paths are as the compiler opened them, relative to the cwd.
    const cwd = try std.process.currentPathAlloc(io, emit.gpa);
    defer emit.gpa.free(cwd);
    if (emit.zcu.ip.target == .aarch64_macos and emit.obj and !emit.shared) {
        const imports = try emit.gpa.alloc(ElfObject.Import, emit.imports.count());
        defer emit.gpa.free(imports);
        for (imports, emit.imports.keys(), emit.imports.values()) |*imp, name, f| imp.* = .{ .key = importKey(name), .name = name, .weak = f.weak };
        MachOObject.link(emit.gpa, io, dir, sub_path, emit.atoms.items, .{ .min_os = emit.macos_min, .values = emit.error_values.items, .exports = emit.exports.items, .imports = imports, .aliases = emit.aliases.items, .diag = &diag }) catch |err| {
            try emit.linkFailed(err, diag);
            return false;
        };
        return true;
    }
    if (emit.zcu.ip.target == .aarch64_macos) {
        const imports = try emit.gpa.alloc(MachO.Import, emit.imports.count());
        defer emit.gpa.free(imports);
        // Each import binds to the first library that exports its name, the
        // linked ones before the implicit ones (`MachODylib.implicit`),
        // which get load commands only if an import binds to them.
        const ordinals = try emit.gpa.alloc(u16, emit.macho_libs.len);
        defer emit.gpa.free(ordinals);
        @memset(ordinals, 0);
        var n_libs: u16 = 0;
        for (emit.macho_libs, ordinals) |lib, *o| if (!lib.implicit) {
            n_libs += 1;
            o.* = n_libs;
        };
        for (imports, emit.imports.keys()) |*imp, name| {
            const i = for (emit.macho_libs, 0..) |l, i| {
                if (l.exports.contains(name)) break i;
            } else null;
            if (i) |k| if (ordinals[k] == 0) {
                n_libs += 1;
                ordinals[k] = n_libs;
            };
            imp.* = .{ .key = importKey(name), .name = name, .lib = if (i) |k| ordinals[k] else 0 };
        }
        const libs = try emit.gpa.alloc(MachO.Lib, n_libs);
        defer emit.gpa.free(libs);
        for (emit.macho_libs, ordinals) |lib, o| if (o != 0) {
            libs[o - 1] = .{ .install_name = lib.install_name, .current_version = lib.current_version, .compatibility_version = lib.compatibility_version };
        };
        var rpaths: std.ArrayList([]const u8) = .empty;
        defer rpaths.deinit(emit.gpa);
        if (emit.runpath) |r| {
            var it = std.mem.splitScalar(u8, r, ':');
            while (it.next()) |p| try rpaths.append(emit.gpa, p);
        }
        // A dylib exports what other images can bind to: not hidden
        // symbols, such as compiler_rt's.
        var dylib_exports: std.ArrayList(MachO.Export) = .empty;
        defer dylib_exports.deinit(emit.gpa);
        if (emit.shared) for (emit.exports.items) |x| if (x.visibility != .hidden)
            try dylib_exports.append(emit.gpa, .{ .key = x.key, .name = x.name, .offset = x.offset, .weak = x.weak });
        const dylib: MachO.Dylib = .{ .install_name = emit.install_name orelse sub_path, .current_version = emit.dylib_version, .exports = dylib_exports.items };
        MachO.link(emit.gpa, io, dir, sub_path, emit.atoms.items, .{ .entry = emit.entry orelse undefined, .dylib = if (emit.shared) &dylib else null, .libs = libs, .rpaths = rpaths.items, .imports = imports, .values = emit.error_values.items, .diag = &diag, .debug = if (emit.strip) &.{} else emit.debug.items, .comp_dir = cwd, .stack_size = emit.stack_size, .min_os = emit.macos_min, .sdk = emit.macos_sdk, .aliases = emit.aliases.items, .local_symbols = emit.input_symbols }) catch |err| {
            try emit.linkFailed(err, diag);
            return false;
        };
        return true;
    }
    const options: Elf.Options = .{ .entry = emit.entry, .arch = if (emit.zcu.ip.target.arch() == .aarch64) .aarch64 else .x86_64, .values = emit.error_values.items, .diag = &diag, .debug = emit.debug.items, .comp_dir = cwd, .stack_size = emit.stack_size, .pic = emit.pic != .none, .local_symbols = emit.input_symbols, .input_sections = emit.input_sections, .aliases = emit.aliases.items, .strip = emit.strip };
    const imports = try emit.gpa.alloc(ElfObject.Import, emit.imports.count());
    defer emit.gpa.free(imports);
    for (imports, emit.imports.keys(), emit.imports.values()) |*imp, name, f| imp.* = .{ .key = importKey(name), .name = name, .weak = f.weak, .hidden = f.hidden, .tls = f.tls };
    const result = if (if (emit.shared) null else emit.glibc) |g| exe: {
        // The copied imports, moved to the end, are the executable's own
        // symbols.
        var n_imports: usize = 0;
        for (imports, 0..) |imp, i| if (!emit.copies.contains(imp.name)) {
            std.mem.swap(ElfObject.Import, &imports[n_imports], &imports[i]);
            n_imports += 1;
        };
        var arena_state: std.heap.ArenaAllocator = .init(emit.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const defined = try std.mem.concat(arena, ElfDynamic.Export, &.{ emit.exports.items, emit.input_exports });
        var dynamic = g.dynamicOptions(arena, imports[0..n_imports], imports[n_imports..], defined, emit.shared_libs, emit.lld, emit.rdynamic) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            // Imports come from the shared libraries and glibc only
            // (`libraryDefines`), but a unit an edit build loaded may
            // import a name a changed library no longer defines.
            error.NotInGlibc => {
                for (imports) |imp| if (!emit.libraryDefines(imp.name)) {
                    std.debug.print("error: undefined symbol: {s} (no shared library or glibc defines it)\n", .{imp.name});
                    break;
                };
                return false;
            },
        };
        dynamic.runpath = emit.runpath;
        var exe_options = options;
        exe_options.dynamic = &dynamic;
        break :exe Elf.link(emit.gpa, io, dir, sub_path, emit.atoms.items, exe_options);
    } else if (emit.shared) shared: {
        // With glibc, its libraries are needed and its symbols versioned.
        var arena_state: std.heap.ArenaAllocator = .init(emit.gpa);
        defer arena_state.deinit();
        const exports = if (emit.version_script) |vs| try emit.applyVersionScript(arena_state.allocator(), vs, sub_path) orelse return false else emit.exports.items;
        var dynamic: ElfDynamic.Options = if (emit.glibc) |g| try g.sharedObjectOptions(arena_state.allocator(), imports, exports, emit.shared_libs) else .{ .imports = imports };
        dynamic.exports = exports;
        if (emit.version_script) |vs| {
            const names = try vs.names(arena_state.allocator());
            if (names.len != 0) dynamic.versions = .{ .base = emit.soname orelse std.Io.Dir.path.basename(sub_path), .names = names };
        }
        dynamic.soname = emit.soname;
        dynamic.runpath = emit.runpath;
        var shared_options = options;
        shared_options.base_address = 0;
        shared_options.dynamic = &dynamic;
        break :shared Elf.link(emit.gpa, io, dir, sub_path, emit.atoms.items, shared_options);
    } else if (emit.obj)
        ElfObject.link(emit.gpa, io, dir, sub_path, emit.atoms.items, options, .{ .exports = emit.exports.items, .imports = imports })
    else
        Elf.link(emit.gpa, io, dir, sub_path, emit.atoms.items, options);
    result catch |err| {
        try emit.linkFailed(err, diag);
        return false;
    };
    return true;
}

/// The exports with the places version script `vs` gives them: a local
/// one hidden (in no .dynsym), a versioned one with its node's index.
/// Null after reporting a name the script gives a version that nothing
/// defines, as lld refuses it without `--undefined-version`.
fn applyVersionScript(emit: *Emit, arena: Allocator, vs: *const VersionScript, sub_path: []const u8) !?[]const ElfDynamic.Export {
    const exports = try arena.dupe(ElfDynamic.Export, emit.exports.items);
    const names = try arena.alloc([]const u8, exports.len);
    for (names, exports) |*n, x| n.* = x.name;
    const places = try arena.alloc(u16, exports.len);
    const unmatched = try vs.assign(arena, names, emit.version_locals, places);
    if (unmatched.len != 0 and !emit.allow_undefined_version) {
        const pat = unmatched[0];
        const node = find: for (vs.nodes) |n| {
            for (n.globals) |p| if (p.offset == pat.offset) break :find n.name;
            for (n.locals) |p| if (p.offset == pat.offset) break :find "local";
        } else "";
        const more = if (unmatched.len > 1) try arena.print(" (and {d} more names)", .{unmatched.len - 1}) else "";
        emit.link_diagnostic = .{
            .code = .@"version-script",
            .loc = versionScriptLoc(vs.path, vs.source, pat.offset),
            .msg = try emit.allocator().print("version script assignment of '{s}' to symbol '{s}' failed: '{s}' defines no such symbol{s}", .{ if (node.len == 0) "global" else node, pat.text, std.Io.Dir.path.basename(sub_path), more }),
            .hint = "export it, remove it from the script, or allow it with --undefined-version (`linker_allow_undefined_version = true`)",
        };
        return null;
    }
    for (exports, places) |*x, place| switch (place) {
        VersionScript.local => x.visibility = .hidden,
        else => x.version = place,
    };
    return exports;
}

/// The location of byte `offset` of version script `path`, whose text
/// is `src`, for messages.
pub fn versionScriptLoc(path: []const u8, src: []const u8, offset: u32) Diag.Loc {
    const at = @min(offset, src.len);
    const line_start = if (std.mem.findScalarLast(u8, src[0..at], '\n')) |nl| nl + 1 else 0;
    const line_end = std.mem.findScalarPos(u8, src, at, '\n') orelse src.len;
    var end = at;
    while (end < line_end and !std.ascii.isWhitespace(src[end]) and src[end] != ';') end += 1;
    return .{
        .path = path,
        .line = @intCast(1 + std.mem.count(u8, src[0..line_start], "\n")),
        .col = @intCast(1 + at - line_start),
        .start = @intCast(at),
        .end = @intCast(@max(end, at + @intFromBool(at < src.len))),
        .main = @intCast(at),
        .source_line = src[line_start..line_end],
        .in_lib = false,
    };
}

/// Reports link error `err`: one a program can fix as `link_diagnostic`,
/// the rest on stderr.
fn linkFailed(emit: *Emit, err: anyerror, diag: Elf.Diagnostic) !void {
    if (err == error.RelocationOverflow and diag.reloc == .aarch64_branch26) {
        emit.link_diagnostic = try branchRangeDiagnostic(emit.allocator(), diag.atom, emit.symbolName(diag.target.?, diag.addend));
        return;
    }
    std.debug.print("error: link failed: {t} (atom '{s}' target {x})\n", .{ err, diag.atom, if (diag.target) |t| @backingInt(t) else 0 });
}

/// An aarch64 branch whose target is out of its ±128 MiB reach, which
/// lld and ld64 extend with thunks and bs does not.
fn branchRangeDiagnostic(arena: Allocator, caller: []const u8, target: []const u8) !Diag.Diagnostic {
    return .{
        .code = .@"branch-range",
        .loc = null,
        .msg = try arena.print("'{s}' calls '{s}', which is out of range: .text exceeds aarch64's \u{b1}128 MiB branch range, and bs adds no range-extension thunks", .{ caller, target }),
        .hint = "upstream zig links it: its linker adds the thunks",
    };
}

/// The name of what is `offset` bytes into the atom or import `key`, for
/// messages: a C object's symbol there (not an aarch64 mapping symbol,
/// `$x` or `$d`), else the atom's name, else its key.
fn symbolName(emit: *Emit, key: SymbolKey, offset: i64) []const u8 {
    for (emit.input_symbols) |s| if (s.atom == key and s.offset == offset and !std.mem.startsWith(u8, s.name, "$")) return s.name;
    for (emit.atoms.items) |a| if (a.key == key and a.name.len > 0) return a.name;
    for (emit.imports.keys()) |name| if (importKey(name) == key) return name;
    return emit.allocator().print("{x:0>32}", .{@backingInt(key)}) catch "?";
}

/// The key of the 8-byte slot holding the address of external symbol
/// `name`, requesting that `finish` write it. A slot for an address
/// `off` bytes into the symbol is named `name`, NUL, and `off` in decimal
/// (`externSlotName`), a name no symbol has.
pub fn useExtern(emit: *Emit, name: []const u8, weak: bool) !SymbolKey {
    try emit.syncPending();
    const gop = try emit.externs.getOrPut(emit.gpa, name);
    if (!gop.found_existing) {
        gop.key_ptr.* = try emit.allocator().dupe(u8, name);
        gop.value_ptr.* = weak;
    } else if (!weak) gop.value_ptr.* = false;
    try emit.addRef(.{ .ext = .{ .name = gop.key_ptr.*, .weak = weak } });
    return externSlotKey(name);
}

/// Records that the current unit's code requested `ref`.
fn addRef(emit: *Emit, ref: @FieldType(UnitRef, "ref")) !void {
    switch (emit.owner) {
        .unit => |u| try emit.unit_refs.append(emit.gpa, .{ .unit = u, .ref = ref }),
        .link => try emit.link_refs.append(emit.gpa, ref),
        .content, .input => {},
    }
    if (emit.uav_capturing != 0) try emit.uav_refs.append(emit.gpa, ref);
}

/// Records that the current unit's code used content atom `key`.
fn addContentUse(emit: *Emit, key: SymbolKey) !void {
    switch (emit.owner) {
        .unit => |u| try emit.content_uses.append(emit.gpa, .{ .unit = u, .key = key }),
        .link => try emit.link_content_uses.append(emit.gpa, key),
        .content, .input => {},
    }
    if (emit.uav_capturing != 0) try emit.uav_uses.append(emit.gpa, key);
}

/// `Zcu.requestCompilerRt` on behalf of the current unit.
pub fn requestCompilerRt(emit: *Emit, file_name: []const u8, name: []const u8) ![]const u8 {
    try emit.syncPending();
    var buf: [128]u8 = undefined;
    const key = try emit.requestRtKey(Zcu.compilerRtKey(&buf, file_name, name));
    try emit.addRef(.{ .rt = key });
    return key;
}

/// `Zcu.requestCompilerRtExport` on behalf of the current unit.
pub fn requestCompilerRtExport(emit: *Emit, name: []const u8) !?[]const u8 {
    const e = Zcu.compilerRtExport(name) orelse return null;
    const result = try emit.requestCompilerRt(e.file, e.decl);
    return result;
}

/// Requests compiler_rt function `key` and returns the key, owned: from a
/// worker, for the merge; while analysis runs, for `sync`; after it, from
/// the Zcu. No unit's reference: also for a lazy replay, whose kept unit
/// keeps its recorded `rt` reference (`Replay.walkNode`).
pub fn requestRtKey(emit: *Emit, key: []const u8) ![]const u8 {
    if (emit.is_worker) {
        const gop = try emit.rt_keys.getOrPut(emit.gpa, key);
        if (gop.found_existing) return gop.key_ptr.*;
        gop.key_ptr.* = try emit.allocator().dupe(u8, key);
        try emit.side.append(emit.gpa, .{ .rt = gop.key_ptr.* });
        return gop.key_ptr.*;
    }
    if (!emit.analyzing) return emit.zcu.requestCompilerRtKey(key);
    const gop = try emit.rt_pending.getOrPut(emit.gpa, key);
    if (!gop.found_existing) gop.key_ptr.* = try emit.allocator().dupe(u8, key);
    return gop.key_ptr.*;
}

/// Requests the error name table, which `@errorName` reads.
pub fn useErrorNames(emit: *Emit) !void {
    try emit.syncPending();
    emit.uses_error_names = true;
    try emit.addRef(.error_names);
}

pub fn externSlotKey(name: []const u8) SymbolKey {
    var buf: [256]u8 = undefined;
    return .fromName(std.mem.print(&buf, "extern.{s}", .{name}) catch name);
}

/// The key a constant that a function reads relocates the address of
/// external symbol `name` to (`externDataTarget`): bound at link time,
/// through an alias, to where `name`'s slot binds it. The constant's
/// content then does not depend on where the symbol is defined.
pub fn externAddrKey(name: []const u8) SymbolKey {
    var buf: [256]u8 = undefined;
    return .fromName(std.mem.print(&buf, "extaddr.{s}", .{name}) catch name);
}

/// An `externAddrKey` and its slot's binding.
pub const Alias = Elf.Alias;

/// The `useExtern` name of the slot for the address `off` bytes into
/// symbol `name`.
pub fn externSlotName(emit: *Emit, name: []const u8, off: i64) Allocator.Error![]const u8 {
    if (off == 0) return name;
    return emit.allocator().print("{s}\x00{d}", .{ name, off });
}

/// The symbol and offset of a `useExtern` name (`externSlotName`).
fn parseExternSlot(slot: []const u8) struct { []const u8, i64 } {
    const nul = std.mem.findScalar(u8, slot, 0) orelse return .{ slot, 0 };
    return .{ slot[0..nul], std.fmt.parseInt(i64, slot[nul + 1 ..], 10) catch unreachable };
}

/// The key relocations name an imported symbol by (see `useImport`).
pub fn importKey(name: []const u8) SymbolKey {
    var buf: [256]u8 = undefined;
    return .fromName(std.mem.print(&buf, "import.{s}", .{name}) catch name);
}

/// In position-independent code, the key of `__tls_get_addr`, which the
/// module that loads it, or a static executable's std, defines.
pub fn tlsGetAddr(emit: *Emit) !SymbolKey {
    return emit.useImport("__tls_get_addr", .{});
}

/// In an object, the key of `name`, which another object defines, on
/// behalf of the current unit (a worker's merge moves its imports with its
/// references).
pub fn useImport(emit: *Emit, name: []const u8, flags: ImportFlags) !SymbolKey {
    const gop = try emit.imports.getOrPut(emit.gpa, name);
    if (!gop.found_existing) {
        gop.key_ptr.* = try emit.allocator().dupe(u8, name);
        gop.value_ptr.* = flags;
    } else gop.value_ptr.* = gop.value_ptr.merge(flags);
    try emit.addRef(.{ .import = .{ .name = gop.key_ptr.*, .flags = flags } });
    return importKey(name);
}

pub const TlsTarget = struct {
    key: SymbolKey,
    /// Defined in the module the final link makes: the compilation's own.
    local: bool,
    /// `key` is an executable's slot holding the variable's offset from
    /// the thread pointer (a shared library's thread-local, initial-exec).
    slot: bool = false,
};

/// The thread-local an `extern threadlocal` names: the compilation's
/// export of that name; in an object an import, which the final link
/// resolves; in an executable with link inputs, the definition the link
/// binds `name`'s slot to (an input object's), through `externAddrKey`,
/// as a constant's address of extern data. An executable imports a shared
/// library's thread-local, through a content-addressed slot the loader
/// writes (TPOFF64 or TLS_TPREL64; ElfInput's `tlsSlot` is the same atom). bs's shared
/// objects import no thread-locals.
pub fn tlsTarget(emit: *Emit, name: []const u8) !TlsTarget {
    if (try emit.userExport(name)) |key| return .{ .key = key, .local = true };
    if (emit.obj and !emit.shared) return .{ .key = try emit.useImport(name, .{ .tls = true }), .local = false };
    if (!emit.obj and emit.sharedTls(name)) {
        const imp = try emit.useImport(name, .{ .tls = true });
        const zeros: [8]u8 = @splat(0);
        const kind: Atom.Reloc.Kind = if (emit.zcu.ip.target == .aarch64_linux) .aarch64_tprel64 else .x86_64_tpoff64;
        return .{ .key = try emit.contentAtom(8, &zeros, &.{imp}, &.{.init(0, kind, 0, 0)}), .local = false, .slot = true };
    }
    if (emit.has_inputs) {
        _ = try emit.useExtern(name, false);
        return .{ .key = externAddrKey(name), .local = true };
    }
    if (emit.shared)
        try emit.addError(0, .{ .start = 0, .end = 0, .main = 0 }, "bs does not import thread-local symbols into shared objects yet: {s}", .{name})
    else
        try emit.addError(0, .{ .start = 0, .end = 0, .main = 0 }, "undefined symbol: {s}", .{name});
    return error.CodegenFail;
}

/// The symbol `@extern` with `.relocation = .pcrel` names, which code
/// reaches PC-relative, or null for an undefined weak symbol in an image.
/// In an object, a symbol it does not export is a hidden import: the
/// final link must define it, as it defines `_DYNAMIC` for std.pie. A
/// shared object defines `_DYNAMIC` itself and cannot reach an import
/// PC-relative.
pub fn pcrelTarget(emit: *Emit, name: []const u8, weak: bool) !?SymbolKey {
    if (emit.obj and !emit.shared) return try emit.userExport(name) orelse try emit.useImport(name, .{ .weak = weak, .hidden = true });
    if (emit.shared and std.mem.eql(u8, name, "_DYNAMIC")) return ElfDynamic.dynamic_key; // ziglint-ignore: Z010 -- a declaration of ElfDynamic, not of SymbolKey
    // Analyzes the compiler_rt function, for the unit's cached references.
    _ = try emit.requestCompilerRtExport(name);
    if (try emit.userExport(name) orelse try emit.rtExport(name)) |key| return key;
    if (weak) return null;
    if (emit.libraryDefines(name)) {
        try emit.addError(0, .{ .start = 0, .end = 0, .main = 0 }, "PC-relative reference to imported symbol {s}, which a shared library defines; reach it through an extern slot (drop '.relocation = .pcrel')", .{name});
        return error.CodegenFail;
    }
    try emit.addError(0, .{ .start = 0, .end = 0, .main = 0 }, "undefined symbol: {s}", .{name});
    return error.CodegenFail;
}

/// Collects an object's exports: each name once, as `exportTarget` picks
/// it, and only those with an atom.
fn findExports(emit: *Emit) !void {
    const ip = &emit.zcu.ip;
    // Each name's place in `emit.exports`.
    var seen: std.StringHashMapUnmanaged(usize) = .empty;
    defer seen.deinit(emit.gpa);
    for (emit.zcu.exports.items) |x| {
        const name = ip.stringSlice(x.name);
        const key = switch (x.target) {
            .nav => |n| key: {
                const nav = ip.getNav(n);
                if (nav.status != .resolved) continue;
                if (ip.keyTag(nav.val) == .func) break :key try emit.funcKey(nav.val);
                if (!Type.hasRuntimeBits(ip, ip.typeOf(nav.val))) continue;
                break :key try emit.navKey(n);
            },
            .uav => |v| try emit.uavKey(v, 0),
        };
        if (x.linkage == .weak and emit.objectsDefineStrong(name)) continue;
        const entry: ElfObject.Export = .{ .key = key, .name = name, .weak = x.linkage == .weak, .visibility = x.visibility };
        const gop = try seen.getOrPut(emit.gpa, name);
        if (gop.found_existing) {
            if (!entry.weak) emit.exports.items[gop.value_ptr.*] = entry;
            continue;
        }
        gop.value_ptr.* = emit.exports.items.len;
        try emit.exports.append(emit.gpa, entry);
    }
    // Container-level assembly's, at the start of its atom (the others
    // are an error in objects, `global_asm.assemble`).
    for (emit.asm_symbols.keys(), emit.asm_symbols.values()) |name, t| {
        if (t.addend == 0) try emit.exports.append(emit.gpa, .{ .key = t.key, .name = name, .weak = false, .visibility = .default });
    }
}

/// Writes the slot of each external symbol: the address of the export of
/// that name, or 0 for an undefined weak symbol; in an object, a symbol
/// that is not exported is imported. Returns false after reporting an
/// undefined strong symbol.
fn lowerExternSlots(emit: *Emit) !bool {
    const zcu = emit.zcu;
    const arena = emit.allocator();
    var ok = true;
    // By name, not in the order units requested them, which a replay
    // changes: the slots' order is the link's.
    emit.externs.sort(struct {
        names: []const []const u8,
        const Self = @This();
        pub fn lessThan(c: Self, a: usize, b: usize) bool {
            return std.mem.order(u8, c.names[a], c.names[b]) == .lt;
        }
    }{ .names = emit.externs.keys() });
    for (emit.externs.keys(), emit.externs.values()) |slot, weak| {
        const name, const off = parseExternSlot(slot);
        const target = try emit.externTarget(name, weak);
        if (target == null and !weak) {
            try zcu.addError(0, .{ .start = 0, .end = 0, .main = 0 }, "undefined symbol: {s}", .{name});
            ok = false;
            continue;
        }
        const bytes = try arena.alloc(u8, 8);
        @memset(bytes, 0);
        if (target) |t| if (off == 0) try emit.aliases.append(emit.gpa, .{ .key = externAddrKey(name), .target = t.key, .addend = t.addend });
        const targets: []const SymbolKey = if (target) |t| try arena.dupe(SymbolKey, &.{t.key}) else &.{};
        const relocs: []const Atom.Reloc = if (target) |t| try arena.dupe(Atom.Reloc, &.{.init(0, emit.abs64Kind(), 0, std.math.cast(i32, t.addend + off) orelse return error.Overflow)}) else &.{};
        try emit.addAtom(.{
            .key = externSlotKey(slot),
            .name = if (off == 0) try arena.print("extern.{s}", .{name}) else try arena.print("extern.{s}+{d}", .{ name, off }),
            .section = .rodata,
            .alignment = .@"8",
            .bytes = bytes,
            .targets = targets,
            .relocs = relocs,
        });
    }
    return ok;
}

pub const ExternTarget = struct { key: SymbolKey, addend: i64 = 0 };

/// Where the link binds external symbol `name`, or null if nothing
/// defines it: the compilation's export, an input object's definition
/// (at an offset in its section's atom; after the exports and before
/// compiler_rt), a section bound, compiler_rt's, or a library's; in an
/// object, a symbol that is not exported is imported. Complete only once
/// analysis is, and the inputs pulled.
fn externTarget(emit: *Emit, name: []const u8, weak: bool) !?ExternTarget {
    if (emit.asm_symbols.get(name)) |t| return t;
    if (emit.inputs) |in| if (try emit.userExport(name) == null) switch (in) {
        inline else => |p| if (try p.lookup(name)) |t| return .{ .key = t.key, .addend = @intCast(t.offset) },
    };
    const key = if (emit.shared)
        try emit.userExport(name) orelse try emit.rtExport(name) orelse
            if (std.mem.eql(u8, name, "_DYNAMIC")) ElfDynamic.dynamic_key else try emit.useImport(name, .{ .weak = weak })
    else if (emit.inputs != null)
        try emit.userExport(name) orelse sectionBound(name) orelse arrayBound(name) orelse try emit.exportTarget(name)
    else if (emit.obj)
        try emit.userExport(name) orelse try emit.useImport(name, .{ .weak = weak })
    else
        sectionBound(name) orelse try emit.exportTarget(name);
    return .{ .key = key orelse return null };
}

/// The relocation target of the address of external symbol `name` in
/// data. A declaration's data, which `lowerNavs` writes once analysis is
/// done, binds it directly: a lazy build keeps the data it does not
/// lower, bound as the last build bound it (its inputs are those, and it
/// falls back if the exports change); one with link inputs that lowers
/// such data goes eager (`inputs_deferred`). Constants that functions
/// read are written while analysis runs, before the exports and inputs
/// are complete: they relocate to `externAddrKey`, which the link binds
/// as the symbol's slot.
pub fn externDataTarget(emit: *Emit, name: []const u8) !ExternTarget {
    const late = switch (emit.owner) {
        .unit => |u| u != .nav_val,
        .content, .input => true,
        .link => emit.analyzing,
    };
    if (late) {
        _ = try emit.requestCompilerRtExport(name);
        _ = try emit.useExtern(name, false);
        return .{ .key = externAddrKey(name) };
    }
    if (emit.inputs_deferred) {
        // Any key: the build does not link.
        emit.needs_inputs = true;
        return .{ .key = externSlotKey(name) };
    }
    return try emit.externTarget(name, false) orelse {
        try emit.addError(0, .{ .start = 0, .end = 0, .main = 0 }, "undefined symbol: {s}", .{name});
        return error.CodegenFail;
    };
}

/// The section bound the linker defines as `name` (`__start___sancov_cntrs`
/// and the others), which an executable's `@extern` reaches.
pub fn sectionBound(name: []const u8) ?SymbolKey {
    inline for (.{ .{ Atom.Section.sancov_cntrs, "__sancov_cntrs" }, .{ Atom.Section.sancov_pcs, "__sancov_pcs1" } }) |s| {
        if (std.mem.eql(u8, name, "__start_" ++ s[1])) return .sectionBound(s[0], .start);
        if (std.mem.eql(u8, name, "__stop_" ++ s[1])) return .sectionBound(s[0], .stop);
    }
    return null;
}

/// The bound of an init or fini array the linker defines as `name`
/// (`__init_array_start` and the others). Only with object inputs, which
/// are what fill the arrays: without them std.start's weak references
/// stay null, and its outputs stay as they were.
pub fn arrayBound(name: []const u8) ?SymbolKey {
    inline for (.{ Atom.Section.preinit_array, Atom.Section.init_array, Atom.Section.fini_array }) |s| {
        if (std.mem.eql(u8, name, "__" ++ @tagName(s) ++ "_start")) return .sectionBound(s, .start);
        if (std.mem.eql(u8, name, "__" ++ @tagName(s) ++ "_end")) return .sectionBound(s, .stop);
    }
    return null;
}

/// The symbol exported as `name`, or null if there is none. In an object,
/// a symbol that is not exported is imported, as upstream leaves it to the
/// final link; an executable resolves it against compiler_rt, as upstream
/// links it, and on aarch64-macos then imports it from libSystem.
/// Complete only once analysis is.
pub fn exportTarget(emit: *Emit, name: []const u8) !?SymbolKey {
    emit.export_lookups += 1;
    if (try emit.userExport(name)) |key| return key;
    // A shared object links compiler_rt in, as upstream's do.
    if (emit.obj and !emit.shared) {
        const result = try emit.useImport(name, .{});
        return result;
    }
    // compiler_rt before libc, as upstream: its `fmod` and `memcpy` stay
    // in the executable, and only names it lacks are imported; plain C's
    // come from libc first (`libc_first`).
    if (!emit.libcFirst(name)) if (try emit.rtExport(name)) |key| return key;
    // On aarch64-macos, then libSystem's.
    if (emit.zcu.ip.target == .aarch64_macos) {
        const result = try emit.useImport(name, .{});
        return result;
    }
    if (emit.libraryDefines(name)) {
        const result = try emit.useImport(name, .{});
        return result;
    }
    if (emit.shared) {
        const result = try emit.useImport(name, .{});
        return result;
    }
    return null;
}

/// Whether one of an executable's shared libraries defines thread-local
/// `name`.
fn sharedTls(emit: *const Emit, name: []const u8) bool {
    return if (Glibc.sharedSymbol(emit.shared_libs, name)) |s| s.sym.tls else false;
}

/// Whether an executable that links glibc imports `name`: one of its
/// shared libraries or glibc defines it. On aarch64-macos, whether
/// `libsystem` has it.
fn libraryDefines(emit: *const Emit, name: []const u8) bool {
    if (emit.libsystem) |set| return set.contains(name);
    const g = emit.glibc orelse return false;
    return Glibc.sharedSymbol(emit.shared_libs, name) != null or g.get(name) != null;
}

/// Whether `name` resolves to glibc's before compiler_rt's (`libc_first`).
fn libcFirst(emit: *const Emit, name: []const u8) bool {
    return emit.libc_first and emit.libraryDefines(name);
}

/// The compiler_rt function exported as `name`, requested, or null.
fn rtExport(emit: *Emit, name: []const u8) !?SymbolKey {
    const e = Zcu.compilerRtExport(name) orelse return null;
    var buf: [128]u8 = undefined;
    return .fromName(try emit.requestRtKey(Zcu.compilerRtKey(&buf, e.file, e.decl)));
}

/// The relocation kind of a 64-bit absolute address in data.
pub fn abs64Kind(emit: *const Emit) Atom.Reloc.Kind {
    return switch (emit.zcu.ip.target) {
        .x86_64_linux => .x86_64_abs64,
        .aarch64_macos, .aarch64_linux => .aarch64_abs64,
    };
}

/// The symbol and offset a comptime-known pointer refers to.
pub const ptrTarget = CodeGen.ptrTarget;

/// The symbol the compilation exports as `name`, or null. Of several
/// exports of one name, the last strong one wins, else the first, as
/// upstream 0.17.1's linker (a weak export after a definition is ignored).
/// Whether an input object defines `name` strongly, which then wins
/// over a weak export of the Zig code, as in ld: a C library's own
/// `bsearch` over zigc's.
fn objectsDefineStrong(emit: *const Emit, name: []const u8) bool {
    const in = emit.inputs orelse return false;
    return switch (in) {
        inline else => |p| if (p.defs.get(name)) |d| !d.weak else false,
    };
}

pub fn userExport(emit: *Emit, name: []const u8) !?SymbolKey {
    const ip = &emit.zcu.ip;
    const view = emit.exportsView();
    var pick: ?usize = null;
    for (view.list, 0..) |x, i| {
        if (!std.mem.eql(u8, ip.stringSlice(x.name), name)) continue;
        if (x.target == .nav and !(if (view.resolved) |r| r[i] else ip.getNav(x.target.nav).status == .resolved)) continue;
        if (pick == null or x.linkage != .weak) pick = i;
    }
    const x = view.list[pick orelse return null];
    if (x.linkage == .weak and emit.objectsDefineStrong(name)) return null;
    const x_nav = switch (x.target) {
        .nav => |n| n,
        .uav => |v| return try emit.uavKey(v, 0),
    };
    const nav = ip.getNav(x_nav);
    return if (ip.keyTag(nav.val) == .func) try emit.funcKey(nav.val) else try emit.navKey(x_nav);
}

pub fn allocator(emit: *Emit) Allocator {
    return emit.arena.allocator();
}

pub fn addAtom(emit: *Emit, atom: Atom) !void {
    if (emit.is_worker) {
        // `mergeOut` tracks grouping in the main Emit.
        try emit.atom_owners.append(emit.gpa, emit.owner);
        return emit.atoms.append(emit.gpa, atom);
    }
    try emit.syncPending();
    try emit.appendAtom(atom);
}

fn appendAtom(emit: *Emit, atom: Atom) !void {
    try emit.atom_owners.ensureUnusedCapacity(emit.gpa, 1);
    try emit.atoms.append(emit.gpa, atom);
    emit.atom_owners.appendAssumeCapacity(emit.owner);
}

/// Reorders atoms so that each owner's are adjacent, owners sorted by the
/// key of their first atom with the link's own atoms and then the inputs'
/// last, and drops atoms whose key an earlier one has, with their debug
/// entries. The order is
/// then a function of the atoms and their owners, not of the order units
/// were analyzed or loaded in, so a build that loads units from the cache
/// links the same bytes as one that analyzes them all. That is also the
/// list the cache's manifest replays (nodes in the order of their first
/// atom, `Incremental.record`), and the linker lays out atoms in chunks of
/// input positions, so a fresh link of any other order or with duplicates
/// could differ from a relink in padding.
pub fn groupByOwner(gpa: Allocator, atoms: *std.ArrayList(Atom), owners: *std.ArrayList(Owner), debug: *std.ArrayList(Atom.Debug)) !void {
    const Group = union(enum) { unit: Zcu.AnalUnit, content: SymbolKey, link, input };
    const dropped = std.math.maxInt(u32);
    const n = atoms.items.len;
    // Each atom's group.
    const group_of = try gpa.alloc(u32, n);
    defer gpa.free(group_of);
    var groups: std.array_hash_map.Auto(Group, void) = .empty;
    defer groups.deinit(gpa);
    for (atoms.items, owners.items, group_of) |a, o, *g| {
        const gop = try groups.getOrPut(gpa, switch (o) {
            .unit => |u| .{ .unit = u },
            .content => .{ .content = a.key },
            .link => .link,
            .input => .input,
        });
        g.* = @intCast(gop.index);
    }
    // Atom indices by group, each group's in their order.
    const starts = try gpa.alloc(u32, groups.count() + 1);
    defer gpa.free(starts);
    @memset(starts, 0);
    for (group_of) |g| starts[g + 1] += 1;
    for (1..starts.len) |i| starts[i] += starts[i - 1];
    const by_group = try gpa.alloc(u32, n);
    defer gpa.free(by_group);
    {
        const next = try gpa.dupe(u32, starts[0 .. starts.len - 1]);
        defer gpa.free(next);
        for (group_of, 0..) |g, i| {
            by_group[next[g]] = @intCast(i);
            next[g] += 1;
        }
    }
    // The groups by their atoms' keys, the link's and the inputs' last.
    // Two owners whose atoms all have the same keys are told apart by
    // owner, which only the dropping of duplicates below can see.
    const order = try gpa.alloc(u32, groups.count());
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const Sort = struct {
        atoms: []const Atom,
        groups: []const Group,
        starts: []const u32,
        by_group: []const u32,

        const Self = @This();
        fn lessThan(c: Self, x: u32, y: u32) bool {
            const gx = c.groups[x];
            const gy = c.groups[y];
            if ((gx == .input) != (gy == .input)) return gy == .input;
            if ((gx == .link) != (gy == .link)) return gy == .link;
            const ax = c.by_group[c.starts[x]..c.starts[x + 1]];
            const ay = c.by_group[c.starts[y]..c.starts[y + 1]];
            for (ax[0..@min(ax.len, ay.len)], ay[0..@min(ax.len, ay.len)]) |i, j| {
                const kx = @backingInt(c.atoms[i].key);
                const ky = @backingInt(c.atoms[j].key);
                if (kx != ky) return kx < ky;
            }
            if (ax.len != ay.len) return ax.len < ay.len;
            var hx: std.hash.Wyhash = .init(0);
            std.hash.autoHash(&hx, gx);
            var hy: std.hash.Wyhash = .init(0);
            std.hash.autoHash(&hy, gy);
            return hx.final() < hy.final();
        }
    };
    std.mem.sortUnstable(u32, order, Sort{ .atoms = atoms.items, .groups = groups.keys(), .starts = starts, .by_group = by_group }, Sort.lessThan);
    // New positions, dropping repeated keys.
    var keys: std.AutoHashMapUnmanaged(SymbolKey, void) = .empty;
    defer keys.deinit(gpa);
    try keys.ensureTotalCapacity(gpa, @intCast(n));
    const new_index = try gpa.alloc(u32, n);
    defer gpa.free(new_index);
    var kept: u32 = 0;
    for (order) |g| for (by_group[starts[g]..starts[g + 1]]) |i| {
        if (keys.getOrPutAssumeCapacity(atoms.items[i].key).found_existing) {
            new_index[i] = dropped;
            continue;
        }
        new_index[i] = kept;
        kept += 1;
    };
    const new_atoms = try gpa.alloc(Atom, kept);
    defer gpa.free(new_atoms);
    const new_owners = try gpa.alloc(Owner, kept);
    defer gpa.free(new_owners);
    for (atoms.items, owners.items, new_index) |a, o, ni| if (ni != dropped) {
        new_atoms[ni] = a;
        new_owners[ni] = o;
    };
    @memcpy(atoms.items[0..kept], new_atoms);
    atoms.shrinkRetainingCapacity(kept);
    @memcpy(owners.items[0..kept], new_owners);
    owners.shrinkRetainingCapacity(kept);
    var d_kept: usize = 0;
    for (debug.items) |d| if (new_index[d.atom] != dropped) {
        debug.items[d_kept] = d;
        debug.items[d_kept].atom = new_index[d.atom];
        d_kept += 1;
    };
    debug.shrinkRetainingCapacity(d_kept);
    std.mem.sortUnstable(Atom.Debug, debug.items, {}, struct {
        fn lt(_: void, a: Atom.Debug, b: Atom.Debug) bool {
            return a.atom < b.atom;
        }
    }.lt);
}

/// Adds a function's atom and its debug info.
pub fn addFunction(emit: *Emit, atom: Atom, debug: Atom.Debug) !void {
    try emit.syncPending();
    try emit.debug.ensureUnusedCapacity(emit.gpa, 1);
    var d = debug;
    d.atom = @intCast(emit.atoms.items.len);
    try emit.addAtom(atom);
    emit.debug.appendAssumeCapacity(d);
}

/// The keys of function `func`'s coverage counters and PC table
/// (`-ffuzz`).
pub fn coverageKeys(func: SymbolKey) [2]SymbolKey {
    var buf: [40]u8 = undefined;
    const k = std.mem.asBytes(&func);
    return .{
        .fromName(std.mem.print(&buf, "cntrs.{x}", .{k}) catch unreachable),
        .fromName(std.mem.print(&buf, "pcs.{x}", .{k}) catch unreachable),
    };
}

/// Adds the coverage atoms of function `func`, whose coverage points are
/// at code offsets `pcs`: a counter per point (`sancov_cntrs`), and its
/// address (`sancov_pcs`). Added together, so that the linker, which keeps
/// each section's atoms in input order, lines the arrays up.
pub fn addCoverage(emit: *Emit, func: SymbolKey, pcs: []const u32) !void {
    if (pcs.len == 0) return;
    const keys = coverageKeys(func);
    const arena = emit.allocator();
    const bytes = try arena.alloc(u8, 8 * pcs.len);
    @memset(bytes, 0);
    const relocs = try arena.alloc(Atom.Reloc, pcs.len);
    for (relocs, pcs, 0..) |*r, pc, i| r.* = .init(@intCast(8 * i), .x86_64_abs64, 0, @intCast(pc));
    try emit.addAtom(.{ .key = keys[0], .name = "", .section = .sancov_cntrs, .zero_fill = pcs.len });
    try emit.addAtom(.{
        .key = keys[1],
        .name = "",
        .section = .sancov_pcs,
        .alignment = .@"8",
        .bytes = bytes,
        .targets = try arena.dupe(SymbolKey, &.{func}),
        .relocs = relocs,
    });
}

/// Adds a content-addressed rodata atom for `bytes` and its sorted `relocs`
/// unless an identical one exists, and returns its key.
pub fn contentAtom(emit: *Emit, alignment: u64, bytes: []const u8, targets: []const SymbolKey, relocs: []const Atom.Reloc) !SymbolKey {
    const a: std.mem.Alignment = .fromByteUnits(@max(alignment, 1));
    const key: SymbolKey = .fromContents(.rodata, a, bytes, targets, relocs);
    try emit.addContentUse(key);
    const gop = try emit.content_keys.getOrPut(emit.gpa, key);
    if (gop.found_existing) return key;
    const owner = emit.owner;
    emit.owner = .content;
    defer emit.owner = owner;
    const arena = emit.allocator();
    try emit.addAtom(.{
        .key = key,
        .name = try arena.print("__anon_{x}", .{@backingInt(key)}),
        .section = .rodata,
        .alignment = a,
        .bytes = try arena.dupe(u8, bytes),
        .targets = try arena.dupe(SymbolKey, targets),
        .relocs = try arena.dupe(Atom.Reloc, relocs),
    });
    return key;
}

pub fn unitName(emit: *Emit, unit: Zcu.AnalUnit) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(emit.allocator());
    emit.zcu.unitKey(unit, &aw.writer) catch return error.OutOfMemory;
    return aw.written();
}

pub fn funcKey(emit: *Emit, func: Index) !SymbolKey {
    return .fromName(try emit.unitName(.{ .func = func }));
}

/// The key of a declaration's data atom, requesting that it be emitted.
pub fn navKey(emit: *Emit, nav: InternPool.NavIndex) !SymbolKey {
    try emit.syncPending();
    try emit.navs.put(emit.gpa, nav, {});
    try emit.addRef(.{ .nav = nav });
    return .fromName(try emit.unitName(.{ .nav_val = nav }));
}

/// A link-time value: the number of error codes the compilation assigned,
/// which `cmp_lt_errors_len` compares a code with. The cache's relinks
/// give it the manifest's count, which an edit build's new errors extend.
pub const errors_len: SymbolKey = .fromName("bs.errors_len");

pub fn errorKey(ip: *const InternPool, name: InternPool.String) SymbolKey {
    return errorKeyFromName(ip.stringSlice(name));
}

pub fn errorKeyFromName(name: []const u8) SymbolKey {
    var buf: [256]u8 = undefined;
    const s = std.mem.print(&buf, "error.{s}", .{name}) catch unreachable;
    return .fromName(s);
}

/// A `[:0]const u8` per error code, for `@errorName` at runtime. It is
/// built after every function is lowered, when every error code is
/// assigned; codes stay symbolic everywhere else. As upstream's, it names
/// every code `@errorFromInt` accepts (`errors_len`), not only the errors
/// code uses: a code can come from a comptime `@intFromError`.
pub const error_name_table: SymbolKey = .fromName("__bs_error_names");

fn emitErrorNameTable(emit: *Emit) !void {
    const ip = &emit.zcu.ip;
    const gpa = emit.gpa;
    // Codes are assigned when first asked for: the errors code uses get
    // theirs now if they have none yet.
    for (emit.errors.keys()) |name| _ = try ip.errorValue(name);
    const bytes = try emit.allocator().alloc(u8, ip.error_names.items.len * 16);
    @memset(bytes, 0);
    var refs: Atom.RelocList = .{};
    defer refs.deinit(gpa);
    // In code order, so that the atom is the same however the build
    // reached its uses (an edit build loads some of them).
    for (ip.error_names.items[1..]) |name| {
        const s = ip.stringSlice(name);
        const z = try gpa.alloc(u8, s.len + 1);
        defer gpa.free(z);
        @memcpy(z[0..s.len], s);
        z[s.len] = 0;
        const off: u32 = try ip.errorValue(name) * 16;
        try refs.append(gpa, off, emit.abs64Kind(), try emit.contentAtom(1, z, &.{}, &.{}), 0);
        std.mem.writeInt(u64, bytes[off + 8 ..][0..8], s.len, .little);
    }
    refs.sort();
    try emit.addAtom(.{
        .key = error_name_table,
        .name = "__bs_error_names",
        .section = .rodata,
        .alignment = .@"8",
        .bytes = bytes,
        .targets = try emit.allocator().dupe(SymbolKey, refs.targets.keys()),
        .relocs = try emit.allocator().dupe(Atom.Reloc, refs.relocs.items),
    });
}

pub fn useError(emit: *Emit, name: InternPool.String) !SymbolKey {
    try emit.syncPending();
    try emit.errors.put(emit.gpa, name, {});
    try emit.addRef(.{ .err = name });
    return errorKey(&emit.zcu.ip, name);
}

/// Lowers an anonymous constant into its own content-addressed atom,
/// aligned to at least `alignment` (0 for its type's). Memoized: a value's
/// bytes and relocations are the same each time, so a repeated call only
/// records again the uses that lowering it made.
pub fn uavKey(emit: *Emit, val: Index, alignment: u64) !SymbolKey {
    const gpa = emit.gpa;
    if (emit.uav_memo.get(.{ .val = val, .alignment = alignment })) |m| {
        // By index: recording into `uav_refs` and `uav_uses` for an outer
        // lowering can grow them.
        for (m.refs_start..m.refs_start + m.refs_len) |i| {
            const ref = emit.uav_refs.items[i];
            try emit.addRef(ref);
        }
        for (m.uses_start..m.uses_start + m.uses_len) |i| {
            const use = emit.uav_uses.items[i];
            try emit.addContentUse(use);
        }
        try emit.addContentUse(m.key);
        return m.key;
    }
    const ip = &emit.zcu.ip;
    const ty = ip.typeOf(val);
    const size = Type.abiSize(ip, ty);
    const bytes = try gpa.alloc(u8, size);
    defer gpa.free(bytes);
    var refs: Atom.RelocList = .{};
    defer refs.deinit(gpa);
    const refs_start: u32 = @intCast(emit.uav_refs.items.len);
    const uses_start: u32 = @intCast(emit.uav_uses.items.len);
    const lookups = emit.export_lookups;
    {
        emit.uav_capturing += 1;
        defer emit.uav_capturing -= 1;
        try CodeGen.lowerValue(emit, val, bytes, &refs, 0);
    }
    refs.sort();
    const key = try emit.contentAtom(@max(alignment, Type.abiAlignment(ip, ty)), bytes, refs.targets.keys(), refs.relocs.items);
    if (emit.export_lookups == lookups) try emit.uav_memo.put(gpa, .{ .val = val, .alignment = alignment }, .{
        .key = key,
        .refs_start = refs_start,
        .refs_len = @intCast(emit.uav_refs.items.len - refs_start),
        .uses_start = uses_start,
        // Without the use `contentAtom` just recorded for an outer lowering.
        .uses_len = @intCast(emit.uav_uses.items.len - uses_start - @intFromBool(emit.uav_capturing != 0)),
    });
    return key;
}

/// Lowers the data of the declarations requested since the last call.
/// Lowering a declaration can request more declarations. A lazy edit
/// build leaves out those whose data the cache has
/// (`Replay.keepsNavData`).
pub fn lowerNavs(emit: *Emit) !void {
    // The navs that loaded units' pending output requests (`beginLoad`).
    try emit.syncPending();
    while (emit.navs_done < emit.navs.count()) {
        const nav = emit.navs.keys()[emit.navs_done];
        emit.navs_done += 1;
        if (emit.zcu.replay) |r| if (try r.keepsNavData(nav)) continue;
        try emit.lowerNav(nav);
    }
}

fn lowerNav(emit: *Emit, nav_index: InternPool.NavIndex) !void {
    const ip = &emit.zcu.ip;
    const nav = ip.getNav(nav_index);
    const ty = ip.typeOf(nav.val);
    if (!Type.hasRuntimeBits(ip, ty)) return;
    emit.owner = .{ .unit = .{ .nav_val = nav_index } };
    defer emit.owner = .link;
    const arena = emit.allocator();
    const bytes = try arena.alloc(u8, Type.abiSize(ip, ty));
    var refs: Atom.RelocList = .{};
    defer refs.deinit(emit.gpa);
    // A failure has reported its error (an undefined symbol).
    CodeGen.lowerValue(emit, nav.val, bytes, &refs, 0) catch |err| switch (err) {
        error.CodegenFail => {
            emit.failed = true;
            return;
        },
        else => |e| return e,
    };
    refs.sort();
    const key: SymbolKey = .fromName(try emit.unitName(.{ .nav_val = nav_index }));
    const alignment: std.mem.Alignment = .fromByteUnits(if (nav.alignment != 0) nav.alignment else Type.abiAlignment(ip, ty));
    // A variable that is undefined or all zeros is zero-filled, in .bss
    // (__bss) or for a thread-local .tbss (__thread_bss), as LLVM places
    // it, rather than bytes in the file (and in every thread's copy of the
    // TLS template): std's 256 KiB signal stack is one. Constants stay in
    // .rodata, as LLVM keeps them.
    if (!nav.is_const and refs.relocs.items.len == 0 and
        (ip.keyTag(nav.val) == .undef or std.mem.allEqual(u8, bytes, 0)))
        return emit.addAtom(.{ .key = key, .name = name_later, .section = if (nav.is_threadlocal) .tbss else .bss, .alignment = alignment, .zero_fill = bytes.len });
    try emit.addAtom(.{
        .key = key,
        .name = name_later,
        .section = if (nav.is_threadlocal) .tdata else if (nav.is_const) .rodata else .data,
        .alignment = alignment,
        .bytes = bytes,
        .targets = try arena.dupe(SymbolKey, refs.targets.keys()),
        .relocs = try arena.dupe(Atom.Reloc, refs.relocs.items),
    });
}

test "an aarch64 branch out of range is an error that names both symbols" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const d = try branchRangeDiagnostic(arena_state.allocator(), "call_far", "far_away");
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try Diag.render(&buf.writer, &.{d}, .json);
    try std.testing.expectEqualStrings(
        \\{"code":"branch-range","msg":"'call_far' calls 'far_away', which is out of range: .text exceeds aarch64's ±128 MiB branch range, and bs adds no range-extension thunks","hint":"upstream zig links it: its linker adds the thunks"}
        \\{"summary":{"errors":1}}
        \\
    , buf.written());
}

test "a relink in the manifest's order reproduces the fresh link, with mixed alignments and duplicates" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var atoms: std.ArrayList(Atom) = .empty;
    defer atoms.deinit(gpa);
    var owners: std.ArrayList(Owner) = .empty;
    defer owners.deinit(gpa);
    var debug: std.ArrayList(Atom.Debug) = .empty;
    defer debug.deinit(gpa);
    const alignments = [_]std.mem.Alignment{ .@"1", .@"16", .@"64", .@"8" };

    // Constants, content-addressed: 50, each emitted again later.
    var constants: [50]Atom = undefined;
    for (&constants, 0..) |*c, j| {
        const bytes = try arena.alloc(u8, 1 + j % 13);
        @memset(bytes, @intCast(j));
        const a = alignments[j % 4];
        c.* = .{ .key = .fromContents(.rodata, a, bytes, &.{}, &.{}), .name = "", .section = .rodata, .alignment = a, .bytes = bytes };
    }
    const start: SymbolKey = .fromName("_start");
    try atoms.append(gpa, .{ .key = start, .name = "_start", .section = .text, .bytes = &.{ 0xe8, 0, 0, 0, 0, 0xcc }, .targets = &.{.fromName("f0")}, .relocs = &.{.init(1, .x86_64_pc32, 0, -4)} });
    try owners.append(gpa, .link);
    for (constants) |c| {
        try atoms.append(gpa, c);
        try owners.append(gpa, .content);
    }
    const n = 3000;
    for (0..n) |i| {
        const unit: Zcu.AnalUnit = .{ .func = @fromBackingInt(@intCast(100_000 + i)) };
        const name = try arena.print("f{d}", .{i});
        const bytes = try arena.alloc(u8, 5 + i % 37);
        @memset(bytes, 0x90);
        const target = constants[i % constants.len].key;
        try debug.append(gpa, .{ .atom = @intCast(atoms.items.len), .file = "t.zig", .name = name, .base_line = @intCast(i), .lines = &.{} });
        try atoms.append(gpa, .{ .key = .fromName(name), .name = name, .section = .text, .alignment = alignments[i % 3], .bytes = bytes, .targets = try arena.dupe(SymbolKey, &.{target}), .relocs = &.{.init(1, .x86_64_pc32, 0, -4)}, .unwind = .frame_pointer });
        try owners.append(gpa, .{ .unit = unit });
        if (i % 7 == 0) {
            try atoms.append(gpa, constants[i % constants.len]);
            try owners.append(gpa, .content);
        }
        // A unit's second atom, after other units' atoms.
        if (i % 11 == 10) {
            const extra = try arena.print("data{d}", .{i});
            try atoms.append(gpa, .{ .key = .fromName(extra), .name = extra, .section = .data, .alignment = alignments[i % 4], .bytes = try arena.dupe(u8, "abcdefgh") });
            try owners.append(gpa, .{ .unit = .{ .func = @fromBackingInt(@intCast(100_000 + i - 5)) } });
        }
    }
    try atoms.append(gpa, .{ .key = .fromName("tail"), .name = "tail", .section = .bss, .alignment = .@"64", .zero_fill = 100 });
    try owners.append(gpa, .link);

    const ungrouped = try Elf.emit(gpa, io, atoms.items, .{ .entry = start, .debug = debug.items });
    defer gpa.free(ungrouped);
    try groupByOwner(gpa, &atoms, &owners, &debug);
    const fresh = try Elf.emit(gpa, io, atoms.items, .{ .entry = start, .debug = debug.items });
    defer gpa.free(fresh);
    // The input order matters to the layout, which is why both builds
    // link one order.
    try std.testing.expect(!std.mem.eql(u8, ungrouped, fresh));

    // Grouped and deduplicated: no key twice, each owner's atoms adjacent.
    var keys: std.AutoHashMapUnmanaged(SymbolKey, void) = .empty;
    defer keys.deinit(gpa);
    var closed: std.AutoHashMapUnmanaged(Zcu.AnalUnit, void) = .empty;
    defer closed.deinit(gpa);
    for (atoms.items, owners.items, 0..) |a, o, i| {
        try std.testing.expect(!(try keys.getOrPut(gpa, a.key)).found_existing);
        if (i > 0 and std.meta.eql(owners.items[i - 1], o)) continue;
        if (i > 0) if (owners.items[i - 1] == .unit) try closed.put(gpa, owners.items[i - 1].unit, {});
        if (o == .unit) try std.testing.expect(!closed.contains(o.unit));
    }

    // Record as `Incremental.record` does, one node per owner, and relink
    // from the pack with the manifest's numbered symbols.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pack: cache.Pack = try .create(io, tmp.dir);
    defer pack.close(gpa, io);
    const refs = try gpa.alloc(cache.Pack.AtomRef, atoms.items.len);
    defer gpa.free(refs);
    try pack.append(gpa, io, atoms.items, debug.items, refs);
    {
        var b: cache.Manifest.Builder = .{ .gpa = gpa };
        defer b.deinit();
        var symbols: std.ArrayList(cache.Manifest.AtomSymbols) = .empty;
        defer symbols.deinit(gpa);
        var next_debug: usize = 0;
        var first: usize = 0;
        for (atoms.items, 0..) |a, i| {
            const file: ?[]const u8 = if (next_debug < debug.items.len and debug.items[next_debug].atom == i) f: {
                next_debug += 1;
                break :f "t.zig";
            } else null;
            try symbols.append(gpa, .{ .key = @backingInt(a.key), .targets = @ptrCast(a.targets), .file = file, .name = a.name });
            if (i + 1 < atoms.items.len and std.meta.eql(owners.items[i + 1], owners.items[i]) and owners.items[i] != .content) continue;
            _ = try b.addNode(.{ .key = i, .result_hash = 0, .atoms = refs[first .. i + 1], .symbols = symbols.items });
            symbols.clearRetainingCapacity();
            first = i + 1;
        }
        b.entry = @backingInt(start);
        try b.write(io, tmp.dir, pack.id);
    }
    var m = (try cache.Manifest.open(gpa, io, tmp.dir)).?;
    defer m.close(gpa, io);
    const in = try m.linkInput(gpa);
    var input = try pack.linkAtoms(gpa, .x86_64, in.refs, in.debug_atoms, .{ .of = in.debug_files, .names = &.{m.file(0)} });
    defer input.deinit(gpa);
    input.names = in.names;
    const relinked = try Elf.emitInput(gpa, io, input, .{
        .entry = start,
        .symbols = .{ .atoms = in.numbered, .targets = in.targets, .targets_tail = in.targets_tail, .entry = m.entry_symbol, .len = m.symbolLen() },
    });
    defer gpa.free(relinked);
    try std.testing.expectEqualSlices(u8, fresh, relinked);
}
