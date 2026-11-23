// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.content.Context;
import android.content.SharedPreferences;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Persistent customization store for TV top/side navigation module ordering and display names.
 * Stored in a dedicated {@link SharedPreferences} file ({@value #PREF_FILE}) so {@link Prefs#KEYS}
 * remains strictly invariant.
 */
final class TvNavConfig {
    static final String PREF_FILE = "tv_nav_custom";
    static final String KEY_CONFIG_JSON = "nav_modules_v1";
    static final int MAX_LABEL_LEN = 8;

    static final class Module {
        final String key;
        final String label;
        final String defaultLabel;
        final int iconKind;

        Module(String key, String label, String defaultLabel, int iconKind) {
            this.key = key;
            this.label = label;
            this.defaultLabel = defaultLabel;
            this.iconKind = iconKind;
        }

        boolean isCustomizedName() {
            return !label.equals(defaultLabel);
        }
    }

    private static final String[] CANONICAL_KEYS = {
        "nav-home",
        "nav-search",
        "nav-history",
        "nav-live",
        "nav-favorites",
        "nav-accounts",
        "nav-cast",
        "nav-settings"
    };

    private static final String[] CANONICAL_LABELS = {
        "首页", "搜索", "历史", "直播", "我的", "网盘", "投屏", "设置"
    };

    private static final int[] CANONICAL_ICONS = {
        HomeDock.ICON_HOME,
        HomeDock.ICON_SEARCH,
        HomeDock.ICON_HISTORY,
        HomeDock.ICON_LIVE,
        HomeDock.ICON_FAVORITE,
        HomeDock.ICON_ACCOUNT,
        HomeDock.ICON_CAST,
        HomeDock.ICON_SETTINGS
    };

    private TvNavConfig() {}

    static List<Module> defaultModules() {
        List<Module> out = new ArrayList<>(CANONICAL_KEYS.length);
        for (int i = 0; i < CANONICAL_KEYS.length; i++) {
            out.add(
                    new Module(
                            CANONICAL_KEYS[i],
                            CANONICAL_LABELS[i],
                            CANONICAL_LABELS[i],
                            CANONICAL_ICONS[i]));
        }
        return out;
    }

    private static int canonicalIndex(String key) {
        if (key == null) return -1;
        for (int i = 0; i < CANONICAL_KEYS.length; i++) {
            if (CANONICAL_KEYS[i].equals(key)) return i;
        }
        return -1;
    }

    static String sanitizeLabel(String raw, String fallback) {
        String def = fallback == null ? "" : fallback;
        if (raw == null) return def;
        String cleaned =
                raw.replaceAll("[\\p{Cntrl}\\r\\n\\t]+", " ").replaceAll("\\s+", " ").trim();
        if (cleaned.isEmpty()) return def;
        if (cleaned.length() > MAX_LABEL_LEN) {
            cleaned = cleaned.substring(0, MAX_LABEL_LEN).trim();
        }
        return cleaned.isEmpty() ? def : cleaned;
    }

    static List<Module> normalize(List<String> orderedKeys, Map<String, String> customLabels) {
        List<Module> out = new ArrayList<>(CANONICAL_KEYS.length);
        Set<String> seen = new LinkedHashSet<>();
        if (orderedKeys != null) {
            for (String rawKey : orderedKeys) {
                int idx = canonicalIndex(rawKey);
                if (idx < 0 || !seen.add(CANONICAL_KEYS[idx])) continue;
                String def = CANONICAL_LABELS[idx];
                String lbl =
                        customLabels != null
                                ? sanitizeLabel(customLabels.get(CANONICAL_KEYS[idx]), def)
                                : def;
                out.add(new Module(CANONICAL_KEYS[idx], lbl, def, CANONICAL_ICONS[idx]));
            }
        }
        for (int i = 0; i < CANONICAL_KEYS.length; i++) {
            if (seen.add(CANONICAL_KEYS[i])) {
                String def = CANONICAL_LABELS[i];
                String lbl =
                        customLabels != null
                                ? sanitizeLabel(customLabels.get(CANONICAL_KEYS[i]), def)
                                : def;
                out.add(new Module(CANONICAL_KEYS[i], lbl, def, CANONICAL_ICONS[i]));
            }
        }
        return out;
    }

    static List<Module> move(List<Module> current, int fromIndex, int toIndex) {
        List<Module> copy = new ArrayList<>(current == null ? defaultModules() : current);
        if (copy.isEmpty()) return defaultModules();
        int from = Math.max(0, Math.min(copy.size() - 1, fromIndex));
        int to = Math.max(0, Math.min(copy.size() - 1, toIndex));
        if (from == to) return copy;
        Module item = copy.remove(from);
        copy.add(to, item);
        return copy;
    }

    static List<Module> rename(List<Module> current, String key, String newLabel) {
        List<Module> source = current == null ? defaultModules() : current;
        List<Module> out = new ArrayList<>(source.size());
        for (Module m : source) {
            if (m.key.equals(key)) {
                out.add(
                        new Module(
                                m.key,
                                sanitizeLabel(newLabel, m.defaultLabel),
                                m.defaultLabel,
                                m.iconKind));
            } else {
                out.add(m);
            }
        }
        return out;
    }

    static boolean isDefault(List<Module> modules) {
        if (modules == null || modules.size() != CANONICAL_KEYS.length) return true;
        for (int i = 0; i < CANONICAL_KEYS.length; i++) {
            Module m = modules.get(i);
            if (!CANONICAL_KEYS[i].equals(m.key) || !CANONICAL_LABELS[i].equals(m.label)) {
                return false;
            }
        }
        return true;
    }

    static String toJson(List<Module> modules) {
        List<Module> safe = normalizeFromModules(modules);
        JSONArray arr = new JSONArray();
        for (Module m : safe) {
            try {
                JSONObject o = new JSONObject();
                o.put("key", m.key);
                o.put("label", m.label);
                o.put("defaultLabel", m.defaultLabel);
                arr.put(o);
            } catch (JSONException ignored) {
            }
        }
        try {
            return new JSONObject().put("items", arr).toString();
        } catch (JSONException ignored) {
            return "{\"items\":[]}";
        }
    }

    private static List<Module> normalizeFromModules(List<Module> modules) {
        if (modules == null || modules.isEmpty()) return defaultModules();
        List<String> keys = new ArrayList<>(modules.size());
        Map<String, String> labels = new LinkedHashMap<>();
        for (Module m : modules) {
            if (m == null || m.key == null) continue;
            keys.add(m.key);
            labels.put(m.key, m.label);
        }
        return normalize(keys, labels);
    }

    static List<Module> parseJson(String raw) {
        if (raw == null || raw.trim().isEmpty()) return defaultModules();
        try {
            JSONArray arr;
            String trimmed = raw.trim();
            if (trimmed.startsWith("[")) {
                arr = new JSONArray(trimmed);
            } else {
                JSONObject obj = new JSONObject(trimmed);
                arr = obj.optJSONArray("items");
            }
            if (arr == null || arr.length() == 0) return defaultModules();
            List<String> keys = new ArrayList<>(arr.length());
            Map<String, String> labels = new LinkedHashMap<>();
            for (int i = 0; i < arr.length(); i++) {
                JSONObject item = arr.optJSONObject(i);
                if (item == null) continue;
                String k = item.optString("key", "").trim();
                if (k.isEmpty()) continue;
                keys.add(k);
                String lbl = item.optString("label", "");
                if (!lbl.trim().isEmpty() && !labels.containsKey(k)) {
                    labels.put(k, lbl);
                }
            }
            return normalize(keys, labels);
        } catch (JSONException ignored) {
            return defaultModules();
        }
    }

    static List<Module> load(Context context) {
        if (context == null) return defaultModules();
        try {
            SharedPreferences sp = context.getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE);
            String raw = sp.getString(KEY_CONFIG_JSON, "");
            return parseJson(raw);
        } catch (Exception ignored) {
            return defaultModules();
        }
    }

    static void save(Context context, List<Module> modules) {
        if (context == null) return;
        List<Module> safe = normalizeFromModules(modules);
        SharedPreferences sp = context.getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE);
        if (isDefault(safe)) {
            sp.edit().remove(KEY_CONFIG_JSON).apply();
        } else {
            sp.edit().putString(KEY_CONFIG_JSON, toJson(safe)).apply();
        }
    }

    static void reset(Context context) {
        if (context == null) return;
        context.getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE)
                .edit()
                .remove(KEY_CONFIG_JSON)
                .apply();
    }

    static String signature(Context context) {
        if (context == null) return "";
        try {
            return context.getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE)
                    .getString(KEY_CONFIG_JSON, "");
        } catch (Exception ignored) {
            return "";
        }
    }

    static String summaryLabel(Context context) {
        List<Module> modules = load(context);
        if (isDefault(modules)) return "默认顺序与名称";
        StringBuilder sb = new StringBuilder();
        int show = Math.min(4, modules.size());
        for (int i = 0; i < show; i++) {
            if (i > 0) sb.append(" · ");
            sb.append(modules.get(i).label);
        }
        if (modules.size() > show) sb.append("…");
        return sb.toString();
    }

    static List<String> keysOf(List<Module> modules) {
        if (modules == null) return Collections.emptyList();
        List<String> out = new ArrayList<>(modules.size());
        for (Module m : modules) out.add(m.key);
        return out;
    }
}
