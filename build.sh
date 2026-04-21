#!/bin/zsh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_MODE="${RUST_BUILD_MODE:-debug}"

# ---- helpers ----

rust_flags() {
    [[ "$BUILD_MODE" == "release" ]] && echo "--release" || echo ""
}

swift_build_env() {
    HOME="$REPO_ROOT/.swift-build-home" \
    CLANG_MODULE_CACHE_PATH="$REPO_ROOT/.swift-build-home/clang-module-cache" \
    "$@"
}

build_rust_macos() {
    echo "==> Rust macOS ($BUILD_MODE)"
    cd "$REPO_ROOT/rust"
    cargo build -p billlens_ffi $(rust_flags)
}

build_rust_ios_sim() {
    echo "==> Rust iOS Simulator ($BUILD_MODE)"
    rustup target add aarch64-apple-ios-sim 2>/dev/null || true
    cd "$REPO_ROOT/rust"
    IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build -p billlens_ffi $(rust_flags) --target aarch64-apple-ios-sim
}

build_rust_ios() {
    echo "==> Rust iOS device ($BUILD_MODE)"
    rustup target add aarch64-apple-ios 2>/dev/null || true
    cd "$REPO_ROOT/rust"
    IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build -p billlens_ffi $(rust_flags) --target aarch64-apple-ios
}

# ---- subcommands ----

cmd_dev() {
    build_rust_macos
    echo "==> Swift macOS (debug)"
    cd "$REPO_ROOT/apple"
    swift_build_env swift build --product BillLensMacApp
    echo "==> Launching BillLensMacApp"
    BIN_DIR="$(swift_build_env swift build --show-bin-path -c debug)"
    "$BIN_DIR/BillLensMacApp"
}

cmd_mac() {
    export RUST_BUILD_MODE=release
    BUILD_MODE=release
    build_rust_macos

    echo "==> Swift macOS (release)"
    cd "$REPO_ROOT/apple"
    RUST_BUILD_MODE=release swift_build_env swift build -c release --product BillLensMacApp
    BIN_DIR="$(RUST_BUILD_MODE=release swift_build_env swift build --show-bin-path -c release)"

    APP_NAME="BillLens"
    BUNDLE_ID="com.shendongchun.BillLensApple"
    VERSION="1.0.0"
    DIST_DIR="$REPO_ROOT/dist"
    APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
    DMG_PATH="$DIST_DIR/$APP_NAME.dmg"

    echo "==> Assembling .app"
    rm -rf "$APP_BUNDLE"
    mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
    cp "$BIN_DIR/BillLensMacApp" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

    cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleSignature</key><string>????</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>BillLens 需要麦克风权限以支持语音输入账单。</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>BillLens 需要语音识别权限以将语音转换为文字。</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

    echo "==> Code signing (ad-hoc with CloudKit entitlements)"
    ENTITLEMENTS="$REPO_ROOT/apple/Sources/BillLensMacApp/BillLensMacApp.entitlements"
    codesign --sign - --deep --force --options runtime --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"

    echo "==> Creating DMG"
    mkdir -p "$DIST_DIR"
    rm -f "$DMG_PATH"
    hdiutil create -volname "$APP_NAME" -srcfolder "$APP_BUNDLE" -ov -format UDZO "$DMG_PATH"

    echo ""
    echo "Done:"
    echo "  App: $APP_BUNDLE"
    echo "  DMG: $DMG_PATH"
}

cmd_ios_sim() {
    build_rust_ios_sim
    echo "Done. Open apple/Package.swift in Xcode, select BillLensIOSApp → iOS Simulator and Run."
}

cmd_ios() {
    build_rust_ios
    echo "Done. Open apple/Package.swift in Xcode, select BillLensIOSApp → your device and Run."
}

cmd_all() {
    build_rust_macos
    build_rust_ios_sim
    build_rust_ios
    echo "Done. All platforms compiled."
}

cmd_test() {
    echo "==> Rust tests"
    cd "$REPO_ROOT/rust"
    cargo test --workspace
}

# ---- dispatch ----

usage() {
    cat <<EOF
Usage: ./build.sh <command>

Commands:
  dev       Compile (debug) + run macOS app
  mac       Compile (release) + package .app + create dist/BillLens.dmg
  ios-sim   Compile Rust for iOS Simulator (aarch64-apple-ios-sim)
  ios       Compile Rust for iOS device (aarch64-apple-ios)
  all       Compile Rust for all platforms (macOS + ios + ios-sim)
  test      Run Rust unit tests

Environment:
  RUST_BUILD_MODE=release   Switch to release mode (default: debug)
EOF
}

case "${1:-}" in
    dev)      cmd_dev ;;
    mac)      cmd_mac ;;
    ios-sim)  cmd_ios_sim ;;
    ios)      cmd_ios ;;
    all)      cmd_all ;;
    test)     cmd_test ;;
    *)        usage; exit 0 ;;
esac
