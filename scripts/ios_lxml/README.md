# Native lxml iOS port

This directory builds pinned lxml 6.1.3 for the iOS Python source runtime. The
product preparer uses the same builder exercised by the native iOS probe below.
Its presence does not establish compatibility with arbitrary Python dependencies
or actual third-party subscription playback.

The pinned upstream generated C code rejects subinterpreters. It also contains
process-wide Python references, cached builtins and Cython dispatch tables, and
uses `PyGILState_Ensure` in native callbacks. Merely changing its module slot, or
disabling the source owner's extension check, cannot establish compatibility.

The experiment migrates these declarations into the generated module state,
adds traversal/clearing for owned references, and preserves the calling
interpreter across native callbacks. It keeps the upstream Python package and
both native modules; it is not a substitute XPath implementation. Generated C
is patched only after verifying the complete source archive. Changed layouts
must fail rather than silently applying a patch to another release.

The first validation stage runs native CPython on Linux with independently
created own-GIL interpreters. Its report must record library versions, source
hashes, failures, and actual interpreter destruction. That is a prerequisite for
the iOS port, not evidence of iPhone compatibility. Native library global
callbacks, import/teardown, simultaneous independent parsers, XPath callbacks,
objectify, XSLT, error recovery and reopening must all be exercised before any
production integration. Physical-device source and playback acceptance remain
separate.

## First native result

Run 42475595293 at `d8e13ca` passed the Linux host stage on CPython 3.14.10,
libxml2 2.9.14 and libxslt 1.1.39. Thirteen core behaviors were repeated for 650
assertions across two simultaneous own-GIL owners, continued use after the peer
was destroyed, and a third freshly created interpreter. All three interpreters
were actually destroyed, and all eight recorded experiment input hashes matched
that commit. XML/HTML, XPath callbacks, resolver ownership, error recovery,
objectify, streaming parse and XSLT were exercised.

The first run failed during simultaneous type initialization. Native debugging
identified a shared static extension type; the follow-up enables per-module heap
types as well as migrating the Python references and dispatch tables. The
previous failing runs remain failures, not accepted results.

This does not establish iOS compilation, iPhone execution, complete upstream API
coverage or real subscription playback. The callback policy in
`native_callbacks.h` also requires private libxml2/libxslt libraries in a product
app; it must not take over an unrelated component's shared library callbacks.

## iOS native result and product integration

[Run 42477373003](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42477373003)
at `9214d45b7551d7088f0ae0c03fb6174b08467361` passed the ARM64 iOS 18.5
simulator probe on CPython 3.14.10. Thirteen core behaviors completed 650 repeated
assertions across three distinct own-GIL interpreters, including use after the
peer interpreter was destroyed and a newly opened owner. All three owners were
destroyed and the UI heartbeat continued during their work. The shared Linux
harness also passed after its refactor for embedded use.

`build_ios.py` compiles pinned libxml2 2.14.6 and libxslt/libexslt 1.1.43 into
`MarcoLxmlNative.framework`; the two lxml module frameworks use two-level symbol
binding to that private library and Python. It checks these imports, supplies
Apple framework import markers, and retains upstream Python files and licenses.
This avoids taking over the player's or the system's XML library callbacks.

The product preparer stages these frameworks beside Python and Crypto, includes
the builder inputs in its cache key, and validates all staged files before
embedding. `product_enabled` records inclusion; the builder's `runtime_tested`
and `physical_device_tested` remain false because building alone tests neither.
The standalone probe remains experimental and excludes Flutter/source playback.
Physical-device playback, minimum-iOS execution and arbitrary plugin coverage
are not claimed by this result.

## Full iPhone/iPad validation package

[Build 42478121521](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42478121521)
at `f494d489d0de8e3263a140fbd609ecd61debb6d0` passed 354 Flutter tests and
produced the unpublished iOS 0.5.1 (51) validation IPA. Package inspection verified
all three lxml frameworks and import markers, 208 lxml package/resource/license
files, 41 Crypto libraries and 120 Crypto package files. All 16 runtime source
hashes matched that commit, and 2,987 staged runtime files matched the package.
The 152 native Mach-O binaries are device ARM64 with deployment targets no newer
than iOS 14; this is not evidence of running on iOS 14 or a physical device.

`MarcoMovie-0.5.1-ios-iphone-ipad-unsigned.ipa` is 64,957,504 bytes, SHA-256
`db08a9561256cfbfa1b1cc9072b9ffa6fa42ee3e518930c76ee26c08dbe0cc27`.
The native Python dispatcher is selected, no owned probe fixture is bundled, and
the package includes the latest PIN dialog and mobile fullscreen fixes. No
official iPhone release or mirror installer was replaced.
