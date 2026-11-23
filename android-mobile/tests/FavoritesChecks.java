package com.pilipala.marcomovie;

import org.json.*;

public final class FavoritesChecks {
    static int checks;

    static void check(boolean ok, String label) {
        if (!ok) throw new AssertionError(label);
        checks++;
    }

    public static void main(String[] args) throws Exception {
        Cms.Video video = new Cms.Video();
        video.id = "one";
        video.title = "Test";
        video.poster = "https://image.test/poster.jpg";
        String data = Favorites.toggle("[]", "alpha", video);
        check(Favorites.contains(data, "alpha", "one"), "Saved favorite survives JSON read");
        data = Favorites.toggle(data, "beta", video);
        check(Favorites.read(data).size() == 2, "Same ID in different sources remains distinct");
        data = Favorites.toggle(data, "alpha", video);
        check(
                !Favorites.contains(data, "alpha", "one")
                        && Favorites.contains(data, "beta", "one"),
                "Remove only selected source title");
        check(
                new JSONArray(data).getJSONObject(0).length() == 4,
                "Persist only source, title, ID and poster; no playback URL");
        check(Favorites.read("broken").isEmpty(), "Malformed storage recovers");
        check(Favorites.read("[{},null]").isEmpty(), "Invalid entries ignored");
        for (int i = 0; i < 305; i++) {
            video.id = "id" + i;
            data = Favorites.toggle(data, "alpha", video);
        }
        check(Favorites.read(data).size() == 300, "Bounded collection");
        check(Favorites.read(data).get(0).id.equals("id304"), "Newest favorite first");

        String skips = VideoSkipStore.writeSkip("[]", "siteA", "vod-1", true, 88, 1000L);
        skips = VideoSkipStore.writeSkip(skips, "siteA", "vod-1", false, 95, 1001L);
        skips = VideoSkipStore.writeSkip(skips, "siteA", "vod-2", true, 42, 1002L);
        check(
                VideoSkipStore.readIntro(skips, "siteA", "vod-1") == 88
                        && VideoSkipStore.readOutro(skips, "siteA", "vod-1") == 95
                        && VideoSkipStore.readIntro(skips, "siteA", "vod-2") == 42
                        && VideoSkipStore.readOutro(skips, "siteA", "vod-2") == 0
                        && VideoSkipStore.readIntro(skips, "siteB", "vod-1") == 0
                        && VideoSkipStore.countRecords(skips) == 2,
                "Per-video intro/outro skip records stay isolated per site and video");
        skips = VideoSkipStore.writeSkip(skips, "siteA", "vod-2", true, 0, 1003L);
        check(
                VideoSkipStore.readIntro(skips, "siteA", "vod-2") == 0
                        && VideoSkipStore.countRecords(skips) == 1,
                "Clearing both intro and outro removes empty video skip record");
        check(
                VideoSkipStore.defaultSecondsFromPlayback(true, 0, 86400, 2700000) == 86
                        && VideoSkipStore.defaultSecondsFromPlayback(false, 0, 2595000, 2700000)
                                == 105
                        && VideoSkipStore.defaultSecondsFromPlayback(false, 0, 92000, 2700000)
                                == 92,
                "Clicking intro/outro in player defaults to current playback time first");
        VideoSkipStore.clearPrivateRecords();
        VideoSkipStore.setPrivateSkip("privSite", "vod-p", true, 75);
        check(
                VideoSkipStore.getPrivateSkip("privSite", "vod-p", true) == 75
                        && VideoSkipStore.countPrivateRecords() == 1,
                "Private session skip records stay in memory");
        VideoSkipStore.clearPrivateRecords();
        check(VideoSkipStore.countPrivateRecords() == 0, "Private skip records clear on exit");

        System.out.println("PASS " + checks + " favorite and per-video skip persistence checks");
    }
}
