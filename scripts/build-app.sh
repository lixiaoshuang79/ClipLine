#!/bin/bash
# 构建 ClipLine.app 到 ./build（SwiftPM，无需 Xcode 工程）。
# 用法: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
TRIPLE="arm64-apple-macosx14.0"
APP="build/ClipLine.app"
VERSION="1.3.4"

# CLT 自带的 macOS 27 SDK 缺 SwiftUI 需要的宏插件；失败时回退到旁边的 macOS 26 SDK。
if [ -z "${SDKROOT:-}" ] && ! swift build -c "$CONFIG" --triple "$TRIPLE"; then
  FALLBACK="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1 || true)"
  if [ -z "$FALLBACK" ]; then
    echo "构建失败，且没有可回退的 SDK" >&2
    exit 1
  fi
  echo "用 $FALLBACK 重试" >&2
  export SDKROOT="$FALLBACK"
  swift build -c "$CONFIG" --triple "$TRIPLE"
fi

BIN_DIR="$(swift build -c "$CONFIG" --triple "$TRIPLE" --show-bin-path)"
BIN="$BIN_DIR/ClipLine"
HELPER_BIN="$BIN_DIR/ClipLineOCRHelper"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClipLine"
# 独立识别进程：主进程的 ANE 会话失效后由它接管识别（见 OcrHelper.swift）。
cp "$HELPER_BIN" "$APP/Contents/MacOS/ClipLineOCRHelper"

# 图标：脚本绘制 1024 图，再切 iconset 打成 icns
WORK="$(mktemp -d)"
swift scripts/make-icon.swift "$WORK/icon.png"
ICONSET="$WORK/ClipLine.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/ClipLine.icns"
rm -rf "$WORK"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ClipLine</string>
  <key>CFBundleDisplayName</key><string>ClipLine</string>
  <key>CFBundleIdentifier</key><string>com.ashuang.clipline</string>
  <key>CFBundleExecutable</key><string>ClipLine</string>
  <key>CFBundleIconFile</key><string>ClipLine</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 签名：优先固定身份（默认「ClipLine Dev」自签名；SIGN_IDENTITY 可覆盖）。
# 为什么不用 ad-hoc：ad-hoc 的指定要求是 cdhash，每次重编译都变 → TCC
# （屏幕录制/辅助功能）授权全丢；固定证书的指定要求只认证书哈希，跨重编译稳定。
# 本机没有该身份时先跑 scripts/make-signing-identity.sh 生成。
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-certificate -c "ClipLine Dev" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  IDENTITY="ClipLine Dev"
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/ClipLineOCRHelper" >/dev/null
  codesign --force --sign "$IDENTITY" "$APP" >/dev/null
  echo "Signed with $IDENTITY (TCC 授权跨重编译保留)"
else
  codesign --force --sign - "$APP/Contents/MacOS/ClipLineOCRHelper" >/dev/null
  codesign --force --sign - "$APP" >/dev/null
  echo "Signed ad hoc（无固定身份；每次重编译会丢 TCC 授权，可跑 scripts/make-signing-identity.sh）"
fi
echo "Built $APP"
