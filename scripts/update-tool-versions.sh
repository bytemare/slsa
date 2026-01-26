#!/usr/bin/env bash
#
# SPDX-License-Identifier: MIT
#
# Copyright (C) 2026 Daniel Bourdrez. All Rights Reserved.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree or at
# https://spdx.org/licenses/MIT.html

###############################################################################
# update-tool-versions.sh - Update tool versions and SHA256 pins
###############################################################################
#
# DESCRIPTION:
#   Updates tool versions and SHA256 pins in .github/tool-versions.json.
#   Downloads pinned tool binaries, computes their SHA256 hashes, and updates
#   the central configuration file. This approach provides:
#   - Supply chain security through hash verification
#   - Single source of truth for all tool versions
#   - Automated updates via Renovate + hash refresh workflow
#
# USAGE:
#   ./update-tool-versions.sh [OPTIONS]
#
# OPTIONS:
#   -h, --help     Show this help message and exit
#   -V, --version  Show version information and exit
#
# ENVIRONMENT:
#   COSIGN_VERSION         Override cosign version (default: from config)
#   GH_VERSION             Override gh version (default: from config)
#   JQ_VERSION             Override jq version (default: from config)
#   SLSA_VERIFIER_VERSION  Override slsa-verifier version (default: from config)
#   GITHUB_TOKEN           Authentication for GitHub API (preferred)
#   GH_TOKEN               Alternative auth token
#
# EXIT CODES:
#   0 - Success
#   1 - General error (missing dependency, invalid input)
#   2 - Download error
#   3 - Configuration error
#
# REQUIREMENTS:
#   curl, jq, sha256sum
#
###############################################################################

# ===========================================================================
# Script Metadata
# ===========================================================================
readonly SCRIPT_VERSION="1.0.0"
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

# ===========================================================================
# Exit Codes
# ===========================================================================
readonly EXIT_SUCCESS=0
readonly EXIT_GENERAL_ERROR=1
readonly EXIT_DOWNLOAD_ERROR=2
readonly EXIT_CONFIG_ERROR=3

# ===========================================================================
# Shell Options
# ===========================================================================
set -euo pipefail

# ===========================================================================
# Color Support (respects NO_COLOR)
# ===========================================================================
if [[ -z "${NO_COLOR:-}" ]] && [[ -t 2 ]]; then
  readonly RED=$'\033[0;31m'
  readonly GREEN=$'\033[0;32m'
  readonly YELLOW=$'\033[0;33m'
  readonly BLUE=$'\033[0;34m'
  readonly RESET=$'\033[0m'
else
  readonly RED=''
  readonly GREEN=''
  readonly YELLOW=''
  readonly BLUE=''
  readonly RESET=''
fi

# ===========================================================================
# Cleanup Management
# ===========================================================================
CLEANUP_DIR=""

cleanup() {
  if [[ -n "$CLEANUP_DIR" ]] && [[ -d "$CLEANUP_DIR" ]]; then
    rm -rf "$CLEANUP_DIR"
  fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ===========================================================================
# Helper Functions
# ===========================================================================

# Print error and exit
# Usage: fail <exit_code> <message>
fail() {
  local code="${1:-$EXIT_GENERAL_ERROR}"
  shift
  echo "${RED}Error:${RESET} $*" >&2
  exit "$code"
}

# Print informational message
# Usage: log <message>
log() {
  echo "${GREEN}[INFO]${RESET} $*"
}

# Print warning message
# Usage: warn <message>
warn() {
  echo "${YELLOW}[WARN]${RESET} $*" >&2
}

# Check for required command
# Usage: need <command>
need() {
  command -v "$1" >/dev/null 2>&1 || fail "$EXIT_GENERAL_ERROR" "Missing required tool: $1"
}

# Compute SHA256 hash of a file
# Usage: sha256_of <file>
sha256_of() {
  sha256sum "$1" | awk '{print $1}'
}

# Show help message
show_help() {
  cat << EOF
${BLUE}${SCRIPT_NAME}${RESET} v${SCRIPT_VERSION}

Update tool versions and SHA256 pins in .github/tool-versions.json.

${YELLOW}USAGE:${RESET}
    ${SCRIPT_NAME} [OPTIONS]

${YELLOW}OPTIONS:${RESET}
    -h, --help     Show this help message
    -V, --version  Show version information

${YELLOW}ENVIRONMENT:${RESET}
    COSIGN_VERSION         Override cosign version
    GH_VERSION             Override gh version
    JQ_VERSION             Override jq version
    SLSA_VERIFIER_VERSION  Override slsa-verifier version
    GITHUB_TOKEN           Authentication for GitHub API

${YELLOW}EXIT CODES:${RESET}
    0 - Success
    1 - General error
    2 - Download error
    3 - Configuration error

EOF
}

# ===========================================================================
# Argument Parsing
# ===========================================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help
      exit "$EXIT_SUCCESS"
      ;;
    -V|--version)
      echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"
      exit "$EXIT_SUCCESS"
      ;;
    *)
      fail "$EXIT_GENERAL_ERROR" "Unknown option: $1. Use --help for usage."
      ;;
  esac
done

# ===========================================================================
# Environment Setup
# ===========================================================================
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
readonly CONFIG_FILE="${ROOT_DIR}/.github/tool-versions.json"

# Verify config file exists
[[ -f "$CONFIG_FILE" ]] || fail "$EXIT_CONFIG_ERROR" "Configuration file not found: $CONFIG_FILE"

# ===========================================================================
# Dependency Checks
# ===========================================================================
need curl
need jq
need sha256sum

# ===========================================================================
# API Functions
# ===========================================================================

# Fetch latest release tag from GitHub
# Usage: latest_tag <owner/repo>
latest_tag() {
  local repo="$1"
  local url="https://api.github.com/repos/${repo}/releases/latest"
  local auth_header=""
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    auth_header="-H Authorization: Bearer ${GITHUB_TOKEN}"
  elif [[ -n "${GH_TOKEN:-}" ]]; then
    auth_header="-H Authorization: Bearer ${GH_TOKEN}"
  fi
  # shellcheck disable=SC2086
  curl -sSfL --retry 3 --retry-delay 2 --retry-all-errors \
    $auth_header -H "Accept: application/vnd.github+json" "$url" | jq -r '.tag_name'
}

# Read version from config file
# Usage: read_version <tool_name>
read_version() {
  local tool="$1"
  jq -r ".tools[\"${tool}\"].version // empty" "$CONFIG_FILE"
}

# ===========================================================================
# Version Resolution
# ===========================================================================
log "Reading versions from config..."

# Read current versions from config or use env overrides
COSIGN_VERSION="${COSIGN_VERSION:-$(read_version cosign)}"
GH_VERSION="${GH_VERSION:-$(read_version gh)}"
JQ_VERSION="${JQ_VERSION:-$(read_version jq)}"
SLSA_VERIFIER_VERSION="${SLSA_VERIFIER_VERSION:-$(read_version slsa-verifier)}"

# Handle "latest" -> fetch actual latest tag
if [[ "$COSIGN_VERSION" == "latest" ]]; then
  log "Fetching latest cosign version..."
  COSIGN_VERSION="$(latest_tag sigstore/cosign)"
fi
if [[ "$GH_VERSION" == "latest" ]]; then
  log "Fetching latest gh version..."
  GH_VERSION="$(latest_tag cli/cli)"
fi
if [[ "$JQ_VERSION" == "latest" ]]; then
  log "Fetching latest jq version..."
  JQ_VERSION="$(latest_tag jqlang/jq)"
fi
if [[ "$SLSA_VERIFIER_VERSION" == "latest" ]]; then
  log "Fetching latest slsa-verifier version..."
  SLSA_VERIFIER_VERSION="$(latest_tag slsa-framework/slsa-verifier)"
fi

# ===========================================================================
# Download Tools
# ===========================================================================
CLEANUP_DIR="$(mktemp -d)"
readonly tmpdir="$CLEANUP_DIR"

log "Downloading cosign ${COSIGN_VERSION}..."
if ! curl -sSfL --retry 3 --retry-delay 2 --retry-all-errors \
  --proto '=https' --proto-redir '=https' --max-redirs 1 \
  -o "${tmpdir}/cosign" \
  "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64"; then
  fail "$EXIT_DOWNLOAD_ERROR" "Failed to download cosign ${COSIGN_VERSION}"
fi
COSIGN_SHA256="$(sha256_of "${tmpdir}/cosign")"
readonly COSIGN_SHA256

log "Downloading gh ${GH_VERSION}..."
if ! curl -sSfL --retry 3 --retry-delay 2 --retry-all-errors \
  --proto '=https' --proto-redir '=https' --max-redirs 1 \
  -o "${tmpdir}/gh.tgz" \
  "https://github.com/cli/cli/releases/download/${GH_VERSION}/gh_${GH_VERSION#v}_linux_amd64.tar.gz"; then
  fail "$EXIT_DOWNLOAD_ERROR" "Failed to download gh ${GH_VERSION}"
fi
GH_SHA256="$(sha256_of "${tmpdir}/gh.tgz")"
readonly GH_SHA256

log "Downloading jq ${JQ_VERSION}..."
if ! curl -sSfL --retry 3 --retry-delay 2 --retry-all-errors \
  --proto '=https' --proto-redir '=https' --max-redirs 1 \
  -o "${tmpdir}/jq" \
  "https://github.com/jqlang/jq/releases/download/${JQ_VERSION}/jq-linux-amd64"; then
  fail "$EXIT_DOWNLOAD_ERROR" "Failed to download jq ${JQ_VERSION}"
fi
JQ_SHA256="$(sha256_of "${tmpdir}/jq")"
readonly JQ_SHA256

# ===========================================================================
# Update Configuration
# ===========================================================================
log "Updating ${CONFIG_FILE}..."
if ! jq --arg cosign_ver "$COSIGN_VERSION" \
   --arg cosign_sha "$COSIGN_SHA256" \
   --arg gh_ver "$GH_VERSION" \
   --arg gh_sha "$GH_SHA256" \
   --arg jq_ver "$JQ_VERSION" \
   --arg jq_sha "$JQ_SHA256" \
   --arg slsa_ver "$SLSA_VERIFIER_VERSION" \
   '.tools.cosign.version = $cosign_ver |
    .tools.cosign.sha256 = $cosign_sha |
    .tools.gh.version = $gh_ver |
    .tools.gh.sha256 = $gh_sha |
    .tools.jq.version = $jq_ver |
    .tools.jq.sha256 = $jq_sha |
    .tools["slsa-verifier"].version = $slsa_ver' \
   "$CONFIG_FILE" > "${tmpdir}/tool-versions.json"; then
  fail "$EXIT_CONFIG_ERROR" "Failed to update configuration with jq"
fi

mv "${tmpdir}/tool-versions.json" "$CONFIG_FILE"

# ===========================================================================
# Summary
# ===========================================================================
cat << EOF

${GREEN}Updated ${CONFIG_FILE}:${RESET}
  cosign:        ${COSIGN_VERSION} (sha256: ${COSIGN_SHA256})
  gh:            ${GH_VERSION} (sha256: ${GH_SHA256})
  jq:            ${JQ_VERSION} (sha256: ${JQ_SHA256})
  slsa-verifier: ${SLSA_VERIFIER_VERSION}
EOF

log "Tool versions updated successfully"
