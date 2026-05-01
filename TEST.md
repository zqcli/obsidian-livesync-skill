# Test Plan — Obsidian LiveSync CouchDB CRUD Skill

## Prerequisites

Set environment variables before running tests:

```bash
export COUCHDB_HOST="<host>:<port>"
export COUCHDB_PATH="<hidden-path>"
export COUCHDB_USER="<username>"
export COUCHDB_PASSWORD="<password>"
export COUCHDB_DATABASE="<database>"
```

All test documents are created under `AgentMemory/test/` to avoid affecting other data.

## Test Execution

Run each test command in order. Verify the **Expected** result matches the actual output. If all tests pass, the code is considered functional.

After completion, run the cleanup (T23) to remove all test data.

---

## Group 1: Connection & Authentication (T1–T3)

### T1: PING — Normal Connection

```bash
bash scripts/couchdb.sh PING
```

**Expected**: `{"success":true,"db_name":"...","doc_count":...,"update_seq":"..."}`

### T2: PING — Connection Failure

```bash
COUCHDB_HOST="nonexistent.invalid:8443" bash scripts/couchdb.sh PING
```

**Expected**: `{"success":false,"error":"connection_failed","reason":"DNS resolution failed"}`
**Exit code**: non-zero

### T3: PING — Missing Database

```bash
COUCHDB_DATABASE="" bash scripts/couchdb.sh PING
```

**Expected**: `{"success":false,"error":"missing_database","reason":"Provide --database or set COUCHDB_DATABASE env var"}`

---

## Group 2: INSERT (T4–T7)

### T4: INSERT — Content with Multiple Sections

```bash
bash scripts/couchdb.sh INSERT --doc-id "AgentMemory/test/insert-content.md" \
  --content $'# Test Content\n\n## Section A\nContent A.\n\n## Section B\nContent B.'
```

**Expected**: `{"success":true,"rev":"1-...","id":"agentmemory/test/insert-content.md"}`

### T5: INSERT — From File

```bash
printf '# Test File\n\nInserted from local file.' > /tmp/test-insert.md
bash scripts/couchdb.sh INSERT --doc-id "AgentMemory/test/insert-file.md" --file /tmp/test-insert.md
rm /tmp/test-insert.md
```

**Expected**: `{"success":true,"rev":"1-...","id":"agentmemory/test/insert-file.md"}`

### T6: INSERT — From Stdin

```bash
printf '# Test Stdin\n\nInserted via stdin.' | \
  bash scripts/couchdb.sh INSERT --doc-id "AgentMemory/test/insert-stdin.md"
```

**Expected**: `{"success":true,"rev":"1-...","id":"agentmemory/test/insert-stdin.md"}`

### T7: INSERT — Duplicate Document

```bash
bash scripts/couchdb.sh INSERT --doc-id "AgentMemory/test/insert-content.md" --content "dup"
```

**Expected**: `{"success":false,"error":"doc_exists"}`
**Exit code**: non-zero

---

## Group 3: SELECT (T8–T12)

### T8: SELECT — Single Document + Newline Correctness

```bash
bash scripts/couchdb.sh SELECT --doc-id "AgentMemory/test/insert-content.md" | jq -r '.content'
```

**Expected**: Multi-line output with **real newlines** (not literal `\n`):
```
# Test Content

## Section A
Content A.

## Section B
Content B.
```

### T9: SELECT — List Root Directory

```bash
bash scripts/couchdb.sh SELECT --list-dir | jq '.[0:3]'
```

**Expected**: JSON array with `name`, `type` ("dir"/"file"), `count` fields. Directories sorted before files.

### T10: SELECT — List Specific Directory

```bash
bash scripts/couchdb.sh SELECT --list-dir "AgentMemory/test"
```

**Expected**: `[{"name":"insert-content.md","type":"file","count":1},{"name":"insert-file.md","type":"file","count":1},{"name":"insert-stdin.md","type":"file","count":1}]`

### T11: SELECT — Recent Changes

```bash
bash scripts/couchdb.sh SELECT --changes 3
```

**Expected**: JSON array with 3 entries, each having `seq`, `id`, `rev` fields.

### T12: SELECT — Non-existent Document

```bash
bash scripts/couchdb.sh SELECT --doc-id "nonexistent/doc.md"
```

**Expected**: `{"error":"not_found","reason":null}`
**Exit code**: non-zero

---

## Group 4: UPDATE (T13–T18)

### T13: UPDATE — Full Replace

Prepare a document with `## Status` and `## StatusReport` sections for T17 testing:

```bash
bash scripts/couchdb.sh UPDATE --doc-id "AgentMemory/test/insert-content.md" \
  --content $'# Updated Content\n\n## Section A\nNew A.\n\n## Section B\nNew B.\n\n## Status\nActive\n\n## StatusReport\nQ2 report'
```

**Expected**: `{"success":true,"rev":"2-...","id":"agentmemory/test/insert-content.md"}`

**Verify** (content replaced):
```bash
bash scripts/couchdb.sh SELECT --doc-id "AgentMemory/test/insert-content.md" | jq -r '.content'
```
Should show new content with `## Status` and `## StatusReport` sections.

### T14: UPDATE — Append (Creates Multi-Leaf Document)

```bash
bash scripts/couchdb.sh UPDATE --doc-id "AgentMemory/test/insert-content.md" \
  --append --content $'\n\n## Appended\nAppended content here.'
```

**Expected**: `{"success":true,"rev":"3-...","id":"agentmemory/test/insert-content.md"}`

### T15: SELECT — Multi-Leaf Content Integrity (Issue #1 Verification)

```bash
bash scripts/couchdb.sh SELECT --doc-id "AgentMemory/test/insert-content.md" | jq -r '.content'
```

**Expected**: Complete concatenated content from ALL leaf nodes:
```
# Updated Content

## Section A
New A.

## Section B
New B.

## Status
Active

## StatusReport
Q2 report

## Appended
Appended content here.
```

**Also verify** children count:
```bash
bash scripts/couchdb.sh SELECT --doc-id "AgentMemory/test/insert-content.md" | jq '.children | length'
```
**Expected**: `2` (two leaf nodes)

### T16: UPDATE — Replace Section on Multi-Leaf Document (Issue #2 Verification)

```bash
bash scripts/couchdb.sh UPDATE --doc-id "AgentMemory/test/insert-content.md" \
  --replace-section "## Section A" --content "REPLACED A content."
```

**Expected**: `{"success":true,"rev":"4-...","id":"agentmemory/test/insert-content.md"}`

**Verify** (only Section A replaced, everything else intact):
```bash
bash scripts/couchdb.sh SELECT --doc-id "AgentMemory/test/insert-content.md" | jq -r '.content'
```
- `## Section A` content should be `REPLACED A content.`
- `## Section B`, `## Status`, `## StatusReport`, `## Appended` should be unchanged

### T17: UPDATE — Replace Section Exact Match Test

```bash
bash scripts/couchdb.sh UPDATE --doc-id "AgentMemory/test/insert-content.md" \
  --replace-section "## Status" --content "Inactive"
```

**Expected**: `{"success":true,"rev":"5-...","id":"agentmemory/test/insert-content.md"}`

**Verify**:
```bash
bash scripts/couchdb.sh SELECT --doc-id "AgentMemory/test/insert-content.md" | jq -r '.content'
```
- `## Status` section content: `Inactive` (replaced)
- `## StatusReport` section content: `Q2 report` (unchanged — must NOT be affected)

### T17b: UPDATE — Replace Section Reverse Order (Issue #3 Verification)

This test verifies that `## Status` does NOT accidentally match `## StatusReport` when the longer-named header appears first in the document.

```bash
bash scripts/couchdb.sh INSERT --doc-id "AgentMemory/test/insert-reverse.md" \
  --content $'# Reverse Test\n\n## StatusReport\nQ2 report\n\n## Status\nActive'
```

**Expected**: `{"success":true,"rev":"1-...","id":"agentmemory/test/insert-reverse.md"}`

Replace `## Status` section:
```bash
bash scripts/couchdb.sh UPDATE --doc-id "AgentMemory/test/insert-reverse.md" \
  --replace-section "## Status" --content "Inactive"
```

**Expected**: `{"success":true,"rev":"2-...","id":"agentmemory/test/insert-reverse.md"}`

**Verify**:
```bash
bash scripts/couchdb.sh SELECT --doc-id "AgentMemory/test/insert-reverse.md" | jq -r '.content'
```
- `## StatusReport` section content: `Q2 report` (unchanged — must NOT be affected)
- `## Status` section content: `Inactive` (replaced)

### T18: UPDATE — Non-existent Document

```bash
bash scripts/couchdb.sh UPDATE --doc-id "nonexistent/doc.md" --content "test"
```

**Expected**: `{"success":false,"error":"doc_not_found"}`

---

## Group 5: DELETE (T19–T21)

### T19: DELETE — Soft Delete (Preserves children/size)

```bash
bash scripts/couchdb.sh DELETE --doc-id "AgentMemory/test/insert-stdin.md"
```

**Expected**: `{"success":true,"rev":"2-...","id":"agentmemory/test/insert-stdin.md"}`

**Verify** (children and size preserved after soft delete — aligned with LiveSync behavior):
```bash
# Use curl directly to inspect the deleted doc's raw fields
# (SELECT filters out deleted docs, so we check via _all_docs with deleted=true)
bash scripts/couchdb.sh SELECT --changes 1 | jq '.[0]'
```
The deleted document should still have its original `children` array and `size` value intact.
Only `deleted: true` and updated `mtime` should differ from the pre-delete state.

### T20: DELETE — Soft Delete (Single Document)

```bash
bash scripts/couchdb.sh DELETE --doc-id "AgentMemory/test/insert-file.md"
```

**Expected**: `{"success":true,"rev":"2-...","id":"agentmemory/test/insert-file.md"}`

### T21: DELETE — Soft Delete Directory

First soft-delete the directory so LiveSync clients receive the deletion via `_changes` feed:

```bash
bash scripts/couchdb.sh DELETE --delete-dir "AgentMemory/test"
```

**Expected**: `{"success":true,"directory":"AgentMemory/test","deleted_count":N}` (N >= 1)

> **Why soft delete first?** CouchDB `_purge` is a local operation that does NOT propagate through the replication protocol. If you purge directly, LiveSync clients will never learn about the deletion, causing ghost files and conflicts. Always soft-delete first, wait for clients to sync, then optionally purge tombstones.

---

## Group 6: Error Handling (T22)

### T22a: Missing Authentication

```bash
COUCHDB_USER="" COUCHDB_PASSWORD="" bash scripts/couchdb.sh PING
```

**Expected**: `{"success":false,"error":"missing_auth","reason":"..."}`

### T22b: Missing Doc ID

```bash
bash scripts/couchdb.sh INSERT --content "test"
```

**Expected**: `{"success":false,"error":"missing_doc_id"}`

### T22c: Missing Content

```bash
bash scripts/couchdb.sh INSERT --doc-id "AgentMemory/test/x.md"
```

**Expected**: `{"success":false,"error":"missing_content"}`

### T22d: Missing Query Parameters

```bash
bash scripts/couchdb.sh SELECT
```

**Expected**: `{"success":false,"error":"missing_query","reason":"..."}`

---

## Group 7: LiveSync Alignment Verification (T24–T26)

These tests verify the refactored behaviors that align with LiveSync source code.

### T24: Chunk Content Dedup

Verify that inserting two documents with identical content reuses the same chunk ID (content-hash dedup).

```bash
# Insert first document
bash scripts/couchdb.sh INSERT --doc-id "AgentMemory/test/dedup-a.md" --content "identical content"

# Insert second document with same content
bash scripts/couchdb.sh INSERT --doc-id "AgentMemory/test/dedup-b.md" --content "identical content"

# Compare chunk IDs
CHUNK_A=$(bash scripts/couchdb.sh SELECT --doc-id "AgentMemory/test/dedup-a.md" | jq -r '.children[0]')
CHUNK_B=$(bash scripts/couchdb.sh SELECT --doc-id "AgentMemory/test/dedup-b.md" | jq -r '.children[0]')
echo "Chunk A: $CHUNK_A"
echo "Chunk B: $CHUNK_B"
[[ "$CHUNK_A" == "$CHUNK_B" ]] && echo "DEDUP OK: same chunk" || echo "DEDUP FAIL: different chunks"
```

**Expected**: Both chunk IDs are identical (format: `h:<32-hex-chars>`) — same content produces same hash.

### T25: Soft Delete Preserves Document Fields

Verify that soft delete only sets `deleted:true` + `mtime`, preserving children, size, and ctime.

```bash
# Record pre-delete state
PRE=$(bash scripts/couchdb.sh SELECT --doc-id "AgentMemory/test/dedup-a.md")
PRE_CHILDREN=$(echo "$PRE" | jq -c '.children')
PRE_SIZE=$(echo "$PRE" | jq '.size')
PRE_CTIME=$(echo "$PRE" | jq '.ctime')
echo "Pre-delete: children=$PRE_CHILDREN size=$PRE_SIZE ctime=$PRE_CTIME"

# Soft delete
bash scripts/couchdb.sh DELETE --doc-id "AgentMemory/test/dedup-a.md"

# Read raw doc via changes to check deleted doc's fields
# (Since SELECT filters out deleted docs, use changes to find the rev, then curl raw)
bash scripts/couchdb.sh SELECT --changes 1
```

**Expected**:
- `children` array preserved (not emptied to `[]`)
- `size` preserved (not reset to `0`)
- `ctime` preserved (unchanged)
- `deleted` set to `true`
- `mtime` updated to current timestamp

### T26: Content Normalization (No Tab Conversion)

Verify that tab characters are preserved (not converted to spaces).

```bash
# Insert content with tabs
bash scripts/couchdb.sh INSERT --doc-id "AgentMemory/test/tabs.md" \
  --content $'# Tabs Test\n\tindented with tab\n\t\tdouble tab'

# Read back and verify tabs preserved
CONTENT=$(bash scripts/couchdb.sh SELECT --doc-id "AgentMemory/test/tabs.md" | jq -r '.content')
echo "$CONTENT" | cat -A | head -5
```

**Expected**: Output should show `^I` (tab characters) in `cat -A` output, NOT spaces.
```
# Tabs Test$
^Iindented with tab$
^I^Idouble tab$
```

---

## Group 8: Cleanup & Purge (T23)

### T23: Two-Phase Cleanup

**Phase 1** — Verify soft-deleted documents no longer appear in listing:

```bash
bash scripts/couchdb.sh SELECT --list-dir "AgentMemory/test"
```

**Expected**: Only un-deleted test docs remain (e.g. `dedup-b.md`, `tabs.md` from Group 7).

Soft-delete remaining:
```bash
bash scripts/couchdb.sh DELETE --delete-dir "AgentMemory/test"
```

Verify empty:
```bash
bash scripts/couchdb.sh SELECT --list-dir "AgentMemory/test"
```

**Expected**: `[]` (empty array — all test documents soft-deleted)

**Phase 2** — (Optional) Purge tombstones after all LiveSync clients have synced:

```bash
bash scripts/couchdb.sh DELETE --delete-dir "AgentMemory/test" --purge
```

> **Important**: Only run Phase 2 after confirming all connected Obsidian clients have synced the deletions. Premature purge will cause ghost files and conflicts on un-synced clients.

---

## Pass Criteria

All 27 tests (T1–T26, including T17b) must produce the expected output. A test is considered:

- **PASS**: Output matches expected result (rev hashes and seq numbers may vary)
- **FAIL**: Output differs from expected, or command crashes/hangs
- **SKIP**: Test cannot run due to environment issue (document why)

The code is considered functional when **all tests PASS**.

---

## Notes on Purge vs Soft Delete

When working with Obsidian LiveSync, **always prefer soft delete** over purge for normal operations:

| | Soft Delete | Purge (`--purge`) |
|---|---|---|
| Mechanism | Sets `deleted:true` in document body (LiveSync-level marker, NOT CouchDB `_deleted` tombstone). Preserves `children`, `size`, `ctime`. Updates `mtime`. | Removes all traces from CouchDB via `_purge` API + deletes leaf nodes |
| Replication | Propagates to all clients via `_changes` feed (document remains visible in CouchDB) | **Does NOT propagate** — clients never learn |
| Use case | Normal deletion workflow | Cleanup tombstones **after** all clients have synced |

**Workflow**: Soft delete → Wait for clients to sync → (Optional) Purge tombstones

**Risk of premature purge**: If you purge before clients sync, the client retains the document with no matching server record. This causes ghost files and revision conflicts that must be resolved manually from the client side.
