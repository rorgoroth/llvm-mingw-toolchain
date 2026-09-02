#!/bin/sh

set -e

# ===========================================================================
# Fixed configuration
# ===========================================================================
cd "$(dirname "$0")"
REPO_ROOT="$(pwd)"

CC=clang
CXX=clang++
LLVM_REPOSITORY="https://github.com/llvm/llvm-project.git"
LLVM_VERSION="23.1.0"
LLVM_TAG="llvmorg-$LLVM_VERSION"
MINGW_W64_VERSION="b0c3cce6a14965dbac1713e619c811a149044dcd"
PATCH_FILE="$REPO_ROOT/musl_stack_size.patch"
ARCH="x86_64"
TARGET_OSES="mingw32 mingw32uwp"
DEFAULT_WIN32_WINNT="0x0A00"
DEFAULT_MSVCRT="ucrt"
DEST="llvm-x86_64-w64-mingw32"

: ${CORES:=$(nproc 2>/dev/null)}
: ${CORES:=$(sysctl -n hw.ncpu 2>/dev/null)}
: ${CORES:=4}

for dep in git cmake clang ninja zstd coreutils; do
    if ! command -v $dep >/dev/null; then
        echo "$dep not installed. Please install it and retry" 1>&2
        exit 1
    fi
done

git clean -xdf

echo "=== Removing previous build output ==="
rm -rf "$DEST"
rm -f "$LLVM_VERSION.tar.zst"

mkdir -p "$DEST"

PREFIX="$(cd "$DEST" && pwd)"


# ===========================================================================
# Stage 1: build clang/llvm
# ===========================================================================
echo "=== [1/10] Building LLVM/clang/lld ==="

if [ ! -d llvm-project ]; then
    git clone --depth 1 --no-tags --branch "$LLVM_TAG" "$LLVM_REPOSITORY" llvm-project
    (cd llvm-project && patch -p1 < "$PATCH_FILE")
fi

LLVM_BUILDDIR="build"
mkdir -p "llvm-project/llvm/$LLVM_BUILDDIR"
(
    cd "llvm-project/llvm/$LLVM_BUILDDIR"
    rm -rf CMake*
    cmake \
        -G Ninja \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DLLVM_USE_LINKER=lld \
        -DLLVM_ENABLE_LTO=thin \
        -DLLVM_ENABLE_ASSERTIONS=OFF \
        -DLLVM_ENABLE_PROJECTS="clang;lld" \
        -DLLVM_TARGETS_TO_BUILD="X86" \
        -DLLVM_INSTALL_TOOLCHAIN_ONLY=ON \
        -DLLVM_LINK_LLVM_DYLIB=ON \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_DOCS=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_ENABLE_Z3_SOLVER=OFF \
        -DLLVM_ENABLE_LIBXML2=OFF \
        -DLLVM_ENABLE_ZLIB=OFF \
        -DLLVM_ENABLE_WARNINGS=OFF \
		-DLLVM_TOOLCHAIN_TOOLS="llvm-ar;llvm-ranlib;llvm-objdump;llvm-rc;llvm-cvtres;llvm-nm;llvm-strings;llvm-readobj;llvm-dlltool;llvm-pdbutil;llvm-objcopy;llvm-strip;llvm-cov;llvm-profdata;llvm-addr2line;llvm-symbolizer;llvm-windres;llvm-ml;llvm-readelf;llvm-size;llvm-cxxfilt;llvm-lib" \
        ..
    cmake --build .
    cmake --install . --strip
)
cp llvm-project/LICENSE.TXT "$PREFIX"


# ===========================================================================
# Stage 2: strip llvm
# ===========================================================================
echo "=== [2/10] Stripping unwanted LLVM install files ==="

(
    cd "$PREFIX/bin"
    for i in amdgpu-arch bugpoint c-index-test clang-* clangd clangd-* darwin-debug diagtool dsymutil find-all-symbols git-clang-format hmaptool ld64.lld* llc lldb-* lli llvm-* modularize nvptx-arch obj2yaml offload-arch opt pp-trace sancov sanstats scan-build scan-view split-file verify-uselistorder wasm-ld yaml2* libclang.dll *LTO.dll *Remarks.dll *.bat; do
        basename=$i
        case $basename in
        *.sh) ;;
        clang++|clang-*.*|clang-cpp) ;;
        clang-format|git-clang-format) ;;
        clangd) ;;
        clang-scan-deps) ;;
        clang-tidy) ;;
        clang-target-wrapper*|clang-scan-deps-wrapper*) ;;
        clang-*)
            suffix="${basename#*-}"
            if [ "$(echo $suffix | tr -d '[0-9]')" != "" ]; then
                rm -f $i
            fi
            ;;
        llvm-ar|llvm-cvtres|llvm-dlltool|llvm-nm|llvm-objdump|llvm-ranlib|llvm-rc|llvm-readobj|llvm-strings|llvm-pdbutil|llvm-objcopy|llvm-strip|llvm-cov|llvm-profdata|llvm-addr2line|llvm-symbolizer|llvm-wrapper|llvm-windres|llvm-ml|llvm-readelf|llvm-size|llvm-cxxfilt|llvm-lib) ;;
        ld64.lld|wasm-ld)
            [ -e $i ] && rm $i
            ;;
        lldb|lldb-server|lldb-argdumper|lldb-instr|lldb-mi|lldb-vscode|lldb-dap) ;;
        *)
            if [ -f $i ]; then
                rm $i
            elif [ -L $i ] && [ ! -e $(readlink $i) ]; then
                rm $i
            fi
            ;;
        esac
    done
)

rm -rf "$PREFIX/libexec"

(
    cd "$PREFIX/share/clang"
    for i in *; do
        case $i in
        clang-format*) ;;
        *) rm -rf $i ;;
        esac
    done
)

rm -rf "$PREFIX/share/opt-viewer" "$PREFIX/share/scan-build" "$PREFIX/share/scan-view"
rm -rf "$PREFIX/share/man/man1/scan-build*"
rm -rf "$PREFIX/include/clang" "$PREFIX/include/clang-c" "$PREFIX/include/clang-tidy" "$PREFIX/include/lld" "$PREFIX/include/llvm" "$PREFIX/include/llvm-c" "$PREFIX/include/lldb"

(
    cd "$PREFIX/lib"
    rm -f *.dll.a
    rm -f lib*.a
    for i in *.so* *.dylib* cmake; do
        case $i in
        liblldb*|libclang-cpp*|libLLVM*) ;;
        *) rm -rf $i ;;
        esac
    done
)

# ===========================================================================
# Stage 3: install wrappers
# ===========================================================================
echo "=== [3/10] Installing target wrapper scripts/binaries ==="

mkdir -p "$PREFIX/bin"
cp wrappers/*-wrapper.sh "$PREFIX/bin"
cp wrappers/mingw32-common.cfg "$PREFIX/bin"
cp "wrappers/$ARCH-w64-windows-gnu.cfg" "$PREFIX/bin"
ln -sf "$ARCH-w64-windows-gnu.cfg" "$PREFIX/bin/$ARCH-pc-windows-gnu.cfg"

$CC wrappers/clang-target-wrapper.c -o "$PREFIX/bin/clang-target-wrapper" -O2 -Wl,-s
$CC wrappers/clang-scan-deps-wrapper.c -o "$PREFIX/bin/clang-scan-deps-wrapper" -O2 -Wl,-s
$CC wrappers/llvm-wrapper.c -o "$PREFIX/bin/llvm-wrapper" -O2 -Wl,-s

(
    cd "$PREFIX/bin"
    for target_os in $TARGET_OSES; do
        for exec in clang clang++ gcc g++ c++ as; do
            ln -sf clang-target-wrapper.sh $ARCH-w64-$target_os-$exec
        done
        ln -sf clang-scan-deps $ARCH-w64-$target_os-clang-scan-deps

        for exec in addr2line ar ranlib nm objcopy readelf size strings strip llvm-ar llvm-ranlib; do
            case $exec in
            llvm-*) link_target=$exec ;;
            *) link_target=llvm-$exec ;;
            esac
            ln -sf $link_target $ARCH-w64-$target_os-$exec || true
        done

        ln -sf llvm-windres $ARCH-w64-$target_os-windres
        ln -sf llvm-dlltool $ARCH-w64-$target_os-dlltool

        for exec in ld objdump; do
            ln -sf $exec-wrapper.sh $ARCH-w64-$target_os-$exec
        done
    done
)


# ===========================================================================
# Stage 4: build mingw-w64 tools
# ===========================================================================
echo "=== [4/10] Building mingw-w64 host tools (gendef, widl) ==="

if [ ! -d mingw-w64 ]; then
    git clone https://github.com/mingw-w64/mingw-w64
    (cd mingw-w64 && git checkout "$MINGW_W64_VERSION")
fi

MAKE=make
command -v gmake >/dev/null && MAKE=gmake

(
    cd mingw-w64/mingw-w64-tools/gendef
    mkdir -p build
    cd build
    ../configure --prefix="$PREFIX" --enable-silent-rules
    $MAKE -j$CORES
    $MAKE install-strip
    mkdir -p "$PREFIX/share/gendef"
    install -m644 ../COPYING "$PREFIX/share/gendef/COPYING.txt"
)
(
    cd mingw-w64/mingw-w64-tools/widl
    mkdir -p build
    cd build
    ../configure --prefix="$PREFIX" --target=$ARCH-w64-mingw32 \
        --with-widl-includedir="$PREFIX/generic-w64-mingw32/include" --enable-silent-rules
    $MAKE -j$CORES
    $MAKE install-strip
    mkdir -p "$PREFIX/share/widl"
    install -m644 ../../../COPYING "$PREFIX/share/widl/COPYING.txt"
)
(
    cd "$PREFIX/bin"
    for target_os in $TARGET_OSES; do
        [ "$target_os" = "mingw32" ] && continue
        ln -sf $ARCH-w64-mingw32-widl $ARCH-w64-$target_os-widl
    done
)

# ===========================================================================
# Stage 5: build mingw-w64 headers/CRT/import-libs
# ===========================================================================
echo "=== [5/10] Building mingw-w64 headers and CRT ==="

export PATH="$PREFIX/bin:$PATH"
unset CC

(
    cd mingw-w64/mingw-w64-headers
    mkdir -p build
    cd build
    ../configure --prefix="$PREFIX/generic-w64-mingw32" \
        --enable-idl --with-default-win32-winnt=$DEFAULT_WIN32_WINNT --with-default-msvcrt=$DEFAULT_MSVCRT \
        INSTALL="install -C"
    $MAKE install
)
mkdir -p "$PREFIX/$ARCH-w64-mingw32"
[ -e "$PREFIX/$ARCH-w64-mingw32/include" ] || ln -sfn ../generic-w64-mingw32/include "$PREFIX/$ARCH-w64-mingw32/include"

(
    cd mingw-w64/mingw-w64-crt
    mkdir -p build-$ARCH
    cd build-$ARCH
    ../configure --host=$ARCH-w64-mingw32 --prefix="$PREFIX/$ARCH-w64-mingw32" \
        --disable-lib32 --enable-lib64 --with-default-msvcrt=$DEFAULT_MSVCRT --enable-silent-rules
    $MAKE -j$CORES
    $MAKE install
)

if [ ! -f "$PREFIX/$ARCH-w64-mingw32/lib/libssp.a" ]; then
    llvm-ar rcs "$PREFIX/$ARCH-w64-mingw32/lib/libssp.a"
    llvm-ar rcs "$PREFIX/$ARCH-w64-mingw32/lib/libssp_nonshared.a"
fi
if [ ! -f "$PREFIX/$ARCH-w64-mingw32/lib/libstdc++.a" ]; then
    llvm-ar rcs "$PREFIX/$ARCH-w64-mingw32/lib/libstdc++.a"
fi
mkdir -p "$PREFIX/$ARCH-w64-mingw32/share/mingw32"
(
    cd mingw-w64
    for f in COPYING COPYING.MinGW-w64/COPYING.MinGW-w64.txt COPYING.MinGW-w64-runtime/COPYING.MinGW-w64-runtime.txt; do
        install -m644 "$f" "$PREFIX/$ARCH-w64-mingw32/share/mingw32"
    done
)


# ===========================================================================
# Stage 6: build-compiler-rt builtins
# ===========================================================================
echo "=== [6/10] Building compiler-rt builtins ==="

CLANG_RESOURCE_DIR="$("$PREFIX/bin/clang" --print-resource-dir)"

cat <<EOF > is-ucrt.c
#include <corecrt.h>
#if !defined(_UCRT)
#error not ucrt
#endif
EOF
IS_UCRT=""
if $ARCH-w64-mingw32-gcc -E is-ucrt.c > /dev/null 2>&1; then
    IS_UCRT=1
fi
rm -f is-ucrt.c

build_compiler_rt_arch() {
    src_dir="$1"
    build_suffix="$2"
    build_builtins="$3"

    INSTALL_PREFIX="$CLANG_RESOURCE_DIR"
    STAGE_TMP=""
    if [ -h "$CLANG_RESOURCE_DIR/include" ]; then
        STAGE_TMP="$(mktemp -d)"
        INSTALL_PREFIX="$STAGE_TMP/install"
    fi

    (
        cd llvm-project/compiler-rt
        mkdir -p build-$ARCH$build_suffix
        cd build-$ARCH$build_suffix
        rm -rf CMake*
        cmake \
            -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="$CLANG_RESOURCE_DIR" \
            -DCMAKE_C_COMPILER=$ARCH-w64-mingw32-clang \
            -DCMAKE_CXX_COMPILER=$ARCH-w64-mingw32-clang++ \
            -DCMAKE_SYSTEM_NAME=Windows \
            -DCMAKE_AR="$PREFIX/bin/llvm-ar" \
            -DCMAKE_RANLIB="$PREFIX/bin/llvm-ranlib" \
            -DCMAKE_C_COMPILER_WORKS=1 \
            -DCMAKE_CXX_COMPILER_WORKS=1 \
            -DCMAKE_C_COMPILER_TARGET=$ARCH-w64-windows-gnu \
            -DCOMPILER_RT_DEFAULT_TARGET_ONLY=TRUE \
            -DCOMPILER_RT_USE_BUILTINS_LIBRARY=TRUE \
            -DCOMPILER_RT_BUILD_BUILTINS=$build_builtins \
            -DCOMPILER_RT_EXCLUDE_ATOMIC_BUILTIN=FALSE \
            -DLLVM_CONFIG_PATH="" \
            -DCMAKE_FIND_ROOT_PATH="$PREFIX/$ARCH-w64-mingw32" \
            -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
            -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
            -DSANITIZER_CXX_ABI=libc++ \
            -DCMAKE_C_FLAGS_INIT="" \
            -DCMAKE_CXX_FLAGS_INIT="" \
            -DCMAKE_ASM_FLAGS_INIT="" \
            "$src_dir"
        cmake --build .
        cmake --install . --prefix "$INSTALL_PREFIX"
    )
    mkdir -p "$PREFIX/$ARCH-w64-mingw32/bin"

    if [ -n "$build_suffix" ]; then
        # sanitizers pass
        if [ -z "$IS_UCRT" ]; then
            rm -f "$INSTALL_PREFIX/lib/windows/libclang_rt.asan"*
        else
            mv "$INSTALL_PREFIX/lib/windows/"*.dll "$PREFIX/$ARCH-w64-mingw32/bin"
        fi
    fi

    if [ "$INSTALL_PREFIX" != "$CLANG_RESOURCE_DIR" ]; then
        rm -rf "$INSTALL_PREFIX/include"
        cp -r "$INSTALL_PREFIX/." "$CLANG_RESOURCE_DIR"
        rm -rf "$STAGE_TMP"
    fi
}
build_compiler_rt_arch "../lib/builtins" "" TRUE


# ===========================================================================
# Stage 7: build-libcxx
# ===========================================================================
echo "=== [7/10] Building libc++/libc++abi/libunwind ==="

(
    cd llvm-project/runtimes
    mkdir -p build-$ARCH
    cd build-$ARCH
    rm -rf CMake*
    cmake \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX/$ARCH-w64-mingw32" \
        -DCMAKE_C_COMPILER=$ARCH-w64-mingw32-clang \
        -DCMAKE_CXX_COMPILER=$ARCH-w64-mingw32-clang++ \
        -DCMAKE_CXX_COMPILER_TARGET=$ARCH-w64-windows-gnu \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_C_COMPILER_WORKS=TRUE \
        -DCMAKE_CXX_COMPILER_WORKS=TRUE \
        -DCMAKE_AR="$PREFIX/bin/llvm-ar" \
        -DCMAKE_RANLIB="$PREFIX/bin/llvm-ranlib" \
        -DLLVM_ENABLE_RUNTIMES="libunwind;libcxxabi;libcxx" \
        -DLIBUNWIND_USE_COMPILER_RT=TRUE \
        -DLIBUNWIND_ENABLE_SHARED=ON \
        -DLIBUNWIND_ENABLE_STATIC=ON \
        -DLIBCXX_USE_COMPILER_RT=ON \
        -DLIBCXX_ENABLE_SHARED=ON \
        -DLIBCXX_ENABLE_STATIC=ON \
        -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=TRUE \
        -DLIBCXX_CXX_ABI=libcxxabi \
        -DLIBCXX_LIBDIR_SUFFIX="" \
        -DLIBCXX_INCLUDE_TESTS=FALSE \
        -DLIBCXX_INSTALL_MODULES=ON \
        -DLIBCXX_INSTALL_MODULES_DIR="$PREFIX/share/libc++/v1" \
        -DLIBCXX_ENABLE_ABI_LINKER_SCRIPT=FALSE \
        -DLIBCXXABI_USE_COMPILER_RT=ON \
        -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
        -DLIBCXXABI_ENABLE_SHARED=OFF \
        -DLIBCXXABI_LIBDIR_SUFFIX="" \
        -DCMAKE_C_FLAGS_INIT="-D__USE_MINGW_ANSI_STDIO=1" \
        -DCMAKE_CXX_FLAGS_INIT="-D__USE_MINGW_ANSI_STDIO=1" \
        -DCMAKE_ASM_FLAGS_INIT="-D__USE_MINGW_ANSI_STDIO=1" \
        -DCMAKE_SHARED_LINKER_FLAGS="" \
        ..
    cmake --build .
    cmake --install .
)


# ===========================================================================
# Stage 8: build mingw-w64 libraries
# ===========================================================================
echo "=== [8/10] Building winpthreads ==="

(
    cd mingw-w64/mingw-w64-libraries/winpthreads
    mkdir -p build-$ARCH
    cd build-$ARCH
    arch_prefix="$PREFIX/$ARCH-w64-mingw32"
    ../configure --host=$ARCH-w64-mingw32 \
        --prefix="$arch_prefix" \
        --libdir="$arch_prefix/lib" \
        --disable-shared \
        --enable-static \
        --enable-silent-rules \
        CFLAGS="-g -O2" \
        CXXFLAGS="-g -O2" \
        LDFLAGS=""
    $MAKE -j$CORES
    $MAKE install
)
mkdir -p "$PREFIX/$ARCH-w64-mingw32/share/mingw32"
install -m644 mingw-w64/mingw-w64-libraries/winpthreads/COPYING \
    "$PREFIX/$ARCH-w64-mingw32/share/mingw32/COPYING.winpthreads.txt"


# ===========================================================================
# Stage 9: build-compiler-rt sanitizers
# ===========================================================================
echo "=== [9/10] Building compiler-rt sanitizers ==="
build_compiler_rt_arch ".." "-sanitizers" FALSE


# ===========================================================================
# Stage 10: build openmp
# ===========================================================================
echo "=== [10/10] Building OpenMP runtime ==="

(
    cd llvm-project/runtimes
    mkdir -p build-openmp-$ARCH
    cd build-openmp-$ARCH
    rm -rf CMake*
    cmake \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX/$ARCH-w64-mingw32" \
        -DCMAKE_C_COMPILER=$ARCH-w64-mingw32-clang \
        -DCMAKE_CXX_COMPILER=$ARCH-w64-mingw32-clang++ \
        -DCMAKE_RC_COMPILER=$ARCH-w64-mingw32-windres \
        -DCMAKE_ASM_MASM_COMPILER=llvm-ml \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_AR="$PREFIX/bin/llvm-ar" \
        -DCMAKE_RANLIB="$PREFIX/bin/llvm-ranlib" \
        -DLLVM_ENABLE_RUNTIMES="openmp" \
        -DLIBOMP_ENABLE_SHARED=TRUE \
        -DCMAKE_C_FLAGS_INIT="" \
        -DCMAKE_CXX_FLAGS_INIT="" \
        -DCMAKE_SHARED_LINKER_FLAGS="" \
        -DLIBOMP_ASMFLAGS=-m64 \
        ..
    cmake --build .
    cmake --install .
)
rm -f "$PREFIX/$ARCH-w64-mingw32/bin/"*iomp5md*
rm -f "$PREFIX/$ARCH-w64-mingw32/lib/"*iomp5md*


# ===========================================================================
# Final packaging
# ===========================================================================
echo "=== Packaging ==="

find "./$DEST" -name '*.dll.a' -print -delete
tar -c -I 'zstd -18 -T0' -f "$LLVM_VERSION.tar.zst" "$DEST"

echo "Done: $REPO_ROOT/$LLVM_VERSION.tar.zst"