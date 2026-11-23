package com.pilipala.marcomovie;

import android.content.Context;

/** TV-only visual values. Persistence and device policy are supplied by the host. */
final class TvV17Theme {
    static final int BACKGROUND = 0xff101318;
    static final int SURFACE = 0xe6222a34;
    static final int OPAQUE_SURFACE = 0xff222a34;
    static final int TEXT = 0xfff2f4f5;
    static final int MUTED = 0xffa9b2be;
    static final int FOCUS = 0xfff4f7fa;
    final float densityScale;
    final float ambientStrength;
    final boolean reducedMotion;
    final boolean reducedTransparency;

    TvV17Theme(
            float densityScale,
            float ambientStrength,
            boolean reducedMotion,
            boolean reducedTransparency) {
        this.densityScale = Math.max(.75f, Math.min(1.4f, densityScale));
        this.ambientStrength = Math.max(0f, Math.min(1f, ambientStrength));
        this.reducedMotion = reducedMotion;
        this.reducedTransparency = reducedTransparency;
    }

    int dp(Context context, float value) {
        return Math.round(
                value * densityScale * context.getResources().getDisplayMetrics().density);
    }
}
