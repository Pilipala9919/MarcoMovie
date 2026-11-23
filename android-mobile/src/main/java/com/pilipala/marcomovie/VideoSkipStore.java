package com.pilipala.marcomovie;

import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Per-video intro/outro skip records keyed by {@code (siteKey, videoId)}.
 *
 * <p>Stored strictly on the local device (never exported to global settings or cloud sync); in
 * private space, records live only in memory for the current session and are cleared on exit.
 */
final class VideoSkipStore {
    static final int MAX_ENTRIES = 500;
    static final int MAX_SKIP_SECONDS = 1200;

    private static final Map<String, int[]> PRIVATE_RECORDS = new LinkedHashMap<>();

    private VideoSkipStore() {}

    static int clampSkipSeconds(int seconds) {
        return Math.max(0, Math.min(MAX_SKIP_SECONDS, seconds));
    }

    static String recordKey(String siteKey, String videoId) {
        String s = siteKey == null ? "" : siteKey.trim();
        String v = videoId == null ? "" : videoId.trim();
        if (s.isEmpty() || v.isEmpty() || "live".equals(s)) return "";
        return s + "\n" + v;
    }

    static String videoKeyFrom(Cms.Video video, Cms.Episode episode) {
        if (video != null && video.id != null && !video.id.trim().isEmpty()) {
            return video.id.trim();
        }
        if (video != null && video.title != null && !video.title.trim().isEmpty()) {
            return video.title.trim();
        }
        if (episode != null && episode.name != null && !episode.name.trim().isEmpty()) {
            return episode.name.trim();
        }
        return "";
    }

    static int defaultSecondsFromPlayback(
            boolean intro, int savedSec, int currentPlayerPosMs, int currentPlayerDurMs) {
        if (currentPlayerPosMs <= 0) {
            return clampSkipSeconds(savedSec);
        }
        if (intro) {
            int raw = currentPlayerPosMs / 1000;
            return clampSkipSeconds(Math.max(1, raw));
        }
        if (currentPlayerDurMs > currentPlayerPosMs) {
            int remain = (currentPlayerDurMs - currentPlayerPosMs) / 1000;
            if (remain <= MAX_SKIP_SECONDS) {
                return clampSkipSeconds(Math.max(1, remain));
            }
            int elapsed = currentPlayerPosMs / 1000;
            if (elapsed <= MAX_SKIP_SECONDS) {
                return clampSkipSeconds(Math.max(1, elapsed));
            }
            return clampSkipSeconds(savedSec > 0 ? savedSec : 90);
        }
        return clampSkipSeconds(Math.max(1, currentPlayerPosMs / 1000));
    }

    static synchronized void clearPrivateRecords() {
        PRIVATE_RECORDS.clear();
    }

    static synchronized int countPrivateRecords() {
        return PRIVATE_RECORDS.size();
    }

    static synchronized int getPrivateSkip(String siteKey, String videoId, boolean intro) {
        String key = recordKey(siteKey, videoId);
        if (key.isEmpty()) return 0;
        int[] pair = PRIVATE_RECORDS.get(key);
        if (pair == null) return 0;
        return clampSkipSeconds(pair[intro ? 0 : 1]);
    }

    static synchronized void setPrivateSkip(
            String siteKey, String videoId, boolean intro, int seconds) {
        String key = recordKey(siteKey, videoId);
        if (key.isEmpty()) return;
        int clamped = clampSkipSeconds(seconds);
        int[] pair = PRIVATE_RECORDS.get(key);
        if (pair == null) pair = new int[] {0, 0};
        pair[intro ? 0 : 1] = clamped;
        PRIVATE_RECORDS.remove(key);
        if (pair[0] > 0 || pair[1] > 0) {
            PRIVATE_RECORDS.put(key, pair);
            while (PRIVATE_RECORDS.size() > MAX_ENTRIES) {
                Iterator<String> it = PRIVATE_RECORDS.keySet().iterator();
                if (!it.hasNext()) break;
                it.next();
                it.remove();
            }
        }
    }

    static int readIntro(String rawJson, String siteKey, String videoId) {
        return readField(rawJson, siteKey, videoId, "intro");
    }

    static int readOutro(String rawJson, String siteKey, String videoId) {
        return readField(rawJson, siteKey, videoId, "outro");
    }

    private static int readField(String rawJson, String siteKey, String videoId, String field) {
        String target = recordKey(siteKey, videoId);
        if (target.isEmpty() || rawJson == null || rawJson.trim().isEmpty()) return 0;
        try {
            JSONArray arr = new JSONArray(rawJson);
            for (int i = 0; i < arr.length(); i++) {
                JSONObject o = arr.optJSONObject(i);
                if (o == null) continue;
                if (target.equals(recordKey(o.optString("site"), o.optString("id")))) {
                    return clampSkipSeconds(o.optInt(field, 0));
                }
            }
        } catch (Exception ignored) {
        }
        return 0;
    }

    static int countRecords(String rawJson) {
        if (rawJson == null || rawJson.trim().isEmpty()) return 0;
        int count = 0;
        try {
            JSONArray arr = new JSONArray(rawJson);
            for (int i = 0; i < arr.length(); i++) {
                JSONObject o = arr.optJSONObject(i);
                if (o == null) continue;
                int intro = clampSkipSeconds(o.optInt("intro", 0));
                int outro = clampSkipSeconds(o.optInt("outro", 0));
                if (!recordKey(o.optString("site"), o.optString("id")).isEmpty()
                        && (intro > 0 || outro > 0)) {
                    count++;
                }
            }
        } catch (Exception ignored) {
        }
        return count;
    }

    static String writeSkip(
            String rawJson,
            String siteKey,
            String videoId,
            boolean intro,
            int seconds,
            long updatedMs) {
        String target = recordKey(siteKey, videoId);
        if (target.isEmpty()) return rawJson == null ? "[]" : rawJson;
        int clamped = clampSkipSeconds(seconds);
        int existingIntro = 0;
        int existingOutro = 0;
        JSONArray kept = new JSONArray();
        try {
            if (rawJson != null && !rawJson.trim().isEmpty()) {
                JSONArray old = new JSONArray(rawJson);
                for (int i = 0; i < old.length(); i++) {
                    JSONObject o = old.optJSONObject(i);
                    if (o == null) continue;
                    String k = recordKey(o.optString("site"), o.optString("id"));
                    if (k.isEmpty()) continue;
                    if (target.equals(k)) {
                        existingIntro = clampSkipSeconds(o.optInt("intro", 0));
                        existingOutro = clampSkipSeconds(o.optInt("outro", 0));
                    } else {
                        int oi = clampSkipSeconds(o.optInt("intro", 0));
                        int oo = clampSkipSeconds(o.optInt("outro", 0));
                        if (oi > 0 || oo > 0) kept.put(o);
                    }
                }
            }
        } catch (Exception ignored) {
        }
        int nextIntro = intro ? clamped : existingIntro;
        int nextOutro = intro ? existingOutro : clamped;
        JSONArray out = new JSONArray();
        if (nextIntro > 0 || nextOutro > 0) {
            try {
                JSONObject head =
                        new JSONObject()
                                .put("site", siteKey.trim())
                                .put("id", videoId.trim())
                                .put("intro", nextIntro)
                                .put("outro", nextOutro)
                                .put("updated", updatedMs);
                out.put(head);
            } catch (Exception ignored) {
            }
        }
        for (int i = 0; i < kept.length() && out.length() < MAX_ENTRIES; i++) {
            out.put(kept.optJSONObject(i));
        }
        return out.toString();
    }
}
