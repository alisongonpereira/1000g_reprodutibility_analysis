#!/usr/bin/env bash
# Control 1: input validation, run before any heavy processing.
# Each check is isolated and fails fast with a distinct exit code (see
# lib/common_functions.sh) and a clear message. Accepts optional VCF/FASTA
# paths so script_9 can point the exact same checks at deliberately
# corrupted fixtures without duplicating this logic.
#
# Usage: script_2_validate_inputs.sh [VCF_PATH] [FASTA_PATH]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common_functions.sh"
source "${SCRIPT_DIR}/../config/pipeline_config.sh"

log_init "script_2_validate_inputs"

VCF="${1:-$VCF_PATH}"
FASTA="${2:-$FASTA_SLICE_PATH}"

manifest_step_start "script_2_validate_inputs"
log_step "Validating $(basename "$VCF") against $(basename "$FASTA")"

check_bgzip_integrity() {
    log_step "Check 1/6: bgzip integrity"
    run_container 1 1 "bgzip -t '$VCF'" >> "$LOG_FILE" 2>&1 \
        || die "$EXIT_CORRUPT_INPUT" "VCF failed bgzip integrity test (truncated or corrupt): $VCF"
}

check_vcf_parses() {
    log_step "Check 2/6: VCF parses fully"
    run_container "$THREADS_BCFTOOLS" 2 "bcftools view -H '$VCF' > /dev/null" >> "$LOG_FILE" 2>&1 \
        || die "$EXIT_CORRUPT_INPUT" "VCF could not be parsed by bcftools (malformed records): $VCF"
}

check_index_valid() {
    log_step "Check 3/6: index present and valid"
    [[ -f "${VCF}.tbi" || -f "${VCF}.csi" ]] \
        || die "$EXIT_MISSING_OR_INVALID_INDEX" "No .tbi/.csi index found next to $VCF"
    run_container 1 1 "bcftools index -s '$VCF' > /dev/null" >> "$LOG_FILE" 2>&1 \
        || die "$EXIT_MISSING_OR_INVALID_INDEX" "Index is missing or does not match the VCF: $VCF"
}

check_chrom_naming() {
    log_step "Check 4/6: chromosome naming consistency (VCF vs. FASTA vs. config)"
    local vcf_chroms fasta_chrom
    vcf_chroms="$(run_container 1 1 "tabix -l '$VCF'" 2>>"$LOG_FILE")"
    [[ "$vcf_chroms" == "$CHROM" ]] \
        || die "$EXIT_CHROM_NAMING_MISMATCH" "VCF contig name '$vcf_chroms' does not match configured CHROM='$CHROM' (e.g. 'chr20' vs '20')"
    fasta_chrom="$(run_container 1 1 "cut -f1 '${FASTA}.fai'" 2>>"$LOG_FILE")"
    [[ "$fasta_chrom" == "$CHROM" ]] \
        || die "$EXIT_CHROM_NAMING_MISMATCH" "FASTA sequence name '$fasta_chrom' does not match configured CHROM='$CHROM'"
}

check_ref_matches_fasta() {
    log_step "Check 5/6: REF alleles match the GRCh38 FASTA"
    run_container "$THREADS_BCFTOOLS" 2 "bcftools norm --check-ref e -f '$FASTA' '$VCF' -Ou -o /dev/null" >> "$LOG_FILE" 2>&1 \
        || die "$EXIT_REF_MISMATCH" "One or more REF alleles do not match the GRCh38 FASTA: $VCF"
}

check_sample_ids_unique() {
    log_step "Check 6/6: sample IDs are unique"
    local dups
    dups="$(run_container 1 1 "bcftools query -l '$VCF' | sort | uniq -d" 2>>"$LOG_FILE")"
    [[ -z "$dups" ]] \
        || die "$EXIT_DUPLICATE_SAMPLE_ID" "Duplicate sample ID(s) found in $VCF: $dups"
}

check_bgzip_integrity
check_vcf_parses
check_index_valid
check_chrom_naming
check_ref_matches_fasta
check_sample_ids_unique

manifest_step_end "completed" 0 \
    "$(files_to_json_array "$VCF" "${VCF}.tbi" "$FASTA" "${FASTA}.fai")" \
    "[]" \
    "$(container_tool_versions_json bcftools tabix bgzip)" \
    "{\"vcf\":\"$(basename "$VCF")\",\"fasta\":\"$(basename "$FASTA")\"}"

log_step "All input validation checks passed"
