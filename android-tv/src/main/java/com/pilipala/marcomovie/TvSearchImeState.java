package com.pilipala.marcomovie;

/** Plain-memory IME draft, independent of Android View/Editable and never persisted. */
final class TvSearchImeState {
    PinyinKeyboardModel.Snapshot before;
    String text;
    int start = -1, end = -1, selection;
    boolean changed, contentChanged;

    void open(PinyinKeyboardModel keyboard) {
        if (before != null && !composing() && !sameKeyboard(before, keyboard.snapshot())) clear();
        if (before != null) return;
        before = keyboard.snapshot();
        text = keyboard.query();
        selection = text.length();
    }

    boolean composing() {
        return start >= 0 && end > start && end <= text.length();
    }

    void update(String value, int from, int to, int cursor, PinyinKeyboardModel keyboard) {
        if (before == null) open(keyboard);
        int nextSelection = Math.max(0, Math.min(value.length(), cursor));
        boolean wasComposing = composing();
        if (!value.equals(text)) contentChanged = true;
        if (!value.equals(text) || start != from || end != to || selection != nextSelection)
            changed = true;
        text = value;
        start = from;
        end = to;
        selection = nextSelection;
        if (wasComposing && !composing()) contentChanged = true;
        // A composing region belongs to the IME. Never flatten it into a submitted query.
        if (!composing() && contentChanged) keyboard.set(value);
    }

    void close(PinyinKeyboardModel keyboard) {
        if (before == null) return;
        // Uncommitted IME text stays as a distinct draft for the next open/return.
        if (composing()) return;
        if (!contentChanged) keyboard.restore(before);
        if (selection != text.length()) {
            before = keyboard.snapshot();
            changed = contentChanged = false;
        } else clear();
    }

    static boolean sameKeyboard(
            PinyinKeyboardModel.Snapshot left, PinyinKeyboardModel.Snapshot right) {
        return left != null
                && right != null
                && left.mode == right.mode
                && left.committed.equals(right.committed)
                && left.composition.equals(right.composition);
    }

    boolean keyboardChanged(PinyinKeyboardModel keyboard) {
        return !sameKeyboard(before, keyboard.snapshot());
    }

    void commit(PinyinKeyboardModel keyboard) {
        if (text != null) keyboard.set(text);
        clear();
    }

    void clear() {
        before = null;
        text = null;
        start = end = -1;
        selection = 0;
        changed = contentChanged = false;
    }

    TvSearchImeState copy() {
        TvSearchImeState out = new TvSearchImeState();
        out.before = before;
        out.text = text;
        out.start = start;
        out.end = end;
        out.selection = selection;
        out.changed = changed;
        out.contentChanged = contentChanged;
        return out;
    }
}
