from pathlib import Path
import os, subprocess
from android_compile_support import resolve_jdk_bin, SUFFIX
ROOT=Path(__file__).resolve().parents[2]
SRC=ROOT/'android-tv/src/main/java/com/pilipala/marcomovie'
out=ROOT/'android-tv/build/tv-feedback-checks';out.mkdir(parents=True,exist_ok=True)
sources=[SRC/x for x in ['PhoneticSearchIndex.java','TvReadingScrollPolicy.java','MediaContentProbe.java','ProxyAddress.java','RequestScope.java']]
subprocess.run([str(resolve_jdk_bin()/('javac'+SUFFIX)),'-encoding','UTF-8','-d',str(out),*map(str,sources),str(ROOT/'android-tv/tests/TvFeedbackChecks.java')],check=True)
subprocess.run([str(resolve_jdk_bin()/('java'+SUFFIX)),'-Dfile.encoding=UTF-8','-cp',str(out),'com.pilipala.marcomovie.TvFeedbackChecks',str(ROOT)],check=True)
