# BillLens

账单智能录入与管理工具，支持 **macOS 14+** 和 **iOS 17+**，文本 / OCR / 语音三路输入，LLM 结构化解析，CloudKit 双端实时同步。

---

## 目录结构

```
BillLensApple/
├── rust/           Rust 核心：SQLite 持久化、LLM 解析、同步逻辑、C FFI
│   ├── crates/
│   │   ├── core/   业务逻辑、AppService
│   │   ├── db/     SQLite 读写（sqlx）
│   │   └── ffi/    C 接口 billlens_handle_request / billlens_free_string
│   └── migrations/ SQLite 迁移脚本
└── apple/          Swift / SwiftUI 界面
    └── Sources/
        ├── BillLensMacApp/         macOS 入口
        ├── BillLensIOSApp/         iOS 入口
        ├── BillLensShared/         SwiftUI 视图、状态、CloudKit 同步
        ├── BillLensAppleServices/  Vision OCR、Speech STT、日志
        └── CBillLensRustBridge/    C 头文件
```

---

## 前置依赖

| 工具 | 版本要求 | 安装 |
|---|---|---|
| Rust + Cargo | 1.78+ | `curl https://sh.rustup.rs -sSf \| sh` |
| Swift | 6.1+ (随 Xcode 15+) | Xcode / Command Line Tools |
| Xcode | 15+（iOS 构建必须） | App Store |
| xcodegen | 可选，重新生成 xcodeproj | `brew install xcodegen` |

---

## 环境变量

运行前需配置 LLM 后端（文本录入与 OCR 均依赖此配置）：

```bash
export LLM_BASE_URL=http://127.0.0.1:8080/v1   # LLM API 地址
export LLM_API_KEY=                              # 无鉴权时留空
export LLM_MODEL=qwen-local                      # 模型名
export LLM_PROVIDER=openai                     # openai | anthropic
```

也可在 App 内「设置 → LLM 配置」中修改，配置持久化至本地数据库。

---

## 快速开始（macOS 开发模式）

```bash
# 一键编译并运行
./build.sh dev
```

等价步骤：

```bash
cd rust && cargo build -p billlens_ffi
cd ../apple && swift build --product BillLensMacApp
$(swift build --show-bin-path -c debug)/BillLensMacApp
```

---

## 构建命令

统一入口：**`./build.sh <子命令>`**

| 子命令 | 说明 |
|---|---|
| `dev` | 编译 Rust（debug）+ 编译 macOS App（debug）并立即运行 |
| `mac` | 编译 Rust（release）+ 编译 macOS App（release）+ 打包 `.app` + 生成 `dist/BillLens.dmg` |
| `ios-sim` | 编译 iOS Simulator 用 Rust 静态库（`aarch64-apple-ios-sim`） |
| `ios` | 编译 iOS 真机用 Rust 静态库（`aarch64-apple-ios`） |
| `all` | 编译所有平台 Rust 静态库（macOS + ios + ios-sim） |
| `test` | 运行 Rust 单元测试 |

示例：

```bash
./build.sh dev        # 开发调试
./build.sh mac        # 打包 macOS 发行版
./build.sh ios-sim    # 为 Xcode iOS 模拟器准备 Rust 库
./build.sh test       # 跑全部单测
```

### Release 模式

所有子命令默认为 debug，加 `RUST_BUILD_MODE=release` 切换：

```bash
RUST_BUILD_MODE=release ./build.sh ios-sim
```

---

## iOS 运行（Xcode）

`swift build` 只能编译宿主平台（macOS），iOS 真机 / 模拟器需通过 Xcode：

1. 先编译 iOS 用 Rust 库：

   ```bash
   ./build.sh ios-sim   # 模拟器
   ./build.sh ios       # 真机
   ```

2. 生成 Xcode 项目（含 entitlements）：

   ```bash
   cd apple && xcodegen
   ```

3. 用 Xcode 打开 `apple/BillLensApple.xcodeproj`（**不要**打开 `Package.swift`，否则 entitlements 不生效）

4. Scheme 选 **BillLensIOSApp**，目标设备选模拟器或真机

5. 点击 ▶️ Run

Xcode Scheme → Run → Environment Variables 中可设置：

| 变量 | 说明 |
|---|---|
| `RUST_TARGET` | `ios-sim`（默认）或 `ios`，控制链接的 Rust 库路径 |
| `RUST_BUILD_MODE` | `debug`（默认）或 `release` |

---

## CloudKit 同步

macOS 与 iOS 通过 **CloudKit 私有库**自动双向同步：records / subscriptions / assets。LLM 配置等 app_settings 保持本地存储，避免同步 API key。

- 触发时机：App 启动、每次写操作（500ms 去抖）、CloudKit Silent Push
- 冲突策略：LWW（`sync_version + updated_at` 大者胜）
- 需要：相同 Apple ID 登录两台设备 + Apple Developer 账号（CloudKit 功能需真实 provisioning）
- 不可用时（未登录 iCloud）自动降级为纯本地模式

---

## 数据位置

| 文件 | 路径 |
|---|---|
| SQLite 数据库 | `~/Library/Application Support/BillLensApple/billlens.sqlite` |
| 日志 | `~/Library/Application Support/BillLensApple/billlens.log` |

---

## 运行测试

```bash
./build.sh test
# 或
cd rust && cargo test
```

当前覆盖：37 个测试，含同步 LWW、tombstone、cursor、脏标记等核心路径。
