# Native lxml port experiment

This directory is an isolated development experiment, **not a supported product
dependency**. The iOS package preparer does not import it. Do not add lxml to the
product's accepted source profile on the strength of a successful compilation.

The pinned upstream generated C code rejects subinterpreters. It also contains
process-wide Python references, cached builtins and Cython dispatch tables, and
uses `PyGILState_Ensure` in native callbacks. Merely changing its module slot, or
disabling the source owner's extension check, cannot establish compatibility.

The experiment migrates these declarations into the generated module state,
adds traversal/clearing for owned references, and preserves the calling
interpreter across native callbacks. It keeps the upstream Python package and
both native modules; it is not a substitute XPath implementation. Generated C
is patched only after verifying the complete source archive. Changed layouts
must fail rather than silently applying a patch to another release.

The first validation stage runs native CPython on Linux with independently
created own-GIL interpreters. Its report must record library versions, source
hashes, failures, and actual interpreter destruction. That is a prerequisite for
the iOS port, not evidence of iPhone compatibility. Native library global
callbacks, import/teardown, simultaneous independent parsers, XPath callbacks,
objectify, XSLT, error recovery and reopening must all be exercised before any
production integration. Physical-device source and playback acceptance remain
separate.

## First native result

Run 42475595293 at `d8e13ca` passed the Linux host stage on CPython 3.14.10,
libxml2 2.9.14 and libxslt 1.1.39. Thirteen core behaviors were repeated for 650
assertions across two simultaneous own-GIL owners, continued use after the peer
was destroyed, and a third freshly created interpreter. All three interpreters
were actually destroyed, and all eight recorded experiment input hashes matched
that commit. XML/HTML, XPath callbacks, resolver ownership, error recovery,
objectify, streaming parse and XSLT were exercised.

The first run failed during simultaneous type initialization. Native debugging
identified a shared static extension type; the follow-up enables per-module heap
types as well as migrating the Python references and dispatch tables. The
previous failing runs remain failures, not accepted results.

This does not establish iOS compilation, iPhone execution, complete upstream API
coverage or real subscription playback. The callback policy in
`native_callbacks.h` also requires private libxml2/libxslt libraries in a product
app; it must not take over an unrelated component's shared library callbacks.
