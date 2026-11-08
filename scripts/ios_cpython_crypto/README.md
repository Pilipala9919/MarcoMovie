# iOS native Crypto dependency

This builds the pinned upstream PyCryptodome source into individual iOS
frameworks. Its Python package and C algorithms are retained; the sole package
change selects the bundled framework in `Crypto.Util._raw_api` on iOS. Ordinary
Python `.fwork` imports cannot serve this package's ctypes raw-library loader.

`source.lock.json` fixes the source archive and SHA-256. The builder reads the
static extension list without executing setup.py, builds all **41 portable raw
libraries**, and omits only 18 explicitly enumerated optional CPU accelerators.
Upstream callers select their portable equivalents. This is not a reimplementation
of AES, a source-specific decryption recipe, or a copied playback address.

The bundled `Crypto/LICENSE.rst` is copied from the source distribution. Upstream
SelfTest files are not included in the application. The dependency build records
source hashes, framework hashes, package hashes, target and architecture. It
requires Apple's compiler and does not download native code at application runtime.

Host-only checks:

```sh
python scripts/test_ios_crypto.py
```

Native checks run through `ios-runtime.yml`, selecting `cpython_flutter` and both
architectures. The production Python source channel and own-GIL owner are used by
`crypto_spider.py` / `crypto_fixture.dart`. Required checks load every native
library, exercise known AES/DES/ARC4/hash answers, RSA/ECC/Ed25519 operations,
concurrent independent source owners, retained cipher state, source destruction
and recreation, UI responsiveness, and surviving Node/QuickJS engines. The app
runs separately in Python-first and Node-first launch order.

These are owned-source simulator tests. They do not establish physical-iPhone
playback, iOS 14 execution, compatibility with every Python dependency, or support
for arbitrary Android JAR plugins. lxml is a separate native dependency and is
not supplied by this work. A published run's exact result and input hashes must
be checked before claiming native acceptance or enabling product packaging.

## Recorded ARM64 result

The ARM64 job of [run 42470008082](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42470008082)
at `7e7cad071c82cf40d64e9cb57b7e45ba694ad4c6` passed all 162 checks in each
launch order on an iOS 18.5 simulator (324 total). All 161 recorded repository
input hashes were verified, as were the 41-library inventory and all 120 bundled
Crypto package files against the pinned source plus the explicit loader patch.
The Intel job compiled but stopped after 43 earlier checks at `transportProbe`,
before this Crypto fixture; it has no completed app result and is not accepted.
The overall two-architecture workflow therefore remains failed, not passed.

The product preparer now uses this same builder, includes its inputs in cache
invalidation, and validates every staged package file before embedding. This
does not publish an IPA or remove the separate real-source/device release gates.
