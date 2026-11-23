package com.pilipala.marcomovie;

import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

/**
 * Centralized preference keys, default values, and backup/restore range validation. Pure Java so
 * offline unit checks can verify every setting constraint without Android framework dependencies.
 */
final class Prefs {
    static final String FILE = "movie";
    static final String MOBILE_FILE = "movie_mobile";
    static final String TV_FILE = "movie_tv";
    static final String SECRETS_FILE = "movie_secrets";

    static final String SCOPE_MOBILE = "mobile";
    static final String SCOPE_TV = "tv";

    // User-facing appearance & playback preferences included in backups.
    static final String UI_SCALE_PERCENT = "ui_scale_percent";
    static final String NAV_SCALE_PERCENT = "nav_scale_percent";
    static final String TV_DOCK_POSITION = "tv_dock_position";
    static final String TV_NAVIGATION_MODE = "tv_navigation_mode";
    static final String TV_AMBIENT_PERCENT = "tv_ambient_percent";
    static final String TV_BG_MODE = "tv_bg_mode";
    static final String TV_GLOW_PRESET = "tv_glow_preset";
    static final String TV_GLOW_COLOR_LEFT = "tv_glow_color_left";
    static final String TV_GLOW_COLOR_RIGHT = "tv_glow_color_right";
    static final String TV_PLAYER_STYLE = "tv_player_style";
    static final String STARTUP_ANIMATION = "startup_animation";
    static final String SHOW_HERO_BANNER = "show_hero_banner";
    static final String HOME_AMBIENT = "home_ambient";
    static final String HOME_COLUMNS = "home_columns";
    static final String HOME_ROWS = "home_rows";
    static final String HOME_SECTIONS = "home_sections";
    static final String WALLPAPER_ENABLED = "wallpaper_enabled";
    static final String WALLPAPER_DIM = "wallpaper_dim";
    static final String REDUCED = "reduced";
    static final String REDUCED_TRANSPARENCY = "reduced_transparency";
    static final String PLAYER_ENGINE = "player_engine";
    static final String VIDEO_OUTPUT = "video_output";
    static final String DECODER_MODE = "decoder_mode";
    static final String SOFTWARE_AUDIO = "software_audio";
    static final String PREFER_AAC = "prefer_aac";
    static final String ASPECT = "aspect";
    static final String BUFFER_SECONDS = "buffer_seconds";
    static final String PLAY_SPEED = "play_speed";
    static final String AUTO_NEXT = "auto_next";
    static final String REPEAT_MODE = "repeat_mode";
    static final String SKIP_INTRO = "skip_intro";
    static final String SKIP_OUTRO = "skip_outro";
    static final String SUBTITLE_SIZE = "subtitle_size";
    static final String SUBTITLE_SIZE_SP = SUBTITLE_SIZE;
    static final String SUBTITLE_BOTTOM = "subtitle_bottom";
    static final String SUBTITLE_STYLE = "subtitle_style";
    static final String SUBTITLE_BG_STYLE = SUBTITLE_STYLE;
    static final String SUBTITLE_WEIGHT = "subtitle_weight";
    static final String SUBTITLE_OFFSET_X = "subtitle_offset_x";
    static final String SKIP_INTRO_SECONDS = SKIP_INTRO;
    static final String SKIP_OUTRO_SECONDS = SKIP_OUTRO;
    static final String TUNNELED_PLAYBACK = "tunneled_playback";
    static final String DANMAKU_DEFAULT = "danmaku_default";
    static final String PICTURE_EFFECT = "picture_effect";
    static final String AUDIO_EFFECT = "audio_effect";
    static final String SEARCH_THREADS = "search_threads";
    static final String SEARCH_TIMEOUT = "search_timeout";
    static final String EPISODES_DESCENDING = "episodes_descending";
    static final String LIVE_HIGH_QUALITY = "live_high_quality";
    static final String LIVE_MERGE_SOURCES = "live_merge_sources";

    // Runtime state & user data keys (excluded from settings-only reset/restore).
    static final String ORIGIN = "origin";
    static final String LIVE_URL = "live_url";
    static final String LIVE_NAME = "live_name";
    static final String LIVE_SOURCES_JSON = "live_sources_json";
    static final String LIVE_UDPXY_URL = "live_udpxy_url";
    static final String LIVE_EPG_URL = "live_epg_url";
    static final String LIVE_STREAM_METRICS = "live_stream_metrics";
    static final String LIVE_FAVORITE_CHANNELS = "live_favorite_channels";
    static final String LIVE_BLOCKED_GROUPS = "live_blocked_groups";
    static final String LIVE_LAST_SOURCE_URL = "live_last_source_url";
    static final String SELECTED_SITE = "selected_site";
    static final String PREFERRED_SITE = "preferred_site_identity";
    static final String PREFERRED_LINE = "preferred_line";
    static final String LOADING_SITE = "loading_site";
    static final String EXPERIMENTAL_CSP = "experimental_csp";
    static final String ONLY_ALLOW_HTTPS_PLUGINS = "only_allow_https_plugins";
    static final String FAVORITES = "favorites";
    static final String WATCH_HISTORY = "watch_history";
    static final String GLOBAL_SEARCH_HISTORY = "global_search_history";
    static final String PHONETIC_TITLES = "phonetic_titles";
    // Leave the unversioned derived cache untouched for rollback; never import it into V2.
    static final String PHONETIC_PUBLIC_TITLES_V2 = "phonetic_public_titles_v2";

    // Multi-device cloud (WebDAV) & LAN sync keys (kept outside KEYS so UI reset preserves sync).
    static final String WEBDAV_URL = "webdav_url";
    static final String WEBDAV_USER = "webdav_user";
    static final String WEBDAV_PASS = "webdav_pass";
    static final String WEBDAV_AUTO = "webdav_auto";
    static final String WEBDAV_SYNC_SUBS = "webdav_sync_subs";
    static final String SYNC_TOMBSTONES = "sync_tombstones";
    static final String SYNC_LAST_TIME = "sync_last_time";
    static final String SYNC_LAST_STATUS = "sync_last_status";

    // Mobile iOS-aligned shell preferences (kept outside KEYS to preserve cross-device backup
    // schema table invariants).
    static final String MOBILE_GLASS_INTENSITY = "mobile_glass_intensity";
    static final String MOBILE_POSTER_DENSITY = "mobile_poster_density";
    static final String MOBILE_CARD_SUBTITLE = "mobile_card_subtitle";
    static final String MOBILE_SHOW_HISTORY = "mobile_show_history";
    static final String VIDEO_SKIP_RECORDS = "video_skip_records";
    static final String VIDEO_SUBTITLE_RECORDS = "video_subtitle_records";
    static final String VIDEO_AUDIO_RECORDS = "video_audio_records";
    static final String AUDIO_TRACK_PREFERENCE = "audio_track_preference";
    static final String PLAYER_ALWAYS_SHOW_CLOCK = "player_always_show_clock";
    static final String TV_PLAYER_TOP_RIGHT_HUD = "tv_player_top_right_hud";
    static final String TV_PLAYER_TOOLBAR_ORDER = "tv_player_toolbar_order";
    static final String CAST_ENABLED = "cast_enabled";
    static final String CAST_DEVICE_UUID = "cast_device_uuid";
    static final String CAST_DEVICE_NAME = "cast_device_name";
    static final String SPIDER_GATEWAY_ENABLED = "spider_gateway_enabled";
    static final String SPIDER_GATEWAY_TOKEN = "spider_gateway_token";
    static final String SPIDER_GATEWAY_PORT = "spider_gateway_port";
    static final String SPIDER_GATEWAY_NAME = "spider_gateway_name";
    static final String CRASH_LAST_EXIT_TS = "crash_last_exit_ts";
    static final String ANIME4K_ENABLED = "anime4k_enabled";
    static final String HDR_TONE_MAPPING = "hdr_tone_mapping";
    static final String HLS_PROXY_ENABLED = "hls_proxy_enabled";
    static final String HLS_AD_STRIP = "hls_ad_strip";
    static final String MEDIA_CACHE_MB = "media_cache_mb";
    static final String LOUDNESS_BOOST = "loudness_boost";
    static final String WEBVIEW_JS_FALLBACK = "webview_js_fallback";
    static final String NATIVE_PYTHON_ENABLED = "native_python_enabled";
    static final String MPV_UNSAFE_DIRECT_CODECS = "mpv_unsafe_direct_codecs";
    static final String SUBSCRIPTION_AUTO_UPDATE = "subscription_auto_update";
    static final String SUBSCRIPTION_LAST_AUTO_UPDATE = "subscription_last_auto_update";
    static final String SUBSCRIPTION_LAST_AUTO_STATUS = "subscription_last_auto_status";
    static final String ACCOUNT_CONFIG_CENTER_KEY = "account_config_center_key";

    // Mobile-exclusive preferences stored in MOBILE_FILE ("movie_mobile").
    static final String MOBILE_UI_SCALE_PERCENT = "mobile_ui_scale_percent";
    static final String NAV_STYLE = "nav_style";
    static final String NAV_SCROLL_BEHAVIOR = "nav_scroll_behavior";
    static final String COVER_AMBIENT = "cover_ambient";
    static final String ACCENT_PRESET = "accent_preset";
    static final String HOME_MODE = "home_mode";
    static final String HOME_CAROUSEL = "home_carousel";
    static final String SEARCH_PLATFORM_SIDEBAR = "search_platform_sidebar";
    static final String DETAIL_TAP_MODE = "detail_tap_mode";
    static final String EPISODE_CLEAN_MODE = "episode_clean_mode";
    static final String SWIPE_SWAP_LR = "swipe_swap_lr";
    static final String REMEMBER_SOURCE_BRIGHTNESS = "remember_source_brightness";
    static final String SOURCE_BRIGHTNESS_MAP = "source_brightness_map";
    static final String LONG_PRESS_SPEED = "long_press_speed";
    static final String VERTICAL_SWIPE_EPISODE = "vertical_swipe_episode";
    static final String LETTERBOX_BLUR = "letterbox_blur";
    static final String PLAYER_CORNER_HUD = "player_corner_hud";
    static final String MINI_PROGRESS_BAR = "mini_progress_bar";
    static final String BACKGROUND_PLAY = "background_play";
    static final String AUTO_PIP = "auto_pip";
    static final String AUTO_SWITCH_KERNEL = "auto_switch_kernel";
    static final String PLAYER_BUTTON_ORDER = "player_button_order";
    static final String TMDB_ENABLED = "tmdb_enabled";
    static final String TMDB_API_PROXY = "tmdb_api_proxy";
    static final String TMDB_IMAGE_PROXY = "tmdb_image_proxy";
    static final String TMDB_LANGUAGE = "tmdb_language";
    static final String THEINTRODB_AUTO_SKIP = "theintrodb_auto_skip";
    static final String AI_ENABLED = "ai_enabled";
    static final String AI_PROVIDER = "ai_provider";
    static final String AI_BASE_URL = "ai_base_url";
    static final String AI_MODEL = "ai_model";
    static final String AI_CLEAN_SEARCH = "ai_clean_search";
    static final String AI_TRANSLATE_SUB = "ai_translate_sub";
    static final String AI_PY_SECURITY_CHECK = "ai_py_security_check";
    static final String SUBTITLE_BILINGUAL = "subtitle_bilingual";
    static final String DANMAKU_AREA = "danmaku_area";
    static final String DANMAKU_OPACITY = "danmaku_opacity";
    static final String DANMAKU_SPEED = "danmaku_speed";
    static final String DANMAKU_SOURCES_JSON = "danmaku_sources_json";

    // Device-local credentials stored ONLY in SECRETS_FILE ("movie_secrets"), never plain-exported.
    static final String SECRET_TMDB_API_KEY = "tmdb_api_key";
    static final String SECRET_AI_API_KEY = "ai_api_key";
    static final String SECRET_MDBLIST_API_KEY = "mdblist_api_key";
    static final String SECRET_TRAKT_CLIENT_ID = "trakt_client_id";
    static final String SECRET_TRAKT_TOKEN = "trakt_access_token";
    static final String SECRET_BANGUMI_TOKEN = "bangumi_access_token";
    static final String SECRET_BANGUMI_USERNAME = "bangumi_username";
    static final String SECRET_DOUBAN_COOKIE = "douban_cookie";
    static final String SECRET_ASSRT_TOKEN = "assrt_token";
    static final String SECRET_OPENSUBTITLES_KEY = "opensubtitles_api_key";
    static final String SECRET_DANDAN_APP_ID = "dandan_app_id";
    static final String SECRET_DANDAN_SECRET = "dandan_app_secret";

    static final String DEFAULT_PLAYER_BUTTON_ORDER =
            "episodes,lines,speed,subtitles,online-sub,ai-sub,danmaku-tool,aspect,decoder,pip-tool,external-player,more";

    // HUD bitmask flags for PLAYER_CORNER_HUD
    static final int HUD_CLOCK = 1;
    static final int HUD_BATTERY = 2;
    static final int HUD_NET_SPEED = 4;
    static final int HUD_RESOLUTION = 8;
    static final int HUD_FPS = 16;

    // Appearance & playback settings exported/restored in backups; update the Prefs.KEYS.length
    // assertion in ReviewFixChecks.java whenever keys are added or removed.
    static final String[] KEYS = {
        UI_SCALE_PERCENT,
        NAV_SCALE_PERCENT,
        TV_DOCK_POSITION,
        TV_NAVIGATION_MODE,
        TV_AMBIENT_PERCENT,
        TV_BG_MODE,
        TV_GLOW_PRESET,
        TV_GLOW_COLOR_LEFT,
        TV_GLOW_COLOR_RIGHT,
        TV_PLAYER_STYLE,
        STARTUP_ANIMATION,
        SHOW_HERO_BANNER,
        HOME_AMBIENT,
        HOME_COLUMNS,
        HOME_ROWS,
        HOME_SECTIONS,
        WALLPAPER_ENABLED,
        WALLPAPER_DIM,
        REDUCED,
        REDUCED_TRANSPARENCY,
        PLAYER_ENGINE,
        VIDEO_OUTPUT,
        DECODER_MODE,
        SOFTWARE_AUDIO,
        PREFER_AAC,
        TUNNELED_PLAYBACK,
        ASPECT,
        BUFFER_SECONDS,
        PLAY_SPEED,
        AUTO_NEXT,
        REPEAT_MODE,
        SKIP_INTRO,
        SKIP_OUTRO,
        SUBTITLE_SIZE,
        SUBTITLE_BOTTOM,
        SUBTITLE_STYLE,
        SUBTITLE_WEIGHT,
        SUBTITLE_OFFSET_X,
        DANMAKU_DEFAULT,
        PICTURE_EFFECT,
        AUDIO_EFFECT,
        SEARCH_THREADS,
        SEARCH_TIMEOUT,
        EPISODES_DESCENDING,
        LIVE_HIGH_QUALITY,
        LIVE_MERGE_SOURCES
    };

    static final String[] MOBILE_KEYS = {
        MOBILE_UI_SCALE_PERCENT,
        NAV_STYLE,
        NAV_SCROLL_BEHAVIOR,
        COVER_AMBIENT,
        ACCENT_PRESET,
        HOME_MODE,
        HOME_CAROUSEL,
        SEARCH_PLATFORM_SIDEBAR,
        DETAIL_TAP_MODE,
        EPISODE_CLEAN_MODE,
        SWIPE_SWAP_LR,
        REMEMBER_SOURCE_BRIGHTNESS,
        LONG_PRESS_SPEED,
        VERTICAL_SWIPE_EPISODE,
        LETTERBOX_BLUR,
        PLAYER_CORNER_HUD,
        MINI_PROGRESS_BAR,
        BACKGROUND_PLAY,
        AUTO_PIP,
        AUTO_SWITCH_KERNEL,
        PLAYER_BUTTON_ORDER,
        TMDB_ENABLED,
        TMDB_API_PROXY,
        TMDB_IMAGE_PROXY,
        TMDB_LANGUAGE,
        THEINTRODB_AUTO_SKIP,
        AI_ENABLED,
        AI_PROVIDER,
        AI_BASE_URL,
        AI_MODEL,
        AI_CLEAN_SEARCH,
        AI_TRANSLATE_SUB,
        AI_PY_SECURITY_CHECK,
        SUBTITLE_BILINGUAL,
        DANMAKU_AREA,
        DANMAKU_OPACITY,
        DANMAKU_SPEED,
        DANMAKU_SOURCES_JSON
    };

    static final Set<String> CROSS_FORM_SAFE_KEYS =
            Collections.unmodifiableSet(
                    new HashSet<>(
                            Arrays.asList(
                                    AUTO_NEXT,
                                    REPEAT_MODE,
                                    SKIP_INTRO,
                                    SKIP_OUTRO,
                                    EPISODES_DESCENDING,
                                    LIVE_HIGH_QUALITY,
                                    LIVE_MERGE_SOURCES,
                                    HLS_PROXY_ENABLED,
                                    HLS_AD_STRIP,
                                    WEBVIEW_JS_FALLBACK,
                                    NATIVE_PYTHON_ENABLED,
                                    SUBSCRIPTION_AUTO_UPDATE)));

    private static final Set<String> MOBILE_BOOLEAN_KEYS =
            Collections.unmodifiableSet(
                    new HashSet<>(
                            Arrays.asList(
                                    COVER_AMBIENT,
                                    HOME_CAROUSEL,
                                    SEARCH_PLATFORM_SIDEBAR,
                                    SWIPE_SWAP_LR,
                                    REMEMBER_SOURCE_BRIGHTNESS,
                                    LETTERBOX_BLUR,
                                    MINI_PROGRESS_BAR,
                                    BACKGROUND_PLAY,
                                    AUTO_PIP,
                                    AUTO_SWITCH_KERNEL,
                                    TMDB_ENABLED,
                                    THEINTRODB_AUTO_SKIP,
                                    AI_ENABLED,
                                    AI_CLEAN_SEARCH,
                                    AI_TRANSLATE_SUB,
                                    AI_PY_SECURITY_CHECK,
                                    SUBTITLE_BILINGUAL)));

    private static final Map<String, int[]> MOBILE_INT_RANGES;
    private static final Set<String> ALLOWED_BUTTON_TOKENS =
            Collections.unmodifiableSet(
                    new HashSet<>(
                            Arrays.asList(
                                    "prev-episode",
                                    "next-episode",
                                    "episodes",
                                    "lines",
                                    "speed",
                                    "aspect",
                                    "subtitles",
                                    "online-sub",
                                    "ai-sub",
                                    "fullscreen-tool",
                                    "audio-tracks",
                                    "decoder",
                                    "danmaku-tool",
                                    "skip-intro-tool",
                                    "skip-outro-tool",
                                    "repeat-tool",
                                    "pip-tool",
                                    "external-player",
                                    "restart-tool",
                                    "more")));

    private static final Set<String> BOOLEAN_KEYS =
            Collections.unmodifiableSet(
                    new HashSet<>(
                            Arrays.asList(
                                    STARTUP_ANIMATION,
                                    SHOW_HERO_BANNER,
                                    HOME_AMBIENT,
                                    WALLPAPER_ENABLED,
                                    REDUCED,
                                    REDUCED_TRANSPARENCY,
                                    AUTO_NEXT,
                                    DANMAKU_DEFAULT,
                                    SOFTWARE_AUDIO,
                                    PREFER_AAC,
                                    TUNNELED_PLAYBACK,
                                    EPISODES_DESCENDING,
                                    LIVE_HIGH_QUALITY,
                                    LIVE_MERGE_SOURCES,
                                    ANIME4K_ENABLED,
                                    HDR_TONE_MAPPING,
                                    HLS_PROXY_ENABLED,
                                    HLS_AD_STRIP,
                                    WEBVIEW_JS_FALLBACK,
                                    NATIVE_PYTHON_ENABLED,
                                    SUBSCRIPTION_AUTO_UPDATE)));

    private static final Map<String, int[]> INT_RANGES;

    static {
        Map<String, int[]> ranges = new HashMap<>();
        ranges.put(HOME_COLUMNS, new int[] {5, 8});
        ranges.put(NAV_SCALE_PERCENT, new int[] {85, 140});
        ranges.put(TV_DOCK_POSITION, new int[] {0, 1});
        ranges.put(TV_NAVIGATION_MODE, new int[] {0, 1});
        ranges.put(TV_AMBIENT_PERCENT, new int[] {0, 100});
        ranges.put(TV_BG_MODE, new int[] {0, 3});
        ranges.put(TV_GLOW_PRESET, new int[] {0, 6});
        ranges.put(TV_GLOW_COLOR_LEFT, new int[] {0, 0xFFFFFF});
        ranges.put(TV_GLOW_COLOR_RIGHT, new int[] {0, 0xFFFFFF});
        ranges.put(TV_PLAYER_STYLE, new int[] {0, 1});
        ranges.put(HOME_ROWS, new int[] {1, 4});
        ranges.put(HOME_SECTIONS, new int[] {0, 5});
        ranges.put(WALLPAPER_DIM, new int[] {0, 100});
        ranges.put(PLAYER_ENGINE, new int[] {0, 3});
        ranges.put(VIDEO_OUTPUT, new int[] {0, 1});
        ranges.put(DECODER_MODE, new int[] {0, 2});
        ranges.put(REPEAT_MODE, new int[] {0, 2});
        ranges.put(ASPECT, new int[] {0, 4});
        ranges.put(BUFFER_SECONDS, new int[] {15, 50});
        ranges.put(SKIP_INTRO, new int[] {0, 180});
        ranges.put(SKIP_OUTRO, new int[] {0, 180});
        ranges.put(SUBTITLE_SIZE, new int[] {25, 65});
        ranges.put(SUBTITLE_BOTTOM, new int[] {0, 180});
        ranges.put(SUBTITLE_STYLE, new int[] {0, 7});
        ranges.put(SUBTITLE_WEIGHT, new int[] {0, 100});
        ranges.put(SUBTITLE_OFFSET_X, new int[] {-100, 100});
        ranges.put(PICTURE_EFFECT, new int[] {0, 3});
        ranges.put(AUDIO_EFFECT, new int[] {0, 3});
        ranges.put(SEARCH_THREADS, new int[] {2, 6});
        ranges.put(SEARCH_TIMEOUT, new int[] {10, 30});
        ranges.put(MEDIA_CACHE_MB, new int[] {0, 1024});
        ranges.put(LOUDNESS_BOOST, new int[] {0, 15});
        INT_RANGES = Collections.unmodifiableMap(ranges);

        Map<String, int[]> mr = new HashMap<>();
        mr.put(MOBILE_UI_SCALE_PERCENT, new int[] {90, 120});
        mr.put(NAV_STYLE, new int[] {0, 1});
        mr.put(NAV_SCROLL_BEHAVIOR, new int[] {0, 2});
        mr.put(ACCENT_PRESET, new int[] {0, 7});
        mr.put(HOME_MODE, new int[] {0, 1});
        mr.put(DETAIL_TAP_MODE, new int[] {0, 2});
        mr.put(EPISODE_CLEAN_MODE, new int[] {0, 2});
        mr.put(VERTICAL_SWIPE_EPISODE, new int[] {0, 2});
        mr.put(PLAYER_CORNER_HUD, new int[] {0, 31});
        mr.put(DANMAKU_AREA, new int[] {0, 3});
        mr.put(DANMAKU_OPACITY, new int[] {20, 100});
        mr.put(DANMAKU_SPEED, new int[] {0, 2});
        MOBILE_INT_RANGES = Collections.unmodifiableMap(mr);
    }

    private Prefs() {}

    /** Unset mode preserves saved right/top placement; a fresh TV defaults to the left rail. */
    static boolean useTvLeftDock(boolean television, boolean hasLegacyPosition, int mode) {
        return television && (mode == 1 || (mode != 0 && mode != 1 && !hasLegacyPosition));
    }

    static float tvAmbientStrength(int percent) {
        return Math.max(0, Math.min(100, percent)) / 100f;
    }

    static final int BG_MODE_ADAPTIVE = 0;
    static final int BG_MODE_GRADIENT = 1;
    static final int BG_MODE_WALLPAPER = 2;
    static final int BG_MODE_DARK = 3;

    static int clampBgMode(int mode) {
        return Math.max(BG_MODE_ADAPTIVE, Math.min(BG_MODE_DARK, mode));
    }

    static int clampGlowPreset(int preset) {
        return Math.max(0, Math.min(6, preset));
    }

    static int clampRgb24(int rgb) {
        return rgb & 0xFFFFFF;
    }

    /** Resolves effective TV background mode with backward compatibility for legacy flags. */
    static int resolveTvBgMode(
            boolean hasExplicitMode,
            int explicitMode,
            boolean wallpaperEnabled,
            boolean homeAmbient) {
        if (hasExplicitMode) return clampBgMode(explicitMode);
        if (wallpaperEnabled) return BG_MODE_WALLPAPER;
        return homeAmbient ? BG_MODE_ADAPTIVE : BG_MODE_DARK;
    }

    /**
     * Validates a candidate setting from a backup payload. Returns a sanitized {@link Boolean},
     * {@link Float}, or {@link Integer} ready to store, or {@code null} if the key is unknown or
     * the value is out of range.
     */
    static Object sanitizeSetting(String key, Object value) {
        if (key == null || value == null) return null;
        if (UI_SCALE_PERCENT.equals(key)) {
            return value instanceof Number
                    ? TvLayoutPolicy.percent(((Number) value).intValue())
                    : null;
        }
        if (PLAY_SPEED.equals(key)) {
            if (value instanceof Number) {
                float speed = ((Number) value).floatValue();
                if (speed >= .5f && speed <= 2f) return speed;
            }
            return null;
        }
        if (BOOLEAN_KEYS.contains(key)) {
            return value instanceof Boolean ? value : null;
        }
        int[] range = INT_RANGES.get(key);
        if (range == null || !(value instanceof Number)) return null;
        int n = ((Number) value).intValue();
        return n >= range[0] && n <= range[1] ? n : null;
    }

    static int clampWallpaperDim(int dim) {
        return Math.max(0, Math.min(100, dim));
    }

    static int clampSubtitleSize(int size) {
        return Math.max(25, Math.min(65, size));
    }

    static int clampSubtitleBottom(int dp) {
        return Math.max(0, Math.min(180, dp));
    }

    static int clampSubtitleStyle(int style) {
        return Math.max(0, Math.min(7, style));
    }

    static int clampSubtitleWeight(int weight) {
        return Math.max(0, Math.min(100, weight));
    }

    static int clampSubtitleOffsetX(int offset) {
        return Math.max(-100, Math.min(100, offset));
    }

    static int clampNavScale(int percent) {
        return Math.max(85, Math.min(140, percent));
    }

    static int clampSubtitleBgStyle(int style) {
        return clampSubtitleStyle(style);
    }

    static int clampSkipSeconds(int seconds) {
        return Math.max(0, Math.min(180, seconds));
    }

    static int clampSearchTimeoutSeconds(int seconds) {
        return Math.max(10, Math.min(30, seconds));
    }

    static boolean isBackupObject(String format, String schema, int version) {
        return "MarcoMovie-1".equals(format)
                || ("marco-movie-backup".equals(schema)
                        && (version == 0 || version == 1 || version == 2));
    }

    static boolean shouldRestoreDeviceSettings(String backupScope, boolean targetIsTv) {
        String scope =
                backupScope == null ? "" : backupScope.trim().toLowerCase(java.util.Locale.ROOT);
        if (targetIsTv) {
            return scope.isEmpty() || SCOPE_TV.equals(scope);
        }
        return SCOPE_MOBILE.equals(scope);
    }

    static Object sanitizeMobileSetting(String key, Object value) {
        if (key == null || value == null) return null;
        if (LONG_PRESS_SPEED.equals(key)) {
            if (value instanceof Number) {
                float s = ((Number) value).floatValue();
                if (!Float.isNaN(s) && s >= 1.5f && s <= 4.0f) return s;
            }
            return null;
        }
        if (MOBILE_BOOLEAN_KEYS.contains(key)) {
            return value instanceof Boolean ? value : null;
        }
        int[] range = MOBILE_INT_RANGES.get(key);
        if (range != null) {
            if (!(value instanceof Number)) return null;
            int n = ((Number) value).intValue();
            return n >= range[0] && n <= range[1] ? n : null;
        }
        if (value instanceof String) {
            String text = ((String) value).trim();
            if (TMDB_API_PROXY.equals(key)
                    || TMDB_IMAGE_PROXY.equals(key)
                    || AI_BASE_URL.equals(key)) {
                return text.isEmpty() ? "" : sanitizeHttpUrl(text);
            }
            if (TMDB_LANGUAGE.equals(key)) {
                return ("zh-CN".equals(text) || "zh-TW".equals(text) || "en-US".equals(text))
                        ? text
                        : null;
            }
            if (AI_PROVIDER.equals(key)) {
                return ("deepseek".equals(text)
                                || "qwen".equals(text)
                                || "siliconflow".equals(text)
                                || "kimi".equals(text)
                                || "glm".equals(text)
                                || "ollama".equals(text)
                                || "custom".equals(text))
                        ? text
                        : null;
            }
            if (AI_MODEL.equals(key)) {
                return text.length() <= 128 ? text : null;
            }
            if (PLAYER_BUTTON_ORDER.equals(key)) {
                return sanitizeButtonOrder(text);
            }
            if (DANMAKU_SOURCES_JSON.equals(key)) {
                if (text.isEmpty()) return "[]";
                return (text.startsWith("[") && text.endsWith("]") && text.length() <= 32768)
                        ? text
                        : null;
            }
        }
        return null;
    }

    static String sanitizeButtonOrder(String raw) {
        if (raw == null || raw.trim().isEmpty()) return DEFAULT_PLAYER_BUTTON_ORDER;
        String[] parts = raw.split(",");
        StringBuilder sb = new StringBuilder();
        Set<String> seen = new HashSet<>();
        for (String p : parts) {
            String token = p == null ? "" : p.trim();
            if (ALLOWED_BUTTON_TOKENS.contains(token) && seen.add(token)) {
                if (sb.length() > 0) sb.append(',');
                sb.append(token);
            }
        }
        return sb.length() > 0 ? sb.toString() : DEFAULT_PLAYER_BUTTON_ORDER;
    }

    static int clampMobileUiScale(int percent) {
        return Math.max(90, Math.min(120, percent));
    }

    static int accentColorForPreset(int preset) {
        switch (preset) {
            case 1:
                return 0xff0a84ff;
            case 2:
                return 0xffff2d55;
            case 3:
                return 0xfff59e0b;
            case 4:
                return 0xffa855f7;
            case 5:
                return 0xff14b8a6;
            case 6:
                return 0xfff97316;
            case 7:
                return 0xff94a3b8;
            case 0:
            default:
                return 0xff34d399;
        }
    }

    static String extractBackupConfigJson(Object raw) {
        if (raw == null) return null;
        String text = raw instanceof String ? ((String) raw).trim() : String.valueOf(raw).trim();
        if (!text.isEmpty() && text.charAt(0) == '\uFEFF') text = text.substring(1).trim();
        if (text.isEmpty() || "null".equals(text)) return null;
        String clean = stripOuterJsonComments(text);
        if ((clean.startsWith("{") && clean.endsWith("}"))
                || (clean.startsWith("[") && clean.endsWith("]"))) {
            return text;
        }
        return null;
    }

    private static String stripOuterJsonComments(String source) {
        StringBuilder out = new StringBuilder(source.length());
        boolean quoted = false, escaped = false;
        for (int i = 0; i < source.length(); i++) {
            char ch = source.charAt(i);
            if (quoted) {
                out.append(ch);
                if (escaped) escaped = false;
                else if (ch == '\\') escaped = true;
                else if (ch == '"') quoted = false;
                continue;
            }
            if (ch == '"') {
                quoted = true;
                out.append(ch);
                continue;
            }
            if (ch == '/' && i + 1 < source.length() && source.charAt(i + 1) == '/') {
                while (i < source.length() && source.charAt(i) != '\n') i++;
                out.append('\n');
                continue;
            }
            if (ch == '/' && i + 1 < source.length() && source.charAt(i + 1) == '*') {
                i += 2;
                while (i + 1 < source.length()
                        && !(source.charAt(i) == '*' && source.charAt(i + 1) == '/')) i++;
                if (i + 1 >= source.length()) return "";
                i++;
                out.append(' ');
                continue;
            }
            out.append(ch);
        }
        return out.toString().trim();
    }

    static String sanitizeUserData(String key, Object value) {
        if (key == null || value == null) return null;
        String text =
                value instanceof String ? ((String) value).trim() : String.valueOf(value).trim();
        if ("null".equals(text)) return null;
        if (SELECTED_SITE.equals(key)) {
            return text.length() <= 256 ? text : null;
        }
        if (TV_PLAYER_TOOLBAR_ORDER.equals(key)) {
            return sanitizeTvToolbarOrder(value);
        }
        if (LIVE_UDPXY_URL.equals(key)) {
            if (text.isEmpty()) return "";
            return sanitizeUdpxyBase(text);
        }
        if (LIVE_EPG_URL.equals(key)) {
            if (text.isEmpty()) return "";
            return sanitizeHttpUrl(text);
        }
        if (LIVE_URL.equals(key)) {
            if (text.isEmpty()) return "";
            return sanitizeHttpUrl(text);
        }
        if (LIVE_NAME.equals(key)) {
            return text.length() <= 120 ? text : null;
        }
        if (LIVE_SOURCES_JSON.equals(key)) {
            if (text.isEmpty()) return "[]";
            if (text.startsWith("[") && text.endsWith("]") && text.length() <= 65536) return text;
            return null;
        }
        if (WATCH_HISTORY.equals(key)
                || FAVORITES.equals(key)
                || GLOBAL_SEARCH_HISTORY.equals(key)) {
            if (text.isEmpty()) return "[]";
            if (text.startsWith("[") && text.endsWith("]")) return text;
            return null;
        }
        return null;
    }

    static String sanitizeHttpUrl(String raw) {
        if (raw == null || raw.length() > 2048) return null;
        String lower = raw.toLowerCase(java.util.Locale.ROOT);
        if (!lower.startsWith("http://") && !lower.startsWith("https://")) return null;
        try {
            java.net.URI uri = java.net.URI.create(raw);
            String host = uri.getHost();
            if (host == null || host.trim().isEmpty()) return null;
            return uri.toASCIIString();
        } catch (Exception ignored) {
            return null;
        }
    }

    private static final Set<String> TV_TOOLBAR_ALLOWED_KEYS =
            Collections.unmodifiableSet(
                    new HashSet<>(
                            Arrays.asList(
                                    "play-pause",
                                    "next-episode",
                                    "episodes",
                                    "subtitles",
                                    "audio-tracks",
                                    "lines",
                                    "speed",
                                    "decoder",
                                    "skip-intro-tool",
                                    "skip-outro-tool",
                                    "more")));

    static String sanitizeTvToolbarOrder(Object raw) {
        if (!(raw instanceof String)) return null;
        String text = ((String) raw).trim();
        if (text.length() > 256) return null;
        if (text.isEmpty()) return "";
        java.util.LinkedHashSet<String> seen = new java.util.LinkedHashSet<>();
        for (String token : text.split(",")) {
            String key = token == null ? "" : token.trim();
            if (TV_TOOLBAR_ALLOWED_KEYS.contains(key)) {
                seen.add(key);
            }
        }
        if (seen.isEmpty()) return "";
        StringBuilder out = new StringBuilder();
        for (String key : seen) {
            if (out.length() > 0) out.append(',');
            out.append(key);
        }
        return out.toString();
    }

    private static String sanitizeUdpxyBase(String raw) {
        if (raw == null || raw.length() > 512) return null;
        String candidate = raw.trim();
        String lower = candidate.toLowerCase(java.util.Locale.ROOT);
        if (!lower.startsWith("http://") && !lower.startsWith("https://")) {
            if (candidate.contains("://")) return null;
            candidate = "http://" + candidate;
        }
        while (candidate.endsWith("/")) {
            candidate = candidate.substring(0, candidate.length() - 1);
        }
        try {
            java.net.URI uri = java.net.URI.create(candidate);
            String host = uri.getHost();
            if (host == null || host.trim().isEmpty()) return null;
            return candidate;
        } catch (Exception ignored) {
            return null;
        }
    }
}
