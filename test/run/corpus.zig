//! exit: 0
//! stdout: "*corpus.S\n*const corpus.S\n*corpus.S\n5\n42\n9\n1\n1\n1\n1\n1\n300\n20\n3\n2\n42\n7\n1\n2\n2\n7\n1\n42\n39\n5\n1\n3\n1\n7\n99\n98\n1073742824\n4\n7\n1\n6\n41\n15\n1\n2\n7\n1\n8\n2\n42\n42\n12\n42\nb\n4\n42\n7\n24\n42\n199\nhello\n74\nabc\n40\n"
//! Reductions of bugs real projects hit (tools/corpus): each section names
//! the project it came from.
const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

// zls (analyser/segmented_list.zig): a method call passes an `anytype`
// first parameter the object's address, not a copy.
const S = struct {
    items: [4]u32 = .{ 0, 0, 0, 0 },
    fn name(self: anytype) []const u8 {
        return @typeName(@TypeOf(self));
    }
    fn AtType(comptime Self: type) type {
        return if (@typeInfo(Self).pointer.attrs.@"const") *const u32 else *u32;
    }
    fn at(self: anytype, i: usize) AtType(@TypeOf(self)) {
        return &self.items[i];
    }
};
const Holder = struct { s: S = .{} };
fn atThroughPointer(h: *Holder) *u32 {
    return h.s.at(1);
}

// z2d (internal/util.zig): a generic function passed as a comptime
// function pointer is instantiated by the calls, never compiled on its own.
fn runCases(cases: anytype, comptime f: *const fn (case: anytype) u32) u32 {
    var sum: u32 = 0;
    for (cases) |c| sum += f(c);
    return sum;
}
const Case = struct { expected: u32 };
fn expected(c: anytype) u32 {
    return c.expected;
}

// ghostty (lib/enum.zig): referring to a function with a comptime-only
// parameter or result (`std.testing.refAllDecls`) does not compile it.
fn Pair(n: []const u8) type {
    return [n.len]u8;
}

// zls (features/hover.zig): `len` is an ordinary field of an anonymous
// struct, also through the pointer a parameter is reached by.
fn lenField(args: anytype) usize {
    return args.len;
}

// ghostty (terminal/stream_terminal.zig): a struct literal stored into a
// global optional (or error union) is set at run time.
var global_opt: ?struct { x: u32, y: []const u8 } = null;
var global_eu: error{Bad}!struct { x: u32 } = error.Bad;

// zig-clap (clap.zig): a field seen as a one-element array (`*T` to
// `*[1]T`) loads as the array at comptime.
const Names = struct {
    short: ?u8 = null,
    fn longest(n: *const Names) []const u8 {
        if (n.short) |*s| return @as(*const [1]u8, s);
        return "";
    }
};

// superhtml (css/Ast.zig): a function in an anonymous struct's field is
// called with method syntax.
fn twice(x: u32) u32 {
    return 2 * x;
}
const rules = .{.{ .name = "a", .func = twice }};

// zig-protobuf (protobuf.zig): a prong over several union fields captures
// the active one at comptime, coerced to their peer type if they differ.
const Repeated = union(enum) { scalar: u8, submessage: void };
const FieldType = union(enum) { repeated: Repeated, packed_repeated: Repeated, small: u8, wide: u16 };
fn isSubmessage(comptime t: FieldType) bool {
    return switch (t) {
        .repeated, .packed_repeated => |r| r == .submessage,
        else => false,
    };
}
fn width(comptime t: FieldType) u32 {
    return switch (t) {
        .small, .wide => |w| w,
        else => 0,
    };
}

// zig-protobuf (wire.zig): `if (runtime) comptime continue;` in an inline
// loop continues only when the condition holds.
fn pick(x: u32) u32 {
    var r: u32 = 0;
    inline for (.{ 1, 2, 3 }) |n| {
        if (n != x) comptime continue;
        r += n * 10;
    }
    return r;
}

// zig-minisign (wasm.zig): @enumFromInt takes an integer of any type.
const Result = enum(isize) { overflow = -12, _ };
const Small = enum(u8) { a, b, c };
fn resultFromLen(len: usize) Result {
    return @enumFromInt(len);
}
fn small(i: u32) Small {
    return @enumFromInt(i);
}

// ziggy (known-folders): a struct literal that leaves a comptime field to
// its default stores nothing for it, not the default over a runtime field.
const Config = struct { a: u32 = 7, b: bool = true };
const WithConfig = struct {
    comptime config: Config = .{},
    p: *const u64,
};

// zio (ev/backends/linux/epoll.zig): a function returning a smaller error
// set coerces to a function type returning `anyerror`.
const SockErr = error{ Refused, Reset };
fn sockErr(code: u32) SockErr {
    return if (code == 0) error.Refused else error.Reset;
}
fn handleErr(comptime toErr: fn (u32) anyerror, code: u32) anyerror {
    return toErr(code);
}

// libxev (watcher/stream.zig): a callback whose parameter takes more errors
// coerces to a callback type that passes fewer.
fn readCb(r: error{ Eof, Reset, Canceled }!u32) u32 {
    return r catch |e| switch (e) {
        error.Eof => 1,
        error.Reset => 2,
        error.Canceled => 3,
    };
}
fn readWith(comptime cb: *const fn (r: error{ Eof, Reset }!u32) u32, r: error{ Eof, Reset }!u32) u32 {
    return cb(r);
}
// libxev (watcher/stream.zig): such a callback called inline through the
// coerced pointer is inlined with the pointer's parameter types.
fn readCbWide(r: error{ Eof, Reset, Canceled }!u32) u32 {
    return r catch |e| if (e == error.Reset) 2 else 1;
}
fn readInline(comptime cb: *const fn (r: error{ Eof, Reset }!u32) u32, r: error{ Eof, Reset }!u32) u32 {
    return @call(.always_inline, cb, .{r});
}

// tokamak (util/shm.zig): a zero-terminated slice coerces to a C pointer.
fn cStrLen(s: [*c]const u8) u64 {
    var n: u64 = 0;
    while (s[n] != 0) n += 1;
    return n;
}
fn passName(name: [:0]const u8) u64 {
    return cStrLen(name);
}

// tokamak (schema.zig, through std.json.Stringify): a union's generated
// tag enum has none of the union's declarations.
const Schema = union(enum) {
    null,
    array: u32,
    pub fn jsonStringify(self: Schema) u32 {
        return @intFromEnum(self);
    }
};

// zio (coro/coroutines.zig): the address of a local label (past a branch
// that shortens), `pushq $imm`, and a jump through memory.
fn jumpViaLabel() callconv(.naked) void {
    asm volatile (
        \\ leaq 0f(%%rip), %%rdx
        \\ pushq %%rdx
        \\ pushq $40
        \\ popq %%rax
        \\ testq %%rax, %%rax
        \\ jnz 1f
        \\ ud2
        \\1:
        \\ addq $2, %%rax
        \\ jmpq *0(%%rsp)
        \\ ud2
        \\0:
        \\ popq %%rdx
        \\ retq
    );
}

// zio (coro/coroutines.zig): a function whose asm clobbers callee-saved
// registers saves them for its caller.
noinline fn clobberCalleeSaved() void {
    asm volatile (
        \\ xorl %%ebx, %%ebx
        \\ xorl %%r12d, %%r12d
        \\ xorl %%r15d, %%r15d
        ::: .{ .rbx = true, .r12 = true, .r15 = true });
}
noinline fn liveAcrossClobber(x: u64) u64 {
    const a = x *% 3;
    const b = x +% 11;
    clobberCalleeSaved();
    return a +% b;
}

// zwasm (engine/codegen/shared/entry.zig): an asm whose clobbers are a
// named constant, not a literal, saves the callee-saved registers they
// name.
fn zeroRbx() callconv(.naked) void {
    asm volatile (
        \\ xorl %%ebx, %%ebx
        \\ xorl %%r12d, %%r12d
        \\ retq
    );
}
var zero_rbx: *const fn () callconv(.c) void = @ptrCast(&zeroRbx);
const jit_clobbers: @import("std").lang.assembly.Clobbers = .{ .rbx = true, .r12 = true, .memory = true };
noinline fn jitTrampoline() callconv(.c) void {
    zero_rbx();
    asm volatile ("" ::: jit_clobbers);
}
fn rbxAcrossTrampoline() u64 {
    return asm volatile (
        \\ pushq %%rbx
        \\ movq $42, %%rbx
        \\ callq *%[f]
        \\ movq %%rbx, %[out]
        \\ popq %%rbx
        : [out] "={rax}" (-> u64),
        : [f] "r" (&jitTrampoline),
        : .{ .rcx = true, .rdx = true, .rsi = true, .rdi = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .memory = true });
}

// tokamak (meta.zig): a comptime variable written a byte at a time
// through a `*[N]u8` view is defined once written; bytes never written
// read as 0xaa, as upstream.
fn transmuteBytes(comptime T: type, val: anytype) T {
    var tmp: T = undefined;
    const src: *const [@sizeOf(T)]u8 = @ptrCast(&val);
    @memcpy(@as(*[@sizeOf(T)]u8, @ptrCast(&tmp)), src);
    return tmp;
}
fn partlyWritten() u64 {
    var t: u64 = undefined;
    const p: *[8]u8 = @ptrCast(&t);
    p[0] = 5;
    return t;
}

// zbor (src/builder.zig): ranges that cover all of u64 make a switch
// exhaustive without an `else`.
fn headBytes(v: u64) u8 {
    return switch (v) {
        0x00...0x17 => 1,
        0x18...0xffffffff => 2,
        0x0000000100000000...0xffffffffffffffff => 3,
    };
}

// monstar (dbus/Connection.zig): an over-aligned pointer coerces to
// `*anyopaque`, whose alignment is 1, as upstream.
fn opaqueAddr(p: ?*const anyopaque) u64 {
    return @intFromPtr(p);
}

// monstar (Keyboard.zig): optional pointers coerce to C pointers, null to
// null.
fn optCStrLen(s: ?[*:0]const u8) u64 {
    const c: [*c]const u8 = s;
    if (c == null) return 99;
    return cStrLen(c);
}

// ziglua (lib.zig): an inline function's return type, and a later
// parameter's type, do arithmetic on a runtime `anytype` argument.
const registry_index = -(@divTrunc(@as(c_int, 2147483647), @as(c_int, 2)) + @as(c_int, 1000));
inline fn upvalueIndex(i: anytype) @TypeOf(registry_index - i) {
    return registry_index - i;
}
inline fn offsetBy(i: anytype, j: @TypeOf(registry_index - i)) @TypeOf(registry_index - i) {
    return j - i;
}

// ziglua (lib.zig): runtime function pointers coerce to C callback types
// whose parameter is a C pointer where the function takes an optional
// pointer, or whose result is less aligned.
const LuaState = opaque {};
const LuaDebug = extern struct { x: c_int };
fn luaHook(s: ?*LuaState, d: ?*LuaDebug) callconv(.c) void {
    _ = s;
    d.?.x = 7;
}
var lua_block: [16]u8 align(16) = undefined;
fn luaAlloc(ud: ?*anyopaque, p: ?*anyopaque, o: usize, n: usize) callconv(.c) ?*align(16) anyopaque {
    _ = .{ ud, p, o };
    return if (n == 0) null else &lua_block;
}
const LuaCHook = ?*const fn (?*LuaState, [*c]LuaDebug) callconv(.c) void;
const LuaCAlloc = ?*const fn (?*anyopaque, ?*anyopaque, usize, usize) callconv(.c) ?*anyopaque;
noinline fn setHook(f: *const fn (?*LuaState, ?*LuaDebug) callconv(.c) void) LuaCHook {
    return f;
}
noinline fn setAlloc(f: ?*const fn (?*anyopaque, ?*anyopaque, usize, usize) callconv(.c) ?*align(16) anyopaque) LuaCAlloc {
    return f;
}

// zig-libs: a comptime-built anonymous struct's array field (a comptime
// field) is indexed at run time.
const exp_table = blk: {
    var exp: [4]u8 = .{ 0, 3, 6, 9 };
    _ = &exp;
    break :blk .{ .exp = exp };
};

// zig-libs (strRepeat): a comptime @bitCast of a nested array costs time
// and memory linear in its length (quadratic ran out of memory).
const repeat_grid: [30000][4]u8 = @splat("(?:)".*);
const repeated: [4 * 30000]u8 = @bitCast(repeat_grid);

// zigcli (src/gitignore.zig): an error prong named through a declared
// set (`E.A`) leaves the else prong's capture the error.
const GiErr = error{A};
fn giF(x: u8) !u8 {
    if (x == 0) return GiErr.A;
    if (x == 1) return error.B;
    return x;
}
fn giG(x: u8) !u8 {
    return giF(x) catch |e| switch (e) {
        GiErr.A => 10,
        else => return e,
    };
}

// zigcli (std.testing.expectEqualDeep): a slice and a pointer to an
// array whose elements differ in const and sentinel have the slice's type
// as their peer.
fn peerLen(a: []const [:0]const u8, buf: *[1][:0]u8) usize {
    const T = @TypeOf(a, buf);
    const x: T = buf;
    return x.len + @intFromBool(T == []const [:0]const u8);
}

// astroz (cfitsio's fits_open_file), zigcli zfetch (getifaddrs): `*?*S`
// passes as `[*c][*c]S`.
const FitsFile = extern struct { x: c_int };
fn fitsOpen(out: [*c][*c]FitsFile) callconv(.c) c_int {
    out.* = null;
    return 7;
}

// revo (std.c.pipe): `*[2]i32` passes as `*[2]c_int`, and back.
fn cPipe(fds: *[2]c_int) *[2]i32 {
    fds[1] = 4;
    return fds;
}

// dvui (Data.zig): @ptrCast(@alignCast()) of an optional slice into an
// optional pointer keeps null.
var data_buf: [8]u8 align(4) = .{ 1, 0, 0, 0, 2, 0, 0, 0 };
noinline fn dataGet(some: bool) ?[]u8 {
    return if (some) &data_buf else null;
}
fn dataPtr(some: bool) ?*u32 {
    return @ptrCast(@alignCast(dataGet(some)));
}

// dvui (App.zig): a comptime struct's `fn () anyerror!T` field holds a
// function whose error set is inferred.
const App = struct { frameFn: fn () anyerror!u8 };
fn appFrame() !u8 {
    return error.Oops;
}
const app: App = .{ .frameFn = appFrame };

// dvui (Examples/animations.zig): a constant destructured from a comptime
// block holds an array built in a comptime var, and runtime code takes its
// address.
fn namesLen(entries: []const []const u8) usize {
    var n: usize = 0;
    for (entries) |e| n += e.len;
    return n;
}

// marionette (fiber.zig): a decl literal of `std.lang.CallingConvention`
// that calls one of its functions gives a calling convention.
fn alignedInc(x: u32) callconv(.withStackAlign(.c, 16)) u32 {
    return x + 1;
}

// verse (ContentType.zig): `inline else` over a comptime-known
// non-exhaustive enum analyzes only the matching prong, though the type's
// values cannot be enumerated.
const Wide = enum(u8) { a, b, _ };
fn wideName(comptime e: Wide) []const u8 {
    return switch (e) {
        inline else => |r| @tagName(r),
    };
}

// knoedel (ecs.zig): a call of a function returning `type` is evaluated at
// comptime with its arguments, even to runtime parameters.
fn doubled(x: u64) u64 {
    return x * 2;
}
fn ValueHolder(n: u64) type {
    return struct {
        const v = n;
    };
}

// knoedel (std's hash_map `Iterator.next` over `ScheduleID` keys): indexing
// a many-pointer resolves the element's layout, which CodeGen scales the
// index by, when nothing else needs it.
const Elem = struct { id: u32, value: u32 };
fn elemOffset(p: [*]Elem, i: usize) usize {
    return @intFromPtr(&p[i]) - @intFromPtr(p);
}

// siv (compositor/Compositor.zig): a weak `@extern` function in a
// container-level constant, tested at run time.
fn weakTwiceImpl(x: u32) callconv(.c) u32 {
    return 2 * x;
}
comptime {
    @export(&weakTwiceImpl, .{ .name = "bs_corpus_weak_twice" });
    @export(&addOneImpl, .{ .name = "bs_corpus_add_one" });
}
const weak_twice = @extern(?*const fn (u32) callconv(.c) u32, .{ .name = "bs_corpus_weak_twice", .linkage = .weak });
fn weakTwice(x: u32) ?u32 {
    const f = weak_twice orelse return null;
    return f(x);
}

// siv (lua/job.zig): an inner function reads a local array of extern
// functions, which is comptime-known.
fn addOneImpl(x: c_int) callconv(.c) c_int {
    return x + 1;
}
extern fn bs_corpus_add_one(c_int) c_int;
const AddFn = ?*const fn (c_int) callconv(.c) c_int;
fn externTable() c_int {
    const fns = [_]struct { [*:0]const u8, AddFn }{
        .{ "a", bs_corpus_add_one },
        .{ "b", &bs_corpus_add_one },
    };
    return struct {
        fn run(x: c_int) callconv(.c) c_int {
            var sum: c_int = 0;
            for (fns) |f| sum += f[1].?(x) + f[0][0];
            return sum;
        }
    }.run(1);
}

// ghostty (apprt/surface.zig): an array field's `len`, read through a
// runtime object in a comptime argument, is comptime-known from its type.
const Titled = struct {
    title: [63:0]u8,
    alt: union { arr: [11]u8, n: u32 },
    fn init(t: []const u8) Titled {
        var result: Titled = undefined;
        copyZ(result.title.len, &result.title, t);
        return result;
    }
    fn copyZ(comptime cap: usize, dst: *[cap:0]u8, src: []const u8) void {
        const len = @min(src.len, cap);
        @memcpy(dst[0..len], src[0..len]);
        dst[len] = 0;
    }
    fn lens(self: Titled) usize {
        return comptimeLen(self.title.len) + comptimeLen(self.alt.arr.len);
    }
};
fn comptimeLen(comptime n: usize) usize {
    return n;
}
fn titleLen(t: *const [63:0]u8) usize {
    var n: usize = 0;
    while (t[n] != 0) n += 1;
    return n;
}

// zigdown (plutosvg.zig): a function taking and returning `i32` coerces to
// a pointer to one with `c_int`, the same integer in memory.
const CIntCb = ?*const fn (c_int) callconv(.c) c_int;
fn twiceI32(x: i32) callconv(.c) i32 {
    return x * 2;
}

// zigdown (treez.zig): `@extern` of an optional function pointer to a
// symbol that is not weak is comptime-known non-null, so `orelse
// @compileError(...)` compiles.
export fn corpus_tree_sitter_x() callconv(.c) u32 {
    return 7;
}
fn externLanguage(comptime name: []const u8) u32 {
    const ext = @extern(?*const fn () callconv(.c) u32, .{ .name = "corpus_tree_sitter_" ++ name }) orelse
        @compileError("Cannot find extern corpus_tree_sitter_" ++ name);
    return ext();
}

// tls (stdx buffer.zig): a field's explicit `align(n)` shows in its
// pointer type even when n is the natural alignment, so a switch on
// `@TypeOf(&self.buffer)` takes the aligned prong.
fn AlignedBuf(comptime T: type, comptime a: usize, comptime cap: usize) type {
    return struct {
        const Self = @This();
        buffer: [cap]T align(a),
        len: usize,
        fn slice(self: *Self) switch (@TypeOf(&self.buffer)) {
            *align(a) [cap]T => []align(a) T,
            *align(a) const [cap]T => []align(a) const T,
            else => unreachable,
        } {
            return self.buffer[0..self.len];
        }
    };
}
const FieldAligns = struct { a: [4]u8 align(1), b: u32 align(4), c: u32 };
fn fieldAlignKinds() u32 {
    var f: FieldAligns = undefined;
    _ = &f;
    const exact = [_]bool{
        @TypeOf(&f.a) == *align(1) [4]u8,
        @TypeOf(&f.b) == *align(4) u32,
        @TypeOf(&f.c) == *u32,
        @TypeOf(f.a[0..2]) == *align(1) [2]u8,
    };
    const natural = [_]bool{ @TypeOf(&f.a) == *[4]u8, @TypeOf(&f.b) == *u32 };
    var n: u32 = 0;
    for (exact) |b| n += if (b) 10 else 0;
    for (natural) |b| n += if (b) 1 else 0;
    return n;
}

fn main() callconv(.c) noreturn {
    var s: S = .{};
    const c: S = .{};
    const p = &s;
    rt.print(s.name());
    rt.print("\n");
    rt.print(c.name());
    rt.print("\n");
    rt.print(p.name());
    rt.print("\n");
    var h: Holder = .{};
    atThroughPointer(&h).* = 5;
    rt.printInt(h.s.items[1]);

    rt.printInt(runCases([_]Case{ .{ .expected = 40 }, .{ .expected = 2 } }, expected));
    _ = &Pair;

    var len: u7 = 9;
    _ = &len;
    rt.printInt(lenField(.{ .len = len }));

    global_opt = .{ .x = 1, .y = "y" };
    global_eu = .{ .x = 1 };
    rt.printInt(global_opt.?.x);
    rt.printInt((global_eu catch unreachable).x);

    const arr = comptime blk: {
        const n: Names = .{ .short = 'a' };
        const l = n.longest();
        break :blk l[0..l.len].*;
    };
    rt.printInt(@intFromBool(@TypeOf(arr) == [1]u8 and arr[0] == 'a'));
    rt.printInt(@intFromBool(rules[0].func(21) == 42));

    rt.printInt(@intFromBool(comptime isSubmessage(.{ .packed_repeated = .submessage })));
    rt.printInt(comptime width(.{ .wide = 300 }));

    var two: u32 = 2;
    _ = &two;
    rt.printInt(pick(two));

    var three: u32 = 3;
    _ = &three;
    rt.printInt(@intCast(@intFromEnum(resultFromLen(three))));
    rt.printInt(@intFromEnum(small(three - 1)));

    const x: u64 = 42;
    var wc: WithConfig = .{ .p = &x };
    _ = &wc;
    rt.printInt(wc.p.*);
    rt.printInt(wc.config.a);

    rt.printInt(@intFromBool(handleErr(sockErr, 1) == error.Reset));
    var eof: error{ Eof, Reset }!u32 = error.Reset;
    _ = &eof;
    rt.printInt(readWith(readCb, eof));
    rt.printInt(readInline(readCbWide, eof));
    rt.printInt(passName("tokamak"));
    const Tag = @typeInfo(Schema).@"union".tag_type.?;
    rt.printInt(@intFromBool(@hasDecl(Schema, "jsonStringify") and !@hasDecl(Tag, "jsonStringify")));
    const jump: *const fn () callconv(.c) u64 = @ptrCast(&jumpViaLabel);
    rt.printInt(jump());
    var seven: u64 = 7;
    _ = &seven;
    rt.printInt(liveAcrossClobber(seven));
    rt.printInt(comptime transmuteBytes(u64, [2]u32{ 5, 0 }));
    rt.printInt(@intFromBool(comptime partlyWritten() == 0xaaaaaaaaaaaaaa05));
    var big: u64 = 0x1_0000_0000;
    _ = &big;
    rt.printInt(headBytes(big));
    var aligned: [80]u8 align(8) = undefined;
    rt.printInt(@intFromBool(opaqueAddr(&aligned) == @intFromPtr(&aligned)));
    var name: ?[*:0]const u8 = "monstar";
    _ = &name;
    rt.printInt(optCStrLen(name));
    rt.printInt(optCStrLen(null));
    var one: ?*const u8 = &"ab"[0];
    _ = &one;
    const c_one: [*c]const u8 = one;
    rt.printInt(c_one[1]);
    var up: i32 = 1;
    _ = &up;
    rt.printInt(@intCast(-upvalueIndex(up)));
    rt.printInt(@intCast(offsetBy(up, 5)));
    var dbg: LuaDebug = .{ .x = 0 };
    setHook(&luaHook).?(null, &dbg);
    rt.printInt(@intCast(dbg.x));
    const alloc = setAlloc(&luaAlloc).?;
    rt.printInt(@intFromBool(alloc(null, null, 0, 16) == @as(*anyopaque, &lua_block) and alloc(null, null, 16, 0) == null));
    var two_i: usize = 2;
    _ = &two_i;
    rt.printInt(exp_table.exp[two_i]);
    var last: usize = repeated.len - 1;
    _ = &last;
    rt.printInt(repeated[last]);
    rt.printInt((giG(0) catch 0) + (giG(5) catch 0));
    rt.printInt(if (giG(1)) |_| 0 else |e| @intFromBool(e == error.B));
    var y = "y".*;
    var peer_buf = [1][:0]u8{y[0..1 :0]};
    rt.printInt(peerLen(&.{"x"}, &peer_buf));
    var fits: ?*FitsFile = undefined;
    rt.printInt(@intCast(fitsOpen(&fits)));
    rt.printInt(@intFromBool(fits == null));
    var fds: [2]i32 = .{ 0, 0 };
    rt.printInt(@intCast(cPipe(&fds)[1] + fds[1]));
    rt.printInt(dataPtr(true).?.* + @intFromBool(dataPtr(false) == null));
    rt.printInt(app.frameFn() catch 42);
    rt.printInt(rbxAcrossTrampoline());
    const names_k, const names = comptime blk: {
        var out: [2][]const u8 = undefined;
        out[0] = "ab";
        out[1] = "cde";
        break :blk .{ 7, out };
    };
    rt.printInt(names_k + namesLen(&names));
    rt.printInt(alignedInc(41));
    rt.print(wideName(.b));
    rt.print("\n");
    rt.printInt(ValueHolder(doubled(2)).v);
    const cint_cb: CIntCb = twiceI32;
    rt.printInt(@intCast(cint_cb.?(21)));
    rt.printInt(externLanguage("x"));
    var elems: [*]Elem = undefined;
    _ = &elems;
    rt.printInt(elemOffset(elems, 3));
    rt.printInt(weakTwice(21) orelse 0);
    rt.printInt(@intCast(externTable()));
    const titled = Titled.init("hello");
    rt.print(titled.title[0..titleLen(&titled.title)]);
    rt.print("\n");
    rt.printInt(titled.lens());
    var abuf: AlignedBuf(u8, 1, 8) = .{ .buffer = "abcdefgh".*, .len = 3 };
    rt.print(abuf.slice());
    rt.print("\n");
    rt.printInt(fieldAlignKinds());
    rt.exit(0);
}
