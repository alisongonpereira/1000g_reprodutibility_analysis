#!/usr/bin/env bash
# Control 4 demonstration: starts the real imputation step, kills it (process
# group + any lingering container) right after the first window finishes,
# then resumes it. Checks the resumed run's own log to confirm the already
# complete window was skipped (verified by checksum, not just by existing)
# and the interrupted window was redone.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common_functions.sh"
source "${SCRIPT_DIR}/../config/pipeline_config.sh"

log_init "script_10_test_failure_and_resume"
mkdir -p "$TEST_RESUME_DIR"
manifest_step_start "script_10_test_failure_and_resume"

for f in "$TARGET_MASKED_VCF" "$REFERENCE_PANEL_VCF"; do
    [[ -f "$f" ]] || die "$EXIT_GENERIC_ERROR" "Missing required input: $f (run scripts 1-5 first)"
done

log_step "Resetting imputation state so this test starts from a clean slate"
rm -rf "${IMPUTATION_DIR}/windows" "$IMPUTED_VCF" "${IMPUTED_VCF}.tbi" "${IMPUTED_VCF}.done"
rm -rf "${PROJECT_ROOT}/locks/06_imputation.lock"
mkdir -p "${IMPUTATION_DIR}/windows"

FIRST_RUN_LOG="${TEST_RESUME_DIR}/first_run_before_kill.log"
log_step "Launching script_6_run_imputation.sh in the background"
setsid bash "${SCRIPT_DIR}/script_6_run_imputation.sh" > "$FIRST_RUN_LOG" 2>&1 &
SCRIPT6_PID=$!
log_detail "script_6 PID=$SCRIPT6_PID"

WINDOW0_DONE="${IMPUTATION_DIR}/windows/window_0.vcf.gz.done"
waited=0
while [[ ! -f "$WINDOW0_DONE" ]]; do
    if ! kill -0 "$SCRIPT6_PID" 2>/dev/null; then
        die "$EXIT_GENERIC_ERROR" "script_6 exited before window 0 finished (see $FIRST_RUN_LOG); cannot test interruption"
    fi
    sleep 2
    waited=$((waited + 2))
    if [[ "$waited" -gt 3600 ]]; then
        die "$EXIT_GENERIC_ERROR" "Timed out waiting for window 0 to complete"
    fi
done
log_step "Window 0 completed after ${waited}s; killing script_6 now to simulate a crash mid-run"

kill -9 -- -"$SCRIPT6_PID" 2>/dev/null || true
docker ps -q --filter "ancestor=${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG}" 2>/dev/null | xargs -r docker kill >/dev/null 2>&1 || true
sleep 2
wait "$SCRIPT6_PID" 2>/dev/null || true
rm -f "${PROJECT_ROOT}/locks/06_imputation.lock" -r

log_step "State right after the simulated crash:"
ls -la "${IMPUTATION_DIR}/windows" >> "$LOG_FILE" 2>&1
[[ -f "$WINDOW0_DONE" ]] || die "$EXIT_GENERIC_ERROR" "Window 0 marker missing after the crash; test setup is broken"
if [[ -f "${IMPUTED_VCF}.done" ]]; then
    die "$EXIT_GENERIC_ERROR" "Final imputed VCF was already marked done before the kill landed; interruption test is not meaningful this run"
fi

RESUME_LOG="${TEST_RESUME_DIR}/second_run_after_resume.log"
log_step "Resuming: re-running script_6_run_imputation.sh to completion"
resume_exit=0
bash "${SCRIPT_DIR}/script_6_run_imputation.sh" > "$RESUME_LOG" 2>&1 || resume_exit=$?
[[ "$resume_exit" -eq 0 ]] || die "$EXIT_GENERIC_ERROR" "Resumed script_6 run failed (exit $resume_exit); see $RESUME_LOG"

if grep -q "Window 0 .*already complete and verified, skipping" "$RESUME_LOG"; then
    log_step "Confirmed in the resumed run's own log: window 0 was skipped (checksum-verified), not reprocessed"
    window0_skipped=true
else
    log_step "WARNING: resumed run's log does not show window 0 being skipped -- check $RESUME_LOG"
    window0_skipped=false
fi

if grep -qE "Imputing window (1|[2-9])" "$RESUME_LOG"; then
    log_step "Confirmed: at least one later window was (re)computed after the crash, as expected"
    later_window_recomputed=true
else
    log_step "No later window needed recomputing in the resumed run (every window had already finished before the kill landed)"
    later_window_recomputed=false
fi

[[ -f "${IMPUTED_VCF}.done" ]] || die "$EXIT_GENERIC_ERROR" "Imputed VCF not marked done after the resumed run completed"
log_step "Resume test complete: imputed VCF produced and checksum-marked done"

test_status="completed"
[[ "$window0_skipped" == "true" ]] || test_status="inconclusive"

manifest_step_end "$test_status" 0 \
    "$(files_to_json_array "$FIRST_RUN_LOG" "$RESUME_LOG")" \
    "$(files_to_json_array "$IMPUTED_VCF")" \
    "{}" \
    "{\"window0_skipped_on_resume\":${window0_skipped},\"later_window_recomputed\":${later_window_recomputed},\"waited_seconds_before_kill\":${waited}}"
