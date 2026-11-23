"""Compile the real app and exercise the sideloaded subtitle duration adapter on JVM."""
from pathlib import Path
import os,subprocess,tempfile
from android_compile_support import compile_real_android_sources,resolve_jdk_bin,SUFFIX
ROOT=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='tv-subtitle-duration-') as temp:
    work=Path(temp)
    cp=compile_real_android_sources(work/'classes',work,[ROOT/'android-tv/tests/TvSubtitleDurationChecks.java'])
    subprocess.run([str(resolve_jdk_bin()/('java'+SUFFIX)),'-cp',os.pathsep.join(map(str,cp)),
                    'androidx.media3.exoplayer.source.TvSubtitleDurationChecks'],check=True)
