# Changelog

<!-- markdownlint-disable MD024 -->

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

For releases prior to this changelog, see [GitHub Releases](https://github.com/bytemare/ecc/releases).

## v0.2.0 - 16/2/2026

### Changed
- **BREAKING**: SLSA subjects structure changed from 2 to 3 subjects
  - Added package-source.sh as third subject for script integrity verification
  - Checksums.txt moved to second line (use `sed -n '2p'` instead of `tail -n1`)
  - Documentation and verification commands updated accordingly

### Added
- Cross-verification in reproduce mode: release asset script validated against repository version
- Script integrity verification step added to manual verification guide
- Hermetic container execution for reproduce mode with defense-in-depth isolation:
  - Network isolation (`--network none`) prevents external communication during rebuild
  - Non-root execution with explicit UID/GID mapping
  - Read-only mounts for all inputs (repository, artifacts, scripts)
  - Security hardening: `--cap-drop=ALL`, `--security-opt=no-new-privileges`
  - Writable tmpfs with proper ownership for build workspace
  - Git config isolation to prevent configuration leakage

### Security
- Enhanced packaging script integrity with cross-verification between release assets and repository
- Reproduce mode now fully hermetic: all downloads and validations on host before container execution
- Container cannot access network or modify any input files during reproducibility check

### Fixed
- Embedded Docker script syntax errors (quote escaping in test commands and variable expansion)
- Git config permission issues in reproduce mode (use writable paths instead of /dev/null)
- Suppressed tar future timestamp warnings with --warning=no-timestamp flag
- Variable quoting in [[ ]] tests (shellcheck SC2027 compliance)

## v0.1.2 - 12/2/2026

### Changed
- **BREAKING**: Removed all tool version override inputs — all versions now sourced from `.github/tool-versions.json`
  - Enforces centralized security control and prevents bypass attacks
  - Simplifies workflow API from 15+ inputs to 6 core inputs
- **BREAKING**: Restructured VSA workflow separation for least-privilege
  - `verify.yaml` is now fully read-only (`contents: read` only), emits unsigned VSA as artifact
  - `slsa.yaml` signs and uploads VSA with proper permissions (`id-token: write` + `contents: write`)
  - External consumers can retrieve unsigned artifacts for their own signing
- **BREAKING**: SBOM generation switched to container-based approach (cdxgen via Docker)
  - Eliminates npm registry from egress policy
  - Uses digest-pinned `ghcr.io/cyclonedx/cdxgen` container
- Reproduce mode now uses hermetic execution with `--network none` container isolation
  - Downloads and validation happen on host before mounting read-only into container
  - Enables use of minimal images (Alpine, Chainguard)
- VSA verification retry window increased from 30s to 100s for CDN propagation

### Added
- Comprehensive input validation with fail-fast error messages
- Debug logging with GitHub Actions collapsible groups

### Security
- Enforced least-privilege permissions across all workflows
- Added input validation to prevent injection attacks (regex for repo format, allowlist for mode/language values)

## v0.1.1 - 8/2/2026

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
