#!/usr/bin/env python3
# Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
"""Strictly verify iOS 14.0/15.0+ arm64 Mach-O binaries & Info.plist, ad-hoc sign for sideloading, and pack IPA."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import zipfile

MH_MAGIC_64 = bytes.fromhex("cffaedfe")
FAT_MAGIC_32 = bytes.fromhex("cafebabe")
FAT_MAGIC_64 = bytes.fromhex("cafebabf")
FAT_MAGICS = (FAT_MAGIC_32, FAT_MAGIC_64)

CPU_TYPE_ARM64 = 0x0100000C
ALLOWED_FILETYPES = (2, 6, 8)  # MH_EXECUTE, MH_DYLIB, MH_BUNDLE

LC_VERSION_MIN_MACOSX = 0x24
LC_VERSION_MIN_IPHONEOS = 0x25
LC_VERSION_MIN_TVOS = 0x2F
LC_VERSION_MIN_WATCHOS = 0x30
LC_BUILD_VERSION = 0x32
DISALLOWED_PLATFORM_CMDS = (LC_VERSION_MIN_MACOSX, LC_VERSION_MIN_TVOS, LC_VERSION_MIN_WATCHOS)

PLATFORM_IOS = 2
DEFAULT_BUNDLE_ID = "com.pilipala.marcoMovie"
DEFAULT_MIN_IOS = "15.0"


def parse_min_ios(min_ios: str) -> tuple[tuple[int, int, int], int]:
    """Parse dotted iOS version into ((major, minor, patch), packed_macho_version)."""
    parts = [int(p) for p in min_ios.strip().split(".") if p.strip()]
    if not parts:
        raise ValueError(f"Invalid iOS version string: {min_ios!r}")
    major = parts[0]
    minor = parts[1] if len(parts) > 1 else 0
    patch = parts[2] if len(parts) > 2 else 0
    return (major, minor, patch), (major << 16) | (minor << 8) | patch


def strip_dsym_bundles(app_dir: Path) -> int:
    """Remove any accidental .dSYM bundles so sideload signers never encounter MH_DSYM objects."""
    removed = 0
    for dsym in sorted(app_dir.rglob("*.dSYM")):
        if dsym.is_dir() and not dsym.is_symlink():
            shutil.rmtree(dsym)
            removed += 1
    return removed


def inspect_fat_archs(binary_path: Path) -> list[int]:
    """Return list of CPU types present in a Mach-O universal (FAT) binary."""
    data = binary_path.read_bytes()
    if len(data) < 8:
        raise ValueError(f"{binary_path}: truncated FAT Mach-O header")
    magic = data[:4]
    if magic not in FAT_MAGICS:
        raise ValueError(f"{binary_path}: not a FAT Mach-O binary")
    (nfat_arch,) = struct.unpack_from(">I", data, 4)
    if nfat_arch < 1 or nfat_arch > 32:
        raise ValueError(f"{binary_path}: invalid FAT architecture count {nfat_arch}")

    entry_size = 20 if magic == FAT_MAGIC_32 else 32
    if len(data) < 8 + nfat_arch * entry_size:
        raise ValueError(f"{binary_path}: truncated FAT architecture table")

    cpus: list[int] = []
    for idx in range(nfat_arch):
        (cputype,) = struct.unpack_from(">I", data, 8 + idx * entry_size)
        cpus.append(cputype)
    return cpus


def thin_fat_to_arm64(binary_path: Path) -> None:
    """Thin a universal Mach-O binary containing arm64 to a single arm64 slice; fail if simulator-only."""
    cpus = inspect_fat_archs(binary_path)
    if CPU_TYPE_ARM64 not in cpus:
        raise ValueError(
            f"{binary_path}: universal Mach-O has no arm64 device slice (cpus={[hex(c) for c in cpus]})"
        )
    lipo = shutil.which("lipo")
    if not lipo:
        raise RuntimeError(f"{binary_path}: universal Mach-O requires 'lipo' to thin arm64 slice")
    subprocess.run(
        [lipo, "-thin", "arm64", str(binary_path), "-output", str(binary_path)],
        check=True,
    )


def verify_macho_ios_arm64(binary_path: Path, max_min_ios: str = DEFAULT_MIN_IOS) -> None:
    """Strictly verify a single 64-bit arm64 iOS Mach-O binary without rewriting minos."""
    _, max_packed = parse_min_ios(max_min_ios)
    with binary_path.open("rb") as stream:
        magic = stream.read(4)

    if magic in FAT_MAGICS:
        thin_fat_to_arm64(binary_path)

    data = binary_path.read_bytes()
    if len(data) < 32 or data[:4] != MH_MAGIC_64:
        raise ValueError(f"{binary_path}: truncated or unsupported Mach-O (expected 64-bit LE 0xFEEDFACF)")

    cpu, _cpusub, filetype, ncmds, sizeofcmds, _flags, _reserved = struct.unpack_from("<IIIIIII", data, 4)
    if cpu != CPU_TYPE_ARM64:
        raise ValueError(f"{binary_path}: expected arm64 iOS device binary (0x0100000c), got {cpu:#x}")
    if filetype not in ALLOWED_FILETYPES:
        raise ValueError(f"{binary_path}: unsupported Mach-O filetype {filetype} (expected one of {ALLOWED_FILETYPES})")
    if sizeofcmds > len(data) - 32 or ncmds > sizeofcmds // 8:
        raise ValueError(f"{binary_path}: invalid Mach-O load-command bounds")

    pos = 32
    has_ios_target = False
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, pos)
        if cmdsize < 8 or pos + cmdsize > 32 + sizeofcmds:
            raise ValueError(f"{binary_path}: malformed Mach-O load command")

        if cmd in DISALLOWED_PLATFORM_CMDS:
            raise ValueError(f"{binary_path}: non-iOS device deployment load command {cmd:#x}")

        if cmd == LC_BUILD_VERSION:
            if cmdsize < 24:
                raise ValueError(f"{binary_path}: truncated LC_BUILD_VERSION")
            platform, minos, _sdk, _ntools = struct.unpack_from("<IIII", data, pos + 8)
            if platform != PLATFORM_IOS:
                raise ValueError(
                    f"{binary_path}: expected PLATFORM_IOS (2), got platform={platform} (simulator/non-iOS rejected)"
                )
            if minos > max_packed:
                raise ValueError(
                    f"{binary_path}: LC_BUILD_VERSION minos={minos:#x} exceeds allowed iOS {max_min_ios} ({max_packed:#x})"
                )
            has_ios_target = True
        elif cmd == LC_VERSION_MIN_IPHONEOS:
            if cmdsize < 16:
                raise ValueError(f"{binary_path}: truncated LC_VERSION_MIN_IPHONEOS")
            minos, _sdk = struct.unpack_from("<II", data, pos + 8)
            if minos > max_packed:
                raise ValueError(
                    f"{binary_path}: LC_VERSION_MIN_IPHONEOS minos={minos:#x} exceeds allowed iOS {max_min_ios} ({max_packed:#x})"
                )
            has_ios_target = True

        pos += cmdsize

    if pos != 32 + sizeofcmds or not has_ios_target:
        raise ValueError(f"{binary_path}: missing iOS deployment target load command or invalid command size")


def validate_info_plist(
    app_dir: Path,
    *,
    max_min_ios: str = DEFAULT_MIN_IOS,
    expected_version: str | None = None,
    expected_build: str | None = None,
    expected_bundle_id: str = DEFAULT_BUNDLE_ID,
) -> dict:
    """Strictly validate main Info.plist and nested framework Info.plists."""
    max_tuple, _ = parse_min_ios(max_min_ios)
    app_plist = app_dir / "Info.plist"
    if not app_plist.is_file():
        raise ValueError(f"Missing application Info.plist in {app_dir}")

    meta = plistlib.loads(app_plist.read_bytes())

    actual_bundle_id = str(meta.get("CFBundleIdentifier") or "").strip()
    if expected_bundle_id and actual_bundle_id != expected_bundle_id:
        raise ValueError(
            f"{app_plist}: CFBundleIdentifier={actual_bundle_id!r} != expected {expected_bundle_id!r}"
        )

    if expected_version is not None:
        actual_ver = str(meta.get("CFBundleShortVersionString") or "").strip()
        if actual_ver != expected_version.strip():
            raise ValueError(
                f"{app_plist}: CFBundleShortVersionString={actual_ver!r} != expected {expected_version!r}"
            )

    if expected_build is not None:
        actual_build = str(meta.get("CFBundleVersion") or "").strip()
        if actual_build != str(expected_build).strip():
            raise ValueError(
                f"{app_plist}: CFBundleVersion={actual_build!r} != expected {expected_build!r}"
            )

    device_family = meta.get("UIDeviceFamily")
    if not isinstance(device_family, list) or 1 not in device_family or 2 not in device_family:
        raise ValueError(f"{app_plist}: UIDeviceFamily must contain both 1 (iPhone) and 2 (iPad), got {device_family!r}")

    min_os = str(meta.get("MinimumOSVersion") or "").strip()
    if not min_os:
        raise ValueError(f"{app_plist}: missing MinimumOSVersion")
    if parse_min_ios(min_os)[0] > max_tuple:
        raise ValueError(f"{app_plist}: MinimumOSVersion={min_os!r} exceeds allowed iOS {max_min_ios}")

    if meta.get("CADisableMinimumFrameDurationOnPhone") is not True:
        raise ValueError(f"{app_plist}: CADisableMinimumFrameDurationOnPhone must be True (120Hz ProMotion)")

    if meta.get("UIRequiresFullScreen") is not False:
        raise ValueError(f"{app_plist}: UIRequiresFullScreen must be False (iPad multitasking / Stage Manager)")

    # Validate nested framework Info.plist deployment targets as well (strict; never rewrites).
    for plist_path in sorted(app_dir.rglob("Info.plist")):
        if plist_path == app_plist or plist_path.is_symlink() or not plist_path.is_file():
            continue
        nested = plistlib.loads(plist_path.read_bytes())
        nested_min = str(nested.get("MinimumOSVersion") or "").strip()
        if nested_min and parse_min_ios(nested_min)[0] > max_tuple:
            raise ValueError(f"{plist_path}: requires iOS {nested_min} > allowed {max_min_ios}")

    return meta


def validate_app(
    app_dir: Path,
    *,
    max_min_ios: str | None = None,
    expected_version: str | None = None,
    expected_build: str | None = None,
    expected_bundle_id: str = DEFAULT_BUNDLE_ID,
) -> dict[str, object]:
    """Strictly verify Info.plist and every Mach-O binary inside .app without forging minos."""
    target_min_ios = (max_min_ios or os.environ.get("MARCOMOVIE_IOS_MIN_TARGET") or DEFAULT_MIN_IOS).strip()
    meta = validate_info_plist(
        app_dir,
        max_min_ios=target_min_ios,
        expected_version=expected_version,
        expected_build=expected_build,
        expected_bundle_id=expected_bundle_id,
    )

    verified_binaries: list[str] = []
    for path in sorted(app_dir.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as stream:
            magic = stream.read(4)
        if magic not in FAT_MAGICS and magic != MH_MAGIC_64:
            continue
        verify_macho_ios_arm64(path, max_min_ios=target_min_ios)
        verified_binaries.append(path.relative_to(app_dir).as_posix())

    if not verified_binaries:
        raise ValueError(f"No arm64 iOS Mach-O binaries found inside {app_dir}")

    return {
        "bundle_id": str(meta.get("CFBundleIdentifier") or expected_bundle_id),
        "version": str(meta.get("CFBundleShortVersionString") or ""),
        "build": str(meta.get("CFBundleVersion") or ""),
        "min_ios": target_min_ios,
        "verified_binaries": verified_binaries,
    }


def build_trollstore_entitlements(bundle_id: str = DEFAULT_BUNDLE_ID) -> dict[str, object]:
    return {
        "application-identifier": f"TROLLSTORE.{bundle_id}",
        "com.apple.developer.team-identifier": "TROLLSTORE",
        "get-task-allow": True,
        "com.apple.developer.networking.multicast": True,
    }


def codesign_bundle(app_dir: Path, bundle_id: str = DEFAULT_BUNDLE_ID) -> Path:
    codesign = shutil.which("codesign")
    if not codesign:
        raise RuntimeError("codesign utility not found on PATH")

    fw_dir = app_dir / "Frameworks"
    if fw_dir.is_dir():
        for item in sorted(fw_dir.iterdir()):
            if item.suffix in (".framework", ".dylib"):
                subprocess.run(
                    [codesign, "--force", "--sign", "-", "--timestamp=none", str(item)],
                    check=True,
                )

    entitlements_path = app_dir.parent / "trollstore.entitlements"
    entitlements_path.write_bytes(
        plistlib.dumps(build_trollstore_entitlements(bundle_id), fmt=plistlib.FMT_XML, sort_keys=False)
    )
    subprocess.run(
        [
            codesign,
            "--force",
            "--sign",
            "-",
            "--timestamp=none",
            "--entitlements",
            str(entitlements_path),
            str(app_dir),
        ],
        check=True,
    )
    subprocess.run([codesign, "--verify", "--deep", "--strict", str(app_dir)], check=True)
    return entitlements_path


def pack_ipa(app_dir: Path, ipa_path: Path) -> Path:
    """Package Payload/<App>.app into an .ipa archive with POSIX executable bits preserved."""
    ipa_path.parent.mkdir(parents=True, exist_ok=True)
    root_plist = plistlib.loads((app_dir / "Info.plist").read_bytes())
    main_exec = str(root_plist.get("CFBundleExecutable") or app_dir.stem)
    app_resolved = app_dir.resolve()

    with zipfile.ZipFile(ipa_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for item in sorted(app_dir.rglob("*")):
            rel = item.relative_to(app_dir).as_posix()
            arcname = f"Payload/{app_dir.name}/{rel}"
            if item.is_symlink():
                target_str = os.readlink(item)
                resolved_target = (item.parent / target_str).resolve()
                if not resolved_target.is_relative_to(app_resolved):
                    raise ValueError(f"Symlink escapes .app bundle: {item} -> {target_str}")
                zinfo = zipfile.ZipInfo(arcname)
                zinfo.create_system = 3
                zinfo.external_attr = (0o120755 << 16)
                zf.writestr(zinfo, target_str.encode("utf-8"))
                continue
            if not item.is_file():
                continue

            zinfo = zipfile.ZipInfo(arcname)
            zinfo.create_system = 3
            zinfo.compress_type = zipfile.ZIP_DEFLATED
            is_exec = item.name == main_exec or item.suffix == ".dylib"
            if not is_exec:
                with item.open("rb") as stream:
                    is_exec = stream.read(4) == MH_MAGIC_64
            mode = 0o100755 if is_exec else 0o100644
            zinfo.external_attr = mode << 16
            zf.writestr(zinfo, item.read_bytes())

    return ipa_path


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app_dir", type=Path, help="Path to MarcoMovieIOS.app")
    parser.add_argument(
        "--min-ios",
        default=None,
        help="Maximum allowed MinimumOSVersion / Mach-O minos (default: $MARCOMOVIE_IOS_MIN_TARGET or 15.0)",
    )
    parser.add_argument("--expected-version", default=None, help="Expected CFBundleShortVersionString")
    parser.add_argument("--expected-build", default=None, help="Expected CFBundleVersion")
    parser.add_argument("--ipa", type=Path, default=None, help="Optional output .ipa path")
    parser.add_argument("--skip-codesign", action="store_true", help="Skip macOS codesign step")
    args = parser.parse_args(argv)

    app_dir = args.app_dir.resolve()
    strip_dsym_bundles(app_dir)
    report = validate_app(
        app_dir,
        max_min_ios=args.min_ios,
        expected_version=args.expected_version,
        expected_build=args.expected_build,
    )

    if not args.skip_codesign:
        codesign_bundle(app_dir, bundle_id=str(report["bundle_id"]))

    if args.ipa is not None:
        pack_ipa(app_dir, args.ipa.resolve())

    print(
        f"Verified iOS bundle {report['bundle_id']} v{report['version']} ({report['build']}), "
        f"min-ios<={report['min_ios']}, {len(report['verified_binaries'])} arm64 Mach-O binary(ies)"
    )


if __name__ == "__main__":
    main()
