"""Exercise staging integrity and embedding boundaries without Apple tooling."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("ios_python_packaging", Path(__file__).with_name("prepare_ios_python_runtime.py"))
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PackagingTests(unittest.TestCase):
    def test_input_manifest_paths_are_canonical_repository_paths(self):
        for name in package.source_inputs():
            self.assertNotIn('..', Path(name).parts)
            self.assertFalse(Path(name).is_absolute())

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.stage = self.root / "stage"
        for name in ("python", "app", "app_packages", "Frameworks/Python.framework/Headers"):
            (self.stage / "bundle" / name).mkdir(parents=True, exist_ok=True)
        (self.stage / "bundle/app/native_source_entry.py").write_text("owned = True\n")
        (self.stage / "bundle/Frameworks/Python.framework/Headers/Python.h").write_text("header")
        self.crypto_binary = self.stage / "bundle/Frameworks/Crypto.Cipher._raw_aes.framework/Crypto.Cipher._raw_aes"
        self.crypto_binary.parent.mkdir(parents=True)
        self.crypto_binary.write_bytes(b"owned crypto test artifact")
        crypto_package = self.stage / "bundle/app_packages/Crypto"
        crypto_package.mkdir(parents=True)
        (crypto_package / "LICENSE.rst").write_text("owned license fixture")
        self.lxml_files = {
            "Frameworks/MarcoLxmlNative.framework/MarcoLxmlNative": b"owned private XML artifact",
            "app_packages/lxml/__init__.py": b"# owned package fixture\n",
            "app_packages/lxml/LICENSE.txt": b"owned lxml license",
            "app_packages/lxml/licenses/libxml2-Copyright.txt": b"owned XML license",
            "app_packages/lxml/licenses/libxslt-Copyright.txt": b"owned XSLT license",
        }
        for module in ("etree", "objectify"):
            binary = "Frameworks/lxml." + module + ".framework/lxml." + module
            marker = "app_packages/lxml/" + module + ".fwork"
            self.lxml_files[binary] = ("owned " + module + " artifact").encode()
            self.lxml_files[marker] = (binary + "\n").encode()
            self.lxml_files[binary + ".origin"] = (marker + "\n").encode()
        for name, data in self.lxml_files.items():
            path = self.stage / "bundle" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.lxml_report = {"private_native_framework": "MarcoLxmlNative", "target": "simulator", "architecture": "arm64",
                            "product_enabled": False, "runtime_tested": False, "physical_device_tested": False}
        self.report = {"inputs": package.source_inputs(), "files": package.files_digest(self.stage / "bundle"),
                       "runtime": {"lxml": self.lxml_report}}
        (self.stage / "prepared.json").write_text(json.dumps(self.report))
        self.app = self.root / "Runner.app"
        self.app.mkdir()
        (self.app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "test.product"}))
        (self.app / "Runner").write_bytes(b"owned-application")

    def test_embedding_preserves_application_and_removes_headers(self):
        before = (self.app / "Info.plist").read_bytes()
        package.embed(self.stage, self.app)
        self.assertEqual((self.app / "Info.plist").read_bytes(), before)
        self.assertEqual((self.app / "Runner").read_bytes(), b"owned-application")
        self.assertTrue((self.app / "app/native_source_entry.py").exists())
        self.assertFalse((self.app / "Frameworks/Python.framework/Headers").exists())
        self.assertEqual((self.app / self.crypto_binary.relative_to(self.stage / "bundle")).read_bytes(), self.crypto_binary.read_bytes())
        self.assertEqual((self.app / "app_packages/Crypto/LICENSE.rst").read_text(), "owned license fixture")
        for name, data in self.lxml_files.items():
            self.assertEqual((self.app / name).read_bytes(), data)
        embedded = json.loads((self.app / "python-runtime-manifest.json").read_text())
        self.assertEqual(embedded["runtime"]["lxml"], self.lxml_report)

    def test_prepare_stages_lxml_and_reuses_integrity_checked_cache(self):
        stage = self.root / "new-stage"
        frameworks = self.root / "link"
        cache = self.root / "cache"

        def stage_python(bundle, target, arch, _cache, **_kwargs):
            for name in ("python", "app", "app_packages", "Frameworks/Python.framework/Headers"):
                (bundle / name).mkdir(parents=True)
            (bundle / "Frameworks/Python.framework/Headers/Python.h").write_text("header")
            return {"target": target, "architecture": arch}

        def stage_lxml(bundle, _cache, **_kwargs):
            self.assertTrue((bundle / "Frameworks/Python.framework/Headers/Python.h").is_file())
            for name, data in self.lxml_files.items():
                path = bundle / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            return self.lxml_report

        with patch.object(package.native, "stage", side_effect=stage_python), \
             patch.object(package.crypto, "stage", return_value={}), \
             patch.object(package.lxml, "stage", side_effect=stage_lxml) as build:
            first = package.prepare(stage, frameworks, cache, "simulator", "arm64")
            self.assertEqual(first["runtime"]["lxml"], self.lxml_report)
            self.assertIs(first["runtime"]["lxml"]["product_enabled"], True)
            self.assertIs(first["runtime"]["lxml"]["runtime_tested"], False)
            self.assertIs(first["runtime"]["lxml"]["physical_device_tested"], False)
            self.assertEqual(package.prepare(stage, frameworks, cache, "simulator", "arm64"), first)
            build.assert_called_once_with(stage / "bundle", cache, target="simulator", arch="arm64",
                                          identifier="com.pilipala.marcomovie.lxml", log_dir=stage / "lxml-logs")

    def test_missing_or_changed_lxml_files_cannot_produce_a_partial_package(self):
        for name, data in self.lxml_files.items():
            path = self.stage / "bundle" / name
            for changed in (False, True):
                with self.subTest(file=name, changed=changed):
                    if changed:
                        path.write_bytes(data + b"changed")
                    else:
                        path.unlink()
                    with self.assertRaisesRegex(ValueError, "stage changed"):
                        package.embed(self.stage, self.app)
                    self.assertFalse((self.app / "app_packages").exists())
                    self.assertFalse((self.app / "Frameworks").exists())
                    path.write_bytes(data)

    def test_changed_lxml_build_input_invalidates_cached_stage(self):
        inputs = package.lxml.source_inputs()
        inputs["scripts/ios_lxml/owner_state.h"] = "changed-owner-input"
        with patch.object(package.lxml, "source_inputs", return_value=inputs):
            with self.assertRaisesRegex(ValueError, "stage changed"):
                package.embed(self.stage, self.app)
        self.assertFalse((self.app / "app_packages").exists())

    def test_missing_crypto_framework_cannot_produce_a_partial_package(self):
        self.crypto_binary.unlink()
        with self.assertRaisesRegex(ValueError, "stage changed"):
            package.embed(self.stage, self.app)
        self.assertFalse((self.app / "app_packages").exists())

    def test_changed_or_extra_staged_file_is_not_embedded(self):
        for filename in ("app/native_source_entry.py", "app/injected.py"):
            (self.stage / "bundle" / filename).write_text("changed")
            with self.assertRaisesRegex(ValueError, "stage changed"):
                package.embed(self.stage, self.app)
        self.assertFalse((self.app / "app").exists())

    def test_existing_link_framework_cannot_be_silently_replaced(self):
        destination = self.root / "link"
        package.copy_framework(self.stage, destination)
        package.copy_framework(self.stage, destination)
        (destination / "Python.framework/Headers/Python.h").write_text("changed")
        with self.assertRaisesRegex(ValueError, "differs"):
            package.copy_framework(self.stage, destination)

    def test_embedding_requires_actual_app_metadata(self):
        with self.assertRaisesRegex(ValueError, "built iOS application"):
            package.embed(self.stage, self.root / "not-an-app")

    def test_pure_dependencies_lock_includes_cssselect_and_pyquery(self):
        deps = package.validate_pure_dependencies_lock()
        self.assertIn("cssselect", deps)
        self.assertIn("pyquery", deps)
        self.assertEqual(deps["cssselect"], "1.6.0")
        self.assertEqual(deps["pyquery"], "2.1.0")

    def test_prepare_stages_tvbox_spider_shims(self):
        inputs = package.source_inputs()
        self.assertIn("flutter/packages/python_source_runtime/python/native_source_entry.py", inputs)
        self.assertIn("flutter/packages/python_source_runtime/python/tvbox_spider_shim.py", inputs)

        stage = self.root / "shim-stage"
        frameworks = self.root / "shim-link"
        cache = self.root / "shim-cache"

        def stage_python(bundle, target, arch, _cache, **_kwargs):
            for name in ("python", "app", "app_packages", "Frameworks/Python.framework/Headers"):
                (bundle / name).mkdir(parents=True)
            (bundle / "Frameworks/Python.framework/Headers/Python.h").write_text("header")
            return {"target": target, "architecture": arch}

        with patch.object(package.native, "stage", side_effect=stage_python), \
             patch.object(package.crypto, "stage", return_value={}), \
             patch.object(package.lxml, "stage", return_value=dict(self.lxml_report)):
            report = package.prepare(stage, frameworks, cache, "simulator", "arm64")

        self.assertIn("cssselect", report["runtime"]["pure_dependencies"])
        self.assertIn("pyquery", report["runtime"]["pure_dependencies"])
        self.assertTrue((stage / "bundle/app/native_source_entry.py").is_file())
        self.assertTrue((stage / "bundle/app/tvbox_spider_shim.py").is_file())

    def test_ios_tvbox_spider_shim_local_proxy_and_get_dependence(self):
        import shutil
        import subprocess
        import sys
        app_dir = self.root / "staged-app"
        app_dir.mkdir()
        packages_dir = self.root / "staged-packages"
        packages_dir.mkdir()
        cache_dir = Path(tempfile.gettempdir()) / "marco-ios-wheel-cache"
        package.native.stage_wheels(packages_dir, cache_dir)
        shutil.copyfile(package.HOST / "host.py", app_dir / "native_source_host.py")
        shutil.copyfile(package.ADAPTER, app_dir / "requests_adapter.py")
        shutil.copytree(package.HOST / "base", app_dir / "base", ignore=shutil.ignore_patterns("__pycache__"))
        for path in (package.RUNTIME / "python").glob("*.py"):
            shutil.copyfile(path, app_dir / path.name)

        script = r"""
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import sys
import threading
from urllib.parse import urlsplit

sys.path[:0] = [sys.argv[1], sys.argv[2]]
import native_source_entry

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass
    def do_GET(self):
        if self.path == "/remote_dep.py":
            body = b'REMOTE_VAL = "from_remote_dep"\n'
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
origin = f"http://127.0.0.1:{server.server_port}"

def bridge(envelope, context):
    u = urlsplit(envelope["url"])
    conn = http.client.HTTPConnection(u.hostname, u.port, timeout=2)
    try:
        conn.request(envelope["method"], u.path + ("?" + u.query if u.query else ""),
                     body=envelope["body"], headers=dict(envelope["headers"]))
        resp = conn.getresponse()
        body = resp.read()
        return {"version": 1, "callId": envelope["callId"], "requestId": envelope["requestId"],
                "url": envelope["url"], "status": resp.status, "reason": resp.reason,
                "headers": [list(p) for p in resp.getheaders()], "body": body}
    finally:
        conn.close()

spider_code = b'''
import base
from com.github.catvod.crawler.Spider import Spider as TVBoxSpider

class Spider(TVBoxSpider):
    def getDependence(self):
        return ["sibling_helper", "remote_dep"]

    def homeContent(self, filter):
        import sibling_helper
        import remote_dep
        proxied = base.localProxy({"token": "ok"})
        return {
            "list": [{
                "vod_id": "1",
                "vod_name": sibling_helper.LABEL + "|" + remote_dep.REMOTE_VAL + "|" + str(proxied[0]) + "|" + proxied[2]
            }]
        }

    def localProxy(self, params):
        return [200, "text/plain", "proxy:" + params.get("token", "")]
'''
sibling_code = b'LABEL = "from_sibling"\n'

src = native_source_entry.create(
    "main.py",
    {"main.py": spider_code, "sibling_helper.py": sibling_code},
    "",
    "http://127.0.0.1:12345/_spider/abc/proxy?do=py&siteKey=abc",
    bridge,
    remote={"url": origin + "/main.py", "headers": {}},
)
try:
    res = native_source_entry.invoke(src, "home", [False], "0" * 32, 5000)
    assert res["list"][0]["vod_name"] == "from_sibling|from_remote_dep|200|proxy:ok", res
    proxy_res = native_source_entry.invoke(src, "proxy", [{"token": "direct"}], "1" * 32, 5000)
    assert proxy_res[:3] == [200, "text/plain", "proxy:direct"], proxy_res
finally:
    native_source_entry.close(src)
    server.shutdown()
    server.server_close()
print("SHIM_OK")
"""
        proc = subprocess.run(
            [sys.executable, "-I", "-c", script, str(app_dir), str(packages_dir)],
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + "\n" + proc.stderr)
        self.assertIn("SHIM_OK", proc.stdout)


if __name__ == "__main__":
    unittest.main()
