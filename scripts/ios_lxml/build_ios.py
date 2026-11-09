"""Build/stage the isolated lxml experiment with private iOS XML libraries.

This is not imported by the product preparer. Upstream CMake builds only static
native archives; a private framework owns every XML callback and global. The two
generated-C modules link to that framework with Mach-O two-level namespaces.
No host libxml2, setup.py, Cython regeneration or dynamic symbol lookup is used.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
LOCK = json.loads((HERE / "source.lock.json").read_text(encoding="utf-8"))
NATIVE_LOCK = json.loads((HERE / "native-libraries.lock.json").read_text(encoding="utf-8"))
PRIVATE_NAME = "MarcoLxmlNative"
PRIVATE_INSTALL_NAME = "@rpath/" + PRIVATE_NAME + ".framework/" + PRIVATE_NAME
MINIMUM_TARGET = "14.0"

# Keep the native feature set explicit. Programs, native Python bindings and
# loadable native plugins are not needed inside the disposable iOS experiment.
NATIVE_OPTIONS = {
    "BUILD_SHARED_LIBS": "OFF",
    "LIBXML2_WITH_PROGRAMS": "OFF", "LIBXML2_WITH_PYTHON": "OFF",
    "LIBXML2_WITH_TESTS": "OFF", "LIBXML2_WITH_MODULES": "OFF",
    "LIBXML2_WITH_HTTP": "OFF", "LIBXML2_WITH_ICONV": "ON",
    "LIBXML2_WITH_ICU": "OFF", "LIBXML2_WITH_LZMA": "OFF",
    "LIBXML2_WITH_ZLIB": "ON", "LIBXML2_WITH_THREADS": "ON",
    "LIBXML2_WITH_THREAD_ALLOC": "OFF", "LIBXML2_WITH_TLS": "ON",
    "LIBXSLT_WITH_PROGRAMS": "OFF", "LIBXSLT_WITH_PYTHON": "OFF",
    "LIBXSLT_WITH_TESTS": "OFF", "LIBXSLT_WITH_MODULES": "OFF",
    "LIBXSLT_WITH_CRYPTO": "OFF", "LIBXSLT_WITH_THREADS": "ON",
}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def source_inputs():
    paths = [HERE / name for name in ("build_ios.py", "native-libraries.lock.json",
             "port.py", "source.lock.json", "owner_state.h", "native_callbacks.h")]
    paths.append(ROOT / "scripts/ios_cpython/run_cpython_probe.py")
    return {p.relative_to(ROOT).as_posix(): digest(p) for p in paths}


def extract_native(archive, destination, lock):
    """Extract only regular files from the checksum-verified upstream release."""
    if digest(archive) != lock["sha256"]:
        raise ValueError("Native source checksum mismatch: " + lock["name"])
    destination.mkdir(parents=True, exist_ok=False)
    prefix = lock["name"] + "-" + lock["version"]
    total, seen = 0, set()
    with tarfile.open(archive, "r:xz") as package:
        for member in package:
            parts = PurePosixPath(member.name)
            if (not parts.parts or parts.is_absolute() or ".." in parts.parts
                    or "\\" in member.name or ":" in member.name or parts.parts[0] != prefix):
                raise ValueError("Unexpected native archive path")
            if member.isdir():
                continue
            if not member.isfile() or len(parts.parts) < 2:
                raise ValueError("Unexpected native archive member")
            relative = PurePosixPath(*parts.parts[1:]).as_posix()
            total += member.size
            if relative in seen or total > 80 * 1024 * 1024 or len(seen) >= 10000:
                raise ValueError("Unexpected native archive size or duplicate")
            seen.add(relative)
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(package.extractfile(member).read())


def cmake_project():
    # Upstream targets provide the correct generated headers and transitive
    # libxml2 includes to libxslt. No copied source file list can drift silently.
    return """cmake_minimum_required(VERSION 3.18)
project(MarcoLxmlNativeArchives LANGUAGES C)
set(CMAKE_C_STANDARD 11)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/archives")
add_subdirectory(libxml2 xml)
add_subdirectory(libxslt xslt)
"""


def run_logged(command, log_dir, phase, *, timeout=360):
    command = list(map(str, command))
    path = log_dir / (phase + ".log")
    print("lxml build:", phase, flush=True)
    with path.open("w", encoding="utf-8") as log:
        log.write(shlex.join(command) + "\n\n")
        log.flush()
        try:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=timeout)
        except (OSError, subprocess.SubprocessError) as error:
            log.flush()
            tail = path.read_text(encoding="utf-8", errors="replace")[-14000:]
            raise RuntimeError("lxml " + phase + " failed; log: " + str(path)
                               + "\n" + tail) from error
    return path


def framework_binary(app, name, identifier, target, version):
    folder = app / "Frameworks" / (name + ".framework")
    folder.mkdir(exist_ok=False)
    info = {"CFBundleIdentifier": identifier + "." + name.replace("_", "-"),
            "CFBundleExecutable": name, "CFBundleName": name,
            "CFBundlePackageType": "FMWK", "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleVersion": "1", "CFBundleShortVersionString": version,
            "MinimumOSVersion": MINIMUM_TARGET,
            "CFBundleSupportedPlatforms": ["iPhoneOS" if target == "device" else "iPhoneSimulator"]}
    (folder / "Info.plist").write_bytes(plistlib.dumps(info))
    return folder / name


def inspect_binary(binary, app, log_dir, *, is_extension):
    """Fail if any XML import resolves to system/Mpv/flat-namespace symbols."""
    inspections = {}
    for name, args in (("dependencies", ["otool", "-L"]),
                       ("header", ["otool", "-hv"]),
                       ("imports", ["nm", "-m", "-u"])):
        log = run_logged(["xcrun", *args, binary], log_dir, binary.name + "-" + name)
        # The first line is the logged command, not tool output.
        inspections[name] = log.read_text(encoding="utf-8").split("\n\n", 1)[1]
    if "TWOLEVEL" not in inspections["header"]:
        raise ValueError("lxml framework is missing two-level namespace: " + binary.name)
    dependencies = [line.strip().split(" (compatibility version", 1)[0]
                    for line in inspections["dependencies"].splitlines()[1:] if line.strip()]
    install_name = "@rpath/" + binary.parent.name + "/" + binary.name
    if not dependencies or dependencies[0] != install_name:
        raise ValueError("Unexpected framework install name: " + binary.name)
    dependencies = dependencies[1:]
    allowed = {"/usr/lib/libSystem.B.dylib", "/usr/lib/libiconv.2.dylib", "/usr/lib/libz.1.dylib"}
    if is_extension:
        required = {PRIVATE_INSTALL_NAME, "@rpath/Python.framework/Python"}
        if not required <= set(dependencies):
            raise ValueError("lxml extension does not link both private XML and Python frameworks")
        allowed |= required
    if set(dependencies) - allowed:
        raise ValueError("Unreviewed lxml native dependency: " + repr(dependencies))
    xml_imports, python_imports = 0, 0
    for line in inspections["imports"].splitlines():
        symbol = re.search(r"external\s+(_+[A-Za-z][A-Za-z0-9_]*)", line)
        if not symbol:
            continue
        name = symbol.group(1).lstrip("_")
        if name.startswith(("xml", "html", "xslt", "exslt")):
            xml_imports += 1
            if not is_extension or "(from " + PRIVATE_NAME + ")" not in line:
                raise ValueError("XML symbol escaped private framework: " + line)
        if name.startswith("Py"):
            python_imports += 1
            if not is_extension or "(from Python)" not in line:
                raise ValueError("Python symbol has unexpected owner: " + line)
        if "dynamically looked up" in line or "flat namespace" in line:
            raise ValueError("Dynamic lookup is forbidden for lxml: " + line)
    if is_extension and (not xml_imports or not python_imports):
        raise ValueError("Could not verify lxml XML/Python import provenance")
    return {"framework": binary.relative_to(app).as_posix(), "sha256": digest(binary),
            "bytes": binary.stat().st_size, "dependencies": dependencies,
            "two_level_namespace": True, "private_xml_imports": xml_imports,
            "python_framework_imports": python_imports}


def stage_package(source, app):
    package = app / "app_packages/lxml"
    if package.exists():
        raise ValueError("lxml package already staged")
    # All .py files and runtime resources are copied byte-for-byte. Cython/C
    # development inputs stay in the build directory, not the app payload.
    shutil.copytree(source / "src/lxml", package, ignore=shutil.ignore_patterns(
        "*.c", "*.h", "*.pyx", "*.pxd", "*.pxi", "__pycache__", "*.pyc"))
    for path in (source / "src/lxml").rglob("*.py"):
        if digest(path) != digest(package / path.relative_to(source / "src/lxml")):
            raise ValueError("Staged lxml Python source changed")
    licenses = package / "licenses"
    shutil.copytree(source / "doc/licenses", licenses)
    for name in ("LICENSE.txt", "LICENSES.txt"):
        shutil.copyfile(source / name, package / name)
    return package


def stage(app: Path, cache: Path, *, target: str, arch: str,
          identifier: str, log_dir: Path) -> dict:
    if sys.platform != "darwin":
        raise RuntimeError("iOS lxml builds require macOS with Apple's compiler")
    if (target not in {"device", "simulator"} or arch not in {"arm64", "x86_64"}
            or target == "device" and arch != "arm64"):
        raise ValueError("Unsupported iOS lxml target")
    app, cache, log_dir = app.resolve(), cache.resolve(), log_dir.resolve()
    python_headers = app / "Frameworks/Python.framework/Headers"
    if not (python_headers / "Python.h").is_file() or not (app / "app_packages").is_dir():
        raise ValueError("Stage the Python runtime and headers before lxml")
    cache.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)
    native = load_module("lxml_ios_download", ROOT / "scripts/ios_cpython/run_cpython_probe.py")
    port = load_module("lxml_ios_port", HERE / "port.py")
    archive = native.download_verified(LOCK["url"], cache / LOCK["file"], LOCK["sha256"])
    native_archives = {lock["name"]: native.download_verified(
        lock["url"], cache / lock["file"], lock["sha256"]) for lock in NATIVE_LOCK["libraries"]}
    sdk = "iphoneos" if target == "device" else "iphonesimulator"
    triple = arch + "-apple-ios" + MINIMUM_TARGET + ("-simulator" if target == "simulator" else "")
    sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
    compiler = subprocess.check_output(["xcrun", "--sdk", sdk, "--find", "clang"], text=True).strip()
    flags = ["-target", triple, "-isysroot", sdk_path, "-dynamiclib", "-O2",
             "-std=c11", "-UNDEBUG", "-Wl,-twolevel_namespace", "-Wl,-undefined,error"]
    frameworks, modules = [], []
    with tempfile.TemporaryDirectory(prefix="ios-lxml-", dir=cache) as temp:
        work = Path(temp)
        source, native_source, build = work / "lxml", work / "native", work / "build"
        port_report = port.prepare(archive, source)
        (log_dir / "port-manifest.json").write_text(json.dumps(port_report, indent=2) + "\n", encoding="utf-8")
        for lock in NATIVE_LOCK["libraries"]:
            extract_native(native_archives[lock["name"]], native_source / lock["name"], lock)
        (native_source / "CMakeLists.txt").write_text(cmake_project(), encoding="utf-8")
        configure = ["cmake", "-S", native_source, "-B", build, "-G", "Unix Makefiles",
                     "-DCMAKE_SYSTEM_NAME=iOS", "-DCMAKE_OSX_SYSROOT=" + sdk_path,
                     "-DCMAKE_OSX_ARCHITECTURES=" + arch, "-DCMAKE_OSX_DEPLOYMENT_TARGET=" + MINIMUM_TARGET,
                     "-DCMAKE_C_COMPILER=" + compiler, "-DCMAKE_C_COMPILER_TARGET=" + triple,
                     "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_C_FLAGS_RELEASE=-O2 -UNDEBUG",
                     "-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY", "-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY",
                     "-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY", "-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER",
                     "-DIconv_INCLUDE_DIR=" + str(Path(sdk_path) / "usr/include"),
                     "-DIconv_LIBRARY=" + str(Path(sdk_path) / "usr/lib/libiconv.tbd"),
                     "-DZLIB_INCLUDE_DIR=" + str(Path(sdk_path) / "usr/include"),
                     "-DZLIB_LIBRARY=" + str(Path(sdk_path) / "usr/lib/libz.tbd"),
                     *["-D" + key + "=" + value for key, value in NATIVE_OPTIONS.items()]]
        run_logged(configure, log_dir, "configure-native")
        run_logged(["cmake", "--build", build, "--target", "LibXml2", "LibXslt", "LibExslt",
                    "--parallel", str(min(os.cpu_count() or 2, 8))], log_dir, "build-native", timeout=600)
        private = framework_binary(app, PRIVATE_NAME, identifier, target, "1.0")
        static = [build / "archives" / name for name in ("libxml2.a", "libxslt.a", "libexslt.a")]
        for path in static:
            if not path.is_file():
                raise ValueError("Missing upstream static archive: " + str(path))
        run_logged([compiler, *flags, "-install_name", PRIVATE_INSTALL_NAME,
                    *[arg for path in static for arg in ("-Xlinker", "-force_load", "-Xlinker", str(path))],
                    "-liconv", "-lz", "-o", private], log_dir, "link-private-native")
        frameworks.append(inspect_binary(private, app, log_dir, is_extension=False))
        package = stage_package(source, app)
        for lock in NATIVE_LOCK["libraries"]:
            shutil.copyfile(native_source / lock["name"] / lock["license_file"],
                            package / "licenses" / (lock["name"] + "-Copyright.txt"))
        includes = [python_headers, source / "src/lxml", source / "src/lxml/includes",
                    build / "xml", native_source / "libxml2/include",
                    build / "xslt", native_source / "libxslt"]
        for module in ("etree", "objectify"):
            name = "lxml." + module
            binary = framework_binary(app, name, identifier, target, LOCK["version"])
            command = [compiler, *flags, "-DMM_LXML_EXPERIMENT=1",
                       *[arg for path in includes for arg in ("-I", str(path))],
                       "-F", app / "Frameworks", "-framework", PRIVATE_NAME, "-framework", "Python",
                       "-install_name", "@rpath/" + name + ".framework/" + name,
                       "-Wl,-rpath,@loader_path/..", source / "src/lxml" / (module + ".c"), "-o", binary]
            run_logged(command, log_dir, "compile-" + module, timeout=600)
            marker = package / (module + ".fwork")
            marker.write_text(binary.relative_to(app).as_posix() + "\n", encoding="utf-8")
            (binary.parent / (name + ".origin")).write_text(marker.relative_to(app).as_posix() + "\n", encoding="utf-8")
            record = inspect_binary(binary, app, log_dir, is_extension=True)
            record.update(name=name, marker=marker.relative_to(app).as_posix(),
                          generated_c_sha256=digest(source / "src/lxml" / (module + ".c")))
            modules.append(record)
            frameworks.append(record)
        native_static = {path.name: digest(path) for path in static}
    report = {"experimental": True, "product_enabled": False, "source": LOCK,
              "native_libraries": NATIVE_LOCK["libraries"], "inputs": source_inputs(),
              "target": target, "architecture": arch, "minimum_target": MINIMUM_TARGET,
              "compiler_target": triple, "native_options": NATIVE_OPTIONS,
              "private_native_framework": PRIVATE_NAME, "native_static_archives": native_static,
              "frameworks": frameworks, "modules": modules, "port": port_report,
              "isolation": {"two_level_namespace": True, "private_xml_imports_verified": True,
                            "system_libxml2_linked": False, "dynamic_lookup": False},
              "package_files": {p.relative_to(app).as_posix(): digest(p)
                                for p in sorted(package.rglob("*")) if p.is_file()},
              "runtime_tested": False, "physical_device_tested": False}
    (app / "lxml-runtime-manifest.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--target", choices=("device", "simulator"), required=True)
    parser.add_argument("--arch", choices=("arm64", "x86_64"), required=True)
    parser.add_argument("--logs", type=Path, required=True)
    parser.add_argument("--identifier", default="com.pilipala.experimental.lxml")
    args = parser.parse_args()
    result = stage(args.app, args.cache, target=args.target, arch=args.arch,
                   identifier=args.identifier, log_dir=args.logs)
    print(json.dumps({"frameworks": len(result["frameworks"]), "architecture": args.arch}))
