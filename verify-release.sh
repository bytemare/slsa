#!/usr/bin/env bash
#
# SPDX-License-Identifier: MIT
#
# Copyright (C) 2026 Daniel Bourdrez. All Rights Reserved.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree or at
# https://spdx.org/licenses/MIT.html
#

###############################################################################
# verify-release.sh - SLSA Level 3 Release Verification
###############################################################################
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
# Exit Codes:
#   0 - Success
#   1 - Missing required tool
#   2 - Missing or invalid argument
#   3 - Verification failed
#   4 - Download failed
#
###############################################################################
# POLICY SPECIFICATION
###############################################################################
#
# This script serves as both the verification implementation AND the policy
# specification. When generating Verification Summary Attestations (VSAs), the
# policy.uri field points to this script and includes its SHA-256 digest.
#
# SLSA Build Level 3 Requirements (per SLSA v1.2):
#
# 1. CHECKSUM INTEGRITY
#    - Verify SHA-256 checksums of source tarball against subjects.sha256
#    - Verify SHA-256 checksums of checksums.txt against subjects.sha256
#    - All checksums must match to ensure artifact integrity
#
# 2. SIGNATURE VERIFICATION (Sigstore/Cosign)
#    - Verify tarball signature bundle (keyless signing via GitHub OIDC)
#    - Verify checksums.txt signature bundle
#    - Require valid certificate chain from GitHub Actions OIDC issuer
#    - Require certificate identity matches repository owner namespace
#
# 3. ATTESTATION VERIFICATION (GitHub Attestations API)
#    - Verify SLSA provenance attestation via GitHub CLI
#    - Verify SBOM attestation
#    - Require attestations signed by specified workflow repository
#
# 4. PROVENANCE VALIDATION (slsa-framework/slsa-verifier)
#    - Verify provenance structure (in-toto DSSE envelope)
#    - Verify provenance subject matches artifact digest
#    - Verify source URI matches repository
#    - Verify source tag matches release tag
#
# 5. SBOM INSPECTION
#    - Verify SBOM file exists and is valid CycloneDX JSON
#    - Verify SBOM contains component list
#
# 6. VSA VERIFICATION (when --mode vsa or VSA files present)
#    - Verify VSA signature bundle via Cosign
#    - Verify verificationResult == "PASSED"
#    - Verify verifiedLevels contains "SLSA_BUILD_LEVEL_3"
#    - Verify VSA subject digest matches subjects.sha256
#    - Verify VSA resourceUri matches expected release URI
#
# 7. REPRODUCIBILITY (--mode reproduce only)
#    - Rebuild source tarball in hermetic container environment
#    - Verify rebuilt artifact digest matches published artifact
#    - Use exact builder image from build.env (if available)
#
# Policy Enforcement: ALL checks in the selected mode must pass. Any single
# failure results in exit code 3 (EXIT_VERIFICATION_FAILED) and prevents VSA
# emission with verificationResult="PASSED".
#
###############################################################################

# ===========================================================================
# Script Metadata
# ===========================================================================
readonly SCRIPT_VERSION="0.1.0"
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

# ===========================================================================
# Shell Options
# ===========================================================================
set -euo pipefail

# ===========================================================================
# Constants
# ===========================================================================

# Default container image used for rebuild verification (matches CI builder digest).
# The reproduce mode prefers the value recorded in build.env but falls back to this.
readonly REPRO_IMAGE_DEFAULT="golang:1.25-bookworm@sha256:51b6b12427dc03451c24f7fc996c43a20e8a8e56f0849dd0db6ff6e9225cc892"

# ===========================================================================
# Color Support (respects NO_COLOR)
# ===========================================================================
if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
  readonly GREEN=$'\033[0;32m'
  readonly RED=$'\033[0;31m'
  readonly YELLOW=$'\033[1;33m'
  readonly BLUE=$'\033[0;34m'
  readonly NC=$'\033[0m'
else
  readonly GREEN=''
  readonly RED=''
  readonly YELLOW=''
  readonly BLUE=''
  readonly NC=''
fi

# ===========================================================================
# Debug Logging
# ===========================================================================
# Default to DEBUG=true in CI for complete logs
if [[ "${GITHUB_ACTIONS:-false}" == "true" && -z "${DEBUG:-}" ]]; then
    DEBUG=true
fi

# Track current GitHub Actions group
_GHA_GROUP_OPEN=false

debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        # In GitHub Actions, use collapsible groups for section headers
        if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
            # Detect section headers (lines starting with ====== or major milestones)
            if [[ "$*" =~ ^=+ ]] || [[ "$*" =~ ^(Starting|Entering|Download|Verification|Complete) ]]; then
                # Close previous group if open
                if [[ "$_GHA_GROUP_OPEN" == "true" ]]; then
                    echo "::endgroup::" >&2
                fi
                # Start new group
                echo "::group::🔍 DEBUG: $*" >&2
                _GHA_GROUP_OPEN=true
            else
                echo "[DEBUG] $*" >&2
            fi
        else
            echo "[DEBUG] $*" >&2
        fi
    fi
}

# Close debug group at exit in GitHub Actions
cleanup_debug_groups() {
    if [[ "${GITHUB_ACTIONS:-false}" == "true" && "$_GHA_GROUP_OPEN" == "true" ]]; then
        echo "::endgroup::" >&2
    fi
}

# ===========================================================================
# Exit Codes
# ===========================================================================
readonly EXIT_SUCCESS=0
readonly EXIT_MISSING_TOOL=1
readonly EXIT_MISSING_ARG=2
readonly EXIT_VERIFICATION_FAILED=3
readonly EXIT_DOWNLOAD_FAILED=4

# ===========================================================================
# Cleanup Management
# ===========================================================================
# shellcheck disable=SC2329  # Function invoked via trap
cleanup() {
  cleanup_debug_groups
  if [[ -n "${WORK_DIR:-}" ]] && [[ -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ===========================================================================
# Global Variables
# ===========================================================================
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
SLSA_VERSION="1.2"
TIME_VERIFIED_OVERRIDE=""
SIGNER_REPO=""
SIGNER_WORKFLOW=""
SIGNER_REPO_DEFAULT="bytemare/slsa"

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

verify_skip() {
    local reason="${1:-""}"
    echo -e " ${YELLOW}!${NC}"
    if [[ -n "$reason" ]]; then
        echo -e "  ${YELLOW}Skip: $reason${NC}" >&2
    fi

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
${BLUE}${SCRIPT_NAME}${NC} v${SCRIPT_VERSION}

Verify SLSA Level 3 compliant release artifacts.

${YELLOW}Usage:${NC}
  $0 --repo OWNER/REPO --tag TAG [--mode MODE]

${YELLOW}Required Arguments:${NC}
  --repo OWNER/REPO    Repository in format owner/repo (e.g., bytemare/workflows)
  --tag TAG            Release tag to verify (e.g., 0.0.4)

${YELLOW}Optional Arguments:${NC}
  --mode MODE          Verification mode (default: quick)
                       - quick: Basic checksum and signature verification.
                       - full: Complete verification of all release artifacts.
                       - reproduce: Full, containerized reproducibility check.
                       - vsa: Verify verification-summary attestation only.
  --emit-vsa PATH      Emit a v1.2 Verification Summary Attestation JSON to PATH
  --verifier-id URI    Identifier for the verifying entity (required when emitting a VSA)
  --verifier-version K=V
                       Additional version metadata for the verifier (repeatable)
  --policy-uri URI     URI of the verification policy being applied (optional)
  --policy-file PATH   File used to compute the policy digest (defaults to this script)
  --verified-level L   Append a verified SLSA level (repeatable, default: SLSA_BUILD_LEVEL_3)
  --signer-repo REPO   Reusable workflow repo that signed attestations (owner/repo)
                       (default: bytemare/slsa when signer-workflow is unset)
  --signer-workflow W  Reusable workflow file that signed attestations (owner/repo/path)
  --resource-uri URI   Resource URI describing the artifact under verification
  --time-verified TS   Override the VSA timeVerified field (RFC3339, defaults to current time)
  --slsa-version VER   Predicated SLSA version for the VSA (default: 1.2)
  -V, --version        Show version information
  --help               Show this help message

Examples:
  $0 --repo bytemare/workflows --tag 0.0.4
  $0 --repo bytemare/workflows --tag 0.0.4 --mode full
  DEBUG=true $0 --repo bytemare/workflows --tag 0.0.4  # Enable debug logging (auto in CI)
  $0 --repo bytemare/workflows --tag 0.0.4 --mode reproduce
  $0 --repo bytemare/workflows --tag 0.0.4 --mode vsa
  $0 --repo bytemare/workflows --tag 0.0.4 --mode full --emit-vsa my.vsa.json --verifier-id https://example.com/verifier
  $0 --repo bytemare/workflows --tag 0.0.4 --mode full --signer-repo bytemare/slsa

Note: VSA emission happens after all checks succeed to preserve a verifier/producer separation. A consumer or CI policy can trust the summary because it was generated post-release by the verification workflow, not during packaging.

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
            --signer-repo)
                SIGNER_REPO="$2"
                shift 2
                ;; 
            --signer-workflow)
                SIGNER_WORKFLOW="$2"
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
            -V|--version)
                echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"
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

    if [[ -z "$SIGNER_REPO" && -z "$SIGNER_WORKFLOW" ]]; then
        SIGNER_REPO="$SIGNER_REPO_DEFAULT"
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
    sha256sum -- "$file" | awk '{print $1}'
}

tokenless_actions() {
    [[ "${GITHUB_ACTIONS:-}" == "true" && -z "${GH_TOKEN:-}" ]]
}

# Check for required tools
check_tools() {
    local missing_tools=()
    local required_tools=()

    if [[ "$MODE" == "reproduce" ]]; then
        required_tools=("docker" "curl")
    else
        required_tools=("jq" "cosign" "curl")
        if [[ "$MODE" == "full" ]]; then
            required_tools+=("slsa-verifier")
        fi
    fi

    if ! tokenless_actions; then
        required_tools+=("gh")
    fi

    if ! command -v sha256sum &> /dev/null; then
        missing_tools+=("sha256sum")
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

download_release_file() {
    local name="$1"
    local output="$2"

    if ! tokenless_actions; then
        debug "Attempting gh release download: TAG=${TAG} REPO=${REPO} PATTERN=${name}"
        if gh release download "$TAG" --repo "$REPO" -p "$name" --output "$output" 2>&1 | tee /tmp/gh-download-error.log >&2; then
            return 0
        else
            echo "[ERROR] gh release download failed. See output above." >&2
        fi
    fi

    local base_url="${GITHUB_SERVER_URL:-https://github.com}"
    local url="${base_url}/${REPO}/releases/download/${TAG}/${name}"
    debug "Attempting curl download: ${url}"
    if curl -fsSL -o "$output" "$url" 2>&1; then
        return 0
    else
        local http_code
        http_code=$(curl -sI -o /dev/null -w "%{http_code}" "$url" 2>&1)
        echo "[ERROR] curl download failed: ${url}" >&2
        echo "[ERROR] HTTP response code: ${http_code}" >&2
    fi

    return 1
}

download_release_pattern() {
    local pattern="$1"
    local required="${2:-false}"
    local downloaded=false

    if ! tokenless_actions; then
        debug "Attempting gh release download: TAG=${TAG} REPO=${REPO} PATTERN=${pattern}"
        if gh release download "$TAG" --repo "$REPO" -p "$pattern" 2>&1 | tee /tmp/gh-pattern-error.log >&2; then
            downloaded=true
        fi
    else
        local api_url="${GITHUB_API_URL:-https://api.github.com}/repos/${REPO}/releases/tags/${TAG}"
        debug "Fetching release assets from GitHub API: ${api_url}"
        local assets
        if ! assets=$(curl -fsSL -H "Accept: application/vnd.github+json" "$api_url" 2>&1); then
            echo "[ERROR] Failed to fetch release metadata from GitHub API" >&2
            echo "[ERROR] API URL: ${api_url}" >&2
            local http_code
            http_code=$(curl -sI -o /dev/null -w "%{http_code}" -H "Accept: application/vnd.github+json" "$api_url" 2>&1)
            echo "[ERROR] HTTP response code: ${http_code}" >&2
            if [[ "$required" == "true" ]]; then
                return 1
            fi
            return 0
        fi

        local assets_list
        if ! assets_list=$(jq -r '.assets? // [] | .[] | "\(.name)\t\(.browser_download_url)"' <<< "$assets"); then
            if [[ "$required" == "true" ]]; then
                return 1
            fi
            return 0
        fi

        while IFS=$'\t' read -r name url; do
            if [[ "$name" == "$pattern" ]]; then
                debug "Downloading asset: ${name} from ${url}"
                if curl -fsSL -L -o "$name" "$url" 2>&1; then
                    downloaded=true
                else
                    local http_code
                    http_code=$(curl -sI -o /dev/null -w "%{http_code}" -L "$url" 2>&1)
                    echo "[ERROR] Failed to download ${name} from ${url}" >&2
                    echo "[ERROR] HTTP response code: ${http_code}" >&2
                    continue
                fi
            fi
        done <<< "$assets_list"
    fi

    # Handle download result
    if [[ "$downloaded" == "false" ]]; then
        if [[ "$required" == "true" ]]; then
            echo "[ERROR] Required asset matching '${pattern}' not found in release" >&2
            return 1
        else
            echo "[WARN] Optional asset matching '${pattern}' not found" >&2
        fi
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

    debug "====== Starting artifact download ======"
    debug "  MODE=${MODE}"
    debug "  REPO=${REPO}"
    debug "  TAG=${TAG}"
    echo "" >&2

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

    debug "Artifact patterns to download: ${patterns[*]}"
    
    verify_step "Downloading release artifacts"

    # Download required files for all modes
    if [[ "$MODE" == "vsa" ]]; then
        download_release_pattern "verification-summary.attestation.json" true
        download_release_pattern "verification-summary.attestation.json.bundle" true
        download_release_pattern "subjects.sha256" true
    else
        download_release_pattern "*.tar.gz" true
        download_release_pattern "*.bundle" true
        download_release_pattern "subjects.sha256" true
        download_release_pattern "checksums.txt" true
        
        # Download optional files for full mode
        if [[ "$MODE" == "full" ]]; then
            download_release_pattern "*.intoto.jsonl" false
            download_release_pattern "sbom.cdx.json" false
            download_release_pattern "verification.json" false
            download_release_pattern "manifest.files.sha256" false
            download_release_pattern "verification-summary.attestation.json" false
            download_release_pattern "verification-summary.attestation.json.bundle" false
        fi
    fi

    echo "" >&2
    debug "====== Download phase complete ======"
    debug "Files in work directory:"
    ls -lah . >&2
    echo "" >&2

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
    computed_hash=$(sha256sum -- "$tarball" | awk '{print $1}')
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
    computed_hash=$(sha256sum -- checksums.txt | awk '{print $1}')
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
    if tokenless_actions; then
        verify_skip "GH_TOKEN not available in GitHub Actions (set a token to verify attestations)"
        return 0
    fi
    local tarball
    tarball=$(find . -maxdepth 1 -name "*.tar.gz" -type f -print -quit)
    local -a args
    args=(--repo "$REPO")
    if [[ -n "$SIGNER_REPO" ]]; then
        args+=(--signer-repo "$SIGNER_REPO")
    fi
    if [[ -n "$SIGNER_WORKFLOW" ]]; then
        args+=(--signer-workflow "$SIGNER_WORKFLOW")
    fi
    local output
    if output=$(gh attestation verify "${args[@]}" "$tarball" 2>&1); then
        verify_ok
    else
        verify_fail "Attestation verification failed"
        echo "$output" >&2
        
        # Add helpful troubleshooting
        echo "" >&2
        echo "${YELLOW}Troubleshooting attestation verification:${NC}" >&2
        echo "1. Verify the release has .intoto.jsonl files" >&2
        echo "2. If verifying a fork's release, specify: --signer-repo <fork-owner>/slsa" >&2
        echo "3. Check that the release was created by GitHub Actions with SLSA provenance" >&2
        echo "" >&2
        echo "Details:" >&2
        echo "  Expected attestations signed by: ${SIGNER_REPO:-${SIGNER_REPO_DEFAULT}}" >&2
        echo "  Verifying release: ${REPO}@${TAG}" >&2
        echo "" >&2
        
        if [[ -n "$SIGNER_REPO" && "$SIGNER_REPO" == "$SIGNER_REPO_DEFAULT" ]]; then
            verify_fail "This run assumed the signer repo is '${SIGNER_REPO_DEFAULT}'. If the attestation was signed by another workflow repo (for example a fork or a repo that reused that workflow), re-run with --signer-repo <owner>/<repo> and optionally --signer-workflow <owner>/<repo>/.github/workflows/slsa.yaml@<ref>." >&2
        elif [[ -n "$SIGNER_REPO" ]]; then
            verify_fail "--signer-repo tells the verifier which workflow repo signed the attestation, and it seems the provided value is not correct. Provide the correct <owner>/<repo> GitHub workflow that signed the attestation. You can try to re-run with --signer-repo ${SIGNER_REPO_DEFAULT} (or your fork) and optionally --signer-workflow <owner>/<repo>/.github/workflows/slsa.yaml@<ref>." >&2
        else
            verify_fail "Provide --signer-repo ${SIGNER_REPO_DEFAULT} (or your fork) and optionally --signer-workflow <owner>/<repo>/.github/workflows/slsa.yaml@<ref>." >&2
        fi
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
        if [[ -f verification-summary.attestation.json || -f verification-summary.attestation.json.bundle ]]; then
            verify_vsa_attestation || exit_code=$EXIT_VERIFICATION_FAILED
        fi
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
    debug "Downloading subjects.sha256 for reproduce mode"
    if ! download_release_file "subjects.sha256" "$subjects_tmp"; then
        echo -e "${RED}Failed to download subjects.sha256${NC}" >&2
        echo "[ERROR] subjects.sha256 download failed (see debug output above)" >&2
        return 1
    fi
    debug "Downloading build.env for reproduce mode"
    download_release_file "build.env" "$build_env_tmp" || debug "build.env not found (optional)"

    local artifact_filename expected_digest builder_from_env script_sha_expected
    artifact_filename=$(awk 'NR==1 {print $2}' "$subjects_tmp")
    expected_digest=$(awk 'NR==1 {print $1}' "$subjects_tmp")
    builder_from_env=$(awk -F= '/^SLSA_BUILDER_IMAGE=/ {print $2}' "$build_env_tmp" | tail -n1)
    script_sha_expected=$(awk -F= '/^PACKAGING_SCRIPT_SHA256=/ {print $2}' "$build_env_tmp" | tail -n1)

    rm -f "$subjects_tmp" "$build_env_tmp"

    if [[ -z "$artifact_filename" || -z "$expected_digest" ]]; then
        echo -e "${RED}subjects.sha256 missing primary artifact details${NC}" >&2
        return 1
    fi
    # Prefer the builder image recorded by the packaging job (falls back to default).
    if [[ -n "$builder_from_env" && "$builder_from_env" != "unknown" ]]; then
        builder_image="$builder_from_env"
    fi

    if ! docker run --rm -i "$builder_image" /bin/bash -se <<'EOS' "$REPO" "$TAG" "$artifact_filename" "$expected_digest" "$script_sha_expected"; then
#!/usr/bin/env bash
set -euo pipefail

REPO="$1"
TAG="$2"
ARTIFACT_NAME="$3"
EXPECTED_DIGEST="$4"
EXPECTED_SCRIPT_SHA="${5:-}"

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
WORK_DIR=$(mktemp -d)
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
artifact_url="https://github.com/${REPO}/releases/download/${TAG}/${ARTIFACT_NAME}"
debug "Downloading artifact from: ${artifact_url}"
if ! curl -sSL -o "$ARTIFACT_NAME" "${artifact_url}" 2>&1; then
    http_code=$(curl -sI -o /dev/null -w "%{http_code}" "${artifact_url}" 2>&1)
    echo "[ERROR] Failed to download artifact from: ${artifact_url}" >&2
    echo "[ERROR] HTTP response code: ${http_code}" >&2
    fail "Unable to download artifact"
fi
ok

info "Validating downloaded digest"
download_digest=$(sha256sum "$ARTIFACT_NAME" | awk '{print $1}')
if [[ "$download_digest" != "$EXPECTED_DIGEST" ]]; then
    fail "Downloaded tarball digest mismatch"
fi
ok

step "Rebuilding artifact"
temp_repo=$(mktemp -d)
info "Cloning repository"
git clone --depth 1 --branch "$TAG" "https://github.com/${REPO}.git" "$temp_repo" >/dev/null 2>&1 || fail "Failed to clone repository for tag $TAG"
cd "$temp_repo"
ok

info "Running packaging script"
export GITHUB_SHA="$(git rev-parse HEAD)"
export GITHUB_REPOSITORY="$REPO"
export GITHUB_REF_NAME="$TAG"
export GITHUB_REF_TYPE="tag"
export GITHUB_RUN_NUMBER=0
export EXTENDED_METADATA=false
export LC_ALL=C LANG=C TZ=UTC
umask 022

set +e
PACKAGING_SCRIPT=""
SCRIPT_URL="https://github.com/${REPO}/releases/download/${TAG}/package-source.sh"
debug "Attempting to download packaging script from: ${SCRIPT_URL}"
if curl -sSL -o package-source.sh "$SCRIPT_URL" 2>&1; then
    chmod +x package-source.sh
    PACKAGING_SCRIPT="./package-source.sh"
elif [[ -f scripts/package-source.sh ]]; then
    debug "Using local packaging script: scripts/package-source.sh"
    PACKAGING_SCRIPT="scripts/package-source.sh"
else
    http_code=$(curl -sI -o /dev/null -w "%{http_code}" "${SCRIPT_URL}" 2>&1)
    echo "[ERROR] Packaging script not found" >&2
    echo "[ERROR] Tried: ${SCRIPT_URL}" >&2
    echo "[ERROR] HTTP response code: ${http_code}" >&2
    echo "[ERROR] Also checked: scripts/package-source.sh (not found)" >&2
    fail "Packaging script not found (expected release asset package-source.sh)"
fi
# Mandatory integrity check to prevent arbitrary code execution
if [[ -z "$EXPECTED_SCRIPT_SHA" || "$EXPECTED_SCRIPT_SHA" == "unknown" ]]; then
    fail "Cannot verify packaging script integrity - SHA missing from build.env. This prevents arbitrary code execution."
fi

script_digest=$(sha256sum "$PACKAGING_SCRIPT" | awk '{print $1}')
if [[ "$script_digest" != "$EXPECTED_SCRIPT_SHA" ]]; then
    fail "Packaging script digest mismatch (expected $EXPECTED_SCRIPT_SHA, got $script_digest)"
fi
echo "  ✓ Packaging script integrity verified (SHA: ${script_digest:0:16}...)" >&2

packaging_log=$(mktemp)
bash "$PACKAGING_SCRIPT" >"$packaging_log" 2>&1
status=$?
set -e
if [[ $status -ne 0 ]]; then
    fail "Packaging script failed:
$(cat "$packaging_log")"
fi
rm -f "$packaging_log"
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
    debug "====== verify-release.sh starting ======"
    debug "Script version: ${SCRIPT_VERSION}"
    debug "Arguments: $*"
    echo "" >&2
    
    parse_args "$@"
    check_tools

    if [[ "$MODE" == "reproduce" ]]; then
        debug "====== Entering reproduce mode ======"
        debug "  REPO=${REPO}"
        debug "  TAG=${TAG}"
        echo "" >&2
        run_repro_check
        exit $?
    fi

    echo -e "\n${YELLOW}Verifying release: ${REPO} @ ${TAG} (${MODE} mode)${NC}\n"
    debug "Script execution context:"
    debug "  REPO=${REPO}"
    debug "  TAG=${TAG}"
    debug "  MODE=${MODE}"
    debug "  WORK_DIR will be: $(mktemp -u)"
    debug "  GITHUB_ACTIONS=${GITHUB_ACTIONS:-false}"
    debug "  GH_TOKEN set: ${GH_TOKEN:+yes}"
    echo "" >&2

    WORK_DIR=$(mktemp -d)
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
