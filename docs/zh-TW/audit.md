---
layout: page
title: "稽核 2026-07-15 —— vendored lhasa @ 75ed835"
description: "對 vendored fragglet/lhasa HEAD 75ed835 (lhasa v0.6.0) 的原始碼級資安稽核。兩條 HIGH（路徑穿越 header->filename）、中/低/info 跟進、vendoring 完整性核對、信任模型說明。"
lang: zh-TW
section: audit
is_top_level: false
---

# 原始碼級資安稽核 —— vendored lhasa @ 75ed835

日期化、按嚴重度排的原始碼級評審，針對 `ljh-sh/lhasa` 公倉
`upstream/lhasa/` 目錄，作為 [v0.6.0.1](https://github.com/ljh-sh/lhasa/releases/tag/v0.6.0.1)
release 的一部分。

被稽核的樹與上游 commit
[`75ed835`](https://github.com/fragglet/lhasa/tree/75ed835) of
[fragglet/lhasa](https://github.com/fragglet/lhasa) **位元級一致**。
沒有本地 patch——`git diff HEAD~1..HEAD -- upstream/lhasa/` 在
vendoring commit 上是空的。

稽核方法：人工讀 `lib/` 與 `src/` 下的 C 原始碼。沒有 fuzz、沒有
coverage instrumentation、也沒有形式化驗證。

> 獨立 markdown 版本：
> [`ljh-sh/lhasa/AUDIT-2026-07-15.md`](https://github.com/ljh-sh/lhasa/blob/main/AUDIT-2026-07-15.md)

## 嚴重度標尺

- **HIGH** ——可被攻擊者控制的輸入觸發、有實際影響（覆寫任意檔案、執行程式等）
- **MEDIUM** ——可觸發，但要繞過限制或影響有限（DoS、部分損壞）
- **LOW** ——窄場景、低影響（decoder 邊緣損壞）
- **INFO** ——不是 bug；記一筆

## 摘要

| # | 等級 | 區域 | 標題 |
|---|------|------|------|
| 1 | **HIGH** | extract | `header->filename` 裡的 `..` **未被** collapse |
| 2 | **HIGH** | symlink | 同 #1；symlink target 策略的歧義 |
| 3 | MEDIUM | header | extended-header 鏈 cap 僅在每個 level 內 |
| 4 | MEDIUM | symlink | 占位檔案 mode 是 0600，跟 umask 無關 |
| 5 | MEDIUM | safe.c | 輸出過濾 `[0x20, 0x7e)`；現代終端在這區間內也有控制序列 |
| 6 | LOW | decode | decoder offset 可以超過 `RING_BUFFER_SIZE` |
| 7 | LOW | monitor | `block_size` 在極端值下翻倍會溢位 unsigned int |
| 8 | INFO | upstream | 0.6.0 已修 `-pm2-` `copy_decode[]` 越界 + 空檔名跳過 |
| 9 | INFO | test | fuzz harness 在上游存在但沒在 CI 跑 |

## 詳細發現

### #1 (HIGH) —— `header->filename` 的路徑穿越

**位置**。`lib/lha_file_header.c:854` 的 `collapse_path()` 只對
`header->path` 呼叫（位於 `lib/lha_file_header.c:1048`），從未對
`header->filename` 呼叫。`src/extract.c:46` 的 `file_full_path()`
拼出 `extract_path + "/" + header->path + header->filename`，只剝離
每段前導 `/`。

**後果**。惡意歸檔可以寫 cwd 之外，方法是把解壓後的檔名設成
帶 `..` 段的路徑。例如從 `/home/user` cwd：

| 歸檔 `header->path` | 歸檔 `header->filename` | 寫到 |
|----------------------|--------------------------|------|
| `subdir`               | `../../../tmp/x`           | `/tmp/x`          |
| `legit`                | `../../etc/passwd`        | `/etc/passwd`     |

`header->path` 被 `collapse_path` 正規化（絕不含 `..`），但
`header->filename` 在 `file_full_path` 裡只剝前導 `/`。

**修復建議**。`lha_file_header_read` 裡 `split_header_filename`
之後給 filename 也跑一次 `collapse_path`：

```c
if (header->filename != NULL) {
    collapse_path(header->filename);
}
```

**風險定級理由**。使用者從網路下載 `.lzh` 後解壓是 lhasa 的標準
威脅模型。同型別 CVE 在 `unrar`、`tar` 上都有過
（CVE-2018-1000888 系列）。`x install lhasa` 正是開啟了這條路。

### #2 (HIGH) —— symlink 檔名有同樣的根問題

**位置**。`lib/lha_reader.c:813` 呼叫
`lha_arch_symlink(filename, header->symlink_target)`。`is_dangerous_symlink`
只查 `symlink_target` 是不是絕對路徑或含 `..`——**不查** link name。

**後果**。`symlink_target = "/etc/passwd"` 的惡意歸檔因為
target 偵測會被替換成 placeholder（不會真的建 symlink），單個
target 防禦是 OK 的。但 #1 的 `header->filename =
"../../../tmp/innocent"` 還會把 placeholder 檔案放到 cwd 之外。
配合後續歸檔條目，可以讓 `lha x` 寫到任何可達路徑。

**修復建議**。同 #1 的 collapse_path；在 `lib/lha_arch_unix.c`
裡所有 syscall 前再加一道 `realpath` 前綴檢查（depth-in-depth）。

### #3 (MEDIUM) —— extended-header 鏈 cap 僅 per-level

`lib/lha_file_header.c:46` `LEVEL_3_MAX_HEADER_LEN = 1 MiB` 只
管 level 3。level 0/1/2 沒有對應 cap。惡意的 1 MiB+ extended
header 鏈在 32-bit target 上能 OOM。

### #4 (MEDIUM) —— symlink placeholder 檔案 mode 是 0600

`lib/lha_reader.c` 的 `extract_placeholder_symlink` 用
`lha_arch_fopen(filename, -1, -1, 0600)` 建立，mode 固定 0600，
真 umask 被忽略。配合 #2，placeholder 檔案無論 umask 都是
owner-readable。

### #5 (MEDIUM) —— `safe_output` 過濾頻寬 `[0x20, 0x7e)`

`src/safe.c:55` 把 `[0x20, 0x7e)` 之外的位元組替換成 `?`。能擋
1980s–1990s 的終端控制協議。但現代終端在這個區間內也有擴充
控制序列（OSC 變體）。`safe.c:43` 已經有 TODO 承認。實際攻擊面
限於 UI 偽裝，沒有程式碼執行路徑。

### #6 (LOW) —— decoder offset 越界

`lib/lh_new_decoder.c:464` `read_offset_code` 返回最大 `2^15 - 1 = 32767`，
超過 `-lh5-` 的 `RING_BUFFER_SIZE = 16384`。`start` 算 unsigned
下溢，但 `% RING_BUFFER_SIZE` 後回到有效索引。輸出是
`ringbuf[wrong_position]`（解壓出錯），**不是** OOB 記憶體存取。

### #7 (LOW) —— `lha_decoder_monitor` 翻倍溢位

`lib/lha_decoder.c:188` 的 `block_size` 是 `unsigned int`，
迴圈裡翻倍直到 `stream_length / 131072 <= block_size`。在
`stream_length > 2^47` 時理論上溢位回 0。但 CLI 端 `stream_length`
是從歸檔欄位讀 `uint32_t`，遠小於 2^47。目前呼叫點不可達。

### #8 (INFO) —— 0.6.0 修復已 vendored

- `-pm2-` `copy_decode[]` 讀越界（[NEWS v0.6.0](https://github.com/fragglet/lhasa/blob/master/NEWS.md)）
- 空 filename 成員跳過（[NEWS v0.6.0](https://github.com/fragglet/lhasa/blob/master/NEWS.md)）

都在 vendored HEAD `75ed835` 裡。無需動作。

### #9 (INFO) —— 測試覆蓋

CI smoke 跑 `lha l` / `lha xq` 三個真實回歸歸檔（`pm1.pma`、
`lzs.lzs`、`long.lzs`）。`-lh0/-lh1/-lh4/-lh5/-lh6/-lh7/-lhx/-lzs/-lz5/-pm1/-pm2`
正向 round-trip 都覆蓋。

缺位：
- 上游 `test/fuzzer.c` fuzz harness **沒** 在 CI 裡持續跑
- 沒有針對畸形 header 的負向測試（如 `header_len = 0xFFFFFFFF`、
  深巢狀 symlink 迴圈）
- CRC 錯誤後 buffer 污染路徑沒有覆蓋

## 信任模型

### 我們**能**確定的

| 信任宣告 | 證據 |
|---------|------|
| Vendored 樹與上游 HEAD 位元級一致 | `git diff HEAD~1..HEAD -- upstream/lhasa/` 空 |
| 上游作者身分 | upstream GitHub commit 元資料：`Simon Howard <fraggle@soulsphere.org>` |
| 程式碼裡沒有出站網路呼叫 | `grep -rE 'socket\|connect\(' upstream/lhasa/` 零命中 |
| 除兩個 test helper 外沒有 `system()` / `exec()` / `popen()` | `test/ghost-tester.c`、`gencov` |
| 不讀 `.ssh`、`.aws`、`/etc/passwd` 等 | `grep -rE '\.ssh\|\.aws\|/etc/(passwd\|shadow)'` 零命中 |
| 沒有 `__attribute__((constructor))` / `__attribute__((destructor))` | `grep -rE '__attribute__\(\(constructor\|destructor' upstream/lhasa/` 零命中 |
| 除一個 test fixture 外沒有 `getenv()` | 只有 `getenv("TEST_NOW_TIME")` 在 `src/list.c` |
| lhasa 在 Debian `main`（不是 `non-free`） | 通過 Debian license + code review 鏈 |

### 我們**不能**確定的（限制）

| 限制 | 含義 |
|------|------|
| 上游維護者**沒有** GPG 簽名 release | `fragglet/lhasa` GitHub 公倉若被攻破，`git verify-commit` 偵測不到 |
| 沒有 reproducible build | 不能從 source 獨立重算出 release 的 SHA256——只能信 GitHub 的簽名 artifact 鏈 |
| 路徑穿越 #1+#2 在上游**未**修 | `git log fragglet/lhasa master` 截至 `75ed835` 沒合相關 commit |

## 行動方案

1. **向上游提 #1 issue** ——建議在 `lha_file_header_read` 末尾加 `collapse_path(filename)`。
2. **向上游提 #2 issue** ——同 #1 的 fix；附帶建議 `realpath` 前綴作第二道。
3. **本倉先打 patch**：在 `ljh-sh/lhasa/upstream/lhasa/` 直接打 #1+#2 patch；用 `git subtree pull --squash` rebase 等上游合併。下一個 release 標 `v0.6.0.2`。
4. **同 patch 系列加 `LEVEL_1_MAX_HEADER_LEN` / `LEVEL_2_MAX_HEADER_LEN`**（#3）。
5. **#5 暫緩**，等真攻擊報上來再處理。

---

*稽核日期 2026-07-15，對象 vendored HEAD = `75ed835`。
源 markdown：
[`AUDIT-2026-07-15.md`](https://github.com/ljh-sh/lhasa/blob/main/AUDIT-2026-07-15.md)。*
