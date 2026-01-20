# SLSA Level 3 Release and Verification Workflows

This project provides a set of tools to help software producers build and publish SLSA Level 3-compliant releases, and for consumers to verify them. They also gather reproducibility evidence to ease adoption of the upcoming SLSA Level 4 guidance once that level is formally published.
- Reusable GitHub Actions Workflows for packaging and verifying releases
- The `verify-release.sh` shell script helper for local verification and reproducibility checks (the same as used in the GitHub Actions verifier), including VSA generation

Most existing workflows stop at "build + provenance" or "SBOM + signatures." This project combines the full producer and consumer flows in one place, with a lower integration cost while raising confidence: consumers get consistent, verifiable evidence
out of the box, and producers get a repeatable, auditable release process that aligns with SLSA Level 3 today
and prepares for future Level 4 compliance, pending GitHub to enable truly L4 hermetic builds.

It provides:
- 🔒 **SLSA Level 3 Compliance** - [Deterministic packaging](https://github.com/slsa-framework/slsa-github-generator) + hermetic reproducible builds with non-falsifiable provenance (to the extent of what GitHub provides)
- 🧭 **Level 4 Preparation** - Additional reproducibility materials to support an eventual Level 4 definition (Level 4 is not fully defined, yet)
- 📦 **SBOM** - [CycloneDX Software Bill of Materials](https://cyclonedx.org/specification/overview/)
- ✍️ **Keyless Signing** - [Cosign](https://github.com/sigstore/cosign) signatures with [Rekor](https://rekor.sigstore.dev) transparency logs
- 🗂️ **Complete Metadata** - attached to releases (commit metadata, environment snapshots, verification reports, subjects, checksums, manifests, SBOM, provenance, ...)
- ✅ **Verification Summary Attestation (VSA)** - Signed VSA documenting policy results for consumers
- ⚓️ **Native GitHub Attestations** - With the SBOM and build provenance
- 🛠️ **Easy Integration** - Plug-and-play with minimal setup
- 📜 **Attached to release** - The example workflow below will attach all artifacts to the GitHub Release

## Supported languages

Source packaging works for any repo, and Go modules receive extra metadata (like `go env`) and use the Go-specific SBOM generator.

## Release - how to use the workflow

**Configuration:**

Replace `[pinned commit SHA]` to ensure stability.

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

## Verify

Quick verification using the helper script:
```bash
# Download the verification script
curl -sSL https://raw.githubusercontent.com/bytemare/slsa/main/verify-release.sh -o verify-release.sh
chmod +x verify-release.sh

# Run quick verification (checksums + signatures)
./verify-release.sh --repo <owner>/<repo> --tag <tag>

# Run full verification (all artifacts)
./verify-release.sh --repo <owner>/<repo> --tag <tag> --mode full

# Run containerized reproducibility check (requires Docker and rebuilds inside a container)
./verify-release.sh --repo <owner>/<repo> --tag <tag> --mode reproduce

# Generate and sign a Verification Summary Attestation locally
./verify-release.sh --repo <owner>/<repo> --tag <tag> --mode full \
  --emit-vsa my-release.vsa.json --verifier-id https://example.com/verifier

# Verify the published Verification Summary Attestation only
./verify-release.sh --repo <owner>/<repo> --tag <tag> --mode vsa
```

Need a signed verification summary? Combine `--mode full` with `--emit-vsa <file> --verifier-id <uri>` (plus optional policy metadata) to generate a [Verification Summary Attestation](https://slsa.dev/spec/v1.1/verification_summary).

**Why does VSA generation live in `verify-release.sh`?**

VSA production happens *after* artifact publication so a verifier role, separate from the packager, can download the release assets, run all policy checks (full mode), and sign the result. Keeping verification outside `scripts/package-source.sh` preserves this independence.

### Run in GitHub Actions

Reuse the bundled verification workflow to automate checks in CI:

```yaml
jobs:
  verify-release:
    uses: bytemare/slsa/.github/workflows/verify.yaml@<pinned-commit>
    with:
      repo: <owner>/<repo>
      tag: <tag>
      mode: full,reproduce   # run multiple modes sequentially
      emit_vsa: true         # optional – uploads a signed verification summary (requires full)
      verifier_id: <https://example.com/trusted-verifier> # optional – URI to identify the verifier in the VSA
```

For interactive runs, trigger `.github/workflows/wf-verify.yaml`. It uses same reusable verifier with sensible defaults.

## Inform your users

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
> ./verify-release.sh --repo <owner>/<repo> --tag <tag> --mode full
> ```
> Add `--mode reproduce` to rerun the build in a container, or `--mode vsa` to validate just the verification summary.
> - 🔁 Automated verification with the reusable verifier workflow from [bytemare/slsa](https://github.com/bytemare/slsa) in GitHub Actions:
> ```yaml
> permissions: {}
> 
> jobs:
>   verify-release:
>     uses: bytemare/slsa/.github/workflows/verify.yaml@<pinned-commit>
>     with:
>       repo: <owner>/<repo>
>       tag: <tag>
>       mode: full,reproduce
>       emit_vsa: true
>     permissions:
>       contents: read
> ```

## SLSA Alignment

> **Note:** The current SLSA specification (v1.1/v1.2) formally defines Levels 1–3. Level 4 remains a work in progress. This workflow implements the Level 3 controls and produces extra reproducibility evidence so to be prepared when Level 4 publication solidifies.

The following table maps the current [SLSA v1.2-rc1](https://slsa.dev/spec/v1.2-rc1/) requirements to how this workflow addresses each safeguard .

> ⚠️ **Disclaimer:** While this workflow implements the controls listed below, achieving SLSA compliance also depends on organizational policies and practices beyond the scope of this automation, like mandatory reviews from at least one other person. Users should ensure that their overall processes align with these SLSA requirements.

| SLSA v1.2 Requirement | Sub-requirement                                        | Compliant | Evidence                                                                                                                                                                                                    |
|-----------------------|--------------------------------------------------------|-----------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
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

## Versioning and Compatibility

Even though releases follow [Semantic Versioning](https://semver.org/), you should use the latest available commit hash from main.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE)
file for details.

