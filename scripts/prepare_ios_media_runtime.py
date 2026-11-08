"""Prefetch the locked media-kit iOS framework and fail before Xcode on errors."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urljoin, urlsplit
from urllib.request import url2pathname

PACKAGE = 'media_kit_libs_ios_video'
VERSION = 'v0.6.0'
SHA256 = 'a95bc18508af26136b8a408341c05b5585d644ec013f00ac07db09d2e28d36ae'
ASSET = 'libmpv-xcframeworks_' + VERSION + '_ios-universal-video-default.tar.gz'
CACHED = 'libmpv-xcframeworks-' + VERSION + '-ios-universal.tar.gz'


def package_directory(config):
    entries = json.loads(config.read_text(encoding='utf-8'))['packages']
    matches = [entry for entry in entries if entry.get('name') == PACKAGE]
    if len(matches) != 1:
        raise ValueError('Expected the locked iOS media-kit package')
    url = urlsplit(urljoin(config.resolve().as_uri(), matches[0]['rootUri']))
    if url.scheme != 'file' or url.netloc:
        raise ValueError('Media-kit package must resolve to a local directory')
    ios = Path(url2pathname(url.path)).resolve() / 'ios'
    make = (ios / 'Makefile').read_text(encoding='utf-8')
    for line in ('MPV_XCFRAMEWORKS_VERSION=' + VERSION, 'MPV_XCFRAMEWORKS_SHA256SUM=' + SHA256):
        if line not in make.splitlines():
            raise ValueError('Media-kit native lock changed; review the upstream inputs')
    return ios


def prepare(config):
    if sys.platform != 'darwin':
        raise RuntimeError('The iOS media framework preparation requires macOS')
    ios = package_directory(config)
    cache = ios / '.cache/xcframeworks'
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / CACHED
    if target.exists():
        if hashlib.sha256(target.read_bytes()).hexdigest() != SHA256:
            raise ValueError('Cached media-kit framework checksum mismatch')
    else:
        with tempfile.TemporaryDirectory(prefix='verified-media-', dir=cache) as temp:
            subprocess.run(['gh', 'release', 'download', VERSION, '--repo', 'media-kit/libmpv-darwin-build',
                            '--pattern', ASSET, '--dir', temp], check=True, timeout=240)
            source = Path(temp) / ASSET
            if hashlib.sha256(source.read_bytes()).hexdigest() != SHA256:
                raise ValueError('Downloaded media-kit framework checksum mismatch')
            shutil.copyfile(source, target)
    # The upstream podspec ignores system("make")'s failure. Run the reviewed
    # Makefile first with a required success result and an already verified cache.
    subprocess.run(['make'], cwd=ios, check=True, timeout=180)
    framework = ios / 'Frameworks/Mpv.xcframework'
    metadata = plistlib.loads((framework / 'Info.plist').read_bytes())
    device = [entry for entry in metadata['AvailableLibraries']
              if entry.get('SupportedPlatform') == 'ios' and not entry.get('SupportedPlatformVariant')
              and 'arm64' in entry.get('SupportedArchitectures', [])]
    if len(device) != 1:
        raise ValueError('Media-kit iPhone framework slice is missing')
    binary = (framework / device[0]['LibraryIdentifier'] / device[0]['LibraryPath'] / 'Mpv').resolve()
    if not binary.is_relative_to(framework.resolve()) or not binary.is_file():
        raise ValueError('Media-kit iPhone executable is missing')
    print('Pinned iOS media framework verified and prepared')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package-config', type=Path, required=True)
    prepare(parser.parse_args().package_config)
