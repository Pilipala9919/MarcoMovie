"""Standalone pure-JVM + local 127.0.0.1 HTTP checks for M3a segmented danmu engine."""

from pathlib import Path
import os
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from java_dependencies import ensure_json_jar

JDK = os.environ.get("MARCOMOVIE_JDK") or os.environ.get("JAVA_HOME")


def tool(name: str) -> str:
    if JDK:
        return str(Path(JDK) / "bin" / (name + (".exe" if os.name == "nt" else "")))
    return shutil.which(name) or name


def main() -> int:
    json_jar = ensure_json_jar()
    out_dir = ROOT / "android-tv/build/danmu-check"
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.rglob("*.class"):
        old.unlink()

    src_dir = ROOT / "android-tv/src/main/java/com/pilipala/marcomovie"
    sources = [
        src_dir / "DanmuProvider.java",
        src_dir / "DandanplayProvider.java",
        src_dir / "DanmuSegmentCache.java",
        ROOT / "android-tv/tests/DanmuEngineChecks.java",
    ]
    subprocess.run(
        [
            tool("javac"),
            "-encoding",
            "UTF-8",
            "-source",
            "8",
            "-target",
            "8",
            "-Xlint:-options",
            "-cp",
            str(json_jar),
            "-d",
            str(out_dir),
            *map(str, sources),
        ],
        check=True,
    )
    result = subprocess.run(
        [
            tool("java"),
            "-Dfile.encoding=UTF-8",
            "-cp",
            str(out_dir) + os.pathsep + str(json_jar),
            "com.pilipala.marcomovie.DanmuEngineChecks",
        ],
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
    )
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, file=sys.stderr, end="")
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
