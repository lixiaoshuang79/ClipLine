#!/bin/bash
# 打 v1.0.0 发布包：先构建 ClipLine.app，再封成 DMG（应用 + Applications 快捷方式）。
# 用法: scripts/make-dmg.sh [版本号，默认 1.0.0]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
scripts/build-app.sh release

STAGE="$(mktemp -d)"
cp -R build/ClipLine.app "$STAGE/ClipLine.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
DMG="dist/ClipLine-${VERSION}.dmg"
rm -f "$DMG"
hdiutil create -volname "ClipLine" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "DMG: $DMG"
hdiutil imageinfo "$DMG" | awk '/Format:|Size Information|Compressed Bytes|Total Bytes/ {print}' | head -6
