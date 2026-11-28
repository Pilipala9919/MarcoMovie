#!/usr/bin/env python3
# Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
"""Prepare native iOS / iPadOS vendor sources, brand assets, frameworks, and Xcode project."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zlib

IOS_DIR = Path(__file__).resolve().parent
REPO_ROOT = IOS_DIR.parent

EDITION_VERSIONS_PATH = IOS_DIR / "edition-versions.json"
BUNDLE_IDENTIFIER = "com.pilipala.marcoMovie"
DEFAULT_MIN_IOS = "15.0"

QUICKJS_SRC_DIR = REPO_ROOT / "flutter" / "packages" / "quickjs_engine" / "native" / "cxx" / "quickjs"
CQUICKJS_DST_DIR = IOS_DIR / "Sources" / "CQuickJS"
CQUICKJS_INCLUDE_DIR = CQUICKJS_DST_DIR / "include"

SHARED_JS_HOST_DIR = REPO_ROOT / "shared" / "script-host" / "js-host"
SHARED_CATPAW_DIR = REPO_ROOT / "shared" / "catpaw"
SHARED_SHADERS_DIR = REPO_ROOT / "flutter" / "assets" / "shaders" / "anime4k"

IOS_JS_HOST_DST_DIR = IOS_DIR / "Sources" / "MarcoIOSCore" / "Resources" / "js-host"
IOS_CATPAW_DST_DIR = IOS_DIR / "Sources" / "MarcoIOSCore" / "Resources" / "catpaw"
IOS_SHADERS_DST_DIR = IOS_DIR / "Sources" / "MarcoIOSCore" / "Resources" / "shaders" / "anime4k"

REQUIRED_SHARED_JS_HOST_FILES = (
    "crypto-js.js",
    "catvod.mjs",
    "module-interop.js",
    "bootstrap.js",
    "crypto.LICENSE",
)

REQUIRED_CATPAW_JS_HOST_FILES = (
    "drpy-core.js",
)

EXTRA_CATPAW_NODE_FILES = (
    "host.cjs",
    "fetch.cjs",
    "fetch-LICENSE.txt",
    "fetch-provenance.json",
    "node-mobile-LICENSE.txt",
)

PORTABLE_QUICKJS_C_FILES = (
    "quickjs.c",
    "libregexp.c",
    "libunicode.c",
    "dtoa.c",
)

PUBLIC_QUICKJS_HEADERS = (
    "quickjs.h",
    "quickjs-libc.h",
)

APP_ICON_CANDIDATES = (
    REPO_ROOT / "flutter" / "brand" / "ios" / "1024.png",
    REPO_ROOT / "docs" / "images" / "app-icon-512.png",
)

LOGO_MARK_CANDIDATES = (
    REPO_ROOT / "android-tv" / "src" / "main" / "res" / "drawable-nodpi" / "logo_mark.png",
    REPO_ROOT / "android-mobile" / "src" / "main" / "res" / "drawable-nodpi" / "logo_mark.png",
)

RUNNER_DIR = IOS_DIR / "RunnerProject"
XCODEPROJ_DIR = RUNNER_DIR / "MarcoMovieIOS.xcodeproj"
XCSCHEMES_DIR = XCODEPROJ_DIR / "xcshareddata" / "xcschemes"
ASSETS_DIR = RUNNER_DIR / "Assets.xcassets"

MPV_XCFRAMEWORKS_VERSION = "v0.6.0"
MPV_XCFRAMEWORKS_ASSET = f"libmpv-xcframeworks_{MPV_XCFRAMEWORKS_VERSION}_ios-universal-video-default.tar.gz"
MPV_XCFRAMEWORKS_SHA256 = "a95bc18508af26136b8a408341c05b5585d644ec013f00ac07db09d2e28d36ae"
MPV_XCFRAMEWORKS_URL = (
    f"https://github.com/media-kit/libmpv-darwin-build/releases/download/"
    f"{MPV_XCFRAMEWORKS_VERSION}/{MPV_XCFRAMEWORKS_ASSET}"
)

APP_ICON_SLOTS: tuple[tuple[str, str, str, int], ...] = (
    ("iphone", "20x20", "2x", 40),
    ("iphone", "20x20", "3x", 60),
    ("iphone", "29x29", "2x", 58),
    ("iphone", "29x29", "3x", 87),
    ("iphone", "40x40", "2x", 80),
    ("iphone", "40x40", "3x", 120),
    ("iphone", "60x60", "2x", 120),
    ("iphone", "60x60", "3x", 180),
    ("ipad", "20x20", "1x", 20),
    ("ipad", "20x20", "2x", 40),
    ("ipad", "29x29", "1x", 29),
    ("ipad", "29x29", "2x", 58),
    ("ipad", "40x40", "1x", 40),
    ("ipad", "40x40", "2x", 80),
    ("ipad", "76x76", "1x", 76),
    ("ipad", "76x76", "2x", 152),
    ("ipad", "83.5x83.5", "2x", 167),
    ("ios-marketing", "1024x1024", "1x", 1024),
)

NS_BONJOUR_SERVICES = [
    "_marcomovie-cast._tcp",
    "_airplay._tcp",
    "_raop._tcp",
    "_lelink._tcp",
    "_lebo._tcp",
    "_googlecast._tcp",
    "_dlna._tcp",
    "_upnp._tcp",
    "_http._tcp",
]

LS_APPLICATION_QUERIES_SCHEMES = [
    "apple-magnifier",
    "qklink",
    "qkcloudlink",
    "quark",
    "uclink",
    "ucliteioslink",
    "ucbrowser",
    "bdnetdisk",
    "baiduyun",
    "baiduyunipad",
    "baiduboxapp",
    "smartdrive",
    "alipan",
    "aliyundrive",
    "tbopen",
    "taobao",
]


# ==============================================================================
# Version & Helper Utilities
# ==============================================================================


def parse_version_tuple(version_str: str) -> tuple[int, int, int]:
    parts = [int(p) for p in version_str.strip().split(".") if p.strip().isdigit()]
    while len(parts) < 3:
        parts.append(0)
    return parts[0], parts[1], parts[2]


def read_ios_edition_version(path: Path = EDITION_VERSIONS_PATH) -> tuple[str, str]:
    version = "0.8.0"
    build = "107"
    if path.is_file():
        data = json.loads(path.read_text(encoding="utf-8")).get("ios", {})
        version = str(data.get("versionName") or version)
        build = str(data.get("buildNumber") or build)
    return version, build


def _write_json(path: Path, obj: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def _clear_directory(path: Path) -> None:
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)


# ==============================================================================
# Pure-Python PNG Decoder / Resizer / Encoder (Zero External Dependencies)
# ==============================================================================


def _paeth_predictor(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def decode_png_rgba(path: Path) -> tuple[int, int, list[bytes]]:
    """Decode an 8-bit RGB (color_type=2) or RGBA (color_type=6) PNG into RGBA rows."""
    data = path.read_bytes()
    if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path}: invalid PNG signature")

    pos = 8
    width = height = bit_depth = color_type = interlace = 0
    idat_chunks: list[bytes] = []
    while pos + 8 <= len(data):
        length, chunk_type = struct.unpack_from(">I4s", data, pos)
        chunk_data = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type, _comp, _flt, interlace = struct.unpack(
                ">IIBBBBB", chunk_data[:13]
            )
        elif chunk_type == b"IDAT":
            idat_chunks.append(chunk_data)
        elif chunk_type == b"IEND":
            break

    if width <= 0 or height <= 0 or bit_depth != 8 or color_type not in (2, 6) or interlace != 0:
        raise ValueError(
            f"{path}: unsupported PNG format ({width}x{height}, depth={bit_depth}, color={color_type})"
        )

    bpp = 3 if color_type == 2 else 4
    stride = width * bpp
    raw = zlib.decompress(b"".join(idat_chunks))
    expected_len = height * (1 + stride)
    if len(raw) < expected_len:
        raise ValueError(f"{path}: truncated decompressed IDAT stream")

    prev_row = bytearray(stride)
    rgba_rows: list[bytes] = []
    offset = 0
    for _ in range(height):
        flt = raw[offset]
        scan = raw[offset + 1 : offset + 1 + stride]
        offset += 1 + stride
        recon = bytearray(stride)

        if flt == 0:
            recon[:] = scan
        elif flt == 1:
            for i in range(stride):
                left = recon[i - bpp] if i >= bpp else 0
                recon[i] = (scan[i] + left) & 0xFF
        elif flt == 2:
            for i in range(stride):
                recon[i] = (scan[i] + prev_row[i]) & 0xFF
        elif flt == 3:
            for i in range(stride):
                left = recon[i - bpp] if i >= bpp else 0
                recon[i] = (scan[i] + ((left + prev_row[i]) >> 1)) & 0xFF
        elif flt == 4:
            for i in range(stride):
                left = recon[i - bpp] if i >= bpp else 0
                up = prev_row[i]
                up_left = prev_row[i - bpp] if i >= bpp else 0
                recon[i] = (scan[i] + _paeth_predictor(left, up, up_left)) & 0xFF
        else:
            raise ValueError(f"{path}: unsupported PNG filter {flt}")

        prev_row = recon
        if bpp == 4:
            rgba_rows.append(bytes(recon))
        else:
            row_rgba = bytearray(width * 4)
            row_rgba[0::4] = recon[0::3]
            row_rgba[1::4] = recon[1::3]
            row_rgba[2::4] = recon[2::3]
            row_rgba[3::4] = b"\xff" * width
            rgba_rows.append(bytes(row_rgba))

    return width, height, rgba_rows


def _downsample_rgba_half(src_w: int, src_h: int, src_rows: list[bytes]) -> tuple[int, int, list[bytes]]:
    """Fast 2x2 alpha-weighted halving for high-speed mip pyramid generation."""
    dst_w = max(1, src_w // 2)
    dst_h = max(1, src_h // 2)
    out_rows: list[bytes] = []
    for dy in range(dst_h):
        r0 = src_rows[min(src_h - 1, dy * 2)]
        r1 = src_rows[min(src_h - 1, dy * 2 + 1)]
        drow = bytearray(dst_w * 4)
        for dx in range(dst_w):
            p0 = min(src_w - 1, dx * 2) * 4
            p1 = min(src_w - 1, dx * 2 + 1) * 4
            a00 = r0[p0 + 3]
            a01 = r0[p1 + 3]
            a10 = r1[p0 + 3]
            a11 = r1[p1 + 3]
            a_sum = a00 + a01 + a10 + a11
            dp = dx * 4
            if a_sum > 0:
                drow[dp] = (r0[p0] * a00 + r0[p1] * a01 + r1[p0] * a10 + r1[p1] * a11) // a_sum
                drow[dp + 1] = (r0[p0 + 1] * a00 + r0[p1 + 1] * a01 + r1[p0 + 1] * a10 + r1[p1 + 1] * a11) // a_sum
                drow[dp + 2] = (r0[p0 + 2] * a00 + r0[p1 + 2] * a01 + r1[p0 + 2] * a10 + r1[p1 + 2] * a11) // a_sum
                drow[dp + 3] = a_sum >> 2
        out_rows.append(bytes(drow))
    return dst_w, dst_h, out_rows


def _build_mip_pyramid(src_w: int, src_h: int, src_rows: list[bytes]) -> list[tuple[int, int, list[bytes]]]:
    levels = [(src_w, src_h, src_rows)]
    w, h, rows = src_w, src_h, src_rows
    while w >= 64 and h >= 64:
        w, h, rows = _downsample_rgba_half(w, h, rows)
        levels.append((w, h, rows))
    return levels


def resize_rgba_box(
    src_w: int, src_h: int, src_rows: list[bytes], dst_w: int, dst_h: int
) -> list[bytes]:
    """Smooth box-averaged RGBA resizer."""
    if src_w == dst_w and src_h == dst_h:
        return src_rows
    out_rows: list[bytes] = []
    for dy in range(dst_h):
        y0 = (dy * src_h) // dst_h
        y1 = max(y0 + 1, ((dy + 1) * src_h) // dst_h)
        drow = bytearray(dst_w * 4)
        for dx in range(dst_w):
            x0 = (dx * src_w) // dst_w
            x1 = max(x0 + 1, ((dx + 1) * src_w) // dst_w)
            r_sum = g_sum = b_sum = a_sum = count = 0
            for sy in range(y0, min(src_h, y1)):
                srow = src_rows[sy]
                for sx in range(x0, min(src_w, x1)):
                    p = sx * 4
                    a = srow[p + 3]
                    r_sum += srow[p] * a
                    g_sum += srow[p + 1] * a
                    b_sum += srow[p + 2] * a
                    a_sum += a
                    count += 1
            pos = dx * 4
            if a_sum > 0 and count > 0:
                drow[pos] = min(255, r_sum // a_sum)
                drow[pos + 1] = min(255, g_sum // a_sum)
                drow[pos + 2] = min(255, b_sum // a_sum)
                drow[pos + 3] = min(255, a_sum // count)
        out_rows.append(bytes(drow))
    return out_rows


def resize_from_pyramid(
    pyramid: list[tuple[int, int, list[bytes]]], dst_w: int, dst_h: int
) -> list[bytes]:
    chosen = pyramid[0]
    for level in pyramid:
        if level[0] >= dst_w and level[1] >= dst_h:
            chosen = level
        else:
            break
    return resize_rgba_box(chosen[0], chosen[1], chosen[2], dst_w, dst_h)


def _png_chunk(chunk_type: bytes, payload: bytes) -> bytes:
    crc = zlib.crc32(chunk_type)
    crc = zlib.crc32(payload, crc) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + chunk_type + payload + struct.pack(">I", crc)


def encode_png_from_scanlines(width: int, height: int, color_type: int, raw_scanlines: bytes) -> bytes:
    ihdr = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    compressed = zlib.compress(raw_scanlines, level=6)
    return (
        b"\x89PNG\r\n\x1a\n"
        + _png_chunk(b"IHDR", ihdr)
        + _png_chunk(b"IDAT", compressed)
        + _png_chunk(b"IEND", b"")
    )


def encode_rgba_png(width: int, height: int, rgba_rows: list[bytes]) -> bytes:
    raw = b"".join(b"\x00" + row for row in rgba_rows)
    return encode_png_from_scanlines(width, height, 6, raw)


def encode_opaque_rgb_png(
    width: int, height: int, rgba_rows: list[bytes], bg: tuple[int, int, int] = (13, 16, 25)
) -> bytes:
    br, bg_c, bb = bg
    scanlines = bytearray()
    for row in rgba_rows:
        scanlines.append(0)
        rgb = bytearray(width * 3)
        for x in range(width):
            p = x * 4
            a = row[p + 3]
            if a == 255:
                rgb[x * 3] = row[p]
                rgb[x * 3 + 1] = row[p + 1]
                rgb[x * 3 + 2] = row[p + 2]
            elif a == 0:
                rgb[x * 3] = br
                rgb[x * 3 + 1] = bg_c
                rgb[x * 3 + 2] = bb
            else:
                inv = 255 - a
                rgb[x * 3] = (row[p] * a + br * inv) // 255
                rgb[x * 3 + 1] = (row[p + 1] * a + bg_c * inv) // 255
                rgb[x * 3 + 2] = (row[p + 2] * a + bb * inv) // 255
        scanlines.extend(rgb)
    return encode_png_from_scanlines(width, height, 2, bytes(scanlines))


def png_dimensions(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path}: invalid PNG file")
    return struct.unpack(">II", data[16:24])


# ==============================================================================
# Step 1 & 2: Sync QuickJS-NG, JS-Host, CatPaw (Full), and Anime4K Shaders
# ==============================================================================


def sync_quickjs_sources(
    src_dir: Path = QUICKJS_SRC_DIR,
    dst_dir: Path = CQUICKJS_DST_DIR,
) -> list[Path]:
    if not src_dir.is_dir():
        raise FileNotFoundError(f"QuickJS source directory missing: {src_dir}")

    include_dir = dst_dir / "include"
    dst_dir.mkdir(parents=True, exist_ok=True)
    include_dir.mkdir(parents=True, exist_ok=True)

    copied: list[Path] = []
    for c_name in PORTABLE_QUICKJS_C_FILES:
        src = src_dir / c_name
        if not src.is_file():
            raise FileNotFoundError(f"Missing QuickJS C file: {src}")
        dst = dst_dir / c_name
        shutil.copy2(src, dst)
        copied.append(dst)

    for h_file in sorted(src_dir.glob("*.h")):
        dst = dst_dir / h_file.name
        shutil.copy2(h_file, dst)
        copied.append(dst)

    for pub_h in PUBLIC_QUICKJS_HEADERS:
        src = src_dir / pub_h
        if src.exists():
            dst = include_dir / pub_h
            shutil.copy2(src, dst)
            copied.append(dst)

    return copied


def _load_catpaw_manifest(shared_catpaw_dir: Path = SHARED_CATPAW_DIR) -> tuple[Path, list[dict]]:
    manifest_path = shared_catpaw_dir / "drpy-assets.json"
    if not manifest_path.is_file():
        raise FileNotFoundError(f"CatPaw DRPY asset manifest missing: {manifest_path}")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    files = manifest.get("files")
    if not isinstance(files, list) or not files:
        raise ValueError(f"Invalid drpy-assets.json manifest: {manifest_path}")
    return manifest_path, files


def _read_verified_catpaw_asset(entry: dict, shared_catpaw_dir: Path = SHARED_CATPAW_DIR) -> bytes:
    name = entry["name"]
    src = shared_catpaw_dir / name
    if not src.is_file():
        raise FileNotFoundError(f"Missing CatPaw asset '{name}': {src}")
    raw = src.read_bytes()
    if len(raw) != entry["bytes"] or hashlib.sha256(raw).hexdigest() != entry["sha256"]:
        raise ValueError(f"SHA-256 verification failed for CatPaw asset: {name}")
    return raw


def sync_js_host_assets(
    shared_js_host_dir: Path = SHARED_JS_HOST_DIR,
    shared_catpaw_dir: Path = SHARED_CATPAW_DIR,
    dst_dir: Path = IOS_JS_HOST_DST_DIR,
) -> list[Path]:
    if not shared_js_host_dir.is_dir():
        raise FileNotFoundError(f"Shared js-host source directory missing: {shared_js_host_dir}")

    _, catpaw_entries = _load_catpaw_manifest(shared_catpaw_dir)
    catpaw_by_name = {entry["name"]: entry for entry in catpaw_entries}

    missing: list[str] = []
    for name in REQUIRED_SHARED_JS_HOST_FILES:
        src = shared_js_host_dir / name
        if not src.is_file():
            missing.append(f"{name} ({src})")
    for name in REQUIRED_CATPAW_JS_HOST_FILES:
        src = shared_catpaw_dir / name
        if not src.is_file():
            missing.append(f"{name} ({src})")
        elif name not in catpaw_by_name:
            missing.append(f"{name} (missing entry in drpy-assets.json)")

    if missing:
        raise FileNotFoundError("Missing required iOS js-host asset(s): " + ", ".join(missing))

    _clear_directory(dst_dir)
    copied: list[Path] = []
    for name in REQUIRED_SHARED_JS_HOST_FILES:
        dst = dst_dir / name
        shutil.copy2(shared_js_host_dir / name, dst)
        copied.append(dst)

    for name in REQUIRED_CATPAW_JS_HOST_FILES:
        raw = _read_verified_catpaw_asset(catpaw_by_name[name], shared_catpaw_dir)
        dst = dst_dir / name
        dst.write_bytes(raw)
        copied.append(dst)

    return copied


def sync_catpaw_assets(
    shared_catpaw_dir: Path = SHARED_CATPAW_DIR,
    dst_dir: Path = IOS_CATPAW_DST_DIR,
) -> list[Path]:
    """Sync ALL SHA-256 verified DRPY2/Guard assets PLUS Node host/fetch scripts for iOS."""
    manifest_path, files = _load_catpaw_manifest(shared_catpaw_dir)

    _clear_directory(dst_dir)
    copied: list[Path] = []
    dst_manifest = dst_dir / "drpy-assets.json"
    shutil.copy2(manifest_path, dst_manifest)
    copied.append(dst_manifest)

    for entry in files:
        raw = _read_verified_catpaw_asset(entry, shared_catpaw_dir)
        dst = dst_dir / entry["name"]
        dst.write_bytes(raw)
        copied.append(dst)

    for extra in EXTRA_CATPAW_NODE_FILES:
        src = shared_catpaw_dir / extra
        if not src.is_file():
            if extra in ("host.cjs", "fetch.cjs"):
                raise FileNotFoundError(f"Missing required CatPaw Node script: {src}")
            continue
        dst = dst_dir / extra
        shutil.copy2(src, dst)
        copied.append(dst)

    return copied


def sync_shader_assets(
    shared_shaders_dir: Path = SHARED_SHADERS_DIR,
    dst_dir: Path = IOS_SHADERS_DST_DIR,
) -> list[Path]:
    """Sync Anime4K GLSL shaders and manifest from flutter/assets/shaders/anime4k/."""
    if not shared_shaders_dir.is_dir():
        raise FileNotFoundError(f"Anime4K shader directory missing: {shared_shaders_dir}")

    _clear_directory(dst_dir)
    copied: list[Path] = []
    for src in sorted(shared_shaders_dir.iterdir()):
        if not src.is_file() or src.name.startswith("."):
            continue
        if src.suffix in (".glsl", ".json", ".txt"):
            dst = dst_dir / src.name
            shutil.copy2(src, dst)
            copied.append(dst)

    if not any(p.suffix == ".glsl" for p in copied):
        raise FileNotFoundError(f"No .glsl shaders found in {shared_shaders_dir}")
    return copied


# ==============================================================================
# Step 3: Optional Native Runtime Discovery, MPV Fetching & Embedding
# ==============================================================================


def resolve_xcframework_slice(xcframework_path: Path, sdk: str = "iphoneos") -> Path:
    """Resolve the matching iOS device or simulator .framework inside an .xcframework."""
    info_plist = xcframework_path / "Info.plist"
    if not info_plist.is_file():
        raise FileNotFoundError(f"Missing XCFramework Info.plist: {info_plist}")
    metadata = plistlib.loads(info_plist.read_bytes())
    libraries = metadata.get("AvailableLibraries") or []
    matches: list[dict] = []
    for entry in libraries:
        if entry.get("SupportedPlatform") != "ios":
            continue
        variant = str(entry.get("SupportedPlatformVariant") or "")
        archs = entry.get("SupportedArchitectures") or []
        if sdk == "iphoneos":
            if not variant and "arm64" in archs:
                matches.append(entry)
        else:
            if variant == "simulator":
                matches.append(entry)

    if not matches:
        raise ValueError(f"No matching {sdk} slice in {xcframework_path}")

    chosen = matches[0]
    slice_path = (xcframework_path / chosen["LibraryIdentifier"] / chosen["LibraryPath"]).resolve()
    if not slice_path.is_relative_to(xcframework_path.resolve()) or not slice_path.is_dir():
        raise ValueError(f"Resolved slice escapes XCFramework or is missing: {slice_path}")
    return slice_path


def fetch_mpv_xcframeworks(dest_dir: Path, cache_dir: Path | None = None) -> Path:
    """Fetch, SHA-256 verify, and extract pinned Mpv v0.6.0 XCFrameworks without Flutter config."""
    dest_dir = dest_dir.resolve()
    dest_dir.mkdir(parents=True, exist_ok=True)
    cache = (cache_dir or (IOS_DIR / "Stage" / "cache")).resolve()
    cache.mkdir(parents=True, exist_ok=True)
    archive_path = cache / MPV_XCFRAMEWORKS_ASSET

    if archive_path.is_file():
        if hashlib.sha256(archive_path.read_bytes()).hexdigest() != MPV_XCFRAMEWORKS_SHA256:
            archive_path.unlink()

    if not archive_path.is_file():
        gh_bin = shutil.which("gh")
        with tempfile.TemporaryDirectory(prefix="marco-mpv-fetch-", dir=cache) as tmp:
            tmp_path = Path(tmp)
            downloaded = tmp_path / MPV_XCFRAMEWORKS_ASSET
            if gh_bin:
                subprocess.run(
                    [
                        gh_bin,
                        "release",
                        "download",
                        MPV_XCFRAMEWORKS_VERSION,
                        "--repo",
                        "media-kit/libmpv-darwin-build",
                        "--pattern",
                        MPV_XCFRAMEWORKS_ASSET,
                        "--dir",
                        str(tmp_path),
                    ],
                    check=True,
                    timeout=300,
                )
            else:
                with urllib.request.urlopen(MPV_XCFRAMEWORKS_URL, timeout=180) as resp, downloaded.open("wb") as out:
                    shutil.copyfileobj(resp, out)
            if hashlib.sha256(downloaded.read_bytes()).hexdigest() != MPV_XCFRAMEWORKS_SHA256:
                raise ValueError(f"SHA-256 mismatch for {MPV_XCFRAMEWORKS_ASSET}")
            shutil.move(str(downloaded), str(archive_path))

    with tempfile.TemporaryDirectory(prefix="marco-mpv-extract-", dir=dest_dir.parent) as extract_tmp:
        extract_root = Path(extract_tmp).resolve()
        with tarfile.open(archive_path, "r:gz") as tar:
            for member in tar.getmembers():
                target = (extract_root / member.name).resolve()
                if not target.is_relative_to(extract_root):
                    raise ValueError(f"Unsafe archive entry in {MPV_XCFRAMEWORKS_ASSET}: {member.name}")
                if member.issym() or member.islnk():
                    link_target = (target.parent / member.linkname).resolve()
                    if not link_target.is_relative_to(extract_root):
                        raise ValueError(f"Unsafe symlink in {MPV_XCFRAMEWORKS_ASSET}: {member.name}")
            tar.extractall(extract_root)

        found_xcfws = sorted(extract_root.rglob("*.xcframework"))
        if not any(p.name == "Mpv.xcframework" for p in found_xcfws):
            raise FileNotFoundError(f"Mpv.xcframework missing inside {MPV_XCFRAMEWORKS_ASSET}")

        for xcfw in found_xcfws:
            dst = dest_dir / xcfw.name
            if dst.exists():
                shutil.rmtree(dst)
            shutil.move(str(xcfw), str(dst))

    resolve_xcframework_slice(dest_dir / "Mpv.xcframework", sdk="iphoneos")
    return dest_dir


def discover_python_framework(python_stage_dir: Path) -> Path:
    stage = python_stage_dir.resolve()
    candidates = (
        stage / "bundle" / "Frameworks" / "Python.framework",
        stage / "Frameworks" / "Python.framework",
        stage / "Python.framework",
    )
    for cand in candidates:
        if cand.is_dir():
            return cand
    raise FileNotFoundError(f"Python.framework not found under {stage}")


def discover_catpaw_framework(catpaw_frameworks_dir: Path, sdk: str = "iphoneos") -> Path:
    root = catpaw_frameworks_dir.resolve()
    xcfw_candidates = sorted(root.rglob("NodeMobile.xcframework"))
    if xcfw_candidates:
        return resolve_xcframework_slice(xcfw_candidates[0], sdk=sdk)
    direct = root / "NodeMobile.framework"
    if direct.is_dir():
        return direct
    raise FileNotFoundError(f"NodeMobile.xcframework not found under {root}")


def discover_mpv_frameworks(mpv_xcframeworks_dir: Path, sdk: str = "iphoneos") -> tuple[Path, list[Path]]:
    root = mpv_xcframeworks_dir.resolve()
    xcfws = sorted(root.glob("*.xcframework"))
    if not xcfws and (root / "Frameworks").is_dir():
        xcfws = sorted((root / "Frameworks").glob("*.xcframework"))
    if not xcfws:
        xcfws = sorted(root.rglob("*.xcframework"))

    if not xcfws:
        raise FileNotFoundError(f"No *.xcframework bundles found under {root}")

    resolved: list[Path] = []
    mpv_fw: Path | None = None
    for xcfw in xcfws:
        fw_slice = resolve_xcframework_slice(xcfw, sdk=sdk)
        resolved.append(fw_slice)
        if xcfw.name == "Mpv.xcframework" or fw_slice.name == "Mpv.framework":
            mpv_fw = fw_slice

    if mpv_fw is None:
        raise FileNotFoundError(f"Mpv.xcframework not found under {root}")
    return mpv_fw, resolved


def _copy_framework_bundle(src_fw: Path, dst_frameworks_dir: Path) -> Path:
    dst_frameworks_dir.mkdir(parents=True, exist_ok=True)
    dst_fw = dst_frameworks_dir / src_fw.name
    if dst_fw.exists():
        shutil.rmtree(dst_fw)
    shutil.copytree(src_fw, dst_fw, symlinks=True)
    for strip_dir in ("Headers", "PrivateHeaders", "Modules"):
        cand = dst_fw / strip_dir
        if cand.exists() and not cand.is_symlink():
            shutil.rmtree(cand)
    return dst_fw


def embed_runtimes_into_app(
    app_dir: Path,
    sdk: str = "iphoneos",
    python_stage_dir: Path | None = None,
    catpaw_frameworks_dir: Path | None = None,
    mpv_xcframeworks_dir: Path | None = None,
) -> dict[str, object]:
    """Embed staged CPython, NodeMobile, and libmpv frameworks into a built .app bundle."""
    app_dir = app_dir.resolve()
    if not (app_dir / "Info.plist").is_file():
        raise ValueError(f"Expected a built iOS .app bundle containing Info.plist: {app_dir}")

    fw_dir = app_dir / "Frameworks"
    fw_dir.mkdir(parents=True, exist_ok=True)
    embedded_frameworks: list[str] = []

    if python_stage_dir is not None:
        stage = python_stage_dir.resolve()
        bundle_root = stage / "bundle"
        if not bundle_root.is_dir():
            raise FileNotFoundError(f"Missing staged Python bundle directory: {bundle_root}")
        for name in ("python", "app", "app_packages", "Frameworks"):
            src = bundle_root / name
            if not src.exists():
                continue
            dst = app_dir / name
            if dst.is_symlink() or not dst.resolve().is_relative_to(app_dir):
                raise ValueError(f"Python runtime destination escapes app bundle: {dst}")
            shutil.copytree(src, dst, dirs_exist_ok=True)
        for strip_dir in ("Headers", "PrivateHeaders", "Modules"):
            cand = fw_dir / "Python.framework" / strip_dir
            if cand.exists() and not cand.is_symlink():
                shutil.rmtree(cand)
        prepared_json = stage / "prepared.json"
        if prepared_json.is_file():
            shutil.copy2(prepared_json, app_dir / "python-runtime-manifest.json")
        embedded_frameworks.append("Python.framework")

    if catpaw_frameworks_dir is not None:
        node_fw = discover_catpaw_framework(catpaw_frameworks_dir, sdk=sdk)
        _copy_framework_bundle(node_fw, fw_dir)
        embedded_frameworks.append(node_fw.name)

    if mpv_xcframeworks_dir is not None:
        _, all_mpv_fws = discover_mpv_frameworks(mpv_xcframeworks_dir, sdk=sdk)
        for fw in all_mpv_fws:
            _copy_framework_bundle(fw, fw_dir)
            embedded_frameworks.append(fw.name)

    return {
        "app": str(app_dir),
        "sdk": sdk,
        "embedded_frameworks": embedded_frameworks,
    }


# ==============================================================================
# Step 4: Generate iOS Assets.xcassets & Adaptive LaunchScreen.storyboard
# ==============================================================================


def resolve_app_icon_png(candidates: tuple[Path, ...] = APP_ICON_CANDIDATES) -> Path:
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    searched = ", ".join(str(p) for p in candidates)
    raise FileNotFoundError(f"Missing app icon asset; searched: {searched}")


def resolve_logo_mark_png(candidates: tuple[Path, ...] = LOGO_MARK_CANDIDATES) -> Path:
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    searched = ", ".join(str(p) for p in candidates)
    raise FileNotFoundError(f"Missing transparent brand mark asset (logo_mark.png); searched: {searched}")


def generate_ios_xcassets(assets_dir: Path = ASSETS_DIR) -> None:
    app_icon_src = resolve_app_icon_png()
    logo_mark_src = resolve_logo_mark_png()

    icon_w, icon_h, icon_rows = decode_png_rgba(app_icon_src)
    mark_w, mark_h, mark_rows = decode_png_rgba(logo_mark_src)

    icon_pyramid = _build_mip_pyramid(icon_w, icon_h, icon_rows)
    mark_pyramid = _build_mip_pyramid(mark_w, mark_h, mark_rows)

    assets_dir.mkdir(parents=True, exist_ok=True)
    _write_json(assets_dir / "Contents.json", {"info": {"author": "xcode", "version": 1}})

    # 1. AppIcon.appiconset (all iPhone + iPad + App Store 1024px opaque RGB slots)
    appicon_dir = assets_dir / "AppIcon.appiconset"
    appicon_dir.mkdir(parents=True, exist_ok=True)
    rendered_cache: dict[int, bytes] = {}
    appicon_images: list[dict[str, str]] = []
    for idiom, size_label, scale, pixels in APP_ICON_SLOTS:
        fname = f"Icon-{idiom}-{size_label}@{scale}.png"
        if pixels not in rendered_cache:
            resized = resize_from_pyramid(icon_pyramid, pixels, pixels)
            rendered_cache[pixels] = encode_opaque_rgb_png(pixels, pixels, resized)
        (appicon_dir / fname).write_bytes(rendered_cache[pixels])
        appicon_images.append(
            {
                "filename": fname,
                "idiom": idiom,
                "scale": scale,
                "size": size_label,
            }
        )
    _write_json(
        appicon_dir / "Contents.json",
        {"images": appicon_images, "info": {"author": "xcode", "version": 1}},
    )

    # 2. BrandLogoMark.imageset (1x/2x/3x transparent RGBA)
    brand_dir = assets_dir / "BrandLogoMark.imageset"
    brand_dir.mkdir(parents=True, exist_ok=True)
    brand_images: list[dict[str, str]] = []
    for scale, dim in ((1, 48), (2, 96), (3, 144)):
        fname = f"brand_logo_mark_{scale}x.png"
        resized = resize_from_pyramid(mark_pyramid, dim, dim)
        (brand_dir / fname).write_bytes(encode_rgba_png(dim, dim, resized))
        brand_images.append({"filename": fname, "idiom": "universal", "scale": f"{scale}x"})
    _write_json(
        brand_dir / "Contents.json",
        {"images": brand_images, "info": {"author": "xcode", "version": 1}},
    )

    # 3. LaunchImage.imageset (76x76 / 152x152 / 228x228 transparent RGBA)
    launch_dir = assets_dir / "LaunchImage.imageset"
    launch_dir.mkdir(parents=True, exist_ok=True)
    launch_images: list[dict[str, str]] = []
    for scale, dim in ((1, 76), (2, 152), (3, 228)):
        fname = f"launch_image_{scale}x.png"
        resized = resize_from_pyramid(mark_pyramid, dim, dim)
        (launch_dir / fname).write_bytes(encode_rgba_png(dim, dim, resized))
        launch_images.append({"filename": fname, "idiom": "universal", "scale": f"{scale}x"})
    _write_json(
        launch_dir / "Contents.json",
        {"images": launch_images, "info": {"author": "xcode", "version": 1}},
    )


def generate_launch_storyboard(runner_dir: Path = RUNNER_DIR) -> Path:
    runner_dir.mkdir(parents=True, exist_ok=True)
    storyboard = """<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<document type="com.apple.InterfaceBuilder3.CocoaTouch.Storyboard.XIB" version="3.0" toolsVersion="22505" targetRuntime="iOS.CocoaTouch" propertyAccessControl="none" useAutolayout="YES" launchScreen="YES" useTraitCollections="YES" useSafeAreas="YES" colorMatched="YES" initialViewController="01J-lp-oVM">
    <device id="retina6_12" orientation="portrait" appearance="light"/>
    <dependencies>
        <deployment identifier="iOS"/>
        <plugIn identifier="com.apple.InterfaceBuilder.IBCocoaTouchPlugin" version="22504"/>
        <capability name="Safe area layout guides" minToolsVersion="9.0"/>
        <capability name="System colors in document resources" minToolsVersion="11.0"/>
        <capability name="documents saved in the Xcode 8 format" minToolsVersion="8.0"/>
    </dependencies>
    <scenes>
        <!--View Controller-->
        <scene sceneID="EHf-IW-A2E">
            <objects>
                <viewController id="01J-lp-oVM" sceneMemberID="viewController">
                    <view key="view" contentMode="scaleToFill" id="Ze5-6b-2t3">
                        <rect key="frame" x="0.0" y="0.0" width="393" height="852"/>
                        <autoresizingMask key="autoresizingMask" widthSizable="YES" heightSizable="YES"/>
                        <subviews>
                            <imageView clipsSubviews="YES" userInteractionEnabled="NO" contentMode="scaleAspectFit" horizontalHuggingPriority="251" verticalHuggingPriority="251" image="LaunchImage" translatesAutoresizingMaskIntoConstraints="NO" id="YRO-k0-Ey4">
                                <rect key="frame" x="158.66666666666666" y="388" width="76" height="76"/>
                                <constraints>
                                    <constraint firstAttribute="width" constant="76" id="marco-launch-w"/>
                                    <constraint firstAttribute="height" constant="76" id="marco-launch-h"/>
                                </constraints>
                            </imageView>
                        </subviews>
                        <viewLayoutGuide key="safeArea" id="6Tk-OE-BBY"/>
                        <color key="backgroundColor" systemColor="systemBackgroundColor"/>
                        <constraints>
                            <constraint firstItem="YRO-k0-Ey4" firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" id="marco-launch-cx"/>
                            <constraint firstItem="YRO-k0-Ey4" firstAttribute="centerY" secondItem="Ze5-6b-2t3" secondAttribute="centerY" id="marco-launch-cy"/>
                        </constraints>
                    </view>
                </viewController>
                <placeholder placeholderIdentifier="IBFirstResponder" id="iYj-Kq-Ea1" userLabel="First Responder" sceneMemberID="firstResponder"/>
            </objects>
            <point key="canvasLocation" x="53" y="375"/>
        </scene>
    </scenes>
    <resources>
        <image name="LaunchImage" width="76" height="76"/>
        <systemColor name="systemBackgroundColor">
            <color white="1" alpha="1" colorSpace="custom" customColorSpace="genericGamma22GrayColorSpace"/>
        </systemColor>
    </resources>
</document>
"""
    path = runner_dir / "LaunchScreen.storyboard"
    path.write_text(storyboard, encoding="utf-8")
    return path


# ==============================================================================
# Step 5: Generate Info.plist, Deterministic project.pbxproj & Shared Scheme
# ==============================================================================


def _pbx_id(tag: str) -> str:
    return hashlib.sha1(f"marco-ios::{tag}".encode("utf-8")).hexdigest()[:24].upper()


def generate_info_plist(min_ios: str = DEFAULT_MIN_IOS, runner_dir: Path = RUNNER_DIR) -> Path:
    runner_dir.mkdir(parents=True, exist_ok=True)
    info = {
        "CFBundleDevelopmentRegion": "zh_CN",
        "CFBundleAllowMixedLocalizations": True,
        "CFBundleDisplayName": "Marco Movie",
        "CFBundleExecutable": "MarcoMovieIOS",
        "CFBundleIdentifier": BUNDLE_IDENTIFIER,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "MarcoMovieIOS",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "LSRequiresIPhoneOS": True,
        "MinimumOSVersion": min_ios,
        "UIDeviceFamily": [1, 2],
        "UIRequiredDeviceCapabilities": ["arm64"],
        "CADisableMinimumFrameDurationOnPhone": True,
        "UIApplicationSupportsIndirectInputEvents": True,
        "UIRequiresFullScreen": False,
        "UILaunchStoryboardName": "LaunchScreen",
        "UIBackgroundModes": ["audio"],
        "UIFileSharingEnabled": True,
        "LSSupportsOpeningDocumentsInPlace": True,
        "UIStatusBarStyle": "UIStatusBarStyleDefault",
        "UIViewControllerBasedStatusBarAppearance": True,
        "UIApplicationSceneManifest": {
            "UIApplicationSupportsMultipleScenes": True,
            "UISceneConfigurations": {
                "UIWindowSceneSessionRoleApplication": [
                    {
                        "UISceneClassName": "UIWindowScene",
                        "UISceneConfigurationName": "Default Configuration",
                        "UISceneDelegateClassName": "$(PRODUCT_MODULE_NAME).SceneDelegate",
                    },
                ],
            },
        },
        "UISupportedInterfaceOrientations": [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        ],
        "UISupportedInterfaceOrientations~ipad": [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        ],
        "NSLocalNetworkUsageDescription": "用于发现局域网投屏电视（DLNA/AirPlay）、局域网点对点同步及连接局域网 Emby 服务器与片源。",
        "NSCameraUsageDescription": "用于扫描电视或电脑端二维码，快速绑定 WebDAV 与局域网同步配置。",
        "NSFaceIDUsageDescription": "用于解锁隐私空间并保护本地收藏与观看记录。",
        "NSBonjourServices": list(NS_BONJOUR_SERVICES),
        "LSApplicationQueriesSchemes": list(LS_APPLICATION_QUERIES_SCHEMES),
        "CFBundleURLTypes": [
            {
                "CFBundleTypeRole": "Editor",
                "CFBundleURLName": BUNDLE_IDENTIFIER,
                "CFBundleURLSchemes": ["marcomovie"],
            },
        ],
        "NSAppTransportSecurity": {
            "NSAllowsArbitraryLoads": True,
        },
    }
    plist_path = runner_dir / "Info.plist"
    plist_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=False))
    return plist_path


def _file_type_for_source(path: Path) -> str:
    ext = path.suffix.lower()
    if ext == ".swift":
        return "sourcecode.swift"
    if ext == ".mm":
        return "sourcecode.cpp.objcpp"
    if ext == ".m":
        return "sourcecode.c.objc"
    if ext in (".cpp", ".cc", ".cxx"):
        return "sourcecode.cpp.cpp"
    return "sourcecode.c.c"


def _collect_sources(base_dir: Path, suffixes: tuple[str, ...]) -> list[Path]:
    if not base_dir.is_dir():
        return []
    return sorted(p for p in base_dir.rglob("*") if p.is_file() and p.suffix.lower() in suffixes)


def generate_xcodeproj(
    *,
    min_ios: str = DEFAULT_MIN_IOS,
    light_simulator: bool = False,
    sdk: str = "iphoneos",
    python_framework: Path | None = None,
    catpaw_framework: Path | None = None,
    mpv_framework: Path | None = None,
    mpv_embed_frameworks: list[Path] | None = None,
    runner_dir: Path = RUNNER_DIR,
) -> Path:
    xcodeproj_dir = runner_dir / "MarcoMovieIOS.xcodeproj"
    xcschemes_dir = xcodeproj_dir / "xcshareddata" / "xcschemes"
    xcodeproj_dir.mkdir(parents=True, exist_ok=True)
    xcschemes_dir.mkdir(parents=True, exist_ok=True)

    ios_ver, ios_build = read_ios_edition_version()
    is_ios14_compat = parse_version_tuple(min_ios) < (15, 0, 0)

    enabled_macros: list[str] = []
    linked_external_frameworks: list[Path] = []
    embedded_external_frameworks: list[Path] = []
    if not light_simulator:
        if python_framework is not None:
            enabled_macros.append("MARCO_HAS_CPYTHON")
            linked_external_frameworks.append(python_framework)
            embedded_external_frameworks.append(python_framework)
        if catpaw_framework is not None:
            enabled_macros.append("MARCO_HAS_CATPAW")
            linked_external_frameworks.append(catpaw_framework)
            embedded_external_frameworks.append(catpaw_framework)
        if mpv_framework is not None:
            enabled_macros.append("MARCO_HAS_MPV")
            linked_external_frameworks.append(mpv_framework)
            for fw in (mpv_embed_frameworks or [mpv_framework]):
                if fw not in embedded_external_frameworks:
                    embedded_external_frameworks.append(fw)

    cquickjs_sources = _collect_sources(IOS_DIR / "Sources" / "CQuickJS", (".c",))
    clibmpv_sources = _collect_sources(IOS_DIR / "Sources" / "CLibmpv", (".c",))
    bridges_sources = _collect_sources(IOS_DIR / "Sources" / "MarcoNativeBridges", (".m", ".mm", ".c", ".cpp"))
    core_sources = _collect_sources(IOS_DIR / "Sources" / "MarcoIOSCore", (".swift",))
    app_sources = _collect_sources(IOS_DIR / "Sources" / "MarcoMovieIOS", (".swift", ".m", ".mm"))
    test_sources = _collect_sources(IOS_DIR / "Tests" / "MarcoIOSCoreTests", (".swift",))
    test_sources.extend(_collect_sources(IOS_DIR / "Tests" / "MarcoMovieIOSSimulatorTests", (".swift",)))

    objects: dict[str, dict] = {}

    def put(oid: str, payload: dict) -> str:
        objects[oid] = payload
        return oid

    def rel_to_runner(path: Path) -> str:
        return Path(os.path.relpath(path, runner_dir)).as_posix()

    def register_source_list(target_tag: str, paths: list[Path]) -> tuple[list[str], list[str]]:
        frefs: list[str] = []
        bfiles: list[str] = []
        for path in paths:
            rpath = rel_to_runner(path)
            fref = put(
                _pbx_id(f"fref:{rpath}"),
                {
                    "isa": "PBXFileReference",
                    "lastKnownFileType": _file_type_for_source(path),
                    "name": path.name,
                    "path": rpath,
                    "sourceTree": "<group>",
                },
            )
            bfile = put(
                _pbx_id(f"bfile:{target_tag}:{rpath}"),
                {"isa": "PBXBuildFile", "fileRef": fref},
            )
            frefs.append(fref)
            bfiles.append(bfile)
        return frefs, bfiles

    cquickjs_frefs, cquickjs_bfiles = register_source_list("cquickjs", cquickjs_sources)
    clibmpv_frefs, clibmpv_bfiles = register_source_list("clibmpv", clibmpv_sources)
    bridges_frefs, bridges_bfiles = register_source_list("bridges", bridges_sources)
    core_frefs, core_bfiles = register_source_list("core", core_sources)
    app_frefs, app_bfiles = register_source_list("app", app_sources)
    test_frefs, test_bfiles = register_source_list("tests", test_sources)

    # Resource file references
    assets_fref = put(
        _pbx_id("fref:Assets.xcassets"),
        {
            "isa": "PBXFileReference",
            "lastKnownFileType": "folder.assetcatalog",
            "path": "Assets.xcassets",
            "sourceTree": "<group>",
        },
    )
    launch_fref = put(
        _pbx_id("fref:LaunchScreen.storyboard"),
        {
            "isa": "PBXFileReference",
            "lastKnownFileType": "file.storyboard",
            "path": "LaunchScreen.storyboard",
            "sourceTree": "<group>",
        },
    )
    info_fref = put(
        _pbx_id("fref:Info.plist"),
        {
            "isa": "PBXFileReference",
            "lastKnownFileType": "text.plist.xml",
            "path": "Info.plist",
            "sourceTree": "<group>",
        },
    )
    jshost_fref = put(
        _pbx_id("fref:js-host"),
        {
            "isa": "PBXFileReference",
            "lastKnownFileType": "folder",
            "name": "js-host",
            "path": rel_to_runner(IOS_JS_HOST_DST_DIR),
            "sourceTree": "<group>",
        },
    )
    catpaw_fref = put(
        _pbx_id("fref:catpaw"),
        {
            "isa": "PBXFileReference",
            "lastKnownFileType": "folder",
            "name": "catpaw",
            "path": rel_to_runner(IOS_CATPAW_DST_DIR),
            "sourceTree": "<group>",
        },
    )
    shaders_root = IOS_DIR / "Sources" / "MarcoIOSCore" / "Resources" / "shaders"
    shaders_fref = put(
        _pbx_id("fref:shaders"),
        {
            "isa": "PBXFileReference",
            "lastKnownFileType": "folder",
            "name": "shaders",
            "path": rel_to_runner(shaders_root),
            "sourceTree": "<group>",
        },
    )

    assets_bfile = put(_pbx_id("bfile:Assets.xcassets"), {"isa": "PBXBuildFile", "fileRef": assets_fref})
    launch_bfile = put(_pbx_id("bfile:LaunchScreen.storyboard"), {"isa": "PBXBuildFile", "fileRef": launch_fref})
    jshost_bfile = put(_pbx_id("bfile:js-host"), {"isa": "PBXBuildFile", "fileRef": jshost_fref})
    catpaw_bfile = put(_pbx_id("bfile:catpaw"), {"isa": "PBXBuildFile", "fileRef": catpaw_fref})
    shaders_bfile = put(_pbx_id("bfile:shaders"), {"isa": "PBXBuildFile", "fileRef": shaders_fref})

    app_resource_bfiles = [assets_bfile, launch_bfile, jshost_bfile, catpaw_bfile]
    if shaders_root.is_dir():
        app_resource_bfiles.append(shaders_bfile)

    # Product references
    cquickjs_prod_ref = put(
        _pbx_id("prod:libCQuickJS.a"),
        {
            "isa": "PBXFileReference",
            "explicitFileType": "archive.ar",
            "includeInIndex": "0",
            "path": "libCQuickJS.a",
            "sourceTree": "BUILT_PRODUCTS_DIR",
        },
    )
    clibmpv_prod_ref = put(
        _pbx_id("prod:libCLibmpv.a"),
        {
            "isa": "PBXFileReference",
            "explicitFileType": "archive.ar",
            "includeInIndex": "0",
            "path": "libCLibmpv.a",
            "sourceTree": "BUILT_PRODUCTS_DIR",
        },
    )
    bridges_prod_ref = put(
        _pbx_id("prod:libMarcoNativeBridges.a"),
        {
            "isa": "PBXFileReference",
            "explicitFileType": "archive.ar",
            "includeInIndex": "0",
            "path": "libMarcoNativeBridges.a",
            "sourceTree": "BUILT_PRODUCTS_DIR",
        },
    )
    core_prod_ref = put(
        _pbx_id("prod:libMarcoIOSCore.a"),
        {
            "isa": "PBXFileReference",
            "explicitFileType": "archive.ar",
            "includeInIndex": "0",
            "path": "libMarcoIOSCore.a",
            "sourceTree": "BUILT_PRODUCTS_DIR",
        },
    )
    app_prod_ref = put(
        _pbx_id("prod:MarcoMovieIOS.app"),
        {
            "isa": "PBXFileReference",
            "explicitFileType": "wrapper.application",
            "includeInIndex": "0",
            "path": "MarcoMovieIOS.app",
            "sourceTree": "BUILT_PRODUCTS_DIR",
        },
    )
    tests_prod_ref = put(
        _pbx_id("prod:MarcoMovieIOSTests.xctest"),
        {
            "isa": "PBXFileReference",
            "explicitFileType": "wrapper.cfbundle",
            "includeInIndex": "0",
            "path": "MarcoMovieIOSTests.xctest",
            "sourceTree": "BUILT_PRODUCTS_DIR",
        },
    )

    link_cquickjs_bfile = put(_pbx_id("bfile:link:libCQuickJS.a"), {"isa": "PBXBuildFile", "fileRef": cquickjs_prod_ref})
    link_clibmpv_bfile = put(_pbx_id("bfile:link:libCLibmpv.a"), {"isa": "PBXBuildFile", "fileRef": clibmpv_prod_ref})
    link_bridges_bfile = put(_pbx_id("bfile:link:libMarcoNativeBridges.a"), {"isa": "PBXBuildFile", "fileRef": bridges_prod_ref})
    link_core_bfile = put(_pbx_id("bfile:link:libMarcoIOSCore.a"), {"isa": "PBXBuildFile", "fileRef": core_prod_ref})

    # External frameworks (optional; empty in --light-simulator mode)
    ext_fw_frefs: list[str] = []
    ext_fw_fref_by_path: dict[Path, str] = {}
    framework_search_paths: list[str] = ["$(inherited)"]

    for fw_path in linked_external_frameworks + embedded_external_frameworks:
        resolved = fw_path.resolve()
        if resolved not in ext_fw_fref_by_path:
            fref = put(
                _pbx_id(f"fref:extfw:{resolved.as_posix()}"),
                {
                    "isa": "PBXFileReference",
                    "lastKnownFileType": "wrapper.framework",
                    "name": resolved.name,
                    "path": resolved.as_posix(),
                    "sourceTree": "<absolute>",
                },
            )
            ext_fw_fref_by_path[resolved] = fref
            ext_fw_frefs.append(fref)
        parent_str = resolved.parent.as_posix()
        if parent_str not in framework_search_paths:
            framework_search_paths.append(parent_str)

    app_link_bfiles = [link_core_bfile, link_bridges_bfile, link_clibmpv_bfile, link_cquickjs_bfile]
    for fw_path in linked_external_frameworks:
        resolved = fw_path.resolve()
        bfile = put(
            _pbx_id(f"bfile:link:extfw:{resolved.as_posix()}"),
            {"isa": "PBXBuildFile", "fileRef": ext_fw_fref_by_path[resolved]},
        )
        app_link_bfiles.append(bfile)

    embed_fw_bfiles: list[str] = []
    for fw_path in embedded_external_frameworks:
        resolved = fw_path.resolve()
        bfile = put(
            _pbx_id(f"bfile:embed:extfw:{resolved.as_posix()}"),
            {
                "isa": "PBXBuildFile",
                "fileRef": ext_fw_fref_by_path[resolved],
                "settings": {"ATTRIBUTES": ["RemoveHeadersOnCopy"]},
            },
        )
        embed_fw_bfiles.append(bfile)

    # Groups
    cquickjs_group = put(
        _pbx_id("grp:CQuickJS"),
        {"isa": "PBXGroup", "children": cquickjs_frefs, "name": "CQuickJS", "sourceTree": "<group>"},
    )
    clibmpv_group = put(
        _pbx_id("grp:CLibmpv"),
        {"isa": "PBXGroup", "children": clibmpv_frefs, "name": "CLibmpv", "sourceTree": "<group>"},
    )
    bridges_group = put(
        _pbx_id("grp:MarcoNativeBridges"),
        {"isa": "PBXGroup", "children": bridges_frefs, "name": "MarcoNativeBridges", "sourceTree": "<group>"},
    )
    core_group = put(
        _pbx_id("grp:MarcoIOSCore"),
        {"isa": "PBXGroup", "children": core_frefs, "name": "MarcoIOSCore", "sourceTree": "<group>"},
    )
    app_group = put(
        _pbx_id("grp:MarcoMovieIOS"),
        {
            "isa": "PBXGroup",
            "children": app_frefs + [assets_fref, launch_fref, jshost_fref, catpaw_fref, shaders_fref, info_fref],
            "name": "MarcoMovieIOS",
            "sourceTree": "<group>",
        },
    )
    tests_group = put(
        _pbx_id("grp:MarcoMovieIOSTests"),
        {"isa": "PBXGroup", "children": test_frefs, "name": "MarcoMovieIOSTests", "sourceTree": "<group>"},
    )
    frameworks_group = put(
        _pbx_id("grp:Frameworks"),
        {"isa": "PBXGroup", "children": ext_fw_frefs, "name": "Frameworks", "sourceTree": "<group>"},
    )
    products_group = put(
        _pbx_id("grp:Products"),
        {
            "isa": "PBXGroup",
            "children": [
                cquickjs_prod_ref,
                clibmpv_prod_ref,
                bridges_prod_ref,
                core_prod_ref,
                app_prod_ref,
                tests_prod_ref,
            ],
            "name": "Products",
            "sourceTree": "<group>",
        },
    )
    main_group = put(
        _pbx_id("grp:Main"),
        {
            "isa": "PBXGroup",
            "children": [
                cquickjs_group,
                clibmpv_group,
                bridges_group,
                core_group,
                app_group,
                tests_group,
                frameworks_group,
                products_group,
            ],
            "sourceTree": "<group>",
        },
    )

    # Build phases
    cquickjs_sources_phase = put(
        _pbx_id("phase:sources:CQuickJS"),
        {
            "isa": "PBXSourcesBuildPhase",
            "buildActionMask": "2147483647",
            "files": cquickjs_bfiles,
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    clibmpv_sources_phase = put(
        _pbx_id("phase:sources:CLibmpv"),
        {
            "isa": "PBXSourcesBuildPhase",
            "buildActionMask": "2147483647",
            "files": clibmpv_bfiles,
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    bridges_sources_phase = put(
        _pbx_id("phase:sources:MarcoNativeBridges"),
        {
            "isa": "PBXSourcesBuildPhase",
            "buildActionMask": "2147483647",
            "files": bridges_bfiles,
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    core_sources_phase = put(
        _pbx_id("phase:sources:MarcoIOSCore"),
        {
            "isa": "PBXSourcesBuildPhase",
            "buildActionMask": "2147483647",
            "files": core_bfiles,
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    app_sources_phase = put(
        _pbx_id("phase:sources:MarcoMovieIOS"),
        {
            "isa": "PBXSourcesBuildPhase",
            "buildActionMask": "2147483647",
            "files": app_bfiles,
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    app_frameworks_phase = put(
        _pbx_id("phase:frameworks:MarcoMovieIOS"),
        {
            "isa": "PBXFrameworksBuildPhase",
            "buildActionMask": "2147483647",
            "files": app_link_bfiles,
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    app_resources_phase = put(
        _pbx_id("phase:resources:MarcoMovieIOS"),
        {
            "isa": "PBXResourcesBuildPhase",
            "buildActionMask": "2147483647",
            "files": app_resource_bfiles,
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    app_embed_frameworks_phase = put(
        _pbx_id("phase:embed_frameworks:MarcoMovieIOS"),
        {
            "isa": "PBXCopyFilesBuildPhase",
            "buildActionMask": "2147483647",
            "dstPath": "",
            "dstSubfolderSpec": "10",
            "files": embed_fw_bfiles,
            "name": "Embed Frameworks",
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    tests_sources_phase = put(
        _pbx_id("phase:sources:MarcoMovieIOSTests"),
        {
            "isa": "PBXSourcesBuildPhase",
            "buildActionMask": "2147483647",
            "files": test_bfiles,
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    tests_frameworks_phase = put(
        _pbx_id("phase:frameworks:MarcoMovieIOSTests"),
        {
            "isa": "PBXFrameworksBuildPhase",
            "buildActionMask": "2147483647",
            "files": [],
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )
    tests_resources_phase = put(
        _pbx_id("phase:resources:MarcoMovieIOSTests"),
        {
            "isa": "PBXResourcesBuildPhase",
            "buildActionMask": "2147483647",
            "files": [],
            "runOnlyForDeploymentPostprocessing": "0",
        },
    )

    def make_config_list(tag: str, debug_settings: dict, release_settings: dict) -> str:
        dbg_id = put(
            _pbx_id(f"cfg:{tag}:Debug"),
            {"isa": "XCBuildConfiguration", "buildSettings": debug_settings, "name": "Debug"},
        )
        rel_id = put(
            _pbx_id(f"cfg:{tag}:Release"),
            {"isa": "XCBuildConfiguration", "buildSettings": release_settings, "name": "Release"},
        )
        return put(
            _pbx_id(f"cfglist:{tag}"),
            {
                "isa": "XCConfigurationList",
                "buildConfigurations": [dbg_id, rel_id],
                "defaultConfigurationIsVisible": "0",
                "defaultConfigurationName": "Release",
            },
        )

    macro_gcc_defs = [f"{m}=1" for m in enabled_macros]
    swift_conds_debug = ["$(inherited)", "DEBUG"] + list(enabled_macros)
    swift_conds_release = ["$(inherited)"] + list(enabled_macros)

    include_search_paths = [
        "$(SRCROOT)/../Sources/CQuickJS/include",
        "$(SRCROOT)/../Sources/CLibmpv/include",
        "$(SRCROOT)/../Sources/MarcoNativeBridges/include",
    ]

    proj_common: dict[str, object] = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_CXX_LANGUAGE_STANDARD": "gnu++17",
        "CLANG_CXX_LIBRARY": "libc++",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CURRENT_PROJECT_VERSION": ios_build,
        "FRAMEWORK_SEARCH_PATHS": list(framework_search_paths),
        "GCC_C_LANGUAGE_STANDARD": "gnu11",
        "GCC_PREPROCESSOR_DEFINITIONS": ["$(inherited)"] + macro_gcc_defs,
        "IPHONEOS_DEPLOYMENT_TARGET": min_ios,
        "MARKETING_VERSION": ios_ver,
        "SDKROOT": "iphoneos",
        "SUPPORTS_MACCATALYST": "NO",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "1,2",
    }
    if is_ios14_compat:
        proj_common["OTHER_LDFLAGS"] = ["$(inherited)", "-Wl,-no_fixup_chains"]
        proj_common["OTHER_CFLAGS"] = ["$(inherited)", "-fno-objc-msgsend-selector-stubs"]
        proj_common["OTHER_CPLUSPLUSFLAGS"] = ["$(inherited)", "-fno-objc-msgsend-selector-stubs"]

    proj_cfg_list = make_config_list(
        "Project",
        {
            **proj_common,
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": swift_conds_debug,
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
            "GCC_OPTIMIZATION_LEVEL": "0",
        },
        {
            **proj_common,
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": swift_conds_release,
            "SWIFT_OPTIMIZATION_LEVEL": "-O",
            "SWIFT_COMPILATION_MODE": "wholemodule",
        },
    )

    cquickjs_common = {
        "PRODUCT_NAME": "CQuickJS",
        "SKIP_INSTALL": "YES",
        "HEADER_SEARCH_PATHS": [
            "$(SRCROOT)/../Sources/CQuickJS",
            "$(SRCROOT)/../Sources/CQuickJS/include",
        ],
        "WARNING_CFLAGS": [
            "-Wno-unused-function",
            "-Wno-unused-variable",
            "-Wno-unused-parameter",
            "-Wno-unused-but-set-variable",
            "-Wno-shorten-64-to-32",
        ],
    }
    cquickjs_cfg_list = make_config_list(
        "CQuickJS",
        {
            **cquickjs_common,
            "GCC_PREPROCESSOR_DEFINITIONS": [
                "$(inherited)",
                "_GNU_SOURCE=1",
                'CONFIG_VERSION=\\"ng-0.14.0\\"',
            ],
        },
        {
            **cquickjs_common,
            "GCC_PREPROCESSOR_DEFINITIONS": [
                "$(inherited)",
                "_GNU_SOURCE=1",
                'CONFIG_VERSION=\\"ng-0.14.0\\"',
                "NDEBUG=1",
            ],
        },
    )

    clibmpv_common = {
        "PRODUCT_NAME": "CLibmpv",
        "SKIP_INSTALL": "YES",
        "HEADER_SEARCH_PATHS": [
            "$(SRCROOT)/../Sources/CLibmpv",
            "$(SRCROOT)/../Sources/CLibmpv/include",
        ],
    }
    clibmpv_cfg_list = make_config_list("CLibmpv", clibmpv_common, clibmpv_common)

    bridges_common = {
        "PRODUCT_NAME": "MarcoNativeBridges",
        "SKIP_INSTALL": "YES",
        "HEADER_SEARCH_PATHS": [
            "$(SRCROOT)/../Sources/MarcoNativeBridges/include",
            "$(SRCROOT)/../Sources/CLibmpv/include",
        ],
        "FRAMEWORK_SEARCH_PATHS": list(framework_search_paths),
        "GCC_PREPROCESSOR_DEFINITIONS": ["$(inherited)", "GLES_SILENCE_DEPRECATION=1"] + macro_gcc_defs,
    }
    bridges_cfg_list = make_config_list("MarcoNativeBridges", bridges_common, bridges_common)

    core_common = {
        "DEFINES_MODULE": "YES",
        "PRODUCT_MODULE_NAME": "MarcoIOSCore",
        "PRODUCT_NAME": "MarcoIOSCore",
        "SKIP_INSTALL": "YES",
        "HEADER_SEARCH_PATHS": list(include_search_paths),
        "SWIFT_INCLUDE_PATHS": list(include_search_paths),
        "FRAMEWORK_SEARCH_PATHS": list(framework_search_paths),
    }
    core_cfg_list = make_config_list(
        "MarcoIOSCore",
        {
            **core_common,
            "ENABLE_TESTABILITY": "YES",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": swift_conds_debug,
        },
        {
            **core_common,
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": swift_conds_release,
        },
    )

    app_extra_ldflags = ["$(inherited)", "-lc++", "-lz", "-lbz2", "-liconv"]
    if "MARCO_HAS_MPV" in enabled_macros:
        app_extra_ldflags.extend(
            [
                "-framework",
                "OpenGLES",
                "-framework",
                "CoreVideo",
                "-framework",
                "Metal",
                "-framework",
                "QuartzCore",
                "-framework",
                "AudioToolbox",
                "-framework",
                "VideoToolbox",
                "-framework",
                "AVFoundation",
                "-framework",
                "CoreMedia",
            ]
        )

    app_common = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "CODE_SIGNING_ALLOWED": "NO",
        "CODE_SIGN_IDENTITY": "",
        "CODE_SIGN_STYLE": "Manual",
        "COPY_PHASE_STRIP": "NO",
        "DEPLOYMENT_POSTPROCESSING": "NO",
        "FRAMEWORK_SEARCH_PATHS": list(framework_search_paths),
        "HEADER_SEARCH_PATHS": list(include_search_paths),
        "INFOPLIST_FILE": "Info.plist",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        "LIBRARY_SEARCH_PATHS": ["$(inherited)", "$(BUILT_PRODUCTS_DIR)"],
        "OTHER_LDFLAGS": list(app_extra_ldflags),
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_IDENTIFIER,
        "PRODUCT_NAME": "MarcoMovieIOS",
        "STRIP_INSTALLED_PRODUCT": "NO",
        "STRIP_SWIFT_SYMBOLS": "NO",
        "SWIFT_INCLUDE_PATHS": ["$(BUILT_PRODUCTS_DIR)"] + list(include_search_paths),
    }
    app_debug = {
        **app_common,
        "DEAD_CODE_STRIPPING": "NO",
        "DEFINES_MODULE": "YES",
        "ENABLE_TESTABILITY": "YES",
        "OTHER_LDFLAGS": list(app_extra_ldflags) + ["-force_load", "$(BUILT_PRODUCTS_DIR)/libMarcoIOSCore.a"],
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": swift_conds_debug,
    }
    app_release = {
        **app_common,
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": swift_conds_release,
    }
    app_cfg_list = make_config_list("MarcoMovieIOS", app_debug, app_release)

    tests_common = {
        "BUNDLE_LOADER": "$(TEST_HOST)",
        "CODE_SIGN_STYLE": "Manual",
        "FRAMEWORK_SEARCH_PATHS": list(framework_search_paths),
        "GENERATE_INFOPLIST_FILE": "YES",
        "HEADER_SEARCH_PATHS": list(include_search_paths),
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"],
        "PRODUCT_BUNDLE_IDENTIFIER": f"{BUNDLE_IDENTIFIER}.tests",
        "PRODUCT_NAME": "MarcoMovieIOSTests",
        "SWIFT_INCLUDE_PATHS": ["$(BUILT_PRODUCTS_DIR)"] + list(include_search_paths),
        "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/MarcoMovieIOS.app/MarcoMovieIOS",
    }
    tests_cfg_list = make_config_list(
        "MarcoMovieIOSTests",
        {**tests_common, "SWIFT_ACTIVE_COMPILATION_CONDITIONS": swift_conds_debug},
        {**tests_common, "SWIFT_ACTIVE_COMPILATION_CONDITIONS": swift_conds_release},
    )

    # Targets & dependencies
    project_id = _pbx_id("project:MarcoMovieIOS")
    cquickjs_target_id = _pbx_id("target:CQuickJS")
    clibmpv_target_id = _pbx_id("target:CLibmpv")
    bridges_target_id = _pbx_id("target:MarcoNativeBridges")
    core_target_id = _pbx_id("target:MarcoIOSCore")
    app_target_id = _pbx_id("target:MarcoMovieIOS")
    tests_target_id = _pbx_id("target:MarcoMovieIOSTests")

    def make_dep(owner_tag: str, dep_target_id: str, dep_name: str) -> str:
        proxy_id = put(
            _pbx_id(f"proxy:{owner_tag}->{dep_name}"),
            {
                "isa": "PBXContainerItemProxy",
                "containerPortal": project_id,
                "proxyType": "1",
                "remoteGlobalIDString": dep_target_id,
                "remoteInfo": dep_name,
            },
        )
        return put(
            _pbx_id(f"dep:{owner_tag}->{dep_name}"),
            {"isa": "PBXTargetDependency", "target": dep_target_id, "targetProxy": proxy_id},
        )

    put(
        cquickjs_target_id,
        {
            "isa": "PBXNativeTarget",
            "buildConfigurationList": cquickjs_cfg_list,
            "buildPhases": [cquickjs_sources_phase],
            "buildRules": [],
            "dependencies": [],
            "name": "CQuickJS",
            "productName": "CQuickJS",
            "productReference": cquickjs_prod_ref,
            "productType": "com.apple.product-type.library.static",
        },
    )
    put(
        clibmpv_target_id,
        {
            "isa": "PBXNativeTarget",
            "buildConfigurationList": clibmpv_cfg_list,
            "buildPhases": [clibmpv_sources_phase],
            "buildRules": [],
            "dependencies": [],
            "name": "CLibmpv",
            "productName": "CLibmpv",
            "productReference": clibmpv_prod_ref,
            "productType": "com.apple.product-type.library.static",
        },
    )
    put(
        bridges_target_id,
        {
            "isa": "PBXNativeTarget",
            "buildConfigurationList": bridges_cfg_list,
            "buildPhases": [bridges_sources_phase],
            "buildRules": [],
            "dependencies": [make_dep("bridges", clibmpv_target_id, "CLibmpv")],
            "name": "MarcoNativeBridges",
            "productName": "MarcoNativeBridges",
            "productReference": bridges_prod_ref,
            "productType": "com.apple.product-type.library.static",
        },
    )
    put(
        core_target_id,
        {
            "isa": "PBXNativeTarget",
            "buildConfigurationList": core_cfg_list,
            "buildPhases": [core_sources_phase],
            "buildRules": [],
            "dependencies": [
                make_dep("core", cquickjs_target_id, "CQuickJS"),
                make_dep("core", clibmpv_target_id, "CLibmpv"),
                make_dep("core", bridges_target_id, "MarcoNativeBridges"),
            ],
            "name": "MarcoIOSCore",
            "productName": "MarcoIOSCore",
            "productReference": core_prod_ref,
            "productType": "com.apple.product-type.library.static",
        },
    )

    app_build_phases = [app_sources_phase, app_frameworks_phase, app_resources_phase]
    if embed_fw_bfiles:
        app_build_phases.append(app_embed_frameworks_phase)

    put(
        app_target_id,
        {
            "isa": "PBXNativeTarget",
            "buildConfigurationList": app_cfg_list,
            "buildPhases": app_build_phases,
            "buildRules": [],
            "dependencies": [
                make_dep("app", cquickjs_target_id, "CQuickJS"),
                make_dep("app", clibmpv_target_id, "CLibmpv"),
                make_dep("app", bridges_target_id, "MarcoNativeBridges"),
                make_dep("app", core_target_id, "MarcoIOSCore"),
            ],
            "name": "MarcoMovieIOS",
            "productName": "MarcoMovieIOS",
            "productReference": app_prod_ref,
            "productType": "com.apple.product-type.application",
        },
    )
    put(
        tests_target_id,
        {
            "isa": "PBXNativeTarget",
            "buildConfigurationList": tests_cfg_list,
            "buildPhases": [tests_sources_phase, tests_frameworks_phase, tests_resources_phase],
            "buildRules": [],
            "dependencies": [make_dep("tests", app_target_id, "MarcoMovieIOS")],
            "name": "MarcoMovieIOSTests",
            "productName": "MarcoMovieIOSTests",
            "productReference": tests_prod_ref,
            "productType": "com.apple.product-type.bundle.unit-test",
        },
    )

    put(
        project_id,
        {
            "isa": "PBXProject",
            "attributes": {
                "LastSwiftUpdateCheck": "1600",
                "LastUpgradeCheck": "1600",
                "TargetAttributes": {
                    tests_target_id: {"TestTargetID": app_target_id},
                },
            },
            "buildConfigurationList": proj_cfg_list,
            "compatibilityVersion": "Xcode 14.0",
            "developmentRegion": "zh_CN",
            "hasScannedForEncodings": "0",
            "knownRegions": ["en", "zh_CN", "Base"],
            "mainGroup": main_group,
            "productRefGroup": products_group,
            "projectDirPath": "",
            "projectRoot": "",
            "targets": [
                cquickjs_target_id,
                clibmpv_target_id,
                bridges_target_id,
                core_target_id,
                app_target_id,
                tests_target_id,
            ],
        },
    )

    pbx_root = {
        "archiveVersion": "1",
        "classes": {},
        "objectVersion": "56",
        "objects": objects,
        "rootObject": project_id,
    }
    pbxproj_path = xcodeproj_dir / "project.pbxproj"
    pbxproj_path.write_bytes(plistlib.dumps(pbx_root, fmt=plistlib.FMT_XML, sort_keys=True))

    scheme_xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
   <BuildAction parallelizeBuildables="NO" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{cquickjs_target_id}" BuildableName="libCQuickJS.a" BlueprintName="CQuickJS" ReferencedContainer="container:MarcoMovieIOS.xcodeproj"/>
         </BuildActionEntry>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{clibmpv_target_id}" BuildableName="libCLibmpv.a" BlueprintName="CLibmpv" ReferencedContainer="container:MarcoMovieIOS.xcodeproj"/>
         </BuildActionEntry>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{bridges_target_id}" BuildableName="libMarcoNativeBridges.a" BlueprintName="MarcoNativeBridges" ReferencedContainer="container:MarcoMovieIOS.xcodeproj"/>
         </BuildActionEntry>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{core_target_id}" BuildableName="libMarcoIOSCore.a" BlueprintName="MarcoIOSCore" ReferencedContainer="container:MarcoMovieIOS.xcodeproj"/>
         </BuildActionEntry>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target_id}" BuildableName="MarcoMovieIOS.app" BlueprintName="MarcoMovieIOS" ReferencedContainer="container:MarcoMovieIOS.xcodeproj"/>
         </BuildActionEntry>
         <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{tests_target_id}" BuildableName="MarcoMovieIOSTests.xctest" BlueprintName="MarcoMovieIOSTests" ReferencedContainer="container:MarcoMovieIOS.xcodeproj"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
      <Testables>
         <TestableReference skipped="NO">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{tests_target_id}" BuildableName="MarcoMovieIOSTests.xctest" BlueprintName="MarcoMovieIOSTests" ReferencedContainer="container:MarcoMovieIOS.xcodeproj"/>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target_id}" BuildableName="MarcoMovieIOS.app" BlueprintName="MarcoMovieIOS" ReferencedContainer="container:MarcoMovieIOS.xcodeproj"/>
      </BuildableProductRunnable>
   </LaunchAction>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
"""
    (xcschemes_dir / "MarcoMovieIOS.xcscheme").write_text(scheme_xml, encoding="utf-8")
    return pbxproj_path


def prepare_all(
    *,
    min_ios: str | None = None,
    light_simulator: bool = False,
    sdk: str = "iphoneos",
    python_stage_dir: Path | None = None,
    catpaw_frameworks_dir: Path | None = None,
    mpv_xcframeworks_dir: Path | None = None,
    fetch_mpv_dir: Path | None = None,
) -> dict[str, object]:
    effective_min_ios = (min_ios or os.environ.get("MARCOMOVIE_IOS_MIN_TARGET") or DEFAULT_MIN_IOS).strip()

    if fetch_mpv_dir is not None:
        fetched = fetch_mpv_xcframeworks(fetch_mpv_dir)
        if mpv_xcframeworks_dir is None and not light_simulator:
            mpv_xcframeworks_dir = fetched

    copied_qjs = sync_quickjs_sources()
    copied_js = sync_js_host_assets()
    copied_catpaw = sync_catpaw_assets()
    copied_shaders = sync_shader_assets()
    generate_ios_xcassets()
    launch_storyboard = generate_launch_storyboard()
    info_plist = generate_info_plist(min_ios=effective_min_ios)

    python_fw: Path | None = None
    catpaw_fw: Path | None = None
    mpv_fw: Path | None = None
    mpv_embed_fws: list[Path] = []
    if not light_simulator:
        if python_stage_dir is not None:
            python_fw = discover_python_framework(python_stage_dir)
        if catpaw_frameworks_dir is not None:
            catpaw_fw = discover_catpaw_framework(catpaw_frameworks_dir, sdk=sdk)
        if mpv_xcframeworks_dir is not None:
            mpv_fw, mpv_embed_fws = discover_mpv_frameworks(mpv_xcframeworks_dir, sdk=sdk)

    pbxproj = generate_xcodeproj(
        min_ios=effective_min_ios,
        light_simulator=light_simulator,
        sdk=sdk,
        python_framework=python_fw,
        catpaw_framework=catpaw_fw,
        mpv_framework=mpv_fw,
        mpv_embed_frameworks=mpv_embed_fws,
    )

    enabled_runtimes: list[str] = []
    if not light_simulator:
        if python_fw is not None:
            enabled_runtimes.append("MARCO_HAS_CPYTHON")
        if catpaw_fw is not None:
            enabled_runtimes.append("MARCO_HAS_CATPAW")
        if mpv_fw is not None:
            enabled_runtimes.append("MARCO_HAS_MPV")

    return {
        "mode": "light-simulator" if light_simulator else "full",
        "min_ios": effective_min_ios,
        "sdk": sdk,
        "enabled_macros": enabled_runtimes,
        "quickjs_files": len(copied_qjs),
        "js_host_files": len(copied_js),
        "catpaw_files": len(copied_catpaw),
        "shader_files": len(copied_shaders),
        "launch_storyboard": str(launch_storyboard),
        "info_plist": str(info_plist),
        "pbxproj": str(pbxproj),
    }


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--light-simulator",
        action="store_true",
        help="Skip CPython/NodeMobile/Mpv frameworks and define zero MARCO_HAS_* macros (fast 8GB Mac / Simulator build)",
    )
    parser.add_argument(
        "--min-ios",
        default=None,
        help="Minimum iOS deployment target (default: $MARCOMOVIE_IOS_MIN_TARGET or 15.0; 14.0 adds Xcode 16 compat flags)",
    )
    parser.add_argument(
        "--sdk",
        choices=("iphoneos", "iphonesimulator"),
        default="iphoneos",
        help="Target SDK for selecting XCFramework slices",
    )
    parser.add_argument("--python-stage-dir", type=Path, default=None, help="Staged CPython runtime directory")
    parser.add_argument("--catpaw-frameworks-dir", type=Path, default=None, help="Directory containing NodeMobile.xcframework")
    parser.add_argument("--mpv-xcframeworks-dir", type=Path, default=None, help="Directory containing Mpv.xcframework & companion XCFrameworks")
    parser.add_argument("--fetch-mpv-dir", type=Path, default=None, help="Fetch & verify pinned libmpv v0.6.0 XCFrameworks into directory")
    parser.add_argument("--embed-runtimes", action="store_true", help="Embed staged frameworks/runtime assets into a built --app bundle")
    parser.add_argument("--app", type=Path, default=None, help="Path to built MarcoMovieIOS.app (used with --embed-runtimes)")
    args = parser.parse_args(argv)

    if args.embed_runtimes:
        if args.app is None:
            parser.error("--embed-runtimes requires --app <MarcoMovieIOS.app>")
        mpv_dir = args.mpv_xcframeworks_dir
        if args.fetch_mpv_dir is not None:
            fetched = fetch_mpv_xcframeworks(args.fetch_mpv_dir)
            mpv_dir = mpv_dir or fetched
        result = embed_runtimes_into_app(
            args.app,
            sdk=args.sdk,
            python_stage_dir=args.python_stage_dir,
            catpaw_frameworks_dir=args.catpaw_frameworks_dir,
            mpv_xcframeworks_dir=mpv_dir,
        )
        print(
            f"Embedded {len(result['embedded_frameworks'])} runtime framework(s) into {result['app']}: "
            + ", ".join(result["embedded_frameworks"])
        )
        return

    summary = prepare_all(
        min_ios=args.min_ios,
        light_simulator=args.light_simulator,
        sdk=args.sdk,
        python_stage_dir=args.python_stage_dir,
        catpaw_frameworks_dir=args.catpaw_frameworks_dir,
        mpv_xcframeworks_dir=args.mpv_xcframeworks_dir,
        fetch_mpv_dir=args.fetch_mpv_dir,
    )
    macros_desc = ", ".join(summary["enabled_macros"]) if summary["enabled_macros"] else "none (light-simulator)"
    print(
        f"Prepared iOS workspace ({summary['mode']}, min-ios={summary['min_ios']}, sdk={summary['sdk']}, "
        f"macros={macros_desc}): {summary['quickjs_files']} QuickJS files, "
        f"{summary['js_host_files']} JS host scripts, {summary['catpaw_files']} CatPaw assets, "
        f"{summary['shader_files']} Anime4K shader files, Xcode project -> {summary['pbxproj']}"
    )


if __name__ == "__main__":
    main()
