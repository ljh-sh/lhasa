#!/usr/bin/env sh
# Stage the built lhasa into a self-contained dist archive. Linux + macOS.
#   TARGET    e.g. x86_64-linux-musl | aarch64-linux-musl | aarch64-macos
#   BUILD_DIR (default $ROOT/build)
#   LHASA_SRC (default $ROOT/upstream/lhasa — for the man page)
#   DIST      (default $ROOT/dist)
#
# Stage layout inside dist/lhasa-$TARGET/:
#   bin/lha          (the CLI binary, +x)
#   man/man1/lha.1   (the man page, source roff)
#   README.md        (link to ljh-sh/lhasa)
#
# Output: dist/lhasa-$TARGET.tar.gz + .sha256 (basename-keyed for portability).
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
LHASA_SRC="${LHASA_SRC:-$ROOT/upstream/lhasa}"
DIST="${DIST:-$ROOT/dist}"
TARGET="${TARGET:?set TARGET, e.g. x86_64-linux-musl}"

ext_for() { [ -f "$1.exe" ] && printf '%s.exe' "$1" || printf '%s' "$1"; }
BIN="$(ext_for "$BUILD_DIR/src/lha")"
[ -x "$BIN" ] || { echo "error: $BIN not built (out-of-tree BUILD_DIR=$BUILD_DIR)" >&2; exit 1; }

# Man page lives under upstream/lhasa/doc/lha.1 (upstream puts docs
# there, not under man/ — different from jca02266/lha).
MAN_SRC="$LHASA_SRC/doc/lha.1"
[ -f "$MAN_SRC" ] || { echo "error: $MAN_SRC not found" >&2; exit 1; }

STAGE="$DIST/lhasa-$TARGET"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/man/man1"

cp "$BIN" "$STAGE/bin/lha"
chmod +x "$STAGE/bin/lha"
cp "$MAN_SRC" "$STAGE/man/man1/lha.1"

# A tiny README so the archive is self-explanatory.
cat > "$STAGE/README.md" <<'EOF'
# lhasa — single-binary release

Self-contained archive from https://github.com/ljh-sh/lhasa (release tag).
The wrapper LICENSE and NOTICE live there; the `lha` binary carries the
upstream ISC license from Simon Howard — see `upstream/lhasa/COPYING.md`
in the source repo or https://github.com/fragglet/lhasa.

The `lha` binary name is intentional: lhasa ships an interface-
compatible `lha` replacement for non-free upstream LHa for UNIX.
After install:

    $ lha --version
    LHa for Unix (lhasa) 0.6.0

Install (optional, manual):

    sudo install -m 0755 bin/lha /usr/local/bin/lha
    sudo install -m 0644 man/man1/lha.1 /usr/local/share/man/man1/

Then:  man lha
EOF

# Tar archive — keyed basename so downstream users can verify from any cwd.
ARCHIVE="$DIST/lhasa-$TARGET.tar.gz"
( cd "$DIST" && tar czf "$ARCHIVE" "$(basename "$STAGE")" )

# SHA256 — basename-only so `sha256sum -c FILE.sha256` works from any
# cwd. Prefer coreutils sha256sum, then macOS shasum, then OpenSSL.
if   command -v sha256sum >/dev/null 2>&1; then
	HASH_CMD='sha256sum'
elif command -v shasum     >/dev/null 2>&1; then
	HASH_CMD='shasum -a 256'
else
	HASH_CMD='openssl dgst -sha256 -r'
fi
( cd "$DIST" && $HASH_CMD "lhasa-$TARGET.tar.gz" \
	| awk '{printf "%s  lhasa-'"$TARGET"'.tar.gz\n", $1}' ) > "$ARCHIVE.sha256"

echo "==> $ARCHIVE"
echo "==> $ARCHIVE.sha256"
