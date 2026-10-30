# Rime Stellae / 墨芯

[English (en)](README.en.md) | [Traditional Chinese (zh-TC)](README.md) | [Simplified Chinese (zh-SC)](README.zh-SC.md)

> 本项目由人类与 AI 协作产生. 部分 AI 提出的内容可能尚未经人工审核. 若有错误或疏漏, 敬请见谅.

Rime Stellae 是基于 Weasel 的 Windows Rime 前端. 本仓库提供 0.17.4.61052 的源码、构建入口、测试及安装器, 可与官方 Weasel 并存.

## 功能

- 独立产品身份、程序目录、服务及用户数据目录.
- TSF 按键配对、候选界面、上屏及焦点处理的原生修改.
- Caps 补键以事件标记识别, 正式构建关闭临时数值诊断.
- 安装与升级保留已有输入法、所选注册项目及用户数据.
- 配色选择、部署、词典管理和手动安装 Rime 方案的工具.

## 安装与使用

从 [GitHub Releases](https://github.com/unknownnumbers/rime-stellae/releases) 获取安装包. 安装包不预装输入方案或词典, 安装后需自行加入方案并重新部署.

用户数据默认位于 `%APPDATA%\RimeStellae`. 可从通知区域菜单打开用户文件夹、安装方案或重新部署. 详见[使用说明](docs/PC.md).

| 组件 | 发布内容 |
| --- | --- |
| 前端 | TSF、Server、Deployer、Setup 及 classic IME 0.17.4.61052 |
| 架构 | x64 与 Win32 |
| x64 引擎 | N01, step-only Lua GC |
| Win32 引擎 | R5 |
| 共用资源 | 前端外观与配色预览、空方案列表、标准 OpenCC、按键与标点资源 |

两种架构的引擎版本分别固定, 构建资料见[构建说明](docs/BUILD.md)与[来源索引](docs/SOURCES.md). 当前公开验证以 Windows hosted CI 为主, ARM64 尚未列入发布范围. classic IME 的历史升级路径及部分宿主的焦点切换、偶发首键行为仍待持续验证.

## 开发与待办

源码与安装包各自附有来源清单及第三方通知. 构建步骤见[构建说明](docs/BUILD.md), 后续工作见[TODO](TODO.md). 本项目尚未设置自动更新源.

## 授权与致谢

本工程原创程序、配置、测试、图标及修改采用 [GPL-3.0-only](LICENSE), 原创说明文字采用 [CC BY-SA 4.0](licenses/CC-BY-SA-4.0.txt). 第三方部分保留原授权及署名, 详见[授权与来源](THIRD_PARTY_NOTICES.md).

感谢 [Rime](https://github.com/rime)、[Weasel](https://github.com/rime/weasel)及其贡献者, 以及引擎、插件和构建依赖的作者.
