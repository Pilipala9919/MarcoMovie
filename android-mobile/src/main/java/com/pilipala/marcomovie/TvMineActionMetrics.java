package com.pilipala.marcomovie;

/** One equal-width row; small viewports scroll instead of shrinking or wrapping labels. */
final class TvMineActionMetrics {
    static int width(int available, int minimum, int gap, int count) {
        if (count <= 0) return Math.max(1, minimum);
        return Math.max(Math.max(1, minimum), (available - Math.max(0, gap) * (count - 1)) / count);
    }
}
