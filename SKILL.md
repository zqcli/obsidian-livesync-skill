---
name: obsidian-livesync-skill
description: >
  CRUD operations on Obsidian LiveSync CouchDB database. Insert, select, update,
  and delete Markdown documents that sync with Obsidian via LiveSync plugin.
  Use when the user wants to create, read, update, or delete notes, journal entries,
  or any Markdown documents in their Obsidian vault without having Obsidian installed.
  Supports stdin pipe input, env var authentication, automatic write conflict retry,
  and leaf node cleanup on purge.
license: MIT
compatibility: >
  Requires curl and jq. Needs network access to a
  CouchDB instance with Obsidian LiveSync configured.
metadata:
  author: https://github.com/zqcli
  version: "1.2.0"
allowed-tools: Bash(scripts/couchdb.sh:*)
---

# Obsidian LiveSync CouchDB CRUD Skill

## Overview

This skill provides atomic CRUD operations on an Obsidian LiveSync CouchDB database.
All operations produce JSON output and are compatible with standard Obsidian LiveSync
synchronization (no sync errors on the Obsidian side).

## Prerequisites

Set these environment variables before use:

| Variable | Required | Description |
|---|---|---|
| `COUCHDB_HOST` | Yes | Host with port, e.g. `obs.example.com:8443` |
| `COUCHDB_USER` | Yes | CouchDB username |
| `COUCHDB_PASSWORD` | Yes | CouchDB password |
| `COUCHDB_DATABASE` | Yes | Database name, e.g. `obsinote` |
| `COUCHDB_PATH` | No | Hidden path prefix, e.g. `/e=_9f3k2a` |

Alternatively, pass credentials via CLI flags: `--user`, `--password`, `--host`, `--path`, `--database`.

### Proxy (CLI only)

| Flag | Default | Description |
|---|---|---|
| `--proxy` | none | Proxy address, format `host:port` |
| `--proxy-type` | socks5 | Proxy type: `socks5` or `http` |

```bash
bash scripts/couchdb.sh PING --proxy 127.0.0.1:12080
bash scripts/couchdb.sh PING --proxy proxy.corp.com:8080 --proxy-type http
```

## Commands

### PING — Test connection

```bash
bash scripts/couchdb.sh PING
```

Output: `{"success":true,"db_name":"...","doc_count":...,"update_seq":"..."}`

### INSERT — Create a document

```bash
# Via --content
bash scripts/couchdb.sh INSERT --doc-id "AgentMemory/note.md" --content "# My Note\nContent here"

# Via --file
bash scripts/couchdb.sh INSERT --doc-id "AgentMemory/note.md" --file /path/to/local.md

# Via stdin
echo "# My Note" | bash scripts/couchdb.sh INSERT --doc-id "AgentMemory/note.md"
```

Output: `{"success":true,"rev":"1-xxx","id":"agentmemory/note.md"}`
Error (duplicate): `{"success":false,"error":"doc_exists"}`

### SELECT — Read documents

```bash
# Single document
bash scripts/couchdb.sh SELECT --doc-id "AgentMemory/note.md"

# List root directory (all top-level dirs and files)
bash scripts/couchdb.sh SELECT --list-dir

# List specific directory (immediate children with dir/file types)
bash scripts/couchdb.sh SELECT --list-dir "AgentMemory"

# Recent changes
bash scripts/couchdb.sh SELECT --changes 10
```

Single doc output: `{"success":true,"id":"...","path":"...","ctime":...,"mtime":...,"size":...,"content":"...","children":[...]}`
List output: `[{"name":"subdir","type":"dir","count":5},{"name":"note.md","type":"file","count":1},...]` (sorted: dirs first, then files)
Changes output: `[{"seq":"...","id":"...","rev":"..."},...]` (JSON array)

### UPDATE — Modify a document

```bash
# Full replace
bash scripts/couchdb.sh UPDATE --doc-id "AgentMemory/note.md" --content "# New Content"

# Append content
bash scripts/couchdb.sh UPDATE --doc-id "AgentMemory/note.md" --append --content "\n## New Section\nAppended text"

# Replace a section (preserves the header line, replaces content below it)
bash scripts/couchdb.sh UPDATE --doc-id "AgentMemory/note.md" --replace-section "## Status" --content "- Done: true"

# Via stdin
echo "New content" | bash scripts/couchdb.sh UPDATE --doc-id "AgentMemory/note.md"
```

Output: `{"success":true,"rev":"2-xxx","id":"agentmemory/note.md"}`

UPDATE automatically retries up to 3 times on CouchDB 409 conflicts.

### DELETE — Remove a document

```bash
# Soft delete (preserves history, standard Obsidian behavior)
bash scripts/couchdb.sh DELETE --doc-id "AgentMemory/note.md"

# Purge (permanently removes document + leaf nodes, irreversible)
bash scripts/couchdb.sh DELETE --doc-id "AgentMemory/note.md" --purge

# Delete entire directory
bash scripts/couchdb.sh DELETE --delete-dir "AgentMemory/temp"

# Purge entire directory
bash scripts/couchdb.sh DELETE --delete-dir "AgentMemory/temp" --purge
```

Soft delete output: `{"success":true,"rev":"...","id":"..."}`
Purge output: `{"success":true,"id":"...","purged":true}`
Directory output: `{"success":true,"directory":"...","deleted_count":N}`

## Important Notes

- **Document IDs** are case-insensitive (stored as lowercase). Path casing is preserved in the `path` field.
- **`--replace-section`** matches any header level (`#` through `######`). It preserves the header line and replaces only the content below it, until the next header of equal or higher level.
- **Soft delete** is the standard Obsidian behavior. Use **purge** only when you want to permanently remove all traces.
- **Content** can be provided via `--content`, `--file`, or stdin pipe. Priority: `--file` > `--content` > stdin.
- All output is JSON. On success, the `success` field is `true`. On failure, `success` is `false` with `error` and `reason` fields.

## Edge Cases

- Inserting a document that already exists returns `{"success":false,"error":"doc_exists"}`.
- Selecting a non-existent document returns `{"error":"not_found","reason":null}` with exit code 1.
- Updating a non-existent document returns `{"success":false,"error":"doc_not_found"}`.
- If no credentials are configured, returns `{"success":false,"error":"missing_auth",...}`.
- If required dependencies are missing, the script exits with a JSON error listing them.
