# Marco Movie iPhone / iPad 0.5.1 验证版

发布日期：2026-11-08。仅适用于 iPhone / iPad，版本 0.5.1（51），最低目标 iOS / iPadOS 14.0。

本次按用户要求同步现有验证包；这是预发布测试版，不表示全部订阅和插件线路已完成适配，不替换正式版自动更新通道。其他系统安装包不随本次发布更新。

## 下载与安装

- [下载 iPhone / iPad 未签名 IPA](https://github.com/Pilipala9919/MarcoMovie/releases/download/ios-v0.5.1-preview/MarcoMovie-0.5.1-ios-iphone-ipad-unsigned.ipa)
- [IPA SHA-256 校验文件](https://github.com/Pilipala9919/MarcoMovie/releases/download/ios-v0.5.1-preview/MarcoMovie-0.5.1-ios-iphone-ipad-unsigned.ipa.sha256)
- IPA 需要自行签名，或使用设备系统支持的安装方式；不承诺所有系统均可使用 TrollStore。
- 包大小：65,205,842 字节。SHA-256：`45a89f48b91273e6829bfa594fb230a84b3b1e03ce33df1726a1a417b94a07a2`。

## 本次新增与修复

- 补充 iOS 本机 Python 的 Crypto、lxml 依赖及常用文本、JSON、分页、HTML/XPath 辅助接口。
- 保留 DRPY 规则声明的页面编码，内置 GBK、GB18030、Big5 解码支持，修复无 ICU 环境下部分目录乱码或为空的问题。
- 修复 JavaScript 模块依赖识别，避免把注释、字符串及正则中的 require 文本误判成真实依赖。
- Auete 增加手动验证码与验证后搜索重试，保留来源会话和含特殊字符的搜索词。
- 夸克扫码接通真实账户验证，移除占位登录凭据；二维码本机生成，避免刷新、关闭或切换账号后旧请求写入登录结果。
- 新增夸克账户内视频目录、分页与原画/转码解析，完善账号隔离和横屏长名称显示。
- iPhone 横屏播放控制区完整避让左右安全区域，修复快速退出全屏后系统栏被再次隐藏的问题。
- 隐私密码弹窗支持横屏滚动，阻止退出弹窗后的延迟解锁。

## 已完成验证

- [iOS 构建 42483330484](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42483330484) 成功，393 项 Flutter 测试通过。
- ARM64 与 x86_64 iOS 模拟器各通过 202 项原生运行检查；对应 53 项运行输入与本包源码一致。
- 核对 2,987 个包内运行库文件、16 项源码输入、152 个 ARM64 原生二进制，以及 41 个 Crypto、3 个 lxml 组件。
- 夸克匿名二维码创建与等待轮询成功；未完成真实账号确认、分享转存和实机媒体播放验证。

## 已知限制

- 夸克分享文件转存及 WoGG/Pan 分享接线仍未完成。
- 33 条待验收插件线路尚未全部移植：26 条未移植、6 条已接入但未验收、1 条实验入口未开放。
- 不保证任意 TXT、JS、JSON、Python、PHP 或本地包订阅均可用；文件格式可导入不等于其中每条插件都可在 iPhone 独立运行。
- iPhone 真机登录、起播、解码、拖动进度及旧系统安装仍需验证。iOS 14.5 巨魔启动问题按用户要求留待新版实测。

## 构建来源

安装包构建提交：`5505c54fc2b77070c037d09d4258f63a39ff21c2`。随发布附上该提交的源码 ZIP 及 SHA-256 文件。后续文档和构建缓存更新不改变本 IPA 内容。
