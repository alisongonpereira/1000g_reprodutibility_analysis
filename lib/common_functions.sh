#!/usr/bin/env bash
# Shared logging, manifest, locking and idempotency helpers.
# Sourced by every script_*.sh; never executed directly.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs"
LOCKS_DIR="${PROJECT_ROOT}/locks"
MANIFEST_FILE="${PROJECT_ROOT}/manifest/manifest.json"

readonly EXIT_GENERIC_ERROR=1
readonly EXIT_CORRUPT_INPUT=10
readonly EXIT_MISSING_OR_INVALID_INDEX=11
readonly EXIT_CHROM_NAMING_MISMATCH=12
readonly EXIT_REF_MISMATCH=13
readonly EXIT_DUPLICATE_SAMPLE_ID=14
readonly EXIT_SAMPLE_SET_INCONSISTENCY=15
readonly EXIT_CHECKSUM_MISMATCH=16
readonly EXIT_MISSING_TOOL=20
readonly EXIT_LOCK_CONTENTION=30
readonly EXIT_ACCEPTANCE_FAILED=40

mkdir -p "$LOG_DIR" "$LOCKS_DIR" "$(dirname "$MANIFEST_FILE")"

CURRENT_STEP="MAIN"
LOG_FILE="${LOG_DIR}/main.log"

log_init() {
    CURRENT_STEP="$1"
    LOG_FILE="${LOG_DIR}/${CURRENT_STEP}.log"
    : > "$LOG_FILE"
}

_ts() { date -u '+%Y-%m-%d %H:%M:%S'; }

# Full detail: log file only.
log_detail() {
    echo "[$(_ts)] [${CURRENT_STEP}] $*" >> "$LOG_FILE"
}

# Step summary: log file + console.
log_step() {
    local line="[$(_ts)] [${CURRENT_STEP}] $*"
    echo "$line" >> "$LOG_FILE"
    echo "[${CURRENT_STEP}] $*"
}

log_error() {
    local line="[$(_ts)] [${CURRENT_STEP}] ERROR: $*"
    echo "$line" >> "$LOG_FILE"
    echo "[${CURRENT_STEP}] ERROR: $*" >&2
}

die() {
    local code="$1"; shift
    log_error "$*"
    exit "$code"
}

sha256_of() {
    sha256sum "$1" | awk '{print $1}'
}

verify_checksum() {
    local file="$1" expected="$2" actual
    actual="$(sha256_of "$file")"
    if [[ "$actual" != "$expected" ]]; then
        die "$EXIT_CHECKSUM_MISMATCH" "Checksum mismatch for $file (expected $expected, got $actual)"
    fi
    log_detail "Checksum OK for $file ($actual)"
}

require_tool() {
    local tool="$1"
    command -v "$tool" >/dev/null 2>&1 || die "$EXIT_MISSING_TOOL" "Required tool not found on PATH: $tool"
}

tool_version() {
    case "$1" in
        bcftools) bcftools --version 2>/dev/null | head -1 ;;
        bgzip)    bgzip --version 2>/dev/null | head -1 ;;
        tabix)    tabix --version 2>/dev/null | head -1 ;;
        java)     java -version 2>&1 | head -1 ;;
        jq)       jq --version 2>/dev/null ;;
        curl)     curl --version 2>/dev/null | head -1 ;;
        docker)   docker --version 2>/dev/null ;;
        beagle)
            if [[ -n "${BEAGLE_JAR:-}" && -f "${BEAGLE_JAR:-}" ]]; then
                java -jar "$BEAGLE_JAR" 2>&1 | grep -im1 "beagle" || echo "unknown"
            else
                echo "unknown"
            fi
            ;;
        *) echo "unknown" ;;
    esac
}

# --- Locking: mkdir-based atomic lock, fail-fast on live contention. ---
# HELD_LOCKS tracks every lock currently held by this process so the EXIT
# trap can release all of them, however many were nested or sequenced.

HELD_LOCKS=()

acquire_lock() {
    local name="$1"
    local lock_dir="${LOCKS_DIR}/${name}.lock"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        local other_pid=""
        [[ -f "${lock_dir}/pid" ]] && other_pid="$(cat "${lock_dir}/pid" 2>/dev/null || true)"
        if [[ -n "$other_pid" ]] && kill -0 "$other_pid" 2>/dev/null; then
            die "$EXIT_LOCK_CONTENTION" "Lock '$name' is held by running PID $other_pid. Concurrent execution of this step is not allowed."
        fi
        log_detail "Stale lock '$name' (dead PID '${other_pid}') found; removing and retrying."
        rm -rf "$lock_dir"
        mkdir "$lock_dir" || die "$EXIT_LOCK_CONTENTION" "Failed to acquire lock '$name' after clearing a stale lock."
    fi
    echo "$$" > "${lock_dir}/pid"
    date -u '+%Y-%m-%dT%H:%M:%SZ' > "${lock_dir}/acquired_at"
    HELD_LOCKS+=("$name")
    trap 'release_all_locks' EXIT
}

release_lock() {
    local name="$1" i
    rm -rf "${LOCKS_DIR}/${name}.lock"
    for i in "${!HELD_LOCKS[@]}"; do
        [[ "${HELD_LOCKS[$i]}" == "$name" ]] && unset 'HELD_LOCKS[i]'
    done
}

release_all_locks() {
    local name
    for name in "${HELD_LOCKS[@]:-}"; do
        [[ -n "$name" ]] && rm -rf "${LOCKS_DIR}/${name}.lock"
    done
    HELD_LOCKS=()
}

# --- Idempotency: output is "done" only if it exists AND its checksum
# matches the checksum recorded at the time it was completed. ---

step_output_is_done() {
    local output_path="$1"
    local marker="${output_path}.done"
    [[ -f "$output_path" && -f "$marker" ]] || return 1
    local recorded expected
    recorded="$(cat "$marker" 2>/dev/null || true)"
    expected="$(sha256_of "$output_path")"
    [[ -n "$recorded" && "$recorded" == "$expected" ]]
}

mark_step_output_done() {
    local output_path="$1"
    sha256_of "$output_path" > "${output_path}.done"
}

# --- Manifest (JSON), one entry per step, written under a dedicated lock. ---

manifest_init() {
    if [[ ! -f "$MANIFEST_FILE" ]]; then
        echo '{"pipeline":"1000g_imputation_reproducibility_demo","steps":{}}' > "$MANIFEST_FILE"
    fi
}

# Builds a JSON array of {path, sha256, size_bytes} for the given files.
# Missing files are skipped (so a partial input list never breaks the call).
files_to_json_array() {
    local f first=1
    echo -n "["
    for f in "$@"; do
        [[ -f "$f" ]] || continue
        [[ $first -eq 1 ]] || echo -n ","
        first=0
        printf '{"path":%s,"sha256":"%s","size_bytes":%s}' \
            "$(printf '%s' "$f" | jq -Rs 'rtrimstr("\n")')" \
            "$(sha256_of "$f")" \
            "$(stat -c%s "$f")"
    done
    echo -n "]"
}

# Version lookups for tools that only exist inside the container (bcftools,
# samtools, java, beagle). Host-only tools (curl, jq, docker) use
# tool_version()/tool_versions_json() instead.
container_tool_version() {
    case "$1" in
        bcftools) run_container 1 1 "bcftools --version 2>/dev/null | head -1" ;;
        samtools) run_container 1 1 "samtools --version 2>/dev/null | head -1" ;;
        tabix)    run_container 1 1 "tabix --version 2>/dev/null | head -1" ;;
        bgzip)    run_container 1 1 "bgzip --version 2>/dev/null | head -1" ;;
        java)     run_container 1 1 "java -version 2>&1 | head -1" ;;
        beagle)   run_container 1 1 'java -jar "$BEAGLE_JAR" 2>&1 | grep -im1 beagle' ;;
        *) echo "unknown" ;;
    esac
}

container_tool_versions_json() {
    local t first=1
    echo -n "{"
    for t in "$@"; do
        [[ $first -eq 1 ]] || echo -n ","
        first=0
        printf '"%s":%s' "$t" "$(container_tool_version "$t" | jq -Rs 'rtrimstr("\n")')"
    done
    echo -n "}"
}

# Builds a JSON object {tool: version_string} for the given tool names.
tool_versions_json() {
    local t first=1
    echo -n "{"
    for t in "$@"; do
        [[ $first -eq 1 ]] || echo -n ","
        first=0
        printf '"%s":%s' "$t" "$(tool_version "$t" | jq -Rs 'rtrimstr("\n")')"
    done
    echo -n "}"
}

# --- Containerized tool execution. All bioinformatics tools (bcftools,
# java/Beagle) run inside the pinned Docker image; the host only needs
# curl/jq/docker. CPU/memory limits come from config, never hardcoded. ---

run_container() {
    local cpus="$1" mem_gb="$2"
    shift 2
    docker run --rm \
        -v "${PROJECT_ROOT}:${PROJECT_ROOT}" \
        -w "$PWD" \
        --cpus="$cpus" \
        --memory="${mem_gb}g" \
        "${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG}" \
        -c "$*"
}

manifest_step_start() {
    CURRENT_MANIFEST_STEP="$1"
    MANIFEST_STEP_START_TIME="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

# manifest_step_end status exit_code inputs_json outputs_json tool_versions_json params_json
manifest_step_end() {
    local status="$1" exit_code="$2" inputs_json="$3" outputs_json="$4" tool_versions_json="$5" params_json="$6"
    local end_time
    end_time="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    manifest_init
    acquire_lock "manifest"
    jq --arg step "$CURRENT_MANIFEST_STEP" \
       --arg script "$(basename "${BASH_SOURCE[1]:-$0}")" \
       --arg status "$status" \
       --argjson exit_code "$exit_code" \
       --arg start "$MANIFEST_STEP_START_TIME" \
       --arg end "$end_time" \
       --arg host "$(hostname)" \
       --argjson inputs "$inputs_json" \
       --argjson outputs "$outputs_json" \
       --argjson tool_versions "$tool_versions_json" \
       --argjson params "$params_json" \
       '.steps[$step] = {script:$script, status:$status, exit_code:$exit_code, start_time:$start, end_time:$end, host:$host, inputs:$inputs, outputs:$outputs, tool_versions:$tool_versions, parameters:$params}' \
       "$MANIFEST_FILE" > "${MANIFEST_FILE}.tmp"
    mv "${MANIFEST_FILE}.tmp" "$MANIFEST_FILE"
    release_lock "manifest"
}
