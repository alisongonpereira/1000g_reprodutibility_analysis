#!/usr/bin/env bash
# Builds the target/reference sample split: target_samples.txt (stratified
# by superpopulation, preferring trio members so relative-exclusion is
# actually exercised), excluded_relatives.txt (first-degree relatives of
# each target: parent/child/sibling, with the relationship recorded for
# audit) and reference_samples.txt (every other VCF sample).
# Selection is deterministic (fixed random source from TARGET_RANDOM_SEED),
# not re-randomized on every run. Only bcftools needs the container; the
# rest is plain POSIX awk/sort/comm/shuf, run directly on the host.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common_functions.sh"
source "${SCRIPT_DIR}/../config/pipeline_config.sh"

log_init "script_3_select_samples"
mkdir -p "$SAMPLE_SELECTION_DIR"
acquire_lock "03_sample_selection"
manifest_step_start "script_3_select_samples"

if step_output_is_done "$TARGET_SAMPLES_FILE" && step_output_is_done "$REFERENCE_SAMPLES_FILE"; then
    log_step "Sample selection already done, skipping"
    manifest_step_end "completed" 0 "[]" "$(files_to_json_array "$TARGET_SAMPLES_FILE" "$REFERENCE_SAMPLES_FILE" "$EXCLUDED_RELATIVES_FILE")" "{}" "{}"
    exit 0
fi

WORK="$SAMPLE_SELECTION_DIR"
VCF_SAMPLES="${WORK}/.vcf_samples.txt"
PED_IN_VCF="${WORK}/.ped_in_vcf.txt"
PED_ANNOTATED="${WORK}/.ped_annotated.txt"

log_step "Listing samples actually present in the VCF (containerized bcftools)"
run_container 1 1 "bcftools query -l '$VCF_PATH'" > "$VCF_SAMPLES" 2>>"$LOG_FILE"

log_step "Restricting pedigree/population table to VCF samples"
awk 'NR>1{print $2, $6, $7, $3, $4}' "$PEDPOP_PATH" > "${WORK}/.ped_simplified.txt"
awk 'NR==FNR{vcf[$1]=1; next} ($1 in vcf)' "$VCF_SAMPLES" "${WORK}/.ped_simplified.txt" > "$PED_IN_VCF"

n_in_vcf=$(wc -l < "$PED_IN_VCF")
log_step "Pedigree rows matching VCF samples: $n_in_vcf"
[[ "$n_in_vcf" -ge 1000 ]] || die "$EXIT_SAMPLE_SET_INCONSISTENCY" "Only $n_in_vcf pedigree rows matched VCF samples; expected roughly 3200"

log_step "Flagging trio membership (has a parent in-panel, or is a parent of someone in-panel)"
awk '
{ id[NR]=$1; pop[NR]=$2; sp[NR]=$3; fa[NR]=$4; mo[NR]=$5; n=NR }
END {
    for (i=1;i<=n;i++) {
        if (fa[i]!="0") childcount[fa[i]]++
        if (mo[i]!="0") childcount[mo[i]]++
    }
    for (i=1;i<=n;i++) {
        trio = (fa[i]!="0" || mo[i]!="0" || (id[i] in childcount && childcount[id[i]]>0)) ? 1 : 0
        print id[i], pop[i], sp[i], fa[i], mo[i], trio
    }
}' "$PED_IN_VCF" > "$PED_ANNOTATED"

: > "${WORK}/.target_samples_raw.txt"
for sp in "${SUPERPOPULATIONS[@]}"; do
    log_step "Selecting $N_TARGET_PER_SUPERPOP target samples for superpopulation $sp (trio members preferred)"
    awk -v sp="$sp" '$3==sp && $6==1 {print $1}' "$PED_ANNOTATED" > "${WORK}/.trio_${sp}.txt"
    awk -v sp="$sp" '$3==sp && $6==0 {print $1}' "$PED_ANNOTATED" > "${WORK}/.nontrio_${sp}.txt"
    shuf --random-source=<(yes "${TARGET_RANDOM_SEED}_${sp}" | head -c 100000) "${WORK}/.trio_${sp}.txt" > "${WORK}/.trio_shuffled_${sp}.txt"
    shuf --random-source=<(yes "${TARGET_RANDOM_SEED}_${sp}_b" | head -c 100000) "${WORK}/.nontrio_${sp}.txt" > "${WORK}/.nontrio_shuffled_${sp}.txt"
    cat "${WORK}/.trio_shuffled_${sp}.txt" "${WORK}/.nontrio_shuffled_${sp}.txt" | head -n "$N_TARGET_PER_SUPERPOP" >> "${WORK}/.target_samples_raw.txt"
done

n_selected=$(wc -l < "${WORK}/.target_samples_raw.txt")
expected_n=$(( ${#SUPERPOPULATIONS[@]} * N_TARGET_PER_SUPERPOP ))
[[ "$n_selected" -eq "$expected_n" ]] \
    || die "$EXIT_SAMPLE_SET_INCONSISTENCY" "Selected $n_selected target samples, expected $expected_n (a superpopulation may have too few candidates)"

sort -u "${WORK}/.target_samples_raw.txt" > "${TARGET_SAMPLES_FILE}.part"
n_unique=$(wc -l < "${TARGET_SAMPLES_FILE}.part")
[[ "$n_unique" -eq "$expected_n" ]] \
    || die "$EXIT_SAMPLE_SET_INCONSISTENCY" "Target selection produced duplicates: $n_unique unique out of $expected_n"
mv "${TARGET_SAMPLES_FILE}.part" "$TARGET_SAMPLES_FILE"
log_step "Selected $n_unique target samples (file: $(basename "$TARGET_SAMPLES_FILE"))"

log_step "Finding first-degree relatives (parent/child/sibling) of target samples"
awk '
FNR==NR { fa[$1]=$4; mo[$1]=$5; allids[++n]=$1; next }
{ ntgt[++m]=$1 }
END {
    for (ti=1; ti<=m; ti++) {
        t = ntgt[ti]; tf = fa[t]; tm = mo[t]
        if (tf!="" && tf!="0") print tf, t, "parent"
        if (tm!="" && tm!="0") print tm, t, "parent"
        for (ai=1; ai<=n; ai++) {
            id = allids[ai]
            if (id==t) continue
            if (fa[id]==t || mo[id]==t) print id, t, "child"
            if (tf!="0" && tm!="0" && tf!="" && tm!="" && fa[id]==tf && mo[id]==tm) print id, t, "sibling"
        }
    }
}' "$PED_ANNOTATED" "$TARGET_SAMPLES_FILE" > "${WORK}/.relatives_raw.txt"

awk '{print $1}' "${WORK}/.relatives_raw.txt" | sort -u > "${WORK}/.excluded_ids.txt"
# A relative that happens to also be a chosen target stays a target, not an exclusion.
comm -23 "${WORK}/.excluded_ids.txt" "$TARGET_SAMPLES_FILE" > "${WORK}/.excluded_ids_final.txt"
{
    echo "ExcludedSampleID TargetSampleID Relationship"
    awk 'NR==FNR{keep[$1]=1; next} ($1 in keep)' "${WORK}/.excluded_ids_final.txt" "${WORK}/.relatives_raw.txt"
} > "${EXCLUDED_RELATIVES_FILE}.part"
mv "${EXCLUDED_RELATIVES_FILE}.part" "$EXCLUDED_RELATIVES_FILE"
n_excluded=$(($(wc -l < "$EXCLUDED_RELATIVES_FILE") - 1))
log_step "Excluding $n_excluded relative(s) of target samples from the reference panel (see $(basename "$EXCLUDED_RELATIVES_FILE"))"

log_step "Building reference sample list (VCF samples minus targets minus excluded relatives)"
sort "$VCF_SAMPLES" > "${WORK}/.vcf_samples_sorted.txt"
sort "$TARGET_SAMPLES_FILE" "${WORK}/.excluded_ids_final.txt" | sort -u > "${WORK}/.remove_from_reference.txt"
comm -23 "${WORK}/.vcf_samples_sorted.txt" "${WORK}/.remove_from_reference.txt" > "${REFERENCE_SAMPLES_FILE}.part"
mv "${REFERENCE_SAMPLES_FILE}.part" "$REFERENCE_SAMPLES_FILE"
n_reference=$(wc -l < "$REFERENCE_SAMPLES_FILE")
log_step "Reference panel: $n_reference samples"

# --- Consistency checks (control 1, extended to the derived sample sets) ---
overlap=$(comm -12 <(sort "$TARGET_SAMPLES_FILE") <(sort "$REFERENCE_SAMPLES_FILE") | wc -l)
[[ "$overlap" -eq 0 ]] || die "$EXIT_SAMPLE_SET_INCONSISTENCY" "$overlap sample(s) appear in both target and reference sets"

not_in_vcf=$(comm -23 <(sort "$TARGET_SAMPLES_FILE") "${WORK}/.vcf_samples_sorted.txt" | wc -l)
[[ "$not_in_vcf" -eq 0 ]] || die "$EXIT_SAMPLE_SET_INCONSISTENCY" "$not_in_vcf target sample(s) are not present in the VCF"

mark_step_output_done "$TARGET_SAMPLES_FILE"
mark_step_output_done "$REFERENCE_SAMPLES_FILE"
mark_step_output_done "$EXCLUDED_RELATIVES_FILE"

manifest_step_end "completed" 0 \
    "$(files_to_json_array "$PEDPOP_PATH" "$VCF_PATH")" \
    "$(files_to_json_array "$TARGET_SAMPLES_FILE" "$REFERENCE_SAMPLES_FILE" "$EXCLUDED_RELATIVES_FILE")" \
    "$(container_tool_versions_json bcftools)" \
    "{\"n_target\":${n_unique},\"n_reference\":${n_reference},\"n_excluded_relatives\":${n_excluded},\"seed\":\"${TARGET_RANDOM_SEED}\"}"

log_step "Sample selection complete: $n_unique target / $n_reference reference / $n_excluded excluded relatives"
