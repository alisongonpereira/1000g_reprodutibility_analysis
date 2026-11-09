#!/usr/bin/env bash
# Builds two VCFs for the target samples:
#   target_truth.vcf.gz        -- every chr20 variant, untouched (the hidden truth)
#   target_array_masked.vcf.gz -- GT only, restricted to a site list that
#                                  approximates genotyping-array density
#                                  (see README for why we approximate instead
#                                  of using the real, GRCh37-only Omni2.5 file)
# The site list is computed from the full chr20 VCF (all 3202 samples): the
# simplification is deliberate -- array content reflects large-population
# design surveys, not this run's specific reference/target split.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common_functions.sh"
source "${SCRIPT_DIR}/../config/pipeline_config.sh"

log_init "script_4_prepare_target_masked"
mkdir -p "$TARGET_MASKED_DIR"
acquire_lock "04_target_masked"
manifest_step_start "script_4_prepare_target_masked"

if step_output_is_done "$TARGET_TRUTH_VCF" && step_output_is_done "$TARGET_MASKED_VCF"; then
    log_step "Target truth/masked VCFs already done, skipping"
    manifest_step_end "completed" 0 "[]" "$(files_to_json_array "$TARGET_TRUTH_VCF" "$TARGET_MASKED_VCF")" "{}" "{}"
    exit 0
fi

SITES_TSV="${TARGET_MASKED_DIR}/.array_sites.tsv"

log_step "Computing array-density site list: biallelic SNVs, MAF >= ${ARRAY_MAF_MIN}, thinned to 1 per ${ARRAY_THIN_SPACING_BP}bp"
run_container "$THREADS_BCFTOOLS" 4 "
bcftools +fill-tags '$VCF_PATH' -- -t AF,MAF 2>>'$LOG_FILE' |
bcftools view -m2 -M2 -v snps -i 'MAF>=${ARRAY_MAF_MIN}' -Ou 2>>'$LOG_FILE' |
bcftools query -f '%CHROM\t%POS\n'
" > "${TARGET_MASKED_DIR}/.candidate_sites.tsv" 2>>"$LOG_FILE"

n_candidates=$(wc -l < "${TARGET_MASKED_DIR}/.candidate_sites.tsv")
[[ "$n_candidates" -gt 0 ]] || die "$EXIT_GENERIC_ERROR" "No candidate sites passed the MAF/biallelic-SNV filter"

awk -v spacing="$ARRAY_THIN_SPACING_BP" 'BEGIN{last=-1e15} {if ($2-last>=spacing){print $1"\t"$2; last=$2}}' \
    "${TARGET_MASKED_DIR}/.candidate_sites.tsv" > "${SITES_TSV}.part"
mv "${SITES_TSV}.part" "$SITES_TSV"
n_sites=$(wc -l < "$SITES_TSV")
log_step "Array-density site list: $n_sites sites (from $n_candidates MAF-qualifying candidates)"

log_step "Extracting target-sample truth VCF (all variants, unmasked)"
run_container "$THREADS_BCFTOOLS" 4 "
bcftools view -S '$TARGET_SAMPLES_FILE' -Oz -o '${TARGET_TRUTH_VCF}.part' '$VCF_PATH' 2>>'$LOG_FILE' &&
tabix -p vcf '${TARGET_TRUTH_VCF}.part'
" >> "$LOG_FILE" 2>&1 || die "$EXIT_GENERIC_ERROR" "Failed to extract target truth VCF"
mv "${TARGET_TRUTH_VCF}.part" "$TARGET_TRUTH_VCF"
mv "${TARGET_TRUTH_VCF}.part.tbi" "${TARGET_TRUTH_VCF}.tbi"

log_step "Extracting target-sample array-masked VCF (GT only, thinned sites)"
run_container "$THREADS_BCFTOOLS" 4 "
bcftools view -S '$TARGET_SAMPLES_FILE' -R '$SITES_TSV' -Ou '$VCF_PATH' 2>>'$LOG_FILE' |
bcftools annotate -x INFO,'^FORMAT/GT' -Oz -o '${TARGET_MASKED_VCF}.part' 2>>'$LOG_FILE' &&
tabix -p vcf '${TARGET_MASKED_VCF}.part'
" >> "$LOG_FILE" 2>&1 || die "$EXIT_GENERIC_ERROR" "Failed to build the array-masked target VCF"
mv "${TARGET_MASKED_VCF}.part" "$TARGET_MASKED_VCF"
mv "${TARGET_MASKED_VCF}.part.tbi" "${TARGET_MASKED_VCF}.tbi"

n_truth_variants=$(run_container 1 1 "bcftools index -n '$TARGET_TRUTH_VCF'" 2>>"$LOG_FILE")
n_masked_variants=$(run_container 1 1 "bcftools index -n '$TARGET_MASKED_VCF'" 2>>"$LOG_FILE")
log_step "Truth VCF: $n_truth_variants variants. Array-masked VCF: $n_masked_variants variants."

mark_step_output_done "$TARGET_TRUTH_VCF"
mark_step_output_done "$TARGET_MASKED_VCF"

manifest_step_end "completed" 0 \
    "$(files_to_json_array "$VCF_PATH")" \
    "$(files_to_json_array "$TARGET_TRUTH_VCF" "$TARGET_MASKED_VCF" "$SITES_TSV")" \
    "$(container_tool_versions_json bcftools)" \
    "{\"array_maf_min\":${ARRAY_MAF_MIN},\"array_thin_spacing_bp\":${ARRAY_THIN_SPACING_BP},\"n_sites\":${n_sites},\"n_truth_variants\":${n_truth_variants},\"n_masked_variants\":${n_masked_variants}}"

log_step "Target truth/masked VCFs ready"
