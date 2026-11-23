package com.pilipala.marcomovie;

import android.app.Dialog;
import android.graphics.Color;
import android.graphics.Typeface;
import android.view.*;
import android.widget.*;

/** The source chooser stays above the current screen and never creates a second navigation page. */
final class SourcePicker {
    static final String DEFAULT_GROUP = "默认分组";

    private static String profile(String origin) {
        return "source-picker:" + (origin == null ? "" : origin);
    }

    static String siteGroup(Cms.Site site) {
        if (site == null || site.group == null || site.group.trim().isEmpty()) {
            return DEFAULT_GROUP;
        }
        return site.group.trim();
    }

    static void applySiteOverride(Cms.Site site, org.json.JSONObject ov) {
        if (site == null || ov == null) return;
        if (ov.has("name")) {
            String n = ov.optString("name", "").trim();
            if (!n.isEmpty()) site.name = n;
        }
        if (ov.has("group")) {
            String g = ov.optString("group", "").trim();
            if (!g.isEmpty()) site.group = g;
        }
        if (ov.has("api")) {
            String nextApi = ov.optString("api", "").trim();
            if (!nextApi.isEmpty()) {
                site.api = nextApi;
                String lower = nextApi.toLowerCase(java.util.Locale.ROOT);
                if ((lower.startsWith("http://") || lower.startsWith("https://"))
                        && !lower.endsWith(".js")
                        && !lower.endsWith(".mjs")
                        && !lower.endsWith(".py")
                        && !lower.endsWith(".jar")
                        && site.type != 0
                        && site.type != 1
                        && site.type != 4) {
                    site.type = lower.contains("xml") ? 0 : 1;
                }
            }
        }
        if (ov.has("playUrl")) {
            site.playUrl = ov.optString("playUrl", "").trim();
            site.requiresParser = !site.playUrl.isEmpty();
        }
        if (ov.has("ext")) {
            String extStr = ov.optString("ext", "");
            String trimmed = extStr.trim();
            if (trimmed.startsWith("{") && trimmed.endsWith("}")) {
                try {
                    site.ext = new org.json.JSONObject(trimmed);
                } catch (org.json.JSONException ignored) {
                    site.ext = extStr;
                }
            } else {
                site.ext = extStr;
            }
            site.extTooLarge = extStr.length() > Cms.Site.MAX_EXT_SIZE;
        }
        if (ov.has("searchable")) {
            site.searchable = ov.optBoolean("searchable", site.searchable);
        }
    }

    static void applyEditsToConfig(Cms.Config config, org.json.JSONObject saved) {
        if (config == null || saved == null) return;
        org.json.JSONObject overrides = saved.optJSONObject("overrides");
        org.json.JSONArray order = saved.optJSONArray("order"),
                removed = saved.optJSONArray("removed");
        java.util.Map<String, Cms.Site> byKey = new java.util.LinkedHashMap<>();
        for (Cms.Site site : config.sites) {
            String id = site.siteId();
            if (overrides != null) {
                org.json.JSONObject ov = overrides.optJSONObject(id);
                if (ov == null && !id.equals(site.key)) ov = overrides.optJSONObject(site.key);
                if (ov != null) applySiteOverride(site, ov);
            }
            byKey.put(id, site);
        }
        if (removed != null) {
            for (int i = 0; i < removed.length(); i++) {
                byKey.remove(removed.optString(i));
            }
        }
        config.sites.clear();
        if (order != null) {
            for (int i = 0; i < order.length(); i++) {
                Cms.Site site = byKey.remove(order.optString(i));
                if (site != null) config.sites.add(site);
            }
        }
        config.sites.addAll(byKey.values());
    }

    static void applyEdits(MainActivity a, Cms.Config config, String origin) {
        String legacyProfile = profile(origin);
        if (!config.origin.isEmpty()) origin = config.origin;
        String currentProfile = profile(origin);
        if (!currentProfile.equals(legacyProfile)
                && !a.prefs.contains(currentProfile)
                && a.prefs.contains(legacyProfile)) {
            String old = a.prefs.getString(legacyProfile, "{}");
            a.prefs.edit().putString(currentProfile, old).remove(legacyProfile).apply();
        }
        try {
            org.json.JSONObject saved =
                    new org.json.JSONObject(a.prefs.getString(currentProfile, "{}"));
            applyEditsToConfig(config, saved);
        } catch (org.json.JSONException ignored) {
            /* Keep the imported order. */
        }
    }

    private static String activeProfileKey(MainActivity a, Cms.Config config) {
        String origin =
                (config != null && !config.origin.isEmpty()) ? config.origin : a.configOrigin;
        return profile(origin);
    }

    private static org.json.JSONObject loadSavedProfile(MainActivity a, Cms.Config config) {
        try {
            return new org.json.JSONObject(a.prefs.getString(activeProfileKey(a, config), "{}"));
        } catch (org.json.JSONException ignored) {
            return new org.json.JSONObject();
        }
    }

    private static boolean hasSiteOverride(MainActivity a, Cms.Config config, Cms.Site site) {
        org.json.JSONObject overrides = loadSavedProfile(a, config).optJSONObject("overrides");
        return overrides != null && (overrides.has(site.siteId()) || overrides.has(site.key));
    }

    private static java.util.List<String> collectGroups(Cms.Config config, boolean includePresets) {
        java.util.List<String> groups = new java.util.ArrayList<>();
        groups.add(DEFAULT_GROUP);
        if (config != null) {
            for (Cms.Site s : config.sites) {
                String g = siteGroup(s);
                if (!groups.contains(g)) groups.add(g);
            }
        }
        if (includePresets) {
            for (String preset : new String[] {"常用秒播", "4K网盘", "备用线路"}) {
                if (!groups.contains(preset)) groups.add(preset);
            }
        }
        return groups;
    }

    private static void reloadAndReopen(MainActivity a, Cms.Config config, String reopenGroup) {
        String origin =
                (config != null && !config.origin.isEmpty()) ? config.origin : a.configOrigin;
        if (config != null && config.raw != null && !config.raw.isEmpty()) {
            try {
                Cms.Config fresh = Cms.parseConfig(config.raw, origin);
                applyEdits(a, fresh, origin);
                a.closeEngines();
                a.config = fresh;
                ensureValidSelectedSite(a, fresh);
                a.back.clear();
                a.open(new MainActivity.Screen(a::home), false);
                if (reopenGroup != null) show(a, reopenGroup);
                return;
            } catch (Exception ignored) {
            }
        }
        a.closeEngines();
        if (a.config != null) ensureValidSelectedSite(a, a.config);
        a.back.clear();
        a.open(new MainActivity.Screen(a::home), false);
        if (reopenGroup != null) show(a, reopenGroup);
    }

    private static void ensureValidSelectedSite(MainActivity a, Cms.Config cfg) {
        String sel = a.prefs.getString(Prefs.SELECTED_SITE, "");
        for (Cms.Site s : cfg.sites) {
            if (s.key.equals(sel) && a.available(s)) return;
        }
        android.content.SharedPreferences.Editor ed = a.prefs.edit().remove(Prefs.SELECTED_SITE);
        for (Cms.Site s : cfg.sites) {
            if (a.available(s)) {
                ed.putString(Prefs.SELECTED_SITE, s.key);
                break;
            }
        }
        ed.apply();
    }

    static void manage(MainActivity a) {
        Cms.Config config = a.config;
        if (config == null) {
            a.notice("暂无可管理的线路");
            return;
        }
        org.json.JSONObject saved = loadSavedProfile(a, config);
        org.json.JSONArray removedArr = saved.optJSONArray("removed");
        final int removedCount = removedArr != null ? removedArr.length() : 0;
        if (config.sites.isEmpty() && removedCount == 0) {
            a.notice("暂无可管理的线路");
            return;
        }
        java.util.List<String> labels = new java.util.ArrayList<>();
        final int actionBatchGroup = config.sites.isEmpty() ? -1 : labels.size();
        if (!config.sites.isEmpty()) labels.add("▸ 批量移动线路到分组…");
        final int actionBatchDelete = config.sites.isEmpty() ? -1 : labels.size();
        if (!config.sites.isEmpty()) labels.add("▸ 批量删除多条线路…");
        final int actionRestore = removedCount > 0 ? labels.size() : -1;
        if (removedCount > 0) labels.add("↺ 恢复已删除的线路（" + removedCount + " 条）");
        final int headerCount = labels.size();
        for (int i = 0; i < config.sites.size(); i++) {
            Cms.Site s = config.sites.get(i);
            labels.add("[" + siteGroup(s) + "] " + s.name);
        }
        new AppDialog.Builder(a)
                .wrapChoices()
                .setTitle("管理线路")
                .setItems(
                        labels.toArray(new String[0]),
                        (d, index) -> {
                            if (index == actionBatchGroup) {
                                showBatchGroupDialog(a, config);
                            } else if (index == actionBatchDelete) {
                                showBatchDeleteDialog(a, config);
                            } else if (index == actionRestore) {
                                showRestoreRemovedDialog(a, config);
                            } else if (index >= headerCount) {
                                Cms.Site site = config.sites.get(index - headerCount);
                                showSiteActionMenu(a, config, site, null);
                            }
                        })
                .setNegativeButton("返回", (d, w) -> show(a))
                .show();
    }

    private static void showSiteActionMenu(
            MainActivity a, Cms.Config config, Cms.Site site, String returnGroup) {
        if (a.config != config) return;
        int index = config.sites.indexOf(site);
        boolean avail = a.available(site);
        boolean isPref = avail && SourcePreferences.isPreferred(a, site);
        boolean overridden = hasSiteOverride(a, config, site);
        java.util.List<String> items = new java.util.ArrayList<>();
        java.util.List<String> codes = new java.util.ArrayList<>();
        items.add("修改分组（当前：" + siteGroup(site) + "）");
        codes.add("group");
        items.add("编辑线路信息");
        codes.add("edit");
        if (avail) {
            items.add(isPref ? "取消默认偏好源" : "设为默认偏好源");
            codes.add("pref");
        }
        if (overridden) {
            items.add("恢复原始配置");
            codes.add("reset");
        }
        if (index >= 0) {
            items.add("移到首位");
            codes.add("top");
            items.add("上移");
            codes.add("up");
            items.add("下移");
            codes.add("down");
        }
        items.add("删除这条线路");
        codes.add("delete");

        new AppDialog.Builder(a)
                .wrapChoices()
                .setTitle(site.name)
                .setItems(
                        items.toArray(new String[0]),
                        (action, choice) -> {
                            String code = codes.get(choice);
                            if ("group".equals(code)) {
                                showGroupPickerDialog(
                                        a,
                                        config,
                                        java.util.Collections.singletonList(site),
                                        returnGroup);
                            } else if ("edit".equals(code)) {
                                showEditSiteDialog(a, config, site, returnGroup);
                            } else if ("pref".equals(code)) {
                                a.prefs
                                        .edit()
                                        .putString(
                                                Prefs.PREFERRED_SITE,
                                                isPref ? "" : SourcePreferences.identity(site))
                                        .apply();
                                a.toast(isPref ? "已取消默认偏好源" : "已设为默认偏好源");
                                if (returnGroup != null) show(a, returnGroup);
                                else manage(a);
                            } else if ("reset".equals(code)) {
                                clearSiteOverride(a, config, site, returnGroup);
                            } else if ("top".equals(code)) {
                                edit(a, config, site, 0, returnGroup);
                            } else if ("up".equals(code)) {
                                edit(a, config, site, Math.max(0, index - 1), returnGroup);
                            } else if ("down".equals(code)) {
                                edit(
                                        a,
                                        config,
                                        site,
                                        Math.min(config.sites.size() - 1, index + 1),
                                        returnGroup);
                            } else if ("delete".equals(code)) {
                                new AppDialog.Builder(a)
                                        .wrapChoices()
                                        .setTitle("删除「" + site.name + "」？")
                                        .setMessage("删除后该线路不会在刷新订阅时重现；可在「管理线路 → 恢复已删除的线路」中找回。")
                                        .setNegativeButton(
                                                "取消",
                                                (c, w) -> {
                                                    if (returnGroup != null) show(a, returnGroup);
                                                    else manage(a);
                                                })
                                        .setPositiveButton(
                                                "删除",
                                                (ok, which) ->
                                                        edit(a, config, site, -1, returnGroup))
                                        .show();
                            }
                        })
                .setNegativeButton(
                        "返回",
                        (d, w) -> {
                            if (returnGroup != null) show(a, returnGroup);
                            else manage(a);
                        })
                .show();
    }

    private static void showGroupPickerDialog(
            MainActivity a,
            Cms.Config config,
            java.util.List<Cms.Site> targetSites,
            String returnGroup) {
        if (targetSites == null || targetSites.isEmpty()) return;
        java.util.List<String> groups = collectGroups(config, true);
        String[] labels = new String[groups.size() + 1];
        for (int i = 0; i < groups.size(); i++) labels[i] = groups.get(i);
        labels[groups.size()] = "+ 新建自定义分组…";
        String title =
                targetSites.size() == 1
                        ? "修改分组 · " + targetSites.get(0).name
                        : "批量移动 " + targetSites.size() + " 条线路到分组";
        new AppDialog.Builder(a)
                .wrapChoices()
                .setTitle(title)
                .setItems(
                        labels,
                        (d, idx) -> {
                            if (idx < groups.size()) {
                                saveBatchGroupOverride(
                                        a, config, targetSites, groups.get(idx), returnGroup);
                            } else {
                                showCustomGroupInputDialog(a, config, targetSites, returnGroup);
                            }
                        })
                .setNegativeButton(
                        "取消",
                        (d, w) -> {
                            if (returnGroup != null) show(a, returnGroup);
                            else manage(a);
                        })
                .show();
    }

    private static void showCustomGroupInputDialog(
            MainActivity a,
            Cms.Config config,
            java.util.List<Cms.Site> targetSites,
            String returnGroup) {
        LinearLayout box = a.vertical();
        box.setPadding(a.dp(18), a.dp(10), a.dp(18), a.dp(6));
        EditText input = new EditText(a);
        input.setSingleLine(true);
        input.setHint("输入新分组名称（如：主力秒播）");
        input.setTextColor(Color.WHITE);
        input.setHintTextColor(0xff8e8e93);
        input.setBackground(a.bg(0x33ffffff, 10));
        input.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
        box.addView(TvQrInputHelper.wrap(a, input, "新分组名称"), new LinearLayout.LayoutParams(-1, -2));
        new AppDialog.Builder(a)
                .setTitle("新建分组")
                .setView(box)
                .setNegativeButton(
                        "取消", (d, w) -> showGroupPickerDialog(a, config, targetSites, returnGroup))
                .setPositiveButton(
                        "确定",
                        (d, w) -> {
                            String g = input.getText().toString().trim();
                            if (g.isEmpty()) {
                                a.notice("分组名称不能为空");
                                return;
                            }
                            saveBatchGroupOverride(a, config, targetSites, g, returnGroup);
                        })
                .show();
    }

    private static void saveBatchGroupOverride(
            MainActivity a,
            Cms.Config config,
            java.util.List<Cms.Site> targetSites,
            String newGroup,
            String returnGroup) {
        if (a.config != config) return;
        String clean = newGroup == null ? "" : newGroup.trim();
        if (clean.isEmpty()) return;
        try {
            String key = activeProfileKey(a, config);
            org.json.JSONObject saved = loadSavedProfile(a, config);
            org.json.JSONObject overrides = saved.optJSONObject("overrides");
            if (overrides == null) overrides = new org.json.JSONObject();
            for (Cms.Site s : targetSites) {
                String id = s.siteId();
                org.json.JSONObject ov = overrides.optJSONObject(id);
                if (ov == null) ov = new org.json.JSONObject();
                ov.put("group", clean);
                overrides.put(id, ov);
                s.group = clean;
            }
            saved.put("overrides", overrides);
            a.prefs.edit().putString(key, saved.toString()).apply();
            a.toast("已移至分组：" + clean);
            if (returnGroup != null) show(a, clean);
            else manage(a);
        } catch (org.json.JSONException e) {
            a.notice("分组未能保存");
        }
    }

    private static void clearSiteOverride(
            MainActivity a, Cms.Config config, Cms.Site site, String returnGroup) {
        if (a.config != config) return;
        String key = activeProfileKey(a, config);
        org.json.JSONObject saved = loadSavedProfile(a, config);
        org.json.JSONObject overrides = saved.optJSONObject("overrides");
        if (overrides != null) {
            overrides.remove(site.siteId());
            overrides.remove(site.key);
        }
        a.prefs.edit().putString(key, saved.toString()).apply();
        a.toast("已恢复原始线路配置");
        reloadAndReopen(a, config, returnGroup != null ? returnGroup : "全部");
    }

    private static void showEditSiteDialog(
            MainActivity a, Cms.Config config, Cms.Site site, String returnGroup) {
        if (a.config != config) return;
        ScrollView scroll = new TvScrollView(a);
        LinearLayout form = a.vertical();
        form.setPadding(a.dp(18), a.dp(8), a.dp(18), a.dp(8));
        scroll.addView(form);

        EditText nameInput = addLabeledInput(a, form, "线路名称", site.name, "输入线路显示名称");
        EditText groupInput = addLabeledInput(a, form, "所属分组", siteGroup(site), DEFAULT_GROUP);
        HorizontalScrollView grpScroll = new HorizontalScrollView(a);
        grpScroll.setHorizontalScrollBarEnabled(false);
        LinearLayout grpRow = a.row();
        grpScroll.addView(grpRow);
        for (String g : collectGroups(config, true)) {
            Button chip =
                    a.button(
                            g,
                            null,
                            () -> {
                                groupInput.setText(g);
                                groupInput.setSelection(g.length());
                            });
            chip.setTextSize(11.5f);
            chip.setPadding(a.dp(10), a.dp(2), a.dp(10), a.dp(2));
            chip.setMinHeight(a.dp(28));
            chip.setMinimumHeight(a.dp(28));
            LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(-2, a.dp(28));
            clp.setMargins(0, a.dp(4), a.dp(6), a.dp(4));
            grpRow.addView(chip, clp);
        }
        form.addView(grpScroll, new LinearLayout.LayoutParams(-1, -2));

        EditText apiInput =
                addLabeledInput(a, form, "接口地址 / Spider API", site.api, "https://… 或 csp_…");
        EditText playUrlInput =
                addLabeledInput(
                        a,
                        form,
                        "解析地址 PlayUrl（可选）",
                        site.playUrl == null ? "" : site.playUrl,
                        "留空使用直连或全局解析");
        String extInitial = site.ext == null ? "" : String.valueOf(site.ext);
        EditText extInput =
                addLabeledInput(a, form, "扩展参数 Ext（可选）", extInitial, "自定义扩展参数或规则地址", true);

        CheckBox searchableCheck = new CheckBox(a);
        searchableCheck.setText("允许参与全站聚合搜索");
        searchableCheck.setTextColor(Color.WHITE);
        searchableCheck.setChecked(site.searchable);
        LinearLayout.LayoutParams chkLp = new LinearLayout.LayoutParams(-1, -2);
        chkLp.topMargin = a.dp(8);
        form.addView(searchableCheck, chkLp);

        AppDialog.Builder builder =
                new AppDialog.Builder(a)
                        .setTitle("编辑线路 · " + site.name)
                        .setView(scroll)
                        .setNegativeButton(
                                "取消",
                                (d, w) -> {
                                    if (returnGroup != null) show(a, returnGroup);
                                    else manage(a);
                                })
                        .setPositiveButton(
                                "保存修改",
                                (d, w) -> {
                                    String newName = nameInput.getText().toString().trim();
                                    String newGroup = groupInput.getText().toString().trim();
                                    if (newGroup.isEmpty()) newGroup = DEFAULT_GROUP;
                                    String newApi = apiInput.getText().toString().trim();
                                    String newPlayUrl = playUrlInput.getText().toString().trim();
                                    String newExt = extInput.getText().toString();
                                    boolean newSearchable = searchableCheck.isChecked();
                                    if (newName.isEmpty() || newApi.isEmpty()) {
                                        a.notice("线路名称与接口地址不能为空");
                                        return;
                                    }
                                    try {
                                        String key = activeProfileKey(a, config);
                                        org.json.JSONObject saved = loadSavedProfile(a, config);
                                        org.json.JSONObject overrides =
                                                saved.optJSONObject("overrides");
                                        if (overrides == null)
                                            overrides = new org.json.JSONObject();
                                        org.json.JSONObject ov = new org.json.JSONObject();
                                        ov.put("name", newName);
                                        ov.put("group", newGroup);
                                        ov.put("api", newApi);
                                        ov.put("playUrl", newPlayUrl);
                                        ov.put("ext", newExt);
                                        ov.put("searchable", newSearchable);
                                        overrides.put(site.siteId(), ov);
                                        saved.put("overrides", overrides);
                                        a.prefs.edit().putString(key, saved.toString()).apply();
                                        applySiteOverride(site, ov);
                                        synchronized (a) {
                                            SourceEngine old = a.engines.remove(site.key);
                                            if (old != null) {
                                                a.worker.execute(
                                                        () -> {
                                                            try {
                                                                old.close();
                                                            } catch (Exception ignored) {
                                                            }
                                                        });
                                            }
                                        }
                                        a.toast("已保存线路修改");
                                        reloadAndReopen(
                                                a,
                                                config,
                                                returnGroup != null ? returnGroup : null);
                                        if (returnGroup == null) manage(a);
                                    } catch (org.json.JSONException e) {
                                        a.notice("无法保存线路修改");
                                    }
                                });
        if (hasSiteOverride(a, config, site)) {
            builder.setNeutralButton(
                    "恢复原始", (d, w) -> clearSiteOverride(a, config, site, returnGroup));
        }
        builder.show();
    }

    private static EditText addLabeledInput(
            MainActivity a, LinearLayout parent, String label, String value, String hint) {
        return addLabeledInput(a, parent, label, value, hint, false);
    }

    private static EditText addLabeledInput(
            MainActivity a,
            LinearLayout parent,
            String label,
            String value,
            String hint,
            boolean multiline) {
        TextView tv = a.text(label, 12, MainActivity.MUTED);
        tv.setPadding(0, a.dp(8), 0, a.dp(4));
        parent.addView(tv);
        EditText input = new EditText(a);
        if (multiline) {
            input.setSingleLine(false);
            input.setMaxLines(3);
        } else {
            input.setSingleLine(true);
        }
        input.setText(value == null ? "" : value);
        input.setHint(hint);
        input.setTextColor(Color.WHITE);
        input.setHintTextColor(0xff8e8e93);
        input.setTextSize(13.5f);
        input.setBackground(a.bg(0x2effffff, 10));
        input.setPadding(a.dp(12), a.dp(8), a.dp(12), a.dp(8));
        parent.addView(
                TvQrInputHelper.wrap(a, input, label, multiline, false, false, null),
                new LinearLayout.LayoutParams(-1, -2));
        return input;
    }

    private static View buildMultiSelectListView(
            MainActivity a, String[] labels, boolean[] checked) {
        LinearLayout listBox = a.vertical();
        Button[] rowButtons = new Button[labels.length];
        LinearLayout quickOps = new LinearLayout(a);
        quickOps.setOrientation(LinearLayout.HORIZONTAL);
        Button selectAll =
                a.button(
                        "全选",
                        "batch-select-all",
                        () -> {
                            for (int i = 0; i < checked.length; i++) {
                                checked[i] = true;
                                if (rowButtons[i] != null) {
                                    rowButtons[i].setText("☑  " + labels[i]);
                                }
                            }
                        });
        Button clearAll =
                a.button(
                        "清空",
                        "batch-clear-all",
                        () -> {
                            for (int i = 0; i < checked.length; i++) {
                                checked[i] = false;
                                if (rowButtons[i] != null) {
                                    rowButtons[i].setText("☐  " + labels[i]);
                                }
                            }
                        });
        LinearLayout.LayoutParams qlp1 = new LinearLayout.LayoutParams(0, a.dp(38), 1f);
        qlp1.rightMargin = a.dp(8);
        quickOps.addView(selectAll, qlp1);
        quickOps.addView(clearAll, new LinearLayout.LayoutParams(0, a.dp(38), 1f));
        listBox.addView(quickOps, new LinearLayout.LayoutParams(-1, -2));
        a.gap(listBox, 8);
        for (int i = 0; i < labels.length; i++) {
            final int idx = i;
            final Button itemBtn =
                    a.button(
                            (checked[idx] ? "☑  " : "☐  ") + labels[idx],
                            "batch-option:" + idx,
                            null);
            itemBtn.setOnClickListener(
                    v -> {
                        checked[idx] = !checked[idx];
                        itemBtn.setText((checked[idx] ? "☑  " : "☐  ") + labels[idx]);
                    });
            itemBtn.setGravity(Gravity.CENTER_VERTICAL | Gravity.START);
            itemBtn.setPadding(a.dp(14), a.dp(8), a.dp(14), a.dp(8));
            itemBtn.setTextSize(14f);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, a.dp(44));
            lp.bottomMargin = a.dp(6);
            rowButtons[idx] = itemBtn;
            listBox.addView(itemBtn, lp);
        }
        return listBox;
    }

    private static void showBatchGroupDialog(MainActivity a, Cms.Config config) {
        showBatchGroupDialog(a, config, null);
    }

    private static void showBatchGroupDialog(
            MainActivity a, Cms.Config config, String returnGroup) {
        if (config.sites.isEmpty()) return;
        String[] labels = new String[config.sites.size()];
        final boolean[] checked = new boolean[config.sites.size()];
        for (int i = 0; i < config.sites.size(); i++) {
            Cms.Site s = config.sites.get(i);
            labels[i] = "[" + siteGroup(s) + "] " + s.name;
        }
        new AppDialog.Builder(a)
                .setTitle("勾选要分组的线路")
                .setView(buildMultiSelectListView(a, labels, checked))
                .setNegativeButton(
                        "取消",
                        (d, w) -> {
                            if (returnGroup != null) show(a, returnGroup);
                            else manage(a);
                        })
                .setPositiveButton(
                        "选择分组",
                        (d, w) -> {
                            java.util.List<Cms.Site> chosen = new java.util.ArrayList<>();
                            for (int i = 0; i < checked.length; i++) {
                                if (checked[i]) chosen.add(config.sites.get(i));
                            }
                            if (chosen.isEmpty()) {
                                a.notice("请至少勾选一条线路");
                                return;
                            }
                            showGroupPickerDialog(a, config, chosen, returnGroup);
                        })
                .show();
    }

    private static void showBatchDeleteDialog(MainActivity a, Cms.Config config) {
        if (config.sites.isEmpty()) return;
        String[] labels = new String[config.sites.size()];
        final boolean[] checked = new boolean[config.sites.size()];
        for (int i = 0; i < config.sites.size(); i++) {
            Cms.Site s = config.sites.get(i);
            labels[i] = "[" + siteGroup(s) + "] " + s.name;
        }
        new AppDialog.Builder(a)
                .setTitle("勾选要删除的线路")
                .setView(buildMultiSelectListView(a, labels, checked))
                .setNegativeButton("取消", (d, w) -> manage(a))
                .setPositiveButton(
                        "删除所选",
                        (d, w) -> {
                            java.util.List<Cms.Site> chosen = new java.util.ArrayList<>();
                            for (int i = 0; i < checked.length; i++) {
                                if (checked[i]) chosen.add(config.sites.get(i));
                            }
                            if (chosen.isEmpty()) {
                                a.notice("请至少勾选一条线路");
                                return;
                            }
                            removeSitesBatch(a, config, chosen);
                        })
                .show();
    }

    private static void removeSitesBatch(
            MainActivity a, Cms.Config config, java.util.List<Cms.Site> toRemove) {
        if (a.config != config || toRemove.isEmpty()) return;
        try {
            String key = activeProfileKey(a, config);
            org.json.JSONObject saved = loadSavedProfile(a, config);
            org.json.JSONArray hidden = saved.optJSONArray("removed");
            if (hidden == null) hidden = new org.json.JSONArray();
            java.util.Set<String> hiddenSet = new java.util.LinkedHashSet<>();
            for (int i = 0; i < hidden.length(); i++) hiddenSet.add(hidden.optString(i));
            GlobalSearchScreen.invalidateContext(a);
            for (Cms.Site s : toRemove) {
                hiddenSet.add(s.siteId());
                config.sites.remove(s);
            }
            org.json.JSONArray nextHidden = new org.json.JSONArray();
            for (String id : hiddenSet) nextHidden.put(id);
            saved.put("removed", nextHidden);
            org.json.JSONArray order = new org.json.JSONArray();
            for (Cms.Site s : config.sites) order.put(s.siteId());
            saved.put("order", order);
            a.prefs.edit().putString(key, saved.toString()).apply();
            ensureValidSelectedSite(a, config);
            a.back.clear();
            a.open(new MainActivity.Screen(a::home), false);
            a.toast("已删除 " + toRemove.size() + " 条线路");
            manage(a);
        } catch (org.json.JSONException e) {
            a.notice("无法保存删除操作");
        }
    }

    private static void showRestoreRemovedDialog(MainActivity a, Cms.Config config) {
        org.json.JSONObject saved = loadSavedProfile(a, config);
        org.json.JSONArray removed = saved.optJSONArray("removed");
        if (removed == null || removed.length() == 0) {
            a.notice("没有已删除的线路");
            return;
        }
        java.util.Map<String, String> nameById = new java.util.LinkedHashMap<>();
        if (config.raw != null && !config.raw.isEmpty()) {
            try {
                String origin = !config.origin.isEmpty() ? config.origin : a.configOrigin;
                Cms.Config rawParsed = Cms.parseConfig(config.raw, origin);
                for (Cms.Site s : rawParsed.sites) nameById.put(s.siteId(), s.name);
            } catch (Exception ignored) {
            }
        }
        final java.util.List<String> ids = new java.util.ArrayList<>();
        for (int i = 0; i < removed.length(); i++) {
            String id = removed.optString(i);
            if (!id.isEmpty()) ids.add(id);
        }
        String[] labels = new String[ids.size() + 1];
        labels[0] = "↺ 全部恢复（共 " + ids.size() + " 条）";
        for (int i = 0; i < ids.size(); i++) {
            String id = ids.get(i);
            String title = nameById.containsKey(id) ? nameById.get(id) : id;
            labels[i + 1] = "恢复 · " + title;
        }
        new AppDialog.Builder(a)
                .wrapChoices()
                .setTitle("恢复已删除的线路")
                .setItems(
                        labels,
                        (d, idx) -> {
                            String key = activeProfileKey(a, config);
                            if (idx == 0) {
                                saved.remove("removed");
                            } else {
                                String restoreId = ids.get(idx - 1);
                                org.json.JSONArray next = new org.json.JSONArray();
                                for (String id : ids) {
                                    if (!id.equals(restoreId)) next.put(id);
                                }
                                try {
                                    saved.put("removed", next);
                                } catch (org.json.JSONException ignored) {
                                }
                            }
                            a.prefs.edit().putString(key, saved.toString()).apply();
                            a.toast("已恢复线路");
                            reloadAndReopen(a, config, "全部");
                        })
                .setNegativeButton("返回", (d, w) -> manage(a))
                .show();
    }

    private static void edit(
            MainActivity a, Cms.Config config, Cms.Site site, int target, String reopenGroup) {
        if (a.config != config) return;
        try {
            String key = activeProfileKey(a, config);
            org.json.JSONObject saved = loadSavedProfile(a, config);
            java.util.List<Cms.Site> sites = new java.util.ArrayList<>(config.sites);
            sites.remove(site);
            if (target >= 0) sites.add(target, site);
            else {
                org.json.JSONArray hidden = saved.optJSONArray("removed");
                if (hidden == null) hidden = new org.json.JSONArray();
                saved.put("removed", hidden.put(site.siteId()));
            }
            org.json.JSONArray order = new org.json.JSONArray();
            for (Cms.Site s : sites) order.put(s.siteId());
            saved.put("order", order);
            android.content.SharedPreferences.Editor editor =
                    a.prefs.edit().putString(key, saved.toString());
            if (target < 0 && site.key.equals(a.prefs.getString(Prefs.SELECTED_SITE, ""))) {
                editor.remove(Prefs.SELECTED_SITE);
                for (Cms.Site s : sites)
                    if (a.available(s)) {
                        editor.putString(Prefs.SELECTED_SITE, s.key);
                        break;
                    }
            }
            editor.apply();
            GlobalSearchScreen.invalidateContext(a);
            config.sites.clear();
            config.sites.addAll(sites);
            a.back.clear();
            a.open(new MainActivity.Screen(a::home), false);
            if (reopenGroup != null) show(a, reopenGroup);
            else manage(a);
        } catch (org.json.JSONException e) {
            a.notice("无法保存线路顺序");
        }
    }

    private static void commitSelectedSiteForCrashGuard(MainActivity a, String siteKey) {
        if (a == null || a.prefs == null) return;
        a.prefs
                .edit()
                .putString(Prefs.SELECTED_SITE, siteKey)
                .putString(Prefs.LOADING_SITE, siteKey)
                .commit();
    }

    static void show(MainActivity a) {
        show(a, "全部");
    }

    static void show(MainActivity a, String requestedGroup) {
        if (a.config == null) {
            a.importDialog();
            return;
        }
        View anchor = a.getCurrentFocus();
        Dialog dialog = new Dialog(a);
        a.sourceDialog = dialog;
        dialog.setOnDismissListener(
                d -> {
                    if (a.sourceDialog == dialog) a.sourceDialog = null;
                    if (anchor != null && anchor.isAttachedToWindow()) anchor.requestFocus();
                });
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        boolean tv = a.isTvDevice();
        LinearLayout panel = a.vertical();
        panel.setTag("source-picker");
        panel.setPadding(
                a.dp(tv ? 22 : 16), a.dp(tv ? 18 : 16), a.dp(tv ? 22 : 16), a.dp(tv ? 16 : 14));
        a.glass(panel, 22);

        LinearLayout headerRow = a.row();
        headerRow.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout titleCol = a.vertical();
        LinearLayout titleBadgeRow = a.row();
        titleBadgeRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView title = a.text("选择片源", tv ? 22 : 19, MainActivity.WHITE);
        title.setTypeface(null, Typeface.BOLD);
        titleBadgeRow.addView(title);
        int supported = 0;
        for (Cms.Site s : a.config.sites) if (a.available(s)) supported++;
        TextView count =
                a.text("可用 " + supported + " / 共 " + a.config.sites.size(), 11.5f, 0xff9ca3af);
        count.setPadding(a.dp(8), a.dp(2), a.dp(8), a.dp(2));
        count.setBackground(a.bg(0x22ffffff, 999));
        LinearLayout.LayoutParams countLp = new LinearLayout.LayoutParams(-2, -2);
        countLp.leftMargin = a.dp(8);
        titleBadgeRow.addView(count, countLp);
        titleCol.addView(titleBadgeRow);
        TextView hint =
                a.text(
                        tv ? "确认键切换 · 菜单键/长按可分组、编辑或删除单条线路" : "点击切换 · 长按线路可分组、编辑或删除单条线路",
                        12,
                        MainActivity.MUTED);
        hint.setPadding(0, a.dp(2), 0, 0);
        titleCol.addView(hint);
        headerRow.addView(titleCol, new LinearLayout.LayoutParams(0, -2, 1f));

        boolean hasExtraTopActions = a.config.depots.length() > 0 || CatPawSettings.available(a);
        Button prefBtn =
                a.navButton(
                        "默认偏好源",
                        "source-preferred",
                        () -> {
                            dialog.dismiss();
                            SourcePreferences.choose(a);
                        });
        prefBtn.setTextSize(12.5f);
        prefBtn.setPadding(a.dp(12), a.dp(4), a.dp(12), a.dp(4));
        prefBtn.setMinHeight(a.dp(34));
        prefBtn.setMinimumHeight(a.dp(34));
        if (!hasExtraTopActions) {
            headerRow.addView(prefBtn, new LinearLayout.LayoutParams(-2, a.dp(34)));
        }
        panel.addView(headerRow, new LinearLayout.LayoutParams(-1, -2));

        if (hasExtraTopActions) {
            a.gap(panel, 8);
            LinearLayout topActions = a.row();
            if (a.config.depots.length() > 0) {
                Button depotBtn =
                        a.navButton(
                                "切换子仓库",
                                "warehouse-switch",
                                () -> {
                                    dialog.dismiss();
                                    showWarehouses(a);
                                });
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, a.dp(34), 1);
                lp.rightMargin = a.dp(6);
                topActions.addView(depotBtn, lp);
            }
            LinearLayout.LayoutParams prefLp = new LinearLayout.LayoutParams(0, a.dp(34), 1);
            if (CatPawSettings.available(a)) prefLp.rightMargin = a.dp(6);
            topActions.addView(prefBtn, prefLp);
            if (CatPawSettings.available(a)) {
                Button catBtn =
                        a.navButton(
                                "CatPaw 配置",
                                "catpaw-settings",
                                () -> {
                                    dialog.dismiss();
                                    CatPawSettings.choose(a);
                                });
                topActions.addView(catBtn, new LinearLayout.LayoutParams(0, a.dp(34), 1));
            }
            panel.addView(topActions, new LinearLayout.LayoutParams(-1, -2));
        }

        java.util.List<String> filterGroups = new java.util.ArrayList<>();
        java.util.Map<String, Integer> groupCounts = new java.util.LinkedHashMap<>();
        filterGroups.add("全部");
        groupCounts.put("全部", a.config.sites.size());
        for (Cms.Site s : a.config.sites) {
            String g = siteGroup(s);
            if (!filterGroups.contains(g)) filterGroups.add(g);
            Integer prev = groupCounts.get(g);
            groupCounts.put(g, (prev == null ? 0 : prev) + 1);
        }
        final String activeGroup =
                (requestedGroup != null && filterGroups.contains(requestedGroup))
                        ? requestedGroup
                        : "全部";

        if (!a.config.sites.isEmpty()) {
            a.gap(panel, 6);
            HorizontalScrollView grpScroll = new HorizontalScrollView(a);
            grpScroll.setHorizontalScrollBarEnabled(false);
            LinearLayout grpRow = a.row();
            grpRow.setGravity(Gravity.CENTER_VERTICAL);
            grpScroll.addView(grpRow);
            for (String g : filterGroups) {
                boolean active = g.equals(activeGroup);
                int c = groupCounts.containsKey(g) ? groupCounts.get(g) : 0;
                Button pill =
                        a.button(
                                g + " " + c,
                                "source-group:" + g,
                                () -> {
                                    if (!g.equals(activeGroup)) {
                                        dialog.dismiss();
                                        show(a, g);
                                    }
                                });
                pill.setTextSize(12f);
                pill.setPadding(a.dp(12), a.dp(4), a.dp(12), a.dp(4));
                pill.setMinHeight(a.dp(30));
                pill.setMinimumHeight(a.dp(30));
                Runnable stylePill =
                        () ->
                                FocusMotion.style(
                                        a,
                                        pill,
                                        pill.hasFocus(),
                                        active ? 0xff0a84ff : 0xff262932,
                                        MainActivity.WHITE,
                                        999,
                                        MainActivity.WHITE,
                                        MainActivity.DARK,
                                        false,
                                        1.02f);
                pill.setOnFocusChangeListener((v, f) -> stylePill.run());
                stylePill.run();
                LinearLayout.LayoutParams plp = new LinearLayout.LayoutParams(-2, a.dp(30));
                plp.rightMargin = a.dp(6);
                grpRow.addView(pill, plp);
            }
            Button batchGrpBtn =
                    a.button(
                            "+ 批量分组",
                            "source-batch-group",
                            () -> {
                                dialog.dismiss();
                                showBatchGroupDialog(a, a.config, activeGroup);
                            });
            batchGrpBtn.setTextSize(12f);
            batchGrpBtn.setPadding(a.dp(12), a.dp(4), a.dp(12), a.dp(4));
            batchGrpBtn.setMinHeight(a.dp(30));
            batchGrpBtn.setMinimumHeight(a.dp(30));
            Runnable styleBatch =
                    () ->
                            FocusMotion.style(
                                    a,
                                    batchGrpBtn,
                                    batchGrpBtn.hasFocus(),
                                    0xff262932,
                                    MainActivity.WHITE,
                                    999,
                                    0xff7dd3fc,
                                    MainActivity.DARK,
                                    false,
                                    1.02f);
            batchGrpBtn.setOnFocusChangeListener((v, f) -> styleBatch.run());
            styleBatch.run();
            grpRow.addView(batchGrpBtn, new LinearLayout.LayoutParams(-2, a.dp(30)));
            panel.addView(grpScroll, new LinearLayout.LayoutParams(-1, -2));
        }

        a.gap(panel, 8);
        ScrollView scrolling = new TvScrollView(a);
        scrolling.setVerticalScrollBarEnabled(false);
        LinearLayout grid = a.vertical();
        grid.setPadding(a.dp(2), a.dp(2), a.dp(2), a.dp(2));
        scrolling.addView(grid);
        FrameLayout viewport =
                new FrameLayout(a) {
                    @Override
                    protected void dispatchDraw(android.graphics.Canvas c) {
                        int save = c.save();
                        c.clipRect(0, 0, getWidth(), getHeight());
                        super.dispatchDraw(c);
                        c.restoreToCount(save);
                    }
                };
        viewport.setTag("scroll-viewport-clip");
        viewport.setClipChildren(true);
        viewport.setClipToPadding(true);
        viewport.addView(scrolling, new FrameLayout.LayoutParams(-1, -1));
        int defaultViewportH = a.dp(tv ? 310 : 350);
        panel.addView(viewport, new LinearLayout.LayoutParams(-1, defaultViewportH));
        String selected = a.prefs.getString(Prefs.SELECTED_SITE, "");
        Button selectedButton = null;
        LinearLayout row = null;
        float fontScale = a.getResources().getConfiguration().fontScale;
        int availWidth = Math.min(a.windowWidth(), a.dp(740)) - a.dp(tv ? 52 : 36);
        int targetColWidth = a.dp(tv ? 200 : 142);
        int columns =
                Math.max(
                        tv ? 2 : (fontScale > 1.35f ? 1 : 2),
                        Math.min(
                                3,
                                (int) (availWidth / (targetColWidth * Math.max(1f, fontScale)))));
        int index = 0;
        for (Cms.Site site : a.config.sites) {
            if (!"全部".equals(activeGroup) && !siteGroup(site).equals(activeGroup)) {
                continue;
            }
            if (index % columns == 0) {
                row = a.row();
                row.setClipChildren(false);
                grid.addView(row);
            }
            boolean current = site.key.equals(selected);
            Button button =
                    a.button(
                            (current ? "✓ " : "")
                                    + (SourcePreferences.isPreferred(a, site) ? "★ " : "")
                                    + site.name,
                            "source-choice:" + site.key,
                            () -> {
                                if (site.api.startsWith("catpaw://")
                                        && android.net.Uri.parse(site.api)
                                                .getPath()
                                                .equals("/api/baseset")) {
                                    dialog.dismiss();
                                    CatPawSettings.open(a, site);
                                    return;
                                }
                                if (!a.available(site)) {
                                    new AppDialog.Builder(a)
                                            .wrapChoices()
                                            .setTitle(site.name)
                                            .setMessage(site.limitation())
                                            .setPositiveButton("知道了", null)
                                            .setNeutralButton(
                                                    "编辑线路",
                                                    (d2, w2) -> {
                                                        dialog.dismiss();
                                                        showEditSiteDialog(
                                                                a, a.config, site, activeGroup);
                                                    })
                                            .setNegativeButton(
                                                    "删除线路",
                                                    (d2, w2) -> {
                                                        dialog.dismiss();
                                                        new AppDialog.Builder(a)
                                                                .wrapChoices()
                                                                .setTitle("删除「" + site.name + "」？")
                                                                .setNegativeButton(
                                                                        "取消",
                                                                        (c, w3) ->
                                                                                show(
                                                                                        a,
                                                                                        activeGroup))
                                                                .setPositiveButton(
                                                                        "删除",
                                                                        (ok, w3) ->
                                                                                edit(
                                                                                        a,
                                                                                        a.config,
                                                                                        site,
                                                                                        -1,
                                                                                        activeGroup))
                                                                .show();
                                                    })
                                            .show();
                                    return;
                                }
                                commitSelectedSiteForCrashGuard(a, site.key);
                                dialog.dismiss();
                                a.back.clear();
                                a.open(new MainActivity.Screen(a::home), false);
                            });
            button.setOnLongClickListener(
                    v -> {
                        dialog.dismiss();
                        showSiteActionMenu(a, a.config, site, activeGroup);
                        return true;
                    });
            button.setOnKeyListener(
                    (v, keyCode, ev) -> {
                        if (keyCode == KeyEvent.KEYCODE_MENU
                                && ev.getAction() == KeyEvent.ACTION_DOWN
                                && ev.getRepeatCount() == 0) {
                            dialog.dismiss();
                            showSiteActionMenu(a, a.config, site, activeGroup);
                            return true;
                        }
                        return false;
                    });
            button.setTextSize(tv ? 13.5f : 12.8f);
            button.setSingleLine(false);
            button.setMaxLines(2);
            button.setEllipsize(android.text.TextUtils.TruncateAt.END);
            button.setGravity(Gravity.START | Gravity.CENTER_VERTICAL);
            int cellH = a.dp(tv ? 44 : 40);
            button.setMinHeight(cellH);
            button.setMinimumHeight(cellH);
            button.setPadding(a.dp(10), a.dp(6), a.dp(10), a.dp(6));
            boolean enabled = a.available(site);
            button.setSelected(current);
            Runnable paint =
                    () -> {
                        boolean focused = button.hasFocus();
                        FocusMotion.style(
                                a,
                                button,
                                focused,
                                current ? 0xff2b384e : 0xff22252a,
                                MainActivity.WHITE,
                                11,
                                enabled
                                        ? (current ? 0xff7dd3fc : MainActivity.WHITE)
                                        : MainActivity.MUTED,
                                MainActivity.DARK,
                                false,
                                1.02f);
                    };
            button.setOnFocusChangeListener((v, f) -> paint.run());
            paint.run();
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, -2, 1);
            lp.setMargins(a.dp(3), a.dp(3), a.dp(3), a.dp(3));
            row.addView(button, lp);
            if (current) selectedButton = button;
            index++;
        }
        if (row != null)
            while (index++ % columns != 0) {
                LinearLayout.LayoutParams blankLp = new LinearLayout.LayoutParams(0, 1, 1);
                blankLp.setMargins(a.dp(3), a.dp(3), a.dp(3), a.dp(3));
                row.addView(new View(a), blankLp);
            }
        a.gap(panel, 8);
        LinearLayout footer = a.row();
        a.addButton(
                footer,
                a.navButton(
                        "已添加源",
                        "source-library",
                        () -> {
                            dialog.dismiss();
                            showSavedConfigs(a);
                        }));
        a.addButton(
                footer,
                a.navButton(
                        "管理线路",
                        "source-manage",
                        () -> {
                            dialog.dismiss();
                            manage(a);
                        }));
        a.addButton(
                footer,
                a.navButton(
                        tv ? "添加新源" : "更新配置",
                        "source-update",
                        () -> {
                            dialog.dismiss();
                            a.importDialog();
                        }));
        a.addButton(footer, a.navButton("完成", "source-close", dialog::dismiss));
        for (int i = 0; i < footer.getChildCount(); i++) {
            View control = footer.getChildAt(i);
            LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(0, a.dp(38), 1);
            params.setMargins(a.dp(3), a.dp(2), a.dp(3), a.dp(2));
            control.setLayoutParams(params);
            if (control instanceof TextView) {
                ((TextView) control).setSingleLine(true);
                ((TextView) control).setEllipsize(android.text.TextUtils.TruncateAt.END);
                ((TextView) control).setTextSize(13);
                control.setPadding(a.dp(8), 0, a.dp(8), 0);
            }
        }
        panel.addView(footer, new LinearLayout.LayoutParams(-1, -2));
        int marginH = tv ? a.dp(48) : a.dp(20);
        int panelWidth = Math.min(a.dp(740), a.windowWidth() - marginH);
        int maxHeight = Math.max(a.dp(180), a.windowHeight() - a.dp(tv ? 32 : 84));
        panel.measure(
                View.MeasureSpec.makeMeasureSpec(panelWidth, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED));
        int controlsHeight = panel.getMeasuredHeight() - defaultViewportH;
        viewport.setLayoutParams(
                new LinearLayout.LayoutParams(
                        -1,
                        Math.max(
                                a.dp(96),
                                Math.min(a.dp(tv ? 360 : 410), maxHeight - controlsHeight))));
        panel.measure(
                View.MeasureSpec.makeMeasureSpec(panelWidth, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED));
        if (panel.getMeasuredHeight() > maxHeight) {
            ScrollView outer = new TvScrollView(a);
            outer.addView(panel);
            dialog.setContentView(outer, new ViewGroup.LayoutParams(panelWidth, maxHeight));
        } else dialog.setContentView(panel);
        Window window = dialog.getWindow();
        if (window != null) {
            window.setBackgroundDrawableResource(android.R.color.transparent);
            window.setLayout(panelWidth, -2);
            window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            WindowManager.LayoutParams params = window.getAttributes();
            params.gravity = Gravity.CENTER;
            params.dimAmount = .65f;
            window.setAttributes(params);
        }
        Button focus = selectedButton;
        dialog.setOnShowListener(
                d -> {
                    if (focus != null) focus.requestFocus();
                    else if (grid.getChildCount() > 0)
                        ((LinearLayout) grid.getChildAt(0)).getChildAt(0).requestFocus();
                });
        dialog.show();
        if (window != null) window.setLayout(Math.min(a.dp(720), a.root.getWidth() - marginH), -2);
    }

    static void showSavedConfigs(MainActivity a) {
        Cms.Config previous = a.config;
        ConfigLibrary library = new ConfigLibrary(a.configStore.directory);
        String previousOrigin = a.configOrigin;
        String previousSelection = a.prefs.getString(Prefs.SELECTED_SITE, "");
        a.worker.execute(
                () -> {
                    try {
                        library.rememberIfAbsent(
                                previous.raw,
                                previousOrigin,
                                SourceController.configName(previous),
                                previousSelection);
                        java.util.List<ConfigLibrary.Entry> entries = library.entries();
                        String active = ConfigLibrary.identity(previousOrigin, previous.raw);
                        String[] names = new String[entries.size()];
                        int selected = -1;
                        final java.util.List<ConfigLibrary.Entry> mergeable =
                                new java.util.ArrayList<>();
                        for (int i = 0; i < names.length; i++) {
                            ConfigLibrary.Entry entry = entries.get(i);
                            String stamp = SourceController.formatShortTimestamp(entry.updated);
                            names[i] =
                                    entry.name
                                            + "（订阅 "
                                            + (i + 1)
                                            + (stamp.isEmpty() ? "" : " · 更新 " + stamp)
                                            + "）";
                            if (entry.id.equals(active)) selected = i;
                            if (!SubscriptionManager.isMergedOrigin(entry.origin)) {
                                mergeable.add(entry);
                            }
                        }
                        final int checked = selected;
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing() || a.config != previous) return;
                                    AppDialog.Builder builder =
                                            new AppDialog.Builder(a)
                                                    .wrapChoices()
                                                    .setTitle("已添加源 · " + entries.size() + " 个订阅")
                                                    .setSingleChoiceItems(
                                                            names,
                                                            checked,
                                                            (dialog, index) -> {
                                                                dialog.dismiss();
                                                                ConfigLibrary.Entry entry =
                                                                        entries.get(index);
                                                                if (entry.id.equals(active)) {
                                                                    show(a);
                                                                    return;
                                                                }
                                                                a.worker.execute(
                                                                        () -> {
                                                                            try {
                                                                                Cms.Config saved =
                                                                                        Cms
                                                                                                .parseConfig(
                                                                                                        library
                                                                                                                .raw(
                                                                                                                        entry),
                                                                                                        entry.origin);
                                                                                a.ui.post(
                                                                                        () -> {
                                                                                            if (a
                                                                                                            .isFinishing()
                                                                                                    || a.config
                                                                                                            != previous)
                                                                                                return;
                                                                                            try {
                                                                                                saveSelectedConfig(
                                                                                                        a,
                                                                                                        saved,
                                                                                                        entry.origin);
                                                                                            } catch (
                                                                                                    Exception
                                                                                                            error) {
                                                                                                a
                                                                                                        .notice(
                                                                                                                "订阅切换失败，已保留当前片源");
                                                                                            }
                                                                                        });
                                                                            } catch (
                                                                                    Exception
                                                                                            error) {
                                                                                a.ui.post(
                                                                                        () ->
                                                                                                a
                                                                                                        .notice(
                                                                                                                "无法读取这份订阅，已保留当前片源"));
                                                                            }
                                                                        });
                                                            })
                                                    .setNegativeButton("关闭", null)
                                                    .setPositiveButton(
                                                            "立即刷新订阅",
                                                            (dialog, which) ->
                                                                    SourceController
                                                                            .runDailyAutoUpdateIfNeeded(
                                                                                    a, true));
                                    if (mergeable.size() >= 2) {
                                        builder.setNeutralButton(
                                                "多源合并 / 删除",
                                                (dialog, which) ->
                                                        showSavedConfigsActionsDialog(
                                                                a, library, entries, mergeable,
                                                                active));
                                    } else if (entries.size() > 1) {
                                        builder.setNeutralButton(
                                                "删除订阅",
                                                (dialog, which) ->
                                                        showDeleteSavedConfigDialog(
                                                                a, library, entries, active));
                                    }
                                    builder.show();
                                });
                    } catch (Exception error) {
                        a.ui.post(() -> a.notice("无法读取已添加源，原订阅文件已保留"));
                    }
                });
    }

    private static void showSavedConfigsActionsDialog(
            final MainActivity a,
            final ConfigLibrary library,
            final java.util.List<ConfigLibrary.Entry> entries,
            final java.util.List<ConfigLibrary.Entry> mergeable,
            final String activeId) {
        String[] actions =
                new String[] {
                    "⚡ 合并多个已添加源并自动分组（" + mergeable.size() + " 个可选）", "↻ 立即刷新全部在线订阅源", "删除不再使用的订阅源"
                };
        new AppDialog.Builder(a)
                .wrapChoices()
                .setTitle("订阅源管理")
                .setItems(
                        actions,
                        (d, idx) -> {
                            if (idx == 0) {
                                showMergeSavedConfigsDialog(a, mergeable);
                            } else if (idx == 1) {
                                SourceController.runDailyAutoUpdateIfNeeded(a, true);
                            } else {
                                showDeleteSavedConfigDialog(a, library, entries, activeId);
                            }
                        })
                .setNegativeButton("返回", (d, w) -> showSavedConfigs(a))
                .show();
    }

    private static void showMergeSavedConfigsDialog(
            final MainActivity a, final java.util.List<ConfigLibrary.Entry> mergeable) {
        String[] labels = new String[mergeable.size()];
        final boolean[] checked = new boolean[mergeable.size()];
        for (int i = 0; i < mergeable.size(); i++) {
            labels[i] = mergeable.get(i).name;
            checked[i] = true;
        }
        new AppDialog.Builder(a)
                .setTitle("勾选要合并自动分组的订阅源")
                .setView(buildMultiSelectListView(a, labels, checked))
                .setNegativeButton("返回", (d, w) -> showSavedConfigs(a))
                .setPositiveButton(
                        "合并并自动分组",
                        (d, w) -> {
                            java.util.List<ConfigLibrary.Entry> chosen =
                                    new java.util.ArrayList<>();
                            for (int i = 0; i < checked.length; i++) {
                                if (checked[i]) chosen.add(mergeable.get(i));
                            }
                            if (chosen.size() < 2) {
                                a.notice("请至少勾选 2 个订阅源进行合并分组");
                                return;
                            }
                            SourceController.mergeSavedSubscriptions(a, chosen);
                        })
                .show();
    }

    private static void showDeleteSavedConfigDialog(
            final MainActivity a,
            final ConfigLibrary library,
            final java.util.List<ConfigLibrary.Entry> entries,
            final String activeId) {
        final java.util.List<ConfigLibrary.Entry> deletable = new java.util.ArrayList<>();
        for (ConfigLibrary.Entry e : entries) {
            if (!e.id.equals(activeId)) {
                deletable.add(e);
            }
        }
        if (deletable.isEmpty()) {
            a.notice("请先切换到其他订阅源，再删除当前订阅。");
            return;
        }
        String[] labels = new String[deletable.size()];
        for (int i = 0; i < deletable.size(); i++) {
            labels[i] = "删除 · " + deletable.get(i).name;
        }
        new AppDialog.Builder(a)
                .wrapChoices()
                .setTitle("选择要移除的订阅源")
                .setItems(
                        labels,
                        (d, idx) -> {
                            final ConfigLibrary.Entry target = deletable.get(idx);
                            a.worker.execute(
                                    () -> {
                                        try {
                                            library.remove(target.id);
                                            CloudSyncDialog.onSubscriptionDeleted(a, target.id);
                                            a.ui.post(
                                                    () -> {
                                                        a.toast("已移除订阅：" + target.name);
                                                        showSavedConfigs(a);
                                                    });
                                        } catch (Exception err) {
                                            a.ui.post(() -> a.notice("删除订阅失败：" + err.getMessage()));
                                        }
                                    });
                        })
                .setNegativeButton("返回", (d, w) -> showSavedConfigs(a))
                .show();
    }

    private static void saveSelectedConfig(MainActivity a, Cms.Config saved, String origin)
            throws Exception {
        SourceController.saveConfig(a, saved, origin);
        show(a);
    }

    static void showWarehouses(MainActivity a) {
        Cms.Config previous = a.config;
        org.json.JSONArray rows = previous.depots;
        boolean canMergeAll = rows.length() >= 2;
        String[] names = new String[rows.length() + (canMergeAll ? 1 : 0)];
        if (canMergeAll) {
            names[0] = "⚡ 勾选多个子仓库合并并自动分组…";
        }
        for (int i = 0; i < rows.length(); i++) {
            names[i + (canMergeAll ? 1 : 0)] = rows.optJSONObject(i).optString("name");
        }
        new AppDialog.Builder(a)
                .wrapChoices()
                .setTitle("切换子仓库")
                .setItems(
                        names,
                        (dialog, index) -> {
                            if (canMergeAll && index == 0) {
                                showMergeWarehousesDialog(a, rows);
                                return;
                            }
                            int rowIdx = index - (canMergeAll ? 1 : 0);
                            String url = rows.optJSONObject(rowIdx).optString("url");
                            a.toast("正在读取子仓库…");
                            a.worker.execute(
                                    () -> {
                                        try {
                                            Cms.Config selected =
                                                    Cms.parseConfig(
                                                            SourceController.fetchImport(a, url),
                                                            url);
                                            String combined =
                                                    com.pilipala.source.Warehouse.retainDirectory(
                                                            selected.raw,
                                                            selected.origin,
                                                            previous.raw,
                                                            raw ->
                                                                    new org.json.JSONObject(
                                                                            Cms.withoutComments(
                                                                                    raw)));
                                            Cms.Config ready =
                                                    Cms.parseConfig(combined, selected.origin);
                                            a.ui.post(
                                                    () -> {
                                                        if (a.isFinishing() || a.config != previous)
                                                            return;
                                                        try {
                                                            SourceController.saveConfig(
                                                                    a, ready, ready.origin);
                                                        } catch (Exception e) {
                                                            a.notice("子仓库保存失败，请重试");
                                                        }
                                                    });
                                        } catch (Exception e) {
                                            a.ui.post(
                                                    () -> {
                                                        if (!a.isFinishing())
                                                            a.notice("子仓库读取失败，已保留原线路");
                                                    });
                                        }
                                    });
                        })
                .show();
    }

    private static void showMergeWarehousesDialog(
            final MainActivity a, final org.json.JSONArray rows) {
        int count = Math.min(SubscriptionManager.MAX_BATCH_SOURCES, rows.length());
        String[] labels = new String[count];
        final boolean[] checked = new boolean[count];
        for (int i = 0; i < count; i++) {
            org.json.JSONObject r = rows.optJSONObject(i);
            labels[i] = r == null ? ("子仓库 " + (i + 1)) : r.optString("name", "子仓库 " + (i + 1));
            checked[i] = i < 4;
        }
        new AppDialog.Builder(a)
                .setTitle("勾选要合并自动分组的子仓库")
                .setView(buildMultiSelectListView(a, labels, checked))
                .setNegativeButton("取消", null)
                .setPositiveButton(
                        "合并并自动分组",
                        (d, w) -> {
                            final java.util.List<SubscriptionManager.ImportSpec> specs =
                                    new java.util.ArrayList<>();
                            for (int i = 0; i < count; i++) {
                                if (!checked[i]) continue;
                                org.json.JSONObject r = rows.optJSONObject(i);
                                if (r == null) continue;
                                String u = r.optString("url", "").trim();
                                String n = r.optString("name", "").trim();
                                if (Cms.isHttp(u)) {
                                    specs.add(new SubscriptionManager.ImportSpec(n, u));
                                }
                            }
                            if (specs.size() < 2) {
                                a.notice("请至少勾选 2 个子仓库");
                                return;
                            }
                            a.toast("正在读取 " + specs.size() + " 个子仓库并自动分组…");
                            a.worker.execute(
                                    () -> {
                                        try {
                                            final SubscriptionManager.MergedResult merged =
                                                    SourceController.fetchAndMergeImportSpecs(
                                                            a, specs, false);
                                            a.ui.post(
                                                    () -> {
                                                        if (a.isFinishing()) return;
                                                        try {
                                                            SourceController.saveConfig(
                                                                    a,
                                                                    merged.config,
                                                                    merged.origin);
                                                            a.toast(
                                                                    "已合并 "
                                                                            + merged.sourceCount
                                                                            + " 个子仓库并自动分组");
                                                            show(a);
                                                        } catch (Exception e) {
                                                            a.notice("合并子仓库保存失败：" + a.message(e));
                                                        }
                                                    });
                                        } catch (Exception e) {
                                            a.ui.post(
                                                    () -> {
                                                        if (!a.isFinishing()) {
                                                            a.notice("子仓库合并失败：" + a.message(e));
                                                        }
                                                    });
                                        }
                                    });
                        })
                .show();
    }
}
