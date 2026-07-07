# Repository Guidelines

## 工作原则

1. **第一性原理**：从原始需求出发，动机不对立刻停，路径非优直接纠正。
2. **极简沟通**：简单直白语言一次输出。拒绝角色扮演，拒绝分段分口吻，已解决的问题后续不再提。不使用 P0/P1/P2 等术语。
3. **Let it crash**：发现问题尽早暴露。禁止使用任何降级、兜底、启发式补丁或非严谨通用算法的后处理补救。
4. **禁止擅自开分支**：严禁私自创建新 worktree。可以给建议，但必须征得用户明确同意后方可操作。
5. **自检与精简**：每次改动后执行"Review查Bug→第一性原理分析"流程，思考是否有更简单、更稳健的实现。
6. **结论先行+表格化**：直接给结论和修补方案，多项对比用 Markdown 表格。严禁复读背景，严禁陈述式汇报。

## Project Structure & Module Organization
`apple/` contains the macOS Swift Package. `apple/Sources/BillLensMacApp/` is the app entry point, `BillLensShared/` holds SwiftUI screens, state, and the Rust bridge, `BillLensAppleServices/` wraps Vision, Speech, and logging, and `CBillLensRustBridge/` exposes the C header consumed by Swift. `rust/` is a Cargo workspace: `crates/core/` contains business logic and LLM parsing, `crates/db/` manages SQLite persistence, and `crates/ffi/` builds the static library linked from Swift. Database migrations live in `rust/migrations/`.

## Build, Test, and Development Commands
Set `LLM_BASE_URL`, `LLM_API_KEY`, `LLM_MODEL`, and `LLM_PROVIDER` before running the app.

- `cd rust && cargo build -p billlens_ffi`: build the Rust static library for Swift linking.
- `cd apple && ./build-rust.sh`: rebuild the FFI library from the Apple-side workflow.
- `cd apple && swift build`: compile the macOS app.
- `cd apple && swift run BillLensMacApp`: launch the local app.
- `cd rust && cargo test`: run the Rust unit test suite.

## Coding Style & Naming Conventions
Use 4-space indentation in Swift and Rust. Follow existing naming patterns: Swift types use `UpperCamelCase`, Swift properties and methods use `lowerCamelCase`, Rust modules and functions use `snake_case`, and Rust types use `CamelCase`. Keep FFI changes synchronized across `rust/crates/ffi/src/lib.rs`, `apple/Sources/CBillLensRustBridge/include/billlens_ffi.h`, and `apple/Sources/BillLensShared/RustBridge.swift`. No repo-level Swift formatter or linter is checked in; keep Swift formatting consistent with nearby files and run `cargo fmt` for Rust edits.

## Testing Guidelines
Rust tests live inline under `#[cfg(test)]`, primarily in `rust/crates/core/` and `rust/crates/db/`. Add unit tests with any change to parsing, storage, or edge-case logic. There is currently no Swift test target in `apple/Package.swift`, so Swift-side changes should at least pass `swift build` and a manual smoke test of the affected flow.

## Failure Visibility
Do not add fallback behavior that hides errors or silently degrades functionality. If a dependency, configuration value, FFI contract, parser, or local service is invalid, fail fast and surface the problem through explicit errors, logs, or assertions so it can be fixed immediately. Prefer exposing integration issues during development over masking them with default behavior.

## Agent Behavior
Keep responses tightly scoped to the user's request and avoid unrelated commentary, explanations, or suggestions. Execute the user's stated instruction directly whenever it is clear. If the request is ambiguous, stop first, ask a concise clarification question, and only proceed after the requirement is clear.

## Commit & Pull Request Guidelines
Recent commits use short, imperative Chinese subjects such as `增加历史账单删除功能`. Keep commits focused and descriptive in that style. Pull requests should summarize user-visible changes, call out migration, FFI, or environment-variable updates, list the commands you ran, and include screenshots or short recordings for SwiftUI changes.

## Configuration & Data
Local runtime data is stored in `~/Library/Application Support/BillLensApple/`, including `billlens.sqlite` and `billlens.log`. Do not commit secrets; keep API keys and model endpoints in shell environment variables only.
<!-- TRELLIS:START -->
# Trellis Instructions

These instructions are for AI assistants working in this project.

This project is managed by Trellis. The working knowledge you need lives under `.trellis/`:

- `.trellis/workflow.md` — development phases, when to create tasks, skill routing
- `.trellis/spec/` — package- and layer-scoped coding guidelines (read before writing code in a given layer)
- `.trellis/workspace/` — per-developer journals and session traces
- `.trellis/tasks/` — active and archived tasks (PRDs, research, jsonl context)

If a Trellis command is available on your platform (e.g. `/trellis:finish-work`, `/trellis:continue`), prefer it over manual steps. Not every platform exposes every command.

If you're using Codex or another agent-capable tool, additional project-scoped helpers may live in:
- `.agents/skills/` — reusable Trellis skills
- `.codex/agents/` — optional custom subagents

Managed by Trellis. Edits outside this block are preserved; edits inside may be overwritten by a future `trellis update`.

<!-- TRELLIS:END -->
