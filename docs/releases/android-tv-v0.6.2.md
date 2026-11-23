# Marco Movie Android 电视 / 盒子 0.6.2

发布日期：2026-11-23。应用版本 `0.6.2`（版本代码 `99`）；最低 Android 6 / API 23。本次发布为针对电视端 `0.6.1` 用户反馈的专项修复与多源体验升级：根治播放器释放态空指针闪退与 `libmpv` 原生 `SIGABRT` 崩溃，新增订阅源每日自动更新、多源导入自动分组以及网盘中心与各订阅源配置中心的统一兼容。

## 本次更新

- **修复 0.6.1 播放页闪退与 `libmpv` 原生崩溃（`SIGABRT`）**：
  - 修复播放器释放后定时进度/状态查询访问空 `ExoPlayer` 引发的 `NullPointerException`（崩溃指纹 `0132b0f66069`）：在 `MoviePlayer` 全量公开查询、暂停、分辨率、规格徽章与解码诊断接口补齐 `released || exo == null` 守卫；
  - 强化原生 `libmpv` 生命周期与 32 位电视内存控制：`MpvPlayer` 初始化默认采用 `vo="null"` / `force-window="no"`，在切换 `Surface` 及销毁前先显式切回 `vo="null"` 再解绑表面，初始化异常时立即回收原生句柄；32 位 `armeabi-v7a` 设备限制 `demuxer-max-bytes` 为 `32 MiB` 并关闭高开销 `hdr-compute-peak`，同步补齐 `mediaBadges()`、`isHdrVideo()`、音轨/字幕轨及 HDR 回调；
  - `PlaybackController` 对 DRM 加密流自动跳过 MPV，并在 MPV 初始化抛异常时平滑回退至 `MoviePlayer`（Media3），避免点击播放或切内核直接闪退。
- **导入订阅源每日自动更新（`SubscriptionManager` / `SourceController`）**：
  - 新增 24 小时周期订阅源自动刷新机制（默认开启，可在设置页「每日自动更新订阅」开关控制，或随时在设置页及「切换源 / 仓库管理」点击「立即刷新订阅」手动触发）；
  - 冷启动延后与返回前台静默检查到期订阅，检测到播放器正在播放时自动推迟绝不打断观影；刷新采用原子校验（新配置校验合法后才覆盖，保留本地缓存与用户在片源管理中的启用/隐藏自定义），并记录每个订阅的最后更新时间戳与状态。
- **支持导入多个订阅源并自动分组**：
  - 新增纯 Java 多源解析与合并分组引擎（`SubscriptionManager`）：手机扫码推送网页与电视手动地址输入框均支持一次粘贴多行订阅地址（可选「与当前源合并」复选框，支持 `分组名,URL` 自定义分组名），自动为每个订阅的站点打上来源分组标签、保留各自独立的 `jar`/`api`/`ext` 依赖、确定性消解重名 `site.key` 冲突并按来源公平上限合并；
  - 「切换源 / 仓库管理」新增「多源合并 / 删除」以及子仓库多选合并（`勾选多个子仓库合并并自动分组`），可随时将多个已添加订阅源或子仓库一键合并并自动分组。
- **网盘中心弹窗与各订阅源「配置中心」全面兼容**：
  - 自动发现当前订阅（含多源合并分组）内的全部配置中心站点，支持按当前分组优先匹配并在网盘弹窗顶部显式展示当前绑定的配置中心名称与一键「切换配置中心」按钮；
  - 夸克、UC、百度网盘、阿里云盘四盘快捷按钮直达所选配置中心对应网盘登录动作（非标准 MyDrive 驱动自动降级打开对应动态配置中心页，不再死锁报错），新增「更多网盘 (115/天翼…)」与「打开当前配置中心」直达入口；登录状态按配置中心独立隔离记录，并扩展 115 / 天翼 / 移动 / 123 / 迅雷等 Cookie 文件识别。

## 验证范围与构建记录

- **自动化构建与回归校验（精确构建提交 `0e1ed283e8b6fe5eb44b006e03ac9dc795465cdf`）**：
  - 公开内容合规守卫 `scripts/check_public_content.py`（`1567` 追踪文件零告警）、`scripts/sync_readme_versions.py --check` 版本对齐与 `scripts/format_java.py --check`（`288` 个 Java 文件）全部通过；
  - 全部 `35` 组 Android JVM 回归测试套件全量通过，包括新增 `Tv061FeedbackChecks`（`41/41` 项：覆盖 `MoviePlayer` 释放空守卫、`MpvPlayer` 生命周期/32 位缓存与徽章回调、多源解析与自动分组、`ConfigTransferServer` 批量推送、24 小时自动刷新调度、多配置中心路由与状态隔离）、`HighQualityUpgradeChecks`（`62/62` 项）、`TvUxOptimizationChecks`（`219/219` 项）、`ConfigLibraryChecks`（`13` 项）、`TvInputChecks`（`27` 项）、`UpdateChecks`（`45` 项）、`GuardChecks`（`170` 项）与 `ConformanceChecks`（`20/20` 项）；
  - 本地官方正式签名构建（`MARCOMOVIE_RELEASE=1`，`git_dirty: false`）通过 `API 23` 回调字节码校验（`736` 个应用类）、`v1/v2/v3` 签名校验与 `zipalign` 对齐校验，并完成 CPython `3.11.17-0` 原生桥接编译。
- **已知边界与限制**：本版本尚未在物理 Sony / TCL 等电视与盒子设备上完成覆盖安装、真实多订阅源在线刷新、网盘真实账号扫码或长时间 4K / MPV 实机播放验收（`device_install_tested: false`，`device_playback_tested: false`）；各第三方订阅源配置中心的自定义交互与外部接口仍取决于其自身规范。

## 安装与校验

- **正式包名**：`com.pilipala.marcomovie`（TV edition，`minSdk 23` / `targetSdk 28`；保留同字节兼容别名 `MarcoMovie-0.6.2-preview.apk`）。
- **TV APK SHA-256**：`MarcoMovie-0.6.2-android-tv.apk`（`56531142` B）— `d0cc7e019d67c1b2a4b7769893cf3305c6c645add08536b06ff320f5c957f2bc`。
- **对应源码包 SHA-256**：`MarcoMovie-android-tv-v0.6.2-source.zip`（`11195809` B）— `362bf5d9b7425d5b6950866209c771a0b0854438cdae88521db799e1e6c33371`。
- **官方签名证书 SHA-256**：`2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de`（与既有正式版一致，覆盖安装保留配置、收藏与观看记录）。
- **精确构建提交**：`0e1ed283e8b6fe5eb44b006e03ac9dc795465cdf`。
- **跨端隔离**：本次仅独立发布 Android 电视/盒子（`android-tv-v0.6.2`），Android 手机/平板（`0.6.0`）、Android Lite（`0.5.8`）、Windows（`0.6.0`）、macOS（`0.5.20`）、iOS/iPadOS（`0.6.1`）、Apple TV（`0.1.1`）与 HarmonyOS NEXT（`0.1.1`）保持不变。
