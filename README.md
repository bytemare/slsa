# SLSA Level 3 Release and Verification Workflows

[![SLSA 3](https://slsa.dev/images/gh-badge-level3.svg)](https://slsa.dev)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/bytemare/slsa/badge)](https://scorecard.dev/viewer/?uri=github.com/bytemare/slsa)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/11820/badge)](https://www.bestpractices.dev/projects/11820)
[![Release](https://github.com/bytemare/slsa/actions/workflows/wf-release.yaml/badge.svg)](https://github.com/bytemare/slsa/actions/workflows/wf-release.yaml)

This project provides a set of tools to help software producers build and publish SLSA Level 3-compliant releases, and for consumers to verify them. They also gather reproducibility evidence to ease adoption of the upcoming SLSA Level 4 guidance once that level is formally published.
- Reusable GitHub Actions Workflows for packaging and verifying releases
- The `verify-release.sh` shell script helper for local verification and reproducibility checks (the same as used in the GitHub Actions verifier), including VSA generation

Building on the [SLSA generator](https://github.com/slsa-framework/slsa-github-generator) and [verifier](https://github.com/slsa-framework/slsa-verifier), and the [Sigstore](https://sigstore.dev/) ecosystem, these integrated workflows combine full producer and consumer flows with minimal setup.

---

## Table of Contents

- [Quick Start](#quick-start)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Supported Languages](#supported-languages)
- [Release - How to Use the Workflow](#release---how-to-use-the-workflow)
- [Verify](#verify)
- [SLSA Alignment](#slsa-alignment)
- [Supply Chain Security](#supply-chain-security)
- [Versioning and Compatibility](#versioning-and-compatibility)
- [Additional Resources](#additional-resources)
- [License](#license)

---

## Quick Start

```yaml
jobs:
  release:
    uses: bytemare/slsa/.github/workflows/slsa.yaml@<pinned-sha>
    with:
      workflow_ref: <pinned-sha>
    permissions:
      contents: write
      id-token: write
      attestations: write
      actions: read
```

For detailed configuration options, see [Release - How to Use the Workflow](#release---how-to-use-the-workflow).

---

## Features

- 🔒 **SLSA Level 3 Compliance** - Provenance via the official [slsa-github-generator](https://github.com/slsa-framework/slsa-github-generator), plus deterministic packaging and hermetic reproducible builds (to the extent of what GitHub provides)
- 🧭 **Level 4 Preparation** - Additional reproducibility materials to support an eventual Level 4 definition (Level 4 is not fully defined, yet)
- 📦 **SBOM** - [CycloneDX Software Bill of Materials](https://cyclonedx.org/specification/overview/)
- ✍️ **Keyless Signing** - [Cosign](https://github.com/sigstore/cosign) signatures with [Rekor](https://rekor.sigstore.dev) transparency logs
- 🗂️ **Complete Metadata** - attached to releases (commit metadata, environment snapshots, verification reports, subjects, checksums, manifests, SBOM, provenance, ...)
- ✅ **Verification Summary Attestation (VSA)** - Signed VSA documenting policy results for consumers
- ⚓️ **Native GitHub Attestations** - With the SBOM and build provenance
- 🛠️ **Easy Integration** - Plug-and-play with minimal setup
- 📜 **Attached to release** - The example workflow below will attach all artifacts to the GitHub Release

---

## Prerequisites

**For release workflow:** None required — tools are installed at runtime with SHA256 hash verification.

**For local verification (`verify-release.sh`):**

| Tool | Required For | Installation |
|------|--------------|--------------|
| `curl`, `jq`, `sha256sum` | All modes | Usually pre-installed |
| `cosign` | Signature verification | [Install guide](https://docs.sigstore.dev/cosign/system_config/installation/) |
| `gh` | GitHub API access (outside Actions) | [Install guide](https://cli.github.com/) |
| `slsa-verifier` | `--mode full` | [Install guide](https://github.com/slsa-framework/slsa-verifier#installation) |
| `docker` | `--mode reproduce` | [Install guide](https://docs.docker.com/get-docker/) |

```bash
# Show all options
./verify-release.sh --help
```

---

## Supported Languages

Source packaging works for any repo. Go modules receive extra metadata (like `go env`) and use a Go-specific SBOM generator.

---

## Release - How to Use the Workflow

**Configuration:**

Replace `[pinned commit SHA]` to ensure stability. `workflow_ref` is required and
must match the same pinned ref so helper scripts are fetched from the same commit.

```yaml
---

name: Release

on:
  push:
    tags: # Adapt to your needs
      - '*.*.*'      # Semantic versioning tags
      - 'v*.*.*'     # Tags starting with 'v'
  workflow_dispatch:  # Manual trigger
  pull_request:       # Dry-run on PRs

permissions: {}

jobs:
  release:
    uses: bytemare/slsa/.github/workflows/slsa.yaml@[pinned commit SHA]
    with:
      workflow_ref: [pinned commit SHA] # required, ensures stable helper scripts
      dry_run: ${{ github.event_name == 'pull_request' }} # optional, default: false
      create_release: ${{ github.event_name != 'pull_request' }} # optional, default: true
      extended_metadata: false  # optional, default: false. Set to true for forensics mode.
      # see .github/workflows/slsa.yaml for all options
    permissions:
      contents: write           # Create releases
      id-token: write          # OIDC for signing
      attestations: write      # GitHub attestations
      actions: read            # Read workflow data
      security-events: write   # Upload SARIF (optional)
```

`packaging_language=auto` detects `go.mod` in the tagged commit and enables Go-specific metadata only when present. `sbom_language=auto` uses the Go SBOM generator when `go.mod` exists, otherwise it runs cdxgen (pin `cdxgen_version` for deterministic output).

### Inform your users

You can use the following snippet in your repo to inform your consumers of the release integrity properties:

> ## Release Integrity (SLSA Level 3)
> Releases are built with the reusable [bytemare/slsa](https://github.com/bytemare/slsa) workflow and ship the evidence required for SLSA Level 3 compliance:
>
> - 📦 Artifacts are uploaded to the release page, and include the deterministic source archive plus subjects.sha256, signed SBOM (sbom.cdx.json), GitHub provenance (*.intoto.jsonl), a reproducibility report (verification.json), and a signed Verification Summary Attestation (verification-summary.attestation.json[.bundle]).
> - ✍️ All artifacts are signed using [Sigstore](https://sigstore.dev) with transparency via [Rekor](https://rekor.sigstore.dev).
> - ✅ Verification (or see the latest docs at [bytemare/slsa](https://github.com/bytemare/slsa)):
> ```shell
> curl -sSL https://raw.githubusercontent.com/bytemare/slsa/main/verify-release.sh -o verify-release.sh
> chmod +x verify-release.sh
> ./verify-release.sh --repo <owner>/<repo> --tag <tag> --mode full --signer-repo bytemare/slsa
> ```
> Run again with `--mode reproduce` to build in a container, or `--mode vsa` to validate just the verification summary.

---

## Verify

Quick verification using the helper script:

`<workflow-repo>` should match the reusable workflow repo that produced the attestations (for example, `bytemare/slsa` or your fork).
```bash
# Download the verification script
curl -sSL https://raw.githubusercontent.com/bytemare/slsa/main/verify-release.sh -o verify-release.sh
chmod +x verify-release.sh

# Run quick verification (checksums + signatures)
./verify-release.sh --repo <owner>/<repo> --tag <tag>

# Run full verification (all artifacts)
./verify-release.sh --repo <owner>/<repo> --tag <tag> --mode full --signer-repo <workflow-repo>

# Run containerized reproducibility check (requires Docker and rebuilds inside a container)
./verify-release.sh --repo <owner>/<repo> --tag <tag> --mode reproduce

# Generate and sign a Verification Summary Attestation locally
./verify-release.sh --repo <owner>/<repo> --tag <tag> --mode full --signer-repo <workflow-repo> \
  --emit-vsa my-release.vsa.json --verifier-id https://example.com/verifier

# Verify the published Verification Summary Attestation only
./verify-release.sh --repo <owner>/<repo> --tag <tag> --mode vsa
```

**Verification Modes:**
- **quick** (default) - Basic checksum and signature verification (fast, recommended for most users).
- **full** - Complete verification of all release artifacts including SBOM and provenance. This mode uses the
  official `slsa-verifier` to verify the provenance and additionally provides a holistic verification of the
  entire release, ensuring that all the pieces of the puzzle (artifacts, signatures, attestations, provenance,
  and SBOM) fit together correctly, providing a much higher level of confidence in the integrity and
  authenticity of the release.
- **reproduce** - Hermetic rebuild using the `SLSA_BUILDER_IMAGE` recorded in `build.env` (defaults to
  `golang:1.25-bookworm@sha256:...`), yielding independent evidence for future Level 4 expectations.

The script automatically:
- Checks for required tools (curl, jq, cosign, sha256sum, gh for attestations, slsa-verifier for full mode, docker for reproduce mode)
- Downloads all necessary artifacts
- Verifies checksums and signatures
- Validates SLSA provenance and SBOM (in full mode)
- Tests reproducibility (in reproduce mode)
- Provides concise one-line output with clear success/failure indicators

**Need a signed verification summary?**

Combine `--mode full` with `--emit-vsa <file> --verifier-id <uri>` (plus optional policy metadata) to generate a [Verification Summary Attestation](https://slsa.dev/spec/v1.1/verification_summary).

**Why does VSA generation live in `verify-release.sh`?**

VSA production happens *after* artifact publication so a verifier role, separate from the packager, can download the release assets, run all policy checks (full mode), and sign the result. Keeping verification outside `scripts/package-source.sh` preserves this independence.

### Run in GitHub Actions

Reuse the bundled verification workflow to automate checks in CI:

```yaml
jobs:
  verify-release:
    uses: bytemare/slsa/.github/workflows/verify.yaml@<pinned-commit>
    with:
      workflow_ref: <pinned-commit>
      tag: <tag>
      mode: full,reproduce   # run multiple modes sequentially
      emit_vsa: true         # optional – uploads a signed verification summary (requires full)
      verifier_id: <https://example.com/trusted-verifier> # optional – URI to identify the verifier in the VSA
    permissions:
      contents: read
      id-token: write
```

For interactive runs, trigger `.github/workflows/wf-verify.yaml`. It uses same reusable verifier with sensible defaults.

For the complete manual verification and reproducibility walkthrough, see [VERIFICATION_AND_REPRODUCIBILITY_GUIDE.md](VERIFICATION_AND_REPRODUCIBILITY_GUIDE.md).

---

## SLSA Alignment

> **Note:** The current SLSA specification (v1.1/v1.2) formally defines Levels 1–3. Level 4 remains a work in progress. This workflow implements the Level 3 controls and produces extra reproducibility evidence so to be prepared when Level 4 publication solidifies.

The following table maps the current [SLSA v1.2-rc1](https://slsa.dev/spec/v1.2-rc1/) requirements to how this workflow addresses each safeguard .

> ⚠️ **Disclaimer:** While this workflow implements the controls listed below, achieving SLSA compliance also depends on organizational policies and practices beyond the scope of this automation, like mandatory reviews from at least one other person. Users should ensure that their overall processes align with these SLSA requirements.

| SLSA v1.2 Requirement | Sub-requirement                                        | Compliant | Evidence                                                                                                                                                                                                    |
| --------------------- | ------------------------------------------------------ | --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Source**            |                                                        |           |                                                                                                                                                                                                             |
| Version Control       | All source code is version controlled.                 | Yes       | The project is hosted on GitHub.                                                                                                                                                                            |
| Verified History      | Commits are signed.                                    | Yes       | The project enforces signed commits.                                                                                                                                                                        |
| Retained Indefinitely | Source is retained indefinitely.                       | Yes       | The project is hosted on GitHub.                                                                                                                                                                            |
| **Build**             |                                                        |           |                                                                                                                                                                                                             |
| Scripted Build        | The build process is fully scripted.                   | Yes       | The build is scripted in `.github/workflows/slsa.yaml` and `scripts/package-source.sh`.                                                                                                                     |
| Build Service         | The build is performed by a build service.             | Yes       | The build is performed by GitHub Actions.                                                                                                                                                                   |
| Build as Code         | The build definition is stored in version control.     | Yes       | The build definition is in `.github/workflows/slsa.yaml`.                                                                                                                                                   |
| Ephemeral Environment | The build runs in an ephemeral environment.            | Yes       | The build runs in a container on GitHub Actions.                                                                                                                                                            |
| Isolated Build        | The build is isolated from other builds.               | Yes       | The `package_source` job in `.github/workflows/slsa.yaml` uses `step-security/harden-runner` to isolate the build.                                                                                          |
| Parameterless Build   | The build is parameterless.                            | Yes       | The build is triggered by a git tag and does not require any parameters.                                                                                                                                    |
| Hermetic Build        | The build is hermetic.                                 | Yes       | The `package_source` job in `.github/workflows/slsa.yaml` only pulls from GitHub and blocks with `egress-policy: block`, and the `package-source.sh` script ensures a clean worktree and no network access. |
| Reproducible Build    | The build is reproducible.                             | Yes       | The `rebuild_verify` job in `.github/workflows/slsa.yaml` verifies that the build is reproducible. The `verify-release.sh` script also provides a way to reproduce the build.                               |
| **Provenance**        |                                                        |           |                                                                                                                                                                                                             |
| Available             | Provenance is available.                               | Yes       | The `*.intoto.jsonl` file is the provenance.                                                                                                                                                                |
| Authenticated         | Provenance is authenticated.                           | Yes       | The provenance is signed using Sigstore and can be verified with `cosign`.                                                                                                                                  |
| Service Generated     | Provenance is generated by the build service.          | Yes       | The provenance is generated by GitHub Actions using the `slsa-framework/slsa-github-generator`.                                                                                                             |
| Non-Falsifiable       | Provenance is non-falsifiable.                         | Yes       | The provenance is signed and stored in a transparency log (Rekor).                                                                                                                                          |
| Dependencies Complete | Provenance includes all dependencies.                  | Yes       | The SBOM (`sbom.cdx.json`) is generated and attested, listing all dependencies.                                                                                                                             |
| **Common**            |                                                        |           |                                                                                                                                                                                                             |
| Security              | The build service meets security requirements.         | Yes       | GitHub Actions is a hardened build service.                                                                                                                                                                 |
| Access                | The build service has limited access to secrets.       | Yes       | The workflow uses minimal permissions.                                                                                                                                                                      |
| Superusers            | The number of superusers is minimized.                 | Yes       | Access to the repository and secrets is restricted.                                                                                                                                                         |

---

## Supply Chain Security

This project implements multiple layers of supply chain hardening:

### Tool Version and Hash Pinning

All external tools used in CI/CD workflows (cosign, gh, jq, slsa-verifier) are pinned to specific versions **and** verified against SHA256 checksums before execution. This defends against:

- **Version tag manipulation** — Even if an attacker compromises a release tag, the hash verification will fail
- **Binary substitution attacks** — Downloaded binaries are verified against known-good hashes before use
- **Supply chain injection** — No tool can execute without matching its recorded fingerprint

Tool versions and hashes are maintained in a single source of truth: [.github/tool-versions.json](.github/tool-versions.json).

### Automated Hash Updates

When [Renovate](https://docs.renovatebot.com/) detects a new tool version, it opens a PR updating the version in `tool-versions.json`. A companion workflow automatically:

1. Downloads the new binary
2. Computes its SHA256 hash
3. Updates `tool-versions.json` with the new hash
4. Commits the change to the PR

This keeps hashes synchronized with versions while maintaining full auditability—all hash changes are visible in PR diffs.

### Industry Alignment

This approach follows patterns used by security-focused projects:

| Practice | This Project | kubernetes/kubernetes | google/oss-fuzz | slsa-framework |
|----------|-------------|----------------------|-----------------|----------------|
| Version pinning | ✅ | ✅ | ✅ | ✅ |
| SHA256 hash verification | ✅ | ✅ (Docker images) | ✅ | ✅ (runtime) |
| Central version config | ✅ `tool-versions.json` | VERSION files | ENV in Dockerfile | Workflow outputs |
| Automated updates | ✅ Renovate + hash workflow | Manual | Manual | Renovate |

---

## Versioning and Compatibility

Even though releases follow [Semantic Versioning](https://semver.org/), you should use the latest available commit hash from main and pass it as `workflow_ref` to keep helper scripts pinned.

---

## Additional Resources

- **SLSA Framework:** <https://slsa.dev>
- **CycloneDX SBOM:** <https://cyclonedx.org>
- **Sigstore Documentation:** <https://docs.sigstore.dev>
- **Cosign CLI:** <https://docs.sigstore.dev/cosign/overview>

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE)
file for details.
