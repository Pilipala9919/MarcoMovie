# 第三方组件与致谢

Marco Movie 的作者为 Pilipala。以下第三方组件保留其自身版权与许可，不能将其归为项目作者原创。

| 组件 | 说明与许可记录 |
| --- | --- |
| AndroidX Media3、Guava、Kotlin 及相关依赖 | `android/media-dependencies.json`；完整许可及声明在 `android/src/main/assets/media-third-party-notices.txt` |
| OkHttp / Okio | Apache-2.0；`android/src/main/assets/third-party-notices.txt` |
| Gson、其他接口依赖 | `android/dependencies.json` 与 `android/src/main/assets/source-engine-third-party-notices.txt` |
| QuickJS 及 Java/Android wrapper | `android/src/main/assets/js-host/quickjs.LICENSE`、`quickjs-wrapper.LICENSE` |
| jsoup、CryptoJS、JSONPath | `android/src/main/assets/js-host/` 中相应 LICENSE 文件；宿主适配层与第三方库分别保留 |
| libtorrent / FrostWire jlibtorrent | `android/torrent-dependencies.json` 与 `android/src/main/assets/torrent-third-party-notices.txt` |
| Rime 简体拼音词典、Unicode Unihan 数据 | `android/src/main/assets/search/` 中许可及 provenance 清单 |

固定依赖版本和摘要用于构建复核，不表示采用各项目最新版本。源码和 APK 都保留第三方许可记录。运行时用户自行载入的内容扩展不随本仓库提供，其权利和行为不由这份组件清单覆盖。

品牌图片由项目作者提供并通过 AI 辅助衍生；应用图标和桌面横幅不含第三方影视海报。系统字体来自运行设备，不随项目单独分发。

## 原生解码组件

FFmpeg 6.1.6（本次配置为 LGPL-2.1-or-later）、Media3、libgav1、cpu_features、Abseil（Apache-2.0）及 libvpx（BSD 许可及专利声明）。完整许可随 APK 保存在 `android/src/main/assets/decoder-licenses/`，固定源码提交、对应源码和修改说明见 [解码组件说明](docs/DECODERS.md)。这些组件归各上游作者所有。
