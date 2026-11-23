package com.pilipala.marcomovie.hud;

import android.content.Context;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.animation.DecelerateInterpolator;
import android.view.animation.LinearInterpolator;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Start-of-playback media specification banner with dual-channel group-safe badge fusion and
 * anti-overlap positioning relative to the top-left back button and safe insets.
 *
 * <p>Uses solid high-contrast rounded pills only (zero blur, zero shaders, ARM32 TV safe).
 */
public final class StartSpecBanner extends LinearLayout {
    public static final long DELAY_MS = 350L;
    public static final long FADE_IN_MS = 180L;
    public static final long DISPLAY_MS = 3000L;
    public static final long FADE_OUT_MS = 240L;
    public static final long REDUCED_FADE_MS = 120L;
    public static final int MAX_BADGES = 5;

    /** Pure-data badge descriptor for dual-channel fusion and cross-layer rendering. */
    public static final class Badge {
        public final String id;
        public final String label;
        public final String group;
        public final int priority;
        public final int fillArgb;
        public final int solidFillArgb;
        public final int strokeArgb;
        public final int textArgb;

        public Badge(
                String id,
                String label,
                String group,
                int priority,
                int fillArgb,
                int solidFillArgb,
                int strokeArgb,
                int textArgb) {
            this.id = id;
            this.label = label;
            this.group = group;
            this.priority = priority;
            this.fillArgb = fillArgb;
            this.solidFillArgb = solidFillArgb;
            this.strokeArgb = strokeArgb;
            this.textArgb = textArgb;
        }
    }

    /** Optional Wave 2 override hook so M1 MediaBadges can plug in without modifying M2 logic. */
    public interface FusionProvider {
        List<Badge> fuse(
                List<String> trackBadges,
                int videoWidth,
                int videoHeight,
                String lineName,
                String episodeName);
    }

    private static volatile FusionProvider externalFusionProvider;

    public static void setExternalFusionProvider(FusionProvider provider) {
        externalFusionProvider = provider;
    }

    /**
     * Dual-channel group-safe badge fusion aligned with player-hud-spec.md §4.1.
     *
     * <p>When real video dimensions ({@code videoWidth > 0 && videoHeight > 0}) are known, the
     * {@code resolution} group is derived strictly from Channel A (actual stream track / video
     * dimensions) so a low-resolution stream on a "4K" line is never mislabeled as 4K.
     */
    public static List<Badge> fuseSpecBadges(
            List<String> trackBadges,
            int videoWidth,
            int videoHeight,
            String lineName,
            String episodeName) {
        FusionProvider provider = externalFusionProvider;
        if (provider != null) {
            List<Badge> custom =
                    provider.fuse(trackBadges, videoWidth, videoHeight, lineName, episodeName);
            if (custom != null) return custom;
        }
        StringBuilder trackText = new StringBuilder();
        if (trackBadges != null) {
            for (String b : trackBadges) {
                if (b != null && !b.trim().isEmpty()) {
                    if (trackText.length() > 0) trackText.append(' ');
                    trackText.append(b.trim());
                }
            }
        }
        StringBuilder metaText = new StringBuilder();
        if (lineName != null && !lineName.trim().isEmpty()) {
            metaText.append(lineName.trim());
        }
        if (episodeName != null && !episodeName.trim().isEmpty()) {
            if (metaText.length() > 0) metaText.append(' ');
            metaText.append(episodeName.trim());
        }

        Map<String, Badge> channelA = extractFromText(trackText.toString(), true);
        boolean hasRealDims = videoWidth > 0 && videoHeight > 0;
        if (hasRealDims) {
            Badge realRes = resolutionFromDimensions(videoWidth, videoHeight);
            if (realRes != null) {
                channelA.put("resolution", realRes);
            } else {
                channelA.remove("resolution");
            }
        }
        Map<String, Badge> channelB = extractFromText(metaText.toString(), false);

        Map<String, Badge> merged = new LinkedHashMap<>();
        // 1. Resolution: strictly Channel A whenever real dimensions are known.
        if (hasRealDims) {
            if (channelA.containsKey("resolution")) {
                merged.put("resolution", channelA.get("resolution"));
            }
        } else if (channelA.containsKey("resolution")) {
            merged.put("resolution", channelA.get("resolution"));
        } else if (channelB.containsKey("resolution")) {
            merged.put("resolution", channelB.get("resolution"));
        }

        // 2. Dynamic range, audio, codec: prefer Channel A, supplement missing from Channel B.
        for (String grp : new String[] {"dynamic_range", "audio", "codec"}) {
            if (channelA.containsKey(grp)) {
                merged.put(grp, channelA.get(grp));
            } else if (channelB.containsKey(grp)) {
                merged.put(grp, channelB.get(grp));
            }
        }

        // 3. Source quality from Channel B metadata.
        if (channelB.containsKey("source_quality")) {
            merged.put("source_quality", channelB.get("source_quality"));
        }

        // 4. Combo synthesis: DV + Atmos -> DV · ATMOS.
        Badge dr = merged.get("dynamic_range");
        Badge aud = merged.get("audio");
        if (dr != null && "dr_dv".equals(dr.id) && aud != null && "aud_atmos".equals(aud.id)) {
            merged.remove("dynamic_range");
            merged.remove("audio");
            merged.put(
                    "combo_dv_atmos",
                    new Badge(
                            "combo_dv_atmos",
                            "DV · ATMOS",
                            "combo",
                            18,
                            0x335e5ce6,
                            0xeb261f42,
                            0x73bf5af2,
                            0xffe5c7ff));
        }

        List<Badge> ordered = new ArrayList<>(merged.values());
        Collections.sort(
                ordered,
                (a, b) -> {
                    int c = Integer.compare(a.priority, b.priority);
                    return c != 0 ? c : a.id.compareTo(b.id);
                });
        if (ordered.size() > MAX_BADGES) {
            return new ArrayList<>(ordered.subList(0, MAX_BADGES));
        }
        return ordered;
    }

    private static Badge resolutionFromDimensions(int w, int h) {
        int longEdge = Math.max(w, h);
        int shortEdge = Math.min(w, h);
        if (longEdge >= 7200 || shortEdge >= 4000) {
            return new Badge(
                    "res_8k",
                    "8K",
                    "resolution",
                    10,
                    0x2eff9f0a,
                    0xeb3a2810,
                    0x66ff9f0a,
                    0xffffb340);
        }
        if (longEdge >= 3600 || shortEdge >= 2000) {
            return new Badge(
                    "res_4k",
                    "4K",
                    "resolution",
                    10,
                    0x2eff9f0a,
                    0xeb3a2810,
                    0x66ff9f0a,
                    0xffffb340);
        }
        if (longEdge >= 2400 || shortEdge >= 1360) {
            return new Badge(
                    "res_2k",
                    "2K",
                    "resolution",
                    11,
                    0x2964d2ff,
                    0xeb142c38,
                    0x5c64d2ff,
                    0xff70d7ff);
        }
        if (longEdge >= 1800 || shortEdge >= 1000) {
            return new Badge(
                    "res_1080p",
                    "1080P",
                    "resolution",
                    12,
                    0x2964d2ff,
                    0xeb142c38,
                    0x5c64d2ff,
                    0xff70d7ff);
        }
        if (longEdge >= 1200 || shortEdge >= 680) {
            return new Badge(
                    "res_720p",
                    "720P",
                    "resolution",
                    13,
                    0x33787884,
                    0xeb25252b,
                    0x4debebf5,
                    0xffd1d1da);
        }
        return new Badge(
                "res_sd", "SD", "resolution", 14, 0x33787884, 0xeb25252b, 0x4debebf5, 0xffd1d1da);
    }

    private static boolean hasToken(String lower, String token) {
        int idx = lower.indexOf(token);
        while (idx >= 0) {
            boolean leftOk = idx == 0 || !isAsciiAlphaNum(lower.charAt(idx - 1));
            int end = idx + token.length();
            boolean rightOk = end >= lower.length() || !isAsciiAlphaNum(lower.charAt(end));
            if (leftOk && rightOk) return true;
            idx = lower.indexOf(token, idx + 1);
        }
        return false;
    }

    private static boolean isAsciiAlphaNum(char c) {
        return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
    }

    private static Map<String, Badge> extractFromText(String raw, boolean isTrack) {
        Map<String, Badge> out = new LinkedHashMap<>();
        if (raw == null || raw.isEmpty()) return out;
        String lower = raw.toLowerCase(Locale.ROOT);

        // Resolution
        if (hasToken(lower, "8k") || hasToken(lower, "4320p")) {
            out.put(
                    "resolution",
                    new Badge(
                            "res_8k",
                            "8K",
                            "resolution",
                            10,
                            0x2eff9f0a,
                            0xeb3a2810,
                            0x66ff9f0a,
                            0xffffb340));
        } else if (hasToken(lower, "4k")
                || hasToken(lower, "2160p")
                || hasToken(lower, "uhd")
                || raw.contains("4K")) {
            out.put(
                    "resolution",
                    new Badge(
                            "res_4k",
                            "4K",
                            "resolution",
                            10,
                            0x2eff9f0a,
                            0xeb3a2810,
                            0x66ff9f0a,
                            0xffffb340));
        } else if (hasToken(lower, "1440p") || hasToken(lower, "2k")) {
            out.put(
                    "resolution",
                    new Badge(
                            "res_2k",
                            "2K",
                            "resolution",
                            11,
                            0x2964d2ff,
                            0xeb142c38,
                            0x5c64d2ff,
                            0xff70d7ff));
        } else if (hasToken(lower, "1080p") || hasToken(lower, "fhd")) {
            out.put(
                    "resolution",
                    new Badge(
                            "res_1080p",
                            "1080P",
                            "resolution",
                            12,
                            0x2964d2ff,
                            0xeb142c38,
                            0x5c64d2ff,
                            0xff70d7ff));
        } else if (hasToken(lower, "720p")) {
            out.put(
                    "resolution",
                    new Badge(
                            "res_720p",
                            "720P",
                            "resolution",
                            13,
                            0x33787884,
                            0xeb25252b,
                            0x4debebf5,
                            0xffd1d1da));
        }

        // Dynamic range
        if (lower.contains("dolby vision")
                || hasToken(lower, "dv")
                || hasToken(lower, "dovi")
                || raw.contains("杜比视界")) {
            out.put(
                    "dynamic_range",
                    new Badge(
                            "dr_dv",
                            "DV",
                            "dynamic_range",
                            20,
                            0x2ebf5af2,
                            0xeb2d1b38,
                            0x66bf5af2,
                            0xffdeb0ff));
        } else if (lower.contains("hdr10+") || lower.contains("hdr10plus")) {
            out.put(
                    "dynamic_range",
                    new Badge(
                            "dr_hdr10_plus",
                            "HDR10+",
                            "dynamic_range",
                            21,
                            0x2e0a84ff,
                            0xeb122640,
                            0x660a84ff,
                            0xff64d2ff));
        } else if (hasToken(lower, "hdr10") || hasToken(lower, "hdr")) {
            out.put(
                    "dynamic_range",
                    new Badge(
                            "dr_hdr10",
                            hasToken(lower, "hdr10") ? "HDR10" : "HDR",
                            "dynamic_range",
                            22,
                            0x2e0a84ff,
                            0xeb122640,
                            0x660a84ff,
                            0xff64d2ff));
        } else if (hasToken(lower, "hlg")) {
            out.put(
                    "dynamic_range",
                    new Badge(
                            "dr_hlg",
                            "HLG",
                            "dynamic_range",
                            23,
                            0x2e0a84ff,
                            0xeb122640,
                            0x660a84ff,
                            0xff64d2ff));
        }

        // Audio
        if (hasToken(lower, "atmos") || raw.contains("全景声")) {
            out.put(
                    "audio",
                    new Badge(
                            "aud_atmos",
                            "ATMOS",
                            "audio",
                            30,
                            0x2e0a84ff,
                            0xeb13283d,
                            0x665ac8fa,
                            0xff8ae0ff));
        } else if (lower.contains("truehd")) {
            out.put(
                    "audio",
                    new Badge(
                            "aud_truehd",
                            "TrueHD",
                            "audio",
                            31,
                            0x2e0a84ff,
                            0xeb13283d,
                            0x665ac8fa,
                            0xff8ae0ff));
        } else if (lower.contains("dts:x") || lower.contains("dts-x") || lower.contains("dtsx")) {
            out.put(
                    "audio",
                    new Badge(
                            "aud_dtsx",
                            "DTS:X",
                            "audio",
                            32,
                            0x2e0a84ff,
                            0xeb13283d,
                            0x665ac8fa,
                            0xff8ae0ff));
        } else if (lower.contains("dts-hd") || lower.contains("dtshd")) {
            out.put(
                    "audio",
                    new Badge(
                            "aud_dtshd",
                            "DTS-HD",
                            "audio",
                            33,
                            0x38787884,
                            0xeb28282e,
                            0x3bffffff,
                            0xfff5f5f7));
        } else if (lower.contains("dd+")
                || hasToken(lower, "ddp")
                || hasToken(lower, "eac3")
                || lower.contains("e-ac-3")) {
            out.put(
                    "audio",
                    new Badge(
                            "aud_ddp",
                            "DD+",
                            "audio",
                            34,
                            0x38787884,
                            0xeb28282e,
                            0x3bffffff,
                            0xfff5f5f7));
        } else if (hasToken(lower, "ac3") || hasToken(lower, "dd5.1")) {
            out.put(
                    "audio",
                    new Badge(
                            "aud_ac3",
                            "DD",
                            "audio",
                            35,
                            0x38787884,
                            0xeb28282e,
                            0x3bffffff,
                            0xfff5f5f7));
        } else if (hasToken(lower, "flac")) {
            out.put(
                    "audio",
                    new Badge(
                            "aud_flac",
                            "FLAC",
                            "audio",
                            36,
                            0x38787884,
                            0xeb28282e,
                            0x3bffffff,
                            0xfff5f5f7));
        } else if (hasToken(lower, "aac") && isTrack) {
            out.put(
                    "audio",
                    new Badge(
                            "aud_aac",
                            "AAC",
                            "audio",
                            37,
                            0x38787884,
                            0xeb28282e,
                            0x3bffffff,
                            0xfff5f5f7));
        }

        // Source quality (metadata channel)
        if (!isTrack) {
            if (hasToken(lower, "remux")) {
                out.put(
                        "source_quality",
                        new Badge(
                                "src_remux",
                                "REMUX",
                                "source_quality",
                                25,
                                0x2930d158,
                                0xeb142e1c,
                                0x5c30d158,
                                0xff63e682));
            } else if (lower.contains("blu-ray")
                    || hasToken(lower, "bluray")
                    || hasToken(lower, "bdmv")
                    || raw.contains("原盘")) {
                out.put(
                        "source_quality",
                        new Badge(
                                "src_bluray",
                                "BluRay",
                                "source_quality",
                                26,
                                0x2930d158,
                                0xeb142e1c,
                                0x5c30d158,
                                0xff63e682));
            } else if (lower.contains("web-dl") || hasToken(lower, "webdl")) {
                out.put(
                        "source_quality",
                        new Badge(
                                "src_webdl",
                                "WEB-DL",
                                "source_quality",
                                27,
                                0x265ac8fa,
                                0xeb152936,
                                0x525ac8fa,
                                0xff82d7ff));
            }
        }

        // Codec
        if (hasToken(lower, "av1") || hasToken(lower, "av01")) {
            out.put(
                    "codec",
                    new Badge(
                            "codec_av1",
                            "AV1",
                            "codec",
                            40,
                            0x29787884,
                            0xeb222228,
                            0x29ffffff,
                            0xffd1d1da));
        } else if (hasToken(lower, "hevc")
                || hasToken(lower, "h265")
                || lower.contains("h.265")
                || hasToken(lower, "x265")) {
            out.put(
                    "codec",
                    new Badge(
                            "codec_hevc",
                            "HEVC",
                            "codec",
                            41,
                            0x29787884,
                            0xeb222228,
                            0x29ffffff,
                            0xffd1d1da));
        } else if (hasToken(lower, "avc")
                || hasToken(lower, "h264")
                || lower.contains("h.264")
                || hasToken(lower, "x264")) {
            out.put(
                    "codec",
                    new Badge(
                            "codec_avc",
                            "H.264",
                            "codec",
                            42,
                            0x29787884,
                            0xeb222228,
                            0x29ffffff,
                            0xffd1d1da));
        }

        return out;
    }

    /**
     * Pure-Java anti-overlap margin calculation aligned with player-hud-spec.md §4.1.
     *
     * @return int[2] {leftMarginPx, topMarginPx}
     */
    public static int[] computeSafeMargins(
            int safeLeftPx,
            int safeTopPx,
            int topHeaderBottomPx,
            boolean controlsVisible,
            float density) {
        int dp10 = Math.round(10f * density);
        int dp12 = Math.round(12f * density);
        int dp16 = Math.round(16f * density);
        int left = Math.max(dp16, safeLeftPx + dp12);
        int top = Math.max(dp16, safeTopPx + dp12);
        if (controlsVisible && topHeaderBottomPx > 0) {
            top = Math.max(top, topHeaderBottomPx + dp10);
        }
        return new int[] {left, top};
    }

    private final boolean isTv;
    private boolean reducedMotion;
    private boolean reducedTransparency;
    private boolean shownForCurrentEpisode;
    private boolean pendingReveal;
    private boolean activeDisplay;
    private boolean topControlsVisible;
    private int safeLeftPx;
    private int safeTopPx;
    private int topHeaderBottomPx;
    private final List<Badge> latestBadges = new ArrayList<>();

    public static boolean shouldDeferReveal(boolean topControlsVisible) {
        return topControlsVisible;
    }

    private final Runnable showRunnable = this::revealNow;
    private final Runnable hideRunnable = this::fadeOutNow;

    public StartSpecBanner(Context context, boolean tv) {
        super(context);
        this.isTv = tv;
        setTag("player-start-spec-banner");
        setOrientation(HORIZONTAL);
        setGravity(Gravity.CENTER_VERTICAL);
        setFocusable(false);
        setClickable(false);
        setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        int padH = dp(tv ? 12 : 10);
        int padV = dp(tv ? 7 : 6);
        setPadding(padH, padV, padH, padV);
        applySurface();
        setVisibility(View.GONE);
        setAlpha(0f);
    }

    private int dp(float v) {
        float d = getResources() != null ? getResources().getDisplayMetrics().density : 1f;
        return Math.max(1, Math.round(v * d));
    }

    private void applySurface() {
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(dp(isTv ? 10 : 9));
        bg.setColor(reducedTransparency ? 0xf51e1e22 : 0xd916161a);
        bg.setStroke(Math.max(1, dp(1)), reducedTransparency ? 0x73ffffff : 0x2bffffff);
        setBackground(bg);
    }

    public void setAccessibilityFlags(boolean reducedMotion, boolean reducedTransparency) {
        this.reducedMotion = reducedMotion;
        if (this.reducedTransparency != reducedTransparency) {
            this.reducedTransparency = reducedTransparency;
            applySurface();
            renderPills(latestBadges);
        }
    }

    public void updateSafeLayout(int safeLeft, int safeTop, int topHeaderBottom) {
        this.safeLeftPx = Math.max(0, safeLeft);
        this.safeTopPx = Math.max(0, safeTop);
        this.topHeaderBottomPx = Math.max(0, topHeaderBottom);
        applyLayoutMargins();
    }

    public void onControlsVisibilityChanged(boolean controlsVisible) {
        this.topControlsVisible = controlsVisible;
        if (controlsVisible && activeDisplay) {
            // Immediately yield top-left space to PlayerChrome's back button & inline badge row.
            cancel();
        } else {
            applyLayoutMargins();
            if (!controlsVisible && pendingReveal && !latestBadges.isEmpty()) {
                pendingReveal = false;
                renderPills(latestBadges);
                removeCallbacks(showRunnable);
                removeCallbacks(hideRunnable);
                postDelayed(showRunnable, DELAY_MS);
            }
        }
    }

    public void resetEpisode() {
        shownForCurrentEpisode = false;
        pendingReveal = false;
        latestBadges.clear();
        cancel();
    }

    public void cancel() {
        removeCallbacks(showRunnable);
        removeCallbacks(hideRunnable);
        animate().withEndAction(null).cancel();
        activeDisplay = false;
        setVisibility(View.GONE);
        setAlpha(0f);
    }

    @Override
    protected void onDetachedFromWindow() {
        cancel();
        super.onDetachedFromWindow();
    }

    public List<Badge> getLatestBadges() {
        return Collections.unmodifiableList(latestBadges);
    }

    /**
     * Triggers the start-of-playback spec banner once per episode after 350ms when video dimensions
     * are valid and the HUD setting is enabled.
     */
    public void scheduleIfReady(
            List<String> trackBadges,
            int videoWidth,
            int videoHeight,
            String lineName,
            String episodeName,
            boolean enabled,
            boolean liveStream,
            boolean miniMode,
            boolean controlsVisible) {
        this.topControlsVisible = controlsVisible;
        if (videoWidth <= 0 || videoHeight <= 0) return;
        List<Badge> badges =
                fuseSpecBadges(trackBadges, videoWidth, videoHeight, lineName, episodeName);
        latestBadges.clear();
        latestBadges.addAll(badges);
        if (shownForCurrentEpisode || !enabled || liveStream || miniMode || badges.isEmpty()) {
            return;
        }
        shownForCurrentEpisode = true;
        renderPills(badges);
        removeCallbacks(showRunnable);
        removeCallbacks(hideRunnable);
        if (shouldDeferReveal(controlsVisible)) {
            pendingReveal = true;
            return;
        }
        pendingReveal = false;
        postDelayed(showRunnable, DELAY_MS);
    }

    private void renderPills(List<Badge> badges) {
        removeAllViews();
        int gap = dp(isTv ? 8 : 6);
        int padH = dp(isTv ? 10 : 8);
        int padV = dp(isTv ? 4 : 3);
        int corner = dp(isTv ? 7 : 6);
        float textSp = isTv ? 13.5f : 12f;
        for (int i = 0; i < badges.size(); i++) {
            Badge b = badges.get(i);
            TextView tv = new TextView(getContext());
            tv.setText(b.label);
            tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, textSp);
            tv.setTextColor(b.textArgb);
            tv.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
            tv.setSingleLine(true);
            tv.setIncludeFontPadding(false);
            tv.setGravity(Gravity.CENTER);
            if (Build.VERSION.SDK_INT >= 21) {
                tv.setLetterSpacing(0.03f);
            }
            tv.setPadding(padH, padV, padH, padV);
            GradientDrawable pillBg = new GradientDrawable();
            pillBg.setCornerRadius(corner);
            pillBg.setColor(reducedTransparency ? b.solidFillArgb : b.fillArgb);
            pillBg.setStroke(Math.max(1, dp(isTv ? 1.5f : 1f)), b.strokeArgb);
            tv.setBackground(pillBg);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
            if (i > 0) lp.leftMargin = gap;
            addView(tv, lp);
        }
    }

    private void applyLayoutMargins() {
        if (!(getLayoutParams() instanceof FrameLayout.LayoutParams)) return;
        float d = getResources() != null ? getResources().getDisplayMetrics().density : 1f;
        int[] margins =
                computeSafeMargins(safeLeftPx, safeTopPx, topHeaderBottomPx, topControlsVisible, d);
        FrameLayout.LayoutParams lp = (FrameLayout.LayoutParams) getLayoutParams();
        if (lp.leftMargin != margins[0] || lp.topMargin != margins[1]) {
            lp.leftMargin = margins[0];
            lp.topMargin = margins[1];
            setLayoutParams(lp);
        }
    }

    private void revealNow() {
        if (latestBadges.isEmpty()) return;
        if (shouldDeferReveal(topControlsVisible)) {
            // Controls are still visible on entry; defer reveal until they auto-hide so the
            // opening spec banner is not silently lost for the entire episode.
            pendingReveal = true;
            return;
        }
        pendingReveal = false;
        applyLayoutMargins();
        activeDisplay = true;
        animate().cancel();
        setVisibility(View.VISIBLE);
        setAlpha(0f);
        if (reducedMotion) {
            setTranslationY(0f);
            animate()
                    .alpha(1f)
                    .setDuration(REDUCED_FADE_MS)
                    .setInterpolator(new LinearInterpolator())
                    .withEndAction(null)
                    .start();
        } else {
            setTranslationY(-dp(6));
            animate()
                    .alpha(1f)
                    .translationY(0f)
                    .setDuration(FADE_IN_MS)
                    .setInterpolator(new DecelerateInterpolator())
                    .withEndAction(null)
                    .start();
        }
        removeCallbacks(hideRunnable);
        postDelayed(hideRunnable, DISPLAY_MS);
    }

    private void fadeOutNow() {
        activeDisplay = false;
        animate().cancel();
        long dur = reducedMotion ? REDUCED_FADE_MS : FADE_OUT_MS;
        animate()
                .alpha(0f)
                .setDuration(dur)
                .setInterpolator(new LinearInterpolator())
                .withEndAction(
                        () -> {
                            if (!activeDisplay) setVisibility(View.GONE);
                        })
                .start();
    }
}
