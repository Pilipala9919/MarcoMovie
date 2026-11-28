# Marco Movie for iOS & iPadOS (Native Swift / UIKit + C/ObjC++)

Native Swift / UIKit + C / Objective-C++ application for iPhone and iPad (`com.pilipala.marcoMovie`), completely independent of `flutter/`, `macos/`, `tvos/`, `android-tv/`, `android-mobile/`, and `lite/`.

## Architecture Overview

- **`CQuickJS` (`Sources/CQuickJS/`)**: C11 target compiling QuickJS-NG `0.14.0` (`quickjs.c`, `libregexp.c`, `libunicode.c`, `dtoa.c`) synced by `ios/prepare_ios.py`.
- **`CLibmpv` (`Sources/CLibmpv/`)**: ABI-compatible C header declarations for `libmpv 0.36.0` (`MPV_CLIENT_API_VERSION = 2.1`) matching `Mpv.xcframework` `v0.6.0`.
- **`MarcoNativeBridges` (`Sources/MarcoNativeBridges/`)**: Zero-Flutter Objective-C++ bridges with clean `#if MARCO_HAS_*` compile-time gating:
  - `MMPythonNativeBridge`: Isolated CPython `3.14` runtime + per-session own-GIL subinterpreter (`Py_NewInterpreterFromConfig`) + native ephemeral `URLSession` HTTP transport (`followRedirects = false`, `6 MiB` body limit, cooperative cancellation).
  - `MMCatpawNativeBridge`: Embedded `NodeMobile.xcframework` (`--jitless`) host thread for CatPaw / DRPY2 adapters.
  - `MMMpvNativeBridge`: Hardware-accelerated `libmpv` (`vo=libmpv`, `hwdec=videotoolbox`, `ao=audiounit`) rendering via OpenGLES3 + double-buffered IOSurface/Metal-compatible `CVPixelBuffer` for zero-copy `CAMetalLayer` presentation.
- **`MarcoIOSCore` (`Sources/MarcoIOSCore/`)**: Pure Swift core library (cross-compiles on macOS 13+ for `swift test` and iOS 14.0+ / 15.0+ via `#if canImport(MarcoNativeBridges)`).
- **`MarcoMovieIOS` (`Sources/MarcoMovieIOS/`)**: Native UIKit + Metal + AVKit + iOS 26 Liquid Glass iPhone/iPad application supporting 120Hz ProMotion, iPad Split View / Stage Manager, and trackpad/keyboard input.

## Build Modes

### 1. Light Simulator Mode (`--light-simulator`, ideal for 8GB Macs & fast UI iteration)

Skips heavy native frameworks (`CPython`, `NodeMobile`, `Mpv`) and defines **zero** `MARCO_HAS_*` flags, compiling only `CQuickJS`, stub `MarcoNativeBridges`, `MarcoIOSCore`, `MarcoMovieIOS`, and `MarcoMovieIOSTests` in seconds:

```bash
python3 ios/prepare_ios.py --light-simulator
xcodebuild \
  -project ios/RunnerProject/MarcoMovieIOS.xcodeproj \
  -scheme MarcoMovieIOS \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

### 2. Full Device Builds (Dual Xcode Toolchains)

Full device builds enable `MARCO_HAS_CPYTHON`, `MARCO_HAS_CATPAW`, and `MARCO_HAS_MPV` with verified staged frameworks:

#### Xcode 26 (`iOS 15.0+` & Native iOS 26 Liquid Glass SDK)

```bash
python3 ios/prepare_ios.py \
  --min-ios 15.0 \
  --sdk iphoneos \
  --python-stage-dir ios/Stage/python-runtime \
  --catpaw-frameworks-dir ios/Frameworks/catpaw \
  --mpv-xcframeworks-dir ios/Frameworks/mpv

xcodebuild \
  -project ios/RunnerProject/MarcoMovieIOS.xcodeproj \
  -scheme MarcoMovieIOS \
  -sdk iphoneos \
  -configuration Release \
  -derivedDataPath ios/DerivedData \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

python3 ios/prepare_ios.py \
  --embed-runtimes \
  --app ios/DerivedData/Build/Products/Release-iphoneos/MarcoMovieIOS.app \
  --sdk iphoneos \
  --python-stage-dir ios/Stage/python-runtime \
  --catpaw-frameworks-dir ios/Frameworks/catpaw \
  --mpv-xcframeworks-dir ios/Frameworks/mpv

python3 ios/patch_ios_ipa.py \
  ios/DerivedData/Build/Products/Release-iphoneos/MarcoMovieIOS.app \
  --min-ios 15.0 \
  --expected-version 0.8.0 \
  --expected-build 107 \
  --ipa MarcoMovie-0.8.0-ios-unsigned.ipa
```

#### Xcode 16 (`iOS 14.0+` Compatibility Build)

When `--min-ios 14.0` is selected (or `MARCOMOVIE_IOS_MIN_TARGET=14.0`), `prepare_ios.py` automatically injects `-Wl,-no_fixup_chains` and `-fno-objc-msgsend-selector-stubs` across all targets so real `iOS 14.0` devices load cleanly without dyld chained-fixup failures:

```bash
python3 ios/prepare_ios.py \
  --min-ios 14.0 \
  --sdk iphoneos \
  --python-stage-dir ios/Stage/python-runtime \
  --catpaw-frameworks-dir ios/Frameworks/catpaw \
  --mpv-xcframeworks-dir ios/Frameworks/mpv

python3 ios/patch_ios_ipa.py \
  ios/DerivedData/Build/Products/Release-iphoneos/MarcoMovieIOS.app \
  --min-ios 14.0 \
  --expected-version 0.8.0 \
  --expected-build 107 \
  --ipa MarcoMovie-0.8.0-ios14-unsigned.ipa
```

## Verification Commands

```bash
# Project generator, IPA verifier & native bridge regression suite
python3 -m unittest discover -s ios -p "test_*.py"

# Cross-platform SwiftPM core tests on macOS (without UIKit or heavy frameworks)
python3 ios/prepare_ios.py --light-simulator
(cd ios && swift test)

# Simulator verification runner (macOS with Xcode Simulator)
python3 ios/run_ios_simulator_verify.py

# Repository guardrails
python3 scripts/check_public_content.py
python3 scripts/sync_readme_versions.py --check
python3 scripts/test_readme_sync.py
```
