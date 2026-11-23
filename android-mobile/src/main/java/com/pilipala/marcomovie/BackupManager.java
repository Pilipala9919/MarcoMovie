package com.pilipala.marcomovie;

import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.net.Uri;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Shared backup/restore, wallpaper persistence, and netdisk account action dispatcher with strict
 * {@code deviceScope} ("tv" vs "mobile") isolation so cross-device backups never overwrite opposite
 * form-factor UI or decoder settings.
 */
final class BackupManager {
    private BackupManager() {}

    static void accountAction(MainActivity a, String action) {
        if (a.config != null) {
            Cms.Site fallback = null;
            for (Cms.Site site : a.config.sites) {
                if (site.api != null && site.api.contains("MyDrive")) {
                    fallback = site;
                    break;
                }
                if (fallback == null && SourceController.isConfigOrNetdiskSite(site)) {
                    fallback = site;
                }
            }
            if (fallback != null) {
                if (!a.available(fallback)) {
                    a.notice("请先在设置中启用来源扩展引擎。");
                    return;
                }
                a.sourceAction(fallback, action);
                return;
            }
        }
        a.notice("当前配置没有提供网盘账号入口，请先导入支持网盘的配置源。");
    }

    static void pickDocument(MainActivity a, int request, String mime, boolean create) {
        if (a.privateMode && (request == 45 || request == 46)) {
            a.toast("请先退出隐私空间，再导出或恢复公开备份");
            return;
        }
        try {
            Intent intent =
                    new Intent(
                            create ? Intent.ACTION_CREATE_DOCUMENT : Intent.ACTION_OPEN_DOCUMENT);
            intent.addCategory(Intent.CATEGORY_OPENABLE);
            intent.setType(mime);
            if (create) {
                String suffix = a.isTvDevice() ? "tv" : "mobile";
                intent.putExtra(Intent.EXTRA_TITLE, "MarcoMovie-" + suffix + "-backup.json");
            }
            a.startActivityForResult(intent, request);
        } catch (Exception error) {
            a.notice("当前系统未找到可用的文档选择器，请先安装文件管理器。");
        }
    }

    static void saveWallpaper(MainActivity a, InputStream stream) throws Exception {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        byte[] chunk = new byte[8192];
        int length;
        while ((length = stream.read(chunk)) != -1) {
            if (bytes.size() + length > 16 * 1024 * 1024) throw new IOException("Image too large");
            bytes.write(chunk, 0, length);
        }
        byte[] data = bytes.toByteArray();
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(data, 0, data.length, options);
        if (options.outWidth <= 0 || options.outHeight <= 0) throw new IOException("Invalid image");
        options.inSampleSize = 1;
        while (options.outWidth / options.inSampleSize > 1920
                || options.outHeight / options.inSampleSize > 1080) options.inSampleSize *= 2;
        options.inJustDecodeBounds = false;
        Bitmap image = BitmapFactory.decodeByteArray(data, 0, data.length, options);
        if (image == null) throw new IOException("Invalid image");
        File temporary = new File(a.getFilesDir(), "wallpaper.tmp");
        try {
            try (OutputStream output = new FileOutputStream(temporary)) {
                if (!image.compress(Bitmap.CompressFormat.JPEG, 90, output))
                    throw new IOException("Encoding failed");
            }
            if (!temporary.renameTo(new File(a.getFilesDir(), "wallpaper.jpg")))
                throw new IOException("Unable to save wallpaper");
        } finally {
            image.recycle();
            temporary.delete();
        }
        a.prefs.edit().putBoolean(Prefs.WALLPAPER_ENABLED, true).apply();
    }

    static JSONObject buildBackupPayload(MainActivity a) throws Exception {
        boolean tv = a.isTvDevice();
        JSONObject backup =
                new JSONObject()
                        .put("format", "MarcoMovie-1")
                        .put("schema", "marco-movie-backup")
                        .put("version", 2)
                        .put("deviceScope", tv ? Prefs.SCOPE_TV : Prefs.SCOPE_MOBILE)
                        .put("origin", a.configOrigin)
                        .put(
                                "config",
                                a.config == null ? JSONObject.NULL : new JSONObject(a.config.raw));
        JSONObject settings = new JSONObject();
        for (String key : Prefs.KEYS) {
            if (!tv
                    && (Prefs.UI_SCALE_PERCENT.equals(key)
                            || Prefs.HOME_COLUMNS.equals(key)
                            || Prefs.HOME_ROWS.equals(key)
                            || Prefs.HOME_SECTIONS.equals(key))) {
                continue;
            }
            if (a.prefs.contains(key)) {
                settings.put(key, a.prefs.getAll().get(key));
            }
        }
        for (String dataKey :
                new String[] {
                    Prefs.SELECTED_SITE,
                    Prefs.LIVE_UDPXY_URL,
                    Prefs.LIVE_EPG_URL,
                    Prefs.LIVE_SOURCES_JSON,
                    Prefs.WATCH_HISTORY,
                    Prefs.FAVORITES,
                    Prefs.GLOBAL_SEARCH_HISTORY
                }) {
            if (a.prefs.contains(dataKey)) {
                String clean = Prefs.sanitizeUserData(dataKey, a.prefs.getString(dataKey, ""));
                if (clean != null) settings.put(dataKey, clean);
            }
        }
        String savedLiveUrl = a.prefs.getString(Prefs.LIVE_URL, "");
        if (Cms.isHttp(savedLiveUrl)) {
            settings.put(Prefs.LIVE_URL, Cms.normalizeHttp(savedLiveUrl));
            settings.put(Prefs.LIVE_NAME, a.prefs.getString(Prefs.LIVE_NAME, "自定义直播源"));
        }
        backup.put("settings", settings);
        if (!tv) {
            SharedPreferences mobilePrefs = a.mobilePrefs();
            JSONObject mobileObj = new JSONObject();
            for (String mKey : Prefs.MOBILE_KEYS) {
                if (mobilePrefs.contains(mKey)) {
                    mobileObj.put(mKey, mobilePrefs.getAll().get(mKey));
                }
            }
            backup.put("mobileSettings", mobileObj);
        }
        return backup;
    }

    static void handleActivityResult(MainActivity a, int request, Uri uri) {
        if (a.privateMode && (request == 45 || request == 46)) return;
        a.worker.execute(
                () -> {
                    try {
                        if (request == 44) {
                            try (InputStream input = a.getContentResolver().openInputStream(uri)) {
                                saveWallpaper(a, input);
                            }
                        } else if (request == 45) {
                            JSONObject backup = buildBackupPayload(a);
                            try (OutputStream output =
                                    a.getContentResolver().openOutputStream(uri, "wt")) {
                                output.write(backup.toString(2).getBytes("UTF-8"));
                            }
                        } else if (request == 46) {
                            JSONObject backup;
                            try (InputStream input = a.getContentResolver().openInputStream(uri)) {
                                backup = new JSONObject(Cms.read(input, Cms.MAX_JSON));
                            }
                            if (!Prefs.isBackupObject(
                                    backup.optString("format", null),
                                    backup.optString("schema", null),
                                    backup.optInt("version", 0)))
                                throw new IOException("Invalid backup");
                            final String origin = backup.optString("origin", "");
                            final String backupScope = backup.optString("deviceScope", "");
                            final String configJson;
                            if (!backup.has("config") || backup.isNull("config")) {
                                configJson = null;
                            } else {
                                configJson = Prefs.extractBackupConfigJson(backup.opt("config"));
                                if (configJson == null)
                                    throw new IOException("Invalid backup config");
                            }
                            final Cms.Config config =
                                    configJson == null ? null : Cms.parseConfig(configJson, origin);
                            final JSONObject settings = backup.optJSONObject("settings");
                            final JSONObject mobileSettings =
                                    backup.optJSONObject("mobileSettings");
                            if (settings != null) {
                                for (String key :
                                        new String[] {
                                            Prefs.WATCH_HISTORY,
                                            Prefs.FAVORITES,
                                            Prefs.GLOBAL_SEARCH_HISTORY
                                        }) {
                                    if (!settings.has(key)) continue;
                                    JSONArray rows =
                                            new JSONArray(String.valueOf(settings.get(key)));
                                    for (int i = 0; i < rows.length(); i++) {
                                        if (Prefs.GLOBAL_SEARCH_HISTORY.equals(key)) {
                                            if (!(rows.get(i) instanceof String))
                                                throw new IOException("Invalid search history");
                                        } else {
                                            JSONObject item = rows.getJSONObject(i);
                                            if (item.optString("id").isEmpty()
                                                    || item.optString("site").isEmpty())
                                                throw new IOException("Invalid bookmark");
                                        }
                                    }
                                }
                            }
                            final boolean sameScope =
                                    Prefs.shouldRestoreDeviceSettings(backupScope, a.isTvDevice());
                            final String scopeHint =
                                    sameScope
                                            ? "将恢复片源、直播、历史收藏及当前设备端的界面与播放偏好（本地 API 密钥与网盘授权保持不变）。"
                                            : "检测到跨形态备份文件：仅恢复片源、直播源、收藏与观看历史，不会覆盖本端的界面布局与解码器设置。";
                            a.ui.post(
                                    () ->
                                            new AppDialog.Builder(a)
                                                    .setTitle("还原备份？")
                                                    .setMessage(scopeHint)
                                                    .setNegativeButton("取消", null)
                                                    .setPositiveButton(
                                                            "还原",
                                                            (d, i) -> {
                                                                try {
                                                                    int oldScale =
                                                                            a.isTvDevice()
                                                                                    ? a.prefs
                                                                                            .getInt(
                                                                                                    Prefs
                                                                                                            .UI_SCALE_PERCENT,
                                                                                                    100)
                                                                                    : a.mobilePrefs()
                                                                                            .getInt(
                                                                                                    Prefs
                                                                                                            .MOBILE_UI_SCALE_PERCENT,
                                                                                                    100);
                                                                    restoreSettingsScoped(
                                                                            a,
                                                                            settings,
                                                                            mobileSettings,
                                                                            backupScope);
                                                                    if (config != null)
                                                                        a.saveConfig(
                                                                                config, origin);
                                                                    else a.refresh();
                                                                    int newScale =
                                                                            a.isTvDevice()
                                                                                    ? a.prefs
                                                                                            .getInt(
                                                                                                    Prefs
                                                                                                            .UI_SCALE_PERCENT,
                                                                                                    100)
                                                                                    : a.mobilePrefs()
                                                                                            .getInt(
                                                                                                    Prefs
                                                                                                            .MOBILE_UI_SCALE_PERCENT,
                                                                                                    100);
                                                                    if (oldScale != newScale)
                                                                        a.recreate();
                                                                } catch (Exception error) {
                                                                    AppLog.w(
                                                                            "BackupManager",
                                                                            "restoreSettings failed",
                                                                            error);
                                                                    a.notice("备份无法还原。");
                                                                }
                                                            })
                                                    .show());
                            return;
                        }
                        a.ui.post(
                                () -> {
                                    a.refresh();
                                    a.toast(request == 45 ? "备份已保存" : "壁纸已更新");
                                });
                    } catch (Exception error) {
                        AppLog.w("BackupManager", "file result " + request + " failed", error);
                        a.ui.post(() -> a.notice("文件无法处理。请检查文件格式与可用存储空间。"));
                    }
                });
    }

    /** Legacy TV restore entry kept compatible with TV instrumentation probes. */
    static void restoreSettings(MainActivity a, JSONObject settings) {
        restoreSettingsScoped(a, settings, null, a.isTvDevice() ? Prefs.SCOPE_TV : "");
    }

    static void restoreSettingsScoped(
            MainActivity a, JSONObject settings, JSONObject mobileSettings, String backupScope) {
        boolean tv = a.isTvDevice();
        boolean fullDeviceSettings = Prefs.shouldRestoreDeviceSettings(backupScope, tv);
        if (settings != null) {
            SharedPreferences.Editor edit = a.prefs.edit();
            for (String key : Prefs.KEYS) {
                if (!fullDeviceSettings && !Prefs.CROSS_FORM_SAFE_KEYS.contains(key)) {
                    continue;
                }
                if (!tv
                        && (Prefs.UI_SCALE_PERCENT.equals(key)
                                || Prefs.HOME_COLUMNS.equals(key)
                                || Prefs.HOME_ROWS.equals(key)
                                || Prefs.HOME_SECTIONS.equals(key))) {
                    continue;
                }
                Object clean = Prefs.sanitizeSetting(key, settings.opt(key));
                if (clean instanceof Boolean) edit.putBoolean(key, (Boolean) clean);
                else if (clean instanceof Float) edit.putFloat(key, (Float) clean);
                else if (clean instanceof Integer) edit.putInt(key, (Integer) clean);
            }
            for (String dataKey :
                    new String[] {
                        Prefs.SELECTED_SITE,
                        Prefs.LIVE_UDPXY_URL,
                        Prefs.LIVE_EPG_URL,
                        Prefs.LIVE_SOURCES_JSON,
                        Prefs.LIVE_URL,
                        Prefs.LIVE_NAME,
                        Prefs.WATCH_HISTORY,
                        Prefs.FAVORITES,
                        Prefs.GLOBAL_SEARCH_HISTORY
                    }) {
                if (settings.has(dataKey)) {
                    String cleanData = Prefs.sanitizeUserData(dataKey, settings.opt(dataKey));
                    if (cleanData != null) edit.putString(dataKey, cleanData);
                }
            }
            edit.apply();
            a.reduced = a.prefs.getBoolean(Prefs.REDUCED, false);
        }
        if (!tv && fullDeviceSettings && mobileSettings != null) {
            SharedPreferences.Editor mEdit = a.mobilePrefs().edit();
            for (String mKey : Prefs.MOBILE_KEYS) {
                Object clean = Prefs.sanitizeMobileSetting(mKey, mobileSettings.opt(mKey));
                if (clean instanceof Boolean) mEdit.putBoolean(mKey, (Boolean) clean);
                else if (clean instanceof Float) mEdit.putFloat(mKey, (Float) clean);
                else if (clean instanceof Integer) mEdit.putInt(mKey, (Integer) clean);
                else if (clean instanceof String) mEdit.putString(mKey, (String) clean);
            }
            mEdit.apply();
        }
    }
}
