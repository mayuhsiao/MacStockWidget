#!/bin/bash
# 編譯並打包成 build/StockWidget.app
#   ./build.sh          只編譯
#   ./build.sh install  編譯後複製到 ~/Applications 並啟動
set -euo pipefail
cd "$(dirname "$0")"

# 用 swiftc 直接編譯（不依賴 SwiftPM / Xcode）。
# Command Line Tools 的 MacOSX.sdk 連結指向與編譯器相符的 SDK；
# xcrun 預設有可能挑到版本更新、編譯器讀不了的 SDK。
SDK="$(xcode-select -p)/SDKs/MacOSX.sdk"
[ -d "$SDK" ] || SDK="$(xcrun --show-sdk-path)"

mkdir -p .build
swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos14.0" \
  -sdk "$SDK" \
  -module-name StockWidget \
  Sources/StockWidget/*.swift \
  -o .build/StockWidget

APP=build/StockWidget.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/StockWidget "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
fi
codesign --force --sign - "$APP" >/dev/null
echo "✅ 已建立 $APP"

if [ "${1:-}" = "install" ]; then
  pkill -x StockWidget 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/StockWidget.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/StockWidget.app
  echo "✅ 已安裝到 ~/Applications/StockWidget.app 並啟動"
fi
