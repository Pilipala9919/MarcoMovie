# 功能与验证范围

各端独立版本与发布状态见[平台发布记录](platform-releases.md)。以下能力矩阵与分版本检查保留历史范围；本轮订阅、历史记录、字幕与兼容修复见[2026-11-07 验证记录](subscription-compatibility-2026-11-07.md)。正式版不等于全设备、全配置无条件兼容。

## 当前能力矩阵

| 模块 | 当前支持范围 | 已知边界与限制 |
|---|---|---|
| 配置导入与引导 | 电视端支持局域网手机扫码/网页表单推送、遥控器 HTTP(S) 地址输入；手机/平板/桌面端支持剪贴板一键粘贴、系统输入法直接输入、本地 JSON 文件导入；全端支持设置与配置备份还原；新增 5 幕独立新手引导（触控/宽屏/TV 遥控）与 `14` 张程序化生成的「示例」海报及首播操作提示 | 不内置、不提供、不托管任何配置地址、影视资源或真实海报；本地文件操作依赖系统文件选择器 |
| 点播来源 | 标准 JSON CMS（`type=1`）、实验性普通 `csp_` JAR 插件（`type=3`，需手动开启）、QuickJS / Python 脚本源、可插拔本地脚本扩展包与可选自建网关 | 混淆/加壳或强绑定特定宿主私有实现的第三方插件不保证兼容 |
| 全局搜索 | 电视端内置全拼/首拼词库与已浏览标题学习；手机/平板端直接调起系统输入法软键盘（iOS 全屏液态玻璃搜索支持同名智能聚合）；多源并发有界调度、单源超时隔离与重试、目录型结果继续展开 | 拼音词库为有限静态词表 + 本地学习，不保证所有生僻缩写均可反查 |
| 详情页与规格徽章 | Java / API 14 Lite（`LiteBadges` 纯文本） / Flutter 三端共享 `45` 条规则与 `3` 条组合规则（`165/165` 黄金样例零差异），统一输出 `4K`、`HDR10+`、`DV · ATMOS`、`DD+ 5.1` 等纯文字规格徽章并保留 `'+'` 号 | 全部为纯文字排版胶囊，不包含第三方商业商标图形；真实码率与动态范围仍以播放内核实际解析为准 |
| 播放器、手势与超分 | Android 采用 Media3（含 FFmpeg 音频、dav1d AV1、libvpx VP9 软解扩展），升级 `PlayerGestureStateMachine`（长按 `2.0×` → 横滑 `1.25×–3.0×` → 上滑 `48dp` 锁定、双击区域自定义）、常驻细进度条、起播规格提示、`3` 秒跳过倒计时与定时关闭；Flutter 端采用 `media_kit`（`libmpv`），iOS 26 重构同心液态玻璃 `IosPlayerChrome`（零多 `UiKitView` 切片、原生半屏面板），桌面端 `DesktopPlayerHud`（`2.5s` 隐藏、滚轮音量、`←`/`→` 预览、`S`/`[`/`]`/`D` 快捷键）并在 Windows / macOS 新增 `Anime4K v4.0.1` 实时超分（Windows 关闭时恢复 `bilinear`） | 4K/HDR 与 Anime4K 表现取决于设备硬件解码器与 GPU 性能；合成样本验证不代表所有真实片源或高码率真机帧率 |
| 字幕与弹幕 | 外挂 SRT / VTT / ASS / TTML 字幕及流内音轨/字幕轨切换，渲染层级严格位于弹幕上方；内置清洁室 `30` 秒分片弹幕引擎（`mmdanmu://v1` 来源绑定、有符号时钟、三窗口跨界、`HTTP 410` 单飞重试、`180ms` Seek 防抖、运动学尾缘无碰撞轨道与 `O(N)` 静态 ReDoS 拦截器，Android TV `P90` 自适应降行 `2..8` 行） | 默认弹幕服务地址为空 `""`，不内置或提供在线弹幕服务器/密钥，仅在用户配置兼容服务或导入本地 XML/JSON 弹幕后生效 |
| 转场与动效 | 分级详情进播放器转场（Android API 33+ AGSL / API 23–32 `RenderNode` + 冻结 `GlassworkSurface` / TV `<= 220ms` 零模糊缩放；Flutter `player_enter.frag` + `IosNativeRouteGate.runWithPlaceholders` + 三重降级 / Windows 快速缩放回退）、空态/关于/引导页 `aurora` 极光背景及 `1.6s` F8 金属丝带 `M` 加载器 | Android TV 端严禁着色器与实时模糊；Windows 保持 `winFastGlass` 无模糊高速面板 |
| 直播与磁力 | M3U / TXT 直播源解析、频道分组、多源高清优选、XMLTV EPG 与回看、Emby Live TV、电视上下台/数字键选台、手机左右双栏触控选台、失败自动切源；`magnet:?` 顺序分片校验流式播放 | 磁力播放需 Android 8.0+（API 26+）且受限于种子连接数与本机可用缓存空间 |
| 应用内更新与同步 | 镜像与 GitHub 双源版本检查、SHA-256 摘要校验、包名/版本递增/同签名证书校验；全端互通 `marco-movie-sync` v2（WebDAV + 局域网双向同步）与 `marco-movie-backup` | 仅对同签名更新包放行；不静默后台安装；隐私空间与网盘凭据严格隔离本机 |
| 多端专属界面与跨平台 | Android 电视（V17 沉浸界面）、手机/平板（`MobileShell`）、Lite（API 14 单 DEX）；`flutter/` 覆盖 Windows / macOS / iOS / iPadOS；Apple TV（`tvos/`，`0.1.1`）与 HarmonyOS NEXT（`flutter/ohos/` + `flutter/lib/ui/tv/`，`0.1.1`）在本轮保持只读不改 | 新增 Flutter 能力均通过 `!OhosRuntime.isOhos` 隔离；Flutter 端不支持 Android 专属 `.jar` 插件 |

## 当前发行版本验证范围（2026-11-21 · 构建提交 `78017bfb`）

1. **公开合规、版本对齐与代码格式守卫**：
   - `scripts/check_public_content.py`：`1513` 个追踪文件零告警通过（GitHub Actions `44857333149` / `44857333769`）。
   - `scripts/sync_readme_versions.py --check` 零漂移通过；`scripts/format_java.py --check`（`261` 个 Java 文件）通过。
2. **Android / TV / Lite 构建、API 23 与 JVM 校验（`78017bfb` 构建实测 + 基线回归）**：
   - 在构建提交 `78017bfb` 上通过 GitHub Actions Guardrails 校验（`CmsChecks` `57` 项、`DanmuEngineChecks` `294` 断言、`Glasswork` `14` 场景与 Android 编译校验）及本地 `MARCOMOVIE_RELEASE=1` 官方签名构建（`API 23` 字节码校验 `627` 应用类、`native Guard import` `170` 项、`v1/v2/v3` 签名与 `zipalign` 校验）。
   - Lite API 14 单 DEX 构建与校验（`78017bfb`）：API 14 `bootclasspath` 与 `D8 --min-api 14` 单 DEX 编译、`194` 项 TV Lite JVM 检查、`8` 项 TLS 检查，全部通过。
   - 前序基线（`82f38cd2`）已通过全套 `android/tests/run_checks.py`（`CloudSyncChecks` `96`、`SecureStorageChecks` `47`、`MediaBadgeChecks` `165/165`、`PlayerGestureChecks` `190`、`MotionTokenChecks` `965`、`OnboardingStateChecks` `114`、`Wave2AndroidWireChecks` `397`）及 `run_compat_checks.py`、`run_review_fix_checks.py`、`run_seek_checks.py`、`run_player_lock_checks.py`、`run_tv_v17_marker_checks.py`、`run_tv_v17_safety_checks.py`、`run_conformance_checks.py`（`20/20`）与 `test_lite_conformance.py`（`18` 通过、`2` 跳过）。
3. **Flutter 跨端测试与多平台云端构建（`78017bfb` · Run `44857333769` 全 7 任务通过）**：
   - Windows x64 Runner：`1179` 项 Flutter 测试通过（`9` 项非桌面平台专属跳过）+ `13` 项 `libmpv-2.dll` 打包回放检验通过，产出 Inno Setup `.exe` 与绿色便携 `.zip`。
   - macOS Runner：`1179` 项 Flutter 测试通过（`9` 项非桌面平台专属跳过）+ `3` 项 `Mpv.framework/Mpv` 打包回放检验通过，产出通用 `.zip`；Guardrails Runner 完成 `34` 项 Flutter 三端规范一致性测试。
   - iOS Runner：Xcode `26.6`（iOS `26` SDK）下 `1179` 项 Flutter 测试通过（`9` 项专属跳过），产出通用未签名 `.ipa`；Apple TV 与 HarmonyOS NEXT 云端构建任务亦保持全绿（代码与版本号维持 `0.1.1` 不变）。

## 0.4.16 验证范围

1. **纯 JVM 离线回归测试（173 项断言全部通过）**：
   - `run_checks.py`（13 项）：CMS JSON/XML 解析、分页、分类、多线路与特殊字符处理。
   - `run_live_checks.py`（19 项）：M3U / TXT / TVBox 直播分组、请求头继承、重定向与空列表防呆。
   - `run_seek_checks.py`（20 项）：电视遥控长按快进加速曲线、触屏防抖阈值、水平滑动快进映射、左半屏亮度与右半屏音量垂直手势映射。
   - `run_review_fix_checks.py`（43 项）：`SingleFlight` 并发合并、选集正倒序分页定位、`ImageDecodePolicy` 海报采样与内存缓存预算、`Prefs` 28 项白名单与范围守卫、`AppLog` 环形诊断日志、`TvLayoutPolicy` 电视/平板/手机三形态密度与响应式列数。
   - `run_update_checks.py`（51 项）：更新策略、断点续传、证书签名校验与窗口密度计算。
   - `run_tv_input_checks.py`（27 项）：局域网扫码配对服务同源安全校验与直播数字键选台。
2. **多平台云端构建验证**：
   - GitHub Actions `Build Multiplatform` 工作流通过公开内容合规守卫、Windows x64 Release、macOS Release 与 iOS/iPadOS Release 构建及 `flutter test` 单元测试。
3. **电视端基线延续（0.4.15）**：
   - 同一 Android 9 电视通过 139 项定向检查：详情与排序 25、播放器交互 75、搜索与续播 39。

音量为 0，结束保持电视开机。

过往版本（0.3.0 – 0.4.14）的逐轮验证范围已归档至 [历史版本验证记录](history/VERIFICATION_HISTORY.md)，公开合规检查见 [PUBLICATION_CHECKS.md](PUBLICATION_CHECKS.md)，性能与帧率基线见 [EXPERIENCE_REVIEW.md](EXPERIENCE_REVIEW.md)。

为保护私有配置和内容信息，真实服务名称、测试影片、播放地址、账号状态和带内容画面的截图不随仓库发布。本地自动检查使用模拟数据；没有这些真实记录并不意味着可对所有服务作出保证。

## 仍在完善

- **已发行与待实机验证项（`a919dfd9` / `45b1d3c4` / `0e1ed283` / `36333b60` / `40795cc8` / `1706e22e` / `9cb86ed2` / `78017bfb`）**：
  - Windows `0.7.1`（构建号 `78`）已完成提交 `a919dfd9` 公开合规守卫（`1601` 追踪文件，Run `45112032114`）、7 平台全绿云端构建（Run `45112032102` Jobs `137486329825` / `137487699037`，验证随包共存 `fvp.dll` / `mdk.dll` / `ffmpeg-9.dll` / `libass.dll` / `libmpv-2.dll` 与内置 Python `3.11.9` / CatPaw 运行时）、本地 Windows `1336` 项全量 Flutter 测试与 `libmpv-2.dll` 校验，以及 `windows-v0.7.1` GitHub Release 独立发行（安装版 `ae13048d...` / 便携版 `1a992fc9...`）；尚未覆盖所有代际 Intel / AMD 核显实机与全部第三方站点；
  - iOS / iPadOS `0.7.0`（构建号 `93`）与 Windows `0.7.0`（构建号 `77`）已完成提交 `45b1d3c4` 公开合规守卫（`1595` 追踪文件，Run `45065556562`）、7 平台全绿云端构建（Run `45065556517` Jobs `137340782837` / `137341995146` / `137341995186`，Xcode `27.2` + `MinimumOSVersion = 15.0`）、本地 Windows `1329/1329` 全量测试（含 `libmpv-2.dll` 与内置 Python `3.11.9` 自检）以及 `ios-v0.7.0`（`d24a947c...`）与 `windows-v0.7.0`（安装版 `eb16bf2b...` / 便携版 `2d01cf4c...`）GitHub Releases 独立发行；iOS `0.7.0` 尚未完成全型号物理真机覆盖安装验收，Windows `BlurayIsoProxy` 不包含商业加密蓝光 DRM 解密能力；
  - Android 电视 / 盒子 `0.6.2`（版本代码 `99`）已完成构建提交 `0e1ed283` 公开合规检查（`1567` 追踪文件）、`288` 个 Java 文件格式校验、`736` 个应用类 `API 23` 字节码回调校验、全部 `35` 组 Android JVM 回归套件（含 `Tv061FeedbackChecks` `41/41`、`HighQualityUpgradeChecks` `62/62`、`TvUxOptimizationChecks` `219/219`）、官方正式签名打包（`2549f01e...`）及 `android-tv-v0.6.2` GitHub Release 独立发行；本版本尚未完成物理电视/盒子的覆盖安装、真实多订阅在线刷新、网盘实机扫码及 4K / MPV 实机播放验收（`device_install_tested: false`，`device_playback_tested: false`）；
  - Android 电视 / 盒子 `0.6.1`（版本代码 `97`）与 Android 手机 / 平板 `0.6.0`（版本代码 `98`）已完成构建提交 `36333b60` 公开合规检查（`1562` 追踪文件）、`286` 个 Java 文件格式校验、`726` 个应用类 `API 23` 字节码回调校验、全部 `33` 组 Android JVM 回归套件（含 `HighQualityUpgradeChecks` `62/62`、`TvUxOptimizationChecks` `219/219`）、官方正式签名打包（`2549f01e...`）及 `android-tv-v0.6.1` / `android-mobile-v0.6.0` GitHub Releases 独立发行；本版本尚未完成物理电视与物理手机的覆盖安装及真实 4K HDR / MPV / CPython 实机播放验收（`device_install_tested: false`，`device_playback_tested: false`）；
  - iOS / iPadOS `0.6.1`（构建号 `92`）已完成提交 `40795cc8` 公开守卫（Run `45018299860`）、跨端源回归（Run `45018299853`）、iOS 内嵌源运行时回归（Run `45018299948`）、7 平台全绿云端构建与 `1234/1234` Flutter 自动化测试（Run `45018299947` Jobs `137202253551` / `137202221820`，Xcode `27.2` / `iphoneos27.2` + `MinimumOSVersion = 15.0`）、物理 iPhone 多轮真机交互与日夜模式实测验收，以及 `ios-v0.6.1` GitHub Release 独立发行（`8f1616c9...`）；
  - Android 电视 / 盒子 `0.6.0`（版本代码 `96`）已完成提交 `1706e22e` 公开守卫（Run `44915956588`）、Android 云端构建校验（Run `44915956538` Jobs `136881495162` / `136882734363`）、`52/52` TV UX 专项回归、物理 Xiaomi `MiTV-ASTP0`（Android 9，1.5 GB RAM）实机低内存崩溃根治与全链路界面/播放验收，以及 `android-tv-v0.6.0` GitHub Release 独立发行（`f368ff08...`）；
  - Windows `0.6.0`（构建号 `76`）已完成提交 `9cb86ed2` 云端 7 任务全绿构建（Run `44884390833` / `44884390802` / `44884390814`）、物理 Windows 实机界面/直播端到端验证及 `windows-v0.6.0` GitHub Release 独立发行；
  - 其余 3 个近期变动端（Android 手机/平板 `0.5.27`、Android Lite `0.5.8`、macOS `0.5.20`）维持 `78017bfb` 已发行版本，对应物理设备 A/B 对照实机验收仍待继续补齐；
  - Apple TV 与 HarmonyOS NEXT（`0.1.1`）本轮未作功能改动，且本地未安装 HarmonyOS `hvigorw` 编译工具链，未执行本地 `.hap` 打包。
- 全部网盘授权流程、任意扩展或直播列表、长时间播放、所有解码器、DRM 授权样本和磁力视频的电视端表现均未完成穷尽验证。配置导入成功不等于可用；第三方服务还可能随时变更。

持久媒体缓存、渲染视图切换等尚未完成。某些文件操作依赖电视的系统文件选择器。不会把未实现功能作为已有能力展示。
