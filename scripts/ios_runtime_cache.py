"""Key and validate the complete iOS Python stage used by the product build.

Only the existing staging inputs and the selected Apple toolchain affect the
key. Flutter source and unrelated JavaScript/HTML assets are not native inputs.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
STAGE_RELATIVE = Path("flutter/build/python-runtime")
CACHE_VERSION = 1


def load_runtime(root=ROOT):
    spec = importlib.util.spec_from_file_location(
        "ios_cached_python_stage", Path(root) / "scripts/prepare_ios_python_runtime.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def toolchain_identity(target):
    sdk = "iphoneos" if target == "device" else "iphonesimulator"

    def output(*command):
        value = subprocess.check_output(command, text=True).strip()
        if not value:
            raise ValueError("Empty iOS toolchain identity")
        return value

    return {"runner_arch": platform.machine(), "sdk": sdk,
            "xcode": output("xcodebuild", "-version"),
            "sdk_version": output("xcrun", "--sdk", sdk, "--show-sdk-version"),
            "sdk_build": output("xcrun", "--sdk", sdk, "--show-sdk-build-version")}


def cache_key(inputs, *, target, arch, toolchain):
    if target not in {"device", "simulator"} or arch not in {"arm64", "x86_64"} or target == "device" and arch != "arm64":
        raise ValueError("Invalid iOS runtime slice")
    payload = {"version": CACHE_VERSION, "inputs": inputs, "target": target,
               "arch": arch, "toolchain": toolchain}
    digest = hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return f"ios-python-stage-v{CACHE_VERSION}-{target}-{arch}-{digest}"


def validate_stage(stage, *, target, arch, runtime):
    # This helper may remove only this workflow's exact disposable stage. Refuse
    # symlinked paths rather than following a restored path outside the checkout.
    root = runtime.ROOT.resolve()
    stage = Path(stage).absolute()
    expected = root / STAGE_RELATIVE
    if stage != expected or stage.is_symlink() or stage.resolve() != expected:
        raise ValueError("Unexpected iOS cache stage location")
    if not stage.exists():
        print("No cached iOS Python stage; prepare will build it")
        return False
    try:
        report = runtime.verify_stage(stage)
        if report["runtime"]["target"] != target or report["runtime"]["architecture"] != arch:
            raise ValueError("Cached Python stage is for another target")
    except (OSError, ValueError, KeyError, TypeError):
        if stage.is_dir():
            shutil.rmtree(stage)
        else:
            stage.unlink()
        print("Discarded mismatched iOS Python stage; prepare will rebuild it")
        return False
    print("Cached iOS Python stage passed full input and file verification")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    key = commands.add_parser("key")
    key.add_argument("--github-output", type=Path)
    validate = commands.add_parser("validate")
    validate.add_argument("--stage-dir", type=Path, default=ROOT / STAGE_RELATIVE)
    for command in (key, validate):
        command.add_argument("--target", choices=("device", "simulator"), default="device")
        command.add_argument("--arch", choices=("arm64", "x86_64"), default="arm64")
    args = parser.parse_args()
    runtime = load_runtime()
    if args.command == "key":
        value = cache_key(runtime.source_inputs(), target=args.target, arch=args.arch,
                          toolchain=toolchain_identity(args.target))
        print(value)
        if args.github_output:
            with args.github_output.open("a", encoding="utf-8", newline="\n") as output:
                output.write("key=" + value + "\n")
    else:
        validate_stage(args.stage_dir, target=args.target, arch=args.arch, runtime=runtime)


if __name__ == "__main__":
    main()
