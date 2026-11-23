"""Dispatcher for the completely independent Android TV and Android Mobile builds.

Prefer invoking the dedicated scripts directly:
  python -X utf8 scripts/build_android_tv.py      # Android TV (android-tv/)
  python -X utf8 scripts/build_android_mobile.py  # Android Mobile (android-mobile/)
"""
import argparse
import os

from android_build_common import ANDROID, DIST, ENV, JDK, ROOT, SDK, exe, run  # noqa: F401

# Default BUILD alias retained for TV probe helpers; Mobile probes use android-mobile/build.
BUILD = ROOT / 'android-tv/build'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        '--edition',
        choices=('tv', 'mobile', 'all'),
        default=os.environ.get('MARCOMOVIE_ANDROID_EDITION', 'all').strip().lower() or 'all',
        help='Which independent Android edition to build (default: all).',
    )
    args = parser.parse_args()
    if args.edition in ('tv', 'all'):
        import build_android_tv
        build_android_tv.main()
    if args.edition in ('mobile', 'all'):
        import build_android_mobile
        build_android_mobile.main()


if __name__ == '__main__':
    main()
