package com.pilipala.marcomovie;

/** Read prose by almost one viewport while preserving two lines of visual context. */
final class TvReadingScrollPolicy {
    static int step(int viewport, int lineHeight, int minimum) {
        if (viewport <= 0) return 0;
        int line = Math.max(1, lineHeight);
        int lines = Math.max(1, viewport / line - 2);
        return Math.min(viewport, Math.max(Math.min(minimum, viewport), lines * line));
    }
}
