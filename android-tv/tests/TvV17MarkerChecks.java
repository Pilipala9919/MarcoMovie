package com.pilipala.marcomovie;

import android.view.KeyEvent;

/** JVM checks for the local transaction; Android key dispatch and playback require device tests. */
public final class TvV17MarkerChecks {
    private static int checks;

    private static void check(boolean condition, String label) {
        if (!condition) throw new AssertionError(label);
        checks++;
        System.out.println("PASS " + label);
    }

    public static void main(String[] args) throws Exception {
        TvV17MarkerOverlay.State state = new TvV17MarkerOverlay.State();
        check(!state.canConfirm(), "cannot confirm while waiting for pause");
        check(
                state.freeze(100000, 1200000) && state.intro && state.entryPositionMs == 100000,
                "freeze captures position and selects intro in first half");
        Thread.sleep(120);
        check(state.selectedTimeMs == 100000, "waiting does not advance selected time");
        state.adjust(10000);
        check(
                state.canConfirm()
                        && state.selectedTimeMs == 110000
                        && state.entryPositionMs == 100000,
                "explicit adjustment changes selected time only");
        check(
                !state.freeze(200000, 1200000) && state.selectedTimeMs == 110000,
                "duplicate pause callback cannot overwrite selection");
        state.adjust(Long.MAX_VALUE);
        check(state.selectedTimeMs == 1199999, "forward adjustment clamps before end");
        state.adjust(Long.MIN_VALUE);
        check(state.selectedTimeMs == 0 && !state.canConfirm(), "zero cannot create a marker");

        TvV17MarkerOverlay.State tail = new TvV17MarkerOverlay.State();
        tail.freeze(5400000, 7200000);
        check(
                !tail.intro && tail.canConfirm() && tail.selectedTimeMs == 5400000,
                "long-film tail retains its absolute position without a 600-second cap");
        TvV17MarkerOverlay.State unknown = new TvV17MarkerOverlay.State();
        unknown.freeze(100000, -1);
        unknown.adjust(10000);
        check(
                unknown.canConfirm() && unknown.selectedTimeMs == 110000 && unknown.durationMs == 0,
                "unknown duration keeps positive absolute node with observed duration zero");
        TvV17MarkerOverlay.State huge = new TvV17MarkerOverlay.State();
        huge.freeze(Long.MAX_VALUE - 1, 0);
        huge.adjust(10000);
        check(
                huge.selectedTimeMs == Long.MAX_VALUE && huge.canConfirm(),
                "unknown duration adjustment cannot overflow long");
        huge.adjust(Long.MIN_VALUE);
        check(
                huge.selectedTimeMs == 0 && !huge.canConfirm(),
                "unknown duration negative adjustment clamps to zero");
        tail.closed = true;
        check(
                !tail.canConfirm() && !tail.freeze(1, 2),
                "closed transaction cannot save or refreeze");

        TvV17MarkerOverlay.State input = new TvV17MarkerOverlay.State();
        input.freeze(100000, 1200000);
        input.key(KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.ACTION_DOWN, 0, false);
        check(
                !input.intro && input.selectedTimeMs == 100000,
                "right switches marker type before time adjustment");
        input.key(KeyEvent.KEYCODE_DPAD_DOWN, KeyEvent.ACTION_DOWN, 0, false);
        input.key(KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.ACTION_DOWN, 0, false);
        check(input.selectedTimeMs == 110000, "down then right adjusts time by ten seconds");
        input.key(KeyEvent.KEYCODE_ENTER, KeyEvent.ACTION_DOWN, 0, false);
        check(
                input.key(KeyEvent.KEYCODE_ENTER, KeyEvent.ACTION_UP, 0, true)
                                == TvV17MarkerOverlay.State.HANDLED
                        && !input.closed,
                "canceled confirm release does not save");
        input.key(KeyEvent.KEYCODE_ENTER, KeyEvent.ACTION_DOWN, 0, false);
        check(
                input.key(KeyEvent.KEYCODE_ENTER, KeyEvent.ACTION_UP, 0, false)
                                == TvV17MarkerOverlay.State.HANDLED
                        && !input.closed,
                "timeline confirm cannot save a marker");
        input.key(KeyEvent.KEYCODE_DPAD_UP, KeyEvent.ACTION_DOWN, 0, false);
        input.key(KeyEvent.KEYCODE_ENTER, KeyEvent.ACTION_DOWN, 0, false);
        input.key(KeyEvent.KEYCODE_ENTER, KeyEvent.ACTION_DOWN, 1, false);
        check(
                input.key(KeyEvent.KEYCODE_ENTER, KeyEvent.ACTION_UP, 0, false)
                                == TvV17MarkerOverlay.State.CONFIRM
                        && input.closed,
                "confirm with repeats commits exactly once on release");
        check(
                input.key(KeyEvent.KEYCODE_ENTER, KeyEvent.ACTION_UP, 0, false)
                        == TvV17MarkerOverlay.State.HANDLED,
                "extra release cannot confirm again");

        TvV17MarkerOverlay.State cancel = new TvV17MarkerOverlay.State();
        check(
                cancel.key(KeyEvent.KEYCODE_BACK, KeyEvent.ACTION_DOWN, 0, false)
                                == TvV17MarkerOverlay.State.HANDLED
                        && cancel.key(KeyEvent.KEYCODE_BACK, KeyEvent.ACTION_UP, 0, false)
                                == TvV17MarkerOverlay.State.CANCEL
                        && cancel.closed,
                "back cancels once even while waiting for pause");
        unknown.key(KeyEvent.KEYCODE_ENTER, KeyEvent.ACTION_DOWN, 0, false);
        check(
                unknown.key(KeyEvent.KEYCODE_ENTER, KeyEvent.ACTION_UP, 0, false)
                                == TvV17MarkerOverlay.State.CONFIRM
                        && unknown.closed,
                "unknown duration confirms transaction without inventing a duration");
        TvV17MarkerOverlay.State guarded = new TvV17MarkerOverlay.State();
        guarded.freeze(100000, 1200000);
        check(
                guarded.key(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.ACTION_DOWN, 0, false)
                                == TvV17MarkerOverlay.State.HANDLED
                        && guarded.selectedTimeMs == 100000
                        && !guarded.closed,
                "media play key cannot escape the marking transaction");
        TvV17MarkerOverlay.State matched = new TvV17MarkerOverlay.State();
        matched.freeze(100000, 1200000);
        matched.key(KeyEvent.KEYCODE_ENTER, KeyEvent.ACTION_DOWN, 0, false, 11);
        check(
                matched.key(KeyEvent.KEYCODE_ENTER, KeyEvent.ACTION_UP, 0, false, 12)
                                == TvV17MarkerOverlay.State.HANDLED
                        && !matched.closed,
                "mismatched downTime cannot confirm");
        matched.key(KeyEvent.KEYCODE_ENTER, KeyEvent.ACTION_DOWN, 0, true, 13);
        check(
                matched.key(KeyEvent.KEYCODE_ENTER, KeyEvent.ACTION_UP, 0, false, 13)
                                == TvV17MarkerOverlay.State.HANDLED
                        && !matched.closed,
                "canceled DOWN cannot confirm on clean UP");
        matched.key(KeyEvent.KEYCODE_ENTER, KeyEvent.ACTION_DOWN, 0, false, 14);
        matched.key(KeyEvent.KEYCODE_ENTER, KeyEvent.ACTION_DOWN, 0, false, 14);
        check(
                matched.key(KeyEvent.KEYCODE_ENTER, KeyEvent.ACTION_UP, 0, false, 14)
                                == TvV17MarkerOverlay.State.HANDLED
                        && !matched.closed,
                "duplicate initial DOWN invalidates gesture");
        matched.key(KeyEvent.KEYCODE_NUMPAD_ENTER, KeyEvent.ACTION_DOWN, 0, false, 15);
        check(
                matched.key(KeyEvent.KEYCODE_NUMPAD_ENTER, KeyEvent.ACTION_UP, 0, false, 15)
                        == TvV17MarkerOverlay.State.CONFIRM,
                "matched numpad enter confirms once");
        System.out.println("ALL PASS (" + checks + " marker state checks)");
    }
}
