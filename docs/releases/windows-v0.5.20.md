# Marco Movie Windows 0.5.20

发布日期：2026-11-15。应用版本：`0.5.20`（构建号 `70`）。本次更新新增播放器防误触锁屏模式，并同步焕新全平台统一的金属胶片丝带 M 桌面图标与应用内品牌视觉。

## 播放交互与品牌视觉

- **播放器防误触锁屏**：播放控制栏新增一键「锁屏」开关；开启锁屏后自动收起全部控制条并隐藏沉浸式无边框窗口标题栏交互，拦截鼠标双击暂停、滚轮调节、拖拽快进快退及键盘播放快捷键误触；单击画面仅浮现独立「解锁」胶囊按钮，全屏或触控屏观影更省心。
- **全新金属胶片丝带 M 品牌图标**：升级 Windows 桌面快捷方式与可执行程序 `.ico` 图标及应用内品牌标识为黑曜石底金属胶片丝带「M」视觉设计。

## 包信息与构建记录

- **安装版（推荐，简体中文向导）**：`MarcoMovie-0.5.20-windows-x64-setup.exe`（更新兼容别名 `MarcoMovie-0.5.20-windows-setup.exe`），SHA-256：`758dbf183ec228a3660cc60f6fa1ab40928163f1361705b9d033f6509b5adbc8`。
- **绿色便携版**：`MarcoMovie-0.5.20-windows-x64-portable.zip`（兼容别名 `MarcoMovie-0.5.20-windows-x64.zip`），SHA-256：`446ebfdce3148a12342bab13cea8dd07886aaffc9959e5fe78bedc3e2514f178`。
- **对应源码包**：`MarcoMovie-windows-v0.5.20-source.zip`，SHA-256：`a5d929dca9a035e0dddfd8c20d14e59feb06ff07568d671072c60c4e26fd8f86`。
- **构建提交**：`76163bf0569f5dea83c872dacfcc65a793d0fe58`。[多端原生构建与校验记录（43617109635）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/43617109635)。

## 验证范围与已知限制

- 通过公共内容守卫检查、Windows x64 原生构建、简体中文 Inno Setup 安装包校验、打包 `libmpv-2.dll` 媒体回放校验及全部 Flutter 自动化测试（含播放器锁屏交互组件测试）；未声明用户私人网盘账号实机穷举验收。
