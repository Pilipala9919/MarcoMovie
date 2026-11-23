<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/brand-horizontal-dark.png" />
    <source media="(prefers-color-scheme: light)" srcset="docs/images/brand-horizontal-light.png" />
    <img src="docs/images/brand-horizontal-light.png" width="520" alt="Marco Movie — 金属胶片丝带 M 标志与品牌字标" />
  </picture>
  <h1>Marco Movie</h1>
  <p>支持 Android 电视、手机、平板，HarmonyOS NEXT（手机 / 平板 / 智慧屏），Apple TV（tvOS）及 Windows / macOS / iOS 多端自适应的播放器。</p>
  <p>作者：<a href="https://github.com/Pilipala9919">Pilipala</a> · Android 手机：0.7.0 · Android 电视：0.6.2 · Android Lite：0.5.8 · Windows：0.7.1 · macOS：0.5.20 · iOS：0.7.0 · Apple TV：0.1.1 · HarmonyOS NEXT：0.1.1 · 各端独立更新</p>
  <p><a href="https://marcotv.wlj9919.top/movie/">镜像下载与产品展示</a> · <a href="https://github.com/Pilipala9919/MarcoMovie/releases">GitHub 下载</a> · <a href="docs/USER_GUIDE.md">使用指南</a> · <a href="docs/BUILD.md">构建说明</a> · <a href="docs/PRIVACY.md">隐私说明</a></p>
</div>

> **本产品仅为播放与内容管理工具，不内置、不提供、不托管、不售卖任何影视资源，也不提供影视资源配置地址、账号或会员权益。内容及配置需由用户自行合法获取，并确保拥有相应访问和使用权。**

## 产品介绍

Marco Movie 希望让大屏电视、随身手机、平板电脑与桌面端上的浏览、搜索和播放同样自然顺手：在大屏电视上（Android TV、Apple TV `tvOS` 及 HarmonyOS NEXT 鸿蒙智慧屏）以大幅竖版海报与清晰焦点反馈配合遥控器操作；在手机与平板上（Android、iOS / iPadOS 及 HarmonyOS NEXT 手机/平板）采用完全独立的触控界面（竖屏底部 Dock、横屏侧边 Dock、原生键盘搜索、剪贴板一键导入、全屏手势播放）；并提供 `tvos/` 原生 Apple TV 客户端、`flutter/ohos/` 原生鸿蒙 Stage 宿主及 `flutter/` 跨平台工程覆盖 Windows、macOS、iPhone 与 iPad。应用没有预装片库；第一次打开时，用户需要自行导入有权使用的配置。

这是一个覆盖 Android、Apple TV（tvOS）、HarmonyOS NEXT（纯血鸿蒙）、iOS / iPadOS、Windows 与 macOS 的多平台客户端项目。界面、配置管理、播放控制和本地搜索匹配在设备上运行；本项目不运营影视内容服务。功能和设备兼容性仍在持续完善。

## 能做什么

| 功能 | 当前能力 |
| --- | --- |
| 电视端导航 | Android TV、Apple TV（Siri Remote 焦点引擎）与鸿蒙智慧屏均配备 10 英尺大屏交互：首页悬浮图标/顶部 Dock、遥控方向键连续焦点移动、分类筛选与按返回键回到原浏览位置 |
| 手机 / 平板专属 UI | 自动识别触屏手机与平板（Android、iOS / iPadOS、HarmonyOS NEXT 手机/平板），进入独立移动端界面：保留系统状态栏、去除遥控器白色焦点框；竖屏底部导航栏、横屏切换侧边导航栏 |
| 大屏与移动端首页 | 电视端提供继续观看横卡、完整分类名称与默认 5–8 列海报墙；手机端提供顶部片源胶囊切换、单行横向滑动分类条、紧凑继续观看条与 3 列触控海报网格（平板横屏 5 列） |
| 内容详情与选集 | 电视端左对齐沉浸影院或分栏滚动；手机端采用左海报右信息紧凑卡片、可折叠简介、横向滑动线路胶囊、每 50 集自动分组标签、正序/倒序切换与触控选集网格；全端（含 Lite 纯文字标签）接入统一纯文字媒体规格徽章（`4K` / `HDR10+` / `DV · ATMOS` 等，零第三方商标图形） |
| 我的收藏与历史 | 详情页一键收藏；整合观看历史与我的收藏，支持单条删除与一键清空；数据保存于本机 |
| 全局搜索 | 在已导入、可搜索的配置项之间并发检索；Android 电视端内置遥控拼音键盘（支持中文、全拼、首拼），Apple TV 支持系统搜索与听写；手机/平板端直接调起系统输入法软键盘 |
| 播放控制与触屏手势 | 电视端（Android TV / Apple TV / 鸿蒙智慧屏）确认键暂停/继续、遥控长按加速快进预览、3 秒片头/片尾跳过倒计时与定时关闭；手机/平板端支持**双击自定义（播放暂停/左右步进）、左右滑快进快退、左半屏亮度、右半屏音量、长按 2.0× 倍速并横滑切换 `1.25×–3.0×` 与上滑锁定**；iOS/iPadOS 26 采用同心液态玻璃空间影院 HUD 与原生半屏面板；桌面端支持 2.5s 鼠标自动隐藏、滚轮调音量、`←`/`→` 加速预览（`Esc` 取消）、`S`/`[`/`]` 倍速与 `D` 弹幕开关 |
| 播放内核 | Android 采用 Media3 + FFmpeg / AV1 / VP9 软解扩展与可选 MPV（[范围与限制](docs/DECODERS.md)）；Apple TV 采用原生 `AVPlayer`（支持 HLS / 4K HDR10 / 杜比视界）；HarmonyOS NEXT 采用原生 ArkTS `AVPlayer` + `XComponent` GPU 硬件纹理；iOS / iPadOS 采用原生 `AVPlayer`（画中画 / AirPlay 2）+ `libmpv` 双引擎自动回退；Windows / macOS 采用 `media_kit`（`libmpv`，Windows 支持三档 HDR 动态色调映射、人声增强与蓝光 `.iso` 流式代理）及可选热切换 `Anime4K v4.0.1` 实时超分 |
| 字幕与弹幕 | 外挂 SRT / VTT / ASS / TTML 字幕及流内音轨/字幕轨切换（字幕严格渲染在弹幕上方）；内置清洁室 30 秒分片弹幕引擎（默认服务地址为空，无碰撞轨道与 ReDoS 防护），仅在用户自行配置兼容服务或导入本地 XML/JSON 弹幕文件后生效，不提供在线弹幕资源 |
| 直播列表 | 读取用户提供的兼容 M3U / TXT 列表与分组；电视端支持遥控快速换台；手机与桌面端提供分组与频道列表点选即播 |
| 配置导入管理 | 电视端（Android TV / Apple TV / 鸿蒙智慧屏）提供同一局域网手机扫码推送、手动输入与备份导入；**手机/平板/桌面端直接提供原生输入框、剪贴板一键粘贴导入与本地 JSON 文件选择**；新增 5 幕独立新手引导（配程序化抽象几何「示例」海报，不内置真实影片或内容源），全端支持配置备份与还原 |
| 跨平台客户端 | 涵盖原生 Android（手机/平板/电视/Lite）、`tvos/` 原生 Apple TV（`tvOS 16.0+` `.ipa`）、`flutter/ohos/` HarmonyOS NEXT 通用包（`API 12+` 手机 / 平板 / 2in1 / 智慧屏单包自适应 `.hap`）及 `flutter/` Windows（x64 `.exe`）、macOS（`.app`）、iOS / iPadOS（`.ipa`），互通 `marco-movie-backup` 备份文件 |
| 多端网络同步 | 全平台（Android 电视 / 手机平板 / Lite、Apple TV、HarmonyOS NEXT、iOS / iPadOS、Windows、macOS）互通 `marco-movie-sync` v2 协议：支持用户自配 WebDAV（坚果云 / NAS / Alist / Nextcloud 等）自动云同步与同一局域网点对点双向免云盘直连同步，合并观看历史进度、我的收藏及可选的公开订阅源配置；严格隔离隐私空间与网盘 / Emby 登录凭据 |
| 软件更新 | 设置内检查更新；镜像优先、GitHub 备用，下载后核对 SHA-256 校验值 |
| 个性化与网盘代理 | 海报配色柔光、极光氛围背景（空态/关于/引导页，按系统减少动态效果自动停帧）、分级转场动效与金属丝带 `M` 品牌加载器、自定义壁纸、界面缩放；全端支持用户本人在夸克 / UC / 百度 / 阿里云盘扫码授权及本机 `127.0.0.1` 6 路并发分片回环代理播放 4K 原画，不内置账号 |

全局搜索的范围是**用户已导入的配置**，不是互联网全网搜索。拼音匹配结合本地字词典和已浏览/搜索过的标题，首拼存在歧义时可改用完整中文。功能存在不代表任意配置或服务都兼容。

## 安装与开始使用

1. 在 [镜像下载页](https://marcotv.wlj9919.top/movie/) 或 [Releases](https://github.com/Pilipala9919/MarcoMovie/releases) 下载对应系统的安装包，并核对随附的 SHA-256 文件。
2. 根据设备选择独立安装包：
   - **Android 设备**：电视/盒子用 `-android-tv.apk`（ARM 32 位），手机/平板用 `-android-mobile.apk`（ARM 32/64 位）；旧 Android 4.0+ 设备选择独立 `-android-lite.apk`。
   - **Apple TV（tvOS 16.0+）**：下载 `-tvos-appletv-unsigned.ipa` 未签名包，通过 Xcode、Sideloadly、自签工具或巨魔（TrollStore tvOS）安装。
   - **HarmonyOS NEXT（API 12+ 手机 / 平板 / 2in1 / 智慧屏）**：下载 `-harmonyos-universal.hap` 通用未签名包，使用 DevEco Studio 自动签名或 `hap-sign-tool` 签名后通过 `hdc install` 安装。
   - **Windows / macOS / iOS**：下载对应 `-windows-x64-setup.exe` / `-windows-x64-portable.zip`、`-macos-desktop.zip` 或 `-ios-iphone-ipad-unsigned.ipa`。最低系统声明不代表已通过每台设备的实测；每次修复与验证范围见[版本记录](CHANGELOG.md)。
3. 打开应用导入配置：
   - **手机 / 平板 / 桌面端**：直接在首页欢迎卡片输入网址，或复制配置链接/JSON 后一键读取剪贴板导入，也可选择本地 JSON 文件，无需扫码。
   - **电视与智慧屏端（Android TV / Apple TV / 鸿蒙智慧屏）**：打开局域网配对二维码，用同一局域网的手机扫码粘贴自行合法获取的配置地址即可推送；也可手动输入或通过 WebDAV 同步导入。本项目不提供获取影视资源的方法或地址。
4. 原生 Android 标准版的扩展执行默认开启，可在设置中关闭；仅导入信任的配置。Apple TV 与 HarmonyOS NEXT 内置 QuickJS-NG 轻量脚本宿主与 CMS / 4K 网盘解析器，不等同于 Android JAR 虚拟机运行环境。
5. 在“设置”中调整解码、倍速、比例、WebDAV 同步和备份选项。需要网盘授权时，应由本人在服务提供方界面扫码完成登录。

同一应用签名的安装包一般可以覆盖升级；自行编译或自签会生成自己的开发签名，不能保证覆盖官方项目发布包。卸载会删除应用本地数据，请先妥善保存必要配置。详细操作见[使用指南](docs/USER_GUIDE.md)。

## 设备与兼容性说明

- **Android**：标准版最低 Android 6.0（API 23），Lite 版最低 Android 4.0（API 14）；当前主要实机验证环境为 Android 9、ARM 32 位电视。
- **Windows / macOS / iOS / iPadOS**：iOS / iPadOS 最低 15.0（Xcode 27.2 / iOS 27.2 SDK 编译下支持真系统级 `UITabBar` + `UIGlassContainerEffect` 液态玻璃宿主、二阶物理弹簧与 `AVPlayer` + `libmpv` 双引擎，iOS 15–18 / iOS 16.4 巨魔自动平滑回退）；Windows x64 内置免安装 Python 3.11.9 运行时、三档 MPV HDR 色调映射与蓝光 `.iso` 流式代理；Windows / macOS 可选热切换 MIT 许可 `Anime4K v4.0.1` 实时超分着色器。
- **Apple TV（tvOS）**：最低 tvOS 16.0（当前版本保持 `0.1.1`）；已通过 Swift 自动化回归与 Xcode Release 云端构建验证，支持 `AVPlayer` 原生播放、QuickJS-NG 脚本源、`marco-movie-sync` v2 及四盘扫码 + 6 路并发 Range 代理，尚未宣称完成全型号物理 Apple TV 真机验收。
- **HarmonyOS NEXT（纯血鸿蒙）**：最低 API 12（HarmonyOS 5.0+，当前版本保持 `0.1.1`），单 HAP 同时适配手机、平板/2in1 与鸿蒙智慧屏（大屏自动切换 10 英尺遥控焦点界面）；已通过 OpenHarmony Flutter 与 DevEco SDK 云端构建打包验证，尚未宣称完成全型号物理鸿蒙真机验收。
- 兼容标准 JSON/XML 内容接口及各端已实现的脚本/网盘扩展形式。没有承诺所有配置、网盘、直播列表、编码或第三方服务都可使用。
- 磁力组件属于 Android 实验能力，要求 Android 8.0+；已完成本地协议测试，尚不作为所有设备上的稳定视频播放能力宣传。
- DRM 仅传递合法授权相关参数，不绕过授权；尚未完成授权样本的端到端验收。

跨端差异和本轮修复状态见[兼容与验证边界](docs/COMPATIBILITY.md)。更多状态见[功能与验证范围](docs/STATUS.md)。遇到问题可提交 [Issue](https://github.com/Pilipala9919/MarcoMovie/issues)，请勿附带账号、Cookie、私有配置地址、二维码或无权分享的内容。

## 项目结构与开发

```text
android-tv/             独立原生 Android TV / 盒子工程（armeabi-v7a）、独立测试与依赖清单
android-mobile/         独立原生 Android 手机 / 平板工程（armeabi-v7a + arm64-v8a）、独立测试与依赖清单
lite/                   独立 Android 4.0+（API 14+）Lite 工程与版本清单
shared/                 跨平台共享层（CatPaw 运行时、跨平台脚本宿主、公共 Java 与一致性样本）
tvos/                   原生 Apple TV（tvOS 16.0+）客户端工程（SwiftUI + AVKit + QuickJS-NG + 6 路网盘代理）
flutter/                跨平台客户端工程（覆盖 Windows / macOS / iPhone / iPad / HarmonyOS NEXT，互通备份与同步）
flutter/ohos/           HarmonyOS NEXT Stage 模型宿主、ArkTS AVPlayer 硬件纹理插件与安全凭据存储插件
scripts/                构建、依赖准备、镜像同步、公开内容检查
docs/                   产品、使用、构建、隐私与验证说明
```

当前构建流程基于 Windows、Python 3、JDK 17 与 Android SDK 工具。构建时从依赖发布方下载清单中固定版本的依赖并校验摘要。详见[构建说明](docs/BUILD.md)；不会下载影视配置或内容。

## 作者与第三方致谢

**Marco Movie · Pilipala**  
GitHub：[@Pilipala9919](https://github.com/Pilipala9919)  
Copyright © 2026 Pilipala

感谢 AndroidX Media3、OkHttp、Okio、Gson、QuickJS 及其 Java 包装库、ZXing、jsoup、CryptoJS、JSONPath、libtorrent / jlibtorrent、Rime 与 Unicode 等项目。它们保留各自作者署名和许可，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。本项目的作者署名不替代第三方版权信息。

原创代码、文档和项目品牌素材按 [GNU GPL v3（GPL-3.0-only）](LICENSE) 发布，另有声明的文件除外。修改与分发时请遵守许可证并保留署名；第三方组件继续适用各自许可。详见 [NOTICE](NOTICE)。

## 捐赠支持

Marco Movie 完全免费开源，捐赠全凭自愿，不影响任何功能。感谢你的支持。

| 微信收款码 | 支付宝收款码 |
| --- | --- |
| <img src="docs/images/donate-wechat.jpg" width="260" alt="微信捐赠收款码"> | <img src="docs/images/donate-alipay.jpg" width="260" alt="支付宝捐赠收款码"> |

## 工具与内容声明

本产品只是工具，不含任何影视资源。仓库及发布包不包含影视片库、站点配置、订阅地址、直播频道资源、第三方内容插件载荷、账号凭据或会员权益。使用者需要自行合法获取配置与内容，并遵守相关服务条款和适用规则。

项目不承诺第三方内容的合法性、准确性、可用性或持续性，不提供绕过付费、访问控制或数字版权保护的功能。这里的说明用于明确产品边界，不意味着可以忽略版权或其他应承担的责任。请不要在本仓库提交资源分享、侵权内容或账号交易请求。

完整说明见 [DISCLAIMER.md](DISCLAIMER.md)，数据处理见[隐私说明](docs/PRIVACY.md)。
