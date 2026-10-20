#!/bin/sh
#
# Copyright (c) 2018 Martin Storsjo
#
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

# Find the directory the real script lives in, following symlinks. This runs
# on every compiler invocation, so avoid spawning dirname/basename/pwd
# subshells; readlink is only run once per symlink hop.
self="$0"
while [ -L "$self" ]; do
    link="$(readlink "$self")"
    case $link in
    /*) self="$link" ;;
    *)
        case $self in
        */*) self="${self%/*}/$link" ;;
        *) self="$link" ;;
        esac
        ;;
    esac
done
case $self in
*/*) DIR="${self%/*}" ;;
*) DIR=. ;;
esac
# Keep it absolute, as callers may use a relative path to the wrapper.
case $DIR in
/*) ;;
*) DIR="$PWD/$DIR" ;;
esac
BASENAME="${0##*/}"
TARGET="${BASENAME%-*}"
EXE="${BASENAME##*-}"
DEFAULT_TARGET=x86_64-w64-mingw32
if [ "$TARGET" = "$BASENAME" ]; then
    TARGET=$DEFAULT_TARGET
fi

# Check if trying to compile Ada; if we try to do this, invoking clang
# would end up invoking <triplet>-gcc with the same arguments, which ends
# up in an infinite recursion.
case "$*" in
*-x\ ada*)
    echo "Ada is not supported" >&2
    exit 1
    ;;
*)
    ;;
esac

# Allow setting e.g. CCACHE=1 to wrap all building in ccache.
if [ -n "$CCACHE" ]; then
    CCACHE=ccache
fi

CLANG="$DIR/clang"
FLAGS=""
FLAGS="$FLAGS --start-no-unused-arguments"
case $EXE in
clang++|g++|c++)
    FLAGS="$FLAGS --driver-mode=g++"
    ;;
c99)
    FLAGS="$FLAGS -std=c99"
    ;;
c11)
    FLAGS="$FLAGS -std=c11"
    ;;
esac
FLAGS="$FLAGS -target $TARGET"
FLAGS="$FLAGS --end-no-unused-arguments"

# exec: no lingering shell, and signals/exit status reach clang directly.
exec $CCACHE "$CLANG" $FLAGS "$@"
