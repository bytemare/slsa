#!/usr/bin/env bash
#
# SPDX-License-Identifier: MIT
#
# Copyright (C) 2025 Daniel Bourdrez. All Rights Reserved.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree or at
# https://spdx.org/licenses/MIT.html
#

# This script automates the verification of SLSA Level 3 compliant releases,
# including checksum verification, signature verification, and a full, containerized
# reproducibility check using a digest-pinned Go toolchain.
#
# Usage:
#   ./verify-release.sh --repo OWNER/REPO --tag TAG [--mode MODE]
#
# Arguments:
#   --repo OWNER/REPO    Repository in format owner/repo (e.g., bytemare/workflows)
#   --tag TAG            Release tag to verify (e.g., 0.0.4)
#   --mode MODE          Verification mode: quick, full, or reproduce (default: quick)
#
# Modes:
#   quick     - Basic checksum and signature verification.
#   full      - Complete verification of all release artifacts (checksums, signatures, SBOM, provenance).
#   reproduce - Full, containerized reproducibility check.
#

set -euo pipefail

# Default container image used for rebuild verification (matches CI builder digest).
# The reproduce mode prefers the value recorded in build.env but falls back to this.
readonly REPRO_IMAGE_DEFAULT="golang:1.25-bookworm@sha256:42d8e9dea06f23d0bfc908826455213ee7f3ed48c43e287a422064220c501be9"

# Color codes for output
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_MISSING_TOOL=1
readonly EXIT_MISSING_ARG=2
readonly EXIT_VERIFICATION_FAILED=3
readonly EXIT_DOWNLOAD_FAILED=4

# Global variables
REPO=""
TAG=""
MODE="quick"
WORK_DIR=""
OWNER=""
REPO_NAME=""
CALLER_PWD="$(pwd -P)"
EMIT_VSA_PATH=""
POLICY_URI=""
POLICY_FILE=""
VERIFIER_ID=""
VERIFIER_VERSIONS=()
VERIFIED_LEVELS=()
RESOURCE_URI=""
SLSA_VERSION="1.1"
TIME_VERIFIED_OVERRIDE=""

# Print a verification step
verify_step() {
    local message="$1"
    printf "% -60s" "$message..."

    return 0
}

verify_ok() {
    echo -e " ${GREEN}✓${NC}"

    return 0
}

verify_fail() {
    local error="${1:-""}"
    echo -e " ${RED}✗${NC}"
    if [[ -n "$error" ]]; then
        echo -e "  ${RED}Error: $error${NC}" >&2
    fi

    return 0
}

# Usage information
usage() {
    cat << EOF
Usage: $0 --repo OWNER/REPO --tag TAG [--mode MODE]

Verify SLSA Level 3 compliant release artifacts.

Required Arguments:
  --repo OWNER/REPO    Repository in format owner/repo (e.g., bytemare/workflows)
  --tag TAG            Release tag to verify (e.g., 0.0.4)

Optional Arguments:
  --mode MODE          Verification mode (default: quick)
                       - quick: Basic checksum and signature verification.
                       - full: Complete verification of all release artifacts.
                       - reproduce: Full, containerized reproducibility check.
                       - vsa: Verify verification-summary attestation only.
  --emit-vsa PATH      Emit a v1.1 Verification Summary Attestation JSON to PATH
  --verifier-id URI    Identifier for the verifying entity (required when emitting a VSA)
  --verifier-version K=V
                       Additional version metadata for the verifier (repeatable)
  --policy-uri URI     URI of the verification policy being applied (optional)
  --policy-file PATH   File used to compute the policy digest (defaults to this script)
  --verified-level L   Append a verified SLSA level (repeatable, default: SLSA_BUILD_LEVEL_3)
  --resource-uri URI   Resource URI describing the artifact under verification
  --time-verified TS   Override the VSA timeVerified field (RFC3339, defaults to current time)
  --slsa-version VER   Predicated SLSA version for the VSA (default: 1.1)
  --help               Show this help message

Examples:
  $0 --repo bytemare/workflows --tag 0.0.4
  $0 --repo bytemare/workflows --tag 0.0.4 --mode full
  $0 --repo bytemare/workflows --tag 0.0.4 --mode reproduce
  $0 --repo bytemare/workflows --tag 0.0.4 --mode vsa
  $0 --repo bytemare/workflows --tag 0.0.4 --mode full --emit-vsa my.vsa.json --verifier-id https://example.com/verifier

Note: VSA emission happens after all checks succeed to preserve a verifier/producer separation—a consumer or CI policy can trust the summary because it was generated post-release by the verification workflow, not during packaging.

EOF

    return 0
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        local arg=$1
        case $arg in
            --repo)
                REPO="$2"
                shift 2
                ;; 
            --tag)
                TAG="$2"
                shift 2
                ;; 
            --mode)
                MODE="$2"
                shift 2
                ;; 
            --emit-vsa)
                EMIT_VSA_PATH="$2"
                shift 2
                ;; 
            --verifier-id)
                VERIFIER_ID="$2"
                shift 2
                ;; 
            --verifier-version)
                VERIFIER_VERSIONS+=("$2")
                shift 2
                ;; 
            --policy-uri)
                POLICY_URI="$2"
                shift 2
                ;; 
            --policy-file)
                POLICY_FILE="$2"
                shift 2
                ;; 
            --verified-level)
                VERIFIED_LEVELS+=("$2")
                shift 2
                ;; 
            --resource-uri)
                RESOURCE_URI="$2"
                shift 2
                ;; 
            --time-verified)
                TIME_VERIFIED_OVERRIDE="$2"
                shift 2
                ;; 
            --slsa-version)
                SLSA_VERSION="$2"
                shift 2
                ;; 
            --help)
                usage
                exit $EXIT_SUCCESS
                ;; 
            *)
                echo -e "${RED}Error: Unknown argument: $arg${NC}" >&2
                usage
                exit $EXIT_MISSING_ARG
                ;; 
        esac
    done

    if [[ -z "$REPO" ]]; then
        echo -e "${RED}Error: Missing required argument: --repo${NC}" >&2
        usage
        exit $EXIT_MISSING_ARG
    fi

    if [[ -z "$TAG" ]]; then
        echo -e "${RED}Error: Missing required argument: --tag${NC}" >&2
        usage
        exit $EXIT_MISSING_ARG
    fi

    if [[ "$MODE" != "quick" && "$MODE" != "full" && "$MODE" != "reproduce" && "$MODE" != "vsa" ]]; then
        echo -e "${RED}Error: Invalid mode: $MODE (must be quick, full, reproduce, or vsa)${NC}" >&2
        usage
        exit $EXIT_MISSING_ARG
    fi

    OWNER="${REPO%%/*}"
    REPO_NAME="${REPO##*/}"

    if [[ -z "$OWNER" || -z "$REPO_NAME" ]]; then
        echo -e "${RED}Error: Invalid repository format. Use OWNER/REPO${NC}" >&2
        exit $EXIT_MISSING_ARG
    fi

    if [[ ${#VERIFIED_LEVELS[@]} -eq 0 ]]; then
        VERIFIED_LEVELS=("SLSA_BUILD_LEVEL_3")
    fi

    if [[ -n "$EMIT_VSA_PATH" ]]; then
        if [[ -z "$VERIFIER_ID" ]]; then
            echo -e "${RED}Error: --verifier-id is required when using --emit-vsa${NC}" >&2
            exit $EXIT_MISSING_ARG
        fi
        if [[ -z "$POLICY_URI" ]]; then
            POLICY_URI="https://github.com/${REPO}/blob/${TAG}/verify-release.sh"
        fi
        if [[ -z "$RESOURCE_URI" ]]; then
            RESOURCE_URI="https://github.com/${REPO}/releases/tag/${TAG}"
        fi
    fi

    if [[ -z "$POLICY_FILE" ]]; then
        POLICY_FILE="$0"
    fi

    # Normalize paths relative to the invoking directory so the script can chdir safely.
    if [[ -n "$EMIT_VSA_PATH" && "${EMIT_VSA_PATH:0:1}" != "/" ]]; then
        EMIT_VSA_PATH="${CALLER_PWD}/${EMIT_VSA_PATH}"
    fi
    if [[ -n "$POLICY_FILE" && "${POLICY_FILE:0:1}" != "/" ]]; then
        POLICY_FILE="${CALLER_PWD}/${POLICY_FILE}"
    fi

    return 0
}

sha256_of() {
    local file="$1"
    if command -v sha256sum &> /dev/null; then
        sha256sum -- "$file" | awk '{print $1}'
    else
        shasum -a 256 -- "$file" | awk '{print $1}'
    fi
}

# Check for required tools
check_tools() {
    local missing_tools=()
    local required_tools=("gh" "jq" "openssl" "cosign")

    if [[ "$MODE" == "reproduce" ]]; then
        required_tools=("docker" "gh")
    elif [[ "$MODE" == "full" ]]; then
        required_tools+=("slsa-verifier")
    fi

    if ! command -v sha256sum &> /dev/null && ! command -v shasum &> /dev/null; then
        missing_tools+=("sha256sum or shasum")
    fi

    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        echo -e "${RED}Error: Missing required tools: ${missing_tools[*]}${NC}" >&2
        exit $EXIT_MISSING_TOOL
    fi

    return 0
}

run_slsa_verifier() {
    verify_step "Verifying provenance with slsa-verifier"

    local provenance_file
    provenance_file=$(find . -maxdepth 1 -name "*.intoto.jsonl" -type f -print -quit 2>/dev/null)
    if [[ -z "$provenance_file" ]]; then
        verify_fail "Provenance file not found"
        return 1
    fi

    local artifact
    artifact=$(find . -maxdepth 1 -name "*.tar.gz" -type f -print -quit 2>/dev/null)
    if [[ -z "$artifact" ]]; then
        verify_fail "Source tarball missing"
        return 1
    fi

    if slsa-verifier verify-artifact --provenance-path "$provenance_file" --source-uri "github.com/$REPO" --source-tag "$TAG" "$artifact"; then
        verify_ok
    else
        verify_fail "slsa-verifier verification failed"
        return 1
    fi

    return 0
}

# Download release artifacts for quick/full modes
download_artifacts() {
    local patterns=()

    if [[ "$MODE" == "vsa" ]]; then
        patterns=(
            "verification-summary.attestation.json"
            "verification-summary.attestation.json.bundle"
            "subjects.sha256"
        )
    else
        patterns=(
            "*.tar.gz"
            "*.bundle"
            "subjects.sha256"
            "checksums.txt"
        )
        if [[ "$MODE" == "full" ]]; then
            patterns+=(
                "*.intoto.jsonl"
                "sbom.cdx.json"
                "verification.json"
                "manifest.files.sha256"
                "verification-summary.attestation.json"
                "verification-summary.attestation.json.bundle"
            )
        fi
    fi

    verify_step "Downloading release artifacts"

    for pattern in "${patterns[@]}"; do
        gh release download "$TAG" --repo "$REPO" -p "$pattern" >/dev/null 2>&1 || true
    done

    if [[ "$MODE" == "vsa" ]]; then
        if [[ ! -f verification-summary.attestation.json ]]; then
            verify_fail "verification-summary.attestation.json missing"
            return 1
        fi
        if [[ ! -f verification-summary.attestation.json.bundle ]]; then
            verify_fail "verification-summary.attestation.json.bundle missing"
            return 1
        fi
        if [[ ! -f subjects.sha256 ]]; then
            verify_fail "subjects.sha256 missing (required for digest cross-check)"
            return 1
        fi
    else
        if [[ ! -f subjects.sha256 ]] || [[ ! -f checksums.txt ]]; then
            verify_fail "Critical files (subjects.sha256, checksums.txt) missing"
            return 1
        fi

        local tarball
        tarball=$(find . -maxdepth 1 -name "*.tar.gz" -type f -print -quit 2>/dev/null)
        if [[ -z "$tarball" ]]; then
            verify_fail "Source tarball missing"
            return 1
        fi
    fi

    verify_ok

    return 0
}

# --- Verification functions for quick/full modes ---
verify_subjects() {
    verify_step "Verifying SLSA subjects structure"
    local subject_count
    subject_count=$(wc -l < subjects.sha256 | tr -d ' ')
    if [[ "$subject_count" -eq 2 ]]; then
        verify_ok
    else
        verify_fail "Expected 2 subjects, found $subject_count"
        return 1
    fi

    return 0
}

verify_tarball_checksum() {
    verify_step "Verifying tarball checksum"
    local tarball
    tarball=$(find . -maxdepth 1 -name "*.tar.gz" -type f -print -quit)
    local computed_hash
    if command -v sha256sum &> /dev/null; then
        computed_hash=$(sha256sum -- "$tarball" | awk '{print $1}')
    else
        computed_hash=$(shasum -a 256 -- "$tarball" | awk '{print $1}')
    fi
    local expected_hash
    expected_hash=$(head -n1 subjects.sha256 | awk '{print $1}')
    if [[ "$computed_hash" == "$expected_hash" ]]; then
        verify_ok
    else
        verify_fail "Tarball checksum mismatch"
        return 1
    fi

    return 0
}

verify_checksums_manifest() {
    verify_step "Verifying checksums manifest"
    local computed_hash
    if command -v sha256sum &> /dev/null; then
        computed_hash=$(sha256sum -- checksums.txt | awk '{print $1}')
    else
        computed_hash=$(shasum -a 256 -- checksums.txt | awk '{print $1}')
    fi
    local expected_hash
    expected_hash=$(tail -n1 subjects.sha256 | awk '{print $1}')
    if [[ "$computed_hash" == "$expected_hash" ]]; then
        verify_ok
    else
        verify_fail "Checksum mismatch"
        return 1
    fi

    return 0
}

verify_signatures() {
    local tarball
    tarball=$(find . -maxdepth 1 -name "*.tar.gz" -type f -print -quit)
    verify_step "Verifying tarball signature"
    if cosign verify-blob --bundle "${tarball}.bundle" --certificate-identity-regexp "^https://github\.com/${OWNER}/" --certificate-oidc-issuer "https://token.actions.githubusercontent.com" "$tarball" &> /dev/null; then
        verify_ok
    else
        verify_fail "Cosign tarball verification failed"
        return 1
    fi

    verify_step "Verifying checksums signature"
    if cosign verify-blob --bundle "checksums.txt.bundle" --certificate-identity-regexp "^https://github\.com/${OWNER}/" --certificate-oidc-issuer "https://token.actions.githubusercontent.com" "checksums.txt" &> /dev/null; then
        verify_ok
    else
        verify_fail "Cosign checksums.txt verification failed"
        return 1
    fi

    return 0
}

verify_attestations() {
    verify_step "Verifying GitHub attestations"
    local tarball
    tarball=$(find . -maxdepth 1 -name "*.tar.gz" -type f -print -quit)
    if gh attestation verify --repo "$REPO" "$tarball" &> /dev/null; then
        verify_ok
    else
        verify_fail "Attestation verification failed"
        return 1
    fi

    return 0
}

verify_provenance_file() {
    verify_step "Verifying SLSA provenance file"
    local provenance
    provenance=$(find . -maxdepth 1 -name "*.intoto.jsonl" -type f -print -quit 2>/dev/null)
    if [[ -z "$provenance" ]]; then
        verify_fail "Provenance file not found"
        return 1
    fi
    if jq -r '.dsseEnvelope.payload' "$provenance" | base64 -d | jq -e '.subject' &>/dev/null; then
        verify_ok
    else
        verify_fail "Invalid provenance (could not find subject)"
        return 1
    fi

    return 0
}

inspect_sbom() {
    verify_step "Inspecting SBOM"
    if [[ ! -f sbom.cdx.json ]]; then
        verify_fail "SBOM file not found"
        return 1
    fi
    if jq -e '.components | length' sbom.cdx.json &> /dev/null; then
        verify_ok
    else
        verify_fail "Invalid SBOM format"
        return 1
    fi

    return 0
}

run_verification() {
    local exit_code=$EXIT_SUCCESS
    verify_subjects || exit_code=$EXIT_VERIFICATION_FAILED
    verify_tarball_checksum || exit_code=$EXIT_VERIFICATION_FAILED
    verify_checksums_manifest || exit_code=$EXIT_VERIFICATION_FAILED
    verify_signatures || exit_code=$EXIT_VERIFICATION_FAILED

    if [[ "$MODE" == "full" ]]; then
        verify_attestations || exit_code=$EXIT_VERIFICATION_FAILED
        verify_provenance_file || exit_code=$EXIT_VERIFICATION_FAILED
        inspect_sbom || exit_code=$EXIT_VERIFICATION_FAILED
        run_slsa_verifier || exit_code=$EXIT_VERIFICATION_FAILED
        verify_vsa_attestation || exit_code=$EXIT_VERIFICATION_FAILED
    fi

    return $exit_code
}

emit_vsa() {
    local verification_status="$1"

    if [[ -z "$EMIT_VSA_PATH" ]]; then
        return 0
    fi

    local artifact_path
    artifact_path=$(find . -maxdepth 1 -name "*.tar.gz" -type f -print -quit 2>/dev/null)
    if [[ -z "$artifact_path" ]]; then
        echo -e "${RED}Unable to emit VSA: source tarball not available in work dir${NC}" >&2
        return 1
    fi

    if [[ ! -f subjects.sha256 ]]; then
        echo -e "${RED}Unable to emit VSA: subjects.sha256 missing${NC}" >&2
        return 1
    fi

    local artifact_name artifact_digest
    artifact_name=$(basename "$artifact_path")
    artifact_digest=$(head -n1 subjects.sha256 | awk '{print $1}')
    if [[ -z "$artifact_digest" ]]; then
        echo -e "${RED}Unable to emit VSA: could not read digest from subjects.sha256${NC}" >&2
        return 1
    fi

    local time_verified
    if [[ -n "$TIME_VERIFIED_OVERRIDE" ]]; then
        time_verified="$TIME_VERIFIED_OVERRIDE"
    else
        time_verified=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    fi

    local resource_uri="${RESOURCE_URI:-"https://github.com/${REPO}/releases/tag/${TAG}"}"

    local verified_levels_json='[]'
    for level in "${VERIFIED_LEVELS[@]}"; do
        [[ -z "$level" ]] && continue
        verified_levels_json=$(jq --arg lvl "$level" '. + [$lvl]' <<<"$verified_levels_json")
    done

    local version_json="null"
    if ((${#VERIFIER_VERSIONS[@]})); then
        version_json='{}'
        for kv in "${VERIFIER_VERSIONS[@]}"; do
            if [[ "$kv" != *=* ]]; then
                continue
            fi
            local key="${kv%%=*}"
            local value="${kv#*=}"
            version_json=$(jq --arg k "$key" --arg v "$value" '.[$k]=$v' <<<"$version_json")
        done
    fi

    local policy_digest=""
    if [[ -n "$POLICY_FILE" && -f "$POLICY_FILE" ]]; then
        policy_digest=$(sha256_of "$POLICY_FILE")
    fi

    local policy_json="null"
    if [[ -n "$POLICY_URI" ]]; then
        if [[ -n "$policy_digest" ]]; then
            policy_json=$(jq -n --arg uri "$POLICY_URI" --arg digest "$policy_digest" '{uri: $uri, digest: {sha256: $digest}}')
        else
            policy_json=$(jq -n --arg uri "$POLICY_URI" '{uri: $uri}')
        fi
    fi

    local input_attestations='[]'
    if [[ -f subjects.sha256 ]]; then
        input_attestations=$(jq --arg uri "https://github.com/${REPO}/releases/download/${TAG}/subjects.sha256" --arg digest "$(sha256_of subjects.sha256)" '. + [{uri: $uri, digest: {sha256: $digest}}]' <<<"$input_attestations")
    fi
    local provenance_path
    provenance_path=$(find . -maxdepth 1 -name "*.intoto.jsonl" -type f -print -quit 2>/dev/null)
    if [[ -n "$provenance_path" ]]; then
        input_attestations=$(jq --arg uri "https://github.com/${REPO}/releases/download/${TAG}/$(basename "$provenance_path")" --arg digest "$(sha256_of "$provenance_path")" '. + [{uri: $uri, digest: {sha256: $digest}}]' <<<"$input_attestations")
    fi
    if [[ -f sbom.cdx.json ]]; then
        input_attestations=$(jq --arg uri "https://github.com/${REPO}/releases/download/${TAG}/sbom.cdx.json" --arg digest "$(sha256_of sbom.cdx.json)" '. + [{uri: $uri, digest: {sha256: $digest}}]' <<<"$input_attestations")
    fi

    local dependency_levels_json='{}'

    local vsa_json
    vsa_json=$(jq -n \
        --arg name "$artifact_name" \
        --arg digest "$artifact_digest" \
        --arg verifier_id "$VERIFIER_ID" \
        --arg time_verified "$time_verified" \
        --arg resource_uri "$resource_uri" \
        --arg verification_result "$verification_status" \
        --arg slsa_version "$SLSA_VERSION" \
        --argjson verified_levels "$verified_levels_json" \
        --argjson dependency_levels "$dependency_levels_json" \
        --argjson input_attestations "$input_attestations" \
        '{
            "_type": "https://in-toto.io/Statement/v1",
            "subject": [{
                "name": $name,
                "digest": { "sha256": $digest }
            }],
            "predicateType": "https://slsa.dev/verification_summary/v1",
            "predicate": {
                "verifier": { "id": $verifier_id },
                "timeVerified": $time_verified,
                "resourceUri": $resource_uri,
                "verificationResult": $verification_result,
                "verifiedLevels": $verified_levels,
                "dependencyLevels": $dependency_levels,
                "inputAttestations": $input_attestations,
                "slsaVersion": $slsa_version
            }
        }')

    if [[ "$version_json" != "null" ]]; then
        vsa_json=$(jq --argjson version "$version_json" '.predicate.verifier.version = $version' <<<"$vsa_json")
    fi

    if [[ "$policy_json" != "null" ]]; then
        vsa_json=$(jq --argjson policy "$policy_json" '.predicate.policy = $policy' <<<"$vsa_json")
    fi

    mkdir -p "$(dirname "$EMIT_VSA_PATH")"
    printf '%s\n' "$vsa_json" | jq -S '.' > "$EMIT_VSA_PATH"
    echo "Wrote Verification Summary Attestation: $EMIT_VSA_PATH"

    return 0
}

verify_vsa_attestation() {
    local vsa_file="verification-summary.attestation.json"
    local vsa_bundle="${vsa_file}.bundle"

    if [[ ! -f "$vsa_file" ]]; then
        verify_fail "VSA file not found"
        return 1
    fi

    verify_step "Verifying VSA signature"
    if cosign verify-blob \
        --bundle "$vsa_bundle" \
        --certificate-identity-regexp "^https://github\\.com/${OWNER}/" \
        --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
        "$vsa_file" &> /dev/null; then
        verify_ok
    else
        verify_fail "Cosign verification failed for VSA"
        return 1
    fi

    verify_step "Checking VSA predicate fields"
    local verification_result
    verification_result=$(jq -r '.predicate.verificationResult // empty' "$vsa_file")
    if [[ "$verification_result" != "PASSED" ]]; then
        verify_fail "verificationResult expected PASSED, got '${verification_result:-<unset>}'"
        return 1
    fi

    local verified_levels
    verified_levels=$(jq -r '.predicate.verifiedLevels[]?' "$vsa_file")
    if [[ -z "$verified_levels" ]]; then
        verify_fail "verifiedLevels is empty"
        return 1
    fi
    verify_ok

    verify_step "Confirming SLSA level claims"
    if jq -e '.predicate.verifiedLevels[]? | select(. == "SLSA_BUILD_LEVEL_3")' "$vsa_file" >/dev/null; then
        verify_ok
    else
        verify_fail "verifiedLevels does not include SLSA_BUILD_LEVEL_3"
        return 1
    fi

    verify_step "Cross-checking VSA subject digest"
    local vsa_digest subjects_digest
    vsa_digest=$(jq -r '.subject[0].digest.sha256 // empty' "$vsa_file")
    subjects_digest=$(awk 'NR==1 {print $1}' subjects.sha256 2>/dev/null || true)
    if [[ -z "$vsa_digest" ]]; then
        verify_fail "VSA subject digest missing"
        return 1
    fi
    if [[ -z "$subjects_digest" ]]; then
        verify_fail "subjects.sha256 missing digest entry"
        return 1
    fi
    if [[ "$vsa_digest" != "$subjects_digest" ]]; then
        verify_fail "VSA digest ${vsa_digest} does not match subjects ${subjects_digest}"
        return 1
    fi
    verify_ok

    verify_step "Validating VSA resource URI"
    local expected_resource
    expected_resource="https://github.com/${REPO}/releases/tag/${TAG}"
    local resource_uri
    resource_uri=$(jq -r '.predicate.resourceUri // empty' "$vsa_file")
    if [[ "$resource_uri" != "$expected_resource" ]]; then
        verify_fail "resourceUri expected ${expected_resource}, got '${resource_uri:-<unset>}'"
        return 1
    fi
    verify_ok

    return 0
}

# --- Reproducibility Check function for reproduce mode ---
run_repro_check() {
    echo "--- Launching reproducibility check for $REPO @ $TAG in Docker... ---"

    local builder_image="$REPRO_IMAGE_DEFAULT"
    local subjects_tmp build_env_tmp
    subjects_tmp=$(mktemp)
    build_env_tmp=$(mktemp)

    # mktemp creates the files. Here, we remove them so gh can write without --clobber.
    rm -f "$subjects_tmp" "$build_env_tmp"

    # Pull the published subjects + build.env so we can reuse the exact builder image
    # and artifact digest captured during packaging.
    gh release download "$TAG" --repo "$REPO" -p "subjects.sha256" --output "$subjects_tmp" >/dev/null
    gh release download "$TAG" --repo "$REPO" -p "build.env" --output "$build_env_tmp" >/dev/null || true

    local artifact_filename expected_digest builder_from_env
    artifact_filename=$(awk 'NR==1 {print $2}' "$subjects_tmp")
    expected_digest=$(awk 'NR==1 {print $1}' "$subjects_tmp")
    builder_from_env=$(awk -F= '/^SLSA_BUILDER_IMAGE=/ {print $2}' "$build_env_tmp" | tail -n1)

    rm -f "$subjects_tmp" "$build_env_tmp"

    if [[ -z "$artifact_filename" || -z "$expected_digest" ]]; then
        echo -e "${RED}subjects.sha256 missing primary artifact details${NC}" >&2
        return 1
    fi
    # Prefer the builder image recorded by the packaging job (falls back to default).
    if [[ -n "$builder_from_env" && "$builder_from_env" != "unknown" ]]; then
        builder_image="$builder_from_env"
    fi

    if ! docker run --rm -i "$builder_image" /bin/bash -se <<'EOS' "$REPO" "$TAG" "$artifact_filename" "$expected_digest"; then
#!/usr/bin/env bash
set -euo pipefail

REPO="$1"
TAG="$2"
ARTIFACT_NAME="$3"
EXPECTED_DIGEST="$4"

step() { printf "
--- %s ---
" "$1"; }
info() { printf "% -50s" "$1..."; }
ok() { echo " OK"; }
fail() {
    echo " FAIL"
    if [[ -n "${1:-}" ]]; then echo "  Error: ${1}" >&2; fi
    exit 1
}

step "Fetching published artifact"
WORK_DIR="/tmp/slsa-repro"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

SUBJECTS_URL="https://github.com/${REPO}/releases/download/${TAG}/subjects.sha256"
info "Downloading subjects.sha256"
curl -sSLo subjects.sha256 "$SUBJECTS_URL" || fail "Unable to fetch subjects.sha256"
sha_from_subjects=$(awk 'NR==1 {print $1}' subjects.sha256)
artifact_from_subjects=$(awk 'NR==1 {print $2}' subjects.sha256)
if [[ "$artifact_from_subjects" != "$ARTIFACT_NAME" ]]; then
    fail "subjects.sha256 lists '$artifact_from_subjects', expected '$ARTIFACT_NAME'"
fi
if [[ "$sha_from_subjects" != "$EXPECTED_DIGEST" ]]; then
    fail "subjects.sha256 digest mismatch"
fi
ok

info "Downloading ${ARTIFACT_NAME}"
mkdir -p "$(dirname "$ARTIFACT_NAME")"
curl -sSLo "$ARTIFACT_NAME" "https://github.com/${REPO}/releases/download/${TAG}/${ARTIFACT_NAME}" || fail "Unable to download artifact"
ok

info "Validating downloaded digest"
download_digest=$(sha256sum "$ARTIFACT_NAME" | awk '{print $1}')
if [[ "$download_digest" != "$EXPECTED_DIGEST" ]]; then
    fail "Downloaded tarball digest mismatch"
fi
ok

step "Rebuilding artifact"
temp_repo="/tmp/repro-repo"
rm -rf "$temp_repo"
info "Cloning repository"
git clone --depth 1 --branch "$TAG" "https://github.com/${REPO}.git" "$temp_repo" >/dev/null 2>&1 || fail "Failed to clone repository for tag $TAG"
cd "$temp_repo"
ok

info "Running packaging script"
export GITHUB_SHA=$(git rev-parse HEAD)
export GITHUB_REPOSITORY="$REPO"
export GITHUB_REF_NAME="$TAG"
export GITHUB_REF_TYPE="tag"
export GITHUB_RUN_NUMBER=0
export EXTENDED_METADATA=false
export LC_ALL=C LANG=C TZ=UTC
umask 022

set +e
bash scripts/package-source.sh >/tmp/packaging.log 2>&1
status=$?
set -e
if [[ $status -ne 0 ]]; then
    fail "Packaging script failed:
$(cat /tmp/packaging.log)"
fi
ok

info "Calculating rebuilt digest"
rebuilt_path=$(find dist -maxdepth 1 -name '*.tar.gz' -print -quit)
if [[ -z "$rebuilt_path" ]]; then
    fail "Rebuilt tarball not found"
fi
rebuilt_digest=$(sha256sum "$rebuilt_path" | awk '{print $1}')
if [[ "$rebuilt_digest" != "$EXPECTED_DIGEST" ]]; then
    fail "Rebuilt digest mismatch (expected $EXPECTED_DIGEST, got $rebuilt_digest)"
fi
ok

echo "
SUCCESS: Artifact is reproducible."
EOS
        echo -e "${RED}Docker reproducibility check failed${NC}" >&2
        return 1
    fi

    echo "--- Reproducibility check complete. ---"

    return 0
}

# Main function
main() {
    parse_args "$@"
    check_tools

    if [[ "$MODE" == "reproduce" ]]; then
        run_repro_check
        exit $?
    fi

    echo -e "\n${YELLOW}Verifying release: ${REPO} @ ${TAG} (${MODE} mode)${NC}\n"

    WORK_DIR="/tmp/verify-${REPO_NAME}-${TAG}-$$"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    if ! download_artifacts; then
        echo -e "\n${RED}Verification failed: Could not download artifacts${NC}\n"
        exit $EXIT_DOWNLOAD_FAILED
    fi

    local verification_result=$EXIT_SUCCESS

    if [[ "$MODE" == "vsa" ]]; then
        verify_vsa_attestation || verification_result=$EXIT_VERIFICATION_FAILED
        echo ""
        if [[ $verification_result -eq $EXIT_SUCCESS ]]; then
            echo -e "${GREEN}✓ VSA verification passed${NC}"
            echo -e "Verification Summary Attestation for ${TAG} is valid\n"
        else
            echo -e "${RED}✗ VSA verification failed${NC}"
            echo -e "Please review the errors above\n"
        fi
    else
        run_verification || verification_result=$?

        echo ""
        if [[ $verification_result -eq $EXIT_SUCCESS ]]; then
            echo -e "${GREEN}✓ All verifications passed${NC}"
            echo -e "Release ${TAG} from ${REPO} is authentic and verified\n"
        else
            echo -e "${RED}✗ Some verifications failed${NC}"
            echo -e "Please review the errors above\n"
        fi

        local vsa_status="FAILED"
        if [[ $verification_result -eq $EXIT_SUCCESS ]]; then
            vsa_status="PASSED"
        fi

        if [[ -n "$EMIT_VSA_PATH" ]]; then
            if ! emit_vsa "$vsa_status"; then
                echo -e "${RED}Failed to emit Verification Summary Attestation${NC}" >&2
                exit $EXIT_VERIFICATION_FAILED
            fi
        fi
    fi

    echo "Artifacts saved in: $WORK_DIR"
    echo "To clean up: rm -rf $WORK_DIR"
    echo ""

    exit $verification_result
}

main "$@"
