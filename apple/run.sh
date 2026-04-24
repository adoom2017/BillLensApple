#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_MODE="${1:-debug}"
BINARY_NAME="BillLensMacApp"
APP_NAME="BillLensApple"
APP_BUNDLE="$SCRIPT_DIR/.build/$APP_NAME.app"

# 1. Build
swift build -c "$BUILD_MODE" --product "$BINARY_NAME"

# 2. Assemble .app bundle
CONTENTS="$APP_BUNDLE/Contents"
rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

# Binary
cp "$SCRIPT_DIR/.build/$BUILD_MODE/$BINARY_NAME" "$CONTENTS/MacOS/$BINARY_NAME"

# Info.plist (填入实际值，替换 Xcode 变量)
cat > "$CONTENTS/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hans</string>
    <key>CFBundleExecutable</key>
    <string>BillLensMacApp</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.billlens.apple</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>BillLensApple</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>BillLens 需要麦克风权限以支持语音输入账单。</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>BillLens 需要语音识别权限以将语音转换为文字。</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

# Icon
cp "$SCRIPT_DIR/Sources/$BINARY_NAME/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

# 3. 关掉旧实例，打开新 bundle
pkill -x "$BINARY_NAME" 2>/dev/null || true
open "$APP_BUNDLE"
