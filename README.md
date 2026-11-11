# 1000 Genomes imputation reproducibility demo

A minimal, public, independently-reproducible demonstration that
**execution reproducibility** of a bioinformatics workflow -- input
validation, resource control, execution logging, failure/resume handling,
and output verification -- can be made an explicit, inspectable part of the
workflow's own code, instead of an infrastructure afterthought. The
scientific task (genotype imputation on one chromosome) is real and uses
real public data; it exists to give the five controls something concrete to
act on, not as an imputation-accuracy benchmark in its own right.

## What this demonstrates

| Control | Problem it solves | Where |
|---|---|---|
| 1. Input validation | Catching a corrupt or mislabeled input *before* an hours-long job burns compute on it | `scripts/script_2_validate_inputs.sh`, exercised on deliberately broken real data by `scripts/script_9_test_input_validation_failures.sh` |
| 2. Resource control + concurrency lock | Threads/memory declared once, actually enforced by the tools; two runs can't silently corrupt the same output | `config/pipeline_config.sh` (declared), `lib/common_functions.sh:run_container`/`acquire_lock` (enforced), exercised by `scripts/script_11_test_concurrency_lock.sh` |
| 3. Execution manifest | A machine-readable record of what actually ran: tool versions, parameters, checksums, timestamps, host, status | `lib/common_functions.sh:manifest_step_end`, written to `manifest/manifest.json` by every script |
| 4. Failure handling + resume | A crash mid-run should not force a full restart, and must not silently skip something that never finished | `lib/common_functions.sh:step_output_is_done`/`mark_step_output_done`, exercised by `scripts/script_10_test_failure_and_resume.sh` |
| 5. Output verification | A PASS/FAIL verdict decided by criteria written down *before* the run, not picked after looking at the numbers | `acceptance_criteria.json` (declared up front), `scripts/script_8_verify_acceptance.sh` (verdict) |

## Data and design choices

- **Chromosome: chr20** (GRCh38, ~64 Mb). It is the de facto standard
  benchmark chromosome in the imputation literature (including Beagle's own
  documentation), fully euchromatic (unlike the acrocentric chromosomes),
  and small enough to download and process on a laptop.
- **Data source**: the NYGC high-coverage 1000 Genomes phased call set
  (3,202 samples, GRCh38, release `20220422_3202_phased_SNV_INDEL_SV`) from
  the official EBI/IGSR FTP, plus the official GRCh38 reference FASTA and
  the official Beagle genetic maps (Browning lab, UW). Every URL is in
  `config/pipeline_config.sh`; `script_1` re-verifies against the live
  source on every run rather than trusting a cached assumption.
- **Target samples**: 25 samples (5 per superpopulation: AFR, AMR, EAS,
  EUR, SAS), preferring samples that are part of a 1000G trio so the
  relative-exclusion rule is actually exercised, not vacuous.
- **Reference panel**: every other chr20 sample, minus the target samples'
  first-degree relatives (parent/child/sibling, from the pedigree file),
  so accuracy isn't inflated by a close relative sitting in the reference.
- **Array-density masking**: no real genotyping-array site list could be
  used as-is. The public 1000G Omni2.5 array VCF is genome-wide and in
  **GRCh37** coordinates only; using it would require a liftover step (a
  chain file, a tool, and its own failure modes near indels) that adds real
  risk for a minimal demo. Instead, the target genotypes are masked to a
  site list computed directly from chr20 itself: biallelic SNVs, reference-
  panel MAF >= 5%, thinned to ~1 marker per 1.5 kb (approximating the
  Omni2.5 genome-wide average density of ~1 marker/kb). This is a declared,
  inspectable simplification (`script_4`), not a hidden one.
- **Imputation**: Beagle 5.5 (bioconda build `5.5_27Feb25.75f`), run
  locally against the official Beagle GRCh38 genetic map, in 5 genomic
  windows (so the failure/resume test has real, separately-checkpointed
  units of work, not just one monolithic job).

### Why R for one step

Everything in this pipeline is bash + bcftools/awk, on purpose (see
"Environment" below) -- with one exception: the actual statistics in
`scripts/script_7_compute_accuracy_metrics.sh` (Pearson r^2 by MAF bin,
non-reference concordance) are computed by
`scripts/compute_accuracy_stats.R`, not accumulated by hand with running
sums in awk. bcftools still does all VCF access, and awk still reshapes
GT/GP strings into plain numbers -- that's file-format handling, not
statistics, and awk is a reasonable tool for it. But a Pearson correlation
is exactly the kind of thing a real stats runtime should compute, not
something to re-derive from the `(n*sxy - sx*sy) / sqrt(...)` formula by
hand. R runs in its own conda env inside the same image (see below), so
this didn't cost the pipeline a second container or a second dependency
story. Both implementations were cross-checked against the same real data
and produced identical results (`git log` has the commit).

## Environment

One pinned Docker image (`docker/Dockerfile` + `docker/environment.lock.yml`,
exact `name=version=build` pins for bcftools, samtools, htslib, Beagle and
OpenJDK via conda-forge/bioconda, plus `docker/environment.rstats.lock.yml`
pinning R 4.6.2 in its own conda env) provides every tool the pipeline uses.
R sits in a separate env from the rest because its conda-forge build needs
`icu`/`libdeflate`/`gsl` versions that conflict with the pinned
bcftools/samtools/htslib builds -- solving it on its own avoids re-pinning
already-verified tools just to fit a statistics runtime next to them; both
envs' `bin/` directories are on `PATH`; `run_container` is unaffected since
it is the container's resource limits that are declared, not which env a
given tool comes from (see `RSTATS_MEM_GB` in `config/pipeline_config.sh`).
Docker was chosen over a bare conda/mamba install because it also pins the
OS layer, and over Apptainer/Singularity only because Docker is what this
demo's own test environment had available; the image is standard OCI, so it
runs unmodified under Apptainer on a shared HPC cluster:

```bash
apptainer pull docker-daemon:1000g-imputation-demo:v1
apptainer run 1000g-imputation-demo_v1.sif
```

The host only needs `bash`, `docker`, `curl`, `jq` and standard coreutils
(`awk`, `sort`, `comm`, `join`, `shuf`); every bcftools/samtools/Beagle call
runs inside the pinned container via `lib/common_functions.sh:run_container`,
which also enforces the CPU/memory limits from `config/pipeline_config.sh`.

A SLURM profile is out of scope for this demo (local execution only); the
container image is the only piece that would need to move to run the same
pipeline on a shared cluster.

## Requirements

- Docker (daemon running), bash >= 5, curl, jq, standard coreutils.
- ~800 MB of download (chr20 VCF ~656 MB, chr20 FASTA slice ~62 MB fetched
  by HTTP byte range instead of the whole ~3 GB genome, Beagle genetic maps
  ~45 MB, pedigree/population table <1 MB).
- A few GB of free disk for intermediates (reference panel, imputed VCF,
  per-window outputs).
- Network access to `ftp.1000genomes.ebi.ac.uk`, `faculty.washington.edu`,
  `bochet.gcc.biostat.washington.edu` and common package registries (for
  the one-time image build).

## How to run

From a clean clone:

```bash
for i in 0 1 2 3 4 5 6 7 8; do
    bash scripts/script_${i}_*.sh || { echo "FAILED at step $i"; exit 1; }
done
```

Every script is idempotent: re-running the same command after it already
succeeded re-verifies checksums and skips completed steps instead of
redoing them. Measured on the real run this repository's evidence comes
from (4 cores, Beagle on 4 threads): a few minutes for the download
(network-dependent, ~800 MB) and 3m25s for the imputation step itself
across all 5 windows -- see `evidence_report.md` for the exact timestamps.

### Expected output

- `08_verdict/verdict.md` -- a human-readable PASS/FAIL table, one row per
  acceptance criterion, with the observed value next to each target.
- `08_verdict/verdict.json` -- the same, machine-readable.
- `manifest/manifest.json` -- one entry per step: script, tool versions,
  parameters, input/output checksums, start/end time, host, status.
- `logs/*.log` -- full detail per step (every command's output); the
  console only ever shows the one-line summary for each step.

## Running the failure-mode tests

Each test script only needs the earlier pipeline steps' outputs; none of
them touch the main run's files:

```bash
bash scripts/script_9_test_input_validation_failures.sh   # 4 corrupted real fixtures, each must be rejected with its documented exit code
bash scripts/script_10_test_failure_and_resume.sh          # kills imputation mid-run, resumes it, checks the resumed run's own log
bash scripts/script_11_test_concurrency_lock.sh             # starts imputation twice at once, checks the second instance is rejected
```

Each prints its own PASS/FAIL per sub-case to the console and records a
`manifest/manifest.json` entry (`script_9/10/11_...`) for the run.

## Interpreting the manifest and the verdict

`manifest/manifest.json` has one object per step under `.steps`. A step's
`status` is `"completed"` only if it actually finished; `exit_code`,
`tool_versions`, `parameters`, and the `sha256` of every listed input/output
are what let you audit *exactly* what produced a given file, without
re-running anything. `script_8_verify_acceptance.sh` reads this file to
decide the `all_steps_completed` criterion.

`08_verdict/verdict.json`'s `overall_verdict` is `"PASS"` only if every row
in `criteria` has `"pass": true`. Each row's `target` and `observed` are
plain numbers (or booleans/counts) so a failing criterion is visible without
cross-referencing anything else.

## Known limitations (stated, not hidden)

- The array-density mask approximates a real genotyping array; see "Data
  and design choices" above.
- The GRCh38 FASTA and the pedigree/population table have no official
  checksum published at their source; `script_1` checks them structurally
  and records its own sha256 instead of skipping verification.
- `bochet.gcc.biostat.washington.edu` (Beagle's genetic maps) does not send
  its TLS intermediate certificate during the handshake -- a server-side
  misconfiguration confirmed with `openssl s_client`. `script_1` fetches
  that one missing intermediate from its own Authority Information Access
  (AIA) URL and verifies against the completed chain; it never disables
  certificate verification.
- This is a demonstration of the five controls, not an imputation-accuracy
  benchmark: 25 target samples and one chromosome give stable-enough
  numbers to check against the declared acceptance criteria, not a
  publishable accuracy estimate.
