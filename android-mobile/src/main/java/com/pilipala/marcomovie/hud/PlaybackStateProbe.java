package com.pilipala.marcomovie.hud;

import android.os.Looper;
import androidx.media3.common.Player;
import com.pilipala.marcomovie.MoviePlayer;
import java.lang.reflect.Field;

/**
 * Pure-Java playback intent & lifecycle guard helper for touch gestures (S-02) and skip countdowns
 * (S-03).
 *
 * <p>Distinguishes Media3 {@link Player#STATE_BUFFERING} with {@code playWhenReady == true} from
 * real pauses or transient audio-focus suppression without modifying {@link MoviePlayer}.
 */
public final class PlaybackStateProbe {
    public static final int STATE_IDLE = 1;
    public static final int STATE_BUFFERING = 2;
    public static final int STATE_READY = 3;
    public static final int STATE_ENDED = 4;
    public static final int SUPPRESSION_NONE = 0;
    public static final int SUPPRESSION_TRANSIENT_AUDIO_FOCUS_LOSS = 1;

    private static volatile boolean fieldsResolved;
    private static Field exoField;
    private static Field releasedField;

    private PlaybackStateProbe() {}

    public static final class Snapshot {
        public final boolean hasExoState;
        public final boolean playWhenReady;
        public final int playbackState;
        public final int suppressionReason;
        public final boolean fallbackPlaying;

        public Snapshot(
                boolean hasExoState,
                boolean playWhenReady,
                int playbackState,
                int suppressionReason,
                boolean fallbackPlaying) {
            this.hasExoState = hasExoState;
            this.playWhenReady = playWhenReady;
            this.playbackState = playbackState;
            this.suppressionReason = suppressionReason;
            this.fallbackPlaying = fallbackPlaying;
        }
    }

    /**
     * Determines whether playback is actively intended to play (allowing Media3 {@code
     * STATE_BUFFERING} while rejecting user pauses, ended/idle states, and audio-focus
     * suppression).
     */
    public static boolean isPlaybackIntended(
            boolean activityPlaying,
            boolean hasExoState,
            boolean playWhenReady,
            int playbackState,
            int suppressionReason,
            boolean fallbackPlaying) {
        if (!activityPlaying) return false;
        if (hasExoState) {
            if (!playWhenReady) return false;
            if (suppressionReason != SUPPRESSION_NONE) return false;
            return playbackState == STATE_READY || playbackState == STATE_BUFFERING;
        }
        return fallbackPlaying;
    }

    public static boolean isPlaybackIntended(boolean activityPlaying, Snapshot snapshot) {
        if (snapshot == null) return activityPlaying;
        return isPlaybackIntended(
                activityPlaying,
                snapshot.hasExoState,
                snapshot.playWhenReady,
                snapshot.playbackState,
                snapshot.suppressionReason,
                snapshot.fallbackPlaying);
    }

    public static boolean isAudioFocusSuppressed(Snapshot snapshot) {
        return snapshot != null
                && snapshot.hasExoState
                && snapshot.suppressionReason != SUPPRESSION_NONE;
    }

    /**
     * Evaluates whether a 3-second intro/outro skip countdown is allowed to run or auto-commit.
     * Any pause, audio-focus loss, backgrounding, mini/PiP mode, screen lock, or modal dialog
     * returns {@code false}.
     */
    public static boolean canRunSkipCountdown(
            boolean foreground,
            boolean miniMode,
            boolean inPip,
            boolean playerLocked,
            boolean prepared,
            boolean playbackIntended,
            boolean transitioning,
            boolean activeDialogShowing) {
        return foreground
                && !miniMode
                && !inPip
                && !playerLocked
                && prepared
                && playbackIntended
                && !transitioning
                && !activeDialogShowing;
    }

    private static void ensureFields() {
        if (fieldsResolved) return;
        try {
            Field fExo = MoviePlayer.class.getDeclaredField("exo");
            fExo.setAccessible(true);
            exoField = fExo;
        } catch (Throwable ignored) {
            exoField = null;
        }
        try {
            Field fReleased = MoviePlayer.class.getDeclaredField("released");
            fReleased.setAccessible(true);
            releasedField = fReleased;
        } catch (Throwable ignored) {
            releasedField = null;
        }
        fieldsResolved = true;
    }

    /** Inspects a live {@link MoviePlayer} on the main looper without allocating per-frame work. */
    public static Snapshot inspect(MoviePlayer player) {
        if (player == null) {
            return new Snapshot(false, false, STATE_IDLE, SUPPRESSION_NONE, false);
        }
        ensureFields();
        try {
            boolean released = releasedField != null && releasedField.getBoolean(player);
            if (released) {
                return new Snapshot(true, false, STATE_IDLE, SUPPRESSION_NONE, false);
            }
            if (exoField != null && Looper.myLooper() == Looper.getMainLooper()) {
                Object rawExo = exoField.get(player);
                if (rawExo instanceof Player) {
                    Player exo = (Player) rawExo;
                    boolean pwr = exo.getPlayWhenReady();
                    int state = exo.getPlaybackState();
                    int suppression = exo.getPlaybackSuppressionReason();
                    boolean playing =
                            pwr && suppression == SUPPRESSION_NONE && state == STATE_READY;
                    return new Snapshot(true, pwr, state, suppression, playing);
                }
            }
        } catch (Throwable ignored) {
        }
        boolean fallback = false;
        try {
            fallback = player.isPlaying();
        } catch (Throwable ignored) {
        }
        return new Snapshot(false, fallback, fallback ? STATE_READY : STATE_IDLE, 0, fallback);
    }
}
