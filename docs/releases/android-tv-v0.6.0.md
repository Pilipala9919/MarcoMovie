# Marco Movie Android 电视 / 盒子 0.6.0

发布日期：2026-11-21。应用版本 `0.6.0`（版本代码 `96`）；最低 Android 6 / API 23。本次大版本更新针对 Android 电视 / 盒子端进行全面专项优化：推出源独立首页热门剧集与热播电影推荐、优化遥控焦点滑动策略与设置页流畅度、彻底根治低内存电视点击剧集闪退与重开循环闪退、统一播放中按返回浅层详情的选集/选季收纳弹窗、重构无边框右上角时间进度 HUD 并新增底部细进度条实时开关，同时完整整合局域网 DLNA / Bonjour 投屏接收与倍速遥控能力并精简包体。

## 本次更新

- **低内存电视点击剧集闪退与重开循环闪退根治**：
  - 首页热门点击改为「优先单源直查当前已选片源，命中可播即止」的两阶段策略，彻底消除点击剧集时向大量片源并发扩散导致 `catpaw-node` 多线程与失控爬虫占满内存/CPU 触发系统 LMK 强杀的问题；仅在当前源未命中时按 `maxConcurrency=1` 顺序回退最多 4 个轻量片源，首个命中即刻关闭搜索器。
  - 新增启动连续异常退出熔断守卫（`startup_boot_guard_v1`），检测到上次异常退出自动清理易损临时缓存，连续异常退出 2 次自动重置故障片源与对应偏好源；冷启动不再提前预热重型插件引擎，将 `CspEngine.initPluginProxy` 改为起播/代理时按需懒初始化，并补齐首页静默刷新 `LOADING_SITE` 保护与 `syncCastService()` 竞态修复。
  - `ImmersivePoster` 全部静态位图缓存改为按字节上限管理（10 / 6 / 8 MB）并接入 `onTrimMemory / onLowMemory / onDestroy`，背景解码采用 `RGB_565` + 原子写盘 + 坏缓存自动清理；移除 `HomeAmbient` 与 `ImageLoader.Atmosphere` 与 HWUI RenderThread 竞争的 `Bitmap.recycle()`；补齐 `Cms.Site` / `PlaybackController` / `SourceController` / `CastService` 空安全与演职员头像 `Integer.MIN_VALUE` 哈希保护。
- **首页沉浸推荐、遥控焦点体验与设置页丝滑优化**：
  - 首页新增独立热门横幅与「近期热剧」「热播电影」横向海报栏，点击直达沉浸式详情并自动匹配用户已添加片源，聚焦框支持在首屏第 1～3 张卡片间自由移动而不锁死首卡；
  - 升级局部作用域 `TvFocusFrame`，仅在同一海报栏或同网格相邻卡片间平滑滑动，跨区、搜索字母键盘与设置侧栏聚焦恢复原生即时反馈，并消除设置页一级分类上下滚动与二级列表切换时的焦点迟滞；
  - 移除已废弃的右侧导航栏模式，精简无效资源与历史死代码（移除 `TvV17LibraryScreen`、`startup.mp4` 等冗余资源）。
- **详情页与播放中返回浅层页体验统一**：
  - 详情页接入豆瓣官方高清横图优选、真实演职员圆形头像条、剧集文件续播副标题及收纳式「选集与线路」「选季」弹窗按钮；
  - 播放中按返回展示的浅层详情页（`MiniDetails`）对齐详情页结构：移除下方铺开的选集/选季网格，将「选集与线路」与多季「选季」统一收纳为「返回全屏播放」旁的玻璃按钮，点击弹出宽版选集/线路或选季弹窗，选择剧集直接切换播放、选择其他季自动退出当前播放并进入目标季详情。
- **播放中无框右上角 HUD 与底部细进度条开关**：
  - 重构电视端全屏播放右上角 HUD（`PlayerChrome`），移除外层胶囊方框与边框，采用清晰投影保证亮场景可读性；**播放进度时间**采用轻盈小号常规字重（`sans-serif-light`），**当前时钟时间**采用大号加粗窄体（`sans-serif-condensed` Bold），远距离一眼区分进度与当前时间；
  - 在播放器「更多」菜单与系统设置「播放与字幕」中提供同步的**「底部细进度条」**实时开关，播放中可随时开启或关闭底部 2dp 细进度条。
- **无线投屏与多端互联增强**：
  - 完整整合局域网 DLNA / UPnP MediaRenderer 与 Bonjour（`_marcomovie-cast._tcp.` 端口 `18652`）接收端服务，支持分块 SOAP 解码、SSDP v2 发现、倍速控制（`Play(Speed)`）与上一集/下一集/静音联动，优化电视端投屏接收页布局与扫码二维码尺寸。

## 验证范围与构建记录

- **物理电视实机验证（Xiaomi `MiTV-ASTP0`，Android 9 / API 28，1.5 GB RAM）**：
  - 冷启动 PSS 内存由 `169 MB + ~80 MB WebView` 降至 **`132 MB`（0 WebView 进程、51 线程）**；
  - 点击热门剧集进入详情页 PSS 由 `352 MB`（触发 LMK 强杀）降至 **`188 MB`**、总堆分配由 `439 MB` 降至 **`106 MB`**（`0` 个 `catpaw-node` / 失控搜索线程）；
  - 全链路 4K 播放（`197 MB` PSS）、无框右上角 HUD 字体区分、底部细进度条实时开关隐藏/显示、播放中按返回浅层页 + 选集弹窗、单一 `18652` 端口投屏广播及连续强停重开均实机截屏验证通过。
- **自动化构建与回归校验（精确构建提交 `1706e22e31cb943ec8825ab0117b62593fb00ed8`）**：
  - GitHub Actions 公开守卫与 Android 构建验证通过：[Public content checks（44915956588）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44915956588)（`1513` 追踪文件零告警、README 版本对齐、Java 格式与离线检查全绿）及 [Build Multiplatform（44915956538）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44915956538) 中的 [Public Guardrails & Offline Java Checks（136881495162）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44915956538/job/136881495162) 与 [Build & Verify Android TV/Phone/Tablet APK（136882734363）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44915956538/job/136882734363) 全部通过；
  - 本地官方正式签名构建（`MARCOMOVIE_RELEASE=1`，`git_dirty: false`）通过 `API 23` 回调字节码校验（`640` 个应用类）、`run_tv_ux_optimization_checks.py`（`52/52` 项专项检查）、`v1/v2/v3` 签名与 `zipalign` 校验，并已在同台 Xiaomi `MiTV-ASTP0` 电视上覆盖安装同 SHA-256 最终正式包完成冷启动无崩溃校验（`versionCode=96`，`0` Fatal）；
  - Android 6（API 23）模拟器回归（[44915956539](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44915956539)）中 `SubtitleProbe` 与 `SourceHostProbe`（`122/122` 项）通过，无 API 23 崩溃或回调兼容回归；旧版 V17 首页探针 `HomeProbe` 初始焦点断言与 `LoadingProbe` 1 项断言待后续适配新版推荐首页布局。
- **已知边界与限制**：物理实测覆盖 Xiaomi Android 9 电视，不代表对全部第三方电视盒固件、全部第三方片源站点或所有 4K/HDR 码流完成穷尽验收。

## 安装与校验

- **正式包名**：`com.pilipala.marcomovie`（TV edition，`minSdk 23` / `targetSdk 28`；保留同字节兼容别名 `MarcoMovie-0.6.0-preview.apk`）。
- **TV APK SHA-256**：`MarcoMovie-0.6.0-android-tv.apk`（`35672158` B）— `f368ff08f19678fec4b804ed29158e95c92370f1daadeebb2f9998234550ed4c`。
- **对应源码包 SHA-256**：`MarcoMovie-android-tv-v0.6.0-source.zip`（`10504071` B）— `35b8b9c56278894e9a598a7d90cf1a58d00f713d1c4cdc7b2d23895331a385d8`。
- **官方签名证书 SHA-256**：`2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de`（与既有正式版一致，覆盖安装保留配置、收藏与观看记录）。
- **精确构建提交**：`1706e22e31cb943ec8825ab0117b62593fb00ed8`。
- **跨端隔离**：本次仅发布 Android 电视 / 盒子独立版本（`android-tv-v0.6.0`），Android 手机/平板（`0.5.27`）、Android Lite（`0.5.8`）、Windows（`0.6.0`）、macOS、iOS/iPadOS、Apple TV 与 HarmonyOS NEXT 版本号及既有发行包均保持不变。
