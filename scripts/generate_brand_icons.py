"""Synchronize derived brand icon frames from the platform brand kit masters.

Run only when brand kit artwork changes, with Pillow installed.
The resulting PNG files are checked in, so CI builds do not need Pillow.
"""
import shutil
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]

# Windows: derive intermediate 125% scaling frames (20px, 40px) from optical masters.
win_dir = ROOT / 'flutter/brand/windows'
win_24 = win_dir / '24.png'
win_64 = win_dir / '64.png'
if win_24.exists() and win_64.exists():
    Image.open(win_24).convert('RGBA').resize((20, 20), Image.Resampling.LANCZOS).save(win_dir / '20.png')
    Image.open(win_64).convert('RGBA').resize((40, 40), Image.Resampling.LANCZOS).save(win_dir / '40.png')

# iOS & docs: keep opaque 512px store/web preview synced with 1024px opaque iOS master.
ios_master = ROOT / 'flutter/brand/ios/1024.png'
if ios_master.exists():
    Image.open(ios_master).convert('RGB').resize((512, 512), Image.Resampling.LANCZOS).save(
        ROOT / 'docs/images/app-icon-512.png'
    )

# Android TV, Android Mobile & Lite: sync legacy mipmap ic_launcher.png from mm_launcher.png.
for density in ('mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi'):
    mm_launcher = ROOT / 'android-mobile/src/main/res' / f'mipmap-{density}' / 'mm_launcher.png'
    if mm_launcher.exists():
        for dst_root in (ROOT / 'android-mobile/src/main/res', ROOT / 'android-tv/src/main/res', ROOT / 'lite/src/main/res'):
            folder = dst_root / f'mipmap-{density}'
            folder.mkdir(parents=True, exist_ok=True)
            shutil.copy2(mm_launcher, folder / 'ic_launcher.png')
