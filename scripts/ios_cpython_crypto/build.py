"""Build the pinned upstream Crypto package for iOS without host-CPU detection.

The source's static Extension declarations supply the complete portable native
library set. No setup.py execution, dependency install or source substitution is
performed. Optional CPU-specific implementations are omitted, as permitted by
upstream's compiler_opt.py; every public algorithm keeps its portable backend.
"""
import argparse
import ast
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
LOCK = json.loads((HERE / "source.lock.json").read_text(encoding="utf-8"))
OPTIONAL = frozenset({
    "Crypto.Hash._SHA224_shani", "Crypto.Hash._SHA256_shani",
    "Crypto.Hash._SHA224_armv8", "Crypto.Hash._SHA256_armv8",
    "Crypto.Hash._SHA384_armv8", "Crypto.Hash._SHA512_armv8",
    "Crypto.Hash._keccak_avx2_bmi2", "Crypto.Hash._k12_avx2_bmi2",
    "Crypto.Hash._ghash_clmul", "Crypto.Hash._ghash_pmull",
    "Crypto.Cipher._raw_aesni", "Crypto.Cipher._raw_aes_armv8",
    "Crypto.Cipher._Salsa20_avx2_bmi2", "Crypto.Cipher._chacha20_avx2_bmi2",
    "Crypto.PublicKey._ec_nat_bmi2_adx", "Crypto.PublicKey._mldsa_avx2_bmi2",
    "Crypto.PublicKey._mlkem_avx2_bmi2", "Crypto.Math._nat_bmi2_adx",
})


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def source_inputs():
    return {p.relative_to(ROOT).as_posix(): digest(p) for p in
            [Path(__file__).resolve(), HERE / "source.lock.json", HERE / "ios_loader.py"]}


def extract(archive, destination):
    if digest(archive) != LOCK["sha256"]:
        raise ValueError("Crypto source archive checksum mismatch")
    total = 0
    seen = set()
    prefix = LOCK["file"].removesuffix(".tar.gz")
    with tarfile.open(archive, "r:gz") as package:
        for member in package:
            parts = PurePosixPath(member.name)
            if (parts.is_absolute() or ".." in parts.parts or "\\" in member.name
                    or ":" in member.name or not parts.parts or parts.parts[0] != prefix):
                raise ValueError("Unsafe crypto archive path")
            if member.isdir():
                continue
            if not member.isfile():
                raise ValueError("Unexpected crypto archive link")
            relative = Path(*parts.parts[1:])
            if not relative.parts or relative.as_posix() in seen:
                raise ValueError("Duplicate crypto archive member")
            seen.add(relative.as_posix())
            total += member.size
            if total > 40 * 1024 * 1024 or len(seen) > 5000:
                raise ValueError("Crypto source exceeds extraction budget")
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(package.extractfile(member).read())


def build_plan(source):
    tree = ast.parse((source / "setup.py").read_text(encoding="utf-8"))
    declarations = [n.value for n in tree.body if isinstance(n, ast.Assign)
                    and any(isinstance(t, ast.Name) and t.id == "ext_modules" for t in n.targets)]
    if len(declarations) != 1 or not isinstance(declarations[0], ast.List):
        raise ValueError("Expected the pinned static crypto extension list")
    modules = {}
    for call in declarations[0].elts:
        if not isinstance(call, ast.Call) or not isinstance(call.func, ast.Name) or call.func.id != "Extension" or len(call.args) != 1:
            raise ValueError("Unsupported crypto extension declaration")
        name = ast.literal_eval(call.args[0])
        values = {k.arg: ast.literal_eval(k.value) for k in call.keywords}
        if (not isinstance(name, str) or not re.fullmatch(r"Crypto\.[A-Za-z_]+\.[A-Za-z0-9_]+", name)
                or name in modules or set(values) - {"sources", "include_dirs", "py_limited_api"}
                or values.get("py_limited_api") is not True):
            raise ValueError("Unreviewed crypto extension options")
        files = values.get("sources")
        if not isinstance(files, list) or not files:
            raise ValueError("Crypto extension has no source")
        for filename in files + values.get("include_dirs", []):
            if not isinstance(filename, str) or not re.fullmatch(r"src/[A-Za-z0-9_./]*", filename) or ".." in PurePosixPath(filename).parts:
                raise ValueError("Crypto compile path escapes source")
            if not (source / filename).exists():
                raise ValueError("Missing crypto compile input")
        modules[name] = files
    if not OPTIONAL <= modules.keys():
        raise ValueError("Pinned crypto accelerator inventory changed")
    return {name: files for name, files in modules.items() if name not in OPTIONAL}


def stage(app, cache, *, target, arch, identifier, log_dir):
    if sys.platform != "darwin":
        raise RuntimeError("iOS crypto builds require Apple's compiler")
    if target not in {"device", "simulator"} or arch not in {"arm64", "x86_64"} or target == "device" and arch != "arm64":
        raise ValueError("Unsupported crypto target")
    spec = importlib.util.spec_from_file_location("crypto_download", ROOT / "scripts/ios_cpython/run_cpython_probe.py")
    native = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(native)
    archive = native.download_verified(LOCK["url"], cache / LOCK["file"], LOCK["sha256"])
    sdk = "iphoneos" if target == "device" else "iphonesimulator"
    triple = arch + "-apple-ios14.0" + ("-simulator" if target == "simulator" else "")
    sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
    compiler = subprocess.check_output(["xcrun", "--sdk", sdk, "--find", "clang"], text=True).strip()
    flags = ["-target", triple, "-isysroot", sdk_path, "-dynamiclib", "-O2", "-std=c11",
             "-DHAVE_STDINT_H", "-DPYCRYPTO_LITTLE_ENDIAN", "-DSYS_BITS=64", "-DHAVE_UINT128",
             "-DHAVE_POSIX_MEMALIGN", "-DNO_CPYTHON_MODULE"]
    if arch == "x86_64":
        flags.append("-DHAVE_CPUID_H")
    log_dir.mkdir(parents=True, exist_ok=True)
    records = []
    with tempfile.TemporaryDirectory(prefix="ios-crypto-", dir=cache) as temp:
        source = Path(temp)
        extract(archive, source)
        plan = build_plan(source)
        for name, sources in plan.items():
            framework = app / "Frameworks" / (name + ".framework")
            framework.mkdir(parents=True, exist_ok=False)
            binary = framework / name
            command = [compiler, *flags, "-I", str(source / "src"),
                       "-install_name", "@rpath/" + name + ".framework/" + name,
                       *[str(source / file) for file in sources], "-o", str(binary)]
            with (log_dir / (name + ".log")).open("wb") as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
            info = {"CFBundleIdentifier": identifier + "." + name.replace("_", "-"),
                    "CFBundleExecutable": name, "CFBundleName": name, "CFBundlePackageType": "FMWK",
                    "CFBundleInfoDictionaryVersion": "6.0", "CFBundleVersion": "1",
                    "CFBundleShortVersionString": LOCK["version"], "MinimumOSVersion": "14.0",
                    "CFBundleSupportedPlatforms": ["iPhoneOS" if target == "device" else "iPhoneSimulator"]}
            (framework / "Info.plist").write_bytes(plistlib.dumps(info))
            records.append({"name": name, "sources": sources, "framework": binary.relative_to(app).as_posix(),
                            "sha256": digest(binary), "bytes": binary.stat().st_size})
        package = app / "app_packages/Crypto"
        if package.exists():
            raise ValueError("Crypto package already staged")
        shutil.copytree(source / "lib/Crypto", package, ignore=shutil.ignore_patterns("SelfTest", "__pycache__", "*.pyc"))
        raw = package / "Util/_raw_api.py"
        code = raw.read_text(encoding="utf-8")
        needle = '    split = name.split(".")\n'
        if code.count(needle) != 1:
            raise ValueError("Pinned raw library loader changed")
        code = code.replace(needle, '    if sys.platform == "ios":\n        from Crypto.Util._ios_loader import load_native\n        return load_native(name, cdecl, load_lib)\n\n' + needle)
        raw.write_text(code, encoding="utf-8")
        shutil.copyfile(HERE / "ios_loader.py", package / "Util/_ios_loader.py")
        (package / "Util/_ios_modules.json").write_text(json.dumps({r["name"]: r["framework"] for r in records}, indent=2)+"\n", encoding="utf-8")
        shutil.copyfile(source / "LICENSE.rst", package / "LICENSE.rst")
    report = {"source": LOCK, "inputs": source_inputs(), "target": target, "architecture": arch,
              "minimum_target": "14.0", "backend": "upstream-portable-c", "frameworks": records,
              "optional_accelerators_omitted": sorted(OPTIONAL), "self_tests_bundled": False,
              "package_files": {p.relative_to(app).as_posix(): digest(p) for p in sorted(package.rglob("*")) if p.is_file()}}
    (app / "crypto-runtime-manifest.json").write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--target", choices=("device", "simulator"), required=True)
    parser.add_argument("--arch", choices=("arm64", "x86_64"), required=True)
    parser.add_argument("--logs", type=Path, required=True)
    args = parser.parse_args()
    result = stage(args.app.resolve(), args.cache.resolve(), target=args.target, arch=args.arch,
                   identifier="com.pilipala.marcomovie.crypto", log_dir=args.logs.resolve())
    print(json.dumps({"modules": len(result["frameworks"]), "architecture": args.arch}))
