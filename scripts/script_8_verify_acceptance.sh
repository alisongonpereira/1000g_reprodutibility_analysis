#!/usr/bin/env bash
# Control 5: output verification against acceptance_criteria.json, which was
# declared before any execution (see repo root). Prints a PASS/FAIL verdict
# with the observed value next to every criterion. Exits 0 on overall PASS,
# EXIT_ACCEPTANCE_FAILED on overall FAIL -- the manifest step itself is
# recorded "completed" either way, since verification ran successfully;
# the exit code is what carries the PASS/FAIL signal to automation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common_functions.sh"
source "${SCRIPT_DIR}/../config/pipeline_config.sh"

log_init "script_8_verify_acceptance"
mkdir -p "$VERDICT_DIR"
manifest_step_start "script_8_verify_acceptance"

METRICS_FILE="${METRICS_DIR}/accuracy_metrics.json"
REF_STATS_FILE="${REFERENCE_PANEL_DIR}/reference_panel_stats.json"
VERDICT_JSON="${VERDICT_DIR}/verdict.json"
VERDICT_MD="${VERDICT_DIR}/verdict.md"

[[ -f "$METRICS_FILE" ]] || die "$EXIT_GENERIC_ERROR" "Missing $METRICS_FILE; run script_7_compute_accuracy_metrics.sh first"
[[ -f "$REF_STATS_FILE" ]] || die "$EXIT_GENERIC_ERROR" "Missing $REF_STATS_FILE; run script_5_prepare_reference_panel.sh first"
[[ -f "$ACCEPTANCE_CRITERIA_FILE" ]] || die "$EXIT_GENERIC_ERROR" "Missing $ACCEPTANCE_CRITERIA_FILE"
manifest_init

all_steps_completed=$(jq '([.steps[].status] | length) > 0 and ([.steps[].status] | all(. == "completed"))' "$MANIFEST_FILE")
ref_variant_count=$(jq '.n_variants' "$REF_STATS_FILE")

observed_json=$(jq --argjson ref_count "$ref_variant_count" --argjson all_done "$all_steps_completed" \
    '. + {reference_panel_variant_count: $ref_count, manifest_all_steps_completed: $all_done}' "$METRICS_FILE")

results_json=$(jq -n --argjson criteria "$(jq '.criteria' "$ACCEPTANCE_CRITERIA_FILE")" --argjson observed "$observed_json" '
  $criteria | map(
    . as $c
    | $observed[$c.metric] as $obs_val
    | (if $c.compare_to_metric then $observed[$c.compare_to_metric] else $c.threshold end) as $target
    | (if $c.operator == ">=" then ($obs_val >= $target)
       elif $c.operator == "==" then ($obs_val == $target)
       else false end) as $pass
    | {id: $c.id, description: $c.description, metric: $c.metric, operator: $c.operator,
       target: $target, observed: $obs_val, pass: $pass}
  )')

overall_pass=$(jq -n --argjson r "$results_json" '($r | all(.pass))')
overall_verdict="FAIL"
[[ "$overall_pass" == "true" ]] && overall_verdict="PASS"

jq -n --argjson criteria "$results_json" --arg verdict "$overall_verdict" --arg generated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{generated_at: $generated_at, overall_verdict: $verdict, criteria: $criteria}' > "${VERDICT_JSON}.part"
mv "${VERDICT_JSON}.part" "$VERDICT_JSON"

{
    echo "# Acceptance verdict: ${overall_verdict}"
    echo
    echo "Generated at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo
    echo "| Criterion | Operator | Target | Observed | Result |"
    echo "|---|---|---|---|---|"
    jq -r '.[] | "| \(.description) | \(.operator) | \(.target) | \(.observed) | \(if .pass then "PASS" else "FAIL" end) |"' <<< "$results_json"
} > "${VERDICT_MD}.part"
mv "${VERDICT_MD}.part" "$VERDICT_MD"

log_step "Verdict: $overall_verdict (see $(basename "$VERDICT_MD"))"

manifest_step_end "completed" 0 \
    "$(files_to_json_array "$METRICS_FILE" "$REF_STATS_FILE" "$ACCEPTANCE_CRITERIA_FILE")" \
    "$(files_to_json_array "$VERDICT_JSON" "$VERDICT_MD")" \
    "{}" \
    "{\"overall_verdict\":\"${overall_verdict}\"}"

if [[ "$overall_verdict" != "PASS" ]]; then
    log_error "One or more acceptance criteria failed; see $VERDICT_MD"
    exit "$EXIT_ACCEPTANCE_FAILED"
fi
