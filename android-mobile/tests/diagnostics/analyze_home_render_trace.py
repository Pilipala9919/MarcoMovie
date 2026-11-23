"""Read one namespaced diagnostic sidecar. Summaries do not decide product pass/fail."""
import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path


def analyze(data):
    columns = data["event_columns"]
    if data.get("schema") != 1 or any(len(row) != len(columns) for row in data["events"]):
        raise ValueError("Unsupported schema or malformed event row")
    if len(data["events"]) != data["event_count"]:
        raise ValueError("Event count does not match sidecar")
    if any(len(row) != len(data["sample_columns"]) for row in data["samples"]):
        raise ValueError("Malformed sample row")
    events = [dict(zip(columns, row)) for row in data["events"]]
    samples = [dict(zip(data["sample_columns"], row)) for row in data["samples"]]
    if any(e["elapsed_ms"] > data["deadline_elapsed_ms"] for e in events):
        raise ValueError("Event outside the original deadline")
    if any(b["nano_time"] < a["nano_time"] for a, b in zip(events, events[1:])):
        raise ValueError("Event time moved backwards")
    phases = defaultdict(list)
    opened = {}
    unmatched_ends = 0
    pairs = {13: (1, "batch"), 3: (2, "build"), 5: (4, "wire"), 7: (6, "focus_or_finalize"),
             9: (8, "animation_queue"), 16: (10, "handler_queue"), 15: (14, "cancel")}
    starts = {v[0] for v in pairs.values()}
    for event in events:
        kind = event["kind"]
        # Epoch changes at cancellation, so pair cancellation by owner, not epoch.
        epoch = -1 if kind in (14, 15) else event["captured_epoch"]
        value = event["value"] if kind in (4, 5, 6, 7) else 0
        key = (event["home_id"], epoch, event["start"], value)
        if kind in starts:
            opened[(kind, key)] = event
        elif kind in pairs:
            start, label = pairs[kind]
            before = opened.pop((start, key), None)
            if before is None:
                unmatched_ends += 1
            else:
                phases[label].append((event["nano_time"] - before["nano_time"]) / 1e6)
    spans = []
    plateau_ms = max_plateau_ms = 0
    for before, after in zip(samples, samples[1:]):
        same_epoch = (before["home_id"], before["grid_epoch"]) == (after["home_id"], after["grid_epoch"])
        plateau_ms = plateau_ms + after["elapsed_ms"] - before["elapsed_ms"] if same_epoch and before["cards"] == after["cards"] else 0
        max_plateau_ms = max(max_plateau_ms, plateau_ms)
        spans.append({"from_ms": before["elapsed_ms"], "to_ms": after["elapsed_ms"],
                      "cards_before": before["cards"], "cards_after": after["cards"],
                      "same_home_epoch": same_epoch})
    summary = {"scope": "observed intervals only; unpaired endpoints may cross the capture boundary",
               "fixture_source": data.get("fixture_source"), "stage": data["stage"],
               "trace_available": data["trace_available"], "condition_satisfied": data["condition_satisfied"],
               "events": len(events), "event_counts": dict(Counter(e["kind"] for e in events)),
               "samples": len(samples), "first_sample": samples[0] if samples else None,
               "last_sample": samples[-1] if samples else None, "growth_intervals": spans,
               "max_observed_same_count_ms": max_plateau_ms,
               "phase_ms": {name: {"count": len(values), "total": sum(values),
                                    "max": max(values), "median": sorted(values)[len(values)//2]}
                            for name, values in phases.items()},
               "unpaired_starts": len(opened), "unpaired_ends": unmatched_ends,
               "cancellation_or_rejection_events": [e for e in events if e["kind"] in (11, 12, 14, 15)],
               "handler_post_failures": [e for e in events if e["kind"] == 10 and e["value"] == 0],
               "recording_losses": {k: data.get(k) for k in
                                    ("events_dropped_capacity", "events_after_deadline", "trace_errors", "diagnostic_error")},
               "observer_ns": data["observer_ns"], "trace_mark_ns": data.get("trace_mark_ns"),
               "max_ui_queue_ns": data["max_ui_queue_ns"], "max_condition_ns": data["max_condition_ns"]}
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sidecar", type=Path)
    args = parser.parse_args()
    print(json.dumps(analyze(json.loads(args.sidecar.read_text(encoding="utf-8-sig"))),
                     ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
