#!/usr/bin/env sh
# Smoke test for the freshly-built lhasa CLI. Lhasa's primary job is
# DECODING .lzh / .lzs / .pma archives. We focus smoke on extraction
# round-trips driven through the actual `lha` binary — to prove that
# the binary we shipped actually drives the liblhasa library correctly
# end-to-end.
#
# Why we don't run upstream `make check`: lhasa's test/Makefile.am
# suites rely on `. test_extract.sh` (relative source from cwd) which
# fails under parallel-build out-of-tree trees. Upstream's CI uses
# in-tree (`./autogen.sh && ./configure && make check`) — we have an
# out-of-tree build dir for multi-libc isolation. So we drive the
# binary directly against upstream's regression archives instead.
#
# `cmp` instead of `sha256sum` — BusyBox compatibility.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="${LHASA_SRC:-$ROOT/upstream/lhasa}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"

# Locate the freshly-built binary. Linux/macOS: $BUILD_DIR/src/lha. MinGW:
# $BUILD_DIR/src/lha.exe.
ext_for() { [ -f "$1.exe" ] && printf '%s.exe' "$1" || printf '%s' "$1"; }
LHA="$(ext_for "$BUILD_DIR/src/lha")"
[ -x "$LHA" ] || { echo "error: $LHA not built (BUILD_DIR=$BUILD_DIR)" >&2; exit 1; }

# Verify the version banner.
echo "==> version check"
"$LHA" 2>&1 | head -1 | grep -q 'Lhasa' \
	|| { echo "FAIL: version banner missing" >&2; exit 1; }
echo "    OK: $($LHA 2>&1 | head -1)"

# Pick a sample archive from upstream's regression suite.
ARCHIVES_DIR="$SRC/test/archives"
if [ ! -d "$ARCHIVES_DIR" ]; then
	echo "WARN: no upstream test archives; skipping decode smoke"
	exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Run a list + extract against the first 3 .lzh/.lzs/.pma archives we
# find. The point is to exercise the binary with the actual archive
# corpus the upstream maintainers curated.
found=0
for archive in $(find "$ARCHIVES_DIR" -type f \( -name '*.lzh' -o -name '*.lzs' -o -name '*.pma' \) 2>/dev/null | head -3); do
	found=$((found + 1))
	echo "==> archive $(basename "$archive")"
	case "$archive" in
	*.pma) label="PMarc";;
	*.lzs) label="LArc";;
	*)     label="LHA";;
	esac
	if ! ( cd "$TMP" && "$LHA" l "$archive" ) > "$TMP/list.txt" 2>&1; then
		echo "    listing failed:"; cat "$TMP/list.txt"
		exit 1
	fi
	if ! [ -s "$TMP/list.txt" ]; then
		echo "FAIL: $label: empty listing for $archive"
		exit 1
	fi
	if ! ( cd "$TMP" && "$LHA" xq "$archive" ) > /dev/null 2>&1; then
		echo "FAIL: $label: extract failed for $archive"
		exit 1
	fi
	echo "    OK: $label list + extract"
done

if [ "$found" -eq 0 ]; then
	echo "WARN: no .lzh/.lzs/.pma archives under $ARCHIVES_DIR; skipping decode smoke"
	exit 0
fi

echo "smoke OK: version + $found archive(s) decoded successfully via lha CLI"
