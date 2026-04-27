# BillLensApple Architecture

> 一个 Rust + Swift 混合架构的 macOS 个人账单应用，通过 LLM 将自然语言解析为结构化账单记录。

---

## 总体架构

```
用户输入 (文字 / 图片 / 语音)
    ↓
SwiftUI (BillLensShared)
    → BillLensStore (@MainActor, ObservableObject)
        → RustBridge (JSON 序列化)
            → C FFI: billlens_handle_request()
                → AppService (Rust)
                    → LLM HTTP API (OpenAI-compatible / Anthropic)
                    → BillRepository → SQLite (SQLx)
```

---

## 目录结构

```
BillLensApple/
├── apple/
│   ├── Package.swift
│   └── Sources/
│       ├── BillLensMacApp/          # macOS 入口，链接 libbilllens_ffi
│       ├── BillLensIOSApp/          # iOS 入口 (BILLLENS_INCLUDE_IOS_SPM=1)
│       ├── BillLensShared/          # SwiftUI 视图 + 状态 + 桥接
│       │   ├── RootView.swift       # 主导航 + 标签路由
│       │   ├── BillLensStore.swift  # 全局状态 (ObservableObject)
│       │   ├── RustBridge.swift     # JSON 请求/响应封装
│       │   ├── EngineModels.swift   # Swift Codable 模型 (对应 Rust 枚举)
│       │   ├── EntryViews.swift     # 聊天面板 + 草稿审核
│       │   ├── LedgerViews.swift    # 账本 + 日历视图
│       │   ├── SubscriptionViews.swift
│       │   ├── AssetViews.swift
│       │   ├── SettingsViews.swift
│       │   ├── SharedComponents.swift # 可复用 UI 组件
│       │   ├── DesignTokens.swift   # 颜色 + 布局常量
│       │   ├── CloudKitSyncService.swift
│       │   └── Formatters.swift
│       ├── BillLensAppleServices/   # 平台服务
│       │   ├── ReceiptOCRService.swift   # Vision OCR
│       │   ├── SpeechCaptureService.swift # Speech STT
│       │   ├── SpeechFFIExports.swift    # 向 Rust 导出 C 回调
│       │   └── AppLogger.swift
│       └── CBillLensRustBridge/     # C 头文件
│           └── billlens_ffi.h
├── rust/
│   ├── Cargo.toml                   # workspace
│   ├── migrations/                  # SQLx 迁移文件 (0001~0008)
│   └── crates/
│       ├── core/                    # 业务逻辑
│       │   ├── lib.rs              # AppService
│       │   ├── llm.rs             # LLM 客户端 + 提示词
│       │   ├── stt.rs             # STT 会话
│       │   └── fx.rs              # 汇率查询
│       ├── db/                      # 数据持久层
│       │   ├── lib.rs             # BillRepository
│       │   └── models.rs          # DB 数据模型
│       └── ffi/
│           └── lib.rs              # C FFI 入口
└── CLAUDE.md
```

---

## Swift 层

### BillLensStore

`@MainActor ObservableObject`，所有 UI 状态的唯一来源。

**关键 @Published 属性：**

| 属性 | 类型 | 用途 |
|------|------|------|
| `messages` | `[ConversationMessage]` | 聊天历史 |
| `drafts` | `[RecordDraft]` | 待审核草稿 |
| `activeDraftIndex` | `Int` | 当前草稿下标 |
| `ledger` | `LedgerSnapshot?` | 账本快照 |
| `subscriptions` | `[SubscriptionItem]` | 订阅列表 |
| `assets` | `[AssetItem]` | 资产列表 |
| `isBusy` | `Bool` | 请求进行中 |
| `draftForm` | `DraftFormState` | 草稿编辑表单 |
| `llmConfig` | `LlmConfigItem?` | LLM 配置 |

**主要 Actions：**

| Action | 说明 |
|--------|------|
| `bootstrap()` | 初始化 DB、加载数据、触发 CloudKit 同步 |
| `submitText()` | 发送文字到 LLM 解析 |
| `importReceipt(url:)` | OCR 图片 → LLM 解析 |
| `toggleRecording()` | 语音识别开/关 |
| `saveDraft()` / `confirmDraft()` / `discardDraft()` | 草稿生命周期 |
| `deleteRecord(recordId:)` | 软删除已确认账单 |
| 订阅/资产 CRUD | `loadSubscriptions`, `updateAsset`, 等 |

### RustBridge

```swift
public struct RustBridge {
    public func send<Response: Decodable>(_ payload: [String: Any]) throws -> Response
    public func sendAsync<Response: Decodable>(_ payload: [String: Any]) async throws -> Response
}
```

序列化 Swift Dictionary → JSON → `billlens_handle_request()` → 反序列化 Response。

### UI 视图层级

```
RootView
├── AppHeader (导航栏 + 状态标签 + 设置)
└── 标签页路由 (AppPage)
    ├── EntryShell
    │   ├── ChatPanel (聊天历史 + 输入框)
    │   └── ReviewPanel (草稿编辑 + 确认)
    ├── LedgerShell
    │   ├── 日历视图 (月/年)
    │   └── 按天分组的账单列表
    ├── SubscriptionShell (订阅管理)
    └── AssetShell (资产 + 快照)
```

**布局策略：**
- macOS / iPad 横屏：聊天面板 + 审核面板并排显示
- iPhone / iPad 竖屏：标签 + Sheet 展示详情
- macOS 最小窗口：1120×720px

### Design Tokens

```swift
enum IMColors {
    static let accent = Color(red: 0.161, green: 0.447, blue: 0.584)   // 主品牌色
    static let danger = Color(red: 0.765, green: 0.286, blue: 0.306)   // 红色/支出
    static let income = textPrimary                                      // 深色/收入
    static let chatBg, userBubble, botBubble, panelBg, surface          // 面板/气泡
    static let pageBgTop/Mid/Bottom                                      // 页面渐变背景
}

enum LayoutMetrics {
    static let pagePadding: CGFloat = 14
    static let bubbleRadius: CGFloat = 22
    static let avatarSize: CGFloat = 32
}
```

---

## Rust 层

### AppService (core/lib.rs)

业务逻辑核心，持有 `BillRepository`、`LlmClient`、`FxClient`。

```rust
pub struct AppService {
    repo: BillRepository,
    device_id: String,
    llm: Option<LlmClient>,
    fx: FxClient,
}
```

**核心方法：**

| 方法 | 说明 |
|------|------|
| `home()` | 加载聊天记录 + 草稿 + 账本快照 |
| `submit_text()` | 调用 LLM 解析文本，生成草稿 |
| `save_draft()` / `confirm_draft()` | 保存/确认草稿，生成 Record |
| `process_due_subscriptions()` | 检查并生成到期订阅账单 |
| Sync 方法 | `sync_list_dirty`, `sync_mark_synced`, `sync_apply_remote` |

### FFI 接口 (ffi/lib.rs)

所有 Swift ↔ Rust 通信通过一个 JSON 接口进行：

```c
// C 接口（Swift 调用）
char *billlens_handle_request(const char *request_json);
void billlens_free_string(char *value);

// STT 回调（Swift 实现，Rust 调用）
void billlens_register_stt_backend(start_fn, stop_fn, cancel_fn, free_fn);
```

**请求格式：** JSON object，`action` 字段区分请求类型（snake_case）。

**响应格式：**
```json
{
  "ok": true,
  "data": { ... },
  "error": null
}
```

### 完整请求类型表

| action | 参数 | 返回 |
|--------|------|------|
| `bootstrap` | database_path, profile_id, device_id, llm, log_file_path | HomeSnapshot |
| `home` | profile_id | HomeSnapshot |
| `submit_text` | profile_id, content, auto_confirm, source | SubmitTextResult |
| `save_draft` | profile_id, draft_id, draft | SaveDraftResult |
| `confirm_draft` | profile_id, draft_id | SaveDraftResult |
| `discard_draft` | profile_id, draft_id | HomeSnapshot |
| `confirm_all_drafts` | profile_id | HomeSnapshot |
| `delete_record` | profile_id, record_id | — |
| `ledger` | profile_id, preset, start_at, end_at | LedgerSnapshot |
| `stt_start` / `stt_stop` / `stt_cancel` | profile_id | — / transcript |
| `list_subscriptions` | profile_id | Vec\<Subscription\> |
| `update_subscription` | profile_id, subscription_id, update | Subscription |
| `pause_subscription` / `resume_subscription` / `delete_subscription` | ... | ... |
| `list_assets` | profile_id | Vec\<AssetWithSnapshots\> |
| `update_asset` / `delete_asset` / `delete_asset_snapshot` | ... | ... |
| `get_llm_config` / `update_llm_config` | ... | LlmConfigItem |
| `sync_list_dirty` / `sync_mark_synced` / `sync_apply_remote` | ... | ... |
| `process_due_subscriptions` | profile_id | — |

---

## 数据模型

### 核心模型

```swift
struct RecordItem {
    id: String (UUID)
    direction: "income" | "expense"
    amount: Double
    currency: String        // ISO 4217，默认 CNY
    category: String
    merchant: String?
    transactionAt: String   // RFC3339
    note: String?
    syncVersion: Int        // CloudKit 同步版本
    deletedAt: String?      // 软删除
}

struct RecordDraft {
    id, profileId: String
    content: String          // 用户原始输入
    status: "parsed" | "confirmed" | "discarded"
    confirmedRecordId: String?
    // 以下字段可为 nil（解析失败时）
    direction, amount, currency, category, merchant, transactionAt, note
}

struct SubscriptionItem {
    cycle: "monthly" | "yearly"
    anchorDay: Int           // 每月第几天
    anchorMonth: Int?        // 仅 yearly 时有值
    nextDueAt: String        // 下次到期时间
    isActive: Bool
}

struct AssetItem {
    name: String             // 如"招商银行"
    category: String         // 存款|现金|股票|基金|加密货币|房产|其他
    snapshots: [AssetSnapshotItem]
    latestAmount: Double?
}

struct AssetSnapshotItem {
    assetId: String
    amount: Double
    recordedOn: String       // YYYY-MM-DD
}
```

### 分类体系

| 类型 | 分类 |
|------|------|
| **支出** | 餐饮, 交通, 日用, 购物, 住房, 医疗, 娱乐, 教育, 通讯, 人情, 订阅, 其他 |
| **收入** | 工资收入, 投资收益, 报销, 退款, 其他 |
| **资产** | 存款, 现金, 股票, 基金, 加密货币, 房产, 其他 |

---

## 数据库 (SQLite)

**位置：** `~/Library/Application Support/BillLensApple/billlens.sqlite`

**迁移文件：** `rust/migrations/`（0001~0008）

### 主要表结构

| 表 | 关键字段 |
|----|---------|
| `records` | id, direction, amount, currency, category, transaction_at, sync_version, synced_version, deleted_at |
| `record_drafts` | id, content, status, confirmed_record_id, [parsed fields] |
| `conversation_messages` | id, role, content, draft_id, record_id |
| `subscriptions` | cycle, anchor_day, anchor_month, next_due_at, is_active |
| `assets` | name, category, currency |
| `asset_snapshots` | asset_id, amount, recorded_on (unique per asset+date) |
| `app_settings` | key, value, device_id |

---

## LLM 集成

### 解析流程

```
用户输入文本/OCR 文本
    → core/llm.rs: parse_record_text_multi()
        → 构建提示词 (RECORD_PROMPT_TEMPLATE)
        → 调用 LLM API (OpenAI-compatible 或 Anthropic)
        → 解析 JSON 数组响应
        → 返回 Vec<ParsedRecordPayload>
```

### LLM 输出 Schema

```json
[
  {
    "direction": "income" | "expense" | null,
    "amount": number | null,
    "currency": "ISO 4217" | null,
    "category": "预定义分类" | null,
    "merchant": string | null,
    "transaction_at": "RFC3339" | null,
    "note": string | null,
    "subscription_cycle": "monthly" | "yearly" | null,
    "asset_info": {
      "name": string,
      "category": "存款|现金|股票|基金|加密货币|房产|其他",
      "amount": number,
      "currency": string,
      "recorded_on": "YYYY-MM-DD" | null,
      "note": string | null
    } | null
  }
]
```

**特殊解析规则：**
- 含「订阅/会员/月费/年费」→ 设置 `subscription_cycle`
- 含「资产/余额/存款」+ 数字 → 设置 `asset_info`，清空常规账单字段
- 货币规范化：人民币→CNY, 美元→USD, 港币→HKD

### LLM Provider 配置

```rust
pub enum LlmProvider { OpenAi, Anthropic }
```

配置存在 `app_settings` 表，key 为 `llm_config`，启动时通过 `bootstrap` 动作传入。

---

## STT（语音输入）流程

```
Swift SpeechCaptureService (Speech.framework)
    ↑↓ C 函数指针（SpeechFFIExports.swift 导出）
Rust SttSession（stt.rs）
    ↑↓ RustBridge: action=stt_start/stt_stop
BillLensStore.toggleRecording()
```

Rust 通过函数指针调用 Swift STT，Swift 返回 transcript 字符串，Store 合并到 `composerText`。

---

## CloudKit 同步

**服务：** `CloudKitSyncService.swift`

**同步协议：** Rust 在 `records` 等表上维护 `sync_version`/`synced_version` 列，Swift 通过以下 actions 协调：

| Action | 作用 |
|--------|------|
| `sync_list_dirty` | 获取本地未同步的变更 |
| `sync_mark_synced` | 标记已成功推送的记录 |
| `sync_apply_remote` | 将远端变更写入本地 |
| `sync_get_cursor` / `sync_set_cursor` | CloudKit 分区游标管理 |

---

## 典型数据流

### 文字录入账单

```
1. 用户输入 → composerText
2. submitText() → bridge.sendAsync([action: "submit_text", ...])
3. Rust: 创建 user 消息 → 调用 LLM → 解析 JSON
4. Rust: 生成 RecordDraft → 创建 assistant 消息
5. Swift 更新 messages, drafts
6. 若 auto_confirm=true → 直接生成 Record + 触发 CloudKit push
7. 否则 → 用户在 ReviewPanel 编辑 → confirmDraft()
```

### 草稿确认

```
1. 用户编辑 draftForm → saveDraft() 保存
2. confirmDraft() → Rust 将 draft.status → "confirmed"
3. Rust 创建 Record 条目
4. Swift 刷新 ledger + 触发 sync push
```

### 订阅到期处理

```
process_due_subscriptions()
    → 查询 next_due_at <= now 的活跃订阅
    → 自动创建 RecordDraft (auto_confirm=true)
    → 更新 next_due_at 到下一周期
```

---

## 构建说明

```bash
# 环境变量（本地 LLM）
export LLM_BASE_URL=http://127.0.0.1:8080/v1
export LLM_API_KEY=
export LLM_MODEL=qwen-local
export LLM_PROVIDER=llamacpp

# 构建 Rust FFI 库
cd rust && cargo build -p billlens_ffi

# 构建运行 macOS App
cd apple && swift build && swift run BillLensMacApp

# Rust 测试
cd rust && cargo test
```

**Rust 库链接路径：** `../rust/target/{debug|release}/libbilllens_ffi.a`
