"""Mistakes for the agent-diagnostics eval (see run.py).

A rule rewrites a seed program, which is correct 0.17 code, into the
mistake. `migration` rules write an API the way 0.11 to 0.16 spelled it
(the `since` field names the release that changed it); the other rules
are mistakes that do not depend on the release: misspelled names, a
missing `try` or `.?`, and the like.

Every rule names the facts an agent needs to fix the mistake: groups of
strings, each group satisfied by any one of its strings appearing in the
compiler's output (case-sensitive). `answer`, when set, is the name a
correct candidate list contains.

A case whose rewrite upstream still accepts is not a mistake in 0.17 and
is dropped by run.py, so a rule may be written without checking that the
old spelling is gone.
"""

import difflib
import re


class Case:
    def __init__(self, rule, seed, src, lines, facts, answer=None, variant=""):
        self.rule = rule
        self.seed = seed
        self.src = src
        # 1-based lines of `src` that the rewrite changed or inserted.
        self.lines = lines
        self.facts = facts
        self.answer = answer
        self.variant = variant

    @property
    def id(self):
        v = f"-{self.variant}" if self.variant else ""
        return f"{self.rule.id}{v}@{self.seed}"


def changed_lines(old, new):
    """The 1-based lines of `new` that differ from `old`; for a pure
    deletion, the line after it."""
    a, b = old.split("\n"), new.split("\n")
    out = set()
    for tag, _, _, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if tag == "equal":
            continue
        if j1 == j2:
            out.add(min(j1 + 1, len(b)))
        out.update(range(j1 + 1, j2 + 1))
    return sorted(out)


class Rule:
    """A rewrite by regular expressions, applied in order to a seed."""

    def __init__(self, id, category, subs, facts, seeds=None, since=None, answer=None, note=""):
        self.id = id
        self.category = category
        self.subs = subs
        self.facts = facts
        self.seeds = seeds
        self.since = since
        self.answer = answer
        self.note = note

    def cases(self, seed, src):
        if self.seeds is not None and seed not in self.seeds:
            return []
        new = src
        for pat, repl in self.subs:
            # A string replacement may use \1; L() gives a literal one.
            new, n = re.subn(pat, repl, new, flags=re.MULTILINE)
            if n == 0:
                return []
        if new == src:
            return []
        return [Case(self, seed, new, changed_lines(src, new), self.facts, self.answer)]


def R(id, subs, facts, seeds=None, since=None, answer=None, note=""):
    return Rule(id, "migration", subs, facts, seeds, since, answer, note)


# ---------------------------------------------------------------------------
# Older std APIs and builtins


def L(text):
    """A literal replacement, with no backslash escapes."""
    return lambda m: text


MAIN_INIT_IO = (
    r"pub fn main\(init: std\.process\.Init\) !void \{\n    const io = init\.io;\n",
    L("pub fn main() !void {\n"),
)
INIT_FACT = ["process.Init", "init.io"]

MIGRATIONS = [
    # Containers
    R(
        "arraylist-managed",
        [
            (r"var list: std\.ArrayList\((\w+)\) = \.empty;", r"var list = std.ArrayList(\1).init(gpa);"),
            (r"list\.(append|appendSlice)\(gpa, ", r"list.\1("),
            (r"list\.(deinit|toOwnedSlice)\(gpa\)", r"list.\1()"),
        ],
        [[".empty"], ["gpa", "allocator"]],
        seeds=["list"],
        since="0.15",
    ),
    R(
        "arraylist-append-noalloc",
        [(r"list\.append\(gpa, ", "list.append(")],
        [["gpa: Allocator"]],
        seeds=["list"],
        since="0.15",
    ),
    R(
        "arraylist-deinit-noalloc",
        [(r"list\.deinit\(gpa\)", "list.deinit()")],
        [["gpa: Allocator"]],
        seeds=["list"],
        since="0.15",
    ),
    R(
        "arraylist-unmanaged-name",
        [(r"std\.ArrayList\(u32\) = \.empty", "std.ArrayListUnmanaged(u32) = .{}")],
        [["ArrayList"]],
        seeds=["list"],
        since="0.15",
    ),
    R(
        "hashmap-managed",
        [
            (
                r"var counts: std\.StringHashMapUnmanaged\(u32\) = \.empty;",
                "var counts = std.StringHashMap(u32).init(gpa);",
            ),
            (r"counts\.(getOrPut)\(gpa, ", r"counts.\1("),
            (r"counts\.deinit\(gpa\)", "counts.deinit()"),
        ],
        [[".empty", "Unmanaged"]],
        seeds=["hashmap"],
        since="0.15",
    ),
    R(
        "array-hashmap-managed",
        [
            (
                r"var counts: std\.StringHashMapUnmanaged\(u32\) = \.empty;",
                "var counts = std.StringArrayHashMap(u32).init(gpa);",
            ),
            (r"counts\.(getOrPut)\(gpa, ", r"counts.\1("),
            (r"counts\.deinit\(gpa\)", "counts.deinit()"),
        ],
        [["StringArrayHashMapUnmanaged"]],
        seeds=["hashmap"],
        since="0.16",
    ),
    R(
        "bounded-array",
        [
            (
                r"var items = \[_\]u32\{ 1, 2, 3, 4 \};",
                "var items = try std.BoundedArray(u32, 4).fromSlice(&.{ 1, 2, 3, 4 });",
            ),
            (r"random\.shuffle\(u32, &items\);", "random.shuffle(u32, items.slice());"),
        ],
        [["initBuffer"]],
        seeds=["random"],
        since="0.15",
    ),
    # Readers and writers
    R(
        "stdout-getstdout",
        [
            MAIN_INIT_IO,
            (
                r"    var buffer: \[1024\]u8 = undefined;\n    var file_writer: std\.Io\.File\.Writer = \.init\(\.stdout\(\), io, &buffer\);\n    const out = &file_writer\.interface;",
                L("    const out = std.io.getStdOut().writer();"),
            ),
            (r"    try out\.flush\(\);\n", ""),
        ],
        [["Io.File"], ["stdout"], INIT_FACT],
        seeds=["stdout"],
        since="0.15",
    ),
    R(
        "stdout-fs-file",
        [
            MAIN_INIT_IO,
            (
                r"var file_writer: std\.Io\.File\.Writer = \.init\(\.stdout\(\), io, &buffer\);",
                "var file_writer = std.fs.File.stdout().writer(&buffer);",
            ),
        ],
        [["Io.File"], INIT_FACT],
        seeds=["stdout"],
        since="0.16",
    ),
    R(
        "stdout-writer-noio",
        [
            MAIN_INIT_IO,
            (
                r"var file_writer: std\.Io\.File\.Writer = \.init\(\.stdout\(\), io, &buffer\);",
                "var file_writer = std.Io.File.stdout().writer(&buffer);",
            ),
        ],
        [["io: Io", "init.io"]],
        seeds=["stdout"],
        since="0.16",
    ),
    R(
        "stdin-getstdin",
        [
            MAIN_INIT_IO,
            (
                r"    var file_reader: std\.Io\.File\.Reader = \.init\(\.stdin\(\), io, &buffer\);\n    const in = &file_reader\.interface;",
                L("    const in = std.io.getStdIn().reader();"),
            ),
            (
                r"while \(try in\.takeDelimiter\('\\n'\)\) \|line\|",
                L("while (try in.readUntilDelimiterOrEof(&buffer, '\\n')) |line|"),
            ),
        ],
        [["Io.File"], ["stdin", "reader"]],
        seeds=["stdin"],
        since="0.15",
    ),
    R(
        "fixed-buffer-stream",
        [
            (
                r"    var fixed: std\.Io\.Writer = \.fixed\(&buf\);",
                L("    var stream = std.io.fixedBufferStream(&buf);\n    var fixed = stream.writer();"),
            )
        ],
        [[".fixed"]],
        seeds=["writers"],
        since="0.15",
    ),
    R(
        "arraylist-writer",
        [
            (r"var aw: std\.Io\.Writer\.Allocating = \.init\(gpa\);", "var aw = std.ArrayList(u8).init(gpa);"),
            (r"&aw\.writer,", "aw.writer(),"),
        ],
        [["Allocating"]],
        seeds=["writers"],
        since="0.15",
    ),
    R(
        "any-writer",
        [(r"fn render\(w: \*std\.Io\.Writer,", "fn render(w: std.io.AnyWriter,")],
        [["Io.Writer"]],
        seeds=["writers"],
        since="0.15",
    ),
    R(
        "fs-cwd-old",
        [
            (r"    const io = init\.io;\n", ""),
            (r"std\.Io\.Dir\.cwd\(\)", "std.fs.cwd()"),
            (r"dir\.(writeFile|openFile|deleteFile)\(io, ", r"dir.\1("),
            (
                r"dir\.readFileAlloc\(io, \"eval-out\.txt\", gpa, \.limited\(1 << 20\)\)",
                L('dir.readFileAlloc(gpa, "eval-out.txt", 1 << 20)'),
            ),
            (r"file\.(close|stat)\(io\)", r"file.\1()"),
        ],
        [["Io.Dir"], INIT_FACT],
        seeds=["files"],
        since="0.16",
    ),
    R("fs-cwd", [(r"std\.Io\.Dir\.cwd\(\)", "std.fs.cwd()")], [["Io.Dir"]], seeds=["files"], since="0.16"),
    R(
        "file-close-noio",
        [(r"file\.close\(io\)", "file.close()")],
        [["io: Io", "init.io"]],
        seeds=["files"],
        since="0.16",
    ),
    R("file-stat-noio", [(r"file\.stat\(io\)", "file.stat()")], [["io: Io", "init.io"]], seeds=["files"], since="0.16"),
    R(
        "fs-file-type",
        [(r"const file = try dir\.openFile", "const file: std.fs.File = try dir.openFile")],
        [["Io.File"]],
        seeds=["files"],
        since="0.16",
    ),
    R(
        "readfilealloc-order",
        [
            (
                r"dir\.readFileAlloc\(io, \"eval-out\.txt\", gpa, \.limited\(1 << 20\)\)",
                L('dir.readFileAlloc(io, gpa, "eval-out.txt", 1 << 20)'),
            )
        ],
        [["sub_path", "[]const u8"]],
        seeds=["files"],
        since="0.15",
    ),
    # Process, time, threads
    R(
        "gpa-old",
        [
            (
                r"var debug_allocator: std\.heap\.DebugAllocator\(\.\{\}\) = \.init;",
                "var debug_allocator = std.heap.GeneralPurposeAllocator(.{}){};",
            )
        ],
        [["DebugAllocator"]],
        seeds=["alloc"],
        since="0.15",
    ),
    R(
        "args-alloc",
        [
            (
                r"const args = try init\.minimal\.args\.toSlice\(arena\);",
                "const args = try std.process.argsAlloc(arena);",
            )
        ],
        [["minimal.args"]],
        seeds=["args"],
        since="0.16",
    ),
    R("os-exit", [(r"std\.process\.exit\(", "std.os.exit(")], [["std.process.exit"]], seeds=["args"], since="0.12"),
    R(
        "time-sleep",
        [(r"try io\.sleep\(\.fromMilliseconds\(1\), \.awake\);", "std.time.sleep(1 * std.time.ns_per_ms);")],
        [["io.sleep", "Io.sleep"]],
        seeds=["sleep"],
        since="0.16",
    ),
    R(
        "thread-sleep",
        [(r"try io\.sleep\(\.fromMilliseconds\(1\), \.awake\);", "std.Thread.sleep(1 * std.time.ns_per_ms);")],
        [["io.sleep", "Io.sleep"]],
        seeds=["sleep"],
        since="0.16",
    ),
    R(
        "thread-mutex",
        [
            (
                r"var mutex: std\.Io\.Mutex = \.init;\n    try mutex\.lock\(io\);\n    mutex\.unlock\(io\);",
                L("var mutex: std.Thread.Mutex = .{};\n    mutex.lock();\n    mutex.unlock();"),
            )
        ],
        [["Io.Mutex"]],
        seeds=["sleep"],
        since="0.16",
    ),
    R(
        "rand",
        [(r"std\.Random\.DefaultPrng", "std.rand.DefaultPrng")],
        [["std.Random"]],
        seeds=["random"],
        since="0.12",
    ),
    R(
        "timestamp",
        [(r"const wall = std\.Io\.Clock\.now\(\.real, io\)\.toSeconds\(\);", "const wall = std.time.timestamp();")],
        [["Clock.now", "Io.Clock", "Timestamp"]],
        seeds=["clock"],
        since="0.16",
    ),
    R(
        "milli-timestamp",
        [
            (
                r"const wall = std\.Io\.Clock\.now\(\.real, io\)\.toSeconds\(\);",
                "const wall = std.time.milliTimestamp();",
            )
        ],
        [["Clock.now", "Io.Clock", "Timestamp"]],
        seeds=["clock"],
        since="0.16",
    ),
    R(
        "timer",
        [
            (r"const start = std\.Io\.Clock\.now\(\.awake, io\);", "var start = try std.time.Timer.start();"),
            (
                r"const elapsed = start\.durationTo\(std\.Io\.Clock\.now\(\.awake, io\)\);",
                "const elapsed = start.read();",
            ),
            (r"elapsed\.toNanoseconds\(\)", "elapsed"),
        ],
        [["Clock", "Timestamp"]],
        seeds=["clock"],
        since="0.16",
    ),
    R(
        "crypto-random",
        [(r"io\.random\(&seed_bytes\);", "std.crypto.random.bytes(&seed_bytes);")],
        [["io.random"]],
        seeds=["clock"],
        since="0.16",
    ),
    R(
        "getenv",
        [
            (r"pub fn main\(init: std\.process\.Init\) !void", "pub fn main() !void"),
            (r'init\.environ_map\.get\("HOME"\)', L('std.posix.getenv("HOME")')),
        ],
        [["environ_map", "Environ"]],
        seeds=["misc"],
        since="0.16",
    ),
    R(
        "os-getenv",
        [
            (r"pub fn main\(init: std\.process\.Init\) !void", "pub fn main() !void"),
            (r'init\.environ_map\.get\("HOME"\)', L('std.os.getenv("HOME")')),
        ],
        [["environ_map", "Environ"]],
        seeds=["misc"],
        since="0.12",
    ),
    # std.mem, std.fmt, std.json, std.math
    R(
        "mem-tokenize",
        [(r"std\.mem\.tokenizeScalar\(u8, trimmed, ' '\)", L('std.mem.tokenize(u8, trimmed, " ")'))],
        [["tokenizeScalar", "tokenizeAny", "tokenizeSequence"]],
        seeds=["strings"],
        since="0.12",
    ),
    R(
        "mem-split",
        [(r"std\.mem\.splitScalar\(u8, w, ','\)", L('std.mem.split(u8, w, ",")'))],
        [["splitScalar", "splitSequence", "splitAny"]],
        seeds=["strings"],
        since="0.12",
    ),
    R(
        "mem-trimright",
        [(r"std\.mem\.trimEnd\(", "std.mem.trimRight(")],
        [["trimEnd"]],
        seeds=["strings"],
        since="0.16",
    ),
    R("mem-indexof", [(r"std\.mem\.find\(", "std.mem.indexOf(")], [["find"]], seeds=["strings"], since="0.17"),
    R(
        "mem-copy",
        [(r"@memcpy\(page, buf\[0\.\.8\]\);", "std.mem.copy(u8, page, buf[0..8]);")],
        [["@memcpy"]],
        seeds=["alloc"],
        since="0.12",
    ),
    R(
        "mem-set",
        [(r"@memset\(buf, 'z'\);", "std.mem.set(u8, buf, 'z');")],
        [["@memset"]],
        seeds=["alloc"],
        since="0.12",
    ),
    R(
        "readint-little",
        [(r"std\.mem\.readInt\(u64, &seed_bytes, \.little\)", "std.mem.readIntLittle(u64, &seed_bytes)")],
        [["readInt"]],
        seeds=["clock"],
        since="0.12",
    ),
    R(
        "page-size",
        [(r"std\.heap\.pageSize\(\)", "std.mem.page_size")],
        [["pageSize", "page_size_min"]],
        seeds=["misc"],
        since="0.14",
    ),
    R(
        "sort-sort",
        [(r"std\.mem\.sort\(i32, &nums", "std.sort.sort(i32, &nums")],
        [["std.mem.sort"]],
        seeds=["sort"],
        since="0.11",
    ),
    R(
        "json-stringify-alloc",
        [(r"std\.json\.Stringify\.valueAlloc\(", "std.json.stringifyAlloc(")],
        [["Stringify.valueAlloc"]],
        seeds=["json"],
        since="0.15",
    ),
    R(
        "debug-warn",
        [(r'std\.debug\.print\("\{d\} \{s\}', L('std.debug.warn("{d} {s}'))],
        [["std.debug.print"]],
        seeds=["json"],
        since="0.9",
    ),
    R(
        "math-absint",
        [(r"const magnitude = @abs\(x\);", "const magnitude = try std.math.absInt(x);")],
        [["@abs"]],
        seeds=["misc"],
        since="0.12",
    ),
    R(
        "meta-int",
        [(r"return @Int\(\.unsigned, bits\);", "return std.meta.Int(.unsigned, bits);")],
        [["@Int"]],
        seeds=["misc"],
        since="0.17",
    ),
    # build.zig (std.Build), configured through `bs build`
    R(
        "build-exe-root-source",
        [
            (
                r'b\.addExecutable\(\.\{ \.name = "app", \.root_module = mod \}\)',
                L(
                    'b.addExecutable(.{ .name = "app", .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize })'
                ),
            )
        ],
        [["root_module"], ["createModule"]],
        seeds=["build_exe"],
        since="0.15",
    ),
    R(
        "build-test-root-source",
        [
            (
                r"b\.addTest\(\.\{ \.root_module = mod \}\)",
                L('b.addTest(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize })'),
            )
        ],
        [["root_module"], ["createModule"]],
        seeds=["build_exe"],
        since="0.15",
    ),
    R(
        "build-link-libc",
        [(r"exe\.root_module\.link_libc = true;", "exe.linkLibC();")],
        [["link_libc"]],
        seeds=["build_exe"],
        since="0.15",
    ),
    R(
        "build-args",
        [(r"run_cmd\.addPassthruArgs\(\);", "if (b.args) |args| run_cmd.addArgs(args);")],
        [["addPassthruArgs"]],
        seeds=["build_exe"],
        since="0.17",
    ),
    R(
        "build-install-old",
        [(r"b\.installArtifact\(exe\);", "exe.install();")],
        [["installArtifact"]],
        seeds=["build_exe"],
        since="0.11",
    ),
    R(
        "build-run-old",
        [(r"const run_cmd = b\.addRunArtifact\(exe\);", "const run_cmd = exe.run();")],
        [["addRunArtifact"]],
        seeds=["build_exe"],
        since="0.11",
    ),
    R(
        "build-release-options",
        [(r"b\.standardOptimizeOption\(\.\{\}\)", "b.standardReleaseOptions()")],
        [["standardOptimizeOption"]],
        seeds=["build_exe"],
        since="0.11",
    ),
    R(
        "build-builder",
        [(r"b: \*std\.Build\)", "b: *std.build.Builder)")],
        [["std.Build"]],
        seeds=["build_exe"],
        since="0.11",
    ),
    R(
        "build-static-lib",
        [
            (
                r'b\.addLibrary\(\.\{\n        \.linkage = \.static,\n        \.name = "core",\n        \.root_module = b\.createModule\(\.\{\n            \.root_source_file = b\.path\("src/main\.zig"\),\n            \.target = target,\n            \.optimize = optimize,\n        \}\),\n    \}\)',
                L(
                    'b.addStaticLibrary(.{\n        .name = "core",\n        .root_source_file = b.path("src/main.zig"),\n        .target = target,\n        .optimize = optimize,\n    })'
                ),
            )
        ],
        [["addLibrary"]],
        seeds=["build_lib"],
        since="0.15",
    ),
    R(
        "build-add-module-old",
        [(r'lib\.root_module\.addImport\("util", util\);', 'lib.addModule("util", util);')],
        [["addImport"]],
        seeds=["build_lib"],
        since="0.12",
    ),
    R(
        "build-include-path-old",
        [(r"lib\.root_module\.addIncludePath\(", "lib.addIncludePath(")],
        [["root_module.addIncludePath"]],
        seeds=["build_lib"],
        since="0.15",
    ),
    R(
        "build-options-old",
        [(r'lib\.root_module\.addOptions\("build_options", options\);', 'lib.addOptions("build_options", options);')],
        [["root_module.addOptions"]],
        seeds=["build_lib"],
        since="0.15",
    ),
    R(
        "build-module-source-file",
        [
            (
                r'(b\.addModule\("util", \.\{\n        )\.root_source_file = b\.path\("src/main\.zig"\)',
                r'\1.source_file = .{ .path = "src/main.zig" }',
            )
        ],
        [["root_source_file"]],
        seeds=["build_lib"],
        since="0.12",
    ),
    R(
        "build-lazypath-path",
        [
            (
                r'(b\.addModule\("util", \.\{\n        \.root_source_file = )b\.path\("src/main\.zig"\)',
                r'\1.{ .path = "src/main.zig" }',
            )
        ],
        [["b.path"]],
        seeds=["build_lib"],
        since="0.13",
    ),
    # Builtins and language
    R(
        "typeinfo-struct-case",
        [(r'@typeInfo\(T\)\.@"struct"', "@typeInfo(T).Struct")],
        [['@"struct"']],
        seeds=["typeinfo"],
        since="0.14",
    ),
    R(
        "typeinfo-int-case",
        [(r"\.int, \.comptime_int => true", ".Int, .ComptimeInt => true")],
        [[".int"]],
        seeds=["typeinfo"],
        since="0.14",
    ),
    R(
        "typeinfo-fields",
        [
            (r'@typeInfo\(Config\)\.@"struct"\.field_names\) \|name\|', '@typeInfo(Config).@"struct".fields) |field|'),
            (r"\.\{name\}\);", ".{field.name});"),
        ],
        [["field_names"]],
        seeds=["typeinfo"],
        since="0.17",
    ),
    R(
        "typeinfo-fields-len",
        [(r'@typeInfo\(T\)\.@"struct"\.field_names\.len', '@typeInfo(T).@"struct".fields.len')],
        [["field_names"]],
        seeds=["typeinfo"],
        since="0.17",
    ),
    R(
        "type-builtin",
        [
            (
                r"const bits: u32 = @bitCast",
                "const bits: @Type(.{ .int = .{ .signedness = .unsigned, .bits = 32 } }) = @bitCast",
            )
        ],
        [["@Int"]],
        seeds=["casts"],
        since="0.17",
    ),
    R(
        "intToEnum",
        [(r"const c: Color = @enumFromInt\(raw\);", "const c = @intToEnum(Color, raw);")],
        [["@enumFromInt"]],
        seeds=["enums"],
        since="0.11",
    ),
    R(
        "enumToInt",
        [(r"const back: u8 = @intFromEnum\(c\);", "const back: u8 = @enumToInt(c);")],
        [["@intFromEnum"]],
        seeds=["enums"],
        since="0.11",
    ),
    R(
        "intToFloat",
        [(r"const count: f64 = @floatFromInt\(values\.len\);", "const count = @intToFloat(f64, values.len);")],
        [["@floatFromInt"]],
        seeds=["casts"],
        since="0.11",
    ),
    R(
        "floatToInt",
        [(r"const rounded: i32 = @intFromFloat\(", "const rounded = @floatToInt(i32, ")],
        [["@intFromFloat"]],
        seeds=["casts"],
        since="0.11",
    ),
    R(
        "intCast-2arg",
        [(r"const narrow: u16 = @intCast\(idx\);", "const narrow = @intCast(u16, idx);")],
        [["@as(u16, @intCast(", "result type"]],
        seeds=["casts"],
        since="0.11",
    ),
    R(
        "truncate-2arg",
        [(r"const small: u8 = @truncate\(big\);", "const small = @truncate(u8, big);")],
        [["@as(u8, @truncate(", "result type"]],
        seeds=["casts"],
        since="0.11",
    ),
    R(
        "bitCast-2arg",
        [(r"const bits: u32 = @bitCast\(@as\(f32, 1\.0\)\);", "const bits = @bitCast(u32, @as(f32, 1.0));")],
        [["@as(u32, @bitCast(", "result type"]],
        seeds=["casts"],
        since="0.11",
    ),
    R(
        "callconv-C",
        [(r"callconv\(\.c\)", "callconv(.C)")],
        [[".c", "candidates: c"]],
        seeds=["cabi"],
        since="0.14",
        answer="c",
    ),
    R("setCold", [(r"@branchHint\(\.cold\);", "@setCold(true);")], [["@branchHint"]], seeds=["cabi"], since="0.14"),
    R(
        "cImport",
        [
            (
                r"(const Pair = extern struct)",
                L('const c = @cImport(@cInclude("stdlib.h"));\n\nconst Pair = extern struct'),
            ),
            (
                r'std\.debug\.print\("\{d\}\\n", \.\{addPair\(&p\)\}\);',
                L('std.debug.print("{d}\\n", .{c.abs(addPair(&p))});'),
            ),
        ],
        [["addTranslateC", "translate"]],
        seeds=["cabi"],
        since="0.17",
    ),
    R(
        "usingnamespace",
        [
            (r'^const std = @import\("std"\);', L('const std = @import("std");\nusingnamespace std.debug;')),
            (r'    std\.debug\.print\("\{d\} \{d\}', L('    print("{d} {d}')),
        ],
        [["usingnamespace"]],
        seeds=["generic"],
        since="0.15",
    ),
    R(
        "for-counter-old",
        [(r"for \(args, 0\.\.\) \|arg, i\|", "for (args) |arg, i|")],
        [["0.."]],
        seeds=["args"],
        since="0.11",
    ),
    R("async-call", [(r"stack\.push\(3\);", "_ = async stack.push(3);")], [["async"]], seeds=["generic"], since="0.12"),
]


# ---------------------------------------------------------------------------
# Mistakes that do not depend on the release


def typo(name, k=0):
    """A deterministic misspelling of `name`: dropped, swapped or doubled
    letters, picked by `k`."""
    if len(name) < 4:
        return None
    i = 1 + (len(name) // 2 + k) % (len(name) - 2)
    kind = k % 3
    if kind == 0:
        return name[:i] + name[i + 1 :]
    if kind == 1:
        if name[i] == name[i + 1]:
            return name[:i] + name[i] + name[i:]
        return name[:i] + name[i + 1] + name[i] + name[i + 2 :]
    return name[:i] + name[i] + name[i:]


def at_line(src, pos):
    return src.count("\n", 0, pos) + 1


class Generic:
    def __init__(self, id, category, facts_of, find, mutate, answer_of=None, limit=3):
        self.id = id
        self.category = category
        self.since = None
        self.facts_of = facts_of
        self.find = find
        self.mutate = mutate
        self.answer_of = answer_of
        self.limit = limit
        self.seeds = None
        self.note = ""

    def cases(self, seed, src):
        out = []
        seen = set()
        for m in self.find(src):
            key = m.group(0)
            if key in seen:
                continue
            seen.add(key)
            new = self.mutate(src, m, len(out))
            if new is None or new == src:
                continue
            c = Case(
                self,
                seed,
                new,
                changed_lines(src, new),
                self.facts_of(m),
                self.answer_of(m) if self.answer_of else None,
                variant=str(len(out)),
            )
            out.append(c)
            if len(out) >= self.limit:
                break
        return out


def _replace(src, start, end, text):
    return src[:start] + text + src[end:]


def _typo_at(group):
    def mutate(src, m, k):
        t = typo(m.group(group), k)
        return None if t is None else _replace(src, m.start(group), m.end(group), t)

    return mutate


DECLARED_FNS = re.compile(r"^\s*(?:pub )?fn (\w+)\(", re.MULTILINE)


def _local_calls(src):
    names = set(DECLARED_FNS.findall(src)) - {"main"}
    for m in re.finditer(r"(?<![\w.])(\w+)\(", src):
        if m.group(1) in names and not src[max(0, m.start() - 3) : m.start()].endswith("fn "):
            yield m


GENERIC = [
    # `std.mem.tokenizeScalar` -> `std.mem.tokenizeSclar`
    Generic(
        "typo-std",
        "typo",
        lambda m: [[m.group(2)]],
        lambda src: re.finditer(r"std\.((?:\w+\.)*)(\w{4,})\b", src),
        _typo_at(2),
        lambda m: m.group(2),
    ),
    Generic("typo-local-fn", "typo", lambda m: [[m.group(1)]], _local_calls, _typo_at(1), lambda m: m.group(1)),
    Generic(
        "typo-field",
        "typo",
        lambda m: [[m.group(2)]],
        lambda src: re.finditer(r"\b(p|c|kv|entry|s|self|stat|parsed|r)\.(\w{3,})\b", src),
        _typo_at(2),
        lambda m: m.group(2),
    ),
    Generic(
        "missing-try",
        "error-union",
        lambda m: [["'try'", "`try`"]],
        lambda src: re.finditer(r"(?<=[=(] )try |^(\s+)try ", src, re.MULTILINE),
        lambda src, m, k: _replace(src, m.start(), m.end(), m.group(1) or ""),
    ),
    # `fn parse(s: []const u8) !u32 {` -> `... u32 {`: try or an error
    # return in a function that cannot return errors.
    Generic(
        "missing-bang",
        "error-union",
        lambda m: [["!" + m.group(1)]],
        lambda src: re.finditer(r"^\s*(?:pub )?fn \w+\([^()]*\) !([\w.]+) \{", src, re.MULTILINE),
        lambda src, m, k: _replace(src, m.start(1) - 1, m.start(1), ""),
    ),
    # `parse(s) catch 0` -> `parse(s) orelse 0`
    Generic(
        "orelse-error",
        "error-union",
        lambda m: [["'catch'", '"catch"']],
        lambda src: re.finditer(r"[\w)\]]+ catch (?!\|)[^;\n,]*", src),
        lambda src, m, k: _replace(src, m.start(), m.end(), m.group(0).replace(" catch ", " orelse ", 1)),
    ),
    # `map.get(k) orelse 0` -> `map.get(k) catch 0`
    Generic(
        "catch-optional",
        "optional",
        lambda m: [["orelse"]],
        lambda src: re.finditer(r"[\w)\]]+ orelse [^;\n,]*", src),
        lambda src, m, k: _replace(src, m.start(), m.end(), m.group(0).replace(" orelse ", " catch ", 1)),
    ),
    # `const n = std.mem.trim(...)` -> `const n = try std.mem.trim(...)`
    Generic(
        "extra-try",
        "error-union",
        lambda m: [["omitting 'try'", "remove 'try'"]],
        lambda src: re.finditer(r"(?<== )std\.(?:mem|ascii|math)\.\w+\(", src),
        lambda src, m, k: _replace(src, m.start(), m.start(), "try "),
    ),
    Generic(
        "missing-unwrap",
        "optional",
        lambda m: [[".?", "orelse"]],
        lambda src: re.finditer(r"(\))\.\?", src),
        lambda src, m, k: _replace(src, m.start() + 1, m.end(), ""),
    ),
    Generic(
        "var-to-const",
        "mutability",
        lambda m: [["'var'", "`var`"]],
        lambda src: re.finditer(r"^(\s+)var (\w+)(?=[: ])", src, re.MULTILINE),
        lambda src, m, k: (
            _replace(src, m.start(), m.end(), f"{m.group(1)}const {m.group(2)}")
            if re.search(rf"\b{m.group(2)}\s*(\+=|-=|=[^=]|\.\w+\(|\[)", src[m.end() :])
            else None
        ),
    ),
    Generic(
        "missing-cast",
        "cast",
        lambda m: [[m.group(1)]],
        lambda src: re.finditer(r"(@intCast|@truncate|@floatFromInt|@intFromFloat)\(([\w.]+)\)", src),
        lambda src, m, k: _replace(src, m.start(), m.end(), m.group(2)),
    ),
]

RULES = MIGRATIONS + GENERIC
