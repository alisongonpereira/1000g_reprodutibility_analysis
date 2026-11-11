#!/usr/bin/env bash
# Single source of truth for chromosome choice, sample design, resource
# limits and data source URLs. No script hardcodes any of these values.

# --- Scope ---
CHROM="chr20"                      # see README for the chr20 vs chr22 justification
CHROM_BARE="20"                    # same chromosome, bare notation (no "chr" prefix)

# --- Sample design ---
SUPERPOPULATIONS=(AFR AMR EAS EUR SAS)
N_TARGET_PER_SUPERPOP=5             # -> 25 target samples total
TARGET_RANDOM_SEED=1000             # fixed seed: sample selection is reproducible, not re-randomized on every run

# --- Array-density masking criterion for the target genotypes ---
# No chromosome-restricted, GRCh38, compatibly licensed real array site list
# was found (the public 1000G Omni2.5 VCF is genome-wide, GRCh37-coordinate
# only -- see README). We approximate chip density directly from the
# reference panel instead of depending on an external array file:
ARRAY_BIALLELIC_SNV_ONLY=true
ARRAY_MAF_MIN=0.05                  # arrays are enriched for common variants
ARRAY_THIN_SPACING_BP=1500          # ~ Omni2.5 genome-wide average marker spacing

# --- Resource control (per step; read by every script, never hardcoded) ---
THREADS_DOWNLOAD=4
THREADS_BCFTOOLS=4
THREADS_BEAGLE=4
RSTATS_MEM_GB=8                     # base R's read.table holds the ~1.6M-row metrics table in memory several times over
BEAGLE_HEAP_GB=8                    # -> java -Xmx${BEAGLE_HEAP_GB}g
N_IMPUTATION_WINDOWS=5               # chr20 split into this many idempotent windows

# --- Container image ---
DOCKER_IMAGE_NAME="1000g-imputation-demo"
DOCKER_IMAGE_TAG="v1"

# --- Beagle (installed from bioconda inside the image, exact version/build
# pinned in docker/environment.lock.yml; path matches the Dockerfile's ENV) ---
BEAGLE_JAR="/opt/conda/envs/demo/share/beagle-5.5_27Feb25.75f-0/beagle.jar"

# --- Official public data sources ---
# Every filename and checksum below was confirmed live against the EBI FTP
# directory listings on 2026-11-09 (see script_1 and evidence_report.md for
# the exact commands). script_1 re-downloads the official MD5 manifest on
# every run and compares against it -- the values here are provenance notes,
# not a substitute for that live check.
BASE_1000G_RELEASE_URL="https://ftp.1000genomes.ebi.ac.uk/vol1/ftp/data_collections/1000G_2504_high_coverage/working/20220422_3202_phased_SNV_INDEL_SV"
VCF_FILENAME="1kGP_high_coverage_Illumina.${CHROM}.filtered.SNV_INDEL_SV_phased_panel.vcf.gz"
VCF_URL="${BASE_1000G_RELEASE_URL}/${VCF_FILENAME}"
VCF_INDEX_URL="${VCF_URL}.tbi"
# This release ships per-file MD5s in a flat manifest, not a CHECKSUMS file.
OFFICIAL_MD5_MANIFEST_URL="${BASE_1000G_RELEASE_URL}/20220804_manifest.txt"

# Single file carrying both pedigree (FamilyID/FatherID/MotherID, for trio
# exclusion) and Population/Superpopulation (for stratified sampling).
PEDIGREE_POPULATION_URL="https://ftp.1000genomes.ebi.ac.uk/vol1/ftp/data_collections/1000G_2504_high_coverage/20130606_g1k_3202_samples_ped_population.txt"

GRCH38_FASTA_BASE_URL="https://ftp.1000genomes.ebi.ac.uk/vol1/ftp/technical/reference/GRCh38_reference_genome"
GRCH38_FASTA_FILENAME="GRCh38_full_analysis_set_plus_decoy_hla.fa"
GRCH38_FASTA_URL="${GRCH38_FASTA_BASE_URL}/${GRCH38_FASTA_FILENAME}"
GRCH38_FASTA_INDEX_URL="${GRCH38_FASTA_URL}.fai"
# No official checksum file is published for the FASTA at this source (see
# its README). script_1 records its own sha256 into the manifest instead of
# bypassing verification, and flags this gap explicitly in its log.
GRCH38_FASTA_HAS_OFFICIAL_CHECKSUM=false

BEAGLE_MAP_ZIP_URL="https://bochet.gcc.biostat.washington.edu/beagle/genetic_maps/plink.GRCh38.map.zip"

# --- Acceptance criteria file (declared before any execution, see root) ---
ACCEPTANCE_CRITERIA_FILE="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/acceptance_criteria.json"

# --- Derived paths. Config must be sourced after lib/common_functions.sh so
# PROJECT_ROOT is already set. Every script uses these instead of rebuilding
# the same strings, so a renamed file only needs to change in one place. ---
DOWNLOAD_DIR="${PROJECT_ROOT}/01_download"
VCF_PATH="${DOWNLOAD_DIR}/${VCF_FILENAME}"
TBI_PATH="${VCF_PATH}.tbi"
PEDPOP_PATH="${DOWNLOAD_DIR}/g1k_3202_samples_ped_population.txt"
MAP_ZIP_PATH="${DOWNLOAD_DIR}/plink.GRCh38.map.zip"
FASTA_SLICE_PATH="${DOWNLOAD_DIR}/${CHROM}.fa"

VALIDATION_DIR="${PROJECT_ROOT}/02_validation"
SAMPLE_SELECTION_DIR="${PROJECT_ROOT}/03_sample_selection"
TARGET_MASKED_DIR="${PROJECT_ROOT}/04_target_masked"
REFERENCE_PANEL_DIR="${PROJECT_ROOT}/05_reference_panel"
IMPUTATION_DIR="${PROJECT_ROOT}/06_imputation"
METRICS_DIR="${PROJECT_ROOT}/07_metrics"
VERDICT_DIR="${PROJECT_ROOT}/08_verdict"
TEST_VALIDATION_DIR="${PROJECT_ROOT}/09_test_validation"
TEST_RESUME_DIR="${PROJECT_ROOT}/10_test_resume"
TEST_LOCK_DIR="${PROJECT_ROOT}/11_test_lock"

TARGET_SAMPLES_FILE="${SAMPLE_SELECTION_DIR}/target_samples.txt"
REFERENCE_SAMPLES_FILE="${SAMPLE_SELECTION_DIR}/reference_samples.txt"
EXCLUDED_RELATIVES_FILE="${SAMPLE_SELECTION_DIR}/excluded_relatives.txt"

TARGET_TRUTH_VCF="${TARGET_MASKED_DIR}/target_truth.vcf.gz"
TARGET_MASKED_VCF="${TARGET_MASKED_DIR}/target_array_masked.vcf.gz"
REFERENCE_PANEL_VCF="${REFERENCE_PANEL_DIR}/reference_panel.vcf.gz"
IMPUTED_VCF="${IMPUTATION_DIR}/imputed.vcf.gz"
