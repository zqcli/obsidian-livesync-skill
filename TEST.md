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

### T19: DELETE — Soft Delete

```bash
bash scripts/couchdb.sh DELETE --doc-id "AgentMemory/test/insert-stdin.md"
```

**Expected**: `{"success":true,"rev":"2-...","id":"agentmemory/test/insert-stdin.md"}`

### T20: DELETE — Purge (Permanent)

```bash
bash scripts/couchdb.sh DELETE --doc-id "AgentMemory/test/insert-file.md" --purge
```

**Expected**: `{"success":true,"id":"agentmemory/test/insert-file.md","purged":true}`

### T21: DELETE — Delete Directory

```bash
bash scripts/couchdb.sh DELETE --delete-dir "AgentMemory/test" --purge
```

**Expected**: `{"success":true,"directory":"AgentMemory/test","deleted_count":N}` (N >= 1)

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

## Group 7: Cleanup (T23)

### T23: Verify All Test Data Removed

```bash
bash scripts/couchdb.sh SELECT --list-dir "AgentMemory/test"
```

**Expected**: `[]` (empty array — all test documents purged by T21)

If not empty, run:
```bash
bash scripts/couchdb.sh DELETE --delete-dir "AgentMemory/test" --purge
```

---

## Pass Criteria

All 24 tests (T1–T23, including T17b) must produce the expected output. A test is considered:

- **PASS**: Output matches expected result (rev hashes and seq numbers may vary)
- **FAIL**: Output differs from expected, or command crashes/hangs
- **SKIP**: Test cannot run due to environment issue (document why)

The code is considered functional when **all tests PASS**.
