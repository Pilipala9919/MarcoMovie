package com.pilipala.marcomovie;

import android.graphics.drawable.GradientDrawable;

/** Lightweight tinted surfaces; no video capture, blur, or output-surface replacement. */
final class TvV17Surface {
    static GradientDrawable rounded(int color, float radiusPx, int strokeColor, int strokePx) {
        GradientDrawable shape = new GradientDrawable();
        shape.setColor(color);
        shape.setCornerRadius(radiusPx);
        if (strokePx > 0) shape.setStroke(strokePx, strokeColor);
        return shape;
    }

    static GradientDrawable panel(TvV17Theme theme, float radiusPx) {
        return rounded(
                theme.reducedTransparency ? TvV17Theme.OPAQUE_SURFACE : TvV17Theme.SURFACE,
                radiusPx,
                0x2affffff,
                1);
    }

    /** Readable TV overlay. No backdrop capture; reduced transparency is fully opaque. */
    static GradientDrawable navigationEdge(TvV17Theme theme) {
        return navigationEdge(theme, false);
    }

    /** Static frosted tint: no blur passes, video readback or continuous repaint. */
    static GradientDrawable navigationEdge(TvV17Theme theme, boolean expanded) {
        if (theme.reducedTransparency) {
            return new GradientDrawable(
                    GradientDrawable.Orientation.LEFT_RIGHT,
                    new int[] {0xff1b222b, 0xff1b222b, 0xff1b222b, 0x001b222b});
        }
        return new GradientDrawable(
                GradientDrawable.Orientation.LEFT_RIGHT,
                expanded
                        ? new int[] {0xfa141b24, 0xf51b242f, 0xe019222e, 0x0019222e}
                        : new int[] {0xee10151d, 0xa6121720, 0x00121720});
    }
}
