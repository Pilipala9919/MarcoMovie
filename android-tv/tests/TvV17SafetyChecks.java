package com.pilipala.marcomovie;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import org.json.*;

/** Actual store/repository/transaction/IME models; deliberately not an Android UI simulation. */
public final class TvV17SafetyChecks {
    static int count;

    interface Checked {
        void run() throws Exception;
    }

    static void check(boolean value, String label) {
        if (!value) throw new AssertionError(label);
        count++;
        System.out.println("PASS " + label);
    }

    static void rejects(Checked task, String label) throws Exception {
        try {
            task.run();
        } catch (IOException | IllegalArgumentException | IllegalStateException expected) {
            check(true, label);
            return;
        }
        throw new AssertionError(label);
    }

    static String hash(String value) throws Exception {
        return ConfigLibrary.hash(value);
    }

    static VideoMarkerStore.Identity id(
            String scope, String config, String site, String video, String ep, String line)
            throws Exception {
        return new VideoMarkerStore.Identity(
                scope, hash(config), hash(site), hash(video), hash(ep), hash(line));
    }

    static final class Memory implements VideoMarkerRepository.Backend {
        String raw = "", backup;
        boolean fail;
        int writes;

        public String read() {
            return raw;
        }

        public void write(String value) throws IOException {
            if (fail) throw new IOException("fixture write failure");
            raw = value;
            writes++;
        }

        public void preserve(String value) {
            backup = value;
        }
    }

    static final class Player implements TvMarkerTransaction.Player {
        long pos = 100000, duration = 7200000;
        boolean playing = true;
        int starts, pauses;

        public long position() {
            return pos;
        }

        public long duration() {
            return duration;
        }

        public boolean playing() {
            return playing;
        }

        public void pause() {
            playing = false;
            pauses++;
        }

        public void seek(long value) {
            pos = value;
        }

        public void start() {
            playing = true;
            starts++;
        }
    }

    public static void main(String[] args) throws Exception {
        VideoMarkerStore.Identity key =
                id("public", "configA", "siteA", "videoA", "episode1", "lineA");
        String legacy = "[ {\"site\":\"s\",\"id\":\"v\",\"intro\":88,\"outro\":95,\"updated\":9} ]";
        check(
                VideoSkipStore.readIntro(legacy, "s", "v") == 88
                        && 7200000 - VideoSkipStore.readOutro(legacy, "s", "v") * 1000 == 7105000,
                "legacy tail remains remaining seconds and old intro remains seconds");
        String original = legacy;
        String raw =
                VideoMarkerStore.update(
                        "", 0, key, true, new VideoMarkerStore.Field(1, 701000, 7200000));
        raw =
                VideoMarkerStore.update(
                        raw, 1, key, false, new VideoMarkerStore.Field(1, 7105000, 7200000));
        VideoMarkerStore.Document doc = VideoMarkerStore.read(raw);
        check(
                doc.revision == 2
                        && doc.field(key, true).position == 701000
                        && doc.field(key, false).position == 7105000,
                "independent long-ms fields retain >600s and absolute tail");
        check(
                legacy.equals(original) && !raw.contains("\"outro\":95"),
                "V2 never rewrites or embeds legacy data");
        check(
                VideoMarkerStore.effective(doc.field(key, false), 7200000) == 7105000,
                "same duration enables absolute tail");
        check(
                VideoMarkerStore.effective(doc.field(key, false), 7272000) == 7105000,
                "duration tolerance includes one percent boundary");
        check(
                VideoMarkerStore.effective(doc.field(key, false), 7272001) == 0,
                "changed duration suspends automatic tail");
        check(
                doc.field(id("public", "configB", "siteA", "videoA", "episode1", "lineA"), true)
                                .mode
                        == 0,
                "same video under another configuration does not inherit V2");
        check(
                doc.field(id("public", "configA", "siteB", "videoA", "episode1", "lineA"), true)
                                .mode
                        == 0,
                "another source does not inherit V2");
        check(
                doc.field(id("public", "configA", "siteA", "videoB", "episode1", "lineA"), true)
                                .mode
                        == 0,
                "another video does not inherit V2");
        check(
                doc.field(id("public", "configA", "siteA", "videoA", "episode2", "lineA"), true)
                                .mode
                        == 0,
                "another episode does not inherit V2");
        check(
                doc.field(id("public", "configA", "siteA", "videoA", "episode1", "lineB"), true)
                                .mode
                        == 0,
                "another line does not inherit V2");
        check(
                doc.field(id("private", "configA", "siteA", "videoA", "episode1", "lineA"), true)
                                .mode
                        == 0,
                "private and public identities never match");
        String disabled =
                VideoMarkerStore.update(raw, 2, key, false, new VideoMarkerStore.Field(2, 0, 0));
        check(
                VideoMarkerStore.effective(
                                VideoMarkerStore.read(disabled).field(key, false), 7200000)
                        == 0,
                "disable tombstone prevents legacy fallback");
        String restored =
                VideoMarkerStore.update(disabled, 3, key, false, VideoMarkerStore.Field.inherit());
        check(
                VideoMarkerStore.effective(
                                VideoMarkerStore.read(restored).field(key, false), 7200000)
                        == -1,
                "explicit restore opts back into legacy semantics");
        String unknown =
                VideoMarkerStore.update(
                        "", 0, key, false, new VideoMarkerStore.Field(1, 7105000, 0));
        check(
                VideoMarkerStore.effective(
                                VideoMarkerStore.read(unknown).field(key, false), 7200000)
                        == 0,
                "unknown observed duration never silently enables after duration appears");
        String confirmed =
                VideoMarkerStore.update(
                        unknown, 1, key, false, new VideoMarkerStore.Field(1, 7105000, 7200000));
        check(
                VideoMarkerStore.effective(
                                VideoMarkerStore.read(confirmed).field(key, false), 7200000)
                        == 7105000,
                "explicit duration confirmation enables the same node");
        String huge =
                VideoMarkerStore.update(
                        "", 0, key, true, new VideoMarkerStore.Field(1, Long.MAX_VALUE, 0));
        check(
                VideoMarkerStore.read(huge).field(key, true).position == Long.MAX_VALUE,
                "schema round-trips maximum long without seconds truncation");
        rejects(() -> new VideoMarkerStore.Field(1, 0, 0), "zero node rejected");
        rejects(() -> new VideoMarkerStore.Field(1, -1, 0), "negative node rejected");
        rejects(() -> new VideoMarkerStore.Field(1, 1000, 1000), "node at known end rejected");
        final String saved = raw;
        rejects(
                () ->
                        VideoMarkerStore.update(
                                saved, 1, key, true, new VideoMarkerStore.Field(1, 1000, 0)),
                "stale revision cannot overwrite newer field");
        rejects(() -> VideoMarkerStore.read("{bad"), "corrupt document rejected");
        rejects(
                () -> VideoMarkerStore.read(saved.replace("\"schema\":2", "\"schema\":3")),
                "future schema not rewritten");
        rejects(
                () -> VideoMarkerStore.read(saved.replace("\"revision\":2", "\"revision\":\"2\"")),
                "numeric strings cannot change data semantics");
        JSONObject full = new JSONObject(saved);
        JSONArray records = full.getJSONArray("records");
        JSONObject seed = records.getJSONObject(0);
        for (int i = 1; i < 500; i++)
            records.put(new JSONObject(seed.toString()).put("videoId", hash("v" + i)));
        String fullRaw = full.toString();
        check(
                VideoMarkerStore.read(fullRaw).records.size() == 500,
                "500 records retained including disabled state");
        rejects(
                () ->
                        VideoMarkerStore.update(
                                fullRaw,
                                2,
                                id("public", "c", "s", "new", "e", "l"),
                                true,
                                new VideoMarkerStore.Field(1, 1, 0)),
                "501st record rejected without eviction or legacy resurrection");
        records.put(seed);
        rejects(
                () -> VideoMarkerStore.read(full.toString()),
                "oversized document not silently truncated");
        JSONObject duplicate = new JSONObject(saved);
        duplicate.getJSONArray("records").put(seed);
        rejects(
                () -> VideoMarkerStore.read(duplicate.toString()),
                "duplicate identities are corruption");

        Memory disk = new Memory();
        final boolean[] valid = {true};
        VideoMarkerRepository repo = new VideoMarkerRepository(key, true, disk, () -> valid[0]);
        repo.write(0, true, new VideoMarkerStore.Field(1, 110000, 7200000));
        check(
                repo.read().field(key, true).position == 110000 && disk.writes == 1,
                "repository commits selected position once");
        String beforeFailure = disk.raw;
        disk.fail = true;
        rejects(
                () -> repo.write(1, false, new VideoMarkerStore.Field(1, 7000000, 7200000)),
                "write failure is propagated");
        check(disk.raw.equals(beforeFailure), "failed atomic backend leaves prior document intact");
        disk.fail = false;
        valid[0] = false;
        rejects(
                () -> repo.write(1, false, new VideoMarkerStore.Field(1, 7000000, 7200000)),
                "revoked owner cannot persist late save");
        valid[0] = true;
        disk.raw = "{damaged";
        rejects(repo::read, "corruption blocks reads");
        check(
                disk.backup.equals(disk.raw) && disk.writes == 1,
                "corrupt original copied to backup without replacement");
        rejects(
                () -> repo.write(0, true, new VideoMarkerStore.Field(1, 110000, 7200000)),
                "corruption cannot be treated as empty on save");

        Cms.Config config = new Cms.Config();
        config.raw = "{\"sites\":[]}";
        config.origin = "https://fixture.invalid/config?secret=never-serialize";
        Cms.Site site = new Cms.Site();
        site.key = "source";
        Cms.Video video = new Cms.Video();
        video.id = "video-1";
        Cms.Line line = new Cms.Line();
        line.name = "main";
        video.lines.add(line);
        Cms.Episode ep = new Cms.Episode();
        ep.url = "source-episode-1";
        ep.name = "Episode 1";
        line.episodes.add(ep);
        VideoMarkerStore.Identity stable =
                VideoMarkerRepository.identify(config, site, video, line, ep, false);
        check(
                stable != null && !stable.key().contains("secret"),
                "opaque source IDs produce hashed non-secret identity");
        ep.url = "https://fixture.invalid/play?token=secret";
        check(
                VideoMarkerRepository.identify(config, site, video, line, ep, false) == null,
                "signed playback URL falls back to session only");
        ep.url = "source-episode-1";
        video.lines.add(line);
        check(
                VideoMarkerRepository.identify(config, site, video, line, ep, false) == null,
                "ambiguous duplicate line flag cannot persist");

        Player player = new Player();
        TvMarkerTransaction tx = new TvMarkerTransaction(player, () -> true);
        check(
                !player.playing && tx.entry == 100000 && tx.wasPlaying,
                "entry captures position and pauses same player");
        tx.preview(110000);
        long[] written = {0};
        tx.confirm(false, 110000, (i, p, d) -> written[0] = p);
        check(
                written[0] == 110000 && player.pos == 110000 && player.starts == 1,
                "100s plus explicit 10s saves and resumes at 110s");
        rejects(
                () -> tx.confirm(false, 120000, (i, p, d) -> written[0] = p),
                "closed transaction rejects duplicate save");
        player = new Player();
        player.playing = false;
        TvMarkerTransaction paused = new TvMarkerTransaction(player, () -> true);
        paused.cancel();
        check(!player.playing && player.starts == 0, "original pause remains paused on cancel");
        player = new Player();
        TvMarkerTransaction canceled = new TvMarkerTransaction(player, () -> true);
        canceled.preview(110000);
        canceled.cancel();
        check(
                player.pos == 110000 && player.starts == 1,
                "cancel keeps deliberate preview and resumes original playing state");
        player = new Player();
        final boolean[] owner = {true};
        TvMarkerTransaction stale = new TvMarkerTransaction(player, () -> owner[0]);
        owner[0] = false;
        rejects(
                () ->
                        stale.confirm(
                                true,
                                100000,
                                (i, p, d) -> {
                                    throw new AssertionError("late write");
                                }),
                "changed player/page/space refuses persistence");
        stale.cancel();
        check(player.starts == 0, "changed identity cannot auto-resume");
        player = new Player();
        TvMarkerTransaction aborted = new TvMarkerTransaction(player, () -> true);
        aborted.abort();
        aborted.cancel();
        check(player.starts == 0, "background/focus abort never resumes when focus later returns");
        player = new Player();
        TvMarkerTransaction retry = new TvMarkerTransaction(player, () -> true);
        rejects(
                () ->
                        retry.confirm(
                                true,
                                100000,
                                (i, p, d) -> {
                                    throw new IOException("disk");
                                }),
                "save failure keeps transaction retryable");
        check(!player.playing && !retry.closed, "save failure preserves pause");
        retry.confirm(true, 100000, (i, p, d) -> {});
        check(player.starts == 1, "successful retry resumes exactly once");

        PinyinKeyboardModel keyboard =
                new PinyinKeyboardModel(
                        new ByteArrayInputStream(
                                "san\t三伞\nti\t体题\n".getBytes(StandardCharsets.UTF_8)));
        keyboard.set("电影");
        keyboard.input("san");
        TvSearchImeState ime = new TvSearchImeState();
        ime.open(keyboard);
        ime.close(keyboard);
        check(
                keyboard.committed().equals("电影")
                        && keyboard.composition().equals("san")
                        && keyboard.candidates().size() == 2,
                "open and cancel unchanged IME preserves built-in composition and candidates");
        ime.open(keyboard);
        ime.update("电影sant", 2, 6, 6, keyboard);
        check(
                ime.composing() && keyboard.query().equals("电影san"),
                "IME composing edit is not flattened into submitted query");
        ime.close(keyboard);
        TvSearchImeState copied = ime.copy();
        check(
                copied.composing() && copied.text.equals("电影sant") && copied.selection == 6,
                "draft region and selection survive page snapshot");
        copied.update("电影三体", -1, -1, 4, keyboard);
        copied.close(keyboard);
        check(
                keyboard.query().equals("电影三体") && keyboard.composition().isEmpty(),
                "IME commit becomes searchable committed text");
        ime.clear();
        check(
                ime.before == null && ime.text == null && !ime.composing(),
                "privacy invalidation clears all IME draft fields");

        TvSearchPageSlot slot = new TvSearchPageSlot();
        SearchCoordinator old =
                new SearchCoordinator(
                        (s, q) -> Collections.emptyList(), (s, v, o) -> {}, 1000, 2000);
        SearchCoordinator next =
                new SearchCoordinator(
                        (s, q) -> Collections.emptyList(), (s, v, o) -> {}, 1000, 2000);
        slot.bind(old);
        slot.cancel();
        slot.bind(next);
        check(
                !slot.finish(old) && slot.get() == next,
                "late canceled page cannot release successor request");
        check(
                slot.finish(next) && slot.get() == null,
                "completion always releases own busy slot before result identity guard");
        slot.bind(old);
        check(
                slot.finish(old) && slot.get() == null,
                "replaced SourceResult still permits request cleanup");
        WatchHistory.Entry history = new WatchHistory.Entry();
        history.episode = "E1";
        history.position = 61000;
        history.duration = 180000;
        check(
                CatalogScreen.historyLabel(history).contains("1:01")
                        && CatalogScreen.historyLabel(history).contains("3:00"),
                "detail history uses old position and total duration label");
        history.position = history.duration;
        check(
                CatalogScreen.historyLabel(history).contains("已看完"),
                "completed detail history label retained");
        System.out.println(
                "ALL PASS ("
                        + count
                        + " V17 safety model checks; no Android UI, disk power-loss, or device execution)");
    }
}
