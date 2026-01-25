#!/usr/bin/env bash
#
# SPDX-License-Identifier: MIT
#
# Copyright (C) 2026 Daniel Bourdrez. All Rights Reserved.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree or at
# https://spdx.org/licenses/MIT.html

# Updates tool versions and SHA256 pins in .github/tool-versions.json.
#
# This script downloads pinned tool binaries, computes their SHA256 hashes,
# and updates the central configuration file. This approach provides:
# - Supply chain security through hash verification
# - Single source of truth for all tool versions
# - Automated updates via Renovate + hash refresh workflow
#
# Requirements: curl, jq, sha256sum
#
# Optional env overrides:
#   COSIGN_VERSION, GH_VERSION, JQ_VERSION, SLSA_VERIFIER_VERSION
#   GITHUB_TOKEN (preferred) or GH_TOKEN for authenticated GitHub API calls
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${ROOT_DIR}/.github/tool-versions.json"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }; }
need curl
need jq
need sha256sum

sha256_of() {
  sha256sum "$1" | awk '{print $1}'
}

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

read_version() {
  local tool="$1"
  jq -r ".tools[\"${tool}\"].version // empty" "$CONFIG_FILE"
}

# Read current versions from config or use env overrides
COSIGN_VERSION="${COSIGN_VERSION:-$(read_version cosign)}"
GH_VERSION="${GH_VERSION:-$(read_version gh)}"
JQ_VERSION="${JQ_VERSION:-$(read_version jq)}"
SLSA_VERIFIER_VERSION="${SLSA_VERIFIER_VERSION:-$(read_version slsa-verifier)}"

# Handle "latest" -> fetch actual latest tag
if [[ "$COSIGN_VERSION" == "latest" ]]; then
  COSIGN_VERSION="$(latest_tag sigstore/cosign)"
fi
if [[ "$GH_VERSION" == "latest" ]]; then
  GH_VERSION="$(latest_tag cli/cli)"
fi
if [[ "$JQ_VERSION" == "latest" ]]; then
  JQ_VERSION="$(latest_tag jqlang/jq)"
fi
if [[ "$SLSA_VERIFIER_VERSION" == "latest" ]]; then
  SLSA_VERIFIER_VERSION="$(latest_tag slsa-framework/slsa-verifier)"
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "Downloading cosign ${COSIGN_VERSION}..."
curl -sSfL --retry 3 --retry-delay 2 --retry-all-errors \
  --proto '=https' --proto-redir '=https' --max-redirs 1 \
  -o "${tmpdir}/cosign" \
  "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64"
COSIGN_SHA256="$(sha256_of "${tmpdir}/cosign")"

echo "Downloading gh ${GH_VERSION}..."
curl -sSfL --retry 3 --retry-delay 2 --retry-all-errors \
  --proto '=https' --proto-redir '=https' --max-redirs 1 \
  -o "${tmpdir}/gh.tgz" \
  "https://github.com/cli/cli/releases/download/${GH_VERSION}/gh_${GH_VERSION#v}_linux_amd64.tar.gz"
GH_SHA256="$(sha256_of "${tmpdir}/gh.tgz")"

echo "Downloading jq ${JQ_VERSION}..."
curl -sSfL --retry 3 --retry-delay 2 --retry-all-errors \
  --proto '=https' --proto-redir '=https' --max-redirs 1 \
  -o "${tmpdir}/jq" \
  "https://github.com/jqlang/jq/releases/download/${JQ_VERSION}/jq-linux-amd64"
JQ_SHA256="$(sha256_of "${tmpdir}/jq")"

# Update tool-versions.json using jq
echo "Updating ${CONFIG_FILE}..."
jq --arg cosign_ver "$COSIGN_VERSION" \
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
   "$CONFIG_FILE" > "${tmpdir}/tool-versions.json"

mv "${tmpdir}/tool-versions.json" "$CONFIG_FILE"

cat <<EOF

Updated ${CONFIG_FILE}:
  cosign:        ${COSIGN_VERSION} (sha256: ${COSIGN_SHA256})
  gh:            ${GH_VERSION} (sha256: ${GH_SHA256})
  jq:            ${JQ_VERSION} (sha256: ${JQ_SHA256})
  slsa-verifier: ${SLSA_VERIFIER_VERSION}
EOF
