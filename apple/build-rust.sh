#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../rust"

# 默认 macOS 当前架构
PLATFORM="${1:-macos}"
BUILD_MODE="${RUST_BUILD_MODE:-debug}"

if [ "$BUILD_MODE" = "release" ]; then
    CARGO_FLAGS="--release"
else
    CARGO_FLAGS=""
fi

case "$PLATFORM" in
    macos)
        echo "Building for macOS..."
        cargo build -p billlens_ffi $CARGO_FLAGS
        ;;
    ios)
        echo "Building for iOS (aarch64-apple-ios)..."
        rustup target add aarch64-apple-ios 2>/dev/null || true
        IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build -p billlens_ffi $CARGO_FLAGS --target aarch64-apple-ios
        ;;
    ios-sim)
        echo "Building for iOS Simulator (aarch64-apple-ios-sim)..."
        rustup target add aarch64-apple-ios-sim 2>/dev/null || true
        IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build -p billlens_ffi $CARGO_FLAGS --target aarch64-apple-ios-sim
        ;;
    all)
        echo "Building for all platforms..."
        cargo build -p billlens_ffi $CARGO_FLAGS
        rustup target add aarch64-apple-ios aarch64-apple-ios-sim 2>/dev/null || true
        IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build -p billlens_ffi $CARGO_FLAGS --target aarch64-apple-ios
        IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build -p billlens_ffi $CARGO_FLAGS --target aarch64-apple-ios-sim
        ;;
    *)
        echo "Usage: $0 [macos|ios|ios-sim|all]"
        exit 1
        ;;
esac

echo "Build complete: platform=$PLATFORM mode=$BUILD_MODE"
