"""Compile the experimental lxml port in a disposable Linux directory."""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import sysconfig
import urllib.request

from port import HERE, LOCK, digest, prepare


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != 'linux' or sys.version_info[:2] != (3, 14):
        raise RuntimeError('This intermediate probe requires Linux CPython 3.14')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    archive = output / LOCK['file']
    if not archive.exists():
        with urllib.request.urlopen(LOCK['url'], timeout=90) as response:
            archive.write_bytes(response.read(8 * 1024 * 1024))
    source = output / 'source'
    prepare(archive, source)
    # Build directly from the pinned generated C; do not execute upstream
    # setup.py or select an unpinned Cython generator.
    from setuptools import Distribution, Extension
    flags = shlex.split(subprocess.check_output(
        ['pkg-config', '--cflags', 'libxml-2.0', 'libxslt', 'libexslt'], text=True))
    extensions = [Extension('lxml.' + module,
        sources=[str(source / 'src/lxml' / (module + '.c'))],
        include_dirs=[str(source / 'src/lxml/includes'), str(source / 'src/lxml')],
        define_macros=[('MM_LXML_EXPERIMENT', '1')],
        extra_compile_args=flags + ['-std=c11', '-O0', '-g', '-UNDEBUG'],
        libraries=['exslt', 'xslt', 'xml2', 'pthread']) for module in ('etree', 'objectify')]
    dist = Distribution({'name': 'lxml-owner-experiment', 'ext_modules': extensions})
    cmd = dist.get_command_obj('build_ext')
    cmd.build_lib = str(source / 'src')
    cmd.build_temp = str(output / 'objects')
    cmd.ensure_finalized()
    cmd.run()
    compiler = shlex.split(sysconfig.get_config_var('CC'))
    libraries = shlex.split(sysconfig.get_config_var('LIBS') or '')
    libraries += shlex.split(sysconfig.get_config_var('SYSLIBS') or '')
    executable = output / 'owner-probe'
    subprocess.run(compiler + ['-std=c11', '-D_GNU_SOURCE', '-g', '-UNDEBUG',
        '-I' + sysconfig.get_path('include'), str(HERE / 'owner_probe.c'),
        '-L' + sysconfig.get_config_var('LIBDIR'),
        '-Wl,-rpath,' + sysconfig.get_config_var('LIBDIR'),
        '-lpython' + sysconfig.get_python_version(), '-pthread', '-o', str(executable)] + libraries,
        check=True)
    versions = subprocess.check_output(
        ['pkg-config', '--modversion', 'libxml-2.0', 'libxslt', 'libexslt'], text=True).splitlines()
    inputs = {p.name: digest(p.read_bytes()) for p in HERE.iterdir() if p.is_file()}
    (output / 'host-inputs.json').write_text(json.dumps({
        'python': sys.version, 'platform': sys.platform,
        'native_library_versions': versions, 'inputs': inputs,
        'git_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
        'product_enabled': False, 'ios_tested': False,
    }, indent=2) + '\n', encoding='utf-8')
    env = dict(os.environ, PYTHONMALLOC='debug', PYTHONFAULTHANDLER='1')
    with (output / 'execution.log').open('w', encoding='utf-8') as log:
        result = subprocess.run([str(executable), str(source / 'src'),
                                 str(HERE / 'owner_fixture.py')], env=env,
                                stdout=log, stderr=subprocess.STDOUT, timeout=180)
    print((output / 'execution.log').read_text(encoding='utf-8'))
    if result.returncode:
        if shutil.which('gdb'):
            with (output / 'native-backtrace.log').open('w', encoding='utf-8') as log:
                subprocess.run(['gdb', '--batch', '-q', '-ex', 'run',
                    '-ex', 'thread apply all bt 35', '--args', str(executable),
                    str(source / 'src'), str(HERE / 'owner_fixture.py')],
                    env=env, stdout=log, stderr=subprocess.STDOUT, timeout=90)
        raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
