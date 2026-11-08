# Marco Movie iPhone / iPad 0.5.2 验证版

发布日期：2026-11-08。仅适用于 iPhone / iPad，版本 0.5.2（52），最低目标 iOS / iPadOS 14.0。

本次按用户要求构建并同步 iOS 0.5.2 验证包；这是预发布测试版，不表示全部订阅和插件线路已完成适配，不替换正式版自动更新通道。其他系统安装包按各自平台节奏独立维护。

## 下载与安装

- [下载 iPhone / iPad 未签名 IPA](https://github.com/Pilipala9919/MarcoMovie/releases/download/ios-v0.5.2-preview/MarcoMovie-0.5.2-ios-iphone-ipad-unsigned.ipa)
- [IPA SHA-256 校验文件](https://github.com/Pilipala9919/MarcoMovie/releases/download/ios-v0.5.2-preview/MarcoMovie-0.5.2-ios-iphone-ipad-unsigned.ipa.sha256)
- IPA 需要自行签名，或使用设备系统支持的安装方式；不承诺所有系统均可使用 TrollStore。
- 包大小：65,093,352 字节。SHA-256：`4b25424425e4b7cbdd09a270b62df8959d250f9cfd222f11f8a58da89bc93141`。

## 本次新增与修复

- **订阅源与直播源全格式解包对齐安卓端**：支持 GZIP（`0x1F 0x8B`）压缩订阅配置与直播源自动解压、图片尾部 `**`+Base64 隐写、`2423`（`$#...#$`）AES-CBC 加密直播列表解包，以及 `#EXTINF` 空标题自动回退 `tvg-name`。
- **TVBox / 影视仓配置结构与请求头增强**：支持顶层 `"jar"` 作为 `"spider"` 同义字段、顶层 `"parses"` JSON 解析器列表提取与站点默认回填；支持从站点顶层及 `site.ext`（JSON 对象或字符串）中提取合并 `headers`、`header`、`ua`、`User-Agent`、`referer`，并支持 `./` 与 `../` 相对路径补全。
- **XML CMS 与 AppYsV2（V1.vod）接口适配**：`type == 0` XML 站点详情与列表统一使用 `ac=videolist` 获取完整海报与播放源；新增 `csp_AppYsV2`（`api.php/app` / `xgapp.php`）分类、列表、搜索、详情及 `vod_url_with_player` 多线路解析；支持直链后缀免解析与 JSON 解析器换链。
- **精简并移除网盘入口**：首页站点选择器自动过滤 `csp_MyDriveGuard`（`🗂我的云盘┃配置`）占位站点，移除首页顶栏网盘按钮、网盘扫码横幅及设置页网盘入口，聚焦订阅源与直播源核心体验。
- **Glasswork 光学毛玻璃 UI 规范落地**：对齐 `glass.css` 与 `adapt.js` 规范，升级 `_LiquidRimPainter` 顶部内高光与底部内折射边、`LiquidGlass` / `GlassworkBackdrop` 密度梯度及“降低透明度”无障碍实底降级（`0.96` alpha），统一应用于首页顶栏胶囊、海报角标、详情页海报悬浮按钮与播放器顶部规格徽章。

## 已完成验证

- [iOS 构建 42493309704](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42493309704) 成功，393 项 Flutter 测试通过。
- [跨平台 HTTP 与 Python 片源回归 42491906998](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42491906998)（macOS 15 与 Windows）及 [公开内容守卫检查 42493307800](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42493307800) 全部通过。
- 核对 IPA 压缩包完整性、`Info.plist` 版本号（`0.5.2` / `52`，`MinimumOSVersion 14.0`）及 SHA-256 校验值。

## 已知限制

- 33 条待验收 Android Guard / JAR 插件线路尚未全部跨平台移植。
- 不保证任意第三方 TXT、JS、JSON、Python、PHP 或本地包订阅均可用；配置格式可解析不等于其中每条自定义爬虫插件均可在 iOS 独立运行。
- iPhone 真机起播、解码、拖动进度及不同 iOS 版本安装仍需按实际设备验证。

## 构建来源

安装包构建提交：`adbd1fa444735a9a7bf77eb6445b15b3f8f1cbab`。随发布附上该提交的源码 ZIP 及 SHA-256 文件。
