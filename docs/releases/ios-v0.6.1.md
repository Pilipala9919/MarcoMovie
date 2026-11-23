# Marco Movie iOS / iPadOS 0.6.1

发布日期：2026-11-22。应用版本 `0.6.1`（构建号 `92`），基于 Xcode `27.2` / iOS `27.2` SDK 编译，并完整保持 `MinimumOSVersion = 15.0` 向下兼容 iOS / iPadOS `15.0+` 及 iOS `16.4` 巨魔（TrollStore）安装。本次更新聚焦 iPhone Duo 原生全适配、首页影院级连续氛围过渡、底部导航四按钮重绘与独立选中态动效、独立直播源管理与流畅播放、夸克代理画质切换修复，以及全端日间 / 夜间模式可读性全面治理。

## 更新内容

- **iPhone Duo 原生全适配与 iOS 27.2 SDK 升级**：
  - 迁移至 `UIScene` 与 `FlutterImplicitEngineDelegate` 现代生命周期，关闭 `UIRequiresFullScreen` 并全面移除 `UIScreen.main` 静态尺寸假设，实时响应窗口折叠/展开与分屏尺寸变化；
  - 新增 `AppleViewportLayout` 响应式视窗体系，覆盖 iPhone Duo 5.4" 外屏、7.6" 展开内屏、横竖屏与 Split View 窄屏，动态协调首页 Hero 高度、海报网格列宽、悬浮 Dock 尺寸与详情页双栏布局；
  - 保留 `MinimumOSVersion = 15.0` 及全部内嵌 Mach-O `minos <= 15.0`，同时兼顾最新系统液态玻璃特性与 iOS 16.4 巨魔兼容。
- **首页连续氛围过渡重构与零闪白线性卡片转场**：
  - 将海报氛围底色层移至 `CustomScrollView` 后方独立 Layer 0，根治旧版 Sliver 0 向下溢出遮罩盖在「光影风向标」文字与卡片上的发灰问题，并彻底移除日间圆角白帽；
  - 采样海报下半区真实自然色调，经 8 段平滑单色氛围渐变无缝衔接至后方 Layer 0，在首行海报卡片背后自然淡出到纯日间 `#E9ECF2` / 夜间 `#000000` 页面底色；左右滑动轮播封面时氛围色与首栏标题实时插值变色并按明度自动反色；
  - 修复点击首页推荐与列表剧集卡片打开及返回时的闪白抖动问题，首屏完整呈现首页封面与首行精选卡片。
- **底部 4 个导航按钮重绘与独立选中态动效**：
  - 重绘「主页 / 直播 / 片库 / 设置」4 枚双色分层矢量图标（主页影院屏+星芒、直播信号塔+绯红 Live 信号点、片库三层胶片卡+书签、设置六瓣精密表盘齿轮），原生 iOS 26/27 `CoreAnimation / CAShapeLayer` 与 iOS 15–18 / 巨魔 Flutter `CustomPainter` 像素级一致；
  - 每个按钮配备专属选中态弹性微动效（影院屏星芒弹出、直播绯红雷达波错峰扩散、片库三层卡片阶梯展开、设置齿轮顺时针精密旋转 60° 并点亮中心点），同步支持点按、重复点击微弹与按住液态玻璃横滑逐个联动，并完整遵循系统「减弱动态效果」设置；
  - 升级选中态微光蓝调磨砂胶囊，日间/夜间模式对比度更清晰。
- **独立直播源导入、自动归类/测速/台标与流畅直播播放**：
  - 支持独立导入 M3U / TXT 直播源（网络地址、本地文件、粘贴内容），提供自动智能分组（央视/卫视/4K/港澳台/体育/影视等）、品牌台标匹配与批量延迟测速优快排序（不可用频道自动归入「失效频道」）；
  - 重做直播页顶部操作布局与导入弹窗排版，提升整体呼吸感与居中按钮规范；优化直播流起播缓冲策略、协议头透传与多路无感回退，提升换台与弱网稳定性。
- **夸克画质切换代理修复、日间/夜间模式全面适配与 iOS 16.4 巨魔修复**：
  - 修复播放页切换夸克网盘（CatPaw）清晰度时无法切回本机代理且保留 Cookie 的问题；
  - 移除无效的液态玻璃强度滑块；全面排查并修复日间/夜间模式切换后设置页字号偏小看不清、搜索栏日间黑底看不清输入、详情页顶栏按钮可读性受影响及原生/Flutter 控件未随主题自适应的问题；
  - 修复 iOS 16.4 巨魔安装环境下底部悬浮搜索图标漂移的问题。

## 包信息与构建记录

- **未签名 IPA（iPhone / iPad / iPhone Duo 通用）**：`MarcoMovie-0.6.1-ios-iphone-ipad-unsigned.ipa`（`63543076` B，更新兼容别名 `MarcoMovie-0.6.1-ios-unsigned.ipa`），SHA-256：`8f1616c93d7f837929f931b033134d591e4c78fd5727e344419ec078d1f32c08`。
- **对应源码包**：`MarcoMovie-ios-v0.6.1-source.zip`（`10857248` B），SHA-256：`958a57ae4d600685a072d558a1d956b1a71b3d746a9c499a650365b664e63bde`。
- **构建提交与 CI 记录**：`40795cc8490c19b0ef60430d36bfe46cecde5392`。[iOS / iPadOS 原生构建与全量测试（Job 137202221820 · Run 45018299947）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45018299947/job/137202221820) / [公开守卫与离线校验（Job 137202253551）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45018299947/job/137202253551) / [Public content checks（45018299860）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45018299860) / [跨端源回归（45018299853）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45018299853) / [iOS 内嵌源运行时回归（45018299948）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45018299948)。

## 验证范围与已知限制

- **已完成真机与自动化校验**：本轮各项核心视觉与交互改动（首页连续氛围过渡、底部四按钮重绘与动效、独立直播源导入归类与流畅播放、夸克代理切换、日间/夜间模式对比度及 iOS 16.4 巨魔兼容）已在物理 iPhone 真机经多轮实测验收；在提交 `40795cc8490c19b0ef60430d36bfe46cecde5392` 上通过了 GitHub Actions 7 平台全绿构建（Run `45018299947`）、macOS 云端 Runner 全套 Flutter 自动化测试（`1234` 项通过、`9` 项非 iOS 专属跳过）、Xcode `27.2`（`iphoneos27.2`）Release `.ipa` 打包与 140 个 Mach-O `minos <= 15.0` 校验、`flutter/test_ios_package.py`、`scripts/check_public_content.py`（`1531` 文件）及 `scripts/sync_readme_versions.py --check`。
- **已知限制**：未签名 `.ipa` 需通过 TrollStore（巨魔）或个人自签工具安装；第三方直播源与片源可用性取决于用户自行导入的上游服务及网络环境。
