# Rime Stellae / 墨芯

> 本项目由人类与 AI 协作产生. 部分 AI 提出的内容可能尚未经人工审核. 若有错误或疏漏, 敬请见谅.

[English (en)](README.en.md) | [Traditional Chinese (zh-TC)](README.md) | [Simplified Chinese (zh-SC)](README.zh-SC.md)

墨芯提供 Windows 的 Rime 前端与配套输入方案. 前端提供 TSF 输入、候选界面、方案部署与配置管理; 方案支持中文、英文、日语及查字工具. 可选择前端与完整方案整合包, 或供官方 Weasel 使用的独立方案 ZIP. 数学、物理、电脑及诗词词汇可通过 DLC 添加.

## 安装与使用

- [墨芯前端与完整方案安装器](https://github.com/unknownnumbers/rime-stellae/releases/download/v2026.11.27.3/stellae-2026.11.27.3-installer.exe).
- [墨芯完整方案 ZIP](https://github.com/unknownnumbers/rime-stellae/releases/download/v2026.11.27.3/stellae-2026.11.27.1-schemes.zip), 用于已有的墨芯安装.
- [官方 Weasel 方案 ZIP](https://github.com/unknownnumbers/rime-stellae/releases/download/v2026.11.27.3/stellae-2026.11.27.3-official-weasel-schemes.zip), 依[安装与合并说明](schemes/docs/official-weasel.md)使用.
- 支持 64-bit Windows, 并附 32-bit 应用兼容组件.
- 前端版本为 `0.17.4.61052`. 整合包版本为 `2026.11.27.3`, 内含 `2026.11.27.1` 版方案基底.
- 整合方案新装默认 SC 输出, 中文横排 5 项、英文直排 6 项, 保留 TC/SC 切换.
- 安装器附 Noto Sans CJK Regular 字体合集. 首装选 SC 或 TC 会设定相应的候选窗字体. 可在墨芯外观设置切换 TC、HK、SC, 升级保留已选字体. [候选窗字体说明](docs/PC.md#候選窗字體)
- 配套方案的英文模式使用蓝色 En 状态图标.
- `Ctrl+Space` 取消未上屏草稿并切换红色 A 与原有中文或英文模式. 已安装的旧版数学 DLC 可由整合安装器补齐英文拼写纠错索引.
- 墨芯外观自订使用 `stellae.custom.yaml`, 官方 Weasel 使用 `weasel.custom.yaml`. 安装器原样迁移墨芯旧外观文件; 若新旧文件内容不同, 先合并再升级.
- 升级保留用户自定义与学习资料. 同名自定义遮蔽方案默认时, 依[使用说明](docs/PC.md)核对与合并.

[完整方案功能](schemes/docs/PC.md) | [可选词汇与 DLC](schemes/docs/dlc-sources.md) | [构建](docs/BUILD.md) | [来源](docs/SOURCES.md) | [待办](TODO.md)

前端、完整方案及官方 Weasel 适配版源码均在本仓库维护. 共用方案来源位于 `schemes/config/pc`, 官方适配版由同一来源生成. ARM64、实体键盘及各 Windows 宿主的完整验收仍依已记录的验证范围逐项进行.

原创程序、配置、测试及资产采用 GPL-3.0-only, 原创说明文字采用 CC BY-SA 4.0. 第三方组件保留原授权及通知, 见[来源与授权](THIRD_PARTY_NOTICES.md).
