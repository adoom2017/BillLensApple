# 开发与运行

## 前置条件

| 工具 | 要求 |
|---|---|
| Rust / Cargo | 能构建 `billlens_ffi` |
| Xcode | 需要 Swift 6.1 toolchain，iOS 运行必须用 Xcode |
| Apple 平台 SDK | macOS 14+ / iOS 17+ |

## 环境变量

账单解析依赖 LLM。启动前至少准备这四个变量：

```bash
export LLM_BASE_URL=http://127.0.0.1:8080/v1
export LLM_API_KEY=
export LLM_MODEL=qwen-local
export LLM_PROVIDER=llamacpp
```

也可以在应用内「设置 -> LLM 连接配置」里修改。配置会落到本地 `app_settings`，不会同步到 CloudKit。

## 推荐入口

最简单的开发命令：

```bash
./build.sh dev
```

它会做三件事：

1. 编译 Rust FFI
2. 编译 macOS App
3. 组装并临时签名 `apple/build/dev/BillLens.app`，从 App Bundle 内启动

开发启动也必须经过 `.app` Bundle。直接运行 `.build/.../BillLensMacApp` 会被 macOS 视为普通 Unix 可执行文件，Dock 将显示默认 `exec` 图标，而且 Bundle 图标、资源和身份信息不完整。

## `build.sh` 子命令

| 命令 | 用途 |
|---|---|
| `./build.sh dev` | macOS 开发构建并启动 |
| `./build.sh mac` | macOS release 打包，输出 `.app` 和 `dist/BillLens.dmg` |
| `./build.sh ios-sim` | 编译 iOS 模拟器 Rust 库 |
| `./build.sh ios` | 编译 iPhone 真机 Rust 库 |
| `./build.sh all` | 编译所有平台 Rust 库 |
| `./build.sh test` | 跑 Rust 全量测试 |
| `./build.sh xcode` | 由 `apple/project.yml` 重新生成 Xcode 工程并打开 |
| `./build.sh xcode-mac` | xcodebuild 构建 macOS Release，临时签名，输出 `dist/xcode/BillLens.app` |
| `./build.sh xcode-ios-sim` | xcodebuild 构建 iOS 模拟器 Debug；设置 `SIMULATOR=<名称或 UDID>` 自动安装启动 |
| `./build.sh archive-ios` | Archive + 导出 iOS（自动签名），输出 `dist/xcode/ios/` |
| `./build.sh archive-mac` | Archive + 导出 macOS（自动签名），输出 `dist/xcode/mac/` |

`RUST_BUILD_MODE=release` 可切换 release：

```bash
RUST_BUILD_MODE=release ./build.sh ios-sim
```

## Xcode 工作流

`apple/project.yml` 是 Xcode 工程的唯一来源，`BillLensApple.xcodeproj` 由 XcodeGen 生成（`brew install xcodegen`）。
Info.plist 与 entitlements 直接使用 `apple/Sources/*/` 下的文件，改 Target 配置时改 `project.yml`，不要在 Xcode 里手改工程。

所有 `xcode-*` / `archive-*` 命令都会先编译对应平台的 Rust 静态库并重新生成工程：

| 场景 | 命令 | 签名 |
|---|---|---|
| 本机验证 macOS Release | `./build.sh xcode-mac` | ad-hoc，去掉 iCloud/推送 entitlements |
| iOS 模拟器 | `SIMULATOR="iPhone 18 Pro" ./build.sh xcode-ios-sim` | 不签名 |
| iOS 真机 / TestFlight | `IOS_EXPORT_METHOD=app-store-connect ./build.sh archive-ios` | 自动签名，Team `YH6JCRN97J` |
| macOS 分发 | `MAC_EXPORT_METHOD=developer-id ./build.sh archive-mac` | 自动签名 |

导出方式默认 `debugging`（开发签名）。Archive 需要 Xcode 已登录对应开发者账号；`-allowProvisioningUpdates` 会自动创建或更新描述文件。

## 手动构建

### macOS

```bash
cd rust
cargo build -p billlens_ffi

cd ../apple
swift build --product BillLensMacApp
swift run BillLensMacApp
```

### iOS

先准备 Rust 静态库：

```bash
./build.sh ios-sim
# 或
./build.sh ios
```

然后用 Xcode 打开：

```text
apple/BillLensApple.xcodeproj
```

不要直接拿 `swift build` 代替 iOS 运行，它默认只构建宿主 macOS target。  
如果你强行用 SwiftPM 带出 iOS target，需要显式设置：

- `BILLLENS_INCLUDE_IOS_SPM=1`
- `RUST_TARGET=ios-sim` 或 `RUST_TARGET=ios`

但日常 iOS 开发仍然建议直接走 Xcode。

## 仓库里的几个关键文件

| 文件 | 用途 |
|---|---|
| `build.sh` | 统一构建入口 |
| `apple/Package.swift` | SwiftPM 包定义；默认只构建 macOS app |
| `apple/project.yml` | Xcode 工程唯一来源（XcodeGen） |
| `apple/scripts/make_app_icon.swift` | 生成 macOS / iOS 全部尺寸图标与 `AppIcon.icns`：`cd apple && swift scripts/make_app_icon.swift` |
| `apple/BillLensApple.xcodeproj/` | 由 `./build.sh xcode` 生成，不手改 |
| `rust/migrations/` | SQLite 迁移 |

## 测试

当前自动化测试主要在 Rust：

```bash
cd rust
cargo test --workspace
```

Swift 侧目前没有独立 test target。UI 或共享视图改动至少要做：

1. `swift build`
2. 相关页面手动冒烟

## 数据位置

| 类型 | 路径 |
|---|---|
| SQLite | `~/Library/Application Support/BillLensApple/billlens.sqlite` |
| 日志 | `~/Library/Application Support/BillLensApple/billlens.log` |

## 常见问题

### 1. `swift build` 链接警告：Rust 库是用更高 macOS 版本构建的

现象类似：

```text
ld: warning: object file ... was built for newer 'macOS' version ...
```

这通常是 Rust 静态库和 Swift 目标的 deployment target 没对齐。处理方式是重编 Rust 库，并统一构建目标版本。

### 2. CloudKit 不工作

先检查：

- 是否用了带 entitlements 的 Xcode / 打包产物
- 当前设备是否登录了可用 iCloud
- 容器是否还是 `iCloud.com.shendongchun.BillLensApple`

Personal Team 不支持 CloudKit 和远程推送。iOS Debug 配置会明确设置
`BILLLENS_CLOUDKIT_ENABLED=NO` 并清空签名 entitlements，因此仍可测试本地模型、
SQLite、OCR 和后台模型下载，但不会创建 `CKContainer` 或注册远程通知。
具备完整开发者权限的 Release 配置必须同时满足：

- `BILLLENS_CLOUDKIT_ENABLED=YES`
- 签名 entitlements 包含目标 iCloud container 与 `CloudKit` service
- Provisioning Profile 支持 CloudKit 与 Push Notifications

### 3. iOS 工程打不开或 entitlements 不生效

优先打开：

```text
apple/BillLensApple.xcodeproj
```

不要把 `Package.swift` 当成 iOS 日常入口。
