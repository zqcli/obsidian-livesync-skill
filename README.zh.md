# Obsidian LiveSync CouchDB CRUD Skill

[English](README.md) | [中文](README.zh.md)

一个符合 [Agent Skills](https://agentskills.io/) 开放标准的 Skill，提供对 Obsidian LiveSync CouchDB 数据库的原子 CRUD 操作。**无需安装 Obsidian 客户端**即可创建、读取、更新和删除 vault 中的 Markdown 文档，与 LiveSync 插件完全兼容（不会产生同步错误）。

本 Skill 遵循 [Agent Skills](https://agentskills.io/) 开放标准——一种轻量级、可移植的 AI 智能体能力扩展格式。可与任何支持该标准的智能体客户端配合使用，包括 Claude Code、GitHub Copilot、Gemini CLI、Roo Code 等（[查看完整列表](https://agentskills.io/clients)）。

## 功能

- **INSERT** — 通过 `--content`、`--file` 或 stdin 管道创建文档
- **SELECT** — 读取文档、列出目录结构、查看最近变更
- **UPDATE** — 全量替换、追加内容、按标题段落替换，内置 409 冲突自动重试
- **DELETE** — 软删除（保留历史）或 purge 永久删除（清理 leaf node 和冲突版本）
- **PING** — 测试 CouchDB 连接

所有命令统一输出 **JSON**，通过 `success` 字段标识成功/失败。

## 前置要求

- `curl`、`jq`、`python3`、`perl`、`uuidgen`
- 需要网络访问已配置 Obsidian LiveSync 的 CouchDB 实例

## 配置

通过环境变量或 CLI 参数设置：

| 环境变量 | CLI 参数 | 必填 | 说明 |
|---|---|---|---|
| `COUCHDB_HOST` | `--host` | 是 | 主机和端口，如 `obs.example.com:8443` |
| `COUCHDB_USER` | `--user` | 是 | CouchDB 用户名 |
| `COUCHDB_PASSWORD` | `--password` | 是 | CouchDB 密码 |
| `COUCHDB_PATH` | `--path` | 否 | 隐藏路径前缀，如 `/e=_9f3k2a` |
| `COUCHDB_DATABASE` | `--database` | 否 | 数据库名称，如 `obsinote` |

## 使用方法

### 测试连接

```bash
bash scripts/couchdb.sh PING
```

### 创建文档

```bash
bash scripts/couchdb.sh INSERT --doc-id "Notes/hello.md" --content "# Hello\nWorld"
bash scripts/couchdb.sh INSERT --doc-id "Notes/hello.md" --file /path/to/local.md
echo "# Hello" | bash scripts/couchdb.sh INSERT --doc-id "Notes/hello.md"
```

### 读取文档

```bash
# 读取单个文档
bash scripts/couchdb.sh SELECT --doc-id "Notes/hello.md"

# 列出根目录
bash scripts/couchdb.sh SELECT --list-dir

# 列出指定目录
bash scripts/couchdb.sh SELECT --list-dir "Notes"

# 查看最近变更
bash scripts/couchdb.sh SELECT --changes 10
```

### 更新文档

```bash
# 全量替换
bash scripts/couchdb.sh UPDATE --doc-id "Notes/hello.md" --content "# 新内容"

# 追加内容
bash scripts/couchdb.sh UPDATE --doc-id "Notes/hello.md" --append --content "\n## 新增章节"

# 按标题段落替换（保留标题行，替换其下方内容）
bash scripts/couchdb.sh UPDATE --doc-id "Notes/hello.md" --replace-section "## 状态" --content "- 完成: true"
```

### 删除文档

```bash
# 软删除（标准 Obsidian 行为，保留历史）
bash scripts/couchdb.sh DELETE --doc-id "Notes/hello.md"

# 永久删除（不可逆）
bash scripts/couchdb.sh DELETE --doc-id "Notes/hello.md" --purge

# 删除整个目录
bash scripts/couchdb.sh DELETE --delete-dir "Notes/temp"
```

## 注意事项

- 文档 ID **大小写不敏感**（统一小写存储），原始路径大小写保留在 `path` 字段中。
- `--replace-section` 匹配任意标题级别（`#` 到 `######`），保留标题行本身，替换其下方内容直到遇到同级或更高级标题。
- UPDATE 操作在遇到 CouchDB 409 冲突时自动重试（最多 3 次）。
- 内容输入优先级：`--file` > `--content` > stdin。

## 许可证

MIT
