# Mac性能监测邓眼瞎

<p align="center"><img src="Support/Assets/Silicon-icon.png" width="160" alt="邓眼瞎液态玻璃风格图标"></p>

> **AI 制作声明**：本项目的主要代码、界面实现、构建脚本及项目说明由 OpenAI Codex 在用户指导下辅助生成和修改；应用图标使用 AI 图像生成工具制作。第三方组件和参考项目的作者及许可证单独列出。本项目为实验性工具，AI 辅助制作不代表 Apple 官方开发、认可或认证。

英文名 **DENG-monitor**，应用名 **邓眼瞎**。应用面板保留 Silicon 标题。

一个简洁的 Apple Silicon Mac 菜单栏性能监测工具。使用原生 SwiftUI / AppKit，跟随系统浅色与深色外观。

## 使用

构建后双击 `dist/邓眼瞎.app`，直接打开性能面板，同时在 Dock 和菜单栏显示应用。关闭窗口后仍可在菜单栏查看数据；再次双击应用或点击 Dock 图标会重新显示窗口。在面板右下角退出应用。

- CPU：系统 CPU 时间差计算的忙碌比例，附估算功耗和平均温度。
- GPU：活动时间比例，附估算功耗和平均温度。
- 内存：采集器报告的已用 / 总量，同时显示 Swap。口径可能与活动监视器不同。
- Neural Engine：主值为 ANE 内存读写合计速率，按量级显示 MB/s 或 GB/s，同时分别显示读、写速率及估算功耗。
- ANE 活动率：从 `SoC Stats / Cluster Power States` 中 ANE 簇的 ACT 驻留时间计算，取最忙簇的比例。不是算力利用率；通道缺失、没有 ACT 状态、或没有有效时间数据时显示“不可用”。本机 M4 / macOS 26.3 未提供此活动率通道。
- 本机吞吐量来源：`AMC Stats / Perf Counters` 的 `ANE DCS RD` 和 `ANE DCS WR` 字节增量，除以实际单调时钟采样间隔。只统计 DCS 通道，避免把 AF 流量重复相加。数字是系统计数器报告的 ANE 内存流量，不是每秒推理次数或 TOPS。
- 其他机器若无法读取字节通道，可尝试 PMP 的 ANE 读写合计带宽分档；此时明确标注“估算”，读写明细显示 `—`。分档存在精度及高位饱和限制。
- 0.00 W 表示采样功耗低于显示精度，不能据此断定没有任何任务。

每秒采样。断开时清除过期的采集器数据并自动重试，缺失的指标显示 `—`。ANE 字节计数直接在应用内读取，不依赖 macmon；系统睡眠或采样间隔超过 5 秒时重新建立基线，避免把长时平均值当成实时速率。

## 运行条件

Apple Silicon Mac。已在当前 macOS 26.3 机器上验证；其他系统版本未验证。应用打包包含 macmon，不需要另装 Homebrew，也不需要管理员密码。macmon 使用私有系统接口，系统更新后可能需要适配。

应用只读取本机指标，没有网络上报、开机启动或历史数据存储。采集器会随应用退出。当前应用采用本机临时签名，没有 Apple 公证，适合本机使用。

## 构建

需要 Apple Silicon Mac、Xcode Command Line Tools（或 Xcode）和 Homebrew。先安装采集器，再构建：

```sh
brew install macmon
./build.sh
open dist/邓眼瞎.app
```

输出到 `dist/邓眼瞎.app`，采集器及图标均随应用打包。

## 第三方与 AI 素材

采集组件：[vladkens/macmon](https://github.com/vladkens/macmon)，MIT 许可证随应用保存在 `Contents/Resources/macmon-LICENSE`。

ANE 通道映射参考 [SiliconScope](https://github.com/kennss/SiliconScope)，MIT 许可证保存在源码 Support/SiliconScope-LICENSE 和应用 Contents/Resources/SiliconScope-LICENSE。

图标的 AI 生成说明和提示词见 [Design.md](Support/Assets/Design.md)。上述 AI 声明不改变第三方代码及组件的原有版权和许可证。
