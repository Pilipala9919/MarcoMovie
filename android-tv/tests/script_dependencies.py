"""Pinned compile-only inputs for standalone script-host JVM checks.

These checks must work in a fresh checkout, without a prior Android app build.
Native engines are not loaded by this helper or by the pure-JVM checks.
"""
from pathlib import Path
import os
import sys
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from java_dependencies import ensure_java_dependencies, ensure_json_jar, verified_file

ROOT = Path(__file__).resolve().parents[2]


def prepare():
    parser = ensure_json_jar()
    android_override = os.environ.get('MARCOMOVIE_ANDROID_JAR')
    if android_override:
        android = Path(android_override)
        if not android.is_file():
            raise RuntimeError('Configured Android compile library is unavailable')
    else:
        sys.path.insert(0, str(ROOT / 'scripts'))
        from prepare_android_platform import prepare as prepare_android
        android = prepare_android()
    result = [parser, android]
    for package in ensure_java_dependencies('wrapper-android', 'wrapper-java', 'jsoup'):
        if package.suffix == '.aar':
            classes = ROOT / 'android-tv/build/script-test-deps' / package.stem / 'classes.jar'
            with zipfile.ZipFile(package) as archive:
                payload = archive.read('classes.jar')
            classes.parent.mkdir(parents=True, exist_ok=True)
            # Re-derive from the verified AAR, never trust a previous app build.
            classes.write_bytes(payload)
            result.append(classes)
        else:
            result.append(package)
    return result
