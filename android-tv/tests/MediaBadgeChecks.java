import com.pilipala.marcomovie.MediaBadges;
import com.pilipala.marcomovie.lite.LiteBadges;
import java.io.File;
import java.io.FileInputStream;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Offline JVM verification suite for MediaBadges (Android) and LiteBadges (Lite API 14).
 *
 * <p>Validates 165/165 cases in shared/ui-spec/badge-golden.json with 0 diff, verifies 256-entry
 * LRU cache eviction, benchmarks average match latency (< 0.2ms), and tests pure-data live track
 * fusion.
 */
public final class MediaBadgeChecks {
    private static final Charset UTF8 = Charset.forName("UTF-8");

    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            throw new IllegalArgumentException(
                    "Usage: MediaBadgeChecks <badge-rules.json> <badge-golden.json>");
        }
        String rulesJson = readUtf8(new File(args[0]));
        String goldenJson = readUtf8(new File(args[1]));

        MediaBadges jsonEngine = MediaBadges.fromJson(rulesJson);
        MediaBadges builtinEngine = MediaBadges.getDefault();

        JSONObject golden = new JSONObject(goldenJson);
        JSONArray cases = golden.getJSONArray("cases");
        int total = cases.length();
        if (total != 165) {
            throw new AssertionError("Expected 165 golden cases, found " + total);
        }

        List<String> failures = new ArrayList<String>();
        List<String> inputs = new ArrayList<String>(total);

        for (int i = 0; i < total; i++) {
            JSONObject c = cases.getJSONObject(i);
            String id = c.getString("id");
            String input = c.isNull("input") ? null : c.getString("input");
            inputs.add(input);
            JSONArray expectedArr = c.getJSONArray("expected");
            List<String> expected = new ArrayList<String>(expectedArr.length());
            for (int j = 0; j < expectedArr.length(); j++) {
                JSONObject e = expectedArr.getJSONObject(j);
                expected.add(e.getString("id") + ":" + e.getString("label"));
            }

            List<String> actualJson = formatMediaBadges(jsonEngine.extract(input));
            if (!expected.equals(actualJson)) {
                failures.add(
                        "MediaBadges(JSON) "
                                + id
                                + " expected="
                                + expected
                                + " actual="
                                + actualJson);
            }

            List<String> actualBuiltin = formatMediaBadges(builtinEngine.extract(input));
            if (!expected.equals(actualBuiltin)) {
                failures.add(
                        "MediaBadges(builtin) "
                                + id
                                + " expected="
                                + expected
                                + " actual="
                                + actualBuiltin);
            }

            List<String> actualLite = formatLiteBadges(LiteBadges.extract(input));
            if (!expected.equals(actualLite)) {
                failures.add(
                        "LiteBadges " + id + " expected=" + expected + " actual=" + actualLite);
            }
        }

        if (!failures.isEmpty()) {
            StringBuilder sb = new StringBuilder();
            sb.append("Golden mismatches (").append(failures.size()).append("):\n");
            for (int i = 0; i < Math.min(20, failures.size()); i++) {
                sb.append("  ").append(failures.get(i)).append('\n');
            }
            throw new AssertionError(sb.toString());
        }

        // Verify 256-entry LRU cache bound
        jsonEngine.clearCache();
        for (int i = 0; i < 320; i++) {
            jsonEngine.extract("Synthetic.Sample." + i + ".2160p.HDR10+.DD+.5.1.mkv");
        }
        int cacheSize = jsonEngine.cacheSize();
        if (cacheSize != MediaBadges.LRU_CACHE_CAPACITY) {
            throw new AssertionError(
                    "Expected LRU cache size "
                            + MediaBadges.LRU_CACHE_CAPACITY
                            + ", got "
                            + cacheSize);
        }

        // Verify pure-data fusion API (live track overrides wrong filename resolution, combines DV
        // + Atmos)
        MediaBadges.TrackSpec track =
                new MediaBadges.TrackSpec(1920, 1080, "hev1.2.4.L120", null, "ec-3", 6, null, true);
        List<MediaBadges.Badge> fused =
                jsonEngine.fuse(new String[] {"Example.Movie.4K.DV.REMUX.NF.mkv"}, track);
        List<String> fusedLabels = new ArrayList<String>();
        for (MediaBadges.Badge b : fused) {
            fusedLabels.add(b.label);
        }
        List<String> expectedFused = new ArrayList<String>();
        expectedFused.add("1080p");
        expectedFused.add("DV · ATMOS");
        expectedFused.add("REMUX");
        expectedFused.add("DD+");
        expectedFused.add("5.1");
        expectedFused.add("HEVC");
        expectedFused.add("NF");
        if (!expectedFused.equals(fusedLabels)) {
            throw new AssertionError(
                    "Fusion mismatch: expected=" + expectedFused + " actual=" + fusedLabels);
        }

        // Fusion contradiction tests: video_codec, audio_codec, dynamic_range
        assertLabels(
                jsonEngine.fuse(
                        new String[] {"Example.H264.mkv"},
                        new MediaBadges.TrackSpec(
                                0, 0, "hev1.1.6.L120", null, null, 0, null, false)),
                new String[] {"HEVC"},
                "fuse video_codec override");
        assertLabels(
                jsonEngine.fuse(
                        new String[] {"Example.AC3.mkv"},
                        new MediaBadges.TrackSpec(0, 0, null, null, "ec-3", 0, null, false)),
                new String[] {"DD+"},
                "fuse audio_codec DD+ overrides DD");
        assertLabels(
                jsonEngine.fuse(
                        new String[] {"Example.DTS.mkv"},
                        new MediaBadges.TrackSpec(0, 0, null, null, "DTS-HD MA", 0, null, false)),
                new String[] {"DTS-HD MA"},
                "fuse audio_codec DTS-HD MA overrides DTS");
        assertLabels(
                jsonEngine.fuse(
                        new String[] {"Example.DDP.Atmos.5.1.mkv"},
                        new MediaBadges.TrackSpec(0, 0, null, null, "mp4a.40.2", 2, null, false)),
                new String[] {"AAC", "2.0"},
                "fuse audio_codec stereo AAC evicts DDP+Atmos+5.1");
        assertLabels(
                jsonEngine.fuse(
                        new String[] {"Example.4K.HDR.mkv"},
                        new MediaBadges.TrackSpec(0, 0, null, "SMPTE2084", null, 0, null, false)),
                new String[] {"4K", "HDR10"},
                "fuse dynamic_range HDR10 overrides HDR");
        assertLabels(
                jsonEngine.fuse(
                        new String[] {"Example.4K.DV.HDR.mkv"},
                        new MediaBadges.TrackSpec(0, 0, null, "HDR10+", null, 0, null, false)),
                new String[] {"4K", "DV", "HDR10+"},
                "fuse dynamic_range HDR10+ overrides HDR while preserving DV");

        // Verify '+' preservation in raw URLs (TvV17DetailScreen bypasses URLDecoder)
        List<MediaBadges.Badge> plusBadges =
                jsonEngine.extract("https://cdn.example.test/Sample.2160p.HDR10%2B.DD+.mkv");
        List<String> plusLabels = new ArrayList<String>();
        for (MediaBadges.Badge b : plusBadges) plusLabels.add(b.label);
        if (!plusLabels.contains("HDR10+") || !plusLabels.contains("DD+")) {
            throw new AssertionError("Expected HDR10+ and DD+ preserved, got " + plusLabels);
        }

        // Verify Lite dot-joined plain text formatting
        String liteJoined =
                LiteBadges.formatFromSources(4, "极速线路", "Sample.2160p.HDR10.DD+ 5.1.mkv");
        if (!"4K · HDR10 · DD+ · 5.1".equals(liteJoined)) {
            throw new AssertionError("Unexpected Lite dot-joined output: " + liteJoined);
        }

        // Benchmark uncached average match latency across all 165 golden inputs (5 warmup + 10
        // timed passes)
        for (int w = 0; w < 5; w++) {
            jsonEngine.clearCache();
            for (String s : inputs) {
                jsonEngine.extract(s);
            }
        }
        int passes = 10;
        long totalNs = 0;
        for (int p = 0; p < passes; p++) {
            jsonEngine.clearCache();
            long t0 = System.nanoTime();
            for (String s : inputs) {
                jsonEngine.extract(s);
            }
            totalNs += (System.nanoTime() - t0);
        }
        double avgMs = (totalNs / 1_000_000.0) / (passes * total);
        if (avgMs >= 0.2) {
            throw new AssertionError(
                    String.format(
                            "Uncached avg match latency %.4f ms exceeds 0.2ms budget", avgMs));
        }

        System.out.printf(
                "PASS MediaBadgeChecks: golden=%d/%d (MediaBadges JSON + builtin + LiteBadges 0 diff), "
                        + "lru=%d, fusion=OK, plusPreserve=OK, uncachedAvg=%.4fms (<0.2ms)%n",
                total, total, cacheSize, avgMs);
    }

    private static void assertLabels(
            List<MediaBadges.Badge> actual, String[] expected, String label) {
        List<String> actualLabels = new ArrayList<String>(actual.size());
        for (MediaBadges.Badge b : actual) actualLabels.add(b.label);
        List<String> expectedList = new ArrayList<String>(expected.length);
        for (String e : expected) expectedList.add(e);
        if (!expectedList.equals(actualLabels)) {
            throw new AssertionError(
                    label + " mismatch: expected=" + expectedList + " actual=" + actualLabels);
        }
    }

    private static List<String> formatMediaBadges(List<MediaBadges.Badge> badges) {
        List<String> out = new ArrayList<String>(badges.size());
        for (MediaBadges.Badge b : badges) {
            out.add(b.id + ":" + b.label);
        }
        return out;
    }

    private static List<String> formatLiteBadges(List<LiteBadges.Badge> badges) {
        List<String> out = new ArrayList<String>(badges.size());
        for (LiteBadges.Badge b : badges) {
            out.add(b.id + ":" + b.label);
        }
        return out;
    }

    private static String readUtf8(File file) throws Exception {
        FileInputStream in = new FileInputStream(file);
        try {
            byte[] data = new byte[(int) file.length()];
            int off = 0;
            while (off < data.length) {
                int n = in.read(data, off, data.length - off);
                if (n < 0) break;
                off += n;
            }
            return new String(data, 0, off, UTF8);
        } finally {
            in.close();
        }
    }
}
