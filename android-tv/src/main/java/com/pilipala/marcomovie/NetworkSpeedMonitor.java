// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.net.TrafficStats;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import android.os.SystemClock;
import java.util.Locale;

/**
 * Lightweight, lifecycle-safe real-time network speed monitor for playback loading & buffering
 * overlays. Prefers active player-engine byte throughput when available (MPV {@code cache-speed},
 * ExoPlayer/Media3 {@code TransferListener}) and seamlessly falls back to {@link TrafficStats}
 * UID RX deltas so pre-player URL resolution, live streams, and SystemPlayer all report live speed.
 */
final class NetworkSpeedMonitor {
    static final long SAMPLE_INTERVAL_MS = 600L;

    interface RateSource {
        /** Returns active player bytes/sec or {@code -1} to fall back to UID TrafficStats. */
        long engineBytesPerSec();
    }

    interface Listener {
        void onSpeedUpdated(long bytesPerSec, String formatted);
    }

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final RateSource rateSource;
    private final Listener listener;
    private boolean running;
    private long lastUidRxBytes = -1L;
    private long lastSampleTimeMs = -1L;
    private long smoothedRate = -1L;

    private final Runnable ticker =
            new Runnable() {
                @Override
                public void run() {
                    if (!running) return;
                    sampleAndDispatch();
                    if (running) {
                        handler.postDelayed(this, SAMPLE_INTERVAL_MS);
                    }
                }
            };

    NetworkSpeedMonitor(RateSource rateSource, Listener listener) {
        this.rateSource = rateSource;
        this.listener = listener;
    }

    void start() {
        if (running) return;
        running = true;
        lastSampleTimeMs = SystemClock.elapsedRealtime();
        lastUidRxBytes = readUidRxBytesSafe();
        smoothedRate = -1L;
        if (listener != null) {
            listener.onSpeedUpdated(-1L, formatSpeedLabel(-1L));
        }
        handler.removeCallbacks(ticker);
        handler.postDelayed(ticker, SAMPLE_INTERVAL_MS);
    }

    void stop() {
        running = false;
        handler.removeCallbacks(ticker);
        lastUidRxBytes = -1L;
        lastSampleTimeMs = -1L;
        smoothedRate = -1L;
    }

    boolean isRunning() {
        return running;
    }

    private void sampleAndDispatch() {
        long now = SystemClock.elapsedRealtime();
        long rawRate = -1L;

        if (rateSource != null) {
            try {
                long eng = rateSource.engineBytesPerSec();
                if (eng >= 0L) rawRate = eng;
            } catch (Throwable ignored) {
            }
        }

        long curUidBytes = readUidRxBytesSafe();
        if (rawRate < 0L && curUidBytes >= 0L && lastUidRxBytes >= 0L && lastSampleTimeMs > 0L) {
            long dt = now - lastSampleTimeMs;
            long delta = curUidBytes - lastUidRxBytes;
            long uidRate = computeRateBytesPerSec(delta, dt);
            if (uidRate >= 0L) {
                rawRate = uidRate;
            }
        }
        lastSampleTimeMs = now;
        if (curUidBytes >= 0L) {
            lastUidRxBytes = curUidBytes;
        }

        if (rawRate >= 0L) {
            smoothedRate = smoothRate(smoothedRate, rawRate);
        }
        if (listener != null) {
            long report = smoothedRate >= 0L ? smoothedRate : rawRate;
            listener.onSpeedUpdated(report, formatSpeedLabel(report));
        }
    }

    private static long readUidRxBytesSafe() {
        try {
            long rx = TrafficStats.getUidRxBytes(Process.myUid());
            return rx >= 0L ? rx : -1L;
        } catch (Throwable ignored) {
            return -1L;
        }
    }

    /** Pure-JVM rate helper returning bytes/sec or -1 on invalid intervals. */
    static long computeRateBytesPerSec(long deltaBytes, long deltaMs) {
        if (deltaMs <= 0L || deltaBytes < 0L) return -1L;
        return Math.round((deltaBytes * 1000.0) / (double) deltaMs);
    }

    /** Exponential smoothing favoring quick ramp-up while avoiding noisy jumps. */
    static long smoothRate(long previous, long current) {
        if (current < 0L) return previous;
        if (previous < 0L) return current;
        if (current == 0L) return previous < 2048L ? 0L : Math.round(previous * 0.35);
        return Math.round(previous * 0.35 + current * 0.65);
    }

    /** Formats a raw bytes/sec value into crisp fixed-unit human text. */
    static String formatSpeed(long bytesPerSec) {
        if (bytesPerSec < 0L) return "测速中…";
        if (bytesPerSec == 0L) return "0 KB/s";
        if (bytesPerSec < 1024L) return bytesPerSec + " B/s";
        double kb = bytesPerSec / 1024.0;
        if (kb < 1024.0) return String.format(Locale.US, "%.0f KB/s", kb);
        double mb = kb / 1024.0;
        if (mb < 1024.0) return String.format(Locale.US, "%.1f MB/s", mb);
        return String.format(Locale.US, "%.2f GB/s", mb / 1024.0);
    }

    static String formatSpeedLabel(long bytesPerSec) {
        return "实时网速 " + formatSpeed(bytesPerSec);
    }
}
