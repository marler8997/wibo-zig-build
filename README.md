# wibo-zig-build

[wibo](https://github.com/decompals/wibo) (a minimal loader for simple command-line Windows
programs on Linux and macOS), built with `zig build`. Builds what wibo's own `CMakeLists.txt`
builds, at the version pinned in `build.zig.zon` (1.2.0), with nothing but Zig.

```
zig build                      # zig-out/bin/wibo
zig build run -- PROGRAM.exe   # run a Windows program
zig build test                 # wibo's own tests, run under it
```

As a dependency:

```zig
const wibo = b.dependency("wibo", .{ .target = ..., .optimize = .ReleaseFast }).artifact("wibo");
```

Options:

- `-Dwine-dlls=false`: leave out the Wine C runtime DLLs wibo embeds (msvcrt, ucrtbase, ...),
  downloaded from [encounter/winedll](https://github.com/encounter/winedll) at the release
  wibo pins. Programs with their C runtime linked in (like `d3dcompiler_47.dll`) don't need
  them.

## Where it runs

wibo runs Windows' 32-bit x86 code directly on the CPU, so it runs on machines that run x86
code: Linux on x86 or x86_64 (the default target, `x86-linux-musl`, is wibo's fast path and
static, as its releases are; `x86_64-linux` is its 64-bit host build), and macOS on x86_64
(Apple Silicon through Rosetta), which this build doesn't do yet.

## Tests

`zig build test` runs wibo's fixture tests (its `test/*.c`: threads, TLS, files, pipes,
DLLs, ...): built by zig for `x86-windows-gnu` (upstream uses a mingw cross compiler), each run
under wibo, expected to exit 0. Where wibo can't run, they're built but not run. CI builds on
Windows, macOS and Linux, and runs them on Linux for both host builds.

## Differences from wibo's CMake build

- **Trampolines.** wibo generates an assembly thunk for every function of every DLL it
  implements, with a Python script driving libclang (`tools/gen_trampolines.py`). Here a Zig
  port of it (`tools/trampolines.zig`) runs in the build, on what zig's own clang says about
  wibo's headers: `zig c++ -E`, then `-cc1` dumps of the AST (JSON, and text for the
  annotation strings JSON leaves out) and record layouts. Its output is byte-identical to the
  Python script's, for x86 and x86_64.
- **Left out:** liburing (off by default upstream too).
- **`-fno-sanitize=alignment,enum` for wibo's sources.** Guest code passes what it likes:
  pointers to 8-byte values that are only 4-byte aligned, as 32-bit Windows does (e.g.
  `QueryPerformanceCounter` from `d3dcompiler_47.dll`'s `DllMain`), and enum values a function
  should reject (wibo's tests do). zig's debug builds (UBSan) would trap on both; upstream
  builds with gcc and no sanitizers.
- **mimalloc's version banner** gets constant `__DATE__`/`__TIME__`, so the build is
  reproducible, and its misaligned-atomic warning (64-bit statistics, 4-byte aligned on x86)
  is off; release builds would otherwise fail on both.
- **`version_info.h`** is written by the build (CMake's `configure_file` of
  `src/version_info.h.in`).
- **The Wine DLLs** are fetched by [zig-fetch](https://github.com/marler8997/zig-fetch) (URL and
  sha256, as wibo's CMake pins them): zig's package fetcher only takes archives.
- **Linked at `0x70000000`, not position independent**, as upstream: the guest's address space
  is below.
