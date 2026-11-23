package com.pilipala.marcomovie;

import java.io.*;
import java.nio.charset.StandardCharsets;

/** Real IME/gate models plus extracted host methods; not Android InputConnection/player execution. */
public final class TvV17ReviewFixChecks {
    static int count;

    static void check(boolean ok, String label) {
        if (!ok) throw new AssertionError(label);
        count++;
        System.out.println("PASS " + label);
    }

    static PinyinKeyboardModel keyboard() throws Exception {
        PinyinKeyboardModel k =
                new PinyinKeyboardModel(
                        new ByteArrayInputStream(
                                "san\t三伞散叁参桑丧嗓\n".getBytes(StandardCharsets.UTF_8)));
        k.set("电影");
        k.input("san");
        return k;
    }

    public static void main(String[] args) throws Exception {
        PinyinKeyboardModel k = keyboard();
        TvSearchImeState d = new TvSearchImeState();
        d.open(k);
        d.update("电影san", 2, 5, 3, k);
        d.close(k);
        check(
                d.composing() && d.selection == 3 && d.start == 2 && d.end == 5,
                "same text region/cursor survives close");
        TvSearchImeState c = d.copy();
        c.open(k);
        check(
                c.composing() && c.selection == 3 && k.composition().equals("san"),
                "snapshot/reopen keeps uncommitted draft");
        c.update("电影san", 3, 5, 4, k);
        c.close(k);
        check(c.start == 3 && c.selection == 4, "region-only edit is not lost on second cancel");
        c.update("电影san", -1, -1, 4, k);
        c.close(k);
        check(
                k.composition().isEmpty() && k.committed().equals("电影san"),
                "finish composition without character change commits text");
        c.open(k);
        check(c.selection == 4, "committed mid-text caret restored");
        k = keyboard();
        d = new TvSearchImeState();
        d.open(k);
        d.update(k.query(), -1, -1, 2, k);
        d.close(k);
        d.open(k);
        check(
                d.selection == 2 && k.composition().equals("san"),
                "caret-only cancel retains cursor without flattening built-in pinyin");
        d.close(k);
        d.open(k);
        check(d.selection == 2, "caret survives repeated unchanged reopen");
        k.input("t");
        d.open(k);
        check(
                d.text.equals(k.query()),
                "built-in mutation invalidates stale noncomposing IME draft");
        d.clear();
        check(
                d.before == null && d.text == null && !d.contentChanged && d.selection == 0,
                "privacy invalidation wipes new draft state");

        ImeHostSlice h = new ImeHostSlice(keyboard());
        h.candidatePage = 1;
        h.finishSystemIme(false);
        check(
                h.candidatePage == 1 && h.keyboard.composition().equals("san"),
                "actual close/update host methods preserve candidate page on no-edit Back");
        h = new ImeHostSlice(keyboard());
        h.candidatePage = 1;
        h.cursor = 3;
        h.captureImeUpdate();
        h.finishSystemIme(false);
        check(
                h.candidatePage == 1 && h.imeDraft.selection == 3,
                "actual capture and close keep page for cursor-only edit");
        h = new ImeHostSlice(keyboard());
        h.candidatePage = 1;
        h.from = 2;
        h.to = 5;
        h.cursor = 3;
        h.captureImeUpdate();
        h.finishSystemIme(false);
        check(
                h.candidatePage == 1 && h.imeDraft.composing() && h.searches == 0,
                "same-text composition suspends search and preserves candidate page");
        h = new ImeHostSlice(keyboard());
        h.candidatePage = 1;
        h.value = "电影三";
        h.cursor = 3;
        h.captureImeUpdate();
        h.finishSystemIme(false);
        check(
                h.candidatePage == 0 && h.keyboard.composition().isEmpty(),
                "real committed edit still resets candidates");
        h = new ImeHostSlice(keyboard());
        h.candidatePage = 1;
        h.finishSystemIme(true);
        check(
                h.candidatePage == 0 && h.keyboard.composition().isEmpty(),
                "explicit search confirmation still commits and resets page");

        TailHostSlice t = new TailHostSlice();
        t.tail = 500;
        t.a.player.duration = 5000;
        t.a.player.position = 500;
        t.tick();
        check(
                t.a.player.seeks == 1 && t.a.player.target == 0,
                "actual tick requests first 500ms tail repeat");
        t.tick();
        t.tick();
        check(t.a.player.seeks == 1, "old ticks while seek is pending cannot double trigger");
        t.markerTail.observe(0);
        t.a.player.position = 1000;
        t.tick();
        check(
                t.a.player.seeks == 2,
                "seek observation rearms short loop even when one-second UI tick misses pre-tail interval");
        t = new TailHostSlice();
        t.tail = 5000;
        t.intro = 4500;
        t.a.player.position = 5000;
        t.tick();
        check(
                t.a.player.target == 4500,
                "near-tail intro kept without arbitrary one-second margin");
        t.markerTail.observe(4500);
        t.a.player.position = 5500;
        t.tick();
        check(t.a.player.seeks == 2, "4500-to-5000 interval repeats on next observed pass");
        t = new TailHostSlice();
        t.tail = 5000;
        t.a.player.position = 5000;
        t.tick();
        t.displayOverride = 0;
        t.tick();
        check(t.a.player.seeks == 1, "optimistic progress preview cannot acknowledge a seek");
        t.a.player.position = 0;
        t.tick();
        t.displayOverride = -1;
        t.a.player.position = 5000;
        t.tick();
        check(t.a.player.seeks == 2, "actual backwards sample can rearm independently of callback");
        t = new TailHostSlice();
        t.tail = 500;
        t.intro = 1000;
        t.a.player.position = 500;
        t.tick();
        check(t.a.player.target == 0, "intro beyond tail still falls back to start");
        t.a.markerHost = new Object();
        t.markerTail.observe(0);
        t.tick();
        check(t.a.player.seeks == 1, "open marker transaction suppresses tail action");
        t = new TailHostSlice();
        t.a.tv = false;
        t.tail = 500;
        t.intro = 0;
        t.a.player.position = 500;
        t.tick();
        t.tick();
        check(t.a.player.seeks == 2, "mobile keeps its previous tail branch without TV gate");
        t = new TailHostSlice();
        t.tail = 500;
        t.a.prefs.repeat = 0;
        t.a.player.position = 500;
        t.tick();
        t.tick();
        check(
                t.a.player.pauses == 1 && t.transitioning && !t.a.playing,
                "last episode pauses once when auto step is unavailable");
        TvMarkerTailGate gate = new TvMarkerTailGate();
        gate.node(1);
        check(gate.take(1), "one-ms node triggers");
        gate.observe(-1);
        check(!gate.take(1), "invalid position cannot rearm");
        gate.observe(0);
        check(gate.take(1), "one-ms loop has no impossible negative reset threshold");
        gate.node(0);
        check(!gate.take(9000), "disabled marker never triggers");
        gate.node(701000);
        check(gate.take(701000), "long node does not truncate at 600 seconds");
        gate.reset();
        gate.node(701000);
        check(gate.take(701000), "new control identity resets gate");
        System.out.println(
                "ALL PASS (" + count + " R3 boundary/host-slice checks; no native execution)");
    }
}
