package com.pilipala.marcomovie;

/** Pixel-exact height budget for the TV brand header and all eight destinations. */
final class TvRailMetrics {
    private TvRailMetrics() {}

    static int height(float scale, float density, int count) {
        int padding = Math.round(Math.round(8 * scale) * density);
        int header = Math.round(Math.round(44 * scale) * density);
        int headerGap = Math.round(Math.round(8 * scale) * density);
        int cell = Math.round(Math.round(42 * scale) * density);
        int gap = Math.round(Math.max(3, Math.round(4 * scale)) * density);
        return padding * 2 + header + headerGap + count * (cell + gap * 2);
    }

    static float fit(float requested, int availablePx, float density, int count) {
        if (height(requested, density, count) <= availablePx) return requested;
        float low = 0, high = requested;
        for (int i = 0; i < 24; i++) {
            float mid = (low + high) / 2;
            if (height(mid, density, count) <= availablePx) low = mid;
            else high = mid;
        }
        return low;
    }
}
