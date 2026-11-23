"""Persistent UTF-8 line-delimited JSON-RPC Spider host for Desktop CPython 3.11+."""
from __future__ import annotations

import base64
import builtins
from contextlib import contextmanager
from contextvars import ContextVar
from email.message import Message
import importlib
import importlib.abc
import importlib.resources.abc
import importlib.util
import inspect
import io
import json
import math
import operator
import os
from pathlib import Path
import queue
import re
import sys
import threading
import time
import types
from types import SimpleNamespace
import unicodedata
from urllib.parse import parse_qsl, quote, unquote, urlencode, urljoin, urlsplit, urlunsplit
import uuid
import weakref
import zlib

# Ensure UTF-8 stdio even when launched with -I on localized Windows codepages,
# and keep Spider print() calls on stderr so stdout stays pure JSON-RPC.
if hasattr(sys.stdin, "reconfigure"):
    sys.stdin.reconfigure(encoding="utf-8", errors="strict")
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="strict")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

_RPC_OUT = sys.stdout
_RPC_WRITE_LOCK = threading.Lock()
sys.stdout = sys.stderr


def _install_cryptodome_alias() -> None:
    """Expose Cryptodome.* aliases backed by Crypto.* when pycryptodome is installed."""
    if "Cryptodome" in sys.modules:
        return
    try:
        crypto_pkg = importlib.import_module("Crypto")
    except Exception:
        return

    class _CryptodomeFinder(importlib.abc.MetaPathFinder):
        def find_spec(self, fullname, path=None, target=None):
            if fullname != "Cryptodome" and not fullname.startswith("Cryptodome."):
                return None
            mapped = "Crypto" + fullname[len("Cryptodome"):]
            try:
                real_mod = importlib.import_module(mapped)
            except Exception:
                return None
            sys.modules[fullname] = real_mod
            return importlib.util.spec_from_loader(fullname, _AliasLoader(real_mod), is_package=hasattr(real_mod, "__path__"))

    class _AliasLoader(importlib.abc.Loader):
        def __init__(self, mod):
            self._mod = mod

        def create_module(self, spec):
            return self._mod

        def exec_module(self, module):
            return None

    sys.modules["Cryptodome"] = crypto_pkg
    sys.meta_path.append(_CryptodomeFinder())


_install_cryptodome_alias()

try:
    import requests
    import requests.adapters
    import requests.api
    import requests.sessions
    from requests.adapters import HTTPAdapter
    from requests.cookies import RequestsCookieJar, extract_cookies_to_jar
    from requests.exceptions import ConnectionError, RequestException, SSLError, Timeout
    from urllib3._collections import HTTPHeaderDict
    from urllib3.response import HTTPResponse
    _HAS_REQUESTS = True
except Exception:  # pragma: no cover - fallback when running on bare stdlib python
    _HAS_REQUESTS = False


MAX_BODY = 6 * 1024 * 1024
MAX_HEADERS = 32768
MAX_HEADER_COUNT = 128
_TOKEN = re.compile(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")
_CONTROL = re.compile(r"[\x00-\x08\x0a-\x1f\x7f]")
_IDENTITY = re.compile(r"^[0-9a-f]{32}$")
_MIME = re.compile(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+/[!#$%&'*+.^_`|~0-9A-Za-z-]+(?: *;[^\r\n]*)?$")
_METHODS = frozenset(("GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"))


class SourceContractError(ValueError):
    pass


if _HAS_REQUESTS:
    class UnsupportedFeature(RequestException):
        pass

    class BridgeProtocolError(RequestException):
        pass

    class CallCancelled(RequestException):
        pass

    class BodyLimitError(RequestException):
        pass
else:
    class UnsupportedFeature(Exception):
        pass

    class BridgeProtocolError(Exception):
        pass

    class CallCancelled(Exception):
        pass

    class BodyLimitError(Exception):
        pass

    class Timeout(Exception):
        pass

    class ConnectionError(Exception):
        pass

    class SSLError(Exception):
        pass

    class RequestException(Exception):
        pass


class BridgeTransportError(Exception):
    def __init__(self, kind: str):
        if kind not in ("timeout", "cancelled", "connection", "tls", "protocol"):
            kind = "connection"
        self.kind = kind
        super().__init__(kind)


class CallContext:
    def __init__(self, budget_seconds: float, *, call_id: str | None = None):
        if (
            isinstance(budget_seconds, bool)
            or not isinstance(budget_seconds, (int, float))
            or not math.isfinite(budget_seconds)
            or not 0 < budget_seconds <= 45
        ):
            raise ValueError("Call budget must be finite and at most 45 seconds")
        self.call_id = call_id or uuid.uuid4().hex
        if not isinstance(self.call_id, str) or not _IDENTITY.fullmatch(self.call_id):
            raise ValueError("Invalid call identity")
        self.deadline = time.monotonic() + budget_seconds
        self._cancelled = threading.Event()

    def cancel(self):
        self._cancelled.set()

    @property
    def cancelled(self):
        return self._cancelled.is_set()

    def check(self):
        if self.cancelled:
            raise CallCancelled("Python source HTTP call cancelled")
        if time.monotonic() >= self.deadline:
            raise Timeout("Python source HTTP call deadline exceeded")

    def remaining_ms(self):
        self.check()
        return max(1, math.ceil((self.deadline - time.monotonic()) * 1000))


def _url(value):
    if not isinstance(value, str) or len(value) > 16384 or re.search(r"[\x00-\x20\x7f]", value):
        raise BridgeProtocolError("Invalid HTTP URL")
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as error:
        raise BridgeProtocolError("Invalid HTTP URL") from error
    if (
        parsed.scheme not in ("http", "https")
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or (port is not None and not 0 < port <= 65535)
    ):
        raise UnsupportedFeature("Only HTTP(S) URLs without userinfo are supported")
    return urlunsplit((parsed.scheme, parsed.netloc, parsed.path or "/", parsed.query, ""))


def _origin(value):
    parsed = urlsplit(_url(value))
    return parsed.scheme, parsed.hostname.lower(), parsed.port or (443 if parsed.scheme == "https" else 80)


def _headers(pairs, *, response=False):
    if not isinstance(pairs, (list, tuple)) or len(pairs) > MAX_HEADER_COUNT:
        raise BridgeProtocolError("Invalid HTTP header list")
    clean, seen, size = [], set(), 0
    for pair in pairs:
        if not isinstance(pair, (list, tuple)) or len(pair) != 2:
            raise BridgeProtocolError("Invalid HTTP header pair")
        name, value = pair
        if (
            not isinstance(name, str)
            or not _TOKEN.fullmatch(name)
            or not isinstance(value, str)
            or _CONTROL.search(value)
        ):
            raise BridgeProtocolError("Invalid HTTP header name or value")
        try:
            size += len(name.encode("ascii")) + len(value.encode("latin-1")) + 4
        except UnicodeError as error:
            raise BridgeProtocolError("HTTP headers require ASCII names and Latin-1 values") from error
        if size > MAX_HEADERS:
            raise BridgeProtocolError("HTTP headers exceed limit")
        name = name.lower()
        if name in seen and (
            not response or name in ("content-length", "location", "content-encoding", "transfer-encoding")
        ):
            raise BridgeProtocolError("Duplicate singleton HTTP header")
        seen.add(name)
        clean.append([name, value])
    if response and "content-length" in seen and "transfer-encoding" in seen:
        raise BridgeProtocolError("Ambiguous HTTP response framing")
    for name, value in clean:
        if name == "content-length" and not re.fullmatch(r"[0-9]+", value):
            raise BridgeProtocolError("Invalid HTTP Content-Length")
    return clean


def _timeout(value, remaining):
    if value is None:
        values = (10.0, 10.0)
    elif isinstance(value, tuple) and len(value) == 2:
        values = value
    elif isinstance(value, (int, float)) and not isinstance(value, bool):
        values = (value, value)
    else:
        raise UnsupportedFeature("Timeout requires a positive number or connect/read pair")
    result = []
    for item in values:
        if (
            isinstance(item, bool)
            or not isinstance(item, (int, float))
            or not math.isfinite(item)
            or item <= 0
        ):
            raise UnsupportedFeature("Unbounded or invalid HTTP timeouts are unsupported")
        result.append(min(remaining, max(1, math.ceil(item * 1000))))
    return result


def _decoded_body(body, headers, method, status):
    if len(body) > MAX_BODY:
        raise BodyLimitError("HTTP response exceeds 6 MiB")
    if method == "HEAD" or status in (204, 304):
        if body:
            raise BridgeProtocolError("Body forbidden for this response")
        return b""
    values = dict(headers)
    length = values.get("content-length")
    if length is not None and (not re.fullmatch(r"[0-9]+", length) or int(length) != len(body)):
        raise BridgeProtocolError("HTTP response length mismatch")
    transfer = values.get("transfer-encoding", "").lower()
    if transfer not in ("", "chunked"):
        raise UnsupportedFeature("Unsupported transfer encoding")
    encoding = values.get("content-encoding", "identity").lower().strip()
    if encoding in ("", "identity"):
        return body
    if encoding not in ("gzip", "deflate"):
        raise UnsupportedFeature("Unsupported content encoding")
    try:
        decoder = zlib.decompressobj(31 if encoding == "gzip" else zlib.MAX_WBITS)
        output = decoder.decompress(body, MAX_BODY + 1)
        if len(output) > MAX_BODY or decoder.unconsumed_tail:
            raise BodyLimitError("Decoded HTTP response exceeds 6 MiB")
        if not decoder.eof or decoder.unused_data:
            raise BridgeProtocolError("Incomplete or concatenated compressed response")
        return output
    except zlib.error as error:
        raise BridgeProtocolError("Invalid compressed HTTP response") from error


def _accept_encoding(value):
    if not value.strip():
        return ""
    weights = {}
    for item in value.split(","):
        parts = item.strip().split(";")
        coding = parts[0].strip().lower()
        if not _TOKEN.fullmatch(coding) or coding in weights or len(parts) > 2:
            raise UnsupportedFeature("Invalid Accept-Encoding preference")
        weight = 1.0
        if len(parts) == 2:
            match = re.fullmatch(r"q\s*=\s*(0(?:\.[0-9]{0,3})?|1(?:\.0{0,3})?)", parts[1].strip(), re.I)
            if not match:
                raise UnsupportedFeature("Invalid Accept-Encoding weight")
            weight = float(match[1])
        weights[coding] = weight
    selected = {key: val for key, val in weights.items() if key in ("gzip", "deflate", "identity")}
    wildcard = weights.get("*")
    if wildcard is not None and wildcard > 0:
        for coding in ("gzip", "deflate"):
            selected.setdefault(coding, wildcard)
    identity = weights.get("identity", 0 if wildcard == 0 else 1)
    if identity == 0:
        selected["identity"] = 0
    if not any(weight > 0 for weight in selected.values()):
        if identity <= 0:
            raise UnsupportedFeature("No supported HTTP content encoding is acceptable")
        selected["identity"] = identity
    return ", ".join(coding if weight == 1 else f"{coding};q={weight:g}" for coding, weight in selected.items())


if _HAS_REQUESTS:
    class RequestsBridgeAdapter(HTTPAdapter):
        def __init__(self, bridge):
            if not callable(bridge):
                raise TypeError("bridge must be callable")
            self._bridge = bridge
            self._context = ContextVar("movie_python_http_call", default=None)
            self._closed = False

        @contextmanager
        def call(self, context):
            if not isinstance(context, CallContext):
                raise TypeError("Explicit CallContext required")
            context.check()
            token = self._context.set(context)
            try:
                yield
            finally:
                self._context.reset(token)

        def close(self):
            # requests.Session.close() may be followed by reuse of the Session
            # object (preserving cookies/headers); only shutdown() permanently closes.
            pass

        def shutdown(self):
            self._closed = True

        def send(self, request, stream=False, timeout=None, verify=True, cert=None, proxies=None):
            context = self._context.get()
            if self._closed:
                raise RequestException("Python source HTTP adapter is closed")
            if context is None:
                raise RequestException("HTTP request requires an active source call")
            context.check()
            if stream is not False:
                raise UnsupportedFeature("Streaming HTTP responses are unsupported")
            if not isinstance(verify, bool) or cert is not None or proxies:
                raise UnsupportedFeature("Custom certificates and proxies are unsupported")
            method = request.method
            if method not in _METHODS:
                raise UnsupportedFeature("Unsupported HTTP method")
            url = _url(request.url)
            body = request.body
            if body is None:
                body = b""
            elif isinstance(body, str):
                body = body.encode("utf-8")
            elif isinstance(body, (bytes, bytearray)):
                body = bytes(body)
            else:
                raise UnsupportedFeature("Streaming/file/custom HTTP bodies are unsupported")
            if len(body) > MAX_BODY:
                raise BodyLimitError("HTTP request exceeds 6 MiB")
            if body and method in ("GET", "HEAD"):
                raise UnsupportedFeature("GET/HEAD request bodies are unsupported")
            headers = _headers(list(request.headers.items()))
            clean = []
            for name, value in headers:
                if name == "content-type" and value.lower().startswith("multipart/"):
                    raise UnsupportedFeature("Multipart HTTP requests are unsupported")
                if name == "content-length":
                    if not value.isascii() or not value.isdigit() or int(value) != len(body):
                        raise BridgeProtocolError("HTTP request length mismatch")
                    continue
                if name == "connection" and value.lower() in ("keep-alive", "close"):
                    continue
                if name in ("host", "connection", "transfer-encoding", "upgrade", "trailer", "te", "proxy-connection"):
                    raise UnsupportedFeature("Custom HTTP transport/framing headers are unsupported")
                if name == "accept-encoding":
                    value = _accept_encoding(value)
                clean.append([name, value])
            if not any(name == "accept-encoding" for name, _ in clean):
                clean.append(["accept-encoding", "identity"])
            remaining = context.remaining_ms()
            connect, read = _timeout(timeout, remaining)
            envelope = {
                "version": 1,
                "callId": context.call_id,
                "requestId": uuid.uuid4().hex,
                "url": url,
                "method": method,
                "headers": clean,
                "body": body,
                "connectTimeoutMs": connect,
                "readTimeoutMs": read,
                "deadlineRemainingMs": remaining,
            }
            try:
                value = self._bridge(envelope, context)
            except BridgeTransportError as error:
                context.check()
                err_types = {
                    "timeout": Timeout,
                    "cancelled": CallCancelled,
                    "connection": ConnectionError,
                    "tls": SSLError,
                    "protocol": BridgeProtocolError,
                }
                raise err_types.get(error.kind, ConnectionError)(
                    "Python HTTP transport " + error.kind, request=request
                ) from error
            context.check()
            if self._closed:
                raise CallCancelled("Python HTTP source closed during request")
            required = {"version", "callId", "requestId", "url", "status", "reason", "headers", "body"}
            if not isinstance(value, dict) or set(value) != required:
                raise BridgeProtocolError("Invalid HTTP bridge response fields")
            if (
                type(value["version"]) is not int
                or value["version"] != 1
                or value["callId"] != envelope["callId"]
                or value["requestId"] != envelope["requestId"]
                or value["url"] != url
            ):
                raise BridgeProtocolError("Stale, mismatched or redirected HTTP bridge response")
            status, reason, wire = value["status"], value["reason"], value["body"]
            if (
                type(status) is not int
                or not 200 <= status <= 599
                or not isinstance(reason, str)
                or len(reason) > 512
                or _CONTROL.search(reason)
                or not isinstance(wire, bytes)
            ):
                raise BridgeProtocolError("Invalid HTTP status, reason or body")
            headers = _headers(value["headers"], response=True)
            decoded = _decoded_body(wire, headers, method, status)
            context.check()
            message, raw_headers = Message(), HTTPHeaderDict()
            for name, text in headers:
                message[name] = text
                raw_headers.add(name, text)
            original = SimpleNamespace(msg=message)
            raw = HTTPResponse(
                body=io.BytesIO(wire),
                status=status,
                reason=reason,
                headers=raw_headers,
                original_response=original,
                preload_content=False,
                decode_content=False,
                request_method=method,
                request_url=url,
            )
            response = self.build_response(request, raw)
            raw.close()
            response._content = decoded
            response._content_consumed = True
            response.url = url
            context.check()
            if self._closed:
                raise CallCancelled("Python HTTP source closed during response validation")
            return response

    class BridgeSession(requests.Session):
        def __init__(self, bridge):
            self._restricted_mount = False
            super().__init__()
            for adapter in self.adapters.values():
                adapter.close()
            self.adapters.clear()
            self.adapter = RequestsBridgeAdapter(bridge)
            self.mount("http://", self.adapter)
            self.mount("https://", self.adapter)
            self._restricted_mount = True
            self.trust_env = False
            self.max_redirects = 5
            self.headers["Accept-Encoding"] = "gzip, deflate"

        def mount(self, prefix, adapter):
            if getattr(self, "_restricted_mount", False):
                raise UnsupportedFeature("Custom HTTP adapters are unsupported")
            return super().mount(prefix, adapter)

        def rebuild_auth(self, prepared_request, response):
            super().rebuild_auth(prepared_request, response)
            previously_crossed = getattr(response.request, "_movie_crossed_origin", False)
            crossed = previously_crossed or _origin(prepared_request.url) != _origin(response.request.url)
            prepared_request._movie_crossed_origin = crossed
            if crossed:
                origin_jars = getattr(response.request, "_movie_redirect_cookies", {})
                if previously_crossed:
                    jar = origin_jars.setdefault(_origin(response.request.url), RequestsCookieJar())
                    extract_cookies_to_jar(jar, response.request, response.raw)
                prepared_request._movie_redirect_cookies = origin_jars
                for key in ("Authorization", "Proxy-Authorization", "Cookie", "Cookie2"):
                    prepared_request.headers.pop(key, None)
                prepared_request.prepare_cookies(
                    origin_jars.get(_origin(prepared_request.url), RequestsCookieJar())
                )

        def call(self, context):
            return self.adapter.call(context)


def _path(value):
    if not isinstance(value, str) or not value or len(value) > 1024:
        raise SourceContractError("Invalid package path")
    value = unicodedata.normalize("NFC", value)
    if (
        value.startswith("/")
        or "\\" in value
        or ":" in value
        or any(ord(c) < 32 or ord(c) == 127 for c in value)
        or any(part in ("", ".", "..") for part in value.split("/"))
    ):
        raise SourceContractError("Package path escapes virtual root")
    return value


def validate_package(entry, files):
    if not isinstance(files, dict) or not 1 <= len(files) <= 256:
        raise SourceContractError("Package requires 1..256 files")
    normalized, folded, total = {}, set(), 0
    for name, content in files.items():
        name = _path(name)
        if name.casefold() in folded:
            raise SourceContractError("Duplicate normalized package path")
        if not isinstance(content, bytes) or len(content) > 2 * 1024 * 1024:
            raise SourceContractError("Package files must be bytes and at most 2 MiB")
        total += len(content)
        if total > MAX_BODY:
            raise SourceContractError("Package exceeds 6 MiB")
        folded.add(name.casefold())
        normalized[name] = content
    for name in normalized:
        parts = name.split("/")
        if any("/".join(parts[:i]).casefold() in folded for i in range(1, len(parts))):
            raise SourceContractError("Package file conflicts with directory")
        if name.endswith(".py") and not name.endswith("/__init__.py"):
            module = name[:-3].casefold() + "/"
            if any(other.startswith(module) for other in folded):
                raise SourceContractError("Package module conflicts with directory")
    entry = _path(entry)
    if entry not in normalized or not entry.endswith(".py"):
        raise SourceContractError("Python package entry is missing")
    return entry, normalized


class _MemoryPath(importlib.resources.abc.Traversable):
    def __init__(self, source, path):
        self.source, self.path = source, path

    @property
    def name(self):
        return self.path.rsplit("/", 1)[-1]

    def is_file(self):
        self.source._ensure_open()
        return self.path in self.source.files

    def is_dir(self):
        self.source._ensure_open()
        return not self.path or any(p.startswith(self.path + "/") for p in self.source.files)

    def iterdir(self):
        self.source._ensure_open()
        prefix = self.path + "/" if self.path else ""
        if not self.is_dir():
            raise NotADirectoryError(self.path)
        names = sorted({p[len(prefix):].split("/", 1)[0] for p in self.source.files if p.startswith(prefix)})
        return iter(_MemoryPath(self.source, prefix + name) for name in names)

    def joinpath(self, *descendants):
        self.source._ensure_open()
        parts = [self.path] if self.path else []
        for child in descendants:
            parts.append(_path(child))
        return _MemoryPath(self.source, "/".join(parts))

    def open(self, mode="r", *args, **kwargs):
        self.source._ensure_open()
        if mode not in ("r", "rb"):
            raise UnsupportedFeature("Package resources are read-only")
        raw = io.BytesIO(self.source._read_file(self.path))
        self.source._resource_streams.add(raw)
        if mode == "rb":
            if args or kwargs:
                raise ValueError("Binary resources do not accept text options")
            return raw
        return io.TextIOWrapper(raw, *args, **kwargs)


class _Resources(importlib.resources.abc.TraversableResources):
    def __init__(self, source, directory):
        self.source, self.directory = source, directory

    def files(self):
        self.source._ensure_open()
        return _MemoryPath(self.source, self.directory)


class _PackageFile(io.RawIOBase):
    def __init__(self, data, name):
        super().__init__()
        self._data = io.BytesIO(data)
        self.name, self.mode = name, "rb"

    def readable(self):
        self._checkClosed()
        return True

    def seekable(self):
        self._checkClosed()
        return True

    def readinto(self, buffer):
        self._checkClosed()
        return self._data.readinto(buffer)

    def tell(self):
        self._checkClosed()
        return self._data.tell()

    def seek(self, offset, whence=0):
        self._checkClosed()
        offset, whence = operator.index(offset), operator.index(whence)
        if whence not in (0, 1, 2):
            raise ValueError("Invalid seek origin")
        position = offset + (
            self._data.tell() if whence == 1 else len(self._data.getbuffer()) if whence == 2 else 0
        )
        if position < 0:
            raise OSError("Negative file position")
        return self._data.seek(position)

    def close(self):
        self._data.close()
        super().close()


class _MemoryLoader(importlib.abc.SourceLoader):
    def __init__(self, source, path, directory, package):
        self.source, self.path, self.directory, self.package = source, path, directory, package

    def get_filename(self, fullname):
        self.source._ensure_open()
        rel = self.path or (self.directory + "/__init__.py" if self.directory else "__init__.py")
        return "/__package__/" + rel

    def get_data(self, path):
        self.source._ensure_open()
        if not isinstance(path, str):
            raise SourceContractError("Resource address is outside this source")
        normalized = path.replace("\\", "/")
        if path.startswith(self.source.origin):
            relative = _path(unquote(path[len(self.source.origin):].replace("\\", "/")))
        elif normalized.startswith("/__package__/"):
            relative = _path(normalized[len("/__package__/"):])
        else:
            raise SourceContractError("Resource address is outside this source")
        return self.source._read_file(relative)

    def get_code(self, fullname):
        self.source._ensure_open()
        return compile(
            self.source.files[self.path] if self.path else b"",
            self.get_filename(fullname),
            "exec",
            dont_inherit=True,
        )

    def is_package(self, fullname):
        return self.package

    def exec_module(self, module):
        self.source._loaded[module.__name__] = module
        super().exec_module(module)

    def get_resource_reader(self, fullname):
        return _Resources(self.source, self.directory) if self.package else None


class _Finder(importlib.abc.MetaPathFinder):
    def __init__(self, source):
        self.source = source

    def find_spec(self, fullname, path=None, target=None):
        source = self.source
        source._ensure_open()
        name = fullname
        if source.entry == "__init__.py" and (name == "_movie_source" or name.startswith("_movie_source.")):
            name = name[len("_movie_source"):].lstrip(".")
        relative = name.replace(".", "/")
        directory = source.entry.rpartition("/")[0]
        if path is None and directory and "." not in name:
            sibling = directory + "/" + relative
            if sibling + ".py" in source.files or any(p.startswith(sibling + "/") for p in source.files):
                relative = sibling
        elif path and len(path) == 1 and str(path[0]).startswith(source.origin):
            parent = unquote(str(path[0])[len(source.origin):]).strip("/")
            relative = (parent + "/" if parent else "") + name.rsplit(".", 1)[-1]
        package_path = relative + "/__init__.py" if relative else "__init__.py"
        if package_path in source.files:
            file, directory, package = package_path, relative, True
        elif relative + ".py" in source.files:
            file, directory, package = relative + ".py", relative.rpartition("/")[0], False
        elif relative and any(p.startswith(relative + "/") for p in source.files):
            file, directory, package = None, relative, True
        else:
            return None
        loader = _MemoryLoader(source, file, directory, package)
        spec = importlib.util.spec_from_loader(fullname, loader, is_package=package)
        if package:
            spec.submodule_search_locations = [source.origin + quote(directory)]
        return spec


class _RemoteFinder(importlib.abc.MetaPathFinder):
    def __init__(self, source):
        self.source = source

    def find_spec(self, fullname, path=None, target=None):
        source = self.source
        name = fullname
        if source.entry == "__init__.py" and name.startswith("_movie_source."):
            name = name[len("_movie_source."):]
        names = name.split(".")
        if (
            not all(part.isidentifier() for part in names)
            or names[0] in source._reserved
            or (path is not None and not all(str(p).startswith(source.origin) for p in path))
        ):
            return None
        relative = "/".join(names)
        for candidate in (relative + "/__init__.py", relative + ".py"):
            try:
                source._read_file(candidate)
            except FileNotFoundError:
                continue
            return source._finder.find_spec(fullname, path, target)
        return None


class _OperationContext(CallContext):
    def __init__(self, budget, cancellation, operation_id):
        super().__init__(budget, call_id=operation_id)
        self.external = cancellation

    @property
    def cancelled(self):
        return super().cancelled or (self.external is not None and bool(self.external()))


class DesktopSpiderBase:
    """TVBox-compatible Spider base class exposed as base.spider.Spider & com.github.catvod.crawler.Spider."""

    def __init__(self):
        self.extend = ""

    def init(self, extend=""):
        self.extend = extend

    def getName(self):
        return ""

    def isVideoFormat(self, url):
        return False

    def manualVideoCheck(self):
        return False

    def getDependence(self):
        return []

    def destroy(self):
        pass

    @staticmethod
    def regStr(reg, src, group=1):
        found = re.search(reg, src)
        return "" if found is None else found.group(group)

    @staticmethod
    def removeHtmlTags(src):
        return re.sub(r"<.*?>", "", src)

    @staticmethod
    def cleanText(src):
        return re.sub(
            "[\U0001F600-\U0001F64F\U0001F300-\U0001F5FF"
            "\U0001F680-\U0001F6FF\U0001F1E0-\U0001F1FF]",
            "",
            src,
        )

    @staticmethod
    def html(content):
        from lxml import etree
        return etree.HTML(content)

    @staticmethod
    def str2json(value):
        return json.loads(value)

    @staticmethod
    def json2str(value):
        return json.dumps(value, ensure_ascii=False)

    @staticmethod
    def log(message):
        print(
            json.dumps(message, ensure_ascii=False)
            if isinstance(message, (dict, list))
            else str(message),
            file=sys.stderr,
        )

    @staticmethod
    def page(items, pg, limit, total=None):
        if isinstance(limit, bool) or not isinstance(limit, int) or limit < 1:
            raise ValueError("page requires a positive limit")
        page = max(1, int(pg))
        if total is None:
            total = len(items)
            start = (page - 1) * limit
            items = items[start : start + limit]
        if isinstance(total, bool) or not isinstance(total, int) or total < 0:
            raise ValueError("page requires a nonnegative total")
        pages = max(1, (total + limit - 1) // limit)
        return dict(list=items, page=page, pagecount=pages, limit=limit, total=total)

    def fetch(self, url, **kwargs):
        if not _HAS_REQUESTS:
            raise UnsupportedFeature("requests package is unavailable")
        return requests.get(url, **kwargs)

    def post(self, url, **kwargs):
        if not _HAS_REQUESTS:
            raise UnsupportedFeature("requests package is unavailable")
        return requests.post(url, **kwargs)

    def getProxyUrl(self, params=None, local=True):
        return _ACTIVE_HOST.proxy_url(params, local, legacy=True)

    def proxyUrl(self, params=None, local=True):
        return _ACTIVE_HOST.proxy_url(params, local)

    def setCache(self, key, value):
        _ACTIVE_CACHE[str(key)] = value

    def getCache(self, key):
        return _ACTIVE_CACHE.get(str(key))

    def loadSpider(self, name):
        return None

    def homeContent(self, filter):
        raise NotImplementedError("Python Spider is missing homeContent")

    def homeVideoContent(self):
        raise NotImplementedError("Python Spider is missing homeVideoContent")

    def categoryContent(self, tid, pg, filter, extend):
        raise NotImplementedError("Python Spider is missing categoryContent")

    def detailContent(self, ids):
        raise NotImplementedError("Python Spider is missing detailContent")

    def searchContent(self, key, quick, pg="1"):
        raise NotImplementedError("Python Spider is missing searchContent")

    def playerContent(self, flag, id, vipFlags):
        raise NotImplementedError("Python Spider is missing playerContent")


_ACTIVE_HOST = None
_ACTIVE_CACHE: dict[str, object] = {}


def normalize_proxy(value):
    if not isinstance(value, (list, tuple)) or not 3 <= len(value) <= 5:
        raise SourceContractError("Proxy requires status, MIME, body, optional headers and Base64 flag")
    status, mime, body = value[:3]
    flag = value[4] if len(value) == 5 else 0
    if (
        type(status) is not int
        or not 200 <= status <= 599
        or not isinstance(mime, str)
        or len(mime) > 256
        or not _MIME.fullmatch(mime)
        or any(ord(c) < 32 or ord(c) > 126 for c in mime)
        or type(flag) is not int
        or flag not in (0, 1)
    ):
        raise SourceContractError("Invalid proxy response metadata")
    headers = value[3] if len(value) > 3 and value[3] is not None else {}
    if not isinstance(headers, dict) or len(headers) > 64:
        raise SourceContractError("Invalid proxy response headers")
    seen, size = set(), 0
    for key, text in headers.items():
        if (
            not isinstance(key, str)
            or not re.fullmatch(_TOKEN, key)
            or key.lower() in seen
            or not isinstance(text, str)
            or re.search(r"[\x00-\x08\x0a-\x1f\x7f]", text)
            or any(ord(c) > 255 for c in text)
        ):
            raise SourceContractError("Invalid proxy response header")
        seen.add(key.lower())
        size += len(key.encode("ascii")) + len(text.encode("latin-1"))
    if size > 16384:
        raise SourceContractError("Proxy response headers exceed limit")

    # Support stream / file-like objects and chunk iterables returned by localProxy.
    if hasattr(body, "read") and callable(body.read):
        chunks = []
        total = 0
        while True:
            chunk = body.read(65536)
            if not chunk:
                break
            if isinstance(chunk, str):
                chunk = chunk.encode("utf-8")
            elif isinstance(chunk, (bytearray, memoryview)):
                chunk = bytes(chunk)
            elif not isinstance(chunk, bytes):
                raise SourceContractError("Proxy stream must yield bytes or text")
            total += len(chunk)
            if total > MAX_BODY:
                raise SourceContractError("Proxy body exceeds limit")
            chunks.append(chunk)
        body = b"".join(chunks)
    elif isinstance(body, memoryview):
        body = bytes(body)
    elif not isinstance(body, (bytes, bytearray, str, list)) and hasattr(body, "__iter__"):
        chunks = []
        total = 0
        for chunk in body:
            if isinstance(chunk, str):
                chunk = chunk.encode("utf-8")
            elif isinstance(chunk, (bytearray, memoryview)):
                chunk = bytes(chunk)
            elif not isinstance(chunk, bytes):
                raise SourceContractError("Proxy stream iterable must yield bytes or text")
            total += len(chunk)
            if total > MAX_BODY:
                raise SourceContractError("Proxy body exceeds limit")
            chunks.append(chunk)
        body = b"".join(chunks)

    if isinstance(body, list):
        if len(body) > MAX_BODY or any(type(v) is not int or not 0 <= v <= 255 for v in body):
            raise SourceContractError("Invalid proxy bytes")
        body = bytes(body)
    if isinstance(body, (bytes, bytearray)):
        if len(body) > MAX_BODY:
            raise SourceContractError("Proxy body exceeds limit")
        return [status, mime, base64.b64encode(body).decode("ascii"), dict(headers), 1]
    if not isinstance(body, str):
        raise SourceContractError("Proxy body must be text or bytes")
    if flag:
        if len(body) > ((MAX_BODY + 2) // 3) * 4 + 1280:
            raise SourceContractError("Proxy Base64 exceeds limit")
        text = body
        if text.startswith("data:"):
            prefix, separator, text = text.partition(",")
            if not separator or len(prefix) > 256 or not re.fullmatch(r"data:[\x20-\x7e]*;base64", prefix):
                raise SourceContractError("Invalid proxy data URL")
        text = re.sub(r"[ \t\r\n]", "", text)
        try:
            decoded = base64.b64decode(text, validate=True)
        except (ValueError, TypeError) as error:
            raise SourceContractError("Invalid proxy Base64") from error
        if len(decoded) > MAX_BODY or base64.b64encode(decoded).decode() != text:
            raise SourceContractError("Non-canonical proxy Base64")
        body = text
    elif len(body.encode("utf-8")) > MAX_BODY:
        raise SourceContractError("Proxy text exceeds limit")
    return [status, mime, body, dict(headers), flag]


class DesktopPythonSource:
    def __init__(self, entry, files, *, bridge, extension="", raw_extension=None, proxy_url=None, remote=None):
        self.entry, self.files = validate_package(entry, files)
        if not callable(bridge) or (raw_extension is not None and not isinstance(raw_extension, str)):
            raise SourceContractError("A real bridge and valid raw extension are required")
        self.ext = (
            raw_extension
            if raw_extension is not None
            else extension
            if isinstance(extension, str)
            else json.dumps(extension, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
        )
        if len(self.ext.encode("utf-8")) > 64 * 1024:
            raise SourceContractError("Source extension exceeds limit")
        self._proxy = self._validate_proxy(proxy_url)
        self._remote_url = None
        self._remote_headers = {}
        if remote is not None:
            if not isinstance(remote, dict) or set(remote) != {"url", "headers"} or not isinstance(remote["headers"], dict):
                raise SourceContractError("Invalid remote Python source descriptor")
            self._remote_url = _url(remote["url"])
            self._remote_headers = dict(_headers(list(remote["headers"].items())))
        reserved = set(sys.stdlib_module_names) | {
            "base",
            "com",
            "requests",
            "urllib3",
            "desktop_runner",
            "_movie_source",
        }
        self._reserved = reserved | set(sys.modules)
        for path in self.files:
            root = path.split("/", 1)[0]
            root = root[:-3] if root.endswith(".py") else root
            if root in reserved or root in sys.modules:
                raise SourceContractError("Package cannot shadow an existing host module")
            if path.endswith(".py"):
                names = path[:-3].split("/")
                if not all(part.isidentifier() for part in names):
                    raise SourceContractError("Python module path must contain valid identifiers")
                if names[0] in reserved or names[0] in sys.modules:
                    raise SourceContractError("Package cannot shadow an existing host module")
            if path.lower().endswith((".so", ".dylib", ".dll", ".pyd", ".pth")):
                raise UnsupportedFeature("Package native extensions and path hooks are unsupported")
        self.origin = "pkg://" + uuid.uuid4().hex + "/"
        self.bridge = bridge
        self._closed = False
        self._failed = False
        self._state = "new"
        self._context = None
        self._sessions = weakref.WeakSet()
        self._resource_streams = weakref.WeakSet()
        self._loaded = {}
        self._patches = []
        self._finder = _Finder(self)
        self._remote_finder = _RemoteFinder(self) if self._remote_url else None
        self._missing_files = set()
        self._spider = None
        self._requests = 0

    @staticmethod
    def _validate_proxy(value):
        if value is None:
            return None
        if not isinstance(value, str) or len(value) > 8192:
            raise SourceContractError("Invalid local proxy address")
        url = urlsplit(value)
        query = parse_qsl(url.query, keep_blank_values=True)
        if (
            url.scheme != "http"
            or url.hostname != "127.0.0.1"
            or not url.port
            or url.username is not None
            or url.password is not None
            or url.fragment
            or not url.path.startswith("/")
            or any(p in (".", "..") for p in url.path.split("/"))
            or len({k.lower() for k, _ in query}) != len(query)
            or dict(query).get("do") != "py"
            or not dict(query).get("siteKey")
        ):
            raise SourceContractError("Only a source-owned loopback Python proxy is accepted")
        return value

    def _ensure_open(self):
        if self._closed:
            raise SourceContractError("Native Python source is closed")

    def _current(self):
        self._ensure_open()
        if self._context is None:
            raise SourceContractError("Source networking requires an active operation")
        self._context.check()
        return self._context

    def _network(self, envelope, context):
        if self._current() is not context:
            raise SourceContractError("HTTP request belongs to another operation")
        self._requests += 1
        if self._requests > 32:
            raise SourceContractError("Source operation exceeds 32 HTTP hops")
        return self.bridge(envelope, context)

    def _read_file(self, relative):
        self._ensure_open()
        relative = _path(relative)
        if relative in self.files:
            return self.files[relative]
        if not self._remote_url or relative in self._missing_files:
            raise FileNotFoundError(relative)
        root = relative.split("/", 1)[0]
        root = root[:-3] if root.endswith(".py") else root
        if root in self._reserved:
            raise SourceContractError("Remote package cannot shadow a host module")
        if relative.lower().endswith((".so", ".dylib", ".dll", ".pyd", ".pth")):
            raise UnsupportedFeature("Remote native extensions and path hooks are unsupported")
        self._current()
        if not _HAS_REQUESTS:
            raise UnsupportedFeature("requests package is unavailable")
        address = urljoin(self._remote_url, quote(relative, safe="/"))
        with requests.Session() as session:
            response = session.get(address, headers=self._remote_headers)
        if response.status_code == 404:
            if len(self._missing_files) >= 256:
                raise SourceContractError("Too many missing remote package files")
            self._missing_files.add(relative)
            raise FileNotFoundError(relative)
        response.raise_for_status()
        _, files = validate_package(self.entry, {**self.files, relative: response.content})
        self.files = files
        return self.files[relative]

    def _install(self):
        global _ACTIVE_HOST
        _ACTIVE_HOST = self
        owner = self

        original_open = builtins.open

        def package_open(
            file,
            mode="r",
            buffering=-1,
            encoding=None,
            errors=None,
            newline=None,
            closefd=True,
            opener=None,
        ):
            if isinstance(file, int):
                return original_open(file, mode, buffering, encoding, errors, newline, closefd, opener)
            name = os.fsdecode(os.fspath(file))
            norm_name = name.replace("\\", "/")
            virtual = norm_name.startswith(("pkg:", "/__package__/"))
            if os.path.isabs(name) and not virtual:
                return original_open(file, mode, buffering, encoding, errors, newline, closefd, opener)
            owner._ensure_open()
            if not isinstance(mode, str) or mode not in ("r", "rt", "rb", "br", "tr"):
                raise ValueError("Package files only support read mode")
            binary = "b" in mode
            buffering = operator.index(buffering)
            if not closefd or opener is not None:
                raise ValueError("Package files have no filesystem descriptor")
            if binary and any(v is not None for v in (encoding, errors, newline)):
                raise ValueError("Binary mode does not accept text options")
            if not binary and buffering == 0:
                raise ValueError("Unbuffered text I/O is unavailable")
            if name.startswith(owner.origin):
                relative = unquote(name[len(owner.origin):])
            elif name.startswith(owner.origin.replace("://", ":/")):
                relative = unquote(name[len(owner.origin.replace("://", ":/")):])
            elif norm_name.startswith("/__package__/"):
                relative = norm_name[len("/__package__/"):]
            elif norm_name.startswith("pkg:"):
                raise SourceContractError("File belongs to another source")
            else:
                directory = owner.entry.rpartition("/")[0]
                relative = (directory + "/" if directory else "") + name
            parts = []
            for part in relative.replace("\\", "/").split("/"):
                if part in ("", "."):
                    continue
                if part == "..":
                    if not parts:
                        raise SourceContractError("File escapes package root")
                    parts.pop()
                else:
                    parts.append(part)
            relative = _path("/".join(parts))
            if any(p.startswith(relative + "/") for p in owner.files):
                raise IsADirectoryError(name)
            raw = _PackageFile(owner._read_file(relative), name)
            try:
                stream = (
                    raw
                    if buffering == 0
                    else io.BufferedReader(raw, buffering if buffering > 1 else io.DEFAULT_BUFFER_SIZE)
                )
                if not binary:
                    stream = io.TextIOWrapper(stream, encoding or "utf-8", errors, newline)
                    stream.mode = mode
            except BaseException:
                raw.close()
                raise
            owner._resource_streams.add(stream)
            return stream

        if _HAS_REQUESTS:
            class ManagedSession(BridgeSession):
                def __init__(self):
                    owner._current()
                    if len(owner._sessions) >= 32:
                        raise SourceContractError("Too many retained HTTP sessions")
                    super().__init__(owner._network)
                    self._initial_headers = self.headers.copy()
                    owner._sessions.add(self)

                def prepare_request(self, request):
                    prepared = super().prepare_request(request)
                    if owner._remote_url and _origin(prepared.url) == _origin(owner._remote_url):
                        headers = requests.structures.CaseInsensitiveDict(request.headers or {})
                        for name, value in owner._remote_headers.items():
                            if (
                                name not in headers
                                and self.headers.get(name) == self._initial_headers.get(name)
                                and not (name == "cookie" and "cookie" in prepared.headers)
                            ):
                                prepared.headers[name] = value
                    return prepared

                def send(self, request, **kwargs):
                    with self.call(owner._current()):
                        return super().send(request, **kwargs)

                def close(self):
                    super().close()

            class UnsupportedAdapter(requests.adapters.BaseAdapter):
                def __init__(self, *args, **kwargs):
                    pass

                def send(self, *args, **kwargs):
                    raise UnsupportedFeature("Custom socket HTTPAdapter is not available in the native source profile")

                def close(self):
                    pass

            for module, key, value in (
                (requests, "Session", ManagedSession),
                (requests.sessions, "Session", ManagedSession),
                (requests.sessions, "HTTPAdapter", UnsupportedAdapter),
                (requests.adapters, "HTTPAdapter", UnsupportedAdapter),
            ):
                self._patches.append((module, key, getattr(module, key)))
                setattr(module, key, value)

        base = types.ModuleType("base")
        base.__path__ = ["marco://python-native/base"]
        base.__package__ = "base"
        spider_mod = types.ModuleType("base.spider")
        spider_mod.__file__ = "marco://python-native/base/spider.py"
        spider_mod.__package__ = "base"
        spider_mod.Spider = DesktopSpiderBase

        local_proxy_mod = types.ModuleType("base.localProxy")
        local_proxy_mod.__file__ = "marco://python-native/base/localProxy.py"
        local_proxy_mod.__package__ = "base"

        class Proxy:
            @staticmethod
            def getUrl():
                return owner.proxy_url()

        local_proxy_mod.Proxy = Proxy
        base.spider = spider_mod
        base.localProxy = local_proxy_mod

        com_mod = types.ModuleType("com")
        com_mod.__path__ = ["marco://python-native/com"]
        github_mod = types.ModuleType("com.github")
        github_mod.__path__ = ["marco://python-native/com/github"]
        catvod_mod = types.ModuleType("com.github.catvod")
        catvod_mod.__path__ = ["marco://python-native/com/github/catvod"]
        crawler_mod = types.ModuleType("com.github.catvod.crawler")
        crawler_mod.__path__ = ["marco://python-native/com/github/catvod/crawler"]
        crawler_mod.Spider = DesktopSpiderBase
        crawler_spider_mod = types.ModuleType("com.github.catvod.crawler.Spider")
        crawler_spider_mod.Spider = DesktopSpiderBase
        com_mod.github = github_mod
        github_mod.catvod = catvod_mod
        catvod_mod.crawler = crawler_mod

        shims = {
            "base": base,
            "base.spider": spider_mod,
            "base.localProxy": local_proxy_mod,
            "com": com_mod,
            "com.github": github_mod,
            "com.github.catvod": catvod_mod,
            "com.github.catvod.crawler": crawler_mod,
            "com.github.catvod.crawler.Spider": crawler_spider_mod,
        }
        sys.modules.update(shims)
        self._loaded.update(shims)

        sys.meta_path.insert(0, self._finder)
        if self._remote_finder:
            sys.meta_path.append(self._remote_finder)
        for module in (builtins, io):
            self._patches.append((module, "open", module.open))
            module.open = package_open

    def _load_dependencies(self):
        fn = getattr(self._spider, "getDependence", None)
        if not callable(fn):
            return
        deps = fn()
        if not isinstance(deps, (list, tuple)):
            return
        for dep in deps:
            if not isinstance(dep, str):
                continue
            mod_name = dep.strip()
            if not mod_name:
                continue
            if mod_name.endswith(".py"):
                mod_name = mod_name[:-3]
            mod_name = mod_name.replace("\\", "/").strip("/").replace("/", ".")
            if not mod_name or not all(part.isidentifier() for part in mod_name.split(".")):
                continue
            if mod_name in self._reserved:
                continue
            importlib.import_module(mod_name)

    def _initialize(self):
        if self._state != "new":
            if self._state != "ready":
                raise SourceContractError("Source initialization failed and cannot be replayed")
            return
        self._state = "loading"
        self._install()
        if self.entry == "__init__.py":
            name = "_movie_source"
        else:
            name = self.entry[:-3].replace("/", ".")
            if name.endswith(".__init__"):
                name = name[: -len(".__init__")]
        module = importlib.import_module(name)
        cls = getattr(module, "Spider", None)
        if not inspect.isclass(cls):
            for _, obj in inspect.getmembers(module, inspect.isclass):
                if obj is not DesktopSpiderBase and issubclass(obj, DesktopSpiderBase):
                    cls = obj
                    break
        if not inspect.isclass(cls):
            raise SourceContractError("Python source must export a Spider class")
        self._spider = cls()
        self._spider.extend = self.ext
        self._load_dependencies()
        init_fn = getattr(self._spider, "init", None)
        if callable(init_fn):
            sig = inspect.signature(init_fn)
            has_varargs = any(
                p.kind in (inspect.Parameter.VAR_POSITIONAL, inspect.Parameter.VAR_KEYWORD)
                for p in sig.parameters.values()
            )
            positional = [
                p
                for p in sig.parameters.values()
                if p.kind in (inspect.Parameter.POSITIONAL_ONLY, inspect.Parameter.POSITIONAL_OR_KEYWORD)
            ]
            if len(positional) == 0 and not has_varargs:
                self._call("init", [])
            else:
                self._call("init", [self.ext])
        self._state = "ready"

    def _call(self, name, args):
        method = getattr(self._spider, name, None)
        if not callable(method):
            raise SourceContractError("Python Spider is missing " + name)
        result = method(*args)
        if inspect.isawaitable(result):
            if inspect.iscoroutine(result):
                result.close()
            raise UnsupportedFeature("Coroutine Spider methods are not supported by this synchronous profile")
        return result

    def invoke(self, method, args, *, budget=12, cancellation=None, operation_id=None):
        self._ensure_open()
        if self._failed or self._state == "failed":
            raise SourceContractError("Failed source cannot be invoked or initialized again")
        if self._context is not None:
            raise SourceContractError("Source operations must be serialized")
        if not isinstance(args, list) or (cancellation is not None and not callable(cancellation)):
            raise SourceContractError("Invalid operation arguments")
        if operation_id is not None and (
            not isinstance(operation_id, str) or _IDENTITY.fullmatch(operation_id) is None
        ):
            raise SourceContractError("Invalid native operation identity")

        aliases = {
            "homeContent": "home",
            "homeVideoContent": "homeVod",
            "categoryContent": "category",
            "searchContent": "search",
            "detailContent": "detail",
            "playerContent": "play",
            "localProxy": "proxy",
        }
        canonical = aliases.get(method, method)
        counts = {
            "init": (0, 1),
            "home": (1, 1),
            "homeVod": (0, 0),
            "category": (4, 4),
            "search": (2, 3),
            "detail": (1, 1),
            "play": (3, 3),
            "proxy": (1, 1),
            "liveContent": (1, 1),
        }
        if canonical not in counts:
            raise SourceContractError("Invalid Spider operation")
        min_args, max_args = counts[canonical]
        if not (min_args <= len(args) <= max_args):
            raise SourceContractError("Invalid Spider operation arity")

        self._context = _OperationContext(budget, cancellation, operation_id)
        self._requests = 0
        try:
            self._current()
            self._initialize()
            self._current()
            if canonical == "init":
                result = {"ok": True}
            elif canonical == "search":
                fn = getattr(self._spider, "searchContent", None)
                if not callable(fn):
                    raise SourceContractError("Python Spider is missing searchContent")
                signature = inspect.signature(fn)
                if len(args) >= 3:
                    selected = [args[0], args[1], str(args[2])]
                    try:
                        signature.bind(*selected)
                    except TypeError:
                        selected = args[:2]
                        signature.bind(*selected)
                else:
                    selected = args[:2]
                    signature.bind(*selected)
                result = self._call("searchContent", selected)
            elif canonical == "proxy":
                name = "localProxy" if callable(getattr(self._spider, "localProxy", None)) else "proxy"
                result = normalize_proxy(self._call(name, args))
            else:
                names = {
                    "home": "homeContent",
                    "homeVod": "homeVideoContent",
                    "category": "categoryContent",
                    "detail": "detailContent",
                    "play": "playerContent",
                    "liveContent": "liveContent",
                }
                if canonical == "category":
                    selected = [args[0], str(args[1]), args[2], args[3]]
                elif canonical == "detail":
                    selected = [args[0] if isinstance(args[0], list) else [args[0]]]
                else:
                    selected = args
                result = self._call(names[canonical], selected)

            if canonical != "proxy" and isinstance(result, str):
                try:
                    result = json.loads(result)
                except json.JSONDecodeError:
                    if canonical != "liveContent":
                        raise
            wire = json.dumps(result, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
            limit = 8 * 1024 * 1024 + 128 * 1024 if canonical == "proxy" else MAX_BODY
            if len(wire.encode("utf-8")) > limit:
                raise SourceContractError("Spider response exceeds limit")
            self._current()
            return result
        except BaseException:
            self._failed = True
            if self._state != "ready":
                self._state = "failed"
            raise
        finally:
            self._context = None

    def proxy_url(self, params=None, local=True, *, legacy=False):
        self._current()
        if self._proxy is None:
            raise UnsupportedFeature("Source-owned local proxy bridge is unavailable")
        if legacy and isinstance(params, bool):
            local, params = params, None
        if type(local) is not bool:
            raise TypeError("Proxy local flag must be a boolean")
        if legacy:
            params = {} if params is None else dict(params)
        elif params is None:
            params = {}
        if not isinstance(params, dict):
            raise TypeError("Proxy parameters must be a dict")
        for key, value in params.items():
            if not isinstance(key, str) or key.lower() in ("do", "sitekey"):
                raise ValueError("Invalid or reserved proxy parameter")
            if not isinstance(value, str) and not (legacy and type(value) in (int, bool)):
                raise TypeError("Proxy parameter values must be strings")
        value = self._proxy + ("&" + urlencode(params) if params else "")
        if len(value) > 8192:
            raise ValueError("Proxy URL exceeds limit")
        return value

    def close(self):
        if self._closed:
            return
        self._closed = True
        if self._context is not None:
            self._context.cancel()
        if self._spider is not None:
            destroy = getattr(self._spider, "destroy", None)
            if callable(destroy):
                try:
                    destroy()
                except Exception:
                    pass
        if _HAS_REQUESTS:
            for session in list(self._sessions):
                session.adapter.shutdown()
        self._sessions.clear()
        for stream in list(self._resource_streams):
            stream.close()
        self._resource_streams.clear()
        if self._finder in sys.meta_path:
            sys.meta_path.remove(self._finder)
        if self._remote_finder in sys.meta_path:
            sys.meta_path.remove(self._remote_finder)
        for name, module in self._loaded.items():
            if sys.modules.get(name) is module:
                del sys.modules[name]
        for module, key, value in reversed(self._patches):
            setattr(module, key, value)
        self._loaded.clear()


class _RpcRunner:
    def __init__(self):
        self._source: DesktopPythonSource | None = None
        self._cancelled_calls: set[str] = set()
        self._active_call_id: str | None = None
        self._active_cancel = threading.Event()
        self._state_lock = threading.Lock()
        self._http_waiters: dict[str, tuple[threading.Event, dict]] = {}
        self._http_lock = threading.Lock()
        self._tasks: queue.Queue = queue.Queue()
        self._shutdown = threading.Event()
        self._worker = threading.Thread(target=self._worker_loop, name="marco-py-worker", daemon=True)
        self._worker.start()

    @staticmethod
    def _send(payload: dict):
        line = json.dumps(payload, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
        with _RPC_WRITE_LOCK:
            _RPC_OUT.write(line + "\n")
            _RPC_OUT.flush()

    def _http_bridge(self, envelope: dict, context: CallContext) -> dict:
        http_id = uuid.uuid4().hex
        event = threading.Event()
        holder: dict = {}
        with self._http_lock:
            self._http_waiters[http_id] = (event, holder)
        try:
            wire_env = {
                "version": envelope["version"],
                "callId": envelope["callId"],
                "requestId": envelope["requestId"],
                "url": envelope["url"],
                "method": envelope["method"],
                "headers": envelope["headers"],
                "body_b64": base64.b64encode(envelope["body"]).decode("ascii"),
                "connectTimeoutMs": envelope["connectTimeoutMs"],
                "readTimeoutMs": envelope["readTimeoutMs"],
                "deadlineRemainingMs": envelope["deadlineRemainingMs"],
            }
            self._send({"type": "http", "id": http_id, "params": wire_env})
            while not event.is_set():
                if self._shutdown.is_set() or context.cancelled:
                    raise BridgeTransportError("cancelled")
                if time.monotonic() >= context.deadline:
                    raise BridgeTransportError("timeout")
                event.wait(timeout=0.05)
            if not holder.get("ok"):
                raise BridgeTransportError(str(holder.get("kind") or "connection"))
            res = dict(holder["result"])
            body_b64 = res.pop("body_b64", "")
            res["body"] = base64.b64decode(body_b64) if body_b64 else b""
            return res
        finally:
            with self._http_lock:
                self._http_waiters.pop(http_id, None)

    def _error_code(self, exc: BaseException) -> str:
        if isinstance(exc, CallCancelled):
            return "cancelled"
        if isinstance(exc, Timeout):
            return "timeout"
        if isinstance(exc, (SourceContractError, UnsupportedFeature)):
            return "invalid_request"
        return "python_error"

    def _handle_open(self, params: dict):
        if self._source is not None:
            raise SourceContractError("Session already opened")
        entry = params.get("entry")
        raw_files = params.get("files")
        if not isinstance(raw_files, dict):
            raise SourceContractError("Missing package files")
        files = {}
        for name, b64_text in raw_files.items():
            if not isinstance(name, str) or not isinstance(b64_text, str):
                raise SourceContractError("Invalid package file encoding")
            files[name] = base64.b64decode(b64_text, validate=True)
        extension = params.get("extension", "")
        proxy_url = params.get("proxy")
        remote = params.get("remote")
        self._source = DesktopPythonSource(
            entry,
            files,
            bridge=self._http_bridge,
            raw_extension=extension if isinstance(extension, str) else None,
            extension="" if isinstance(extension, str) else extension,
            proxy_url=proxy_url,
            remote=remote,
        )
        return {"opened": True}

    def _handle_call(self, params: dict):
        if self._source is None:
            raise SourceContractError("Session is not open")
        call_id = params.get("callId")
        method = params.get("method")
        args = params.get("args")
        budget_ms = params.get("budgetMs")
        if (
            not isinstance(call_id, str)
            or not isinstance(method, str)
            or not isinstance(args, list)
            or type(budget_ms) is not int
            or not 1 <= budget_ms <= 45000
        ):
            raise SourceContractError("Invalid call parameters")
        with self._state_lock:
            if call_id in self._cancelled_calls:
                self._cancelled_calls.discard(call_id)
                raise CallCancelled("Call cancelled before execution")
            self._active_call_id = call_id
            self._active_cancel = threading.Event()
            cancel_event = self._active_cancel
        try:
            return self._source.invoke(
                method,
                args,
                budget=budget_ms / 1000.0,
                cancellation=lambda: cancel_event.is_set() or self._shutdown.is_set(),
                operation_id=call_id,
            )
        finally:
            with self._state_lock:
                self._active_call_id = None

    def _handle_close(self):
        if self._source is not None:
            try:
                self._source.close()
            finally:
                self._source = None
        return {"closed": True}

    def _worker_loop(self):
        while True:
            item = self._tasks.get()
            if item is None:
                break
            req_id, op, params = item
            try:
                if op == "open":
                    result = self._handle_open(params)
                elif op == "call":
                    result = self._handle_call(params)
                elif op == "close":
                    result = self._handle_close()
                else:
                    raise SourceContractError(f"Unknown op: {op}")
                self._send({"type": "resp", "id": req_id, "ok": True, "result": result})
                if op == "close":
                    self._shutdown.set()
                    break
            except BaseException as exc:
                self._send({
                    "type": "resp",
                    "id": req_id,
                    "ok": False,
                    "code": self._error_code(exc),
                    "error": f"{type(exc).__name__}: {exc}",
                })

    def run(self):
        try:
            for raw_line in sys.stdin:
                line = raw_line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except Exception:
                    continue
                msg_type = msg.get("type")
                if msg_type == "http_resp":
                    http_id = str(msg.get("id", ""))
                    with self._http_lock:
                        waiter = self._http_waiters.get(http_id)
                    if waiter is not None:
                        event, holder = waiter
                        holder["ok"] = bool(msg.get("ok"))
                        if holder["ok"]:
                            holder["result"] = msg.get("result") or {}
                        else:
                            holder["kind"] = msg.get("kind") or "connection"
                        event.set()
                    continue
                if msg_type != "req":
                    continue
                req_id = str(msg.get("id", ""))
                op = str(msg.get("op", ""))
                params = msg.get("params") or {}
                if op == "ping":
                    self._send({
                        "type": "resp",
                        "id": req_id,
                        "ok": True,
                        "result": {
                            "version": 1,
                            "runtime": sys.version.split()[0],
                            "pid": os.getpid(),
                        },
                    })
                elif op == "cancel":
                    call_id = str(params.get("callId", ""))
                    with self._state_lock:
                        if self._active_call_id == call_id:
                            self._active_cancel.set()
                        else:
                            self._cancelled_calls.add(call_id)
                    with self._http_lock:
                        for event, holder in self._http_waiters.values():
                            holder["ok"] = False
                            holder["kind"] = "cancelled"
                            event.set()
                    self._send({"type": "resp", "id": req_id, "ok": True, "result": {"cancelled": True}})
                elif op in ("open", "call", "close"):
                    self._tasks.put((req_id, op, params))
                else:
                    self._send({
                        "type": "resp",
                        "id": req_id,
                        "ok": False,
                        "code": "invalid_request",
                        "error": f"Unknown op: {op}",
                    })
        finally:
            self._shutdown.set()
            with self._state_lock:
                self._active_cancel.set()
            with self._http_lock:
                for event, holder in self._http_waiters.values():
                    holder["ok"] = False
                    holder["kind"] = "cancelled"
                    event.set()
            self._tasks.put(None)
            self._worker.join(timeout=0.3)
            if self._source is not None:
                try:
                    self._source.close()
                except Exception:
                    pass
            os._exit(0)


if __name__ == "__main__":
    _RpcRunner().run()
