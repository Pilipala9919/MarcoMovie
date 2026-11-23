package com.pilipala.marcomovie;

/** One tail action per observed pass; only actual player positions can re-arm it. */
final class TvMarkerTailGate {
    private long node;
    private boolean triggered;

    void reset() {
        node = 0;
        triggered = false;
    }

    void node(long value) {
        if (node != value) {
            node = value;
            triggered = false;
        }
    }

    void observe(long actualPosition) {
        if (node > 0 && actualPosition >= 0 && actualPosition < node) triggered = false;
    }

    boolean take(long actualPosition) {
        observe(actualPosition);
        if (node <= 0 || actualPosition < node || triggered) return false;
        triggered = true;
        return true;
    }
}
