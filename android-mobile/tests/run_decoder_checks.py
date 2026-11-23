"""Check failure categories without a device or any media service."""
from pathlib import Path
import os, subprocess
ROOT=Path(__file__).resolve().parents[2]
JDK=Path(os.environ.get('MARCOMOVIE_JDK',os.environ.get('JAVA_HOME','missing-jdk')))
OUT=ROOT/'android-mobile/build/decoder-check';OUT.mkdir(parents=True,exist_ok=True)
suffix='.exe' if os.name=='nt' else ''
subprocess.run([str(JDK/'bin'/('javac'+suffix)),'-encoding','UTF-8','-d',str(OUT),str(ROOT/'android-mobile/src/main/java/com/pilipala/marcomovie/PlaybackFailure.java'),str(ROOT/'android-mobile/tests/PlaybackFailureChecks.java')],check=True)
subprocess.run([str(JDK/'bin'/('java'+suffix)),'-cp',str(OUT),'com.pilipala.marcomovie.PlaybackFailureChecks'],check=True)
