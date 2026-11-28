# Marco Movie 仓库开发规范

## Android 电视端与手机端彻底分离规则（强制）

`android-tv/` 与 `android-mobile/` 是两个**完全独立、互不同步、各自演进**的原生 Android 工程，严禁再合并回单一 `android/` 目录：

1. **目录边界（各做各的，绝不互同步）**：
   - **Android 电视端（TV / 盒子）**：仅修改 `android-tv/`，版本清单位于 `android-tv/edition-versions.json`，构建脚本为 `scripts/build_android_tv.py`（仅编打 32 位 `armeabi-v7a`），测试位于 `android-tv/tests/`。
   - **Android 手机 / 平板端**：仅修改 `android-mobile/`，版本清单位于 `android-mobile/edition-versions.json`，构建脚本为 `scripts/build_android_mobile.py`（编打 `armeabi-v7a` + `arm64-v8a`），测试位于 `android-mobile/tests/`。
   - **Android Lite（API 14+）**：位于 `lite/`，版本清单位于 `lite/edition-versions.json`，构建脚本为 `scripts/build_lite.py`。
   - **禁止跨端同步**：除非用户明确提出「同时改两端」，否则修改 `android-tv/` 时不得顺带改动 `android-mobile/`，修改 `android-mobile/` 时也不得顺带改动 `android-tv/`。两端 UI、交互、设置项、功能节奏与版本号完全各自独立。

2. **包名、签名与更新隔离**：
   - 电视端与手机端**保持包名 `com.pilipala.marcomovie` 与原正式签名不变**（保证现有电视与手机老用户可无缝覆盖升级且不丢失本地配置与收藏）。
   - 两端通过 `AndroidManifest.xml` 中的 `com.pilipala.marcomovie.EDITION`（`tv` / `mobile`）与独立更新通道（`updates/android-tv.json` / `updates/android-mobile.json`）严格隔离，严禁混发或跨通道覆盖。

3. **跨平台公共层约束**：
   - `shared/script-host/`（`python-host` / `js-host` / `python-native`）服务于 Flutter / iOS 与跨平台单测；`android-tv/src/main/assets/` 与 `android-mobile/src/main/assets/` 各自保留独立副本，互不耦合。
   - 改动 `shared/java/` 时必须保持 API 14+ 兼容（因为 `lite/` 也编译 `shared/java/`），且仅放真正跨端通用的底层修复。

4. **独立验证命令**：
   - TV 端：`python -X utf8 scripts/build_android_tv.py` + `android-tv/tests/run_*.py`
   - 手机端：`python -X utf8 scripts/build_android_mobile.py` + `android-mobile/tests/run_*.py`
   - 通用守卫：`python -X utf8 scripts/check_public_content.py`、`python -X utf8 scripts/sync_readme_versions.py --check`

## macOS 桌面端独立目录规则（强制）

`macos/` 是**独立于 `flutter/` 的 macOS 桌面端工程目录**，与 `flutter/`（Windows / HarmonyOS）彻底解耦、各自演进、严禁互同步：

1. **目录与版本边界**：
   - **macOS 桌面端**：仅修改 `macos/`，版本清单位于 `macos/edition-versions.json`，CI 构建由 `.github/workflows/build-multiplatform.yml` 的 `build-macos` 任务驱动（`working-directory: macos`），更新通道为 `updates/macos.json`。
   - **其他 Flutter 端（Windows / HarmonyOS）**：位于 `flutter/`，版本清单位于 `flutter/edition-versions.json`。
   - **禁止跨端同步**：除非用户明确要求「同时改动 macOS 与其他 Flutter 端」，否则修改 `flutter/` 时不得顺带修改 `macos/`，修改 `macos/` 时也不得顺带修改 `flutter/`。

2. **独立验证命令**：
   - macOS Runner 回归：`python -X utf8 -m unittest discover -s macos -p "test_*.py"`
   - macOS Dart 分析与测试：在 `macos/` 下运行 `flutter pub get`、`flutter analyze --no-fatal-infos --no-fatal-warnings`、`flutter test`
   - macOS 成品验包：`python -X utf8 scripts/verify_macos_candidate.py --app <MarcoMovie.app> --flutter-dir macos`
   - 通用守卫：`python -X utf8 scripts/check_public_content.py`、`python -X utf8 scripts/sync_readme_versions.py --check`、`python -X utf8 scripts/test_readme_sync.py`

## iOS / iPadOS 原生客户端独立目录规则（强制）

`ios/` 是**完全独立于 `flutter/`、`macos/`、`tvos/`、`android-tv/`、`android-mobile/` 与 `lite/` 的原生 Swift / UIKit + C/ObjC++ iOS / iPadOS 客户端工程目录**，各自演进、严禁互同步：

1. **目录、包名与版本边界**：
   - **iOS / iPadOS 原生端**：仅修改 `ios/`，保持包名 `com.pilipala.marcoMovie` 不变（保证老用户可无缝覆盖升级且保留本地配置与收藏），版本清单位于 `ios/edition-versions.json`，更新通道为 `updates/ios.json`。
   - **禁止跨端同步**：除非用户明确要求「同时改动 iOS 与其他端」，否则修改 `ios/` 时不得顺带改动 `flutter/`、`macos/`、`tvos/`、`android-tv/`、`android-mobile/` 或 `lite/`。

2. **构建脚本与双模式 / 双工具链约束**：
   - 工程生成与资源同步：`ios/prepare_ios.py` 同时支持：
     - **完整设备构建模式**：按传入的暂存目录开启 `MARCO_HAS_CPYTHON`、`MARCO_HAS_CATPAW`、`MARCO_HAS_MPV` 并链接/嵌入 `Python.framework`、`NodeMobile.framework` 与 `Mpv.framework` 全套运行时。
     - **轻量模拟器模式（`--light-simulator`）**：不定义上述 3 个重型宏，仅编译 `CQuickJS` + 纯 Swift 与桩 ObjC++ 桥接，适配 8GB M1 Mac 快速本地迭代与 CI 模拟器 UI 验证。
   - **双工具链 CI 构建**：同时维护 Xcode 26（`--min-ios 15.0`，iOS 26 Liquid Glass SDK）与 Xcode 16（`--min-ios 14.0` 兼容构建，自动注入 `-Wl,-no_fixup_chains` 与 `-fno-objc-msgsend-selector-stubs`）。
   - **严格 Mach-O 验包与打包**：`ios/patch_ios_ipa.py` 清理 `.dSYM`、裁剪 fat 二进制至 `arm64`、严格核验所有 Mach-O 的 `LC_BUILD_VERSION` / `LC_VERSION_MIN_IPHONEOS` 与 `Info.plist`（严禁篡改 `minos`），使用 TrollStore entitlements 临时签名并打包 `.ipa`。

3. **独立验证命令**：
   - 工程与脚本回归：`python -X utf8 -m unittest discover -s ios -p "test_*.py"`（或 `python -X utf8 ios/test_ios_project.py`）
   - 核心单测（macOS）：`python -X utf8 ios/prepare_ios.py --light-simulator` 后在 `ios/` 下运行 `swift test`
   - 模拟器验证（macOS）：`python -X utf8 ios/run_ios_simulator_verify.py`
   - 成品验包：`python -X utf8 ios/patch_ios_ipa.py <MarcoMovieIOS.app> --min-ios <15.0|14.0> --expected-version <ver> --expected-build <build> --ipa <out.ipa>`
   - 通用守卫：`python -X utf8 scripts/check_public_content.py`、`python -X utf8 scripts/sync_readme_versions.py --check`、`python -X utf8 scripts/test_readme_sync.py`

