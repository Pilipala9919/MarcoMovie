"""Generate test-only HomeScreen overlays. Probe compilation is separate; no build/install.

Inputs come from two exact audited Git revisions, never the mutable working tree product.
Every inserted source edit has a mechanical inverse checked against the input bytes.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess

BASE = "55799fd3c829075547c26b1e76e0de95cc833e5c"
CURRENT = "f194405e5890aef922b9a11af8be9558fedc9d75"
SOURCE = "android-tv/src/main/java/com/pilipala/marcomovie/HomeScreen.java"
HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]


def digest(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def instrument(original):
    changed = original
    edits = []

    def edit(name, before, after):
        nonlocal changed
        if changed.count(before) != 1:
            raise ValueError("Non-unique/missing hook: " + name)
        changed = changed.replace(before, after, 1)
        edits.append({"name": name, "before": before, "after": after})

    edit("cancel-enter", "    void cancelGrid() {\n        gridEpoch++;",
         "    void cancelGrid() {\n        HomeGridTrace.mark(this, 14, -1, -1, gridEpoch, 0);\n        gridEpoch++;")
    edit("cancel-exit", "        pendingGrid = null;\n    }\n\n    void clearGrid()",
         "        pendingGrid = null;\n        HomeGridTrace.mark(this, 15, -1, -1, gridEpoch, 0);\n    }\n\n    void clearGrid()")
    edit("batch-enter-reject", "    void appendCards(int start, int epoch, boolean restore) {\n        pendingGrid = null;\n        if (!active() || epoch != gridEpoch) return;",
         "    void appendCards(int start, int epoch, boolean restore) {\n"
         "        HomeGridTrace.mark(this, 1, start, -1, epoch, 0);\n"
         "        pendingGrid = null;\n"
         "        if (!active() || epoch != gridEpoch) {\n"
         "            HomeGridTrace.mark(this, 12, start, -1, epoch, 0);\n"
         "            return;\n        }")
    edit("build-begin", "        long batchStarted = System.nanoTime();\n        for (int index = start;",
         "        HomeGridTrace.mark(this, 2, start, -1, epoch, 0);\n"
         "        long batchStarted = System.nanoTime();\n        for (int index = start;")
    edit("build-wire-focus", "        wireNavigation(Math.max(0, (start - state.windowStart) / COLUMNS - 1));\n        resolvePendingFocus(false);\n        if (end < windowEnd()) {",
         "        HomeGridTrace.mark(this, 3, start, end, epoch, 0);\n"
         "        HomeGridTrace.mark(this, 4, start, end, epoch, 0);\n"
         "        wireNavigation(Math.max(0, (start - state.windowStart) / COLUMNS - 1));\n"
         "        HomeGridTrace.mark(this, 5, start, end, epoch, 0);\n"
         "        HomeGridTrace.mark(this, 6, start, end, epoch, 0);\n"
         "        resolvePendingFocus(false);\n"
         "        HomeGridTrace.mark(this, 7, start, end, epoch, 0);\n"
         "        if (end < windowEnd()) {")
    edit("handler-arrive", "            pendingGrid = () -> appendCards(next, epoch, restore);",
         "            pendingGrid = () -> {\n"
         "                HomeGridTrace.mark(this, 16, next, -1, epoch, 0);\n"
         "                appendCards(next, epoch, restore);\n            };")
    edit("animation-and-handler-post", "            content.postOnAnimation(\n                    () -> {\n                        if (active() && epoch == gridEpoch) a.ui.post(nextBatch);\n                    });",
         "            HomeGridTrace.mark(this, 8, next, -1, epoch, 0);\n"
         "            content.postOnAnimation(\n                    () -> {\n"
         "                        HomeGridTrace.mark(this, 9, next, -1, epoch, 0);\n"
         "                        if (active() && epoch == gridEpoch) {\n"
         "                            boolean tracePosted = a.ui.post(nextBatch);\n"
         "                            HomeGridTrace.mark(this, 10, next, -1, epoch, tracePosted ? 1 : 0);\n"
         "                        } else {\n"
         "                            HomeGridTrace.mark(this, 11, next, -1, epoch, 0);\n"
         "                        }\n                    });")
    edit("finish-focus-wire", "        } else {\n            resolvePendingFocus(true);\n            updateMore();\n            wireNavigation(Math.max(0, rows.size() - 1));",
         "        } else {\n            HomeGridTrace.mark(this, 6, start, end, epoch, 1);\n"
         "            resolvePendingFocus(true);\n            updateMore();\n"
         "            HomeGridTrace.mark(this, 7, start, end, epoch, 1);\n"
         "            HomeGridTrace.mark(this, 4, start, end, epoch, 1);\n"
         "            wireNavigation(Math.max(0, rows.size() - 1));\n"
         "            HomeGridTrace.mark(this, 5, start, end, epoch, 1);")
    edit("batch-exit", '                    && a.current.focus.startsWith("home-video:")) restoreFocus();\n        }\n    }\n\n    View card(',
         '                    && a.current.focus.startsWith("home-video:")) restoreFocus();\n        }\n'
         '        HomeGridTrace.mark(this, 13, start, end, epoch, 0);\n    }\n\n    View card(')
    inverse = changed
    for item in reversed(edits):
        if inverse.count(item["after"]) != 1:
            raise ValueError("Non-unique inverse: " + item["name"])
        inverse = inverse.replace(item["after"], item["before"], 1)
    if inverse != original:
        raise ValueError("Instrumentation inverse differs from original")
    return changed, edits


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", choices=(BASE, CURRENT), required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    # Generated code is confined to this checkout's build area, not product/source or dist.
    build = (REPO / "android-tv/build").resolve()
    if not out.is_relative_to(build) or out == build or out.exists():
        parser.error("--out must be a NEW child of this checkout's android-tv/build")
    original = subprocess.check_output(["git", "show", args.revision + ":" + SOURCE], cwd=REPO).decode("utf-8").replace("\r\n", "\n")
    generated, edits = instrument(original)
    trace = (HERE / "HomeGridTrace.java.in").read_text(encoding="utf-8").replace("@SOURCE_REVISION@", args.revision)
    out.mkdir(parents=True, exist_ok=False)
    (out / "HomeScreen.java").write_text(generated, encoding="utf-8", newline="\n")
    (out / "HomeGridTrace.java").write_text(trace, encoding="utf-8", newline="\n")
    receipt = {"created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
               "revision": args.revision, "source": SOURCE, "source_lf_sha256": digest(original),
               "instrumented_lf_sha256": digest(generated), "trace_lf_sha256": digest(trace),
               "inverse_exact": True, "diagnostic_only": True, "build_install_publish": False,
               "edits": edits}
    (out / "overlay-receipt.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"out": str(out), "revision": args.revision, "inverse_exact": True}))


if __name__ == "__main__":
    main()
