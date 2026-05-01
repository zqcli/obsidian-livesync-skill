# couchdb.sh 测试报告

> 31 个测试场景，全部通过 ✅
> 测试环境：CouchDB 3.5.1 + Nginx 反向代理 (couchdb.example.com:8443)

---

## Group 1: 连接测试 (T1–T3)

| # | 场景 | 命令 | 期望 | 结果 |
|---|------|------|------|------|
| T1 | PING 正常 | `PING` | `{"ok":true}` | ✅ PASS |
| T2 | PING DNS 失败 | `COUCHDB_HOST=bad.host PING` | 连接错误，exit 1 | ✅ PASS |
| T3a | 缺少 HOST | 未设 COUCHDB_HOST | `missing_config` | ✅ PASS |
| T3b | 缺少 USER | 未设 COUCHDB_USER | `missing_config` | ✅ PASS |
| T3c | 缺少 PASSWORD | 未设 COUCHDB_PASSWORD | `missing_config` | ✅ PASS |

## Group 2: INSERT 测试 (T4–T8)

| # | 场景 | 命令 | 期望 | 结果 |
|---|------|------|------|------|
| T4 | --content 插入 | `INSERT --doc-id "…/insert-content.md" --content "…"` | `success:true` | ✅ PASS |
| T5 | --file 插入 | `INSERT --doc-id "…/insert-file.md" --file /tmp/test.md` | `success:true` | ✅ PASS |
| T6 | stdin 插入 | `echo "…" \| INSERT --doc-id "…/insert-stdin.md"` | `success:true` | ✅ PASS |
| T7 | 重复插入 | 对已存在文档再次 INSERT | `doc_exists`, exit 1 | ✅ PASS |
| T8 | 大小写不敏感 | `INSERT --doc-id "…/UPPERCASE.md"` → SELECT 小写 id | id=小写, path=原始大小写 | ✅ PASS |

## Group 3: SELECT 测试 (T9–T14)

| # | 场景 | 命令 | 期望 | 结果 |
|---|------|------|------|------|
| T9 | 读取文档 | `SELECT --doc-id "…/insert-content.md"` | 返回完整内容 | ✅ PASS |
| T10 | list-dir 根目录 | `SELECT --list-dir` / `SELECT --list-dir "/"` | 返回顶层目录列表 | ✅ PASS |
| T11 | list-dir 子目录 | `SELECT --list-dir "AgentMemory/test"` | 列出 4 个文件 | ✅ PASS |
| T12 | changes | `SELECT --changes 3` | 返回 3 条变更记录 | ✅ PASS |
| T13 | 文档不存在 | `SELECT --doc-id "nonexistent/doc.md"` | `not_found`, exit 1 | ✅ PASS |
| T14 | changes 无效参数 | `SELECT --changes abc` | `invalid_parameter` | ✅ PASS |

## Group 4: UPDATE 测试 (T15–T22)

| # | 场景 | 命令 | 期望 | 结果 |
|---|------|------|------|------|
| T15 | 全量替换 | `UPDATE --doc-id "…" --content "…"` | `success:true` | ✅ PASS |
| T16 | --append 追加 | `UPDATE --doc-id "…" --append --content "…"` | children=2 (多叶节点) | ✅ PASS |
| T17 | replace-section 精确匹配 | `UPDATE --replace-section "## Section A"` | Section A 内容被替换 | ✅ PASS |
| T18 | replace-section 前缀匹配 | `UPDATE --replace-section "## Status"` | `## Status` 改变，`## StatusReport` 不变 | ✅ PASS |
| T19 | replace-section 逆序 | StatusReport 在 Status 前面 | 仅 `## Status` 被替换 | ✅ PASS |
| T20 | --file 更新 | `UPDATE --doc-id "…" --file /tmp/update.md` | 内容="Content from file update." | ✅ PASS |
| T21 | 文档不存在 | `UPDATE --doc-id "nonexistent/doc.md"` | `doc_not_found` | ✅ PASS |
| T22 | Tab 规范化 | 插入含 Tab 的内容 | 输出中 Tab 数=0 (全部转为空格) | ✅ PASS |

## Group 5: 软删除测试 (T23–T26)

| # | 场景 | 命令 | 期望 | 结果 |
|---|------|------|------|------|
| T23 | 软删除 | `DELETE --doc-id "…/delete-test.md"` | `success:true` | ✅ PASS |
| T24 | 字段保留 | 检查软删除后文档 | `deleted:true`, children/size/mtime 保留 | ✅ PASS |
| T25 | 重复删除 | 对已软删除文档再删 | `not_found`, exit 1 | ✅ PASS |
| T26 | 目录删除 | `DELETE --delete-dir "…/dir-del"` | deleted_count=2, list-dir 返回 [] | ✅ PASS |

## Group 6: 清除与重新插入 (T27–T29)

| # | 场景 | 命令 | 期望 | 结果 |
|---|------|------|------|------|
| T27 | purge 单文档 | `DELETE --doc-id "…" --purge` | purged:true, all_docs 返回 not_found | ✅ PASS |
| T28 | 软删除后重新插入 | INSERT → DELETE → INSERT | 新内容="re-inserted" | ✅ PASS |
| T29 | SELECT 已删除文档 | INSERT → DELETE → SELECT | `not_found`, exit 1 | ✅ PASS |

## Group 7: 错误处理 (T30a–T30d)

| # | 场景 | 命令 | 期望 | 结果 |
|---|------|------|------|------|
| T30a | 缺少 doc-id | `INSERT --content "…"` (无 --doc-id) | `missing_doc_id`, exit 1 | ✅ PASS |
| T30b | 缺少 content | `INSERT --doc-id "…"` (无内容) | `missing_content`, exit 1 | ✅ PASS |
| T30c | 缺少查询参数 | `SELECT` (无参数) | `missing_query`, exit 1 | ✅ PASS |
| T30d | 缺少删除目标 | `DELETE` (无参数) | `missing_target`, exit 1 | ✅ PASS |

## Group 8: 清理 (T31)

| # | 场景 | 命令 | 期望 | 结果 |
|---|------|------|------|------|
| T31 | 两阶段清理 | soft delete → purge 整个 test 目录 | deleted_count=4 (软删), deleted_count=11 (清除) | ✅ PASS |

---

## 已知注意事项

1. **CouchDB ghost data**：多次创建/删除同一文档会累积冲突修订层。`--purge` 每次只清除一层修订，可能需要多次执行才能完全清除。
2. **macOS `cat -A`**：macOS 原生 `cat` 不支持 `-A` 选项，Tab 检测可用 `grep -cP '\t'` 替代。
3. **软删除字段保留**：`curl_delete_doc_soft` 设置 `.deleted = true` 并更新 `mtime`，保留 `children`、`size` 等字段，兼容 Obsidian LiveSync 同步协议。