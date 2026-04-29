#!/bin/bash
set -euo pipefail

# =============================================================================
# Obsidian LiveSync CouchDB CRUD Tool
# =============================================================================

DEFAULT_HOST="${COUCHDB_HOST:-}"        # env var fallback for --host
DEFAULT_PATH="${COUCHDB_PATH:-}"        # env var fallback for --path
DEFAULT_DATABASE="${COUCHDB_DATABASE:-}" # env var fallback for --database
MAX_RETRIES=3

# CLI-parsed values (override env vars when provided)
HOST="" HIDDEN_PATH="" USERNAME="" PASSWORD="" DATABASE=""
DOC_ID="" FILE_PATH="" CONTENT="" LIST_DIR="" CHANGES_LIMIT=""
APPEND_MODE=false REPLACE_SECTION="" PURGE_MODE=false DELETE_DIR=""
INSECURE=false CONTENT_SET=false
PROXY="" PROXY_TYPE="socks5"
COMMAND="" BASE_URL=""

# =============================================================================
# Dependency Check
# =============================================================================

check_dependencies() {
  local missing=()
  for cmd in curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo '{"success":false,"error":"missing_dependencies","reason":"Required: '"${missing[*]}"'"}' >&2
    exit 1
  fi
}

# =============================================================================
# curl wrapper (SSL control + Cookie Auth)
# =============================================================================

COOKIE_JAR=""

_build_proxy_args() {
  PROXY_ARGS=()
  if [[ -n "${PROXY:-}" ]]; then
    if [[ "${PROXY_TYPE}" == "http" ]]; then
      PROXY_ARGS=(--proxy "http://${PROXY}")
    else
      PROXY_ARGS=(--proxy "socks5h://${PROXY}")
    fi
  fi
}

_ensure_cookie_jar() {
  if [[ -z "$COOKIE_JAR" ]]; then
    COOKIE_JAR=$(mktemp "${TMPDIR:-/tmp}/couchdb_skill_XXXXXX")
    trap 'rm -f "$COOKIE_JAR"' EXIT
  fi
}

_authenticate() {
  local host="$1" username="$2" password="$3"
  _ensure_cookie_jar
  local url="https://${host}"
  [[ -n "${DEFAULT_PATH:-}" ]] && url="${url}/${DEFAULT_PATH}"
  local ssl_flag=""
  [[ "${INSECURE}" == "true" ]] && ssl_flag="-k"
  _build_proxy_args
  local result
  result=$(curl -s $ssl_flag --connect-timeout 10 --max-time 30 \
    ${PROXY_ARGS+"${PROXY_ARGS[@]}"} \
    -c "$COOKIE_JAR" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"${username}\",\"password\":\"${password}\"}" \
    "${url}/_session" 2>&1) || true
  # Check if auth succeeded
  if echo "$result" | jq -e '.ok == true' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

_curl() {
  _build_proxy_args
  local exit_code=0
  local result
  local cookie_args=()
  if [[ -n "$COOKIE_JAR" && -s "$COOKIE_JAR" ]]; then
    cookie_args=(-b "$COOKIE_JAR" -c "$COOKIE_JAR")
  fi
  if [[ "${INSECURE}" == "true" ]]; then
    result=$(curl -sk --connect-timeout 10 --max-time 120 ${cookie_args+"${cookie_args[@]}"} ${PROXY_ARGS+"${PROXY_ARGS[@]}"} "$@" 2>&1) || exit_code=$?
  else
    result=$(curl -s --connect-timeout 10 --max-time 120 ${cookie_args+"${cookie_args[@]}"} ${PROXY_ARGS+"${PROXY_ARGS[@]}"} "$@" 2>&1) || exit_code=$?
  fi
  # Detect curl-level failures (network unreachable, timeout, DNS failure, etc.)
  if [[ $exit_code -ne 0 && ! "$result" =~ ^\{ && ! "$result" =~ ^\[ ]]; then
    local reason=""
    case $exit_code in
      6)   reason="DNS resolution failed" ;;
      7)   reason="Failed to connect to host" ;;
      28)  reason="Connection timed out" ;;
      35)  reason="SSL/TLS handshake failed" ;;
      52)  reason="Empty reply from server" ;;
      56)  reason="Connection reset by peer" ;;
      *)   reason="curl exit code $exit_code" ;;
    esac
    echo "{\"success\":false,\"error\":\"connection_failed\",\"reason\":\"${reason}\"}"
    return 1
  fi
  echo "$result"
}

# =============================================================================
# Connection
# =============================================================================

build_base_url() {
  local url="https://${1}"
  [[ -n "${2:-}" ]] && url="${url}/${2}"
  echo "${url}/${3}"
}

curl_get_doc() {
  local base_url="$1" doc_id="$2" username="$3" password="$4"
  local keys_json
  keys_json=$(jq -c -n --arg key "$doc_id" '[$key]')
  local encoded_keys
  encoded_keys=$(jq -rn --arg v "$keys_json" '$v|@uri')
  local result
  result=$(_curl -u "${username}:${password}" \
    "${base_url}/_all_docs?include_docs=true&keys=${encoded_keys}") || return 1
  if echo "$result" | jq -e '.rows[0].doc' >/dev/null 2>&1; then
    echo "$result" | jq '.rows[0].doc'
  elif echo "$result" | jq -e '.rows[0].error' >/dev/null 2>&1; then
    echo "$result" | jq -c '{success:false, error:.rows[0].error, reason:(.rows[0].reason // null)}'
  else
    echo "$result"
  fi
}

curl_insert_doc() {
  _curl -u "${4}:${5}" -X POST -H 'Content-Type: application/json' -d "$3" "$1"
}

curl_update_doc() {
  local doc_with_rev=$(echo "$4" | jq --arg rev "$3" '. + {_rev: $rev}')
  local bulk_json=$(jq -c -n --argjson docs "[${doc_with_rev}]" '{docs: $docs}')
  _curl -u "${5}:${6}" -X POST -H 'Content-Type: application/json' \
    -d "$bulk_json" "${1}/_bulk_docs"
}

curl_insert_node() {
  local base_url="$1" node_id="$2" content_json="$3" username="$4" password="$5"
  local node_json=$(jq -c -n --arg id "$node_id" --argjson data "$content_json" \
    '{_id: $id, type: "leaf", data: $data}')
  _curl -u "${username}:${password}" -X PUT -H 'Content-Type: application/json' \
    -d "$node_json" "${base_url}/${node_id}"
}

curl_list_dir() {
  local prefix=$(echo "$2" | tr '[:upper:]' '[:lower:]' | sed 's|/$||')
  local startkey=$(jq -n --arg p "${prefix}/" '$p')
  local endkey=$(jq -n --arg p "${prefix}/" '$p + "\uffff"')
  local enc_start=$(jq -rn --arg v "$startkey" '$v|@uri')
  local enc_end=$(jq -rn --arg v "$endkey" '$v|@uri')
  _curl -u "${3}:${4}" "${1}/_all_docs?startkey=${enc_start}&endkey=${enc_end}"
}

curl_list_all() {
  _curl -u "${2}:${3}" "${1}/_all_docs"
}

curl_changes() {
  _curl -u "${3}:${4}" "${1}/_changes?limit=${2}&descending=true"
}

curl_delete_doc_soft() {
  local bulk=$(jq -c -n --arg id "$2" --arg rev "$3" '{docs:[{_id:$id,_rev:$rev,_deleted:true}]}')
  _curl -u "${4}:${5}" -X POST -H 'Content-Type: application/json' -d "$bulk" "${1}/_bulk_docs"
}

curl_delete_doc_purge() {
  local base_url="$1" doc_id="$2" rev="$3" username="$4" password="$5"
  # Get all leaf revisions (including conflicts) to purge completely
  local encoded_id
  encoded_id=$(jq -rn --arg v "$doc_id" '$v|@uri')
  local doc_info
  doc_info=$(_curl -u "${username}:${password}" \
    "${base_url}/${encoded_id}?conflicts=true") || return 1
  local all_revs
  if echo "$doc_info" | jq -e '._conflicts' >/dev/null 2>&1; then
    all_revs=$(echo "$doc_info" | jq -c '[._rev] + ._conflicts')
  else
    all_revs=$(jq -c -n --arg rev "$rev" '[$rev]')
  fi
  local purge_json
  purge_json=$(jq -c -n --arg id "$doc_id" --argjson revs "$all_revs" '{($id): $revs}')
  local purge_result
  purge_result=$(_curl -u "${username}:${password}" -X POST -H 'Content-Type: application/json' \
    -d "$purge_json" "${base_url}/_purge") || return 1
  if echo "$purge_result" | jq -e '.purged' >/dev/null 2>&1; then
    echo "$purge_result" | jq -c --arg id "$doc_id" '{success:true, id:$id, purged:true}'
  else
    echo "$purge_result" | jq -c '{success:false, error:.error, reason:.reason}'
  fi
}

curl_delete_node() {
  local base_url="$1" node_id="$2" username="$3" password="$4"
  local node
  node=$(_curl -u "${username}:${password}" "${base_url}/${node_id}") || return 0
  local node_rev=$(echo "$node" | jq -r '._rev // empty' 2>/dev/null)
  [[ -z "$node_rev" ]] && return 0
  _curl -u "${username}:${password}" -X DELETE \
    "${base_url}/${node_id}?rev=${node_rev}" >/dev/null 2>&1
}

# =============================================================================
# Path & Encoding
# =============================================================================

generate_node_id() {
  local id
  id=$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 13)
  while [[ ${#id} -lt 13 ]]; do
    id+=$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c $((13 - ${#id})))
  done
  echo "h:${id}"
}

# =============================================================================
# Content Processing
# =============================================================================

encode_content_json() { printf '%s' "$1" | jq -Rs .; }
normalize_content()    { printf '%s' "$1" | sed 's/\r$//' | sed 's/\t/    /g'; }

validate_content_size() {
  local size=${#1}
  if [[ $size -gt ${2:-50000000} ]]; then
    echo '{"success":false,"error":"content_too_large","reason":"Size '$size' exceeds limit"}' >&2
    return 1
  fi
  return 0
}

calculate_size_for_livesync() {
  printf '%s' "$1" | jq -sRj 'sub("\n+$";"")' | wc -c | tr -d ' '
}

read_file_content() {
  if [[ -f "$1" ]]; then
    cat "$1"
  else
    echo '{"success":false,"error":"file_not_found","reason":"'"$1"'"}' >&2
    return 1
  fi
}

# =============================================================================
# Response Parsing
# =============================================================================

parse_response() {
  echo "$1" | jq -c '
    if type == "array" then
      if .[0].ok == true then {success:true, rev:.[0].rev, id:.[0].id}
      elif .[0].error then {success:false, error:.[0].error, reason:(.[0].reason // "Unknown")}
      else {success:true, raw:.}
      end
    elif .ok == true then {success:true, rev:.rev, id:.id}
    elif .error then {success:false, error:.error, reason:(.reason // "Unknown")}
    else {success:true, raw:.}
    end
  '
}

decode_content_newlines() {
  local raw="$1"
  raw="${raw//\\n/$'\n'}"
  raw="${raw//$'\r'/}"
  printf '%s' "$raw"
}

resolve_full_content() {
  local doc_json="$1" base_url="$2" username="$3" password="$4"
  local children=$(echo "$doc_json" | jq -r '.children[]? // empty')
  if [[ -z "$children" ]]; then
    local raw=$(echo "$doc_json" | jq -r '.data // empty')
    decode_content_newlines "$raw"
    return
  fi
  local keys_json=$(echo "$children" | jq -R . | jq -s .)
  local encoded_keys=$(jq -rn --arg v "$keys_json" '$v|@uri')
  local result
  result=$(_curl -u "${username}:${password}" \
    "${base_url}/_all_docs?include_docs=true&keys=${encoded_keys}") || return 1
  local raw=$(echo "$result" | jq -r '[.rows[].doc.data // empty] | join("")')
  decode_content_newlines "$raw"
}

format_select_result() {
  jq -c --arg c "$2" \
    '{success:true,id:._id,path:.path,ctime:.ctime,mtime:.mtime,size:.size,content:$c,children:.children}' <<< "$1"
}

format_list_result() {
  echo "$1" | jq -c '[.rows[] | {id:.id, rev:.value.rev}]'
}

format_dir_listing() {
  local raw_result="$1" prefix="$2"
  # Lowercase and normalize prefix: add trailing / if non-empty
  prefix=$(echo "$prefix" | tr '[:upper:]' '[:lower:]')
  [[ -n "$prefix" && "$prefix" != */ ]] && prefix="${prefix}/"
  echo "$raw_result" | jq -c --arg prefix "$prefix" '
    [.rows[].id
     | select(startswith("h:") | not)
     | select(startswith("_") | not)
    ]
    | if $prefix != "" then map(select(startswith($prefix)) | ltrimstr($prefix)) else . end
    | map(select(length > 0))
    | map(split("/") | {segment: .[0], depth: length})
    | group_by(.segment)
    | map({
        name: .[0].segment,
        type: (if any(.depth > 1) then "dir" else "file" end),
        count: length
      })
    | sort_by(.type, .name)
  '
}

format_changes_result() {
  echo "$1" | jq -c '[.results[] | {seq:.seq, id:.id, rev:.changes[0].rev}]'
}

# =============================================================================
# Document Building
# =============================================================================

resolve_latest_rev() {
  local base_url="$1" doc_id="$2" username="$3" password="$4"
  local keys_json
  keys_json=$(jq -c -n --arg key "$doc_id" '[$key]')
  local encoded_keys
  encoded_keys=$(jq -rn --arg v "$keys_json" '$v|@uri')
  local result
  result=$(_curl -u "${username}:${password}" "${base_url}/_all_docs?keys=${encoded_keys}") || return 1
  if echo "$result" | jq -e '.rows[0].value.rev' >/dev/null 2>&1; then
    echo "$result" | jq -r '.rows[0].value.rev'
  else
    echo '{"success":false,"error":"rev_not_found","reason":"Could not resolve revision for document"}' >&2; return 1
  fi
}

build_doc_json_for_insert() {
  local doc_id="$1" node_id="$2" timestamp="$3" content="$4"
  local id_lower=$(echo "$doc_id" | tr '[:upper:]' '[:lower:]')
  local size=$(printf '%s' "$content" | jq -sRj 'sub("\n+$";"")' | wc -c | tr -d ' ')
  local children=$(jq -c -n --arg n "$node_id" '[$n]')
  jq -c -n --arg id "$id_lower" --arg path "$doc_id" --argjson children "$children" \
    --arg ctime "$timestamp" --arg mtime "$timestamp" --arg size "$size" \
    '{_id:$id,path:$path,children:$children,ctime:($ctime|tonumber),mtime:($mtime|tonumber),size:($size|tonumber),type:"plain",eden:{}}'
}

build_doc_json_for_update() {
  local current_doc="$1" new_children="$2" new_timestamp="$3" new_size="$4"
  local children_json
  if echo "$new_children" | jq -e 'type == "array"' >/dev/null 2>&1; then
    children_json="$new_children"
  else
    children_json=$(echo "$new_children" | tr ' ' '\n' | jq -R . | jq -s .)
  fi
  echo "$current_doc" | jq -c \
    --argjson nc "$children_json" --arg mt "$new_timestamp" --arg ns "$new_size" \
    '.children=$nc | .mtime=($mt|tonumber) | .size=($ns|tonumber)'
}

replace_section() {
  local content="$1" header="$2" new_content="$3"
  # Detect header level from the target (e.g. "## Foo" -> level=2)
  local header_prefix=$(echo "$header" | grep -o '^#\+' || true)
  local level_len=${#header_prefix}
  [[ $level_len -eq 0 ]] && level_len=2

  local before="" after="" found=false in_section=false
  while IFS= read -r line; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^(#{1,6})[[:space:]] ]]; then
      local cur_level=${#BASH_REMATCH[1]}
      # End section when hitting a header of same or higher level
      if [[ "$in_section" == true && $cur_level -le $level_len ]]; then
        in_section=false
        after+="${line}"$'\n'
        continue
      fi
      # Match target header exactly (first occurrence only)
      if [[ "$found" == false && "$line" =~ ^"$header"[[:space:]]*$ ]]; then
        found=true; in_section=true
        before+="${line}"$'\n'  # Preserve the header line
        continue
      fi
    fi
    [[ "$in_section" == true ]] && continue
    [[ "$found" == false ]] && before+="${line}"$'\n' || after+="${line}"$'\n'
  done <<< "$content"
  if [[ "$found" == true ]]; then
    printf '%s%s\n\n%s' "$before" "$new_content" "$after"
  else
    printf '%s\n\n%s' "$content" "$new_content"
  fi
}

# =============================================================================
# Retry Logic (for CouchDB 409 conflicts)
# =============================================================================

retry_on_conflict() {
  local func="$1"; shift
  local attempt=0
  while [[ $attempt -lt $MAX_RETRIES ]]; do
    local result=$("$func" "$@")
    if echo "$result" | jq -e '.error == "conflict" or (.success == false and .error == "conflict")' >/dev/null 2>&1; then
      attempt=$((attempt + 1))
      [[ $attempt -lt $MAX_RETRIES ]] && sleep 0.5
    else
      echo "$result"; return
    fi
  done
  echo '{"success":false,"error":"conflict","reason":"Max retries ('$MAX_RETRIES') exceeded"}'
}

# =============================================================================
# Leaf Node Cleanup (for purge operations)
# =============================================================================

cleanup_leaf_nodes() {
  local base_url="$1" doc_json="$2" username="$3" password="$4"
  local children=$(echo "$doc_json" | jq -r '.children[]? // empty' 2>/dev/null)
  for node_id in $children; do
    curl_delete_node "$base_url" "$node_id" "$username" "$password" || true
  done
}

# =============================================================================
# CRUD Commands
# =============================================================================

cmd_ping() {
  validate_connection || return 1
  local base_url="$BASE_URL"
  local result
  result=$(_curl -u "${USERNAME}:${PASSWORD}" "${base_url}") || true
  if echo "$result" | jq -e '.db_name' >/dev/null 2>&1; then
    echo "$result" | jq -c '{success:true, db_name:.db_name, doc_count:.doc_count, update_seq:.update_seq}'
  elif echo "$result" | jq -e '.error' >/dev/null 2>&1; then
    echo "$result"
    return 1
  else
    echo '{"success":false,"error":"connection_failed","reason":"Cannot reach CouchDB"}'
    return 1
  fi
}

cmd_insert() {
  validate_connection || return 1
  [[ -z "${DOC_ID:-}" ]] && { echo '{"success":false,"error":"missing_doc_id"}'; return 1; }

  local content
  if [[ -n "${FILE_PATH:-}" ]]; then
    content=$(read_file_content "$FILE_PATH") || return 1
  elif [[ "${CONTENT_SET}" == "true" ]]; then
    content="$CONTENT"
  elif [[ ! -t 0 ]]; then
    content=$(cat)
  else
    echo '{"success":false,"error":"missing_content"}'; return 1
  fi

  validate_content_size "$content" || return 1
  content=$(normalize_content "$content")

  local base_url="$BASE_URL"

  [[ "$(curl_get_doc "$base_url" "$(echo "$DOC_ID" | tr '[:upper:]' '[:lower:]')" "$USERNAME" "$PASSWORD" | jq -e '.success == false' 2>/dev/null)" == "true" ]] || \
    { echo '{"success":false,"error":"doc_exists"}'; return 1; }

  local node_id=$(generate_node_id)
  local encoded=$(encode_content_json "$content")

  local node_result=$(curl_insert_node "$base_url" "$node_id" "$encoded" "$USERNAME" "$PASSWORD")
  echo "$node_result" | jq -e '.error' >/dev/null 2>&1 && { echo "$node_result"; return 1; }

  local timestamp=$(date +%s)000
  local doc_json=$(build_doc_json_for_insert "$DOC_ID" "$node_id" "$timestamp" "$content")
  local result=$(curl_insert_doc "$base_url" "$DOC_ID" "$doc_json" "$USERNAME" "$PASSWORD")
  parse_response "$result"
}

cmd_select() {
  validate_connection || return 1
  local base_url="$BASE_URL"

  if [[ -n "${DOC_ID:-}" ]]; then
    local doc_id_lower=$(echo "$DOC_ID" | tr '[:upper:]' '[:lower:]')
    local result=$(curl_get_doc "$base_url" "$doc_id_lower" "$USERNAME" "$PASSWORD")
    echo "$result" | jq -e '.error' >/dev/null 2>&1 && { echo "$result"; return 1; }
    local full_content=$(resolve_full_content "$result" "$base_url" "$USERNAME" "$PASSWORD")
    format_select_result "$result" "$full_content"
  elif [[ -n "${LIST_DIR:-}" ]]; then
    if [[ "$LIST_DIR" == "/" ]]; then
      format_dir_listing "$(curl_list_all "$base_url" "$USERNAME" "$PASSWORD")" ""
    else
      format_dir_listing "$(curl_list_dir "$base_url" "$LIST_DIR" "$USERNAME" "$PASSWORD")" "$LIST_DIR"
    fi
  elif [[ -n "${CHANGES_LIMIT:-}" ]]; then
    if [[ ! "$CHANGES_LIMIT" =~ ^[0-9]+$ ]]; then
      echo '{"success":false,"error":"invalid_parameter","reason":"--changes requires a positive integer"}'; return 1
    fi
    format_changes_result "$(curl_changes "$base_url" "$CHANGES_LIMIT" "$USERNAME" "$PASSWORD")"
  else
    echo '{"success":false,"error":"missing_query","reason":"Provide --doc-id, --list-dir, or --changes"}'; return 1
  fi
}

_cmd_update_inner() {
  validate_connection || return 1
  [[ -z "${DOC_ID:-}" ]] && { echo '{"success":false,"error":"missing_doc_id"}'; return 1; }

  local base_url="$BASE_URL"
  local doc_id_lower=$(echo "$DOC_ID" | tr '[:upper:]' '[:lower:]')

  local current=$(curl_get_doc "$base_url" "$doc_id_lower" "$USERNAME" "$PASSWORD")
  echo "$current" | jq -e '.error' >/dev/null 2>&1 && \
    { echo '{"success":false,"error":"doc_not_found"}'; return 1; }

  local current_rev=$(echo "$current" | jq -r '._rev')
  local current_children=$(echo "$current" | jq -c '.children // []')
  local current_size=$(echo "$current" | jq -r '.size // 0')
  local new_node content_for_chunk final_children new_size_bytes
  new_node=$(generate_node_id)

  # Resolve content based on mode
  if [[ -n "${FILE_PATH:-}" ]]; then
    content_for_chunk=$(read_file_content "$FILE_PATH") || return 1
  elif [[ "${APPEND_MODE}" == "true" && -n "${CONTENT:-}" ]]; then
    content_for_chunk="$CONTENT"
  elif [[ -n "${REPLACE_SECTION:-}" && -n "${CONTENT:-}" ]]; then
    local cur_content=$(resolve_full_content "$current" "$base_url" "$USERNAME" "$PASSWORD")
    content_for_chunk=$(replace_section "$cur_content" "$REPLACE_SECTION" "$CONTENT")
  elif [[ "${CONTENT_SET}" == "true" ]]; then
    content_for_chunk="$CONTENT"
  else
    echo '{"success":false,"error":"missing_content"}'; return 1
  fi

  content_for_chunk=$(normalize_content "$content_for_chunk")
  validate_content_size "$content_for_chunk" || return 1

  # Append mode: add to existing children; all others: replace
  if [[ "${APPEND_MODE}" == "true" && -n "${CONTENT:-}" ]]; then
    final_children=$(echo "$current_children" | jq -c --arg new "$new_node" '. + [$new]')
    new_size_bytes=$((current_size + $(calculate_size_for_livesync "$content_for_chunk")))
  else
    final_children=$(jq -c -n --arg n "$new_node" '[$n]')
    new_size_bytes=$(calculate_size_for_livesync "$content_for_chunk")
  fi

  local node_result=$(curl_insert_node "$base_url" "$new_node" "$(encode_content_json "$content_for_chunk")" "$USERNAME" "$PASSWORD")
  echo "$node_result" | jq -e '.error' >/dev/null 2>&1 && { echo "$node_result"; return 1; }

  local updated=$(build_doc_json_for_update "$current" "$final_children" "$(date +%s)000" "$new_size_bytes")
  parse_response "$(curl_update_doc "$base_url" "$doc_id_lower" "$current_rev" "$updated" "$USERNAME" "$PASSWORD")"
}

cmd_update() {
  # Pre-read stdin before retry loop (stdin is consumed on first read)
  if [[ "${CONTENT_SET}" != "true" && -z "${FILE_PATH:-}" && ! -t 0 ]]; then
    CONTENT=$(cat)
    CONTENT_SET=true
  fi
  retry_on_conflict _cmd_update_inner
}

cmd_delete() {
  validate_connection || return 1
  local base_url="$BASE_URL"

  if [[ -n "${DELETE_DIR:-}" ]]; then
    local list_result=$(curl_list_dir "$base_url" "$DELETE_DIR" "$USERNAME" "$PASSWORD")
    local count=0
    for doc_id in $(echo "$list_result" | jq -r '.rows[].id' 2>/dev/null); do
      local rev=$(resolve_latest_rev "$base_url" "$doc_id" "$USERNAME" "$PASSWORD")
      if [[ "${PURGE_MODE}" == "true" ]]; then
        local doc=$(curl_get_doc "$base_url" "$doc_id" "$USERNAME" "$PASSWORD")
        cleanup_leaf_nodes "$base_url" "$doc" "$USERNAME" "$PASSWORD"
        curl_delete_doc_purge "$base_url" "$doc_id" "$rev" "$USERNAME" "$PASSWORD" >/dev/null
      else
        curl_delete_doc_soft "$base_url" "$doc_id" "$rev" "$USERNAME" "$PASSWORD" >/dev/null
      fi
      count=$((count + 1))
    done
    jq -c -n --arg c "$count" --arg d "$DELETE_DIR" '{success:true,directory:$d,deleted_count:($c|tonumber)}'

  elif [[ -n "${DOC_ID:-}" ]]; then
    local doc_id_lower=$(echo "$DOC_ID" | tr '[:upper:]' '[:lower:]')
    local rev=$(resolve_latest_rev "$base_url" "$doc_id_lower" "$USERNAME" "$PASSWORD")
    if [[ "${PURGE_MODE}" == "true" ]]; then
      local doc=$(curl_get_doc "$base_url" "$doc_id_lower" "$USERNAME" "$PASSWORD")
      cleanup_leaf_nodes "$base_url" "$doc" "$USERNAME" "$PASSWORD"
      curl_delete_doc_purge "$base_url" "$doc_id_lower" "$rev" "$USERNAME" "$PASSWORD"
    else
      parse_response "$(curl_delete_doc_soft "$base_url" "$doc_id_lower" "$rev" "$USERNAME" "$PASSWORD")"
    fi
  else
    echo '{"success":false,"error":"missing_target"}'; return 1
  fi
}

# =============================================================================
# CLI
# =============================================================================

merge_config() {
  # Merge env vars as fallback for CLI flags
  [[ -z "${USERNAME:-}" && -n "${COUCHDB_USER:-}" ]] && USERNAME="$COUCHDB_USER"
  [[ -z "${PASSWORD:-}" && -n "${COUCHDB_PASSWORD:-}" ]] && PASSWORD="$COUCHDB_PASSWORD"
  # CLI --host/--path/--database override env vars
  [[ -n "${HOST:-}" ]] && DEFAULT_HOST="$HOST"
  [[ -n "${HIDDEN_PATH:-}" ]] && DEFAULT_PATH="$HIDDEN_PATH"
  [[ -n "${DATABASE:-}" ]] && DEFAULT_DATABASE="$DATABASE"
}

validate_config() {
  [[ -n "${USERNAME:-}" && -n "${PASSWORD:-}" ]] || \
    { echo '{"success":false,"error":"missing_auth","reason":"Provide --user/--password or set COUCHDB_USER/COUCHDB_PASSWORD env vars"}'; return 1; }
  [[ -n "${DEFAULT_HOST:-}" ]] || \
    { echo '{"success":false,"error":"missing_host","reason":"Provide --host or set COUCHDB_HOST env var"}'; return 1; }
  [[ -n "${DEFAULT_DATABASE:-}" ]] || \
    { echo '{"success":false,"error":"missing_database","reason":"Provide --database or set COUCHDB_DATABASE env var"}'; return 1; }
}

validate_connection() {
  merge_config
  validate_config || return $?
  BASE_URL=$(build_base_url "$DEFAULT_HOST" "${DEFAULT_PATH:-}" "$DEFAULT_DATABASE")
  # Establish Cookie Auth session (avoids per-request PBKDF2 hashing)
  _authenticate "${DEFAULT_HOST}" "$USERNAME" "$PASSWORD" || true
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host)       HOST="$2"; shift 2 ;;
      --path)       HIDDEN_PATH="$2"; shift 2 ;;
      --user)       USERNAME="$2"; shift 2 ;;
      --password)   PASSWORD="$2"; shift 2 ;;
      --database)   DATABASE="$2"; shift 2 ;;
      --doc-id)     DOC_ID="$2"; shift 2 ;;
      --file)       FILE_PATH="$2"; shift 2 ;;
      --content)    CONTENT="$2"; CONTENT_SET=true; shift 2 ;;
      --list-dir)
        if [[ $# -lt 2 || "$2" == --* || "$2" =~ ^(INSERT|SELECT|UPDATE|DELETE|PING)$ ]]; then
          LIST_DIR="/"; shift
        else
          LIST_DIR="$2"; shift 2
        fi
        ;;
      --changes)    CHANGES_LIMIT="$2"; shift 2 ;;
      --append)     APPEND_MODE=true; shift ;;
      --replace-section) REPLACE_SECTION="$2"; shift 2 ;;
      --purge)      PURGE_MODE=true; shift ;;
      --delete-dir) DELETE_DIR="$2"; shift 2 ;;
      --verify-ssl) INSECURE=false; shift ;;
      --insecure)   INSECURE=true; shift ;;
      --proxy)      PROXY="$2"; shift 2 ;;
      --proxy-type) PROXY_TYPE="$2"; shift 2 ;;
      INSERT|SELECT|UPDATE|DELETE|PING) COMMAND="$1"; shift ;;
      -h|--help)    show_help; exit 0 ;;
      *)            echo "Unknown: $1" >&2; exit 1 ;;
    esac
  done
}

show_help() {
  cat <<'EOF'
Usage: couchdb.sh <COMMAND> [OPTIONS]

Commands:
  PING      Test connection to CouchDB
  INSERT    Create a new document
  SELECT    Read document(s) or list changes
  UPDATE    Modify an existing document
  DELETE    Remove document(s)

Connection (all commands):
  --user/--password   Auth (env: COUCHDB_USER / COUCHDB_PASSWORD)
  --host              Host (env: COUCHDB_HOST)
  --path              Hidden path (env: COUCHDB_PATH)
  --database          Database (env: COUCHDB_DATABASE)
  --insecure          Skip SSL certificate verification (default: verify)
  --verify-ssl        Enable SSL certificate verification (this is the default)
  --proxy HOST:PORT   Proxy address (CLI only, no env var)
  --proxy-type TYPE   Proxy type: socks5 (default) or http

INSERT:
  --doc-id ID         Document path (e.g. AgentMemory/note.md)
  --content TEXT      Content string (also accepts stdin pipe)
  --file PATH         Read content from local file

SELECT:
  --doc-id ID         Read a single document
  --list-dir DIR      List documents in directory
  --changes N         Get N recent changes

UPDATE:
  --doc-id ID         Document to update (required)
  --content TEXT      New content (also accepts stdin pipe or --file)
  --file PATH         Read content from local file
  --append            Append instead of replace
  --replace-section H Replace content under heading H

DELETE:
  --doc-id ID         Delete a single document
  --delete-dir DIR    Delete all docs in directory
  --purge             Permanently delete (remove history + leaf nodes)
EOF
}

main() {
  check_dependencies
  parse_args "$@"
  [[ -z "${COMMAND:-}" ]] && { show_help; exit 1; }
  case "$COMMAND" in
    INSERT) cmd_insert ;; SELECT) cmd_select ;;
    UPDATE) cmd_update ;; DELETE) cmd_delete ;;
    PING)   cmd_ping ;;
    *) echo "Unknown command: $COMMAND" >&2; exit 1 ;;
  esac
}

main "$@"
