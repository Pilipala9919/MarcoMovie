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
