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
3. 直接启动 `BillLensMacApp`

## `build.sh` 子命令

| 命令 | 用途 |
|---|---|
| `./build.sh dev` | macOS 开发构建并启动 |
| `./build.sh mac` | macOS release 打包，输出 `.app` 和 `dist/BillLens.dmg` |
| `./build.sh ios-sim` | 编译 iOS 模拟器 Rust 库 |
| `./build.sh ios` | 编译 iPhone 真机 Rust 库 |
| `./build.sh all` | 编译所有平台 Rust 库 |
| `./build.sh test` | 跑 Rust 全量测试 |

`RUST_BUILD_MODE=release` 可切换 release：

```bash
RUST_BUILD_MODE=release ./build.sh ios-sim
```

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
| `apple/project.yml` | XcodeGen 输入 |
| `apple/BillLensApple.xcodeproj/` | 已生成的 Xcode 工程 |
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

### 3. iOS 工程打不开或 entitlements 不生效

优先打开：

```text
apple/BillLensApple.xcodeproj
```

不要把 `Package.swift` 当成 iOS 日常入口。
