"""Trusted native entrypoint; source text is provided as a bounded memory package."""
from tvbox_spider_shim import IosNativePythonSource


def create(entry, files, extension, proxy_url, bridge, remote=None):
    return IosNativePythonSource(
        entry,
        files,
        bridge=bridge,
        raw_extension=extension,
        proxy_url=proxy_url,
        remote=remote,
    )


def invoke(source, method, args, call_id, remaining_ms):
    return source.invoke(method, args, operation_id=call_id, budget=remaining_ms / 1000)


def close(source):
    source.close()
