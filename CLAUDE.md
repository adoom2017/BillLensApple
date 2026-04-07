# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
