# BillLensApple

独立于当前 Rust API 工程的 Apple 原生实现原型。

目录说明：

- `rust/`：本地 Rust 核心、SQLite、同步预留表、JSON FFI
- `apple/`：SwiftUI macOS 原生界面、Vision OCR、Speech 语音转写

本地构建：

```bash
export LLM_BASE_URL=http://127.0.0.1:8080/v1
export LLM_API_KEY=
export LLM_MODEL=qwen-local
export LLM_PROVIDER=llamacpp

cd BillLensApple/rust
cargo build -p billlens_ffi

cd ../apple
swift build
swift run BillLensMacApp
```

说明：

- 数据库默认写入 `~/Library/Application Support/BillLensApple/billlens.sqlite`
- 日志默认写入 `~/Library/Application Support/BillLensApple/billlens.log`，同时也会打印到控制台
- 当前同步只做本地 `sync_outbox` 预留，未接云端
- OCR 已接入 Vision；OCR 结果会继续送入与原工程一致的 LLM 结构化解析链路
- 文本录入与 OCR 录入都依赖 `LLM_BASE_URL / LLM_API_KEY / LLM_MODEL / LLM_PROVIDER`
- 语音转写已接入 Speech，但首次运行需要系统授权
