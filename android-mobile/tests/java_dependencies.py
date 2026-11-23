"""Shared helper to fetch and SHA-256 verify pinned Java test dependencies on clean checkouts."""

from pathlib import Path
import hashlib
import json
import os
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
DEPENDENCIES_MANIFEST = ROOT / "android-mobile/dependencies.json"
JAVA_DEPENDENCIES_DIR = ROOT / "tools/java-dependencies"

JSON_JAR_URL = "https://repo.maven.apache.org/maven2/org/json/json/20240303/json-20240303.jar"
JSON_JAR_SHA256 = "3cf6cd6892e32e2b4c1c39e0f52f5248a2f5b37646fdfbb79a66b46b618414ed"


def verified_file(path: Path, url: str, sha256: str) -> bytes:
    path = Path(path)
    expected = sha256.strip().lower()
    if path.exists():
        data = path.read_bytes()
    else:
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read()
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected:
        raise RuntimeError(
            f"Test dependency SHA-256 mismatch for {path.name}: expected {expected}, got {actual}"
        )
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
        tmp.write_bytes(data)
        tmp.replace(path)
    return data


def ensure_json_jar() -> Path:
    env_jar = os.environ.get("MARCOMOVIE_JSON_JAR")
    if env_jar and Path(env_jar).is_file():
        return Path(env_jar)
    jar = ROOT / "android-mobile/tests/lib/json-20240303.jar"
    verified_file(jar, JSON_JAR_URL, JSON_JAR_SHA256)
    return jar


def ensure_java_dependencies(*names: str) -> list[Path]:
    manifest = json.loads(DEPENDENCIES_MANIFEST.read_text(encoding="utf-8"))
    resolved: list[Path] = []
    for query in names:
        key = query.strip().lower()
        matches = [
            item
            for item in manifest
            if item["name"].lower() == key or item["url"].rsplit("/", 1)[1].lower() == key
        ]
        if len(matches) != 1:
            raise RuntimeError(f"Expected exactly one pinned Java dependency matching {query!r}")
        item = matches[0]
        filename = item["url"].rsplit("/", 1)[1]
        target = JAVA_DEPENDENCIES_DIR / filename
        verified_file(target, item["url"], item["sha256"])
        resolved.append(target)
    return resolved
