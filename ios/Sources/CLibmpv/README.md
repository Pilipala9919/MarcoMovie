# CLibmpv (libmpv 0.36.0 / API 2.1 C Declarations)

Because `Mpv.xcframework` `v0.6.0` (`libmpv-xcframeworks_v0.6.0_ios-universal-video-default.tar.gz`) ships binary framework slices without public headers, `include/CLibmpv.h` provides the exact ABI-compatible C structs, enums, and prototypes for `libmpv 0.36.0` (`MPV_CLIENT_API_VERSION = (2 << 16) | 1`).

In `--light-simulator` mode `MARCO_HAS_MPV` is unset and `clibmpv_anchor.c` compiles with zero link dependency on `Mpv.framework`.
