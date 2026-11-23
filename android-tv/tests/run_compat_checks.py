from pathlib import Path
import json, os, subprocess, sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(ROOT / 'scripts'))
from java_dependencies import ensure_java_dependencies, ensure_json_jar, verified_file
from prepare_android_platform import prepare as prepare_android

if not os.environ.get('MARCOMOVIE_ANDROID_JAR'):
    prepare_android()
jar = ensure_json_jar()
ensure_java_dependencies('OkHttp', 'Okio', 'Gson', 'jsoup', 'wrapper-android', 'wrapper-java')
for item in json.loads((ROOT / 'android-tv/torrent-dependencies.json').read_text(encoding='utf-8')):
    if item.get('java_classes'):
        filename = item['url'].rsplit('/', 1)[1]
        verified_file(ROOT / 'tools/java-dependencies' / filename, item['url'], item['sha256'])

JDK = Path(os.environ.get('MARCOMOVIE_JDK', os.environ.get('JAVA_HOME', 'missing-jdk')))
folder = ROOT / 'android-tv/build/compat-check'
folder.mkdir(exist_ok=True, parents=True)
sources = [
    ROOT / 'android-tv/src/main/java/com/pilipala/marcomovie' / name
    for name in [
        'AppLog.java',
        'Cms.java',
        'RequestScope.java',
        'ProxyAddress.java',
        'MediaOptions.java',
        'DanmakuData.java',
        'PhoneticSearchIndex.java',
        'WatchHistory.java',
        'HomeKeyTracker.java',
    ]
]
subprocess.run(
    [
        str(JDK / 'bin' / ('javac.exe' if os.name == 'nt' else 'javac')),
        '-encoding',
        'UTF-8',
        '-cp',
        str(jar),
        '-d',
        str(folder),
        str(ROOT / 'shared/java/com/pilipala/source/Json.java'),
        str(ROOT / 'shared/java/com/pilipala/source/Warehouse.java'),
        *map(str, sources),
        str(ROOT / 'android-tv/tests/CompatChecks.java'),
    ],
    check=True,
)
result = subprocess.run(
    [
        str(JDK / 'bin' / ('java.exe' if os.name == 'nt' else 'java')),
        '-Dfile.encoding=UTF-8',
        '-cp',
        str(folder) + os.pathsep + str(jar),
        'com.pilipala.marcomovie.CompatChecks',
        str(ROOT),
    ],
    capture_output=True,
    text=True,
    encoding='utf8',
)
print(result.stdout)
if result.returncode:
    print(result.stderr, file=sys.stderr)
    result.check_returncode()
(ROOT / 'android-tv/tests/compat-results.txt').write_text(result.stdout, encoding='utf8')
