"""Unified CPython 3 spider host for Android native JNI and Desktop stdio bridge."""
from __future__ import annotations

import base64
import hashlib
from html.parser import HTMLParser
import importlib.util
import inspect
import json
import os
import re
import sys
import threading
import types
from urllib.parse import urlencode


# ---------------------------------------------------------------------------
# Pure-Python Crypto.Cipher.AES + Padding shim (only when pycryptodome absent)
# ---------------------------------------------------------------------------
def _install_crypto_shim():
    if "Crypto.Cipher.AES" in sys.modules:
        return
    try:
        import Crypto.Cipher.AES  # noqa: F401
        return
    except Exception:
        pass
    try:
        import pyaes
    except Exception:
        return

    crypto_pkg = types.ModuleType("Crypto")
    cipher_pkg = types.ModuleType("Crypto.Cipher")
    util_pkg = types.ModuleType("Crypto.Util")
    padding_mod = types.ModuleType("Crypto.Util.Padding")
    hash_pkg = types.ModuleType("Crypto.Hash")
    aes_mod = types.ModuleType("Crypto.Cipher.AES")

    def pad(data_to_pad: bytes, block_size: int = 16, style: str = "pkcs7") -> bytes:
        padding_len = block_size - (len(data_to_pad) % block_size)
        if style == "pkcs7":
            return data_to_pad + bytes([padding_len]) * padding_len
        if style == "x923":
            return data_to_pad + b"\x00" * (padding_len - 1) + bytes([padding_len])
        raise ValueError(f"Unsupported padding style: {style}")

    def unpad(padded_data: bytes, block_size: int = 16, style: str = "pkcs7") -> bytes:
        if not padded_data or len(padded_data) % block_size != 0:
            raise ValueError("Input data is not padded")
        padding_len = padded_data[-1]
        if padding_len < 1 or padding_len > block_size:
            raise ValueError("Invalid padding length")
        if style == "pkcs7" and padded_data[-padding_len:] != bytes([padding_len]) * padding_len:
            raise ValueError("PKCS7 padding is incorrect")
        return padded_data[:-padding_len]

    padding_mod.pad = pad
    padding_mod.unpad = unpad

    class _AesCipher:
        def __init__(self, key: bytes, mode: int, iv: bytes | None = None):
            self._key = bytes(key)
            self._mode = mode
            self._iv = bytes(iv) if iv is not None else b"\x00" * 16

        def encrypt(self, plaintext: bytes) -> bytes:
            data = bytes(plaintext)
            if self._mode == aes_mod.MODE_ECB:
                op = pyaes.AESModeOfOperationECB(self._key)
                out = bytearray()
                for i in range(0, len(data), 16):
                    out.extend(op.encrypt(data[i:i + 16]))
                return bytes(out)
            if self._mode == aes_mod.MODE_CBC:
                op = pyaes.AESModeOfOperationCBC(self._key, iv=self._iv)
                out = bytearray()
                for i in range(0, len(data), 16):
                    out.extend(op.encrypt(data[i:i + 16]))
                return bytes(out)
            if self._mode == aes_mod.MODE_CTR:
                ctr = pyaes.Counter(initial_value=int.from_bytes(self._iv, "big"))
                op = pyaes.AESModeOfOperationCTR(self._key, counter=ctr)
                return op.encrypt(data)
            raise ValueError(f"Unsupported AES mode: {self._mode}")

        def decrypt(self, ciphertext: bytes) -> bytes:
            data = bytes(ciphertext)
            if self._mode == aes_mod.MODE_ECB:
                op = pyaes.AESModeOfOperationECB(self._key)
                out = bytearray()
                for i in range(0, len(data), 16):
                    out.extend(op.decrypt(data[i:i + 16]))
                return bytes(out)
            if self._mode == aes_mod.MODE_CBC:
                op = pyaes.AESModeOfOperationCBC(self._key, iv=self._iv)
                out = bytearray()
                for i in range(0, len(data), 16):
                    out.extend(op.decrypt(data[i:i + 16]))
                return bytes(out)
            if self._mode == aes_mod.MODE_CTR:
                ctr = pyaes.Counter(initial_value=int.from_bytes(self._iv, "big"))
                op = pyaes.AESModeOfOperationCTR(self._key, counter=ctr)
                return op.decrypt(data)
            raise ValueError(f"Unsupported AES mode: {self._mode}")

    aes_mod.MODE_ECB = 1
    aes_mod.MODE_CBC = 2
    aes_mod.MODE_CTR = 6
    aes_mod.block_size = 16
    aes_mod.new = lambda key, mode, iv=None, IV=None, **kw: _AesCipher(key, mode, iv if iv is not None else IV)

    def _make_hash_mod(name: str, ctor):
        mod = types.ModuleType(f"Crypto.Hash.{name}")
        mod.new = lambda data=b"": ctor(data)
        return mod

    md5_mod = _make_hash_mod("MD5", hashlib.md5)
    sha256_mod = _make_hash_mod("SHA256", hashlib.sha256)

    cipher_pkg.AES = aes_mod
    util_pkg.Padding = padding_mod
    hash_pkg.MD5 = md5_mod
    hash_pkg.SHA256 = sha256_mod
    crypto_pkg.Cipher = cipher_pkg
    crypto_pkg.Util = util_pkg
    crypto_pkg.Hash = hash_pkg

    sys.modules["Crypto"] = crypto_pkg
    sys.modules["Crypto.Cipher"] = cipher_pkg
    sys.modules["Crypto.Cipher.AES"] = aes_mod
    sys.modules["Crypto.Util"] = util_pkg
    sys.modules["Crypto.Util.Padding"] = padding_mod
    sys.modules["Crypto.Hash"] = hash_pkg
    sys.modules["Crypto.Hash.MD5"] = md5_mod
    sys.modules["Crypto.Hash.SHA256"] = sha256_mod


# ---------------------------------------------------------------------------
# Pure-Python lxml.etree (HTML + XPath) and bs4 fallback (when absent)
# ---------------------------------------------------------------------------
_VOID_TAGS = frozenset(
    "area base br col embed hr img input link meta param source track wbr".split()
)


class _HtmlNode:
    def __init__(self, tag: str, attrs: dict[str, str] | None = None, parent: "_HtmlNode | None" = None):
        self.tag = tag.lower()
        self.attrib: dict[str, str] = dict(attrs or {})
        self.parent = parent
        self.children: list[_HtmlNode] = []
        self.text_parts: list[str] = []
        self.tail_parts: list[str] = []

    @property
    def text(self) -> str | None:
        val = "".join(self.text_parts)
        return val if val else None

    @property
    def tail(self) -> str | None:
        val = "".join(self.tail_parts)
        return val if val else None

    def get(self, key: str, default=None):
        return self.attrib.get(key, default)

    def itertext(self):
        if self.text_parts:
            yield "".join(self.text_parts)
        for child in self.children:
            yield from child.itertext()
            if child.tail_parts:
                yield "".join(child.tail_parts)

    def full_text(self) -> str:
        return "".join(self.itertext())

    def descendants(self):
        for child in self.children:
            yield child
            yield from child.descendants()

    def xpath(self, expr: str):
        expr = expr.strip()
        if not expr:
            return []
        if "|" in expr:
            out = []
            for branch in expr.split("|"):
                out.extend(self.xpath(branch.strip()))
            return out
        if expr.startswith("string(") and expr.endswith(")"):
            inner = self.xpath(expr[7:-1].strip())
            if not inner:
                return ""
            first = inner[0]
            return first.full_text() if isinstance(first, _HtmlNode) else str(first)

        # Tokenize steps preserving // vs /
        steps = []
        i = 0
        n = len(expr)
        if expr.startswith("."):
            i = 1
        while i < n:
            if expr.startswith("//", i):
                axis = "//"
                i += 2
            elif expr[i] == "/":
                axis = "/"
                i += 1
            else:
                axis = "/"
            start = i
            bracket_depth = 0
            quote_char = None
            while i < n:
                ch = expr[i]
                if quote_char:
                    if ch == quote_char:
                        quote_char = None
                elif ch in ("'", '"'):
                    quote_char = ch
                elif ch == "[":
                    bracket_depth += 1
                elif ch == "]":
                    bracket_depth = max(0, bracket_depth - 1)
                elif ch == "/" and bracket_depth == 0:
                    break
                i += 1
            steps.append((axis, expr[start:i]))

        current: list = [self]
        for axis, step in steps:
            if not step or step == ".":
                continue
            if step == "..":
                current = [node.parent for node in current if isinstance(node, _HtmlNode) and node.parent is not None]
                continue
            if step == "text()":
                out = []
                for node in current:
                    if isinstance(node, _HtmlNode):
                        if axis == "//":
                            for t in node.itertext():
                                if t:
                                    out.append(t)
                        else:
                            if node.text:
                                out.append(node.text)
                            for ch in node.children:
                                if ch.tail:
                                    out.append(ch.tail)
                current = out
                continue
            if step.startswith("@"):
                attr = step[1:]
                out = []
                for node in current:
                    if isinstance(node, _HtmlNode) and attr in node.attrib:
                        out.append(node.attrib[attr])
                current = out
                continue

            m = re.match(r"^([a-zA-Z0-9_:*.-]+)(.*)$", step)
            if not m:
                return []
            tag_name = m.group(1).lower()
            pred_raw = m.group(2)
            predicates = re.findall(r"\[([^\]]+)\]", pred_raw)

            next_nodes: list[_HtmlNode] = []
            for node in current:
                if not isinstance(node, _HtmlNode):
                    continue
                pool = list(node.descendants()) if axis == "//" else list(node.children)
                matched = [c for c in pool if tag_name == "*" or c.tag == tag_name]
                for pred in predicates:
                    matched = _apply_xpath_predicate(matched, pred.strip())
                next_nodes.extend(matched)
            current = next_nodes
        return current

    def __iter__(self):
        return iter(self.children)


def _apply_xpath_predicate(nodes: list[_HtmlNode], pred: str) -> list[_HtmlNode]:
    if not nodes:
        return []
    if pred.isdigit():
        idx = int(pred) - 1
        return [nodes[idx]] if 0 <= idx < len(nodes) else []
    if pred == "last()":
        return [nodes[-1]]
    m = re.match(r"^position\(\)\s*([<>]=?|=)\s*(\d+)$", pred)
    if m:
        op, num = m.group(1), int(m.group(2))
        out = []
        for i, n in enumerate(nodes, 1):
            if (op == "=" and i == num) or (op == ">" and i > num) or (op == ">=" and i >= num) or (op == "<" and i < num) or (op == "<=" and i <= num):
                out.append(n)
        return out
    m = re.match(r"^@([a-zA-Z0-9_:-]+)\s*=\s*['\"]([^'\"]*)['\"]$", pred)
    if m:
        k, v = m.group(1), m.group(2)
        return [n for n in nodes if n.attrib.get(k) == v]
    m = re.match(r"^contains\(\s*@([a-zA-Z0-9_:-]+)\s*,\s*['\"]([^'\"]*)['\"]\s*\)$", pred)
    if m:
        k, v = m.group(1), m.group(2)
        return [n for n in nodes if v in n.attrib.get(k, "")]
    m = re.match(r"^contains\(\s*(?:text\(\)|\.)\s*,\s*['\"]([^'\"]*)['\"]\s*\)$", pred)
    if m:
        v = m.group(1)
        return [n for n in nodes if v in n.full_text()]
    m = re.match(r"^@([a-zA-Z0-9_:-]+)$", pred)
    if m:
        k = m.group(1)
        return [n for n in nodes if k in n.attrib]
    return nodes


class _TreeBuilder(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = _HtmlNode("html")
        self.stack = [self.root]

    def handle_starttag(self, tag, attrs):
        tag_l = tag.lower()
        attr_map = {k.lower(): (v if v is not None else "") for k, v in attrs}
        node = _HtmlNode(tag_l, attr_map, parent=self.stack[-1])
        self.stack[-1].children.append(node)
        if tag_l not in _VOID_TAGS:
            self.stack.append(node)

    def handle_endtag(self, tag):
        tag_l = tag.lower()
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag_l:
                del self.stack[i:]
                break

    def handle_data(self, data):
        parent = self.stack[-1]
        if parent.children:
            parent.children[-1].tail_parts.append(data)
        else:
            parent.text_parts.append(data)


def _parse_html(content) -> _HtmlNode:
    if isinstance(content, bytes):
        content = content.decode("utf-8", errors="replace")
    builder = _TreeBuilder()
    builder.feed(str(content or ""))
    builder.close()
    return builder.root


def _install_lxml_and_bs4_shims():
    if "lxml.etree" not in sys.modules:
        try:
            import lxml.etree  # noqa: F401
        except Exception:
            lxml_pkg = types.ModuleType("lxml")
            etree_mod = types.ModuleType("lxml.etree")
            html_mod = types.ModuleType("lxml.html")
            etree_mod.HTML = _parse_html
            etree_mod.fromstring = _parse_html
            etree_mod.tostring = lambda node, encoding="unicode", method="html", **kw: (
                node.full_text() if method == "text" else str(node.full_text())
            )
            html_mod.fromstring = _parse_html
            lxml_pkg.etree = etree_mod
            lxml_pkg.html = html_mod
            sys.modules["lxml"] = lxml_pkg
            sys.modules["lxml.etree"] = etree_mod
            sys.modules["lxml.html"] = html_mod

    if "bs4" not in sys.modules:
        try:
            import bs4  # noqa: F401
        except Exception:
            bs4_mod = types.ModuleType("bs4")

            class _TagWrap:
                def __init__(self, node: _HtmlNode):
                    self._node = node

                @property
                def name(self):
                    return self._node.tag

                @property
                def attrs(self):
                    return self._node.attrib

                @property
                def text(self):
                    return self._node.full_text()

                def get_text(self, separator="", strip=False):
                    txt = separator.join(self._node.itertext())
                    return txt.strip() if strip else txt

                def get(self, key, default=None):
                    return self._node.attrib.get(key, default)

                def __getitem__(self, key):
                    return self._node.attrib[key]

                def find_all(self, name=None, attrs=None, class_=None, id=None, limit=None, **kw):
                    filters = dict(attrs or {})
                    if class_ is not None:
                        filters["class"] = class_
                    if id is not None:
                        filters["id"] = id
                    for k, v in kw.items():
                        filters[k.rstrip("_")] = v
                    out = []
                    for n in self._node.descendants():
                        if name and n.tag != str(name).lower():
                            continue
                        ok = True
                        for fk, fv in filters.items():
                            actual = n.attrib.get(fk, "")
                            if callable(fv):
                                if not fv(actual):
                                    ok = False
                                    break
                            elif fk == "class":
                                classes = actual.split()
                                if str(fv) not in classes and str(fv) != actual:
                                    ok = False
                                    break
                            elif actual != str(fv):
                                ok = False
                                break
                        if ok:
                            out.append(_TagWrap(n))
                            if limit and len(out) >= limit:
                                break
                    return out

                def find(self, name=None, attrs=None, class_=None, id=None, **kw):
                    res = self.find_all(name=name, attrs=attrs, class_=class_, id=id, limit=1, **kw)
                    return res[0] if res else None

                def select(self, selector: str):
                    # Basic tag / #id / .class / descendant CSS selector support
                    parts = [p.strip() for p in selector.split() if p.strip()]
                    nodes = [self._node]
                    for part in parts:
                        nxt = []
                        tag = None
                        req_id = None
                        req_classes = []
                        m = re.match(r"^([a-zA-Z0-9_-]+)?", part)
                        if m and m.group(1):
                            tag = m.group(1).lower()
                        id_m = re.search(r"#([a-zA-Z0-9_-]+)", part)
                        if id_m:
                            req_id = id_m.group(1)
                        req_classes = re.findall(r"\.([a-zA-Z0-9_-]+)", part)
                        for root in nodes:
                            for d in root.descendants():
                                if tag and d.tag != tag:
                                    continue
                                if req_id and d.attrib.get("id") != req_id:
                                    continue
                                if req_classes:
                                    cls_set = set(d.attrib.get("class", "").split())
                                    if not all(c in cls_set for c in req_classes):
                                        continue
                                nxt.append(d)
                        nodes = nxt
                    return [_TagWrap(n) for n in nodes]

                def select_one(self, selector: str):
                    res = self.select(selector)
                    return res[0] if res else None

            class BeautifulSoup(_TagWrap):
                def __init__(self, markup="", features="html.parser", **kw):
                    super().__init__(_parse_html(markup))

            bs4_mod.BeautifulSoup = BeautifulSoup
            sys.modules["bs4"] = bs4_mod


# ---------------------------------------------------------------------------
# Spider host state & compatibility shims
# ---------------------------------------------------------------------------
class _ProxyHostAdapter:
    def __init__(self):
        self._tls = threading.local()

    def set_base(self, base_url: str):
        self._tls.base_url = base_url or ""

    def proxy_url(self, params=None, local=True, legacy=False):
        base = getattr(self._tls, "base_url", "") or "http://127.0.0.1:9978/proxy?do=py"
        if not params:
            return base
        if isinstance(params, dict):
            q = urlencode(params)
            sep = "&" if "?" in base else "?"
            return f"{base}{sep}{q}" if q else base
        return base


_PROXY_HOST = _ProxyHostAdapter()


def _install_requests_fallback():
    if "requests" in sys.modules:
        return
    try:
        import requests  # noqa: F401
        return
    except Exception:
        pass
    import urllib.request
    import urllib.error
    import urllib.parse

    req_mod = types.ModuleType("requests")

    class _Response:
        def __init__(self, status_code: int, headers: dict[str, str], content: bytes, url: str):
            self.status_code = status_code
            self.headers = headers
            self.content = content
            self.url = url
            self.encoding = "utf-8"

        @property
        def text(self) -> str:
            return self.content.decode(self.encoding or "utf-8", errors="replace")

        def json(self):
            return json.loads(self.text)

    def _do_request(method: str, url: str, params=None, data=None, json_body=None, headers=None, timeout=15, **kw):
        if params:
            sep = "&" if "?" in url else "?"
            url = f"{url}{sep}{urllib.parse.urlencode(params)}"
        req_headers = dict(headers or {})
        body = None
        if json_body is not None:
            body = json.dumps(json_body).encode("utf-8")
            req_headers.setdefault("Content-Type", "application/json")
        elif data is not None:
            if isinstance(data, dict):
                body = urllib.parse.urlencode(data).encode("utf-8")
                req_headers.setdefault("Content-Type", "application/x-www-form-urlencoded")
            elif isinstance(data, bytes):
                body = data
            else:
                body = str(data).encode("utf-8")
        request = urllib.request.Request(url, data=body, headers=req_headers, method=method.upper())
        try:
            with urllib.request.urlopen(request, timeout=timeout or 15) as resp:
                return _Response(resp.status, dict(resp.headers.items()), resp.read(), resp.geturl())
        except urllib.error.HTTPError as err:
            return _Response(err.code, dict(err.headers.items()) if err.headers else {}, err.read(), url)

    class Session:
        def __init__(self):
            self.headers: dict[str, str] = {}

        def request(self, method: str, url: str, headers=None, **kw):
            merged = dict(self.headers)
            if headers:
                merged.update(headers)
            return _do_request(method, url, headers=merged, **kw)

        def get(self, url: str, **kw):
            return self.request("GET", url, **kw)

        def post(self, url: str, **kw):
            return self.request("POST", url, **kw)

    req_mod.request = _do_request
    req_mod.get = lambda url, **kw: _do_request("GET", url, **kw)
    req_mod.post = lambda url, **kw: _do_request("POST", url, **kw)
    req_mod.Session = Session
    sys.modules["requests"] = req_mod


def _install_spider_base_shims():
    _install_requests_fallback()
    import base.spider as spider_mod

    spider_mod._HOST = _PROXY_HOST
    if not hasattr(spider_mod.Spider, "getDependence"):
        spider_mod.Spider.getDependence = lambda self: []
    if not hasattr(spider_mod.Spider, "loadSpider"):
        spider_mod.Spider.loadSpider = lambda self, name: None
    if not hasattr(spider_mod.Spider, "setCache"):
        spider_mod.Spider.setCache = lambda self, key, value: None
    if not hasattr(spider_mod.Spider, "getCache"):
        spider_mod.Spider.getCache = lambda self, key: None

    if "base.localProxy" not in sys.modules:
        lp_mod = types.ModuleType("base.localProxy")

        class Proxy:
            @staticmethod
            def getUrl():
                return _PROXY_HOST.proxy_url()

        lp_mod.Proxy = Proxy
        sys.modules["base.localProxy"] = lp_mod


_SHIMS_READY = False
_SHIM_LOCK = threading.Lock()


def _ensure_shims():
    global _SHIMS_READY
    if _SHIMS_READY:
        return
    with _SHIM_LOCK:
        if _SHIMS_READY:
            return
        _install_crypto_shim()
        _install_lxml_and_bs4_shims()
        _install_spider_base_shims()
        _SHIMS_READY = True


class _SpiderEntry:
    def __init__(self, instance, script_path: str, proxy_base: str):
        self.instance = instance
        self.script_path = script_path
        self.proxy_base = proxy_base
        self.lock = threading.RLock()


_SPIDERS: dict[str, _SpiderEntry] = {}
_SPIDERS_LOCK = threading.Lock()


def _load_spider_instance(site_key: str, script_path: str, ext_json: str, proxy_base: str):
    _ensure_shims()
    script_dir = os.path.dirname(os.path.abspath(script_path))
    if script_dir and script_dir not in sys.path:
        sys.path.insert(0, script_dir)
    mod_name = f"_mm_spider_{hashlib.sha256((site_key + ':' + script_path).encode('utf-8')).hexdigest()[:16]}"
    spec = importlib.util.spec_from_file_location(mod_name, script_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load Python spider module: {script_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[mod_name] = module
    spec.loader.exec_module(module)

    import base.spider as spider_mod

    spider_cls = getattr(module, "Spider", None)
    if not inspect.isclass(spider_cls):
        for _, obj in inspect.getmembers(module, inspect.isclass):
            if obj is not spider_mod.Spider and issubclass(obj, spider_mod.Spider):
                spider_cls = obj
                break
    if not inspect.isclass(spider_cls):
        raise RuntimeError("Python source does not define a Spider class")

    _PROXY_HOST.set_base(proxy_base)
    instance = spider_cls()
    if hasattr(instance, "init") and callable(instance.init):
        sig = inspect.signature(instance.init)
        if len(sig.parameters) == 0:
            instance.init()
        else:
            instance.init(ext_json or "")
    return _SpiderEntry(instance, script_path, proxy_base)


def _get_or_create(site_key: str, script_path: str, ext_json: str, proxy_base: str) -> _SpiderEntry:
    with _SPIDERS_LOCK:
        entry = _SPIDERS.get(site_key)
        if entry is not None and entry.script_path == script_path:
            if proxy_base:
                entry.proxy_base = proxy_base
            return entry
    created = _load_spider_instance(site_key, script_path, ext_json, proxy_base)
    with _SPIDERS_LOCK:
        _SPIDERS[site_key] = created
    return created


def _encode_result(val) -> str:
    if val is None:
        return "{}"
    if isinstance(val, str):
        return val
    return json.dumps(val, ensure_ascii=False)


def call_spider(
    site_key: str,
    script_path: str,
    ext_json: str,
    proxy_base: str,
    method_name: str,
    args_json: str,
) -> str:
    try:
        entry = _get_or_create(site_key, script_path, ext_json, proxy_base)
        args = json.loads(args_json) if args_json else []
        if not isinstance(args, list):
            args = [args]
        with entry.lock:
            _PROXY_HOST.set_base(entry.proxy_base)
            if method_name == "init":
                return json.dumps({"ok": True, "data": "ok"}, ensure_ascii=False)
            fn = getattr(entry.instance, method_name, None)
            if fn is None and method_name == "action":
                return json.dumps({"ok": False, "error": "Spider does not implement action"}, ensure_ascii=False)
            if not callable(fn):
                return json.dumps({"ok": False, "error": f"Missing spider method: {method_name}"}, ensure_ascii=False)
            # Match argument arity gently for 2-arg vs 3-arg searchContent(key, quick[, pg])
            try:
                sig = inspect.signature(fn)
                has_varargs = any(p.kind == inspect.Parameter.VAR_POSITIONAL for p in sig.parameters.values())
                if not has_varargs and len(args) > len(sig.parameters):
                    args = args[:len(sig.parameters)]
            except Exception:
                pass
            res = fn(*args)
            return json.dumps({"ok": True, "data": _encode_result(res)}, ensure_ascii=False)
    except Exception as exc:
        return json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"}, ensure_ascii=False)


def call_proxy(site_key: str, params_json: str) -> str:
    try:
        with _SPIDERS_LOCK:
            entry = _SPIDERS.get(site_key)
        if entry is None:
            return json.dumps({"ok": False, "error": "Python spider session not active"}, ensure_ascii=False)
        params = json.loads(params_json) if params_json else {}
        with entry.lock:
            _PROXY_HOST.set_base(entry.proxy_base)
            fn = getattr(entry.instance, "localProxy", None) or getattr(entry.instance, "proxy", None)
            if not callable(fn):
                return json.dumps({"ok": False, "error": "Spider has no localProxy"}, ensure_ascii=False)
            result = fn(params)
            if not isinstance(result, (list, tuple)) or len(result) < 3:
                return json.dumps({"ok": False, "error": "Invalid localProxy return value"}, ensure_ascii=False)
            code = int(result[0])
            mime = str(result[1] or "application/octet-stream")
            raw_body = result[2]
            headers = result[3] if len(result) > 3 and isinstance(result[3], dict) else {}
            if isinstance(raw_body, bytes):
                body_bytes = raw_body
            elif isinstance(raw_body, bytearray):
                body_bytes = bytes(raw_body)
            elif raw_body is None:
                body_bytes = b""
            else:
                body_bytes = str(raw_body).encode("utf-8")
            return json.dumps(
                {
                    "ok": True,
                    "code": code,
                    "mime": mime,
                    "body_b64": base64.b64encode(body_bytes).decode("ascii"),
                    "headers": {str(k): str(v) for k, v in headers.items()},
                },
                ensure_ascii=False,
            )
    except Exception as exc:
        return json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"}, ensure_ascii=False)


def release_spider(site_key: str) -> None:
    with _SPIDERS_LOCK:
        entry = _SPIDERS.pop(site_key, None)
    if entry is not None:
        destroy = getattr(entry.instance, "destroy", None)
        if callable(destroy):
            try:
                destroy()
            except Exception:
                pass


def _stdio_loop():
    """Line-delimited JSON-RPC bridge for Desktop Flutter (Windows/macOS/Linux)."""
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        req_id = ""
        try:
            req = json.loads(line)
            req_id = str(req.get("id", ""))
            op = req.get("op", "")
            if op == "ping":
                resp = {"id": req_id, "ok": True, "version": sys.version.split()[0]}
            elif op == "call":
                raw = call_spider(
                    str(req.get("siteKey", "")),
                    str(req.get("scriptPath", "")),
                    str(req.get("ext", "")),
                    str(req.get("proxyBase", "")),
                    str(req.get("method", "")),
                    json.dumps(req.get("args", []), ensure_ascii=False),
                )
                parsed = json.loads(raw)
                parsed["id"] = req_id
                resp = parsed
            elif op == "proxy":
                raw = call_proxy(
                    str(req.get("siteKey", "")),
                    json.dumps(req.get("params", {}), ensure_ascii=False),
                )
                parsed = json.loads(raw)
                parsed["id"] = req_id
                resp = parsed
            elif op == "release":
                release_spider(str(req.get("siteKey", "")))
                resp = {"id": req_id, "ok": True}
            elif op == "quit":
                resp = {"id": req_id, "ok": True}
                sys.stdout.write(json.dumps(resp, ensure_ascii=False) + "\n")
                sys.stdout.flush()
                break
            else:
                resp = {"id": req_id, "ok": False, "error": f"Unknown op: {op}"}
        except Exception as exc:
            resp = {"id": req_id, "ok": False, "error": f"{type(exc).__name__}: {exc}"}
        sys.stdout.write(json.dumps(resp, ensure_ascii=False) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    if "--stdio" in sys.argv:
        _stdio_loop()
