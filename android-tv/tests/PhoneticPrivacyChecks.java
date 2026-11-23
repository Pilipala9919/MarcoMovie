package com.pilipala.marcomovie;

import java.nio.file.*;
import java.util.*;

/** Synthetic titles only. The host uses exact extracted production methods, not a reimplementation. */
public final class PhoneticPrivacyChecks {
    static int checks;
    static final String SECRET = "斗罗大陆隐私专属", PUBLIC = "三体公有合成剧";

    static void check(boolean ok, String label) {
        if (!ok) throw new AssertionError(label);
        checks++;
        System.out.println("PASS " + label);
    }

    static PhoneticHost host(boolean privateMode) {
        PhoneticHost h = new PhoneticHost();
        h.privateMode = privateMode;
        h.initialize();
        return h;
    }

    static boolean absent(PhoneticSearchIndex i, String title, String query) {
        return !i.titles.containsKey(title)
                && !i.suggestTitles(query, 8).contains(title)
                && !i.expand(query).contains(title)
                && !i.preferred.contains(title);
    }

    static List<Cms.Video> videos(String title) {
        Cms.Video v = new Cms.Video();
        v.id = "synthetic";
        v.title = title;
        return Collections.singletonList(v);
    }

    static void revoke(PhoneticHost h) {
        h.switchingPrivacy = true;
        h.engineEpoch++;
        TvSearchContext.revokeAll();
        h.phonetic = null;
    }

    public static void main(String[] args) throws Exception {
        PhoneticHost.assets = Paths.get(args[0], "android-tv/src/main/assets");
        PhoneticHost secret = host(true);
        MatchSlice match = new MatchSlice(secret);
        List<String> terms = SearchVariants.mergeTerms("dldl", secret.phonetic.searchTerms("dldl"));
        TvSearchPages result =
                TvSearchPages.first(
                        "dldl",
                        terms,
                        title -> match.matchesTitle(title, "dldl"),
                        (term, page) -> {
                            Cms.Listing l = new Cms.Listing();
                            l.page = 1;
                            l.pageCount = 1;
                            if (term.equals("斗罗大陆")) l.videos.addAll(videos(SECRET));
                            return l;
                        });
        check(result.videos.size() == 1, "private expanded real paging still finds matching title");
        check(
                absent(secret.phonetic, SECRET, "dldl"),
                "matching has no learning/suggestion/expansion side effect");
        secret.phonetic.learn(SECRET);
        secret.phonetic.prefer(SECRET);
        check(
                absent(secret.phonetic, SECRET, "dldl"),
                "private session rejects explicit learn and prefer");
        PhoneticSearchIndex former = secret.phonetic;
        revoke(secret);
        PhoneticHost normal = host(false);
        check(
                absent(normal.phonetic, SECRET, "dldl"),
                "private to public recreate has no private suggestions");
        check(former != normal.phonetic, "Activity sessions do not share mutable index");
        normal.phonetic.learn(PUBLIC);
        PhoneticHost reverse = host(true);
        check(
                absent(reverse.phonetic, PUBLIC, "st"),
                "public to private does not import public learned titles");
        check(
                normal.phonetic.suggestTitles("st", 8).contains(PUBLIC),
                "ordinary explicit learning still works");

        PhoneticHost legacy = new PhoneticHost();
        legacy.prefs.values.put(Prefs.PHONETIC_TITLES, "[\"" + SECRET + "\"]");
        legacy.prefs.values.put(Prefs.GLOBAL_SEARCH_HISTORY, "[\"" + SECRET + "\"]");
        legacy.prefs.values.put(Prefs.FAVORITES, "user-favorites-sentinel");
        Map<String, String> before = new HashMap<>(legacy.prefs.values);
        legacy.initialize();
        check(
                absent(legacy.phonetic, SECRET, "dldl"),
                "untrusted legacy cache/history not imported into suggestions");
        check(
                before.equals(legacy.prefs.values) && legacy.prefs.writes == 0,
                "legacy data kept byte-for-byte with zero migration writes");
        // Simulate the previous version's contaminated Activity, then recreate against clean
        // assets.
        legacy.phonetic.learn(SECRET);
        PhoneticHost recreated = new PhoneticHost();
        recreated.prefs = legacy.prefs;
        recreated.initialize();
        check(
                absent(recreated.phonetic, SECRET, "dldl"),
                "contaminated old Activity index is not reused");
        check(
                absent(PhoneticHost.sharedPhoneticDictionary, SECRET, "dldl"),
                "shared assets template was never contaminated");
        check(
                absent(legacy.phonetic.newSession(true), SECRET, "dldl"),
                "even a polluted session forks from assets only");

        PhoneticHost late = host(false);
        LearnSlice.learnTitles(late, videos(PUBLIC));
        late.ui.drain();
        revoke(late);
        late.phoneticWork.drain();
        late.ui.drain();
        check(late.prefs.writes == 0, "switch before queued worker rejects persistence");
        late = host(false);
        PhoneticSearchIndex oldIndex = late.phonetic;
        LearnSlice.learnTitles(late, videos(PUBLIC));
        late.ui.drain();
        late.phoneticWork.drain();
        revoke(late);
        late.ui.drain();
        check(
                late.prefs.writes == 0 && absent(oldIndex, PUBLIC, "st"),
                "switch after worker before UI commit rejects mutation and persistence");
        late = host(false);
        LearnSlice.learnTitles(late, videos(PUBLIC));
        late.ui.drain();
        late.phoneticWork.drain();
        late.destroyed = true;
        late.ui.drain();
        check(late.prefs.writes == 0, "destroyed Activity rejects delayed learning");
        late = host(true);
        LearnSlice.learnTitles(late, videos(SECRET));
        late.ui.drain();
        late.phoneticWork.drain();
        late.ui.drain();
        check(
                late.prefs.writes == 0 && late.pendingTitles.isEmpty(),
                "private input never schedules persistent learning");
        late = new PhoneticHost();
        late.initializePhonetic();
        revoke(late);
        late.worker.drain();
        late.ui.drain();
        check(
                late.phonetic == null && late.phoneticReady.getCount() == 0,
                "late initialization after switch cannot publish index");
        late = new PhoneticHost();
        late.initializePhonetic();
        late.privateMode = true;
        late.worker.drain();
        late.ui.drain();
        check(
                late.phonetic == null,
                "initialization cannot cross a changed space even without switch flag");
        late = new PhoneticHost();
        late.initializePhonetic();
        late.prefs = new PhoneticHost.MemoryPrefs();
        late.worker.drain();
        late.ui.drain();
        check(late.phonetic == null, "initialization cannot cross replaced preference storage");
        late = new PhoneticHost();
        late.initializePhonetic();
        late.config = new Object();
        late.engineEpoch++;
        TvSearchContext.revokeAll();
        late.worker.drain();
        late.ui.drain();
        check(
                late.phonetic != null,
                "source-only change keeps safe assets initialization available");

        PhoneticHost writer = host(false);
        LearnSlice.learnTitles(writer, videos(PUBLIC));
        writer.ui.drain();
        writer.phoneticWork.drain();
        writer.ui.drain();
        check(
                writer.prefs.writes == 1 && writer.phonetic.suggestTitles("st", 8).contains(PUBLIC),
                "current public UI commit learns and saves V2");
        check(
                !writer.prefs.values.containsKey(Prefs.PHONETIC_TITLES),
                "V2 learning does not overwrite quarantined legacy key");
        PhoneticHost.sharedPhoneticDictionary = null;
        PhoneticHost process = new PhoneticHost();
        process.prefs = writer.prefs;
        process.initialize();
        check(
                process.phonetic.suggestTitles("st", 8).contains(PUBLIC),
                "verified public cache survives process restart");
        // Restore old data into a new process: retained bytes remain excluded, not deleted.
        PhoneticHost.sharedPhoneticDictionary = null;
        PhoneticHost restored = new PhoneticHost();
        restored.prefs.values.putAll(before);
        restored.initialize();
        check(
                absent(restored.phonetic, SECRET, "dldl") && before.equals(restored.prefs.values),
                "legacy backup restore cannot resurrect polluted index");
        check(!normal.phonetic.matches(null, "dldl"), "null remote title safely rejected");
        check(
                normal.phonetic.matches(SECRET, "douluodalu")
                        && normal.phonetic.matches(SECRET, "dldl"),
                "full pinyin and initials matching retained");
        check(absent(normal.phonetic, SECRET, "dldl"), "repeated matching remains read only");
        PhoneticSearchIndex.PreparedTitles staged =
                normal.phonetic.prepareTitles(Collections.singletonList(SECRET));
        check(
                absent(normal.phonetic, SECRET, "dldl"),
                "worker pronunciation preparation does not publish anything");
        reverse.phonetic.learnPrepared(staged);
        check(
                absent(reverse.phonetic, SECRET, "dldl"),
                "private session rejects even public prepared learning");

        PhoneticHost queued = host(false);
        LearnSlice.learnTitles(queued, videos("公有批次甲"));
        queued.ui.drain();
        LearnSlice.learnTitles(queued, videos("公有批次乙"));
        queued.ui.drain();
        queued.phoneticWork.drain();
        check(queued.prefs.writes == 0, "both ordinary workers finish before either UI commit");
        queued.ui.drain();
        String merged = queued.prefs.getString(Prefs.PHONETIC_PUBLIC_TITLES_V2, "[]");
        check(
                merged.contains("公有批次甲") && merged.contains("公有批次乙"),
                "queued UI commits merge both public batches");
        PhoneticHost restarted = new PhoneticHost();
        restarted.prefs = queued.prefs;
        restarted.initialize();
        check(
                restarted.phonetic.titles.containsKey("公有批次甲")
                        && restarted.phonetic.titles.containsKey("公有批次乙"),
                "both batches remain after recreation");
        queued = host(false);
        for (int batch = 0; batch < 2; batch++) {
            List<Cms.Video> many = new ArrayList<>();
            for (int i = 0; i < 250; i++) many.addAll(videos("public-batch-" + (batch * 250 + i)));
            LearnSlice.learnTitles(queued, many);
            queued.ui.drain();
        }
        queued.phoneticWork.drain();
        queued.ui.drain();
        org.json.JSONArray bounded =
                new org.json.JSONArray(
                        queued.prefs.getString(Prefs.PHONETIC_PUBLIC_TITLES_V2, "[]"));
        check(
                bounded.length() == 400
                        && bounded.getString(0).equals("public-batch-100")
                        && bounded.getString(399).equals("public-batch-499"),
                "queued cache respects ordered 400 title cap");
        String longTitle = String.join("", Collections.nCopies(100, "x")) + " Batman";
        PhoneticSearchIndex literal = normal.phonetic;
        literal.learn("Batman");
        check(
                longTitle.length() == 107 && literal.matches(longTitle, "bat"),
                "107 character literal match remains valid");
        TvSearchPages longPage =
                TvSearchPages.first(
                        "bat",
                        SearchVariants.mergeTerms("bat", literal.searchTerms("bat")),
                        title -> literal.matches(title, "bat"),
                        (term, page) -> {
                            Cms.Listing l = new Cms.Listing();
                            l.page = 1;
                            l.pageCount = 1;
                            if (term.equals("Batman")) l.videos.addAll(videos(longTitle));
                            return l;
                        });
        check(longPage.videos.size() == 1, "expanded remote result preserves long matching title");
        check(
                !literal.titles.containsKey(longTitle),
                "long match still does not learn or persist title");
        System.out.println("TOTAL " + checks);
    }
}
