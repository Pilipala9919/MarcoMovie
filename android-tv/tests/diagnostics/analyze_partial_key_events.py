"""Read a partial-key result + sidecar. Diagnostic validity is separate from business/acceptance."""
import argparse
import json
from pathlib import Path


def analyze(result, trace):
    if "result" in result: result = result["result"]
    errors, witnesses, findings, focus_unusable = [], [], [], []
    if trace.get("schema") != 1: errors.append("unsupported schema")
    for key, result_key in (("scenario", "scenario"), ("layout", "layout"),
                            ("run_id", "run_id"), ("product_revision", "product_revision_argument")):
        if not trace.get(key) or trace.get(key) != result.get(result_key): errors.append("binding: " + key)
    if result.get("acceptance_passed") is not False or result.get("original_homeprobe_replaced") is not False:
        errors.append("acceptance/original-test boundary missing")
    keys = trace.get("key_events", [])
    if not keys or len(keys) != result.get("key_pairs"): errors.append("key count mismatch or no input")
    for n, key in enumerate(keys):
        if key.get("number") != n or key.get("down_callbacks") != 1 or key.get("up_callbacks") != 1:
            errors.append("callback pairing: " + str(n))
        if not key.get("down_injected") or not key.get("up_injected"): errors.append("injection: " + str(n))
        states = [key.get(k) for k in ("before_down", "after_down", "before_up", "after_up", "post_delivery")]
        if not all(isinstance(s, dict) for s in states):
            errors.append("missing capture: " + str(n)); continue
        if any(b["uptime_ms"] < a["uptime_ms"] for a, b in zip(states, states[1:])):
            errors.append("state time reversed: " + str(n))
        before = states[0]
        if key.get("key_code") != 20 or before["focus_index"] < 0: continue  # DPAD_DOWN
        partial = (before["pending_grid"] and 0 < before["cards"] < before["window_end"]-before["window_start"]
                   and all(before[k] for k in ("attached", "shown", "visible_screen_intersection",
                                              "enabled_focusable", "active", "ready")) and not before["busy"])
        tail = before["next_down_id"] == before["focus_id"]
        target = before["next_down_index"]
        prefetch = (target >= before["window_start"] and
                    (target-before["window_start"])//before["columns"] >= max(1, before["rows"]-2))
        if partial: witnesses.append({"key": n, "boundary": tail or prefetch,
                                      "kind": "tail_self" if tail else "focus_prefetch" if prefetch else "ordinary"})
        for label in ("after_down", "after_up", "post_delivery", "followup"):
            after = key.get(label)
            if not isinstance(after, dict): continue
            if not all(after[k] for k in ("attached", "shown", "visible_screen_intersection", "enabled_focusable")):
                focus_unusable.append({"key": n, "capture": label, "focus_index": after["focus_index"],
                                       "note": "observed transient; persistent loss requires bounded settle outcome"})
            last_row = ((before["window_end"]-1)//before["columns"])*before["columns"]
            reasons = []
            if after["items"] < before["items"]: reasons.append("dataset_shrank")
            if after["window_start"] > before["window_start"] and before["focus_index"] < last_row:
                reasons.append("premature_window_advance")
            if after["focus_index"] > before["focus_index"]+before["columns"]: reasons.append("skipped_focus_row")
            if after["window_start"] < before["window_start"]: reasons.append("down_window_backwards")
            if 0 <= after["focus_index"] < before["focus_index"]: reasons.append("down_focus_backwards")
            if reasons: findings.append({"key": n, "capture": label, "reasons": reasons,
                                        "before_index": before["focus_index"], "after_index": after["focus_index"],
                                        "before_window": before["window_start"], "after_window": after["window_start"]})
    if trace.get("observer_error") or result.get("capture_error"): errors.append("capture/observer failure")
    if not witnesses: errors.append("no native partial-render witness")
    if trace.get("scenario") == "edge" and not any(w["boundary"] for w in witnesses):
        errors.append("partial boundary not observed")
    return {"diagnostic_valid": not errors, "errors": errors, "business_passed": result.get("passed"),
            "failure_code": result.get("failure_code"), "witnesses": witnesses, "findings": findings,
            "focus_unusable_observations": focus_unusable,
            "requested_pages": trace.get("requested_pages"), "keys": len(keys),
            "acceptance_passed": False, "original_12s_2001_result_overridden": False,
            "scope": "injected keys in this fixture only; no physical remote or no-regression claim"}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("result", type=Path); p.add_argument("sidecar", type=Path)
    a = p.parse_args()
    print(json.dumps(analyze(json.loads(a.result.read_text(encoding="utf-8-sig")),
                             json.loads(a.sidecar.read_text(encoding="utf-8-sig"))), ensure_ascii=False, indent=2))


if __name__ == "__main__": main()
