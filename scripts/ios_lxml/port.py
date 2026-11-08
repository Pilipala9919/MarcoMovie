"""Pinned, isolated own-GIL lxml port experiment; never a product installer.

Only declarations outside function bodies are selected. The complete pinned
archive is verified before extraction, and every moved declaration is reported.
The output still needs native tests; the module slot is a test hypothesis, not
an assertion that untested lxml/libxml2 APIs are safe.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import tarfile

HERE = Path(__file__).resolve().parent
LOCK = json.loads((HERE / "source.lock.json").read_text(encoding="utf-8"))


def digest(data):
    return hashlib.sha256(data).hexdigest()


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError("Pinned lxml patch anchor changed: " + old[:100])
    return text.replace(old, new, 1)


def extract(archive, output):
    if digest(archive.read_bytes()) != LOCK["sha256"]:
        raise ValueError("lxml archive checksum mismatch")
    if output.exists() and any(output.iterdir()):
        raise ValueError("Use a new empty experiment output directory")
    output.mkdir(parents=True, exist_ok=True)
    total = 0
    seen = set()
    with tarfile.open(archive, "r:gz") as source:
        for entry in source:
            parts = PurePosixPath(entry.name)
            if (parts.is_absolute() or ".." in parts.parts or "\\" in entry.name
                    or ":" in entry.name or parts.parts[0] != "lxml-" + LOCK["version"]):
                raise ValueError("Unexpected lxml archive path")
            if entry.isdir():
                continue
            if not entry.isfile() or len(parts.parts) < 2:
                raise ValueError("Unexpected lxml archive member")
            name = PurePosixPath(*parts.parts[1:]).as_posix()
            total += entry.size
            if name in seen or total > 90 * 1024 * 1024 or len(seen) > 5000:
                raise ValueError("Unexpected lxml archive size or duplicate")
            seen.add(name)
            target = output / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.extractfile(entry).read())


def port_module(text, module):
    # Generated C uses unindented global declarations and indented locals.
    # Match only the audited name families, not arbitrary C with a regexp.
    names = (r"__pyx_v_4lxml_\w+|__pyx_\d+genexpr\d+__pyx_v_4lxml_\w+|"
             r"__pyx_builtin_\w+|__pyx_vtab(?:ptr|le)_\w+|"
             r"__pyx_collections_abc_Sequence|generic|strided|indirect|"
             r"contiguous|indirect_contiguous|__pyx_memoryview_thread_locks(?:_used)?")
    declaration = re.compile(
        r"^static (?P<type>[^;\n()=]+?)(?P<name>" + names + r")"
        r"(?P<array>\[\d+\])?(?P<init> = (?:0|NULL))?;\s*$", re.M)
    found = list(declaration.finditer(text))
    if len(found) != {'etree': 283, 'objectify': 42}[module] or len({m['name'] for m in found}) != len(found):
        raise ValueError("Unexpected lxml declaration inventory")
    fields, macros, owned = [], [], []
    inventory = []
    for match in found:
        name, type_name = match['name'], match['type'].strip()
        field = "mm_" + name
        fields.append("  " + match['type'] + field + (match['array'] or "") + ";")
        macros.append("#define " + name + " (__pyx_mstate_global->" + field + ")")
        is_object = type_name == 'PyObject *' or (
            type_name.startswith('struct __pyx_obj_') and type_name.endswith('*'))
        if is_object:
            owned.append(field)
        inventory.append({"name": name, "type": type_name,
                          "array": match['array'], "owned_python_reference": is_object})
    text = declaration.sub("/* moved to per-interpreter module state */", text)
    text = replace_once(text, '/* #### Code section: module_state_end ### */',
                        '\n'.join(fields) + '\n/* #### Code section: module_state_end ### */')
    anchor = '#define __pyx_mstate_global (__Pyx_PyModule_GetState(__Pyx_State_FindModule(&__pyx_moduledef)))'
    headers = '\n#include "mm_owner_state.h"\n'
    if module == 'etree':
        headers += '#include "mm_native_callbacks.h"\n'
    text = replace_once(text, anchor, anchor + headers + '\n'.join(macros))
    if module == 'etree':
        text = replace_once(text,
            '__pyx_v_4lxml_5etree___DEFAULT_ENTITY_LOADER = xmlGetExternalEntityLoader();',
            '__pyx_v_4lxml_5etree___DEFAULT_ENTITY_LOADER = mm_lxml_original_entity_loader;')
        text = replace_once(text,
            '__pyx_v_4lxml_5etree_XSLT_DOC_DEFAULT_LOADER = xsltDocDefaultLoader;',
            '__pyx_v_4lxml_5etree_XSLT_DOC_DEFAULT_LOADER = mm_lxml_original_xslt_loader;')
    clear = '  Py_CLEAR(clear_module_state->__pyx_d);'
    text = replace_once(text, clear, '\n'.join(
        '  Py_CLEAR(clear_module_state->' + field + ');' for field in owned) + '\n' + clear)
    traverse = '  Py_VISIT(traverse_module_state->__pyx_d);'
    text = replace_once(text, traverse, '\n'.join(
        '  Py_VISIT(traverse_module_state->' + field + ');' for field in owned) + '\n' + traverse)
    text = replace_once(text,
                        '{Py_mod_multiple_interpreters, Py_MOD_MULTIPLE_INTERPRETERS_NOT_SUPPORTED}',
                        '{Py_mod_multiple_interpreters, Py_MOD_PER_INTERPRETER_GIL_SUPPORTED}')
    # This assertion remains enabled independently of NDEBUG in the host probe.
    text = ('#ifndef MM_LXML_EXPERIMENT\n#error "Unaccepted lxml port is experiment-only"\n#endif\n'
            '#define CYTHON_USE_MODULE_STATE 1\n'
            '#define CYTHON_USE_TYPE_SPECS 1\n' + text)
    return text, inventory


def prepare(archive, output):
    extract(archive, output)
    report = {"experimental": True, "product_enabled": False,
              "source": LOCK, "modules": {}, "port_inputs": {}}
    for path in [Path(__file__), HERE / 'source.lock.json', HERE / 'owner_state.h', HERE / 'native_callbacks.h']:
        report['port_inputs'][path.name] = digest(path.read_bytes())
    for module in ('etree', 'objectify'):
        path = output / 'src/lxml' / (module + '.c')
        original = path.read_bytes()
        patched, inventory = port_module(original.decode('utf-8'), module)
        path.write_text(patched, encoding='utf-8', newline='\n')
        report['modules'][module] = {
            'upstream_sha256': digest(original), 'patched_sha256': digest(path.read_bytes()),
            'declarations': inventory,
        }
    (output / 'src/lxml/mm_owner_state.h').write_bytes((HERE / 'owner_state.h').read_bytes())
    (output / 'src/lxml/mm_native_callbacks.h').write_bytes((HERE / 'native_callbacks.h').read_bytes())
    # The public C API header caches only C function pointers. They are not
    # Python-owned values, but concurrent imports must not write the same storage.
    api = output / 'src/lxml/etree_api.h'
    original = api.read_text(encoding='utf-8')
    patched, count = re.subn(r'^static (.*\(\*__pyx_api_f_4lxml_5etree_.* = 0;)$',
                             r'static _Thread_local \1', original, flags=re.M)
    if count != 45:
        raise ValueError('Pinned lxml C API pointer inventory changed')
    api.write_text(patched, encoding='utf-8', newline='\n')
    report['c_api'] = {'function_pointer_count': count, 'upstream_sha256': digest(original.encode()),
                       'patched_sha256': digest(api.read_bytes())}
    (output / 'port-manifest.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = prepare(args.archive, args.output)
    print(json.dumps({name: len(value['declarations']) for name, value in result['modules'].items()}))
