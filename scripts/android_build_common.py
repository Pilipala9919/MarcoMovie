"""Shared Android SDK/toolchain helpers for independent TV, Mobile, and Lite builds."""
from pathlib import Path
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / 'dist'
JDK = Path(os.environ.get('MARCOMOVIE_JDK', os.environ.get('JAVA_HOME', 'missing-jdk')))
SDK = Path(os.environ.get('MARCOMOVIE_BUILD_TOOLS', 'missing-build-tools'))
ANDROID = Path(os.environ.get('MARCOMOVIE_ANDROID_JAR', str(ROOT / 'tools/android-35/android.jar')))
ENV = dict(os.environ, JAVA_HOME=str(JDK), PATH=str(JDK / 'bin') + os.pathsep + os.environ.get('PATH', ''))
# Development default only. A release key must supply its own password through
# MARCOMOVIE_KEY_PASSWORD; an externally provided value is never overridden.
ENV.setdefault('MARCOMOVIE_KEY_PASSWORD', 'android')

RELEASE_SIGNER_SHA256 = '2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de'


def exe(parent, name):
    return Path(parent) / (name + ('.exe' if os.name == 'nt' else ''))


def run(*args, capture=False):
    r = subprocess.run(
        [str(x) for x in args],
        cwd=ROOT,
        env=ENV,
        check=True,
        text=True,
        encoding='utf-8',
        errors='replace',
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )
    return r.stdout if capture else None


def resolve_signing_key(module_dir: Path, fallback_dirs=(), auto_generate=True) -> Path:
    """Resolve signing key from MARCOMOVIE_SIGNING_KEY or the module's private keystore."""
    release_mode = os.environ.get('MARCOMOVIE_RELEASE', '') == '1' or 'MARCOMOVIE_SIGNING_KEY' in os.environ
    explicit = os.environ.get('MARCOMOVIE_SIGNING_KEY')
    if explicit:
        key = Path(explicit)
    else:
        key = Path(module_dir) / 'private/development.p12'
        if not key.exists():
            for fb in fallback_dirs:
                cand = Path(fb) / 'private/development.p12'
                if cand.exists():
                    key = cand
                    break
    key.parent.mkdir(parents=True, exist_ok=True)
    if not key.exists():
        if release_mode or not auto_generate:
            raise RuntimeError(f'Release/explicit signing key missing; refusing to auto-generate: {key}')
        run(
            exe(JDK / 'bin', 'keytool'),
            '-genkeypair',
            '-keystore', key,
            '-storetype', 'PKCS12',
            '-alias', 'marcomovie',
            '-storepass:env', 'MARCOMOVIE_KEY_PASSWORD',
            '-keypass:env', 'MARCOMOVIE_KEY_PASSWORD',
            '-keyalg', 'RSA',
            '-keysize', '2048',
            '-validity', '10000',
            '-dname', 'CN=Pilipala, OU=Marco Movie Preview',
        )
    return key
