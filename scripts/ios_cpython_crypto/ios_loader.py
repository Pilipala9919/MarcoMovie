"""Locate the app-bundled raw libraries used by upstream PyCryptodome.

These are ordinary C libraries, not CPython extension modules. Python's .fwork
import loader is therefore not involved. The crypto implementation is unchanged.
"""
import json
from pathlib import Path

_HERE = Path(__file__).resolve().parent
_BUNDLE = _HERE.parents[2]
_MODULES = json.loads((_HERE / "_ios_modules.json").read_text(encoding="utf-8"))


def load_native(name, cdecl, load_lib):
    relative = _MODULES.get(name)
    if not isinstance(relative, str):
        # Optional CPU accelerators are absent on the portable build; the
        # upstream caller then selects its corresponding portable primitive.
        raise OSError("Native crypto module is not bundled: " + name)
    target = (_BUNDLE / relative).resolve()
    frameworks = (_BUNDLE / "Frameworks").resolve()
    if (not target.is_relative_to(frameworks) or target.parent.parent != frameworks
            or target.parent.name != name + ".framework" or target.name != name
            or not target.is_file()):
        raise OSError("Invalid bundled crypto framework: " + name)
    return load_lib(str(target), cdecl)
