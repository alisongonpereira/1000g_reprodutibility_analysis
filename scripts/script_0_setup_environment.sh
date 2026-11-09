#!/usr/bin/env bash
# Setup exception: creates the initial directory structure and the pinned
# container image. This is the only script allowed to create output
# directories outside the 0N_[output] numbering scheme.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common_functions.sh"
source "${SCRIPT_DIR}/../config/pipeline_config.sh"

log_init "script_0_setup_environment"
log_step "Starting environment setup"

mkdir -p "${PROJECT_ROOT}"/01_download "${PROJECT_ROOT}"/02_validation \
         "${PROJECT_ROOT}"/03_sample_selection "${PROJECT_ROOT}"/04_target_masked \
         "${PROJECT_ROOT}"/05_reference_panel "${PROJECT_ROOT}"/06_imputation \
         "${PROJECT_ROOT}"/07_metrics "${PROJECT_ROOT}"/08_verdict \
         "${PROJECT_ROOT}"/09_test_validation "${PROJECT_ROOT}"/10_test_resume \
         "${PROJECT_ROOT}"/11_test_lock
mkdir -p "$LOG_DIR" "$LOCKS_DIR" "$(dirname "$MANIFEST_FILE")"
manifest_init
log_step "Directory tree ready under ${PROJECT_ROOT}"

manifest_step_start "script_0_setup_environment"

require_tool docker
require_tool curl
require_tool jq
require_tool sha256sum
log_step "Host-level tools present (docker, curl, jq, sha256sum)"

if ! docker image inspect "${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG}" >/dev/null 2>&1; then
    log_step "Building container image ${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG} (one-time; needs network)"
    if ! docker build -t "${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG}" "${PROJECT_ROOT}/docker" >> "$LOG_FILE" 2>&1; then
        manifest_step_end "failed" "$EXIT_GENERIC_ERROR" "[]" "[]" "{}" "{}"
        die "$EXIT_GENERIC_ERROR" "Container image build failed; see $LOG_FILE"
    fi
else
    log_step "Container image ${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG} already present, skipping build"
fi

log_step "Verifying tool versions inside the container"
if ! run_container 1 1 'bcftools --version | head -1; samtools --version | head -1; java -version; jq --version; test -f "$BEAGLE_JAR" && echo BEAGLE_JAR_OK' >> "$LOG_FILE" 2>&1; then
    manifest_step_end "failed" "$EXIT_MISSING_TOOL" "[]" "[]" "{}" "{}"
    die "$EXIT_MISSING_TOOL" "Container tool verification failed; see $LOG_FILE"
fi

manifest_step_end "completed" 0 "[]" "[]" \
    "$(container_tool_versions_json bcftools samtools java beagle)" \
    "{\"docker_image\":\"${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG}\"}"

log_step "Environment setup complete"
