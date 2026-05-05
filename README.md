# BillLens

BillLens 是一个 **Rust 核心 + SwiftUI 前端** 的个人账单应用，当前支持 **macOS 14+** 和 **iOS 17+**。  
输入路径支持文本、票据 OCR、语音转写，结构化解析后先生成草稿，再由用户确认入库。CloudKit 用于双端同步业务数据，LLM 凭据保持本地。

## 当前能力

- 文本、OCR、语音三路录入
- 草稿审核后确认入库
- 账本日历 / 明细视图
- 订阅管理与到期自动记账
- 资产与快照管理
- macOS / iOS 共用一套 `BillLensShared` UI
- Liquid Glass 视觉系统与统一圆角 token

## 仓库结构

```text
BillLensApple/
├── apple/    SwiftUI、平台入口、CloudKit、OCR、STT
├── rust/     核心业务、SQLite、LLM、FFI
├── docs/     人类可读文档
├── AGENTS.md
└── README.md
```

## 快速开始

先准备 LLM 环境变量：

```bash
export LLM_BASE_URL=http://127.0.0.1:8080/v1
export LLM_API_KEY=
export LLM_MODEL=qwen-local
export LLM_PROVIDER=llamacpp
```

本地开发直接跑：

```bash
./build.sh dev
```

常用命令：

```bash
./build.sh dev
./build.sh mac
./build.sh ios-sim
./build.sh test
```

## 文档入口

- [docs/README.md](docs/README.md)：文档索引
- [docs/architecture.md](docs/architecture.md)：系统架构、数据流、同步、UI 结构
- [docs/development.md](docs/development.md)：环境变量、构建、iOS 运行、常见问题

## Agent 入口

- [AGENTS.md](AGENTS.md)：Codex / 通用 agent 项目规则
- [CLAUDE.md](CLAUDE.md)：Claude 入口，指向同一套规则
