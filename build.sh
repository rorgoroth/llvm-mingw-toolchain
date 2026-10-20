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
LLVM_VERSION="23.1.4"
LLVM_TAG="llvmorg-$LLVM_VERSION"
MINGW_W64_VERSION="344407dfc63fc495db714d0f79d291e99b85730e"
# https://github.com/mingw-w64/mingw-w64/commits/master/
PATCH_FILE="$REPO_ROOT/musl_stack_size.patch"
ARCH="x86_64"
DEFAULT_WIN32_WINNT="0x0A00"
DEFAULT_MSVCRT="ucrt"
DEST="llvm-x86_64-w64-mingw32"

: "${CORES:=$(nproc 2>/dev/null)}"
: "${CORES:=4}"

for dep in git cmake clang ninja ld.lld patch python3 zstd coreutils; do
    if ! command -v "$dep" >/dev/null; then
        echo "$dep not found. Please install it and retry" 1>&2
        exit 1
    fi
done

git clean -xdf

echo "=== Removing previous build output ==="
rm -rf "$DEST"
rm -f "$LLVM_VERSION.tar.zst"

mkdir -p "$DEST"

# llvm stamp file
SRC_STAMP="$LLVM_TAG $MINGW_W64_VERSION $(cksum < "$PATCH_FILE")"
if [ "$(cat llvm-project/.src-stamp 2>/dev/null)" != "$SRC_STAMP" ]; then
    rm -rf llvm-project mingw-w64
fi

PREFIX="$(cd "$DEST" && pwd)"


# ===========================================================================
# Stage 1: build clang/llvm
# ===========================================================================
echo "=== [1/8] Building LLVM/clang/lld ==="

if [ ! -d llvm-project ]; then
    git clone --depth 1 --no-tags --branch "$LLVM_TAG" "$LLVM_REPOSITORY" llvm-project
    (cd llvm-project && patch -p1 < "$PATCH_FILE")
    printf '%s\n' "$SRC_STAMP" > llvm-project/.src-stamp
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
        -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
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
        -DLLVM_TOOLCHAIN_TOOLS="llvm-ar;llvm-ranlib;llvm-objdump;llvm-rc;llvm-cvtres;llvm-nm;llvm-strings;llvm-readobj;llvm-dlltool;llvm-pdbutil;llvm-objcopy;llvm-strip;llvm-addr2line;llvm-symbolizer;llvm-windres;llvm-ml;llvm-readelf;llvm-size;llvm-cxxfilt;llvm-lib" \
        ..
    cmake --build .
    cmake --install . --strip
)
cp llvm-project/LICENSE.TXT "$PREFIX"


# ===========================================================================
# Stage 2: strip llvm
# ===========================================================================
echo "=== [2/8] Stripping unwanted LLVM install files ==="

(
    cd "$PREFIX/bin"
    for i in amdgpu-arch bugpoint c-index-test clang-* darwin-debug diagtool dsymutil find-all-symbols git-clang-format hmaptool ld64.lld* llc lli llvm-* modularize nvptx-arch obj2yaml offload-arch opt pp-trace sancov sanstats split-file verify-uselistorder wasm-ld yaml2*; do
        basename=$i
        case $basename in
        clang++|clang-*.*|clang-cpp) ;;
        clang-scan-deps) ;;
        clang-*)
            suffix="${basename#*-}"
            if [ "$(echo $suffix | tr -d '[0-9]')" != "" ]; then
                rm -f $i
            fi
            ;;
        llvm-ar|llvm-cvtres|llvm-dlltool|llvm-nm|llvm-objdump|llvm-ranlib|llvm-rc|llvm-readobj|llvm-strings|llvm-pdbutil|llvm-objcopy|llvm-strip|llvm-addr2line|llvm-symbolizer|llvm-windres|llvm-ml|llvm-readelf|llvm-size|llvm-cxxfilt|llvm-lib) ;;
        ld64.lld|wasm-ld)
            [ -e $i ] && rm $i
            ;;
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

rm -rf "$PREFIX/share/clang" "$PREFIX/share/opt-viewer"

rm -rf "$PREFIX/include/clang" "$PREFIX/include/clang-c" "$PREFIX/include/lld" "$PREFIX/include/llvm" "$PREFIX/include/llvm-c"

(
    cd "$PREFIX/lib"
    rm -f lib*.a
    for i in *.so* cmake; do
        case $i in
        libclang-cpp*|libLLVM*) ;;
        *) rm -rf $i ;;
        esac
    done
)

# ===========================================================================
# Stage 3: install wrappers
# ===========================================================================
echo "=== [3/8] Installing target wrapper scripts/binaries ==="

mkdir -p "$PREFIX/bin"
# install(1) sets the mode explicitly, so the result doesn't depend on the
# execute bits surviving in the checkout (zip/tarball copies lose them).
install -m755 wrappers/*-wrapper.sh "$PREFIX/bin"
install -m644 wrappers/mingw32-common.cfg "$PREFIX/bin"
install -m644 "wrappers/$ARCH-w64-windows-gnu.cfg" "$PREFIX/bin"
ln -sf "$ARCH-w64-windows-gnu.cfg" "$PREFIX/bin/$ARCH-pc-windows-gnu.cfg"

(
    cd "$PREFIX/bin"
    for exec in clang clang++ gcc g++ c++ as; do
        ln -sf clang-target-wrapper.sh $ARCH-w64-mingw32-$exec
    done
    ln -sf clang-scan-deps $ARCH-w64-mingw32-clang-scan-deps

    for exec in addr2line ar ranlib nm objcopy readelf size strings strip llvm-ar llvm-ranlib; do
        case $exec in
        llvm-*) link_target=$exec ;;
        *) link_target=llvm-$exec ;;
        esac
        ln -sf $link_target $ARCH-w64-mingw32-$exec || true
    done

    ln -sf llvm-windres $ARCH-w64-mingw32-windres
    ln -sf llvm-dlltool $ARCH-w64-mingw32-dlltool

    for exec in ld objdump; do
        ln -sf $exec-wrapper.sh $ARCH-w64-mingw32-$exec
    done
)


# ===========================================================================
# Stage 4: build mingw-w64 tools
# ===========================================================================
echo "=== [4/8] Building mingw-w64 host tools (gendef, widl) ==="

if [ ! -d mingw-w64 ]; then
    mkdir mingw-w64
    (
        cd mingw-w64
        git init -q .
        git remote add origin https://github.com/mingw-w64/mingw-w64
        git fetch --depth 1 origin "$MINGW_W64_VERSION"
        git checkout -q FETCH_HEAD
    )
fi

MAKE=make
command -v gmake >/dev/null && MAKE=gmake

(
    cd mingw-w64/mingw-w64-tools/gendef
    rm -rf build
    mkdir build
    cd build
    ../configure --prefix="$PREFIX" --enable-silent-rules
    $MAKE -j$CORES
    $MAKE install-strip
    mkdir -p "$PREFIX/share/gendef"
    install -m644 ../COPYING "$PREFIX/share/gendef/COPYING.txt"
)
(
    cd mingw-w64/mingw-w64-tools/widl
    rm -rf build
    mkdir build
    cd build
    ../configure --prefix="$PREFIX" --target=$ARCH-w64-mingw32 \
        --with-widl-includedir="$PREFIX/generic-w64-mingw32/include" --enable-silent-rules
    $MAKE -j$CORES
    $MAKE install-strip
    mkdir -p "$PREFIX/share/widl"
    install -m644 ../../../COPYING "$PREFIX/share/widl/COPYING.txt"
)

# ===========================================================================
# Stage 5: build mingw-w64 headers/CRT/import-libs
# ===========================================================================
echo "=== [5/8] Building mingw-w64 headers and CRT ==="

export PATH="$PREFIX/bin:$PATH"
unset CC

(
    cd mingw-w64/mingw-w64-headers
    rm -rf build
    mkdir build
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
    rm -rf build-$ARCH
    mkdir build-$ARCH
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
echo "=== [6/8] Building compiler-rt builtins ==="

CLANG_RESOURCE_DIR="$("$PREFIX/bin/clang" --print-resource-dir)"

build_compiler_rt_arch() {
    src_dir="$1"
    build_suffix="$2"
    build_builtins="$3"

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
            -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
            -DCOMPILER_RT_BUILD_XRAY=OFF \
            -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
            -DCOMPILER_RT_BUILD_MEMPROF=OFF \
            -DCOMPILER_RT_BUILD_ORC=OFF \
            -DCOMPILER_RT_BUILD_GWP_ASAN=OFF \
            -DCOMPILER_RT_BUILD_PROFILE=OFF \
            -DCMAKE_C_FLAGS_INIT="" \
            -DCMAKE_CXX_FLAGS_INIT="" \
            -DCMAKE_ASM_FLAGS_INIT="" \
            "$src_dir"
        cmake --build .
        cmake --install .
    )
    mkdir -p "$PREFIX/$ARCH-w64-mingw32/bin"
}
build_compiler_rt_arch "../lib/builtins" "" TRUE


# ===========================================================================
# Stage 7: build-libcxx
# ===========================================================================
echo "=== [7/8] Building libc++/libc++abi/libunwind ==="

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
        -DLIBUNWIND_ENABLE_SHARED=OFF \
        -DLIBUNWIND_ENABLE_STATIC=ON \
        -DLIBCXX_USE_COMPILER_RT=ON \
        -DLIBCXX_ENABLE_SHARED=OFF \
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
echo "=== [8/8] Building winpthreads ==="

(
    cd mingw-w64/mingw-w64-libraries/winpthreads
    rm -rf build-$ARCH
    mkdir build-$ARCH
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

# libtool archive: records the build-time install path and only misleads
# libtool-based projects (they prefer it over the .a).
rm -f "$PREFIX/$ARCH-w64-mingw32/lib/libwinpthread.la"
install -m644 mingw-w64/mingw-w64-libraries/winpthreads/COPYING \
    "$PREFIX/$ARCH-w64-mingw32/share/mingw32/COPYING.winpthreads.txt"

# ===========================================================================
# Final packaging
# ===========================================================================
echo "=== Packaging ==="

tar -c -I 'zstd -18 -T0' -f "$LLVM_VERSION.tar.zst" "$DEST"

echo "Done: $REPO_ROOT/$LLVM_VERSION.tar.zst"
