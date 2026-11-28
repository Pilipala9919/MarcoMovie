# CQuickJS (iOS / macOS SwiftPM & Xcode Bridge)

Portable QuickJS-NG `0.14.0` C/H sources (`quickjs.c`, `libregexp.c`, `libunicode.c`, `dtoa.c`, and headers) are synced from `flutter/packages/quickjs_engine/native/cxx/quickjs/` into this directory by running:

```bash
python3 ios/prepare_ios.py --light-simulator
```

Only `cquickjs_anchor.c`, `include/CQuickJS.h`, `include/module.modulemap`, and this `README.md` are tracked in Git.
