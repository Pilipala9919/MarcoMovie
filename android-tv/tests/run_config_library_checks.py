from pathlib import Path
import os, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
jdk = Path(os.environ.get('MARCOMOVIE_JDK') or os.environ['JAVA_HOME']) / 'bin'
jar = root / 'android-tv/tests/lib/json-20240303.jar'
with tempfile.TemporaryDirectory() as output:
    sources = [root / 'android-tv/src/main/java/com/pilipala/marcomovie/ConfigLibrary.java',
               root / 'android-tv/tests/ConfigLibraryChecks.java']
    subprocess.run([jdk / 'javac', '-encoding', 'UTF-8', '-cp', jar, '-d', output, *sources], check=True)
    subprocess.run([jdk / 'java', '-cp', output + os.pathsep + str(jar),
                    'com.pilipala.marcomovie.ConfigLibraryChecks', str(Path(output) / 'store')], check=True)
