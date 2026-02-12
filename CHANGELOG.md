# Changelog

<!-- markdownlint-disable MD024 -->

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

For releases prior to this changelog, see [GitHub Releases](https://github.com/bytemare/ecc/releases).

## v0.4.0 - 12/2/2026

### Changed
- **BREAKING**: Removed all tool version override inputs from both `slsa.yaml` and `verify.yaml`
  - Removed: `cosign_version`, `cosign_sha256`, `gh_version`, `gh_sha256`, `jq_version`, `jq_sha256`, `slsa_verifier_version`, `cdxgen_version`, `builder_image`
  - All tool versions now exclusively sourced from `.github/tool-versions.json`
  - Enforces centralized security control and prevents override bypass attacks
  - Simplifies workflow API from 15+ inputs to 6 core inputs
- **BREAKING**: Removed VSA upload functionality from `verify.yaml`
  - Removed inputs: `upload_to_release`, `verify_vsa_after_upload`
  - VSA upload now handled exclusively by `slsa.yaml` for integrated release workflows
  - `verify.yaml` now read-only (contents: read) for external consumers
  - External verifiers emit VSA as workflow artifact only
- **verify.yaml** workflow restructured for least-privilege permissions
  - Split into conditional jobs: `run_verification` (read-only), `emit_vsa_artifact` (id-token: write)
  - `run_verification` downgraded to `contents: read` (was: write + id-token: write permissions)
  - VSA signing moved to separate `emit_vsa_artifact` job with minimal permissions
  - Enables truly read-only verification for external consumers
- **slsa.yaml** now handles VSA upload independently
  - New `upload_vsa_to_release` job downloads already-signed VSA artifact from verification workflow
  - Uploads signed VSA to GitHub release (no re-signing - verify.yaml signs it once)
  - Includes retry verification logic (10 attempts, 100s total) for CDN propagation
  - Clear separation: verify.yaml = verification + signing, slsa.yaml = upload only

### Added
- Comprehensive input validation in both workflows
  - `verify.yaml`: Validates repo format (owner/name), mode values (quick/full/reproduce/vsa), emit_vsa consistency
  - `slsa.yaml`: Validates packaging_language and sbom_language (auto/go/generic)
  - Warnings for non-semver tags (still allowed)
  - Fail-fast with clear error messages for invalid inputs
- Docker image caching removed (caused disk space issues on GitHub Actions runners)
  - Builder and cdxgen images now pulled fresh each run (~30-60s overhead)
  - Simpler than managing /tmp space limits and tar files

### Security
- Enforced least-privilege permissions across all workflows
  - External consumers of `verify.yaml` now require only `contents: read`
  - VSA upload restricted to `slsa.yaml` which already has `contents: write` for releases
  - Tool version tampering prevented by removing all override mechanisms
- Input validation prevents injection attacks and silent failures
  - Strict regex for repo format, allowed-list for mode/language values
  - Comprehensive validation before any sensitive operations

## v0.3.0 - 11/2/2026

### Added
- Conditional DEBUG logging with GitHub Actions collapsible groups
- Input validation for verifier_metadata to prevent injection attacks
- Required/optional file handling in download functions with proper error reporting

### Changed
- **BREAKING**: Switched cdxgen to container-based approach (docker required)
  - Uses digest-pinned ghcr.io/cyclonedx/cdxgen container
  - Eliminates npm registry from egress policy
  - SBOM generation now runs in dedicated job with docker access
  - Maintains full multi-language SBOM support
- **Reproduce mode now uses hermetic execution with network isolation**
  - Container runs with `--network none` flag for zero network access
  - All downloads and validation happen on host before container execution
  - Repository and artifacts mounted as read-only volumes
  - Eliminates curl/wget/ca-certificates requirement in builder images
  - Matches security model of CI package_source job (egress-policy: block)
  - Enables use of minimal images like golang:1.25-alpine or Chainguard
- gh CLI installation now uses dynamic version from tool-versions.json (previously hardcoded v2.40.1)
- VSA verification retry window increased from 30s to 100s to handle CDN propagation delays
- PR verification workflow now dynamically discovers latest release

### Fixed
- Silent downloads now properly detected and reported

### Removed
- Unused load-tool-versions composite action

### Security
- Eliminated npm registry access in SBOM generation (pure container-based approach)
- Added regex validation for verifier_metadata input

## v0.2.0 - 8/2/2026

### Added
- Automatic verifier metadata computation in verification workflows
  - `workflow_ref`: Automatically captures Git checkout reference (commit SHA, tag, or branch)
  - `script_sha`: Automatically computes SHA-256 hash of verify-release.sh for policy integrity
  - User-provided metadata is merged with automatic metadata for complete VSA context

### Changed
- **SLSA v1.2 Compliance**: Updated from v1.2-rc to official v1.2 specification
  - Updated default SLSA version from "1.1" to "1.2" in verify-release.sh
  - Fixed all specification links to point to stable v1.2 (slsa.dev/spec/v1.2)
  - Standardized terminology to "SLSA Build Track Level 3" throughout documentation
- **Workflow Consolidation**: Simplified GitHub Actions workflow structure
  - Enhanced verify.yaml as primary reusable workflow with automatic metadata computation
  - Simplified wf-verify.yaml to minimal caller workflow
  - Consolidated verification jobs in slsa.yaml to eliminate redundancy
  - Removed duplicate workflow_dispatch trigger from verify.yaml

### Improved
- **Documentation Enhancements**
  - Added comprehensive policy specification header to verify-release.sh documenting 7 verification requirements
  - Added "Policy as Executable Code" section to README explaining executable script approach
  - Clarified Build Track vs Source Track scope (this project implements Build Track Level 3)
  - Added Build Track scope clarification notes to README and Verification Guide
  - Updated all VSA specification references to v1.2
  - Enhanced examples for verifier metadata configuration with multi-line YAML syntax

## v0.1.0 - 27/01/2026

### Documentation
- Added governance and releasing documents to docs/
- Upgraded Code of Conduct to Contributor Covenant 3.0.
