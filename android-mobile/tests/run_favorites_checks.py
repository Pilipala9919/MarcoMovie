"""Check failure categories without a device or any media service."""
from pathlib import Path
import os, subprocess
ROOT=Path(__file__).resolve().parents[2]
JDK=Path(os.environ.get('MARCOMOVIE_JDK',os.environ.get('JAVA_HOME','missing-jdk')))
OUT=ROOT/'android-mobile/build/decoder-check';OUT.mkdir(parents=True,exist_ok=True)
suffix='.exe' if os.name=='nt' else ''
subprocess.run([str(JDK/'bin'/('javac'+suffix)),'-encoding','UTF-8','-d',str(OUT),'-cp',str(ROOT/'android-mobile/tests/lib/json-20240303.jar'),str(ROOT/'shared/java/com/pilipala/source/Json.java'),str(ROOT/'shared/java/com/pilipala/source/Warehouse.java'),str(ROOT/'android-mobile/src/main/java/com/pilipala/marcomovie/Cms.java'),str(ROOT/'android-mobile/src/main/java/com/pilipala/marcomovie/RequestScope.java'),str(ROOT/'android-mobile/src/main/java/com/pilipala/marcomovie/Favorites.java'),str(ROOT/'android-mobile/src/main/java/com/pilipala/marcomovie/VideoSkipStore.java'),str(ROOT/'android-mobile/tests/FavoritesChecks.java')],check=True)
subprocess.run([str(JDK/'bin'/('java'+suffix)),'-cp',str(OUT)+os.pathsep+str(ROOT/'android-mobile/tests/lib/json-20240303.jar'),'com.pilipala.marcomovie.FavoritesChecks'],check=True)
