package com.pilipala.marcomovie;

import android.view.KeyEvent;

/** Pure host decisions; no Android view/focus/playback claims. */
public final class TvRouteHostChecks {
    static int count;

    static void check(boolean ok, String label) {
        if (!ok) throw new AssertionError(label);
        count++;
        System.out.println("PASS " + label);
    }

    static Cms.Line line(String name) {
        Cms.Line l = new Cms.Line();
        l.name = name;
        for (int n = 0; n < 120; n++) {
            Cms.Episode e = new Cms.Episode();
            e.name = "E" + n;
            e.url = "https://fixture.invalid/" + n;
            l.episodes.add(e);
        }
        return l;
    }

    public static void main(String[] args) {
        TvMenuAction.Release key = new TvMenuAction.Release();
        check(!key.key(KeyEvent.ACTION_UP, 0, 10, false), "orphan MENU release ignored");
        key.key(KeyEvent.ACTION_DOWN, 0, 10, false);
        check(!key.key(KeyEvent.ACTION_UP, 0, 11, false), "mismatched downTime rejected");
        key.key(KeyEvent.ACTION_DOWN, 0, 10, false);
        check(!key.key(KeyEvent.ACTION_UP, 0, 10, true), "canceled MENU release ignored");
        key.key(KeyEvent.ACTION_DOWN, 0, 10, false);
        key.reset();
        check(!key.key(KeyEvent.ACTION_UP, 0, 10, false), "focus loss invalidates pending MENU");
        key.key(KeyEvent.ACTION_DOWN, 0, 10, false);
        key.key(KeyEvent.ACTION_DOWN, 2, 10, false);
        check(
                key.key(KeyEvent.ACTION_UP, 0, 10, false)
                        && !key.key(KeyEvent.ACTION_UP, 0, 10, false),
                "repeat sequence commits once");

        LiveCatalog.Source source = new LiveCatalog.Source();
        LiveCatalog.Catalog catalog = new LiveCatalog.Catalog();
        LiveCatalog.Group group = new LiveCatalog.Group();
        LiveCatalog.Channel a = new LiveCatalog.Channel(), b = new LiveCatalog.Channel();
        a.streams.add(new LiveCatalog.Stream());
        b.streams.add(new LiveCatalog.Stream());
        group.channels.add(a);
        group.channels.add(b);
        catalog.groups.add(group);
        LiveSession session = LiveSession.forChannel(source, catalog, b);
        check(
                session.source == source && session.index == 1,
                "selected catalog and channel form one playback session");
        check(
                session.step(1) == 0 && session.step(-1) == 0,
                "channel stepping uses the selected catalog");
        session.digit(1);
        check(session.selectedNumber() == 0, "numeric tuning uses selected catalog order");
        try {
            LiveSession.forChannel(source, catalog, new LiveCatalog.Channel());
            throw new AssertionError();
        } catch (IllegalArgumentException expected) {
            check(true, "foreign cached channel cannot bind to different catalog");
        }

        Cms.Video video = new Cms.Video();
        video.lines.add(line("A"));
        video.lines.add(line("B"));
        WatchHistory.Entry bookmark = new WatchHistory.Entry();
        bookmark.line = "A";
        bookmark.episode = "E70";
        int[] chosen = TvDetailHost.initialSelection(video, bookmark, "B", null, false);
        check(chosen[0] == 0 && chosen[1] == 1, "bookmark A wins over default line B");
        chosen = TvDetailHost.initialSelection(video, null, "B", null, false);
        check(
                chosen[0] == 1 && chosen[1] == 0,
                "without bookmark the configured default line wins");
        chosen = TvDetailHost.initialSelection(video, null, "missing", null, false);
        check(chosen[0] == 0, "missing preferred line falls back to first playable line");
        chosen = TvDetailHost.initialSelection(video, bookmark, "B", null, true);
        check(
                chosen[0] == 0 && chosen[1] == 0,
                "descending browse locates original bookmark episode");
        EpisodeSelection saved = new EpisodeSelection();
        saved.select("B", 9, 120);
        chosen = TvDetailHost.initialSelection(video, bookmark, "A", saved, false);
        check(
                chosen[0] == 1 && chosen[1] == 2,
                "return preserves independently selected bounded line and page");
        System.out.println("ALL PASS (" + count + " route host checks; no native view/playback)");
    }
}
