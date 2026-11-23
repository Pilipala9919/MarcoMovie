"""TVBox community Spider shims for iOS CPython 3.14 source runtime.

Provides:
- `com.github.catvod.crawler.Spider.Spider` base class compatibility
- `base.localProxy` callback bridge
- `getDependence()` sibling / remote dependency loader
"""
from __future__ import annotations

import importlib
import importlib.util
import sys
import types

from native_source_host import NativePythonSource, SourceContractError, normalize_proxy


def _normalize_dependence_entries(raw_deps):
    if raw_deps is None:
        return []
    if isinstance(raw_deps, str):
        items = [part.strip() for part in raw_deps.split(",") if part.strip()]
    elif isinstance(raw_deps, (list, tuple, set)):
        items = [str(item).strip() for item in raw_deps if item is not None and str(item).strip()]
    else:
        return []
    return items


def _resolve_dependence_candidates(source: NativePythonSource, dep_name: str):
    cleaned = dep_name.strip().replace("\\", "/")
    while cleaned.startswith("./"):
        cleaned = cleaned[2:]
    if not cleaned:
        return []
    if cleaned.endswith(".py"):
        mod_name = cleaned[:-3].replace("/", ".")
        rel_paths = [cleaned]
    else:
        mod_name = cleaned.replace("/", ".")
        rel = cleaned.replace(".", "/")
        rel_paths = [rel + ".py", rel + "/__init__.py"]
    entry_dir = source.entry.rpartition("/")[0]
    candidates = []
    for rel in rel_paths:
        if entry_dir and "/" not in rel:
            candidates.append((mod_name, entry_dir + "/" + rel))
        candidates.append((mod_name, rel))
    return candidates


def load_dependence_module(source: NativePythonSource, dep_name: str):
    """Load a sibling or remote Python dependency module into `sys.modules`."""
    source._ensure_open()
    candidates = _resolve_dependence_candidates(source, dep_name)
    if not candidates:
        return None
    for mod_name, rel_path in candidates:
        parts = [p for p in mod_name.split(".") if p]
        if not parts or not all(p.isidentifier() for p in parts):
            raise SourceContractError("Invalid dependency module name: " + dep_name)
        if parts[0] in source._reserved:
            raise SourceContractError("Dependency cannot shadow a host module: " + dep_name)
        if mod_name in sys.modules and mod_name in source._loaded:
            return sys.modules[mod_name]
        try:
            raw_bytes = source._read_file(rel_path)
        except FileNotFoundError:
            continue
        is_pkg = rel_path.endswith("/__init__.py")
        module = types.ModuleType(mod_name)
        module.__file__ = source.origin + rel_path
        module.__package__ = mod_name if is_pkg else mod_name.rpartition(".")[0]
        if is_pkg:
            module.__path__ = [source.origin + rel_path.rpartition("/")[0]]
        sys.modules[mod_name] = module
        source._loaded[mod_name] = module
        try:
            code = compile(raw_bytes, module.__file__, "exec", dont_inherit=True)
            exec(code, module.__dict__)
        except BaseException:
            if sys.modules.get(mod_name) is module:
                del sys.modules[mod_name]
            source._loaded.pop(mod_name, None)
            raise
        return module
    return None


def install_tvbox_shims(source: NativePythonSource):
    """Install `com.github.catvod.crawler.Spider`, `base.localProxy`, and `getDependence`."""
    base_mod = sys.modules["base"]
    base_spider_mod = sys.modules["base.spider"]
    BaseSpider = base_spider_mod.Spider

    # 1. Attach getDependence / loadDependence defaults to base.spider.Spider
    if not hasattr(BaseSpider, "getDependence"):
        def getDependence(self):
            return []
        BaseSpider.getDependence = getDependence

    if not hasattr(BaseSpider, "loadDependence"):
        def loadDependence(self, name):
            return load_dependence_module(source, name)
        BaseSpider.loadDependence = loadDependence

    if not hasattr(BaseSpider, "getName"):
        def getName(self):
            return type(self).__name__
        BaseSpider.getName = getName

    if not hasattr(BaseSpider, "isVideoFormat"):
        def isVideoFormat(self, url):
            return False
        BaseSpider.isVideoFormat = isVideoFormat

    if not hasattr(BaseSpider, "manualVideoCheck"):
        def manualVideoCheck(self):
            return False
        BaseSpider.manualVideoCheck = manualVideoCheck

    if not hasattr(BaseSpider, "destroy"):
        def destroy(self):
            pass
        BaseSpider.destroy = destroy

    # 2. base.localProxy callback bridge (callable on `base` and `base.spider`)
    def local_proxy_bridge(*args, **kwargs):
        if len(args) == 1 and isinstance(args[0], dict) and not kwargs:
            params = args[0]
            spider = getattr(source, "_spider", None)
            if spider is not None:
                fn = getattr(spider, "localProxy", None) or getattr(spider, "proxy", None)
                if callable(fn):
                    return normalize_proxy(fn(params))
            return source.proxy_url(params)
        if len(args) >= 3:
            status, mime, body = args[0], args[1], args[2]
            headers = args[3] if len(args) > 3 else kwargs.get("headers")
            flag = args[4] if len(args) > 4 else kwargs.get("flag", 0)
            return normalize_proxy([status, mime, body, headers, flag])
        if kwargs:
            return source.proxy_url(kwargs)
        return source.proxy_url({})

    def get_dependence_bridge(name=None):
        if name is None:
            spider = getattr(source, "_spider", None)
            if spider is not None and callable(getattr(spider, "getDependence", None)):
                return spider.getDependence()
            return []
        return load_dependence_module(source, str(name))

    base_mod.localProxy = local_proxy_bridge
    base_spider_mod.localProxy = local_proxy_bridge
    base_mod.getDependence = get_dependence_bridge
    base_spider_mod.getDependence = get_dependence_bridge

    # 3. com.github.catvod.crawler.Spider hierarchy
    class CatVodSpider(BaseSpider):
        """Compatibility base class matching TVBox `com.github.catvod.crawler.Spider`."""

        def setExtendInfo(self, extend=""):
            self.extend = extend

    com_mod = types.ModuleType("com")
    com_mod.__path__ = ["marco://python-native/com"]
    github_mod = types.ModuleType("com.github")
    github_mod.__path__ = ["marco://python-native/com/github"]
    catvod_mod = types.ModuleType("com.github.catvod")
    catvod_mod.__path__ = ["marco://python-native/com/github/catvod"]
    crawler_mod = types.ModuleType("com.github.catvod.crawler")
    crawler_mod.__path__ = ["marco://python-native/com/github/catvod/crawler"]
    spider_mod = types.ModuleType("com.github.catvod.crawler.Spider")
    spider_mod.__file__ = "marco://python-native/com/github/catvod/crawler/Spider.py"
    spider_mod.__package__ = "com.github.catvod.crawler"
    spider_mod.Spider = CatVodSpider
    spider_mod.localProxy = local_proxy_bridge
    spider_mod.getDependence = get_dependence_bridge

    com_mod.github = github_mod
    github_mod.catvod = catvod_mod
    catvod_mod.crawler = crawler_mod
    crawler_mod.Spider = spider_mod

    shim_modules = {
        "com": com_mod,
        "com.github": github_mod,
        "com.github.catvod": catvod_mod,
        "com.github.catvod.crawler": crawler_mod,
        "com.github.catvod.crawler.Spider": spider_mod,
    }
    sys.modules.update(shim_modules)
    source._loaded.update(shim_modules)


class IosNativePythonSource(NativePythonSource):
    """iOS CPython source host with TVBox community Spider shims & dependency loading."""

    def __init__(self, entry, files, *, bridge, extension="", raw_extension=None, proxy_url=None, remote=None):
        super().__init__(
            entry,
            files,
            bridge=bridge,
            extension=extension,
            raw_extension=raw_extension,
            proxy_url=proxy_url,
            remote=remote,
        )
        self._reserved = self._reserved | {"com", "tvbox_spider_shim"}

    def _install(self):
        super()._install()
        install_tvbox_shims(self)

    def _load_declared_dependencies(self):
        spider = self._spider
        if spider is None:
            return
        fn = getattr(spider, "getDependence", None)
        if not callable(fn):
            return
        deps = _normalize_dependence_entries(fn())
        for dep in deps:
            load_dependence_module(self, dep)

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
                name = name[:-len(".__init__")]
        module = importlib.import_module(name)
        import inspect
        cls = getattr(module, "Spider", None)
        if not inspect.isclass(cls):
            raise SourceContractError("Python source must export a Spider class")
        self._spider = cls()
        self._load_declared_dependencies()
        if getattr(self._spider, "init", None) is not None:
            self._call("init", [self.ext])
        self._state = "ready"
