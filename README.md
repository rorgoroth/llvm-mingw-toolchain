

# llvm-mingw

*Note: This is only tested and supported on Alpine Linux.*

A from-source build of a Clang/LLVM-based cross-compiler toolchain targeting
`x86_64-w64-mingw32` (Windows, UCRT), with `lld`, `libc++`, `libunwind`, and
compiler-rt built as part of the toolchain rather than relying on GCC.

`build.sh` builds LLVM/clang/lld, the mingw-w64 headers/CRT/import libraries
(plus `gendef` and `widl`), compiler-rt builtins, libc++/libc++abi/libunwind
and winpthreads, then packages the result into a self-contained
`llvm-x86_64-w64-mingw32` toolchain archive. Sanitizers, the profiling runtime,
XRay, libFuzzer and OpenMP are not built.

This project is a rewrite of [mstorsjo/llvm-mingw](https://github.com/mstorsjo/llvm-mingw),
trimmed down to a single architecture/target configuration and intended for
use with [rorgoroth/mingw-cmake-env](https://github.com/rorgoroth/mingw-cmake-env)

## Building

```sh
./build.sh
```

Requires `git`, `cmake`, `ninja`, `clang`/`clang++`, `lld`, `patch`, `python3`,
`make`, `zstd` and `coreutils`.
Output is written to `llvm-x86_64-w64-mingw32/` and packaged as `<version>.tar.zst`
in the repository root.

Re-running keeps the `llvm-project/` and `mingw-w64/` source and build trees so
rebuilds are incremental; they are discarded automatically when `LLVM_VERSION`,
`MINGW_W64_VERSION` or `musl_stack_size.patch` change.
