package com.pilipala.marcomovie;

/** Exercises the real pixel budget against supported UI/nav scales and rounding edges. */
public final class TvRailMetricsChecks {
    public static void main(String[] args) {
        int cases = 0;
        for (int pixels : new int[] {720, 1080, 2160}) {
            for (float baseDensity : new float[] {pixels / 540f, pixels / 720f}) {
                for (float ui : new float[] {1f, 1.1f, 1.2f}) {
                    float density = baseDensity * ui;
                    for (int nav = 85; nav <= 140; nav++) {
                        float request = nav / 100f;
                        int available = pixels - Math.round(32 * density);
                        float fit = TvRailMetrics.fit(request, available, density, 8);
                        if (!(fit > 0 && fit <= request)) throw new AssertionError("invalid scale");
                        if (TvRailMetrics.height(fit, density, 8) > available)
                            throw new AssertionError("bottom settings clipped");
                        if (Math.round(Math.round(42 * fit) * density) < Math.round(32 * density))
                            throw new AssertionError("navigation target too small");
                        if (TvRailMetrics.height(request, density, 8) <= available
                                && fit != request)
                            throw new AssertionError("unnecessary shrinking");
                        cases++;
                    }
                }
            }
        }
        System.out.println("PASS " + cases + " TV brand/8-item pixel budgets");
    }
}
