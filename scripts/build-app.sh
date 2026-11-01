#!/bin/zsh
# 編譯 release 版並組成 build/NetQuota.app。
#   scripts/build-app.sh            只打包
#   scripts/build-app.sh --install  打包後複製到 /Applications 並啟動
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/build/NetQuota.app"
cd "$ROOT"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/NetQuota"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NetQuota"
[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift Resources/AppIcon.icns
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 宣告繁體中文，系統選單（編輯、視窗、說明…）才會顯示中文。
mkdir -p "$APP/Contents/Resources/zh-Hant.lproj" "$APP/Contents/Resources/zh_TW.lproj"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>io.github.sandwichcookice.NetQuota</string>
    <key>CFBundleName</key>
    <string>NetQuota</string>
    <key>CFBundleDisplayName</key>
    <string>NetQuota</string>
    <key>CFBundleExecutable</key>
    <string>NetQuota</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hant</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hant</string>
        <string>zh_TW</string>
    </array>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSLocationUsageDescription</key>
    <string>NetQuota 需要定位權限才能讀取 Wi-Fi 名稱，用來分開計算各網路的流量。不會取得或記錄你的位置。</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>NetQuota 需要定位權限才能讀取 Wi-Fi 名稱，用來分開計算各網路的流量。不會取得或記錄你的位置。</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Personal use</string>
</dict>
</plist>
PLIST

# 每次打包用不同的版本號，系統與 Dock 才會重新讀取圖示，不會沿用舊的快取。
/usr/bin/sed -i '' "s/BUILD_NUMBER/$(date +%Y%m%d%H%M%S)/" "$APP/Contents/Info.plist"

codesign --force --sign - "$APP"
echo "已產生 $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x NetQuota 2>/dev/null || true
    sleep 1
    rm -rf /Applications/NetQuota.app
    cp -R "$APP" /Applications/
    # 重新登記 App，讓 Dock 上固定的圖示馬上更新（否則可能暫時顯示成空白）。
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/NetQuota.app
    open /Applications/NetQuota.app
    echo "已安裝到 /Applications 並啟動"
fi
