#!/usr/bin/env sh
# Build lhasa as a static, self-contained binary. Linux gnu + macOS + MinGW.
# Out-of-tree build into BUILD_DIR (default ./build) — leaves upstream/
# untouched so musl alpine + host glibc builds don't fight over state.
#
# Used by:
#   - .github/workflows/build-and-test.yml + release.yml on:
#       macos-14          (host arch = aarch64-macos; cross to x86_64 too)
#       windows-latest    (MSYS2/mingw64 x86_64)
#   - Local development on any POSIX host.
#
# Cross-compile: set LHASA_TARGET_ARCH + LHASA_TARGET_OS (or LHASA_TRIPLET)
# + LHASA_OS_HINT (darwin | windows). The script exports CC/CFLAGS/LDFLAGS
# and tells autotools --host=<triplet>. macOS uses clang -arch; MinGW uses
# the cross-toolchain named aarch64-w64-mingw32-gcc.
#
# Lhasa produces TWO artifacts: bin/lha (CLI, named lha to mirror the
# original LHa CLI), and lib/liblhasa.la (libtool — becomes static .a
# when --disable-shared is passed at configure time). We only ship the
# CLI in the release archive; the library stays available in-tree for
# embedders via a separate future channel.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="${LHASA_SRC:-$ROOT/upstream/lhasa}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"

[ -f "$SRC/configure.ac" ] \
	|| { echo "error: $SRC/configure.ac not found" >&2; exit 1; }
command -v autoreconf >/dev/null 2>&1 \
	|| { echo "error: autoreconf not found in PATH (install autoconf + automake + libtool)" >&2; exit 1; }

JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.nproc 2>/dev/null || echo 4)"

# Configure args.
#   --disable-dependency-tracking   (one-shot CI build, no dep graph)
#   --disable-shared               (build a libtool static archive only;
#                                    the lha CLI links statically)
#   --disable-silent-rules          (so `make` logs each step — CI shows it)
CONFIGURE_ARGS="--disable-dependency-tracking --disable-shared --disable-silent-rules"

# Cross-compile: LHASA_TARGET_ARCH + LHASA_TARGET_OS, etc.
HOST_ARCH="$(uname -m 2>/dev/null || echo unknown)"
TARGET_ARCH="${LHASA_TARGET_ARCH:-$HOST_ARCH}"
TRIPLET="${LHASA_TRIPLET:-}"
if [ -n "${LHASA_TARGET_OS:-}" ]; then
	TRIPLET="${TRIPLET:-${LHASA_TARGET_ARCH}-${LHASA_TARGET_OS}}"
fi
if [ "$TARGET_ARCH" != "$HOST_ARCH" ] || [ -n "${LHASA_TARGET_OS:-}" ]; then
	[ -z "$TRIPLET" ] && TRIPLET="$TARGET_ARCH"
	case "${LHASA_OS_HINT:-}" in
	darwin)
		# Apple SDK is shared between arches; clang auto-discovers via xcrun.
		export CC=clang
		export CFLAGS="-arch $TARGET_ARCH -O2"
		export LDFLAGS="-arch $TARGET_ARCH"
		;;
	windows)
		# MinGW cross-toolchain (e.g. aarch64-w64-mingw32-gcc from msys2).
		export CC="${TARGET_ARCH}-w64-mingw32-gcc"
		export CXX="${TARGET_ARCH}-w64-mingw32-g++"
		;;
	*)
		# Generic clang fallback.
		export CC=clang
		export CFLAGS="-arch $TARGET_ARCH -O2"
		export LDFLAGS="-arch $TARGET_ARCH"
		;;
	esac
	CONFIGURE_ARGS="$CONFIGURE_ARGS --host=$TRIPLET"
	[ -n "${LHASA_BUILD_TRIPLET:-}" ] && CONFIGURE_ARGS="$CONFIGURE_ARGS --build=$LHASA_BUILD_TRIPLET"
	echo "==> cross-compile: host=$HOST_ARCH → target=$TARGET_ARCH ($TRIPLET)"
fi

# Optional escape hatch — CI flows don't set this; downstream can.
[ -n "${LHASA_EXTRA_CONFIGURE_ARGS:-}" ] && CONFIGURE_ARGS="$CONFIGURE_ARGS $LHASA_EXTRA_CONFIGURE_ARGS"

# Clean any prior in-tree state left by a previous build — otherwise
# `configure` rejects the out-of-tree run with "source directory already
# configured". Idempotent on fresh checkouts (Makefile absent → no-op).
echo "==> distclean (in-tree, idempotent)"
( cd "$SRC" && [ -f Makefile ] && make distclean >/dev/null 2>&1 ) || true

echo "==> autoreconf -is"
( cd "$SRC" && autoreconf -is )

echo "==> configure (out-of-tree: $BUILD_DIR)"
mkdir -p "$BUILD_DIR"
( cd "$BUILD_DIR" && "$SRC/configure" --srcdir="$SRC" $CONFIGURE_ARGS )

echo "==> make -C $BUILD_DIR -j$JOBS"
( cd "$BUILD_DIR" && make -j"$JOBS" )

echo "==> built:"
ext_for() { [ -f "$1.exe" ] && printf '%s.exe' "$1" || printf '%s' "$1"; }
ls -l "$(ext_for "$BUILD_DIR/src/lha")" \
	|| { echo "error: lha binary not found under $BUILD_DIR/src/" >&2; exit 1; }
