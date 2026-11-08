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
