# Marco Movie Windows 0.7.1

发布日期：2026-11-23。应用版本 `0.7.1`（构建号 `78`）。本次 Windows x64 专项更新重点解决核显电脑播放流畅度与兼容性、全屏隐藏进度条弹幕静止、海报与剧集不匹配、动态漫画与正式动漫混淆以及剧集内集数错位与弹幕匹配偏差问题。

## 更新内容

- **新增 Windows MDK（`libmdk` / `fvp`）核显兼容播放引擎（`MdkPlatformPlayer` / `VideoKernel`）**：
  - 引入 `fvp`（底层 `libmdk` + FFmpeg + `libass`）作为与 `libmpv` 并行的 Windows 可选播放引擎，面向 Intel / AMD 核显与轻薄本电脑深度调优：
    - 默认硬件解码链 `MFT:d3d=11 → D3D11 → DXVA → CUDA → FFmpeg → dav1d`；当播放策略切换为「兼容缓冲」时自动将 `DXVA` 置顶以照顾老旧核显；
    - 强制启用 `video.decoder=shader_resource=0` 避免部分核显驱动出现 D3D11 SRV 格式不兼容或黑屏，启动期初始化 `d3d11.sync.cpu=1` 与 Windows 中文字体（微软雅黑等）供原生 `libass` 字幕清晰渲染；
    - 完整支持自定义请求头（跨集自动清理残留 `Referer`/`User-Agent`）、关键帧快速 Seek、0–200% 音量、倍速、循环模式及内嵌/外挂音轨与字幕轨切换。
  - 在「设置 → 播放」新增 **Windows 播放引擎**（`MDK 核显兼容（推荐核显）` / `MPV 旗舰画质（libmpv）`），并在播放页右下角「更多」菜单与播放失败卡片提供**保留进度实时热切**；当 MDK 遇到不兼容流启动失败时自动无缝回退至 MPV 继续播放。
- **修复全屏隐藏进度条时弹幕静止不动问题（`DanmuLayer` / `PlayerScreen`）**：
  - 保留隐藏控制条且关闭底部细进度条时跳过整树 `setState()` 的性能优化，同时为 `DanmuLayer` 新增 `positionListenable`（`ValueListenable<int>`）独立时钟通道，将播放器实时进度直接喂给 `DanmuClockInterpolator`（防跑飞外推保护窗口调整为 `1000ms`），彻底修复进度条自动隐藏 2 秒后弹幕静止不动的问题。
- **新增剧集内刮削、快速定位集数与弹幕集号校准（`SeriesScraper` / `SeriesScrapeSheet`）**：
  - 支持在详情页与播放页内对当前剧集重新刮削与分季/集号校准，自动识别正片、SP/OVA/番外与错位命名，并支持快速搜索/定位目标集数；
  - 将校准后的真实集数同步联动至弹幕查询与加载链路，解决因源站集名错位导致找不到想看的集数及弹幕与当前集不匹配的问题。
- **优化 Windows 海报与实际剧集匹配准确度 & 区分动态漫画与正式动漫**：
  - 强化 `PosterLoader`、`CastAvatarService` 与 `WindowsDetail` 的剧集/电影封面及演职员头像匹配策略，结合年份、介质形态与片名做严格过滤，减少同名不同剧与人物词条错误配图；
  - 在 `CmsParser`、`CuratedDiscovery` 与详情/检索链路中明确识别并隔离「动态漫画 / 漫剧」与正式 3D/2D 动漫，避免两者混排与封面串片。

## 包信息与构建记录

- **Windows 64 位安装版（Inno Setup）**：`MarcoMovie-0.7.1-windows-x64-setup.exe`（`71616917` B，兼容别名 `MarcoMovie-0.7.1-windows-setup.exe`），SHA-256：`ae13048dc0d67152235b4a28e03f7301119f5d11b04c9d52d509319a97e05b06`。
- **Windows 64 位绿色便携版**：`MarcoMovie-0.7.1-windows-x64-portable.zip`（`102641882` B，兼容别名 `MarcoMovie-0.7.1-windows-x64.zip`），SHA-256：`1a992fc9f917c375177a36a3afc16ebec95aabdb64f47535c60c28a55333407a`。
- **对应源码包**：`MarcoMovie-windows-v0.7.1-source.zip`（`11510458` B），SHA-256：`bfee0bb3f4ef67de243aa512e8f1c8bfa471c4c1c8882a18945096b93d849678`。
- **构建提交与 CI 记录**：`a919dfd9c8605628c8a5bb59f330ede104e225f4`。[Windows x64 原生构建与全量校验（Job 137487699037 · Run 45112032102）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45112032102/job/137487699037) / [公开守卫与离线校验（Job 137486329825）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45112032102/job/137486329825) / [Public content checks（45112032114）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45112032114)。

## 验证范围与已知限制

- **本地与云端自动化校验**：已在本地 Windows x64 环境与提交 `a919dfd9c8605628c8a5bb59f330ede104e225f4` 的 GitHub Actions 7 平台全绿构建（Run `45112032102`）完成 Release 编译打包（Inno Setup 安装包与绿色便携包，已验证包内同时包含 `fvp.dll`、`mdk.dll`、`ffmpeg-9.dll`、`libass.dll`、`libmpv-2.dll`、内置 Python `3.11.9` 与 Node/CatPaw 运行时）、`scripts/check_public_content.py`（`1601` 追踪文件）、`scripts/sync_readme_versions.py --check`、`flutter analyze --no-fatal-infos` 零错误零告警、全量 `1336` 项 Flutter 单元测试（零失败，含新增 `windows_danmu_and_mdk_test.dart` 与 `windows_poster_and_series_scraper_test.dart`）及 `libmpv-2.dll` 原生解码回放校验。尚未在全部型号 Intel / AMD 核显实机与所有第三方片源上完成穷尽验证。
- **已知限制**：安装包与便携程序未购买商业代码签名证书，Windows SmartScreen 首次运行如提示未知发布者需手动确认运行；MDK 引擎模式下不适用 MPV 专属的 Anime4K 着色器与 `dynaudnorm` 人声响度滤波，可随时一键切回 MPV 旗舰画质模式；动态网页嗅探与 WebView2 异步 JS 需系统已安装 Microsoft Edge WebView2 Runtime。
