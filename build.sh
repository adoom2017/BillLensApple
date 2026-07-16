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

assemble_macos_app() {
    local bin_dir="$1"
    local app_bundle="$2"
    local version="$3"
    local executable_name="BillLensMacApp"
    local resource_bundle_name="BillLensApple_BillLensAppleServices.bundle"

    rm -rf "$app_bundle"
    mkdir -p \
        "$app_bundle/Contents/MacOS" \
        "$app_bundle/Contents/Frameworks" \
        "$app_bundle/Contents/Resources"
    cp "$bin_dir/$executable_name" "$app_bundle/Contents/MacOS/$executable_name"
    cp "$REPO_ROOT/apple/Sources/BillLensMacApp/AppIcon.icns" \
        "$app_bundle/Contents/Resources/AppIcon.icns"
    cp -R "$bin_dir/llama.framework" "$app_bundle/Contents/Frameworks/llama.framework"
    cp -R "$bin_dir/$resource_bundle_name" \
        "$app_bundle/Contents/Resources/$resource_bundle_name"
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$app_bundle/Contents/MacOS/$executable_name"

    cat > "$app_bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.shendongchun.BillLensApple</string>
    <key>CFBundleName</key><string>BillLens</string>
    <key>CFBundleDisplayName</key><string>BillLens</string>
    <key>CFBundleExecutable</key><string>$executable_name</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
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
    BIN_DIR="$(swift_build_env swift build --show-bin-path -c debug)"
    APP_BUNDLE="$REPO_ROOT/apple/build/dev/BillLens.app"

    echo "==> Assembling debug .app"
    assemble_macos_app "$BIN_DIR" "$APP_BUNDLE" "1.0.0"

    echo "==> Code signing debug .app (ad-hoc, without restricted entitlements)"
    codesign --sign - --deep --force "$APP_BUNDLE"

    echo "==> Launching $APP_BUNDLE"
    "$APP_BUNDLE/Contents/MacOS/BillLensMacApp"
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
    VERSION="1.0.0"
    DIST_DIR="$REPO_ROOT/dist"
    APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
    DMG_PATH="$DIST_DIR/$APP_NAME.dmg"

    echo "==> Assembling .app"
    assemble_macos_app "$BIN_DIR" "$APP_BUNDLE" "$VERSION"

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
    echo "Done. Open apple/BillLensApple.xcodeproj in Xcode, select BillLensIOSApp → iOS Simulator and Run."
}

cmd_ios() {
    build_rust_ios
    echo "Done. Open apple/BillLensApple.xcodeproj in Xcode, select BillLensIOSApp → your device and Run."
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
