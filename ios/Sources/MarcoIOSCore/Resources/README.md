# MarcoIOSCore Synced Resources

This directory holds generated/synced runtime assets populated by `python3 ios/prepare_ios.py`:

- `js-host/`: QuickJS-NG host bootstrap scripts (`crypto-js.js`, `catvod.mjs`, `module-interop.js`, `bootstrap.js`, `drpy-core.js`).
- `catpaw/`: SHA-256 verified DRPY2 / Guard extractor & adapter scripts plus `host.cjs` and `fetch.cjs` for embedded CatPaw Node.
- `shaders/anime4k/`: Anime4K GLSL shaders and manifest for `libmpv` real-time upscaling.

Synced asset subdirectories are excluded via `ios/.gitignore` and never committed directly.
