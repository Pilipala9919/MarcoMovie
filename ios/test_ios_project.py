#!/usr/bin/env python3
# Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
"""Offline regression suite for native iOS/iPadOS preparation, Swift guards, Mach-O verification, and IPA packaging."""

from __future__ import annotations

import ast
import json
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

IOS_DIR = Path(__file__).resolve().parent
REPO_ROOT = IOS_DIR.parent
if str(IOS_DIR) not in sys.path:
    sys.path.insert(0, str(IOS_DIR))

import patch_ios_ipa  # noqa: E402
import prepare_ios  # noqa: E402


def _strip_swift_strings_and_comments(source: str) -> str:
    """Strip Swift line/nested block comments and string literals for accurate delimiter balance checks."""
    n = len(source)
    i = 0
    out: list[str] = []
    while i < n:
        ch = source[i]
        # Line comment //
        if ch == "/" and i + 1 < n and source[i + 1] == "/":
            i += 2
            while i < n and source[i] != "\n":
                i += 1
            continue
        # Nested block comment /* ... */
        if ch == "/" and i + 1 < n and source[i + 1] == "*":
            depth = 1
            i += 2
            while i + 1 < n and depth > 0:
                if source[i] == "/" and source[i + 1] == "*":
                    depth += 1
                    i += 2
                elif source[i] == "*" and source[i + 1] == "/":
                    depth -= 1
                    i += 2
                else:
                    i += 1
            out.append(" ")
            continue
        # Extended raw string #"..."# or #"""..."""#
        if ch == "#":
            j = i
            while j < n and source[j] == "#":
                j += 1
            hashes = j - i
            if j < n and source[j] == '"':
                if source[j : j + 3] == '"""':
                    end_pat = '"""' + ("#" * hashes)
                    end_idx = source.find(end_pat, j + 3)
                    i = (end_idx + len(end_pat)) if end_idx >= 0 else n
                    out.append(" ")
                    continue
                end_pat = '"' + ("#" * hashes)
                end_idx = source.find(end_pat, j + 1)
                i = (end_idx + len(end_pat)) if end_idx >= 0 else n
                out.append(" ")
                continue
        # Multiline string """..."""
        if source[i : i + 3] == '"""':
            i += 3
            while i < n:
                if source[i] == "\\":
                    i += 2
                    continue
                if source[i : i + 3] == '"""':
                    i += 3
                    break
                i += 1
            out.append(" ")
            continue
        # Standard string "..."
        if ch == '"':
            i += 1
            while i < n:
                if source[i] == "\\":
                    i += 2
                    continue
                if source[i] == '"':
                    i += 1
                    break
                i += 1
            out.append(" ")
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def _extract_public_guard_constants() -> dict[str, object]:
    """Parse constant dicts/sets from scripts/check_public_content.py without running top-level checks."""
    guard_path = REPO_ROOT / "scripts" / "check_public_content.py"
    tree = ast.parse(guard_path.read_text(encoding="utf-8"), filename=str(guard_path))
    wanted = {"EXCLUDED", "ALLOWED_HOSTS", "CLOUD_SHARE_HOSTS", "TEST_AUTHORITIES"}
    result: dict[str, object] = {}
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id in wanted:
                    result[target.id] = ast.literal_eval(node.value)
    return result


def _make_mock_xcframework(root: Path, fw_name: str, *, include_simulator: bool = False) -> Path:
    """Create a minimal valid .xcframework structure for offline prepare_ios.py tests."""
    xcfw = root / f"{fw_name}.xcframework"
    dev_fw = xcfw / "ios-arm64" / f"{fw_name}.framework"
    dev_fw.mkdir(parents=True, exist_ok=True)
    (dev_fw / fw_name).write_bytes(b"mock-ios-arm64-framework")
    (dev_fw / "Headers").mkdir(exist_ok=True)
    (dev_fw / "Headers" / f"{fw_name}.h").write_text("// header\n", encoding="utf-8")
    (dev_fw / "Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleIdentifier": f"com.example.{fw_name.lower()}",
                "MinimumOSVersion": "14.0",
            },
            fmt=plistlib.FMT_XML,
        )
    )

    libs: list[dict[str, object]] = [
        {
            "BinaryPath": f"{fw_name}.framework/{fw_name}",
            "LibraryIdentifier": "ios-arm64",
            "LibraryPath": f"{fw_name}.framework",
            "SupportedArchitectures": ["arm64"],
            "SupportedPlatform": "ios",
        }
    ]
    if include_simulator:
        sim_fw = xcfw / "ios-arm64_x86_64-simulator" / f"{fw_name}.framework"
        sim_fw.mkdir(parents=True, exist_ok=True)
        (sim_fw / fw_name).write_bytes(b"mock-ios-sim-framework")
        libs.append(
            {
                "BinaryPath": f"{fw_name}.framework/{fw_name}",
                "LibraryIdentifier": "ios-arm64_x86_64-simulator",
                "LibraryPath": f"{fw_name}.framework",
                "SupportedArchitectures": ["arm64", "x86_64"],
                "SupportedPlatform": "ios",
                "SupportedPlatformVariant": "simulator",
            }
        )

    (xcfw / "Info.plist").write_bytes(
        plistlib.dumps(
            {
                "AvailableLibraries": libs,
                "CFBundlePackageType": "XFWK",
                "XCFrameworkFormatVersion": "1.0",
            },
            fmt=plistlib.FMT_XML,
        )
    )
    return xcfw


def _make_synthetic_macho(
    *,
    cputype: int = patch_ios_ipa.CPU_TYPE_ARM64,
    filetype: int = 2,
    platform: int = patch_ios_ipa.PLATFORM_IOS,
    minos_packed: int = 0x000F0000,
    sdk_packed: int = 0x00120000,
    use_version_min_cmd: bool = False,
) -> bytes:
    """Build a minimal valid 64-bit LE Mach-O binary for strict patch_ios_ipa tests."""
    if use_version_min_cmd:
        lc = struct.pack(
            "<IIII",
            patch_ios_ipa.LC_VERSION_MIN_IPHONEOS,
            16,
            minos_packed,
            sdk_packed,
        )
    else:
        lc = struct.pack(
            "<IIIIII",
            patch_ios_ipa.LC_BUILD_VERSION,
            24,
            platform,
            minos_packed,
            sdk_packed,
            0,
        )
    header = struct.pack(
        "<IIIIIIII",
        0xFEEDFACF,  # MH_MAGIC_64
        cputype,
        0,
        filetype,
        1,  # ncmds
        len(lc),
        0,
        0,
    )
    return header + lc + (b"\x00" * 64)


def _make_mock_ios_app(
    app_dir: Path,
    *,
    version: str = "0.8.0",
    build: str = "107",
    min_ios: str = "15.0",
    macho_bytes: bytes | None = None,
    include_dsym: bool = True,
) -> Path:
    app_dir.mkdir(parents=True, exist_ok=True)
    if include_dsym:
        dsym = app_dir / "MarcoMovieIOS.app.dSYM"
        dsym.mkdir(exist_ok=True)
        (dsym / "dummy.dwarf").write_text("strip me", encoding="utf-8")

    info = {
        "CFBundleExecutable": "MarcoMovieIOS",
        "CFBundleIdentifier": "com.pilipala.marcoMovie",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
        "MinimumOSVersion": min_ios,
        "UIDeviceFamily": [1, 2],
        "CADisableMinimumFrameDurationOnPhone": True,
        "UIRequiresFullScreen": False,
    }
    (app_dir / "Info.plist").write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML))

    _, packed = patch_ios_ipa.parse_min_ios(min_ios)
    bin_data = macho_bytes if macho_bytes is not None else _make_synthetic_macho(minos_packed=packed)
    (app_dir / "MarcoMovieIOS").write_bytes(bin_data)
    return app_dir


class IOSWorkspaceAndPackagingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.light_summary = prepare_ios.prepare_all(
            min_ios="15.0",
            light_simulator=True,
            sdk="iphonesimulator",
        )

    def test_light_simulator_prepare_and_synced_assets(self) -> None:
        self.assertEqual(self.light_summary["mode"], "light-simulator")
        self.assertEqual(self.light_summary["enabled_macros"], [])

        # 1. CQuickJS files synced and sandbox-incompatible quickjs-libc.c excluded
        cquickjs_dir = IOS_DIR / "Sources" / "CQuickJS"
        for c_name in ("cquickjs_anchor.c", "quickjs.c", "libregexp.c", "libunicode.c", "dtoa.c"):
            self.assertTrue((cquickjs_dir / c_name).is_file(), f"Missing CQuickJS/{c_name}")
        self.assertFalse((cquickjs_dir / "quickjs-libc.c").exists(), "quickjs-libc.c must NOT be synced")
        include_dir = cquickjs_dir / "include"
        for h_name in ("CQuickJS.h", "module.modulemap", "quickjs.h", "quickjs-libc.h"):
            self.assertTrue((include_dir / h_name).is_file(), f"Missing CQuickJS/include/{h_name}")

        # 2. js-host/ synced completely
        js_host_dir = IOS_DIR / "Sources" / "MarcoIOSCore" / "Resources" / "js-host"
        expected_js_host = set(prepare_ios.REQUIRED_SHARED_JS_HOST_FILES) | set(
            prepare_ios.REQUIRED_CATPAW_JS_HOST_FILES
        )
        for name in sorted(expected_js_host):
            self.assertTrue((js_host_dir / name).is_file(), f"Missing js-host/{name}")
        actual_js_host = {p.name for p in js_host_dir.iterdir() if p.is_file()}
        self.assertEqual(actual_js_host, expected_js_host)

        # 3. catpaw/ synced completely with SHA-256 verified manifest + host.cjs / fetch.cjs
        catpaw_dir = IOS_DIR / "Sources" / "MarcoIOSCore" / "Resources" / "catpaw"
        self.assertTrue((catpaw_dir / "drpy-assets.json").is_file())
        _, manifest_files = prepare_ios._load_catpaw_manifest()
        for entry in manifest_files:
            self.assertTrue((catpaw_dir / entry["name"]).is_file(), f"Missing catpaw/{entry['name']}")
        for required_node in ("host.cjs", "fetch.cjs"):
            self.assertTrue((catpaw_dir / required_node).is_file(), f"Missing catpaw/{required_node}")

        # 4. shaders/anime4k/ synced with manifest + GLSL shaders
        shaders_dir = IOS_DIR / "Sources" / "MarcoIOSCore" / "Resources" / "shaders" / "anime4k"
        self.assertTrue((shaders_dir / "manifest.json").is_file(), "Missing shaders/anime4k/manifest.json")
        glsl_files = sorted(shaders_dir.glob("*.glsl"))
        self.assertGreaterEqual(len(glsl_files), 1, "Expected synced Anime4K .glsl shader files")

        # 5. AppIcon, BrandLogoMark & LaunchImage dimensions + real RGBA alpha
        assets_dir = IOS_DIR / "RunnerProject" / "Assets.xcassets"
        appicon_dir = assets_dir / "AppIcon.appiconset"
        for idiom, size_label, scale, pixels in prepare_ios.APP_ICON_SLOTS:
            icon_file = appicon_dir / f"Icon-{idiom}-{size_label}@{scale}.png"
            self.assertTrue(icon_file.is_file(), f"Missing AppIcon slot {icon_file.name}")
            self.assertEqual(prepare_ios.png_dimensions(icon_file), (pixels, pixels))

        for imageset, specs in (
            ("BrandLogoMark.imageset", (("brand_logo_mark_1x.png", 48), ("brand_logo_mark_2x.png", 96), ("brand_logo_mark_3x.png", 144))),
            ("LaunchImage.imageset", (("launch_image_1x.png", 76), ("launch_image_2x.png", 152), ("launch_image_3x.png", 228))),
        ):
            for fname, dim in specs:
                png_path = assets_dir / imageset / fname
                self.assertTrue(png_path.is_file(), f"Missing {imageset}/{fname}")
                self.assertEqual(prepare_ios.png_dimensions(png_path), (dim, dim))
                _, _, rows = prepare_ios.decode_png_rgba(png_path)
                has_transparent = any(row[idx] == 0 for row in rows for idx in range(3, len(row), 4))
                has_opaque = any(row[idx] > 0 for row in rows for idx in range(3, len(row), 4))
                self.assertTrue(
                    has_transparent and has_opaque,
                    f"{imageset}/{fname} must preserve real RGBA transparency",
                )

        # 6. Info.plist required keys
        info = plistlib.loads((IOS_DIR / "RunnerProject" / "Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "com.pilipala.marcoMovie")
        self.assertEqual(info["UIDeviceFamily"], [1, 2])
        self.assertIs(info["CADisableMinimumFrameDurationOnPhone"], True)
        self.assertIs(info["UIApplicationSupportsIndirectInputEvents"], True)
        self.assertIs(info["UIRequiresFullScreen"], False)
        scene_cfgs = info["UIApplicationSceneManifest"]["UISceneConfigurations"]["UIWindowSceneSessionRoleApplication"]
        self.assertTrue(
            any("SceneDelegate" in str(cfg.get("UISceneDelegateClassName", "")) for cfg in scene_cfgs),
            "Info.plist UIApplicationSceneManifest must declare SceneDelegate",
        )

        # 7. Valid XML project.pbxproj with all 6 targets, all sources, zero MARCO_HAS_*, Debug-only -force_load
        pbx_path = IOS_DIR / "RunnerProject" / "MarcoMovieIOS.xcodeproj" / "project.pbxproj"
        pbx = plistlib.loads(pbx_path.read_bytes())
        self.assertEqual(pbx["objectVersion"], "56")
        objects = pbx["objects"]

        native_targets = {
            obj["name"]: obj
            for obj in objects.values()
            if isinstance(obj, dict) and obj.get("isa") == "PBXNativeTarget"
        }
        expected_targets = {
            "CQuickJS",
            "CLibmpv",
            "MarcoNativeBridges",
            "MarcoIOSCore",
            "MarcoMovieIOS",
            "MarcoMovieIOSTests",
        }
        self.assertEqual(set(native_targets.keys()), expected_targets)

        referenced_paths = {
            obj.get("path")
            for obj in objects.values()
            if isinstance(obj, dict) and obj.get("isa") == "PBXFileReference"
        }
        all_expected_sources = (
            list((IOS_DIR / "Sources" / "CQuickJS").rglob("*.c"))
            + list((IOS_DIR / "Sources" / "CLibmpv").rglob("*.c"))
            + list((IOS_DIR / "Sources" / "MarcoNativeBridges").rglob("*.mm"))
            + list((IOS_DIR / "Sources" / "MarcoIOSCore").rglob("*.swift"))
            + list((IOS_DIR / "Sources" / "MarcoMovieIOS").rglob("*.swift"))
            + list((IOS_DIR / "Tests" / "MarcoIOSCoreTests").rglob("*.swift"))
            + list((IOS_DIR / "Tests" / "MarcoMovieIOSSimulatorTests").rglob("*.swift"))
        )
        self.assertGreaterEqual(len(all_expected_sources), 50)
        for src in all_expected_sources:
            rel_path = f"../{src.relative_to(IOS_DIR).as_posix()}"
            self.assertIn(rel_path, referenced_paths, f"{rel_path} missing from project.pbxproj")

        # Zero MARCO_HAS_* macros in light-simulator mode across EVERY build configuration
        for obj in objects.values():
            if isinstance(obj, dict) and obj.get("isa") == "XCBuildConfiguration":
                settings = obj.get("buildSettings", {})
                for key in ("GCC_PREPROCESSOR_DEFINITIONS", "SWIFT_ACTIVE_COMPILATION_CONDITIONS"):
                    vals = settings.get(key, [])
                    joined = " ".join(vals) if isinstance(vals, list) else str(vals)
                    self.assertNotIn("MARCO_HAS_", joined, f"Unexpected MARCO_HAS_* in {obj['name']} {key}: {joined}")

        # -force_load ONLY in MarcoMovieIOS Debug config, NEVER in Release
        app_cfg_list = objects[native_targets["MarcoMovieIOS"]["buildConfigurationList"]]
        app_cfgs = {objects[cid]["name"]: objects[cid]["buildSettings"] for cid in app_cfg_list["buildConfigurations"]}
        self.assertIn("-force_load", app_cfgs["Debug"].get("OTHER_LDFLAGS", []))
        self.assertNotIn("-force_load", app_cfgs["Release"].get("OTHER_LDFLAGS", []))

    def test_full_mode_ios15_and_ios14_flags(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)

            # Build mock staged CPython, NodeMobile, and Mpv + companion XCFrameworks
            py_stage = tmp_path / "python-stage"
            py_fw = py_stage / "bundle" / "Frameworks" / "Python.framework"
            py_fw.mkdir(parents=True)
            (py_fw / "Python").write_bytes(b"mock-python-binary")
            (py_fw / "Headers").mkdir()
            (py_fw / "Headers" / "Python.h").write_text("// py header\n", encoding="utf-8")
            (py_fw / "Modules").mkdir()
            (py_fw / "Modules" / "module.modulemap").write_text("framework module Python {}\n", encoding="utf-8")
            (py_stage / "bundle" / "python").mkdir(parents=True)
            (py_stage / "bundle" / "python" / "site.py").write_text("# stdlib\n", encoding="utf-8")
            (py_stage / "bundle" / "app").mkdir(parents=True)
            (py_stage / "bundle" / "app" / "native_source_host.py").write_text("# host\n", encoding="utf-8")
            (py_stage / "bundle" / "app_packages").mkdir(parents=True)
            (py_stage / "prepared.json").write_text(json.dumps({"version": 1}), encoding="utf-8")

            catpaw_dir = tmp_path / "catpaw-frameworks"
            _make_mock_xcframework(catpaw_dir, "NodeMobile")

            mpv_dir = tmp_path / "mpv-xcframeworks"
            _make_mock_xcframework(mpv_dir, "Mpv")
            _make_mock_xcframework(mpv_dir, "Avcodec")

            discovered_py = prepare_ios.discover_python_framework(py_stage)
            discovered_catpaw = prepare_ios.discover_catpaw_framework(catpaw_dir, sdk="iphoneos")
            discovered_mpv, all_mpv_fws = prepare_ios.discover_mpv_frameworks(mpv_dir, sdk="iphoneos")
            self.assertEqual(len(all_mpv_fws), 2)

            # 1) Full device mode --min-ios 15.0
            runner_15 = tmp_path / "Runner15"
            info15_path = prepare_ios.generate_info_plist(min_ios="15.0", runner_dir=runner_15)
            pbx15_path = prepare_ios.generate_xcodeproj(
                min_ios="15.0",
                light_simulator=False,
                sdk="iphoneos",
                python_framework=discovered_py,
                catpaw_framework=discovered_catpaw,
                mpv_framework=discovered_mpv,
                mpv_embed_frameworks=all_mpv_fws,
                runner_dir=runner_15,
            )
            info15 = plistlib.loads(info15_path.read_bytes())
            self.assertEqual(info15["MinimumOSVersion"], "15.0")

            pbx15 = plistlib.loads(pbx15_path.read_bytes())
            objs15 = pbx15["objects"]
            proj15 = objs15[pbx15["rootObject"]]
            proj15_cfgs = {
                objs15[cid]["name"]: objs15[cid]["buildSettings"]
                for cid in objs15[proj15["buildConfigurationList"]]["buildConfigurations"]
            }
            for cfg_name in ("Debug", "Release"):
                swift_conds = proj15_cfgs[cfg_name]["SWIFT_ACTIVE_COMPILATION_CONDITIONS"]
                gcc_defs = proj15_cfgs[cfg_name]["GCC_PREPROCESSOR_DEFINITIONS"]
                for macro in ("MARCO_HAS_CPYTHON", "MARCO_HAS_CATPAW", "MARCO_HAS_MPV"):
                    self.assertIn(macro, swift_conds)
                    self.assertIn(f"{macro}=1", gcc_defs)
                self.assertNotIn("-Wl,-no_fixup_chains", proj15_cfgs[cfg_name].get("OTHER_LDFLAGS", []))
                self.assertNotIn("-fno-objc-msgsend-selector-stubs", proj15_cfgs[cfg_name].get("OTHER_CFLAGS", []))
                self.assertNotIn(
                    "-fno-objc-msgsend-selector-stubs",
                    proj15_cfgs[cfg_name].get("OTHER_CPLUSPLUSFLAGS", []),
                )
            self.assertEqual(proj15_cfgs["Release"]["IPHONEOS_DEPLOYMENT_TARGET"], "15.0")

            # 2) Full device mode --min-ios 14.0 (Xcode 16 compat flags injected)
            runner_14 = tmp_path / "Runner14"
            info14_path = prepare_ios.generate_info_plist(min_ios="14.0", runner_dir=runner_14)
            pbx14_path = prepare_ios.generate_xcodeproj(
                min_ios="14.0",
                light_simulator=False,
                sdk="iphoneos",
                python_framework=discovered_py,
                catpaw_framework=discovered_catpaw,
                mpv_framework=discovered_mpv,
                mpv_embed_frameworks=all_mpv_fws,
                runner_dir=runner_14,
            )
            info14 = plistlib.loads(info14_path.read_bytes())
            self.assertEqual(info14["MinimumOSVersion"], "14.0")

            pbx14 = plistlib.loads(pbx14_path.read_bytes())
            objs14 = pbx14["objects"]
            proj14 = objs14[pbx14["rootObject"]]
            proj14_cfgs = {
                objs14[cid]["name"]: objs14[cid]["buildSettings"]
                for cid in objs14[proj14["buildConfigurationList"]]["buildConfigurations"]
            }
            for cfg_name in ("Debug", "Release"):
                swift_conds = proj14_cfgs[cfg_name]["SWIFT_ACTIVE_COMPILATION_CONDITIONS"]
                gcc_defs = proj14_cfgs[cfg_name]["GCC_PREPROCESSOR_DEFINITIONS"]
                for macro in ("MARCO_HAS_CPYTHON", "MARCO_HAS_CATPAW", "MARCO_HAS_MPV"):
                    self.assertIn(macro, swift_conds)
                    self.assertIn(f"{macro}=1", gcc_defs)
                self.assertIn("-Wl,-no_fixup_chains", proj14_cfgs[cfg_name].get("OTHER_LDFLAGS", []))
                self.assertIn("-fno-objc-msgsend-selector-stubs", proj14_cfgs[cfg_name].get("OTHER_CFLAGS", []))
                self.assertIn(
                    "-fno-objc-msgsend-selector-stubs",
                    proj14_cfgs[cfg_name].get("OTHER_CPLUSPLUSFLAGS", []),
                )
            self.assertEqual(proj14_cfgs["Release"]["IPHONEOS_DEPLOYMENT_TARGET"], "14.0")

            # 3) Verify runtime embedding strips Headers/Modules and bundles Python + NodeMobile + Mpv
            mock_app = _make_mock_ios_app(tmp_path / "MarcoMovieIOS.app", min_ios="15.0", include_dsym=False)
            embed_report = prepare_ios.embed_runtimes_into_app(
                mock_app,
                sdk="iphoneos",
                python_stage_dir=py_stage,
                catpaw_frameworks_dir=catpaw_dir,
                mpv_xcframeworks_dir=mpv_dir,
            )
            self.assertEqual(
                set(embed_report["embedded_frameworks"]),
                {"Python.framework", "NodeMobile.framework", "Mpv.framework", "Avcodec.framework"},
            )
            self.assertTrue((mock_app / "python" / "site.py").is_file())
            self.assertTrue((mock_app / "app" / "native_source_host.py").is_file())
            self.assertTrue((mock_app / "python-runtime-manifest.json").is_file())
            for fw_name in ("Python.framework", "NodeMobile.framework", "Mpv.framework", "Avcodec.framework"):
                self.assertTrue((mock_app / "Frameworks" / fw_name).is_dir())
                self.assertFalse((mock_app / "Frameworks" / fw_name / "Headers").exists())
                self.assertFalse((mock_app / "Frameworks" / fw_name / "Modules").exists())

    def test_patch_ios_ipa_strict_macho_and_packaging(self) -> None:
        # Positive case 1: valid arm64 iOS 15.0 app with .dSYM stripped and IPA executable bits verified
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            original_macho = _make_synthetic_macho(minos_packed=0x000F0000)
            app_dir = _make_mock_ios_app(
                tmp_path / "MarcoMovieIOS.app",
                version="0.8.0",
                build="107",
                min_ios="15.0",
                macho_bytes=original_macho,
                include_dsym=True,
            )
            ipa_out = tmp_path / "MarcoMovie-0.8.0-ios-unsigned.ipa"
            patch_ios_ipa.main(
                [
                    str(app_dir),
                    "--min-ios",
                    "15.0",
                    "--expected-version",
                    "0.8.0",
                    "--expected-build",
                    "107",
                    "--skip-codesign",
                    "--ipa",
                    str(ipa_out),
                ]
            )
            self.assertFalse((app_dir / "MarcoMovieIOS.app.dSYM").exists(), ".dSYM must be stripped")
            # Strict verification must NEVER rewrite/forge Mach-O bytes
            self.assertEqual((app_dir / "MarcoMovieIOS").read_bytes(), original_macho)
            self.assertTrue(ipa_out.is_file())
            with zipfile.ZipFile(ipa_out, "r") as zf:
                names = set(zf.namelist())
                self.assertIn("Payload/MarcoMovieIOS.app/MarcoMovieIOS", names)
                self.assertIn("Payload/MarcoMovieIOS.app/Info.plist", names)
                exec_info = zf.getinfo("Payload/MarcoMovieIOS.app/MarcoMovieIOS")
                self.assertEqual((exec_info.external_attr >> 16) & 0o777, 0o755)
                plist_info = zf.getinfo("Payload/MarcoMovieIOS.app/Info.plist")
                self.assertEqual((plist_info.external_attr >> 16) & 0o777, 0o644)

        # Positive case 2: valid arm64 iOS 14.0 app using LC_VERSION_MIN_IPHONEOS
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            app14 = _make_mock_ios_app(
                tmp_path / "MarcoMovieIOS.app",
                version="0.8.0",
                build="107",
                min_ios="14.0",
                macho_bytes=_make_synthetic_macho(minos_packed=0x000E0000, use_version_min_cmd=True),
            )
            report14 = patch_ios_ipa.validate_app(
                app14,
                max_min_ios="14.0",
                expected_version="0.8.0",
                expected_build="107",
            )
            self.assertEqual(report14["min_ios"], "14.0")
            self.assertEqual(report14["verified_binaries"], ["MarcoMovieIOS"])

        # Negative case 1: reject Mach-O with minos > target (16.0 under --min-ios 15.0)
        with tempfile.TemporaryDirectory() as tmp:
            app_dir = _make_mock_ios_app(
                Path(tmp) / "MarcoMovieIOS.app",
                min_ios="15.0",
                macho_bytes=_make_synthetic_macho(minos_packed=0x00100000),  # iOS 16.0
            )
            with self.assertRaisesRegex(ValueError, "exceeds allowed iOS 15.0"):
                patch_ios_ipa.validate_app(app_dir, max_min_ios="15.0")

        # Negative case 2: reject simulator platform == 7 (PLATFORM_IOSSIMULATOR)
        with tempfile.TemporaryDirectory() as tmp:
            app_dir = _make_mock_ios_app(
                Path(tmp) / "MarcoMovieIOS.app",
                min_ios="15.0",
                macho_bytes=_make_synthetic_macho(platform=7, minos_packed=0x000F0000),
            )
            with self.assertRaisesRegex(ValueError, "expected PLATFORM_IOS"):
                patch_ios_ipa.validate_app(app_dir, max_min_ios="15.0")

        # Negative case 3: reject x86_64-only Mach-O binary
        with tempfile.TemporaryDirectory() as tmp:
            app_dir = _make_mock_ios_app(
                Path(tmp) / "MarcoMovieIOS.app",
                min_ios="15.0",
                macho_bytes=_make_synthetic_macho(cputype=0x01000007, minos_packed=0x000F0000),
            )
            with self.assertRaisesRegex(ValueError, "expected arm64"):
                patch_ios_ipa.validate_app(app_dir, max_min_ios="15.0")

        # Negative case 4: reject wrong expected version
        with tempfile.TemporaryDirectory() as tmp:
            app_dir = _make_mock_ios_app(Path(tmp) / "MarcoMovieIOS.app", version="0.7.9", build="107")
            with self.assertRaisesRegex(ValueError, "CFBundleShortVersionString"):
                patch_ios_ipa.validate_app(app_dir, max_min_ios="15.0", expected_version="0.8.0")

        # Negative case 5: reject wrong expected build
        with tempfile.TemporaryDirectory() as tmp:
            app_dir = _make_mock_ios_app(Path(tmp) / "MarcoMovieIOS.app", version="0.8.0", build="99")
            with self.assertRaisesRegex(ValueError, "CFBundleVersion"):
                patch_ios_ipa.validate_app(app_dir, max_min_ios="15.0", expected_build="107")

    def test_swift_delimiters_availability_and_isolation(self) -> None:
        swift_files = sorted(
            sf
            for sf in IOS_DIR.rglob("*.swift")
            if not any(part in {".build", ".swiftpm", "DerivedData", "RunnerProject", "Stage"} for part in sf.parts)
        )
        self.assertGreaterEqual(len(swift_files), 40)

        pairs = {"{": "}", "(": ")", "[": "]"}
        closing = set(pairs.values())
        glass_token_re = re.compile(r"\b(?:UIGlassEffect|UIGlassContainerEffect)\b")
        async_urlsession_re = re.compile(r"URLSession\.shared\.data\s*\(\s*(?:from|for):")

        glass_guard_hits = 0
        for sf in swift_files:
            rel = sf.relative_to(IOS_DIR).as_posix()
            text = sf.read_text(encoding="utf-8")

            # Zero Flutter coupling
            self.assertIsNone(
                re.search(r"(?m)^\s*import\s+Flutter\b", text),
                f"{rel}: pure native iOS client must NEVER import Flutter",
            )

            # Strict MarcoIOSCore isolation (no UIKit import in core or core unit tests)
            if rel.startswith(("Sources/MarcoIOSCore/", "Tests/MarcoIOSCoreTests/")):
                self.assertIsNone(
                    re.search(r"(?m)^\s*import\s+UIKit\b", text),
                    f"{rel}: MarcoIOSCore / MarcoIOSCoreTests must stay UIKit-free for macOS swift test",
                )

            # Balanced {}()[] delimiters
            stripped = _strip_swift_strings_and_comments(text)
            stack: list[str] = []
            for ch in stripped:
                if ch in pairs:
                    stack.append(pairs[ch])
                elif ch in closing:
                    self.assertTrue(stack, f"Unexpected '{ch}' in {rel}")
                    expected = stack.pop()
                    self.assertEqual(ch, expected, f"Mismatched '{ch}' (expected '{expected}') in {rel}")
            self.assertEqual(stack, [], f"Unclosed delimiters {stack} in {rel}")

            # Balanced #if / #endif + line-by-line checks on non-comment code
            if_stack: list[str] = []
            in_block_comment = 0
            for idx, raw_line in enumerate(text.splitlines(), start=1):
                line = raw_line
                # Track multi-line block comments coarsely so doc comments don't trigger code checks
                code_line = re.sub(r"//.*$", "", line)
                if "/*" in code_line or in_block_comment > 0:
                    opens = code_line.count("/*")
                    closes = code_line.count("*/")
                    if in_block_comment > 0:
                        in_block_comment = max(0, in_block_comment + opens - closes)
                        continue
                    code_line = re.sub(r"/\*.*?\*/", "", code_line)
                    if opens > closes:
                        in_block_comment += opens - closes
                        code_line = code_line.split("/*", 1)[0]

                s = code_line.strip()
                if re.match(r"^#if\b", s):
                    if_stack.append(s)
                elif re.match(r"^#elseif\b", s):
                    self.assertTrue(if_stack, f"{rel}:{idx}: #elseif without matching #if")
                    if_stack[-1] = s
                elif re.match(r"^#else\b", s):
                    self.assertTrue(if_stack, f"{rel}:{idx}: #else without matching #if")
                    if_stack[-1] = "#else"
                elif re.match(r"^#endif\b", s):
                    self.assertTrue(if_stack, f"{rel}:{idx}: #endif without matching #if")
                    if_stack.pop()

                # Reject unguarded iOS 15+ URLSession.shared.data(from:/for:)
                if async_urlsession_re.search(code_line):
                    self.fail(
                        f"{rel}:{idx}: unguarded URLSession.shared.data(from:/for:) breaks iOS 14.0 compatibility"
                    )

                # Every UIGlassEffect / UIGlassContainerEffect usage MUST be guarded by #if compiler(>=6.2)
                if glass_token_re.search(code_line):
                    glass_guard_hits += 1
                    has_compiler_guard = any("compiler(>=6.2)" in cond for cond in if_stack)
                    self.assertTrue(
                        has_compiler_guard,
                        f"{rel}:{idx}: UIGlassEffect/UIGlassContainerEffect must be inside #if compiler(>=6.2)",
                    )

            self.assertEqual(if_stack, [], f"{rel}: unclosed #if directive(s): {if_stack}")

        self.assertGreaterEqual(glass_guard_hits, 2, "Expected guarded UIGlassEffect references in AdaptiveGlassView.swift")

    def test_public_content_compliance(self) -> None:
        constants = _extract_public_guard_constants()
        excluded: set[str] = set(constants["EXCLUDED"])  # type: ignore[arg-type]
        allowed_hosts: set[str] = set(constants["ALLOWED_HOSTS"])  # type: ignore[arg-type]
        cloud_share_hosts: dict[str, set[str]] = constants["CLOUD_SHARE_HOSTS"]  # type: ignore[assignment]
        test_authorities: dict[str, set[str]] = constants["TEST_AUTHORITIES"]  # type: ignore[assignment]

        proc_status = subprocess.run(
            ["git", "status", "--porcelain", "-uall", "ios"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
        proc_tracked = subprocess.run(
            ["git", "ls-files", "ios"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
        rel_candidates = {
            line[3:].strip()
            for line in proc_status.stdout.splitlines()
            if line.strip() and not line.startswith("D ")
        } | {line.strip() for line in proc_tracked.stdout.splitlines() if line.strip()}

        files = [REPO_ROOT / rel for rel in sorted(rel_candidates) if (REPO_ROOT / rel).is_file()]
        self.assertGreaterEqual(len(files), 40, "Expected >= 40 tracked/unignored files under ios/")

        url_re = re.compile(r'https?://([^/\s"\'<>\\)`\u3000-\u303f\uff00-\uffef]+)')
        secret_patterns = [
            r"gh[pousr]_[A-Za-z0-9]{25,}",
            r"github_pat_[A-Za-z0-9_]{30,}",
            r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
            r"[A-Za-z]:[/\\](?:Users|TV)[/\\]",
            r"192\.168\.\d+\.\d+",
        ]

        for p in files:
            rel = p.relative_to(REPO_ROOT)
            rel_posix = rel.as_posix()
            self.assertFalse(
                any(part in excluded for part in rel.parts),
                f"{rel_posix}: contains excluded directory name",
            )
            self.assertNotIn(
                p.suffix,
                {".apk", ".aab", ".p12", ".jks", ".keystore", ".rar", ".zip", ".bin", ".mp4", ".ipa"},
                f"{rel_posix}: excluded binary extension",
            )
            if p.suffix == ".png":
                continue
            text = p.read_bytes().decode("utf-8")
            for pat in secret_patterns:
                self.assertIsNone(re.search(pat, text), f"{rel_posix}: matched private pattern {pat}")
            for match in url_re.finditer(text):
                authority = match.group(1)
                if authority in test_authorities.get(rel_posix, set()):
                    continue
                if re.fullmatch(r"\$(?:[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_.]*\})", authority):
                    continue
                host = authority.split(":")[0].lower().rstrip(".,;")
                if host in cloud_share_hosts.get(rel_posix, set()):
                    continue
                if host not in allowed_hosts and not host.endswith((".test", ".example", ".invalid")):
                    self.fail(f"{rel_posix}: unlisted network host {host!r} in {match.group(0)!r}")


if __name__ == "__main__":
    unittest.main()
