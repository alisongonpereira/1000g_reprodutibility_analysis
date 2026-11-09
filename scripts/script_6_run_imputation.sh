#!/usr/bin/env bash
# Control 2 (resource limits, concurrency lock) + Control 4 (failure/resume).
# chr20 is split into N_IMPUTATION_WINDOWS genomic windows; each window is
# its own idempotent unit (own .done checksum marker), so killing this
# script mid-run and re-running it only redoes the interrupted window --
# completed windows are skipped, verified by their checksum, not just by
# file existence. Threads/heap come from config, never hardcoded, and the
# container's --cpus/--memory enforce them.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common_functions.sh"
source "${SCRIPT_DIR}/../config/pipeline_config.sh"

log_init "script_6_run_imputation"
WINDOWS_DIR="${IMPUTATION_DIR}/windows"
mkdir -p "$WINDOWS_DIR"
acquire_lock "06_imputation"
manifest_step_start "script_6_run_imputation"

if step_output_is_done "$IMPUTED_VCF"; then
    log_step "Imputed VCF already complete, skipping"
    manifest_step_end "completed" 0 "[]" "$(files_to_json_array "$IMPUTED_VCF")" "{}" "{}"
    exit 0
fi

for f in "$TARGET_MASKED_VCF" "$REFERENCE_PANEL_VCF"; do
    [[ -f "$f" ]] || die "$EXIT_GENERIC_ERROR" "Missing required input: $f (run earlier scripts first)"
done

MAP_FILE="${IMPUTATION_DIR}/${CHROM}.GRCh38.map"
if ! step_output_is_done "$MAP_FILE"; then
    log_step "Extracting Beagle genetic map for $CHROM (chr-prefixed variant, matching our VCF naming)"
    run_container 1 1 "unzip -p '$MAP_ZIP_PATH' 'chr_in_chrom_field/plink.chr${CHROM}.GRCh38.map' > '${MAP_FILE}.part'" >> "$LOG_FILE" 2>&1 \
        || die "$EXIT_GENERIC_ERROR" "Failed to extract genetic map for $CHROM from $MAP_ZIP_PATH"
    [[ -s "${MAP_FILE}.part" ]] || die "$EXIT_CORRUPT_INPUT" "Extracted genetic map for $CHROM is empty"
    mv "${MAP_FILE}.part" "$MAP_FILE"
    mark_step_output_done "$MAP_FILE"
fi

CHROM_LENGTH=$(awk -v c="$CHROM" '$1==c{print $2}' "${FASTA_SLICE_PATH}.fai")
[[ -n "$CHROM_LENGTH" ]] || die "$EXIT_CORRUPT_INPUT" "Could not read $CHROM length from ${FASTA_SLICE_PATH}.fai"
WINDOW_SIZE=$(( (CHROM_LENGTH + N_IMPUTATION_WINDOWS - 1) / N_IMPUTATION_WINDOWS ))
log_step "chr20 length=$CHROM_LENGTH, split into $N_IMPUTATION_WINDOWS windows of ~${WINDOW_SIZE}bp"

CONTAINER_MEM_GB=$((BEAGLE_HEAP_GB + 2))
WINDOW_FILES=()
for (( i=0; i<N_IMPUTATION_WINDOWS; i++ )); do
    start=$(( i * WINDOW_SIZE + 1 ))
    end=$(( (i + 1) * WINDOW_SIZE ))
    (( end > CHROM_LENGTH )) && end="$CHROM_LENGTH"
    region="${CHROM}:${start}-${end}"
    window_vcf="${WINDOWS_DIR}/window_${i}.vcf.gz"
    WINDOW_FILES+=("$window_vcf")

    if step_output_is_done "$window_vcf"; then
        log_step "Window $i ($region) already complete and verified, skipping"
        continue
    fi

    log_step "Imputing window $i/$((N_IMPUTATION_WINDOWS - 1)): $region"
    tmp_prefix="${WINDOWS_DIR}/window_${i}_tmp"
    rm -f "${tmp_prefix}.vcf.gz" "${tmp_prefix}.log"
    run_container "$THREADS_BEAGLE" "$CONTAINER_MEM_GB" "
java -Xmx${BEAGLE_HEAP_GB}g -jar \"\$BEAGLE_JAR\" \
  gt='$TARGET_MASKED_VCF' \
  ref='$REFERENCE_PANEL_VCF' \
  map='$MAP_FILE' \
  chrom='$region' \
  out='$tmp_prefix' \
  nthreads=${THREADS_BEAGLE} \
  gp=true
" >> "$LOG_FILE" 2>&1 || die "$EXIT_GENERIC_ERROR" "Beagle failed on window $i ($region); see $LOG_FILE"

    [[ -f "${tmp_prefix}.vcf.gz" ]] || die "$EXIT_GENERIC_ERROR" "Beagle did not produce output for window $i ($region)"
    mv "${tmp_prefix}.vcf.gz" "$window_vcf"
    run_container 1 1 "tabix -p vcf '$window_vcf'" >> "$LOG_FILE" 2>&1 \
        || die "$EXIT_GENERIC_ERROR" "tabix failed on window $i output"
    mark_step_output_done "$window_vcf"
    log_step "Window $i complete and checksum-marked done"
done

log_step "Concatenating $N_IMPUTATION_WINDOWS windows into the final imputed VCF"
window_args="$(printf "'%s' " "${WINDOW_FILES[@]}")"
run_container "$THREADS_BCFTOOLS" 2 "
bcftools concat $window_args -Oz -o '${IMPUTED_VCF}.part' 2>>'$LOG_FILE' &&
tabix -p vcf '${IMPUTED_VCF}.part'
" >> "$LOG_FILE" 2>&1 || die "$EXIT_GENERIC_ERROR" "Failed to concatenate imputation windows"
mv "${IMPUTED_VCF}.part" "$IMPUTED_VCF"
mv "${IMPUTED_VCF}.part.tbi" "${IMPUTED_VCF}.tbi"
mark_step_output_done "$IMPUTED_VCF"

n_variants=$(run_container 1 1 "bcftools index -n '$IMPUTED_VCF'" 2>>"$LOG_FILE")
n_samples=$(run_container 1 1 "bcftools query -l '$IMPUTED_VCF' | wc -l" 2>>"$LOG_FILE")
log_step "Imputation complete: $n_variants variants, $n_samples samples"

manifest_step_end "completed" 0 \
    "$(files_to_json_array "$TARGET_MASKED_VCF" "$REFERENCE_PANEL_VCF" "$MAP_FILE")" \
    "$(files_to_json_array "$IMPUTED_VCF")" \
    "$(container_tool_versions_json java beagle bcftools)" \
    "{\"n_windows\":${N_IMPUTATION_WINDOWS},\"threads_beagle\":${THREADS_BEAGLE},\"beagle_heap_gb\":${BEAGLE_HEAP_GB},\"n_variants\":${n_variants},\"n_samples\":${n_samples}}"
