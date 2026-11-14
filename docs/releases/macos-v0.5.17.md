# Marco Movie macOS 0.5.17

发布日期：2026-11-15。应用版本：`0.5.17`（构建号 `67`）。本次更新新增播放器防误触锁屏模式，并同步焕新全平台统一的金属胶片丝带 M 桌面图标与应用内品牌视觉。

## 播放交互与品牌视觉

- **播放器防误触锁屏**：播放控制栏新增一键「锁屏」开关；开启锁屏后自动收起全部控制条，拦截触控板/鼠标误触双击暂停、滑动跳转与键盘播放快捷键操作；单击画面仅浮现独立「解锁」胶囊按钮，安心沉浸观影。
- **全新金属胶片丝带 M 品牌图标**：升级 macOS 应用 `.icns` 图标集（Dock 栏与访达）及应用内品牌标识为黑曜石底金属胶片丝带「M」视觉设计。

## 包信息与构建记录

- **macOS 桌面应用包（Apple Silicon / Intel）**：`MarcoMovie-0.5.17-macos-desktop.zip`（更新兼容别名 `MarcoMovie-0.5.17-macos.zip`），SHA-256：`43651b4323b5fd34d84f9088ad87c338ca7736b568fc199c0dc8da6f2d8e9b17`。
- **对应源码包**：`MarcoMovie-macos-v0.5.17-source.zip`，SHA-256：`a5d929dca9a035e0dddfd8c20d14e59feb06ff07568d671072c60c4e26fd8f86`。
- **构建提交**：`76163bf0569f5dea83c872dacfcc65a793d0fe58`。[多端原生构建与校验记录（43617109635）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/43617109635)。

## 验证范围与已知限制

- 通过公共内容守卫检查、macOS 原生 Release 构建、打包 `Mpv.framework` 媒体回放校验及全部 Flutter 自动化测试（含播放器锁屏交互组件测试）；应用压缩包未公证，首次打开请右键选择“打开”。
