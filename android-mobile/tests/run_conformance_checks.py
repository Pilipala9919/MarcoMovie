"""Runner for Android TV/Mobile Conformance Test Suite (Lane H).

Compiles AOSP libcore org.json (Apache 2.0) together with production Cms and
related classes plus ConformanceChecks.java against Android SDK compile stubs
(android.jar), and executes on JVM using Android's real org.json runtime.
"""
from pathlib import Path
import os
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
JDK = Path(os.environ.get('MARCOMOVIE_JDK', os.environ.get('JAVA_HOME', 'missing-jdk')))

def compile_aosp_json(javac: str, aosp_classes_dir: Path) -> Path:
    aosp_root = ROOT / 'android-mobile/tests/lib/aosp-json'
    src_dir = aosp_root / 'src/org/json'
    annotations_dir = aosp_root / 'annotations'
    sources = sorted(src_dir.glob('*.java'))
    if not sources:
        raise RuntimeError(f'Missing AOSP org.json sources in {src_dir}')
    aosp_classes_dir.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            javac,
            '-encoding', 'UTF-8',
            '-sourcepath', str(annotations_dir),
            '-d', str(aosp_classes_dir),
            *map(str, sources),
        ],
        check=True,
    )
    return aosp_classes_dir

def ensure_android_jar() -> Path:
    override = os.environ.get('MARCOMOVIE_ANDROID_JAR')
    if override and Path(override).is_file():
        return Path(override)
    local_jar = ROOT / 'tools/android-35/android.jar'
    if local_jar.is_file():
        return local_jar
    sys.path.insert(0, str(ROOT / 'scripts'))
    from prepare_android_platform import prepare
    return prepare()

def main() -> None:
    android_jar = ensure_android_jar()

    build_dir = ROOT / 'android-mobile/build/conformance-check'
    aosp_classes_dir = build_dir / 'aosp-json-classes'
    classes_dir = build_dir / 'classes'
    classes_dir.mkdir(parents=True, exist_ok=True)

    javac = str(JDK / 'bin' / ('javac.exe' if os.name == 'nt' else 'javac'))
    java = str(JDK / 'bin' / ('java.exe' if os.name == 'nt' else 'java'))

    compile_aosp_json(javac, aosp_classes_dir)

    shared_sources = [
        ROOT / 'shared/java/com/pilipala/source/Json.java',
        ROOT / 'shared/java/com/pilipala/source/Warehouse.java',
    ]

    android_src_dir = ROOT / 'android-mobile/src/main/java/com/pilipala/marcomovie'
    required_names = [
        'AppLog.java',
        'Cms.java',
        'RequestScope.java',
        'ProxyAddress.java',
    ]
    prod_sources = [android_src_dir / name for name in required_names]

    test_source = ROOT / 'android-mobile/tests/ConformanceChecks.java'

    compile_cmd = [
        javac,
        '-encoding', 'UTF-8',
        '-cp', os.pathsep.join([str(aosp_classes_dir), str(android_jar)]),
        '-d', str(classes_dir),
        *map(str, shared_sources),
        *map(str, prod_sources),
        str(test_source),
    ]

    print('[run_conformance_checks] Compiling ConformanceChecks...')
    subprocess.run(compile_cmd, check=True)

    exec_cp = os.pathsep.join([str(classes_dir), str(aosp_classes_dir)])
    exec_cmd = [
        java,
        '-Dfile.encoding=UTF-8',
        '-cp', exec_cp,
        'com.pilipala.marcomovie.ConformanceChecks',
        str(ROOT),
    ]

    print('[run_conformance_checks] Executing ConformanceChecks...')
    res = subprocess.run(exec_cmd, capture_output=True, text=True, encoding='utf-8', errors='replace')

    results_file = ROOT / 'android-mobile/tests/conformance-results.txt'
    results_file.write_text(res.stdout + ('\nSTDERR:\n' + res.stderr if res.stderr else ''), encoding='utf-8')

    sys.stdout.write(res.stdout)
    if res.returncode != 0:
        sys.stderr.write(res.stderr)
        sys.exit(res.returncode)

if __name__ == '__main__':
    main()
