package com.pilipala.marcomovie;

/** Test-only outcome oracle. No Android, scheduler, rendering or product mutations. */
final class PartialKeyContract {
    static final class State {
        int index = -1, start, end, items, page, columns = 5, cards, rows;
        int focusId = -1, nextId = -1, nextIndex = -1, epoch, generation, requests;
        boolean attached, shown, visible, enabled, pending, active, ready, busy;
        String tag = "null", contentId = "";
        long uptime, captureNs;
        int left, top, right, bottom;

        boolean usable() {
            return attached && shown && visible && enabled;
        }

        boolean partial() {
            return pending && cards > 0 && cards < end - start;
        }
    }

    static String downViolation(State before, State after) {
        if (before.index < 0) return null; // Category entry has its own expected-index check.
        if (after.items < before.items) return "DATASET_SHRANK";
        if (after.start < before.start) return "DOWN_MOVED_WINDOW_BACKWARDS";
        int lastLogicalRow = ((before.end - 1) / before.columns) * before.columns;
        if (after.start > before.start && before.index < lastLogicalRow)
            return "PREMATURE_WINDOW_ADVANCE";
        if (after.start > before.end) return "SKIPPED_WINDOW";
        if (after.index > before.index + before.columns) return "SKIPPED_FOCUS_ROW";
        if (after.index >= 0 && after.index < before.index) return "DOWN_MOVED_FOCUS_BACKWARDS";
        return null; // Transient loss is recorded, then tested against a bounded settle guard.
    }

    static boolean partialKeyWitness(State before) {
        return before.index >= 0
                && before.usable()
                && before.active
                && before.ready
                && !before.busy
                && before.partial();
    }

    static String witnessKind(State before) {
        if (!partialKeyWitness(before)) return "not_partial";
        if (before.nextId == before.focusId) return "partial_tail_self";
        if (before.nextIndex >= before.start
                && (before.nextIndex - before.start) / before.columns
                        >= Math.max(1, before.rows - 2)) return "partial_focus_prefetch_boundary";
        return "partial_ordinary_row";
    }
}
