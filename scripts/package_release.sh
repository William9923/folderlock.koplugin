#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    if git describe --tags --exact-match >/dev/null 2>&1; then
        VERSION="$(git describe --tags --exact-match)"
    else
        VERSION="dev-$(git rev-parse --short HEAD)"
    fi
fi

OUT_DIR="$PWD/dist"
ASSET_NAME="folderlock.koplugin-${VERSION}.zip"
ASSET_PATH="$OUT_DIR/$ASSET_NAME"

mkdir -p "$OUT_DIR"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

cp -a "$PWD/folderlock.koplugin" "$TMP_DIR/folderlock.koplugin"
(
    cd "$TMP_DIR"
    zip -qr "$ASSET_PATH" folderlock.koplugin
)

echo "Created: $ASSET_PATH"
