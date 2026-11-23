package com.pilipala.marcomovie;

public final class TvMineActionMetricsChecks {
    public static void main(String[] args) {
        int cases = 0;
        for (int viewport : new int[] {320, 640, 720, 1024, 1280, 1736, 1920, 3840}) {
            for (int measuredMinimum : new int[] {100, 112, 200, 240, 300, 480}) {
                for (int gap : new int[] {10, 20, 24, 40}) {
                    int width = TvMineActionMetrics.width(viewport, measuredMinimum, gap, 7);
                    int total = width * 7 + gap * 6;
                    if (width < measuredMinimum) throw new AssertionError("label clipped");
                    if (measuredMinimum * 7 + gap * 6 <= viewport) {
                        if (total > viewport || viewport - total >= 7)
                            throw new AssertionError("uneven spare space");
                    } else if (width != measuredMinimum)
                        throw new AssertionError("scrolling row inflated");
                    cases++;
                }
            }
        }
        if (TvMineActionMetrics.width(0, 100, 10, 7) != 100)
            throw new AssertionError("pre-layout width");
        System.out.println(
                "PASS "
                        + (cases + 1)
                        + " equal action row fit/scroll budgets; text minimum supplied by actual Paint in UI");
    }
}
