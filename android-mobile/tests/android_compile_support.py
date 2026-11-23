"""Shared pure-JVM compiler/runtime support for Android offline checks against real sources."""

from pathlib import Path
import json
import os
import re
import subprocess
import sys

from java_dependencies import JAVA_DEPENDENCIES_DIR, ensure_json_jar, verified_file

ROOT = Path(__file__).resolve().parents[2]
SUFFIX = ".exe" if os.name == "nt" else ""
DEPENDENCY_MANIFESTS = (
    ROOT / "android-mobile/dependencies.json",
    ROOT / "android-mobile/media-dependencies.json",
    ROOT / "android-mobile/torrent-dependencies.json",
)
R_REF_PATTERN = re.compile(r"(?<!\.)\bR\.([a-z_]+)\.([A-Za-z0-9_]+)\b")


def resolve_jdk_bin() -> Path:
    jdk_home = os.environ.get("MARCOMOVIE_JDK") or os.environ.get("JAVA_HOME")
    if not jdk_home:
        raise RuntimeError("Set MARCOMOVIE_JDK or JAVA_HOME to JDK 17 before running Android checks")
    return Path(jdk_home) / "bin"


def ensure_android_jar() -> Path:
    env_jar = os.environ.get("MARCOMOVIE_ANDROID_JAR")
    if env_jar and Path(env_jar).is_file():
        return Path(env_jar)
    for env_key in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        sdk_root = os.environ.get(env_key)
        if sdk_root:
            candidate = Path(sdk_root) / "platforms/android-35/android.jar"
            if candidate.is_file():
                return candidate
    if str(ROOT) not in sys.path:
        sys.path.insert(0, str(ROOT))
    from scripts.prepare_android_platform import prepare

    return prepare()


def ensure_all_android_dep_jars(extract_dir: Path) -> list[Path]:
    jars: list[Path] = []
    extract_dir.mkdir(parents=True, exist_ok=True)
    for manifest_path in DEPENDENCY_MANIFESTS:
        items = json.loads(manifest_path.read_text(encoding="utf-8"))
        for item in items:
            if item.get("java_classes") is False:
                continue
            filename = item["url"].rsplit("/", 1)[1]
            target = JAVA_DEPENDENCIES_DIR / filename
            verified_file(target, item["url"], item["sha256"])
            if target.suffix == ".jar":
                jars.append(target)
            elif target.suffix == ".aar":
                import zipfile

                out_jar = extract_dir / f"{target.stem}-{item['sha256'][:12]}-classes.jar"
                if not out_jar.exists():
                    with zipfile.ZipFile(target) as archive:
                        if "classes.jar" not in archive.namelist():
                            continue
                        data = archive.read("classes.jar")
                    tmp = out_jar.with_suffix(f".{os.getpid()}.tmp")
                    tmp.write_bytes(data)
                    tmp.replace(out_jar)
                jars.append(out_jar)
    return jars


def generate_r_java(gen_dir: Path, source_files: list[Path]) -> Path:
    r_refs: dict[str, set[str]] = {}
    for src in source_files:
        text = src.read_text(encoding="utf-8")
        for kind, name in R_REF_PATTERN.findall(text):
            r_refs.setdefault(kind, set()).add(name)

    lines = ["package com.pilipala.marcomovie;", "", "public final class R {"]
    next_id = 0x7F010001
    for kind, names in sorted(r_refs.items()):
        lines.append(f"    public static final class {kind} {{")
        for name in sorted(names):
            lines.append(f"        public static final int {name} = 0x{next_id:08x};")
            next_id += 1
        lines.append("    }")
    lines.append("}")

    r_file = gen_dir / "com/pilipala/marcomovie/R.java"
    r_file.parent.mkdir(parents=True, exist_ok=True)
    r_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return r_file


RUNTIME_STUBS = {
    "android/graphics/Typeface.java": """package android.graphics;

public class Typeface {
    public static final int NORMAL = 0;
    public static final int BOLD = 1;
    public static final int ITALIC = 2;
    public static final int BOLD_ITALIC = 3;
    public static final Typeface DEFAULT = new Typeface();
    public static final Typeface DEFAULT_BOLD = new Typeface();
    public static final Typeface SANS_SERIF = new Typeface();
    public static final Typeface SERIF = new Typeface();
    public static final Typeface MONOSPACE = new Typeface();

    public static Typeface create(String familyName, int style) {
        return DEFAULT;
    }

    public static Typeface create(Typeface family, int style) {
        return DEFAULT;
    }

    public int getStyle() {
        return NORMAL;
    }

    public final boolean isBold() {
        return false;
    }

    public final boolean isItalic() {
        return false;
    }
}
"""
}


def compile_real_android_sources(
    classes_dir: Path,
    work_dir: Path,
    test_sources: list[Path],
    extra_runtime_stubs: dict[str, str] | None = None,
) -> list[Path]:
    classes_dir.mkdir(parents=True, exist_ok=True)
    aar_cache = ROOT / "android-mobile/build/test-dep-classes"
    dep_jars = [ensure_json_jar(), *ensure_all_android_dep_jars(aar_cache), ensure_android_jar()]

    real_sources = sorted((ROOT / "shared/java").rglob("*.java")) + sorted(
        (ROOT / "android-mobile/src/main/java").rglob("*.java")
    )

    gen_dir = work_dir / "gen-src"
    r_file = generate_r_java(gen_dir, real_sources + list(test_sources))

    all_sources = [r_file, *real_sources, *test_sources]
    sources_argfile = work_dir / "javac-sources.txt"
    sources_argfile.write_text(
        "\n".join(f'"{Path(p).resolve().as_posix()}"' for p in all_sources) + "\n",
        encoding="utf-8",
    )

    jdk = resolve_jdk_bin()
    compile_cp = os.pathsep.join(str(p) for p in dep_jars)
    subprocess.run(
        [
            str(jdk / ("javac" + SUFFIX)),
            "-encoding",
            "UTF-8",
            "-source",
            "8",
            "-target",
            "8",
            "-Xlint:-options",
            "-cp",
            compile_cp,
            "-d",
            str(classes_dir),
            f"@{sources_argfile}",
        ],
        check=True,
    )

    runtime_stubs = dict(RUNTIME_STUBS)
    if extra_runtime_stubs:
        runtime_stubs.update(extra_runtime_stubs)
    stubs_src_dir = work_dir / "runtime-stubs-src"
    stubs_classes_dir = work_dir / "runtime-stubs-classes"
    stubs_classes_dir.mkdir(parents=True, exist_ok=True)
    stub_files: list[Path] = []
    for rel_path, content in runtime_stubs.items():
        target = stubs_src_dir / rel_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        stub_files.append(target)
    if stub_files:
        subprocess.run(
            [
                str(jdk / ("javac" + SUFFIX)),
                "-encoding",
                "UTF-8",
                "-source",
                "8",
                "-target",
                "8",
                "-Xlint:-options",
                "-d",
                str(stubs_classes_dir),
                *(str(p) for p in stub_files),
            ],
            check=True,
        )

    return [classes_dir, stubs_classes_dir, *dep_jars]
