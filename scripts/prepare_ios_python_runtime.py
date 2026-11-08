"""Stage pinned iOS Python inputs and embed them before final app signing.

Uses the same archive, dependency lock and .fwork conversion as the exercised
native runner. No test fixture, launch configuration or source subscription is
bundled. This does not sign or publish the resulting application.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "flutter/packages/python_source_runtime"
HOST = ROOT / "android/src/main/assets/python-native"
ADAPTER = ROOT / "scripts/ios_cpython_transport/requests_adapter.py"
SPEC = importlib.util.spec_from_file_location("ios_python_staging", ROOT / "scripts/ios_cpython/run_cpython_probe.py")
native = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(native)


def files_digest(directory):
    return {p.relative_to(directory).as_posix(): native.digest(p)
            for p in sorted(directory.rglob("*")) if p.is_file()}


def source_inputs():
    paths = [Path(__file__).resolve(), ROOT / "scripts/ios_cpython/run_cpython_probe.py",
             ROOT / "scripts/ios_cpython/pure-dependencies.lock.json", HOST / "host.py", ADAPTER]
    paths += sorted((HOST / "base").rglob("*.py"))
    paths += sorted((RUNTIME / "python").glob("*.py"))
    return {p.relative_to(ROOT).as_posix(): native.digest(p) for p in paths}


def verify_stage(stage):
    report = json.loads((stage / "prepared.json").read_text(encoding="utf-8"))
    if report.get("inputs") != source_inputs() or report.get("files") != files_digest(stage / "bundle"):
        raise ValueError("Python stage changed; prepare a fresh build directory")
    return report


def copy_framework(stage, destination):
    source = stage / "bundle/Frameworks/Python.framework"
    target = destination / "Python.framework"
    if target.exists():
        if files_digest(target) != files_digest(source):
            raise ValueError("Python link framework differs; use a fresh build directory")
    else:
        destination.mkdir(parents=True, exist_ok=True)
        shutil.copytree(source, target)


def prepare(stage, frameworks, cache, target="device", arch="arm64"):
    if target not in ("device", "simulator") or arch not in ("arm64", "x86_64") or target == "device" and arch != "arm64":
        raise ValueError("Invalid iOS runtime slice")
    if stage.exists():
        report = verify_stage(stage)
        if report["runtime"]["target"] != target or report["runtime"]["architecture"] != arch:
            raise ValueError("Python stage is for another target")
    else:
        bundle = stage / "bundle"
        bundle.mkdir(parents=True)
        report = native.stage(bundle, target, arch, cache, include_fixture=False,
                              identifier="com.pilipala.marcomovie.python")
        shutil.copyfile(HOST / "host.py", bundle / "app/native_source_host.py")
        shutil.copyfile(ADAPTER, bundle / "app/requests_adapter.py")
        shutil.copytree(HOST / "base", bundle / "app/base", ignore=shutil.ignore_patterns("__pycache__"))
        for path in (RUNTIME / "python").glob("*.py"):
            shutil.copyfile(path, bundle / "app" / path.name)
        report = {"version": 1, "runtime": report, "inputs": source_inputs(), "files": files_digest(bundle)}
        (stage / "prepared.json").write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
    copy_framework(stage, frameworks)
    return report


def embed(stage, app):
    report = verify_stage(stage)
    if not (app / "Info.plist").is_file():
        raise ValueError("Expected a built iOS application")
    for name in ("python", "app", "app_packages", "Frameworks"):
        destination = app / name
        if destination.is_symlink() or not destination.resolve().is_relative_to(app.resolve()):
            raise ValueError("Runtime destination escapes the application")
        # Refuse pre-existing nested links instead of following them during copy.
        if destination.exists() and any(p.is_symlink() for p in destination.rglob("*")):
            raise ValueError("Unexpected symlink in iOS application runtime destination")
        shutil.copytree(stage / "bundle" / name, destination, dirs_exist_ok=True)
    for name in ("Headers", "Modules"):
        path = app / "Frameworks/Python.framework" / name
        if path.exists():
            if not path.resolve().is_relative_to(app.resolve()):
                raise ValueError("Framework headers escape application")
            shutil.rmtree(path)
    (app / "python-runtime-manifest.json").write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    stage = commands.add_parser("prepare")
    stage.add_argument("--stage-dir", type=Path, required=True)
    stage.add_argument("--frameworks", type=Path, required=True)
    stage.add_argument("--cache", type=Path, default=ROOT / "tools/python-ios")
    stage.add_argument("--target", choices=("device", "simulator"), default="device")
    stage.add_argument("--arch", choices=("arm64", "x86_64"), default="arm64")
    install = commands.add_parser("embed")
    install.add_argument("--stage-dir", type=Path, required=True)
    install.add_argument("--app", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.stage_dir.resolve(), args.frameworks.resolve(), args.cache.resolve(), args.target, args.arch)
    else:
        embed(args.stage_dir.resolve(), args.app.resolve())
    print("Python runtime " + args.command + " verified")


if __name__ == "__main__":
    main()
