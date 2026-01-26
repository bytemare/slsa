#!/usr/bin/env bash
# shellcheck disable=SC1091
#
# SPDX-License-Identifier: MIT
#
# Copyright (C) 2026 Daniel Bourdrez. All Rights Reserved.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree or at
# https://spdx.org/licenses/MIT.html
#

# Deterministic source packaging script for SLSA L3/L4 compliance.
# Language support can be auto-detected or forced via PACKAGING_LANGUAGE (go|generic|auto).
#
# Usage:
#   ./package-source.sh [--help]
#
# Required env (set automatically by GitHub Actions, or manually for local reproduction):
#   GITHUB_SHA         Commit SHA to package.
#   GITHUB_REPOSITORY  owner/repo string.
#   GITHUB_REF_NAME    Tag or branch name used in naming.
#   GITHUB_REF_TYPE    "tag" for tag builds or anything else treated as non-tag.
#   GITHUB_RUN_NUMBER  Used only to disambiguate dry-run (non-tag) builds.
#
# Optional env:
#   PACKAGING_LANGUAGE  go|generic|auto (defaults to auto; auto checks for go.mod in commit)
#   EXTENDED_METADATA   true|false (defaults to false)
#   SLSA_BUILDER_IMAGE  Container image used for hermetic builds
#
# Outputs (written to $GITHUB_OUTPUT for workflow consumption):
#   artifact_path       Full path to produced .tar.gz
#   artifact_filename   Basename of the archive
#   artifact_sha256     SHA-256 digest of the archive
#   subjects_b64        Base64 encoding of subjects.sha256 line (SLSA input)
#
# Produced artifacts (persisted in repo workspace):
#   dist/<basename>.tar.gz        Reproducible source archive
#   subjects.sha256 / .b64        Canonical digest plus base64 variant
#   manifest.files.sha256         Per-file content digests (content-addressed map)
#   commit.metadata / .sha256     Core commit descriptors
#   build.env / .sha256           Toolchain snapshot and script hash
#   packaging-script.sha256       Integrity hash of this script itself
#
# Exit codes:
#   0   Success
#   1   General error (missing env, invalid input)
#   2   Git error (dirty worktree, invalid commit)
#   3   Archive error (empty archive, missing required files)
#   4   Reproducibility error (self-check failed)
#
# Design decisions (trade-offs):
#   - gzip -n -9: maximum compression and zeroed metadata (deterministic), slight CPU cost acceptable (single archive).
#   - Dual determinism checks: internal self-check here plus external rebuild job in CI for SLSA L4 readiness evidence.
#   - Per-file SHA-256 manifest retained (most useful for external verification) while other metadata (git tree, optional Go env) gated by EXTENDED_METADATA for lean defaults.
#   - Keeping script hash in both packaging-script.sha256 and build.env provides redundancy for integrity.
#
# Security posture:
#   - Aborts if working tree or index is dirty (prevents accidental inclusion of
#     unstaged changes causing irreproducibility).
#   - Sanitizes naming components to avoid path or shell interpretation issues.
#   - SOURCE_DATE_EPOCH derived from commit timestamp (future-proof if build
#     steps are added that honor it).
#
# NOTE: If adding build steps later (e.g., compiled binaries), propagate the same SOURCE_DATE_EPOCH and use -trimpath or reproducible flags for the language toolchain.

set -euo pipefail
export LC_ALL=C LANG=C TZ=UTC
umask 022

# -----------------------------------------------------------------------------
# Exit codes
# -----------------------------------------------------------------------------
readonly EXIT_SUCCESS=0
readonly EXIT_GENERAL_ERROR=1
readonly EXIT_GIT_ERROR=2
readonly EXIT_ARCHIVE_ERROR=3
readonly EXIT_REPRODUCIBILITY_ERROR=4

# -----------------------------------------------------------------------------
# Script metadata
# -----------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="${0##*/}"

# -----------------------------------------------------------------------------
# Color support (respects NO_COLOR standard: https://no-color.org/)
# -----------------------------------------------------------------------------
if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
  readonly RED=$'\033[0;31m'
  readonly GREEN=$'\033[0;32m'
  readonly YELLOW=$'\033[0;33m'
  readonly BLUE=$'\033[0;34m'
  readonly RESET=$'\033[0m'
else
  # shellcheck disable=SC2034  # Colors defined for consistency, used conditionally
  readonly RED='' GREEN='' YELLOW='' BLUE='' RESET=''
fi

# -----------------------------------------------------------------------------
# Cleanup and signal handling
# -----------------------------------------------------------------------------
declare -a CLEANUP_FILES=()

# shellcheck disable=SC2329  # Function invoked via trap
cleanup() {
  local file
  for file in "${CLEANUP_FILES[@]}"; do
    if [[ -f "$file" ]]; then rm -f "$file"; fi
  done
}

trap cleanup EXIT
trap 'echo "${RED}Interrupted${RESET}" >&2; exit 130' INT
trap 'echo "${RED}Terminated${RESET}" >&2; exit 143' TERM

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

# Print an error message and exit with specified code
# Usage: fail [exit_code] message
fail() {
  local code="${EXIT_GENERAL_ERROR}"
  if [[ "$1" =~ ^[0-9]+$ ]]; then
    code="$1"
    shift
  fi
  echo "${RED}ERROR:${RESET} $*" >&2
  exit "$code"
}

# Print a log message to stderr
log() {
  echo "${BLUE}[package]${RESET} $*" >&2
}

# Print a warning message to stderr
warn() {
  echo "${YELLOW}WARNING:${RESET} $*" >&2
}

# Check that an environment variable is set
# Usage: need VAR_NAME
need() {
  local var_name="$1"
  if [[ -z "${!var_name:-}" ]]; then
    fail "$EXIT_GENERAL_ERROR" "Missing required environment variable: $var_name"
  fi
}

# Compute SHA-256 hash of a file
# Usage: sha256_of FILE
sha256_of() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    fail "$EXIT_GENERAL_ERROR" "File not found: $file"
  fi
  sha256sum -- "$file" | awk '{print $1}'
}

# Sanitize a string for use in filenames
# Usage: sanitize STRING
sanitize() {
  local in="$1"
  local out="${in//[^A-Za-z0-9._-]/_}"
  if [[ -z "$out" ]]; then
    fail "$EXIT_GENERAL_ERROR" "Sanitized string is empty: $in"
  fi
  printf '%s\n' "$out"
}

# Show help message
show_help() {
  cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} — Deterministic source packaging for SLSA L3/L4

Usage:
  ${SCRIPT_NAME} [--help] [--version]

Required environment variables:
  GITHUB_SHA          Commit SHA to package
  GITHUB_REPOSITORY   Repository in owner/repo format
  GITHUB_REF_NAME     Tag or branch name
  GITHUB_REF_TYPE     "tag" for releases, anything else for dry-run
  GITHUB_RUN_NUMBER   Workflow run number (for dry-run disambiguation)

Optional environment variables:
  PACKAGING_LANGUAGE  go|generic|auto (default: auto)
  EXTENDED_METADATA   true|false (default: false)
  SLSA_BUILDER_IMAGE  Container image for hermetic builds

Outputs (to \$GITHUB_OUTPUT):
  artifact_path       Path to the produced tarball
  artifact_filename   Tarball filename
  artifact_sha256     SHA-256 digest
  subjects_b64        Base64-encoded subjects for SLSA

Exit codes:
  0  Success
  1  General error
  2  Git error (dirty tree, invalid commit)
  3  Archive error (empty, missing files)
  4  Reproducibility error (self-check failed)

EOF
  exit "$EXIT_SUCCESS"
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    -h|--help) show_help ;;
    -V|--version) echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"; exit "$EXIT_SUCCESS" ;;
    *) fail "$EXIT_GENERAL_ERROR" "Unknown argument: $arg" ;;
  esac
done

# -----------------------------------------------------------------------------
# Main script
# -----------------------------------------------------------------------------

echo '::group::Validate environment & prepare'
# Validate required environment variables are present.
for v in GITHUB_SHA GITHUB_REPOSITORY GITHUB_REF_NAME GITHUB_RUN_NUMBER; do need "$v"; done
# Resolve packaging language (go|generic|auto).
PACKAGING_LANGUAGE="${PACKAGING_LANGUAGE:-auto}"
PACKAGING_LANGUAGE="$(echo "$PACKAGING_LANGUAGE" | tr '[:upper:]' '[:lower:]')"
if [[ "$PACKAGING_LANGUAGE" == "auto" ]]; then
  if git cat-file -e "${GITHUB_SHA}:go.mod" 2>/dev/null; then
    PACKAGING_LANGUAGE="go"
  else
    PACKAGING_LANGUAGE="generic"
  fi
fi
case "$PACKAGING_LANGUAGE" in
  go|generic) : ;;
  *) fail "$EXIT_GENERAL_ERROR" "Invalid PACKAGING_LANGUAGE: $PACKAGING_LANGUAGE (expected go|generic|auto)" ;;
esac
if [[ "$PACKAGING_LANGUAGE" == "go" ]]; then
  git cat-file -e "${GITHUB_SHA}:go.mod" 2>/dev/null || \
    fail "$EXIT_GENERAL_ERROR" "PACKAGING_LANGUAGE=go but go.mod not found in ${GITHUB_SHA}"
fi
# Ensure the referenced commit exists in this repository.
git rev-parse --verify -q "${GITHUB_SHA}^{commit}" >/dev/null || fail "$EXIT_GIT_ERROR" "Invalid commit ${GITHUB_SHA}"
# Enforce a clean working tree and index so the archive purely reflects the commit.
if ! git diff --quiet --ignore-submodules --exit-code || \
   ! git diff --quiet --cached --ignore-submodules --exit-code; then
  fail "$EXIT_GIT_ERROR" "Dirty worktree or index, aborting"
fi
# Use commit timestamp to seed deterministic tooling.
SOURCE_DATE_EPOCH="$(git show -s --format=%ct "$GITHUB_SHA")"
export SOURCE_DATE_EPOCH
# Sanitize naming components using the sanitize function defined above.
REPO_SAFE="$(sanitize "${GITHUB_REPOSITORY#*/}")"
if [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
  TAG_SAFE="$(sanitize "${GITHUB_REF_NAME//\//_}")"
else
  TAG_SAFE="$(sanitize "${GITHUB_REF_NAME//\//_}")-dryrun-${GITHUB_RUN_NUMBER}"
fi
BASENAME="$(echo "${REPO_SAFE}-${TAG_SAFE}" | tr -dc '[:print:]')"
readonly BASENAME
readonly OUTDIR="dist"
mkdir -p "$OUTDIR"
readonly ARCHIVE_PATH="${OUTDIR}/${BASENAME}.tar.gz"

echo '::endgroup::'

echo '::group::Create deterministic archive'
log "Creating deterministic archive: $ARCHIVE_PATH"
git archive --format=tar --prefix="${BASENAME}/" "$GITHUB_SHA" | gzip -n -9 > "$ARCHIVE_PATH"
[[ -s "$ARCHIVE_PATH" ]] || fail "$EXIT_ARCHIVE_ERROR" "Archive is empty"
# Structural guard (list just the target path to avoid broken-pipe edge cases).
if [[ "$PACKAGING_LANGUAGE" == "go" ]]; then
  if ! tar -tzf "$ARCHIVE_PATH" "${BASENAME}/go.mod" >/dev/null 2>&1; then
    fail "$EXIT_ARCHIVE_ERROR" "go.mod not found in archive"
  fi
fi
# Primary digest plus subjects (initially only archive, more subjects may be appended later).
artifact_sha256="$(sha256_of "$ARCHIVE_PATH")"
printf '%s  %s\n' "$artifact_sha256" "$(basename "$ARCHIVE_PATH")" > subjects.sha256
# (Deferred base64 generation until all subjects finalized.)
echo '::endgroup::'

echo '::group::Internal reproducibility self-check'
tmp_rebuild=$(mktemp)
CLEANUP_FILES+=("$tmp_rebuild")
git archive --format=tar --prefix="${BASENAME}/" "$GITHUB_SHA" | gzip -n -9 > "$tmp_rebuild"
artifact_sha256_rebuild="$(sha256_of "$tmp_rebuild")"
if [[ "$artifact_sha256_rebuild" != "$artifact_sha256" ]]; then
  echo "${RED}Original digest:${RESET} $artifact_sha256" >&2
  echo "${RED}Rebuilt  digest:${RESET} $artifact_sha256_rebuild" >&2
  fail "$EXIT_REPRODUCIBILITY_ERROR" "Internal reproducibility self-check failed"
fi
rm -f "$tmp_rebuild"
echo '::endgroup::'

echo '::group::Generate per-file manifest'
log "Generating per-file content manifest"
git ls-files -z | sort -z | while IFS= read -r -d '' f; do printf '%s  %s\n' "$(sha256_of "$f")" "$f"; done > manifest.files.sha256
echo '::endgroup::'

echo '::group::Commit metadata'
# Commit metadata snapshot (no separate .sha256 file as it's derivable from commit)
git show -s --format='format:COMMIT %H%nTREE %T%nPARENT %P%nAUTHOR %an <%ae> %ad%nCOMMITTER %cn <%ce> %cd%nSUBJECT %s%n' "$GITHUB_SHA" > commit.metadata
# Extract commit metadata fields for later summary and JSON.
commit_sha=$(sed -n 's/^COMMIT //p' commit.metadata)
tree_sha=$(sed -n 's/^TREE //p' commit.metadata)
parent_line=$(sed -n 's/^PARENT //p' commit.metadata)
file_manifest_entries=$(wc -l < manifest.files.sha256 | tr -d ' ')
echo '::endgroup::'

echo '::group::Extended metadata (conditional)'
if [ "${EXTENDED_METADATA:-false}" = "true" ]; then
  log "EXTENDED_METADATA enabled: git tree plus optional Go env"
  git ls-tree -r --full-tree --long "$GITHUB_SHA" > manifest.git-tree
  printf '%s  %s\n' "$(sha256_of manifest.git-tree)" manifest.git-tree > manifest.git-tree.sha256
  if [[ "$PACKAGING_LANGUAGE" == "go" ]]; then
    if command -v jq >/dev/null 2>&1; then go env -json | jq -S . > go.env.json; else go env -json > go.env.json; fi
    printf '%s  %s\n' "$(sha256_of go.env.json)" go.env.json > go.env.json.sha256
  fi
else
  log "EXTENDED_METADATA disabled: skipping git tree and language specific env snapshot"
fi
echo '::endgroup::'

echo '::group::Script & environment snapshot'
# Script integrity (hash stored in build.env, no separate file)
SCRIPT_PATH="$(realpath "$0")"
readonly SCRIPT_PATH
SCRIPT_DIGEST="$(sha256_of "$SCRIPT_PATH")"
readonly SCRIPT_DIGEST
# Capture gzip version
GZIP_VER=$(gzip --version 2>&1 | head -n1 || echo 'unknown')
readonly GZIP_VER
# Source OS info for runner identification
if [ -f /etc/os-release ]; then source /etc/os-release; fi
# Environment summary (no separate .sha256 file)
{
  printf 'GIT_VERSION=%s\n' "$(git --version)"
  printf 'GO_VERSION=%s\n' "$(go version 2>/dev/null || echo 'unknown')"
  printf 'GZIP_VERSION=%s\n' "$GZIP_VER"
  printf 'UNAME=%s\n' "$(uname -a)"
  printf 'RUNNER_OS_ID=%s\n' "${ID:-unknown}"
  printf 'RUNNER_OS_VERSION=%s\n' "${VERSION_ID:-unknown}"
  printf 'BUILD_PACKAGES=%s\n' "git,ca-certificates,gzip,wget,coreutils,perl-base"
  printf 'SOURCE_DATE_EPOCH=%s\n' "${SOURCE_DATE_EPOCH}"
  printf 'PACKAGING_SCRIPT_SHA256=%s\n' "$SCRIPT_DIGEST"
  printf 'PACKAGING_LANGUAGE=%s\n' "$PACKAGING_LANGUAGE"
  # Surface the container digest so external verifiers can reuse the exact builder.
  printf 'SLSA_BUILDER_IMAGE=%s\n' "${SLSA_BUILDER_IMAGE:-unknown}"
} > build.env
echo "EXTENDED_METADATA=${EXTENDED_METADATA:-false}" >> build.env
echo '::endgroup::'

echo '::group::Verification reports'
internal_self_check_status="passed"
# JSON summary
{
  echo '{'
  echo '  "artifact": {'
  printf '    "filename": "%s",\n' "$(basename "$ARCHIVE_PATH")"
  printf '    "sha256": "%s",\n' "$artifact_sha256"
  printf '    "subjects_sha256_line": "%s"\n' "$(head -n1 subjects.sha256)"
  echo '  },'
  echo '  "commit": {'
  printf '    "sha": "%s",\n' "$commit_sha"
  printf '    "tree": "%s",\n' "$tree_sha"
  printf '    "parents": ["%s"]\n' "${parent_line// /","}"
  echo '  },'
  echo '  "reproducibility": {'
  printf '    "internal_self_check": "%s",\n' "$internal_self_check_status"
  printf '    "extended_metadata": %s,\n' "${EXTENDED_METADATA:-false}"
  printf '    "file_manifest_entries": %s\n' "$file_manifest_entries"
  echo '  },'
  echo '  "environment": {'
  printf '    "git_version": "%s",\n' "$(git --version)"
  printf '    "go_version": "%s",\n' "$(go version 2>/dev/null || echo 'unknown')"
  printf '    "gzip_version": "%s",\n' "$GZIP_VER"
  printf '    "source_date_epoch": "%s",\n' "${SOURCE_DATE_EPOCH}"
  printf '    "script_sha256": "%s"\n' "$SCRIPT_DIGEST"
  echo '  },'
  echo '  "checksums": ['
  # list all subjects lines as JSON entries
  subj_sep=""; while read -r line; do s_sha=$(echo "$line"|awk '{print $1}'); s_file=$(echo "$line"|awk '{print $2}'); printf '    %s{"file": "%s", "sha256": "%s"}\n' "$subj_sep" "$s_file" "$s_sha"; subj_sep=','; done < subjects.sha256
  echo '  ],'
  echo '  "schema_version": "1.0"'
  echo '}'
} > verification.json
echo '::endgroup::'

echo '::group::Aggregate checksums'
# Aggregated checksums.txt file (no circular reference to subjects.sha256)
checksum_file=checksums.txt
{
  echo "# Aggregated SHA-256 checksums"
  echo "# Format: <sha256>  <filename>"
  echo "# This file provides quick verification of all artifacts"
  printf '%s  %s\n' "$artifact_sha256" "$(basename "$ARCHIVE_PATH")"
  printf '%s  %s\n' "$(sha256_of build.env)" build.env
  printf '%s  %s\n' "$(sha256_of manifest.files.sha256)" manifest.files.sha256
  printf '%s  %s\n' "$(sha256_of commit.metadata)" commit.metadata
  if [ -f manifest.git-tree ]; then printf '%s  %s\n' "$(sha256_of manifest.git-tree)" manifest.git-tree; fi
  if [ -f go.env.json ]; then printf '%s  %s\n' "$(sha256_of go.env.json)" go.env.json; fi
  printf '%s  %s\n' "$(sha256_of verification.json)" verification.json
} > "$checksum_file"

# Add checksums.txt as second SLSA subject
checksums_sha256="$(sha256_of "$checksum_file")"
printf '%s  %s\n' "$checksums_sha256" "$(basename "$checksum_file")" >> subjects.sha256
echo '::endgroup::'

# Generate base64 subjects for SLSA (ephemeral, for workflow use only)
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  subjects_b64=$(base64 < subjects.sha256 | tr -d '\n')
fi

# Summary line (parse-friendly)
subjects_count=$(wc -l < subjects.sha256 | tr -d ' ')
echo "PACKAGING SUMMARY: artifact=$(basename "$ARCHIVE_PATH") sha256=$artifact_sha256 extended_metadata=${EXTENDED_METADATA:-false} files=$file_manifest_entries commit=$commit_sha subjects=$subjects_count"

# GitHub Actions Job Summary (rich Markdown in the Actions UI)
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## 📦 Packaging Summary"
    echo ""
    echo "| Property | Value |"
    echo "|----------|-------|"
    echo "| **Artifact** | \`$(basename "$ARCHIVE_PATH")\` |"
    echo "| **SHA256** | \`${artifact_sha256:0:16}...\` |"
    echo "| **Commit** | \`${commit_sha:0:12}\` |"
    echo "| **Tree** | \`${tree_sha:0:12}\` |"
    echo "| **Files in manifest** | ${file_manifest_entries} |"
    echo "| **SLSA subjects** | ${subjects_count} |"
    echo "| **Extended metadata** | ${EXTENDED_METADATA:-false} |"
    echo "| **Packaging language** | ${PACKAGING_LANGUAGE} |"
    echo ""
    echo "### ✅ Reproducibility Self-Check"
    echo ""
    echo "Internal rebuild produced **identical digest** — packaging is deterministic."
    echo ""
    echo "<details>"
    echo "<summary>Full SHA256</summary>"
    echo ""
    echo "\`\`\`"
    echo "$artifact_sha256"
    echo "\`\`\`"
    echo "</details>"
  } >> "$GITHUB_STEP_SUMMARY"
fi

# Surface outputs for GitHub Actions workflow consumption.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    printf 'artifact_path=%s\n' "$ARCHIVE_PATH"
    printf 'artifact_filename=%s\n' "$(basename "$ARCHIVE_PATH")"
    printf 'artifact_sha256=%s\n' "$artifact_sha256"
    printf 'subjects_b64=%s\n' "$subjects_b64"
  } >> "$GITHUB_OUTPUT"
fi
