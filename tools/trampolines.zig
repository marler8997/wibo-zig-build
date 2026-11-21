//! trampolines DLL ARCH OS AST_JSON AST_TEXT LAYOUTS OUT_ASM OUT_HDR
//!
//! wibo's tools/gen_trampolines.py, in Zig, and with clang's dumps instead of libclang: the
//! thunks between Windows code (the guest) and wibo's implementation of DLL (the host), for
//! every function in namespace DLL annotated with its guest calling convention, and for every
//! annotated function pointer typedef. Same output, byte for byte.
//!
//! From clang -cc1 on the module's preprocessed headers: AST_JSON (-ast-dump=json: the
//! declarations, types and mangled names), AST_TEXT (-ast-dump: annotation strings, which the
//! JSON leaves out) and LAYOUTS (-fdump-record-layouts-complete: sizes of records passed by
//! value). ARCH is x86 or x86_64, OS linux or macos.

const usage = "usage: trampolines DLL ARCH OS AST_JSON AST_TEXT LAYOUTS OUT_ASM OUT_HDR\n";

pub fn main(init: std.process.Init.Minimal) !void {
    // a short-lived process: nothing is freed before it exits
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var args = init.args.iterateAllocator(arena) catch oom();
    _ = args.skip();
    var argv: [8][]const u8 = undefined;
    for (&argv) |*a| a.* = args.next() orelse fatal(usage, .{});
    if (args.next() != null) fatal(usage, .{});
    const dll, const arch_arg, const os_arg, const json_path, const text_path, const layouts_path, const asm_path, const hdr_path = argv;

    var g: Gen = .{
        .arena = arena,
        .arch = std.meta.stringToEnum(Arch, arch_arg) orelse fatal("ARCH must be x86 or x86_64, not '{s}'", .{arch_arg}),
        .darwin = if (std.mem.eql(u8, os_arg, "macos")) true else if (std.mem.eql(u8, os_arg, "linux")) false else fatal("OS must be linux or macos, not '{s}'", .{os_arg}),
    };
    const cwd = std.Io.Dir.cwd();
    const json_bytes = cwd.readFileAlloc(io, json_path, arena, .unlimited) catch |e| fatal("reading {s}: {t}", .{ json_path, e });
    const text = cwd.readFileAlloc(io, text_path, arena, .unlimited) catch |e| fatal("reading {s}: {t}", .{ text_path, e });
    const layouts = cwd.readFileAlloc(io, layouts_path, arena, .unlimited) catch |e| fatal("reading {s}: {t}", .{ layouts_path, e });

    var tu = std.json.parseFromSliceLeaky(std.json.Value, arena, json_bytes, .{}) catch |e| fatal("{s}: not JSON: {t}", .{ json_path, e });
    g.attachAnnotations(&tu, text, text_path);
    g.readLayouts(layouts);
    g.indexTypes(tu);

    const funcs = g.collectFunctions(tu, dll);
    const typedefs = g.collectTypedefs(tu);
    const variables = g.collectVariables(tu, dll);
    if (funcs.len == 0 and typedefs.len == 0 and variables.len == 0)
        fatal("No functions, typedefs, or variables found for generation.", .{});

    var asm_out: std.Io.Writer.Allocating = .init(arena);
    g.emitAsm(&asm_out.writer, dll, funcs, typedefs) catch oom();
    var hdr_out: std.Io.Writer.Allocating = .init(arena);
    g.emitHeader(&hdr_out.writer, dll, funcs, typedefs, variables) catch oom();
    cwd.writeFile(io, .{ .sub_path = asm_path, .data = asm_out.written() }) catch |e| fatal("writing {s}: {t}", .{ asm_path, e });
    cwd.writeFile(io, .{ .sub_path = hdr_path, .data = hdr_out.written() }) catch |e| fatal("writing {s}: {t}", .{ hdr_path, e });
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

fn oom() noreturn {
    @panic("out of memory");
}

const Arch = enum { x86, x86_64 };

/// libclang's CXCallingConv names, as the output spells them.
const CallingConv = enum { DEFAULT, C, X86_STDCALL, X86_FASTCALL };

/// A type, canonical: what libclang's get_canonical() gives.
const Type = struct {
    kind: enum { builtin, pointer, reference, record, @"enum", function },
    is_const: bool = false,
    is_volatile: bool = false,
    /// a builtin's spelling ("unsigned int"), a record's name
    name: []const u8 = "",
    /// what a pointer or reference refers to
    child: ?*const Type = null,
};

const ArgInfo = struct {
    canon: *const Type,
    sign_extended: bool,
    /// the type as written: libclang's spelling of it
    spelling: []const u8,
};

const FuncInfo = struct {
    qualified_ns: []const u8,
    name: []const u8,
    mangled: []const u8,
    source_cc: CallingConv,
    target_cc: CallingConv,
    variadic: bool,
    ret: ArgInfo,
    args: []const ArgInfo,
    /// a function pointer typedef's thunk (host to guest), or a function's (guest to host)
    host_to_guest: bool,
};

const VarInfo = struct { qualified_ns: []const u8, name: []const u8 };

const Value = std.json.Value;

const Gen = struct {
    arena: std.mem.Allocator,
    arch: Arch,
    darwin: bool,
    /// typedef and using declarations, by name: the type they name
    typedefs: std.StringHashMapUnmanaged(Value) = .empty,
    /// struct, union, class and enum names (for types written without a typedef)
    tags: std.StringHashMapUnmanaged(enum { record, @"enum" }) = .empty,
    /// sizeof each record clang laid out, by name
    record_sizes: std.StringHashMapUnmanaged(u32) = .empty,

    // ---- reading clang's dumps ----

    /// The JSON's AnnotateAttr nodes don't have their string; the text dump, made from the same
    /// AST in the same order, does: the k-th in one is the k-th in the other.
    fn attachAnnotations(g: *Gen, tu: *Value, text: []const u8, text_path: []const u8) void {
        var strings: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |ln| {
            if (std.mem.indexOf(u8, ln, "AnnotateAttr 0x") == null) continue;
            const first = std.mem.indexOfScalar(u8, ln, '"') orelse fatal("{s}: an AnnotateAttr without a string: {s}", .{ text_path, ln });
            const last = std.mem.lastIndexOfScalar(u8, ln, '"').?;
            if (last <= first) fatal("{s}: an AnnotateAttr without a string: {s}", .{ text_path, ln });
            strings.append(g.arena, ln[first + 1 .. last]) catch oom();
        }
        var next: usize = 0;
        g.annotate(tu, strings.items, &next);
        if (next != strings.items.len) fatal("the JSON has {} annotations, the text dump {}", .{ next, strings.items.len });
    }

    fn annotate(g: *Gen, node: *Value, strings: []const []const u8, next: *usize) void {
        if (node.* != .object) return;
        if (str(node.*, "kind")) |k| if (std.mem.eql(u8, k, "AnnotateAttr")) {
            if (next.* >= strings.len) fatal("the JSON has more annotations than the text dump", .{});
            node.object.put(g.arena, "value", .{ .string = strings[next.*] }) catch oom();
            next.* += 1;
        };
        if (node.object.getPtr("inner")) |children| if (children.* == .array) {
            for (children.array.items) |*c| g.annotate(c, strings, next);
        };
    }

    /// -fdump-record-layouts-complete: "*** Dumping AST Record Layout", "0 | struct NAME", ...,
    /// "| [sizeof=N, ...".
    fn readLayouts(g: *Gen, layouts: []const u8) void {
        var lines = std.mem.splitScalar(u8, layouts, '\n');
        var name: ?[]const u8 = null;
        while (lines.next()) |ln| {
            if (std.mem.indexOf(u8, ln, "*** Dumping AST Record Layout") != null) {
                name = null;
                const first = lines.next() orelse break;
                const bar = std.mem.indexOf(u8, first, "| ") orelse continue;
                var n = std.mem.trim(u8, first[bar + 2 ..], " \r");
                for ([_][]const u8{ "struct ", "union ", "class " }) |kw| {
                    if (std.mem.startsWith(u8, n, kw)) n = n[kw.len..];
                }
                name = n;
                continue;
            }
            const at = std.mem.indexOf(u8, ln, "[sizeof=") orelse continue;
            const n = name orelse continue;
            const rest = ln[at + "[sizeof=".len ..];
            const end = std.mem.indexOfAny(u8, rest, ",]") orelse continue;
            const sz = std.fmt.parseInt(u32, rest[0..end], 10) catch fatal("a record layout's sz isn't a number: {s}", .{ln});
            g.record_sizes.put(g.arena, n, sz) catch oom();
            name = null;
        }
    }

    /// Every typedef, using, struct, union, class and enum name, at namespace scope.
    fn indexTypes(g: *Gen, node: Value) void {
        for (inner(node)) |c| {
            const k = str(c, "kind") orelse continue;
            if (eql(k, "NamespaceDecl") or eql(k, "LinkageSpecDecl")) {
                g.indexTypes(c);
            } else if (eql(k, "TypedefDecl") or eql(k, "TypeAliasDecl")) {
                const n = str(c, "name") orelse continue;
                const ty = inner(c);
                if (ty.len == 0) continue;
                g.typedefs.put(g.arena, n, ty[0]) catch oom();
            } else if (eql(k, "CXXRecordDecl") or eql(k, "RecordDecl") or eql(k, "ClassTemplateDecl")) {
                if (str(c, "name")) |n| g.tags.put(g.arena, n, .record) catch oom();
            } else if (eql(k, "EnumDecl")) {
                if (str(c, "name")) |n| g.tags.put(g.arena, n, .@"enum") catch oom();
            }
        }
    }

    // ---- types ----

    /// A JSON type node, made canonical.
    fn canon(g: *Gen, node: Value) *const Type {
        const k = str(node, "kind") orelse fatal("a type node without a kind", .{});
        if (eql(k, "BuiltinType")) return g.new(.{ .kind = .builtin, .name = qualType(node) });
        if (eql(k, "PointerType")) return g.new(.{ .kind = .pointer, .child = g.canon(only(node)) });
        if (eql(k, "LValueReferenceType") or eql(k, "RValueReferenceType")) return g.new(.{ .kind = .reference, .child = g.canon(only(node)) });
        if (eql(k, "TypedefType") or eql(k, "UsingType")) {
            if (inner(node).len > 0) return g.canon(inner(node)[0]);
            const decl = get(node, "decl") orelse fatal("a {s} without its declaration", .{k});
            return g.canonName(str(decl, "name") orelse fatal("a {s} without a name", .{k}));
        }
        if (eql(k, "ElaboratedType") or eql(k, "ParenType") or eql(k, "AttributedType") or eql(k, "MacroQualifiedType") or eql(k, "SubstTemplateTypeParmType"))
            return g.canon(inner(node)[0]);
        if (eql(k, "QualType")) {
            const q = str(node, "qualifiers") orelse "";
            const t = g.canon(only(node));
            return g.qualified(t, std.mem.indexOf(u8, q, "const") != null, std.mem.indexOf(u8, q, "volatile") != null);
        }
        if (eql(k, "RecordType") or eql(k, "InjectedClassNameType")) {
            const decl = get(node, "decl") orelse fatal("a {s} without its declaration", .{k});
            return g.new(.{ .kind = .record, .name = str(decl, "name") orelse "" });
        }
        if (eql(k, "TemplateSpecializationType")) return g.new(.{ .kind = .record, .name = qualType(node) });
        if (eql(k, "EnumType")) return g.new(.{ .kind = .@"enum" });
        if (eql(k, "FunctionProtoType") or eql(k, "FunctionNoProtoType")) return g.new(.{ .kind = .function });
        fatal("unsupported type node {s} ({s})", .{ k, qualType(node) });
    }

    /// A type written as a name: a typedef's, or a tag's (struct X, guest_ptr<>).
    fn canonName(g: *Gen, name: []const u8) *const Type {
        if (g.typedefs.get(name)) |t| return g.canon(t);
        if (std.mem.indexOfScalar(u8, name, '<') != null) return g.new(.{ .kind = .record, .name = name });
        if (g.tags.get(name)) |tag| return switch (tag) {
            .record => g.new(.{ .kind = .record, .name = name }),
            .@"enum" => g.new(.{ .kind = .@"enum" }),
        };
        fatal("unknown type name '{s}'", .{name});
    }

    fn new(g: *Gen, t: Type) *const Type {
        const p = g.arena.create(Type) catch oom();
        p.* = t;
        return p;
    }

    fn qualified(g: *Gen, t: *const Type, c: bool, v: bool) *const Type {
        if (!c and !v) return t;
        var q = t.*;
        q.is_const = q.is_const or c;
        q.is_volatile = q.is_volatile or v;
        return g.new(q);
    }

    /// A type as clang prints it ("const LPSTR *", "guest_ptr<> *", "unsigned int"): what a
    /// parameter's or a return type's JSON gives, which has no type tree. Its canonical type,
    /// and whether libclang would call it a HANDLE-like typedef.
    const Written = struct { canon: *const Type, handle: bool };

    fn parseWritten(g: *Gen, spelling: []const u8) Written {
        var toks: std.ArrayList([]const u8) = .empty;
        {
            var i: usize = 0;
            while (i < spelling.len) {
                const c = spelling[i];
                if (c == ' ') {
                    i += 1;
                } else if (c == '*' or c == '&') {
                    toks.append(g.arena, spelling[i .. i + 1]) catch oom();
                    i += 1;
                } else if (std.ascii.isAlphanumeric(c) or c == '_' or c == ':') {
                    const start = i;
                    while (i < spelling.len and (std.ascii.isAlphanumeric(spelling[i]) or spelling[i] == '_' or spelling[i] == ':')) i += 1;
                    // a template's arguments are part of its name
                    if (i < spelling.len and spelling[i] == '<') {
                        var depth: usize = 0;
                        while (i < spelling.len) : (i += 1) {
                            if (spelling[i] == '<') depth += 1;
                            if (spelling[i] == '>') {
                                depth -= 1;
                                if (depth == 0) {
                                    i += 1;
                                    break;
                                }
                            }
                        }
                    }
                    toks.append(g.arena, spelling[start..i]) catch oom();
                } else fatal("can't parse the type '{s}'", .{spelling});
            }
        }
        var is_const = false;
        var is_volatile = false;
        var builtin: std.ArrayList(u8) = .empty;
        var name: ?[]const u8 = null;
        var i: usize = 0;
        while (i < toks.items.len and !eql(toks.items[i], "*") and !eql(toks.items[i], "&")) : (i += 1) {
            const t = toks.items[i];
            if (eql(t, "const")) {
                is_const = true;
            } else if (eql(t, "volatile")) {
                is_volatile = true;
            } else if (eql(t, "struct") or eql(t, "union") or eql(t, "class") or eql(t, "enum")) {
                // the tag's name follows
            } else if (isBuiltinWord(t)) {
                if (builtin.items.len > 0) builtin.append(g.arena, ' ') catch oom();
                builtin.appendSlice(g.arena, t) catch oom();
            } else {
                if (name != null) fatal("can't parse the type '{s}'", .{spelling});
                name = t;
            }
        }
        if ((name == null) == (builtin.items.len == 0)) fatal("can't parse the type '{s}'", .{spelling});
        var t = if (name) |n| g.canonName(n) else g.new(.{ .kind = .builtin, .name = builtin.items });
        t = g.qualified(t, is_const, is_volatile);
        const declarators = toks.items[i..];
        var j: usize = 0;
        while (j < declarators.len) {
            if (eql(declarators[j], "*")) {
                t = g.new(.{ .kind = .pointer, .child = t });
                j += 1;
                var pc = false;
                var pv = false;
                while (j < declarators.len and (eql(declarators[j], "const") or eql(declarators[j], "volatile"))) : (j += 1) {
                    if (eql(declarators[j], "const")) pc = true else pv = true;
                }
                t = g.qualified(t, pc, pv);
            } else if (eql(declarators[j], "&") and j == declarators.len - 1) {
                t = g.new(.{ .kind = .reference, .child = t });
                j += 1;
            } else fatal("can't parse the type '{s}'", .{spelling});
        }
        // a typedef (qualified or not, as libclang ignores qualifiers for a type's kind)
        const handle = declarators.len == 0 and name != null and g.typedefs.contains(name.?) and
            (isHandleName(name.?) or g.handleChain(g.typedefs.get(name.?).?));
        return .{ .canon = t, .handle = handle };
    }

    /// gen_trampolines.py's _is_handle_typedef: a typedef named like HANDLE, HWND, ...,
    /// anywhere along a chain of typedefs.
    fn handleChain(g: *Gen, start: Value) bool {
        var node = start;
        while (true) {
            const k = str(node, "kind") orelse return false;
            if (eql(k, "TypedefType")) {
                const decl = get(node, "decl") orelse return false;
                const n = str(decl, "name") orelse return false;
                if (isHandleName(n)) return true;
                node = if (inner(node).len > 0) inner(node)[0] else g.typedefs.get(n) orelse return false;
            } else if (eql(k, "ElaboratedType") or eql(k, "QualType") or eql(k, "ParenType") or eql(k, "AttributedType")) {
                if (inner(node).len == 0) return false;
                node = inner(node)[0];
            } else return false;
        }
    }

    fn argFromWritten(g: *Gen, spelling: []const u8) ArgInfo {
        const w = g.parseWritten(spelling);
        return .{ .canon = w.canon, .sign_extended = isSigned(w.canon) or w.handle, .spelling = spelling };
    }

    fn argFromNode(g: *Gen, node: Value) ArgInfo {
        const t = g.canon(node);
        return .{ .canon = t, .sign_extended = isSigned(t) or g.handleChain(node), .spelling = qualType(node) };
    }

    /// libclang's get_size(): sizeof.
    fn size(g: *const Gen, t: *const Type) u32 {
        return switch (t.kind) {
            .pointer, .reference => g.pointerSize(),
            .builtin => builtinSize(t.name, g.arch, g.darwin) orelse fatal("unknown builtin type '{s}'", .{t.name}),
            .record => g.record_sizes.get(t.name) orelse fatal("no layout for record '{s}'", .{t.name}),
            .@"enum" => 4,
            .function => fatal("a function type has no size", .{}),
        };
    }

    fn pointerSize(g: *const Gen) u32 {
        return if (g.arch == .x86_64) 8 else 4;
    }

    /// _slot_size_for_arch
    fn slotSize(g: *const Gen, a: ArgInfo, arch: Arch) u32 {
        if (a.canon.kind == .pointer) return if (arch == .x86_64) 8 else 4;
        const s = g.size(a.canon);
        switch (arch) {
            .x86 => {
                if (s <= 4) return 4;
                if (s <= 8) return 8;
            },
            .x86_64 => if (s <= 8) return 8,
        }
        fatal("Argument size {} not supported for architecture {t}", .{ s, arch });
    }

    // ---- collecting ----

    fn collectFunctions(g: *Gen, tu: Value, dll: []const u8) []const FuncInfo {
        var out: std.StringArrayHashMapUnmanaged(FuncInfo) = .empty;
        g.visitFunctions(tu, &.{}, dll, &out);
        return g.sorted(FuncInfo, out.values());
    }

    fn visitFunctions(g: *Gen, node: Value, ns: []const []const u8, dll: []const u8, out: *std.StringArrayHashMapUnmanaged(FuncInfo)) void {
        for (inner(node)) |c| {
            const k = str(c, "kind") orelse continue;
            if (eql(k, "NamespaceDecl")) {
                const sub = g.arena.alloc([]const u8, ns.len + 1) catch oom();
                @memcpy(sub[0..ns.len], ns);
                sub[ns.len] = str(c, "name") orelse "";
                g.visitFunctions(c, sub, dll, out);
                continue;
            }
            if (!eql(k, "FunctionDecl")) continue;
            if (ns.len != 1 or !eql(ns[0], dll)) continue;
            const name = str(c, "name") orelse continue;
            if (name.len == 0) continue;
            const source_cc = ccAnnotation(c);
            if (source_cc == .DEFAULT) continue;
            const fn_type = qualType(c);
            var args: std.ArrayList(ArgInfo) = .empty;
            for (inner(c)) |p| {
                if (eql(str(p, "kind") orelse "", "ParmVarDecl")) args.append(g.arena, g.argFromWritten(qualType(p))) catch oom();
            }
            out.put(g.arena, name, .{
                .qualified_ns = std.mem.join(g.arena, "::", ns) catch oom(),
                .name = name,
                .mangled = str(c, "mangledName") orelse name,
                .source_cc = source_cc,
                .target_cc = ccOfType(fn_type),
                .variadic = if (get(c, "variadic")) |v| v == .bool and v.bool else false,
                .ret = g.argFromWritten(returnSpelling(fn_type)),
                .args = args.items,
                .host_to_guest = false,
            }) catch oom();
        }
    }

    fn collectTypedefs(g: *Gen, tu: Value) []const FuncInfo {
        var out: std.StringArrayHashMapUnmanaged(FuncInfo) = .empty;
        g.visitTypedefs(tu, &out);
        return g.sorted(FuncInfo, out.values());
    }

    fn visitTypedefs(g: *Gen, node: Value, out: *std.StringArrayHashMapUnmanaged(FuncInfo)) void {
        for (inner(node)) |c| {
            const k = str(c, "kind") orelse continue;
            if (eql(k, "NamespaceDecl")) {
                g.visitTypedefs(c, out);
                continue;
            }
            if (!eql(k, "TypedefDecl")) continue;
            const name = str(c, "name") orelse continue;
            if (name.len == 0) continue;
            const ty = inner(c);
            if (ty.len == 0) continue;
            // libclang sees through parentheses and attributes
            const ptr = transparent(ty[0]);
            if (!eql(str(ptr, "kind") orelse "", "PointerType")) continue;
            const func = transparent(only(ptr));
            if (!eql(str(func, "kind") orelse "", "FunctionProtoType")) continue;
            const target_cc = ccAnnotation(c);
            if (target_cc == .DEFAULT) continue;
            const parts = inner(func);
            var args: std.ArrayList(ArgInfo) = .empty;
            for (parts[1..]) |p| args.append(g.arena, g.argFromNode(p)) catch oom();
            out.put(g.arena, name, .{
                .qualified_ns = "",
                .name = name,
                .mangled = name,
                .source_cc = ccName(str(func, "cc") orelse "cdecl"),
                .target_cc = target_cc,
                .variadic = if (get(func, "variadic")) |v| v == .bool and v.bool else false,
                .ret = g.argFromNode(parts[0]),
                .args = args.items,
                .host_to_guest = true,
            }) catch oom();
        }
    }

    fn collectVariables(g: *Gen, tu: Value, dll: []const u8) []const VarInfo {
        var out: std.StringArrayHashMapUnmanaged(VarInfo) = .empty;
        g.visitVariables(tu, &.{}, dll, &out);
        return g.sorted(VarInfo, out.values());
    }

    fn visitVariables(g: *Gen, node: Value, ns: []const []const u8, dll: []const u8, out: *std.StringArrayHashMapUnmanaged(VarInfo)) void {
        for (inner(node)) |c| {
            const k = str(c, "kind") orelse continue;
            if (eql(k, "NamespaceDecl")) {
                const sub = g.arena.alloc([]const u8, ns.len + 1) catch oom();
                @memcpy(sub[0..ns.len], ns);
                sub[ns.len] = str(c, "name") orelse "";
                g.visitVariables(c, sub, dll, out);
                continue;
            }
            if (!eql(k, "VarDecl")) continue;
            if (!eql(str(c, "storageClass") orelse "", "extern") or get(c, "init") != null) continue;
            if (ns.len != 1 or !eql(ns[0], dll)) continue;
            const name = str(c, "name") orelse continue;
            if (name.len == 0) continue;
            out.put(g.arena, name, .{ .qualified_ns = std.mem.join(g.arena, "::", ns) catch oom(), .name = name }) catch oom();
        }
    }

    fn sorted(g: *Gen, comptime T: type, items: []const T) []const T {
        const copy = g.arena.dupe(T, items) catch oom();
        std.mem.sortUnstable(T, copy, {}, struct {
            fn lessThan(_: void, a: T, b: T) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);
        return copy;
    }

    // ---- argument layout ----

    const Placement = struct {
        slot_size: u32,
        stack_offset: ?u32 = null,
        register: ?[]const u8 = null,
    };
    const Layout = struct { args: []const Placement, stack_size: u32 };

    /// compute_arg_layout
    fn layout(g: *Gen, args: []const ArgInfo, cc: CallingConv, arch: Arch, start_offset: u32, skip_args: u32) Layout {
        var placements: std.ArrayList(Placement) = .empty;
        var stack_offset = start_offset;
        var stack_size: u32 = 0;
        const gpr_order: []const []const u8 = if (arch == .x86 and cc == .X86_FASTCALL)
            &.{ "ecx", "edx" }
        else if (arch == .x86_64 and cc == .C)
            &.{ "rdi", "rsi", "rdx", "rcx", "r8", "r9" }
        else
            &.{};
        var gpr_index: usize = skip_args;
        const register_size: u32 = if (arch == .x86_64) 8 else 4;
        const consumed: u32 = @as(u32, @intCast(@max(0, @as(i64, skip_args) - @as(i64, @intCast(gpr_order.len))))) * register_size;
        stack_offset += consumed;
        stack_size += consumed;

        const S = struct {
            fn pushStack(gg: *Gen, ps: *std.ArrayList(Placement), a: ArgInfo, ar: Arch, off: *u32, sz: *u32) void {
                const slot = gg.slotSize(a, ar);
                ps.append(gg.arena, .{ .slot_size = slot, .stack_offset = off.* }) catch oom();
                off.* += slot;
                sz.* += slot;
            }
        };
        if (arch == .x86 and cc == .X86_FASTCALL) {
            var stack_args_start: usize = 0;
            for (0..@min(gpr_order.len, args.len)) |i| {
                if (gpr_index >= gpr_order.len) break;
                const slot = g.slotSize(args[i], arch);
                if (slot != 4) break;
                placements.append(g.arena, .{ .slot_size = slot, .register = gpr_order[gpr_index] }) catch oom();
                gpr_index += 1;
                stack_args_start += 1;
            }
            for (args[stack_args_start..]) |a| S.pushStack(g, &placements, a, arch, &stack_offset, &stack_size);
        } else {
            for (args) |a| {
                const slot = g.slotSize(a, arch);
                if (slot <= register_size and gpr_index < gpr_order.len) {
                    placements.append(g.arena, .{ .slot_size = slot, .register = gpr_order[gpr_index] }) catch oom();
                    gpr_index += 1;
                } else S.pushStack(g, &placements, a, arch, &stack_offset, &stack_size);
            }
        }
        return .{ .args = placements.items, .stack_size = stack_size };
    }

    // ---- emitting ----

    const Writer = std.Io.Writer;
    const Error = Writer.Error;

    fn emitAsm(g: *Gen, w: *Writer, dll: []const u8, funcs: []const FuncInfo, typedefs: []const FuncInfo) Error!void {
        try w.writeAll("# Auto-generated thunks; DO NOT EDIT.\n");
        try w.writeAll("#include \"macros.S\"\n");
        try w.writeAll(".text\n");
        for (funcs) |f| {
            try w.print("\n# {s}::{s} (source_cc={t}, target_cc={t}, variadic={s})\n", .{ f.qualified_ns, f.name, f.source_cc, f.target_cc, pyBool(f.variadic) });
            try g.describeArgs(w, f, g.layout(f.args, f.source_cc, .x86, 0, 0), g.layout(f.args, f.target_cc, g.arch, 0, 0));
            try w.print("ASM_GLOBAL(thunk_{s}_{s}, @function)\n", .{ dll, f.name });
            try g.emitThunk(w, f);
            try w.print("ASM_END(thunk_{s}_{s})\n", .{ dll, f.name });
        }
        for (typedefs) |f| {
            try w.print("\n# {s} (target_cc={t}, variadic={s})\n", .{ f.name, f.target_cc, pyBool(f.variadic) });
            try g.describeArgs(w, f, g.layout(f.args, f.source_cc, g.arch, 0, 1), g.layout(f.args, f.target_cc, .x86, 0, 0));
            try w.print("ASM_WEAK(call_{s}, @function)\n", .{f.name});
            try g.emitThunk(w, f);
            try w.print("ASM_END(call_{s})\n", .{f.name});
        }
    }

    fn describeArgs(g: *Gen, w: *Writer, f: FuncInfo, src: Layout, dst: Layout) Error!void {
        _ = g;
        for (f.args, 0..) |a, i| {
            try w.print("\t# Arg {} (src=", .{i});
            try describePlacement(w, src.args[i]);
            try w.writeAll(", dst=");
            try describePlacement(w, dst.args[i]);
            try w.print(", class=int, sign_extended={s})\n", .{pyBool(a.sign_extended)});
        }
    }

    fn describePlacement(w: *Writer, p: Placement) Error!void {
        if (p.register) |r| return w.print("{s}[{}]", .{ r, p.slot_size });
        if (p.stack_offset) |o| return w.print("stack+{}[{}]", .{ o, p.slot_size });
        unreachable;
    }

    fn emitThunk(g: *Gen, w: *Writer, f: FuncInfo) Error!void {
        switch (g.arch) {
            .x86 => try g.emitThunk32(w, f),
            .x86_64 => try g.emitThunk64(w, f),
        }
    }

    fn ins(w: *Writer, comptime format: []const u8, args: anytype) Error!void {
        try w.print("\t" ++ format ++ "\n", args);
    }

    fn swapSegments(w: *Writer) Error!void {
        try ins(w, "mov ax, fs", .{});
        try ins(w, "mov dx, word ptr [ecx+TEB_FS_SEL]", .{});
        try ins(w, "mov word ptr [ecx+TEB_FS_SEL], ax", .{});
        try ins(w, "mov fs, dx", .{});
        try ins(w, "mov ax, gs", .{});
        try ins(w, "mov dx, word ptr [ecx+TEB_GS_SEL]", .{});
        try ins(w, "mov word ptr [ecx+TEB_GS_SEL], ax", .{});
        try ins(w, "mov gs, dx", .{});
    }

    /// emit_cc_thunk32
    fn emitThunk32(g: *Gen, w: *Writer, f: FuncInfo) Error!void {
        const call_target = if (f.host_to_guest) "[eax+4]" else f.mangled;
        const alignment: u32 = if (f.host_to_guest) 0 else 16;
        if (f.variadic) {
            if (f.source_cc != .C or f.target_cc != .C) fatal("Variadic functions must be cdecl ({s})", .{f.name});
            return ins(w, "jmp {s}", .{call_target});
        }
        const src = g.layout(f.args, f.source_cc, .x86, 4, if (f.host_to_guest) 1 else 0);
        const dst = g.layout(f.args, f.target_cc, .x86, 0, 0);

        if (f.host_to_guest) try ins(w, "GET_TEB_HOST ecx", .{}) else try ins(w, "mov ecx, fs:[TEB_SELF]", .{});
        try swapSegments(w);
        if (f.args.len > 0 or f.host_to_guest) try ins(w, "mov eax, esp", .{});
        try ins(w, "push ebp", .{});
        try ins(w, "mov ebp, dword ptr [ecx+TEB_SP]", .{});
        try ins(w, "mov dword ptr [ecx+TEB_SP], esp", .{});
        try ins(w, "mov esp, ebp", .{});
        if (dst.stack_size > 0) try ins(w, "sub esp, {}", .{dst.stack_size});
        if (alignment > 0) try ins(w, "and esp, ~{}", .{alignment - 1});
        for (dst.args, 0..) |t, i| {
            const to = t.stack_offset orelse continue;
            const s = src.args[i];
            const from = s.stack_offset orelse fatal("Source calling convention {t} requires register argument {}; not implemented", .{ f.source_cc, i });
            if (s.slot_size != t.slot_size) fatal("Argument {} requires size conversion {}->{}; not implemented", .{ i, s.slot_size, t.slot_size });
            var off: u32 = 0;
            while (off < t.slot_size) : (off += 4) {
                try ins(w, "mov ecx, [eax+{}]", .{from + off});
                try ins(w, "mov [esp+{}], ecx", .{to + off});
            }
        }
        for (dst.args, 0..) |t, i| {
            const reg = t.register orelse continue;
            const from = src.args[i].stack_offset orelse fatal("Source calling convention {t} requires register argument {}; not implemented", .{ f.source_cc, i });
            try ins(w, "mov {s}, [eax+{}]", .{ reg, from });
        }
        try ins(w, "call {s}", .{call_target});

        const return_size = g.returnSize(f.ret);
        if (return_size > 8) fatal("Return size {} not supported for function {s}", .{ return_size, f.name });
        const save_eax = return_size > 0;
        const save_edx = return_size > 4;
        if (save_eax) try ins(w, "push eax", .{});
        if (save_edx) try ins(w, "push edx", .{});
        if (f.host_to_guest) try ins(w, "mov ecx, fs:[TEB_SELF]", .{}) else try ins(w, "GET_TEB_HOST ecx", .{});
        try swapSegments(w);
        if (save_edx) try ins(w, "pop edx", .{});
        if (save_eax) try ins(w, "pop eax", .{});
        try ins(w, "mov esp, ebp", .{});
        try ins(w, "mov ebp, dword ptr [ecx+TEB_SP]", .{});
        try ins(w, "mov dword ptr [ecx+TEB_SP], esp", .{});
        try ins(w, "leave", .{});
        if (f.source_cc == .X86_STDCALL and src.stack_size > 0) try ins(w, "ret {}", .{src.stack_size}) else try ins(w, "ret", .{});
    }

    /// The return type's size; void's is libclang's error value, which counts as none.
    fn returnSize(g: *const Gen, ret: ArgInfo) u32 {
        if (ret.canon.kind == .builtin and eql(ret.canon.name, "void")) return 0;
        return g.size(ret.canon);
    }

    /// _x64_register_by_slot_size
    fn reg64(g: *Gen, reg: []const u8, slot_size: u32) []const u8 {
        if (slot_size == 8) return reg;
        const legacy = [_][]const u8{ "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp" };
        for (legacy) |l| if (eql(reg, l)) {
            return switch (slot_size) {
                4 => g.fmt("e{s}", .{reg[1..]}),
                2 => reg[1..],
                1 => if (eql(reg, "rax") or eql(reg, "rbx") or eql(reg, "rcx") or eql(reg, "rdx"))
                    g.fmt("{c}l", .{reg[1]})
                else if (eql(reg, "rsi") or eql(reg, "rdi"))
                    g.fmt("{c}il", .{reg[1]})
                else
                    g.fmt("{c}pl", .{reg[1]}),
                else => fatal("Unsupported register {s} for slot size {}", .{ reg, slot_size }),
            };
        };
        return switch (slot_size) {
            4 => g.fmt("{s}d", .{reg}),
            2 => g.fmt("{s}w", .{reg}),
            1 => g.fmt("{s}b", .{reg}),
            else => fatal("Unsupported register {s} for slot size {}", .{ reg, slot_size }),
        };
    }

    /// _x64_ptr_type_by_slot_size
    fn ptr64(slot_size: u32) []const u8 {
        return switch (slot_size) {
            4 => "dword ptr",
            8 => "qword ptr",
            else => fatal("Unsupported slot size {}", .{slot_size}),
        };
    }

    fn fmt(g: *Gen, comptime f: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(g.arena, f, args) catch oom();
    }

    /// emit_cc_thunk64
    fn emitThunk64(g: *Gen, w: *Writer, f: FuncInfo) Error!void {
        const call_target = if (f.host_to_guest) "edi" else f.mangled;
        const alignment: u32 = if (f.host_to_guest) 0 else 16;
        if (f.variadic) {
            if (f.source_cc != .C or f.target_cc != .C) fatal("Variadic functions must be cdecl ({s})", .{f.name});
            return ins(w, "jmp {s}", .{call_target});
        }
        const src = g.layout(f.args, f.source_cc, if (f.host_to_guest) .x86_64 else .x86, if (f.host_to_guest) 24 else 20, if (f.host_to_guest) 1 else 0);
        const dst = g.layout(f.args, f.target_cc, if (f.host_to_guest) .x86 else .x86_64, 0, 0);

        if (f.host_to_guest) {
            try w.writeAll(".code64\n");
            try ins(w, "push rbp", .{});
            try ins(w, "push rbx", .{});
            try ins(w, "mov r10, rsp", .{});
            try ins(w, "GET_TEB_HOST rbx", .{});
            if (!g.darwin) {
                try ins(w, "READ_FSBASE r9, rbx", .{});
                try ins(w, "mov qword ptr [rbx+TEB_FSBASE], r9", .{});
            }
            try ins(w, "mov rbp, qword ptr [rbx+TEB_SP]", .{});
            try ins(w, "mov qword ptr [rbx+TEB_SP], rsp", .{});
            try ins(w, "mov rsp, rbp", .{});
            if (dst.stack_size > 0) try ins(w, "sub rsp, {}", .{dst.stack_size});
            if (alignment > 0) try ins(w, "and rsp, ~{}", .{alignment - 1});
            for (dst.args, 0..) |t, i| {
                const to = t.stack_offset orelse fatal("Unexpected register argument {}", .{i});
                const s = src.args[i];
                var ptr_type: []const u8 = undefined;
                var register: []const u8 = undefined;
                if (s.stack_offset) |from| {
                    try ins(w, "mov {s}, {s} [r10+{}]", .{ g.reg64("rax", t.slot_size), ptr64(s.slot_size), from });
                    ptr_type = ptr64(t.slot_size);
                    register = g.reg64("rax", t.slot_size);
                } else if (s.register) |r| {
                    ptr_type = ptr64(t.slot_size);
                    register = g.reg64(r, t.slot_size);
                } else fatal("Argument {} is not a register or stack offset", .{i});
                try ins(w, "mov {s} [rsp+{}], {s}", .{ ptr_type, to, register });
            }
            try ins(w, "LJMP32 rbx", .{});
            if (!g.darwin) {
                try ins(w, "mov ax, word ptr [ebx+TEB_FS_SEL]", .{});
                try ins(w, "mov fs, ax", .{});
            }
            try ins(w, "call {s}", .{call_target});
            try ins(w, "mov ebx, fs:[TEB_SELF]", .{});
            try ins(w, "LJMP64 ebx", .{});
            if (f.ret.sign_extended) try ins(w, "cdqe", .{});
            if (!g.darwin) {
                try ins(w, "mov r9, qword ptr [rbx+TEB_FSBASE]", .{});
                try ins(w, "WRITE_FSBASE r9, rbx", .{});
            }
            try ins(w, "mov rsp, qword ptr [rbx+TEB_SP]", .{});
            try ins(w, "mov qword ptr [rbx+TEB_SP], rbp", .{});
            try ins(w, "pop rbx", .{});
            try ins(w, "pop rbp", .{});
            try ins(w, "ret", .{});
        } else {
            try w.writeAll(".code32\n");
            try ins(w, "push ebp", .{});
            try ins(w, "push esi", .{});
            try ins(w, "push edi", .{});
            try ins(w, "push ebx", .{});
            try ins(w, "mov ebx, fs:[TEB_SELF]", .{});
            if (!g.darwin) {
                try ins(w, "mov di, fs", .{});
                try ins(w, "mov word ptr [ebx+TEB_FS_SEL], di", .{});
            }
            try ins(w, "LJMP64 ebx", .{});
            if (!g.darwin) {
                try ins(w, "mov r9, qword ptr [rbx+TEB_FSBASE]", .{});
                try ins(w, "WRITE_FSBASE r9, rbx", .{});
            }
            try ins(w, "mov r10, rsp", .{});
            try ins(w, "mov rbp, qword ptr [rbx+TEB_SP]", .{});
            try ins(w, "mov qword ptr [rbx+TEB_SP], rsp", .{});
            try ins(w, "mov rsp, rbp", .{});
            if (dst.stack_size > 0) try ins(w, "sub rsp, {}", .{dst.stack_size});
            if (alignment > 0) try ins(w, "and rsp, ~{}", .{alignment - 1});
            for (dst.args, 0..) |t, i| {
                const a = f.args[i];
                const s = src.args[i];
                if (t.stack_offset) |to| {
                    var ptr_type: []const u8 = undefined;
                    var register: []const u8 = undefined;
                    if (s.stack_offset) |from| {
                        try ins(w, "mov {s}, {s} [r10+{}]", .{ g.reg64("rax", s.slot_size), ptr64(s.slot_size), from });
                        ptr_type = ptr64(t.slot_size);
                        register = g.reg64("rax", t.slot_size);
                    } else if (s.register) |r| {
                        ptr_type = ptr64(t.slot_size);
                        register = g.reg64(r, t.slot_size);
                    } else fatal("Argument {} is not a register or stack offset", .{i});
                    try ins(w, "mov {s} [rsp+{}], {s}", .{ ptr_type, to, register });
                } else if (t.register) |reg| {
                    const ptr_type = ptr64(s.slot_size);
                    const from = s.stack_offset orelse fatal("Argument {} is not on the stack", .{i});
                    if (s.slot_size == 4 and t.slot_size == 8) {
                        const r32 = g.reg64(reg, s.slot_size);
                        try ins(w, "mov {s}, {s} [r10+{}]", .{ r32, ptr_type, from });
                        if (a.sign_extended) try ins(w, "movsxd {s}, {s}", .{ reg, r32 });
                    } else if (s.slot_size == 8 and t.slot_size == 8) {
                        try ins(w, "mov {s}, {s} [r10+{}]", .{ reg, ptr_type, from });
                    } else fatal("Unsupported conversion from {} to {}", .{ s.slot_size, t.slot_size });
                }
            }
            try ins(w, "call {s}", .{call_target});
            try ins(w, "mov rsp, qword ptr [rbx+TEB_SP]", .{});
            try ins(w, "mov qword ptr [rbx+TEB_SP], rbp", .{});
            try ins(w, "LJMP32 rbx", .{});
            if (!g.darwin) {
                try ins(w, "mov di, word ptr [ebx+TEB_FS_SEL]", .{});
                try ins(w, "mov fs, di", .{});
            }
            try ins(w, "pop ebx", .{});
            try ins(w, "pop edi", .{});
            try ins(w, "pop esi", .{});
            try ins(w, "pop ebp", .{});
            if (f.source_cc == .X86_STDCALL and src.stack_size > 0) try ins(w, "ret {}", .{src.stack_size}) else try ins(w, "ret", .{});
        }
    }

    /// emit_header_mapping
    fn emitHeader(g: *Gen, w: *Writer, dll: []const u8, funcs: []const FuncInfo, typedefs: []const FuncInfo, variables: []const VarInfo) Error!void {
        const guard = g.fmt("WIBO_GEN_{s}_THUNKS_H", .{std.ascii.allocUpperString(g.arena, dll) catch oom()});
        try w.writeAll("/* Auto-generated; DO NOT EDIT. */\n");
        try w.print("#ifndef {s}\n#define {s}\n", .{ guard, guard });
        try w.writeAll("#include <stddef.h>\n#include <string.h>\n");
        try w.writeAll("#ifdef __cplusplus\nextern \"C\" {\n#endif\n");
        for (funcs) |f| {
            const cc_attr = if (g.arch == .x86_64) "" else switch (f.source_cc) {
                .X86_STDCALL => "__attribute__((stdcall)) ",
                .C => "__attribute__((cdecl)) ",
                else => fatal("Unsupported calling convention {t} for function {s}", .{ f.source_cc, f.name }),
            };
            try w.print("{s}{s} thunk_{s}_{s}(", .{ cc_attr, g.canonicalString(f.ret.canon), dll, f.name });
            for (f.args, 0..) |a, i| try w.print("{s}{s} arg{}", .{ if (i == 0) "" else ", ", g.canonicalString(a.canon), i });
            try w.writeAll(");\n");
        }
        for (typedefs) |td| {
            if (td.variadic) continue;
            try w.print("{s} call_{s}({s} fn", .{ typeToString(g, td.ret.spelling), td.name, td.name });
            for (td.args, 0..) |a, i| try w.print(", {s} arg{}", .{ typeToString(g, a.spelling), i });
            try w.writeAll(");\n");
        }
        try w.writeAll("#ifdef __cplusplus\n}\n#endif\n");
        try w.writeAll("\n");
        try w.print("static inline void *{s}ThunkByName(const char *name) {{\n", .{dll});
        for (funcs) |f| try w.print("\tif (strcmp(name, \"{s}\") == 0) return (void*)&thunk_{s}_{s};\n", .{ f.name, dll, f.name });
        for (variables) |v| {
            if (v.qualified_ns.len > 0)
                try w.print("\tif (strcmp(name, \"{s}\") == 0) return (void*)&{s}::{s};\n", .{ v.name, v.qualified_ns, v.name })
            else
                try w.print("\tif (strcmp(name, \"{s}\") == 0) return (void*)&{s};\n", .{ v.name, v.name });
        }
        try w.writeAll("\treturn NULL;\n}\n");
        try w.print("#endif /* {s} */\n", .{guard});
    }

    /// _canonical_type_str: records, enums, functions and pointers to them are void *.
    fn canonicalString(g: *Gen, t: *const Type) []const u8 {
        if (isOpaque(t)) return "void *";
        return g.spell(t);
    }

    /// A canonical type as clang spells it: "const unsigned short *", "char **", "int *const".
    fn spell(g: *Gen, t: *const Type) []const u8 {
        return switch (t.kind) {
            .builtin => g.fmt("{s}{s}{s}", .{ if (t.is_const) "const " else "", if (t.is_volatile) "volatile " else "", t.name }),
            .pointer, .reference => blk: {
                const inner_s = g.spell(t.child.?);
                const mark: []const u8 = if (t.kind == .pointer) "*" else "&";
                const sep: []const u8 = if (std.mem.endsWith(u8, inner_s, "*") or std.mem.endsWith(u8, inner_s, "&")) "" else " ";
                const q: []const u8 = if (t.is_const and t.is_volatile) "const volatile" else if (t.is_const) "const" else if (t.is_volatile) "volatile" else "";
                break :blk g.fmt("{s}{s}{s}{s}", .{ inner_s, sep, mark, q });
            },
            .record => g.fmt("{s}{s}", .{ if (t.is_const) "const " else "", t.name }),
            .@"enum", .function => fatal("spelling an opaque type", .{}),
        };
    }
};

/// _type_to_string: as written, without struct/union/enum keywords.
fn typeToString(g: *Gen, spelling: []const u8) []const u8 {
    var s = spelling;
    for ([_][]const u8{ "struct ", "union ", "enum " }) |kw| s = std.mem.replaceOwned(u8, g.arena, s, kw, "") catch oom();
    return s;
}

fn isOpaque(t: *const Type) bool {
    return switch (t.kind) {
        .record, .@"enum", .function => true,
        .pointer => isOpaque(t.child.?),
        else => false,
    };
}

/// SIGNED_KINDS: signed char, char (signed on x86), short, int, long, long long, __int128.
fn isSigned(t: *const Type) bool {
    if (t.kind != .builtin) return false;
    for ([_][]const u8{ "signed char", "char", "short", "int", "long", "long long", "__int128" }) |n| {
        if (eql(t.name, n)) return true;
    }
    return false;
}

fn builtinSize(name: []const u8, arch: Arch, darwin: bool) ?u32 {
    _ = darwin;
    const long: u32 = if (arch == .x86_64) 8 else 4;
    const table = [_]struct { []const u8, u32 }{
        .{ "bool", 1 },               .{ "char", 1 },          .{ "signed char", 1 },        .{ "unsigned char", 1 },
        .{ "char8_t", 1 },            .{ "short", 2 },         .{ "unsigned short", 2 },     .{ "char16_t", 2 },
        .{ "wchar_t", 4 },            .{ "char32_t", 4 },      .{ "int", 4 },                .{ "unsigned int", 4 },
        .{ "long", long },            .{ "unsigned long", long }, .{ "long long", 8 },        .{ "unsigned long long", 8 },
        .{ "__int128", 16 },          .{ "unsigned __int128", 16 }, .{ "float", 4 },          .{ "double", 8 },
        .{ "long double", if (arch == .x86_64) 16 else 12 },
    };
    for (table) |e| if (eql(e[0], name)) return e[1];
    return null;
}

fn isBuiltinWord(t: []const u8) bool {
    for ([_][]const u8{ "void", "bool", "char", "short", "int", "long", "signed", "unsigned", "float", "double", "wchar_t", "char8_t", "char16_t", "char32_t", "__int128" }) |b| {
        if (eql(t, b)) return true;
    }
    return false;
}

/// Python's str.isupper() on a name starting with H.
fn isHandleName(name: []const u8) bool {
    if (name.len == 0 or name[0] != 'H') return false;
    for (name) |c| if (std.ascii.isLower(c)) return false;
    return true;
}

/// The function's return type, from its type's spelling: "BOOL (HANDLE, DWORD) ...".
fn returnSpelling(fn_type: []const u8) []const u8 {
    var depth: usize = 0;
    for (fn_type, 0..) |c, i| switch (c) {
        '<' => depth += 1,
        '>' => depth -= 1,
        '(' => if (depth == 0) return std.mem.trimEnd(u8, fn_type[0..i], " "),
        else => {},
    };
    fatal("can't find the return type in '{s}'", .{fn_type});
}

/// The calling convention of a function's type, from its spelling.
fn ccOfType(fn_type: []const u8) CallingConv {
    if (std.mem.indexOf(u8, fn_type, "__attribute__((fastcall))") != null) return .X86_FASTCALL;
    if (std.mem.indexOf(u8, fn_type, "__attribute__((stdcall))") != null) return .X86_STDCALL;
    return .C;
}

fn ccName(name: []const u8) CallingConv {
    if (eql(name, "cdecl")) return .C;
    if (eql(name, "stdcall")) return .X86_STDCALL;
    if (eql(name, "fastcall")) return .X86_FASTCALL;
    fatal("unsupported calling convention '{s}'", .{name});
}

/// _source_cc_from_annotations: the first CC: annotation among a declaration's children.
fn ccAnnotation(decl: Value) CallingConv {
    for (inner(decl)) |c| {
        if (!eql(str(c, "kind") orelse "", "AnnotateAttr")) continue;
        const v = str(c, "value") orelse continue;
        if (eql(v, "CC:fastcall")) return .X86_FASTCALL;
        if (eql(v, "CC:stdcall")) return .X86_STDCALL;
        if (eql(v, "CC:cdecl")) return .C;
    }
    return .DEFAULT;
}

fn pyBool(b: bool) []const u8 {
    return if (b) "True" else "False";
}

// ---- JSON ----

fn get(v: Value, key: []const u8) ?Value {
    return if (v == .object) v.object.get(key) else null;
}

fn str(v: Value, key: []const u8) ?[]const u8 {
    const s = get(v, key) orelse return null;
    return if (s == .string) s.string else null;
}

fn inner(v: Value) []const Value {
    const i = get(v, "inner") orelse return &.{};
    return if (i == .array) i.array.items else &.{};
}

fn only(v: Value) Value {
    const i = inner(v);
    if (i.len == 0) fatal("a {s} without what it's of", .{str(v, "kind") orelse "node"});
    return i[0];
}

fn transparent(v: Value) Value {
    var n = v;
    while (true) {
        const k = str(n, "kind") orelse return n;
        if (!(eql(k, "ParenType") or eql(k, "AttributedType") or eql(k, "MacroQualifiedType"))) return n;
        n = only(n);
    }
}

fn qualType(v: Value) []const u8 {
    const t = get(v, "type") orelse fatal("a {s} without a type", .{str(v, "kind") orelse "node"});
    return str(t, "qualType") orelse fatal("a type without qualType", .{});
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const std = @import("std");
