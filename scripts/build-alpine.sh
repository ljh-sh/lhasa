#!/usr/bin/env sh
# Build lhasa as a true musl-static binary inside an Alpine container.
# Out-of-tree build into /w/build so host-side state (if any) never
# leaks in — `./configure` runs with --srcdir.
#
# CI invokes:
#   docker run --rm --platform linux/$ARCH -v "$PWD":/w -w /w \
#     alpine:3.20 sh -c 'apk add --no-cache bash >/dev/null && bash /w/scripts/build-alpine.sh'
#
# Alpine's musl + alpine's gcc → fully static lha binary that runs on
# Alpine AND every glibc distro (Ubuntu/Debian/Fedora/Arch).
set -eu

echo "==> apk add: build deps (musl-native toolchain)"
apk add --no-cache \
	build-base \
	autoconf \
	automake \
	libtool \
	linux-headers \
	bash

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"

echo "==> autoreconf -is (out-of-tree bootstrapping next)"
( cd "$ROOT/upstream/lhasa" && autoreconf -is )

# make distclean is a no-op on a fresh checkout, but defensive: if a
# prior host build left Makefile/config.h in the source tree (e.g. CI
# reused a cached checkout), drop it so autoreconf regenerates cleanly.
( cd "$ROOT/upstream/lhasa" \
	&& find . -maxdepth 2 -name Makefile -delete -o -name 'config.h' -delete -o -name 'config.status' -delete 2>/dev/null || true )

mkdir -p "$BUILD_DIR"

echo "==> configure (musl-static + minimal)"
( cd "$BUILD_DIR" && "$ROOT/upstream/lhasa/configure" \
		--srcdir="$ROOT/upstream/lhasa" \
		--disable-dependency-tracking \
		--disable-silent-rules \
		--disable-shared )

echo "==> make"
( cd "$BUILD_DIR" && make -j"$(getconf _NPROCESSORS_ONLN)" )

echo "==> built:"
ls -l "$BUILD_DIR/src/lha"
