package com.pilipala.marcomovie;

/** Testable pause/preview/resume transaction. The host supplies immutable player/session guards. */
final class TvMarkerTransaction {
    interface Player {
        long position();

        long duration();

        boolean playing();

        void pause();

        void seek(long position);

        void start();
    }

    interface Valid {
        boolean get();
    }

    interface Save {
        void write(boolean intro, long position, long duration) throws Exception;
    }

    final long entry, duration;
    final boolean wasPlaying;
    private final Player player;
    private final Valid valid;
    boolean closed;

    TvMarkerTransaction(Player player, Valid valid) {
        this.player = player;
        this.valid = valid;
        if (!valid.get()) throw new IllegalStateException("stale playback");
        entry = Math.max(0, player.position());
        duration = Math.max(0, player.duration());
        wasPlaying = player.playing();
        player.pause();
    }

    void preview(long position) {
        if (closed || !valid.get()) {
            abort();
            return;
        }
        player.pause();
        player.seek(position);
    }

    void confirm(boolean intro, long position, Save save) throws Exception {
        if (closed || !valid.get()) throw new IllegalStateException("播放已更改，请重新打开标记");
        player.pause();
        save.write(intro, position, duration);
        finish();
    }

    void cancel() {
        if (!closed) finish();
    }

    private void finish() {
        boolean resume = wasPlaying && valid.get();
        closed = true;
        if (resume) player.start();
    }

    void abort() {
        closed = true;
    } // Lifecycle, focus loss and identity change never resume.
}
