# Obsidian LiveSync Skill — 代码审查跟踪

> 审查日期: 2026-04-27 | 审查范围: `scripts/couchdb.sh` (679行) + 文档

## 审查方法

- 逐行代码审查 + 跨平台兼容性分析 (macOS / Linux / MSYS2)
- ShellCheck 规则集交叉验证 (SC2181, SC2086, SC2155, SC2162 等)
- CouchDB REST API 最佳实践对照
- 多agent辅助探索

---

## 🔴 严重 (Security / Data Correctness)

### [x] #1 SSL 证书验证默认禁用 ← 安全问题 — ✅ 已修复
- **位置**: L18 `INSECURE=true` → L56 `curl -sk`
- **问题**: 默认跳过 TLS 证书验证。所有请求（含 Basic Auth 凭证）可在 MITM 攻击下被窃取。
- **修复**: `INSECURE=false` 改为默认安全；`--insecure` flag 保留供用户显式选择。帮助文档和 README 同步更新。
- **优先级**: P0 — 安全基线

### [x] #2 `replace_section` 标题匹配过于宽松 ← 功能 Bug — ✅ 已修复 (Issue #3, commit 85db345)
- **位置**: L359 `[[ "$line" == "$header"* ]]`
- **问题**: glob 匹配 `## Status*` 会误匹配 `## StatusReport`、`## StatusUpdate` 等标题名称包含目标前缀的段落。
- **场景**: `--replace-section "## Status"` 但文档中同时存在 `## Status` 和 `## StatusHistory`，后者内容会被错误覆盖。
- **修复**: 改为 regex 精确匹配：`[[ "$line" =~ ^"$header"[[:space:]]*$ ]]`
- **优先级**: P0 — 数据正确性

### [x] #3 size 计算不一致 ← 同步正确性 Bug — ✅ 已修复
- **位置**: L209 `calculate_size_for_livesync` vs L320 `build_doc_json_for_insert`
- **问题**: 
  - `calculate_size_for_livesync`: `sub("\n+$";"")` — 去除**所有**尾部换行
  - `build_doc_json_for_insert`: `sub("\n$";"")` — 只去除**一个**尾部换行
- **场景**: 内容为 `"text\n\n"` 时，两个计算得出不同 size。INSERT 存储的 size 与 LiveSync 期望的 size 不一致，可能导致同步校验失败。
- **修复**: `build_doc_json_for_insert` 统一使用 `sub("\n+$";"")`
- **优先级**: P0 — 同步正确性

---

## 🟠 高 (Robustness / Reliability)

### [x] #4 `--content ""` 空值处理缺陷 — ✅ 已修复
- **位置**: L431 `[[ -n "${CONTENT:-}" ]]`
- **问题**: 用户显式传 `--content ""` 时 `-n` 对空串返回 false，fall through 到 stdin 检查，最终报 `"missing_content"`。
- **修复**: 引入 `CONTENT_SET` 标记变量区分"未传"和"传空值"，INSERT 和 UPDATE 均已适配
- **优先级**: P1

### [x] #5 `--changes` 参数未校验 — ✅ 已修复
- **位置**: L476 直接使用 `$CHANGES_LIMIT`
- **问题**: `--changes abc` 将非数字传给 CouchDB，产生难以解析的错误。
- **修复**: 添加 `[[ "$CHANGES_LIMIT" =~ ^[0-9]+$ ]]` 校验，返回 `invalid_parameter` JSON 错误
- **优先级**: P1

### [x] #6 `resolve_latest_rev` 失败无结构化错误 — ✅ 已修复
- **位置**: L313 `echo "ERROR: Could not resolve rev" >&2`
- **问题**: 错误消息是 raw 文本而非 JSON。`cmd_delete` for 循环中若某 doc 的 rev 解析失败，后续操作静默跳过。
- **修复**: 输出 JSON 格式错误 `{"success":false,"error":"rev_not_found",...}` 到 stderr
- **优先级**: P1

### [x] #7 `_curl` 缺少 `--connect-timeout` — ✅ 已修复
- **位置**: L50-71 `_curl` 函数
- **问题**: 默认 curl 超时可能长达数分钟（取决于 OS）。代理不可达时用户长时间等待。
- **修复**: 添加 `--connect-timeout 10 --max-time 120`
- **优先级**: P1

### [x] #8 `local` 屏蔽命令替换退出码 (SC2155) — ✅ 已修复（关键路径）
- **位置**: 多处 (L85-89, L99-101, L320, L343 等，约 15-20 处)
- **问题**: `local x=$(command)` 吞掉 `command` 的退出码。`set -e` 下 `local` 声明是已知例外。
- **修复**: 关键 `_curl` 调用处（`check_doc_exists`、`curl_get_doc`、`resolve_latest_rev`、`curl_delete_doc_purge`、`curl_delete_node`）已拆分为 `local var; var=$(...) || return`。纯 jq 本地变换保持原样（风险极低）
- **优先级**: P2 — 实用风险低但属规范缺陷

---

## 🟡 中 (Code Quality / Maintainability)

### [x] #9 重复 CRLF 解码逻辑 — ✅ 已修复
- **位置**: L249-251 ≈ L260-262
- **问题**: `\n`/`\r` 解码在单 child 和多 children 两个分支中完全重复
- **修复**: 提取 `decode_content_newlines()` helper，两个分支统一调用

### [x] #10 `curl_delete_doc_purge` 多余 `2>&1` — ✅ 已修复
- **位置**: L158, L167
- **问题**: `_curl` 内部已合并 stderr，外层 `2>&1` 冗余
- **修复**: 移除两处冗余 `2>&1`

### [x] #11 变量命名混乱 — ✅ 已修复
- **位置**: L8 `DEFAULT_HOST` vs L13 `HOST`
- **问题**: CLI 参数用 `HOST`，env 用 `DEFAULT_HOST`，`validate_connection` 中交叉赋值
- **修复**: 添加注释说明 DEFAULT_* 为 env fallback、CLI 变量为覆盖源，拆分后职责更清晰

### [x] #12 `validate_connection` 职责混杂 — ✅ 已修复
- **位置**: L583-597
- **问题**: 同时做变量合并（env→CLI alias）和必填校验
- **修复**: 拆为 `merge_config()` + `validate_config()`，`validate_connection()` 保留为兼容入口

### [ ] #13 重试策略过于简单
- **位置**: L379-392
- **问题**: 固定 0.5 秒延迟无指数退避。高并发场景下可能导致连续冲突 (thundering herd)

### [ ] #14 Cookie Auth 可替代 Basic Auth
- **位置**: `_curl` 函数 (L50-71)
- **问题**: Basic Auth 每次请求触发 PBKDF2 哈希（CPU 密集）。Cookie Auth 一次认证后可复用 session cookie 10 分钟，降低服务端 CPU
- **参考**: [CouchDB Auth Docs](https://docs.couchdb.org/en/stable/api/server/authn.html)

### [x] #15 `generate_node_id` 理论缺陷 — ✅ 已修复
- **位置**: L189
- **问题**: `tr -dc 'a-f0-9'` 过滤后可能少于 13 字符（概率极低但非零）
- **修复**: 添加 while 循环确保生成满 13 字符

### [x] #16 `curl_get_doc` 错误输出格式不一致 — ✅ 已修复
- **位置**: L106
- **问题**: 返回 `{"error":"not_found",...}` 而非标准 `{"success":false,...}` 包装
- **修复**: 错误分支输出 `{success:false, error:..., reason:...}` 标准格式

---

## 🟢 低 (Documentation / Tooling)

### [ ] #17 SKILL.md 头部描述缺少 `--file` 提及
- **位置**: SKILL.md:8
- **问题**: "Supports stdin pipe input, env var authentication..." 未提及 `--file`

### [ ] #18 `--help` 未按命令分组
- **位置**: L633-665 `show_help`
- **问题**: 列出所有参数，难以区分哪些适用 INSERT / 哪些适用 DELETE / 哪些适用 SELECT

### [ ] #19 缺少 CI 配置
- **问题**: 缺少 shellcheck 静态检查 + 跨平台自动化测试

### [ ] #20 `sanitize_content` 命名误导
- **位置**: L197
- **问题**: 实际做 Tab→Space + CRLF→LF 标准化，非安全过滤

### [ ] #21 README 中 `_purge` 未注明需要 admin 权限
- **位置**: README.md / README.zh.md
- **问题**: CouchDB 3.0+ `_purge` endpoint 限 server admin

---

## 修复优先级矩阵

```
优先级 \ 改动量    小(1-3行)    中(5-15行)    大(重构)
─────────────────────────────────────────────────
严重   ██ #2(标题匹配)  #1(SSL默认)   —
       ██ #3(size统一)
高     ██ #5(changes)   #4(空值)      #6(rev错误)
       #7(timeout)
中     ██ #9(去重)      #11(变量)     #13(重试)
       #10(冗余pipe)    #12(拆分)     #14(CookieAuth)
低     ██ #17(docs)     #19(CI)       —
```

## 建议实施顺序

**Phase 1** (5处，预计30分钟): #1 SSL → #2 标题匹配 → #3 size统一 → #5 changes校验 → #7 timeout

**Phase 2** (5处，预计1-2小时): #4 空值 → #6 rev错误 → #8 SC2155 → #9 去重 → #10-11-12 重构

**Phase 3** (可选增强): #13 退避重试 → #14 CookieAuth → #19 CI
