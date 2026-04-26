# Obsidian LiveSync CouchDB CRUD Skill

[English](README.md) | [中文](README.zh.md)

An [Agent Skill](https://agentskills.io/) that provides atomic CRUD operations on an Obsidian LiveSync CouchDB database. Create, read, update, and delete Markdown documents in your Obsidian vault **without having Obsidian installed**, fully compatible with the LiveSync plugin (no sync errors).

This skill follows the open [Agent Skills](https://agentskills.io/) standard — a lightweight, portable format for extending AI agent capabilities. It works with any skills-compatible agent client, including Claude Code, GitHub Copilot, Gemini CLI, Roo Code, and [more](https://agentskills.io/clients).

## Features

- **INSERT** — Create documents via `--content`, `--file`, or stdin pipe
- **SELECT** — Read documents, list directories, view recent changes
- **UPDATE** — Full replace, append, or section-level replace with automatic 409 conflict retry
- **DELETE** — Soft delete (preserves history) or purge (permanent removal with leaf node cleanup)
- **PING** — Test CouchDB connection

All commands produce **JSON output** with a unified `success` field.

## Prerequisites

- `curl`, `jq`, `python3`, `perl`, `uuidgen`
- Network access to a CouchDB instance with Obsidian LiveSync configured

## Configuration

Set environment variables or pass CLI flags:

| Variable | CLI Flag | Required | Description |
|---|---|---|---|
| `COUCHDB_HOST` | `--host` | Yes | Host with port, e.g. `obs.example.com:8443` |
| `COUCHDB_USER` | `--user` | Yes | CouchDB username |
| `COUCHDB_PASSWORD` | `--password` | Yes | CouchDB password |
| `COUCHDB_PATH` | `--path` | No | Hidden path prefix, e.g. `/e=_9f3k2a` |
| `COUCHDB_DATABASE` | `--database` | No | Database name, e.g. `obsinote` |

## Usage

### Test Connection

```bash
bash scripts/couchdb.sh PING
```

### Create a Document

```bash
bash scripts/couchdb.sh INSERT --doc-id "Notes/hello.md" --content "# Hello\nWorld"
bash scripts/couchdb.sh INSERT --doc-id "Notes/hello.md" --file /path/to/local.md
echo "# Hello" | bash scripts/couchdb.sh INSERT --doc-id "Notes/hello.md"
```

### Read Documents

```bash
# Single document
bash scripts/couchdb.sh SELECT --doc-id "Notes/hello.md"

# List root directory
bash scripts/couchdb.sh SELECT --list-dir

# List specific directory
bash scripts/couchdb.sh SELECT --list-dir "Notes"

# Recent changes
bash scripts/couchdb.sh SELECT --changes 10
```

### Update a Document

```bash
# Full replace
bash scripts/couchdb.sh UPDATE --doc-id "Notes/hello.md" --content "# New Content"

# Append
bash scripts/couchdb.sh UPDATE --doc-id "Notes/hello.md" --append --content "\n## Added Section"

# Replace a section (preserves header line, replaces content below it)
bash scripts/couchdb.sh UPDATE --doc-id "Notes/hello.md" --replace-section "## Status" --content "- Done: true"
```

### Delete a Document

```bash
# Soft delete (standard Obsidian behavior)
bash scripts/couchdb.sh DELETE --doc-id "Notes/hello.md"

# Purge (permanent, irreversible)
bash scripts/couchdb.sh DELETE --doc-id "Notes/hello.md" --purge

# Delete entire directory
bash scripts/couchdb.sh DELETE --delete-dir "Notes/temp"
```

## Important Notes

- Document IDs are **case-insensitive** (stored as lowercase). Original path casing is preserved in the `path` field.
- `--replace-section` matches any header level (`#` through `######`). It preserves the header line and replaces content below it until the next header of equal or higher level.
- UPDATE automatically retries up to 3 times on CouchDB 409 conflicts.
- Content priority: `--file` > `--content` > stdin.

## License

MIT
