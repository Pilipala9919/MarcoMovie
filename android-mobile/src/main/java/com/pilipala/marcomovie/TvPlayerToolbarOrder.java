package com.pilipala.marcomovie;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * Pure-Java ordering, labeling, sanitization, and tooltip placement policy for the Android TV
 * playback toolbar (both Modern Floating Card and Classic Dual-Bar styles).
 */
final class TvPlayerToolbarOrder {
    static final String KEY_PLAY_PAUSE = "play-pause";
    static final String KEY_NEXT_EPISODE = "next-episode";
    static final String KEY_EPISODES = "episodes";
    static final String KEY_SUBTITLES = "subtitles";
    static final String KEY_AUDIO_TRACKS = "audio-tracks";
    static final String KEY_LINES = "lines";
    static final String KEY_SPEED = "speed";
    static final String KEY_DECODER = "decoder";
    static final String KEY_SKIP_INTRO = "skip-intro-tool";
    static final String KEY_SKIP_OUTRO = "skip-outro-tool";
    static final String KEY_MORE = "more";

    private static final List<String> DEFAULT_MODERN_ORDER =
            Collections.unmodifiableList(
                    Arrays.asList(
                            KEY_PLAY_PAUSE,
                            KEY_NEXT_EPISODE,
                            KEY_EPISODES,
                            KEY_SUBTITLES,
                            KEY_AUDIO_TRACKS,
                            KEY_LINES,
                            KEY_SPEED,
                            KEY_SKIP_INTRO,
                            KEY_SKIP_OUTRO,
                            KEY_MORE));

    private static final List<String> DEFAULT_CLASSIC_ORDER =
            Collections.unmodifiableList(
                    Arrays.asList(
                            KEY_NEXT_EPISODE,
                            KEY_EPISODES,
                            KEY_LINES,
                            KEY_SPEED,
                            KEY_AUDIO_TRACKS,
                            KEY_DECODER,
                            KEY_SKIP_INTRO,
                            KEY_SKIP_OUTRO,
                            KEY_MORE));

    private static final Set<String> ALL_KNOWN_KEYS;

    static {
        LinkedHashSet<String> all = new LinkedHashSet<>();
        all.addAll(DEFAULT_MODERN_ORDER);
        all.addAll(DEFAULT_CLASSIC_ORDER);
        ALL_KNOWN_KEYS = Collections.unmodifiableSet(all);
    }

    static final class TooltipPlacement {
        final int left;
        final int top;
        final float arrowCenterX;

        TooltipPlacement(int left, int top, float arrowCenterX) {
            this.left = left;
            this.top = top;
            this.arrowCenterX = arrowCenterX;
        }
    }

    private TvPlayerToolbarOrder() {}

    static List<String> defaultOrder(boolean modernTv) {
        return new ArrayList<>(modernTv ? DEFAULT_MODERN_ORDER : DEFAULT_CLASSIC_ORDER);
    }

    static boolean isKnownKey(String key) {
        return key != null && ALL_KNOWN_KEYS.contains(key);
    }

    static String sanitize(Object raw) {
        return Prefs.sanitizeTvToolbarOrder(raw);
    }

    static List<String> resolveOrder(String savedRaw, boolean modernTv) {
        List<String> defaults = defaultOrder(modernTv);
        if (savedRaw == null || savedRaw.trim().isEmpty()) {
            return defaults;
        }
        Set<String> allowed = new LinkedHashSet<>(defaults);
        List<String> resolved = new ArrayList<>(defaults.size());
        for (String token : savedRaw.split(",")) {
            String key = token == null ? "" : token.trim();
            if (allowed.contains(key) && !resolved.contains(key)) {
                resolved.add(key);
            }
        }
        if (resolved.isEmpty()) {
            return defaults;
        }
        insertMissingRelativeToReference(resolved, defaults);
        return resolved;
    }

    static String mergeEditedOrder(
            String existingSavedRaw, List<String> editedStyleOrder, boolean modernTv) {
        List<String> normalized = resolveOrder(joinKeys(editedStyleOrder), modernTv);
        List<String> activeDefaults = defaultOrder(modernTv);
        if (normalized.equals(activeDefaults)
                && (existingSavedRaw == null
                        || existingSavedRaw.trim().isEmpty()
                        || isDefaultOrder(existingSavedRaw, !modernTv))) {
            return "";
        }
        List<String> merged = new ArrayList<>(normalized);
        List<String> otherOrder = resolveOrder(existingSavedRaw, !modernTv);
        insertMissingRelativeToReference(merged, otherOrder);
        return joinKeys(merged);
    }

    static boolean isDefaultOrder(String savedRaw, boolean modernTv) {
        return resolveOrder(savedRaw, modernTv).equals(defaultOrder(modernTv));
    }

    static boolean moveItem(List<String> order, int fromIndex, int delta) {
        if (order == null || order.isEmpty() || delta == 0) return false;
        if (fromIndex < 0 || fromIndex >= order.size()) return false;
        int target = fromIndex + delta;
        if (target < 0 || target >= order.size()) return false;
        String item = order.remove(fromIndex);
        order.add(target, item);
        return true;
    }

    static String settingsLabel(String key) {
        if (key == null) return "";
        switch (key) {
            case KEY_PLAY_PAUSE:
                return "播放 / 暂停";
            case KEY_NEXT_EPISODE:
                return "下一集 / 下台";
            case KEY_EPISODES:
                return "选集 / 频道";
            case KEY_SUBTITLES:
                return "字幕";
            case KEY_AUDIO_TRACKS:
                return "音轨";
            case KEY_LINES:
                return "换源 / 线路";
            case KEY_SPEED:
                return "倍速";
            case KEY_DECODER:
                return "解码 / 播放器";
            case KEY_SKIP_INTRO:
                return "跳过片头";
            case KEY_SKIP_OUTRO:
                return "跳过片尾";
            case KEY_MORE:
                return "更多";
            default:
                return key;
        }
    }

    static String shortChipLabel(String key) {
        if (key == null) return "";
        switch (key) {
            case KEY_PLAY_PAUSE:
                return "播放";
            case KEY_NEXT_EPISODE:
                return "下集";
            case KEY_EPISODES:
                return "选集";
            case KEY_SUBTITLES:
                return "字幕";
            case KEY_AUDIO_TRACKS:
                return "音轨";
            case KEY_LINES:
                return "换源";
            case KEY_SPEED:
                return "倍速";
            case KEY_DECODER:
                return "解码";
            case KEY_SKIP_INTRO:
                return "片头";
            case KEY_SKIP_OUTRO:
                return "片尾";
            case KEY_MORE:
                return "更多";
            default:
                return key;
        }
    }

    static String settingsSummary(String savedRaw, boolean modernTv) {
        if (isDefaultOrder(savedRaw, modernTv)) {
            return "默认顺序";
        }
        List<String> order = resolveOrder(savedRaw, modernTv);
        StringBuilder sb = new StringBuilder("已自定义 · ");
        int previewCount = Math.min(4, order.size());
        for (int i = 0; i < previewCount; i++) {
            if (i > 0) sb.append(" / ");
            sb.append(shortChipLabel(order.get(i)));
        }
        if (order.size() > previewCount) {
            sb.append(" …");
        }
        return sb.toString();
    }

    static String tooltipLabel(
            String key,
            boolean live,
            boolean playing,
            float speed,
            int introSec,
            int outroSec,
            int engineMode) {
        if (key == null) return "";
        switch (key) {
            case KEY_PLAY_PAUSE:
                return playing ? "暂停" : "播放";
            case KEY_NEXT_EPISODE:
                return live ? "下一频道" : "下一集";
            case KEY_EPISODES:
                return live ? "频道列表" : "选集";
            case KEY_SUBTITLES:
                return "字幕";
            case KEY_AUDIO_TRACKS:
                return "音轨";
            case KEY_LINES:
                return live ? "切换线路" : "换源";
            case KEY_SPEED:
                return Math.abs(speed - 1f) < 0.01f ? "倍速" : ("倍速 " + formatSpeed(speed));
            case KEY_DECODER:
                String eng =
                        engineMode == 3
                                ? "MPV"
                                : (engineMode == 2 ? "IJK" : (engineMode == 1 ? "系统" : "Exo"));
                return "解码 · " + eng;
            case KEY_SKIP_INTRO:
                return introSec > 0 ? ("跳过片头 " + formatClockSeconds(introSec)) : "跳过片头";
            case KEY_SKIP_OUTRO:
                return outroSec > 0 ? ("跳过片尾 " + formatClockSeconds(outroSec)) : "跳过片尾";
            case KEY_MORE:
                return "更多";
            default:
                return "";
        }
    }

    static TooltipPlacement computeTooltipPlacement(
            int containerWidth,
            int containerHeight,
            int anchorCenterX,
            int anchorTopY,
            int bubbleWidth,
            int bubbleHeight,
            int edgeMarginPx,
            int gapPx,
            float minArrowInsetPx) {
        int safeEdge = Math.max(0, edgeMarginPx);
        int safeW = Math.max(1, bubbleWidth);
        int safeH = Math.max(1, bubbleHeight);
        int maxLeft = Math.max(safeEdge, containerWidth - safeW - safeEdge);
        int desiredLeft = anchorCenterX - safeW / 2;
        int left = Math.max(safeEdge, Math.min(maxLeft, desiredLeft));

        int maxTop = Math.max(safeEdge, containerHeight - safeH - safeEdge);
        int desiredTop = anchorTopY - safeH - Math.max(0, gapPx);
        int top = Math.max(safeEdge, Math.min(maxTop, desiredTop));

        float clampedInset = Math.max(0f, Math.min(minArrowInsetPx, safeW * 0.5f));
        float rawArrow = anchorCenterX - left;
        float arrowCenterX = Math.max(clampedInset, Math.min(safeW - clampedInset, rawArrow));
        return new TooltipPlacement(left, top, arrowCenterX);
    }

    private static void insertMissingRelativeToReference(
            List<String> target, List<String> reference) {
        for (int i = 0; i < reference.size(); i++) {
            String key = reference.get(i);
            if (target.contains(key)) continue;
            int insertAt = 0;
            for (int p = i - 1; p >= 0; p--) {
                int idx = target.indexOf(reference.get(p));
                if (idx >= 0) {
                    insertAt = idx + 1;
                    break;
                }
            }
            target.add(insertAt, key);
        }
    }

    private static String joinKeys(List<String> keys) {
        if (keys == null || keys.isEmpty()) return "";
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < keys.size(); i++) {
            String k = keys.get(i);
            if (k == null || k.trim().isEmpty()) continue;
            if (sb.length() > 0) sb.append(',');
            sb.append(k.trim());
        }
        return sb.toString();
    }

    private static String formatSpeed(float speed) {
        if (Math.abs(speed - Math.round(speed)) < 0.01f) {
            return Math.round(speed) + "×";
        }
        String raw = String.format(Locale.ROOT, "%.2f", speed);
        while (raw.endsWith("0")) {
            raw = raw.substring(0, raw.length() - 1);
        }
        if (raw.endsWith(".")) {
            raw = raw.substring(0, raw.length() - 1);
        }
        return raw + "×";
    }

    private static String formatClockSeconds(int seconds) {
        int sec = Math.max(0, seconds);
        if (sec >= 3600) {
            return String.format(
                    Locale.ROOT, "%d:%02d:%02d", sec / 3600, (sec / 60) % 60, sec % 60);
        }
        return String.format(Locale.ROOT, "%02d:%02d", sec / 60, sec % 60);
    }
}
