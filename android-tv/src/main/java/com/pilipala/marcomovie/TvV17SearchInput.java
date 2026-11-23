package com.pilipala.marcomovie;

/** Time-window policy shared by touch clicks and non-repeated remote confirmations. */
final class TvV17SearchInput {
    static final long DOUBLE_CLICK_MS = 500L;

    private TvV17SearchInput() {}

    static boolean isDoubleClick(long previous, long now) {
        return previous > 0 && now >= previous && now - previous <= DOUBLE_CLICK_MS;
    }
}
