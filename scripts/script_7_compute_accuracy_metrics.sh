#!/usr/bin/env bash
# Compares the imputed VCF against the hidden target-sample truth: dosage
# r-squared and non-reference genotype concordance, both overall and by
# reference-panel MAF bin. Metrics are restricted to biallelic SNVs (the
# same site class the array mask uses), computed from GT (truth, imputed
# best-guess) and GP (imputed dosage = P(het) + 2*P(hom-alt)).
# bcftools extracts the data and awk reshapes GT/GP strings into numbers
# (file-format handling); the actual statistics (Pearson r^2, concordance)
# are computed by scripts/compute_accuracy_stats.R, not accumulated by
# hand in awk -- see README "Why R for one step".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common_functions.sh"
source "${SCRIPT_DIR}/../config/pipeline_config.sh"

log_init "script_7_compute_accuracy_metrics"
mkdir -p "$METRICS_DIR"
acquire_lock "07_metrics"
manifest_step_start "script_7_compute_accuracy_metrics"

METRICS_FILE="${METRICS_DIR}/accuracy_metrics.json"
if step_output_is_done "$METRICS_FILE"; then
    log_step "Accuracy metrics already computed, skipping"
    manifest_step_end "completed" 0 "[]" "$(files_to_json_array "$METRICS_FILE")" "{}" "{}"
    exit 0
fi

for f in "$IMPUTED_VCF" "$TARGET_TRUTH_VCF" "$REFERENCE_PANEL_VCF" "$TARGET_SAMPLES_FILE"; do
    [[ -f "$f" ]] || die "$EXIT_GENERIC_ERROR" "Missing required input: $f (run earlier scripts first)"
done

SAMPLE_CSV="$(paste -sd, "$TARGET_SAMPLES_FILE")"
WORK="$METRICS_DIR"

log_step "Computing reference-panel MAF for biallelic SNVs"
run_container "$THREADS_BCFTOOLS" 2 "
bcftools +fill-tags '$REFERENCE_PANEL_VCF' -- -t MAF 2>>'$LOG_FILE' |
bcftools view -m2 -M2 -v snps -Ou 2>>'$LOG_FILE' |
bcftools query -f '%CHROM:%POS\t%INFO/MAF\n'
" > "${WORK}/.maf.tsv" 2>>"$LOG_FILE"
sort -k1,1 "${WORK}/.maf.tsv" > "${WORK}/.maf_sorted.tsv"
log_step "$(wc -l < "${WORK}/.maf_sorted.tsv") biallelic SNV sites with MAF computed"

log_step "Extracting truth genotypes for target samples"
run_container 1 1 "bcftools query -f '%CHROM:%POS[\t%GT]\n' -s '$SAMPLE_CSV' '$TARGET_TRUTH_VCF'" \
    > "${WORK}/.truth_gt.tsv" 2>>"$LOG_FILE"

log_step "Extracting imputed genotypes and dosages for target samples"
run_container 1 1 "bcftools query -f '%CHROM:%POS[\t%GT\t%GP]\n' -s '$SAMPLE_CSV' '$IMPUTED_VCF'" \
    > "${WORK}/.imputed_raw.tsv" 2>>"$LOG_FILE"

log_step "Converting genotypes to allele counts and dosages"
awk -F'\t' '
function count(gt) {
    if (gt ~ /\./) return -1
    gsub(/[|\/]/, "", gt)
    c = 0
    for (k = 1; k <= length(gt); k++) if (substr(gt, k, 1) == "1") c++
    return c
}
{
    line = $1
    for (i = 2; i <= NF; i++) line = line "\t" count($i)
    print line
}' "${WORK}/.truth_gt.tsv" | sort -k1,1 > "${WORK}/.truth_counts_sorted.tsv"

awk -F'\t' '
function count(gt) {
    if (gt ~ /\./) return -1
    gsub(/[|\/]/, "", gt)
    c = 0
    for (k = 1; k <= length(gt); k++) if (substr(gt, k, 1) == "1") c++
    return c
}
function dosage(gp) {
    if (gp == "." || gp == "") return -1
    n = split(gp, a, ",")
    if (n != 3) return -1
    return a[2] + 2 * a[3]
}
{
    line = $1
    for (i = 2; i <= NF; i += 2) line = line "\t" count($i) "\t" dosage($(i + 1))
    print line
}' "${WORK}/.imputed_raw.tsv" | sort -k1,1 > "${WORK}/.imputed_counts_sorted.tsv"

log_step "Joining MAF + truth + imputed by site, computing r-squared and concordance"
join -j1 -t $'\t' "${WORK}/.maf_sorted.tsv" "${WORK}/.truth_counts_sorted.tsv" | \
join -j1 -t $'\t' - "${WORK}/.imputed_counts_sorted.tsv" > "${WORK}/.joined.tsv"

n_joined_sites=$(wc -l < "${WORK}/.joined.tsv")
[[ "$n_joined_sites" -gt 0 ]] || die "$EXIT_GENERIC_ERROR" "No sites survived the truth/imputed/MAF join; cannot compute metrics"
log_step "$n_joined_sites sites available for metrics"

run_container 1 "$RSTATS_MEM_GB" "Rscript '${SCRIPT_DIR}/compute_accuracy_stats.R' '${WORK}/.joined.tsv' '$ARRAY_MAF_MIN'" \
    > "${WORK}/.stats.txt" 2>>"$LOG_FILE"

cat "${WORK}/.stats.txt" >> "$LOG_FILE"

n_target_samples=$(wc -l < "$TARGET_SAMPLES_FILE")
n_target_variants=$(run_container 1 1 "bcftools index -n '$IMPUTED_VCF'" 2>>"$LOG_FILE")

# shellcheck disable=SC1090
source <(sed 's/^/METRIC_/' "${WORK}/.stats.txt")

jq -n \
    --argjson overall_r2 "$METRIC_overall_r2" \
    --argjson rare_r2 "$METRIC_rare_r2" \
    --argjson low_r2 "$METRIC_low_r2" \
    --argjson common_r2 "$METRIC_common_r2" \
    --argjson concordance "$METRIC_nonref_concordance" \
    --argjson n_sites "$n_target_variants" \
    --argjson n_samples "$n_target_samples" \
    --argjson n_genotype_pairs "$METRIC_n_genotype_pairs" \
    --argjson n_nonref_truth_calls "$METRIC_n_nonref_truth_calls" \
    '{dosage_r2_overall: $overall_r2, dosage_r2_maf_lt_0_01: $rare_r2, dosage_r2_maf_0_01_0_05: $low_r2, dosage_r2_maf_gte_0_05: $common_r2, nonref_genotype_concordance_overall: $concordance, imputed_variant_count: $n_sites, imputed_sample_count: $n_samples, n_genotype_pairs_compared: $n_genotype_pairs, n_nonref_truth_calls: $n_nonref_truth_calls}' \
    > "${METRICS_FILE}.part"
mv "${METRICS_FILE}.part" "$METRICS_FILE"
mark_step_output_done "$METRICS_FILE"

manifest_step_end "completed" 0 \
    "$(files_to_json_array "$IMPUTED_VCF" "$TARGET_TRUTH_VCF" "$REFERENCE_PANEL_VCF")" \
    "$(files_to_json_array "$METRICS_FILE")" \
    "$(container_tool_versions_json bcftools r)" \
    "{\"n_joined_sites\":${n_joined_sites}}"

log_step "Accuracy metrics computed: $(cat "$METRICS_FILE")"
