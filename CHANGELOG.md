# Changelog

<!-- markdownlint-disable MD024 -->

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

For releases prior to this changelog, see [GitHub Releases](https://github.com/bytemare/ecc/releases).

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
