# lhasa — self-contained multi-platform builds of fragglet/lhasa

[Vendored](upstream/lhasa/) [fragglet/lhasa](https://github.com/fragglet/lhasa)
(an ISC-licensed LZH / LZS / PMarc decoder + libtool library, by
Simon Howard) with a native per-OS packaging layer that produces
**statically-linked, self-contained** binaries. No glibc /
applefile / zlib / libiconv to install on the target machine — just
download, extract, run.

This is a **distribution repo** (lhasa source + build/packaging
scripts + CI). See `NOTICE.md` for the upstream lhasa license terms
that apply to the binary.

The CLI binary name is intentionally `lha` (not `lhasa`): lhasa
ships an interface-compatible `lha` replacement for the original
LHa for UNIX command.

## Binary

Built into each release archive under `bin/`:

| binary | purpose |
|---|---|
| `lha` | the CLI — list / extract / print contents of `.lzh` archives |

The man page `lha(1)` is shipped under `man/man1/` in the same archive.

## Install

Each release publishes multi-architecture static binaries. The
fastest cross-platform one-line install uses x-cmd:

```bash
x eget ljh-sh/lhasa    # ~200 KB, zero deps, multi-arch static build
```

This installs the `lha` binary to `~/.local/bin/lha`. See the
README.md inside the archive for manual install instructions.

## Platform matrix

Every release builds **multiple targets** via GitHub Actions on
native runners. Linux uses **musl-static** (Alpine toolchain) so
the binary runs on Alpine, Debian/Ubuntu, RHEL/Fedora, Arch — every
Linux distro — with zero system-library dependencies; there is
intentionally no separate glibc/dynamic Linux variant.

| target | runner | linkage | archive |
|---|---|---|---|
| `x86_64-linux-musl` | `ubuntu-latest` + Alpine 3.20 docker | fully static musl | `.tar.gz` |
| `aarch64-linux-musl` | `ubuntu-24.04-arm` + Alpine 3.20 docker | fully static musl | `.tar.gz` |
| `aarch64-macos` | `macos-14` | static, system libc++/libSystem | `.tar.gz` |
| `x86_64-macos` | `macos-14` (cross from aarch64) | static, system libc++/libSystem | `.tar.gz` |
| `x86_64-windows` | `windows-latest` + MSYS2 + mingw64 | fully static (no DLLs) | `.zip` |

> aarch64-windows and additional targets are deferred. Restoring
> aarch64-windows would require either LLVM clang with
> `-target aarch64-w64-windows-msvc`, or building mingw-w64-aarch64
> from source.

## Quick check after install

```bash
$ lha --version
LHa for Unix (lhasa) 0.6.0

$ lha l archive.lzh
[archive listing...]

$ lha x archive.lzh
[extracts to current directory]
```

## Build from source (vendoring update)

This repo ships `upstream/lhasa/` as a `git subtree` copy of
`fragglet/lhasa.git` master (`75ed835`, lhasa 0.6.0, 2026-06-17).
To refresh the vendoring:

```bash
git subtree pull --prefix=upstream/lhasa https://github.com/fragglet/lhasa.git master --squash
```

Then run `bash scripts/build.sh && bash scripts/smoke.sh` to
reproduce the CI locally. For a true musl-static build:

```bash
docker run --rm --platform linux/amd64 -v "$PWD":/w -w /w alpine:3.20 \
    sh -c 'apk add --no-cache bash >/dev/null && bash /w/scripts/build-alpine.sh && bash /w/scripts/smoke.sh'
```

## Smoke test policy

CI runs the upstream `make check` regression suite (in upstream/lhasa/test/)
against the freshly-built `lha` binary on every push to main and every PR.
A tag push (v*) additionally bundles the per-target static binary as a
GitHub Release.

The CI does **not** run smoke on Windows-target builds because the
upstream test fixtures hardcode Linux /tmp paths. Linux + macOS
build-and-test fully exercise the regression suite on every PR.
