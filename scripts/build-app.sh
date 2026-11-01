#!/bin/zsh
# 編譯 release 版並組成 build/NetQuota.app。
#   scripts/build-app.sh --bundle-id com.example.NetQuota            只打包
#   scripts/build-app.sh --bundle-id com.example.NetQuota --install  打包後複製到 /Applications 並啟動
# Bundle ID 也可以用環境變數 NETQUOTA_BUNDLE_ID 指定；兩者都有時以引數為準。
set -euo pipefail

usage() {
    echo "用法：scripts/build-app.sh --bundle-id <反向網域 ID> [--install]" >&2
    echo "  例如：scripts/build-app.sh --bundle-id com.example.NetQuota --install" >&2
    echo "  也可以先 export NETQUOTA_BUNDLE_ID=com.example.NetQuota" >&2
}

BUNDLE_ID="${NETQUOTA_BUNDLE_ID:-}"
INSTALL=0
while (( $# > 0 )); do
    case "$1" in
        --install) INSTALL=1 ;;
        --bundle-id) (( $# >= 2 )) || { usage; exit 1; }; BUNDLE_ID="$2"; shift ;;
        --bundle-id=*) BUNDLE_ID="${1#*=}" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "不認得的引數：$1" >&2; usage; exit 1 ;;
    esac
    shift
done

if [[ -z "$BUNDLE_ID" ]]; then
    echo "請指定 Bundle ID。" >&2
    usage
    exit 1
fi
# 只允許英數、點與連字號，且至少要有一個點（例如 com.example.NetQuota）。
if [[ ! "$BUNDLE_ID" =~ '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' ]]; then
    echo "Bundle ID 格式不正確：$BUNDLE_ID（只能有英數、點與連字號，例如 com.example.NetQuota）" >&2
    exit 1
fi

ROOT="${0:A:h:h}"

# App 版本號取自目前 commit 已包含的最大版本 tag（v1.1 → 1.1）。
# 不是從 git 取得原始碼（例如下載 zip）時用 0.0；放在別的 git 專案底下時也不讀那個專案的 tag。
VERSION=""
if [[ "$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" == "$ROOT" ]]; then
    VERSION="$(git -C "$ROOT" tag --merged HEAD --list 'v[0-9]*' --sort=-v:refname | head -n 1)"
fi
VERSION="${VERSION#v}"
if [[ ! "$VERSION" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]]; then
    echo "找不到版本 tag，版本號使用 0.0" >&2
    VERSION="0.0"
fi

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
    <string>BUNDLE_ID</string>
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
    <string>APP_VERSION</string>
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
    <string>MIT License</string>
</dict>
</plist>
PLIST

# 每次打包用不同的版本號，系統與 Dock 才會重新讀取圖示，不會沿用舊的快取。
/usr/bin/sed -i '' -e "s/BUILD_NUMBER/$(date +%Y%m%d%H%M%S)/" -e "s/BUNDLE_ID/$BUNDLE_ID/" \
    -e "s/APP_VERSION/$VERSION/" "$APP/Contents/Info.plist"

# ad-hoc 簽章預設用 cdhash 當身分，每次打包都會變，系統就會重新詢問定位等權限。
# 把身分指定為 Bundle ID，重新打包後系統會沿用之前的授權。
codesign --force --sign - -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
echo "已產生 $APP（$BUNDLE_ID，版本 $VERSION）"

if (( INSTALL )); then
    pkill -x NetQuota 2>/dev/null || true
    sleep 1
    rm -rf /Applications/NetQuota.app
    cp -R "$APP" /Applications/
    # 重新登記 App，讓 Dock 上固定的圖示馬上更新（否則可能暫時顯示成空白）。
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/NetQuota.app
    open /Applications/NetQuota.app
    echo "已安裝到 /Applications 並啟動"
fi
