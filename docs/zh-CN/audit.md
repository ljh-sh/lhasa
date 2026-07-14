---
layout: page
title: "审计 2026-07-15 —— vendored lhasa @ 75ed835"
description: "对 vendored fragglet/lhasa HEAD 75ed835 (lhasa v0.6.0) 的源码级安全审计。两条 HIGH（路径穿越 header->filename）、中/低/info 跟进、vendoring 完整性核对、信任模型说明。"
lang: zh-CN
section: audit
is_top_level: false
---

# 源码级安全审计 —— vendored lhasa @ 75ed835

日期化、按严重度排的源码级评审，针对 `ljh-sh/lhasa` 公仓
`upstream/lhasa/` 目录，作为 [v0.6.0.1](https://github.com/ljh-sh/lhasa/releases/tag/v0.6.0.1)
release 的一部分。

被审计的树与上游 commit
[`75ed835`](https://github.com/fragglet/lhasa/tree/75ed835) of
[fragglet/lhasa](https://github.com/fragglet/lhasa) **字节级一致**。
没有本地 patch——`git diff HEAD~1..HEAD -- upstream/lhasa/` 在
vendoring commit 上是空的。

审计方法：人工读 `lib/` 与 `src/` 下的 C 源码。没有 fuzz、没有
coverage instrumentation、也没有形式化验证。

> 独立 markdown 版本：
> [`ljh-sh/lhasa/AUDIT-2026-07-15.md`](https://github.com/ljh-sh/lhasa/blob/main/AUDIT-2026-07-15.md)

## 严重度标尺

- **HIGH** ——可被攻击者控制的输入触发、有实际影响（覆盖任意文件、代码执行等）
- **MEDIUM** ——可触发，但要绕过限制或影响有限（DoS、部分损坏）
- **LOW** ——窄场景、低影响（decoder 边缘损坏）
- **INFO** ——不是 bug；记一笔

## 摘要

| # | 等级 | 区域 | 标题 |
|---|------|------|------|
| 1 | **HIGH** | extract | `header->filename` 里的 `..` **未被** collapse |
| 2 | **HIGH** | symlink | 同 #1；symlink target 策略的歧义 |
| 3 | MEDIUM | header | extended-header 链 cap 仅在每个 level 内 |
| 4 | MEDIUM | symlink | 占位文件 mode 是 0600，跟 umask 无关 |
| 5 | MEDIUM | safe.c | 输出过滤 `[0x20, 0x7e)`；现代终端在这区间内也有控制序列 |
| 6 | LOW | decode | decoder offset 可以超过 `RING_BUFFER_SIZE` |
| 7 | LOW | monitor | `block_size` 在极端值下翻倍会溢出 unsigned int |
| 8 | INFO | upstream | 0.6.0 已修 `-pm2-` `copy_decode[]` 越界 + 空文件名跳过 |
| 9 | INFO | test | fuzz harness 在上游存在但没在 CI 跑 |

## 详细发现

### #1 (HIGH) —— `header->filename` 的路径穿越

**位置**。`lib/lha_file_header.c:854` 的 `collapse_path()` 只对
`header->path` 调用（位于 `lib/lha_file_header.c:1048`），从未对
`header->filename` 调用。`src/extract.c:46` 的 `file_full_path()`
拼出 `extract_path + "/" + header->path + header->filename`，只剥离
每段前导 `/`。

**后果**。恶意归档可以写 cwd 之外，方法是把解压后的文件名设成
带 `..` 段的路径。例如从 `/home/user` cwd：

| 归档 `header->path` | 归档 `header->filename` | 写到 |
|----------------------|--------------------------|------|
| `subdir`               | `../../../tmp/x`           | `/tmp/x`          |
| `legit`                | `../../etc/passwd`        | `/etc/passwd`     |

`header->path` 被 `collapse_path` 规范化（绝不含 `..`），但
`header->filename` 在 `file_full_path` 里只剥前导 `/`。

**修复建议**。`lha_file_header_read` 里 `split_header_filename`
之后给 filename 也跑一次 `collapse_path`：

```c
if (header->filename != NULL) {
    collapse_path(header->filename);
}
```

**风险定级理由**。用户从网络下载 `.lzh` 后解压是 lhasa 的标准
威胁模型。同类型 CVE 在 `unrar`、`tar` 上都有过
（CVE-2018-1000888 系列）。`x install lhasa` 正是开启了这条路。

### #2 (HIGH) —— symlink 文件名有同样的根问题

**位置**。`lib/lha_reader.c:813` 调用
`lha_arch_symlink(filename, header->symlink_target)`。`is_dangerous_symlink`
只查 `symlink_target` 是不是绝对路径或含 `..`——**不查** link name。

**后果**。`symlink_target = "/etc/passwd"` 的恶意归档因为
target 检测会被替换成 placeholder（不会真的建 symlink），单个
target 防御是 OK 的。但 #1 的 `header->filename =
"../../../tmp/innocent"` 还会把 placeholder 文件放到 cwd 之外。
配合后续 archive 条目，可以让 `lha x` 写到任何可达路径。

**修复建议**。同 #1 的 collapse_path；在 `lib/lha_arch_unix.c`
里所有 syscall 前再加一道 `realpath` 前缀检查（depth-in-depth）。

### #3 (MEDIUM) —— extended-header 链 cap 仅 per-level

`lib/lha_file_header.c:46` `LEVEL_3_MAX_HEADER_LEN = 1 MiB` 只
管 level 3。level 0/1/2 没有对应 cap。恶意的 1 MiB+ extended
header 链在 32-bit target 上能 OOM。

### #4 (MEDIUM) —— symlink placeholder 文件 mode 是 0600

`lib/lha_reader.c` 的 `extract_placeholder_symlink` 用
`lha_arch_fopen(filename, -1, -1, 0600)` 创建，mode 固定 0600，
真 umask 被忽略。配合 #2，placeholder 文件无论 umask 都是
owner-readable。

### #5 (MEDIUM) —— `safe_output` 过滤带宽 `[0x20, 0x7e)`

`src/safe.c:55` 把 `[0x20, 0x7e)` 之外的字节替换成 `?`。能挡
1980s–1990s 的终端控制协议。但现代终端在这个区间内也有扩展
控制序列（OSC 变体）。`safe.c:43` 已经有 TODO 承认。实际攻击面
限于 UI 伪装，没有代码执行路径。

### #6 (LOW) —— decoder offset 越界

`lib/lh_new_decoder.c:464` `read_offset_code` 返回最大 `2^15 - 1 = 32767`，
超过 `-lh5-` 的 `RING_BUFFER_SIZE = 16384`。`start` 算 unsigned
下溢，但 `% RING_BUFFER_SIZE` 后回到有效索引。输出是
`ringbuf[wrong_position]`（解压出错），**不是** OOB 内存访问。

### #7 (LOW) —— `lha_decoder_monitor` 翻倍溢出

`lib/lha_decoder.c:188` 的 `block_size` 是 `unsigned int`，
循环里翻倍直到 `stream_length / 131072 <= block_size`。在
`stream_length > 2^47` 时理论上溢出回 0。但 CLI 端 `stream_length`
是从归档字段读 `uint32_t`，远小于 2^47。当前调用点不可达。

### #8 (INFO) —— 0.6.0 修复已 vendored

- `-pm2-` `copy_decode[]` 读越界（[NEWS v0.6.0](https://github.com/fragglet/lhasa/blob/master/NEWS.md)）
- 空 filename 成员跳过（[NEWS v0.6.0](https://github.com/fragglet/lhasa/blob/master/NEWS.md)）

都在 vendored HEAD `75ed835` 里。无需动作。

### #9 (INFO) —— 测试覆盖

CI smoke 跑 `lha l` / `lha xq` 三个真实回归归档（`pm1.pma`、
`lzs.lzs`、`long.lzs`）。`-lh0/-lh1/-lh4/-lh5/-lh6/-lh7/-lhx/-lzs/-lz5/-pm1/-pm2`
正向 round-trip 都覆盖。

缺位：
- 上游 `test/fuzzer.c` fuzz harness **没** 在 CI 里持续跑
- 没有针对畸形 header 的负向测试（如 `header_len = 0xFFFFFFFF`、
  深嵌套 symlink 循环）
- CRC 错误后 buffer 污染路径没有覆盖

## 信任模型

### 我们**能**确定的

| 信任声明 | 证据 |
|---------|------|
| Vendored 树与上游 HEAD 字节级一致 | `git diff HEAD~1..HEAD -- upstream/lhasa/` 空 |
| 上游作者身份 | upstream GitHub commit 元数据：`Simon Howard <fraggle@soulsphere.org>` |
| 代码里没有出站网络调用 | `grep -rE 'socket\|connect\(' upstream/lhasa/` 零命中 |
| 除两个 test helper 外没有 `system()` / `exec()` / `popen()` | `test/ghost-tester.c`、`gencov` |
| 不读 `.ssh`、`.aws`、`/etc/passwd` 等 | `grep -rE '\.ssh\|\.aws\|/etc/(passwd\|shadow)'` 零命中 |
| 没有 `__attribute__((constructor))` / `__attribute__((destructor))` | `grep -rE '__attribute__\(\(constructor\|destructor' upstream/lhasa/` 零命中 |
| 除一个 test fixture 外没有 `getenv()` | 只有 `getenv("TEST_NOW_TIME")` 在 `src/list.c` |
| lhasa 在 Debian `main`（不是 `non-free`） | 通过 Debian license + code review 链 |

### 我们**不能**确定的（限制）

| 限制 | 含义 |
|------|------|
| 上游维护者**没有** GPG 签名 release | `fragglet/lhasa` GitHub 公仓若被攻破，`git verify-commit` 检测不到 |
| 没有 reproducible build | 不能从 source 独立重算出 release 的 SHA256——只能信 GitHub 的签名 artifact 链 |
| 路径穿越 #1+#2 在上游**未**修 | `git log fragglet/lhasa master` 截至 `75ed835` 没合相关 commit |

## 行动方案

1. **向上游提 #1 issue** ——建议在 `lha_file_header_read` 末尾加 `collapse_path(filename)`。
2. **向上游提 #2 issue** ——同 #1 的 fix；附带建议 `realpath` 前缀作第二道。
3. **本仓先打 patch**：在 `ljh-sh/lhasa/upstream/lhasa/` 直接打 #1+#2 patch；用 `git subtree pull --squash` rebase 等上游合并。下一个 release 标 `v0.6.0.2`。
4. **同 patch 系列加 `LEVEL_1_MAX_HEADER_LEN` / `LEVEL_2_MAX_HEADER_LEN`**（#3）。
5. **#5 暂缓**，等真攻击报上来再处理。

---

*审计日期 2026-07-15，对象 vendored HEAD = `75ed835`。
源 markdown：
[`AUDIT-2026-07-15.md`](https://github.com/ljh-sh/lhasa/blob/main/AUDIT-2026-07-15.md)。*
