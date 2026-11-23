// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.content.Context;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;
import java.io.InputStream;
import java.util.List;

/**
 * Plain-text typography capsule pills for media specification badges on Android TV, phone, and
 * tablet.
 *
 * <p>Uses lightweight {@link GradientDrawable} pills inside a zero-dependency wrapping flow layout
 * with zero blur/shader effects so Android TV stays >= 50fps, 100/110/120% UI scaling never clips
 * badges, and {@link Prefs#REDUCED_TRANSPARENCY} switches to high-contrast solid fills per {@code
 * shared/ui-spec/motion-tokens.json}. Zero trademarked graphic logos are ever rendered.
 */
final class MediaBadgeView {
    static final int LINE_PICKER_MAX_BADGES = 3;
    static final int HERO_MAX_BADGES = 5;

    private static final int FOCUSED_FILL_ARGB = 0xfff5f5f7;
    private static final int FOCUSED_STROKE_ARGB = 0xfff5f5f7;
    private static final int FOCUSED_TEXT_ARGB = 0xff101013;

    private static volatile boolean assetAttempted;

    private MediaBadgeView() {}

    static void ensureAssetsLoaded(Context context) {
        if (assetAttempted || context == null) return;
        synchronized (MediaBadgeView.class) {
            if (assetAttempted) return;
            assetAttempted = true;
            InputStream in = null;
            try {
                in = context.getAssets().open("ui-spec/badge-rules.json");
                MediaBadges.loadDefaultFromStream(in);
            } catch (Exception ignored) {
                // Built-in rules in MediaBadges match shared/ui-spec/badge-rules.json 1:1.
            } finally {
                if (in != null) {
                    try {
                        in.close();
                    } catch (Exception ignored) {
                    }
                }
            }
        }
    }

    /**
     * Extracts per-line badges strictly from line name + representative episode (never polluted by
     * series-level {@code video.remarks}).
     */
    static List<MediaBadges.Badge> extractForLineOnly(
            Context context, Cms.Line line, Cms.Episode episode) {
        ensureAssetsLoaded(context);
        String lineName = line == null ? null : line.name;
        Cms.Episode target = episode;
        if (target == null && line != null && line.episodes != null && !line.episodes.isEmpty()) {
            target = line.episodes.get(0);
        }
        String epName = target == null ? null : target.name;
        String epUrl = target == null ? null : target.url;
        return MediaBadges.extractBadgesFromSources(lineName, epName, epUrl);
    }

    /**
     * Extracts hero badges for the active line/episode, falling back to series {@code remarks} only
     * when the active line and episode yield no spec tags.
     */
    static List<MediaBadges.Badge> extractForHero(
            Context context, String remarks, Cms.Line line, Cms.Episode episode) {
        List<MediaBadges.Badge> lineBadges = extractForLineOnly(context, line, episode);
        if (!lineBadges.isEmpty()) {
            return lineBadges;
        }
        ensureAssetsLoaded(context);
        return MediaBadges.extractBadges(remarks);
    }

    /** Wrapping zero-dependency flow container so badges wrap cleanly at 100/110/120% scale. */
    static final class BadgeFlowLayout extends ViewGroup {
        private int horizontalGapPx;
        private int verticalGapPx;
        private boolean centered;

        BadgeFlowLayout(Context context, int gapPx, boolean centered) {
            super(context);
            this.horizontalGapPx = gapPx;
            this.verticalGapPx = gapPx;
            this.centered = centered;
            setClipChildren(false);
            setClipToPadding(false);
        }

        void setGapPx(int gapPx) {
            this.horizontalGapPx = gapPx;
            this.verticalGapPx = gapPx;
        }

        void setCentered(boolean centered) {
            this.centered = centered;
        }

        @Override
        protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
            int widthMode = MeasureSpec.getMode(widthMeasureSpec);
            int maxWidth =
                    widthMode == MeasureSpec.UNSPECIFIED
                            ? Integer.MAX_VALUE
                            : Math.max(
                                    0,
                                    MeasureSpec.getSize(widthMeasureSpec)
                                            - getPaddingLeft()
                                            - getPaddingRight());
            int childCount = getChildCount();
            int rowW = 0;
            int rowH = 0;
            int totalW = 0;
            int totalH = 0;
            for (int i = 0; i < childCount; i++) {
                View child = getChildAt(i);
                if (child.getVisibility() == GONE) continue;
                int childWSpec =
                        widthMode == MeasureSpec.UNSPECIFIED
                                ? MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED)
                                : MeasureSpec.makeMeasureSpec(maxWidth, MeasureSpec.AT_MOST);
                child.measure(childWSpec, MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED));
                int cw = child.getMeasuredWidth();
                int ch = child.getMeasuredHeight();
                if (rowW > 0 && rowW + horizontalGapPx + cw > maxWidth) {
                    totalW = Math.max(totalW, rowW);
                    totalH += rowH + verticalGapPx;
                    rowW = cw;
                    rowH = ch;
                } else {
                    if (rowW > 0) rowW += horizontalGapPx;
                    rowW += cw;
                    rowH = Math.max(rowH, ch);
                }
            }
            if (rowW > 0) {
                totalW = Math.max(totalW, rowW);
                totalH += rowH;
            }
            int measuredW =
                    widthMode == MeasureSpec.EXACTLY
                            ? MeasureSpec.getSize(widthMeasureSpec)
                            : Math.min(maxWidth, totalW + getPaddingLeft() + getPaddingRight());
            int measuredH = totalH + getPaddingTop() + getPaddingBottom();
            setMeasuredDimension(
                    resolveSize(measuredW, widthMeasureSpec),
                    resolveSize(measuredH, heightMeasureSpec));
        }

        @Override
        protected void onLayout(boolean changed, int l, int t, int r, int b) {
            int availW = Math.max(0, (r - l) - getPaddingLeft() - getPaddingRight());
            int childCount = getChildCount();
            int y = getPaddingTop();
            int i = 0;
            while (i < childCount) {
                int rowStart = i;
                int rowW = 0;
                int rowH = 0;
                while (i < childCount) {
                    View child = getChildAt(i);
                    if (child.getVisibility() == GONE) {
                        i++;
                        continue;
                    }
                    int cw = child.getMeasuredWidth();
                    int ch = child.getMeasuredHeight();
                    if (rowW > 0 && rowW + horizontalGapPx + cw > availW) {
                        break;
                    }
                    if (rowW > 0) rowW += horizontalGapPx;
                    rowW += cw;
                    rowH = Math.max(rowH, ch);
                    i++;
                }
                int x = getPaddingLeft() + (centered ? Math.max(0, (availW - rowW) / 2) : 0);
                for (int j = rowStart; j < i; j++) {
                    View child = getChildAt(j);
                    if (child.getVisibility() == GONE) continue;
                    int cw = child.getMeasuredWidth();
                    int ch = child.getMeasuredHeight();
                    int cy = y + (rowH - ch) / 2;
                    child.layout(x, cy, x + cw, cy + ch);
                    x += cw + horizontalGapPx;
                }
                if (rowH > 0) {
                    y += rowH + verticalGapPx;
                }
            }
        }
    }

    static BadgeFlowLayout createRow(MainActivity a, String tag, boolean centered) {
        BadgeFlowLayout row = new BadgeFlowLayout(a, a.dp(6), centered);
        row.setTag(tag);
        row.setVisibility(View.GONE);
        return row;
    }

    static void populateRow(
            MainActivity a,
            ViewGroup container,
            List<MediaBadges.Badge> badges,
            int maxBadges,
            boolean compact,
            boolean tvStyle) {
        if (container == null) return;
        container.removeAllViews();
        if (badges == null || badges.isEmpty() || maxBadges == 0) {
            container.setVisibility(View.GONE);
            return;
        }
        int gapDp = compact ? 4 : (tvStyle ? 8 : 6);
        if (container instanceof BadgeFlowLayout) {
            ((BadgeFlowLayout) container).setGapPx(a.dp(gapDp));
        }
        int limit = maxBadges > 0 ? Math.min(maxBadges, badges.size()) : badges.size();
        for (int i = 0; i < limit; i++) {
            MediaBadges.Badge badge = badges.get(i);
            TextView pill = createPill(a, badge, compact, tvStyle);
            container.addView(pill, new ViewGroup.LayoutParams(-2, -2));
        }
        container.setVisibility(View.VISIBLE);
    }

    static TextView createPill(
            MainActivity a, MediaBadges.Badge badge, boolean compact, boolean tvStyle) {
        int[] palette = colorsForStyle(badge.style);
        boolean reduceTransparency =
                a.prefs != null && a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false);
        int textColor = palette[0];
        int fillColor = reduceTransparency ? palette[3] : palette[1];
        int strokeColor = reduceTransparency ? ensureMinAlpha(palette[2], 0x73) : palette[2];

        // Metrics locked to shared/ui-spec/motion-tokens.json scaleTokens.badgeMetrics
        float textSp = compact ? 11f : (tvStyle ? 14f : 12f);
        float padHDp = compact ? 6f : (tvStyle ? 10f : 8f);
        float padVDp = compact ? 2f : (tvStyle ? 4f : 3f);
        float radiusDp = compact ? 5f : (tvStyle ? 7f : 6f);
        float strokeDp = tvStyle ? 1.5f : 1.0f;
        float letterSpacing = compact ? 0.03f : (tvStyle ? 0.04f : 0.035f);

        TextView tv = a.text(badge.label, textSp, textColor);
        tv.setTag("media-badge:" + badge.id);
        tv.setSingleLine(true);
        tv.setEllipsize(TextUtils.TruncateAt.END);
        tv.setIncludeFontPadding(false);
        tv.setTypeface(null, Typeface.BOLD);
        tv.setGravity(Gravity.CENTER);
        tv.setLetterSpacing(letterSpacing);
        int padH = a.dp(padHDp);
        int padV = a.dp(padVDp);
        tv.setPadding(padH, padV, padH, padV);
        UiCompat.setBackground(tv, pillDrawable(a, fillColor, strokeColor, radiusDp, strokeDp));
        return tv;
    }

    static void applyFocusHighlight(
            MainActivity a,
            TextView pill,
            MediaBadges.Badge badge,
            boolean focused,
            boolean compact,
            boolean tvStyle) {
        if (pill == null || badge == null) return;
        float radiusDp = compact ? 5f : (tvStyle ? 7f : 6f);
        if (focused) {
            pill.setTextColor(FOCUSED_TEXT_ARGB);
            UiCompat.setBackground(
                    pill, pillDrawable(a, FOCUSED_FILL_ARGB, FOCUSED_STROKE_ARGB, radiusDp, 2.0f));
            return;
        }
        int[] palette = colorsForStyle(badge.style);
        boolean reduceTransparency =
                a.prefs != null && a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false);
        int fill = reduceTransparency ? palette[3] : palette[1];
        int stroke = reduceTransparency ? ensureMinAlpha(palette[2], 0x73) : palette[2];
        float strokeDp = tvStyle ? 1.5f : 1.0f;
        pill.setTextColor(palette[0]);
        UiCompat.setBackground(pill, pillDrawable(a, fill, stroke, radiusDp, strokeDp));
    }

    private static GradientDrawable pillDrawable(
            MainActivity a, int fillColor, int strokeColor, float radiusDp, float strokeDp) {
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(fillColor);
        gd.setCornerRadius(a.dp(radiusDp));
        gd.setStroke(Math.max(1, a.dp(strokeDp)), strokeColor);
        return gd;
    }

    private static int ensureMinAlpha(int argb, int minAlpha) {
        int alpha = Math.max((argb >>> 24) & 0xff, minAlpha);
        return (alpha << 24) | (argb & 0x00ffffff);
    }

    /**
     * Returns {@code {textArgb, fillArgb, strokeArgb, solidFillArgb}} locked 1:1 with {@code
     * shared/ui-spec/motion-tokens.json#badgeStyles}.
     */
    static int[] colorsForStyle(String style) {
        if ("uhdGold".equals(style)) {
            return new int[] {0xffffb340, 0x2eff9f0a, 0x66ff9f0a, 0xeb3a2810};
        }
        if ("hdCyan".equals(style)) {
            return new int[] {0xff70d7ff, 0x2964d2ff, 0x5c64d2ff, 0xeb142c38};
        }
        if ("sdNeutral".equals(style)) {
            return new int[] {0xffd1d1da, 0x33787884, 0x4debebf5, 0xeb25252b};
        }
        if ("premiumCombo".equals(style)) {
            return new int[] {0xffe5c7ff, 0x335e5ce6, 0x73bf5af2, 0xeb261f42};
        }
        if ("visionPurple".equals(style)) {
            return new int[] {0xffdeb0ff, 0x2ebf5af2, 0x66bf5af2, 0xeb2d1b38};
        }
        if ("hdrBlue".equals(style)) {
            return new int[] {0xff64d2ff, 0x2e0a84ff, 0x660a84ff, 0xeb122640};
        }
        if ("discEmerald".equals(style)) {
            return new int[] {0xff63e682, 0x2930d158, 0x5c30d158, 0xeb142e1c};
        }
        if ("streamTeal".equals(style)) {
            return new int[] {0xff82d7ff, 0x265ac8fa, 0x525ac8fa, 0xeb152936};
        }
        if ("spatialAudio".equals(style)) {
            return new int[] {0xff8ae0ff, 0x2e0a84ff, 0x665ac8fa, 0xeb13283d};
        }
        if ("standardAudio".equals(style)) {
            return new int[] {0xfff5f5f7, 0x38787884, 0x3bffffff, 0xeb28282e};
        }
        if ("codecSlate".equals(style)) {
            return new int[] {0xffd1d1da, 0x29787884, 0x29ffffff, 0xeb222228};
        }
        if ("platformTag".equals(style)) {
            return new int[] {0xffebebf5, 0x2e36363d, 0x45ffffff, 0xeb28282e};
        }
        return new int[] {0xffd1d1da, 0x29787884, 0x3bffffff, 0xeb222228};
    }
}
