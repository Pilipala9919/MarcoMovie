package com.pilipala.marcomovie;

/** Phase-only diagnostics: no source addresses, titles, IDs, or authentication data. */
final class DetailRequest {
    final long started=android.os.SystemClock.elapsedRealtime();long dispatched,engineReady,returned,parsed;boolean cached;
    void ready(){long now=android.os.SystemClock.elapsedRealtime();android.util.Log.i("MovieDetailTiming","cache="+cached+" queue_ms="+(dispatched-started)+" engine_ms="+(engineReady-dispatched)+" source_ms="+(returned-engineReady)+" parse_ms="+(parsed-returned)+" present_ms="+(now-parsed)+" total_ms="+(now-started));}
}
