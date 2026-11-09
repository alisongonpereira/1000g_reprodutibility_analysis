#!/usr/bin/env bash
# Builds the reference panel: every chr20 sample except the 25 target
# samples and their first-degree relatives (script_3's reference_samples.txt
# already encodes that exclusion -- this script just subsets to it).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common_functions.sh"
source "${SCRIPT_DIR}/../config/pipeline_config.sh"

log_init "script_5_prepare_reference_panel"
mkdir -p "$REFERENCE_PANEL_DIR"
acquire_lock "05_reference_panel"
manifest_step_start "script_5_prepare_reference_panel"

STATS_FILE="${REFERENCE_PANEL_DIR}/reference_panel_stats.json"

if step_output_is_done "$REFERENCE_PANEL_VCF"; then
    log_step "Reference panel already built, skipping"
    manifest_step_end "completed" 0 "[]" "$(files_to_json_array "$REFERENCE_PANEL_VCF" "$STATS_FILE")" "{}" "{}"
    exit 0
fi

[[ -f "$REFERENCE_SAMPLES_FILE" ]] || die "$EXIT_SAMPLE_SET_INCONSISTENCY" "reference_samples.txt not found; run script_3_select_samples.sh first"

log_step "Subsetting chr20 VCF to the $(wc -l < "$REFERENCE_SAMPLES_FILE") reference samples"
run_container "$THREADS_BCFTOOLS" 4 "
bcftools view -S '$REFERENCE_SAMPLES_FILE' -Oz -o '${REFERENCE_PANEL_VCF}.part' '$VCF_PATH' 2>>'$LOG_FILE' &&
tabix -p vcf '${REFERENCE_PANEL_VCF}.part'
" >> "$LOG_FILE" 2>&1 || die "$EXIT_GENERIC_ERROR" "Failed to build the reference panel VCF"
mv "${REFERENCE_PANEL_VCF}.part" "$REFERENCE_PANEL_VCF"
mv "${REFERENCE_PANEL_VCF}.part.tbi" "${REFERENCE_PANEL_VCF}.tbi"

n_samples=$(run_container 1 1 "bcftools query -l '$REFERENCE_PANEL_VCF' | wc -l" 2>>"$LOG_FILE")
n_variants=$(run_container 1 1 "bcftools index -n '$REFERENCE_PANEL_VCF'" 2>>"$LOG_FILE")
log_step "Reference panel: $n_samples samples, $n_variants variants"

printf '{"n_samples":%s,"n_variants":%s}\n' "$n_samples" "$n_variants" > "${STATS_FILE}.part"
mv "${STATS_FILE}.part" "$STATS_FILE"

mark_step_output_done "$REFERENCE_PANEL_VCF"
mark_step_output_done "$STATS_FILE"

manifest_step_end "completed" 0 \
    "$(files_to_json_array "$VCF_PATH" "$REFERENCE_SAMPLES_FILE")" \
    "$(files_to_json_array "$REFERENCE_PANEL_VCF" "$STATS_FILE")" \
    "$(container_tool_versions_json bcftools)" \
    "{\"n_samples\":${n_samples},\"n_variants\":${n_variants}}"

log_step "Reference panel ready"
