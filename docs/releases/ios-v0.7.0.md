# Marco Movie iOS / iPadOS 0.7.0

发布日期：2026-11-23。应用版本 `0.7.0`（构建号 `93`），基于 Xcode `27.2` / iOS `27.2` SDK 编译，并完整保持 `MinimumOSVersion = 15.0` 向下兼容 iOS / iPadOS `15.0+` 及 iOS `16.4` 巨魔（TrollStore）安装。本次大版本更新围绕 **真·iOS 27 原生液态玻璃交互重构**、**AVPlayer + libmpv 双引擎画中画与人声增强** 以及 **内置 CPython 3.14 生态补齐与 HLS 分块缓存/去广告** 三大方向全面升级。

## 更新内容

- **真·iOS 27 原生液态玻璃宿主体系与二阶物理弹簧动效（`MarcoLiquidGlass.swift` / `Ios27Spring`）**：
  - 根控制器升级为真系统原生 `UITabBar` + `UIGlassContainerEffect` 宿主（`configureRootTabChrome` / `setRootTabSelectedIndex` / `setRootTabMinimized` / `setRootTabVisible`）与真 `UIButton.Configuration.glass()` / `.prominentGlass()`，支持滚动连续最小化、横竖屏自适应与二级页面/全屏播放页无缝弹簧隐显，彻底取代旧版非原生底部模拟胶囊；
  - 新增原生 `UIContextMenuInteraction` 长按预览菜单、无箭头原位生长液态菜单、底部/侧边内缩同心圆角悬浮半屏面板（`Ios27LiquidSheet`）以及原位流体缩放转场（`.zoom` 风格路由）；
  - 全域动效与手势交互对齐 `Ios27Spring`（`.snappy` / `.smooth` / `.bouncy`）二阶物理弹簧模型（支持中途打断速度继承），并在 iOS 15–18 / 巨魔环境与开启「减弱动态效果 / 降低透明度」时自动平滑回退。
- **AVPlayer + libmpv 双引擎、自动画中画（PiP）、AirPlay 2 与高阶视听增强（`MarcoAvPlayerEngine.swift` / `IosMpvProfile`）**：
  - 新增 Apple 原生低功耗 `AVQueuePlayer` 播放引擎，支持 `AVPictureInPictureController`（含 `canStartPictureInPictureAutomaticallyFromInline` 上滑退后台自动开启小窗画中画及前台恢复）、AirPlay 2 隔空投屏选择器与原生字幕/音轨切换；
  - 智能双核协同：标准 HLS / MP4 优先走低功耗原生 `AVPlayer`；遇到 `.mkv` / `.flv` / `.avi` / `.ts`、外挂 `.ass`/`.ssa` 特效字幕或流内解码异常时，自动在当前毫秒级播放进度无缝回退 `libmpv` 续播；
  - 优化 iOS `libmpv` 内存分级（`< 6 GB` 内存设备默认 `64 MiB`，`>= 6 GB` 设备支持 `128 MiB` 大缓冲开关）、HDR 自动峰值色调映射、4 档动态人声响度增强（`dynaudnorm`）以及 Apple Silicon A15+ / M 系轻量化单通道 `Anime4K_Upscale_CNN_x2_S.glsl` 实时超分（内置 `ProcessInfo.thermalState` 过热自动关闭保护）。
- **片源播放链路补齐、离线分块缓存、HLS 去广告与内置 CPython 3.14 扩容**：
  - 新增直链 `256 KiB` 对齐分块落盘缓存（`DiskBlockCache`，支持 HTTP `206` Range、`416` 自动降级回退、LRU 容量淘汰，`Off / 128 MB / 256 MB / 512 MB` 可调与一键清理）及点播 `#EXT-X-DISCONTINUITY` HLS 短广告段启发式剔除（直播流零误伤）；
  - 打通 `CmsClient` -> `WebMediaResolver` 配置级 `rules` / `ads` 规则透传与 `MarcoWebSnifferAndJsHost.swift`（原生 `WKContentRuleList` 广告拦截、自动点击嗅探与离屏 `WKWebView` 异步 JS / DRPY2 兜底引擎）；
  - 内置 iOS CPython `3.14` 运行时新增锁定官方 `pyquery` + `cssselect` wheel，补齐 TVBox `Spider` / `localProxy` / `getDependence` 兼容垫片，并将并发 Python 会话池扩容至 `4`（LRU 回收）。

## 包信息与构建记录

- **未签名 IPA（iPhone / iPad / iPhone Duo 通用）**：`MarcoMovie-0.7.0-ios-iphone-ipad-unsigned.ipa`（`63924528` B，更新兼容别名 `MarcoMovie-0.7.0-ios-unsigned.ipa`），SHA-256：`d24a947cae3e9d26a536fde11a113bac95a0c5ef986114ce3ecdf1ffbe891e26`。
- **对应源码包**：`MarcoMovie-ios-v0.7.0-source.zip`（`11341454` B），SHA-256：`2d354caaead240870789f408e22f848bc1cb553ff79fea4c304d4f6bfd7ebb5d`。
- **构建提交与 CI 记录**：`45b1d3c4a3fe3ea2696ffa3c8e484754b26fa6af`。[iOS / iPadOS 原生构建与全量测试（Job 137341995146 · Run 45065556517）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45065556517/job/137341995146) / [公开守卫与离线校验（Job 137340782837）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45065556517/job/137340782837) / [Public content checks（45065556562）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45065556562)。

## 验证范围与已知限制

- **自动化与云端构建校验**：在提交 `45b1d3c4a3fe3ea2696ffa3c8e484754b26fa6af` 上通过了 GitHub Actions 7 平台全绿构建（Run `45065556517`）、macOS 云端 Runner 全套 Flutter 自动化测试（`1314` 项通过、`15` 项非 iOS 平台专属跳过）、Xcode `27.2`（`iphoneos27.2`）Release `.ipa` 打包与全量内嵌 Mach-O `minos <= 15.0` 校验、`scripts/test_ios_python_packaging.py`、`flutter/test_ios_package.py`、`scripts/check_public_content.py`（`1595` 文件）及 `scripts/sync_readme_versions.py --check`。本轮 `0.7.0` 尚未宣称完成全型号物理 iPhone / iPad 真机安装与实机播放验收。
- **已知限制**：未签名 `.ipa` 需通过 TrollStore（巨魔）或个人自签工具安装；真系统级 `UIGlassContainerEffect` / `UIButton.Configuration.glass()` 需运行在支持 Liquid Glass 的新系统版本上（iOS 15–18 自动采用高保真磨砂回退）；第三方直播源与片源可用性取决于用户自行导入的上游服务及网络环境。
