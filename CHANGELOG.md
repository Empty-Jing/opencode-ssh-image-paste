# Changelog

All notable changes to this project are documented in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- One-command uninstall through `bootstrap.ps1 -Uninstall`, including local and remote cleanup.
- `-KeepConfig` support for uninstalling without deleting the local configuration.
- Dedicated English and Simplified Chinese troubleshooting guides.
- Project-specific README hero, demo GIF, and social preview artwork.

### Changed

- Reorganized both READMEs around a four-step quick start, including uninstall.
- Installation instructions now download `bootstrap.ps1` from the latest Release instead of `main`.

## [0.1.3] - 2026-07-31

### Fixed

- Detached standard input and disabled pseudo-terminal allocation for bootstrap SSH probes, preventing first-run hangs at `Testing SSH connection`.

## [0.1.2] - 2026-07-31

### Fixed

- Replaced anonymous GitHub Releases API discovery with direct Release download URLs to avoid API rate-limit failures.

## [0.1.1] - 2026-07-31

### Fixed

- Made bootstrap diagnostics terminate cleanly after installation.
- Built and launched the Windows client as a windowless background process.
- Kept the SSH probe output on its own line for readable installer progress.

## [0.1.0] - 2026-07-31

### Added

- Windows clipboard client with image-only `Ctrl+V` interception for Windows Terminal.
- Persistent OpenSSH transport and Linux receiver with private temporary storage.
- Focus, input, mouse, and clipboard safety checks before automatic paste.
- `doctor` diagnostics and one-command Windows/Linux bootstrap installation.
- Release binaries for Windows x86_64, Linux x86_64, and Linux aarch64 with SHA-256 checksums.

[Unreleased]: https://github.com/Empty-Jing/opencode-ssh-image-paste/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/Empty-Jing/opencode-ssh-image-paste/releases/tag/v0.1.3
[0.1.2]: https://github.com/Empty-Jing/opencode-ssh-image-paste/releases/tag/v0.1.2
[0.1.1]: https://github.com/Empty-Jing/opencode-ssh-image-paste/releases/tag/v0.1.1
[0.1.0]: https://github.com/Empty-Jing/opencode-ssh-image-paste/releases/tag/v0.1.0
