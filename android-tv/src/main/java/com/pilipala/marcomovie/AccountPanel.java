package com.pilipala.marcomovie;

import android.app.Dialog;
import android.content.SharedPreferences;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Environment;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.view.animation.DecelerateInterpolator;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.io.File;
import java.util.Locale;

/**
 * Unified netdisk login & QR credential center.
 *
 * <p>On Android phones/tablets, opens a full-screen iOS secondary page ("我的云盘") aligned 1:1 with
 * {@code flutter/lib/ui/netdisk_sheet.dart} (obsidian-slate palette, priority banner card, and 4
 * two-tier cloud drive cards for 夸父 / 优汐 / 嘟嘟 / 阿狸). Keeps the anchored D-pad menu on Android TV.
 */
final class AccountPanel {
    private static final int ICON_CLOUD = 1;
    private static final int ICON_QR = 2;
    private static final int ICON_ARROWS_UD = 3;
    private static final int ICON_REFRESH = 4;
    private static final int ICON_PENCIL = 5;
    private static final int ICON_SORT = 6;
    private static final int ICON_CATPAW = 7;

    private static final String PREF_LOGIN_PREFIX = "netdisk_obs_login_";
    private static final String PREF_ENABLED_PREFIX = "netdisk_obs_enabled_";

    private static Runnable activePageRefresh;

    private interface EmbedCategoryLoader {
        void load(String catId, String folderTitle);
    }

    private static final class DriveSpec {
        final String key;
        final String tvAlias;
        final String providerName;
        final String lineSubtitle;
        final String panConfigCode;
        final String wexConfigCode;

        DriveSpec(
                String key,
                String tvAlias,
                String providerName,
                String lineSubtitle,
                String panConfigCode,
                String wexConfigCode) {
            this.key = key;
            this.tvAlias = tvAlias;
            this.providerName = providerName;
            this.lineSubtitle = lineSubtitle;
            this.panConfigCode = panConfigCode;
            this.wexConfigCode = wexConfigCode;
        }
    }

    private static final DriveSpec[] DRIVES = {
        new DriveSpec("quark", "我的夸父", "夸克网盘", "对应线路：夸父智1 / 夸克4K", "quark", "quarkcookie"),
        new DriveSpec("uc", "我的优汐", "UC网盘", "对应线路：优汐智1 / UC4K", "uccookie", "ucpancookie"),
        new DriveSpec("baidu", "我的嘟嘟", "百度网盘", "对应线路：嘟嘟无限2 / 百度原画", "baidu", "baidupanlogin"),
        new DriveSpec("ali", "我的阿狸", "阿里云盘", "对应线路：阿狸原画 / 阿里4K", "LoginShow", "aliyuntoken")
    };

    private static final DriveSpec[] EXTENDED_DRIVES = {
        new DriveSpec("115", "115网盘", "115网盘", "115 扫码 / Cookie 登录", "pan115", "115pancookie"),
        new DriveSpec("189", "天翼云盘", "天翼189", "天翼云盘扫码 / 账号登录", "pan189", "tianyilogin"),
        new DriveSpec("139", "移动云盘", "移动139", "移动云盘扫码 / Cookie 登录", "pan139", "ydyuncookie"),
        new DriveSpec("123", "123云盘", "123网盘", "123云盘账号 / 凭据登录", "pan123manual", "pan123login"),
        new DriveSpec("thunder", "迅雷云盘", "迅雷网盘", "迅雷云盘扫码 / 账号登录", "thunder", "panxunleiuser")
    };

    private AccountPanel() {}

    static boolean isLikelyConfigCenterSite(Cms.Site site) {
        if (site == null) return false;
        if (SourceController.isDedicatedConfigSite(site)) return true;
        String api = site.api == null ? "" : site.api.toLowerCase(Locale.ROOT);
        String key = site.key == null ? "" : site.key.toLowerCase(Locale.ROOT);
        String name = site.name == null ? "" : site.name;
        return api.contains("mydrive")
                || key.contains("mydrive")
                || api.contains("configcenter")
                || api.contains("localconfig")
                || api.contains("panconfig")
                || api.contains("wexconfig")
                || api.contains("wexokconfig")
                || key.contains("configcenter")
                || key.contains("panconfig")
                || key.contains("wexconfig")
                || name.contains("我的云盘")
                || name.contains("我的网盘")
                || name.contains("我的┃网盘")
                || name.contains("我的丨网盘")
                || name.contains("配置中心")
                || name.contains("配置丨中心")
                || name.contains("配置┃中心")
                || (name.contains("配置") && name.contains("中心"));
    }

    /**
     * Collects all compatible Config Center sites across single or merged multi-source configs,
     * prioritizing: (1) explicitly selected Config Center key, (2) Config Center in the active
     * site's group, and (3) all other Config Centers in subscription order.
     */
    static java.util.List<Cms.Site> collectConfigCenterSites(
            java.util.List<Cms.Site> sites, String activeGroup, String preferredKey) {
        java.util.List<Cms.Site> primary = new java.util.ArrayList<Cms.Site>();
        java.util.List<Cms.Site> fallback = new java.util.ArrayList<Cms.Site>();
        if (sites == null || sites.isEmpty()) return primary;
        for (Cms.Site site : sites) {
            if (site == null) continue;
            if (isLikelyConfigCenterSite(site)) {
                primary.add(site);
            } else {
                String api = site.api == null ? "" : site.api.toLowerCase(Locale.ROOT);
                String name = site.name == null ? "" : site.name;
                if (api.contains("wogg")
                        || api.contains("mogg")
                        || name.contains("玩偶")
                        || name.contains("木偶")) {
                    fallback.add(site);
                }
            }
        }
        java.util.List<Cms.Site> candidates = primary.isEmpty() ? fallback : primary;
        if (candidates.size() <= 1) return candidates;
        java.util.List<Cms.Site> ordered = new java.util.ArrayList<Cms.Site>(candidates.size());
        java.util.Set<String> added = new java.util.HashSet<String>();
        String cleanPref = preferredKey == null ? "" : preferredKey.trim();
        String cleanGroup = activeGroup == null ? "" : activeGroup.trim();
        if (!cleanPref.isEmpty()) {
            for (Cms.Site s : candidates) {
                if (cleanPref.equals(s.key) && added.add(s.key)) {
                    ordered.add(s);
                }
            }
        }
        if (!cleanGroup.isEmpty()) {
            for (Cms.Site s : candidates) {
                if (cleanGroup.equals(SourcePicker.siteGroup(s)) && added.add(s.key)) {
                    ordered.add(s);
                }
            }
        }
        for (Cms.Site s : candidates) {
            if (added.add(s.key)) ordered.add(s);
        }
        return ordered;
    }

    static java.util.List<Cms.Site> findAllConfigCenterSites(MainActivity a) {
        if (a == null || a.config == null) return java.util.Collections.emptyList();
        String activeGroup = "";
        String selectedKey = a.prefs != null ? a.prefs.getString(Prefs.SELECTED_SITE, "") : "";
        if (!selectedKey.isEmpty()) {
            for (Cms.Site s : a.config.sites) {
                if (s != null && selectedKey.equals(s.key)) {
                    activeGroup = SourcePicker.siteGroup(s);
                    break;
                }
            }
        }
        String preferredCenter =
                a.prefs != null ? a.prefs.getString(Prefs.ACCOUNT_CONFIG_CENTER_KEY, "") : "";
        return collectConfigCenterSites(a.config.sites, activeGroup, preferredCenter);
    }

    static Cms.Site findConfigCenterSite(MainActivity a) {
        java.util.List<Cms.Site> all = findAllConfigCenterSites(a);
        return all.isEmpty() ? null : all.get(0);
    }

    private static String configScopePrefix(MainActivity a) {
        Cms.Site site = findConfigCenterSite(a);
        String origin = a != null && a.configOrigin != null ? a.configOrigin : "";
        String siteId = site != null && site.key != null ? site.key : "";
        String raw = origin + "|" + siteId;
        return Integer.toHexString(raw.hashCode()) + "_";
    }

    static boolean isAvailable(MainActivity a) {
        return findConfigCenterSite(a) != null || CatPawSettings.available(a);
    }

    private static final java.util.concurrent.ConcurrentHashMap<String, Integer>
            LIVE_SPIDER_DRIVE_STATUS = new java.util.concurrent.ConcurrentHashMap<>();

    static void onPluginConfigRefreshed() {
        NetdiskQrBubble.onPluginConfigRefreshed();
        final MainActivity a = MainActivity.activeActivity;
        final Runnable refresh = activePageRefresh;
        if (a != null && !a.isFinishing() && refresh != null) {
            a.ui.post(refresh);
        }
    }

    static boolean resolveEffectiveLoginState(
            int observedPref, boolean hasLiveCredential, int liveSpiderCardStatus) {
        if (hasLiveCredential) return true;
        if (liveSpiderCardStatus == 1) return true;
        if (observedPref == 1) return true;
        return false;
    }

    static void markDriveLoggedIn(MainActivity a, String driveKey, boolean loggedIn) {
        if (a == null || driveKey == null || driveKey.trim().isEmpty()) return;
        String key = driveKey.trim().toLowerCase(Locale.ROOT);
        String scope = configScopePrefix(a);
        LIVE_SPIDER_DRIVE_STATUS.put(scope + key, loggedIn ? 1 : 0);
        if (a.prefs != null) {
            SharedPreferences.Editor ed = a.prefs.edit();
            ed.putInt(PREF_LOGIN_PREFIX + scope + key, loggedIn ? 1 : 0);
            if (loggedIn) {
                ed.putInt(PREF_ENABLED_PREFIX + scope + key, 1);
            }
            ed.apply();
        }
        Runnable refresh = activePageRefresh;
        if (refresh != null) {
            a.ui.post(refresh);
        }
    }

    static void harvestConfigCenterVideos(MainActivity a, java.util.List<Cms.Video> videos) {
        if (a == null || videos == null || videos.isEmpty()) return;
        String scope = configScopePrefix(a);
        boolean changed = false;
        for (Cms.Video v : videos) {
            if (v == null) continue;
            String combined =
                    (v.title == null ? "" : v.title) + " " + (v.remarks == null ? "" : v.remarks);
            String key = PluginDialogStyler.detectDriveKeyFromLabel(combined);
            if (key == null) continue;
            boolean loggedIn =
                    combined.contains("已登录")
                            || combined.contains("已绑定")
                            || combined.contains("已授权")
                            || combined.contains("已配置")
                            || combined.contains("VIP")
                            || combined.contains("会员");
            boolean explicitlyOut = combined.contains("未登录") || combined.contains("未绑定");
            if (loggedIn) {
                Integer prev = LIVE_SPIDER_DRIVE_STATUS.put(scope + key, 1);
                if (prev == null || prev != 1) changed = true;
                if (a.prefs != null) {
                    a.prefs.edit().putInt(PREF_LOGIN_PREFIX + scope + key, 1).apply();
                }
            } else if (explicitlyOut && !hasNonEmptyCookieFile(a, key)) {
                LIVE_SPIDER_DRIVE_STATUS.put(scope + key, 0);
            }
        }
        if (changed) {
            Runnable refresh = activePageRefresh;
            if (refresh != null) a.ui.post(refresh);
        }
    }

    static void recordObservedSpiderRow(MainActivity a, String accountLabel, String statusLabel) {
        if (a == null || a.prefs == null || accountLabel == null) return;
        String key = PluginDialogStyler.detectDriveKeyFromLabel(accountLabel);
        if (key == null) return;

        boolean loggedIn =
                accountLabel.contains("已登录")
                        || accountLabel.contains("已绑定")
                        || accountLabel.contains("已配置")
                        || accountLabel.contains("已授权");
        boolean explicitlyLoggedOut = accountLabel.contains("未登录") || accountLabel.contains("未绑定");
        if (!loggedIn && !explicitlyLoggedOut) return;

        // Never overwrite verified real credentials with a stale "未登录" snapshot!
        if (!loggedIn && hasNonEmptyCookieFile(a, key)) {
            loggedIn = true;
        }

        boolean enabled =
                statusLabel != null && (statusLabel.contains("启用中") || statusLabel.contains("已启用"));

        int nextLogin = loggedIn ? 1 : 0;
        int nextEnabled = enabled ? 1 : 0;
        String scope = configScopePrefix(a);
        String scopedLoginKey = PREF_LOGIN_PREFIX + scope + key;
        String scopedEnabledKey = PREF_ENABLED_PREFIX + scope + key;
        LIVE_SPIDER_DRIVE_STATUS.put(scope + key, nextLogin);
        int prevLogin = a.prefs.getInt(scopedLoginKey, -1);
        int prevEnabled = a.prefs.getInt(scopedEnabledKey, -1);
        if (prevLogin != nextLogin || prevEnabled != nextEnabled) {
            SharedPreferences.Editor ed = a.prefs.edit();
            ed.putInt(scopedLoginKey, nextLogin);
            ed.putInt(scopedEnabledKey, nextEnabled);
            ed.apply();
            Runnable refresh = activePageRefresh;
            if (refresh != null) {
                a.ui.post(refresh);
            }
        }
    }

    static boolean isDriveLoggedIn(MainActivity a, String driveKey) {
        if (a == null || driveKey == null) return false;
        String key = driveKey.trim().toLowerCase(Locale.ROOT);
        String scope = configScopePrefix(a);
        boolean hasFile = hasNonEmptyCookieFile(a, key);
        int obs = a.prefs != null ? a.prefs.getInt(PREF_LOGIN_PREFIX + scope + key, -1) : -1;
        Integer liveObj = LIVE_SPIDER_DRIVE_STATUS.get(scope + key);
        int live = liveObj == null ? -1 : liveObj;
        boolean effective = resolveEffectiveLoginState(obs, hasFile, live);
        if (hasFile && obs != 1 && a.prefs != null) {
            // Auto-promote stale cached 0 once real credential evidence is present
            a.prefs.edit().putInt(PREF_LOGIN_PREFIX + scope + key, 1).apply();
        }
        return effective;
    }

    static boolean isDriveEnabled(MainActivity a, String driveKey) {
        if (a == null || a.prefs == null || driveKey == null) return false;
        return a.prefs.getInt(PREF_ENABLED_PREFIX + configScopePrefix(a) + driveKey, 0) == 1;
    }

    static int loggedDriveCount(MainActivity a) {
        int count = 0;
        for (DriveSpec d : DRIVES) {
            if (isDriveLoggedIn(a, d.key)) count++;
        }
        return count;
    }

    private static String[] driveFileNames(String driveKey) {
        if (driveKey == null) return new String[0];
        switch (driveKey.toLowerCase(Locale.ROOT)) {
            case "quark":
                return new String[] {
                    "quark.txt",
                    ".quark",
                    "quark_cookie.txt",
                    "quark_cookie",
                    "quarkck.txt",
                    "quark_token.txt"
                };
            case "uc":
                return new String[] {
                    "uc.txt",
                    ".uc",
                    "uc_cookie.txt",
                    "uc_cookie",
                    "uc_token.txt",
                    "ucck.txt",
                    "ucpan.txt"
                };
            case "baidu":
                return new String[] {
                    "baidu.txt",
                    ".baidu",
                    "bd_cookie.txt",
                    "baidu_cookie.txt",
                    "baiduck.txt",
                    "baidupan.txt"
                };
            case "ali":
                return new String[] {
                    "ali.txt",
                    ".ali",
                    "aliyundrive.txt",
                    "ali_token.txt",
                    "token.txt",
                    "alipan.txt",
                    "alitoken.txt"
                };
            case "115":
                return new String[] {"115.txt", "115_cookie.txt", "pan115.txt", "cookie115.txt"};
            case "189":
                return new String[] {
                    "189.txt", "tianyi.txt", "cloud189.txt", "189_cookie.txt", "ty.txt"
                };
            case "139":
                return new String[] {
                    "139.txt", "ydyun.txt", "yun139.txt", "139_cookie.txt", "yd.txt"
                };
            case "123":
                return new String[] {"123.txt", "pan123.txt", "123_cookie.txt", "123_token.txt"};
            case "thunder":
                return new String[] {
                    "thunder.txt", "thunder_cookie.txt", "xunlei.txt", "xl.txt", "xunlei_cookie.txt"
                };
            default:
                return new String[0];
        }
    }

    private static String[] driveKeywordTokens(String driveKey) {
        if (driveKey == null) return new String[0];
        switch (driveKey.toLowerCase(Locale.ROOT)) {
            case "quark":
                return new String[] {"quark", "kuake", "夸克", "夸父"};
            case "uc":
                return new String[] {"uc_cookie", "uccookie", "ucpan", "uc_token", "\"uc\"", "优汐"};
            case "baidu":
                return new String[] {"baidu", "bd_cookie", "bduss", "百度", "嘟嘟"};
            case "ali":
                return new String[] {"alipan", "aliyun", "ali_token", "alitoken", "阿里", "阿狸"};
            case "115":
                return new String[] {"115", "pan115"};
            case "189":
                return new String[] {"189", "tianyi", "cloud189"};
            case "139":
                return new String[] {"139", "yun139", "ydyun"};
            case "123":
                return new String[] {"123", "pan123"};
            case "thunder":
                return new String[] {"thunder", "xunlei", "迅雷"};
            default:
                return new String[0];
        }
    }

    private static File[] credentialSearchDirs(MainActivity a) {
        java.util.List<File> dirs = new java.util.ArrayList<>();
        File[] roots = {
            a.getCacheDir(),
            a.getFilesDir(),
            a.getExternalCacheDir(),
            a.getExternalFilesDir(null),
            new File(Environment.getExternalStorageDirectory(), "TV")
        };
        String[] subNames = {
            "TV", "tv", "wex", "pan", "ok", "cfg", "config", "token", "cookie", "drive", "catvod",
            "box"
        };
        for (File r : roots) {
            if (r == null || !r.isDirectory()) continue;
            dirs.add(r);
            for (String sub : subNames) {
                File s = new File(r, sub);
                if (s.isDirectory()) dirs.add(s);
            }
        }
        return dirs.toArray(new File[0]);
    }

    private static boolean hasNonEmptyCookieFile(MainActivity a, String driveKey) {
        try {
            String[] names = driveFileNames(driveKey);
            String[] keywords = driveKeywordTokens(driveKey);
            if (names.length == 0 && keywords.length == 0) return false;
            File[] dirs = credentialSearchDirs(a);
            String[] unifiedJsonNames = {
                "pan_config.json",
                "config.json",
                "token.json",
                "cookie.json",
                "drive.json",
                "local_config.json",
                "wex.json"
            };
            for (File dir : dirs) {
                for (String name : names) {
                    File f = new File(dir, name);
                    if (f.isFile() && f.length() > 8) return true;
                }
                for (String jName : unifiedJsonNames) {
                    File jf = new File(dir, jName);
                    if (jf.isFile() && jf.length() > 16 && jf.length() < 512 * 1024) {
                        if (jsonFileHasDriveCredential(jf, keywords)) return true;
                    }
                }
            }
            // Also probe spider-owned SharedPreferences XML files (excluding our own prefs)
            File dataDir = a.getFilesDir() != null ? a.getFilesDir().getParentFile() : null;
            if (dataDir != null) {
                File spDir = new File(dataDir, "shared_prefs");
                File[] xmls = spDir.isDirectory() ? spDir.listFiles() : null;
                if (xmls != null) {
                    for (File xf : xmls) {
                        if (xf == null || !xf.isFile() || !xf.getName().endsWith(".xml")) continue;
                        String n = xf.getName();
                        if (n.contains("marcomovie")
                                || n.contains("tv_nav_custom")
                                || n.contains("series_scrape")
                                || n.contains("marco_player_hud")) {
                            continue;
                        }
                        if (xf.length() > 32 && xf.length() < 256 * 1024) {
                            if (xmlPrefHasDriveCredential(xf, keywords)) return true;
                        }
                    }
                }
            }
        } catch (Throwable ignored) {
        }
        return false;
    }

    private static boolean jsonFileHasDriveCredential(File file, String[] keywords) {
        if (file == null || keywords == null || keywords.length == 0) return false;
        try (java.io.FileInputStream in = new java.io.FileInputStream(file)) {
            byte[] buf = new byte[(int) Math.min(file.length(), 131072)];
            int read = in.read(buf);
            if (read <= 0) return false;
            String text = new String(buf, 0, read, java.nio.charset.StandardCharsets.UTF_8);
            return textHasDriveCredentialValue(text, keywords);
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static boolean xmlPrefHasDriveCredential(File file, String[] keywords) {
        if (file == null || keywords == null || keywords.length == 0) return false;
        try (java.io.FileInputStream in = new java.io.FileInputStream(file)) {
            byte[] buf = new byte[(int) Math.min(file.length(), 131072)];
            int read = in.read(buf);
            if (read <= 0) return false;
            String text = new String(buf, 0, read, java.nio.charset.StandardCharsets.UTF_8);
            String lower = text.toLowerCase(Locale.ROOT);
            for (String kw : keywords) {
                int idx = lower.indexOf(kw.toLowerCase(Locale.ROOT));
                while (idx >= 0) {
                    int gt = text.indexOf('>', idx);
                    int lt = gt > 0 ? text.indexOf("</string>", gt) : -1;
                    if (gt > 0 && lt > gt) {
                        String val = text.substring(gt + 1, lt).trim();
                        if (val.length() >= 8 && !"null".equalsIgnoreCase(val)) return true;
                    }
                    idx = lower.indexOf(kw.toLowerCase(Locale.ROOT), idx + kw.length());
                }
            }
        } catch (Throwable ignored) {
        }
        return false;
    }

    static boolean textHasDriveCredentialValue(String raw, String[] keywords) {
        if (raw == null || raw.isEmpty() || keywords == null) return false;
        String lower = raw.toLowerCase(Locale.ROOT);
        for (String kw : keywords) {
            if (kw == null || kw.isEmpty()) continue;
            int idx = lower.indexOf(kw.toLowerCase(Locale.ROOT));
            while (idx >= 0) {
                int colon = raw.indexOf(':', idx);
                if (colon > idx && colon - idx < 48) {
                    int q1 = raw.indexOf('"', colon + 1);
                    int q2 = q1 > colon ? raw.indexOf('"', q1 + 1) : -1;
                    if (q1 > colon && q2 > q1) {
                        String val = raw.substring(q1 + 1, q2).trim();
                        if (val.length() >= 8
                                && !"null".equalsIgnoreCase(val)
                                && !val.startsWith("http://127.0.0.1")) {
                            return true;
                        }
                    }
                }
                idx = lower.indexOf(kw.toLowerCase(Locale.ROOT), idx + kw.length());
            }
        }
        return false;
    }

    /**
     * Captures a fast snapshot fingerprint of spider credential storage (files, shared_prefs, and
     * databases) so {@link NetdiskQrBubble} detects the exact moment ANY spider persists a QR login
     * token/cookie.
     */
    static String captureCredentialFingerprint(MainActivity a, String driveKey) {
        if (a == null) return "";
        try {
            long hash = hasNonEmptyCookieFile(a, driveKey) ? 17L : 3L;
            int fileCount = 0;
            long maxMtime = 0L;
            long totalLen = 0L;
            for (File dir : credentialSearchDirs(a)) {
                File[] list = dir.listFiles();
                if (list == null) continue;
                for (File f : list) {
                    if (f == null || !f.isFile()) continue;
                    long len = f.length();
                    if (len <= 4 || len > 4 * 1024 * 1024) continue;
                    fileCount++;
                    totalLen += len;
                    long mt = f.lastModified();
                    if (mt > maxMtime) maxMtime = mt;
                }
            }
            File dataDir = a.getFilesDir() != null ? a.getFilesDir().getParentFile() : null;
            if (dataDir != null) {
                for (String sub : new String[] {"shared_prefs", "databases"}) {
                    File d = new File(dataDir, sub);
                    File[] list = d.isDirectory() ? d.listFiles() : null;
                    if (list == null) continue;
                    for (File f : list) {
                        if (f == null || !f.isFile()) continue;
                        String n = f.getName();
                        if (n.contains("marcomovie")
                                || n.contains("tv_nav_custom")
                                || n.contains("series_scrape")
                                || n.contains("marco_player_hud")) {
                            continue;
                        }
                        fileCount++;
                        totalLen += f.length();
                        long mt = f.lastModified();
                        if (mt > maxMtime) maxMtime = mt;
                    }
                }
            }
            return hash + ":" + fileCount + ":" + totalLen + ":" + maxMtime;
        } catch (Throwable ignored) {
            return "";
        }
    }

    /** Builds the iOS-matched top-bar Liquid Glass netdisk pill for {@link MobileShell}. */
    static View buildHeaderCapsule(final MainActivity a, final Runnable onTap) {
        boolean unconfigured = a.config == null;
        int logged = unconfigured ? 0 : loggedDriveCount(a);
        LinearLayout pill = a.row();
        pill.setTag("home-netdisk-button");
        pill.setGravity(Gravity.CENTER);
        pill.setPadding(a.dp(10), a.dp(6), a.dp(11), a.dp(6));
        if (logged > 0) {
            GradientDrawable tinted = new GradientDrawable();
            tinted.setShape(GradientDrawable.RECTANGLE);
            tinted.setCornerRadius(a.dp(999));
            tinted.setColor(0x38165b33);
            tinted.setStroke(Math.max(1, a.dp(0.8f)), 0x6630d158);
            pill.setBackground(tinted);
        } else {
            a.glass(pill, 999);
        }

        if (!unconfigured) {
            VectorGlyphView icon =
                    new VectorGlyphView(
                            a,
                            logged > 0 ? ICON_CLOUD : ICON_QR,
                            logged > 0 ? 0xff30d158 : 0xff5ac8fa);
            LinearLayout.LayoutParams ilp = new LinearLayout.LayoutParams(a.dp(14), a.dp(14));
            ilp.rightMargin = a.dp(4);
            pill.addView(icon, ilp);
        }

        TextView label = a.text(unconfigured ? "＋配置" : "网盘", 12.5f, Color.WHITE);
        label.setTypeface(null, Typeface.BOLD);
        label.setSingleLine(true);
        pill.addView(label);

        MobileDetailScreen.bindTouchFeedback(pill);
        pill.setOnClickListener(v -> onTap.run());
        return pill;
    }

    static void show(MainActivity a) {
        show(a, null);
    }

    static void show(MainActivity a, View anchor) {
        if (a == null) return;
        if (a.isTvDevice()) {
            showTvDialog(a, anchor);
            return;
        }
        boolean hasCatPaw = CatPawSettings.available(a);
        Cms.Site configSite = findConfigCenterSite(a);
        if (configSite == null && !hasCatPaw) {
            AlistAccounts.openManager(a);
            return;
        }
        String backLabel =
                (a.current != null && a.current.home && MobileShell.activeTab == 4) ? "设置" : "返回";
        if (a.current != null && "mobile-netdisk-page".equals(a.current.focus)) {
            renderMobileCloudDrivePage(a, backLabel);
            return;
        }
        MainActivity.Screen page =
                new MainActivity.Screen(() -> renderMobileCloudDrivePage(a, backLabel));
        page.focus = "mobile-netdisk-page";
        a.open(page, true);
    }

    private static void showTvDialog(final MainActivity a, final View anchor) {
        final Dialog dialog = new Dialog(a);
        a.accountDialog = dialog;
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        if (dialog.getWindow() != null) {
            dialog.getWindow().getDecorView().setTag("app-dialog");
        }
        final java.util.List<Cms.Site> allConfigCenters = findAllConfigCenterSites(a);
        final Cms.Site[] activeSiteRef =
                new Cms.Site[] {allConfigCenters.isEmpty() ? null : allConfigCenters.get(0)};

        LinearLayout panel = a.vertical();
        panel.setTag("account-panel");
        panel.setPadding(a.dp(24), a.dp(18), a.dp(24), a.dp(14));
        panel.setClipChildren(true);
        panel.setClipToPadding(true);
        GradientDrawable cardBg =
                new GradientDrawable(
                        GradientDrawable.Orientation.TOP_BOTTOM,
                        new int[] {0xf724242b, 0xfa15161b});
        cardBg.setCornerRadius(a.dp(24));
        cardBg.setStroke(Math.max(1, a.dp(0.9f)), 0x34ffffff);
        panel.setBackground(cardBg);

        // Header row: title + storage permission pill
        LinearLayout headRow = a.row();
        headRow.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout titleCol = a.vertical();
        TextView heading = a.text("网盘与配置中心", 21, MainActivity.WHITE);
        heading.setTypeface(null, Typeface.BOLD);
        titleCol.addView(heading);
        final TextView note = a.text("", 12f, MainActivity.MUTED);
        note.setSingleLine(true);
        note.setEllipsize(TextUtils.TruncateAt.END);
        note.setPadding(0, a.dp(2), 0, 0);
        titleCol.addView(note);
        headRow.addView(titleCol, new LinearLayout.LayoutParams(0, -2, 1f));

        final boolean permOk = a.hasFullStoragePermission() || a.hasLegacyStorageWritePermission();
        final android.widget.Button permBtn =
                a.button(
                        permOk ? "✓ 存储权限已就绪" : "⚠ 未开启存储权限 · 去授权",
                        "account-storage-permission",
                        () -> {
                            if (Build.VERSION.SDK_INT >= 30) {
                                a.openTvStoragePermissionSettings();
                            } else {
                                a.requestRuntimeStoragePermission(() -> show(a, anchor));
                            }
                        });
        UiCompat.setDefaultFocusHighlightEnabled(permBtn, false);
        permBtn.setTextSize(12f);
        permBtn.setSingleLine(true);
        permBtn.setPadding(a.dp(12), 0, a.dp(12), 0);
        permBtn.setMinHeight(a.dp(34));
        permBtn.setMinimumHeight(a.dp(34));
        int permNormalBg = permOk ? 0x2e30d158 : 0x38ff453a;
        int permNormalFg = permOk ? 0xff4ade80 : 0xffff8a80;
        permBtn.setBackground(a.bg(permNormalBg, 999));
        permBtn.setTextColor(permNormalFg);
        permBtn.setOnFocusChangeListener(
                (v, f) ->
                        FocusMotion.style(
                                a,
                                permBtn,
                                f,
                                permNormalBg,
                                MainActivity.WHITE,
                                999,
                                permNormalFg,
                                MainActivity.DARK,
                                false,
                                1.02f));
        LinearLayout.LayoutParams permLp = new LinearLayout.LayoutParams(-2, a.dp(34));
        permLp.leftMargin = a.dp(12);
        headRow.addView(permBtn, permLp);
        panel.addView(headRow, new LinearLayout.LayoutParams(-1, -2));
        a.gap(panel, 12);

        // Scrollable content body wrapped in a clip-guarded viewport
        LinearLayout body = a.vertical();
        body.setClipChildren(false);
        body.setClipToPadding(false);
        body.setPadding(a.dp(2), a.dp(2), a.dp(2), a.dp(2));

        final java.util.Map<String, android.widget.Button> driveButtons =
                new java.util.LinkedHashMap<>();
        final Runnable[] refreshDriveStatesRef = new Runnable[1];
        final Runnable[] reloadEmbeddedConfigRef = new Runnable[1];

        // 2x2 Quick Drive Cards Grid (stay open on click -> anchored QR bubble extends from
        // button!)
        for (int rowIdx = 0; rowIdx < DRIVES.length; rowIdx += 2) {
            LinearLayout gridRow = a.row();
            gridRow.setClipChildren(false);
            for (int col = 0; col < 2; col++) {
                int idx = rowIdx + col;
                if (idx >= DRIVES.length) break;
                final DriveSpec drive = DRIVES[idx];
                final android.widget.Button driveCard =
                        a.button("", "account-drive:" + drive.key, () -> {});
                driveCard.setOnClickListener(
                        v ->
                                a.ensureStoragePermissionForNetdisk(
                                        () -> {
                                            NetdiskQrBubble.arm(
                                                    a,
                                                    driveCard,
                                                    drive.key,
                                                    drive.providerName,
                                                    () -> {
                                                        if (refreshDriveStatesRef[0] != null) {
                                                            refreshDriveStatesRef[0].run();
                                                        }
                                                        if (reloadEmbeddedConfigRef[0] != null) {
                                                            reloadEmbeddedConfigRef[0].run();
                                                        }
                                                    });
                                            dispatchDriveLoginAction(
                                                    a, activeSiteRef[0], drive, false);
                                        }));
                driveCard.setOnLongClickListener(
                        v -> {
                            a.ensureStoragePermissionForNetdisk(
                                    () ->
                                            dispatchDriveLoginAction(
                                                    a, activeSiteRef[0], drive, true));
                            return true;
                        });
                UiCompat.setDefaultFocusHighlightEnabled(driveCard, false);
                driveCard.setSingleLine(false);
                driveCard.setMaxLines(2);
                driveCard.setGravity(Gravity.START | Gravity.CENTER_VERTICAL);
                driveCard.setTextSize(13f);
                driveCard.setLineSpacing(a.dp(3), 1f);
                driveCard.setPadding(a.dp(14), a.dp(10), a.dp(14), a.dp(10));
                driveCard.setMinHeight(a.dp(62));
                driveCard.setMinimumHeight(a.dp(62));
                driveButtons.put(drive.key, driveCard);
                LinearLayout.LayoutParams dLp = new LinearLayout.LayoutParams(0, -2, 1f);
                if (col == 0) dLp.rightMargin = a.dp(10);
                dLp.bottomMargin = a.dp(10);
                gridRow.addView(driveCard, dLp);
            }
            body.addView(gridRow, new LinearLayout.LayoutParams(-1, -2));
        }

        refreshDriveStatesRef[0] =
                () -> {
                    Cms.Site cs = activeSiteRef[0];
                    note.setText(
                            cs != null
                                    ? ("已自动兼容配置中心：["
                                            + SourcePicker.siteGroup(cs)
                                            + "] "
                                            + cs.name
                                            + " · 点击按钮直接弹出扫码气泡，长按切换启用")
                                    : "当前订阅未内置配置中心 · 可在下方挂载 AList 或切换到含配置中心的订阅源");
                    for (DriveSpec drive : DRIVES) {
                        android.widget.Button btn = driveButtons.get(drive.key);
                        if (btn == null) continue;
                        boolean loggedIn = isDriveLoggedIn(a, drive.key);
                        boolean enabled = isDriveEnabled(a, drive.key);
                        String stateBadge =
                                loggedIn
                                        ? (enabled ? "✓ 已登录 · 启用中 · 点击重新扫码" : "✓ 已登录 · 点击扫码")
                                        : "未登录 · 点击弹出扫码气泡";
                        btn.setText(
                                drive.tvAlias + "  (" + drive.providerName + ")\n" + stateBadge);
                        final int cardNormal = loggedIn ? 0x2a30d158 : 0x18ffffff;
                        final int cardFg = loggedIn ? 0xffe8fff0 : MainActivity.WHITE;
                        boolean focused = btn.hasFocus();
                        FocusMotion.style(
                                a,
                                btn,
                                focused,
                                cardNormal,
                                MainActivity.WHITE,
                                16,
                                cardFg,
                                MainActivity.DARK,
                                false,
                                1.015f);
                        btn.setOnFocusChangeListener(
                                (v, f) ->
                                        FocusMotion.style(
                                                a,
                                                btn,
                                                f,
                                                cardNormal,
                                                MainActivity.WHITE,
                                                16,
                                                cardFg,
                                                MainActivity.DARK,
                                                false,
                                                1.015f));
                    }
                };
        refreshDriveStatesRef[0].run();

        // Utility Action Row (keeps AccountPanel open!)
        String[] labels = {"Cookie 凭据", "网盘优先顺序", "网盘搜索顺序"};
        String[] actions = {"pushCkShow", "panSortShow", "panSourceSortShow"};
        LinearLayout actRow = a.row();
        actRow.setClipChildren(false);
        actRow.setWeightSum(labels.length);
        for (int c = 0; c < labels.length; c++) {
            final String action = actions[c];
            final android.widget.Button item =
                    a.button(
                            labels[c],
                            "account-action:" + action,
                            () ->
                                    a.ensureStoragePermissionForNetdisk(
                                            () -> {
                                                PluginDialogStyler.clearDirectDriveForward();
                                                PluginDialogStyler.watch(a);
                                                new SettingsScreen(a)
                                                        .accountAction(action, activeSiteRef[0]);
                                            }));
            UiCompat.setDefaultFocusHighlightEnabled(item, false);
            item.setMinWidth(0);
            item.setMinimumWidth(0);
            item.setSingleLine(true);
            item.setEllipsize(TextUtils.TruncateAt.END);
            item.setTextSize(13f);
            item.setPadding(a.dp(10), 0, a.dp(10), 0);
            item.setBackground(a.bg(0x1effffff, 14));
            item.setOnFocusChangeListener(
                    (v, f) ->
                            FocusMotion.style(
                                    a,
                                    item,
                                    f,
                                    0x1effffff,
                                    MainActivity.WHITE,
                                    14,
                                    MainActivity.WHITE,
                                    MainActivity.DARK,
                                    false,
                                    1.015f));
            LinearLayout.LayoutParams aLp = new LinearLayout.LayoutParams(0, a.dp(40), 1f);
            if (c + 1 < labels.length) aLp.rightMargin = a.dp(10);
            aLp.bottomMargin = a.dp(8);
            actRow.addView(item, aLp);
        }
        body.addView(actRow, new LinearLayout.LayoutParams(-1, -2));

        // Embedded Auto-Compatible Subscription Source Config Center Section (Item 7)
        final LinearLayout configEmbedBox = a.vertical();
        configEmbedBox.setTag("account-config-center-embed");
        configEmbedBox.setClipChildren(false);
        configEmbedBox.setClipToPadding(false);
        if (activeSiteRef[0] != null) {
            body.addView(configEmbedBox, new LinearLayout.LayoutParams(-1, -2));
        }

        final int[] embedReqGen = new int[] {0};
        final java.util.List<Cms.Category> cachedCategories = new java.util.ArrayList<>();
        final boolean[] homeReturnedVideos = new boolean[] {false};
        final String[] activeCatId = new String[] {""};
        final java.util.List<String[]> folderStack = new java.util.ArrayList<>();

        final Runnable[] renderEmbedCardsRef = new Runnable[1];
        final Runnable[] renderCenterTabsRef = new Runnable[1];
        final java.util.List<Cms.Video> currentEmbedVideos = new java.util.ArrayList<>();
        final TextView embedStatusTv = a.text("", 12f, MainActivity.MUTED);
        final LinearLayout centerTabsRow = a.row();
        centerTabsRow.setClipChildren(false);
        final LinearLayout embedCatsRow = a.row();
        embedCatsRow.setClipChildren(false);
        final LinearLayout embedGridHost = a.vertical();
        embedGridHost.setClipChildren(false);
        final LinearLayout multiSubMergeSlot = a.vertical();
        multiSubMergeSlot.setClipChildren(false);
        body.addView(multiSubMergeSlot, 0, new LinearLayout.LayoutParams(-1, -2));

        final EmbedCategoryLoader loadEmbedCategory =
                (catId, folderTitle) -> {
                    final Cms.Site cs = activeSiteRef[0];
                    if (cs == null) return;
                    final int req = ++embedReqGen[0];
                    embedStatusTv.setText(
                            folderTitle != null && !folderTitle.isEmpty()
                                    ? ("正在加载 " + folderTitle + "…")
                                    : "正在读取订阅源配置中心…");
                    embedStatusTv.setVisibility(View.VISIBLE);
                    a.worker.execute(
                            () -> {
                                java.util.List<Cms.Category> cats = new java.util.ArrayList<>();
                                java.util.List<Cms.Video> vids = new java.util.ArrayList<>();
                                String err = "";
                                try {
                                    CspEngine.syncAllPluginActivities(a);
                                    SourceEngine eng = a.engine(cs);
                                    if (catId == null || catId.isEmpty()) {
                                        String homeRaw = eng.home();
                                        if (homeRaw != null && !homeRaw.trim().isEmpty()) {
                                            java.util.List<Cms.Category> parsedCats =
                                                    Cms.categories(homeRaw);
                                            if (parsedCats != null) cats.addAll(parsedCats);
                                            Cms.Listing homeList = Cms.listing(homeRaw);
                                            if (homeList != null && homeList.videos != null) {
                                                vids.addAll(homeList.videos);
                                            }
                                        }
                                        if (vids.isEmpty()) {
                                            try {
                                                String hvRaw = eng.homeVideos();
                                                if (hvRaw != null && !hvRaw.trim().isEmpty()) {
                                                    Cms.Listing hv = Cms.listing(hvRaw);
                                                    if (hv != null && hv.videos != null) {
                                                        vids.addAll(hv.videos);
                                                    }
                                                }
                                            } catch (Throwable ignored) {
                                            }
                                        }
                                        if (vids.isEmpty() && !cats.isEmpty()) {
                                            String firstRaw = eng.category(cats.get(0).id, 1);
                                            if (firstRaw != null && !firstRaw.trim().isEmpty()) {
                                                Cms.Listing first = Cms.listing(firstRaw);
                                                if (first != null && first.videos != null) {
                                                    vids.addAll(first.videos);
                                                }
                                            }
                                        }
                                    } else {
                                        String catRaw = eng.category(catId, 1);
                                        if (catRaw != null && !catRaw.trim().isEmpty()) {
                                            Cms.Listing listing = Cms.listing(catRaw);
                                            if (listing != null && listing.videos != null) {
                                                vids.addAll(listing.videos);
                                            }
                                        }
                                    }
                                } catch (Throwable t) {
                                    err = a.message(t);
                                }
                                final String finalErr = err;
                                a.ui.post(
                                        () -> {
                                            if (a.isFinishing()
                                                    || !dialog.isShowing()
                                                    || req != embedReqGen[0]) {
                                                return;
                                            }
                                            if (catId == null || catId.isEmpty()) {
                                                cachedCategories.clear();
                                                cachedCategories.addAll(cats);
                                                homeReturnedVideos[0] = !vids.isEmpty();
                                                activeCatId[0] =
                                                        vids.isEmpty() && !cats.isEmpty()
                                                                ? cats.get(0).id
                                                                : "";
                                            }
                                            currentEmbedVideos.clear();
                                            currentEmbedVideos.addAll(vids);
                                            harvestConfigCenterVideos(a, vids);
                                            if (refreshDriveStatesRef[0] != null) {
                                                refreshDriveStatesRef[0].run();
                                            }
                                            if (!finalErr.isEmpty() && vids.isEmpty()) {
                                                embedStatusTv.setText("配置中心加载失败：" + finalErr);
                                                embedStatusTv.setVisibility(View.VISIBLE);
                                            } else if (vids.isEmpty()) {
                                                embedStatusTv.setText("该分类暂无配置项");
                                                embedStatusTv.setVisibility(View.VISIBLE);
                                            } else {
                                                embedStatusTv.setVisibility(View.GONE);
                                            }
                                            if (renderEmbedCardsRef[0] != null) {
                                                renderEmbedCardsRef[0].run();
                                            }
                                        });
                            });
                };

        reloadEmbeddedConfigRef[0] =
                () -> {
                    if (activeSiteRef[0] == null) return;
                    if (!folderStack.isEmpty()) {
                        String[] top = folderStack.get(folderStack.size() - 1);
                        loadEmbedCategory.load(top[0], top[1]);
                    } else {
                        loadEmbedCategory.load(activeCatId[0], "");
                    }
                };

        renderEmbedCardsRef[0] =
                () -> {
                    embedCatsRow.removeAllViews();
                    if (!folderStack.isEmpty()) {
                        android.widget.Button backFolder =
                                a.button(
                                        "‹ 返回上级",
                                        "account-embed-back",
                                        () -> {
                                            folderStack.remove(folderStack.size() - 1);
                                            reloadEmbeddedConfigRef[0].run();
                                        });
                        styleTvCompatPill(a, backFolder, 0x285ac8fa, 0xffd8f3ff);
                        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(-2, a.dp(34));
                        blp.rightMargin = a.dp(8);
                        embedCatsRow.addView(backFolder, blp);
                    }
                    if (!cachedCategories.isEmpty()) {
                        if (homeReturnedVideos[0]) {
                            boolean homeSel = folderStack.isEmpty() && activeCatId[0].isEmpty();
                            android.widget.Button homePill =
                                    a.button(
                                            "全部功能",
                                            "account-embed-cat:home",
                                            () -> {
                                                folderStack.clear();
                                                activeCatId[0] = "";
                                                loadEmbedCategory.load("", "");
                                            });
                            styleTvCompatPill(
                                    a,
                                    homePill,
                                    homeSel ? 0x385ac8fa : 0x18ffffff,
                                    homeSel ? 0xffffffff : 0xffcfd8e6);
                            LinearLayout.LayoutParams hlp =
                                    new LinearLayout.LayoutParams(-2, a.dp(34));
                            hlp.rightMargin = a.dp(6);
                            embedCatsRow.addView(homePill, hlp);
                        }
                        for (int ci = 0; ci < cachedCategories.size(); ci++) {
                            final Cms.Category cat = cachedCategories.get(ci);
                            boolean sel =
                                    folderStack.isEmpty()
                                            && (cat.id.equals(activeCatId[0])
                                                    || (!homeReturnedVideos[0]
                                                            && activeCatId[0].isEmpty()
                                                            && ci == 0));
                            android.widget.Button pill =
                                    a.button(
                                            cat.name,
                                            "account-embed-cat:" + cat.id,
                                            () -> {
                                                folderStack.clear();
                                                activeCatId[0] = cat.id;
                                                loadEmbedCategory.load(cat.id, cat.name);
                                            });
                            styleTvCompatPill(
                                    a,
                                    pill,
                                    sel ? 0x385ac8fa : 0x18ffffff,
                                    sel ? 0xffffffff : 0xffcfd8e6);
                            LinearLayout.LayoutParams clp =
                                    new LinearLayout.LayoutParams(-2, a.dp(34));
                            clp.rightMargin = a.dp(6);
                            embedCatsRow.addView(pill, clp);
                        }
                    }

                    embedGridHost.removeAllViews();
                    int total = currentEmbedVideos.size();
                    for (int i = 0; i < total; i += 2) {
                        LinearLayout row = a.row();
                        row.setClipChildren(false);
                        for (int col = 0; col < 2; col++) {
                            int idx = i + col;
                            if (idx >= total) {
                                row.addView(new View(a), new LinearLayout.LayoutParams(0, 1, 1f));
                                break;
                            }
                            final Cms.Video item = currentEmbedVideos.get(idx);
                            final boolean isFolder = "folder".equalsIgnoreCase(item.tag);
                            String titleLine =
                                    (item.title == null ? "" : item.title.trim())
                                            + (isFolder ? "  ›" : "");
                            String rem = item.remarks == null ? "" : item.remarks.trim();
                            String cardLabel = rem.isEmpty() ? titleLine : (titleLine + "\n" + rem);
                            boolean cardLogged =
                                    rem.contains("已登录")
                                            || rem.contains("已绑定")
                                            || rem.contains("VIP")
                                            || titleLine.contains("已登录");
                            final int cBg = cardLogged ? 0x2430d158 : 0x16ffffff;
                            final int cFg = cardLogged ? 0xffdcfce7 : MainActivity.WHITE;
                            final android.widget.Button actBtn =
                                    a.button(cardLabel, "account-embed-item:" + idx, () -> {});
                            actBtn.setOnClickListener(
                                    v -> {
                                        Cms.Site cs = activeSiteRef[0];
                                        if (cs == null) return;
                                        if (isFolder) {
                                            folderStack.add(new String[] {item.id, item.title});
                                            loadEmbedCategory.load(item.id, item.title);
                                            return;
                                        }
                                        a.ensureStoragePermissionForNetdisk(
                                                () -> {
                                                    String detectedDrive =
                                                            PluginDialogStyler
                                                                    .detectDriveKeyFromLabel(
                                                                            item.title
                                                                                    + " "
                                                                                    + item.remarks);
                                                    NetdiskQrBubble.arm(
                                                            a,
                                                            actBtn,
                                                            detectedDrive == null
                                                                    ? ""
                                                                    : detectedDrive,
                                                            item.title,
                                                            () -> {
                                                                if (refreshDriveStatesRef[0]
                                                                        != null) {
                                                                    refreshDriveStatesRef[0].run();
                                                                }
                                                                if (reloadEmbeddedConfigRef[0]
                                                                        != null) {
                                                                    reloadEmbeddedConfigRef[0]
                                                                            .run();
                                                                }
                                                            });
                                                    String actCode =
                                                            item.action != null
                                                                            && !item.action
                                                                                    .trim()
                                                                                    .isEmpty()
                                                                    ? item.action.trim()
                                                                    : (item.id == null
                                                                            ? ""
                                                                            : item.id.trim());
                                                    PluginDialogStyler.clearDirectDriveForward();
                                                    PluginDialogStyler.watch(a);
                                                    SourceController.sourceAction(
                                                            a, cs, actCode, true);
                                                });
                                    });
                            UiCompat.setDefaultFocusHighlightEnabled(actBtn, false);
                            actBtn.setSingleLine(false);
                            actBtn.setMaxLines(2);
                            actBtn.setEllipsize(TextUtils.TruncateAt.END);
                            actBtn.setGravity(Gravity.START | Gravity.CENTER_VERTICAL);
                            actBtn.setTextSize(12.5f);
                            actBtn.setLineSpacing(a.dp(2), 1f);
                            actBtn.setPadding(a.dp(12), a.dp(8), a.dp(12), a.dp(8));
                            actBtn.setMinHeight(a.dp(50));
                            actBtn.setMinimumHeight(a.dp(50));
                            actBtn.setBackground(a.bg(cBg, 14));
                            actBtn.setTextColor(cFg);
                            actBtn.setOnFocusChangeListener(
                                    (v, f) ->
                                            FocusMotion.style(
                                                    a,
                                                    actBtn,
                                                    f,
                                                    cBg,
                                                    MainActivity.WHITE,
                                                    14,
                                                    cFg,
                                                    MainActivity.DARK,
                                                    false,
                                                    1.015f));
                            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, -2, 1f);
                            if (col == 0) lp.rightMargin = a.dp(10);
                            lp.bottomMargin = a.dp(8);
                            row.addView(actBtn, lp);
                        }
                        embedGridHost.addView(row, new LinearLayout.LayoutParams(-1, -2));
                    }
                };

        renderCenterTabsRef[0] =
                () -> {
                    centerTabsRow.removeAllViews();
                    if (allConfigCenters.size() <= 1) return;
                    Cms.Site cur = activeSiteRef[0];
                    for (int i = 0; i < allConfigCenters.size(); i++) {
                        final Cms.Site candidate = allConfigCenters.get(i);
                        final boolean isCurrent = cur != null && cur.key.equals(candidate.key);
                        String grp = SourcePicker.siteGroup(candidate);
                        String tabLabel =
                                (isCurrent ? "✓ " : "")
                                        + (SourcePicker.DEFAULT_GROUP.equals(grp)
                                                ? candidate.name
                                                : ("[" + grp + "] " + candidate.name));
                        android.widget.Button tabBtn =
                                a.button(
                                        tabLabel,
                                        "account-center-tab:" + candidate.key,
                                        () -> {
                                            if (activeSiteRef[0] != null
                                                    && activeSiteRef[0].key.equals(candidate.key)) {
                                                return;
                                            }
                                            NetdiskQrBubble.dismissActive(false);
                                            activeSiteRef[0] = candidate;
                                            if (a.prefs != null) {
                                                a.prefs
                                                        .edit()
                                                        .putString(
                                                                Prefs.ACCOUNT_CONFIG_CENTER_KEY,
                                                                candidate.key)
                                                        .apply();
                                            }
                                            folderStack.clear();
                                            cachedCategories.clear();
                                            homeReturnedVideos[0] = false;
                                            activeCatId[0] = "";
                                            refreshDriveStatesRef[0].run();
                                            renderCenterTabsRef[0].run();
                                            loadEmbedCategory.load("", "");
                                        });
                        styleTvCompatPill(
                                a,
                                tabBtn,
                                isCurrent ? 0x420a84ff : 0x1affffff,
                                isCurrent ? 0xffffffff : 0xffcfd8e6);
                        LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(-2, a.dp(34));
                        tlp.rightMargin = a.dp(8);
                        centerTabsRow.addView(tabBtn, tlp);
                    }
                };

        if (activeSiteRef[0] != null) {
            LinearLayout embedHeader = a.row();
            embedHeader.setGravity(Gravity.CENTER_VERTICAL);
            embedHeader.setPadding(0, a.dp(6), 0, a.dp(6));
            TextView embedTitle =
                    a.text(
                            allConfigCenters.size() > 1
                                    ? ("订阅源配置中心 · 已识别 " + allConfigCenters.size() + " 个订阅源")
                                    : "订阅源配置中心 · 全部功能自动兼容",
                            13.5f,
                            0xffd8e4f8);
            embedTitle.setTypeface(null, Typeface.BOLD);
            embedHeader.addView(embedTitle, new LinearLayout.LayoutParams(0, -2, 1f));
            if (allConfigCenters.size() > 1) {
                final android.widget.Button switchCenterBtn =
                        a.button(
                                "切换配置中心 (" + allConfigCenters.size() + ")",
                                "account-action:switch-config-center",
                                () -> {
                                    dialog.dismiss();
                                    showConfigCenterSwitcher(
                                            a, allConfigCenters, activeSiteRef[0], anchor);
                                });
                styleTvCompatPill(a, switchCenterBtn, 0x265ac8fa, 0xffd8f3ff);
                embedHeader.addView(switchCenterBtn, new LinearLayout.LayoutParams(-2, a.dp(34)));
            }
            configEmbedBox.addView(embedHeader, new LinearLayout.LayoutParams(-1, -2));

            if (allConfigCenters.size() > 1) {
                android.widget.HorizontalScrollView centerScroll =
                        new android.widget.HorizontalScrollView(a);
                centerScroll.setTag("account-config-center-tabs");
                centerScroll.setHorizontalScrollBarEnabled(false);
                centerScroll.setClipChildren(false);
                centerScroll.addView(centerTabsRow, new FrameLayout.LayoutParams(-2, -2));
                LinearLayout.LayoutParams cslp = new LinearLayout.LayoutParams(-1, -2);
                cslp.bottomMargin = a.dp(8);
                configEmbedBox.addView(centerScroll, cslp);
                renderCenterTabsRef[0].run();
            }

            android.widget.HorizontalScrollView catScroll =
                    new android.widget.HorizontalScrollView(a);
            catScroll.setHorizontalScrollBarEnabled(false);
            catScroll.setClipChildren(false);
            catScroll.addView(embedCatsRow, new FrameLayout.LayoutParams(-2, -2));
            LinearLayout.LayoutParams csLp = new LinearLayout.LayoutParams(-1, -2);
            csLp.bottomMargin = a.dp(8);
            configEmbedBox.addView(catScroll, csLp);

            embedStatusTv.setPadding(a.dp(4), a.dp(4), a.dp(4), a.dp(8));
            configEmbedBox.addView(embedStatusTv, new LinearLayout.LayoutParams(-1, -2));
            configEmbedBox.addView(embedGridHost, new LinearLayout.LayoutParams(-1, -2));

            // Keep quick extended drives shortcut right under embedded Config Center
            LinearLayout compatRow = a.row();
            compatRow.setClipChildren(false);
            compatRow.setWeightSum(2);
            final android.widget.Button moreDrivesBtn =
                    a.button(
                            "更多网盘快捷入口 (115/天翼…)",
                            "account-action:more-drives",
                            () -> showExtendedDrivesPicker(a, activeSiteRef[0], anchor));
            styleTvCompatPill(a, moreDrivesBtn, 0x1effffff, MainActivity.WHITE);
            LinearLayout.LayoutParams mdLp = new LinearLayout.LayoutParams(0, a.dp(38), 1f);
            mdLp.rightMargin = a.dp(10);
            mdLp.bottomMargin = a.dp(8);
            compatRow.addView(moreDrivesBtn, mdLp);

            final android.widget.Button refreshEmbedBtn =
                    a.button(
                            "刷新配置中心状态",
                            "account-action:refresh-config-center",
                            () -> {
                                refreshDriveStatesRef[0].run();
                                reloadEmbeddedConfigRef[0].run();
                                a.toast("正在刷新配置中心与登录状态…");
                            });
            styleTvCompatPill(a, refreshEmbedBtn, 0x1effffff, MainActivity.WHITE);
            LinearLayout.LayoutParams ocLp = new LinearLayout.LayoutParams(0, a.dp(38), 1f);
            ocLp.bottomMargin = a.dp(8);
            compatRow.addView(refreshEmbedBtn, ocLp);
            configEmbedBox.addView(compatRow, new LinearLayout.LayoutParams(-1, -2));
        }

        final android.widget.Button alistBtn =
                a.button(
                        "挂载 AList 网盘 / 媒体库  ·  " + AlistAccounts.list(a).size() + " 个已挂载",
                        "account-action:alist",
                        () -> {
                            dialog.dismiss();
                            AlistAccounts.openManager(a);
                        });
        UiCompat.setDefaultFocusHighlightEnabled(alistBtn, false);
        alistBtn.setSingleLine(true);
        alistBtn.setEllipsize(TextUtils.TruncateAt.END);
        alistBtn.setTextSize(13f);
        alistBtn.setBackground(a.bg(0x240a84ff, 14));
        alistBtn.setTextColor(0xffcce6ff);
        alistBtn.setOnFocusChangeListener(
                (v, f) ->
                        FocusMotion.style(
                                a,
                                alistBtn,
                                f,
                                0x240a84ff,
                                MainActivity.WHITE,
                                14,
                                0xffcce6ff,
                                MainActivity.DARK,
                                false,
                                1.015f));
        LinearLayout.LayoutParams alistLp = new LinearLayout.LayoutParams(-1, a.dp(40));
        alistLp.bottomMargin = a.dp(8);
        body.addView(alistBtn, alistLp);

        if (CatPawSettings.available(a)) {
            final android.widget.Button catItem =
                    a.button(
                            "CatPaw 本机配置",
                            "account-action:catpaw",
                            () -> {
                                dialog.dismiss();
                                CatPawSettings.choose(a);
                            });
            catItem.setBackground(a.bg(0x1effffff, 14));
            catItem.setOnFocusChangeListener(
                    (v, f) ->
                            FocusMotion.style(
                                    a,
                                    catItem,
                                    f,
                                    0x1effffff,
                                    MainActivity.WHITE,
                                    14,
                                    MainActivity.WHITE,
                                    MainActivity.DARK,
                                    false,
                                    1.015f));
            catItem.setTextSize(13.5f);
            LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(-1, a.dp(42));
            size.bottomMargin = a.dp(8);
            body.addView(catItem, size);
        }

        FrameLayout scrollViewport = new FrameLayout(a);
        scrollViewport.setTag("scroll-viewport-clip");
        scrollViewport.setClipChildren(true);
        scrollViewport.setClipToPadding(true);
        ScrollView scroller = new TvScrollView(a);
        scroller.setVerticalScrollBarEnabled(false);
        scroller.addView(body, new ScrollView.LayoutParams(-1, -2));
        scrollViewport.addView(scroller, new FrameLayout.LayoutParams(-1, -1));

        int panelW = Math.min(a.dp(740), a.windowWidth() - a.dp(64));
        int maxBodyH = Math.max(a.dp(220), a.windowHeight() - a.dp(178));
        panel.addView(scrollViewport, new LinearLayout.LayoutParams(-1, maxBodyH));

        a.gap(panel, 8);
        LinearLayout footer = a.row();
        footer.setGravity(Gravity.RIGHT);
        android.widget.Button close = a.navButton("完成", "account-close", dialog::dismiss);
        footer.addView(close, new LinearLayout.LayoutParams(a.dp(120), a.dp(40)));
        panel.addView(footer, new LinearLayout.LayoutParams(-1, -2));

        final Runnable tvLiveRefresh =
                () -> {
                    if (!dialog.isShowing() || a.isFinishing()) return;
                    if (refreshDriveStatesRef[0] != null) refreshDriveStatesRef[0].run();
                };
        activePageRefresh = tvLiveRefresh;

        dialog.setContentView(panel);
        dialog.setOnDismissListener(
                d -> {
                    if (activePageRefresh == tvLiveRefresh) activePageRefresh = null;
                    NetdiskQrBubble.dismissActive(false);
                    a.accountDialog = null;
                    if (anchor != null && anchor.isAttachedToWindow()) anchor.requestFocus();
                });
        dialog.show();
        final Window window = dialog.getWindow();
        if (window != null) {
            window.getDecorView().setTag("app-dialog");
            window.getDecorView().setMinimumWidth(0);
            window.setBackgroundDrawableResource(android.R.color.transparent);
            window.setLayout(panelW, WindowManager.LayoutParams.WRAP_CONTENT);
            window.setGravity(Gravity.CENTER);
            WindowManager.LayoutParams lp = window.getAttributes();
            lp.dimAmount = .58f;
            window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            window.setAttributes(lp);
        }
        panel.post(
                () -> {
                    if (!a.reduced) {
                        panel.setScaleX(.95f);
                        panel.setScaleY(.95f);
                        panel.setAlpha(0);
                        panel.animate()
                                .scaleX(1)
                                .scaleY(1)
                                .alpha(1)
                                .setDuration(160)
                                .setInterpolator(new DecelerateInterpolator())
                                .start();
                    }
                    View first =
                            permOk
                                    ? panel.findViewWithTag("account-drive:quark")
                                    : panel.findViewWithTag("account-storage-permission");
                    if (first != null) first.requestFocus();
                    if (activeSiteRef[0] != null) {
                        loadEmbedCategory.load("", "");
                    }
                    // Async probe for multiple unmerged subscriptions saved in ConfigLibrary
                    if (a.configStore != null) {
                        final Cms.Config snapCfg = a.config;
                        a.worker.execute(
                                () -> {
                                    try {
                                        ConfigLibrary lib =
                                                new ConfigLibrary(a.configStore.directory);
                                        java.util.List<ConfigLibrary.Entry> mergeable =
                                                new java.util.ArrayList<>();
                                        for (ConfigLibrary.Entry e : lib.entries()) {
                                            if (e != null
                                                    && !SubscriptionManager.isMergedOrigin(
                                                            e.origin)) {
                                                mergeable.add(e);
                                            }
                                        }
                                        int activeMergedCount =
                                                snapCfg != null && snapCfg.raw != null
                                                        ? SubscriptionManager.readMultiSourceMeta(
                                                                        snapCfg.raw)
                                                                .size()
                                                        : 0;
                                        if (mergeable.size() >= 2
                                                && activeMergedCount < mergeable.size()) {
                                            a.ui.post(
                                                    () -> {
                                                        if (a.isFinishing()
                                                                || !dialog.isShowing()
                                                                || multiSubMergeSlot.getChildCount()
                                                                        > 0) {
                                                            return;
                                                        }
                                                        android.widget.Button mergeAllBtn =
                                                                a.button(
                                                                        "⚡ 检测到 "
                                                                                + mergeable.size()
                                                                                + " 个已添加订阅源 · 点击合并显示全部线路与配置中心",
                                                                        "account-merge-all-subscriptions",
                                                                        () -> {
                                                                            dialog.dismiss();
                                                                            SourceController
                                                                                    .mergeSavedSubscriptions(
                                                                                            a,
                                                                                            mergeable);
                                                                        });
                                                        styleTvCompatPill(
                                                                a,
                                                                mergeAllBtn,
                                                                0x300a84ff,
                                                                0xffd8eeff);
                                                        LinearLayout.LayoutParams mlp =
                                                                new LinearLayout.LayoutParams(
                                                                        -1, a.dp(38));
                                                        mlp.bottomMargin = a.dp(10);
                                                        multiSubMergeSlot.addView(mergeAllBtn, mlp);
                                                    });
                                        }
                                    } catch (Throwable ignored) {
                                    }
                                });
                    }
                });
    }

    private static void styleTvCompatPill(
            MainActivity a, android.widget.Button item, int normalBg, int normalFg) {
        UiCompat.setDefaultFocusHighlightEnabled(item, false);
        item.setMinWidth(0);
        item.setMinimumWidth(0);
        item.setSingleLine(true);
        item.setEllipsize(TextUtils.TruncateAt.END);
        item.setTextSize(13f);
        item.setPadding(a.dp(10), 0, a.dp(10), 0);
        item.setBackground(a.bg(normalBg, 14));
        item.setTextColor(normalFg);
        item.setOnFocusChangeListener(
                (v, f) ->
                        FocusMotion.style(
                                a,
                                item,
                                f,
                                normalBg,
                                MainActivity.WHITE,
                                14,
                                normalFg,
                                MainActivity.DARK,
                                false,
                                1.015f));
    }

    private static void showExtendedDrivesPicker(
            final MainActivity a, final Cms.Site configSite, final View anchor) {
        String[] labels = new String[EXTENDED_DRIVES.length + 1];
        for (int i = 0; i < EXTENDED_DRIVES.length; i++) {
            DriveSpec d = EXTENDED_DRIVES[i];
            boolean logged = isDriveLoggedIn(a, d.key);
            labels[i] = d.tvAlias + " · " + (logged ? "已检测凭据" : d.lineSubtitle);
        }
        labels[EXTENDED_DRIVES.length] = "打开完整配置中心 (" + configSite.name + ")";
        new AppDialog.Builder(a)
                .wrapChoices()
                .setTitle("更多网盘 · " + configSite.name)
                .setItems(
                        labels,
                        (d, idx) -> {
                            if (idx == EXTENDED_DRIVES.length) {
                                new SettingsScreen(a).openConfigSiteHome(configSite);
                            } else if (idx >= 0 && idx < EXTENDED_DRIVES.length) {
                                final DriveSpec chosen = EXTENDED_DRIVES[idx];
                                a.ensureStoragePermissionForNetdisk(
                                        () ->
                                                dispatchDriveLoginAction(
                                                        a, configSite, chosen, false));
                            }
                        })
                .setNegativeButton("返回", (d, w) -> show(a, anchor))
                .show();
    }

    private static void showConfigCenterSwitcher(
            final MainActivity a,
            final java.util.List<Cms.Site> centers,
            final Cms.Site activeCenter,
            final View anchor) {
        String[] labels = new String[centers.size()];
        int checked = 0;
        for (int i = 0; i < centers.size(); i++) {
            Cms.Site c = centers.get(i);
            labels[i] = "[" + SourcePicker.siteGroup(c) + "] " + c.name;
            if (activeCenter != null && activeCenter.key.equals(c.key)) checked = i;
        }
        new AppDialog.Builder(a)
                .wrapChoices()
                .setTitle("切换当前绑定的配置中心")
                .setSingleChoiceItems(
                        labels,
                        checked,
                        (d, idx) -> {
                            d.dismiss();
                            Cms.Site picked = centers.get(idx);
                            if (a.prefs != null) {
                                a.prefs
                                        .edit()
                                        .putString(Prefs.ACCOUNT_CONFIG_CENTER_KEY, picked.key)
                                        .apply();
                            }
                            a.toast("已绑定配置中心：" + picked.name);
                            show(a, anchor);
                        })
                .setNegativeButton("返回", (d, w) -> show(a, anchor))
                .show();
    }

    private static void runSafeAccountAction(final MainActivity a, final String action) {
        a.ensureStoragePermissionForNetdisk(
                () -> {
                    try {
                        CspEngine.syncAllPluginActivities(a);
                        PluginDialogStyler.clearDirectDriveForward();
                        PluginDialogStyler.watch(a);
                        new SettingsScreen(a).accountAction(action, findConfigCenterSite(a));
                    } catch (Throwable t) {
                        AppLog.w("AccountPanel", "accountAction failed: " + action, t);
                        a.notice(a.message(t));
                    }
                });
    }

    /**
     * Resolves the direct per-drive QR login route for a given config center site without stopping
     * at the old intermediate multi-drive dialog.
     */
    static String resolveDirectDriveRoute(Cms.Site configSite, String driveKey) {
        DriveSpec matched = null;
        if (driveKey != null) {
            String clean = driveKey.trim();
            for (DriveSpec d : DRIVES) {
                if (d.key.equalsIgnoreCase(clean)) {
                    matched = d;
                    break;
                }
            }
            if (matched == null) {
                for (DriveSpec d : EXTENDED_DRIVES) {
                    if (d.key.equalsIgnoreCase(clean)) {
                        matched = d;
                        break;
                    }
                }
            }
        }
        if (matched == null) return "forward:LoginShow";
        if (configSite == null) return "forward:LoginShow";
        String api = configSite.api == null ? "" : configSite.api.toLowerCase(Locale.ROOT);
        String key = configSite.key == null ? "" : configSite.key.toLowerCase(Locale.ROOT);
        if (api.contains("panconfig") || key.contains("panconfig")) {
            if (!"LoginShow".equals(matched.panConfigCode)) {
                return "direct:" + matched.panConfigCode;
            }
            return "dynamic:" + matched.key;
        }
        if (api.contains("wexconfig")
                || api.contains("wexokconfig")
                || key.contains("wexconfig")
                || key.contains("wexokconfig")) {
            return "direct:" + matched.wexConfigCode;
        }
        if (api.contains("mydrive") || key.contains("mydrive")) {
            return "forward:LoginShow";
        }
        return "dynamic:" + matched.key;
    }

    private static void dispatchDriveLoginAction(
            final MainActivity a, final Cms.Site configSite, final DriveSpec drive) {
        dispatchDriveLoginAction(a, configSite, drive, false);
    }

    private static void dispatchDriveLoginAction(
            final MainActivity a,
            final Cms.Site configSite,
            final DriveSpec drive,
            final boolean toggleEnableOnly) {
        a.ensureStoragePermissionForNetdisk(
                () -> {
                    try {
                        CspEngine.syncAllPluginActivities(a);
                        String route = resolveDirectDriveRoute(configSite, drive.key);
                        if (toggleEnableOnly
                                && configSite != null
                                && route.startsWith("direct:")
                                && (configSite.api != null
                                                && (configSite
                                                                .api
                                                                .toLowerCase(Locale.ROOT)
                                                                .contains("wexconfig")
                                                        || configSite
                                                                .api
                                                                .toLowerCase(Locale.ROOT)
                                                                .contains("wexokconfig"))
                                        || (configSite.key != null
                                                && configSite
                                                        .key
                                                        .toLowerCase(Locale.ROOT)
                                                        .contains("wexconfig")))) {
                            PluginDialogStyler.clearDirectDriveForward();
                            PluginDialogStyler.watch(a);
                            a.sourceAction(configSite, "pankaiguan");
                            return;
                        }
                        if (!toggleEnableOnly
                                && configSite != null
                                && route.startsWith("direct:")) {
                            PluginDialogStyler.clearDirectDriveForward();
                            PluginDialogStyler.watch(a);
                            a.sourceAction(configSite, route.substring("direct:".length()));
                            return;
                        }
                        if (configSite != null && route.startsWith("dynamic:")) {
                            PluginDialogStyler.watch(a);
                            new SettingsScreen(a)
                                    .openDirectDriveConfigAction(
                                            configSite, drive.key, toggleEnableOnly);
                            return;
                        }
                        // MyDrive / LoginShow spiders: transparently auto-forward past the
                        // intermediate multi-drive dialog straight to this drive's QR login dialog.
                        PluginDialogStyler.armDirectDriveForward(a, drive.key, toggleEnableOnly);
                        if (configSite != null) {
                            a.sourceAction(configSite, "LoginShow");
                        } else {
                            new SettingsScreen(a).accountAction("LoginShow");
                        }
                    } catch (Throwable t) {
                        PluginDialogStyler.clearDirectDriveForward();
                        AppLog.w(
                                "AccountPanel", "dispatchDriveLoginAction failed: " + drive.key, t);
                        a.notice(a.message(t));
                    }
                });
    }

    /**
     * Renders the full-screen iOS secondary page "我的云盘" matching {@code IosSettingsScaffold} +
     * {@code _NetdiskAccountSheet} in {@code flutter/lib/ui/netdisk_sheet.dart}.
     */
    private static void renderMobileCloudDrivePage(final MainActivity a, final String backLabel) {
        a.applyMobileSystemBars(false);

        final Cms.Site configSite = findConfigCenterSite(a);
        final boolean hasCatPaw = CatPawSettings.available(a);
        final LinearLayout drivesHolder = a.vertical();

        FrameLayout pageRoot =
                new MainActivity.GlassFreezeFrameLayout(a, a.glassFreezeController) {
                    @Override
                    public void onWindowFocusChanged(boolean hasWindowFocus) {
                        super.onWindowFocusChanged(hasWindowFocus);
                        if (hasWindowFocus) {
                            populateDriveCards(a, drivesHolder, configSite);
                        }
                    }

                    @Override
                    protected void onDetachedFromWindow() {
                        super.onDetachedFromWindow();
                        activePageRefresh = null;
                    }
                };
        pageRoot.setTag("netdisk-account-sheet");
        GradientDrawable pageBg =
                new GradientDrawable(
                        GradientDrawable.Orientation.TOP_BOTTOM,
                        new int[] {0xff121217, 0xff050507, 0xff000000});
        pageRoot.setBackground(pageBg);
        a.root = pageRoot;
        a.setContentView(pageRoot);

        activePageRefresh =
                () -> {
                    if (drivesHolder.isAttachedToWindow()) {
                        populateDriveCards(a, drivesHolder, configSite);
                    }
                };

        LinearLayout outerCol = a.vertical();
        pageRoot.addView(outerCol, new FrameLayout.LayoutParams(-1, -1));

        // 1. iOS Secondary Navigation Header (< 返回 / 我的云盘)
        LinearLayout topNav = a.row();
        topNav.setGravity(Gravity.CENTER_VERTICAL);
        int topInset = Math.max(a.dp(28), a.statusBarHeight());
        topNav.setPadding(a.dp(20), topInset + a.dp(10), a.dp(20), a.dp(12));

        TextView backBtn = a.text("‹", 22f, Color.WHITE);
        backBtn.setTag("netdisk-back");
        backBtn.setGravity(Gravity.CENTER);
        backBtn.setPadding(0, 0, a.dp(1), a.dp(2));
        GradientDrawable backCircle = new GradientDrawable();
        backCircle.setShape(GradientDrawable.OVAL);
        backCircle.setColor(0x24ffffff);
        backCircle.setStroke(Math.max(1, a.dp(0.9f)), 0x34ffffff);
        backBtn.setBackground(backCircle);
        bindPressScale(backBtn);
        backBtn.setOnClickListener(v -> a.onBackPressed());
        LinearLayout.LayoutParams backLp = new LinearLayout.LayoutParams(a.dp(38), a.dp(38));
        backLp.rightMargin = a.dp(12);
        topNav.addView(backBtn, backLp);

        LinearLayout titleStack = a.vertical();
        TextView crumb = a.text(backLabel, 11.5f, 0x99ebebf5);
        crumb.setOnClickListener(v -> a.onBackPressed());
        titleStack.addView(crumb);

        TextView pageTitle = a.text("我的云盘", 24f, 0xfff5f5f7);
        pageTitle.setTypeface(null, Typeface.BOLD);
        titleStack.addView(pageTitle);
        topNav.addView(titleStack, new LinearLayout.LayoutParams(0, -2, 1f));
        outerCol.addView(topNav, new LinearLayout.LayoutParams(-1, -2));

        // 2. Scrollable Body matching netdisk_sheet.dart padding(20, 4, 20, 36)
        ScrollView sv = new ScrollView(a);
        sv.setVerticalScrollBarEnabled(false);
        sv.setClipToPadding(false);
        a.scroll = sv;

        LinearLayout body = a.vertical();
        body.setPadding(a.dp(20), a.dp(4), a.dp(20), a.dp(40));
        sv.addView(body, new ScrollView.LayoutParams(-1, -2));
        outerCol.addView(sv, new LinearLayout.LayoutParams(-1, 0, 1f));

        // Card A: Priority Order Banner (matches iOS `盘序优先：夸父 > 优汐 > 嘟嘟 > 阿狸`)
        if (configSite != null) {
            body.addView(buildPriorityOrderBanner(a));
            a.gap(body, 14);
        }

        // Card Group B: 4 Stacked Two-Tier iOS Drive Cards (夸父 / 优汐 / 嘟嘟 / 阿狸)
        if (configSite != null) {
            populateDriveCards(a, drivesHolder, configSite);
            body.addView(drivesHolder, new LinearLayout.LayoutParams(-1, -2));
            a.gap(body, 8);
        }

        // Card Group C: Secondary iOS Grouped Settings Card (搜索排序 / 扩展网盘 / CatPaw)
        body.addView(buildSecondarySettingsCard(a, configSite, hasCatPaw));

        if (!a.reduced) {
            outerCol.setTranslationX(a.dp(22));
            outerCol.setAlpha(0.4f);
            outerCol.animate()
                    .translationX(0f)
                    .alpha(1f)
                    .setDuration(175)
                    .setInterpolator(new DecelerateInterpolator())
                    .start();
        }
    }

    private static View buildPriorityOrderBanner(final MainActivity a) {
        LinearLayout banner = a.vertical();
        banner.setPadding(a.dp(15), a.dp(12), a.dp(15), a.dp(12));
        GradientDrawable bg = new GradientDrawable();
        bg.setShape(GradientDrawable.RECTANGLE);
        bg.setCornerRadius(a.dp(18));
        bg.setColor(0xb826262e);
        bg.setStroke(Math.max(1, a.dp(0.7f)), 0x24ffffff);
        banner.setBackground(bg);

        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);

        FrameLayout iconCircle = new FrameLayout(a);
        GradientDrawable circle = new GradientDrawable();
        circle.setShape(GradientDrawable.OVAL);
        circle.setColor(0xff0a84ff);
        iconCircle.setBackground(circle);
        iconCircle.addView(
                new VectorGlyphView(a, ICON_ARROWS_UD, Color.WHITE),
                new FrameLayout.LayoutParams(a.dp(12), a.dp(12), Gravity.CENTER));
        LinearLayout.LayoutParams icLp = new LinearLayout.LayoutParams(a.dp(20), a.dp(20));
        icLp.rightMargin = a.dp(8);
        row.addView(iconCircle, icLp);

        TextView orderTv = a.text("盘序优先：夸父 > 优汐 > 嘟嘟 > 阿狸", 13.5f, Color.WHITE);
        orderTv.setTypeface(null, Typeface.BOLD);
        orderTv.setSingleLine(true);
        orderTv.setEllipsize(TextUtils.TruncateAt.END);
        row.addView(orderTv, new LinearLayout.LayoutParams(0, -2, 1f));

        View switchBtn =
                buildIosCapsuleButton(
                        a,
                        ICON_REFRESH,
                        "切换盘序",
                        false,
                        true,
                        () -> runSafeAccountAction(a, "panSortShow"));
        LinearLayout.LayoutParams sLp = new LinearLayout.LayoutParams(-2, a.dp(30));
        sLp.leftMargin = a.dp(8);
        row.addView(switchBtn, sLp);
        banner.addView(row, new LinearLayout.LayoutParams(-1, -2));

        TextView hint =
                a.text("与电视端「🗂我的云盘┃配置」保持一致，支持优汐智1 / 夸父智1 / 嘟嘟无限2 / 阿狸原画", 11.5f, 0x99ebebf5);
        hint.setLineSpacing(a.dp(2), 1f);
        hint.setPadding(0, a.dp(6), 0, 0);
        banner.addView(hint, new LinearLayout.LayoutParams(-1, -2));
        return banner;
    }

    private static void populateDriveCards(
            final MainActivity a, final LinearLayout container, final Cms.Site configSite) {
        container.removeAllViews();
        for (DriveSpec drive : DRIVES) {
            View tile = buildIosDriveTile(a, configSite, drive);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
            lp.bottomMargin = a.dp(10);
            container.addView(tile, lp);
        }
    }

    private static View buildIosDriveTile(
            final MainActivity a, final Cms.Site configSite, final DriveSpec drive) {
        final boolean loggedIn = isDriveLoggedIn(a, drive.key);
        final boolean enabled = isDriveEnabled(a, drive.key);

        LinearLayout tile = a.vertical();
        tile.setTag("netdisk-tile-" + drive.key);
        tile.setPadding(a.dp(14), a.dp(13), a.dp(14), a.dp(12));

        GradientDrawable bg =
                new GradientDrawable(
                        GradientDrawable.Orientation.TOP_BOTTOM,
                        new int[] {0xb82e2e36, 0xb81e1e24});
        bg.setCornerRadius(a.dp(18));
        bg.setStroke(Math.max(1, a.dp(0.8f)), loggedIn ? 0x7a30d158 : 0x24ffffff);
        tile.setBackground(bg);

        // Upper Row: 40x40 rounded-11dp icon + title/provider/lines + status pill
        LinearLayout topRow = a.row();
        topRow.setGravity(Gravity.CENTER_VERTICAL);

        FrameLayout iconBox = new FrameLayout(a);
        GradientDrawable iconBg = new GradientDrawable();
        iconBg.setShape(GradientDrawable.RECTANGLE);
        iconBg.setCornerRadius(a.dp(11));
        iconBg.setColor(loggedIn ? 0x2e30d158 : 0x2e0a84ff);
        iconBox.setBackground(iconBg);
        iconBox.addView(
                new VectorGlyphView(
                        a, loggedIn ? ICON_CLOUD : ICON_QR, loggedIn ? 0xff30d158 : 0xff5ac8fa),
                new FrameLayout.LayoutParams(a.dp(20), a.dp(20), Gravity.CENTER));
        LinearLayout.LayoutParams ibLp = new LinearLayout.LayoutParams(a.dp(40), a.dp(40));
        ibLp.rightMargin = a.dp(12);
        topRow.addView(iconBox, ibLp);

        LinearLayout infoCol = a.vertical();
        LinearLayout nameRow = a.row();
        nameRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView aliasTv = a.text(drive.tvAlias, 15f, Color.WHITE);
        aliasTv.setTypeface(null, Typeface.BOLD);
        aliasTv.setSingleLine(true);
        nameRow.addView(aliasTv);

        TextView providerTv = a.text(drive.providerName, 12f, 0x99ebebf5);
        providerTv.setSingleLine(true);
        providerTv.setEllipsize(TextUtils.TruncateAt.END);
        LinearLayout.LayoutParams pvLp = new LinearLayout.LayoutParams(-2, -2);
        pvLp.leftMargin = a.dp(6);
        nameRow.addView(providerTv, pvLp);
        infoCol.addView(nameRow);

        TextView lineTv = a.text(drive.lineSubtitle, 12f, 0xb3ebebf5);
        lineTv.setSingleLine(true);
        lineTv.setEllipsize(TextUtils.TruncateAt.END);
        lineTv.setPadding(0, a.dp(3), 0, 0);
        infoCol.addView(lineTv);
        topRow.addView(infoCol, new LinearLayout.LayoutParams(0, -2, 1f));

        String badgeText = loggedIn ? (enabled ? "已登录 · 启用" : "已登录") : "未登录";
        TextView statusPill = a.text(badgeText, 11f, loggedIn ? 0xff30d158 : 0x99ebebf5);
        statusPill.setTypeface(null, Typeface.BOLD);
        statusPill.setSingleLine(true);
        statusPill.setPadding(a.dp(9), a.dp(3.5f), a.dp(9), a.dp(3.5f));
        GradientDrawable pillBg = new GradientDrawable();
        pillBg.setShape(GradientDrawable.RECTANGLE);
        pillBg.setCornerRadius(a.dp(999));
        pillBg.setColor(loggedIn ? 0x3330d158 : 0xa63a3a42);
        pillBg.setStroke(Math.max(1, a.dp(0.6f)), loggedIn ? 0x7330d158 : 0x24ffffff);
        statusPill.setBackground(pillBg);
        LinearLayout.LayoutParams spLp = new LinearLayout.LayoutParams(-2, -2);
        spLp.leftMargin = a.dp(8);
        topRow.addView(statusPill, spLp);

        tile.addView(topRow, new LinearLayout.LayoutParams(-1, -2));

        // 0.5dp Hairline Divider
        View divider = new View(a);
        divider.setBackgroundColor(0x1affffff);
        LinearLayout.LayoutParams divLp = new LinearLayout.LayoutParams(-1, 1);
        divLp.topMargin = a.dp(10);
        divLp.bottomMargin = a.dp(10);
        tile.addView(divider, divLp);

        // Lower Action Row: Primary Scan/Toggle Capsule + Manual Cookie/Token Capsule
        LinearLayout actionRow = a.row();
        actionRow.setGravity(Gravity.CENTER_VERTICAL);

        View scanBtn =
                buildIosCapsuleButton(
                        a,
                        ICON_QR,
                        loggedIn ? "账号与启用开关" : "扫码登录",
                        !loggedIn,
                        false,
                        () -> dispatchDriveLoginAction(a, configSite, drive));
        LinearLayout.LayoutParams leftLp = new LinearLayout.LayoutParams(0, a.dp(34), 1f);
        leftLp.rightMargin = a.dp(8);
        actionRow.addView(scanBtn, leftLp);

        View tokenBtn =
                buildIosCapsuleButton(
                        a,
                        ICON_PENCIL,
                        "配置 Token / Cookie",
                        false,
                        false,
                        () -> runSafeAccountAction(a, "pushCkShow"));
        LinearLayout.LayoutParams rightLp = new LinearLayout.LayoutParams(0, a.dp(34), 1f);
        actionRow.addView(tokenBtn, rightLp);

        tile.addView(actionRow, new LinearLayout.LayoutParams(-1, -2));
        return tile;
    }

    private static View buildIosCapsuleButton(
            MainActivity a,
            int iconKind,
            String label,
            boolean primary,
            boolean compact,
            Runnable onClick) {
        LinearLayout btn = a.row();
        btn.setGravity(Gravity.CENTER);
        btn.setPadding(
                a.dp(compact ? 10 : 12),
                a.dp(compact ? 4 : 6),
                a.dp(compact ? 10 : 12),
                a.dp(compact ? 4 : 6));

        GradientDrawable gd = new GradientDrawable();
        gd.setShape(GradientDrawable.RECTANGLE);
        gd.setCornerRadius(a.dp(999));
        if (primary) {
            gd.setColor(0xfff5f5f7);
        } else {
            gd.setColor(0x8c3a3a42);
            gd.setStroke(Math.max(1, a.dp(0.7f)), 0x26ffffff);
        }
        btn.setBackground(gd);

        int fg = primary ? 0xff111114 : 0xfff5f5f7;
        VectorGlyphView glyph = new VectorGlyphView(a, iconKind, fg);
        LinearLayout.LayoutParams glp =
                new LinearLayout.LayoutParams(a.dp(compact ? 12 : 14), a.dp(compact ? 12 : 14));
        glp.rightMargin = a.dp(5);
        btn.addView(glyph, glp);

        TextView tv = a.text(label, compact ? 11.5f : 12.5f, fg);
        tv.setTypeface(null, Typeface.BOLD);
        tv.setSingleLine(true);
        tv.setEllipsize(TextUtils.TruncateAt.END);
        btn.addView(tv);

        bindPressScale(btn);
        btn.setOnClickListener(v -> onClick.run());
        return btn;
    }

    private static View buildSecondarySettingsCard(
            final MainActivity a, final Cms.Site configSite, final boolean hasCatPaw) {
        LinearLayout section = a.vertical();

        TextView secHeader = a.text("更多网盘与检索设置", 12.5f, 0x99ebebf5);
        secHeader.setTypeface(null, Typeface.BOLD);
        secHeader.setPadding(a.dp(6), a.dp(2), a.dp(6), a.dp(8));
        section.addView(secHeader);

        LinearLayout card = a.vertical();
        GradientDrawable bg = new GradientDrawable();
        bg.setShape(GradientDrawable.RECTANGLE);
        bg.setCornerRadius(a.dp(18));
        bg.setColor(0xb826262e);
        bg.setStroke(Math.max(1, a.dp(0.7f)), 0x24ffffff);
        card.setBackground(bg);

        boolean addedAny = false;
        if (configSite != null) {
            card.addView(
                    buildGroupedRow(
                            a,
                            ICON_SORT,
                            0xffbf5af2,
                            "网盘搜索结果排序",
                            "自定义多网盘聚合检索时的画质与网盘展示先后",
                            () -> runSafeAccountAction(a, "panSourceSortShow")));
            addedAny = true;

            card.addView(buildGroupedDivider(a));
            card.addView(
                    buildGroupedRow(
                            a,
                            ICON_CLOUD,
                            0xff0a84ff,
                            "全部云盘授权开关面板",
                            "打开扩展原生配置面板（支持 115 / 天翼 / 移动 / 123 等扩展盘）",
                            () -> runSafeAccountAction(a, "LoginShow")));
        }

        if (hasCatPaw) {
            if (addedAny) card.addView(buildGroupedDivider(a));
            card.addView(
                    buildGroupedRow(
                            a,
                            ICON_CATPAW,
                            0xff5ac8fa,
                            "CatPaw 本机服务配置",
                            "打开内嵌 CatPaw 控制台配置代理与云盘账号",
                            () -> CatPawSettings.choose(a)));
            addedAny = true;
        }

        if (addedAny) card.addView(buildGroupedDivider(a));
        card.addView(
                buildGroupedRow(
                        a,
                        ICON_CLOUD,
                        0xff32ade6,
                        "挂载 AList 网盘 / 媒体库",
                        AlistAccounts.statusSummary(a),
                        () -> AlistAccounts.openManager(a)));

        section.addView(card, new LinearLayout.LayoutParams(-1, -2));
        return section;
    }

    private static View buildGroupedDivider(MainActivity a) {
        FrameLayout wrap = new FrameLayout(a);
        wrap.setPadding(a.dp(58), 0, a.dp(14), 0);
        View line = new View(a);
        line.setBackgroundColor(0x1affffff);
        wrap.addView(line, new FrameLayout.LayoutParams(-1, 1));
        return wrap;
    }

    private static View buildGroupedRow(
            MainActivity a,
            int iconKind,
            int accentColor,
            String title,
            String subtitle,
            Runnable onClick) {
        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(a.dp(14), a.dp(12), a.dp(14), a.dp(12));

        FrameLayout badge = new FrameLayout(a);
        GradientDrawable badgeBg = new GradientDrawable();
        badgeBg.setShape(GradientDrawable.RECTANGLE);
        badgeBg.setCornerRadius(a.dp(9));
        badgeBg.setColor((accentColor & 0x00ffffff) | 0x2e000000);
        badge.setBackground(badgeBg);
        badge.addView(
                new VectorGlyphView(a, iconKind, accentColor),
                new FrameLayout.LayoutParams(a.dp(17), a.dp(17), Gravity.CENTER));
        LinearLayout.LayoutParams badgeLp = new LinearLayout.LayoutParams(a.dp(32), a.dp(32));
        badgeLp.rightMargin = a.dp(12);
        row.addView(badge, badgeLp);

        LinearLayout textCol = a.vertical();
        TextView t = a.text(title, 14.5f, 0xfff5f5f7);
        t.setTypeface(null, Typeface.BOLD);
        t.setSingleLine(true);
        t.setEllipsize(TextUtils.TruncateAt.END);
        textCol.addView(t);

        TextView s = a.text(subtitle, 11.5f, 0x99ebebf5);
        s.setSingleLine(true);
        s.setEllipsize(TextUtils.TruncateAt.END);
        s.setPadding(0, a.dp(2), 0, 0);
        textCol.addView(s);
        row.addView(textCol, new LinearLayout.LayoutParams(0, -2, 1f));

        TextView chev = a.text("›", 18, 0x66ebebf5);
        chev.setPadding(a.dp(8), 0, 0, a.dp(1));
        row.addView(chev);

        bindPressScale(row);
        row.setOnClickListener(v -> onClick.run());
        return row;
    }

    private static void bindPressScale(View view) {
        if (Build.VERSION.SDK_INT >= 21) {
            view.setStateListAnimator(null);
        }
        view.setOnTouchListener(
                (v, ev) -> {
                    int act = ev.getActionMasked();
                    if (act == MotionEvent.ACTION_DOWN) {
                        v.animate().scaleX(0.97f).scaleY(0.97f).setDuration(90).start();
                    } else if (act == MotionEvent.ACTION_UP || act == MotionEvent.ACTION_CANCEL) {
                        v.animate().scaleX(1f).scaleY(1f).setDuration(130).start();
                    }
                    return false;
                });
    }

    private static final class VectorGlyphView extends View {
        private final int kind;
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Path path = new Path();
        private final RectF rect = new RectF();

        VectorGlyphView(MainActivity a, int kind, int color) {
            super(a);
            this.kind = kind;
            paint.setColor(color);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(Math.max(1.8f, a.dp(1.6f)));
            paint.setStrokeCap(Paint.Cap.ROUND);
            paint.setStrokeJoin(Paint.Join.ROUND);
        }

        @Override
        protected void onDraw(Canvas c) {
            float w = getWidth();
            float h = getHeight();
            if (w <= 0 || h <= 0) return;
            path.reset();
            switch (kind) {
                case ICON_CLOUD:
                    {
                        rect.set(w * 0.14f, h * 0.36f, w * 0.86f, h * 0.78f);
                        c.drawRoundRect(rect, w * 0.22f, w * 0.22f, paint);
                        rect.set(w * 0.28f, h * 0.20f, w * 0.68f, h * 0.58f);
                        c.drawArc(rect, 195f, 160f, false, paint);
                        break;
                    }
                case ICON_QR:
                    {
                        float s = w * 0.28f;
                        rect.set(w * 0.14f, h * 0.14f, w * 0.14f + s, h * 0.14f + s);
                        c.drawRoundRect(rect, w * 0.06f, w * 0.06f, paint);
                        rect.set(w * 0.86f - s, h * 0.14f, w * 0.86f, h * 0.14f + s);
                        c.drawRoundRect(rect, w * 0.06f, w * 0.06f, paint);
                        rect.set(w * 0.14f, h * 0.86f - s, w * 0.14f + s, h * 0.86f);
                        c.drawRoundRect(rect, w * 0.06f, w * 0.06f, paint);
                        c.drawLine(w * 0.58f, h * 0.58f, w * 0.84f, h * 0.58f, paint);
                        c.drawLine(w * 0.58f, h * 0.72f, w * 0.58f, h * 0.86f, paint);
                        c.drawLine(w * 0.74f, h * 0.72f, w * 0.86f, h * 0.86f, paint);
                        break;
                    }
                case ICON_ARROWS_UD:
                    {
                        c.drawLine(w * 0.34f, h * 0.22f, w * 0.34f, h * 0.78f, paint);
                        c.drawLine(w * 0.20f, h * 0.38f, w * 0.34f, h * 0.22f, paint);
                        c.drawLine(w * 0.48f, h * 0.38f, w * 0.34f, h * 0.22f, paint);
                        c.drawLine(w * 0.66f, h * 0.22f, w * 0.66f, h * 0.78f, paint);
                        c.drawLine(w * 0.52f, h * 0.62f, w * 0.66f, h * 0.78f, paint);
                        c.drawLine(w * 0.80f, h * 0.62f, w * 0.66f, h * 0.78f, paint);
                        break;
                    }
                case ICON_REFRESH:
                    {
                        rect.set(w * 0.18f, h * 0.18f, w * 0.82f, h * 0.82f);
                        c.drawArc(rect, -40f, 285f, false, paint);
                        c.drawLine(w * 0.62f, h * 0.16f, w * 0.82f, h * 0.24f, paint);
                        c.drawLine(w * 0.76f, h * 0.42f, w * 0.82f, h * 0.24f, paint);
                        break;
                    }
                case ICON_PENCIL:
                    {
                        path.moveTo(w * 0.20f, h * 0.80f);
                        path.lineTo(w * 0.26f, h * 0.60f);
                        path.lineTo(w * 0.68f, h * 0.18f);
                        path.lineTo(w * 0.82f, h * 0.32f);
                        path.lineTo(w * 0.40f, h * 0.74f);
                        path.close();
                        c.drawPath(path, paint);
                        break;
                    }
                case ICON_SORT:
                    {
                        c.drawLine(w * 0.16f, h * 0.26f, w * 0.84f, h * 0.26f, paint);
                        c.drawLine(w * 0.16f, h * 0.52f, w * 0.64f, h * 0.52f, paint);
                        c.drawLine(w * 0.16f, h * 0.78f, w * 0.44f, h * 0.78f, paint);
                        break;
                    }
                default:
                    {
                        c.drawCircle(w * 0.5f, h * 0.5f, w * 0.34f, paint);
                        c.drawCircle(w * 0.5f, h * 0.5f, w * 0.10f, paint);
                        break;
                    }
            }
        }
    }
}
