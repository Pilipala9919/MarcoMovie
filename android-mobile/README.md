# Android 手机 / 平板独立工程 (`android-mobile/`)

原生 Java 实现，最低 API 23，仅面向 Android 手机 / 平板（`armeabi-v7a` + `arm64-v8a`），与 `android-tv/` 完全分离、独立演进、互不同步。

- 构建命令：`python -X utf8 scripts/build_android_mobile.py`
- 版本清单：`android-mobile/edition-versions.json`
- 更新通道：`android-mobile`（应用包名保持 `com.pilipala.marcomovie`，通过 `EDITION=mobile` 与电视端隔离）
- 详细构建与测试命令见 [docs/BUILD.md](../docs/BUILD.md)。

应用没有默认配置地址或内置内容列表。`src/main/assets` 包含运行库、拼音词典及对应许可，不含影视资源或第三方内容插件载荷。
