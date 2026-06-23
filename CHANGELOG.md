# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Auto-update system** — check for and install new versions directly from inside KOReader via **Folder Lock → Check for updates**
  - Fetches latest release metadata from GitHub Releases API
  - Downloads release zip and verifies SHA-256 checksum before touching the live plugin
  - Safe swap with rollback: renames live plugin → `.bak`, extracts new version in its place, restores `.bak` on any failure
  - Startup recovery: cleans up stale `.bak` after a successful boot, restores `.bak` if the live plugin is missing
  - Override URL for testing with a local dummy server
- **Runtime version source** — `folderlock.koplugin/lib/folderlock_version.lua` embedded at package time so the updater knows what's installed
- **Checksum sidecar in releases** — `folderlock.koplugin-<version>.zip.sha256` is now published alongside each release zip

### Changed

- **Code convention**: all KOReader module requires are scoped inside the functions that use them (lazy require), keeping the module loadable in test environments without the full KOReader runtime
- `scripts/package_release.sh` now injects the release version into the packaged plugin and generates the `.sha256` checksum file

## [0.1.0] - 2026-06-19

### Added

### Added

- **Folder lock/unlock UI** — lock or unlock the current folder via KOReader's main menu, with password confirmation before setting a new lock
- **Password prompt on navigation** — a patch on `FileChooser.changeToPath` intercepts folder entries and shows a password dialog when the target folder (or any ancestor) is locked
- **Ancestor cascade** — locking a parent folder automatically protects all subfolders; child folders are not individually locked but inherit protection
- **djb2 password hashing** — passwords are stored as djb2 hashes in an on-device registry file (`folderlock_registry.lua`); plaintext passwords are never persisted
- **Fail-safe design** — no file encryption or modification; removing the plugin or deleting the registry restores full access with zero risk of data loss

### Documentation

- Project overview, philosophy and scope, installation guide, usage walkthrough with screenshots
- Upcoming features documented: automatic updater, file-based lock, cover cache isolation

### CI & Testing

- **Unit tests** — Lua unit tests for core logic (hashing, path normalization, ancestor traversal, registry operations)
- **End-to-end tests** — KOReader simulator-based tests that exercise the full plugin lifecycle: loading, menu interaction, folder locking/unlocking, and password verification
- **GitHub Actions workflows** — test workflow (unit + e2e) on push/PR, and a release workflow that runs tests, packages the plugin, and publishes a GitHub Release on version tags
- **Test runner scripts** — `run_unit.sh` and `run_e2e.sh` for local development

### Build & Packaging

- `make package-release VERSION=...` produces a compressed `.zip` archive (`dist/folderlock.koplugin-<version>.zip`) using 9x compression
- `make run-koreader` symlinks the plugin into a local koreader checkout for rapid iteration

### Infrastructure

- Continuous integration against KOReader `v2026.03` via git submodule
- Dependencies installed for SDL3-based simulator builds (libdbus, libdecor, libibus, Wayland, X11, etc.)

### Fixed

- Use absolute path for `LD_LIBRARY_PATH` in CI for try_run reliability
- Revert submodule pointer back to official koreader repo
- Remove stray comments in docs

### Changed

- Set `LD_LIBRARY_PATH` for cmake SDL3 try_run in CI

[0.1.0]: https://github.com/William9923/folderlock.koplugin/releases/tag/0.1.0
