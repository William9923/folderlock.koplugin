# folderlock.koplugin

Standalone repository for the KOReader `folderlock.koplugin` plugin.

## Layout

- `folderlock.koplugin/` — plugin files (`main.lua`, `_meta.lua`, `lib/`)
- `tests/` — unit + E2E test assets (to be added in later steps)

## Install (manual)

Copy `folderlock.koplugin/` into KOReader's plugins directory on your device.

## Development

This repo is being scaffolded in phases:
1. plugin extraction/refactor
2. standalone scaffolding
3. unit tests
4. E2E via koreader submodule
5. CI

## Commands

```bash
make test-unit
make test-e2e
make lint
```

(Commands are placeholders until later steps wire them up.)
