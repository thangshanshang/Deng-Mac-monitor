# AI 制作声明 / AI disclosure

Mac性能监测邓眼瞎（英文名 DENG-monitor，应用名邓眼瞎）是在用户指导下借助 AI 制作的项目。

- 主要 Swift / SwiftUI / AppKit 代码、ANE 计数器读取实现、构建脚本和项目说明，由 OpenAI Codex 辅助生成、修改和排查问题。
- 应用图标通过 AI 图像生成工具制作，提示词与设计说明位于 `Support/Assets/Design.md`。
- 硬件指标来自本机 macOS 系统计数器和 macmon，运行时没有使用 AI 推断数据；不可用的指标直接标为不可用。
- 已在一台 Apple M4 / macOS 26.3 上进行编译、实时数据读取及界面布局检查，不代表在所有芯片和系统版本上均已验证。
- macmon 与 SiliconScope 的归属和许可证保留；AI 辅助制作声明不将第三方作品归为本项目原创。

This project was created with AI assistance under user direction. OpenAI Codex assisted with the source code, interface, build scripts, documentation, and troubleshooting. The app icon was generated using an AI image generation tool. Runtime hardware metrics are read from system counters, not inferred by AI. Third-party copyrights and licenses remain intact.
