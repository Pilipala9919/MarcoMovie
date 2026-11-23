package com.pilipala.marcomovie;

import java.util.*;
import org.json.*;

/**
 * Source-advertised filter engine with multi-format TVBox/CSP/DRPY/T4 schema parsing, sub-category
 * resolution for MacCMS sources, remote-filter honoring verification, and local metadata fallback.
 */
final class VideoFilters {
    static final String[] DIMENSIONS = {"class", "area", "year"};
    static final String[] LABELS = {"类型", "国家 / 地区", "年份"};
    private static final int MAX_REMOTE_GROUPS = 8;

    static final class Choice {
        final String label, value;

        Choice(String label, String value) {
            this.label = label;
            this.value = value;
        }
    }

    static final class Definition {
        final String dimension, key, label;
        boolean remote;
        final List<Choice> choices = new ArrayList<>();

        Definition(String dimension, String key, String label, boolean remote) {
            this.dimension = dimension;
            this.key = key;
            this.label = label;
            this.remote = remote;
            choices.add(new Choice("全部", ""));
        }

        String labelFor(String value) {
            if (value == null || value.isEmpty()) return "全部";
            for (Choice choice : choices) if (choice.value.equals(value)) return choice.label;
            return value;
        }
    }

    static final class SubCategoryMatch {
        final String categoryId;
        final String categoryName;
        final String satisfiedDimension;

        SubCategoryMatch(String categoryId, String categoryName, String satisfiedDimension) {
            this.categoryId = categoryId;
            this.categoryName = categoryName;
            this.satisfiedDimension = satisfiedDimension;
        }
    }

    static boolean allowedKey(String key) {
        return Arrays.asList(
                        "class", "genre", "area", "region", "country", "year", "lang", "by",
                        "letter")
                .contains(key);
    }

    static String dimension(String key, String label) {
        String k = key == null ? "" : key.trim().toLowerCase(Locale.ROOT);
        String l = label == null ? "" : label.trim();
        if (k.equals("year")
                || k.equals("yr")
                || k.equals("11") && (l.contains("年") || l.isEmpty())
                || l.contains("年份")
                || l.contains("年代")) return "year";
        if (Arrays.asList("area", "region", "country").contains(k)
                || l.contains("地区")
                || l.contains("国家")
                || l.contains("产地")
                || l.contains("区域")) return "area";
        if (Arrays.asList("class", "genre", "type", "cateid", "plot", "style").contains(k)
                || l.contains("类型")
                || l.contains("题材")
                || l.contains("剧情")
                || l.contains("分类")
                || l.contains("风格")) return "class";
        return "";
    }

    private static String friendlyGroupLabel(String key, String rawLabel, String canonicalDim) {
        if (rawLabel != null && !rawLabel.trim().isEmpty()) {
            String trimmed = rawLabel.trim();
            if ("class".equals(canonicalDim) && ("类型".equals(trimmed) || "剧情".equals(trimmed))) {
                return LABELS[0];
            }
            if ("area".equals(canonicalDim) && ("地区".equals(trimmed) || "国家".equals(trimmed))) {
                return LABELS[1];
            }
            if ("year".equals(canonicalDim) && ("年份".equals(trimmed) || "年代".equals(trimmed))) {
                return LABELS[2];
            }
            return trimmed;
        }
        if ("class".equals(canonicalDim)) return LABELS[0];
        if ("area".equals(canonicalDim)) return LABELS[1];
        if ("year".equals(canonicalDim)) return LABELS[2];
        String k = key == null ? "" : key.trim().toLowerCase(Locale.ROOT);
        if (k.equals("by") || k.equals("sort") || k.equals("order")) return "排序";
        if (k.equals("lang") || k.equals("language")) return "语言";
        if (k.equals("letter") || k.equals("alpha")) return "字母";
        if (k.equals("state") || k.equals("status")) return "状态";
        if (k.equals("tag") || k.equals("tags")) return "标签";
        return key == null ? "筛选" : key.trim();
    }

    private static Object unwrapJsonValue(Object raw) {
        if (!(raw instanceof String)) return raw;
        String s = ((String) raw).trim();
        if (s.startsWith("{")) {
            try {
                return new JSONObject(s);
            } catch (JSONException ignored) {
            }
        } else if (s.startsWith("[")) {
            try {
                return new JSONArray(s);
            } catch (JSONException ignored) {
            }
        }
        return raw;
    }

    private static JSONArray asGroupArray(Object entry) {
        Object unwrapped = unwrapJsonValue(entry);
        if (unwrapped instanceof JSONArray) return (JSONArray) unwrapped;
        if (unwrapped instanceof JSONObject) return new JSONArray().put(unwrapped);
        return null;
    }

    private static String findCategoryName(JSONObject root, String categoryId) {
        if (root == null || categoryId == null || categoryId.isEmpty()) return "";
        JSONArray classes = root.optJSONArray("class");
        if (classes == null) return "";
        String trimmed = categoryId.trim();
        for (int i = 0; i < classes.length(); i++) {
            JSONObject item = classes.optJSONObject(i);
            if (item == null) continue;
            String id = item.optString("type_id", "").trim();
            if (id.equals(trimmed)) {
                return item.optString("type_name", "").trim();
            }
        }
        return "";
    }

    private static JSONArray extractGroups(JSONObject root, String category) {
        if (root == null) return null;
        Object filters = unwrapJsonValue(root.opt("filters"));
        if (filters == null) filters = unwrapJsonValue(root.opt("filter"));
        if (filters instanceof JSONArray) return (JSONArray) filters;
        if (!(filters instanceof JSONObject)) return null;
        JSONObject map = (JSONObject) filters;
        String cat = category == null ? "" : category;
        String trimmed = cat.trim();
        String catName = findCategoryName(root, trimmed);

        // 1. Exact ID, trimmed ID, or category type_name
        String[] directKeys = {cat, trimmed, catName};
        for (String candidate : directKeys) {
            if (candidate == null || candidate.isEmpty()) continue;
            if (map.has(candidate)) {
                JSONArray found = asGroupArray(map.opt(candidate));
                if (found != null && found.length() > 0) return found;
            }
        }
        // 2. Case-insensitive / trimmed key match
        Iterator<String> keys = map.keys();
        while (keys.hasNext()) {
            String k = keys.next();
            if (k == null) continue;
            String kt = k.trim();
            if ((!trimmed.isEmpty() && kt.equalsIgnoreCase(trimmed))
                    || (!catName.isEmpty() && kt.equalsIgnoreCase(catName))) {
                JSONArray found = asGroupArray(map.opt(k));
                if (found != null && found.length() > 0) return found;
            }
        }
        // 3. Global wildcard fallback if provided by the source
        for (String wildcard : new String[] {"all", "*"}) {
            if (map.has(wildcard)) {
                JSONArray found = asGroupArray(map.opt(wildcard));
                if (found != null && found.length() > 0) return found;
            }
        }
        return null;
    }

    static List<Definition> definitions(String home, String category, List<Cms.Video> videos) {
        List<Definition> remoteList = new ArrayList<>();
        Set<String> usedDimensions = new HashSet<>();
        Set<String> usedKeys = new HashSet<>();
        try {
            JSONObject root = new JSONObject(home == null ? "{}" : home);
            JSONArray groups = extractGroups(root, category);
            if (groups != null) {
                for (int i = 0; i < Math.min(groups.length(), 32); i++) {
                    if (remoteList.size() >= MAX_REMOTE_GROUPS) break;
                    JSONObject group = groups.optJSONObject(i);
                    if (group == null) continue;
                    String key = group.optString("key", "").trim();
                    String rawLabel = group.optString("name", group.optString("title", "")).trim();
                    if (key.isEmpty() || key.length() > 64) continue;
                    if (!usedKeys.add(key)) continue;

                    JSONArray values = group.optJSONArray("value");
                    if (values == null) values = group.optJSONArray("values");
                    if (values == null) values = group.optJSONArray("options");
                    if (values == null) values = group.optJSONArray("list");
                    if (values == null) continue;

                    String canonicalDim = dimension(key, rawLabel);
                    String assignedDim;
                    if (!canonicalDim.isEmpty() && !usedDimensions.contains(canonicalDim)) {
                        assignedDim = canonicalDim;
                    } else if (!usedDimensions.contains(key)) {
                        assignedDim = key;
                    } else {
                        assignedDim = "ext:" + key;
                    }
                    String displayLabel = friendlyGroupLabel(key, rawLabel, canonicalDim);
                    Definition def = new Definition(assignedDim, key, displayLabel, true);
                    Set<String> seen = new HashSet<>();
                    seen.add("");
                    for (int n = 0; n < Math.min(values.length(), 256); n++) {
                        JSONObject item = values.optJSONObject(n);
                        String value;
                        String name;
                        if (item == null) {
                            value = values.optString(n, "").trim();
                            name = value;
                        } else {
                            value =
                                    item.optString(
                                                    "v",
                                                    item.optString(
                                                            "value", item.optString("id", "")))
                                            .trim();
                            name =
                                    item.optString(
                                                    "n",
                                                    item.optString(
                                                            "name", item.optString("title", value)))
                                            .trim();
                        }
                        if (("全部".equals(name) || "不限".equals(name))
                                && (value.isEmpty()
                                        || "0".equals(value)
                                        || "all".equalsIgnoreCase(value))) {
                            continue;
                        }
                        if (!value.isEmpty() && !name.isEmpty() && seen.add(value)) {
                            def.choices.add(new Choice(name, value));
                        }
                    }
                    if (def.choices.size() > 1) {
                        usedDimensions.add(assignedDim);
                        remoteList.add(def);
                    }
                }
            }
        } catch (JSONException ignored) {
        }
        if (!remoteList.isEmpty()) {
            return remoteList;
        }
        List<Definition> result = new ArrayList<>();
        for (int i = 0; i < DIMENSIONS.length; i++) {
            String dim = DIMENSIONS[i];
            Definition def = new Definition(dim, dim, LABELS[i], false);
            Set<String> values = new LinkedHashSet<>();
            if (dim.equals("class"))
                Collections.addAll(
                        values, "剧情", "喜剧", "动作", "爱情", "科幻", "悬疑", "犯罪", "惊悚", "动画", "纪录片");
            if (dim.equals("area"))
                Collections.addAll(
                        values, "中国大陆", "中国香港", "中国台湾", "美国", "英国", "日本", "韩国", "法国", "印度", "泰国");
            if (dim.equals("year")) {
                int year = Calendar.getInstance().get(Calendar.YEAR);
                for (int n = year; n >= year - 15; n--) values.add(String.valueOf(n));
            }
            if (videos != null) {
                for (Cms.Video video : videos) {
                    if (video == null) continue;
                    String raw =
                            dim.equals("class")
                                    ? video.genre
                                    : dim.equals("area") ? video.area : video.year;
                    if (raw != null)
                        for (String value : raw.split("[ /、,，;；|]+")) {
                            value = value.trim();
                            if (!value.isEmpty() && value.length() <= 24 && values.size() < 256)
                                values.add(value);
                        }
                }
            }
            for (String value : values) def.choices.add(new Choice(value, value));
            result.add(def);
        }
        return result;
    }

    static boolean hasRemoteDefinitions(List<Definition> definitions) {
        if (definitions == null) return false;
        for (Definition def : definitions) {
            if (def.remote) return true;
        }
        return false;
    }

    static Map<String, String> remoteValues(
            List<Definition> definitions, Map<String, String> selected) {
        return remoteValues(definitions, selected, false);
    }

    static Map<String, String> remoteValues(
            List<Definition> definitions,
            Map<String, String> selected,
            boolean includeHttpCmsFallback) {
        Map<String, String> values = new LinkedHashMap<>();
        if (definitions == null || selected == null) return values;
        for (Definition def : definitions) {
            String value = selected.get(def.dimension);
            if (value == null || value.isEmpty()) continue;
            if (def.remote) {
                values.put(def.key, value);
            } else if (includeHttpCmsFallback && allowedKey(def.dimension)) {
                String queryValue = value;
                if (def.dimension.equals("area")) {
                    queryValue =
                            queryValue
                                    .replace("中国大陆", "大陆")
                                    .replace("中国香港", "香港")
                                    .replace("中国台湾", "台湾");
                }
                values.put(def.dimension, queryValue);
            }
        }
        return values;
    }

    static boolean hasLocal(List<Definition> definitions, Map<String, String> selected) {
        return hasLocalExcluding(definitions, selected, null);
    }

    static boolean hasLocalExcluding(
            List<Definition> definitions, Map<String, String> selected, String excludedDimension) {
        if (definitions == null || selected == null) return false;
        for (Definition def : definitions) {
            if (excludedDimension != null && excludedDimension.equals(def.dimension)) continue;
            String value = selected.get(def.dimension);
            if (!def.remote && value != null && !value.isEmpty()) return true;
        }
        return false;
    }

    /**
     * Resolves a concrete sub-category from {@code categories} when the active category has no
     * server-side remote filter schema (e.g. MacCMS "电影" + "喜剧" -> "喜剧片", "连续剧" + "美国" ->
     * "欧美剧").
     */
    static SubCategoryMatch resolveMatchingSubCategory(
            List<Cms.Category> categories,
            String activeCategoryId,
            List<Definition> definitions,
            Map<String, String> selected) {
        if (categories == null
                || categories.size() < 2
                || activeCategoryId == null
                || activeCategoryId.isEmpty()
                || definitions == null
                || selected == null
                || selected.isEmpty()) {
            return null;
        }
        String activeName = "";
        for (Cms.Category c : categories) {
            if (c != null && activeCategoryId.equals(c.id)) {
                activeName = c.name == null ? "" : c.name.trim();
                break;
            }
        }
        String family = mediaFamily(activeName);
        for (String dim : new String[] {"class", "area"}) {
            Definition def = findDefinition(definitions, dim);
            if (def == null || def.remote) continue;
            String value = selected.get(dim);
            if (value == null || value.isEmpty()) continue;
            String label = def.labelFor(value);
            Cms.Category best = null;
            int bestScore = 0;
            for (Cms.Category candidate : categories) {
                if (candidate == null
                        || candidate.id == null
                        || candidate.id.isEmpty()
                        || candidate.id.equals(activeCategoryId)) continue;
                String cname = candidate.name == null ? "" : candidate.name.trim();
                if (cname.isEmpty()) continue;
                int score = scoreSubCategoryCandidate(cname, family, dim, label);
                if (score > bestScore) {
                    bestScore = score;
                    best = candidate;
                }
            }
            if (best != null) {
                return new SubCategoryMatch(best.id, best.name, dim);
            }
        }
        return null;
    }

    private static Definition findDefinition(List<Definition> definitions, String dimension) {
        for (Definition def : definitions) {
            if (dimension.equals(def.dimension)) return def;
        }
        return null;
    }

    private static String mediaFamily(String name) {
        if (name == null) return "";
        if (name.contains("电影") || name.endsWith("片")) return "movie";
        if (name.contains("剧")) return "drama";
        if (name.contains("动漫") || name.contains("动画")) return "anime";
        if (name.contains("综艺")) return "variety";
        return "";
    }

    private static int scoreSubCategoryCandidate(
            String candidateName, String parentFamily, String dim, String label) {
        String candFamily = mediaFamily(candidateName);
        if (!parentFamily.isEmpty() && !candFamily.isEmpty() && !parentFamily.equals(candFamily)) {
            return 0;
        }
        if ("class".equals(dim)) {
            String stem = label.length() > 2 ? label.replaceAll("[片剧漫]$", "") : label;
            if (stem.length() < 2) return 0;
            if (candidateName.equals(label)) return 100;
            if ("movie".equals(parentFamily)
                    && (candidateName.equals(stem + "片") || candidateName.equals(stem + "电影"))) {
                return 95;
            }
            if ("drama".equals(parentFamily) && candidateName.equals(stem + "剧")) {
                return 95;
            }
            if (candidateName.contains(stem)) {
                return (!parentFamily.isEmpty() && parentFamily.equals(candFamily)) ? 80 : 60;
            }
            return 0;
        }
        if ("area".equals(dim)) {
            String normLabel = normalizeAreaText(label);
            String normCand = normalizeAreaText(candidateName);
            if (normCand.equals(normLabel)) return 100;
            if (normCand.contains(normLabel)) {
                return (!parentFamily.isEmpty() && parentFamily.equals(candFamily)) ? 90 : 55;
            }
        }
        return 0;
    }

    /**
     * Detects when a remote source returned the exact same video ID sequence as the cached
     * unfiltered first page, proving it ignored the sent filter parameters.
     */
    static boolean isIdenticalListing(List<Cms.Video> unfiltered, List<Cms.Video> filtered) {
        if (unfiltered == null || filtered == null) return false;
        if (unfiltered.size() < 4 || unfiltered.size() != filtered.size()) return false;
        for (int i = 0; i < unfiltered.size(); i++) {
            Cms.Video a = unfiltered.get(i);
            Cms.Video b = filtered.get(i);
            String idA = a == null || a.id == null ? "" : a.id;
            String idB = b == null || b.id == null ? "" : b.id;
            if (idA.isEmpty() || !idA.equals(idB)) return false;
        }
        return true;
    }

    /**
     * Checks whether a remote source actually honored selected metadata filters (`year`, `area`,
     * `class`). When cards omit metadata we still trust the source (`true`); only when multiple
     * cards expose explicit metadata and zero match the requested filter do we return `false`.
     */
    static boolean looksSourceHonored(
            List<Cms.Video> videos, List<Definition> definitions, Map<String, String> selected) {
        if (videos == null
                || videos.isEmpty()
                || definitions == null
                || selected == null
                || selected.isEmpty()) {
            return true;
        }
        for (Definition def : definitions) {
            String value = selected.get(def.dimension);
            if (value == null || value.isEmpty()) continue;
            if (!"year".equals(def.dimension)
                    && !"area".equals(def.dimension)
                    && !"class".equals(def.dimension)) {
                continue;
            }
            String label = def.labelFor(value);
            int explicitCount = 0;
            int matchCount = 0;
            for (Cms.Video v : videos) {
                if (v == null) continue;
                String field =
                        "year".equals(def.dimension)
                                ? v.year
                                : "area".equals(def.dimension) ? v.area : v.genre;
                boolean hasExplicit =
                        "class".equals(def.dimension)
                                ? meaningfulGenre(field)
                                : (field != null && !field.trim().isEmpty());
                if (!hasExplicit) continue;
                explicitCount++;
                if (matches(field, label, def.dimension)) matchCount++;
            }
            if (explicitCount >= 3 && matchCount == 0) {
                return false;
            }
        }
        return true;
    }

    static List<Cms.Video> apply(
            List<Cms.Video> videos, List<Definition> definitions, Map<String, String> selected) {
        return applyInternal(videos, definitions, selected, false, null);
    }

    static List<Cms.Video> applyExcluding(
            List<Cms.Video> videos,
            List<Definition> definitions,
            Map<String, String> selected,
            String excludedDimension) {
        return applyInternal(videos, definitions, selected, false, excludedDimension);
    }

    /**
     * Applies local metadata filtering even for dimensions marked {@code remote=true}, used as a
     * verified fallback when the remote server/spider ignored the requested filter parameters.
     */
    static List<Cms.Video> applyAll(
            List<Cms.Video> videos,
            List<Definition> definitions,
            Map<String, String> selected,
            String excludedDimension) {
        return applyInternal(videos, definitions, selected, true, excludedDimension);
    }

    private static List<Cms.Video> applyInternal(
            List<Cms.Video> videos,
            List<Definition> definitions,
            Map<String, String> selected,
            boolean includeRemoteMetadataDims,
            String excludedDimension) {
        List<Cms.Video> result = new ArrayList<>();
        if (videos == null) return result;
        for (Cms.Video video : videos) {
            boolean match = true;
            if (definitions != null && selected != null) {
                for (Definition def : definitions) {
                    if (excludedDimension != null && excludedDimension.equals(def.dimension))
                        continue;
                    String value = selected.get(def.dimension);
                    if (value == null || value.isEmpty()) continue;
                    if (def.remote) {
                        if (!includeRemoteMetadataDims) continue;
                        if (!"class".equals(def.dimension)
                                && !"area".equals(def.dimension)
                                && !"year".equals(def.dimension)) {
                            continue;
                        }
                    }
                    if (!matchesVideo(video, def.labelFor(value), def.dimension)) {
                        match = false;
                        break;
                    }
                }
            }
            if (match) result.add(video);
        }
        return result;
    }

    static boolean hasAnyFilterableMetadata(List<Cms.Video> videos) {
        if (videos == null) return false;
        for (Cms.Video v : videos) {
            if (v == null) continue;
            if ((v.year != null && !v.year.trim().isEmpty())
                    || (v.area != null && !v.area.trim().isEmpty())
                    || meaningfulGenre(v.genre)) {
                return true;
            }
        }
        return false;
    }

    private static boolean meaningfulGenre(String raw) {
        if (raw == null) return false;
        String cleaned =
                raw.replace("电影", "")
                        .replace("电视剧", "")
                        .replace("连续剧", "")
                        .replace("剧集", "")
                        .replace("综艺", "")
                        .replace("动漫", "")
                        .replace("影视", "")
                        .replaceAll("[ /、,，;；|]+", "")
                        .trim();
        return !cleaned.isEmpty();
    }

    private static String joinFields(String... parts) {
        StringBuilder sb = new StringBuilder();
        for (String p : parts) {
            if (p != null && !p.trim().isEmpty()) {
                if (sb.length() > 0) sb.append(' ');
                sb.append(p.trim());
            }
        }
        return sb.toString();
    }

    static boolean matchesVideo(Cms.Video video, String label, String dimension) {
        if (video == null) return false;
        if (dimension.equals("year")) {
            if (video.year != null && !video.year.trim().isEmpty()) {
                return matches(video.year, label, "year");
            }
            return matches(joinFields(video.remarks, video.tag, video.title), label, "year");
        }
        if (dimension.equals("area")) {
            if (video.area != null && !video.area.trim().isEmpty()) {
                return matches(video.area, label, "area");
            }
            return matches(
                    joinFields(video.remarks, video.tag, video.description, video.title),
                    label,
                    "area");
        }
        if (meaningfulGenre(video.genre)) {
            return matches(video.genre, label, "class")
                    || matches(joinFields(video.tag, video.remarks), label, "class");
        }
        return matches(
                joinFields(video.genre, video.tag, video.remarks, video.description, video.title),
                label,
                "class");
    }

    private static String normalizeAreaText(String s) {
        return s.replace("中国大陆", "大陆")
                .replace("内地", "大陆")
                .replace("国产", "大陆")
                .replace("国语", "大陆")
                .replace("普通话", "大陆")
                .replace("中国香港", "香港")
                .replace("港剧", "香港")
                .replace("港片", "香港")
                .replace("粤语", "香港")
                .replace("中国台湾", "台湾")
                .replace("台剧", "台湾")
                .replace("欧美", "美国")
                .replace("好莱坞", "美国")
                .replace("美剧", "美国")
                .replace("韩剧", "韩国")
                .replace("韩语", "韩国")
                .replace("日剧", "日本")
                .replace("日语", "日本")
                .replace("日漫", "日本")
                .replace("英剧", "英国")
                .replace("泰剧", "泰国");
    }

    static boolean matches(String raw, String value, String dimension) {
        if (raw == null || raw.trim().isEmpty() || value == null || value.trim().isEmpty())
            return false;
        if (dimension.equals("area")) {
            raw = normalizeAreaText(raw);
            value = normalizeAreaText(value);
        }
        if (dimension.equals("year"))
            return raw.matches(
                    ".*(?<![0-9])" + java.util.regex.Pattern.quote(value) + "(?![0-9]).*");
        String lowerRaw = raw.toLowerCase(Locale.ROOT);
        String lowerVal = value.toLowerCase(Locale.ROOT);
        if (lowerRaw.contains(lowerVal)) return true;
        if (dimension.equals("class") && lowerVal.length() > 2) {
            String stem = lowerVal.replaceAll("[片剧漫]$", "");
            if (stem.length() >= 2 && lowerRaw.contains(stem)) return true;
        }
        return false;
    }
}
