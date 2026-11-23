package com.pilipala.marcomovie;

import java.util.concurrent.atomic.AtomicLong;

/** In-memory revocation token. No URLs, queries, credentials or private data are persisted. */
final class TvSearchContext {
    private static final AtomicLong EPOCH = new AtomicLong();
    private final long epoch = EPOCH.get();
    private final Object config;
    private final boolean privateMode;
    private final int engineEpoch;

    TvSearchContext(Object config, boolean privateMode, int engineEpoch) {
        this.config = config;
        this.privateMode = privateMode;
        this.engineEpoch = engineEpoch;
    }

    boolean matches(Object config, boolean privateMode, int engineEpoch) {
        return epoch == EPOCH.get()
                && this.config == config
                && this.privateMode == privateMode
                && this.engineEpoch == engineEpoch;
    }

    static void revokeAll() {
        EPOCH.incrementAndGet();
    }
}
