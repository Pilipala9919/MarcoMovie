# Marco Movie Android Lite 0.5.6

发布日期：2026-11-15。应用版本：`0.5.6`（versionCode `56`）。专为 Android 4.0+（API 14+）老旧电视、机顶盒与老手机打造的超轻量独立版本（包名 `com.pilipala.marcomovie.lite`，可与标准版共存），本次更新同步焕新全平台统一的金属胶片丝带 M 桌面图标，并保持完整的老电视投屏、扫码搜索、线路分组编删与现代 TLS 根证书兼容能力。

## 品牌视觉与版本维护

- **全新金属胶片丝带 M 品牌图标**：同步更新 Android Lite 多密度桌面启动图标（`mdpi` 至 `xxxhdpi`）为黑曜石底金属胶片丝带「M」视觉设计，在老电视与机顶盒桌面上呈现更清晰的辨识度。
- **超轻量兼容保障**：持续保持 API 14 单 DEX 架构、内置 Conscrypt TLS + Let's Encrypt `ISRG Root X1` 根证书信任链、DLNA / 网页投屏接收、手机扫码搜索输入与订阅线路分组编删能力。

## 包信息与构建记录

- **安装包**：`MarcoMovie-0.5.6-android-lite.apk`（更新兼容别名 `MarcoMovie-0.5.6-lite.apk`），官方正式签名。
- **SHA-256**：`9d0f55fa2029ab5195ca04556f1ead6dde3ffbaecc644d95f14b5bd65743e115`。
- **对应源码包**：`MarcoMovie-android-lite-v0.5.6-source.zip`，SHA-256：`a5d929dca9a035e0dddfd8c20d14e59feb06ff07568d671072c60c4e26fd8f86`。
- **构建提交**：`76163bf0569f5dea83c872dacfcc65a793d0fe58`。[多端原生构建与校验记录（43617109635）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/43617109635)。

## 验证范围与已知限制

- 通过公共内容守卫检查、API 14 `bootclasspath` 与 D8 `--min-api 14` 单 DEX 编译校验、`193` 项 TV Lite JVM 离线回归、20 项三端规范一致性测试、8 项 TLS 能力检查及官方正式签名校验；未声明实体老旧电视实机穷举验收。
