package com.pilipala.marcomovie;

import org.json.*;
import java.net.URL;
import java.util.*;

/** Normalizes playback metadata returned by a source, without persisting signed URLs. */
final class MediaOptions {
    static Cms.Episode episode(Cms.Site site, Cms.Episode original, JSONObject result)
            throws Exception {
        Cms.Episode out = new Cms.Episode();
        out.name = original.name;
        out.media = new JSONObject(result.toString());
        if (original.name != null && !original.name.isEmpty()) {
            out.media.put("_episodeName", original.name);
        }
        if (original.media != null && original.media.has("_lineHopCount")) {
            out.media.put("_lineHopCount", original.media.optInt("_lineHopCount", 0));
        }
        JSONArray qualities = new JSONArray();
        out.url = extractPlayUrl(result.opt("url"), qualities);
        if (out.url.isEmpty()
                && !result.optString("playUrl").isEmpty()
                && Cms.isMedia(result.optString("playUrl"))) {
            out.url = ProxyAddress.rewrite(result.optString("playUrl").trim());
        }
        if (qualities.length() > 0) {
            for (int i = 0; i < qualities.length(); i++) {
                JSONObject q = qualities.optJSONObject(i);
                if (q == null) continue;
                Map<String, String> inlineHeaders = new LinkedHashMap<>();
                String cleanUrl = stripInlineHeaders(q.optString("url", ""), inlineHeaders);
                if (!cleanUrl.isEmpty()) {
                    q.put("url", cleanUrl);
                }
                if (!inlineHeaders.isEmpty()) {
                    JSONObject qHeaders = q.optJSONObject("headers");
                    if (qHeaders == null) qHeaders = new JSONObject();
                    for (Map.Entry<String, String> entry : inlineHeaders.entrySet()) {
                        qHeaders.put(entry.getKey(), entry.getValue());
                    }
                    q.put("headers", qHeaders);
                }
            }
            out.media.put("qualities", qualities);
        }
        out.headers.putAll(Cms.inheritedHeaders(site.api, out.url, site.headers));
        Cms.mergeHeaders(
                out.headers, Cms.inheritedHeaders(original.url, out.url, original.headers));
        Object value = result.opt("header");
        if (value instanceof String)
            try {
                value = new JSONObject((String) value);
            } catch (JSONException ignored) {
            }
        if (value instanceof JSONObject) headers(out.headers, (JSONObject) value);
        for (String key : new String[] {"User-Agent", "UA", "ua"})
            if (!result.optString(key).isEmpty())
                put(out.headers, "User-Agent", result.optString(key));
        for (String key : new String[] {"Referer", "referer"})
            if (!result.optString(key).isEmpty())
                put(out.headers, "Referer", result.optString(key));
        Object subtitles = result.opt("subtitles");
        if (subtitles == null) subtitles = result.opt("subs");
        if (subtitles == null) subtitles = result.opt("subt");
        if (subtitles == null) subtitles = result.opt("sub");
        if (subtitles instanceof String) {
            String text = ((String) subtitles).trim();
            try {
                subtitles =
                        text.startsWith("[")
                                ? new JSONArray(text)
                                : text.startsWith("{") ? new JSONObject(text) : text;
            } catch (JSONException ignored) {
            }
        }
        JSONArray normalized = new JSONArray();
        if (subtitles instanceof JSONArray) {
            JSONArray items = (JSONArray) subtitles;
            for (int i = 0; i < items.length(); i++) subtitle(normalized, items.opt(i), out.url);
        } else if (subtitles != null) subtitle(normalized, subtitles, out.url);
        out.media.put("subtitles", normalized);
        List<String> danmakuUrls = extractDanmakuUrls(result);
        if (!danmakuUrls.isEmpty()) {
            out.media.put("danmaku", danmakuUrls.get(0));
            JSONArray dmArr = new JSONArray();
            for (String u : danmakuUrls) dmArr.put(u);
            out.media.put("danmakuList", dmArr);
        } else {
            out.media.remove("danmaku");
            out.media.remove("danmakuList");
        }
        out.url = stripInlineHeaders(out.url, out.headers);
        return out;
    }

    static String extractDanmakuUrl(JSONObject result) {
        List<String> urls = extractDanmakuUrls(result);
        return urls.isEmpty() ? "" : urls.get(0);
    }

    static List<String> extractDanmakuUrls(JSONObject result) {
        if (result == null) return Collections.emptyList();
        LinkedHashSet<String> urls = new LinkedHashSet<>();
        for (String key : new String[] {"danmaku", "dm", "danmu", "danmuku", "barrage"}) {
            if (result.has(key) && result.opt(key) != null && result.opt(key) != JSONObject.NULL) {
                collectDanmakuCandidates(result.opt(key), urls);
            }
        }
        JSONObject extra = result.optJSONObject("extra");
        if (extra != null) {
            for (String key : new String[] {"danmaku", "dm", "danmu", "danmuku", "barrage"}) {
                if (extra.has(key) && extra.opt(key) != null && extra.opt(key) != JSONObject.NULL) {
                    collectDanmakuCandidates(extra.opt(key), urls);
                }
            }
        }
        return new ArrayList<>(urls);
    }

    private static void collectDanmakuCandidates(Object raw, Set<String> out) {
        if (raw == null || raw == JSONObject.NULL) return;
        if (raw instanceof String) {
            String s = ((String) raw).trim();
            if (s.isEmpty()) return;
            if (s.startsWith("[")) {
                try {
                    collectDanmakuCandidates(new JSONArray(s), out);
                    return;
                } catch (JSONException ignored) {
                }
            } else if (s.startsWith("{")) {
                try {
                    collectDanmakuCandidates(new JSONObject(s), out);
                    return;
                } catch (JSONException ignored) {
                }
            }
            if (s.contains("$$$")) {
                for (String part : s.split("\\$\\$\\$")) {
                    collectDanmakuCandidates(part, out);
                }
                return;
            }
            if (s.contains("$http://") || s.contains("$https://") || s.contains("$proxy://")) {
                for (String entry : s.split("#")) {
                    int dollar = entry.indexOf('$');
                    String cand = dollar >= 0 ? entry.substring(dollar + 1).trim() : entry.trim();
                    if (!cand.isEmpty()) {
                        String rewritten = ProxyAddress.rewrite(cand);
                        if (rewritten != null && !rewritten.isEmpty()) out.add(rewritten);
                    }
                }
                return;
            }
            String rewritten = ProxyAddress.rewrite(s);
            if (rewritten != null && !rewritten.isEmpty()) out.add(rewritten);
            return;
        }
        if (raw instanceof JSONObject) {
            JSONObject obj = (JSONObject) raw;
            String u =
                    obj.optString(
                                    "url",
                                    obj.optString(
                                            "uri", obj.optString("src", obj.optString("path", ""))))
                            .trim();
            if (!u.isEmpty()) {
                collectDanmakuCandidates(u, out);
            }
            return;
        }
        if (raw instanceof JSONArray) {
            JSONArray arr = (JSONArray) raw;
            for (int i = 0; i < arr.length(); i++) {
                collectDanmakuCandidates(arr.opt(i), out);
            }
        }
    }

    static boolean looksLikePlayableUrl(String s) {
        if (s == null) return false;
        String t = s.trim();
        if (t.isEmpty()) return false;
        return Cms.isMedia(t)
                || t.startsWith("magnet:?")
                || t.regionMatches(true, 0, "proxy://", 0, 8)
                || t.regionMatches(true, 0, "push://", 0, 7)
                || t.startsWith("http://")
                || t.startsWith("https://");
    }

    static String normalizeCandidateUrl(String raw) {
        if (raw == null) return "";
        String t = raw.trim();
        if (t.isEmpty()) return "";
        return ProxyAddress.rewrite(t);
    }

    static String extractPlayUrl(Object rawUrl, JSONArray qualities) {
        if (rawUrl == null || rawUrl == JSONObject.NULL) return "";
        if (rawUrl instanceof String) {
            String s = ((String) rawUrl).trim();
            if (s.startsWith("[")) {
                try {
                    return extractPlayUrl(new JSONArray(s), qualities);
                } catch (JSONException ignored) {
                }
            } else if (s.startsWith("{")) {
                try {
                    return extractPlayUrl(new JSONObject(s), qualities);
                } catch (JSONException ignored) {
                }
            }
            return normalizeCandidateUrl(s);
        }
        if (rawUrl instanceof JSONObject) {
            JSONObject obj = (JSONObject) rawUrl;
            if (obj.has("urls")) {
                return extractPlayUrl(obj.opt("urls"), qualities);
            }
            if (obj.has("values")) {
                return extractPlayUrl(obj.opt("values"), qualities);
            }
            String u = obj.optString("url", obj.optString("playUrl", "")).trim();
            return normalizeCandidateUrl(u);
        }
        if (rawUrl instanceof JSONArray) {
            JSONArray arr = (JSONArray) rawUrl;
            if (arr.length() == 0) return "";
            // Case 1: Array of JSONObjects [{"name":"...", "url":"..."}, ...]
            if (arr.opt(0) instanceof JSONObject) {
                String firstUrl = "";
                for (int i = 0; i < arr.length(); i++) {
                    JSONObject item = arr.optJSONObject(i);
                    if (item == null) continue;
                    String name = item.optString("name", item.optString("label", "线路 " + (i + 1)));
                    String u = normalizeCandidateUrl(item.optString("url", ""));
                    if (!u.isEmpty()) {
                        if (firstUrl.isEmpty()) firstUrl = u;
                        try {
                            qualities.put(new JSONObject().put("name", name).put("url", u));
                        } catch (JSONException ignored) {
                        }
                    }
                }
                return firstUrl;
            }
            // Case 2: CatVod alternating ["代理原画", "https://media.example/1.mkv", "直连原画",
            // "https://media.example/2.mkv"]
            if (arr.length() >= 2
                    && !looksLikePlayableUrl(arr.optString(0, ""))
                    && looksLikePlayableUrl(arr.optString(1, ""))) {
                String firstUrl = "";
                for (int i = 0; i + 1 < arr.length(); i += 2) {
                    String label = arr.optString(i, "画质 " + (i / 2 + 1)).trim();
                    String u = normalizeCandidateUrl(arr.optString(i + 1, ""));
                    if (!u.isEmpty()) {
                        if (firstUrl.isEmpty()) firstUrl = u;
                        try {
                            qualities.put(
                                    new JSONObject()
                                            .put(
                                                    "name",
                                                    label.isEmpty() ? "画质 " + (i / 2 + 1) : label)
                                            .put("url", u));
                        } catch (JSONException ignored) {
                        }
                    }
                }
                if (!firstUrl.isEmpty()) return firstUrl;
            }
            // Case 3: Plain array of URLs ["https://media.example/1.m3u8"]
            String firstUrl = "";
            for (int i = 0; i < arr.length(); i++) {
                String cand = normalizeCandidateUrl(arr.optString(i, ""));
                if (looksLikePlayableUrl(cand)) {
                    if (firstUrl.isEmpty()) firstUrl = cand;
                    try {
                        qualities.put(
                                new JSONObject()
                                        .put("name", "画质 " + (qualities.length() + 1))
                                        .put("url", cand));
                    } catch (JSONException ignored) {
                    }
                }
            }
            return firstUrl;
        }
        return "";
    }

    static String stripInlineHeaders(String rawUrl, Map<String, String> headers) {
        if (rawUrl == null || rawUrl.isEmpty()) return "";
        String url = rawUrl.trim();
        int pipe = url.indexOf('|');
        if (pipe > 0) {
            String tail = url.substring(pipe + 1);
            url = url.substring(0, pipe).trim();
            for (String pair : tail.split("&")) {
                int eq = pair.indexOf('=');
                if (eq > 0) {
                    String k = pair.substring(0, eq).trim();
                    String v = pair.substring(eq + 1).trim();
                    put(headers, k, v);
                }
            }
        }
        java.util.regex.Matcher m =
                java.util.regex.Pattern.compile(
                                "@(?i:Referer|User-Agent|Cookie|Origin|Authorization)=")
                        .matcher(url);
        int first = -1, start = 0;
        String key = null;
        while (m.find()) {
            if (first < 0) first = m.start();
            if (key != null) put(headers, key, url.substring(start, m.start()));
            key = url.substring(m.start() + 1, m.end() - 1);
            start = m.end();
        }
        if (key != null) {
            put(headers, key, url.substring(start));
            url = url.substring(0, first).trim();
        }
        return ProxyAddress.rewrite(url);
    }

    static void put(Map<String, String> target, String key, String value) {
        if (!key.matches("[A-Za-z0-9-]+") || value.contains("\r") || value.contains("\n")) return;
        for (Iterator<String> it = target.keySet().iterator(); it.hasNext(); ) {
            if (it.next().equalsIgnoreCase(key)) it.remove();
        }
        target.put(key, value);
    }

    static void headers(Map<String, String> target, JSONObject object) {
        Iterator<String> keys = object.keys();
        while (keys.hasNext()) {
            String key = keys.next();
            put(target, key, object.optString(key));
        }
    }

    static void subtitle(JSONArray target, Object value, String origin) throws JSONException {
        JSONObject item;
        if (value instanceof JSONObject) item = new JSONObject(value.toString());
        else if (value instanceof String) item = new JSONObject().put("url", value);
        else return;
        String url = item.optString("url", item.optString("uri"));
        try {
            url = new URL(new URL(origin), url).toString();
        } catch (Exception ignored) {
        }
        if (!Cms.isHttp(url) && !url.startsWith("content://") && !url.startsWith("file://")) return;
        item.put("url", url);
        if (!item.has("name")) item.put("name", item.optString("label", "外挂字幕"));
        target.put(item);
    }

    static String subtitleMime(String uri, String declared) {
        if (declared != null && !declared.isEmpty()) return declared;
        String path = uri.split("[?#]", 2)[0].toLowerCase(Locale.ROOT);
        if (path.endsWith(".vtt")) return "text/vtt";
        if (path.endsWith(".ass") || path.endsWith(".ssa")) return "text/x-ssa";
        if (path.endsWith(".ttml") || path.endsWith(".xml")) return "application/ttml+xml";
        return "application/x-subrip";
    }

    static String mime(JSONObject options) {
        for (String key : new String[] {"mimeType", "type", "format"}) {
            String type =
                    options.optString(key, "").split(";", 2)[0].trim().toLowerCase(Locale.ROOT);
            if (type.equals("hls")
                    || type.equals("m3u8")
                    || type.equals("application/x-mpegurl")
                    || type.equals("application/vnd.apple.mpegurl")
                    || type.equals("audio/mpegurl")
                    || type.equals("audio/x-mpegurl")) return "application/x-mpegURL";
            if (type.equals("dash") || type.equals("mpd")) return "application/dash+xml";
            if (type.contains("/") && !type.equals("application/octet-stream")) return type;
        }
        return null;
    }
}
