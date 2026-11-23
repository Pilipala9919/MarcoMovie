"""Prepare/compile only on local host; optional oracle execution requires an explicit cloud Linux host.
No ADB, emulator, signing, network, installation or product editing.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[3]
PREVIOUS = "6528b1ae6015a459c259cc982d10fe1070ee31bb"


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ("out", "jdk", "android", "d8", "current-classes", "baseline-classes"):
        p.add_argument("--" + name, type=Path, required=True)
    p.add_argument("--cloud-contract", action="store_true",
                   help="Execute JVM oracle only on the explicitly authorized cloud Linux host")
    a = p.parse_args()
    out = a.out.resolve(); build = (ROOT / "android-mobile/build").resolve()
    if not out.is_relative_to(build) or out == build or out.exists():
        p.error("Use a new directory under this F checkout android-mobile/build")
    if a.cloud_contract and (os.name == "nt" or os.environ.get("MARCO_AUTHORIZED_CLOUD_TEST") != "1"):
        p.error("JVM execution restricted to authorized cloud Linux; local preparation is compile only")
    out.mkdir(parents=True)
    report = {"started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "native_execution": False, "jvm_execution": a.cloud_contract, "apk_build": False,
              "source_checks": {}, "commands": []}
    suffix = ".exe" if os.name == "nt" else ""
    javac = a.jdk / "bin" / ("javac" + suffix); java = a.jdk / "bin" / ("java" + suffix)

    def run(label, *cmd):
        r = subprocess.run(list(map(str, cmd)), cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (out / (label + ".log")).write_bytes(r.stdout)
        report["commands"].append({"label": label, "exit_code": r.returncode})
        if r.returncode: raise RuntimeError(label + " failed; retained log")

    try:
        for name in ("HomeProbe", "HomeRenderDiagnostics", "GridRenderCompareProbe"):
            rel = "android-mobile/tests/device/" + name + ".java"
            old = subprocess.check_output(["git", "show", PREVIOUS + ":" + rel], cwd=ROOT).replace(b"\r\n", b"\n")
            new = (ROOT / rel).read_bytes().replace(b"\r\n", b"\n")
            if old != new: raise AssertionError("Existing test changed: " + name)
            report["source_checks"][name + "_unchanged_lf"] = hashlib.sha256(new).hexdigest()
        sources = [ROOT / ("android-mobile/tests/device/" + name + ".java") for name in
                   ("PartialRenderKeyProbe", "PartialKeyContract")]
        for label, product in (("current", a.current_classes), ("baseline", a.baseline_classes)):
            classes = out / (label + "-classes"); classes.mkdir()
            cp = os.pathsep.join(map(str, (a.android, product)))
            run(label + "-javac", javac, "-encoding", "UTF-8", "-source", "8", "-target", "8",
                "-Xlint:-options", "-classpath", cp, "-d", classes, *sources)
            archive = out / (label + "-probe.jar")
            with zipfile.ZipFile(archive, "w") as jar:
                for path in sorted(classes.rglob("*.class")): jar.write(path, path.relative_to(classes).as_posix())
            dex = out / (label + "-dex"); dex.mkdir()
            run(label + "-d8", java, "-cp", a.d8, "com.android.tools.r8.D8", "--min-api", "23",
                "--lib", a.android, "--classpath", product, "--output", dex, archive)
            report[label + "_classpath"] = {"path": str(product.resolve()),
                "sha256": hashlib.sha256(product.read_bytes()).hexdigest()}
        oracle = out / "oracle"; oracle.mkdir()
        run("oracle-javac", javac, "-encoding", "UTF-8", "-source", "8", "-target", "8", "-Xlint:-options",
            "-d", oracle, ROOT / "android-mobile/tests/device/PartialKeyContract.java",
            ROOT / "android-mobile/tests/diagnostics/PartialKeyContractCheck.java")
        if a.cloud_contract:
            run("oracle-contract", java, "-cp", oracle, "com.pilipala.marcomovie.PartialKeyContractCheck")
        report["prepared"] = True
        report["behavior_validation"] = "cloud JVM only; no native claim" if a.cloud_contract else "NOT RUN; cloud only"
    except Exception as error:
        report["prepared"] = False; report["error"] = str(error)
        raise
    finally:
        report["finished_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        (out / "check-result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__": main()
