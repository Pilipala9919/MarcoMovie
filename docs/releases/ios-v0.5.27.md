# Marco Movie iOS / iPadOS 0.5.27

发布日期：2026-11-15。应用版本：`0.5.27`（构建号 `77`），最低系统要求：iOS / iPadOS 14.0。本次更新新增播放器防误触锁屏模式，并同步焕新全平台统一的金属胶片丝带 M 主屏幕图标与应用内品牌视觉。

## 播放交互与品牌视觉

- **播放器防误触锁屏**：播放控制栏新增一键「锁屏」开关；开启锁屏后自动收起全部控制条，拦截手持 iPhone / iPad 观影时的边缘误触、双击暂停、左右滑动快进快退及上下滑动亮度/音量手势；轻触画面仅浮现独立「解锁」胶囊按钮，3.5 秒无操作自动隐去。
- **全新金属胶片丝带 M 品牌图标**：升级 iOS / iPadOS 全尺寸 AppIcon 与应用内品牌标识为黑曜石底金属胶片丝带「M」视觉设计。

## 包信息与构建记录

- **未签名 IPA（iPhone / iPad 通用）**：`MarcoMovie-0.5.27-ios-iphone-ipad-unsigned.ipa`（更新兼容别名 `MarcoMovie-0.5.27-ios-unsigned.ipa`），SHA-256：`c81b72ada0521a6009dfc3fa123f20fde0190dfebea4f64c462e388ee4d45668`。
- **对应源码包**：`MarcoMovie-ios-v0.5.27-source.zip`，SHA-256：`a5d929dca9a035e0dddfd8c20d14e59feb06ff07568d671072c60c4e26fd8f86`。
- **构建提交**：`76163bf0569f5dea83c872dacfcc65a793d0fe58`。[多端原生构建与校验记录（43617109635）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/43617109635)。

## 验证范围与已知限制

- 通过公共内容守卫检查、iOS Xcode 原生 Release 构建及全部 Flutter 自动化测试（含播放器锁屏交互组件测试）；未签名 IPA 支持巨魔（TrollStore）直接覆盖更新或自签工具安装。
