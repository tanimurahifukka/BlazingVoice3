#!/bin/bash
set -e

VERSION="${1:-4.0.7}"
BUILD_DATE=$(date +"%Y%m%d.%H%M")
BUILD_ID="${VERSION}.${BUILD_DATE}"
APP_NAME="BlazingVoice3"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"

echo "=== Building ${APP_NAME} v${VERSION} (build: ${BUILD_ID}) ==="

# Build release
echo "[1/5] Building release..."
swift build -c release

# Create app bundle
echo "[2/5] Creating app bundle..."
BUNDLE_DIR="${APP_NAME}.app"
rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

cp .build/release/${APP_NAME} "${BUNDLE_DIR}/Contents/MacOS/"

# Copy SPM resource bundle if it exists
RESOURCE_BUNDLE=".build/release/BlazingVoice3_BlazingVoice3.bundle"
if [ -d "${RESOURCE_BUNDLE}" ]; then
    cp -R "${RESOURCE_BUNDLE}" "${BUNDLE_DIR}/Contents/Resources/"
    echo "  Copied resource bundle"
fi

cat > "${BUNDLE_DIR}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.blazingvoice3.app</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_ID}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>BlazingVoice3は音声入力にマイクアクセスが必要です。</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>BlazingVoice3は音声認識を使用します。</string>
</dict>
</plist>
PLIST

cat > "entitlements.plist" << ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
ENTITLEMENTS

codesign --force --deep --sign - --identifier com.blazingvoice3.app --entitlements entitlements.plist "${BUNDLE_DIR}"
rm entitlements.plist

# Create install script
echo "[3/5] Creating installer..."
DMG_DIR="dmg_staging"
rm -rf "${DMG_DIR}"
mkdir -p "${DMG_DIR}"

cat > "${DMG_DIR}/インストール.command" << 'INSTALL'
#!/bin/bash
# BlazingVoice3 インストーラ
# ダブルクリックで実行してください

echo "=== BlazingVoice3 インストール ==="
echo ""

APP_SRC="$(dirname "$0")/BlazingVoice3.app"
APP_DST="/Applications/BlazingVoice3.app"

if [ ! -d "$APP_SRC" ]; then
    echo "エラー: BlazingVoice3.app が見つかりません"
    exit 1
fi

# Copy to Applications
echo "[1/3] Applications にコピー中..."
cp -R "$APP_SRC" "$APP_DST"

# Remove quarantine and re-sign (Gatekeeper bypass for ad-hoc signed app)
echo "[2/4] セキュリティ設定を解除中..."
xattr -cr "$APP_DST"

echo "[3/4] コード署名を適用中..."
codesign --force --deep --sign - --identifier com.blazingvoice3.app "$APP_DST"

# Launch
echo "[4/4] 起動中..."
open "$APP_DST"

echo ""
echo "=== インストール完了 ==="
echo "メニューバーに BlazingVoice3 アイコンが表示されます"
echo "左Shiftキーを2回押すと録音が開始されます"
echo ""
echo "※ 初回起動時にマイク・アクセシビリティの許可が求められます"
echo ""
INSTALL
chmod +x "${DMG_DIR}/インストール.command"

# Copy app and Applications link
cp -R "${BUNDLE_DIR}" "${DMG_DIR}/"
ln -s /Applications "${DMG_DIR}/Applications"

# Create DMG
echo "[4/5] Creating DMG..."
hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_DIR}" -ov -format UDZO "${DMG_NAME}"
rm -rf "${DMG_DIR}" "${BUNDLE_DIR}"

echo "[5/5] Done!"
echo "  Output:  ${DMG_NAME}"
echo "  Version: ${VERSION}"
echo "  Build:   ${BUILD_ID}"
echo "  Size:    $(du -h "${DMG_NAME}" | cut -f1)"
