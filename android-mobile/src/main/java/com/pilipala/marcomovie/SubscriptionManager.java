package com.pilipala.marcomovie;

import java.io.IOException;
import java.net.URL;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Pure-Java subscription auto-update scheduler and multi-source auto-grouping merger.
 *
 * <p>Handles: (1) parsing single or multi-line subscription imports (optional {@code 分组名,URL}
 * prefix), (2) merging multiple independent subscriptions into one grouped {@link Cms.Config} while
 * preserving each site's resolved {@code jar}/{@code api}/{@code ext} and disambiguating colliding
 * keys deterministically, and (3) daily (24h) automatic subscription refresh with atomic rollback
 * safety.
 */
final class SubscriptionManager {
    static final long AUTO_UPDATE_INTERVAL_MS = 24L * 60L * 60L * 1000L;
    static final String META_MULTI_SOURCES = "_marco_multi_sources";
    static final String MULTI_ORIGIN_PREFIX = "marco-multi://";
    static final int MAX_BATCH_SOURCES = 16;
    static final int MAX_MERGED_SITES = 500;
    static final int MAX_TRANSFER_LENGTH = 16384;

    private static final Set<String> GENERIC_HOSTS;

    static {
        Set<String> hosts = new HashSet<String>();
        hosts.add("raw.githubusercontent.com");
        hosts.add("github.com");
        hosts.add("gist.githubusercontent.com");
        hosts.add("cdn.jsdelivr.net");
        hosts.add("fastly.jsdelivr.net");
        hosts.add("ghproxy.com");
        hosts.add("mirror.ghproxy.com");
        hosts.add("gh-proxy.com");
        hosts.add("gitee.com");
        hosts.add("gitlab.com");
        hosts.add("pastebin.com");
        hosts.add("localhost");
        hosts.add("127.0.0.1");
        GENERIC_HOSTS = Collections.unmodifiableSet(hosts);
    }

    private SubscriptionManager() {}

    static final class ImportSpec {
        final String name;
        final String url;

        ImportSpec(String name, String url) {
            this.name = name == null ? "" : name.trim();
            this.url = url == null ? "" : url.trim();
        }
    }

    static final class SourceBundle {
        final String groupName;
        final String origin;
        final String raw;
        final long updated;

        SourceBundle(String groupName, String origin, String raw, long updated) {
            this.groupName = groupName == null ? "" : groupName.trim();
            this.origin = origin == null ? "" : origin.trim();
            this.raw = raw == null ? "" : raw;
            this.updated = Math.max(1L, updated);
        }
    }

    static final class MultiSourceMeta {
        final String name;
        final String url;
        final long updated;

        MultiSourceMeta(String name, String url, long updated) {
            this.name = name == null ? "" : name.trim();
            this.url = url == null ? "" : url.trim();
            this.updated = Math.max(1L, updated);
        }
    }

    static final class MergedResult {
        final Cms.Config config;
        final String rawJson;
        final String origin;
        final List<String> groupNames;
        final int sourceCount;

        MergedResult(
                Cms.Config config,
                String rawJson,
                String origin,
                List<String> groupNames,
                int sourceCount) {
            this.config = config;
            this.rawJson = rawJson;
            this.origin = origin;
            this.groupNames = Collections.unmodifiableList(new ArrayList<String>(groupNames));
            this.sourceCount = sourceCount;
        }
    }

    static final class RefreshSummary {
        final int checkedCount;
        final int updatedCount;
        final int failedCount;
        final boolean activeChanged;
        final String updatedActiveRaw;
        final String updatedActiveOrigin;
        final List<String> updatedNames;

        RefreshSummary(
                int checkedCount,
                int updatedCount,
                int failedCount,
                boolean activeChanged,
                String updatedActiveRaw,
                String updatedActiveOrigin,
                List<String> updatedNames) {
            this.checkedCount = checkedCount;
            this.updatedCount = updatedCount;
            this.failedCount = failedCount;
            this.activeChanged = activeChanged;
            this.updatedActiveRaw = updatedActiveRaw == null ? "" : updatedActiveRaw;
            this.updatedActiveOrigin = updatedActiveOrigin == null ? "" : updatedActiveOrigin;
            this.updatedNames = Collections.unmodifiableList(new ArrayList<String>(updatedNames));
        }
    }

    interface Fetcher {
        String fetch(String url) throws Exception;
    }

    static boolean isMergedOrigin(String origin) {
        return origin != null && origin.trim().startsWith(MULTI_ORIGIN_PREFIX);
    }

    static boolean isDueForDailyUpdate(long lastUpdatedMs, long nowMs) {
        if (lastUpdatedMs <= 0L) return true;
        if (nowMs < lastUpdatedMs) return false;
        return (nowMs - lastUpdatedMs) >= AUTO_UPDATE_INTERVAL_MS;
    }

    /**
     * Parses a single URL or multi-line batch of URLs (optionally prefixed with {@code 分组名,URL} /
     * {@code 分组名|URL} / {@code 分组名 URL}). Throws {@link IOException} if any non-empty line is
     * malformed or uses a non-HTTP(S) scheme.
     */
    static List<ImportSpec> parseImportSpecsStrict(String rawInput) throws IOException {
        if (rawInput == null) throw new IOException("请输入有效的 HTTP 或 HTTPS 配置地址");
        String trimmedAll = rawInput.trim();
        if (trimmedAll.isEmpty() || trimmedAll.length() > MAX_TRANSFER_LENGTH) {
            throw new IOException("配置地址为空或超出长度限制");
        }
        String normalizedNewlines = trimmedAll.replace("\r\n", "\n").replace('\r', '\n');
        String[] rawLines = normalizedNewlines.split("\n");
        List<ImportSpec> out = new ArrayList<ImportSpec>();
        Set<String> seenUrls = new LinkedHashSet<String>();
        for (String rawLine : rawLines) {
            String line = rawLine == null ? "" : rawLine.trim();
            if (line.isEmpty()) continue;
            // Support semicolon-separated URLs on a single line (without breaking ;md5; or queries)
            List<String> segments = splitInlineUrls(line);
            for (String segment : segments) {
                ImportSpec spec = parseSingleSpecLine(segment);
                if (spec == null) {
                    throw new IOException("请输入有效的 HTTP 或 HTTPS 配置地址");
                }
                if (seenUrls.add(spec.url)) {
                    if (out.size() >= MAX_BATCH_SOURCES) {
                        throw new IOException("单次最多同时导入 " + MAX_BATCH_SOURCES + " 个订阅源");
                    }
                    out.add(spec);
                }
            }
        }
        if (out.isEmpty()) {
            throw new IOException("请输入有效的 HTTP 或 HTTPS 配置地址");
        }
        return out;
    }

    /** Permissive variant for UI helpers; returns empty list when input contains no valid URL. */
    static List<ImportSpec> parseImportSpecs(String rawInput) {
        try {
            return parseImportSpecsStrict(rawInput);
        } catch (IOException ignored) {
            return Collections.emptyList();
        }
    }

    /**
     * Validates single- or multi-line address payloads received by {@link ConfigTransferServer}.
     * Rejects non-HTTP(S) schemes, control characters, malformed lines, or oversized inputs.
     */
    static String validateTransferAddressInput(String rawInput) throws IOException {
        List<ImportSpec> specs = parseImportSpecsStrict(rawInput);
        if (specs.size() == 1 && specs.get(0).name.isEmpty()) {
            String only = specs.get(0).url;
            if (only.length() > 8192) throw new IOException("地址过长");
            return only;
        }
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < specs.size(); i++) {
            ImportSpec spec = specs.get(i);
            if (i > 0) sb.append('\n');
            if (!spec.name.isEmpty()) {
                sb.append(spec.name).append(',');
            }
            sb.append(spec.url);
        }
        String result = sb.toString();
        if (result.length() > MAX_TRANSFER_LENGTH) throw new IOException("地址过长");
        return result;
    }

    private static List<String> splitInlineUrls(String line) {
        List<String> parts = new ArrayList<String>();
        int start = 0;
        int len = line.length();
        for (int i = 0; i < len; i++) {
            char c = line.charAt(i);
            if (c == ';' || c == '；') {
                String rest = line.substring(i + 1).trim().toLowerCase(Locale.ROOT);
                if (rest.startsWith("http://") || rest.startsWith("https://")) {
                    String piece = line.substring(start, i).trim();
                    if (!piece.isEmpty()) parts.add(piece);
                    start = i + 1;
                }
            }
        }
        String tail = line.substring(start).trim();
        if (!tail.isEmpty()) parts.add(tail);
        return parts;
    }

    private static ImportSpec parseSingleSpecLine(String line) {
        if (line == null) return null;
        String trimmed = line.trim();
        if (trimmed.isEmpty() || containsControlChars(trimmed)) return null;
        int httpIdx = findHttpStart(trimmed);
        if (httpIdx < 0) return null;
        String label = trimmed.substring(0, httpIdx).trim();
        label = stripLabelDelimiters(label);
        if (label.length() > 28) label = label.substring(0, 28).trim();
        String urlPart = trimmed.substring(httpIdx).trim();
        if (urlPart.length() > 8192 || urlPart.indexOf(' ') >= 0 || urlPart.indexOf('\t') >= 0) {
            return null;
        }
        try {
            URL parsed = new URL(urlPart);
            String proto = parsed.getProtocol();
            String host = parsed.getHost();
            if ((!"http".equals(proto) && !"https".equals(proto))
                    || host == null
                    || host.trim().isEmpty()) {
                return null;
            }
            return new ImportSpec(label, urlPart);
        } catch (Exception ignored) {
            return null;
        }
    }

    private static int findHttpStart(String line) {
        String lower = line.toLowerCase(Locale.ROOT);
        int idxHttps = lower.indexOf("https://");
        int idxHttp = lower.indexOf("http://");
        if (idxHttps < 0) return idxHttp;
        if (idxHttp < 0) return idxHttps;
        return Math.min(idxHttps, idxHttp);
    }

    private static boolean containsControlChars(String s) {
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c < 0x20 || c == 0x7f) return true;
        }
        return false;
    }

    private static String stripLabelDelimiters(String label) {
        if (label == null || label.isEmpty()) return "";
        int end = label.length();
        while (end > 0) {
            char c = label.charAt(end - 1);
            if (c == ','
                    || c == '，'
                    || c == '|'
                    || c == ':'
                    || c == '：'
                    || c == '='
                    || c == '-'
                    || Character.isWhitespace(c)) {
                end--;
            } else {
                break;
            }
        }
        int start = 0;
        while (start < end) {
            char c = label.charAt(start);
            if (c == '[' || c == '【' || Character.isWhitespace(c)) start++;
            else break;
        }
        while (end > start) {
            char c = label.charAt(end - 1);
            if (c == ']' || c == '】' || Character.isWhitespace(c)) end--;
            else break;
        }
        return label.substring(start, end).trim();
    }

    static String cleanSubscriptionLabel(String raw) {
        if (raw == null) return "";
        String s = raw.trim();
        s = s.replaceFirst("\\s*（订阅\\s*\\d+）$", "");
        s = s.replaceFirst("\\s*·\\s*\\d+\\s*个片源$", "");
        s = s.trim();
        if (s.length() > 24) s = s.substring(0, 24).trim();
        return s;
    }

    /**
     * Derives a concise, human-friendly, deduplicated group name for an imported subscription.
     */
    static String deriveGroupName(
            String preferredName,
            String origin,
            Cms.Config parsed,
            int fallbackIndex,
            Set<String> usedNames) {
        String candidate = cleanSubscriptionLabel(preferredName);
        if (candidate.isEmpty() || "我的订阅".equals(candidate) || "默认分组".equals(candidate)) {
            candidate = inferNameFromOrigin(origin);
        }
        if (candidate.isEmpty() && parsed != null && !parsed.sites.isEmpty()) {
            candidate = inferNameFromSites(parsed.sites);
        }
        if (candidate.isEmpty()) {
            candidate = "订阅源 " + Math.max(1, fallbackIndex);
        }
        if (candidate.length() > 24) {
            candidate = candidate.substring(0, 24).trim();
        }
        if (usedNames == null) return candidate;
        String unique = candidate;
        int suffix = 2;
        while (usedNames.contains(unique)) {
            unique = candidate + " " + suffix++;
        }
        usedNames.add(unique);
        return unique;
    }

    private static String inferNameFromOrigin(String origin) {
        if (origin == null || origin.trim().isEmpty()) return "";
        if (!Cms.isHttp(origin)) return "";
        try {
            URL u = new URL(origin.trim());
            String host = u.getHost() == null ? "" : u.getHost().toLowerCase(Locale.ROOT);
            if (host.startsWith("www.")) host = host.substring(4);
            String path = u.getPath() == null ? "" : u.getPath();
            String pathLabel = extractReadablePathToken(path);
            boolean genericHost =
                    host.isEmpty()
                            || GENERIC_HOSTS.contains(host)
                            || host.matches("\\d+\\.\\d+\\.\\d+\\.\\d+");
            if (!genericHost) {
                if (!pathLabel.isEmpty() && pathLabel.length() <= 14) {
                    return host + "/" + pathLabel;
                }
                return host;
            }
            if (!pathLabel.isEmpty()) return pathLabel;
            return host;
        } catch (Exception ignored) {
            return "";
        }
    }

    private static String extractReadablePathToken(String path) {
        if (path == null || path.isEmpty()) return "";
        String[] segs = path.split("/");
        for (int i = segs.length - 1; i >= 0; i--) {
            String seg = segs[i].trim();
            if (seg.isEmpty()) continue;
            String stem = seg.replaceFirst("\\.(?:json|txt|js|py|m3u8?)$", "");
            String lower = stem.toLowerCase(Locale.ROOT);
            if (lower.isEmpty()
                    || "api".equals(lower)
                    || "config".equals(lower)
                    || "tv".equals(lower)
                    || "tvbox".equals(lower)
                    || "index".equals(lower)
                    || "main".equals(lower)
                    || "master".equals(lower)
                    || "raw".equals(lower)
                    || "json".equals(lower)
                    || "vod".equals(lower)) {
                continue;
            }
            return stem;
        }
        return "";
    }

    private static String inferNameFromSites(List<Cms.Site> sites) {
        if (sites == null || sites.isEmpty()) return "";
        for (Cms.Site s : sites) {
            if (s == null || s.name == null) continue;
            String n = s.name.trim();
            if (n.isEmpty()) continue;
            if (n.contains("豆瓣")
                    || n.contains("配置中心")
                    || n.contains("我的云盘")
                    || n.contains("我的网盘")
                    || n.contains("推送")) {
                continue;
            }
            return n;
        }
        String first = sites.get(0).name;
        return first == null ? "" : first.trim();
    }

    /** Reads {@code _marco_multi_sources} metadata from a merged multi-source config JSON. */
    static List<MultiSourceMeta> readMultiSourceMeta(String rawJson) {
        if (rawJson == null || rawJson.trim().isEmpty()) return Collections.emptyList();
        try {
            String clean = Cms.withoutComments(rawJson).trim();
            if (!clean.startsWith("{")) return Collections.emptyList();
            JSONObject root = new JSONObject(clean);
            JSONArray arr = root.optJSONArray(META_MULTI_SOURCES);
            if (arr == null || arr.length() == 0) return Collections.emptyList();
            List<MultiSourceMeta> out = new ArrayList<MultiSourceMeta>();
            for (int i = 0; i < arr.length(); i++) {
                JSONObject item = arr.optJSONObject(i);
                if (item == null) continue;
                String url = item.optString("url", "").trim();
                String name = item.optString("name", "").trim();
                long updated = Math.max(1L, item.optLong("updated", 1L));
                if (!url.isEmpty() || !name.isEmpty()) {
                    out.add(new MultiSourceMeta(name, url, updated));
                }
            }
            return out;
        } catch (Exception ignored) {
            return Collections.emptyList();
        }
    }

    /**
     * Merges multiple subscription bundles into one auto-grouped {@link Cms.Config}.
     *
     * <p>Every site retains its own resolved {@code jar} (inheriting its bundle's {@code spider}
     * when the site does not specify an explicit {@code jar}), its resolved {@code api}/{@code
     * ext}, and receives its source's automatic {@code group}. Duplicate site keys across bundles
     * are deterministically disambiguated by origin hash so bookmarks, preferences, and edits stay
     * stable across daily updates.
     */
    static MergedResult mergeSources(List<SourceBundle> bundles) throws Exception {
        if (bundles == null || bundles.isEmpty()) {
            throw new IOException("没有可合并的订阅源");
        }
        List<ParsedBundle> parsedBundles = new ArrayList<ParsedBundle>();
        Set<String> usedGroups = new LinkedHashSet<String>();
        for (int i = 0; i < bundles.size(); i++) {
            SourceBundle b = bundles.get(i);
            if (b == null || b.raw == null || b.raw.trim().isEmpty()) continue;
            Cms.Config parsed = Cms.parseConfig(b.raw, b.origin);
            String effectiveOrigin =
                    !b.origin.isEmpty()
                            ? b.origin
                            : (!parsed.origin.isEmpty() ? parsed.origin : "");
            String groupName =
                    deriveGroupName(b.groupName, effectiveOrigin, parsed, i + 1, usedGroups);
            JSONObject rawRoot = parseRootObjectOrEmpty(parsed.raw);
            parsedBundles.add(new ParsedBundle(b, parsed, rawRoot, groupName, effectiveOrigin));
        }
        if (parsedBundles.isEmpty()) {
            throw new IOException("没有解析到有效的订阅源");
        }

        // Fair per-bundle cap if combined site count exceeds Cms's 500-site limit
        int totalSites = 0;
        for (ParsedBundle pb : parsedBundles) totalSites += pb.parsed.sites.size();
        int[] siteLimits = computeFairSiteLimits(parsedBundles, totalSites, MAX_MERGED_SITES);

        JSONArray mergedSites = new JSONArray();
        JSONArray mergedParses = new JSONArray();
        JSONArray mergedRules = new JSONArray();
        JSONArray mergedAds = new JSONArray();
        JSONArray mergedLives = new JSONArray();
        JSONArray metaArray = new JSONArray();
        List<String> groupNames = new ArrayList<String>();
        Set<String> usedSiteKeys = new HashSet<String>();
        Set<String> seenParseUrls = new HashSet<String>();
        Set<String> seenAds = new HashSet<String>();
        Set<String> seenLiveKeys = new HashSet<String>();
        String firstSpider = "";
        StringBuilder identityMaterial = new StringBuilder();

        for (int bIdx = 0; bIdx < parsedBundles.size(); bIdx++) {
            ParsedBundle pb = parsedBundles.get(bIdx);
            groupNames.add(pb.groupName);
            if (firstSpider.isEmpty() && pb.parsed.spider != null && !pb.parsed.spider.isEmpty()) {
                firstSpider = pb.parsed.spider;
            }
            String originTag =
                    pb.effectiveOrigin.isEmpty()
                            ? ("local:" + pb.groupName + ":" + bIdx)
                            : pb.effectiveOrigin;
            identityMaterial.append(originTag).append('\n');
            String bundleShortHash = ConfigLibrary.hash(originTag).substring(0, 6);

            metaArray.put(
                    new JSONObject()
                            .put("name", pb.groupName)
                            .put("url", pb.effectiveOrigin)
                            .put("updated", pb.bundle.updated));

            JSONArray rawSites = extractRawSitesArray(pb.rawRoot);
            int limit = siteLimits[bIdx];
            int addedForBundle = 0;
            for (int sIdx = 0; sIdx < pb.parsed.sites.size() && addedForBundle < limit; sIdx++) {
                Cms.Site site = pb.parsed.sites.get(sIdx);
                JSONObject rawSite =
                        (rawSites != null && sIdx < rawSites.length())
                                ? rawSites.optJSONObject(sIdx)
                                : null;
                JSONObject copy = copyJsonObject(rawSite);
                String uniqueKey = site.key;
                if (!usedSiteKeys.add(uniqueKey)) {
                    uniqueKey = site.key + "__" + bundleShortHash;
                    int dup = 2;
                    while (!usedSiteKeys.add(uniqueKey)) {
                        uniqueKey = site.key + "__" + bundleShortHash + "_" + dup++;
                    }
                }
                copy.put("key", uniqueKey);
                copy.put("name", site.name);
                copy.put("group", pb.groupName);
                copy.put("type", site.type);
                copy.put("api", site.api);
                copy.put("searchable", site.searchable ? 1 : 0);
                String effectiveJar =
                        (site.jar != null && !site.jar.isEmpty())
                                ? site.jar
                                : (pb.parsed.spider == null ? "" : pb.parsed.spider);
                if (!effectiveJar.isEmpty()) {
                    copy.put("jar", effectiveJar);
                }
                if (site.playUrl != null && !site.playUrl.isEmpty()) {
                    copy.put("playUrl", site.playUrl);
                }
                if (site.ext != null) {
                    copy.put("ext", site.ext);
                }
                mergedSites.put(copy);
                addedForBundle++;
            }

            // Merge parses (dedup by URL, bounded at 100)
            JSONArray rawParses = pb.rawRoot.optJSONArray("parses");
            if (rawParses != null) {
                for (int i = 0; i < rawParses.length() && mergedParses.length() < 100; i++) {
                    JSONObject p = rawParses.optJSONObject(i);
                    if (p == null) continue;
                    String pUrl = p.optString("url", "").trim();
                    if (!pUrl.isEmpty() && seenParseUrls.add(pUrl)) {
                        mergedParses.put(copyJsonObject(p));
                    }
                }
            }
            // Merge rules (bounded at 200)
            JSONArray rawRules = pb.rawRoot.optJSONArray("rules");
            if (rawRules != null) {
                for (int i = 0; i < rawRules.length() && mergedRules.length() < 200; i++) {
                    JSONObject r = rawRules.optJSONObject(i);
                    if (r != null) mergedRules.put(copyJsonObject(r));
                }
            }
            // Merge ads
            JSONArray rawAds = pb.rawRoot.optJSONArray("ads");
            if (rawAds != null) {
                for (int i = 0; i < rawAds.length(); i++) {
                    String ad = rawAds.optString(i, "").trim();
                    if (!ad.isEmpty() && seenAds.add(ad)) mergedAds.put(ad);
                }
            }
            // Merge lives
            JSONArray rawLives = pb.rawRoot.optJSONArray("lives");
            if (rawLives != null) {
                for (int i = 0; i < rawLives.length(); i++) {
                    JSONObject lv = rawLives.optJSONObject(i);
                    if (lv == null) continue;
                    String lvKey = lv.optString("url", lv.optString("name", "")).trim();
                    if (lvKey.isEmpty() || seenLiveKeys.add(lvKey)) {
                        mergedLives.put(copyJsonObject(lv));
                    }
                }
            }
        }

        JSONObject mergedRoot = new JSONObject();
        if (!firstSpider.isEmpty()) mergedRoot.put("spider", firstSpider);
        mergedRoot.put("sites", mergedSites);
        if (mergedParses.length() > 0) mergedRoot.put("parses", mergedParses);
        if (mergedRules.length() > 0) mergedRoot.put("rules", mergedRules);
        if (mergedAds.length() > 0) mergedRoot.put("ads", mergedAds);
        if (mergedLives.length() > 0) mergedRoot.put("lives", mergedLives);
        mergedRoot.put(META_MULTI_SOURCES, metaArray);

        String multiOrigin =
                parsedBundles.size() == 1 && !parsedBundles.get(0).effectiveOrigin.isEmpty()
                        ? parsedBundles.get(0).effectiveOrigin
                        : MULTI_ORIGIN_PREFIX
                                + ConfigLibrary.hash(identityMaterial.toString()).substring(0, 16);
        String mergedRaw = mergedRoot.toString();
        Cms.Config verified = Cms.parseConfig(mergedRaw, multiOrigin);
        return new MergedResult(verified, mergedRaw, multiOrigin, groupNames, parsedBundles.size());
    }

    private static int[] computeFairSiteLimits(
            List<ParsedBundle> bundles, int totalSites, int maxTotal) {
        int n = bundles.size();
        int[] limits = new int[n];
        if (totalSites <= maxTotal) {
            for (int i = 0; i < n; i++) limits[i] = bundles.get(i).parsed.sites.size();
            return limits;
        }
        int remaining = maxTotal;
        boolean[] done = new boolean[n];
        int active = n;
        while (remaining > 0 && active > 0) {
            int share = Math.max(1, remaining / active);
            boolean progress = false;
            for (int i = 0; i < n && remaining > 0; i++) {
                if (done[i]) continue;
                int avail = bundles.get(i).parsed.sites.size() - limits[i];
                int grant = Math.min(avail, Math.min(share, remaining));
                limits[i] += grant;
                remaining -= grant;
                progress = true;
                if (limits[i] >= bundles.get(i).parsed.sites.size()) {
                    done[i] = true;
                    active--;
                }
            }
            if (!progress) break;
        }
        return limits;
    }

    private static JSONObject parseRootObjectOrEmpty(String raw) {
        try {
            String clean = Cms.withoutComments(raw).trim();
            if (clean.startsWith("[")) {
                return new JSONObject().put("sites", new JSONArray(clean));
            }
            if (clean.startsWith("{")) {
                return new JSONObject(clean);
            }
        } catch (Exception ignored) {
        }
        return new JSONObject();
    }

    private static JSONArray extractRawSitesArray(JSONObject root) {
        if (root == null) return null;
        JSONArray sites = root.optJSONArray("sites");
        if (sites != null && sites.length() > 0) return sites;
        if (root.has("api") && !root.optString("api", "").trim().isEmpty()) {
            return new JSONArray().put(root);
        }
        return null;
    }

    private static JSONObject copyJsonObject(JSONObject source) {
        if (source == null) return new JSONObject();
        try {
            return new JSONObject(source.toString());
        } catch (Exception ignored) {
            JSONObject out = new JSONObject();
            Iterator<String> keys = source.keys();
            while (keys.hasNext()) {
                String k = keys.next();
                try {
                    out.put(k, source.opt(k));
                } catch (Exception ignoredKey) {
                }
            }
            return out;
        }
    }

    private static final class ParsedBundle {
        final SourceBundle bundle;
        final Cms.Config parsed;
        final JSONObject rawRoot;
        final String groupName;
        final String effectiveOrigin;

        ParsedBundle(
                SourceBundle bundle,
                Cms.Config parsed,
                JSONObject rawRoot,
                String groupName,
                String effectiveOrigin) {
            this.bundle = bundle;
            this.parsed = parsed;
            this.rawRoot = rawRoot;
            this.groupName = groupName;
            this.effectiveOrigin = effectiveOrigin;
        }
    }

    /**
     * Checks all saved HTTP(S) subscriptions (and members of an active merged multi-source config)
     * that are due for daily refresh (or all of them when {@code force} is true), validates every
     * fetched config before persisting, and rebuilds the active merged config if any member
     * changed.
     */
    static RefreshSummary refreshDueSubscriptions(
            ConfigLibrary library,
            String activeOrigin,
            String activeRaw,
            long nowMs,
            boolean force,
            Fetcher fetcher)
            throws Exception {
        if (library == null || fetcher == null) {
            return new RefreshSummary(0, 0, 0, false, "", "", Collections.<String>emptyList());
        }
        List<ConfigLibrary.Entry> entries = library.entries();
        Map<String, ConfigLibrary.Entry> byOrigin =
                new LinkedHashMap<String, ConfigLibrary.Entry>();
        for (ConfigLibrary.Entry e : entries) {
            if (e != null && Cms.isHttp(e.origin)) {
                byOrigin.put(e.origin.trim(), e);
            }
        }

        List<MultiSourceMeta> activeMembers = readMultiSourceMeta(activeRaw);
        Map<String, RefreshCandidate> candidates = new LinkedHashMap<String, RefreshCandidate>();
        for (ConfigLibrary.Entry e : byOrigin.values()) {
            candidates.put(
                    e.origin.trim(),
                    new RefreshCandidate(e.origin.trim(), e.name, e.selected, e.digest, e.updated));
        }
        for (MultiSourceMeta m : activeMembers) {
            if (!Cms.isHttp(m.url)) continue;
            if (!candidates.containsKey(m.url)) {
                candidates.put(m.url, new RefreshCandidate(m.url, m.name, "", "", m.updated));
            }
        }
        String cleanActiveOrigin = activeOrigin == null ? "" : activeOrigin.trim();
        if (Cms.isHttp(cleanActiveOrigin) && !candidates.containsKey(cleanActiveOrigin)) {
            String activeDigest =
                    activeRaw != null && !activeRaw.isEmpty() ? ConfigLibrary.hash(activeRaw) : "";
            candidates.put(
                    cleanActiveOrigin,
                    new RefreshCandidate(cleanActiveOrigin, "", "", activeDigest, 0L));
        }

        int checked = 0;
        int updated = 0;
        int failed = 0;
        List<String> updatedNames = new ArrayList<String>();
        Map<String, String> refreshedRawByUrl = new HashMap<String, String>();
        Set<String> changedUrls = new HashSet<String>();

        for (RefreshCandidate c : candidates.values()) {
            if (!force && !isDueForDailyUpdate(c.lastUpdated, nowMs)) {
                continue;
            }
            checked++;
            try {
                String fetched = fetcher.fetch(c.url);
                Cms.Config parsed = Cms.parseConfig(fetched, c.url);
                String validRaw = parsed.raw;
                String newDigest = ConfigLibrary.hash(validRaw);
                String saveName =
                        (c.name != null && !c.name.isEmpty()) ? c.name : defaultConfigName(parsed);
                library.remember(validRaw, c.url, saveName, c.selected, nowMs);
                refreshedRawByUrl.put(c.url, validRaw);
                if (!newDigest.equals(c.previousDigest)) {
                    updated++;
                    changedUrls.add(c.url);
                    updatedNames.add(cleanSubscriptionLabel(saveName));
                }
            } catch (Throwable ignored) {
                failed++;
            }
        }

        boolean activeChanged = false;
        String nextActiveRaw = "";
        String nextActiveOrigin = cleanActiveOrigin;

        if (!activeMembers.isEmpty()) {
            boolean anyMemberChanged = false;
            for (MultiSourceMeta m : activeMembers) {
                if (changedUrls.contains(m.url)) {
                    anyMemberChanged = true;
                    break;
                }
            }
            if (anyMemberChanged) {
                List<ConfigLibrary.Entry> refreshedEntries = library.entries();
                Map<String, ConfigLibrary.Entry> latestByOrigin =
                        new HashMap<String, ConfigLibrary.Entry>();
                for (ConfigLibrary.Entry e : refreshedEntries) {
                    if (e != null && e.origin != null && !e.origin.isEmpty()) {
                        latestByOrigin.put(e.origin.trim(), e);
                    }
                }
                List<SourceBundle> rebuildBundles = new ArrayList<SourceBundle>();
                for (MultiSourceMeta m : activeMembers) {
                    String raw = refreshedRawByUrl.get(m.url);
                    long stamp = changedUrls.contains(m.url) ? nowMs : m.updated;
                    if (raw == null) {
                        ConfigLibrary.Entry saved = latestByOrigin.get(m.url);
                        if (saved != null) {
                            try {
                                raw = library.raw(saved);
                                stamp = saved.updated;
                            } catch (Exception ignored) {
                            }
                        }
                    }
                    if (raw != null && !raw.trim().isEmpty()) {
                        rebuildBundles.add(new SourceBundle(m.name, m.url, raw, stamp));
                    }
                }
                if (!rebuildBundles.isEmpty()) {
                    MergedResult rebuilt = mergeSources(rebuildBundles);
                    activeChanged = true;
                    nextActiveRaw = rebuilt.rawJson;
                    nextActiveOrigin = rebuilt.origin;
                    library.remember(
                            rebuilt.rawJson,
                            rebuilt.origin,
                            mergedSubscriptionName(rebuilt.groupNames),
                            "",
                            nowMs);
                }
            }
        } else if (Cms.isHttp(cleanActiveOrigin) && changedUrls.contains(cleanActiveOrigin)) {
            String newRaw = refreshedRawByUrl.get(cleanActiveOrigin);
            if (newRaw != null && !newRaw.isEmpty()) {
                activeChanged = true;
                nextActiveRaw = newRaw;
                nextActiveOrigin = cleanActiveOrigin;
            }
        }

        return new RefreshSummary(
                checked,
                updated,
                failed,
                activeChanged,
                nextActiveRaw,
                nextActiveOrigin,
                updatedNames);
    }

    static String defaultConfigName(Cms.Config config) {
        if (config == null || config.sites.isEmpty()) return "我的订阅";
        return config.sites.get(0).name
                + (config.sites.size() > 1 ? " · " + config.sites.size() + " 个片源" : "");
    }

    static String mergedSubscriptionName(List<String> groupNames) {
        if (groupNames == null || groupNames.isEmpty()) return "多源合集";
        if (groupNames.size() == 1) return groupNames.get(0);
        StringBuilder sb = new StringBuilder();
        int limit = Math.min(2, groupNames.size());
        for (int i = 0; i < limit; i++) {
            if (i > 0) sb.append(" + ");
            sb.append(groupNames.get(i));
        }
        if (groupNames.size() > limit) {
            sb.append(" 等 ").append(groupNames.size()).append(" 源");
        }
        return sb.toString();
    }

    private static final class RefreshCandidate {
        final String url;
        final String name;
        final String selected;
        final String previousDigest;
        final long lastUpdated;

        RefreshCandidate(
                String url, String name, String selected, String previousDigest, long lastUpdated) {
            this.url = url;
            this.name = name == null ? "" : name;
            this.selected = selected == null ? "" : selected;
            this.previousDigest = previousDigest == null ? "" : previousDigest;
            this.lastUpdated = lastUpdated;
        }
    }
}
