package com.pilipala.marcomovie;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.DashPathEffect;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.text.Layout;
import android.view.View;
import android.widget.FrameLayout;
import androidx.media3.common.text.Cue;
import androidx.media3.ui.CaptionStyleCompat;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.regex.Pattern;

/**
 * Wrapper around Media3 SubtitleView with full-screen interactive preview, continuous font size &
 * stroke/weight rendering, horizontal/vertical positioning, and center-axis guide lines (中轴线指引).
 */
final class SubtitleOverlayView extends FrameLayout {
    static final String[] STYLE_NAMES = {
        "纯白黑边 · 透明底",
        "暖黄黑边 · 透明底",
        "天青黑边 · 透明底",
        "翠绿黑边 · 透明底",
        "珊瑚粉边 · 透明底",
        "纯白字幕 · 毛玻璃黑底",
        "暖黄字幕 · 毛玻璃黑底",
        "纯白极简 · 柔和阴影"
    };
    static final String[] STYLE_LABELS = STYLE_NAMES;
    static final int[] STYLE_COLORS = {
        Color.WHITE,
        0xFFFFE066,
        0xFF8BE9FD,
        0xFF69F0AE,
        0xFFFF9EBB,
        Color.WHITE,
        0xFFFFE066,
        Color.WHITE
    };

    static String bgStyleLabel(int preset) {
        return styleName(preset);
    }

    private static final String PREVIEW_LINE_CN = "那晚的星光穿过银幕，落在了故事开始的地方";
    private static final String PREVIEW_LINE_EN = "The starlight fell where the story began.";
    private static final Pattern RESIDUAL_ASS_TAG = Pattern.compile("\\{\\\\[^}]*\\}");

    final androidx.media3.ui.SubtitleView delegate;
    private List<Cue> currentCues = Collections.emptyList();
    private boolean previewActive;
    private boolean showAxisGuides;
    private int currentStylePreset = 0;
    private int currentWeight = 50;
    private int currentSize = 45;
    private int currentBottomDp = 24;
    private int currentOffsetX = 0;

    private final Paint axisPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint boxPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint strokePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint fillPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint badgePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF tempRect = new RectF();

    SubtitleOverlayView(Context context) {
        super(context);
        setWillNotDraw(true);
        delegate = new androidx.media3.ui.SubtitleView(context);
        delegate.setApplyEmbeddedStyles(false);
        delegate.setApplyEmbeddedFontSizes(false);
        delegate.setVisibility(View.GONE);
        addView(delegate, new FrameLayout.LayoutParams(-1, -1));
        float density = context.getResources().getDisplayMetrics().density;
        axisPaint.setStyle(Paint.Style.STROKE);
        axisPaint.setPathEffect(new DashPathEffect(new float[] {6f * density, 5f * density}, 0f));
        applyStylePreset(0, 50);
    }

    private float dp(float value) {
        return value * getResources().getDisplayMetrics().density;
    }

    static String styleName(int preset) {
        int idx = Prefs.clampSubtitleStyle(preset);
        return STYLE_NAMES[idx];
    }

    void setFractionalTextSize(float fractionOfHeight) {
        delegate.setApplyEmbeddedFontSizes(false);
        delegate.setFractionalTextSize(fractionOfHeight);
        this.currentSize = Prefs.clampSubtitleSize(Math.round(fractionOfHeight * 1000f));
        invalidate();
    }

    void setSubtitleSizeValue(int size) {
        this.currentSize = Prefs.clampSubtitleSize(size);
        delegate.setApplyEmbeddedFontSizes(false);
        delegate.setFractionalTextSize(this.currentSize / 1000f);
        invalidate();
    }

    void setBottomPaddingFraction(float fractionOfHeight) {
        delegate.setBottomPaddingFraction(fractionOfHeight);
        this.currentBottomDp =
                Prefs.clampSubtitleBottom(Math.round((fractionOfHeight - 0.02f) * 650f));
        invalidate();
    }

    void setSubtitleBottomDp(int bottomDp) {
        this.currentBottomDp = Prefs.clampSubtitleBottom(bottomDp);
        delegate.setBottomPaddingFraction(0.02f + (this.currentBottomDp / 650f));
        invalidate();
    }

    void setSubtitleWeight(int weight) {
        this.currentWeight = Prefs.clampSubtitleWeight(weight);
        applyStylePreset(this.currentStylePreset, this.currentWeight);
        invalidate();
    }

    void setHorizontalOffsetPercent(int offsetPercent) {
        this.currentOffsetX = Prefs.clampSubtitleOffsetX(offsetPercent);
        updateDelegateTranslationX(getWidth());
        invalidate();
    }

    int getHorizontalOffsetPercent() {
        return currentOffsetX;
    }

    int getSubtitleBottomDp() {
        return currentBottomDp;
    }

    int getSubtitleSizeValue() {
        return currentSize;
    }

    int getSubtitleWeight() {
        return currentWeight;
    }

    int getStylePreset() {
        return currentStylePreset;
    }

    void setShowAxisGuides(boolean show) {
        if (this.showAxisGuides != show) {
            this.showAxisGuides = show;
            setWillNotDraw(!this.previewActive && !this.showAxisGuides);
            invalidate();
        }
    }

    private void updateDelegateTranslationX(int width) {
        if (delegate == null) return;
        float maxShift = Math.max(dp(80), width * 0.30f);
        delegate.setTranslationX((currentOffsetX / 100f) * maxShift);
    }

    @Override
    protected void onSizeChanged(int w, int h, int oldw, int oldh) {
        super.onSizeChanged(w, h, oldw, oldh);
        updateDelegateTranslationX(w);
    }

    void setUserDefaultStyle() {
        applyStylePreset(0, 50);
    }

    void applyStylePreset(int preset) {
        applyStylePreset(preset, currentWeight);
    }

    void applyStylePreset(int preset, int weight) {
        int idx = Prefs.clampSubtitleStyle(preset);
        int w = Prefs.clampSubtitleWeight(weight);
        this.currentStylePreset = idx;
        this.currentWeight = w;
        delegate.setApplyEmbeddedStyles(false);

        Typeface tf;
        if (w < 25) {
            tf = Typeface.create("sans-serif-light", Typeface.NORMAL);
        } else if (w < 48) {
            tf = Typeface.create("sans-serif", Typeface.NORMAL);
        } else if (w < 75) {
            tf = Typeface.create("sans-serif-medium", Typeface.BOLD);
        } else {
            tf = Typeface.create("sans-serif-black", Typeface.BOLD);
        }

        int fg = STYLE_COLORS[idx];
        int bg = (idx == 5 || idx == 6) ? 0x88000000 : Color.TRANSPARENT;
        int edgeType =
                idx == 7
                        ? CaptionStyleCompat.EDGE_TYPE_DROP_SHADOW
                        : CaptionStyleCompat.EDGE_TYPE_OUTLINE;
        int edgeColor = w < 30 ? 0xCC000000 : 0xF2000000;

        CaptionStyleCompat style =
                new CaptionStyleCompat(fg, bg, Color.TRANSPARENT, edgeType, edgeColor, tf);
        delegate.setStyle(style);
        invalidate();
    }

    void setPreviewActive(boolean active) {
        this.previewActive = active;
        this.showAxisGuides = active;
        setWillNotDraw(!this.previewActive && !this.showAxisGuides);
        refreshCues();
        invalidate();
    }

    boolean isPreviewActive() {
        return previewActive;
    }

    @Override
    public void setPadding(int left, int top, int right, int bottom) {
        if (delegate != null) {
            delegate.setPadding(left, top, right, bottom);
        } else {
            super.setPadding(left, top, right, bottom);
        }
    }

    void setCues(List<Cue> cues) {
        this.currentCues = cues != null ? cues : Collections.emptyList();
        refreshCues();
    }

    private static final class TextCueSlot {
        final int order;
        final Cue cue;
        final String text;
        final float sortLine;
        final boolean hasFracLine;

        TextCueSlot(int order, Cue cue, String text, float sortLine, boolean hasFracLine) {
            this.order = order;
            this.cue = cue;
            this.text = text;
            this.sortLine = sortLine;
            this.hasFracLine = hasFracLine;
        }
    }

    private static String sanitizeCueText(CharSequence raw) {
        if (raw == null || raw.length() == 0) return "";
        String s = raw.toString().replace("\r\n", "\n").replace('\r', '\n');
        s = s.replace("\\N", "\n").replace("\\n", "\n");
        s = RESIDUAL_ASS_TAG.matcher(s).replaceAll("");
        String[] lines = s.split("\n", -1);
        StringBuilder out = new StringBuilder(s.length());
        for (String line : lines) {
            String trimmed = line.trim();
            if (trimmed.isEmpty()) continue;
            if (out.length() > 0) out.append('\n');
            out.append(trimmed);
        }
        return out.toString();
    }

    private static boolean isTopClusterCue(Cue cue) {
        if (cue.line == Cue.DIMEN_UNSET) return false;
        if (cue.lineType == Cue.LINE_TYPE_FRACTION) {
            return cue.line <= 0.32f;
        }
        if (cue.lineType == Cue.LINE_TYPE_NUMBER) {
            return cue.line >= 0f && cue.line <= 2f;
        }
        return false;
    }

    private static boolean isBottomClusterCue(Cue cue) {
        if (cue.line == Cue.DIMEN_UNSET) return true;
        if (cue.lineType == Cue.LINE_TYPE_NUMBER) {
            return cue.line < 0f;
        }
        if (cue.lineType == Cue.LINE_TYPE_FRACTION) {
            return cue.line >= 0.55f;
        }
        return true;
    }

    private static String joinUniqueSlots(List<TextCueSlot> slots) {
        LinkedHashSet<String> seenLines = new LinkedHashSet<>();
        StringBuilder sb = new StringBuilder();
        for (TextCueSlot slot : slots) {
            for (String part : slot.text.split("\n")) {
                String trimmed = part.trim();
                if (trimmed.isEmpty() || !seenLines.add(trimmed)) continue;
                if (sb.length() > 0) sb.append('\n');
                sb.append(trimmed);
            }
        }
        return sb.toString();
    }

    /**
     * Coalesces simultaneous colliding cues (e.g. bilingual ASS/SRT/WebVTT tracks where Chinese and
     * English emit as separate Cues sharing the same bottom/top anchor or tightly spaced {@code
     * \pos} coordinates) into non-overlapping stacked multi-line cues.
     */
    static List<Cue> normalizeCuesForDisplay(List<Cue> rawCues, float fractionalTextSize) {
        if (rawCues == null || rawCues.isEmpty()) return Collections.emptyList();
        List<Cue> out = new ArrayList<>(rawCues.size());
        List<TextCueSlot> bottomSlots = new ArrayList<>();
        List<TextCueSlot> topSlots = new ArrayList<>();
        List<TextCueSlot> midSlots = new ArrayList<>();

        int idx = 0;
        for (Cue cue : rawCues) {
            if (cue == null) continue;
            if (cue.bitmap != null) {
                out.add(cue);
                continue;
            }
            String text = sanitizeCueText(cue.text);
            if (text.isEmpty()) continue;
            boolean hasFrac = cue.line != Cue.DIMEN_UNSET && cue.lineType == Cue.LINE_TYPE_FRACTION;
            float sortLine = hasFrac ? cue.line : (isTopClusterCue(cue) ? 0.05f : 0.95f);
            TextCueSlot slot = new TextCueSlot(idx++, cue, text, sortLine, hasFrac);
            if (isTopClusterCue(cue)) {
                topSlots.add(slot);
            } else if (isBottomClusterCue(cue)) {
                bottomSlots.add(slot);
            } else {
                midSlots.add(slot);
            }
        }

        if (!topSlots.isEmpty()) {
            Collections.sort(
                    topSlots,
                    new Comparator<TextCueSlot>() {
                        @Override
                        public int compare(TextCueSlot a, TextCueSlot b) {
                            if (a.hasFracLine
                                    && b.hasFracLine
                                    && Math.abs(a.sortLine - b.sortLine) > 0.005f) {
                                return Float.compare(a.sortLine, b.sortLine);
                            }
                            return Integer.compare(a.order, b.order);
                        }
                    });
            String joined = joinUniqueSlots(topSlots);
            if (!joined.isEmpty()) {
                out.add(
                        new Cue.Builder()
                                .setText(joined)
                                .setTextAlignment(Layout.Alignment.ALIGN_CENTER)
                                .setLine(0.05f, Cue.LINE_TYPE_FRACTION)
                                .setLineAnchor(Cue.ANCHOR_TYPE_START)
                                .build());
            }
        }

        if (!midSlots.isEmpty()) {
            Collections.sort(
                    midSlots,
                    new Comparator<TextCueSlot>() {
                        @Override
                        public int compare(TextCueSlot a, TextCueSlot b) {
                            if (a.hasFracLine
                                    && b.hasFracLine
                                    && Math.abs(a.sortLine - b.sortLine) > 0.005f) {
                                return Float.compare(a.sortLine, b.sortLine);
                            }
                            return Integer.compare(a.order, b.order);
                        }
                    });
            float minGap = Math.max(0.08f, Math.max(0.025f, fractionalTextSize) * 1.45f);
            int i = 0;
            while (i < midSlots.size()) {
                List<TextCueSlot> group = new ArrayList<>();
                TextCueSlot anchor = midSlots.get(i);
                group.add(anchor);
                float lastLine = anchor.sortLine;
                int j = i + 1;
                while (j < midSlots.size()) {
                    TextCueSlot next = midSlots.get(j);
                    if (Math.abs(next.sortLine - lastLine) < minGap) {
                        group.add(next);
                        lastLine = next.sortLine;
                        j++;
                    } else {
                        break;
                    }
                }
                String joined = joinUniqueSlots(group);
                if (!joined.isEmpty()) {
                    Cue.Builder cb =
                            new Cue.Builder()
                                    .setText(joined)
                                    .setTextAlignment(Layout.Alignment.ALIGN_CENTER);
                    if (anchor.hasFracLine) {
                        cb.setLine(anchor.sortLine, Cue.LINE_TYPE_FRACTION)
                                .setLineAnchor(Cue.ANCHOR_TYPE_MIDDLE);
                    }
                    out.add(cb.build());
                }
                i = j;
            }
        }

        if (!bottomSlots.isEmpty()) {
            Collections.sort(
                    bottomSlots,
                    new Comparator<TextCueSlot>() {
                        @Override
                        public int compare(TextCueSlot a, TextCueSlot b) {
                            if (a.hasFracLine
                                    && b.hasFracLine
                                    && Math.abs(a.sortLine - b.sortLine) > 0.005f) {
                                return Float.compare(a.sortLine, b.sortLine);
                            }
                            return Integer.compare(a.order, b.order);
                        }
                    });
            String joined = joinUniqueSlots(bottomSlots);
            if (!joined.isEmpty()) {
                // Leave line = DIMEN_UNSET so Media3 SubtitlePainter renders all bilingual lines in
                // one StaticLayout with zero overlap AND honors user bottomPaddingFraction
                // uniformly.
                out.add(
                        new Cue.Builder()
                                .setText(joined)
                                .setTextAlignment(Layout.Alignment.ALIGN_CENTER)
                                .build());
            }
        }

        return out;
    }

    private void refreshCues() {
        if (delegate == null) return;
        if (previewActive) {
            delegate.setVisibility(View.INVISIBLE);
            return;
        }
        List<Cue> normalized = normalizeCuesForDisplay(currentCues, currentSize / 1000f);
        if (!normalized.isEmpty()) {
            delegate.setVisibility(View.VISIBLE);
            delegate.setCues(normalized);
        } else {
            delegate.setCues(Collections.emptyList());
            delegate.setVisibility(View.GONE);
        }
    }

    @Override
    protected void dispatchDraw(Canvas canvas) {
        super.dispatchDraw(canvas);
        if (!previewActive && !showAxisGuides) return;

        int w = getWidth();
        int h = getHeight();
        if (w <= 0 || h <= 0) return;

        float centerX = w / 2f;
        float centerY = h / 2f;
        float maxShiftX = Math.max(dp(80), w * 0.30f);
        float subCenterX = centerX + (currentOffsetX / 100f) * maxShiftX;

        // Map bottomDp (0..180) to vertical position from bottom
        float bottomMarginPx = dp(24) + (currentBottomDp / 180f) * Math.max(dp(160), h * 0.56f);
        float baseTextPx = Math.max(dp(15), Math.min(dp(44), h * (currentSize / 1000f) * 0.88f));
        float subTextPx = baseTextPx * 0.72f;
        float lineGap = dp(5);
        float blockHeight = baseTextPx + subTextPx + lineGap + dp(16);
        float subCenterY =
                Math.max(
                        blockHeight * 0.6f + dp(20),
                        Math.min(h - blockHeight * 0.6f - dp(12), h - bottomMarginPx));

        boolean alignedX = Math.abs(currentOffsetX) <= 2;
        boolean alignedDefaultY = Math.abs(currentBottomDp - 24) <= 2;
        boolean alignedCenterY = Math.abs(subCenterY - centerY) <= dp(10);

        // 1. Draw Center-Axis Guide Lines (中轴线指引)
        if (showAxisGuides) {
            // Vertical screen center axis line (X = 50%)
            axisPaint.setStrokeWidth(alignedX ? dp(1.8f) : dp(1.1f));
            axisPaint.setColor(alignedX ? 0xDD34D399 : 0x58FFFFFF);
            canvas.drawLine(centerX, dp(16), centerX, h - dp(16), axisPaint);

            // Horizontal screen center axis line (Y = 50%)
            axisPaint.setStrokeWidth(alignedCenterY ? dp(1.6f) : dp(1.0f));
            axisPaint.setColor(alignedCenterY ? 0xDD34D399 : 0x38FFFFFF);
            canvas.drawLine(dp(24), centerY, w - dp(24), centerY, axisPaint);

            // Subtitle baseline horizontal guide
            axisPaint.setStrokeWidth(alignedDefaultY ? dp(1.6f) : dp(1.0f));
            axisPaint.setColor(alignedDefaultY ? 0xDD5AC8FA : 0x525AC8FA);
            canvas.drawLine(dp(36), subCenterY, w - dp(36), subCenterY, axisPaint);

            // Center crosshair reticle
            boxPaint.setStyle(Paint.Style.STROKE);
            boxPaint.setStrokeWidth(dp(1.2f));
            boxPaint.setColor(alignedX ? 0xEE34D399 : 0x66FFFFFF);
            canvas.drawCircle(centerX, subCenterY, dp(5), boxPaint);
        }

        // 2. Render live preview subtitle with continuous Size (25..65) & Weight (0..100)
        Typeface tf;
        if (currentWeight < 25) {
            tf = Typeface.create("sans-serif-light", Typeface.NORMAL);
        } else if (currentWeight < 48) {
            tf = Typeface.create("sans-serif", Typeface.NORMAL);
        } else if (currentWeight < 75) {
            tf = Typeface.create("sans-serif-medium", Typeface.BOLD);
        } else {
            tf = Typeface.create("sans-serif-black", Typeface.BOLD);
        }

        boolean fakeBold = currentWeight >= 68;
        float strokeWidthPx = dp(0.7f + (currentWeight / 100f) * 4.8f);

        fillPaint.setTypeface(tf);
        fillPaint.setFakeBoldText(fakeBold);
        fillPaint.setTextAlign(Paint.Align.CENTER);
        fillPaint.setColor(STYLE_COLORS[currentStylePreset]);
        if (currentStylePreset == 7) {
            fillPaint.setShadowLayer(dp(5), 0, dp(2), 0xDD000000);
        } else {
            fillPaint.clearShadowLayer();
        }

        strokePaint.setTypeface(tf);
        strokePaint.setFakeBoldText(fakeBold);
        strokePaint.setTextAlign(Paint.Align.CENTER);
        strokePaint.setStyle(Paint.Style.STROKE);
        strokePaint.setStrokeJoin(Paint.Join.ROUND);
        strokePaint.setStrokeCap(Paint.Cap.ROUND);
        strokePaint.setStrokeWidth(strokeWidthPx);
        strokePaint.setColor(0xF0000000);

        fillPaint.setTextSize(baseTextPx);
        Paint.FontMetrics cnFm = fillPaint.getFontMetrics();
        float cnLineH = Math.max(baseTextPx, cnFm.descent - cnFm.ascent);
        float w1 = fillPaint.measureText(PREVIEW_LINE_CN);
        fillPaint.setTextSize(subTextPx);
        Paint.FontMetrics enFm = fillPaint.getFontMetrics();
        float enLineH = Math.max(subTextPx, enFm.descent - enFm.ascent);
        float w2 = fillPaint.measureText(PREVIEW_LINE_EN);
        float safeLineGap = Math.max(dp(6), strokeWidthPx * 1.15f + dp(4));
        float totalTextH = cnLineH + enLineH + safeLineGap;
        float boxW = Math.min(w - dp(32), Math.max(w1, w2) + dp(28));
        float boxH = totalTextH + dp(18);
        subCenterY =
                Math.max(
                        boxH * 0.55f + dp(20),
                        Math.min(h - boxH * 0.55f - dp(12), h - bottomMarginPx));

        tempRect.set(
                subCenterX - boxW / 2f,
                subCenterY - boxH / 2f,
                subCenterX + boxW / 2f,
                subCenterY + boxH / 2f);

        // Background box for translucent-backdrop presets (5 & 6)
        if (currentStylePreset == 5 || currentStylePreset == 6) {
            boxPaint.setStyle(Paint.Style.FILL);
            boxPaint.setColor(0x88000000);
            canvas.drawRoundRect(tempRect, dp(10), dp(10), boxPaint);
        }

        // Interactive bounding frame during adjustment
        if (showAxisGuides) {
            boxPaint.setStyle(Paint.Style.STROKE);
            boxPaint.setStrokeWidth(dp(1.2f));
            boxPaint.setColor(alignedX ? 0xAA34D399 : 0x665AC8FA);
            canvas.drawRoundRect(tempRect, dp(10), dp(10), boxPaint);
        }

        float textTopY = subCenterY - totalTextH / 2f;
        float line1Y = textTopY - cnFm.ascent;
        float line2Y = textTopY + cnLineH + safeLineGap - enFm.ascent;

        // Draw Line 1 (CN)
        if (currentStylePreset != 7) {
            strokePaint.setTextSize(baseTextPx);
            canvas.drawText(PREVIEW_LINE_CN, subCenterX, line1Y, strokePaint);
        }
        fillPaint.setTextSize(baseTextPx);
        canvas.drawText(PREVIEW_LINE_CN, subCenterX, line1Y, fillPaint);

        // Draw Line 2 (EN)
        if (currentStylePreset != 7) {
            strokePaint.setTextSize(subTextPx);
            strokePaint.setStrokeWidth(strokeWidthPx * 0.82f);
            canvas.drawText(PREVIEW_LINE_EN, subCenterX, line2Y, strokePaint);
        }
        fillPaint.setTextSize(subTextPx);
        canvas.drawText(PREVIEW_LINE_EN, subCenterX, line2Y, fillPaint);

        // 3. Draw small alignment pill badge right above the subtitle bounding box
        if (showAxisGuides) {
            String alignText =
                    (alignedX
                                    ? "中轴线已对齐 ✓"
                                    : ("水平偏移 " + (currentOffsetX > 0 ? "+" : "") + currentOffsetX))
                            + "  ·  高度 "
                            + currentBottomDp
                            + "dp  ·  字号 "
                            + currentSize
                            + "  ·  粗细 "
                            + currentWeight;
            badgePaint.setTextSize(dp(11.5f));
            badgePaint.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
            badgePaint.setTextAlign(Paint.Align.CENTER);
            float bw = badgePaint.measureText(alignText) + dp(20);
            float bh = dp(24);
            float by = Math.max(dp(12), tempRect.top - bh - dp(8));
            RectF pillRect = new RectF(subCenterX - bw / 2f, by, subCenterX + bw / 2f, by + bh);
            boxPaint.setStyle(Paint.Style.FILL);
            boxPaint.setColor(0xD8121A17);
            canvas.drawRoundRect(pillRect, dp(12), dp(12), boxPaint);
            boxPaint.setStyle(Paint.Style.STROKE);
            boxPaint.setStrokeWidth(dp(1f));
            boxPaint.setColor(alignedX ? 0xAA34D399 : 0x55FFFFFF);
            canvas.drawRoundRect(pillRect, dp(12), dp(12), boxPaint);
            badgePaint.setColor(alignedX ? 0xFF34D399 : 0xFFE5E7EB);
            canvas.drawText(alignText, subCenterX, by + bh * 0.68f, badgePaint);
        }
    }
}
