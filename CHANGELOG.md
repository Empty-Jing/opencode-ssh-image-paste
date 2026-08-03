# Changelog

All notable changes to this project are documented in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Start the default normal-integrity client through Explorer when installation
  runs elevated, wait for the previous client to exit before replacement, share
  one deadline across receiver probing and upload retries, and fill receiver slot
  holes before overwriting existing images.
- Avoid a trailing comma after generated actions when the existing Windows
  Terminal root `actions` array is empty, and repair affected v0.1.8 output on
  the next installer run.
- Insert private paste actions only into the root Windows Terminal `actions`
  array when nested composite-command arrays are also present.
- Refresh the stable Windows Terminal recovery backup before each update instead
  of retaining only the state from the first installation.

### Changed

- Reduce the private Terminal actions and rotating receiver image slots from 50
  to 10, aging retired v0.1.8 slot files out through the existing cleanup window.
- Use normal-integrity Startup by default. Administrator Terminal users must now
  explicitly select `-ElevatedStartup`; `-NonElevatedStartup` remains accepted
  for compatibility with existing install commands.
- Pin CI and Release actions to reviewed commit SHAs while retaining Dependabot
  updates for the declared action versions.

## [0.1.8] - 2026-08-03

### Fixed

- Treat the empty string produced when PowerShell coerces a `$null` string
  argument as an absent fresh-install configuration, rather than misclassifying
  a missing `config.toml` as an incompatible existing configuration.

## [0.1.7] - 2026-08-03

### Fixed

- Preserve a compact Windows Terminal `actions` array whose first element starts
  immediately after `[`, instead of allowing the inserted end-marker comment to
  consume that element and produce invalid JSONC.

## [0.1.6] - 2026-08-03

### Fixed

- Start the login client through a hidden Windows Script Host launcher so the
  console-subsystem executable does not flash a window before detaching.
- Trigger Windows Terminal slot actions with sequential zero-extra-info keyboard
  events; Windows Terminal 1.24 ignored the previous marked `SendInput` batch.
- Poll for asynchronous launcher startup instead of treating startup slower than
  500 ms as an installation failure.
- Use a per-user, highest-privilege login task by default so the client matches
  administrator Windows Terminal sessions; add `-NonElevatedStartup` for an
  explicit normal-integrity opt-out, including mode switching, rollback, and
  uninstall cleanup.

## [0.1.5] - 2026-08-01

### Added

- Protocol capability reporting and strict client/receiver compatibility checks.
- Cross-process receiver locking and a Windows named mutex to prevent duplicate
  clients from racing over image slots or keyboard hooks.
- Explicit decoded-result dimension, pixel, RGBA-size, and encoded PNG limits.
- Dependabot configuration for Cargo and GitHub Actions dependencies.
- Bounded per-paste timing logs for clipboard reads, PNG encoding, SSH transport,
  receiver round trips, terminal action dispatch, and the observable OpenCode
  handoff boundary.
- Atomic Windows Terminal `sendInput` slot-action installation, diagnostics, and
  uninstall cleanup.
- Standard PNG, DIBV5, DIB, and Bitmap clipboard image decoding, including
  Windows GDI fallback for screenshot tools such as PixPin.

### Changed

- Intercept only an exact image `Ctrl+V`; modified shortcuts such as
  `Ctrl+Shift+V`, `Ctrl+Alt+V`, and AltGr combinations pass through unchanged.
- Mark internally injected Terminal shortcuts so they do not cancel queued paste
  requests, and release synthetic keys after partial `SendInput` failures.
- Require Rust 1.89 or newer and protocol `OCB2`/`OCR2`.
- Gate Release publishing on tests, dependency audits, tag/package/changelog
  version equality, and the tagged commit being part of `main`; include
  `bootstrap.ps1` in `SHA256SUMS`.
- Publish x86_64 and aarch64 Linux receivers as static musl binaries so they do
  not depend on the target distribution's glibc version.
- Keep the latest 50 successful paste operations in private rotating image
  slots. Each paste invokes the matching private Windows Terminal action,
  which emits bracketed paste atomically without replacing or restoring the
  Windows clipboard. The 51st successful paste replaces the oldest slot.

### Fixed

- Prevent concurrent receiver processes from returning the same slot, reject
  abnormal managed slot files, and clean temporary images immediately after
  write or rename failures.
- Preserve valid Windows Terminal JSONC when adjacent project-owned actions are
  removed, and update settings with validated atomic replacement and rollback.
- Validate new Windows and Linux binaries before replacing the installed copies,
  migrate minimal TOML configurations, and restore the previous installation if
  a later installation step fails.
- Preserve recovery copies when an atomic settings restore fails, serialize
  install/uninstall operations, and keep the previous client stopped whenever
  any binary, config, Terminal, shortcut, or receiver rollback is incomplete.
- Remove project-owned Windows Terminal actions and keybindings after Terminal
  reformats them as separate multiline JSONC objects, so upgrading from the
  original single-slot action does not report a false shortcut conflict.

## [0.1.4] - 2026-07-31

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

[Unreleased]: https://github.com/Empty-Jing/opencode-ssh-image-paste/compare/v0.1.8...HEAD
[0.1.8]: https://github.com/Empty-Jing/opencode-ssh-image-paste/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/Empty-Jing/opencode-ssh-image-paste/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/Empty-Jing/opencode-ssh-image-paste/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/Empty-Jing/opencode-ssh-image-paste/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/Empty-Jing/opencode-ssh-image-paste/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/Empty-Jing/opencode-ssh-image-paste/releases/tag/v0.1.3
[0.1.2]: https://github.com/Empty-Jing/opencode-ssh-image-paste/releases/tag/v0.1.2
[0.1.1]: https://github.com/Empty-Jing/opencode-ssh-image-paste/releases/tag/v0.1.1
[0.1.0]: https://github.com/Empty-Jing/opencode-ssh-image-paste/releases/tag/v0.1.0
