# Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
"""Deterministic procedural demo poster generator for Marco Movie onboarding.

Generates 14 abstract film-geometry 2:3 portrait posters (360x540) as 8-bit
indexed-palette PNGs (IHDR color type 3) with a baked-in top-right "示例 / DEMO"
badge and a bilingual UTF-8 manifest.json, mirrored identically to:
  - flutter/assets/demo/
  - android-tv/src/main/assets/demo/
  - android-mobile/src/main/assets/demo/

Zero third-party dependencies, 100% byte-deterministic across reruns.
"""

from __future__ import annotations

import hashlib
import json
import math
import random
import struct
import sys
import zlib
from pathlib import Path

SEED = 20261120
WIDTH = 360
HEIGHT = 540
MAX_SINGLE_PNG_BYTES = 35 * 1024
MAX_DIR_TOTAL_BYTES = 480 * 1024

ROOT = Path(__file__).resolve().parents[1]
OUTPUT_DIRS = (
    ROOT / "flutter" / "assets" / "demo",
    ROOT / "android-tv" / "src" / "main" / "assets" / "demo",
    ROOT / "android-mobile" / "src" / "main" / "assets" / "demo",
)

# 4x4 Bayer ordered dithering matrix normalized to [-0.5, +0.5).
BAYER_4X4 = (
    (0 / 16.0 - 0.5, 8 / 16.0 - 0.5, 2 / 16.0 - 0.5, 10 / 16.0 - 0.5),
    (12 / 16.0 - 0.5, 4 / 16.0 - 0.5, 14 / 16.0 - 0.5, 6 / 16.0 - 0.5),
    (3 / 16.0 - 0.5, 11 / 16.0 - 0.5, 1 / 16.0 - 0.5, 9 / 16.0 - 0.5),
    (15 / 16.0 - 0.5, 7 / 16.0 - 0.5, 13 / 16.0 - 0.5, 5 / 16.0 - 0.5),
)

# Crisp 5x7 ASCII glyphs for "DEMO" and separator dot.
GLYPHS_5X7 = {
    "D": (
        "11110",
        "10001",
        "10001",
        "10001",
        "10001",
        "10001",
        "11110",
    ),
    "E": (
        "11111",
        "10000",
        "10000",
        "11110",
        "10000",
        "10000",
        "11111",
    ),
    "M": (
        "10001",
        "11011",
        "10101",
        "10101",
        "10001",
        "10001",
        "10001",
    ),
    "O": (
        "01110",
        "10001",
        "10001",
        "10001",
        "10001",
        "10001",
        "01110",
    ),
    "/": (
        "00001",
        "00010",
        "00010",
        "00100",
        "01000",
        "01000",
        "10000",
    ),
}

# Crisp 9x9 bitmap glyphs for "示例".
GLYPHS_9X9 = {
    "示": (
        "011111110",
        "000000000",
        "111111111",
        "000010000",
        "001010100",
        "010010010",
        "100010001",
        "000110000",
        "000010000",
    ),
    "例": (
        "010111101",
        "010001001",
        "110010001",
        "010111011",
        "010010111",
        "010001011",
        "010010001",
        "010100001",
        "010000010",
    ),
}

# 14 strictly fictional placeholder entries. Zero real movie/show titles.
DEMO_SPECS = (
    {
        "id": "demo_01",
        "titleZh": "示例 · 远航",
        "titleEn": "Sample · Horizon",
        "subtitleZh": "抽象几何示例海报 · 仅作界面演示",
        "subtitleEn": "Procedural demo poster · UI preview only",
        "categoryZh": "科幻示例",
        "categoryEn": "Sci-Fi Demo",
        "specs": ["4K", "DV · ATMOS", "REMUX"],
        "progress": 0.68,
        "year": 2026,
        "accentHex": "#0A84FF",
        "colors": ((9, 9, 12), (10, 132, 255), (90, 200, 250), (225, 245, 255)),
        "motif": "aperture",
        "variant": 0,
    },
    {
        "id": "demo_02",
        "titleZh": "示例 · 城市微光",
        "titleEn": "Sample · City Glow",
        "subtitleZh": "抽象几何示例海报 · 仅作界面演示",
        "subtitleEn": "Procedural demo poster · UI preview only",
        "categoryZh": "都市示例",
        "categoryEn": "Urban Demo",
        "specs": ["4K", "HDR10+", "DD+ 5.1"],
        "progress": 0.34,
        "year": 2026,
        "accentHex": "#BF5AF2",
        "colors": ((11, 10, 18), (94, 92, 230), (191, 90, 242), (245, 224, 255)),
        "motif": "prism_beams",
        "variant": 0,
    },
    {
        "id": "demo_03",
        "titleZh": "示例 · 深空信标",
        "titleEn": "Sample · Deep Beacon",
        "subtitleZh": "抽象几何示例海报 · 仅作界面演示",
        "subtitleEn": "Procedural demo poster · UI preview only",
        "categoryZh": "探索示例",
        "categoryEn": "Voyage Demo",
        "specs": ["4K", "DV · ATMOS"],
        "progress": 0.52,
        "year": 2026,
        "accentHex": "#5AC8FA",
        "colors": ((8, 12, 20), (18, 86, 178), (90, 200, 250), (220, 248, 255)),
        "motif": "orbital_rings",
        "variant": 0,
    },
    {
        "id": "demo_04",
        "titleZh": "示例 · 海岸季风",
        "titleEn": "Sample · Coastal Wind",
        "subtitleZh": "抽象几何示例海报 · 仅作界面演示",
        "subtitleEn": "Procedural demo poster · UI preview only",
        "categoryZh": "自然示例",
        "categoryEn": "Nature Demo",
        "specs": ["4K", "HLG", "HEVC"],
        "progress": 0.0,
        "year": 2026,
        "accentHex": "#30D158",
        "colors": ((8, 16, 16), (20, 118, 108), (48, 209, 88), (218, 252, 232)),
        "motif": "horizon_waves",
        "variant": 0,
    },
    {
        "id": "demo_05",
        "titleZh": "示例 · 静夜回响",
        "titleEn": "Sample · Night Echo",
        "subtitleZh": "抽象几何示例海报 · 仅作界面演示",
        "subtitleEn": "Procedural demo poster · UI preview only",
        "categoryZh": "声景示例",
        "categoryEn": "Acoustic Demo",
        "specs": ["1080P", "REMUX", "DD+ 5.1"],
        "progress": 0.81,
        "year": 2026,
        "accentHex": "#5E5CE6",
        "colors": ((10, 10, 20), (62, 60, 168), (112, 134, 255), (232, 236, 255)),
        "motif": "cinema_stripes",
        "variant": 0,
    },
    {
        "id": "demo_06",
        "titleZh": "示例 · 云端走廊",
        "titleEn": "Sample · Cloud Corridor",
        "subtitleZh": "抽象几何示例海报 · 仅作界面演示",
        "subtitleEn": "Procedural demo poster · UI preview only",
        "categoryZh": "建筑示例",
        "categoryEn": "Design Demo",
        "specs": ["4K", "HDR10"],
        "progress": 0.0,
        "year": 2026,
        "accentHex": "#FF9F0A",
        "colors": ((16, 11, 10), (168, 86, 24), (255, 159, 10), (255, 238, 204)),
        "motif": "stepped_monolith",
        "variant": 0,
    },
    {
        "id": "demo_07",
        "titleZh": "示例 · 折光之境",
        "titleEn": "Sample · Prism Field",
        "subtitleZh": "抽象几何示例海报 · 仅作界面演示",
        "subtitleEn": "Procedural demo poster · UI preview only",
        "categoryZh": "光影示例",
        "categoryEn": "Optics Demo",
        "specs": ["4K", "DV · ATMOS"],
        "progress": 0.24,
        "year": 2026,
        "accentHex": "#FF6482",
        "colors": ((16, 9, 16), (168, 44, 106), (255, 100, 130), (255, 224, 234)),
        "motif": "constellation_grid",
        "variant": 0,
    },
    {
        "id": "demo_08",
        "titleZh": "示例 · 极昼航线",
        "titleEn": "Sample · Solstice Line",
        "subtitleZh": "抽象几何示例海报 · 仅作界面演示",
        "subtitleEn": "Procedural demo poster · UI preview only",
        "categoryZh": "纪实示例",
        "categoryEn": "Journal Demo",
        "specs": ["4K", "HDR10+", "REMUX"],
        "progress": 0.0,
        "year": 2026,
        "accentHex": "#64D2FF",
        "colors": ((9, 14, 22), (24, 108, 162), (100, 210, 255), (228, 248, 255)),
        "motif": "aperture",
        "variant": 1,
    },
    {
        "id": "demo_09",
        "titleZh": "示例 · 琥珀潮汐",
        "titleEn": "Sample · Amber Tide",
        "subtitleZh": "抽象几何示例海报 · 仅作界面演示",
        "subtitleEn": "Procedural demo poster · UI preview only",
        "categoryZh": "视觉示例",
        "categoryEn": "Visual Demo",
        "specs": ["4K", "HDR10", "ATMOS"],
        "progress": 0.45,
        "year": 2026,
        "accentHex": "#FFB340",
        "colors": ((18, 12, 9), (154, 72, 34), (255, 179, 64), (255, 240, 212)),
        "motif": "horizon_waves",
        "variant": 1,
    },
    {
        "id": "demo_10",
        "titleZh": "示例 · 雾港灯塔",
        "titleEn": "Sample · Mist Harbor",
        "subtitleZh": "抽象几何示例海报 · 仅作界面演示",
        "subtitleEn": "Procedural demo poster · UI preview only",
        "categoryZh": "人文示例",
        "categoryEn": "Story Demo",
        "specs": ["1080P", "HEVC"],
        "progress": 0.0,
        "year": 2026,
        "accentHex": "#5AC8FA",
        "colors": ((10, 14, 18), (44, 92, 118), (90, 200, 250), (226, 242, 248)),
        "motif": "prism_beams",
        "variant": 1,
    },
    {
        "id": "demo_11",
        "titleZh": "示例 · 星环纪事",
        "titleEn": "Sample · Orbital Notes",
        "subtitleZh": "抽象几何示例海报 · 仅作界面演示",
        "subtitleEn": "Procedural demo poster · UI preview only",
        "categoryZh": "天文示例",
        "categoryEn": "Cosmos Demo",
        "specs": ["4K", "DV · ATMOS"],
        "progress": 0.0,
        "year": 2026,
        "accentHex": "#BF5AF2",
        "colors": ((12, 9, 20), (102, 52, 178), (191, 90, 242), (242, 224, 255)),
        "motif": "orbital_rings",
        "variant": 1,
    },
    {
        "id": "demo_12",
        "titleZh": "示例 · 砾石山谷",
        "titleEn": "Sample · Slate Valley",
        "subtitleZh": "抽象几何示例海报 · 仅作界面演示",
        "subtitleEn": "Procedural demo poster · UI preview only",
        "categoryZh": "地貌示例",
        "categoryEn": "Terrain Demo",
        "specs": ["4K", "REMUX"],
        "progress": 0.0,
        "year": 2026,
        "accentHex": "#63E682",
        "colors": ((10, 14, 12), (40, 108, 78), (99, 230, 130), (224, 252, 232)),
        "motif": "stepped_monolith",
        "variant": 1,
    },
    {
        "id": "demo_13",
        "titleZh": "示例 · 晨曦画幅",
        "titleEn": "Sample · Dawn Frame",
        "subtitleZh": "抽象几何示例海报 · 仅作界面演示",
        "subtitleEn": "Procedural demo poster · UI preview only",
        "categoryZh": "影像示例",
        "categoryEn": "Cinema Demo",
        "specs": ["4K", "HDR10+"],
        "progress": 0.0,
        "year": 2026,
        "accentHex": "#FF6482",
        "colors": ((16, 10, 14), (156, 62, 112), (255, 138, 102), (255, 234, 222)),
        "motif": "cinema_stripes",
        "variant": 1,
    },
    {
        "id": "demo_14",
        "titleZh": "示例 · 漫游声景",
        "titleEn": "Sample · Drift Soundscape",
        "subtitleZh": "抽象几何示例海报 · 仅作界面演示",
        "subtitleEn": "Procedural demo poster · UI preview only",
        "categoryZh": "实验示例",
        "categoryEn": "Ambient Demo",
        "specs": ["1080P", "DD+ 5.1"],
        "progress": 0.0,
        "year": 2026,
        "accentHex": "#0A84FF",
        "colors": ((9, 10, 16), (38, 72, 186), (94, 92, 230), (218, 234, 255)),
        "motif": "constellation_grid",
        "variant": 1,
    },
)


def _clamp01(v: float) -> float:
    if v < 0.0:
        return 0.0
    if v > 1.0:
        return 1.0
    return v


def _lerp_rgb(
    c0: tuple[int, int, int], c1: tuple[int, int, int], t: float
) -> tuple[int, int, int]:
    t = _clamp01(t)
    return (
        int(round(c0[0] + (c1[0] - c0[0]) * t)),
        int(round(c0[1] + (c1[1] - c0[1]) * t)),
        int(round(c0[2] + (c1[2] - c0[2]) * t)),
    )


def _build_palette(
    colors: tuple[
        tuple[int, int, int],
        tuple[int, int, int],
        tuple[int, int, int],
        tuple[int, int, int],
    ],
) -> list[tuple[int, int, int]]:
    """Build a 48-entry indexed palette (0..43 gradient ramp + 4 badge colors)."""
    c_base, c_mid, c_accent, c_hi = colors
    palette: list[tuple[int, int, int]] = []
    # 0..43: smooth 4-stop tonal ramp
    stops = (0.0, 0.42, 0.78, 1.0)
    ramp_len = 44
    for i in range(ramp_len):
        t = i / float(ramp_len - 1)
        if t <= stops[1]:
            rgb = _lerp_rgb(c_base, c_mid, t / stops[1])
        elif t <= stops[2]:
            rgb = _lerp_rgb(c_mid, c_accent, (t - stops[1]) / (stops[2] - stops[1]))
        else:
            rgb = _lerp_rgb(c_accent, c_hi, (t - stops[2]) / (stops[3] - stops[2]))
        palette.append(rgb)
    # 44: badge dark background
    palette.append((14, 15, 20))
    # 45: badge border
    palette.append((120, 132, 156))
    # 46: badge accent dot
    palette.append(c_accent)
    # 47: crisp white text
    palette.append((245, 247, 252))
    return palette


def _motif_intensity(
    motif: str, variant: int, nx: float, ny: float, phase: float
) -> float:
    """Return normalized luminance [0, 1] for an abstract geometric film motif."""
    # Base cinema vignette gradient
    base = 0.08 + 0.34 * (1.0 - ny) + 0.14 * (1.0 - abs(nx - 0.5) * 1.6)
    cx = 0.5 + (0.12 if variant == 1 else -0.08)
    cy = 0.44 + (0.08 if variant == 1 else -0.04)
    dx = (nx - cx) * (WIDTH / float(HEIGHT))
    dy = ny - cy
    dist = math.hypot(dx, dy)

    accent = 0.0
    if motif == "aperture":
        # Concentric film lens rings + soft central glow
        glow = math.exp(-dist * dist * 8.5) * 0.52
        ring1 = math.exp(-((dist - 0.22) ** 2) * 900.0) * 0.45
        ring2 = math.exp(-((dist - 0.34) ** 2) * 1400.0) * 0.32
        angle = math.atan2(dy, dx)
        blade = 0.12 * max(0.0, math.cos(angle * 6.0 + phase)) * math.exp(-dist * 3.0)
        accent = glow + ring1 + ring2 + blade
    elif motif == "prism_beams":
        # Diagonal cinema projector shafts
        s1 = nx * 0.85 + ny * 0.52
        s2 = nx * 0.65 - ny * 0.76
        beam1 = math.exp(-((s1 - (0.62 + 0.08 * variant)) ** 2) * 28.0) * 0.55
        beam2 = math.exp(-((s1 - (0.88 - 0.10 * variant)) ** 2) * 75.0) * 0.35
        beam3 = math.exp(-((s2 + 0.12) ** 2) * 45.0) * 0.28
        accent = beam1 + beam2 + beam3
    elif motif == "orbital_rings":
        # Elliptical orbital arcs + bright beacon core
        ex = dx * 1.15
        ey = dy * 0.72 + dx * (0.28 if variant == 0 else -0.28)
        ed = math.hypot(ex, ey)
        arc1 = math.exp(-((ed - 0.25) ** 2) * 1500.0) * 0.48
        arc2 = math.exp(-((ed - 0.37) ** 2) * 1900.0) * 0.30
        core = math.exp(-(dx * dx + dy * dy) * 26.0) * 0.62
        accent = arc1 + arc2 + core
    elif motif == "horizon_waves":
        # Layered abstract horizon waves
        w1 = 0.56 + 0.06 * math.sin(nx * 5.2 + phase)
        w2 = 0.68 + 0.05 * math.sin(nx * 7.4 + phase + 1.4)
        w3 = 0.79 + 0.04 * math.cos(nx * 4.5 + phase)
        sun = math.exp(-((nx - cx) ** 2 * 10.0 + (ny - 0.34) ** 2 * 18.0)) * 0.58
        band1 = 0.24 if ny > w1 else 0.0
        band2 = -0.14 if ny > w2 else 0.0
        band3 = -0.14 if ny > w3 else 0.0
        crest = math.exp(-((ny - w1) ** 2) * 2200.0) * 0.42
        accent = sun + band1 + band2 + band3 + crest
    elif motif == "cinema_stripes":
        # Anamorphic light bands + subtle vertical framing bars
        band = math.exp(-((ny - (0.42 + 0.06 * variant)) ** 2) * 32.0) * 0.48
        flare = math.exp(-((ny - 0.46) ** 2) * 1600.0) * 0.46 * (1.0 - abs(nx - 0.5))
        bars = 0.14 * (0.5 + 0.5 * math.sin(nx * math.pi * 8.0 + phase))
        accent = band + flare + bars * (1.0 - ny * 0.6)
    elif motif == "stepped_monolith":
        # Minimal architectural stepped planes
        step = 0.0
        if 0.18 < nx < 0.82 and 0.24 < ny < 0.78:
            step += 0.22
        if 0.30 < nx < 0.74 and 0.32 < ny < 0.72:
            step += 0.20
        if 0.42 < nx < 0.66 and 0.40 < ny < 0.64:
            step += 0.24
        rim = math.exp(-((nx - 0.42) ** 2) * 1400.0) * (0.35 if 0.24 < ny < 0.78 else 0.0)
        accent = step + rim
    else:
        # constellation_grid: subtle diagonal lattice + glowing nodes
        gx = abs(math.sin((nx * 5.0 + ny * 2.0) * math.pi))
        gy = abs(math.sin((ny * 6.0 - nx * 1.5) * math.pi))
        grid = (math.exp(-gx * gx * 90.0) + math.exp(-gy * gy * 90.0)) * 0.16
        n1 = math.exp(-((nx - 0.34) ** 2 + (ny - 0.36) ** 2) * 35.0) * 0.55
        n2 = math.exp(-((nx - 0.68) ** 2 + (ny - 0.58) ** 2) * 42.0) * 0.45
        accent = grid + n1 + n2

    # Subtle bottom dark gradient so UI card text stays legible
    bottom_fade = 1.0 - 0.42 * max(0.0, (ny - 0.65) / 0.35)
    return _clamp01((base + accent) * bottom_fade)


def _draw_demo_badge(pixels: bytearray) -> None:
    """Bake a crisp top-right '示例 / DEMO' pill directly into the indexed image."""
    bx0, by0 = 216, 14
    bx1, by1 = 346, 42
    radius = 12

    for y in range(by0, by1 + 1):
        row_off = y * WIDTH
        for x in range(bx0, bx1 + 1):
            # Rounded pill corner check
            dx = 0
            dy = 0
            if x < bx0 + radius:
                dx = (bx0 + radius) - x
            elif x > bx1 - radius:
                dx = x - (bx1 - radius)
            if y < by0 + radius:
                dy = (by0 + radius) - y
            elif y > by1 - radius:
                dy = y - (by1 - radius)
            d2 = dx * dx + dy * dy
            if d2 > radius * radius:
                continue
            on_border = (
                x == bx0
                or x == bx1
                or y == by0
                or y == by1
                or d2 >= (radius - 1) * (radius - 1)
            )
            pixels[row_off + x] = 45 if on_border else 44

    # Small colored status dot inside left side of badge
    dot_cx, dot_cy = bx0 + 13, (by0 + by1) // 2
    for y in range(dot_cy - 3, dot_cy + 4):
        for x in range(dot_cx - 3, dot_cx + 4):
            if (x - dot_cx) ** 2 + (y - dot_cy) ** 2 <= 9:
                pixels[y * WIDTH + x] = 46

    # Draw "示例" (9x9 glyphs scaled 1x at y = by0 + 10)
    cursor_x = bx0 + 23
    text_y9 = by0 + 10
    for ch in ("示", "例"):
        glyph = GLYPHS_9X9[ch]
        for gy, row in enumerate(glyph):
            py = text_y9 + gy
            for gx, bit in enumerate(row):
                if bit == "1":
                    pixels[py * WIDTH + cursor_x + gx] = 47
        cursor_x += 12

    # Draw "/ DEMO" (5x7 glyphs)
    cursor_x += 2
    text_y7 = by0 + 11
    for ch in ("/", " ", "D", "E", "M", "O"):
        if ch == " ":
            cursor_x += 4
            continue
        glyph = GLYPHS_5X7[ch]
        for gy, row in enumerate(glyph):
            py = text_y7 + gy
            for gx, bit in enumerate(row):
                if bit == "1":
                    pixels[py * WIDTH + cursor_x + gx] = 47
        cursor_x += 8


def _png_chunk(chunk_type: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(chunk_type)
    crc = zlib.crc32(data, crc) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + chunk_type + data + struct.pack(">I", crc)


def _encode_indexed_png(
    width: int,
    height: int,
    palette: list[tuple[int, int, int]],
    pixels: bytearray,
) -> bytes:
    """Encode an 8-bit indexed PNG (IHDR color type = 3) deterministically."""
    # IHDR: width, height, bit_depth=8, color_type=3 (indexed), comp=0, filter=0, interlace=0
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 3, 0, 0, 0)
    plte = bytearray()
    for r, g, b in palette:
        plte.extend((r, g, b))

    # Filter type 0 (None) compresses best for indexed-palette PNGs.
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw.extend(pixels[y * width : (y + 1) * width])

    idat = zlib.compress(bytes(raw), level=9)
    return (
        b"\x89PNG\r\n\x1a\n"
        + _png_chunk(b"IHDR", ihdr)
        + _png_chunk(b"PLTE", bytes(plte))
        + _png_chunk(b"IDAT", idat)
        + _png_chunk(b"IEND", b"")
    )


def _render_poster(index: int, spec: dict) -> bytes:
    rng = random.Random(SEED + index * 9973)
    phase = rng.uniform(0.0, math.tau)
    # Deterministic tiled 8x8 film-grain table keeps subtle cinema texture compact in PNG.
    grain_tile = [
        [((rng.getrandbits(4) / 15.0) - 0.5) * 0.004 for _ in range(8)]
        for _ in range(8)
    ]
    palette = _build_palette(spec["colors"])
    pixels = bytearray(WIDTH * HEIGHT)
    ramp_max = 43

    motif = spec["motif"]
    variant = spec["variant"]

    for y in range(HEIGHT):
        ny = y / float(HEIGHT - 1)
        bayer_row = BAYER_4X4[y & 3]
        grain_row = grain_tile[y & 7]
        row_off = y * WIDTH
        for x in range(WIDTH):
            nx = x / float(WIDTH - 1)
            val = _motif_intensity(motif, variant, nx, ny, phase)
            scaled = (val + grain_row[x & 7]) * ramp_max + bayer_row[x & 3] * 0.55
            idx = int(round(scaled))
            if idx < 0:
                idx = 0
            elif idx > ramp_max:
                idx = ramp_max
            pixels[row_off + x] = idx

    # Crisp subtle frame border (1px inside edges)
    for x in range(WIDTH):
        pixels[x] = 45
        pixels[(HEIGHT - 1) * WIDTH + x] = 45
    for y in range(HEIGHT):
        pixels[y * WIDTH] = 45
        pixels[y * WIDTH + (WIDTH - 1)] = 45

    _draw_demo_badge(pixels)
    return _encode_indexed_png(WIDTH, HEIGHT, palette, pixels)


def _inspect_png_ihdr(data: bytes) -> tuple[int, int, int, int]:
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("Invalid PNG signature")
    length, chunk_type = struct.unpack(">I4s", data[8:16])
    if chunk_type != b"IHDR" or length != 13:
        raise ValueError("Missing or malformed IHDR chunk")
    w, h, bit_depth, color_type, _, _, _ = struct.unpack(">IIBBBBB", data[16:29])
    return w, h, bit_depth, color_type


def generate() -> int:
    manifest_items = []
    rendered: dict[str, bytes] = {}

    for idx, spec in enumerate(DEMO_SPECS, start=1):
        filename = f"{spec['id']}.png"
        png_bytes = _render_poster(idx, spec)
        w, h, bit_depth, color_type = _inspect_png_ihdr(png_bytes)
        if (w, h, bit_depth, color_type) != (WIDTH, HEIGHT, 8, 3):
            raise RuntimeError(
                f"{filename}: unexpected IHDR {(w, h, bit_depth, color_type)}"
            )
        if len(png_bytes) > MAX_SINGLE_PNG_BYTES:
            raise RuntimeError(
                f"{filename}: {len(png_bytes)} bytes exceeds {MAX_SINGLE_PNG_BYTES}"
            )
        rendered[filename] = png_bytes
        manifest_items.append(
            {
                "id": spec["id"],
                "file": filename,
                "titleZh": spec["titleZh"],
                "titleEn": spec["titleEn"],
                "subtitleZh": spec["subtitleZh"],
                "subtitleEn": spec["subtitleEn"],
                "categoryZh": spec["categoryZh"],
                "categoryEn": spec["categoryEn"],
                "badgeZh": "示例",
                "badgeEn": "DEMO",
                "specs": spec["specs"],
                "progress": spec["progress"],
                "year": spec["year"],
                "accentHex": spec["accentHex"],
            }
        )

    manifest = {
        "schemaVersion": 1,
        "license": "GPL-3.0-only",
        "seed": SEED,
        "noticeZh": "所有示例海报与条目均为程序化生成的虚构占位内容，仅用于界面引导演示。",
        "noticeEn": "All sample posters and titles are procedurally generated fictional placeholders for UI preview only.",
        "items": manifest_items,
    }
    manifest_bytes = (
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
    ).encode("utf-8")

    for out_dir in OUTPUT_DIRS:
        out_dir.mkdir(parents=True, exist_ok=True)
        for filename, data in rendered.items():
            (out_dir / filename).write_bytes(data)
        (out_dir / "manifest.json").write_bytes(manifest_bytes)

    # Verify both platform directories strictly
    totals = {}
    digests: dict[Path, dict[str, str]] = {}
    for out_dir in OUTPUT_DIRS:
        dir_total = 0
        dir_digests: dict[str, str] = {}
        for filename in sorted(rendered.keys()) + ["manifest.json"]:
            p = out_dir / filename
            raw = p.read_bytes()
            dir_total += len(raw)
            dir_digests[filename] = hashlib.sha256(raw).hexdigest()
            if filename.endswith(".png"):
                w, h, bd, ct = _inspect_png_ihdr(raw)
                assert (w, h, bd, ct) == (WIDTH, HEIGHT, 8, 3)
        if dir_total >= MAX_DIR_TOTAL_BYTES:
            raise RuntimeError(
                f"{out_dir}: total {dir_total} bytes >= {MAX_DIR_TOTAL_BYTES}"
            )
        totals[out_dir] = dir_total
        digests[out_dir] = dir_digests

    # Assert byte-for-byte mirror identity
    base_dir = OUTPUT_DIRS[0]
    for other_dir in OUTPUT_DIRS[1:]:
        if digests[base_dir] != digests[other_dir]:
            raise RuntimeError(f"Mirror mismatch between {base_dir} and {other_dir}")

    print(f"Generated {len(rendered)} indexed PNGs (360x540, 8-bit, IHDR color_type=3) + manifest.json")
    for filename in sorted(rendered.keys()):
        raw = rendered[filename]
        sha = hashlib.sha256(raw).hexdigest()[:12]
        print(f"  {filename}: {len(raw):6d} bytes  color_type=3  sha256={sha}")
    print(f"  manifest.json: {len(manifest_bytes):6d} bytes  sha256={hashlib.sha256(manifest_bytes).hexdigest()[:12]}")
    for out_dir, total in totals.items():
        rel = out_dir.relative_to(ROOT).as_posix()
        print(f"  TOTAL [{rel}]: {total} bytes ({total / 1024.0:.2f} KB < 480 KB)")
    return 0


if __name__ == "__main__":
    sys.exit(generate())
