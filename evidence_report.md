# Evidence report — clean execution

Executed end to end in this container, from a repository checkout with no
pre-existing output directories, by running `scripts/script_0_*.sh` through
`scripts/script_8_*.sh` in order, then the three failure-mode tests
(`script_9`, `script_10`, `script_11`). Every number below is read directly
from this run's own `manifest/manifest.json`, its per-step logs under
`logs/`, or a command re-run live against the files this run produced — none
of it is estimated or assumed. The full per-step logs are concatenated in
`full_execution_log.txt` (sent alongside this report).

## Control → implementation → evidence

| Control | Problem it solves | Implementation (file:line) | Evidence (command + summarized result) |
|---|---|---|---|
| 1. Input validation | Catching a corrupt/mislabeled input before expensive processing | `scripts/script_2_validate_inputs.sh:23` (bgzip), `:29` (duplicate IDs), `:41` (parses), `:47` (index), `:55` (chrom naming), `:66` (REF vs FASTA) | `bash scripts/script_9_test_input_validation_failures.sh` → `4 passed, 0 failed` (truncated→exit 10, chrom mismatch→exit 12, REF mismatch→exit 13, duplicate ID→exit 14) |
| 2. Resource control | Threads/memory declared once in config, actually enforced on every tool call | `config/pipeline_config.sh:25-28` (declared), `lib/common_functions.sh:225` `run_container()` (enforced via `docker run --cpus/--memory`) | `docker run --cpus=4 --memory=10g ... ; docker inspect $cid --format '{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}}'` → `4000000000 10737418240` (exactly 4.0 CPUs and 10 GiB, matching `THREADS_BEAGLE=4` and `BEAGLE_HEAP_GB+2=10` from config) |
| 2. Concurrency lock | Two runs can't silently corrupt the same output | `lib/common_functions.sh:105` `acquire_lock()` | `bash scripts/script_11_test_concurrency_lock.sh` → second instance exited with code 30 (`EXIT_LOCK_CONTENTION`) while the first was still running; `log`: "Confirmed: concurrent execution was blocked by the lock" |
| 3. Execution manifest | A machine-readable record of what actually ran | `lib/common_functions.sh:243` `manifest_step_end()` | `jq '.steps \| keys' manifest/manifest.json` → all 12 steps present, all with `"status": "completed"` |
| 4. Failure + resume | A crash mid-run shouldn't force a full restart or silently skip unfinished work | `lib/common_functions.sh:143` `step_output_is_done()`, `:153` `mark_step_output_done()` | `bash scripts/script_10_test_failure_and_resume.sh` → window 0 completed after 20s, process killed, resumed run's own log: "window 0 was skipped (checksum-verified), not reprocessed" + "at least one later window was (re)computed" |
| 5. Output verification | A PASS/FAIL verdict decided by criteria written down before the run | `acceptance_criteria.json` (repo root, declared up front), `scripts/script_8_verify_acceptance.sh:46-48` | `bash scripts/script_8_verify_acceptance.sh` → exit 40, `08_verdict/verdict.md`: overall **FAIL**, 6/8 criteria PASS, 2/8 FAIL (see below) |

## Numbers verified

Every figure below, with the exact command that produced it.

**Downloaded files and their checksums** — `jq '.steps.script_1_download_reference_data.outputs' manifest/manifest.json`:

| File | Size (bytes) | sha256 |
|---|---|---|
| `1kGP_high_coverage_Illumina.chr20....vcf.gz` | 687320087 | `9e936fdf434a4aa4ff1d37c0d386a13a43a7211d4f09fb5da811ed6eb5125626` |
| `....vcf.gz.tbi` | 61767 | `75813eaee99b87874b17616b88b0d711496dd6e9ae33b74d4a014a48a734d20b` |
| `g1k_3202_samples_ped_population.txt` | 97483 | `4e164b717433fc9bfc16e29b20e5b4659b4216185b3275322d421fe3d323c132` |
| `plink.GRCh38.map.zip` | 47469980 | `521549889b9ce0236142a4fb7db45d3f00035ec645e01465490d55f5b8ef26d6` |
| `chr20.fa` (byte-range slice) | 65364805 | `61eba5b05ef7d9ae5310e756c1143fa48072de3856d36871bb14e57aa2435ff3` |

Official MD5 verification, re-run live for this report —
`md5sum 01_download/1kGP_high_coverage_Illumina.chr20.filtered.SNV_INDEL_SV_phased_panel.vcf.gz{,.tbi}`
vs. `grep "chr20\." 01_download/official_md5_manifest.txt`:
```
34a9a5dbfb285e7eb9d1f2881953014b  ...vcf.gz        (ours == official)
59a2ff0c589ca6b78f45a17304f2117e  ...vcf.gz.tbi    (ours == official)
```

**chr20 FASTA byte range** (saved ~3 GB vs. the whole genome) —
`logs/script_1_download_reference_data.log`:
```
Computed byte range for chr20: 2751788762-2817153559 (65364798 bytes, 64444167 bases)
```

**Sample selection** — `grep "Sample selection complete" logs/script_3_select_samples.log`:
```
Sample selection complete: 25 target / 3147 reference / 30 excluded relatives
```
(25 + 3147 + 30 = 3202, the full cohort — `wc -l 03_sample_selection/target_samples.txt 03_sample_selection/reference_samples.txt` + `wc -l 03_sample_selection/excluded_relatives.txt`.)

**Array-density site list** — `grep "Array-density site list" logs/script_4_prepare_target_masked.log`:
```
Array-density site list: 30759 sites (from 158799 MAF-qualifying candidates)
```

**Target truth vs. array-masked variant counts** — `grep "Truth VCF:" logs/script_4_prepare_target_masked.log`:
```
Truth VCF: 1644384 variants. Array-masked VCF: 33406 variants.
```

**Reference panel** — `grep "Reference panel:" logs/script_5_prepare_reference_panel.log`:
```
Reference panel: 3147 samples, 1644384 variants
```

**Imputation** — `jq '.steps.script_6_run_imputation' manifest/manifest.json`:
```
1644384 variants, 25 samples, 5 windows, 4 threads, 8GB heap
start_time=2026-11-09T16:10:36Z  end_time=2026-11-09T16:14:01Z  (3m25s wall clock)
```

**Accuracy metrics** — `cat 07_metrics/accuracy_metrics.json`:
```json
{
  "dosage_r2_overall": 0.802854,
  "dosage_r2_maf_lt_0_01": 0.310900,
  "dosage_r2_maf_0_01_0_05": 0.685286,
  "dosage_r2_maf_gte_0_05": 0.867384,
  "nonref_genotype_concordance_overall": 0.871709,
  "imputed_variant_count": 1644384,
  "imputed_sample_count": 25,
  "n_genotype_pairs_compared": 40324625,
  "n_nonref_truth_calls": 2361241
}
```

**Final verdict** — `bash scripts/script_8_verify_acceptance.sh; cat 08_verdict/verdict.md`:

| Criterion | Target | Observed | Result |
|---|---|---|---|
| Dosage r² overall | >= 0.80 | 0.802854 | PASS |
| Dosage r² (MAF < 1%) | >= 0.30 | 0.310900 | PASS |
| Dosage r² (1% <= MAF < 5%) | >= 0.60 | 0.685286 | PASS |
| Dosage r² (MAF >= 5%) | >= 0.90 | 0.867384 | **FAIL** |
| Non-ref genotype concordance | >= 0.95 | 0.871709 | **FAIL** |
| Variant count retained | == 1644384 | 1644384 | PASS |
| Sample count | == 25 | 25 | PASS |
| All manifest steps completed | == true | true | PASS |

**Overall verdict: FAIL** (6 of 8 criteria). This is the honest result of
this run against the thresholds declared in `acceptance_criteria.json`
*before* execution — they were not adjusted after seeing these numbers. The
two failing criteria (common-variant r² and non-reference concordance) are
plausible given the setup: concordance is computed over every non-reference
call on the whole chromosome (1.6M variants, including large numbers of very
rare variants that are intrinsically hard to impute), not restricted to
common, array-typical sites, and the array mask itself is an approximation
(see README). This is exactly the kind of result control 5 exists to
surface rather than hide.

**Failure-mode test results** — `jq '.steps.script_9_test_input_validation_failures, .steps.script_10_test_failure_and_resume, .steps.script_11_test_concurrency_lock | .parameters' manifest/manifest.json`:
```
script_9:  pass_count=4, fail_count=0
script_10: window0_skipped_on_resume=true, later_window_recomputed=true, waited_seconds_before_kill=20
script_11: second_instance_exit_code=30, expected_exit_code=30
```

## Post-report change: statistics moved from awk to R

After this report was first written, the Pearson r^2 / concordance
computation in `script_7_compute_accuracy_metrics.sh` (previously a
hand-accumulated formula in awk) was replaced with
`scripts/compute_accuracy_stats.R`, run inside a second, separately-pinned
conda env (`docker/environment.rstats.lock.yml`, R 4.6.2) added to the same
image. bcftools and awk still do all VCF access and GT/GP-to-number
reshaping; only the actual statistics moved. Re-run against the same real
`07_metrics/.joined.tsv` this report's numbers came from --
`bash scripts/script_7_compute_accuracy_metrics.sh` then
`bash scripts/script_8_verify_acceptance.sh` -- produced byte-identical
output to every number in "Numbers verified" above, including the FAIL
verdict on the same two criteria. See `git log` for the commit.

## Known caveats of this specific run

- `bochet.gcc.biostat.washington.edu` (Beagle's genetic maps) omits its TLS
  intermediate certificate; `script_1` fetches it from its own AIA URL and
  verifies against the completed chain (see README and
  `scripts/script_1_download_reference_data.sh`'s `ensure_beagle_map_ca_bundle`).
  This is a server-side misconfiguration at the source, not a weakening of
  verification on our side.
- Two bugs were found and fixed by actually running the test scripts (not by
  inspection): `set -e` inherited from the sourced library killed `script_9`
  on an *expected* subprocess failure, and `script_2`'s bcftools-based parse
  check could not reach the dedicated duplicate-sample-ID check because
  htslib itself refuses to open a VCF with duplicate sample names. Both are
  described in the commit history (`git log --oneline`).
