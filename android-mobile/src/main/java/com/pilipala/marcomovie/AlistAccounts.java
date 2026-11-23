package com.pilipala.marcomovie;

import android.content.Context;
import android.content.SharedPreferences;
import android.text.InputType;
import android.view.View;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Local storage and Apple TV / Mobile frosted-glass UI for mounting AList v3 media libraries.
 *
 * <p>Persists mount entries in dedicated private {@link SharedPreferences} ({@code alist_mounts})
 * without modifying {@code Prefs.KEYS}. On TV, every text input attaches {@link TvQrInputHelper} so
 * users can paste AList URLs and credentials from their phone via QR bubble.
 */
final class AlistAccounts {
    static final String PREFS_FILE = "alist_mounts";
    static final String KEY_MOUNTS = "mounts_json";

    private AlistAccounts() {}

    static List<AlistEngine.MountConfig> parseMounts(String rawJson) {
        List<AlistEngine.MountConfig> out = new ArrayList<>();
        if (rawJson == null || rawJson.trim().isEmpty()) return out;
        try {
            JSONArray arr = new JSONArray(rawJson);
            for (int i = 0; i < arr.length(); i++) {
                AlistEngine.MountConfig cfg =
                        AlistEngine.MountConfig.fromJson(arr.optJSONObject(i));
                if (cfg != null) out.add(cfg);
            }
        } catch (Exception ignored) {
        }
        return out;
    }

    static String serializeMounts(List<AlistEngine.MountConfig> mounts) {
        JSONArray arr = new JSONArray();
        if (mounts != null) {
            for (AlistEngine.MountConfig cfg : mounts) {
                if (cfg == null) continue;
                try {
                    arr.put(cfg.toJson());
                } catch (Exception ignored) {
                }
            }
        }
        return arr.toString();
    }

    static List<AlistEngine.MountConfig> list(Context context) {
        if (context == null) return new ArrayList<>();
        SharedPreferences sp = context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE);
        return parseMounts(sp.getString(KEY_MOUNTS, "[]"));
    }

    static AlistEngine.MountConfig find(Context context, String apiOrId) {
        String id = AlistEngine.parseMountId(apiOrId);
        if (id.isEmpty()) return null;
        for (AlistEngine.MountConfig cfg : list(context)) {
            if (id.equals(cfg.id)) return cfg;
        }
        return null;
    }

    static void save(Context context, AlistEngine.MountConfig mount) {
        if (context == null || mount == null) return;
        List<AlistEngine.MountConfig> all = list(context);
        for (Iterator<AlistEngine.MountConfig> it = all.iterator(); it.hasNext(); ) {
            if (mount.id.equals(it.next().id)) it.remove();
        }
        all.add(0, mount);
        context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_MOUNTS, serializeMounts(all))
                .apply();
    }

    static void remove(Context context, String mountId) {
        if (context == null || mountId == null || mountId.isEmpty()) return;
        List<AlistEngine.MountConfig> all = list(context);
        boolean changed = false;
        for (Iterator<AlistEngine.MountConfig> it = all.iterator(); it.hasNext(); ) {
            if (mountId.equals(it.next().id)) {
                it.remove();
                changed = true;
            }
        }
        if (changed) {
            context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
                    .edit()
                    .putString(KEY_MOUNTS, serializeMounts(all))
                    .apply();
        }
    }

    static JSONObject toSiteJson(AlistEngine.MountConfig mount) throws Exception {
        return new JSONObject()
                .put("key", mount.siteKey())
                .put("name", "AList · " + mount.name)
                .put("type", 4)
                .put("api", mount.apiUri())
                .put("searchable", 1)
                .put("quickSearch", 1);
    }

    static String statusSummary(Context context) {
        List<AlistEngine.MountConfig> mounts = list(context);
        if (mounts.isEmpty()) {
            return "挂载自建或公开 AList v3 网盘目录，支持浏览、搜索与直连播放";
        }
        if (mounts.size() == 1) {
            AlistEngine.MountConfig m = mounts.get(0);
            return "已挂载「" + m.name + "」(" + m.rootPath + ")";
        }
        return "已挂载 " + mounts.size() + " 个 AList 媒体库，点击管理或添加";
    }

    static void openManager(final MainActivity a) {
        openManager(a, null);
    }

    static void openManager(final MainActivity a, final Runnable onUpdated) {
        if (a == null) return;
        final List<AlistEngine.MountConfig> mounts = list(a);
        if (mounts.isEmpty()) {
            openEditor(a, null, onUpdated);
            return;
        }
        String[] labels = new String[mounts.size() + 1];
        for (int i = 0; i < mounts.size(); i++) {
            AlistEngine.MountConfig m = mounts.get(i);
            labels[i] = m.name + "  (" + m.baseUrl + m.rootPath + ")";
        }
        labels[mounts.size()] = "＋ 添加新的 AList 挂载";
        new AppDialog.Builder(a)
                .setTitle("AList 挂载管理")
                .setItems(
                        labels,
                        (d, which) -> {
                            if (which == mounts.size()) {
                                openEditor(a, null, onUpdated);
                            } else if (which >= 0 && which < mounts.size()) {
                                showMountActions(a, mounts.get(which), onUpdated);
                            }
                        })
                .setNegativeButton("关闭", null)
                .show();
    }

    private static void showMountActions(
            final MainActivity a, final AlistEngine.MountConfig mount, final Runnable onUpdated) {
        new AppDialog.Builder(a)
                .setTitle("AList · " + mount.name)
                .setItems(
                        new String[] {"立即打开浏览", "编辑挂载配置", "移除此挂载"},
                        (d, which) -> {
                            if (which == 0) {
                                openMountInApp(a, mount);
                            } else if (which == 1) {
                                openEditor(a, mount, onUpdated);
                            } else if (which == 2) {
                                remove(a, mount.id);
                                removeMountFromActiveConfig(a, mount);
                                a.toast("已移除 AList 挂载「" + mount.name + "」");
                                if (onUpdated != null) onUpdated.run();
                                else a.refresh();
                            }
                        })
                .setNegativeButton("返回", (d, w) -> openManager(a, onUpdated))
                .show();
    }

    static void openEditor(
            final MainActivity a,
            final AlistEngine.MountConfig existing,
            final Runnable onUpdated) {
        if (a == null) return;
        LinearLayout form = a.vertical();
        form.setClipChildren(false);
        form.setClipToPadding(false);

        TextView intro =
                a.text(
                        "支持 AList v3（公网/局域网、游客模式、账号密码或 Token 登录），挂载后自动加入片源并支持目录浏览、搜索和外挂字幕。",
                        13,
                        MainActivity.MUTED);
        intro.setLineSpacing(a.dp(3), 1f);
        form.addView(intro);
        a.gap(form, 10);

        final EditText urlInput =
                makeField(
                        a,
                        form,
                        "AList 服务地址（必填）",
                        existing != null ? existing.baseUrl : "",
                        "http://alist.example:5244",
                        false,
                        "AList 地址");
        final EditText[] pair1 =
                makeFieldPair(
                        a,
                        form,
                        "显示名称（可选）",
                        existing != null ? existing.name : "",
                        "例如：家庭影音 AList",
                        false,
                        "AList 名称",
                        "挂载根目录（默认 /）",
                        existing != null ? existing.rootPath : "/",
                        "/ 或 /电影",
                        false,
                        "AList 根目录");
        final EditText nameInput = pair1[0];
        final EditText pathInput = pair1[1];
        final EditText[] pair2 =
                makeFieldPair(
                        a,
                        form,
                        "用户名（游客或 Token 可留空）",
                        existing != null ? existing.username : "",
                        "admin（可选）",
                        false,
                        "AList 用户名",
                        "登录密码（可选）",
                        existing != null ? existing.password : "",
                        "登录密码（可选）",
                        true,
                        "AList 密码");
        final EditText userInput = pair2[0];
        final EditText passInput = pair2[1];
        final EditText[] pair3 =
                makeFieldPair(
                        a,
                        form,
                        "永久 Token（可选，优先于密码）",
                        existing != null ? existing.token : "",
                        "alist-xxxx（可选）",
                        true,
                        "AList Token",
                        "目录访问密码（可选）",
                        existing != null ? existing.folderPassword : "",
                        "文件夹密码（可选）",
                        true,
                        "AList 目录密码");
        final EditText tokenInput = pair3[0];
        final EditText dirPassInput = pair3[1];

        final TextView status = a.text("", 13, 0xff7ac0ff);
        status.setVisibility(View.GONE);
        LinearLayout.LayoutParams stLp = new LinearLayout.LayoutParams(-1, -2);
        stLp.topMargin = a.dp(6);
        form.addView(status, stLp);

        AppDialog dialog =
                new AppDialog.Builder(a)
                        .setTitle(existing == null ? "挂载 AList 网盘 / 媒体库" : "编辑 AList 挂载")
                        .setView(form)
                        .setNegativeButton("取消", null)
                        .setPositiveButton("测试并挂载", null)
                        .create();
        dialog.show();

        android.widget.Button saveBtn = dialog.getButton(-1);
        if (saveBtn != null) {
            saveBtn.setOnClickListener(
                    v -> {
                        String rawUrl = urlInput.getText().toString().trim();
                        if (rawUrl.isEmpty()) {
                            status.setText("请先填写 AList 服务地址");
                            status.setTextColor(0xffff6961);
                            status.setVisibility(View.VISIBLE);
                            return;
                        }
                        String normUrl = AlistEngine.normalizeBaseUrl(rawUrl);
                        if (!Cms.isHttp(normUrl)) {
                            status.setText("服务地址格式不正确，请输入 http:// 或 https:// 地址");
                            status.setTextColor(0xffff6961);
                            status.setVisibility(View.VISIBLE);
                            return;
                        }
                        final AlistEngine.MountConfig candidate =
                                new AlistEngine.MountConfig(
                                        existing != null ? existing.id : "",
                                        nameInput.getText().toString().trim(),
                                        normUrl,
                                        pathInput.getText().toString().trim(),
                                        userInput.getText().toString().trim(),
                                        passInput.getText().toString(),
                                        tokenInput.getText().toString().trim(),
                                        dirPassInput.getText().toString());
                        saveBtn.setEnabled(false);
                        status.setText("正在连接 AList 并校验目录…");
                        status.setTextColor(0xff7ac0ff);
                        status.setVisibility(View.VISIBLE);
                        new Thread(
                                        () -> {
                                            try {
                                                int itemCount =
                                                        new AlistEngine.Client(candidate)
                                                                .testConnection();
                                                a.ui.post(
                                                        () -> {
                                                            if (a.isFinishing()) return;
                                                            save(a, candidate);
                                                            try {
                                                                JSONObject siteJson =
                                                                        toSiteJson(candidate);
                                                                SourceController.mergeOrSaveConfig(
                                                                        a,
                                                                        Cms.parseConfig(
                                                                                new JSONObject()
                                                                                        .put(
                                                                                                "sites",
                                                                                                new JSONArray()
                                                                                                        .put(
                                                                                                                siteJson))
                                                                                        .toString(),
                                                                                ""),
                                                                        "",
                                                                        true);
                                                            } catch (Exception ignored) {
                                                            }
                                                            if (dialog.isShowing()) {
                                                                dialog.dismiss();
                                                            }
                                                            a.toast(
                                                                    "AList「"
                                                                            + candidate.name
                                                                            + "」挂载成功（"
                                                                            + itemCount
                                                                            + " 项内容）");
                                                            if (onUpdated != null) {
                                                                onUpdated.run();
                                                            } else {
                                                                openMountInApp(a, candidate);
                                                            }
                                                        });
                                            } catch (Exception err) {
                                                a.ui.post(
                                                        () -> {
                                                            if (a.isFinishing()) return;
                                                            saveBtn.setEnabled(true);
                                                            status.setText(a.message(err));
                                                            status.setTextColor(0xffff6961);
                                                            status.setVisibility(View.VISIBLE);
                                                        });
                                            }
                                        },
                                        "alist-connect")
                                .start();
                    });
        }
    }

    private static EditText[] makeFieldPair(
            MainActivity a,
            LinearLayout parent,
            String label1,
            String value1,
            String hint1,
            boolean password1,
            String qrLabel1,
            String label2,
            String value2,
            String hint2,
            boolean password2,
            String qrLabel2) {
        if (!a.isTvDevice()) {
            EditText first = makeField(a, parent, label1, value1, hint1, password1, qrLabel1);
            EditText second = makeField(a, parent, label2, value2, hint2, password2, qrLabel2);
            return new EditText[] {first, second};
        }
        LinearLayout row = a.row();
        row.setClipChildren(false);
        row.setClipToPadding(false);
        LinearLayout left = a.vertical();
        left.setClipChildren(false);
        left.setClipToPadding(false);
        LinearLayout right = a.vertical();
        right.setClipChildren(false);
        right.setClipToPadding(false);
        EditText first = makeField(a, left, label1, value1, hint1, password1, qrLabel1);
        EditText second = makeField(a, right, label2, value2, hint2, password2, qrLabel2);
        LinearLayout.LayoutParams lLp = new LinearLayout.LayoutParams(0, -2, 1f);
        lLp.rightMargin = a.dp(10);
        row.addView(left, lLp);
        row.addView(right, new LinearLayout.LayoutParams(0, -2, 1f));
        parent.addView(row, new LinearLayout.LayoutParams(-1, -2));
        return new EditText[] {first, second};
    }

    private static EditText makeField(
            MainActivity a,
            LinearLayout parent,
            String label,
            String value,
            String hint,
            boolean password,
            String qrLabel) {
        TextView lbl = a.text(label, 12.5f, MainActivity.MUTED);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.topMargin = a.dp(6);
        lp.bottomMargin = a.dp(4);
        parent.addView(lbl, lp);

        EditText et = new EditText(a);
        et.setText(value);
        et.setHint(hint);
        et.setTextColor(MainActivity.WHITE);
        et.setHintTextColor(0xff8e98a8);
        et.setSingleLine(true);
        et.setTextSize(14f);
        et.setPadding(a.dp(12), a.dp(8), a.dp(12), a.dp(8));
        et.setBackground(a.bg(0x3a000000, 12));
        if (password) {
            et.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        } else {
            et.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        }
        View wrapped = TvQrInputHelper.wrap(a, et, qrLabel, false, password, false, null);
        LinearLayout.LayoutParams flp = new LinearLayout.LayoutParams(-1, -2);
        flp.bottomMargin = a.dp(2);
        parent.addView(wrapped, flp);
        return et;
    }

    private static void openMountInApp(MainActivity a, AlistEngine.MountConfig mount) {
        if (a == null || mount == null) return;
        Cms.Site target = null;
        if (a.config != null && a.config.sites != null) {
            for (Cms.Site s : a.config.sites) {
                if (s != null && mount.apiUri().equals(s.api)) {
                    target = s;
                    break;
                }
            }
        }
        if (target == null) {
            try {
                JSONObject siteJson = toSiteJson(mount);
                SourceController.mergeOrSaveConfig(
                        a,
                        Cms.parseConfig(
                                new JSONObject()
                                        .put("sites", new JSONArray().put(siteJson))
                                        .toString(),
                                ""),
                        "",
                        true);
            } catch (Exception ignored) {
            }
            if (a.config != null && a.config.sites != null) {
                for (Cms.Site s : a.config.sites) {
                    if (s != null && mount.apiUri().equals(s.api)) {
                        target = s;
                        break;
                    }
                }
            }
        }
        if (target != null) {
            final Cms.Site chosen = target;
            a.prefs.edit().putString(Prefs.SELECTED_SITE, chosen.key).apply();
            a.open(
                    new MainActivity.Screen(
                            () ->
                                    a.videos(
                                            chosen,
                                            mount.rootPath,
                                            "AList · " + mount.name,
                                            1,
                                            null)),
                    true);
        }
    }

    private static void removeMountFromActiveConfig(MainActivity a, AlistEngine.MountConfig mount) {
        if (a == null || mount == null || a.config == null || a.config.sites == null) return;
        boolean removed = false;
        for (Iterator<Cms.Site> it = a.config.sites.iterator(); it.hasNext(); ) {
            Cms.Site s = it.next();
            if (s != null && (mount.apiUri().equals(s.api) || mount.siteKey().equals(s.key))) {
                it.remove();
                removed = true;
            }
        }
        if (removed) {
            a.closeEngines();
            if (a.config.raw != null && !a.config.raw.trim().isEmpty()) {
                try {
                    JSONObject root = new JSONObject(a.config.raw);
                    JSONArray sites = root.optJSONArray("sites");
                    if (sites != null) {
                        JSONArray filtered = new JSONArray();
                        for (int i = 0; i < sites.length(); i++) {
                            JSONObject so = sites.optJSONObject(i);
                            if (so == null) continue;
                            String api = Cms.optSafeString(so, "api");
                            String key = Cms.optSafeString(so, "key");
                            if (!mount.apiUri().equals(api) && !mount.siteKey().equals(key)) {
                                filtered.put(so);
                            }
                        }
                        root.put("sites", filtered);
                        String updatedRaw = root.toString();
                        String origin = a.config.origin == null ? "" : a.config.origin;
                        SourceController.saveConfig(a, Cms.parseConfig(updatedRaw, origin), origin);
                    }
                } catch (Exception ignored) {
                }
            }
        }
    }
}
