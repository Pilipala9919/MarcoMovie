package com.pilipala.marcomovie;

import java.util.*;

/** Actual snapshot comparator; this does not drive Android rendering or focus. */
public final class HomeRefreshChecks {
    static int checks;

    static void check(boolean value, String name) {
        if (!value) throw new AssertionError(name);
        checks++;
        System.out.println("PASS " + name);
    }

    static HomeScreen.Snapshot sample() throws Exception {
        String raw =
                "{\"list\":[{\"vod_id\":\"a\",\"vod_name\":\"first\"},"
                        + "{\"vod_id\":\"b\",\"vod_name\":\"second\",\"vod_pic\":\"https://fixture.test/b.png\","
                        + "\"vod_play_from\":\"line\",\"vod_play_url\":\"ep$https://fixture.test/b.mp4\"}],"
                        + "\"class\":[{\"type_id\":\"cat\",\"type_name\":\"category\"}]}";
        return new HomeScreen.Snapshot(Cms.listing(raw).videos, Cms.categories(raw), "", 1);
    }

    interface Change {
        void apply(HomeScreen.Snapshot s) throws Exception;
    }

    static void changed(String name, Change mutate) throws Exception {
        HomeScreen.Snapshot a = sample(), b = sample();
        mutate.apply(b);
        check(!HomeScreen.sameSnapshotContent(a, b), name);
    }

    public static void main(String[] args) throws Exception {
        check(
                HomeScreen.sameSnapshotContent(sample(), sample()),
                "identical fresh response retains the tree");
        changed("same first id and count, later id replaced", s -> s.videos.get(1).id = "c");
        changed("same ids, title updated", s -> s.videos.get(1).title = "updated");
        changed("poster updated", s -> s.videos.get(1).poster = "https://fixture.test/new.png");
        changed("remote action updated", s -> s.videos.get(1).action = "folder");
        changed("filter value updated", s -> s.videos.get(1).year = "2026");
        changed("detail description updated", s -> s.videos.get(1).description = "new description");
        changed("rating updated", s -> s.videos.get(1).doubanScore = "9.1");
        changed("category name updated", s -> s.categories.get(0).name = "renamed");
        changed("filter schema updated", s -> s.filterSchema = "{\"filters\":{}}");
        changed(
                "episode URL updated",
                s ->
                        s.videos.get(1).lines.get(0).episodes.get(0).url =
                                "https://fixture.test/new.mp4");
        changed(
                "episode header updated",
                s ->
                        s.videos
                                .get(1)
                                .lines
                                .get(0)
                                .episodes
                                .get(0)
                                .headers
                                .put("Referer", "https://fixture.test"));
        changed(
                "episode media updated",
                s -> s.videos.get(1).lines.get(0).episodes.get(0).media.put("parse", 1));
        changed("video order updated", s -> Collections.reverse(s.videos));
        HomeScreen.Snapshot a = sample();
        check(
                !HomeScreen.sameSnapshotContent(
                        a, new HomeScreen.Snapshot(a.videos, a.categories, "", 2)),
                "page count updated");
        check(
                !HomeScreen.sameSnapshotContent(
                        a, new HomeScreen.Snapshot(a.videos, a.categories, "cat", 1)),
                "fallback category updated");
        System.out.println(
                "OK " + checks + " actual snapshot comparison checks; no native UI claim");
    }
}
