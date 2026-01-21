#!/usr/bin/env bash
#
# Updates tool versions and SHA256 pins in workflow defaults.
#
# Requirements: curl, python3, sha256sum
#
# Optional env overrides:
#   COSIGN_VERSION, GH_VERSION, JQ_VERSION, SLSA_VERIFIER_VERSION
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW_RELEASE="${ROOT_DIR}/.github/workflows/slsa.yaml"
WORKFLOW_VERIFY="${ROOT_DIR}/.github/workflows/verify.yaml"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }; }
need curl
need python3
need sha256sum

sha256_of() {
  sha256sum "$1" | awk '{print $1}'
}

latest_tag() {
  local repo="$1"
  curl -sSfL "https://api.github.com/repos/${repo}/releases/latest" | \
    python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"])'
}

read_default() {
  local file="$1" key="$2"
  python3 - "$file" "$key" <<'PY'
import re, sys
path, key = sys.argv[1:]
text = open(path, "r", encoding="utf-8").read()
pattern = re.compile(rf'^\s*{re.escape(key)}:\s*\n(?:^\s+.*\n)*?^\s*default:\s*([^\s]+)', re.M)
match = pattern.search(text)
if not match:
    raise SystemExit(f"Missing default for {key} in {path}")
print(match.group(1))
PY
}

update_default() {
  local file="$1" key="$2" value="$3"
  python3 - "$file" "$key" "$value" <<'PY'
import re, sys
path, key, value = sys.argv[1:]
text = open(path, "r", encoding="utf-8").read()
pattern = re.compile(rf'(^\s*{re.escape(key)}:\s*\n(?:^\s+.*\n)*?^\s*default:\s*)([^\n]+)', re.M)
new_text, count = pattern.subn(rf'\g<1>{value}', text, count=1)
if count != 1:
    raise SystemExit(f"Failed to update {key} in {path} (matches={count})")
open(path, "w", encoding="utf-8").write(new_text)
PY
}

COSIGN_VERSION="${COSIGN_VERSION:-$(read_default "$WORKFLOW_RELEASE" cosign_version)}"
GH_VERSION="${GH_VERSION:-$(read_default "$WORKFLOW_RELEASE" gh_version)}"
JQ_VERSION="${JQ_VERSION:-$(read_default "$WORKFLOW_RELEASE" jq_version)}"
SLSA_VERIFIER_VERSION="${SLSA_VERIFIER_VERSION:-$(read_default "$WORKFLOW_RELEASE" slsa_verifier_version)}"

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

curl -sSfL --proto '=https' --proto-redir '=https' --max-redirs 1 \
  -o "${tmpdir}/cosign" \
  "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64"
COSIGN_SHA256="$(sha256_of "${tmpdir}/cosign")"

curl -sSfL --proto '=https' --proto-redir '=https' --max-redirs 1 \
  -o "${tmpdir}/gh.tgz" \
  "https://github.com/cli/cli/releases/download/${GH_VERSION}/gh_${GH_VERSION#v}_linux_amd64.tar.gz"
GH_SHA256="$(sha256_of "${tmpdir}/gh.tgz")"

curl -sSfL --proto '=https' --proto-redir '=https' --max-redirs 1 \
  -o "${tmpdir}/jq" \
  "https://github.com/jqlang/jq/releases/download/${JQ_VERSION}/jq-linux-amd64"
JQ_SHA256="$(sha256_of "${tmpdir}/jq")"

update_default "$WORKFLOW_RELEASE" cosign_version "$COSIGN_VERSION"
update_default "$WORKFLOW_RELEASE" cosign_sha256 "$COSIGN_SHA256"
update_default "$WORKFLOW_RELEASE" gh_version "$GH_VERSION"
update_default "$WORKFLOW_RELEASE" gh_sha256 "$GH_SHA256"
update_default "$WORKFLOW_RELEASE" jq_version "$JQ_VERSION"
update_default "$WORKFLOW_RELEASE" jq_sha256 "$JQ_SHA256"
update_default "$WORKFLOW_RELEASE" slsa_verifier_version "$SLSA_VERIFIER_VERSION"

update_default "$WORKFLOW_VERIFY" cosign_version "$COSIGN_VERSION"
update_default "$WORKFLOW_VERIFY" cosign_sha256 "$COSIGN_SHA256"
update_default "$WORKFLOW_VERIFY" slsa_verifier_version "$SLSA_VERIFIER_VERSION"

cat <<EOF
Updated:
- cosign: ${COSIGN_VERSION} (${COSIGN_SHA256})
- gh: ${GH_VERSION} (${GH_SHA256})
- jq: ${JQ_VERSION} (${JQ_SHA256})
- slsa-verifier: ${SLSA_VERIFIER_VERSION}
EOF
