"""Validate the real Windows installer script and compile with a tiny fixture when ISCC is available."""
from pathlib import Path
import argparse
import hashlib
import shutil
import struct
import tempfile
import zipfile

from platform_package_names import (
    clear_names,
    find_inno_setup_compiler,
    rebuild_windows_setup_if_runner_present,
    windows_installer_script,
)


def validate_installer_script() -> None:
    rendered = windows_installer_script('0.0.0', 'MarcoMovie-0.0.0-windows-setup')
    assert '{#' not in rendered, 'Unresolved Inno Setup macro placeholder remains'
    assert 'AppId={{8E9A5D2B-4F31-4C19-9A62-7B8D1E3F4A50}' in rendered
    assert 'UsePreviousAppDir=yes' in rendered
    assert 'Type: filesandordirs; Name: "{app}\\data\\flutter_assets"' in rendered
    assert 'Type: filesandordirs; Name: "{app}\\data\\python"' in rendered, (
        'Missing {app}\\data\\python cleanup entry in [InstallDelete]'
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--compiler', required=False, default=None)
    args = parser.parse_args()
    validate_installer_script()

    compiler_path: Path | None = None
    if args.compiler:
        compiler_path = Path(args.compiler)
        if not compiler_path.is_file():
            raise FileNotFoundError(f'Specified Inno Setup compiler not found: {compiler_path}')
    else:
        compiler_path = find_inno_setup_compiler()

    repo = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='marco-installer-preflight-') as name:
        work = Path(name).resolve()
        assert work.is_relative_to(Path(tempfile.gettempdir()).resolve())
        source = work / 'flutter/build/windows/x64/runner/Release'
        source.mkdir(parents=True)
        (source / 'marco_movie.exe').write_text('Compiler validation fixture only; never execute.', encoding='utf-8')
        installer = work / 'flutter/installer'
        installer.mkdir()
        shutil.copy2(repo / 'flutter/installer/ChineseSimplified.isl', installer)
        resources = work / 'flutter/windows/runner/resources'
        resources.mkdir(parents=True)
        output = work / 'flutter/dist'
        output.mkdir()
        # Use the approved brand frames, without relying on a generated runner.
        frames = [(size, (repo / f'flutter/brand/windows/{size}.png').read_bytes())
                  for size in (16, 32, 48, 256)]
        offset = 6 + 16 * len(frames)
        directory = bytearray(struct.pack('<HHH', 0, 1, len(frames)))
        for size, data in frames:
            directory += struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0,
                                     1, 32, len(data), offset)
            offset += len(data)
        icon = source / 'MarcoMovie-0.0.0.ico'
        icon.write_bytes(directory + b''.join(data for _, data in frames))
        shutil.copy2(icon, resources / 'app_icon.ico')
        portable = output / 'MarcoMovie-0.0.0-windows-x64.zip'
        with zipfile.ZipFile(portable, 'w') as package:
            package.write(source / 'marco_movie.exe', 'marco_movie.exe')
            package.write(icon, icon.name)
        digest = hashlib.sha256(portable.read_bytes()).hexdigest()
        portable.with_suffix('.zip.sha256').write_text(digest + '  ' + portable.name)

        if compiler_path is None:
            print('Windows installer script validated (including {app}\\data\\python cleanup); ISCC not installed so compilation was skipped.')
            return

        assert rebuild_windows_setup_if_runner_present(output, '0.0.0', str(compiler_path))
        aliases = clear_names(output, '0.0.0', 'windows')
        assert len(aliases) == 2 and all(path.is_file() for path in aliases)
        assert aliases[0].read_bytes() == (output / 'MarcoMovie-0.0.0-windows-setup.exe').read_bytes()
    print('Windows installer script compiled successfully; fixture removed.')


if __name__ == '__main__':
    main()
