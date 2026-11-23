package com.pilipala.marcomovie;

/** Pure timing policy checks; physical key repeat and IME need Android device tests. */
public final class TvV17SearchInputChecks {
    public static void main(String[] args) {
        long[] gaps = {419, 420, 499, 500, 501};
        boolean[] expected = {true, true, true, true, false};
        for (int i = 0; i < gaps.length; i++) {
            if (TvV17SearchInput.isDoubleClick(1000, 1000 + gaps[i]) != expected[i])
                throw new AssertionError("gap " + gaps[i]);
        }
        if (TvV17SearchInput.isDoubleClick(0, 100)) throw new AssertionError("first click");
        if (TvV17SearchInput.isDoubleClick(1000, 999)) throw new AssertionError("clock order");
        System.out.println("PASS search click window boundaries");
    }
}
