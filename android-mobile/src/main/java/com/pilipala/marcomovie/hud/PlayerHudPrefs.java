package com.pilipala.marcomovie.hud;

import android.content.Context;
import android.content.SharedPreferences;

/**
 * Device-local preferences for player HUD & touch gesture behavior.
 *
 * <p>Stored in a dedicated {@link SharedPreferences} file ({@value #PREFS_FILE}) so that {@code
 * Prefs.java} and the 46-key cross-device backup schema table remain 100% invariant.
 */
public final class PlayerHudPrefs {
    public static final String PREFS_FILE = "marco_player_hud";

    // Snake_case keys aligned with shared/ui-spec/player-hud-spec.md.
    public static final String KEY_DOUBLE_TAP_CENTER = "player_double_tap_center";
    public static final String KEY_DOUBLE_TAP_SIDES = "player_double_tap_sides";
    public static final String KEY_LONG_PRESS_RESTORE_MODE = "player_long_press_restore_mode";
    public static final String KEY_START_SPEC_HUD = "player_start_spec_hud";
    public static final String KEY_SLIM_PROGRESS = "player_slim_progress";
    public static final String KEY_SKIP_COUNTDOWN = "player_skip_countdown";

    public static final String CENTER_PLAY_PAUSE = "play_pause";
    public static final String CENTER_FULLSCREEN = "fullscreen";
    public static final String CENTER_NONE = "none";

    public static final String SIDES_SEEK_5S = "seek_5s";
    public static final String SIDES_SEEK_10S = "seek_10s";
    public static final String SIDES_SEEK_15S = "seek_15s";
    public static final String SIDES_PLAY_PAUSE = "play_pause";

    public static final String RESTORE_PREVIOUS = "previous";
    public static final String RESTORE_ONE_X = "1.0x";

    private PlayerHudPrefs() {}

    public static SharedPreferences open(Context context) {
        if (context == null) return null;
        try {
            return context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE);
        } catch (Throwable ignored) {
            return null;
        }
    }

    public static String normalizeDoubleTapCenter(String raw) {
        if (CENTER_FULLSCREEN.equals(raw)) return CENTER_FULLSCREEN;
        if (CENTER_NONE.equals(raw)) return CENTER_NONE;
        return CENTER_PLAY_PAUSE;
    }

    public static String normalizeDoubleTapSides(String raw) {
        if (SIDES_SEEK_5S.equals(raw)) return SIDES_SEEK_5S;
        if (SIDES_SEEK_15S.equals(raw)) return SIDES_SEEK_15S;
        if (SIDES_PLAY_PAUSE.equals(raw)) return SIDES_PLAY_PAUSE;
        return SIDES_SEEK_10S;
    }

    public static String normalizeLongPressRestoreMode(String raw) {
        if (RESTORE_ONE_X.equals(raw)) return RESTORE_ONE_X;
        return RESTORE_PREVIOUS;
    }

    public static String getDoubleTapCenter(Context context) {
        SharedPreferences sp = open(context);
        if (sp == null) return CENTER_PLAY_PAUSE;
        return normalizeDoubleTapCenter(sp.getString(KEY_DOUBLE_TAP_CENTER, CENTER_PLAY_PAUSE));
    }

    public static void setDoubleTapCenter(Context context, String value) {
        SharedPreferences sp = open(context);
        if (sp == null) return;
        sp.edit().putString(KEY_DOUBLE_TAP_CENTER, normalizeDoubleTapCenter(value)).apply();
    }

    public static String getDoubleTapSides(Context context) {
        SharedPreferences sp = open(context);
        if (sp == null) return SIDES_SEEK_10S;
        return normalizeDoubleTapSides(sp.getString(KEY_DOUBLE_TAP_SIDES, SIDES_SEEK_10S));
    }

    public static void setDoubleTapSides(Context context, String value) {
        SharedPreferences sp = open(context);
        if (sp == null) return;
        sp.edit().putString(KEY_DOUBLE_TAP_SIDES, normalizeDoubleTapSides(value)).apply();
    }

    public static String getLongPressRestoreMode(Context context) {
        SharedPreferences sp = open(context);
        if (sp == null) return RESTORE_PREVIOUS;
        return normalizeLongPressRestoreMode(
                sp.getString(KEY_LONG_PRESS_RESTORE_MODE, RESTORE_PREVIOUS));
    }

    public static void setLongPressRestoreMode(Context context, String value) {
        SharedPreferences sp = open(context);
        if (sp == null) return;
        sp.edit()
                .putString(KEY_LONG_PRESS_RESTORE_MODE, normalizeLongPressRestoreMode(value))
                .apply();
    }

    public static boolean isStartSpecHudEnabled(Context context) {
        SharedPreferences sp = open(context);
        return sp == null || sp.getBoolean(KEY_START_SPEC_HUD, true);
    }

    public static void setStartSpecHudEnabled(Context context, boolean enabled) {
        SharedPreferences sp = open(context);
        if (sp == null) return;
        sp.edit().putBoolean(KEY_START_SPEC_HUD, enabled).apply();
    }

    public static boolean isSlimProgressEnabled(Context context) {
        SharedPreferences sp = open(context);
        return sp == null || sp.getBoolean(KEY_SLIM_PROGRESS, true);
    }

    public static void setSlimProgressEnabled(Context context, boolean enabled) {
        SharedPreferences sp = open(context);
        if (sp == null) return;
        sp.edit().putBoolean(KEY_SLIM_PROGRESS, enabled).apply();
    }

    public static boolean isSkipCountdownEnabled(Context context) {
        SharedPreferences sp = open(context);
        return sp == null || sp.getBoolean(KEY_SKIP_COUNTDOWN, true);
    }

    public static void setSkipCountdownEnabled(Context context, boolean enabled) {
        SharedPreferences sp = open(context);
        if (sp == null) return;
        sp.edit().putBoolean(KEY_SKIP_COUNTDOWN, enabled).apply();
    }

    public static String doubleTapSidesLabel(String mode) {
        String normalized = normalizeDoubleTapSides(mode);
        if (SIDES_SEEK_5S.equals(normalized)) return "左右快退/快进 5 秒";
        if (SIDES_SEEK_15S.equals(normalized)) return "左右快退/快进 15 秒";
        if (SIDES_PLAY_PAUSE.equals(normalized)) return "全屏双击播放 / 暂停";
        return "左右快退/快进 10 秒";
    }

    public static String doubleTapCenterLabel(String mode) {
        String normalized = normalizeDoubleTapCenter(mode);
        if (CENTER_FULLSCREEN.equals(normalized)) return "切换横竖屏全屏";
        if (CENTER_NONE.equals(normalized)) return "关闭双击";
        return "播放 / 暂停";
    }

    public static String longPressRestoreLabel(String mode) {
        return RESTORE_ONE_X.equals(normalizeLongPressRestoreMode(mode)) ? "固定恢复 1.0×" : "恢复长按前倍速";
    }
}
