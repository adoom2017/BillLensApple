#!/bin/zsh
# Xcode Cloud 克隆仓库后执行：安装 Rust 并编译 Xcode 工程链接所需的 libbilllens_ffi 静态库。
# 工具链版本与目标由 rust/rust-toolchain.toml 固定，依赖版本由 rust/Cargo.lock 固定。
set -euo pipefail

: "${CI_PRIMARY_REPOSITORY_PATH:?仅在 Xcode Cloud 中运行}"
: "${CI_PRODUCT_PLATFORM:?缺少 CI_PRODUCT_PLATFORM}"
: "${CI_XCODEBUILD_ACTION:?缺少 CI_XCODEBUILD_ACTION}"

RUST_DIR="$CI_PRIMARY_REPOSITORY_PATH/rust"

# 与 project.yml 一致：archive 使用 Release 配置（链接 target/.../release），其余动作使用 Debug。
case "$CI_XCODEBUILD_ACTION" in
    archive) PROFILE=release; CARGO_PROFILE_FLAG=(--release) ;;
    build|build-for-testing|test-without-building|analyze) PROFILE=debug; CARGO_PROFILE_FLAG=() ;;
    *) echo "error: unsupported CI_XCODEBUILD_ACTION=$CI_XCODEBUILD_ACTION" >&2; exit 1 ;;
esac

# Xcode Cloud 构建机没有 Rust。
if ! command -v rustup >/dev/null 2>&1; then
    echo "==> Installing rustup"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --profile minimal --default-toolchain none --no-modify-path
fi
export PATH="$HOME/.cargo/bin:$PATH"

cd "$RUST_DIR"
# 读取 rust-toolchain.toml，安装固定版本与全部 Apple 目标。
rustup toolchain install
rustc --version

build_target() {
    echo "==> cargo build ($PROFILE) ${1:-host}"
    if [[ -n "${1:-}" ]]; then
        cargo build --locked -p billlens_ffi "${CARGO_PROFILE_FLAG[@]}" --target "$1"
    else
        cargo build --locked -p billlens_ffi "${CARGO_PROFILE_FLAG[@]}"
    fi
}

case "$CI_PRODUCT_PLATFORM" in
    macOS)
        build_target
        ;;
    iOS)
        # 构建与测试可能面向真机或模拟器，两个切片都准备好。
        build_target aarch64-apple-ios
        if [[ "$CI_XCODEBUILD_ACTION" != archive ]]; then
            build_target aarch64-apple-ios-sim
        fi
        ;;
    *)
        echo "error: unsupported CI_PRODUCT_PLATFORM=$CI_PRODUCT_PLATFORM" >&2
        exit 1
        ;;
esac

echo "==> Rust static libraries ready"
find "$RUST_DIR/target" -name libbilllens_ffi.a -path "*/$PROFILE/*" -print
