# Marco Movie Android 手机 / 平板 0.6.0

发布日期：2026-11-22。应用版本 `0.6.0`（版本代码 `98`）；最低 Android 6 / API 23，完整提供 `armeabi-v7a` + 16 KB 页面对齐 `arm64-v8a` 双架构原生库。本次升级同步补齐高画质多内核播放、完整片源代理/缓存/嗅探/运行时生态，以及 AList 原生引擎、智能音轨字幕记忆、跨源续播与崩溃上报等最新能力。

## 本次更新

- **可选 MPV 高画质播放内核（`libmpv 0.4.1`）与 Media3 全面增强**：
  - 集成官方 Maven `dev.jdtech.mpv:libmpv:0.4.1`（32/64 位双 ABI），可在播放页或设置页切换至 **MPV 高画质内核**（`PLAYER_ENGINE = 3`，异常自动回退 Media3），内置 `gpu-next` + `libplacebo` HDR 自动峰值色调映射、`libass` 特效字幕、MIT 许可 `Anime4K_Upscale_CNN_x2_S.glsl` 实时超分滤镜与 Direct-Guard 硬解保护；
  - Media3 内核升级为 `media3-datasource-okhttp:1.5.1`（HTTP/2 连接池）、基于显示能力协商杜比视界基底降级（`hasDisplayDolbyVisionSupport`），并新增 Media3 `LoudnessEnhancer` 与 MPV 双路**人声/响度增益**（`0..+12 dB`）；
  - 同步在 `MobileIosSettings` 与 `MobileShell` 设置页中开放 MPV 内核、HDR 色调映射、Anime4K 超分、HLS 代理/广告过滤、本地分块缓存容量、响度增益、内置 CPython 与 WebView JS 兜底开关。
- **片源适配与代理缓存全面升级**：
  - **HLS 伪装分片实时修正代理（`HlsStreamProxy`）**：64 KiB 头部流式探测 3×188 字节 `0x47` TS 同步头，零全片缓冲剥离伪装 PNG/JPG/GIF 头，重写嵌套 m3u8 / Key / Map，并支持可选点播 `#EXT-X-DISCONTINUITY` 广告段启发式过滤；
  - **256 KiB 直链本地分块缓存（`MediaDiskCache`）**：支持 HTTP `206` Range 与 `416` 回退、LRU 容量管理（默认 256 MB，支持关闭至 1 GB 可调）；
  - **配置级嗅探规则与广告拦截（`Cms` / `WebResolver`）**：解析 `rules`（`hosts` / `regex` / `exclude` / `script` / `click`）与 `ads` 广告域名，支持广告拦截、脚本自动点击、Cookie 透传、RTMP/RTSP 直链捕获与 API 26+ 渲染进程崩溃恢复；
  - **离屏 WebView 异步 JS 兜底与内置原生 CPython 3.11**：QuickJS 遇 `Promise` / `DOMParser` / ES2022+ 脚本异常自动回退至离屏 Blink WebView（`WebViewJsEngine`）；内置官方 CPython `3.11.17-0` 与 16 KB 页面对齐 `arm64-v8a` / `armeabi-v7a` `libmarco_python.so` 桥接及官方纯 Python 依赖包（`requests` / `urllib3` / `certifi` / `idna` / `charset_normalizer` / `soupsieve` / `pyaes` + `Crypto` / `lxml` / `bs4` 兼容层）。
- **核心片源、音轨字幕与诊断能力同步增强**：
  - 集成 **AList 原生网盘源引擎（`AlistAccounts` / `AlistEngine`）**、**智能音轨与字幕记忆（`SubtitlePreferenceStore`）**、**跨源失效自动续播匹配（`HistoryResumeMatcher`）**、**新版磨砂弹幕设置面板（`DanmuSettingsPanel`）**、**直播分组收藏与屏蔽（`LivePreferences`）** 以及 **崩溃日志收集与上报（`CrashReport*`）**。

## 验证范围与构建记录

- **自动化构建与回归校验（精确构建提交 `36333b602697ec02afeb3587f273acd7f150b27c`）**：
  - 公开内容合规守卫 `scripts/check_public_content.py`（`1562` 追踪文件零告警）、`scripts/sync_readme_versions.py --check` 版本对齐与 `scripts/format_java.py --check`（`286` 个 Java 文件）全部通过；
  - 全部 `33` 组 Android JVM 回归测试套件通过（含 `HighQualityUpgradeChecks` `62/62`、`TvUxOptimizationChecks` `219/219`、`CmsChecks` `57/57`、`CompatChecks`、`Wave2AndroidWireChecks`、`LocalProxyRangeChecks`、`ScriptProxyChecks`、`ReviewFixChecks`）；
  - 本地官方正式签名构建（`MARCOMOVIE_RELEASE=1`，`git_dirty: false`）通过 `API 23` 回调字节码校验（`726` 个应用类）、`arm64-v8a` 16 KB 页面对齐校验、`v1/v2/v3` 签名与 `zipalign` 校验。
- **已知边界与限制**：本版本尚未在物理手机/平板设备上完成覆盖安装与真实片源 4K HDR / MPV / CPython 实机播放验收（`device_install_tested: false`，`device_playback_tested: false`）；Anime4K 与色调映射耗电/帧率取决于设备 SoC 性能。

## 安装与校验

- **正式包名**：`com.pilipala.marcomovie`（Mobile edition，`minSdk 23` / `targetSdk 28`；保留同字节兼容别名 `MarcoMovie-0.6.0-mobile.apk`）。
- **Mobile APK SHA-256**：`MarcoMovie-0.6.0-android-mobile.apk`（`100442580` B）— `addd9a3ae3a205dbbe4201730d14f0a0647916df02b21662c9bf793e03cd4fc2`。
- **对应源码包 SHA-256**：`MarcoMovie-android-mobile-v0.6.0-source.zip`（`11053103` B）— `7ae636f2968e638c438f22579524ca5501e8afe7a581f3cdca1e20b91b4b81ab`。
- **官方签名证书 SHA-256**：`2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de`（与既有正式版一致，覆盖安装保留配置、收藏与观看记录）。
- **精确构建提交**：`36333b602697ec02afeb3587f273acd7f150b27c`。
- **跨端隔离**：本次同步独立发布 Android 电视/盒子（`android-tv-v0.6.1`）与 Android 手机/平板（`android-mobile-v0.6.0`），Android Lite（`0.5.8`）、Windows（`0.6.0`）、macOS（`0.5.20`）、iOS/iPadOS（`0.6.1`）、Apple TV 与 HarmonyOS NEXT 保持不变。
