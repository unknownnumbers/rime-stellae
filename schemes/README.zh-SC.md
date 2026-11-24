# 墨芯方案

> 本项目由人类与 AI 协作产生. 部分 AI 提出的内容可能尚未经人工审核. 若有错误或疏漏, 敬请见谅.

[English (en)](README.en.md) | [Traditional Chinese (zh-TC)](README.md) | [Simplified Chinese (zh-SC)](README.zh-SC.md)

墨芯提供中文、英文及日语输入方案, 包含墨芯前端用方案及官方 Weasel 兼容方案.

## 现有功能

- 中文全拼、缩写、既有容错、组句及本地学习, 支持 TC/SC 输出切换. 使用 `;` 固定前一个完整音节, 使用 `"` 确认其左侧整段完整拼写. 例如 `xiao;sr`、`woxiang"` 和 `wenti"s`.
- 光标位于草稿末端时, 两套方案从第 8 键起以普通组句处理整段只能按单字母切分的简拼.
- 英文的完整词、补全、容错、大小写与既有缩写展开.
- 查字、Unicode 和计算工具按输入模式调用.
- 两套方案均提供平假名、片假名、汉字、romaji、q/x/v 查询模式.
- 官方 Weasel 方案使用原生整词补全, 固定直排 6 项、非内嵌.
- 默认使用通用词库. 数学、物理、电脑及诗词词汇可通过独立 DLC 安装. 数学及物理包涵盖广泛学科词汇, 诗词包收录固定来源的全量唐诗、宋诗、宋词及配套选集.

墨芯完整方案新装默认 SC 输出, 中文横排 5 项、英文直排 6 项. 两套方案保留既有学习及自定义配置的使用方式. 墨芯前端的英文模式使用蓝色 En 状态图标. 中文方案的左右 Shift 在中文与英文间切换, 红 A 保留前端的原生输入状态.

## 安装

- [墨芯前端与方案安装器](https://github.com/unknownnumbers/rime-stellae/releases).
- [官方 Weasel 方案 ZIP](https://github.com/unknownnumbers/rime-stellae/releases/latest).
- [完整方案使用说明](docs/PC.md)、[官方方案安装及合并](docs/official-weasel.md)、[DLC 来源](docs/dlc-sources.md).

共用维护源位于 [config/pc](config/pc), [config/official-weasel](config/official-weasel) 由同一源码和明确的引擎设置生成. 修改共用源后使用 `python scripts/rebuild_profiles.py --refresh-official`, 并以 `--check` 核对派生结果. 安装到已有资料夹时, 先备份同名配置并依说明合并, 保留用户词库.

2026.11.14.2 诗词 DLC 需要 2026.11.14.2 或更新的方案基座. 词表由仓库中的固定来源及构建程序生成, 可直接下载 Release 的模块 ZIP. 读音与异文采用自动处理及有限校核, 尚未逐句审校, 详见 [DLC 来源与限制](docs/dlc-sources.md).

数学、物理与电脑 DLC 随包提供英文拼写纠错索引. 已有旧包时可更新对应模块后重新部署.

## 开发与待办

[构建说明](docs/BUILD.md) | [来源及重建范围](docs/sources/README.md) | [待办](TODO.md)

原创程序与配置采用 GPL-3.0-only, 原创说明文字采用 CC BY-SA 4.0. 第三方数据及原通知保留各自授权, 见 [授权索引](THIRD_PARTY_NOTICES.md).
