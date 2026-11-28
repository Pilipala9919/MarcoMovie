#!/usr/bin/env python3
# Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
"""Run real iOS/iPadOS Simulator build, hosted XCTest suite (iPhone + iPad Portrait + iPad Landscape),
cold-start smoke launches, crash audit, and HD screenshot verification."""

from __future__ import annotations

import argparse
import glob
import json
import os
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess
import sys
import time

IOS_DIR = Path(__file__).resolve().parent
REPO_ROOT = IOS_DIR.parent
BUNDLE_ID = "com.pilipala.marcoMovie"
DIAG_DIR = Path.home() / "Library" / "Logs" / "DiagnosticReports"

CAPTURED_SCREENS = (
    "01_home.png",
    "02_sidebar_or_discover.png",
    "03_search.png",
    "04_detail.png",
    "05_live.png",
    "06_settings.png",
    "07_player.png",
)


def _run(
    cmd: list[str],
    *,
    env: dict[str, str] | None = None,
    check: bool = True,
    capture: bool = True,
) -> subprocess.CompletedProcess[str]:
    print(f"+ {' '.join(cmd)}", flush=True)
    return subprocess.run(
        cmd,
        cwd=REPO_ROOT,
        env=env,
        text=True,
        capture_output=capture,
        check=check,
    )


def _run_streaming(
    cmd: list[str],
    *,
    env: dict[str, str],
    log_path: Path,
) -> tuple[int, str]:
    print(f"+ {' '.join(cmd)}", flush=True)
    log_lines: list[str] = []
    with subprocess.Popen(
        cmd,
        cwd=REPO_ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    ) as proc:
        assert proc.stdout is not None
        for line in proc.stdout:
            sys.stdout.write(line)
            log_lines.append(line)
        rc = proc.wait()
    full_log = "".join(log_lines)
    log_path.write_text(full_log, encoding="utf-8")
    return rc, full_log


def _list_available_ios_runtimes(env: dict[str, str]) -> list[dict]:
    proc = _run(["xcrun", "simctl", "list", "runtimes", "--json"], env=env, check=False)
    if proc.returncode != 0:
        return []
    try:
        payload = json.loads(proc.stdout)
    except Exception:
        return []

    runtimes: list[dict] = []
    for rt in payload.get("runtimes", []):
        ident = str(rt.get("identifier", ""))
        name = str(rt.get("name", ""))
        platform_name = str(rt.get("platform", ""))
        avail = bool(rt.get("isAvailable", False))
        is_ios = (
            platform_name == "iOS"
            or "SimRuntime.iOS-" in ident
            or (name.startswith("iOS ") and "tvOS" not in name and "watchOS" not in name)
        )
        if avail and is_ios:
            runtimes.append(rt)

    runtimes.sort(
        key=lambda r: tuple(int(p) for p in re.findall(r"\d+", str(r.get("version", "0")))),
        reverse=True,
    )
    return runtimes


def _select_developer_dir_and_ios_runtime() -> tuple[str, dict, str]:
    base_env = os.environ.copy()
    current_proc = _run(["xcode-select", "-p"], env=base_env, check=True)
    current_dev = current_proc.stdout.strip()

    candidates: list[str] = [current_dev]
    for app_path in sorted(glob.glob("/Applications/Xcode*.app"), reverse=True):
        dev = str(Path(app_path) / "Contents" / "Developer")
        if dev not in candidates and Path(dev).is_dir():
            candidates.append(dev)

    for dev in candidates:
        env = base_env.copy()
        env["DEVELOPER_DIR"] = dev
        ver = _run(["xcodebuild", "-version"], env=env, check=False).stdout.strip().replace("\n", " | ")
        runtimes = _list_available_ios_runtimes(env)
        print(f"Probed {dev} ({ver}) -> {len(runtimes)} available iOS runtime(s)", flush=True)
        if runtimes:
            return dev, runtimes[0], ver

    # Fallback: download official iOS Simulator runtime for active Xcode
    env = base_env.copy()
    env["DEVELOPER_DIR"] = current_dev
    ver = _run(["xcodebuild", "-version"], env=env, check=False).stdout.strip().replace("\n", " | ")
    print("No pre-installed iOS Simulator runtime found; downloading official iOS runtime...", flush=True)
    dl = _run(["xcodebuild", "-downloadPlatform", "iOS"], env=env, check=False, capture=False)
    if dl.returncode != 0:
        raise RuntimeError(f"xcodebuild -downloadPlatform iOS failed with exit code {dl.returncode}")

    runtimes = _list_available_ios_runtimes(env)
    if not runtimes:
        raise RuntimeError("iOS Simulator runtime still unavailable after xcodebuild -downloadPlatform iOS")
    return current_dev, runtimes[0], ver


def _score_iphone_name(name: str) -> tuple[int, str]:
    if name == "iPhone 16 Pro":
        return (0, name)
    if name == "iPhone 16":
        return (1, name)
    if "iPhone 16 Pro" in name:
        return (2, name)
    if "iPhone 16" in name:
        return (3, name)
    if name == "iPhone 15 Pro":
        return (4, name)
    if name == "iPhone 15":
        return (5, name)
    if "iPhone 15" in name:
        return (6, name)
    if "iPhone" in name and "SE" not in name:
        return (7, name)
    if "iPhone" in name:
        return (8, name)
    return (99, name)


def _score_ipad_name(name: str) -> tuple[int, str]:
    if "iPad Air" in name and "11" in name:
        return (0, name)
    if "iPad Air" in name:
        return (1, name)
    if "iPad Pro" in name and "11" in name:
        return (2, name)
    if "iPad Pro" in name:
        return (3, name)
    if "iPad (10th generation)" in name or "iPad (A16)" in name:
        return (4, name)
    if "iPad" in name and "mini" not in name.lower():
        return (5, name)
    if "iPad" in name:
        return (6, name)
    return (99, name)


def _select_or_create_simulator(
    env: dict[str, str],
    runtime: dict,
    *,
    family: str,
) -> tuple[str, str]:
    """Select or create the best available simulator device for `family` ('iPhone' or 'iPad')."""
    rt_id = str(runtime["identifier"])
    scorer = _score_iphone_name if family == "iPhone" else _score_ipad_name

    proc = _run(["xcrun", "simctl", "list", "devices", "available", "--json"], env=env, check=True)
    devices_map = json.loads(proc.stdout).get("devices", {})
    rt_devices = devices_map.get(rt_id, [])

    usable = [
        d
        for d in rt_devices
        if d.get("isAvailable", True) and family in str(d.get("name", ""))
    ]
    if usable:
        usable.sort(key=lambda d: scorer(str(d.get("name", ""))))
        chosen = usable[0]
        return str(chosen["udid"]), str(chosen["name"])

    dt_proc = _run(["xcrun", "simctl", "list", "devicetypes", "--json"], env=env, check=True)
    devicetypes = json.loads(dt_proc.stdout).get("devicetypes", [])
    matching_types = [
        dt
        for dt in devicetypes
        if family in str(dt.get("name", "")) or family in str(dt.get("identifier", ""))
    ]
    if not matching_types:
        raise RuntimeError(f"No {family} simulator device types found")
    matching_types.sort(key=lambda dt: scorer(str(dt.get("name", ""))))
    chosen_dt = matching_types[0]
    sim_label = f"MarcoMovie-{family}"
    create_proc = _run(
        ["xcrun", "simctl", "create", sim_label, str(chosen_dt["identifier"]), rt_id],
        env=env,
        check=True,
    )
    udid = create_proc.stdout.strip()
    return udid, f"{sim_label} ({chosen_dt['name']})"


def _snapshot_crash_reports() -> set[str]:
    if not DIAG_DIR.is_dir():
        return set()
    return {
        p.name
        for p in DIAG_DIR.iterdir()
        if p.is_file() and "MarcoMovieIOS" in p.name
    }


def _png_info(path: Path) -> dict[str, object]:
    data = path.read_bytes()
    w = h = 0
    valid_sig = len(data) >= 24 and data[:8] == b"\x89PNG\r\n\x1a\n"
    if valid_sig:
        w, h = struct.unpack(">II", data[16:24])
    return {
        "file": path.name,
        "bytes": len(data),
        "width": w,
        "height": h,
        "valid_png": valid_sig and w > 0 and h > 0,
    }


def _parse_xcodebuild_test_summary(log_text: str) -> dict[str, object]:
    passed_cases = re.findall(r"Test Case '-\[([^\]]+)\]' passed \(([\d.]+) seconds\)", log_text)
    failed_cases = re.findall(r"Test Case '-\[([^\]]+)\]' failed \(([\d.]+) seconds\)", log_text)
    sim_cases = [c for c, _ in passed_cases if "IOSSimulatorVerificationTests" in c]
    core_cases = [c for c, _ in passed_cases if "IOSSimulatorVerificationTests" not in c]
    return {
        "total_passed": len(passed_cases),
        "total_failed": len(failed_cases),
        "core_tests_passed": len(core_cases),
        "simulator_ui_tests_passed": len(sim_cases),
        "failed_cases": [c for c, _ in failed_cases],
        "simulator_ui_case_names": sim_cases,
    }


def _extract_container_screenshots(
    env: dict[str, str],
    udid: str,
    prefix: str,
    shots_dir: Path,
) -> list[str]:
    copied: list[str] = []
    container_proc = _run(
        ["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data"],
        env=env,
        check=False,
    )
    if container_proc.returncode != 0:
        return copied
    app_shots = Path(container_proc.stdout.strip()) / "Library" / "Caches" / "sim-screenshots"
    if not app_shots.is_dir():
        return copied
    for png in sorted(app_shots.glob(f"{prefix}_*.png")):
        dst = shots_dir / png.name
        shutil.copy2(png, dst)
        copied.append(dst.name)
    return copied


def _run_cold_start_smoke(
    env: dict[str, str],
    udid: str,
    app_path: Path,
    shot_path: Path,
) -> dict[str, object]:
    if not app_path.is_dir():
        return {"executed": False, "error": f"App bundle missing: {app_path}"}

    _run(["xcrun", "simctl", "terminate", udid, BUNDLE_ID], env=env, check=False)
    _run(["xcrun", "simctl", "uninstall", udid, BUNDLE_ID], env=env, check=False)
    _run(["xcrun", "simctl", "install", udid, str(app_path)], env=env, check=True)
    launch_proc = _run(["xcrun", "simctl", "launch", udid, BUNDLE_ID], env=env, check=True)
    pid_match = re.search(r":\s*(\d+)", launch_proc.stdout)
    pid = int(pid_match.group(1)) if pid_match else 0

    time.sleep(5.0)
    alive = False
    if pid > 0:
        ps_proc = _run(["ps", "-p", str(pid), "-o", "pid=,comm="], env=env, check=False)
        alive = ps_proc.returncode == 0 and bool(ps_proc.stdout.strip())

    shot_proc = _run(["xcrun", "simctl", "io", udid, "screenshot", str(shot_path)], env=env, check=False)
    _run(["xcrun", "simctl", "terminate", udid, BUNDLE_ID], env=env, check=False)
    return {
        "executed": True,
        "pid": pid,
        "stayed_alive_5s": alive,
        "screenshot": shot_path.name,
        "simctl_screenshot_ok": shot_proc.returncode == 0 and shot_path.is_file() and shot_path.stat().st_size > 8_000,
    }


def _run_test_pass(
    *,
    base_env: dict[str, str],
    udid: str,
    derived_dir: Path,
    xcresult_path: Path,
    log_path: Path,
    prefix: str,
    orientation: str,
    only_testing: str | None = None,
) -> tuple[int, dict[str, object]]:
    if xcresult_path.exists():
        shutil.rmtree(xcresult_path)

    pass_env = base_env.copy()
    pass_env["TEST_RUNNER_MARCO_SIM_CAPTURE_PREFIX"] = prefix
    pass_env["TEST_RUNNER_MARCO_SIM_ORIENTATION"] = orientation

    cmd = [
        "xcodebuild",
        "test-without-building",
        "-project",
        str(IOS_DIR / "RunnerProject" / "MarcoMovieIOS.xcodeproj"),
        "-scheme",
        "MarcoMovieIOS",
        "-sdk",
        "iphonesimulator",
        "-configuration",
        "Debug",
        "-destination",
        f"id={udid}",
        "-derivedDataPath",
        str(derived_dir),
        "-resultBundlePath",
        str(xcresult_path),
    ]
    if only_testing:
        cmd.append(f"-only-testing:{only_testing}")

    rc, log_text = _run_streaming(cmd, env=pass_env, log_path=log_path)
    return rc, _parse_xcodebuild_test_summary(log_text)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify MarcoMovieIOS on iPhone & iPad Simulators (Portrait + Landscape) with HD screenshots."
    )
    parser.add_argument("--output-dir", default=str(IOS_DIR / "sim-evidence"))
    args = parser.parse_args()

    out_dir = Path(args.output_dir).resolve()
    shots_dir = out_dir / "screenshots"
    derived_dir = out_dir / "DerivedDataSim"

    out_dir.mkdir(parents=True, exist_ok=True)
    if shots_dir.exists():
        shutil.rmtree(shots_dir)
    shots_dir.mkdir(parents=True, exist_ok=True)

    dev_dir, runtime, xcode_ver = _select_developer_dir_and_ios_runtime()
    env = os.environ.copy()
    env["DEVELOPER_DIR"] = dev_dir

    iphone_udid, iphone_name = _select_or_create_simulator(env, runtime, family="iPhone")
    ipad_udid, ipad_name = _select_or_create_simulator(env, runtime, family="iPad")
    print(f"Selected iPhone Simulator: {iphone_name} ({iphone_udid}) on {runtime['name']}", flush=True)
    print(f"Selected iPad Simulator:   {ipad_name} ({ipad_udid}) on {runtime['name']}", flush=True)

    crash_before = _snapshot_crash_reports()

    # Step 1: Build once for testing (iphonesimulator, Debug, active arch)
    build_cmd = [
        "xcodebuild",
        "build-for-testing",
        "-project",
        str(IOS_DIR / "RunnerProject" / "MarcoMovieIOS.xcodeproj"),
        "-scheme",
        "MarcoMovieIOS",
        "-sdk",
        "iphonesimulator",
        "-configuration",
        "Debug",
        "-destination",
        f"id={iphone_udid}",
        "-derivedDataPath",
        str(derived_dir),
        "CODE_SIGNING_ALLOWED=YES",
        "CODE_SIGN_IDENTITY=-",
        "CODE_SIGNING_REQUIRED=NO",
        "ONLY_ACTIVE_ARCH=YES",
    ]
    build_rc, _ = _run_streaming(
        build_cmd,
        env=env,
        log_path=out_dir / "xcodebuild-build-for-testing.log",
    )
    if build_rc != 0:
        print(f"ERROR: xcodebuild build-for-testing failed with code {build_rc}", file=sys.stderr)
        return build_rc

    app_path = derived_dir / "Build" / "Products" / "Debug-iphonesimulator" / "MarcoMovieIOS.app"

    # Step 2: Pass 1 — iPhone Portrait (ALL MarcoMovieIOSTests + cold-start smoke)
    _run(["xcrun", "simctl", "boot", iphone_udid], env=env, check=False)
    _run(["xcrun", "simctl", "bootstatus", iphone_udid, "-b"], env=env, check=True, capture=False)

    iphone_rc, iphone_summary = _run_test_pass(
        base_env=env,
        udid=iphone_udid,
        derived_dir=derived_dir,
        xcresult_path=out_dir / "MarcoMovieIOS-iPhone-Portrait.xcresult",
        log_path=out_dir / "xcodebuild-iphone-portrait.log",
        prefix="iphone_portrait",
        orientation="portrait",
        only_testing=None,
    )
    iphone_extracted = _extract_container_screenshots(env, iphone_udid, "iphone_portrait", shots_dir)
    iphone_cold = _run_cold_start_smoke(
        env,
        iphone_udid,
        app_path,
        shots_dir / "iphone_portrait_00_cold_start.png",
    )
    _run(["xcrun", "simctl", "shutdown", iphone_udid], env=env, check=False)

    # Step 3: Pass 2 — iPad Portrait (IOSSimulatorVerificationTests + cold-start smoke)
    _run(["xcrun", "simctl", "boot", ipad_udid], env=env, check=False)
    _run(["xcrun", "simctl", "bootstatus", ipad_udid, "-b"], env=env, check=True, capture=False)

    ipad_port_rc, ipad_port_summary = _run_test_pass(
        base_env=env,
        udid=ipad_udid,
        derived_dir=derived_dir,
        xcresult_path=out_dir / "MarcoMovieIOS-iPad-Portrait.xcresult",
        log_path=out_dir / "xcodebuild-ipad-portrait.log",
        prefix="ipad_portrait",
        orientation="portrait",
        only_testing="MarcoMovieIOSTests/IOSSimulatorVerificationTests",
    )
    ipad_port_extracted = _extract_container_screenshots(env, ipad_udid, "ipad_portrait", shots_dir)
    ipad_cold = _run_cold_start_smoke(
        env,
        ipad_udid,
        app_path,
        shots_dir / "ipad_portrait_00_cold_start.png",
    )

    # Step 4: Pass 3 — iPad Landscape (IOSSimulatorVerificationTests)
    ipad_land_rc, ipad_land_summary = _run_test_pass(
        base_env=env,
        udid=ipad_udid,
        derived_dir=derived_dir,
        xcresult_path=out_dir / "MarcoMovieIOS-iPad-Landscape.xcresult",
        log_path=out_dir / "xcodebuild-ipad-landscape.log",
        prefix="ipad_landscape",
        orientation="landscape",
        only_testing="MarcoMovieIOSTests/IOSSimulatorVerificationTests",
    )
    ipad_land_extracted = _extract_container_screenshots(env, ipad_udid, "ipad_landscape", shots_dir)
    _run(["xcrun", "simctl", "shutdown", ipad_udid], env=env, check=False)

    crash_after = _snapshot_crash_reports()
    new_crashes = sorted(crash_after - crash_before)

    expected_pngs = (
        ["iphone_portrait_00_cold_start.png"]
        + [f"iphone_portrait_{s}" for s in CAPTURED_SCREENS]
        + ["ipad_portrait_00_cold_start.png"]
        + [f"ipad_portrait_{s}" for s in CAPTURED_SCREENS]
        + [f"ipad_landscape_{s}" for s in CAPTURED_SCREENS]
    )

    screenshots_meta = [_png_info(p) for p in sorted(shots_dir.glob("*.png"))]
    meta_by_name = {str(item["file"]): item for item in screenshots_meta}
    missing_or_invalid: list[str] = []
    for fname in expected_pngs:
        info = meta_by_name.get(fname)
        if not info or not info["valid_png"] or int(info["bytes"]) <= 8_000:
            missing_or_invalid.append(f"{fname} (missing or <=8KB)")
            continue
        if int(info["width"]) <= 200 or int(info["height"]) <= 200:
            missing_or_invalid.append(f"{fname} (tiny dimensions {info['width']}x{info['height']})")
            continue
        if fname.startswith("ipad_landscape_") and int(info["width"]) <= int(info["height"]):
            missing_or_invalid.append(
                f"{fname} (expected landscape width > height, got {info['width']}x{info['height']})"
            )

    report = {
        "host_arch": platform.machine(),
        "macos_version": platform.mac_ver()[0],
        "developer_dir": dev_dir,
        "xcode_version": xcode_ver,
        "simulator_runtime": runtime.get("name"),
        "simulator_runtime_id": runtime.get("identifier"),
        "devices": {
            "iphone": {"name": iphone_name, "udid": iphone_udid},
            "ipad": {"name": ipad_name, "udid": ipad_udid},
        },
        "build_for_testing_returncode": build_rc,
        "passes": {
            "iphone_portrait": {
                "returncode": iphone_rc,
                "test_summary": iphone_summary,
                "extracted_screenshots": iphone_extracted,
                "cold_start_smoke": iphone_cold,
            },
            "ipad_portrait": {
                "returncode": ipad_port_rc,
                "test_summary": ipad_port_summary,
                "extracted_screenshots": ipad_port_extracted,
                "cold_start_smoke": ipad_cold,
            },
            "ipad_landscape": {
                "returncode": ipad_land_rc,
                "test_summary": ipad_land_summary,
                "extracted_screenshots": ipad_land_extracted,
            },
        },
        "new_crash_reports": new_crashes,
        "expected_screenshot_count": len(expected_pngs),
        "actual_screenshot_count": len(screenshots_meta),
        "missing_or_invalid_screenshots": missing_or_invalid,
        "screenshots": screenshots_meta,
    }
    report_path = out_dir / "simulator-report.json"
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    print("\n=== iOS / iPadOS Simulator Verification Report ===", flush=True)
    print(json.dumps(report, indent=2, ensure_ascii=False), flush=True)

    failures: list[str] = []
    if iphone_rc != 0 or iphone_summary["total_failed"] != 0 or int(iphone_summary["simulator_ui_tests_passed"]) < 2:
        failures.append(f"iPhone Portrait pass failed (rc={iphone_rc}, summary={iphone_summary})")
    if ipad_port_rc != 0 or ipad_port_summary["total_failed"] != 0 or int(ipad_port_summary["simulator_ui_tests_passed"]) < 2:
        failures.append(f"iPad Portrait pass failed (rc={ipad_port_rc}, summary={ipad_port_summary})")
    if ipad_land_rc != 0 or ipad_land_summary["total_failed"] != 0 or int(ipad_land_summary["simulator_ui_tests_passed"]) < 2:
        failures.append(f"iPad Landscape pass failed (rc={ipad_land_rc}, summary={ipad_land_summary})")
    if not iphone_cold.get("stayed_alive_5s") or not iphone_cold.get("simctl_screenshot_ok"):
        failures.append(f"iPhone cold-start smoke failed: {iphone_cold}")
    if not ipad_cold.get("stayed_alive_5s") or not ipad_cold.get("simctl_screenshot_ok"):
        failures.append(f"iPad cold-start smoke failed: {ipad_cold}")
    if new_crashes:
        failures.append(f"New MarcoMovieIOS crash reports detected: {new_crashes}")
    if missing_or_invalid:
        failures.append(f"Missing or invalid screenshots: {missing_or_invalid}")

    if failures:
        for msg in failures:
            print(f"ERROR: {msg}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
