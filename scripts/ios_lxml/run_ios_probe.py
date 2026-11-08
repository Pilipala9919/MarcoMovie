"""Build and run only the disposable ARM64 iOS lxml own-GIL experiment.

Requires macOS/Apple Silicon with full Xcode. Creates its own simulator, never
installs on an existing user simulator/device, and retains reports on failure.
"""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

import build_ios

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
native = build_ios.load_module("lxml_probe_native", ROOT / "scripts/ios_cpython/run_cpython_probe.py")
IDENTIFIER = native.IDENTIFIER
APP_NAME = "CPythonProbe"  # An existing diagnostic-allowlisted disposable app.
BEHAVIORS = frozenset((
    "owner_element_class", "xpath_unicode", "xpath_count", "xpath_owner_callback",
    "xml_serialization", "html_xpath", "html_text", "objectify_values", "iterparse",
    "malformed_xml_error_log", "parse_after_error", "xslt_unicode", "custom_resolver_owner",
))
APP_CHECKS = frozenset((
    "probe_runs_off_ui_thread", "actual_ios_python", "pinned_python_3_14_10",
    "ui_main_thread_remained_responsive", "own_gil_owner_lifecycle",
    "peer_use_after_owner_destroyed", "main_interpreter_remains_attached",
    "lxml_absent_from_main_interpreter",
))


def validate_checks(checks, expected, *, rounds=None):
    if not isinstance(checks, list) or len(checks) != len(expected):
        raise ValueError("Unexpected named check inventory")
    seen = set()
    for check in checks:
        if not isinstance(check, dict) or check.get("name") not in expected:
            raise ValueError("Unknown or malformed named check")
        if check["name"] in seen or check.get("passed") is not True:
            raise ValueError("Duplicated or failed named check")
        if rounds is not None and check.get("count") != rounds:
            raise ValueError("Behavior was not exercised in every expected round")
        seen.add(check["name"])


def validate_app_report(report, arch):
    """Require actual iOS runtime, all behavior results, and every owner teardown."""
    if not isinstance(report, dict) or report.get("passed") is not True:
        raise ValueError("The native app did not pass")
    if report.get("experiment") != "ios-lxml-own-gil" or report.get("platform") != "ios":
        raise ValueError("Report was not produced by the iOS lxml experiment")
    if report.get("native_arch") != arch or not re.match(r"^3\.14\.10\s", str(report.get("runtime", ""))):
        raise ValueError("Actual architecture or Python version differs from the pinned input")
    if type(report.get("heartbeat_during_owners")) is not int or report["heartbeat_during_owners"] < 1:
        raise ValueError("No UI heartbeat was observed during owner execution")
    validate_checks(report.get("checks"), APP_CHECKS)
    harness = report.get("owner_harness")
    if (not isinstance(harness, dict) or harness.get("passed") is not True
            or harness.get("gil") != "OWN_GIL" or harness.get("assertions") != 650
            or harness.get("peer_used_after_alpha_destroyed") is not True):
        raise ValueError("Own-GIL owner lifecycle did not complete")
    owners = harness.get("owners")
    if not isinstance(owners, list) or len(owners) != 3:
        raise ValueError("Exactly three owner records are required")
    expected_rounds = {"alpha": [10], "beta": [10, 20], "reopened": [10]}
    names, identifiers = set(), set()
    pinned_versions = {entry["name"]: [int(part) for part in entry["version"].split(".")]
                       for entry in build_ios.NATIVE_LOCK["libraries"]}
    bundle = PurePosixPath(report.get("bundle_path", ""))
    if not bundle.is_absolute() or bundle.name != APP_NAME + ".app":
        raise ValueError("Missing disposable app bundle path")
    for owner in owners:
        if not isinstance(owner, dict):
            raise ValueError("Malformed owner record")
        name, identity = owner.get("owner"), owner.get("interpreter")
        if name not in expected_rounds or name in names or type(identity) is not int or identity <= 0 or identity in identifiers:
            raise ValueError("Owner names or interpreter identities are not distinct")
        names.add(name); identifiers.add(identity)
        if any(owner.get(key) is not True for key in ("created", "destroyed", "passed")):
            raise ValueError("An owner failed to create, execute, or destroy")
        rounds = expected_rounds[name]
        runs = owner.get("runs")
        if not isinstance(runs, list) or len(runs) != len(rounds) or owner.get("assertions") != sum(rounds) * 13:
            raise ValueError("Owner execution count differs from the fixture")
        for result, count in zip(runs, rounds):
            if (not isinstance(result, dict) or result.get("owner") != name
                    or result.get("rounds") != count or result.get("assertions") != count * 13):
                raise ValueError("Malformed owner exercise report")
            if result.get("platform") != "ios" or not re.match(r"^3\.14\.10\s", str(result.get("runtime", ""))):
                raise ValueError("An owner was not running the pinned iOS CPython")
            validate_checks(result.get("checks"), BEHAVIORS, rounds=count)
            if result.get("lxml_version", [])[:3] != [int(part) for part in build_ios.LOCK["version"].split(".")]:
                raise ValueError("Executed lxml version differs from the pinned source")
            if result.get("libxml_version") != pinned_versions["libxml2"] or result.get("libxslt_version") != pinned_versions["libxslt"]:
                raise ValueError("Executed native XML libraries differ from the private pinned build")
            modules = result.get("modules")
            if not isinstance(modules, dict) or set(modules) != {"lxml.etree", "lxml.objectify"}:
                raise ValueError("Missing native lxml module provenance")
            for module, origin in modules.items():
                expected = bundle / "Frameworks" / (module + ".framework") / module
                if not isinstance(origin, dict) or origin.get("origin") != str(expected):
                    raise ValueError("lxml was not loaded from the app's signed module framework")
                # __file__ may be the .fwork marker: spec.origin is the actual
                # framework binary selected by CPython's AppleFrameworkLoader.
                if origin.get("loader") != "AppleFrameworkLoader":
                    raise ValueError("Native lxml did not use the iOS framework loader")


def compile_probe(app, out, arch, progress):
    sdk = native.run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path", capture=True, progress=progress)
    target = arch + "-apple-ios14.0-simulator"
    flags = ["-target", target, "-isysroot", sdk, "-O1", "-g", "-UNDEBUG"]
    commands = [
        ("compile-owner.log", ["xcrun", "--sdk", "iphonesimulator", "clang", "-std=c11",
            *flags, "-DMM_LXML_EMBEDDED=1", "-I" + str(app / "Frameworks/Python.framework/Headers"),
            "-c", str(HERE / "owner_probe.c"), "-o", str(out / "owner_probe.o")]),
        ("compile-app.log", ["xcrun", "--sdk", "iphonesimulator", "clang++", "-std=c++17", "-fobjc-arc",
            *flags, "-F" + str(app / "Frameworks"), "-framework", "Python", "-framework", "Foundation",
            "-framework", "UIKit", "-Wl,-rpath,@executable_path/Frameworks",
            str(HERE / "LxmlProbe.mm"), str(out / "owner_probe.o"), "-o", str(app / APP_NAME)]),
    ]
    for name, command in commands:
        progress["last_command"] = command
        print("Running:", " ".join(command), flush=True)
        with (out / "logs" / name).open("w", encoding="utf-8") as output:
            completed = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, text=True, timeout=180)
        if completed.returncode:
            print((out / "logs" / name).read_text(encoding="utf-8"), flush=True)
            raise subprocess.CalledProcessError(completed.returncode, command)
    return native.sign_app(app, out, arch, "-", progress)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=("arm64",), default="arm64")
    parser.add_argument("--build-only", action="store_true", help="Build/sign without claiming runtime acceptance")
    parser.add_argument("--cache-dir", type=Path, default=HERE / "downloads")
    parser.add_argument("--output-dir", type=Path, default=HERE / "probe-output")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This focused probe requires macOS with full Xcode")
    if not args.build_only and platform.machine() not in ("arm64", "aarch64"):
        parser.error("ARM64 simulator execution requires an Apple Silicon host")
    out_root = args.output_dir.resolve();out_root.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix="simulator-" + args.arch + "-", dir=out_root))
    app = out / (APP_NAME + ".app");app.mkdir()
    (out / "logs").mkdir()
    inputs = {"probe_inputs": {str(path.relative_to(ROOT).as_posix()): native.digest(path)
        for path in (HERE / "run_ios_probe.py", HERE / "LxmlProbe.mm", HERE / "owner_probe.c", HERE / "owner_fixture.py")}}
    native.write_json(out / "inputs.json", inputs)
    progress = {"passed": False, "phase": "stage_python", "output": str(out),
        "runtime_tested": False, "physical_device_tested": False, "flutter_integration_tested": False,
        "product_enabled": False, "host_arch": platform.machine(), "target_arch": args.arch,
        "github_sha": os.environ.get("GITHUB_SHA", ""), "github_run_id": os.environ.get("GITHUB_RUN_ID", ""),
        "github_repository": os.environ.get("GITHUB_REPOSITORY", ""), "host_platform": platform.platform()}
    start_time = time.time()
    try:
        inputs["python"] = native.stage(app, "simulator", args.arch, args.cache_dir.resolve(),
                                        include_fixture=False, identifier=IDENTIFIER)
        native.write_json(out / "inputs.json", inputs)
        progress["phase"] = "build_lxml"
        inputs["lxml"] = build_ios.stage(app, args.cache_dir.resolve(), target="simulator",
            arch=args.arch, identifier=IDENTIFIER, log_dir=out / "logs")
        native.write_json(out / "inputs.json", inputs)
        # Keep a small manifest next to the reports; CI need not upload the app.
        native.write_json(out / "lxml-runtime-manifest.json", inputs["lxml"])
        shutil.copyfile(HERE / "owner_fixture.py", app / "app/owner_fixture.py")
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": IDENTIFIER, "CFBundleExecutable": APP_NAME,
            "CFBundleName": APP_NAME, "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0", "MinimumOSVersion": "14.0", "UIDeviceFamily": [1, 2],
            "UILaunchScreen": {}, "CFBundleSupportedPlatforms": ["iPhoneSimulator"]}))
        progress["phase"] = "compile_sign"
        inputs["signed_frameworks"] = compile_probe(app, out, args.arch, progress)
        inputs["signed_executable_sha256"] = native.digest(app / APP_NAME)
        native.write_json(out / "inputs.json", inputs)
        if args.build_only:
            progress.update(phase="compiled_signed_only", build_passed=True)
        else:
            progress["phase"] = "simulator_runtime"
            report = native.simulator_run(app, None, progress, identifier=IDENTIFIER, app_name=APP_NAME, fresh=True)
            native.write_json(out / "app-result.json", report)
            progress["runtime_tested"] = True
            validate_app_report(report, args.arch)
            progress.update(phase="simulator_completed", passed=True, checks=len(report["checks"]),
                            core_behaviors=len(BEHAVIORS), assertions=report["owner_harness"]["assertions"], owners_destroyed=3)
    except BaseException as error:
        progress.update(passed=False, failure=type(error).__name__ + ": " + str(error))
        raise
    finally:
        try:
            native.collect_diagnostics(out, progress, start_time, identifier=IDENTIFIER, app_name=APP_NAME)
        except (OSError, subprocess.SubprocessError) as error:
            progress["diagnostics_note"] = type(error).__name__ + ": " + str(error)
        try:
            native.cleanup_owned_simulator(progress)
        finally:
            native.write_json(out / "result.json", progress)
            print(json.dumps(progress, ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    main()
