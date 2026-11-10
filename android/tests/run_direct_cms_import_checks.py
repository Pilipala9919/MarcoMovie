"""Compile the production importer and exercise it with an offline HTTP transport."""
from pathlib import Path
import hashlib
import os
import subprocess

ROOT = Path(__file__).resolve().parents[2]
JDK = Path(os.environ.get('MARCOMOVIE_JDK', os.environ.get('JAVA_HOME', 'missing-jdk')))


def main():
    tests = ROOT / 'android/tests'
    jar = tests / 'lib/json-20240303.jar'
    if not jar.exists():
        raise SystemExit('Prepare the JSON test dependency with android/tests/run_checks.py first')
    if hashlib.sha256(jar.read_bytes()).hexdigest() != '3cf6cd6892e32e2b4c1c39e0f52f5248a2f5b37646fdfbb79a66b46b618414ed':
        raise RuntimeError('Test JSON library digest mismatch')
    classes = ROOT / 'android/build/direct-cms-import-checks'
    classes.mkdir(parents=True, exist_ok=True)
    source = ROOT / 'android/src/main/java/com/pilipala/marcomovie'
    files = [source / name for name in (
        'Cms.java', 'RequestScope.java', 'SourceEngine.java', 'JsonCmsEngine.java', 'VideoFilters.java')]
    files += [ROOT / 'shared/java/com/pilipala/source/Warehouse.java', tests / 'DirectCmsImportChecks.java']
    suffix = '.exe' if os.name == 'nt' else ''
    subprocess.run([str(JDK / 'bin' / ('javac' + suffix)), '-encoding', 'UTF-8',
                    '-source', '8', '-target', '8', '-Xlint:-options', '-cp', str(jar),
                    '-d', str(classes), *map(str, files)], check=True)
    result = subprocess.run([str(JDK / 'bin' / ('java' + suffix)), '-cp',
                             str(classes) + os.pathsep + str(jar), 'DirectCmsImportChecks'],
                            check=True, text=True, encoding='utf-8', capture_output=True)
    print(result.stdout, end='')
    (classes / 'results.txt').write_text(result.stdout, encoding='utf-8')


if __name__ == '__main__':
    main()
