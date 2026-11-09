#!/usr/bin/env bash
# Control 2 (lock) demonstration: starts script_6_run_imputation.sh, then
# while it is still running starts a second instance and checks that it is
# rejected immediately with EXIT_LOCK_CONTENTION, instead of corrupting the
# first instance's output by writing to it concurrently.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common_functions.sh"
source "${SCRIPT_DIR}/../config/pipeline_config.sh"

log_init "script_11_test_concurrency_lock"
mkdir -p "$TEST_LOCK_DIR"
manifest_step_start "script_11_test_concurrency_lock"

for f in "$TARGET_MASKED_VCF" "$REFERENCE_PANEL_VCF"; do
    [[ -f "$f" ]] || die "$EXIT_GENERIC_ERROR" "Missing required input: $f (run scripts 1-5 first)"
done

rm -rf "${PROJECT_ROOT}/locks/06_imputation.lock"

FIRST_LOG="${TEST_LOCK_DIR}/first_instance.log"
SECOND_LOG="${TEST_LOCK_DIR}/second_instance.log"

log_step "Starting first instance of script_6_run_imputation.sh in the background"
setsid bash "${SCRIPT_DIR}/script_6_run_imputation.sh" > "$FIRST_LOG" 2>&1 &
FIRST_PID=$!

waited=0
while [[ ! -d "${PROJECT_ROOT}/locks/06_imputation.lock" ]]; do
    if ! kill -0 "$FIRST_PID" 2>/dev/null; then
        die "$EXIT_GENERIC_ERROR" "First instance exited before acquiring the lock; see $FIRST_LOG"
    fi
    sleep 1
    waited=$((waited + 1))
    [[ "$waited" -gt 60 ]] && die "$EXIT_GENERIC_ERROR" "First instance never acquired the lock within 60s"
done
log_step "First instance holds the lock (PID $FIRST_PID); launching a second instance now"

second_exit=0
bash "${SCRIPT_DIR}/script_6_run_imputation.sh" > "$SECOND_LOG" 2>&1 || second_exit=$?
log_step "Second instance exited with code $second_exit (expected $EXIT_LOCK_CONTENTION)"

log_step "Stopping the first instance (test does not need the full run to finish)"
kill -9 -- -"$FIRST_PID" 2>/dev/null || true
docker ps -q --filter "ancestor=${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG}" 2>/dev/null | xargs -r docker kill >/dev/null 2>&1 || true
sleep 1
wait "$FIRST_PID" 2>/dev/null || true
rm -rf "${PROJECT_ROOT}/locks/06_imputation.lock"

test_status="completed"
test_exit=0
if [[ "$second_exit" -ne "$EXIT_LOCK_CONTENTION" ]]; then
    log_error "Second instance did not fail with EXIT_LOCK_CONTENTION as expected (got $second_exit)"
    test_status="failed"
    test_exit=1
else
    log_step "Confirmed: concurrent execution was blocked by the lock, as required"
fi

manifest_step_end "$test_status" "$test_exit" \
    "[]" \
    "$(files_to_json_array "$FIRST_LOG" "$SECOND_LOG")" \
    "{}" \
    "{\"second_instance_exit_code\":${second_exit},\"expected_exit_code\":${EXIT_LOCK_CONTENTION}}"

exit "$test_exit"
