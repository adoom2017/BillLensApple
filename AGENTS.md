# Repository Guidelines

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
