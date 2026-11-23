from pathlib import Path
import subprocess,tempfile
from android_compile_support import resolve_jdk_bin,SUFFIX
ROOT=Path(__file__).resolve().parents[2];SRC=ROOT/'android-tv/src/main/java/com/pilipala/marcomovie'
with tempfile.TemporaryDirectory(prefix='tv-layout-feedback-') as tmp:
    sources=[SRC/'TvMineActionMetrics.java',SRC/'TvRailMetrics.java',ROOT/'android-tv/tests/TvMineActionMetricsChecks.java',ROOT/'android-tv/tests/TvRailMetricsChecks.java']
    subprocess.run([str(resolve_jdk_bin()/('javac'+SUFFIX)),'-encoding','UTF-8','-d',tmp,*map(str,sources)],check=True)
    for name in ['TvMineActionMetricsChecks','TvRailMetricsChecks']:
        subprocess.run([str(resolve_jdk_bin()/('java'+SUFFIX)),'-cp',tmp,'com.pilipala.marcomovie.'+name],check=True)
