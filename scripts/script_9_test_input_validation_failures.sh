#!/usr/bin/env bash
# Demonstrates control 1 catching bad input. Every fixture here is derived
# from the real downloaded chr20 VCF, deliberately corrupted one way at a
# time, then fed to the exact same script_2_validate_inputs.sh used on the
# real data. Exits 0 only if every fixture was rejected with the expected
# exit code; a mismatch means the validation logic itself has a bug.
set -uo pipefail
# (no -e here: we expect script_2 to fail on purpose and need its exit code)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common_functions.sh"
source "${SCRIPT_DIR}/../config/pipeline_config.sh"

log_init "script_9_test_input_validation_failures"
mkdir -p "$TEST_VALIDATION_DIR"
manifest_step_start "script_9_test_input_validation_failures"

for f in "$VCF_PATH" "$FASTA_SLICE_PATH"; do
    [[ -f "$f" ]] || die "$EXIT_GENERIC_ERROR" "Missing required input: $f (run script_1_download_reference_data.sh first)"
done

WORK="$TEST_VALIDATION_DIR"
BASE_SUBSET="${WORK}/base_subset.vcf.gz"

log_step "Extracting a small real subset (chr20:1-2,000,000) to build fast fixtures from"
run_container "$THREADS_BCFTOOLS" 2 "
bcftools view -r '${CHROM}:1-2000000' '$VCF_PATH' -Oz -o '${BASE_SUBSET}.part' 2>>'$LOG_FILE' &&
tabix -p vcf '${BASE_SUBSET}.part'
" >> "$LOG_FILE" 2>&1 || die "$EXIT_GENERIC_ERROR" "Could not build the base subset for fixtures"
mv "${BASE_SUBSET}.part" "$BASE_SUBSET"
mv "${BASE_SUBSET}.part.tbi" "${BASE_SUBSET}.tbi"

declare -A RESULTS
PASS_COUNT=0
FAIL_COUNT=0

run_case() {
    local name="$1" fixture="$2" fasta="$3" expected_code="$4"
    log_step "Case [$name]: expecting exit code $expected_code"
    # lib/common_functions.sh sets -e, so the fixture's expected failure must
    # sit on the left of || or it would kill this script, not just the case.
    local actual_code=0
    bash "${SCRIPT_DIR}/script_2_validate_inputs.sh" "$fixture" "$fasta" >> "$LOG_FILE" 2>&1 || actual_code=$?
    if [[ "$actual_code" -eq "$expected_code" ]]; then
        log_step "Case [$name]: PASS (rejected with exit $actual_code as expected)"
        RESULTS["$name"]="PASS (exit $actual_code)"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        log_step "Case [$name]: FAIL (expected exit $expected_code, got $actual_code)"
        RESULTS["$name"]="FAIL (expected $expected_code, got $actual_code)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# --- Case 1: truncated VCF (breaks bgzip structure) ---
TRUNCATED="${WORK}/truncated.vcf.gz"
full_size=$(stat -c%s "$BASE_SUBSET")
half_size=$((full_size / 2))
head -c "$half_size" "$BASE_SUBSET" > "$TRUNCATED"
run_case "truncated_vcf" "$TRUNCATED" "$FASTA_SLICE_PATH" "$EXIT_CORRUPT_INPUT"

# --- Case 2: chromosome naming mismatch ("chr20" vs "20") ---
CHROM_MISMATCH="${WORK}/chrom_mismatch.vcf.gz"
run_container "$THREADS_BCFTOOLS" 2 "
echo '${CHROM} ${CHROM_BARE}' > '${WORK}/.rename_chrs.txt' &&
bcftools annotate --rename-chrs '${WORK}/.rename_chrs.txt' '$BASE_SUBSET' -Oz -o '${CHROM_MISMATCH}.tmp' 2>>'$LOG_FILE' &&
tabix -p vcf '${CHROM_MISMATCH}.tmp'
" >> "$LOG_FILE" 2>&1
mv "${CHROM_MISMATCH}.tmp" "$CHROM_MISMATCH"
mv "${CHROM_MISMATCH}.tmp.tbi" "${CHROM_MISMATCH}.tbi"
run_case "chrom_naming_mismatch" "$CHROM_MISMATCH" "$FASTA_SLICE_PATH" "$EXIT_CHROM_NAMING_MISMATCH"

# --- Case 3: REF allele incompatible with the FASTA (swap REF/ALT on the first record) ---
REF_MISMATCH="${WORK}/ref_mismatch.vcf.gz"
run_container "$THREADS_BCFTOOLS" 2 "
bcftools view '$BASE_SUBSET' 2>>'$LOG_FILE' |
awk 'BEGIN{OFS=\"\t\"; done=0} /^#/{print; next} { if (done==0) { tmp=\$4; \$4=\$5; \$5=tmp; done=1 } print }' |
bgzip -c > '${REF_MISMATCH}.tmp' &&
tabix -p vcf '${REF_MISMATCH}.tmp'
" >> "$LOG_FILE" 2>&1
mv "${REF_MISMATCH}.tmp" "$REF_MISMATCH"
mv "${REF_MISMATCH}.tmp.tbi" "${REF_MISMATCH}.tbi"
run_case "ref_fasta_mismatch" "$REF_MISMATCH" "$FASTA_SLICE_PATH" "$EXIT_REF_MISMATCH"

# --- Case 4: duplicate sample ID (second sample renamed to match the first) ---
DUP_SAMPLE="${WORK}/dup_sample.vcf.gz"
run_container 1 1 "bcftools query -l '$BASE_SUBSET'" > "${WORK}/.samples.txt" 2>>"$LOG_FILE"
first_sample=$(sed -n '1p' "${WORK}/.samples.txt")
second_sample=$(sed -n '2p' "${WORK}/.samples.txt")
awk -v first="$first_sample" -v second="$second_sample" \
    '{ if ($1==second) print $1, first; else print $1, $1 }' "${WORK}/.samples.txt" > "${WORK}/.rename_samples.txt"
run_container "$THREADS_BCFTOOLS" 2 "
bcftools reheader -s '${WORK}/.rename_samples.txt' '$BASE_SUBSET' -o '${DUP_SAMPLE}.tmp' 2>>'$LOG_FILE' &&
tabix -p vcf '${DUP_SAMPLE}.tmp'
" >> "$LOG_FILE" 2>&1
mv "${DUP_SAMPLE}.tmp" "$DUP_SAMPLE"
mv "${DUP_SAMPLE}.tmp.tbi" "${DUP_SAMPLE}.tbi"
run_case "duplicate_sample_id" "$DUP_SAMPLE" "$FASTA_SLICE_PATH" "$EXIT_DUPLICATE_SAMPLE_ID"

log_step "Validation fixture tests: $PASS_COUNT passed, $FAIL_COUNT failed"
for name in "${!RESULTS[@]}"; do
    log_detail "  $name: ${RESULTS[$name]}"
done

overall_status="completed"
exit_code=0
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    overall_status="failed"
    exit_code=1
fi

results_json="{"
first=1
for name in "${!RESULTS[@]}"; do
    [[ $first -eq 1 ]] || results_json+=","
    first=0
    results_json+="\"$name\":$(printf '%s' "${RESULTS[$name]}" | jq -Rs 'rtrimstr("\n")')"
done
results_json+="}"

manifest_step_end "$overall_status" "$exit_code" \
    "$(files_to_json_array "$VCF_PATH" "$FASTA_SLICE_PATH")" \
    "$(files_to_json_array "$TRUNCATED" "$CHROM_MISMATCH" "$REF_MISMATCH" "$DUP_SAMPLE")" \
    "{}" \
    "{\"pass_count\":${PASS_COUNT},\"fail_count\":${FAIL_COUNT},\"results\":${results_json}}"

exit "$exit_code"
