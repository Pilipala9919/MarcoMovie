package com.pilipala.marcomovie;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import org.json.JSONArray;

/**
 * Pure-Java user preferences for Live TV (favorite channels, hidden/blocked groups, channel
 * filtering, and virtual group synthesis). Shared across Android TV and Android Mobile.
 */
final class LivePreferences {
    static final String FAVORITES_GROUP_NAME = "★ 收藏频道";
    static final String SEARCH_GROUP_NAME = "搜索结果";

    private LivePreferences() {}

    static String channelFavoriteKey(LiveCatalog.Channel channel) {
        if (channel == null) return "";
        return channelFavoriteKey(channel.name);
    }

    static String channelFavoriteKey(String channelName) {
        if (channelName == null) return "";
        String canon = LiveQualityPolicy.canonicalChannelName(channelName);
        String clean = canon == null || canon.trim().isEmpty() ? channelName.trim() : canon.trim();
        return clean.toLowerCase(Locale.ROOT);
    }

    static Set<String> readStringSet(String rawJson) {
        Set<String> out = new LinkedHashSet<String>();
        if (rawJson == null || rawJson.trim().isEmpty()) return out;
        try {
            JSONArray arr = new JSONArray(rawJson);
            for (int i = 0; i < arr.length(); i++) {
                String v = arr.optString(i, "").trim();
                if (!v.isEmpty()) out.add(v);
            }
        } catch (Exception ignored) {
        }
        return out;
    }

    static String serializeStringSet(Set<String> items) {
        JSONArray arr = new JSONArray();
        if (items != null) {
            for (String item : items) {
                if (item != null && !item.trim().isEmpty()) arr.put(item.trim());
            }
        }
        return arr.toString();
    }

    static boolean isFavorite(Set<String> favorites, LiveCatalog.Channel channel) {
        if (favorites == null || favorites.isEmpty() || channel == null) return false;
        String key = channelFavoriteKey(channel);
        return !key.isEmpty() && favorites.contains(key);
    }

    static Set<String> toggleFavorite(Set<String> current, String channelName) {
        Set<String> next = new LinkedHashSet<String>();
        if (current != null) next.addAll(current);
        String key = channelFavoriteKey(channelName);
        if (!key.isEmpty()) {
            if (!next.remove(key)) next.add(key);
        }
        return next;
    }

    static Set<String> toggleBlockedGroup(Set<String> current, String groupName) {
        Set<String> next = new LinkedHashSet<String>();
        if (current != null) next.addAll(current);
        String key = groupName == null ? "" : groupName.trim();
        if (!key.isEmpty() && !FAVORITES_GROUP_NAME.equals(key) && !SEARCH_GROUP_NAME.equals(key)) {
            if (!next.remove(key)) next.add(key);
        }
        return next;
    }

    static Set<String> loadFavorites(MainActivity a) {
        if (a == null || a.prefs == null) return Collections.emptySet();
        return readStringSet(a.prefs.getString(Prefs.LIVE_FAVORITE_CHANNELS, "[]"));
    }

    static boolean toggleFavorite(MainActivity a, LiveCatalog.Channel channel) {
        if (a == null || a.prefs == null || channel == null) return false;
        Set<String> cur = loadFavorites(a);
        Set<String> next = toggleFavorite(cur, channel.name);
        a.prefs.edit().putString(Prefs.LIVE_FAVORITE_CHANNELS, serializeStringSet(next)).apply();
        return isFavorite(next, channel);
    }

    static Set<String> loadBlockedGroups(MainActivity a) {
        if (a == null || a.prefs == null) return Collections.emptySet();
        return readStringSet(a.prefs.getString(Prefs.LIVE_BLOCKED_GROUPS, "[]"));
    }

    static boolean toggleBlockedGroup(MainActivity a, String groupName) {
        if (a == null || a.prefs == null || groupName == null) return false;
        Set<String> cur = loadBlockedGroups(a);
        Set<String> next = toggleBlockedGroup(cur, groupName);
        a.prefs.edit().putString(Prefs.LIVE_BLOCKED_GROUPS, serializeStringSet(next)).apply();
        return next.contains(groupName.trim());
    }

    static void clearBlockedGroups(MainActivity a) {
        if (a == null || a.prefs == null) return;
        a.prefs.edit().putString(Prefs.LIVE_BLOCKED_GROUPS, "[]").apply();
    }

    /**
     * Applies blocked-group filtering, search filtering, and favorite-group synthesis without
     * mutating the original cached {@link LiveCatalog.Catalog}.
     */
    static List<LiveCatalog.Group> buildDisplayGroups(
            LiveCatalog.Catalog raw,
            Set<String> favorites,
            Set<String> blockedGroups,
            String searchQuery) {
        List<LiveCatalog.Group> out = new ArrayList<LiveCatalog.Group>();
        if (raw == null || raw.groups == null || raw.groups.isEmpty()) return out;
        String q = searchQuery == null ? "" : searchQuery.trim().toLowerCase(Locale.ROOT);
        Set<String> favSet = favorites == null ? Collections.<String>emptySet() : favorites;
        Set<String> blockedSet =
                blockedGroups == null ? Collections.<String>emptySet() : blockedGroups;

        if (!q.isEmpty()) {
            LiveCatalog.Group searchGroup = new LiveCatalog.Group();
            searchGroup.name = SEARCH_GROUP_NAME;
            Set<String> seen = new LinkedHashSet<String>();
            for (LiveCatalog.Group g : raw.groups) {
                if (g == null || g.channels == null) continue;
                String gName = g.name == null ? "" : g.name.trim();
                if (!gName.isEmpty() && blockedSet.contains(gName)) continue;
                for (LiveCatalog.Channel ch : g.channels) {
                    if (ch == null || ch.name == null) continue;
                    String epg = ch.options.get("epg");
                    boolean matchName = ch.name.toLowerCase(Locale.ROOT).contains(q);
                    boolean matchEpg = epg != null && epg.toLowerCase(Locale.ROOT).contains(q);
                    if (matchName || matchEpg) {
                        String key = channelFavoriteKey(ch) + "|" + ch.name;
                        if (seen.add(key)) {
                            searchGroup.channels.add(ch);
                        }
                    }
                }
            }
            out.add(searchGroup);
            return out;
        }

        LiveCatalog.Group favGroup = new LiveCatalog.Group();
        favGroup.name = FAVORITES_GROUP_NAME;
        Set<String> seenFavs = new LinkedHashSet<String>();
        List<LiveCatalog.Group> visible = new ArrayList<LiveCatalog.Group>(raw.groups.size());

        for (LiveCatalog.Group g : raw.groups) {
            if (g == null || g.channels == null || g.channels.isEmpty()) continue;
            String gName = g.name == null ? "" : g.name.trim();
            if (!gName.isEmpty() && blockedSet.contains(gName)) continue;
            visible.add(g);
            if (!favSet.isEmpty()) {
                for (LiveCatalog.Channel ch : g.channels) {
                    if (isFavorite(favSet, ch)) {
                        String key = channelFavoriteKey(ch);
                        if (seenFavs.add(key)) {
                            favGroup.channels.add(ch);
                        }
                    }
                }
            }
        }
        if (!favGroup.channels.isEmpty()) {
            out.add(favGroup);
        }
        out.addAll(visible);
        return out;
    }

    /** Resolves preferred initial live source index honoring the user's last selected source. */
    static int resolveInitialSourceIndex(List<LiveCatalog.Source> sources, String lastSourceUrl) {
        if (sources == null || sources.isEmpty()) return 0;
        if (lastSourceUrl != null && !lastSourceUrl.trim().isEmpty()) {
            String wanted = lastSourceUrl.trim();
            for (int i = 0; i < sources.size(); i++) {
                LiveCatalog.Source s = sources.get(i);
                if (s != null && wanted.equals(s.url)) return i;
            }
        }
        return 0;
    }

    /** Computes EPG current programme progress in [0f, 1f], or -1f when unavailable. */
    static float computeEpgProgress(long startMs, long stopMs, long nowMs) {
        if (startMs <= 0L || stopMs <= startMs || nowMs < startMs) return -1f;
        float ratio = (float) (nowMs - startMs) / (float) (stopMs - startMs);
        return Math.max(0f, Math.min(1f, ratio));
    }

    /** Extracts crisp 2–4 char channel badge monogram when a channel has no tvg-logo. */
    static String channelMonogram(String channelName) {
        if (channelName == null) return "TV";
        String clean = channelName.trim();
        if (clean.isEmpty()) return "TV";
        String upper = clean.toUpperCase(Locale.ROOT);
        if (upper.startsWith("CCTV")) {
            StringBuilder digits = new StringBuilder();
            for (int i = 4; i < upper.length() && digits.length() < 2; i++) {
                char c = upper.charAt(i);
                if (c >= '0' && c <= '9') digits.append(c);
                else if (c == '+') {
                    digits.append('+');
                    break;
                } else if (digits.length() > 0) {
                    break;
                }
            }
            return digits.length() > 0 ? "C" + digits : "CCTV";
        }
        StringBuilder compact = new StringBuilder();
        for (int i = 0; i < clean.length() && compact.length() < 2; i++) {
            char c = clean.charAt(i);
            if (!Character.isWhitespace(c) && c != '-' && c != '_' && c != '[' && c != '【') {
                compact.append(c);
            }
        }
        return compact.length() > 0 ? compact.toString().toUpperCase(Locale.ROOT) : "TV";
    }
}
