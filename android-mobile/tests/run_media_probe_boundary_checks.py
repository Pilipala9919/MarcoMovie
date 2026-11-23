from pathlib import Path
import subprocess
from android_compile_support import resolve_jdk_bin,SUFFIX
ROOT=Path(__file__).resolve().parents[2];SRC=ROOT/'android-mobile/src/main/java/com/pilipala/marcomovie'
out=ROOT/'android-mobile/build/media-probe-boundaries';out.mkdir(parents=True,exist_ok=True)
subprocess.run([str(resolve_jdk_bin()/('javac'+SUFFIX)),'-encoding','UTF-8','-d',str(out),*[str(SRC/n) for n in ['MediaContentProbe.java','ProxyAddress.java','RequestScope.java']],str(ROOT/'android-mobile/tests/MediaProbeBoundaryChecks.java')],check=True)
subprocess.run([str(resolve_jdk_bin()/('java'+SUFFIX)),'-cp',str(out),'com.pilipala.marcomovie.MediaProbeBoundaryChecks'],check=True)
