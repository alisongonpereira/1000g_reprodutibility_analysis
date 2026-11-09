#!/usr/bin/env bash
# Downloads chr20 phased VCF+index, the pedigree/population table, Beagle's
# genetic map, and a chr20-only slice of the GRCh38 reference FASTA (fetched
# by HTTP byte range from the official file's own .fai index, so we pull
# ~65 MB of sequence instead of the whole ~3 GB genome). Every file is
# checksummed: against the official MD5 manifest where one is published,
# or against our own recorded sha256 plus a structural integrity check
# where it is not (documented per-file below).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common_functions.sh"
source "${SCRIPT_DIR}/../config/pipeline_config.sh"

log_init "script_1_download_reference_data"
OUT_DIR="$DOWNLOAD_DIR"
mkdir -p "$OUT_DIR"
acquire_lock "01_download"
manifest_step_start "script_1_download_reference_data"

FAI_REMOTE_PATH="${OUT_DIR}/GRCh38_full_analysis_set_plus_decoy_hla.fa.fai"

download_if_needed() {
    local url="$1" dest="$2"; shift 2
    local extra_curl_args=("$@")
    if step_output_is_done "$dest"; then
        log_step "Already downloaded and verified, skipping: $(basename "$dest")"
        return 0
    fi
    log_step "Downloading $(basename "$dest")"
    log_detail "URL: $url"
    curl -fSL -C - --retry 5 --retry-delay 5 "${extra_curl_args[@]}" -o "${dest}.part" "$url" >> "$LOG_FILE" 2>&1 \
        || die "$EXIT_GENERIC_ERROR" "Download failed: $url"
    mv "${dest}.part" "$dest"
}

# bochet.gcc.biostat.washington.edu (Beagle's genetic maps) does not send its
# TLS intermediate certificate during the handshake -- a server-side
# misconfiguration, confirmed with `openssl s_client -connect ... | openssl
# x509 -noout -text`, which shows the chain and its Authority Information
# Access (AIA) "CA Issuers" URL. We fetch that one missing intermediate and
# verify against system-trust-plus-that-certificate -- a completed chain,
# not weakened verification.
ensure_beagle_map_ca_bundle() {
    local bundle="${OUT_DIR}/.ca_bundle_with_incommon_intermediate.pem"
    if [[ -s "$bundle" ]]; then
        echo "$bundle"
        return 0
    fi
    log_detail "bochet.gcc.biostat.washington.edu omits its TLS intermediate cert; fetching it from its own AIA URL"
    local intermediate_der="${OUT_DIR}/.incommon_ovg2c.der"
    curl -fSL --retry 3 -o "$intermediate_der" "https://repository.emsign.com/certs/EEEMIncommonOVG2C.crt" >> "$LOG_FILE" 2>&1 \
        || die "$EXIT_GENERIC_ERROR" "Could not fetch the missing intermediate CA certificate for bochet.gcc.biostat.washington.edu"
    local system_bundle="/etc/ssl/certs/ca-certificates.crt"
    [[ -f "$system_bundle" ]] || system_bundle="${SSL_CERT_FILE:-/root/.ccr/ca-bundle.crt}"
    { cat "$system_bundle"; openssl x509 -in "$intermediate_der" -inform DER; } > "${bundle}.part" 2>>"$LOG_FILE"
    mv "${bundle}.part" "$bundle"
    echo "$bundle"
}

# --- 1. VCF + index, checked against the official MD5 manifest ---
download_if_needed "$VCF_URL" "$VCF_PATH"
download_if_needed "$VCF_INDEX_URL" "$TBI_PATH"

if ! step_output_is_done "$VCF_PATH"; then
    log_step "Fetching official MD5 manifest to verify VCF and index"
    MD5_MANIFEST="${OUT_DIR}/official_md5_manifest.txt"
    curl -fSL --retry 3 -o "$MD5_MANIFEST" "$OFFICIAL_MD5_MANIFEST_URL" >> "$LOG_FILE" 2>&1 \
        || die "$EXIT_GENERIC_ERROR" "Could not fetch official MD5 manifest: $OFFICIAL_MD5_MANIFEST_URL"

    expected_vcf_md5="$(awk -v f="$VCF_FILENAME" '$1==f{print $2}' "$MD5_MANIFEST")"
    expected_tbi_md5="$(awk -v f="$(basename "$TBI_PATH")" '$1==f{print $2}' "$MD5_MANIFEST")"
    [[ -n "$expected_vcf_md5" ]] || die "$EXIT_CHECKSUM_MISMATCH" "VCF filename not found in official MD5 manifest: $VCF_FILENAME"
    [[ -n "$expected_tbi_md5" ]] || die "$EXIT_CHECKSUM_MISMATCH" "Index filename not found in official MD5 manifest"

    actual_vcf_md5="$(md5sum "$VCF_PATH" | awk '{print $1}')"
    actual_tbi_md5="$(md5sum "$TBI_PATH" | awk '{print $1}')"
    [[ "$actual_vcf_md5" == "$expected_vcf_md5" ]] || die "$EXIT_CHECKSUM_MISMATCH" "VCF MD5 mismatch (official manifest): expected $expected_vcf_md5, got $actual_vcf_md5"
    [[ "$actual_tbi_md5" == "$expected_tbi_md5" ]] || die "$EXIT_CHECKSUM_MISMATCH" "Index MD5 mismatch (official manifest): expected $expected_tbi_md5, got $actual_tbi_md5"
    log_step "VCF and index MD5 verified against the official 1000G manifest"

    mark_step_output_done "$VCF_PATH"
    mark_step_output_done "$TBI_PATH"
fi

# --- 2. Pedigree + population table: no official checksum is published for
# this file at the source. We record our own sha256 for future comparisons
# and check it is well-formed (right header, right column count). ---
download_if_needed "$PEDIGREE_POPULATION_URL" "$PEDPOP_PATH"
if ! step_output_is_done "$PEDPOP_PATH"; then
    header="$(head -1 "$PEDPOP_PATH")"
    [[ "$header" == "FamilyID SampleID FatherID MotherID Sex Population Superpopulation" ]] \
        || die "$EXIT_CORRUPT_INPUT" "Pedigree/population file has an unexpected header: $header"
    n_rows=$(($(wc -l < "$PEDPOP_PATH") - 1))
    [[ "$n_rows" -ge 3200 ]] || die "$EXIT_CORRUPT_INPUT" "Pedigree/population file has only $n_rows sample rows, expected >= 3200"
    log_step "Pedigree/population file structurally valid ($n_rows samples); no official checksum published at source, sha256 recorded"
    mark_step_output_done "$PEDPOP_PATH"
fi

# --- 3. Beagle genetic map (whole-genome zip, ~45 MB; no official checksum
# published). Integrity checked by verifying the zip's own CRCs. ---
if step_output_is_done "$MAP_ZIP_PATH"; then
    log_step "Already downloaded and verified, skipping: $(basename "$MAP_ZIP_PATH")"
else
    BEAGLE_CA_BUNDLE="$(ensure_beagle_map_ca_bundle)"
    download_if_needed "$BEAGLE_MAP_ZIP_URL" "$MAP_ZIP_PATH" --cacert "$BEAGLE_CA_BUNDLE"
fi
if ! step_output_is_done "$MAP_ZIP_PATH"; then
    run_container 1 1 "unzip -tq '$MAP_ZIP_PATH'" >> "$LOG_FILE" 2>&1 \
        || die "$EXIT_CORRUPT_INPUT" "Genetic map zip failed its own internal CRC check"
    log_step "Genetic map zip integrity OK (internal CRC check); no official checksum published at source, sha256 recorded"
    mark_step_output_done "$MAP_ZIP_PATH"
fi

# --- 4. GRCh38 FASTA, chr20 only, via HTTP byte range on the official file's
# own .fai index (saves ~3 GB vs. downloading the whole genome). ---
if ! step_output_is_done "$FASTA_SLICE_PATH"; then
    log_step "Fetching remote .fai to locate ${CHROM} byte range"
    curl -fSL --retry 3 -o "$FAI_REMOTE_PATH" "$GRCH38_FASTA_INDEX_URL" >> "$LOG_FILE" 2>&1 \
        || die "$EXIT_GENERIC_ERROR" "Could not fetch remote FASTA .fai: $GRCH38_FASTA_INDEX_URL"

    read -r name length offset linebases linewidth < <(awk -v c="$CHROM" '$1==c{print $1,$2,$3,$4,$5}' "$FAI_REMOTE_PATH")
    [[ "$name" == "$CHROM" ]] || die "$EXIT_CORRUPT_INPUT" "Chromosome $CHROM not found in remote FASTA .fai"

    newline_bytes=$((linewidth - linebases))
    full_lines=$((length / linebases))
    remainder=$((length % linebases))
    total_bytes=$((full_lines * linewidth))
    if [[ "$remainder" -gt 0 ]]; then
        total_bytes=$((total_bytes + remainder + newline_bytes))
    fi
    end_byte=$((offset + total_bytes - 1))
    log_detail "Computed byte range for $CHROM: ${offset}-${end_byte} (${total_bytes} bytes, ${length} bases)"

    printf '>%s\n' "$CHROM" > "${FASTA_SLICE_PATH}.part"
    curl -fSL --retry 3 --range "${offset}-${end_byte}" "$GRCH38_FASTA_URL" >> "${FASTA_SLICE_PATH}.part" 2>>"$LOG_FILE" \
        || die "$EXIT_GENERIC_ERROR" "Range request for $CHROM sequence failed"

    actual_bases=$(grep -v '^>' "${FASTA_SLICE_PATH}.part" | tr -d '\n' | wc -c)
    [[ "$actual_bases" -eq "$length" ]] \
        || die "$EXIT_CORRUPT_INPUT" "FASTA slice base count mismatch: expected $length, got $actual_bases"

    mv "${FASTA_SLICE_PATH}.part" "$FASTA_SLICE_PATH"
    run_container 1 1 "samtools faidx '$FASTA_SLICE_PATH'" >> "$LOG_FILE" 2>&1 \
        || die "$EXIT_GENERIC_ERROR" "samtools faidx failed on the chr20 slice"

    log_step "GRCh38 ${CHROM} slice fetched by byte range and verified ($length bases); no official checksum published for the source FASTA, sha256 recorded"
    mark_step_output_done "$FASTA_SLICE_PATH"
fi

manifest_step_end "completed" 0 \
    "[]" \
    "$(files_to_json_array "$VCF_PATH" "$TBI_PATH" "$PEDPOP_PATH" "$MAP_ZIP_PATH" "$FASTA_SLICE_PATH")" \
    "$(tool_versions_json curl)" \
    "{\"chrom\":\"${CHROM}\"}"

log_step "All reference data downloaded and verified"
