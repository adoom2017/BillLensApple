# Billumi（账映）架构

## 模块边界

```text
SwiftUI → BillLensStore → RustBridge → JSON C FFI → AppService → SQLite
                │                                  │
                ├─ Vision OCR / Speech             ├─ 文本规则 / 云端 HTTP
                ├─ CloudKit 传输                   └─ 本地推理 C 回调 → Swift llama.cpp
                └─ 模型下载、校验、文件管理
```

| 目录 | 职责 |
|---|---|
| `apple/Sources/BillLensMacApp/` / `BillLensIOSApp/` | 平台入口、权限、通知与生命周期 |
| `apple/Sources/BillLensShareExtension/` | iOS 分享扩展：把信用卡账单文件放入 App Group 收件箱，不链接 Rust |
| `apple/Sources/BillLensShared/` | 共享视图、MainActor 状态、FFI DTO、CloudKit、订阅提醒 |
| `apple/Sources/BillLensAppleServices/` | OCR、Speech、日志、本地模型文件与推理运行时 |
| `apple/Sources/CBillLensRustBridge/` | C 头文件，Swift/Rust 之间的所有权合同 |
| `rust/crates/core/` | 解析、路由、字段验证、业务编排、汇率和订阅补算 |
| `rust/crates/db/` | SQLx Repository、持久化模型和事务 |
| `rust/crates/ffi/` | 版本化输入的 JSON 分发、运行时与后端注册 |
| `rust/migrations/` | 0001–0011 顺序迁移；已发布迁移必须保留 |

主界面由 `RootView` 分发记账、账单、订阅、资产页面：iOS 使用 TabView，macOS 使用侧栏。系统语义色、分类图标和浮动控件材质集中在 `DesignTokens.swift`；Liquid Glass 仅用于受支持系统的浮动控件。

## 输入、规则与模型

1. 语音停止后将转写放入输入框，用户发送后进入文本链路；图片先由 Vision 转为 OCR 文本。
2. 文本先经过 `rule_parser.rs`。能够完整确定单笔账单时返回 `parser_source=rule`，不调用模型；否则确定字段作为 prompt 约束，并覆盖对应的单笔模型字段。资产、多笔、订阅和 OCR 交给模型。
3. 模型只输出原文 `time_text`，时间换算由 Rust 完成。外部模型输出不接受旧 `transaction_at` 字段、Markdown 包装或未知字段，不做文本修补。
4. `cloud_only` 只调用云端；`local_first` 优先选择已安装模型。未选择模型或发生允许转交的类型化本地错误时，最多调用云端一次，并返回来源与失败原因。取消、后台、内存压力、忙碌状态不转云端。
5. 本地和云端共用提示词与严格 JSON 合同。规则并非本地模型，即使选择本地优先，规则完整命中时仍遵循规则保存语义。

| 来源 / 类型 | 自动保存关闭 | 自动保存开启 |
|---|---|---|
| 本地模型：账单、订阅、资产 | 全部写入待确认草稿 | 全部写入待确认草稿 |
| 规则或云端：账单、订阅 | 写入待确认草稿；订阅未创建 | 在同一确认事务内保存账单和对应订阅 |
| 云端：资产 | 直接更新资产 / 快照 | 直接更新资产 / 快照 |

`cloud_after_local_failure` 遵循云端保存语义，并携带本地错误。账单、订阅自动保存先持久化一批草稿，再复用确认事务；失败保留完整草稿供查看，不留下该批次的部分账单或订阅。云端资产独立处理，不与同次输入的账单构成跨类型总事务。

## 邮箱账单同步（Hotmail / iCloud）

```text
Swift：OAuth 授权码 + PKCE（ASWebAuthenticationSession）→ 钥匙串存 refresh token → 刷新 access token
  → FFI mail_sync {access_token} → Rust：Graph 列出 ccsvc@message.cmbchina.com 邮件（升序、分页、游标）
  或：钥匙串存 iCloud 地址 + App 专用密码 → FFI mail_sync_imap → Rust：IMAP（imap.mail.me.com:993）
     SELECT INBOX → UID SEARCH FROM 招行 → BODY.PEEK[] 下载（不改已读）
  → 逐封下载 MIME → 复用账单导入（解析 / 确定性 ID / 疑似重复 / 勾稽）→ 自动入账或留待确认
```

- 同一时间只连接一个邮箱；连接 iCloud 会清除 Hotmail 授权，反之亦然。两种来源实现同一个 `MailSource` 抽象，同步编排共用。
- iCloud 没有 OAuth 邮件接口，用 App 专用密码；连接前 `mail_verify_imap` 校验登录。密码只存本机钥匙串，Rust 不落盘、不写日志。
- 只申请 `Mail.Read`、`User.Read`、`offline_access`；refresh token 仅存本机钥匙串（`AfterFirstUnlockThisDeviceOnly`，不同步），Rust 只接收短期 access token，不落盘。
- 勾稽通过：默认勾选且未入账的行自动入账（单事务 + 助手消息）；疑似重复、「其他」分区留待确认。勾稽失败：整封留待确认。非账单邮件记为跳过。
- 同步范围：设置页可选最近 1–24 个月（默认 3，存 `UserDefaults`，随 `mail_sync` 传入）。调大时 Rust 按 `synced_from` 判断并清空游标补扫更早邮件，已处理的邮件按 id 跳过；调小不重扫。
- `mail_sync_state` / `mail_messages`（迁移 0012、0013）只在本机；待确认账单保留原始邮件，确认或忽略后清空；断开连接全部删除，已入账记录保留。
- 触发：启动 / 回到前台（自动触发间隔 ≥ 15 分钟）、设置页「立即检查」、iOS 后台刷新（与订阅维护同一任务）。同一时刻只运行一次。
- 401 → 需要重新连接；429/503/网络错误 → 进度停在出错前一封，下次续传。分页链接必须仍指向 Graph 主机才跟随。
- Client ID 来自构建设置 `BILLLENS_MICROSOFT_CLIENT_ID`（Info.plist `BillLensMicrosoftClientID`）；为空时设置页提示未配置。

## 手动新增与编辑

账单、订阅、资产页面的「＋」与账单行编辑、资产详情「更新估值」走 FFI `create_record` / `update_record` / `create_subscription` / `create_asset`。

- 校验与写入复用草稿确认：`validated_record_create` / `validated_asset_create`，以及 `apply_confirmation_action_in_transaction`（`confirm_parsed_drafts` 与 `create_manual_entry` 共用）。不经过 `parsed_drafts`，不写对话消息，无迁移。
- 手动订阅以首次扣费日为第一个 `next_due_at`；不晚于今天时只对该订阅执行到期补扣（UUID v5，重复执行幂等），将来日期只建订阅。
- 更新估值沿用资产当前名称、类别、币种，按名称合并，同日快照覆盖。按名称写入资产（草稿确认、手动新增、云端直接保存）时，同名在用资产币种不同则拒绝（`AssetCurrencyMismatch`），不改币种也不追加异币种快照。
- `update_record` 同时写入 `device_id` 并递增 `sync_version`。

## 信用卡电子账单导入

目前支持招商银行信用卡电子账单。入口：记账页「＋」菜单；macOS 在导入面板的拖放区拖入 Mail 邮件（file promise 只能由 AppKit `NSFilePromiseReceiver` 接收，SwiftUI `onDrop` 收不到），或把 Finder 中的 `.eml` / `.html` / `.pdf` 拖进窗口；iOS Mail「打印 → 分享 → 账映」。

```text
.eml（base64）/ .html / PDFKit 文字 → statement::source（MIME 解码、HTML 转行、NFKC + 部首映射）
  → statement::cmb（账期、汇总、分区、尾部锚点切分交易行）→ 分类 / 确定性 ID / 状态 → 预览
确认：同一来源重新解析 → 校验选中 ID 与分类 → 单事务 INSERT … ON CONFLICT(id) DO NOTHING + 助手消息
```

- 解析只在本机进行，不调用模型或网络；日志只记行数、状态计数与勾稽结果。
- 记录 ID 为 UUID v5（尾号、分区、记账日、交易日、金额、同 key 序号，**不含摘要**）。同一封账单无论从 eml 还是 PDF、在哪台设备导入，ID 都相同；已导入（含已删除）行不再写入。不需要迁移，CloudKit payload 不变。
- 消费 / 退款按交易日入账，分期 / 费用 / 利息按记账日；时刻为设备时区 12:00。还款、取现本金不入账。与已有记录方向、金额相同且在同一天（本机时区；账单无时刻，不比较小时）的行标为疑似重复，默认不勾选。
- 勾稽：本期新增 = 消费 + 分期 + 取现 + 费用；本期调整 = −退款；本期应还 = 上期账单 + 还款 + 新增 − 调整 + 利息。不一致只警告，仍可导入。
- iOS 分享扩展先写 `StatementInbox/<uuid>.<ext>.partial` 再改名；主 App 回到前台时取最早的文件打开预览，完成、取消或解析失败后删除。App Group `group.com.shendongchun.BillLensApple` 仅在 Release 签名启用。

## 草稿与数据库

| 表 | 内容 |
|---|---|
| `records` | 已入库账单 |
| `parsed_drafts` | 通用待确认项：kind、parser_source、原文、完整 payload、转交原因、确认结果 |
| `conversation_messages` | 本机对话历史 |
| `subscriptions` | 周期、锚点、下次扣费日、启停状态 |
| `assets` / `asset_snapshots` | 资产主表与按日期的估值快照 |
| `app_settings` | 本地配置，含云端连接配置 |
| `fx_rates` | 汇率缓存 |
| `sync_state` / `sync_cursor` | 同步状态和 CloudKit 拉取游标 |

`0010_generalize_parsed_drafts.sql` 将旧 `record_drafts` 迁移为 `parsed_drafts`；Swift 和 Rust 的兼容类型名称仍为 `RecordDraft`。`0011_add_rule_parser_source.sql` 增加规则来源。原 `sync_outbox` 已由 0009 删除。

`confirm_parsed_drafts` 在单个事务中校验所属 profile、草稿状态及类型，写入业务表、确认结果、草稿状态与助手消息。订阅确认同时创建首笔账单；资产确认写入资产和快照。批量确认的任一动作失败会整体回滚。编辑或丢弃不会创建业务记录。

资产重命名命中已有名称时，同币种资产在一个事务中合并；同日快照保留目标行 ID，按更新时间选择内容，源行软删除。拒绝跨 profile、不同币种和自身合并。

## 时间、订阅与汇率

- 交易时间以 UTC 绝对时间持久化。带偏移的 RFC3339 是 DTO 时间边界；无偏移时间直接拒绝。
- Swift 启动时传入设备 IANA 时区，系统时区变化时更新 Rust 并刷新账本与提醒。
- Rust 按设备时区完成时间描述换算、账本日分组、月年边界和订阅扣费日，处理夏令时。
- 明确时段使用规则表的钟点：凌晨 05、早上 08、上午 10、中午 12、下午 15、傍晚 18、晚上 20；只有日期时保留当前钟点，无时间线索时使用当前时间。
- 启动、回到前台和 iOS 后台刷新都会补算到期订阅。启用 CloudKit 时，必须先完整拉取成功。每次扣费的 UUID v5 由订阅 ID 与到期日决定，账单写入与到期日推进为同一事务。
- 可选的系统通知在设备当前时区的扣费日 09:00 提醒。iOS 后台调度由系统决定，补账正确性依赖下次启动时补算。
- 账本统一换算为 CNY，汇率由 Frankfurter 获取。网络失败且已有缓存时，结果包含 `fx_warning`；没有可用汇率时报错。

## 本地模型

- 唯一清单位于 `BillLensAppleServices/Resources/local-models.json`，固定下载地址、revision、字节数、SHA-256、许可和内存门槛。
- 0.8B 与 2B 都由用户下载。权重和状态位于 Application Support 的 `BillLensApple/LocalModels/`，排除设备备份，不通过 CloudKit 同步。
- 下载完成必须验证大小与 SHA-256 才能安装。iOS 使用后台 URLSession，默认禁止昂贵和受限网络；蜂窝授权仅针对当前下载。macOS 使用由 App 持有的普通 URLSession。
- `LocalModelManager` 持有下载与安装状态；`LocalLlmRuntime` 的串行队列持有唯一模型实例，切换前卸载。iOS 后台或内存压力会取消并卸载。
- llama.cpp 固定为 b9632 XCFramework。模型生命周期、取消和字符串分配由 Swift 管理，路由与业务验证由 Rust 管理。

## FFI 合同

普通调用通过 `billlens_handle_request(const char *) -> char *`，返回 JSON：

```json
{"ok":true,"data":null,"error":null}
```

成功的 `data` 按请求响应类型解码。可空响应的 `null`（如尚未配置 LLM）是合法值；必填数据缺失或 `null` 是合同错误。失败返回 `ok=false` 与完整原因链。

调用方必须使用 `billlens_free_string` 恰好释放一次响应。Speech 与本地 LLM 另有后端注册函数，注册时传入运行、取消、释放等 Swift C 回调；完整声明以 `billlens_ffi.h` 为准。Swift 从后台任务进入阻塞 FFI，SwiftUI 状态更新留在 MainActor。

## CloudKit

CloudKit 在 Swift 中负责传输，Rust 负责行版本与冲突处理。容器为 `iCloud.com.shendongchun.BillLensApple`，自定义 zone 为 `BillLensZone`。

- 只同步 `record`、`subscription`、`asset`、`asset_snapshot`；草稿、对话、模型和 LLM 凭据留在本机。
- 业务删除为带版本的软删除；远端意外硬删除（控制台操作或数据区重置）会被跳过并保留本地数据，记录 `sync.pull.skip` 日志，不阻塞游标。
- 推送按 `sync_version > synced_version` 查询；只有 CloudKit 保存和本地水位确认都成功才视为该批次完成。
- 拉取按页处理：验证整页类型及 payload → 父资产先于快照应用 → 保存新游标。任一记录、操作、解码、数据库或游标写入失败都终止，保留可重放的旧游标。
- 同一进程共享进行中的拉取任务，状态隔离在 MainActor；不并发运行两个推送循环。
- iOS Debug 默认禁用 CloudKit；macOS ad-hoc 构建不携带受限 entitlement。正式签名和真机多设备验证见开发文档与审查记录。
