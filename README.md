# Billumi · 账映

一句话记账，一眼看清收支。

Rust 核心 + SwiftUI 前端的个人账单应用，支持 macOS 14+ 和 iOS 17+。构建脚本面向 Apple Silicon Mac。

- 文本、票据 OCR、语音转写录入；明确的单笔文本可由规则直接解析。
- 可下载 Qwen 0.8B / 2B 本地模型，也可配置 OpenAI 兼容或 Anthropic 云端服务。
- 本地模型结果始终待确认；规则与云端账单、订阅遵循“自动保存”设置。云端资产解析直接更新快照。
- 账本、周期订阅、资产快照；具备签名能力时通过 CloudKit 同步业务数据。

## 开始开发

需要 Xcode（Swift 6.1+）、Rust / Cargo、XcodeGen（`brew install xcodegen`）。从仓库根目录运行：

```bash
./build.sh dev
```

启动后在设置中下载本地模型或配置云端服务。能完整匹配规则的文本无需模型，例如“今天早上打车花了30元”。App 不内置 GGUF 权重。云端连接也可通过 `LLM_BASE_URL`、`LLM_MODEL`、`LLM_PROVIDER` 和可选 `LLM_API_KEY` 配置，详见开发文档。

| 命令 | 用途 |
|---|---|
| `./build.sh dev` | 构建并通过 LaunchServices 启动 macOS Debug App |
| `./build.sh mac` | macOS Release App 与 DMG |
| `./build.sh xcode-ios-sim` | 构建 iOS 模拟器 App |
| `./build.sh test` | Rust 全量测试 |
| `cd apple && swift test` | Swift 服务和共享层合同测试，需先构建 macOS Rust 库 |

## 代码与文档

| 路径 | 内容 |
|---|---|
| `apple/` | SwiftUI、平台入口、本地模型、CloudKit、OCR、Speech |
| `rust/` | 解析规则、云端路由、业务事务、SQLite、C FFI |
| [架构](docs/architecture.md) | 解析来源、保存语义、数据库与同步合同 |
| [开发与运行](docs/development.md) | 配置、构建、测试、签名、数据位置与排错 |
| [审查记录](docs/review.md) | 已修复问题、清理依据、验证边界 |
| [文档索引](docs/README.md) | 完整文档入口 |
| [AGENTS.md](AGENTS.md) | 项目开发约定；[CLAUDE.md](CLAUDE.md) 引用同一份规则 |
