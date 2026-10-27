# 开发与运行

## 工具与平台

| 工具 / 平台 | 要求 |
|---|---|
| Xcode | 提供 Swift 6.1+ 与 Apple SDK；`xcode-select -p` 指向完整 Xcode |
| Rust / Cargo / rustup | 构建 `billlens_ffi`；脚本安装 iOS arm64 target |
| XcodeGen | `brew install xcodegen` |
| 部署目标 | macOS 14+、iOS 17+ |
| 构建主机 | Apple Silicon；macOS 工程与 iOS 模拟器配置使用 arm64 |

SwiftPM 会获取固定 URL 和 checksum 的 llama.cpp b9632 XCFramework。首次构建需要网络；GGUF 权重不参与构建。

## 应用名称与本地化

产品名称为 **Billumi**，中文宣传语为“一句话记账，一眼看清收支”。iOS 与 macOS 共用 `apple/Resources/` 下的 `InfoPlist.strings`：

| 应用语言 | 显示名称 |
|---|---|
| 简体中文（`zh-Hans`） | 账映 |
| 繁体中文（`zh-Hant`） | 帳映 |
| 英语及其他未提供翻译的语言 | Billumi |

名称与麦克风、语音识别权限提示由系统本地化机制选择；用户为 App 单独设置语言时，以应用语言为准。此处仅本地化名称与权限提示，不代表其他界面已完成多语言翻译。修改资源或配置后重新生成 Xcode 工程，再构建并检查实际 App 产物。

`PRODUCT_NAME` 决定安装包及可执行文件名，两端均为 `Billumi`。Bundle ID、CloudKit 容器、数据库及模型目录、设备标识、后台会话标识继续使用原有值，保证升级后的数据与同步身份连续。工程、scheme、Swift 模块及 Rust FFI 保留 `BillLens` 内部名称。App Store 页面上的本地化名称与副标题需另外在 App Store Connect 配置。

## 启动与模型配置

```bash
./build.sh dev
```

该命令固定构建 Rust Debug 与 Xcode Debug，以不含受限 entitlement 的 ad-hoc 签名通过 `open -W -n` 启动 App。退出 App 后命令结束。直接运行 `.app/Contents/MacOS/` 内二进制不能替代 LaunchServices，键盘焦点和权限归属可能异常。

启动不要求预先配置模型。设置页可下载本地模型，或保存独立的云端配置；能完整匹配规则的单笔文本不需要模型。

| 变量 | 合同 |
|---|---|
| `LLM_BASE_URL` | HTTP(S) API 基址 |
| `LLM_MODEL` | 非空模型 ID |
| `LLM_PROVIDER` | `openai`、`openai_compatible`、`llamacpp`、`anthropic`，或代码支持的 OpenAI 兼容别名 |
| `LLM_API_KEY` | 可省略或为空，供无需鉴权的本地服务使用 |

四个变量全部未设置时不注入云端配置；只设置部分时，基址、模型和 provider 仍必须完整。例：

```bash
export LLM_BASE_URL=http://127.0.0.1:8080/v1
export LLM_MODEL=qwen-local
export LLM_PROVIDER=llamacpp
export LLM_API_KEY=
./build.sh dev
```

App 经 LaunchServices 启动，不能假定会继承终端环境变量。日常使用优先在设置页填写配置；验证环境变量注入时应先检查启动后的设置与日志。已有本地配置优先于环境变量；环境配置只在数据库尚无配置时写入。配置保存到 SQLite 的 `app_settings`，不通过 CloudKit 同步；它不是 Keychain 加密存储。不要提交包含真实密钥的环境文件、数据库或 HTTP 请求文件。

云端 thinking 模式通过设置页显式选择；未设置时保留 provider 默认行为。模型把思考文本混入 JSON 时会报合同错误，不会自动删除该文本。

## 构建命令

所有命令从仓库根目录运行。

| 命令 | 行为与输出 |
|---|---|
| `./build.sh dev` | macOS Debug，`apple/build/DerivedData/Build/Products/Debug/Billumi.app`，构建并启动 |
| `./build.sh mac` | 复用 `xcode-mac` 生成 Release App，并打包 `dist/Billumi.dmg` |
| `./build.sh ios-sim` | Rust `aarch64-apple-ios-sim` 静态库 |
| `./build.sh ios` | Rust `aarch64-apple-ios` 静态库 |
| `./build.sh all` | macOS、iOS 模拟器、iOS 真机三份 Rust 库 |
| `./build.sh test` | Rust workspace 测试 |
| `./build.sh xcode` | 重新生成工程并打开 Xcode |
| `./build.sh xcode-mac` | macOS Release、ad-hoc 签名，`dist/xcode/Billumi.app` |
| `./build.sh xcode-ios-sim` | iOS 模拟器 Debug；设置 `SIMULATOR=<名称或 UDID>` 时安装启动 |
| `./build.sh archive-ios` | iOS Release archive 与自动签名导出，`dist/xcode/ios/` |
| `./build.sh archive-mac` | macOS Release archive 与自动签名导出，`dist/xcode/mac/` |

`RUST_BUILD_MODE` 只接受 `debug` / `release`。Rust 单独构建命令及 `all` 使用该值；`dev`、`xcode-ios-sim` 固定 Debug，`mac`、`xcode-mac`、`archive-*` 固定 Release，保证静态库路径与 Xcode configuration 一致。

`apple/project.yml` 是工程唯一来源，`BillLensApple.xcodeproj` 由 XcodeGen 生成并纳入版本控制。修改 target 配置后重新生成工程，不在 Xcode 手工修改生成结果。Info.plist 与 entitlements 来源均在 `apple/Sources/`。

### SwiftPM 编译与测试

```bash
cd rust
cargo build -p billlens_ffi
cd ../apple
swift build
swift test
```

SwiftPM 默认构建宿主 macOS，不是 iOS 启动入口。高级 iOS SwiftPM 使用需设置 `BILLLENS_INCLUDE_IOS_SPM=1` 与合法 `RUST_TARGET=ios|ios-sim`，并指定实际 SDK 和 target；日常使用 Xcode。

受限执行环境中若默认缓存目录不可写，可使用临时缓存路径：

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/billlens-clang-cache \
swift test --disable-sandbox \
  --cache-path /private/tmp/billlens-swift-cache \
  --config-path /private/tmp/billlens-swift-config \
  --security-path /private/tmp/billlens-swift-security
```

`--disable-sandbox` 仅用于宿主沙盒不允许 SwiftPM 嵌套 sandbox-exec 的环境。

## Xcode Cloud

云端构建机没有 Rust。`apple/ci_scripts/ci_post_clone.sh` 在克隆后安装 rustup，并按 Xcode Cloud 的
`CI_PRODUCT_PLATFORM` 与 `CI_XCODEBUILD_ACTION` 编译工程链接所需的 `libbilllens_ffi.a`：

| 平台 | `archive` | 其他动作（build / test） |
|---|---|---|
| iOS | `aarch64-apple-ios` release | `aarch64-apple-ios` + `aarch64-apple-ios-sim` debug |
| macOS | `aarch64-apple-darwin` release | `aarch64-apple-darwin` debug |

- 工具链版本与目标固定在 `rust/rust-toolchain.toml`，依赖版本固定在已提交的 `rust/Cargo.lock`（脚本使用 `--locked`）。升级依赖后需提交新的 `Cargo.lock`。
- 工作流选择 `BillLens-iOS` / `BillLens-macOS` scheme。
- 本地验证脚本：`CI_PRIMARY_REPOSITORY_PATH=$PWD CI_PRODUCT_PLATFORM=iOS CI_XCODEBUILD_ACTION=archive ./apple/ci_scripts/ci_post_clone.sh`

## 签名与 CloudKit

| 构建方式 | CloudKit |
|---|---|
| macOS `dev` / `mac` / `xcode-mac` | ad-hoc，不携带 iCloud / 推送 entitlement，不用于同步验证 |
| iOS Debug | `BILLLENS_CLOUDKIT_ENABLED=NO`，无受限 entitlement |
| iOS Release / 正式 macOS Archive | 需要完整开发者权限、正确容器和 provisioning profile |

iOS 分享扩展（`com.shendongchun.BillLensApple.ShareExtension`）与主 App 通过 App Group `group.com.shendongchun.BillLensApple` 交换账单文件，该 entitlement 只在 Release 配置中声明。Debug 构建不带 App Group，扩展会提示「当前安装的版本不支持分享导入」，App 内文件导入不受影响。首次 Archive 依赖 `-allowProvisioningUpdates` 为 App 与扩展注册 App Group 和 profile。

容器为 `iCloud.com.shendongchun.BillLensApple`，工程中的 Team 为 `YH6JCRN97J`。其他开发者应在 `project.yml` 配置自己的签名身份和匹配容器后重新生成工程。

导出默认 `debugging`；可设置 `IOS_EXPORT_METHOD=app-store-connect` 或 `MAC_EXPORT_METHOD=developer-id`。Archive 使用 `-allowProvisioningUpdates`，要求 Xcode 已登录具备相应能力的开发者账号。

### macOS 正式签名

| 用途 | 命令 | 产物 |
|---|---|---|
| 本机或已注册的 Mac | `./build.sh archive-mac` | `dist/xcode/mac/Billumi.app`（开发签名） |
| 分发给任何 Mac（推荐） | `MAC_EXPORT_METHOD=developer-id NOTARY_PROFILE=<名称> ./build.sh archive-mac` | 已公证、已钉票据的 App、`dist/xcode/Billumi-mac.zip` 与 `dist/xcode/Billumi.dmg`（DMG 单独签名、公证并钉票据） |
| Mac App Store / TestFlight | `MAC_EXPORT_METHOD=app-store-connect ./build.sh archive-mac` | 需先开启 App Sandbox |

- Developer ID 分发需要公证，先保存一次凭据：`xcrun notarytool store-credentials <名称> --apple-id <Apple ID> --team-id YH6JCRN97J`（密码使用 appleid.apple.com 生成的 App 专用密码）。
- macOS 推送权限键是 `com.apple.developer.aps-environment`（iOS 是 `aps-environment`）；导出分发版本时 Xcode 自动改为 production。
- 正式签名版本使用 CloudKit **Production** 环境，需先在 CloudKit Console 把 schema 部署到 Production。

## 检查与冒烟

```bash
cd rust
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cd ..
zsh -n build.sh
./build.sh all
cd apple
swift build
swift test
```

Swift 测试分为 `BillLensAppleServicesTests`（清单、下载配置、运行时、FFI 内存）与 `BillLensSharedTests`（同步页面、响应可空值、提醒日期）。Rust 测试覆盖解析、规则时间、路由、数据库迁移、事务回滚、订阅与同步。

信用卡账单导入可用本机真实账单核对（只输出计数与勾稽结果，真实文件已被 `.gitignore` 排除，不得提交）：

```bash
cd rust
BILLLENS_CMB_SAMPLE_EML=/path/账单.eml BILLLENS_CMB_SAMPLE_PDF_TEXT=/path/pdf.txt \
  cargo test -p billlens-apple-core real_cmb -- --ignored --nocapture
```

iOS UI 冒烟测试（`apple/Tests/BillLensIOSUITests`）在模拟器上手动新增 / 编辑账单、订阅、资产。建议使用一台专用模拟器并先清空，避免污染日常调试数据：

```bash
./build.sh xcode-ios-sim   # 构建 Rust 模拟器库并生成工程
UDID=$(xcrun simctl create "BillLens UITest" "iPhone 18 Pro")
cd apple && xcodebuild test -project BillLensApple.xcodeproj -scheme BillLens-iOS \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO
xcrun simctl delete "$UDID"
```

跨层改动还须构建 iOS 模拟器。人工冒烟检查文本/OCR、三类草稿保存与确认、订阅重复检查、时区切换。真实模型下载/取消/更新、iOS 后台恢复、语音权限与录音、CloudKit 多设备冲突必须使用对应设备与签名环境验证；自动化通过不替代这些检查。

## 数据与清理

| 内容 | 位置 |
|---|---|
| 数据库 | `Application Support/BillLensApple/billlens.sqlite` |
| 日志 | `Application Support/BillLensApple/billlens.log` |
| 权重 / 下载状态 | `Application Support/BillLensApple/LocalModels/` |
| Rust 构建产物 | `rust/target/` |
| SwiftPM 产物 | `apple/.build/` |
| Xcode 产物 | `apple/build/` |
| 分发产物 | `dist/` |

macOS 非沙盒运行的 Application Support 为 `~/Library/Application Support/`；iOS 及沙盒构建使用各自容器。删除构建产物可重新编译，不要把运行数据目录当缓存删除。SQLite 迁移只能升级；测试旧版本或回滚 App 前应另行备份数据库及 WAL 文件。

本地模型合同错误的诊断日志可能包含完整模型输出，分享日志前需检查票据信息。API Key 不应写入日志。

## 排错

| 问题 | 检查 |
|---|---|
| Swift 链接找不到 Rust 库 | 先构建对应 target 和 Debug/Release 库，检查 `OTHER_LDFLAGS` |
| macOS deployment target 警告 | Rust `.cargo/config.toml` 与 Xcode/SwiftPM 均需 macOS 14 |
| iOS 模拟器/设备链接混用 | 分别链接 `aarch64-apple-ios-sim` / `aarch64-apple-ios`，不能互换 |
| CloudKit 不启动 | 检查 build flag、实际签名 entitlement、容器、iCloud 账号；ad-hoc/Personal Debug 不具备同步能力 |
| 模型下载失败 | 保留日志中的错误域、错误码和底层原因；大小或摘要不匹配直接失败，不切换镜像 |
| 图标需要更新 | `cd apple && swift scripts/make_app_icon.swift` 后重新构建 |
