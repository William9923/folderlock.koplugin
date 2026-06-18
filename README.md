# folderlock.koplugin

Standalone repository for the KOReader `folderlock.koplugin` plugin.

## Layout

- `folderlock.koplugin/` — plugin files (`main.lua`, `_meta.lua`, `lib/`)
- `tests/` — unit + E2E test assets
- `vendor/koreader/` — KOReader submodule used for E2E tests

## Install (manual)

Copy `folderlock.koplugin/` into KOReader's plugins directory on your device.

## Commands

```bash
# Unit tests (standalone)
make test-unit

# E2E tests (requires KOReader submodule + build deps)
git submodule update --init --recursive
make test-e2e

# Lint
make lint

# Build release zip containing only folderlock.koplugin/
make package-release VERSION=v0.1.0
```
