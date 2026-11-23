"""Run the same HTTP T4 contract fixture as Android instrumentation on the JVM."""
from pathlib import Path
import os
import subprocess

ROOT = Path(__file__).resolve().parents[2]
JDK = Path(os.environ.get('MARCOMOVIE_JDK', os.environ.get('JAVA_HOME', 'missing-jdk')))
OUT = ROOT / 'android-mobile/tests/t4-classes'
OUT.mkdir(exist_ok=True)
JSON = ROOT / 'android-mobile/tests/lib/json-20240303.jar'
APP = ROOT / 'android-mobile/src/main/java/com/pilipala/marcomovie'
FILES = [APP / name for name in ('Cms.java', 'RequestScope.java', 'SourceEngine.java', 'HttpT4Engine.java')]
FILES += [ROOT / 'shared/java/com/pilipala/source/Json.java', ROOT / 'shared/java/com/pilipala/source/Warehouse.java', ROOT / 'android-mobile/tests/device/HttpT4Checks.java']
SUFFIX = '.exe' if os.name == 'nt' else ''
subprocess.run([str(JDK / 'bin' / ('javac' + SUFFIX)), '-encoding', 'UTF-8', '-cp', str(JSON), '-d', str(OUT), *map(str, FILES)], check=True)
subprocess.run([str(JDK / 'bin' / ('java' + SUFFIX)), '-cp', str(OUT) + os.pathsep + str(JSON), 'com.pilipala.marcomovie.HttpT4Checks'], check=True)
