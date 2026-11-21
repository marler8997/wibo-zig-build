pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .x86, .os_tag = .linux, .abi = .musl } });
    const optimize = b.standardOptimizeOption(.{});
    const t = target.result;
    if (t.os.tag != .linux) std.process.fatal("wibo-zig-build: only Linux targets so far, not {t}", .{t.os.tag});
    const arch: []const u8 = switch (t.cpu.arch) {
        .x86 => "x86",
        .x86_64 => "x86_64",
        else => std.process.fatal("wibo-zig-build: wibo runs on x86 and x86_64, not {t}", .{t.cpu.arch}),
    };

    const upstream = b.dependency("upstream", .{});
    const mimalloc = b.dependency("mimalloc", .{});

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    mod.addCSourceFiles(.{
        .root = mimalloc.path(""),
        .files = &.{"src/static.c"},
        .flags = &.{
            "-fvisibility=hidden",
            "-ftls-model=local-dynamic",
            "-fno-builtin-malloc",
            "-Wno-psabi",
            "-Wno-builtin-macro-redefined",
            "-D__DATE__=\"-\"",
            "-D__TIME__=\"-\"",
            "-Wno-atomic-alignment",
        },
    });
    mod.addIncludePath(mimalloc.path("include"));
    mod.addCMacro("MI_MALLOC_OVERRIDE", "1");
    mod.addCMacro("MI_USE_BUILTIN_THREAD_POINTER", "1");
    if (t.abi.isMusl()) mod.addCMacro("MI_LIBC_MUSL", "1");
    if (t.ptrBitWidth() == 64) mod.addCMacro("MI_DEBUG", "0");

    mod.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = &wibo_sources,
        .flags = &.{ "-std=c++20", "-fno-exceptions", "-fno-rtti", "-fno-sanitize=alignment,enum" },
    });
    mod.addCSourceFiles(.{ .root = upstream.path(""), .files = &.{"dll/advapi32/md5.c"} });
    mod.addAssemblyFile(upstream.path("src/setup.S"));

    const gen_exe = b.addExecutable(.{
        .name = "trampolines",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/trampolines.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const trampoline_headers = b.addWriteFiles();
    const trampolines_step = b.step("trampolines", "Install the generated trampolines to zig-out/trampolines");
    for (trampoline_modules) |m| {
        const out = trampolines(b, gen_exe, upstream, t, m.name, m.headers);
        mod.addAssemblyFile(out.asm_file);
        _ = trampoline_headers.addCopyFile(out.header, b.fmt("{s}_trampolines.h", .{m.name}));
        trampolines_step.dependOn(&b.addInstallFile(out.asm_file, b.fmt("trampolines/{s}/{s}_trampolines.S", .{ arch, m.name })).step);
        trampolines_step.dependOn(&b.addInstallFile(out.header, b.fmt("trampolines/{s}/{s}_trampolines.h", .{ arch, m.name })).step);
    }
    for ([_][]const u8{ "_GNU_SOURCE", "_FILE_OFFSET_BITS", "_TIME_BITS" }, [_][]const u8{ "1", "64", "64" }) |name, value| mod.addCMacro(name, value);
    mod.addCMacro("WIBO_ENABLE_LIBURING", "0");
    const embed_wine_dlls = b.option(bool, "wine-dlls", "Embed Wine's C runtime DLLs (msvcrt, ucrtbase, ...), for programs that load them (default: true)") orelse true;
    if (embed_wine_dlls) {
        const dlls = b.addWriteFiles();
        for (wine_dlls) |d| {
            const fetch = b.lazyDependency("fetch", .{
                .url = b.fmt("https://github.com/encounter/winedll/releases/download/" ++ wine_dll_release ++ "/{s}.dll", .{d.name}),
                .sha256 = d.sha256,
            }) orelse continue;
            _ = dlls.addCopyFile(fetch.namedLazyPath("file"), b.fmt("{s}.dll", .{d.name}));
            mod.addCSourceFile(.{
                .file = upstream.path(b.fmt("dll/{s}.cpp", .{d.name})),
                .flags = &.{ "-std=c++20", "-fno-exceptions", "-fno-rtti", "-fno-sanitize=alignment,enum", b.fmt("-DEMBED_PATH=\"{s}.dll\"", .{d.name}) },
            });
        }
        mod.addIncludePath(dlls.getDirectory());
    }
    for (wine_dlls) |d| mod.addCMacro(d.flag, if (embed_wine_dlls) "1" else "0");
    mod.addIncludePath(upstream.path("dll"));
    mod.addIncludePath(upstream.path("src"));
    mod.addIncludePath(trampoline_headers.getDirectory());
    mod.addIncludePath(b.addWriteFiles().add("version_info.h", b.fmt(
        \\#pragma once
        \\namespace wibo {{
        \\constexpr const char kVersionString[] = "1.2.0 (Linux {s})";
        \\}}
        \\
    , .{if (t.cpu.arch == .x86) "i686" else "x86_64"})).dirname());

    const exe = b.addExecutable(.{ .name = "wibo", .root_module = mod, .linkage = .static });
    exe.pie = false;
    exe.image_base = 0x70000000;
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run wibo (zig build run -- PROGRAM.exe ARGS...)").dependOn(&run.step);

    const test_step = b.step("test", "Run wibo's fixture tests under wibo (built everywhere, run where wibo runs)");
    const fixture_target = b.resolveTargetQuery(.{ .cpu_arch = .x86, .os_tag = .windows, .abi = .gnu });
    const fixtures = b.addWriteFiles();
    for (fixture_dlls) |d| {
        const lib = b.addLibrary(.{ .name = d.name, .linkage = .dynamic, .root_module = fixtureModule(b, upstream, fixture_target, d.source) });
        _ = fixtures.addCopyFile(lib.getEmittedBin(), b.fmt("{s}.dll", .{d.name}));
    }
    for (fixture_bins) |f| {
        const m = fixtureModule(b, upstream, fixture_target, b.fmt("test/{s}.c", .{f.name}));
        for (f.libs) |lib| m.linkSystemLibrary(lib, .{});
        if (f.rc) |rc| m.addWin32ResourceFile(.{ .file = upstream.path(rc) });
        const fixture = b.addExecutable(.{ .name = f.name, .root_module = m });
        _ = fixtures.addCopyFile(fixture.getEmittedBin(), b.fmt("{s}.exe", .{f.name}));
    }
    for (fixture_bins) |f| {
        const test_run = b.addRunArtifact(exe);
        test_run.setName(f.name);
        test_run.addFileArg(fixtures.getDirectory().path(b, b.fmt("{s}.exe", .{f.name})));
        test_run.setCwd(fixtures.getDirectory());
        test_run.expectExitCode(0);
        test_run.skip_foreign_checks = true;
        test_step.dependOn(&test_run.step);
    }
}

fn fixtureModule(b: *std.Build, upstream: *std.Build.Dependency, target: std.Build.ResolvedTarget, source: []const u8) *std.Build.Module {
    const m = b.createModule(.{ .target = target, .optimize = .ReleaseFast, .link_libc = true });
    m.addCSourceFile(.{ .file = upstream.path(source), .flags = &.{ "-Wall", "-Wextra" } });
    m.addIncludePath(upstream.path("test"));
    return m;
}

const fixture_dlls = [_]struct { name: []const u8, source: []const u8 }{
    .{ .name = "external_exports", .source = "test/external_exports.c" },
    .{ .name = "dll_attach_failure", .source = "test/dll_attach_failure.c" },
    .{ .name = "thread_notifications", .source = "test/thread_notifications.c" },
    .{ .name = "tls_reloc", .source = "test/tls_reloc_dll.c" },
};

const Fixture = struct { name: []const u8, libs: []const []const u8 = &.{}, rc: ?[]const u8 = null };

const fixture_bins = [_]Fixture{
    .{ .name = "test_external_dll" },          .{ .name = "test_dll_attach_failure" },
    .{ .name = "test_thread_notifications" },  .{ .name = "test_bcrypt", .libs = &.{"bcrypt"} },
    .{ .name = "test_shlwapi", .libs = &.{"shlwapi"} }, .{ .name = "test_ws2", .libs = &.{"ws2_32"} },
    .{ .name = "test_resources", .libs = &.{"version"}, .rc = "test/test_resources.rc" },
    .{ .name = "test_threading" },             .{ .name = "test_temppath" },
    .{ .name = "test_gettempfilename" },       .{ .name = "test_getprocaddress" },
    .{ .name = "test_getmodulehandleex" },     .{ .name = "test_tls" },
    .{ .name = "test_tls_reloc" },             .{ .name = "test_fls" },
    .{ .name = "test_handleapi" },             .{ .name = "test_findfile" },
    .{ .name = "test_getfileattributesex" },   .{ .name = "test_locale" },
    .{ .name = "test_lstrcpyn" },              .{ .name = "test_critical_section" },
    .{ .name = "test_synchapi" },              .{ .name = "test_processes" },
    .{ .name = "test_heap" },                  .{ .name = "test_actctx" },
    .{ .name = "test_overlapped_io" },         .{ .name = "test_time" },
    .{ .name = "test_ntdll_time" },            .{ .name = "test_virtualalloc" },
    .{ .name = "test_virtualquery" },          .{ .name = "test_createfilemapping" },
    .{ .name = "test_clsids", .libs = &.{"ole32"} }, .{ .name = "test_rtl" },
    .{ .name = "test_rtl_bitmap" },            .{ .name = "test_ntquery" },
    .{ .name = "test_ntqueryfile" },           .{ .name = "test_ntreadfile" },
    .{ .name = "test_ntwritefile" },           .{ .name = "test_pipe_io" },
    .{ .name = "test_namedpipe" },             .{ .name = "test_sysdir" },
    .{ .name = "test_stringapiset" },          .{ .name = "test_srw_lock" },
    .{ .name = "test_init_once" },             .{ .name = "test_wait_on_address", .libs = &.{"api-ms-win-core-synch-l1-2-0"} },
    .{ .name = "test_env_strings" },
};

const wibo_sources = [_][]const u8{
    "dll/advapi32.cpp",                   "dll/advapi32/processthreadsapi.cpp",
    "dll/advapi32/securitybaseapi.cpp",   "dll/advapi32/winbase.cpp",
    "dll/advapi32/wincrypt.cpp",          "dll/advapi32/winreg.cpp",
    "dll/bcrypt.cpp",                     "dll/kernel32.cpp",
    "dll/kernel32/debugapi.cpp",          "dll/kernel32/errhandlingapi.cpp",
    "dll/kernel32/fibersapi.cpp",         "dll/kernel32/fileapi.cpp",
    "dll/kernel32/handleapi.cpp",         "dll/kernel32/heapapi.cpp",
    "dll/kernel32/interlockedapi.cpp",    "dll/kernel32/ioapiset.cpp",
    "dll/kernel32/libloaderapi.cpp",      "dll/kernel32/memoryapi.cpp",
    "dll/kernel32/namedpipeapi.cpp",      "dll/kernel32/processenv.cpp",
    "dll/kernel32/processthreadsapi.cpp", "dll/kernel32/profileapi.cpp",
    "dll/kernel32/stringapiset.cpp",      "dll/kernel32/synchapi.cpp",
    "dll/kernel32/sysinfoapi.cpp",        "dll/kernel32/timezoneapi.cpp",
    "dll/kernel32/winbase.cpp",           "dll/kernel32/wincon.cpp",
    "dll/kernel32/winnls.cpp",            "dll/kernel32/winnt.cpp",
    "dll/kernel32/wow64apiset.cpp",       "dll/lmgr.cpp",
    "dll/mscoree.cpp",                    "dll/ntdll.cpp",
    "dll/ole32.cpp",                      "dll/rpcrt4.cpp",
    "dll/shlwapi.cpp",                    "dll/user32.cpp",
    "dll/vcruntime.cpp",                  "dll/version.cpp",
    "dll/ws2.cpp",                        "src/access.cpp",
    "src/async_io.cpp",                   "src/errors.cpp",
    "src/files.cpp",                      "src/handles.cpp",
    "src/heap.cpp",                       "src/loader.cpp",
    "src/main.cpp",                       "src/modules.cpp",
    "src/processes_common.cpp",           "src/resources.cpp",
    "src/strutil.cpp",                    "src/tls.cpp",
    "src/async_io_epoll.cpp",             "src/processes_linux.cpp",
    "src/setup_linux.cpp",
};

fn trampolines(
    b: *std.Build,
    gen_exe: *std.Build.Step.Compile,
    upstream: *std.Build.Dependency,
    t: std.Target,
    name: []const u8,
    headers: []const []const u8,
) struct { asm_file: std.Build.LazyPath, header: std.Build.LazyPath } {
    const zig_target, const triple, const os = switch (t.cpu.arch) {
        .x86 => .{ "x86-linux-musl", "i686-linux-gnu", "linux" },
        else => if (t.os.tag == .macos)
            .{ "x86_64-macos", "x86_64-apple-darwin", "macos" }
        else
            .{ "x86_64-linux-musl", "x86_64-linux-gnu", "linux" },
    };
    var source: std.ArrayList(u8) = .empty;
    for (headers) |h| source.print(b.allocator, "#include \"{s}\"\n", .{h}) catch @panic("OOM");
    const tu = b.addWriteFiles().add(b.fmt("{s}.cpp", .{name}), source.items);

    const preprocess = std.Build.Step.Run.create(b, b.fmt("preprocess {s}", .{name}));
    preprocess.addFileArg(std.Build.LazyPath.zig_exe);
    preprocess.addArgs(&.{ "c++", "-E", "-target", zig_target, "-x", "c++", "-std=c++17", "-DWIBO_CODEGEN=1", "-Wno-gcc-install-dir-libstdcxx" });
    for ([_][]const u8{ "", "dll", "src" }) |dir| {
        preprocess.addArg("-I");
        preprocess.addDirectoryArg(upstream.path(dir));
    }
    preprocess.addFileArg(tu);
    preprocess.addArg("-o");
    const ii = preprocess.addOutputFileArg(b.fmt("{s}.ii", .{name}));

    var dumps: [3]std.Build.LazyPath = undefined;
    for (&dumps, [_][]const u8{ "-ast-dump=json", "-ast-dump", "-fdump-record-layouts-complete" }) |*dump, flag| {
        const cc1 = std.Build.Step.Run.create(b, b.fmt("clang {s} {s}", .{ flag, name }));
        cc1.addFileArg(std.Build.LazyPath.zig_exe);
        cc1.addArgs(&.{ "clang", "-cc1", "-triple", triple, "-fsyntax-only", "-x", "c++-cpp-output", "-std=c++17", flag });
        cc1.addFileArg(ii);
        dump.* = cc1.captureStdOut(.{});
    }

    const gen = b.addRunArtifact(gen_exe);
    gen.addArgs(&.{ name, if (t.cpu.arch == .x86) "x86" else "x86_64", os });
    for (dumps) |d| gen.addFileArg(d);
    const asm_file = gen.addOutputFileArg(b.fmt("{s}_trampolines.S", .{name}));
    const header = gen.addOutputFileArg(b.fmt("{s}_trampolines.h", .{name}));
    return .{ .asm_file = asm_file, .header = header };
}

const TrampolineModule = struct { name: []const u8, headers: []const []const u8 };

const trampoline_modules = [_]TrampolineModule{
    .{ .name = "advapi32", .headers = &.{ "dll/advapi32/processthreadsapi.h", "dll/advapi32/securitybaseapi.h", "dll/advapi32/winbase.h", "dll/advapi32/wincrypt.h", "dll/advapi32/winreg.h" } },
    .{ .name = "bcrypt", .headers = &.{"dll/bcrypt.h"} },
    .{ .name = "entry", .headers = &.{"src/entry.h"} },
    .{ .name = "mscoree", .headers = &.{"dll/mscoree.h"} },
    .{ .name = "version", .headers = &.{"dll/version.h"} },
    .{ .name = "rpcrt4", .headers = &.{"dll/rpcrt4.h"} },
    .{ .name = "shlwapi", .headers = &.{"dll/shlwapi.h"} },
    .{ .name = "ws2", .headers = &.{"dll/ws2.h"} },
    .{ .name = "vcruntime", .headers = &.{"dll/vcruntime.h"} },
    .{ .name = "lmgr", .headers = &.{"dll/lmgr.h"} },
    .{ .name = "ole32", .headers = &.{"dll/ole32.h"} },
    .{ .name = "user32", .headers = &.{"dll/user32.h"} },
    .{ .name = "ntdll", .headers = &.{"dll/ntdll.h"} },
    .{ .name = "kernel32", .headers = &.{
        "dll/kernel32/debugapi.h",       "dll/kernel32/errhandlingapi.h", "dll/kernel32/fibersapi.h",
        "dll/kernel32/fileapi.h",        "dll/kernel32/handleapi.h",      "dll/kernel32/heapapi.h",
        "dll/kernel32/interlockedapi.h", "dll/kernel32/ioapiset.h",       "dll/kernel32/libloaderapi.h",
        "dll/kernel32/memoryapi.h",      "dll/kernel32/namedpipeapi.h",   "dll/kernel32/processenv.h",
        "dll/kernel32/processthreadsapi.h", "dll/kernel32/profileapi.h",  "dll/kernel32/stringapiset.h",
        "dll/kernel32/synchapi.h",       "dll/kernel32/sysinfoapi.h",     "dll/kernel32/timezoneapi.h",
        "dll/kernel32/winbase.h",        "dll/kernel32/wincon.h",         "dll/kernel32/winnls.h",
        "dll/kernel32/winnt.h",          "dll/kernel32/wow64apiset.h",
    } },
};

const wine_dll_release = "2026-07-10";

const wine_dlls = [_]struct { name: []const u8, flag: []const u8, sha256: []const u8 }{
    .{ .name = "msvcrt", .flag = "WIBO_HAS_MSVCRT", .sha256 = "01f5b5a6f8b249e2842e74720376ca84ea6e8094c18b5416ec80a2183fc9ef81" },
    .{ .name = "msvcirt", .flag = "WIBO_HAS_MSVCIRT", .sha256 = "c170ef5e15c91cafe520e4342a42eef8f8ed2c007e20471b0ac1c0277e1e0333" },
    .{ .name = "msvcrt20", .flag = "WIBO_HAS_MSVCRT20", .sha256 = "fb94edfa05414460ea8f27b82acf205a0d3caccd68d66f7e7de8ae7d29ae4563" },
    .{ .name = "msvcrt40", .flag = "WIBO_HAS_MSVCRT40", .sha256 = "da49673adf20b5f8cf23e99b18278f3ea225d33ce47bd25e1455c654ff4fc5ec" },
    .{ .name = "msvcr71", .flag = "WIBO_HAS_MSVCR71", .sha256 = "ad5b9673604a205f24feb06283c93fdbd7b652fbe9c865c50dbf26505b3df463" },
    .{ .name = "msvcr90", .flag = "WIBO_HAS_MSVCR90", .sha256 = "c8682ba683665bd3d6b9ff8ee0b34af34edbcfd30e7682321b98941aefeae659" },
    .{ .name = "msvcr100", .flag = "WIBO_HAS_MSVCR100", .sha256 = "405e44bced50a4b57c08de47e16e7d9792603c0af52bdd0fb19cff2c858b5880" },
    .{ .name = "msvcr120", .flag = "WIBO_HAS_MSVCR120", .sha256 = "fdb166b3eadd663fda65718334b72736a6f4aa3ec94a32d4c47e7a7add75b696" },
    .{ .name = "ucrtbase", .flag = "WIBO_HAS_UCRTBASE", .sha256 = "9606bcdd8d8436ce4d5c995cada5c20ce3d6cb52c35a04a0366613950785c282" },
};

const std = @import("std");
