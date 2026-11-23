"""Offline JVM check runner for MediaBadges (Android) and LiteBadges (Lite API 14)."""
from pathlib import Path
import hashlib
import os
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
JDK = Path(os.environ.get('MARCOMOVIE_JDK', os.environ.get('JAVA_HOME', 'missing-jdk')))
JSON_JAR_URL = 'https://repo.maven.apache.org/maven2/org/json/json/20240303/json-20240303.jar'
JSON_JAR_SHA256 = '3cf6cd6892e32e2b4c1c39e0f52f5248a2f5b37646fdfbb79a66b46b618414ed'


def prepare_json_jar() -> Path:
    env_jar = os.environ.get('MARCOMOVIE_JSON_JAR')
    if env_jar and Path(env_jar).exists():
        return Path(env_jar)
    jar = ROOT / 'android-mobile/tests/lib/json-20240303.jar'
    if not jar.exists():
        jar.parent.mkdir(parents=True, exist_ok=True)
        jar.write_bytes(urllib.request.urlopen(JSON_JAR_URL, timeout=30).read())
    if hashlib.sha256(jar.read_bytes()).hexdigest() != JSON_JAR_SHA256:
        raise RuntimeError('Test JSON library digest mismatch')
    return jar


def main() -> None:
    test_dir = ROOT / 'android-mobile/tests'
    jar = prepare_json_jar()
    javac = JDK / 'bin' / ('javac.exe' if os.name == 'nt' else 'javac')
    java = JDK / 'bin' / ('java.exe' if os.name == 'nt' else 'java')
    sources = [
        ROOT / 'android-mobile/src/main/java/com/pilipala/marcomovie/MediaBadges.java',
        ROOT / 'lite/src/main/java/com/pilipala/marcomovie/lite/LiteBadges.java',
        test_dir / 'MediaBadgeChecks.java',
    ]
    rules_path = ROOT / 'shared/ui-spec/badge-rules.json'
    golden_path = ROOT / 'shared/ui-spec/badge-golden.json'
    with tempfile.TemporaryDirectory() as tmp:
        classes = Path(tmp) / 'classes'
        classes.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [str(javac), '-encoding', 'UTF-8', '-source', '8', '-target', '8', '-Xlint:-options',
             '-cp', str(jar), '-d', str(classes), *[str(p) for p in sources]],
            check=True,
        )
        r = subprocess.run(
            [str(java), '-Dfile.encoding=UTF-8', '-cp', str(classes) + os.pathsep + str(jar),
             'MediaBadgeChecks', str(rules_path), str(golden_path)],
            text=True,
            encoding='utf-8',
            errors='replace',
            capture_output=True,
        )
        if r.stdout:
            print(r.stdout.strip())
        if r.stderr:
            print(r.stderr.strip())
        if r.returncode != 0:
            raise SystemExit(r.returncode)


if __name__ == '__main__':
    main()
