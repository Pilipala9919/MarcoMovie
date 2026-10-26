"""Offline keyboard and bounded-search behavior checks; no TV or real content request."""
from pathlib import Path
import os, subprocess
ROOT=Path(__file__).resolve().parents[2]
JDK=Path(os.environ.get('MARCOMOVIE_JDK',os.environ.get('JAVA_HOME', 'missing-jdk')))
out=ROOT/'android/tests/global-search-classes';out.mkdir(exist_ok=True)
jar=ROOT/'android/tests/lib/json-20240303.jar'
sources=[ROOT/'android/src/main/java/com/pilipala/marcomovie'/name for name in ('Cms.java','PinyinKeyboardModel.java','SearchCoordinator.java')]
subprocess.run([str(JDK/'bin/javac.exe'),'-encoding','UTF-8','-source','8','-target','8','-Xlint:-options','-cp',str(jar),'-d',str(out),*map(str,sources),str(ROOT/'android/tests/GlobalSearchChecks.java')],check=True)
result=subprocess.run([str(JDK/'bin/java.exe'),'-cp',str(out)+os.pathsep+str(jar),'com.pilipala.marcomovie.GlobalSearchChecks',str(ROOT)],check=True,text=True,encoding='utf8',capture_output=True)
print(result.stdout);(ROOT/'android/tests/global-search-results.txt').write_text(result.stdout,encoding='utf8')
