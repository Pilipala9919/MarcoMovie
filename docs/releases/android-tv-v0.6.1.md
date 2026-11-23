# Marco Movie Android 电视 / 盒子 0.6.1

发布日期：2026-11-22。应用版本 `0.6.1`（版本代码 `97`）；最低 Android 6 / API 23。本次发布整合了全部电视端未发布的体验与能力升级，并同步落地完整高画质多内核播放与片源适配升级（MPV 可选高画质内核 + Media3 OkHttp/HDR/响度增强 + HLS 伪装分片实时代理 + 256 KiB 直链分块缓存 + WebResolver 规则/去广告 + WebView 异步 JS 兜底 + 内置 CPython 3.11 运行时）。

## 本次更新

- **可选 MPV 高画质播放内核（`libmpv 0.4.1`）与 Media3 全面增强**：
  - 集成官方 Maven `dev.jdtech.mpv:libmpv:0.4.1`，可在播放菜单或设置页随时切换至 **MPV 高画质内核**（`PLAYER_ENGINE = 3`，保留既有 Exo / IJK / 系统播放器选项且异常时自动回退 Media3），支持 `gpu-next` + `libplacebo` HDR 自动峰值色调映射、`libass` 特效字幕、MIT 许可 `Anime4K_Upscale_CNN_x2_S.glsl` 实时超分滤镜及硬解 Direct-Guard 降级保护；
  - Media3 内核升级为 `media3-datasource-okhttp:1.5.1`（HTTP/2 连接池与断连重试）、基于本机显示能力协商杜比视界基底降级（`hasDisplayDolbyVisionSupport`），并新增 Amlogic / 非广色域电视 HDR 窗体防闪策略（`shouldRequestWindowHdrColorMode`）；
  - 新增 Media3 `LoudnessEnhancer` 与 MPV 音量增益双路**人声/响度增益**（`0..+12 dB`）。
- **片源播放链路与脚本运行时升级**：
  - **HLS 伪装分片实时修正代理（`HlsStreamProxy`）**：仅用 64 KiB 头部流式探测 3×188 字节 `0x47` TS 同步头即可零全片缓冲剥离伪装 PNG/JPG/GIF 头，重写嵌套 m3u8 / Key / Map，并支持可选点播 `#EXT-X-DISCONTINUITY` 广告段启发式过滤；
  - **256 KiB 直链本地分块缓存（`MediaDiskCache`）**：为直链点播提供 `/kcache/<sid>` 落盘分块缓存（完整 HTTP `206` Range 与 `416` 自动降级、LRU 回收，默认 256 MB，支持关闭至 1024 MB 可调）；
  - **配置级嗅探规则与广告拦截（`Cms` / `WebResolver`）**：支持解析配置 `rules`（`hosts` / `regex` / `exclude` / `script` / `click`）与 `ads` 列表，提供广告域名拦截、自动点击脚本注入、Cookie 透传、RTMP/RTSP 直链捕获及 API 26+ `onRenderProcessGone` 渲染进程恢复；
  - **离屏 WebView 异步 JS 兜底与内置原生 CPython 3.11**：QuickJS 遇到 `Promise` / `DOMParser` / ES2022+ 脚本异常时自动回退至离屏 Blink WebView（`WebViewJsEngine`）；内置官方 CPython `3.11.17-0` 与 NDK r28c 编译的 `libmarco_python.so` 桥接（含官方纯 Python `requests` / `urllib3` / `certifi` / `idna` / `charset_normalizer` / `soupsieve` / `pyaes` 与 `Crypto` / `lxml` / `bs4` 兼容层），原生运行 Python 3.11 爬虫源，无需外部 Python 环境。
- **电视端大版本功能与操控体验整合**：
  - **AList 原生网盘源引擎（`AlistAccounts` / `AlistEngine`）**：支持挂载多组 AList 服务、自动令牌刷新、自然集数排序、直链播放及中文字幕自动优先挂载；
  - **智能音轨/字幕记忆与跨源续播兜底**：新增 `SubtitlePreferenceStore`（双语简体中文优先、智能规避口述影像音轨、分剧集记忆偏好）与 `HistoryResumeMatcher`（原源失效时按规范集号与季号自动跨源精准续播）；
  - **电视界面与遥控器精进**：新增 `TvV17WelcomeHomeScreen` 欢迎首页、`TvPlayerToolbarOrder` 播放器工具栏按键自定义排序与焦点浮泡提示、`EpisodeHoldSwitchOverlay` 长按切集浮层、极简标签页 Apple TV 磨砂风格 `DanmuSettingsPanel`、`TvQrInputHelper` / `RemoteInputServer` 扫码远程输入、`SpiderGatewayServer` 局域网爬虫网关、直播分组收藏与屏蔽（`LivePreferences`）、选片筛选（`VideoFilters`）增强及 `CrashReport*` 崩溃报告收集与扫码分享闭环。

## 验证范围与构建记录

- **自动化构建与回归校验（精确构建提交 `36333b602697ec02afeb3587f273acd7f150b27c`）**：
  - 公开内容合规守卫 `scripts/check_public_content.py`（`1562` 追踪文件零告警）、`scripts/sync_readme_versions.py --check` 版本对齐与 `scripts/format_java.py --check`（`286` 个 Java 文件）全部通过；
  - 全部 `33` 组 Android JVM 回归测试套件通过，包括 `HighQualityUpgradeChecks`（`62/62` 项：MPV Direct-Guard、HLS 64 KiB TS 剥离与回环代理、256 KiB 分块缓存与 416 回退、WebResolver 规则/去广告、CPython/WebViewJS 判定）、`TvUxOptimizationChecks`（`219/219` 项：AList、工具栏排序、浮泡定位、弹幕面板、智能音轨字幕、跨源续播、Amlogic HDR 防闪等）、`CmsChecks`（`57` 项）、`CompatChecks`、`Wave2AndroidWireChecks`、`LocalProxyRangeChecks`、`ScriptProxyChecks` 与 `ReviewFixChecks`；
  - 本地官方正式签名构建（`MARCOMOVIE_RELEASE=1`，`git_dirty: false`）通过 `API 23` 回调字节码校验（`726` 个应用类）、`v1/v2/v3` 签名校验与 `zipalign` 对齐校验，并完成 CPython `3.11.17-0` 原生桥接编译。
- **已知边界与限制**：本版本尚未在物理电视/盒子设备上完成覆盖安装与真实片源 4K HDR / MPV / CPython 实机播放验收（`device_install_tested: false`，`device_playback_tested: false`）；Anime4K 与软解/色调映射帧率取决于具体设备 GPU 与散热能力。

## 安装与校验

- **正式包名**：`com.pilipala.marcomovie`（TV edition，`minSdk 23` / `targetSdk 28`；保留同字节兼容别名 `MarcoMovie-0.6.1-preview.apk`）。
- **TV APK SHA-256**：`MarcoMovie-0.6.1-android-tv.apk`（`56510662` B）— `780ccac5c5fe093f8bed1fb2950a3f123044f3338059eb350e30a67a67acf7c6`。
- **对应源码包 SHA-256**：`MarcoMovie-android-tv-v0.6.1-source.zip`（`11053103` B）— `7ae636f2968e638c438f22579524ca5501e8afe7a581f3cdca1e20b91b4b81ab`。
- **官方签名证书 SHA-256**：`2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de`（与既有正式版一致，覆盖安装保留配置、收藏与观看记录）。
- **精确构建提交**：`36333b602697ec02afeb3587f273acd7f150b27c`。
- **跨端隔离**：本次同步独立发布 Android 电视/盒子（`android-tv-v0.6.1`）与 Android 手机/平板（`android-mobile-v0.6.0`），Android Lite（`0.5.8`）、Windows（`0.6.0`）、macOS（`0.5.20`）、iOS/iPadOS（`0.6.1`）、Apple TV 与 HarmonyOS NEXT 保持不变。
