# 文档索引

| 文件 | 读者 | 用途 |
|---|---|---|
| [../README.md](../README.md) | 第一次进入仓库的人 | 产品概览、快速开始、文档入口 |
| [architecture.md](architecture.md) | 需要理解系统结构的人 | Rust + SwiftUI 架构、数据流、同步、UI 结构 |
| [review.md](review.md) | 维护者 | 审查结果、清理依据与验证边界 |
| [development.md](development.md) | 日常开发和打包的人 | 环境变量、构建命令、iOS 运行、常见问题 |
| [../AGENTS.md](../AGENTS.md) | Codex / 其他 Agent | 项目规则、红线、代码修改约定 |
| [../CLAUDE.md](../CLAUDE.md) | Claude Code | 指向同一套项目规则，避免双写 |

规则：

- 人类可读的项目文档统一放在 `docs/`。
- 根目录只保留入口型文档，不再堆平铺的专题稿。
- 过期设计稿和已被推翻的 PRD 直接删除，不做“历史陈列”。
