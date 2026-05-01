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

### [x] #14 Cookie Auth 可替代 Basic Auth — ✅ 已修复
- **位置**: `_curl` 函数 (L50-71)
- **问题**: Basic Auth 每次请求触发 PBKDF2 哈希（CPU 密集）。Cookie Auth 一次认证后可复用 session cookie 10 分钟，降低服务端 CPU
- **修复**: 添加 `_authenticate()` 在 `validate_connection` 中建立 Cookie Auth 会话，`_curl` 自动附带 cookie jar。Basic Auth 仍作为 fallback
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

### [x] #17 SKILL.md 头部描述缺少 `--file` 提及 — ✅ 已修复
- **位置**: SKILL.md:8
- **问题**: "Supports stdin pipe input, env var authentication..." 未提及 `--file`
- **修复**: 添加 "file input" 到描述中

### [x] #18 `--help` 未按命令分组 — ✅ 已修复
- **位置**: L633-665 `show_help`
- **问题**: 列出所有参数，难以区分哪些适用 INSERT / 哪些适用 DELETE / 哪些适用 SELECT
- **修复**: 按命令分组参数，每个命令单独列出其可用参数

### [ ] #19 缺少 CI 配置
- **问题**: 缺少 shellcheck 静态检查 + 跨平台自动化测试

### [x] #20 `sanitize_content` 命名误导 — ✅ 已修复
- **位置**: L197
- **问题**: 实际做 Tab→Space + CRLF→LF 标准化，非安全过滤
- **修复**: 重命名为 `normalize_content`

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

---

## LiveSync 源码研究：删除机制

> 研究日期: 2026-05-01 | 源码仓库: `vrtmrz/obsidian-livesync` + `vrtmrz/livesync-commonlib`

### 关键源文件

| 文件 | 仓库 | 作用 |
|------|------|------|
| `src/common/models/db.type.ts` | livesync-commonlib | 文档类型定义 (DatabaseEntry, EntryBase, PlainEntry, NewEntry 等) |
| `src/common/models/db.definition.ts` | livesync-commonlib | EntryDoc 联合类型, EntryBody, isMetaEntry |
| `src/common/models/db.const.ts` | livesync-commonlib | EntryTypes 常量 (notes, newnote, plain, leaf 等) |
| `src/managers/EntryManager/EntryManagerImpls.ts` | livesync-commonlib | **核心删除逻辑** `deleteDBEntryByPath()` |
| `src/managers/ConflictManager.ts` | livesync-commonlib | 冲突处理和自动合并 |
| `src/pouchdb/LiveSyncLocalDB.ts` | livesync-commonlib | DB 操作封装, `removeRevision()` |
| `src/serviceFeatures/offlineScanner.ts` | livesync-commonlib | 过期删除元数据清理 `collectDeletedFiles()` |
| `src/managers/StorageEventManager.ts` | livesync-commonlib | 文件事件监听 (CREATE/CHANGED/DELETE/RENAME) |
| `src/common/models/setting.type.ts` | livesync-commonlib | `DeletedFileMetadataSettings` 设置定义 |

### 文档结构

LiveSync 在 CouchDB 中的文档结构由以下类型组成：

```typescript
// 数据库基础字段 (CouchDB 原生)
interface DatabaseEntry {
    _id: DocumentID;         // 文档 ID（由文件路径 hash 或直接路径生成）
    _rev?: string;           // CouchDB revision
    _deleted?: boolean;      // CouchDB 原生删除标记（tombstone）
    _conflicts?: string[];   // 冲突 revisions
}

// 文件元数据
type EntryBase = {
    ctime: number;           // 创建时间 (epoch ms)
    mtime: number;           // 修改时间 (epoch ms)
    size: number;            // 文件大小 (bytes)
    deleted?: boolean;       // ★ LiveSync 自定义删除标记
};

// Eden（内联 chunk 缓存，用于小文件优化）
type EntryWithEden = {
    eden: Record<DocumentID, EdenChunk>;
};

// 实际文件条目类型
type PlainEntry = DatabaseEntry & EntryBase & EntryWithEden & {
    path: FilePathWithPrefix;
    children: string[];      // chunk IDs（内容分片引用）
    type: "plain";           // 纯文本
};

type NewEntry = DatabaseEntry & EntryBase & EntryWithEden & {
    path: FilePathWithPrefix;
    children: string[];
    type: "newnote";         // 二进制
};

// 旧格式（data 直接存内容，无 children）
type NoteEntry = DatabaseEntry & EntryBase & EntryWithEden & {
    path: FilePathWithPrefix;
    data: string | string[];
    type: "notes";           // 已废弃，仅为兼容
};

// chunk 类型
type EntryLeaf = DatabaseEntry & {
    type: "leaf";
    data: string;
};
```

### 文件类型常量

```typescript
const EntryTypes = {
    NOTE_LEGACY: "notes",      // 旧格式（直接存数据）
    NOTE_BINARY: "newnote",    // 新格式二进制
    NOTE_PLAIN: "plain",       // 新格式纯文本
    CHUNK: "leaf",             // 内容分片
    CHUNK_PACK: "chunkpack",   // 批量分片
    VERSION_INFO: "versioninfo",
    SYNC_INFO: "syncinfo",
    MILESTONE_INFO: "milestoneinfo",
    NODE_INFO: "nodeinfo",
};
```

### 核心删除逻辑

**源码位置**: `EntryManagerImpls.ts` → `deleteDBEntryByPath()`

LiveSync 使用**两级删除机制**：

#### 级别 1：软删除（正常文件删除）

```typescript
// 正常删除 (revDeletion = false)
obj.deleted = true;          // ★ 自定义字段，不是 _deleted
obj.mtime = Date.now();      // 更新修改时间为删除时间

// 仅当用户设置开启时才同时设置 CouchDB tombstone
if (settings.deleteMetadataOfDeletedFiles) {
    obj._deleted = true;
}

await localDatabase.put(obj, { force: true });
```

**此时文档状态**：
- `deleted: true` — LiveSync 自定义标记
- `_deleted: false/undefined` — 文档在 CouchDB 中仍然可见
- `children` — **保持不变**，不清空
- `size` — **保持不变**
- `ctime` — **保持不变**
- `mtime` — **更新为 `Date.now()`**
- `data` / `eden` / `type` / `path` — **保持不变**
- `force: true` — 即使有冲突也强制写入

#### 级别 2：硬删除

三种情况会设置 `_deleted: true`：

1. **旧 "notes" 格式** → 直接 `_deleted = true`
2. **删除特定 revision** (`revDeletion = true`) → `_deleted = true`
3. **过期元数据自动清理** → 由 `collectDeletedFiles()` 执行

#### 过期元数据清理

```typescript
// offlineScanner.ts → collectDeletedFiles()
const limitDays = settings.automaticallyDeleteMetadataOfDeletedFiles;
const limit = Date.now() - 86400 * 1000 * limitDays;

for await (const doc of localDatabase.findAllDocs({ conflicts: true })) {
    if (isAnyNote(doc) && doc.deleted && doc.mtime - limit < 0) {
        // 超过保留天数 → 设置 CouchDB tombstone
        delDoc._deleted = true;
        await localDatabase.putRaw(delDoc);
    }
}
```

### 目录删除

LiveSync **完全不跟踪文件夹**。所有文件夹事件被忽略：

```typescript
// StorageEventManager.ts
protected watchVaultDelete(file, ctx) {
    if (this.adapter.typeGuard.isFolder(file)) return;  // 跳过
    // ...
}
```

文件夹由文件路径隐含存在。设置 `doNotDeleteFolder` 控制是否在存储端删除空文件夹。

### 文件重命名

重命名被分解为 DELETE + CREATE 两个原子操作：

```typescript
watchVaultRename(file, oldPath, ctx) {
    this.appendQueue([
        { type: "DELETE", file: { path: oldPath, deleted: true }, skipBatchWait: true },
        { type: "CREATE", file: newFileInfo, skipBatchWait: true },
    ]);
}
```

### CouchDB `_purge` API

LiveSync **不使用 `_purge` API**。所有删除通过 PouchDB `put()` 实现。

### 冲突处理

- 正常删除使用 `force: true`：即使有冲突也强制覆盖
- `removeRevision()` 对特定 rev 设置 `_deleted: true`
- 自动合并时，若两个冲突版本都标记为 `deleted`，视为已一致（返回 `false` 不合并）
- 读取 entry 时，`includeDeleted` 参数控制是否返回已删除文档：
  ```typescript
  const deleted = (obj as any)?.deleted ?? obj._deleted ?? undefined;
  if (!includeDeleted && deleted) return false;
  ```
- chunk 清理 (`allChunks()`) 会检查所有冲突版本的 children，防止误删仍在使用的 chunk

### 相关设置

| 设置名 | 类型 | 作用 |
|--------|------|------|
| `deleteMetadataOfDeletedFiles` | boolean | 删除时是否同时设置 `_deleted: true` |
| `automaticallyDeleteMetadataOfDeletedFiles` | number (天) | 软删除多少天后自动硬删除 |
| `trashInsteadDelete` | boolean | 存储端：移到回收站而非直接删除 |
| `doNotDeleteFolder` | boolean | 存储端：即使文件夹变空也不删除 |

### 对 couchdb.sh 脚本的影响

`couchdb.sh` 的 DELETE 命令已与 LiveSync 行为**一致** (2026-05-01 修复)。

**当前行为（软删除）**：
1. 保留文档可见性（不设置 `_deleted`）
2. 设置 `deleted: true`（LiveSync 自定义字段）
3. 更新 `mtime = Date.now()`
4. 保留 `children`, `size`, `ctime`, `eden`, `type`, `path`
5. 不清理 leaf nodes（与 LiveSync 一致）

**Purge 模式 (`--purge`)**：
1. 清理 leaf nodes
2. 使用 CouchDB `_purge` API 彻底删除文档
3. 此模式为脚本扩展功能，LiveSync 本身不使用 `_purge`

---

## couchdb.sh vs LiveSync 官方源码：全机制对比报告

> 对比日期: 2026-05-01
> couchdb.sh 版本: 当前工作区 (约 850 行)
> LiveSync 版本: main branch (commit fa7ef62, 2026-04-29)
> 对比范围: 所有 CRUD 操作、文档格式、ID 生成、chunk 处理、冲突处理、认证等

### 对比总览

| 机制 | couchdb.sh | LiveSync 官方 | 差异严重程度 |
|------|-----------|--------------|------------|
| **删除方式** | 软删除（保留 children） | 软删除（保留 children） | ✅ 已修复 |
| **Chunk ID 生成** | 随机 hex | 内容 hash（确定性） | 🟠 高 |
| **内容分片** | 单 chunk | 多 chunk 智能分割 | 🟡 中（可接受） |
| **Document ID** | path 转小写 | path2id（可能含 hash/混淆） | 🟡 中 |
| **Size 计算** | wc -c（去尾换行） | Blob.size | 🟡 中 |
| **Content 标准化** | Tab→4空格, CRLF→LF | 无显式标准化 | 🟡 中 |
| **Eden** | 创建时 `eden:{}` 不使用 | 小文件内联优化 | 🟢 低 |
| **冲突处理** | 重试 0.5s 间隔 | serialized 锁 + force:true | 🟡 中 |
| **_purge API** | 支持 `--purge` 选项 | 从不使用 | 🟡 中（脚本扩展） |
| **认证** | Cookie Auth + Basic Auth | PouchDB 内置 | 🟢 一致 |
| **文档结构** | 基本一致 | 基本一致 | 🟢 一致 |

---

### 1. Document ID 生成

**couchdb.sh**:
```bash
local doc_id_lower=$(echo "$DOC_ID" | tr '[:upper:]' '[:lower:]')
# _id = 文件路径的小写版
# 例: "AgentMemory/note.md" → _id: "agentmemory/note.md"
```

**LiveSync 官方**:
```typescript
// 取决于设置:
// 1. 无路径混淆: _id = path 的小写
// 2. usePathObfuscation: _id = hash(path) 加前缀
const id = await host.services.path.path2id(path);
```

**差异**:
- 当 `usePathObfuscation = false` 时行为一致（`path` 转小写）
- 当启用路径混淆时，LiveSync 使用 hash 作为 `_id`，此时 couchdb.sh 无法直接通过文件路径找到文档
- couchdb.sh 目前只支持无混淆模式，这是合理的（混淆模式主要用于 E2EE 场景）

---

### 2. Chunk ID 生成 🔴

**couchdb.sh**:
```bash
generate_node_id() {
  local id
  id=$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 13)
  echo "h:${id}"
}
# 结果: "h:" + 13位随机hex → 如 "h:a1b2c3d4e5f67"
```

**LiveSync 官方**:
```typescript
// EntryManagerImpls.ts → prepareChunk()
export async function prepareChunk({ chunkManager, hashManager }, piece) {
    // 先从缓存查找
    const cachedChunkId = chunkManager.getChunkIDFromCache(piece);
    if (cachedChunkId !== false) {
        return { isNew: false, id: cachedChunkId, piece: piece };
    }
    // 基于内容 hash 生成确定性 ID
    const chunkId = (await hashManager.computeHash(piece)) as DocumentID;
    return { isNew: true, id: `${IDPrefixes.Chunk}${chunkId}`, piece: piece };
}
// IDPrefixes.Chunk = "h:" → 结果: "h:" + hash(content)
```

**关键差异**:
| | couchdb.sh | LiveSync |
|---|---|---|
| ID 前缀 | `h:` | `h:` (来自 IDPrefixes.Chunk) |
| 生成方式 | **随机** | **内容 hash**（确定性） |
| 相同内容 | 每次生成不同 ID | 始终相同 ID（去重） |
| 缓存 | 无 | 有（getChunkIDFromCache） |

**影响**:
- couchdb.sh 的随机 ID 意味着每次更新会创建全新 chunk，即使内容没有变化
- LiveSync 的 hash-based ID 实现了**内容寻址去重**：相同内容只存一份 chunk
- 不影响功能正确性（LiveSync 能正常读取随机 ID 的 chunk），但浪费存储空间

---

### 3. 内容分片（Chunking）

**couchdb.sh**:
```bash
# INSERT: 整个文件内容 → 单个 chunk
local encoded=$(encode_content_json "$content")
curl_insert_node "$base_url" "$node_id" "$encoded" ...
# children = ["h:single_node_id"]

# UPDATE (非 append): 同样单 chunk
final_children=$(jq -c -n --arg n "$new_node" '[$n]')

# UPDATE (append): 添加新 chunk 到现有 children
final_children=$(echo "$current_children" | jq -c --arg new "$new_node" '. + [$new]')
```

**LiveSync 官方**:
```typescript
// EntryManagerImpls.ts → createChunks()
const pieces = await splitter.splitContent(note);
for await (const piece of pieces) {
    const chunk = await prepareChunk(managers, piece);
    await addBuffer(chunk.id, chunk.piece);
}
// children = ["h:hash1", "h:hash2", "h:hash3", ...]
```

**差异**:
- couchdb.sh 将整个文件内容作为**一个 chunk** → `children` 只有一个元素
- LiveSync 使用 `ContentSplitter` 将内容**按行/段落智能分割**为多个 chunk
- LiveSync 分割后每个 chunk 通过 hash 去重，重复内容不会被重新上传
- 两者在功能上兼容：LiveSync 读取时只是把所有 children 的 data 拼接

**实际影响**:
- couchdb.sh 的单 chunk 模式在小文件（<几KB）场景下完全没问题
- 大文件场景下效率低于 LiveSync（无法增量更新、无法去重）
- 对于脚本的典型用途（Agent Memory 笔记，通常几KB），单 chunk 可接受

---

### 4. 内容标准化

**couchdb.sh**:
```bash
normalize_content() { printf '%s' "$1" | sed 's/\r$//' | sed 's/\t/    /g'; }
# 1. CRLF → LF (去除 \r)
# 2. Tab → 4 空格
```

**LiveSync 官方**:
```typescript
// 在 DB 层面没有显式标准化
// Obsidian 本身在保存文件时处理换行
// chunk data 直接存储 splitter 输出的原始文本
```

**差异**:
- couchdb.sh 额外做了 Tab→空格 转换，LiveSync 不做
- 如果 Obsidian vault 中的文件包含 Tab，couchdb.sh 写入的内容会与 LiveSync 产生 diff
- Tab→空格 的转换是 couchdb.sh 的设计选择（Obsidian 默认使用空格），但可能导致与某些文件不一致

---

### 5. Size 计算 🟡

**couchdb.sh**:
```bash
calculate_size_for_livesync() {
  printf '%s' "$1" | jq -sRj 'sub("\n+$";"")' | wc -c | tr -d ' '
}
# = 去除尾部所有换行后的 UTF-8 字节数
```

**LiveSync 官方**:
```typescript
// putDBEntry() in EntryManagerImpls.ts
const data = note.data instanceof Blob ? note.data : createTextBlob(note.data);
// newDoc.size = note.size
// note.size 来自 Obsidian 的 file.stat.size → 文件系统实际大小
```

**差异**:
- couchdb.sh: 去除尾部换行后的字节数
- LiveSync: 直接使用文件系统报告的大小（`stat.size`）
- 差异来源: Obsidian 在保存文件时可能保留尾部换行，而 `stat.size` 包含这些换行
- 在 CONTEXT.md 的审查中已标记为 #3 并修复了 size 计算在脚本内部的不一致性

---

### 6. 删除机制 🔴（已在上一节详述，此处补充对比）

**couchdb.sh 的 `curl_delete_doc_soft()`** (已修复):
```bash
local updated=$(echo "$doc_json" | jq -c --arg mt "$timestamp" \
  '.deleted = true | .mtime = ($mt|tonumber)')
# 1. deleted = true
# 2. mtime = now
# children, size, ctime, eden, type, path — 全部保留
```

**LiveSync 官方的 `deleteDBEntryByPath()`**:
```typescript
obj.deleted = true;
obj.mtime = Date.now();
// children → 不修改（保持原值）
// size → 不修改（保持原值）
// ctime → 不修改
// data/eden/type/path → 不修改
```

| 字段 | couchdb.sh | LiveSync | 一致? |
|------|-----------|----------|-------|
| `deleted` | `true` | `true` | ✅ |
| `mtime` | `Date.now()` | `Date.now()` | ✅ |
| `children` | **保持原值** | **保持原值** | ✅ |
| `size` | **保持原值** | **保持原值** | ✅ |
| `ctime` | 不变 | 不变 | ✅ |
| `type` | 不变 | 不变 | ✅ |
| `path` | 不变 | 不变 | ✅ |
| `eden` | 不变 | 不变 | ✅ |

**状态**: ✅ 已修复 (2026-05-01)
- children 和 size 现在与 LiveSync 行为完全一致
- 软删除时不清理 leaf nodes（与 LiveSync 一致，仅 purge 模式清理）

---

### 7. INSERT 文档创建

**couchdb.sh**:
```bash
build_doc_json_for_insert() {
  local id_lower=$(echo "$doc_id" | tr '[:upper:]' '[:lower:]')
  local size=$(printf '%s' "$content" | jq -sRj 'sub("\n+$";"")' | wc -c | tr -d ' ')
  jq -c -n --arg id "$id_lower" --arg path "$DOC_ID" --argjson children "$children" \
    --arg ctime "$timestamp" --arg mtime "$timestamp" --arg size "$size" \
    '{_id:$id,path:$path,children:$children,ctime:($ctime|tonumber),mtime:($mtime|tonumber),size:($size|tonumber),type:"plain",eden:{}}'
}
```

**LiveSync 官方**:
```typescript
const newDoc: PlainEntry | NewEntry = {
    children: chunks,          // 多个 chunk IDs
    _id: note._id,
    path: note.path,
    ctime: note.ctime,
    mtime: note.mtime,
    size: note.size,
    type: note.datatype,       // "plain" 或 "newnote"
    eden: {},
};
```

**差异**:
| 字段 | couchdb.sh | LiveSync | 一致? |
|------|-----------|----------|-------|
| `_id` | path 小写 | path2id（取决于设置） | 🟡 条件一致 |
| `path` | 原始 DOC_ID | note.path | ✅ |
| `children` | 单 chunk | 多 chunk | 🟡 兼容 |
| `ctime` | 当前时间 | 文件创建时间 | 🟡 可接受 |
| `mtime` | 当前时间 | 文件修改时间 | 🟡 可接受 |
| `size` | 去尾换行字节数 | stat.size | 🟡 可能不同 |
| `type` | 固定 "plain" | "plain" 或 "newnote" | 🟡 脚本只处理文本 |
| `eden` | `{}` | `{}` | ✅ |

---

### 8. UPDATE 文档更新

**couchdb.sh**:
```bash
build_doc_json_for_update() {
  echo "$current_doc" | jq -c \
    --argjson nc "$children_json" --arg mt "$timestamp" --arg ns "$new_size" \
    '.children=$nc | .mtime=($mt|tonumber) | .size=($ns|tonumber)'
}
# 更新: children, mtime, size
# 保留: _id, path, ctime, type, eden, deleted 等
```

**LiveSync 官方**:
```typescript
const newDoc: PlainEntry | NewEntry = {
    children: chunks,         // 完全替换
    _id: note._id,
    path: note.path,
    ctime: note.ctime,        // 保留原始
    mtime: note.mtime,        // 更新
    size: note.size,           // 更新
    type: note.datatype,
    eden: {},                  // 重置为空
};
// 然后获取旧 rev，设置 _rev，force put
```

**差异**:
- couchdb.sh 在更新时保留了原文档的大部分字段（包括 `eden`），只更新 children/mtime/size
- LiveSync 创建一个全新文档对象（eden 重置为 `{}`），然后设置 `_rev`
- 两者功能等效：都是通过 CouchDB PUT/bulk_docs 实现乐观锁更新

**couchdb.sh 的 append 模式** 在 LiveSync 中没有对应功能（LiveSync 总是完全替换 children）

---

### 9. SELECT / 读取

**couchdb.sh**:
```bash
resolve_full_content() {
  local children=$(echo "$doc_json" | jq -r '.children[]? // empty')
  if [[ -z "$children" ]]; then
    # 旧格式: data 字段直接包含内容
    local raw=$(echo "$doc_json" | jq -r '.data // empty')
    decode_content_newlines "$raw"
    return
  fi
  # 新格式: 通过 children IDs 获取 chunk 内容
  local keys_json=$(echo "$children" | jq -R . | jq -s .)
  local result=$(_curl ... "_all_docs?include_docs=true&keys=${encoded_keys}")
  local raw=$(echo "$result" | jq -r '[.rows[].doc.data // empty] | join("")')
  decode_content_newlines "$raw"
}
```

**LiveSync 官方**:
```typescript
// respondEntryFromMeta()
// 1. 先处理 eden chunks（内联小 chunk）
let edenChunks = {};
if (meta.eden && Object.keys(meta.eden).length > 0) {
    const chunks = Object.entries(meta.eden).map(([id, data]) => ({
        _id: id, data: data.data, type: "leaf",
    }));
    edenChunks = Object.fromEntries(chunks.map(e => [e._id, e]));
}
// 2. 从 chunkManager 读取 children chunks
const chunks = await chunkManager.read(childrenKeys, options, edenChunks);
// 3. 拼接内容
const doc = { data: chunks.map(e => e.data), ... };
```

**差异**:
- couchdb.sh 不处理 `eden` 中的内联 chunk（设置为 `{}`，不影响自身创建的文档）
- LiveSync 支持 on-demand chunk 远程获取（带超时和重试），couchdb.sh 只做直接查询
- 两者内容拼接逻辑一致：按 children 顺序拼接 data
- couchdb.sh 的 `decode_content_newlines()` 处理 `\\n` → 实际换行，这与 LiveSync 的 chunk data 存储格式一致

---

### 10. 目录列表

**couchdb.sh**:
```bash
curl_list_dir() {
  local prefix=$(echo "$2" | tr '[:upper:]' '[:lower:]' | sed 's|/$||')
  # 使用 CouchDB _all_docs 的 startkey/endkey 范围查询
  _curl ... "_all_docs?startkey=${enc_start}&endkey=${enc_end}&include_docs=true"
}

format_dir_listing() {
  # 过滤 h: 前缀 (chunk) 和 _ 前缀 (内部文档)
  # 过滤 deleted == true 的文档
  # 按 / 分割路径，生成文件/目录列表
}
```

**LiveSync 官方**:
```typescript
// offlineScanner.ts → collectDatabaseFiles()
for await (const doc of localDatabase.findAllNormalDocs({ conflicts: true })) {
    // findAllNormalDocs 过滤 type == "newnote" || type == "plain"
    // 排除 _id 以 _ 开头的内部文档
    // 排除 VERSIONING_DOCID
    if (isMetaEntry(doc)) {
        _DBEntries.push(doc);
    }
}
```

**差异**:
- couchdb.sh 使用 `_all_docs` 范围查询（CouchDB 原生），按路径前缀过滤
- LiveSync 遍历所有文档，按 type 过滤
- couchdb.sh 的过滤条件 `select(.doc.deleted != true)` 与 LiveSync 的 `w.deleted || w._deleted` 逻辑一致
- 两者都排除 chunk 文档（`h:` 前缀）和内部文档（`_` 前缀）

---

### 11. 冲突处理

**couchdb.sh**:
```bash
retry_on_conflict() {
  local attempt=0
  while [[ $attempt -lt $MAX_RETRIES ]]; do
    local result=$("$func" "$@")
    if ... error == "conflict" ...; then
      attempt=$((attempt + 1))
      sleep 0.5     # 固定 0.5 秒延迟
    else
      echo "$result"; return
    fi
  done
}
```

**LiveSync 官方**:
```typescript
// 使用序列化锁防止并发写入同一文件
await serialized("file:" + filename, async () => {
    const old = await localDatabase.get(newDoc._id);
    newDoc._rev = old._rev;
    const r = await localDatabase.put(newDoc, { force: true });
});
```

**差异**:
| | couchdb.sh | LiveSync |
|---|---|---|
| 并发控制 | 重试（乐观锁） | 序列化锁（悲观锁） |
| 写入策略 | `_bulk_docs`（正常） | `put` + `force: true` |
| 冲突处理 | 最多 3 次重试，固定 0.5s | 锁内操作不会冲突 |
| force 模式 | 否 | 是（正常删除时） |

- couchdb.sh 的乐观锁重试在低并发场景下工作良好
- LiveSync 的 `force: true` 意味着即使有并发冲突也会创建新的冲突分支（而非失败）

---

### 12. 认证

**couchdb.sh**:
```bash
_authenticate() {
  # Cookie Auth: POST /_session
  result=$(curl ... -c "$COOKIE_JAR" -d '{"name":"...","password":"..."}' "/_session")
}
_curl() {
  # 自动附带 cookie jar
  if [[ -n "$COOKIE_JAR" && -s "$COOKIE_JAR" ]]; then
    cookie_args=(-b "$COOKIE_JAR" -c "$COOKIE_JAR")
  fi
}
```

**LiveSync 官方**:
- 使用 PouchDB 内置的认证机制
- 通过 `couchDB_USER` / `couchDB_PASSWORD` 配置

**评价**: couchdb.sh 的 Cookie Auth + Basic Auth fallback 与 CouchDB 最佳实践一致，减少 PBKDF2 开销。✅

---

### 13. Chunk/Leaf 节点格式

**couchdb.sh**:
```bash
curl_insert_node() {
  local node_json=$(jq -c -n --arg id "$node_id" --argjson data "$content_json" \
    '{_id: $id, type: "leaf", data: $data}')
  _curl ... -X PUT ... -d "$node_json" "${base_url}/${node_id}"
}
```

**LiveSync 官方**:
```typescript
const chunk = {
    _id: id,
    data: data,
    type: "leaf",
} as const;
// 通过 chunkManager.write() 批量写入
```

**差异**:
- 文档格式完全一致：`{_id, type: "leaf", data}`
- couchdb.sh 使用 PUT 单条写入，LiveSync 可能使用 `bulkDocs` 批量写入
- chunk data 编码方式一致（JSON 字符串，`\n` 编码为 `\\n`）

---

### 14. Eden 机制

**couchdb.sh**: 创建时设置 `eden: {}`，不使用 eden 功能

**LiveSync 官方**:
```typescript
// Eden 是一种优化：将小 chunk 内联到文档本身
// 减少小文件的 CouchDB 请求数
type EntryWithEden = {
    eden: Record<DocumentID, EdenChunk>;
};
type EdenChunk = {
    data: string;
    epoch: number;
};
```

**影响**: couchdb.sh 创建的文档不使用 eden，但 LiveSync 读取时不受影响（eden 为空时直接走 children 路径）

---

### 15. LiveSync-deleted 文档的恢复（re-insert）

**couchdb.sh**:
```bash
# INSERT 时检测到 deleted == true → 更新覆盖
local updated=$(echo "$existing" | jq -c --arg n "$node_id" --arg mt "$timestamp" --arg sz "$size" \
  '.children = [$n] | .size = ($sz|tonumber) | .mtime = ($mt|tonumber) | del(.deleted)')
# 1. 替换 children
# 2. 更新 size, mtime
# 3. 删除 deleted 字段
```

**LiveSync 官方**:
- LiveSync 没有显式的"恢复已删除文档"逻辑
- 如果一个文件在存储端重新创建，`storeFileToDB()` → `putDBEntry()` 会创建全新文档覆盖（通过获取旧 `_rev`）
- 旧文档的 `deleted: true` 会被完全覆盖（因为 `putDBEntry` 创建的是全新文档对象，不包含 `deleted` 字段）

**差异**: couchdb.sh 的方式（从现有文档上删除 `deleted` 字段）与 LiveSync 的方式（创建全新文档对象）在结果上等效，但实现路径不同。

---

### 16. CouchDB Tombstone 处理

**couchdb.sh**:
```bash
# INSERT 时检测到 CouchDB tombstone → 循环 purge 清除
if echo "$existing" | jq -e '.error == "couchdb_tombstone"'; then
  while [[ $_max_purge -gt 0 ]]; do
    _curl ... -d "$_purge_json" "${base_url}/_purge"
    # 检查是否还有更多 tombstone 层
  done
fi
```

**LiveSync 官方**: 从不使用 `_purge`，也不处理外部创建的 tombstone

**评价**: couchdb.sh 的 tombstone 清理是脚本特有的防御机制，用于处理之前 `--purge` 操作或外部工具留下的 tombstone。LiveSync 不需要此功能。

---

### 总结：需要修复的差异

#### ✅ 已修复

1. **删除时保留 children 和 size** — ✅ 已修复 (2026-05-01)
   - 之前: `.children = [] | .size = 0`（清空）
   - 修复后: 只设置 `deleted: true` + `mtime = now`，保留 `children`、`size`
   - 同时移除了软删除路径中的 `cleanup_leaf_nodes` 调用（与 LiveSync 一致）

#### 🟠 建议评估是否修复

2. **Chunk ID 生成方式**
   - 当前: 随机 hex
   - LiveSync: 内容 hash（确定性去重）
   - 影响: 存储空间浪费（每次更新都创建新 chunk），但功能正确
   - 修复难度: 需要实现 hash 函数（LiveSync 使用 xxhash/murmur），shell 中较难

#### 🟡 低优先级

3. **Tab→空格 标准化**: LiveSync 不做此转换，可能导致 content diff
4. **Size 计算差异**: stat.size vs 去尾换行字节数，实际影响小
5. **内容分片**: 单 chunk vs 多 chunk，对小文件无影响

---

## 重构记录 (2026-05-01)

> 基于 LiveSync 源码研究和全机制对比，对 `couchdb.sh` 进行了完整重构。
> 目标: 逻辑与 LiveSync 官方行为一致，OOP 风格组织代码。

### 重构变更概览

| 类别 | 变更前 | 变更后 | 状态 |
|------|--------|--------|------|
| 删除逻辑 | `.children=[] \| .size=0` 清空数据 | 仅设 `deleted:true` + `mtime=now`，保留 children/size | ✅ 已修复 |
| Chunk ID | 随机 hex (`openssl rand -hex 16`) | SHA-256 内容 hash (`h:` + 32位 hex) | ✅ 已修复 |
| 内容标准化 | CRLF→LF + Tab→4空格 | 仅 CRLF→LF（与 LiveSync 一致） | ✅ 已修复 |
| Chunk 去重 | 无去重（每次新建 chunk） | 相同内容 = 相同 hash = 自动去重（409 conflict 视为成功） | ✅ 新增 |
| 代码组织 | 平铺函数 | `module__function()` 命名空间（8个模块） | ✅ 重构 |

### 模块结构

```
http__        → curl 封装、Cookie Auth、代理、SSL
config__      → 连接配置合并、校验
db__          → CouchDB 低级操作 (get/put/bulk/purge/list/info)
chunk__       → chunk CRUD + 内容 hash 去重
content__     → 编码/解码/标准化/大小计算
doc__         → 文档 JSON 构建/解析/格式化
text__        → 文本操作 (replace_section)
cmd__         → CLI 命令入口 (ping/insert/select/update/delete)
tombstone__   → CouchDB tombstone 多层清理
```

### 关键实现细节

1. **`doc__build_delete()`**: 对应 LiveSync `deleteDBEntryByPath()` — 只修改 `deleted` 和 `mtime`
2. **`chunk__hash_id()`**: 对应 LiveSync `computeHash()` — 使用 `shasum -a 256 | cut -c1-32` + `h:` 前缀
3. **`chunk__create_for_content()`**: 对应 LiveSync `prepareChunk()` — 409 冲突 = 内容已存在（去重成功）
4. **`content__normalize()`**: 对应 LiveSync `normalizeNewlineRecursive()` — 仅 CRLF→LF
5. **`doc__build_restore()`**: 处理 LiveSync 软删除文档的覆盖写入（del deleted + 更新 children/size/mtime）

### CLI 接口

接口完全向后兼容，无破坏性变更：
- `PING` / `INSERT` / `SELECT` / `UPDATE` / `DELETE` 五个命令不变
- 所有 `--xxx` 参数不变
- 新增 `--verify-ssl` 显式启用 SSL 验证（默认行为，与 `--insecure` 互斥）

### 代码规模

- 重构前: ~850 行
- 重构后: 823 行（减少 ~3%，同时新增了 chunk 去重功能）
