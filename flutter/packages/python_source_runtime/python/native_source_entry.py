"""Trusted native entrypoint; source text is provided as a bounded memory package."""
from native_source_host import NativePythonSource


def create(entry, files, extension, proxy_url, bridge):
    return NativePythonSource(entry, files, bridge=bridge,
                              raw_extension=extension, proxy_url=proxy_url)


def invoke(source, method, args, call_id, remaining_ms):
    return source.invoke(method, args, operation_id=call_id, budget=remaining_ms / 1000)


def close(source):
    source.close()
