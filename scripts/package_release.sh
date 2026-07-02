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
CHECKSUM_PATH="$ASSET_PATH.sha256"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$OUT_DIR"
cp -a "$PWD/folderlock.koplugin" "$TMP_DIR/"
cat > "$TMP_DIR/folderlock.koplugin/util/folderlock_version.lua" <<EOF
local FolderLockVersion = {
    VERSION = "${VERSION}",
}

return FolderLockVersion
EOF

(
    cd "$TMP_DIR"
    zip -qr9X "$ASSET_PATH" folderlock.koplugin
)

if command -v sha256sum >/dev/null 2>&1; then
    (
        cd "$OUT_DIR"
        sha256sum "$ASSET_NAME" > "$(basename "$CHECKSUM_PATH")"
    )
else
    (
        cd "$OUT_DIR"
        shasum -a 256 "$ASSET_NAME" > "$(basename "$CHECKSUM_PATH")"
    )
fi

echo "Created: $ASSET_PATH"
echo "Created: $CHECKSUM_PATH"
