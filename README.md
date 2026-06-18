# folderlock.koplugin

Standalone repository for the KOReader `folderlock.koplugin` plugin.

## What this plugin does

`folderlock.koplugin` adds password protection to folders in KOReader's File Manager.

### Features

- Lock the **current folder** from KOReader menu (`Folder Lock`)
- Unlock the **current folder** from KOReader menu
- Intercept File Manager navigation and require password for locked folders
- Inherited lock checks: locking a parent folder also protects child folders
- Persistent lock registry saved in KOReader settings
- Passwords stored as hashed values (`djb2`) instead of plaintext

> Note: `djb2` is lightweight hashing used by current implementation. It is good for basic obfuscation, but not strong cryptographic password storage.

## Repository layout

- `folderlock.koplugin/` — plugin source (`main.lua`, `_meta.lua`, `lib/`)
- `tests/` — unit tests + KOReader E2E spec + test runners
- `vendor/koreader/` — KOReader submodule used for E2E testing
- `.github/workflows/test.yml` — CI test workflow (push/PR)
- `.github/workflows/release.yml` — tag-based release workflow
- `scripts/package_release.sh` — builds plugin-only release zip

## Local development

### 1) Clone + submodule setup

```bash
git clone <this-repo>
cd folderlock.koplugin
git submodule update --init --recursive
```

### 2) Run tests locally

```bash
# Unit tests (pure Lua)
make test-unit

# End-to-end tests (KOReader integration)
make test-e2e
```

### 3) Optional lint

```bash
make lint
```

## Test types

### Unit tests (`make test-unit`)

- Runner: `tests/run_unit.sh`
- Executes all files matching `tests/_test_*.lua`
- Fast, standalone, no KOReader build needed

### E2E tests (`make test-e2e`)

- Runner: `tests/run_e2e.sh`
- Requires `vendor/koreader` submodule
- Symlinks `folderlock.koplugin/` into KOReader's `plugins/`
- Copies `tests/folderlock_spec.lua` into KOReader spec directory
- Runs `./kodev test folderlock`
- Restores previous plugin/spec state on exit (cleanup trap)

## Automated GitHub Actions workflows

## CI testing (`.github/workflows/test.yml`)

Triggered on:

- every `push`
- every `pull_request`

Jobs:

- `unit`: installs Lua and runs `make test-unit`
- `e2e`: checks out submodules, installs KOReader build deps, runs `make test-e2e`

This ensures both pure logic and KOReader integration are validated in CI.

## Releases (`.github/workflows/release.yml`)

Triggered on tag push matching `v*` (example: `v0.1.0`).

Pipeline:

1. checkout repo + submodules
2. install dependencies
3. run unit tests
4. run E2E tests
5. build release asset via `make package-release VERSION=<tag>`
6. publish GitHub Release with generated notes

Release asset created:

- `folderlock.koplugin-<tag>.zip`

The zip contains only:

- `folderlock.koplugin/`

No submodule or dev/test files are included in the user-facing release artifact.

## Manual release packaging (local)

```bash
make package-release VERSION=v0.1.0
```

Output:

- `dist/folderlock.koplugin-v0.1.0.zip`

## Installation for end users

From a GitHub Release asset:

1. Download `folderlock.koplugin-<version>.zip`
2. Extract it
3. Copy `folderlock.koplugin/` into your KOReader `plugins/` directory
4. Restart KOReader
