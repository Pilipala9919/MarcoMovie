from pathlib import Path
import os, subprocess
ROOT=Path(__file__).resolve().parents[2]
JDK=Path(os.environ.get('MARCOMOVIE_JDK',os.environ.get('JAVA_HOME', 'missing-jdk')))
ANDROID=Path(os.environ.get('MARCOMOVIE_ANDROID_JAR',str(ROOT/'tools/android-35/android.jar')))
test=ROOT/'android/tests';out=test/'js-player-classes';out.mkdir(exist_ok=True)
deps=[test/'lib/json-20240303.jar',ANDROID,ROOT/'android/build/aar/wrapper-android-3.2.3/classes.jar',ROOT/'tools/java-dependencies/wrapper-java-3.2.3.jar',ROOT/'tools/java-dependencies/jsoup-1.18.3.jar']
classpath=os.pathsep.join(map(str,deps))
sources=[ROOT/'android/src/main/java/com/pilipala/marcomovie'/f for f in ('Cms.java','RequestScope.java','SourceEngine.java','JsEngine.java','ProxyAddress.java')]
subprocess.run([str(JDK/'bin/javac.exe'),'-encoding','UTF-8','-source','8','-target','8','-Xlint:-options','-cp',classpath,'-d',str(out),*map(str,sources),str(test/'JsPlayerChecks.java')],check=True)
result=subprocess.run([str(JDK/'bin/java.exe'),'-cp',str(out)+os.pathsep+classpath,'com.pilipala.marcomovie.JsPlayerChecks',str(ROOT)],check=True,capture_output=True,text=True,encoding='utf-8')
print(result.stdout);(test/'js-player-results.txt').write_text(result.stdout,encoding='utf-8')
