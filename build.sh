#!/bin/zsh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_MODE="${RUST_BUILD_MODE:-debug}"
case "$BUILD_MODE" in
    debug|release) ;;
    *) echo "error: RUST_BUILD_MODE must be debug or release" >&2; exit 1 ;;
esac

# ---- helpers ----

rust_flags() {
    [[ "$BUILD_MODE" == "release" ]] && echo "--release" || echo ""
}

build_rust_macos() {
    echo "==> Rust macOS ($BUILD_MODE)"
    cd "$REPO_ROOT/rust"
    cargo build -p billlens_ffi $(rust_flags)
}

build_rust_ios_sim() {
    echo "==> Rust iOS Simulator ($BUILD_MODE)"
    rustup target add aarch64-apple-ios-sim
    cd "$REPO_ROOT/rust"
    IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build -p billlens_ffi $(rust_flags) --target aarch64-apple-ios-sim
}

build_rust_ios() {
    echo "==> Rust iOS device ($BUILD_MODE)"
    rustup target add aarch64-apple-ios
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
    BUILD_MODE=debug
    export RUST_BUILD_MODE=debug
    build_rust_macos
    xcode_generate

    # 与 xcode-mac 同一条 xcodebuild 链路（Debug 配置）：Info.plist、资源与 Bundle ID 都来自工程。
    echo "==> xcodebuild macOS (Debug, ad-hoc)"
    run_xcodebuild \
        -scheme BillLens-macOS \
        -configuration Debug \
        -destination 'generic/platform=macOS' \
        "${adhoc_signing_args[@]}" \
        build

    local app="$DERIVED_DATA/Build/Products/Debug/BillLens.app"
    # ad-hoc 签名没有 Team ID：整体重签且不开 Hardened Runtime，否则 llama.framework 会被库校验拒绝。
    codesign --force --deep --sign - "$app"

    echo "==> Launching $app"
    # 必须经 LaunchServices 启动：直接执行 Contents/MacOS 下的二进制会成为终端的子进程，
    # 无法正常激活窗口，麦克风/语音权限也会记到终端名下。-W 等待 App 退出，-n 总是启动新实例。
    echo "    log: $HOME/Library/Application Support/BillLensApple/billlens.log"
    open -W -n "$app"
}

cmd_mac() {
    cmd_xcode_mac
    local dmg="$REPO_ROOT/dist/BillLens.dmg"
    echo "==> Creating DMG"
    rm -f "$dmg"
    hdiutil create -volname BillLens -srcfolder "$XCODE_DIST/BillLens.app" -ov -format UDZO "$dmg"
    echo "Done: $dmg"
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
    BUILD_MODE=debug
    export RUST_BUILD_MODE=debug
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
  dev       xcodebuild Debug + run macOS app (ad-hoc signed, via LaunchServices)
  mac       xcodebuild Release + create dist/BillLens.dmg (app: dist/xcode/BillLens.app)
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
    ""|-h|--help) usage ;;
    *)        usage >&2; exit 1 ;;
esac
