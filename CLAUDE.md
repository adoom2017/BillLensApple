# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 工作原则

1. **第一性原理**：从原始需求出发，动机不对立刻停，路径非优直接纠正。
2. **极简沟通**：简单直白语言一次输出。拒绝角色扮演，拒绝分段分口吻，已解决的问题后续不再提。不使用 P0/P1/P2 等术语。
3. **Let it crash**：发现问题尽早暴露。禁止使用任何降级、兜底、启发式补丁或非严谨通用算法的后处理补救。
4. **禁止擅自开分支**：严禁私自创建新 worktree。可以给建议，但必须征得用户明确同意后方可操作。
5. **自检与精简**：每次改动后执行"Review查Bug→第一性原理分析"流程，思考是否有更简单、更稳健的实现。
6. **结论先行+表格化**：直接给结论和修补方案，多项对比用 Markdown 表格。严禁复读背景，严禁陈述式汇报。

## Build & Run

Set required environment variables before building:

```bash
export LLM_BASE_URL=http://127.0.0.1:8080/v1
export LLM_API_KEY=
export LLM_MODEL=qwen-local
export LLM_PROVIDER=llamacpp
```

Build and run:

```bash
# Build Rust FFI library first
cd rust && cargo build -p billlens_ffi

# Build and run the macOS app
cd apple && swift build
swift run BillLensMacApp
```

Run Rust tests:

```bash
cd rust && cargo test
```

## Architecture

Hybrid Rust + Swift macOS app. The Rust core is compiled as a static library and called from Swift via C FFI.

**Communication flow:**
```
SwiftUI (BillLensShared/RootView.swift)
  → BillLensStore (observable state)
    → RustBridge (JSON serialization)
      → billlens_ffi C FFI (billlens_handle_request / billlens_free_string)
        → AppService in billlens-apple-core
          → BillRepository in billlens-apple-db (SQLite via SQLx)
```

**Rust crates (`rust/crates/`):**
- `core/` — business logic, LLM integration, structured parsing pipeline
- `db/` — SQLite persistence (records, drafts, sync_outbox tables)
- `ffi/` — C FFI bridge, exposes only `billlens_handle_request()` and `billlens_free_string()`

**Swift targets (`apple/Sources/`):**
- `BillLensMacApp/` — app entry point, NSApplicationDelegate
- `BillLensShared/` — SwiftUI views, `BillLensStore` (state), `RustBridge` (JSON bridge)
- `BillLensAppleServices/` — Vision OCR, Speech STT, logging
- `CBillLensRustBridge/` — C headers for Rust FFI

**Entry paths for bill input:**
1. Text → LLM structured parsing
2. Image → Vision OCR (Chinese + English) → LLM structured parsing

Both paths use a draft-based workflow: parse result becomes a draft for user review before confirmation.

## Data

- Database: `~/Library/Application Support/BillLensApple/billlens.sqlite`
- Logs: `~/Library/Application Support/BillLensApple/billlens.log`
- Migrations: `rust/migrations/`
- Sync: local `sync_outbox` table reserved; no cloud sync yet
