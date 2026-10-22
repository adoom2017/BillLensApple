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

# ---- Xcode (xcodebuild) helpers ----

XCODE_PROJECT="$REPO_ROOT/apple/BillLensApple.xcodeproj"
DERIVED_DATA="$REPO_ROOT/apple/build/DerivedData"
XCODE_DIST="$REPO_ROOT/dist/xcode"

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "error: 缺少 $1，$2" >&2
        exit 1
    fi
}

xcode_generate() {
    require_tool xcodegen "请先执行 brew install xcodegen"
    require_tool xcodebuild "请安装 Xcode 并执行 xcode-select -s /Applications/Xcode.app"
    echo "==> xcodegen (apple/project.yml)"
    (cd "$REPO_ROOT/apple" && xcodegen generate --quiet)
}

run_xcodebuild() {
    xcodebuild -project "$XCODE_PROJECT" -derivedDataPath "$DERIVED_DATA" -quiet "$@"
}

# 本机临时签名：不带 iCloud/推送等受限 entitlements，任何 Mac 都能直接运行。
adhoc_signing_args=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY=-
    DEVELOPMENT_TEAM=
    CODE_SIGN_ENTITLEMENTS=
    ENABLE_HARDENED_RUNTIME=NO
)

write_export_options() {
    local path="$1"
    local method="$2"
    cat > "$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>$method</string>
    <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST
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
    echo "Done. Open apple/BillLensApple.xcodeproj in Xcode, select scheme BillLens-iOS → iOS Simulator and Run."
}

cmd_ios() {
    build_rust_ios
    echo "Done. Open apple/BillLensApple.xcodeproj in Xcode, select scheme BillLens-iOS → your device and Run."
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

cmd_xcode() {
    xcode_generate
    open "$XCODE_PROJECT"
}

cmd_xcode_mac() {
    export RUST_BUILD_MODE=release
    BUILD_MODE=release
    build_rust_macos
    xcode_generate

    echo "==> xcodebuild macOS (Release, ad-hoc)"
    run_xcodebuild \
        -scheme BillLens-macOS \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        "${adhoc_signing_args[@]}" \
        build

    mkdir -p "$XCODE_DIST"
    rm -rf "$XCODE_DIST/BillLens.app"
    cp -R "$DERIVED_DATA/Build/Products/Release/BillLens.app" "$XCODE_DIST/BillLens.app"
    # ad-hoc 签名没有 Team ID，开启 Hardened Runtime 时库校验会拒绝加载 llama.framework，
    # 因此本机构建整体重签且不带 runtime；正式分发走 archive-mac 的团队签名。
    codesign --force --deep --sign - "$XCODE_DIST/BillLens.app"
    codesign --verify --deep --strict "$XCODE_DIST/BillLens.app"
    echo ""
    echo "Done: $XCODE_DIST/BillLens.app"
}

cmd_xcode_ios_sim() {
    build_rust_ios_sim
    xcode_generate

    echo "==> xcodebuild iOS Simulator (Debug)"
    run_xcodebuild \
        -scheme BillLens-iOS \
        -configuration Debug \
        -sdk iphonesimulator \
        -destination 'generic/platform=iOS Simulator' \
        CODE_SIGNING_ALLOWED=NO \
        build

    local app="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/BillLensIOSApp.app"
    if [[ -z "${SIMULATOR:-}" ]]; then
        echo ""
        echo "Done: $app"
        echo "设置 SIMULATOR=<模拟器名称或 UDID> 可自动安装并启动。"
        return
    fi

    echo "==> Install & launch on $SIMULATOR"
    xcrun simctl bootstatus "$SIMULATOR" -b
    open -a Simulator
    xcrun simctl install "$SIMULATOR" "$app"
    xcrun simctl launch "$SIMULATOR" com.shendongchun.BillLensApple
}

cmd_archive_ios() {
    export RUST_BUILD_MODE=release
    BUILD_MODE=release
    build_rust_ios
    xcode_generate

    local method="${IOS_EXPORT_METHOD:-debugging}"
    local archive="$XCODE_DIST/BillLensIOS.xcarchive"
    local export_dir="$XCODE_DIST/ios"
    local options="$XCODE_DIST/ExportOptions-ios.plist"
    mkdir -p "$XCODE_DIST"
    rm -rf "$archive" "$export_dir"

    echo "==> xcodebuild archive iOS (Release)"
    run_xcodebuild \
        -scheme BillLens-iOS \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath "$archive" \
        -allowProvisioningUpdates \
        archive

    echo "==> Export IPA (method=$method)"
    write_export_options "$options" "$method"
    xcodebuild -exportArchive \
        -archivePath "$archive" \
        -exportPath "$export_dir" \
        -exportOptionsPlist "$options" \
        -allowProvisioningUpdates

    echo ""
    echo "Done:"
    echo "  Archive: $archive"
    echo "  Export:  $export_dir"
}

cmd_archive_mac() {
    export RUST_BUILD_MODE=release
    BUILD_MODE=release
    build_rust_macos
    xcode_generate

    local method="${MAC_EXPORT_METHOD:-debugging}"
    local archive="$XCODE_DIST/BillLensMac.xcarchive"
    local export_dir="$XCODE_DIST/mac"
    local options="$XCODE_DIST/ExportOptions-mac.plist"
    mkdir -p "$XCODE_DIST"
    rm -rf "$archive" "$export_dir"

    echo "==> xcodebuild archive macOS (Release)"
    run_xcodebuild \
        -scheme BillLens-macOS \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -archivePath "$archive" \
        -allowProvisioningUpdates \
        archive

    echo "==> Export app (method=$method)"
    write_export_options "$options" "$method"
    xcodebuild -exportArchive \
        -archivePath "$archive" \
        -exportPath "$export_dir" \
        -exportOptionsPlist "$options" \
        -allowProvisioningUpdates

    echo ""
    echo "Done:"
    echo "  Archive: $archive"
    echo "  Export:  $export_dir"
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

Xcode workflow (project generated from apple/project.yml):
  xcode          Regenerate BillLensApple.xcodeproj and open it in Xcode
  xcode-mac      xcodebuild macOS Release, ad-hoc signed -> dist/xcode/BillLens.app
  xcode-ios-sim  xcodebuild iOS Simulator Debug; SIMULATOR=<name or UDID> installs and launches
  archive-ios    Archive + export iOS with automatic signing -> dist/xcode/ios/
  archive-mac    Archive + export macOS with automatic signing -> dist/xcode/mac/

Environment:
  RUST_BUILD_MODE=release   Switch to release mode (default: debug)
  IOS_EXPORT_METHOD         archive-ios export method (default: debugging; app-store-connect / release-testing)
  MAC_EXPORT_METHOD         archive-mac export method (default: debugging; developer-id / app-store-connect)
EOF
}

case "${1:-}" in
    dev)      cmd_dev ;;
    mac)      cmd_mac ;;
    ios-sim)  cmd_ios_sim ;;
    ios)      cmd_ios ;;
    all)      cmd_all ;;
    test)     cmd_test ;;
    xcode)         cmd_xcode ;;
    xcode-mac)     cmd_xcode_mac ;;
    xcode-ios-sim) cmd_xcode_ios_sim ;;
    archive-ios)   cmd_archive_ios ;;
    archive-mac)   cmd_archive_mac ;;
    *)        usage; exit 0 ;;
esac
