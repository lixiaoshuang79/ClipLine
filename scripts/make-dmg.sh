#!/bin/bash
# 打 v 发布包：构建 ClipLine.app，封成带安装引导背景的 DMG（应用 + Applications 快捷方式）。
# 布局手法参考 Tendedero（MIT）；图片与文案为 ClipLine 自己的。
# 用法: scripts/make-dmg.sh [版本号，默认从 build 的 Info.plist 读]
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh release
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/ClipLine.app/Contents/Info.plist)}"
NAME="ClipLine"
DMG="dist/${NAME}-${VERSION}.dmg"

WORK="$(mktemp -d)"
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background" dist
cp -R build/ClipLine.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
swift scripts/make-dmg-background.swift "$WORK/bg1x.png" 1
swift scripts/make-dmg-background.swift "$WORK/bg2x.png" 2
# 1x/2x 合成一张 TIFF，Retina 屏下窗口背景也清晰。
tiffutil -cathidpicheck "$WORK/bg1x.png" "$WORK/bg2x.png" -out "$STAGE/.background/background.tiff" >/dev/null

RW="$WORK/rw.dmg"
hdiutil create -quiet -srcfolder "$STAGE" -volname "$NAME" -fs HFS+ -format UDRW -size 60m "$RW"
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')"

# 用 Finder 摆好窗口：无此权限时镜像仍可用，只是退成 Finder 默认布局。
osascript <<OSA || echo "Finder 布局被跳过（无自动化权限）"
tell application "Finder"
  tell disk "$NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 800, 528}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "${NAME}.app" of container window to {160, 150}
    set position of item "Applications" of container window to {440, 150}
    -- 尺寸最后再设一次：Finder 应用选项时可能改动窗口大小。
    set the bounds of container window to {200, 120, 800, 528}
    update without registering applications
    delay 1
    set the bounds of container window to {200, 120, 800, 528}
    delay 1
    close
  end tell
end tell
OSA

chmod -Rf go-w "$MOUNT" || true
sync
hdiutil detach -quiet "$MOUNT"
rm -f "$DMG"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -rf "$WORK"
echo "DMG: $DMG"
hdiutil imageinfo "$DMG" | awk '/Format:|Compressed Bytes|Total Bytes/ {print}' | head -4
