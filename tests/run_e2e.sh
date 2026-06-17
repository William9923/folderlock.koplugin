#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

KOREADER="vendor/koreader"
PLUGIN_SRC="$PWD/folderlock.koplugin"
PLUGIN_DST="$KOREADER/plugins/folderlock.koplugin"
SPEC_SRC="$PWD/tests/folderlock_spec.lua"
SPEC_DST="$KOREADER/spec/unit/folderlock_spec.lua"

if [ ! -d "$KOREADER" ]; then
    echo "koreader submodule not found. Run: git submodule update --init --recursive"
    exit 1
fi

if [ ! -d "$PLUGIN_SRC" ]; then
    echo "plugin source not found at: $PLUGIN_SRC"
    exit 1
fi

if [ ! -f "$SPEC_SRC" ]; then
    echo "spec file not found at: $SPEC_SRC"
    exit 1
fi

BACKUP_PLUGIN=""
BACKUP_SPEC=""

cleanup() {
    if [ -n "$BACKUP_PLUGIN" ] && [ -e "$BACKUP_PLUGIN" ]; then
        rm -rf "$PLUGIN_DST"
        mv "$BACKUP_PLUGIN" "$PLUGIN_DST"
    else
        rm -rf "$PLUGIN_DST"
    fi

    if [ -n "$BACKUP_SPEC" ] && [ -e "$BACKUP_SPEC" ]; then
        rm -f "$SPEC_DST"
        mv "$BACKUP_SPEC" "$SPEC_DST"
    else
        rm -f "$SPEC_DST"
    fi
}
trap cleanup EXIT INT TERM

if [ -e "$PLUGIN_DST" ] || [ -L "$PLUGIN_DST" ]; then
    BACKUP_PLUGIN="$KOREADER/plugins/.folderlock.koplugin.backup.$$"
    mv "$PLUGIN_DST" "$BACKUP_PLUGIN"
fi
ln -s "$PLUGIN_SRC" "$PLUGIN_DST"

if [ -f "$SPEC_DST" ]; then
    BACKUP_SPEC="$KOREADER/spec/unit/.folderlock_spec.lua.backup.$$"
    mv "$SPEC_DST" "$BACKUP_SPEC"
fi
cp "$SPEC_SRC" "$SPEC_DST"

(
    cd "$KOREADER"
    ./kodev test folderlock
)
