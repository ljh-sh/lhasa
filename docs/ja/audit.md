---
layout: page
title: "監査 2026-07-15 — vendored lhasa @ 75ed835"
description: "vendored fragglet/lhasa HEAD 75ed835 (lhasa v0.6.0) のソースレベルセキュリティ監査。HIGH 2 件（header->filename のパストラバーサル）、Medium/Low/Info 残務、vendoring 整合性検証、信頼モデル解説。"
lang: ja
section: audit
is_top_level: false
---

# ソースレベルセキュリティ監査 — vendored lhasa @ 75ed835

`ljh-sh/lhasa` リポジトリの `upstream/lhasa/` 配下に対する、日付入り・深刻度ランク付きのソースレベルレビュー。
[v0.6.0.1](https://github.com/ljh-sh/lhasa/releases/tag/v0.6.0.1) で配布されたバイナリの対象。

監査対象は upstream コミット
[`75ed835`](https://github.com/fragglet/lhasa/tree/75ed835) of
[fragglet/lhasa](https://github.com/fragglet/lhasa) と**バイト単位で一致**。
ローカル patch は一切当たっていない——`git diff HEAD~1..HEAD -- upstream/lhasa/`
は vendoring commit で空。

監査方法：`lib/` と `src/` 配下の C ソースを人力で読む。
ファジング・カバレッジ計測・形式検証は使っていない。

> スタンドアロン版 markdown：
> [`ljh-sh/lhasa/AUDIT-2026-07-15.md`](https://github.com/ljh-sh/lhasa/blob/main/AUDIT-2026-07-15.md)

## 深刻度の物差し

- **HIGH** — 攻撃者制御の入力で到達可、現実の被害（任意ファイル上書き、コード実行など）
- **MEDIUM** — 到達可だが発火条件が限定的、または影響が局所的（DoS、部分破壊）
- **LOW** — 到達パスが狭い、または影響が小さい（デコーダ破壊のエッジケース）
- **INFO** — バグではない。後世のため記録

## 概要

| # | 深刻度 | 領域 | タイトル |
|---|--------|------|----------|
| 1 | **HIGH** | extract | `header->filename` の `..` が **collapse されていない** |
| 2 | **HIGH** | symlink | #1 と同じ；symlink target ポリシーの曖昧さ |
| 3 | MEDIUM | header | extended-header 連鎖の上限は level ごとにしかない |
| 4 | MEDIUM | symlink | プレースホルダファイルの mode は umask に関わらず 0600 |
| 5 | MEDIUM | safe.c | 出力フィルタは `[0x20, 0x7e)`；現代端末でもこの帯域に制御シーケンスがある |
| 6 | LOW | decode | decoder の offset が `RING_BUFFER_SIZE` を超え得る |
| 7 | LOW | monitor | `block_size` の 2 倍ループが理論上 `unsigned int` を溢れさせる |
| 8 | INFO | upstream | 0.6.0 で `-pm2-` `copy_decode[]` 越境と空ファイル名スキップは既修正 |
| 9 | INFO | test | 上流に fuzz harness あるが CI では未稼働 |

## 詳細

### #1 (HIGH) — `header->filename` のパストラバーサル

**所在**。`lib/lha_file_header.c:854` の `collapse_path()` は
`header->path`（`lib/lha_file_header.c:1048`）に対してしか呼ばれず、
`header->filename` には一度も適用されていない。
`src/extract.c:46` の `file_full_path()` は
`extract_path + "/" + header->path + header->filename` を連結し、
各成分の先頭 `/` を剥がすだけ。

**効果**。攻撃アーカイブは展開後ファイル名に `..` を含むパスを
設定することで cwd 外への書込みができる。`/home/user` cwd での例：

| アーカイブ `header->path` | アーカイブ `header->filename` | 書込み先 |
|---------------------------|-----------------------------|----------|
| `subdir`                  | `../../../tmp/x`            | `/tmp/x`     |
| `legit`                   | `../../etc/passwd`         | `/etc/passwd` |

`header->path` は `collapse_path` で正規化（`..` は含まれない）が、
`header->filename` は `file_full_path` で先頭 `/` を剥がすだけでそのまま。

**修正提案**。`lha_file_header_read` 内の `split_header_filename`
直後に filename にも `collapse_path` を適用：

```c
if (header->filename != NULL) {
    collapse_path(header->filename);
}
```

**深刻度根拠**。ユーザーがネットから `.lzh` を落として展開するのは
lhasa の標準的な脅威モデル。`unrar`・`tar` などの同種 CVE
（CVE-2018-1000888 系）と同じ表面。`x install lhasa` でその経路が
開かれてしまう。

### #2 (HIGH) — symlink のファイル名は同じ根問題

**所在**。`lib/lha_reader.c:813` で
`lha_arch_symlink(filename, header->symlink_target)` を呼ぶ。
`is_dangerous_symlink` は `symlink_target` の絶対パス・`..` のみ
検査し、**リンク名（filename）は検査しない**。

**効果**。`symlink_target = "/etc/passwd"` は target 検査で
プレースホルダ化されるため単独では安全。しかし #1 の
`header->filename = "../../../tmp/innocent"` がそのまま残ると、
プレースホルダファイルが cwd 外に置かれる。続くエントリと組み
合わせれば `lha x` の到達圏内なら任意の場所に書込み可能。

**修正提案**。#1 と同じ修正に加え、`lib/lha_arch_unix.c` の全
syscall 前に `realpath` cwd-prefix チェック（多層防御）。

### #3 (MEDIUM) — extended-header 連鎖の上限が level ごとにしかない

`lib/lha_file_header.c:46` の `LEVEL_3_MAX_HEADER_LEN = 1 MiB`
は level 3 のみ。level 0/1/2 には対応する上限がない。1 MiB+
の extended-header 連鎖は 32-bit ターゲットで OOM を起こせる。

### #4 (MEDIUM) — symlink プレースホルダの mode は 0600

`lib/lha_reader.c` の `extract_placeholder_symlink` は
`lha_arch_fopen(filename, -1, -1, 0600)` で mode 0600 を渡す。
umask を考慮しない。#2 と組み合わせると、プレースホルダは
umask に関わらず owner-readable。

### #5 (MEDIUM) — `safe_output` フィルタ帯 `[0x20, 0x7e)`

`src/safe.c:55` は `[0x20, 0x7e)` 外を `?` に潰す。1980–90
年代の端末プロトコルは防げる。が、現代端末は同帯域に拡張プロトコル
（OSC 系等）を持つ。`safe.c:43` の TODO で既に認識。実攻撃面は
UI 偽装のみで、コード実行パスはない。

### #6 (LOW) — decoder offset のリングバッファ越え

`lib/lh_new_decoder.c:464` の `read_offset_code` は最大
`2^15 - 1 = 32767` を返し、`-lh5-` の `RING_BUFFER_SIZE = 16384`
を超える。`start` が unsigned 下溢するが `% RING_BUFFER_SIZE`
で有効インデックスに戻る。出力は `ringbuf[wrong_position]`
（展開破壊）、**OOB メモリアクセスではない**。

### #7 (LOW) — `lha_decoder_monitor` の 2 倍ループ

`lib/lha_decoder.c:188` の `block_size`（`unsigned int`）は
`stream_length / 131072 <= block_size` まで 2 倍しつづける。
`stream_length > 2^47` で理論上 0 にラップ。CLI 側は `stream_length`
をアーカイブから `uint32_t` で読むため 2^47 にはるかに届かず、
現行呼出点では不可達。

### #8 (INFO) — 0.6.0 修正は vendored に含まれる

- `-pm2-` `copy_decode[]` の読出し越境（[NEWS v0.6.0](https://github.com/fragglet/lhasa/blob/master/NEWS.md)）
- 空 filename メンバー行のスキップ（[NEWS v0.6.0](https://github.com/fragglet/lhasa/blob/master/NEWS.md)）

どちらも vendored HEAD `75ed835` に既に取り込み済み。対応不要。

### #9 (INFO) — テストカバー

CI smoke は 3 つのアーカイブ（`pm1.pma`、`lzs.lzs`、`long.lzs`）
に対して `lha l` / `lha xq` を回す。`-lh0/-lh1/-lh4/-lh5/-lh6/-lh7/-lhx/-lzs/-lz5/-pm1/-pm2`
の happy-path round-trip は網羅。

不足：
- upstream の `test/fuzzer.c` fuzz harness が CI で**未稼働**
- 破損ヘッダ（`header_len = 0xFFFFFFFF` など）への negative-path
  テストがない
- CRC エラー後のバッファ汚染経路が未カバー

## 信頼モデル

### 我々が**言える**こと

| 主張 | 証拠 |
|------|------|
| vendored ツリーは upstream HEAD とバイト一致 | `git diff HEAD~1..HEAD -- upstream/lhasa/` 空 |
| upstream 作者 | upstream GitHub commit メタデータ：`Simon Howard <fraggle@soulsphere.org>` |
| コードに外向きネットワーク呼び出しなし | `grep -rE 'socket\|connect\(' upstream/lhasa/` 0 件 |
| 2 つの test helper 外で `system()` / `exec()` / `popen()` なし | `test/ghost-tester.c`、`gencov` |
| `.ssh` / `.aws` / `/etc/passwd` 等の読出しなし | `grep -rE '\.ssh\|\.aws\|/etc/(passwd\|shadow)'` 0 件 |
| `__attribute__((constructor))` / `__attribute__((destructor))` なし | `grep -rE '__attribute__\(\(constructor\|destructor' upstream/lhasa/` 0 件 |
| test fixture を除く `getenv()` なし | `getenv("TEST_NOW_TIME")` のみ（`src/list.c`） |
| lhasa は Debian `main`（non-free ではない） | Debian の license + コードレビューを通っている |

### 我々が**言えない**こと（残された制約）

| 制約 | 含意 |
|------|------|
| upstream メンテナは release に **GPG 署名していない** | `fragglet/lhasa` リポジトリが侵害された場合に `git verify-commit` で検知できない |
| reproducible build ではない | リリースの SHA256 をソースから独立に再計算できない——GitHub の署名アーティファクト連鎖のみを信頼している |
| パストラバーサル #1+#2 は upstream で未修正 | `git log fragglet/lhasa master` の `75ed835` 時点まで関連 commit なし |

## アクションプラン

1. **upstream に #1 issue** を提出 — `lha_file_header_read` 末尾で `collapse_path(filename)` を提案。
2. **upstream に #2 issue** を提出 — 同上の fix に加え `realpath` 第 2 段を提案。
3. **本倉にローカル patch** — `ljh-sh/lhasa/upstream/lhasa/` に #1+#2 を直接当て、upstream が採用したら `git subtree pull --squash` で rebase。 次リリースは **`v0.6.0.2`**。
4. **同 patch 系列で `LEVEL_1_MAX_HEADER_LEN` / `LEVEL_2_MAX_HEADER_LEN`**（#3）を追加。
5. **#5 は保留** — 実攻撃が報告されてから着手。

---

*監査日 2026-07-15、対象 vendored HEAD = `75ed835`。
ソース markdown：
[`AUDIT-2026-07-15.md`](https://github.com/ljh-sh/lhasa/blob/main/AUDIT-2026-07-15.md)。*
