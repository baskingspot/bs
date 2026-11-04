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
//! (see "Parallel function bodies" in docs/architecture.md).

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("InternPool.zig");
const Index = InternPool.Index;
const Ir = @import("Ir.zig");
const Type = @import("Type.zig");
const Zcu = @import("Zcu.zig");
const Diag = @import("diag.zig");
const Atom = @import("link/Atom.zig");
const print = @import("Ir/print.zig");
const SymbolKey = Atom.SymbolKey;
const Elf = @import("link/Elf.zig");
const ElfObject = @import("link/ElfObject.zig");
const ElfDynamic = @import("link/ElfDynamic.zig");
const Glibc = @import("link/Glibc.zig");
const ElfInput = @import("link/ElfInput.zig");
const ElfShared = @import("link/ElfShared.zig");
const CSource = @import("CSource.zig");
const CodeGen = @import("codegen/x86_64/CodeGen.zig");
const Ssa = @import("codegen/Ssa.zig");
const inline_ir = @import("codegen/inline.zig");
const rewrite = @import("codegen/rewrite.zig");
const prove = @import("codegen/prove.zig");
const Sema = @import("Sema.zig");
const cache = @import("cache.zig");

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
navs: std.AutoArrayHashMapUnmanaged(InternPool.NavIndex, void) = .empty,
/// How many of `navs` were lowered (`lowerNavs`).
navs_done: usize = 0,
/// A lazy edit build (`Replay.lazy`): `finish` lowers only this build's
/// data, and the link's own atoms come from the cache.
lazy: bool = false,
/// Error names referenced by `value*` relocations.
errors: std.AutoArrayHashMapUnmanaged(InternPool.String, void) = .empty,
/// External symbols the code reads the address of (`@extern`), by name,
/// and whether every reference is weak. `finish` writes each one's slot.
externs: std.StringArrayHashMapUnmanaged(bool) = .empty,
/// For each bound slot at offset 0, its `externAddrKey` and where the
/// slot binds the symbol, for `link` (`lowerExternSlots`).
aliases: std.ArrayList(Alias) = .empty,
/// Whether code reads `error_name_table`.
uses_error_names: bool = false,
/// Compile errors that codegen reports (unsupported constructs), rendered
/// like Sema's.
failed: bool = false,
/// The entry symbol, once `finish` found it.
entry: ?SymbolKey = null,
/// Whether the output is a relocatable object (`zap build-obj`): it needs
/// no entry, its exports are symbols for other objects, and symbols it
/// does not define are imported from them.
obj: bool = false,
/// How code reaches thread-locals: `.pic` is position-independent code
/// that may end up in a shared object (`-fPIC`), which uses the
/// local-dynamic model; `.pie` and `.none` use local-exec. `.pic` and
/// `.pie` images put .rodata with absolute addresses in .data.rel.ro.
pic: enum { none, pic, pie } = .none,
/// Whether the output is a shared object (`zap build-lib -dynamic`), with
/// `obj` set too: it needs no entry, its exports are its dynamic symbols,
/// and symbols that neither it nor compiler_rt defines are imported from
/// the modules that load it.
shared: bool = false,
/// The shared object's DT_SONAME.
soname: ?[]const u8 = null,
/// `--stack`: the executable's main thread stack size.
stack_size: u64 = 16 * 1024 * 1024,
/// `-ffuzz`: CodeGen instruments the main module family's functions with
/// coverage points (docs/architecture.md, "Fuzzing").
fuzz: bool = false,
/// An executable that links glibc (`-lc`): names neither the compilation
/// nor compiler_rt exports resolve to glibc's symbols, imported.
glibc: ?*const Glibc = null,
/// Such an executable's shared library inputs, whose symbols come before
/// glibc's (`Glibc.dynamicOptions`), and its DT_RUNPATH.
shared_libs: []const ElfShared = &.{},
runpath: ?[]const u8 = null,
/// An executable's object and archive inputs, which `sync` pulls archive
/// members for and `finish` converts into atoms.
inputs: ?*ElfInput = null,
/// A lazy edit build with link inputs, whose relink from the manifest
/// converts them and binds the externs (`Incremental.linkFrom`): a
/// declaration's data cannot bind to them here, so `externDataTarget` sets
/// `needs_inputs` and the build goes eager (`Incremental.finishLazy`).
inputs_deferred: bool = false,
needs_inputs: bool = false,
/// C sources compiling while the build analyzes (CSource.zig): the first
/// `sync` waits for them and adds their objects to `inputs`, before it
/// pulls archive members and compiler_rt for them.
c_batch: ?*CSource.Batch = null,
/// In an object, the symbols other objects define, by name.
imports: std.StringArrayHashMapUnmanaged(ImportFlags) = .empty,
/// The imports the executable copies (R_X86_64_COPY) and their sizes, a
/// subset of `imports`, for data C objects reach without the GOT.
copies: std.StringArrayHashMapUnmanaged(u64) = .empty,
/// In an object, its exports, once `finish` found them.
exports: std.ArrayList(ElfObject.Export) = .empty,
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
/// Time spent in `CodeGen.generate`, for `ZAP_TIMING`.
codegen_ns: u64 = 0,
/// `ZAP_BENCH_CODEGEN`: a copy of every function's IR, which
/// `benchCodegen` generates again after analysis.
bench_irs: ?std.ArrayList(Ir) = null,
/// The SSA form of the function being generated, reused for the next.
ssa: Ssa = .{},
/// `rewrite.run`'s arrays, reused for the next function.
rewrite_scratch: std.ArrayList(u32) = .empty,
/// `prove.run`'s arrays, on a worker, reused for the next function.
prove_scratch: prove.Scratch = .{},
/// Per-stage backend time and size, for `ZAP_TIMING` and bench-codegen.
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
rt_pending: std.StringArrayHashMapUnmanaged(void) = .empty,
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

/// The CodeGen workers. Sema hands each analyzed function over as a job
/// (`functionOwned`); workers take jobs in order, and `mergeJobs` waits
/// for all jobs handed over and merges their output in job order. Jobs not
/// handed over yet when a merge comes, and with no threads every job, are
/// generated on the Sema thread into its own Emit, `workers[threads]`; the
/// merge is the same.
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
    /// `ZAP_SCHED_FUZZ=<seed>`: random delays and yields where workers take
    /// jobs and the Sema thread hands them over, random batch lengths, and
    /// merges that sometimes wait for workers instead of generating the
    /// jobs not handed over yet. The output must not change; a difference
    /// from `ZAP_THREADS=1` is a dependence on timing. Which worker takes
    /// which job varies, but each worker's jobs stay ascending, which the
    /// merge relies on (`mergeOut`).
    fuzz: ?u64 = null,
    /// The Sema thread's random state and batch length under `fuzz`.
    fuzz_rng: std.Random.DefaultPrng = .init(0),
    batch_target: usize = batch_len,
};

const Fate = union(enum) {
    no,
    yes: struct {
        size: u32,
        hash: cache.Hash,
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
const FateResult = union(enum) { fate: Fate, cycle, busy };

const Job = struct {
    ir: Ir,
    exports: ExportsView,
    /// Set when the job finished: the worker that generated it, and what
    /// it added to that worker's lists.
    worker: u32 = 0,
    out: Out = undefined,
    /// A job in `batch` the Sema thread generated already (no threads).
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
    /// Proving checks (`prove.run`, on the workers), and the checks
    /// proven.
    prove_ns: u64 = 0,
    checks: u64 = 0,
    proven: u64 = 0,
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
        std.debug.print("{s}: {d} functions, {d} IR instructions; rewrite {d:.1} ms ({d:.1} ns/IR, {d} folds), prove {d:.1} ms ({d:.1} ns/IR, {d} of {d} checks proven), ssa build {d:.1} ms ({d:.1} ns/IR), regalloc {d:.1} ms ({d:.1} ns/IR), emit {d:.1} ms ({d:.1} ns/IR), total {d:.1} ns/IR; {d:.2} code bytes/IR, {d:.0} frame bytes/function\n", .{
            label,
            s.functions,
            s.ir_insts,
            ms(s.rewrite_ns),
            per(s.rewrite_ns, s.ir_insts),
            s.folds,
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
}

/// Ends the worker threads once they finished the jobs left, which frees
/// their IR. Their Emits stay: the main Emit's atoms point into them.
fn stopWorkers(pool: *Pool) void {
    const io = pool.io;
    pool.mutex.lockUncancelable(io);
    pool.stop = true;
    pool.work.broadcast(io);
    pool.mutex.unlock(io);
    pool.group.await(io) catch {};
}

/// Starts CodeGen workers on `threads` threads besides the Sema thread; 0
/// generates each function on the Sema thread, with the same output.
pub fn startPool(emit: *Emit, threads: usize, fuzz: ?u64) !void {
    const gpa = emit.gpa;
    const io = emit.zcu.io;
    // One per thread, and the Sema thread's.
    const workers = try gpa.alloc(Emit, threads + 1);
    errdefer gpa.free(workers);
    for (workers) |*w| {
        w.* = .init(gpa, emit.zcu);
        w.is_worker = true;
        w.obj = emit.obj;
        w.fuzz = emit.fuzz;
        w.pic = emit.pic;
        w.shared = emit.shared;
        w.glibc = emit.glibc;
        w.shared_libs = emit.shared_libs;
    }
    const pool = try gpa.create(Pool);
    pool.* = .{ .io = io, .workers = workers, .fuzz = fuzz };
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

const ProcessMode = enum {
    /// Generate the function; callees that cannot be decided now stay
    /// calls.
    generate,
    /// Generate it, unless a callee cannot be decided now: then hand the
    /// IR back to the Zcu (`ready_irs`) for later.
    generate_or_defer,
    /// Only make its inlinable body: it was loaded from the cache.
    body,
};

/// Decides what `ir`'s function inlines and whether it is inlinable,
/// splices the inlinable callees in, and hands it on as `mode` says.
/// Returns false if it handed the IR back.
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
    var all = s.inlinable;
    for (sites.items) |site| {
        const fate = switch (try emit.inlineFate(site.callee)) {
            .fate => |f| f,
            .cycle => Fate.no,
            .busy => if (mode == .generate_or_defer) {
                try zcu.ready_irs.append(gpa, ir);
                ir_owned = false;
                return false;
            } else Fate.no,
        };
        const yes = switch (fate) {
            .no => {
                all = false;
                continue;
            },
            .yes => |y| y,
        };
        const body = emit.inlineBody(site.callee) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // As for a busy fate.
            error.Busy => if (mode == .generate_or_defer) {
                try zcu.ready_irs.append(gpa, ir);
                ir_owned = false;
                return false;
            } else null,
        } orelse {
            all = false;
            continue;
        };
        size += yes.size;
        callee_hash = cache.hash(@truncate(callee_hash), std.mem.asBytes(&yes.hash)) ^ callee_hash;
        try bodies.append(gpa, body);
        try splices.append(gpa, .{ .site = site, .body = undefined });
    }
    const inlinable = all and size <= emit.inline_budget;
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
    if (inlinable) {
        const hash = cache.hash(size, std.mem.asBytes(&[2]cache.Hash{ own_hash, callee_hash })) ^ emit.inlineSalt();
        var copy = ir.instructions.toMultiArrayList();
        try emit.inline_bodies.append(gpa, .{
            .instructions = (try copy.clone(gpa)).slice(),
            .extra = try gpa.dupe(u32, ir.extra),
            .func = func,
            .main_block = ir.main_block,
            .rbrace_line = ir.rbrace_line,
            .rbrace_column = ir.rbrace_column,
        });
        try emit.inline_fates.put(gpa, func, .{ .yes = .{ .size = size, .hash = hash, .body = @intCast(emit.inline_bodies.items.len - 1) } });
        try zcu.inline_results.put(gpa, func, .{ .size = size, .hash = hash });
    } else try emit.inline_fates.put(gpa, func, .no);
    if (mode == .body) return true;
    ir_owned = false;
    try emit.submit(ir, if (emit.pool != null) try emit.exportsSnapshot() else undefined);
    return true;
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
    if (std.mem.indexOfScalar(Index, emit.inline_active.items, func) != null) return .cycle;
    switch (try emit.zcu.takeFuncBody(func)) {
        .busy => return .busy,
        .failed => try emit.inline_fates.put(emit.gpa, func, .no),
        // Loaded from the cache: its recorded result.
        .done => try emit.inline_fates.put(emit.gpa, func, if (emit.zcu.inline_results.get(func)) |r|
            .{ .yes = .{ .size = r.size, .hash = r.hash, .body = no_body } }
        else
            .no),
        .analyzed => |ir| if (!try emit.inlineProcess(ir, .generate_or_defer)) return .busy,
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
    _ = try emit.inlineProcess(ir, .body);
    const b = emit.inline_fates.get(func).?.yes.body;
    return if (b == no_body) null else b;
}

/// Generates a function whose inlining is done.
fn submit(emit: *Emit, ir_in: Ir, exports: ExportsView) !void {
    const zcu = emit.zcu;
    var ir = ir_in;
    {
        const t0 = std.Io.Timestamp.now(zcu.io, .awake);
        const st = try rewrite.run(emit.gpa, &zcu.ip, Zcu.tid, &ir, &emit.rewrite_scratch);
        emit.codegen_stats.rewrite_ns += @intCast(t0.durationTo(.now(zcu.io, .awake)).nanoseconds);
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
    if (pool.threads == 0) {
        const t0 = std.Io.Timestamp.now(zcu.io, .awake);
        defer emit.codegen_ns += @intCast(t0.durationTo(.now(zcu.io, .awake)).nanoseconds);
        const out = try runJob(&pool.workers[0], ir, exports);
        try pool.batch.append(emit.gpa, .{ .ir = undefined, .exports = exports, .out = out, .done = true });
        return;
    }
    try pool.batch.append(emit.gpa, .{ .ir = ir, .exports = exports });
    if (pool.batch.items.len >= pool.batch_target) try publish(pool, emit.gpa);
    if (pool.fuzz != null) fuzzDelay(pool.io, pool.fuzz_rng.random());
}

/// Under `ZAP_SCHED_FUZZ`: sometimes sleeps up to half a millisecond,
/// sometimes yields.
fn fuzzDelay(io: std.Io, random: std.Random) void {
    switch (random.uintLessThan(u8, 8)) {
        0, 1 => io.sleep(.{ .nanoseconds = random.uintLessThan(u32, 500_000) }, .awake) catch {},
        2, 3 => std.Thread.yield() catch {},
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
        for ((try b.wait()).objects) |o| in.addObject(o.path, o.bytes) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            // As `convertInputs` reports the inputs' problems.
            else => try zcu.addError(0, .{ .start = 0, .end = 0, .main = 0 }, "{s}", .{try std.fmt.allocPrint(emit.allocator(), "unable to link '{s}': {t}", .{ o.path, err })}),
        };
        for ((try b.wait()).archives) |a| in.addArchive(a.path, a.bytes) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => try zcu.addError(0, .{ .start = 0, .end = 0, .main = 0 }, "{s}", .{try std.fmt.allocPrint(emit.allocator(), "unable to link '{s}': {t}", .{ a.path, err })}),
        };
    }
    if (emit.inputs) |in| try emit.pullInputs(in);
    for (emit.rt_pending.keys()) |key| _ = try zcu.requestCompilerRtKey(key);
    emit.rt_pending.clearRetainingCapacity();
}

/// Pulls the archive members the inputs and the Zig code's externs need so
/// far, and requests the compiler_rt functions that the new objects call
/// and nothing else defines, so that analysis generates them.
fn pullInputs(emit: *Emit, in: *ElfInput) !void {
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
    for (names.items) |name| _ = try emit.requestCompilerRtExport(name);
}

/// How names the objects reference but do not define resolve on the Zig
/// side (`ElfInput.convert`).
const InputResolver = struct {
    emit: *Emit,

    pub fn zigExport(r: InputResolver, name: []const u8) !?SymbolKey {
        return r.emit.userExport(name);
    }

    /// compiler_rt's, and the bounds of the init and fini arrays.
    pub fn rtExport(r: InputResolver, name: []const u8) !?SymbolKey {
        if (arrayBound(name)) |key| return key;
        if (Zcu.compilerRtExport(name) == null) return null;
        return r.emit.rtExport(name);
    }

    /// With `-lc`, the shared libraries' and glibc's symbols, imported.
    pub fn importSym(r: InputResolver, name: []const u8, weak: bool) !?SymbolKey {
        if (!r.emit.libraryDefines(name)) return null;
        return try r.emit.useImport(name, .{ .weak = weak });
    }

    /// The executable's copy of a shared library's data object `name`, an
    /// import already (`importSym`), or null if it is not one. The copy
    /// takes the import's key, so every reference to the import uses it.
    pub fn copySym(r: InputResolver, name: []const u8) !?SymbolKey {
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
fn convertInputs(emit: *Emit, in: *ElfInput) !bool {
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
    return true;
}

/// Generates a function into this Emit.
fn generateFunction(emit: *Emit, ir: *const Ir) Allocator.Error!void {
    emit.owner = .{ .unit = .{ .func = ir.func } };
    defer emit.owner = .link;
    const io = emit.zcu.io;
    const t0 = std.Io.Timestamp.now(io, .awake);
    defer emit.codegen_ns += @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
    // Off until its rules are sound: it removed bounds checks it had not
    // proven (`x +% 1 <= n` taken as `x < n`; a load read against a later
    // store).
    const prove_enabled = false;
    if (prove_enabled) {
        // The IR is this job's own.
        const st = try prove.run(emit.gpa, &emit.zcu.ip, @constCast(ir), &emit.prove_scratch);
        emit.codegen_stats.prove_ns += @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
        emit.codegen_stats.checks += st.checks;
        emit.codegen_stats.proven += st.proven;
    }
    CodeGen.generate(emit, ir) catch |err| switch (err) {
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
/// another way (a unit the cache loads), as the serial order has it.
fn syncPending(emit: *Emit) Allocator.Error!void {
    if (emit.pool) |pool| if (pool.jobs.items.len + pool.batch.items.len != 0) try emit.mergeJobs();
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
        .msg = try std.fmt.allocPrint(emit.allocator(), fmt, args),
        .code = comptime Diag.formatCode(fmt),
    });
}

/// `ZAP_BENCH_CODEGEN=n`: generates every function captured during
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
    // Before the declarations: a slot can request an exported one.
    if (!try emit.lowerExternSlots()) return false;
    if (emit.inputs) |in| if (!try emit.convertInputs(in)) return false;
    // An executable's too, with inputs: the cache resolves their
    // references to Zig's exports again when it relinks.
    if (emit.obj or emit.inputs != null) try emit.findExports();
    try emit.lowerNavs();
    if (emit.uses_error_names) try emit.emitErrorNameTable();

    var entry: ?SymbolKey = null;
    for (zcu.exports.items) |e| {
        if (e.target != .nav) continue;
        const nav = ip.getNav(e.target.nav);
        if (nav.status != .resolved) continue;
        if (std.mem.eql(u8, ip.stringSlice(e.name), "_start") and ip.keyTag(nav.val) == .func) {
            entry = try emit.funcKey(nav.val);
        }
    }
    if (emit.failed) return false;
    emit.entry = entry;
    if (entry == null and !emit.obj) {
        try zcu.addError(0, .{ .start = 0, .end = 0, .main = 0 }, "zap requires the root file to export '_start' (std.start is not supported yet)", .{});
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
            pub fn lessThan(c: @This(), a: usize, b: usize) bool {
                return std.mem.lessThan(u8, c.keys[a], c.keys[b]);
            }
        };
        emit.imports.sort(Names{ .keys = emit.imports.keys() });
    }

    // Error codes: the order names were first interned, starting at 1.
    for (emit.errors.keys()) |name| {
        try emit.error_values.append(emit.gpa, .{ .key = errorKey(ip, name), .value = try ip.errorValue(name) });
    }
    return true;
}

/// The name of a declaration's atom until `nameAtoms`: CodeGen runs while
/// analysis can still rename the types names come from
/// (docs/architecture.md, "Type names").
pub const name_later: []const u8 = "(named later)";

/// Names the atoms of declarations and functions, those this build made
/// and those it loaded, from the final names (docs/architecture.md, "Type
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
            try std.fmt.allocPrint(arena, "{s}.{s}__func_{x:0>8}", .{ gop.value_ptr.*, ip.stringSlice(nav.name), @as(u32, @truncate(ip.stableHash(func_index))) })
        else
            try std.fmt.allocPrint(arena, "{s}.{s}", .{ gop.value_ptr.*, ip.stringSlice(nav.name) });
    }
}

/// Links the atoms `finish` prepared into `sub_path`. Returns false, after
/// printing the error, if the link failed.
pub fn link(emit: *Emit, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !bool {
    var diag: Elf.Diagnostic = .{};
    // Source paths are as the compiler opened them, relative to the cwd.
    const cwd = try std.process.currentPathAlloc(io, emit.gpa);
    defer emit.gpa.free(cwd);
    const options: Elf.Options = .{ .entry = emit.entry, .values = emit.error_values.items, .diag = &diag, .debug = emit.debug.items, .comp_dir = cwd, .stack_size = emit.stack_size, .pic = emit.pic != .none, .local_symbols = emit.input_symbols, .input_sections = emit.input_sections, .aliases = emit.aliases.items };
    const imports = try emit.gpa.alloc(ElfObject.Import, emit.imports.count());
    defer emit.gpa.free(imports);
    for (imports, emit.imports.keys(), emit.imports.values()) |*imp, name, f| imp.* = .{ .key = importKey(name), .name = name, .weak = f.weak, .hidden = f.hidden, .tls = f.tls };
    const result = if (emit.glibc) |g| exe: {
        // The copied imports, moved to the end, are the executable's own
        // symbols.
        var n_imports: usize = 0;
        for (imports, 0..) |imp, i| if (!emit.copies.contains(imp.name)) {
            std.mem.swap(ElfObject.Import, &imports[n_imports], &imports[i]);
            n_imports += 1;
        };
        var arena_state: std.heap.ArenaAllocator = .init(emit.gpa);
        defer arena_state.deinit();
        var dynamic = g.dynamicOptions(arena_state.allocator(), imports[0..n_imports], imports[n_imports..], emit.shared_libs) catch |err| switch (err) {
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
        const dynamic: ElfDynamic.Options = .{ .exports = emit.exports.items, .imports = imports, .soname = emit.soname };
        var shared_options = options;
        shared_options.base_address = 0;
        shared_options.dynamic = &dynamic;
        break :shared Elf.link(emit.gpa, io, dir, sub_path, emit.atoms.items, shared_options);
    } else if (emit.obj)
        ElfObject.link(emit.gpa, io, dir, sub_path, emit.atoms.items, options, .{ .exports = emit.exports.items, .imports = imports })
    else
        Elf.link(emit.gpa, io, dir, sub_path, emit.atoms.items, options);
    result catch |err| {
        std.debug.print("error: link failed: {t} (atom '{s}' target {x})\n", .{ err, diag.atom, if (diag.target) |t| @backingInt(t) else 0 });
        return false;
    };
    return true;
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
    return try emit.requestCompilerRt(e.file, e.decl);
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
    return .fromName(std.fmt.bufPrint(&buf, "extern.{s}", .{name}) catch name);
}

/// The key a constant that a function reads relocates the address of
/// external symbol `name` to (`externDataTarget`): bound at link time,
/// through an alias, to where `name`'s slot binds it. The constant's
/// content then does not depend on where the symbol is defined.
pub fn externAddrKey(name: []const u8) SymbolKey {
    var buf: [256]u8 = undefined;
    return .fromName(std.fmt.bufPrint(&buf, "extaddr.{s}", .{name}) catch name);
}

/// An `externAddrKey` and its slot's binding.
pub const Alias = Elf.Alias;

/// The `useExtern` name of the slot for the address `off` bytes into
/// symbol `name`.
pub fn externSlotName(emit: *Emit, name: []const u8, off: i64) Allocator.Error![]const u8 {
    if (off == 0) return name;
    return std.fmt.allocPrint(emit.allocator(), "{s}\x00{d}", .{ name, off });
}

/// The symbol and offset of a `useExtern` name (`externSlotName`).
fn parseExternSlot(slot: []const u8) struct { []const u8, i64 } {
    const nul = std.mem.indexOfScalar(u8, slot, 0) orelse return .{ slot, 0 };
    return .{ slot[0..nul], std.fmt.parseInt(i64, slot[nul + 1 ..], 10) catch unreachable };
}

/// The key relocations name an imported symbol by (see `useImport`).
pub fn importKey(name: []const u8) SymbolKey {
    var buf: [256]u8 = undefined;
    return .fromName(std.fmt.bufPrint(&buf, "import.{s}", .{name}) catch name);
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
};

/// The thread-local an `extern threadlocal` names: the compilation's
/// export of that name, or in an object an import, which the final link
/// resolves. zap's executables and shared objects import no thread-locals.
pub fn tlsTarget(emit: *Emit, name: []const u8) !TlsTarget {
    if (try emit.userExport(name)) |key| return .{ .key = key, .local = true };
    if (emit.obj and !emit.shared) return .{ .key = try emit.useImport(name, .{ .tls = true }), .local = false };
    if (emit.shared)
        try emit.addError(0, .{ .start = 0, .end = 0, .main = 0 }, "zap does not import thread-local symbols into shared objects yet: {s}", .{name})
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
    if (emit.shared and std.mem.eql(u8, name, "_DYNAMIC")) return ElfDynamic.dynamic_key;
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
    var seen: std.StringHashMapUnmanaged(void) = .empty;
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
        if ((try seen.getOrPut(emit.gpa, name)).found_existing) continue;
        try emit.exports.append(emit.gpa, .{ .key = key, .name = name, .weak = x.linkage == .weak, .visibility = x.visibility });
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
        pub fn lessThan(c: @This(), a: usize, b: usize) bool {
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
        const relocs: []const Atom.Reloc = if (target) |t| try arena.dupe(Atom.Reloc, &.{.init(0, .x86_64_abs64, 0, std.math.cast(i32, t.addend + off) orelse return error.Overflow)}) else &.{};
        try emit.addAtom(.{
            .key = externSlotKey(slot),
            .name = if (off == 0) try std.fmt.allocPrint(arena, "extern.{s}", .{name}) else try std.fmt.allocPrint(arena, "extern.{s}+{d}", .{ name, off }),
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
    const key = if (emit.inputs) |in| if (try emit.userExport(name)) |key| key else if (try in.lookup(name)) |t|
        return .{ .key = t.key, .addend = @intCast(t.offset) }
    else
        sectionBound(name) orelse arrayBound(name) orelse try emit.exportTarget(name)
    else if (emit.shared)
        try emit.userExport(name) orelse try emit.rtExport(name) orelse
            if (std.mem.eql(u8, name, "_DYNAMIC")) ElfDynamic.dynamic_key else try emit.useImport(name, .{ .weak = weak })
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
fn sectionBound(name: []const u8) ?SymbolKey {
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
/// links it. Complete only once analysis is.
pub fn exportTarget(emit: *Emit, name: []const u8) !?SymbolKey {
    emit.export_lookups += 1;
    if (try emit.userExport(name)) |key| return key;
    // A shared object links compiler_rt in, as upstream's do.
    if (emit.obj and !emit.shared) return try emit.useImport(name, .{});
    // compiler_rt before libc, as upstream: its `fmod` and `memcpy` stay
    // in the executable, and only names it lacks are imported.
    if (try emit.rtExport(name)) |key| return key;
    if (emit.libraryDefines(name)) return try emit.useImport(name, .{});
    if (emit.shared) return try emit.useImport(name, .{});
    return null;
}

/// Whether an executable that links glibc imports `name`: one of its
/// shared libraries or glibc defines it.
fn libraryDefines(emit: *const Emit, name: []const u8) bool {
    const g = emit.glibc orelse return false;
    return Glibc.sharedSymbol(emit.shared_libs, name) != null or g.get(name) != null;
}

/// The compiler_rt function exported as `name`, requested, or null.
fn rtExport(emit: *Emit, name: []const u8) !?SymbolKey {
    const e = Zcu.compilerRtExport(name) orelse return null;
    var buf: [128]u8 = undefined;
    return .fromName(try emit.requestRtKey(Zcu.compilerRtKey(&buf, e.file, e.decl)));
}

/// The symbol the compilation exports as `name`, or null.
fn userExport(emit: *Emit, name: []const u8) !?SymbolKey {
    const ip = &emit.zcu.ip;
    const view = emit.exportsView();
    for (view.list, 0..) |x, i| {
        if (!std.mem.eql(u8, ip.stringSlice(x.name), name)) continue;
        const x_nav = switch (x.target) {
            .nav => |n| n,
            .uav => |v| return try emit.uavKey(v, 0),
        };
        const nav = ip.getNav(x_nav);
        if (!(if (view.resolved) |r| r[i] else nav.status == .resolved)) continue;
        return if (ip.keyTag(nav.val) == .func) try emit.funcKey(nav.val) else try emit.navKey(x_nav);
    }
    return null;
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
    var groups: std.AutoArrayHashMapUnmanaged(Group, void) = .empty;
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

        fn lessThan(c: @This(), x: u32, y: u32) bool {
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
        .fromName(std.fmt.bufPrint(&buf, "cntrs.{x}", .{k}) catch unreachable),
        .fromName(std.fmt.bufPrint(&buf, "pcs.{x}", .{k}) catch unreachable),
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
        .name = try std.fmt.allocPrint(arena, "__anon_{x}", .{@backingInt(key)}),
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

pub fn errorKey(ip: *const InternPool, name: InternPool.String) SymbolKey {
    return errorKeyFromName(ip.stringSlice(name));
}

pub fn errorKeyFromName(name: []const u8) SymbolKey {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "error.{s}", .{name}) catch unreachable;
    return .fromName(s);
}

/// A `[:0]const u8` per error code, for `@errorName` at runtime. It is
/// built after every function is lowered, when the set of errors the
/// program uses is known; codes stay symbolic everywhere else.
pub const error_name_table: SymbolKey = .fromName("__zap_error_names");

fn emitErrorNameTable(emit: *Emit) !void {
    const ip = &emit.zcu.ip;
    const gpa = emit.gpa;
    var max: u32 = 0;
    for (emit.errors.keys()) |name| max = @max(max, try ip.errorValue(name));
    const bytes = try emit.allocator().alloc(u8, (@as(usize, max) + 1) * 16);
    @memset(bytes, 0);
    var refs: Atom.RelocList = .{};
    defer refs.deinit(gpa);
    // In code order, not use order, so that the atom is the same however
    // the build reached its uses (an edit build loads some of them).
    for (ip.error_names.items[1 .. max + 1]) |name| {
        if (!emit.errors.contains(name)) continue;
        const s = ip.stringSlice(name);
        const z = try gpa.alloc(u8, s.len + 1);
        defer gpa.free(z);
        @memcpy(z[0..s.len], s);
        z[s.len] = 0;
        const off: u32 = try ip.errorValue(name) * 16;
        try refs.append(gpa, off, .x86_64_abs64, try emit.contentAtom(1, z, &.{}, &.{}), 0);
        std.mem.writeInt(u64, bytes[off + 8 ..][0..8], s.len, .little);
    }
    refs.sort();
    try emit.addAtom(.{
        .key = error_name_table,
        .name = "__zap_error_names",
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
    try emit.addAtom(.{
        .key = .fromName(try emit.unitName(.{ .nav_val = nav_index })),
        .name = name_later,
        .section = if (nav.is_threadlocal) .tdata else if (nav.is_const) .rodata else .data,
        .alignment = .fromByteUnits(if (nav.alignment != 0) nav.alignment else Type.abiAlignment(ip, ty)),
        .bytes = bytes,
        .targets = try arena.dupe(SymbolKey, refs.targets.keys()),
        .relocs = try arena.dupe(Atom.Reloc, refs.relocs.items),
    });
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
        const name = try std.fmt.allocPrint(arena, "f{d}", .{i});
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
            const extra = try std.fmt.allocPrint(arena, "data{d}", .{i});
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
