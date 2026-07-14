# NOTICE

This repository (`ljh-sh/lhasa`) provides self-contained, statically-linked
builds of **lhasa** (the ISC-licensed LZH/LZS/PMarc decoder) and the
build/packaging layer around it. The CLI binary is named `lha` because
that is the upstream-distributed binary name — the project deliberately
provides an interface-compatible `lha` replacement for the non-free
upstream `ljh-sh/lha` (which was retired 2026-07-15).

## Wrapper license (this repo's own files)

`scripts/`, `.github/workflows/`, `README.md`, `NOTICE.md`, `.gitattributes`,
`.gitignore`, and `LICENSE` (the MIT half) are

    Copyright (c) 2026 Li Junhao
    Licensed under the MIT License — see LICENSE.

## Upstream license (`upstream/lhasa/` and the `lha` / `liblhasa` artifacts)

`upstream/lhasa/` is a copy of [fragglet/lhasa](https://github.com/fragglet/lhasa)
(the maintained LZH/LArc/PMarc decoder + CLI tool, originally by
Simon Howard <fraggle@gmail.com> — see `upstream/lhasa/AUTHORS`).
Upstream is vendored via `git subtree`. Upstream license is ISC:

    Copyright (c) 2011-2025, Simon Howard
    Licensed under the ISC License — see upstream/lhasa/COPYING.md.

ISC is a permissive license functionally identical to MIT — it
explicitly permits binary redistribution (`x eget ljh-sh/lhasa`,
distro packages, embedded commercial use). It is OSI-approved and
DFSG-free (which is why Debian's `lhasa` package lives in `main`,
not `non-free`).

## CLI binary naming

The `src/Makefile.am` in upstream installs the CLI binary as `lha`,
not `lhasa`, intentionally mimicking the original LHa for UNIX
command. After installing via `x eget ljh-sh/lhasa`, the user runs:

```bash
$ lha --version
LHa for Unix (lhasa) 0.6.0
```

If both `lha` and `lhasa` are installed on `$PATH`, `lha --version`
will disambiguate via the version banner.

## No patches applied to the vendored source

`upstream/lhasa/` is a clean copy. There are no local patches over
the upstream HEAD at the time of vendoring. Re-vendor (or
`git subtree pull`) to refresh.

## How vendoring is structured

`upstream/lhasa/` was created with:

    git subtree add --prefix=upstream/lhasa https://github.com/fragglet/lhasa.git master --squash

Subsequent updates should use:

    git subtree pull --prefix=upstream/lhasa https://github.com/fragglet/lhasa.git master --squash
