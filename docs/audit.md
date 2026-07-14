---
layout: page
title: "Audit 2026-07-15 — vendored lhasa @ 75ed835"
description: "Source-level security audit of vendored fragglet/lhasa at HEAD 75ed835 (lhasa v0.6.0). Two HIGH findings (path traversal via header->filename), medium/low/info follow-ups, vendor-integrity verification, and trust-model context."
lang: en
section: audit
---

# Source-Level Security Audit — vendored lhasa @ 75ed835

A dated, severity-ranked source-level review of the C code under
`upstream/lhasa/` in `ljh-sh/lhasa`, as shipped in
[v0.6.0.1](https://github.com/ljh-sh/lhasa/releases/tag/v0.6.0.1).

The audited tree is byte-for-byte identical to upstream commit
[`75ed835`](https://github.com/fragglet/lhasa/tree/75ed835) of
[fragglet/lhasa](https://github.com/fragglet/lhasa). No local patches
have been applied: `git diff HEAD~1..HEAD -- upstream/lhasa/`
on the vendoring commit is empty.

Audit method: reading the C source under `lib/` and `src/`.
No fuzzing, no coverage instrumentation, no formal verification.

> See [`ljh-sh/lhasa/AUDIT-2026-07-15.md`](https://github.com/ljh-sh/lhasa/blob/main/AUDIT-2026-07-15.md)
> for the standalone MD version.

## Severity scale

- **HIGH** — reachable by attacker-controlled input, real impact
  (file overwrite, code execution, etc.)
- **MEDIUM** — reachable, but harder to trigger or limited impact
  (DoS, partial corruption)
- **LOW** — narrow reach or low impact (decoder-corruption edge
  case)
- **INFO** — not a bug; recorded for posterity

## Summary

| # | Level | Area | Title |
|---|-------|------|-------|
| 1 | **HIGH** | extract | `..` in `header->filename` is **not** collapsed |
| 2 | **HIGH** | symlink | Same as #1; symlink target policy ambiguity |
| 3 | MEDIUM | header | extended-header chain cap is per-level only |
| 4 | MEDIUM | symlink | placeholder file mode is 0600 regardless of umask |
| 5 | MEDIUM | safe.c | output filter `[0x20, 0x7e)`; modern terminals interpret sequences within that range |
| 6 | LOW | decode | decoder offset can exceed `RING_BUFFER_SIZE` |
| 7 | LOW | monitor | `block_size` doubling overflows at theoretical extremes |
| 8 | INFO | upstream | 0.6.0 already fixed `-pm2-` `copy_decode[]` overflow + empty-filename skip |
| 9 | INFO | test | fuzz harness exists upstream but is not run in CI |

## Detailed findings

### #1 (HIGH) — Path traversal via `header->filename`

**Where.** `lib/lha_file_header.c:854` `collapse_path()` is called
on `header->path` only (at `lib/lha_file_header.c:1048`), never on
`header->filename`. `src/extract.c:46` `file_full_path()` concatenates
`extract_path + "/" + header->path + header->filename` with only
leading-`/` stripping on each component.

**Effect.** A malicious archive can write outside `cwd` by setting
the decompressed filename to a path containing `..` segments. Example
from `/home/user` cwd:

| archive `header->path` | archive `header->filename` | extract writes to |
|------------------------|----------------------------|-------------------|
| `subdir`               | `../../../tmp/x`           | `/tmp/x`          |
| `legit`                | `../../etc/passwd`        | `/etc/passwd`     |

`header->path` is normalised by `collapse_path` (so it never
contains `..`), but `header->filename` is taken as-is in
`file_full_path` after only the leading-`/` strip.

**Suggested fix.** Add `collapse_path` on the filename in
`lha_file_header_read` after `split_header_filename`:

```c
if (header->filename != NULL) {
    collapse_path(header->filename);
}
```

**Severity rationale.** Reachable by user-controlled input
(untrusted `.lzh` extracted from the network). The threat model
matches analogous CVEs in `unrar`, `tar` (CVE-2018-1000888 family),
etc. lhasa's `x install lhasa` enables exactly this scenario.

### #2 (HIGH) — Symlink filename traversal shares root cause

**Where.** `lib/lha_reader.c:813` invokes
`lha_arch_symlink(filename, header->symlink_target)`. The
`is_dangerous_symlink` predicate inspects only `symlink_target`
for absolute paths and `..` segments; it does **not** check the
link name (the filename).

**Effect.** A malicious archive with a benign-looking
`symlink_target = "/etc/passwd"` is rewritten to a placeholder
(no actual symlink), so the symmetric-target defence works.
However, the same uncleared
`header->filename = "../../../tmp/innocent"` from #1 routes the
placeholder file to outside `cwd`. Combined with subsequent
archive entries, this enables follow-up file writes anywhere
`lha x` can reach.

**Suggested fix.** Same as #1, plus defence-in-depth
`realpath`-and-cwd-prefix check before any `lha_arch_*` syscall
in `lib/lha_arch_unix.c`.

### #3 (MEDIUM) — Extended-header chain cap is per-level

`lib/lha_file_header.c:46` `LEVEL_3_MAX_HEADER_LEN = 1 MiB`
bounds the level-3 chain. Levels 0/1/2 have **no equivalent
cap**. A hostile 1 MiB+ extended-header chain can OOM a 32-bit
target.

### #4 (MEDIUM) — Symlink placeholder file mode

`lib/lha_reader.c` `extract_placeholder_symlink` calls
`lha_arch_fopen(filename, -1, -1, 0600)` with mode 0600; the
real umask is ignored. In combination with #2, the placeholder
file is owner-readable regardless of umask.

### #5 (MEDIUM) — `safe_output` filter band `[0x20, 0x7e)`

`src/safe.c:55` blanks bytes outside `[0x20, 0x7e)` to `?`.
Defends against 1980s–1990s terminal-emulator control protocols.
Modern terminal emulators interpret sequences within that range
(vendor extensions, OSC variants). The TODO on `safe.c:43`
acknowledges the gap. Practical attack surface is limited to
UI spoofing; no code execution path.

### #6 (LOW) — Decoder offset out-of-range

`lib/lh_new_decoder.c:464` `read_offset_code` returns up to
`2^15 - 1 = 32767`, larger than `RING_BUFFER_SIZE = 16384`
for `-lh5-`. `start` underflows unsigned, but the `% RING_BUFFER_SIZE`
wraps to a valid index. Output is `ringbuf[wrong_position]`
(decompression corruption), **not** OOB memory access.

### #7 (LOW) — `lha_decoder_monitor` block-size doubling

`lib/lha_decoder.c:188` `block_size` is `unsigned int`, doubled
in a loop until `stream_length / 131072 <= block_size`. Theoretical
overflow to 0 if `stream_length > 2^47`. Realistic reach requires
attacker-controlled `stream_length`; the CLI reads it as `uint32_t`,
capped well below 2^47. Non-issue in current call sites.

### #8 (INFO) — 0.6.0 fixes already vendored

- `-pm2-` `copy_decode[]` read overflow
  ([NEWS v0.6.0](https://github.com/fragglet/lhasa/blob/master/NEWS.md))
- Empty-filename member skipping
  ([NEWS v0.6.0](https://github.com/fragglet/lhasa/blob/master/NEWS.md))

Both already present in vendored HEAD `75ed835`. No action.

### #9 (INFO) — Test coverage

CI smoke drives `lha l` / `lha xq` against three real upstream
regression archives (`pm1.pma`, `lzs.lzs`, `long.lzs`). Tests cover
`-lh0/-lh1/-lh4/-lh5/-lh6/-lh7/-lhx/-lzs/-lz5/-pm1/-pm2` happy-path
round-trips.

Gaps:
- fuzz harness (`test/fuzzer.c`) exists upstream but **not** run
  continuously in CI;
- no negative-path tests for malformed headers
  (e.g. `header_len = 0xFFFFFFFF`, deeply-nested symlink loop);
- post-CRC-failure buffer pollution is not exercised.

## Trust model

### What we **do** know

| Trust claim | Evidence |
|-------------|----------|
| Vendored tree is byte-identical to upstream HEAD | `git diff HEAD~1..HEAD -- upstream/lhasa/` empty |
| Upstream author identity | upstream GitHub commit metadata: `Simon Howard <fraggle@soulsphere.org>` |
| No outbound network calls in the code | `grep -rE 'socket\|connect\(' upstream/lhasa/` returns 0 hits |
| No `system()` / `exec()` / `popen()` outside two test helpers | `test/ghost-tester.c`, `gencov` |
| No reads of `.ssh`, `.aws`, `/etc/passwd`, etc. | `grep -rE '\.ssh\|\.aws\|/etc/(passwd\|shadow)'` returns 0 hits |
| No `__attribute__((constructor))` / `__attribute__((destructor))` | `grep -rE '__attribute__\(\(constructor\|destructor' upstream/lhasa/` returns 0 hits |
| No `getenv()` outside a test fixture override | only `getenv("TEST_NOW_TIME")` in `src/list.c` |
| lhasa is in Debian `main` (not `non-free`) | passes Debian license + code-review chain |

### What we **do not** know (limiting factors)

| Limitation | Implication |
|------------|-------------|
| Upstream maintainer is **not** GPG-signing releases | a compromised `fragglet/lhasa` GitHub repo would not be detected by `git verify-commit` |
| No reproducible build | we cannot independently re-derive the SHA256 of a release from source — we trust only GitHub's signed-artifact chain |
| Path-traversal findings (#1+#2) are **open** upstream | `git log fragglet/lhasa master` shows no commits addressing them as of `75ed835` |

## Action plan

1. **File upstream issue for #1** — recommend `collapse_path(filename)` in `lha_file_header_read` finaliser.
2. **File upstream issue for #2** — same fix; suggest `realpath`-prefix as a second line.
3. **Local patch** in `ljh-sh/lhasa/upstream/lhasa/` for #1 + #2 as an immediate fix, gated via `git subtree pull --squash` rebase when upstream adopts it. Drive the next release as **v0.6.0.2**.
4. **Add `LEVEL_1_MAX_HEADER_LEN` / `LEVEL_2_MAX_HEADER_LEN`** (#3) in the same patch series.
5. **Defer #5** (`safe.c` filter modernisation) until a concrete attack is reported.

---

*Audit performed 2026-07-15 against vendored HEAD = `75ed835`.
Source available at
[`AUDIT-2026-07-15.md`](https://github.com/ljh-sh/lhasa/blob/main/AUDIT-2026-07-15.md).*
