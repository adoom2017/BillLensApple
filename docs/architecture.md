# BillLens 架构

## 系统概览

BillLens 是一套 **Rust 核心 + SwiftUI 前端** 的账单应用，当前同时支持 **macOS 14+** 和 **iOS 17+**。

核心链路：

```text
文本 / 票据图片 / 语音
  -> SwiftUI 视图
  -> BillLensStore
  -> RustBridge
  -> C FFI
  -> Rust AppService
  -> SQLite / LLM / CloudKit 同步
```

三种输入最终都会先变成 `RecordDraft`，用户确认后再写入正式账单。没有“猜一把再悄悄兜底”的降级路径。

## 仓库结构

```text
BillLensApple/
├── apple/
│   ├── Package.swift
│   ├── project.yml
│   ├── BillLensApple.xcodeproj/
│   └── Sources/
│       ├── BillLensMacApp/
│       ├── BillLensIOSApp/
│       ├── BillLensShared/
│       ├── BillLensAppleServices/
│       └── CBillLensRustBridge/
├── rust/
│   ├── crates/
│   │   ├── core/
│   │   ├── db/
│   │   └── ffi/
│   └── migrations/
├── docs/
├── AGENTS.md
└── README.md
```

### Swift 侧

| 路径 | 职责 |
|---|---|
| `apple/Sources/BillLensMacApp/` | macOS 入口、远程通知桥接、桌面打包资源 |
| `apple/Sources/BillLensIOSApp/` | iOS 入口、iOS 远程通知桥接 |
| `apple/Sources/BillLensShared/` | 跨平台共享视图、状态、CloudKit 同步、FFI 调用 |
| `apple/Sources/BillLensAppleServices/` | Vision OCR、Speech STT、日志 |
| `apple/Sources/CBillLensRustBridge/` | Swift 调 Rust 的 C 头文件 |

### Rust 侧

| 路径 | 职责 |
|---|---|
| `rust/crates/core/` | `AppService`、LLM 调用、汇率、订阅到期处理 |
| `rust/crates/db/` | SQLite 持久化、迁移后的领域模型、查询 |
| `rust/crates/ffi/` | 单入口 JSON FFI 协议，给 Swift 用 |
| `rust/migrations/` | 数据库迁移，当前到 `0009_drop_sync_outbox.sql` |

## 前端结构

共享 UI 都在 `BillLensShared`，所以视觉和交互改动会同时影响 macOS 和 iOS。

主视图：

```text
RootView
├── EntryShell
│   ├── ChatPanel
│   └── ReviewPanel
├── LedgerShell
├── SubscriptionShell
└── AssetShell
```

### 当前 UI 约束

- 视觉基底是 **Liquid Glass**，原生支持的平台走 `glassEffect`，旧平台走同一套回退材质。
- 半径统一收口在 `DesignTokens.swift` 的 `LayoutRadii`。
- 主要容器分三层：

| 层级 | Token |
|---|---|
| 页面外壳 | `LayoutRadii.shell` |
| 主要分区 / 大卡片 | `LayoutRadii.section` |
| 内容卡片 / 字段 / 小控件 | `LayoutRadii.card` / `field` / `compactField` / `micro` |

- 颜色、文字层级、玻璃强度都统一在 `DesignTokens.swift` 和 `SharedComponents.swift`。

## 业务流

### 账单录入

1. 用户输入文本、上传票据或开始语音。
2. Swift 侧把输入发给 Rust。
3. Rust 调 LLM，返回结构化结果。
4. 结构化结果先写成 `RecordDraft`。
5. 用户审核后确认入库，生成 `Record`。

### 图片录入

1. `ReceiptOCRService` 用 Vision 做 OCR。
2. OCR 文本继续走同一条 `submit_text` 解析链路。

### 语音录入

1. `SpeechCaptureService` 负责录音和实时转写。
2. 停止录音后把转写结果塞回输入框。
3. 后续仍然走文本解析链路。

### 订阅与资产

- 订阅支持周期规则、暂停/恢复、自动生成到期账单。
- 资产支持快照式余额记录与趋势展示。
- 两者都通过同一套 Rust FFI 协议增删改查。

## 状态与桥接

### `BillLensStore`

`BillLensStore` 是前端唯一状态源，负责：

- 启动时 `bootstrap`
- 刷新首页、账本、订阅、资产
- 草稿编辑和确认
- 触发 CloudKit 拉取 / 推送
- 读取和保存 LLM 配置

### `RustBridge`

Swift 不直接调用 Rust 结构体，而是统一走 JSON：

```text
[String: Any]
  -> JSONSerialization
  -> billlens_handle_request(...)
  -> JSONDecoder
  -> Codable 响应模型
```

这条边界当前只暴露两个 C 函数：

- `billlens_handle_request`
- `billlens_free_string`

## FFI 协议

所有请求都有一个 `action` 字段，Rust 侧在 `rust/crates/ffi/src/lib.rs` 分发。

高频动作：

| action | 用途 |
|---|---|
| `bootstrap` | 初始化数据库和运行时 |
| `home` | 读取首页消息、草稿、最新入库记录 |
| `submit_text` | 解析文本或 OCR 文本 |
| `save_draft` / `confirm_draft` / `discard_draft` | 草稿生命周期 |
| `ledger` | 拉取账本快照 |
| `list_subscriptions` / `update_subscription` | 订阅管理 |
| `list_assets` / `update_asset` | 资产管理 |
| `get_llm_config` / `update_llm_config` | 应用内模型配置 |
| `sync_list_dirty` / `sync_apply_remote` / `sync_mark_synced` | CloudKit 同步传输层 |
| `process_due_subscriptions` | 扫描并生成到期订阅账单 |

## 数据与同步

### SQLite

主库位置：

- 数据库：`~/Library/Application Support/BillLensApple/billlens.sqlite`
- 日志：`~/Library/Application Support/BillLensApple/billlens.log`

主要表：

| 表 | 用途 |
|---|---|
| `records` | 正式账单 |
| `record_drafts` | 待确认草稿 |
| `conversation_messages` | 对话历史 |
| `subscriptions` | 周期订阅 |
| `assets` | 资产主表 |
| `asset_snapshots` | 资产快照 |
| `app_settings` | 应用配置 |

### CloudKit

CloudKit 当前是**已接入**状态，不是占位稿。

- 容器在 `CloudKitSyncService.swift`
- 同步对象：`record`、`subscription`、`asset`、`asset_snapshot`
- 冲突处理主要由 Rust 侧的版本字段决定
- `llm_config` 不进云端，API Key 保持本地

历史上存在过 `sync_outbox`，但已在 `0009_drop_sync_outbox.sql` 删除，当前改为行级 `sync_version / synced_version` 水位

## 当前设计取舍

| 主题 | 取舍 |
|---|---|
| 错误处理 | 尽早暴露，不做静默 fallback |
| 前后端边界 | 用 JSON FFI，避免 Swift/Rust 结构直接绑死 |
| 输入流程 | 先草稿后确认，避免模型直接写库 |
| 跨平台 UI | 尽量共享 `BillLensShared`，减少双端分叉 |
| 云同步 | 凭据本地保存，同步只传业务数据 |
