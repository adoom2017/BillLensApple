# BillLensApple

独立于当前 Rust API 工程的 Apple 原生实现原型，支持 **macOS 14+** 和 **iOS 16+**。

目录说明：

- `rust/`：本地 Rust 核心、SQLite、同步预留表、JSON FFI
- `apple/`：SwiftUI 界面（macOS / iOS 统一代码库）、Vision OCR、Speech 语音转写

## 环境变量

```bash
export LLM_BASE_URL=http://127.0.0.1:8080/v1
export LLM_API_KEY=
export LLM_MODEL=qwen-local
export LLM_PROVIDER=llamacpp
```

## macOS 构建与运行

```bash
cd BillLensApple/rust
cargo build -p billlens_ffi

cd ../apple
swift build --target BillLensMacApp
swift run BillLensMacApp
```

## iOS 构建与测试

### 1. 编译 Rust 静态库（iOS 目标）

```bash
# iOS 模拟器（Apple Silicon Mac）
./apple/build-rust.sh ios-sim

# iOS 真机
./apple/build-rust.sh ios

# 同时构建所有平台
./apple/build-rust.sh all
```

`build-rust.sh` 支持的参数：`macos`（默认）、`ios-sim`、`ios`、`all`。  
`RUST_BUILD_MODE=release` 可切换为 release 构建。

### 2. 用 Xcode 运行 iOS 模拟器

`swift build` 只能在宿主机（macOS）上编译，iOS 真机 / 模拟器部署需要通过 Xcode：

1. 用 Xcode 打开 `apple/Package.swift`
2. Scheme 选择 **BillLensIOSApp**
3. 目标设备选择 **iPhone 模拟器**（如 iPhone 17 Pro）
4. 点击 ▶️ Run

`BillLensIOSApp` 的 Rust 静态库路径由 `RUST_TARGET` 环境变量控制（在 Xcode Scheme → Run → Arguments → Environment Variables 中设置）：

| `RUST_TARGET` 值 | 链接的静态库路径 |
|---|---|
| 未设置 / `ios-sim`（默认）| `rust/target/aarch64-apple-ios-sim/{mode}/` |
| `ios` | `rust/target/aarch64-apple-ios/{mode}/` |

> **注意**：`BillLensMacApp` 始终链接 `rust/target/{mode}/`，不受 `RUST_TARGET` 影响。

### iOS 与 macOS 布局差异

- **iPhone**：单栏布局，聊天与审核面板通过顶部分段选择器切换
- **iPad 横屏**：与 macOS 一致的双栏布局（聊天 + 审核并排）
- 聊天列表支持向下滑动关闭软键盘

## 说明

- 数据库默认写入 `~/Library/Application Support/BillLensApple/billlens.sqlite`
- 日志默认写入 `~/Library/Application Support/BillLensApple/billlens.log`，同时也会打印到控制台
- 当前同步只做本地 `sync_outbox` 预留，未接云端
- OCR 已接入 Vision；OCR 结果会继续送入与原工程一致的 LLM 结构化解析链路
- 文本录入与 OCR 录入都依赖 `LLM_BASE_URL / LLM_API_KEY / LLM_MODEL / LLM_PROVIDER`
- 语音转写已接入 Speech，但首次运行需要系统授权
