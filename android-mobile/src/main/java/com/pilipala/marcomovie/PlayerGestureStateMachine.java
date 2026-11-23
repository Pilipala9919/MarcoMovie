package com.pilipala.marcomovie;

/**
 * Pure-Java deterministic touch gesture state machine for mobile and tablet video playback.
 *
 * <p>Implements single-tap controls toggle, release-validated double-tap (center play/pause or
 * fullscreen; left/right 28% seek with 650ms continuous multi-tap combo window), mutual-exclusion
 * drag classification (horizontal seek, left brightness, right volume), and stationary long-press
 * (>= 350ms) speed boost with horizontal detent stepping (1.25x / 1.5x / 2.0x / 3.0x), swipe-up
 * speed lock (dy <= -48dp with -36dp hysteresis), and full interruption safety reset.
 */
public final class PlayerGestureStateMachine {
    public enum State {
        IDLE,
        LOCKED_IDLE,
        DOWN_PENDING,
        WAIT_DOUBLE_TAP,
        SECOND_TAP_DOWN,
        MULTI_TAP_SEEK_WINDOW,
        HORIZONTAL_SEEK,
        VERTICAL_BRIGHTNESS,
        VERTICAL_VOLUME,
        LONG_PRESS_SPEED,
        SPEED_LOCK_READY,
        SPEED_LOCKED,
        CANCELLED
    }

    public enum InterruptReason {
        ACTION_CANCEL,
        MULTI_TOUCH,
        WINDOW_FOCUS_LOST,
        BACKGROUND,
        AUDIO_FOCUS_LOST,
        PLAYBACK_PAUSED,
        PIP_OR_MINI,
        DIALOG_OPEN,
        EPISODE_SWITCH,
        SCREEN_LOCKED,
        EXIT_PLAYER,
        MANUAL_SPEED_CHANGE
    }

    public static final int ZONE_LEFT = -1;
    public static final int ZONE_CENTER = 0;
    public static final int ZONE_RIGHT = 1;

    // Thresholds aligned with shared/ui-spec/motion-tokens.json (schemaVersion 2).
    public static final float TOUCH_SLOP_DP = 12f;
    public static final long DOUBLE_TAP_TIMEOUT_MS = 260L;
    public static final float DOUBLE_TAP_SLOP_DP = 42f;
    public static final long MULTI_TAP_SEEK_WINDOW_MS = 650L;
    public static final float EDGE_BACK_GUARD_DP = 24f;
    public static final float SYSTEM_VERTICAL_GUARD_DP = 28f;
    public static final long TOUCH_HOLD_SPEED_BOOST_THRESHOLD_MS = 350L;
    public static final float SPEED_SLIDE_STEP_DP = 36f;
    public static final float SWIPE_LOCK_THRESHOLD_DP = -48f;
    public static final float SWIPE_LOCK_HYSTERESIS_DP = -36f;
    public static final float SIDE_ZONE_RATIO = 0.28f;
    public static final float HORIZONTAL_RATIO_BIAS = 1.15f;
    public static final float DEFAULT_BOOST_SPEED = 2.0f;
    public static final float[] SPEED_DETENTS = {1.25f, 1.5f, 2.0f, 3.0f};

    public static final class Config {
        public String doubleTapCenter = "play_pause";
        public String doubleTapSides = "seek_10s";
        public String longPressRestoreMode = "previous";

        public int sideSeekStepMs() {
            if ("seek_5s".equals(doubleTapSides)) return 5000;
            if ("seek_15s".equals(doubleTapSides)) return 15000;
            if ("seek_10s".equals(doubleTapSides)) return 10000;
            return 0;
        }

        public boolean isSidePlayPause() {
            return "play_pause".equals(doubleTapSides);
        }
    }

    public static final class Env {
        public float density = 1f;
        public float screenWidthPx = 1080f;
        public float screenHeightPx = 1920f;
        public float systemGestureInsetLeftPx = 0f;
        public float systemGestureInsetRightPx = 0f;
        public float systemInsetTopPx = 0f;
        public float systemInsetBottomPx = 0f;
        public boolean screenLocked = false;
        public boolean miniOrPip = false;
        public boolean liveStream = false;
        public boolean prepared = true;
        public boolean playing = true;
        public int durationMs = 0;
        public boolean controlsVisible = false;
        public boolean startedInsideControls = false;
        public float userNormalSpeed = 1.0f;
    }

    public interface Listener {
        void onStateChanged(State from, State to);

        void onSingleTap();

        void onLockedSingleTap();

        void onDoubleTapPlayPause();

        void onDoubleTapFullscreen();

        void onDoubleTapSeek(int stepMs, int accumulatedMs);

        void onMultiTapSeekEnd();

        void onSeekBegin(float downX, float downY);

        void onSeekMove(float dx, float stepDx, float rawX, long nowMs);

        void onSeekCommit();

        void onSeekCancel();

        void onBrightnessBegin();

        void onBrightnessMove(float dy);

        void onVolumeBegin();

        void onVolumeMove(float dy);

        void onVerticalDragEnd();

        void onSpeedBoostStart(float speed, int detentIndex);

        void onSpeedBoostChanged(float speed, int detentIndex);

        void onSpeedLockReadyChanged(boolean lockReady, float speed);

        void onSpeedLocked(float lockedSpeed);

        void onSpeedBoostEnd(float restoredSpeed, boolean cancelled);

        void onSpeedUnlocked(float restoredSpeed);
    }

    public static class ListenerAdapter implements Listener {
        @Override
        public void onStateChanged(State from, State to) {}

        @Override
        public void onSingleTap() {}

        @Override
        public void onLockedSingleTap() {}

        @Override
        public void onDoubleTapPlayPause() {}

        @Override
        public void onDoubleTapFullscreen() {}

        @Override
        public void onDoubleTapSeek(int stepMs, int accumulatedMs) {}

        @Override
        public void onMultiTapSeekEnd() {}

        @Override
        public void onSeekBegin(float downX, float downY) {}

        @Override
        public void onSeekMove(float dx, float stepDx, float rawX, long nowMs) {}

        @Override
        public void onSeekCommit() {}

        @Override
        public void onSeekCancel() {}

        @Override
        public void onBrightnessBegin() {}

        @Override
        public void onBrightnessMove(float dy) {}

        @Override
        public void onVolumeBegin() {}

        @Override
        public void onVolumeMove(float dy) {}

        @Override
        public void onVerticalDragEnd() {}

        @Override
        public void onSpeedBoostStart(float speed, int detentIndex) {}

        @Override
        public void onSpeedBoostChanged(float speed, int detentIndex) {}

        @Override
        public void onSpeedLockReadyChanged(boolean lockReady, float speed) {}

        @Override
        public void onSpeedLocked(float lockedSpeed) {}

        @Override
        public void onSpeedBoostEnd(float restoredSpeed, boolean cancelled) {}

        @Override
        public void onSpeedUnlocked(float restoredSpeed) {}
    }

    private final Config config = new Config();
    private final Listener listener;

    private State state = State.IDLE;
    private boolean screenLocked;
    private boolean speedLocked;
    private float lockedSpeed = DEFAULT_BOOST_SPEED;
    private float savedUserNormalSpeed = 1.0f;

    private int activePointerId = -1;
    private float downX, downY;
    private float lastX, lastY;
    private long downTimeMs;
    private boolean movedBeyondSlop;
    private boolean gestureAccepted;

    // Double-tap & multi-tap state
    private float firstTapX, firstTapY;
    private long waitDoubleTapDeadlineMs = -1L;
    private int multiTapSide = ZONE_CENTER;
    private int multiTapAccumulatedMs = 0;
    private long multiTapDeadlineMs = -1L;
    private boolean multiTapDownActive = false;

    // Long-press speed boost state
    private boolean longPressArmed = false;
    private long longPressDeadlineMs = -1L;
    private float speedAnchorX, speedAnchorY;
    private int baseDetentIndex = 2;
    private int currentDetentIndex = 2;
    private float currentBoostSpeed = DEFAULT_BOOST_SPEED;

    // Snapshot of the active pointer's environment for move/tick transitions
    private Env lastEnv = new Env();

    public PlayerGestureStateMachine(Listener listener) {
        this.listener = listener != null ? listener : new ListenerAdapter();
    }

    public Config config() {
        return config;
    }

    public State getState() {
        return state;
    }

    public boolean isSpeedLocked() {
        return speedLocked;
    }

    public boolean isSpeedBoostActive() {
        return state == State.LONG_PRESS_SPEED || state == State.SPEED_LOCK_READY;
    }

    public boolean isAnySpeedOverrideActive() {
        return isSpeedBoostActive() || speedLocked;
    }

    public float getLockedSpeed() {
        return lockedSpeed;
    }

    public float getCurrentBoostSpeed() {
        return currentBoostSpeed;
    }

    public int getCurrentDetentIndex() {
        return currentDetentIndex;
    }

    public float getSavedUserNormalSpeed() {
        return savedUserNormalSpeed;
    }

    public boolean isLongPressArmed() {
        return longPressArmed;
    }

    public long nextDeadlineMs() {
        long best = -1L;
        if (state == State.DOWN_PENDING && longPressArmed && longPressDeadlineMs >= 0L) {
            best = longPressDeadlineMs;
        }
        if (state == State.WAIT_DOUBLE_TAP && waitDoubleTapDeadlineMs >= 0L) {
            best = best < 0L ? waitDoubleTapDeadlineMs : Math.min(best, waitDoubleTapDeadlineMs);
        }
        if (state == State.MULTI_TAP_SEEK_WINDOW && multiTapDeadlineMs >= 0L) {
            best = best < 0L ? multiTapDeadlineMs : Math.min(best, multiTapDeadlineMs);
        }
        return best;
    }

    private float dp(float value) {
        float d = lastEnv != null && lastEnv.density > 0f ? lastEnv.density : 1f;
        return value * d;
    }

    private State restingState() {
        if (screenLocked) return State.LOCKED_IDLE;
        return speedLocked ? State.SPEED_LOCKED : State.IDLE;
    }

    private void transition(State next) {
        if (state == next) return;
        State prev = state;
        state = next;
        listener.onStateChanged(prev, next);
    }

    private float computeRestoreSpeed() {
        if ("1.0x".equals(config.longPressRestoreMode)) {
            return 1.0f;
        }
        return savedUserNormalSpeed > 0f ? savedUserNormalSpeed : 1.0f;
    }

    public static int resolveZone(float x, float screenWidthPx) {
        if (screenWidthPx <= 0f) return ZONE_CENTER;
        float ratio = x / screenWidthPx;
        if (ratio < SIDE_ZONE_RATIO) return ZONE_LEFT;
        if (ratio > 1f - SIDE_ZONE_RATIO) return ZONE_RIGHT;
        return ZONE_CENTER;
    }

    public static boolean isInEdgeOrSystemGuard(float x, float y, Env env) {
        if (env == null) return false;
        float d = env.density > 0f ? env.density : 1f;
        float edgeLeft = Math.max(EDGE_BACK_GUARD_DP * d, env.systemGestureInsetLeftPx);
        float edgeRight = Math.max(EDGE_BACK_GUARD_DP * d, env.systemGestureInsetRightPx);
        if (env.screenWidthPx > 0f) {
            if (x < edgeLeft || x > env.screenWidthPx - edgeRight) return true;
        }
        float topGuard = Math.max(SYSTEM_VERTICAL_GUARD_DP * d, env.systemInsetTopPx);
        float bottomGuard = Math.max(SYSTEM_VERTICAL_GUARD_DP * d, env.systemInsetBottomPx);
        if (env.screenHeightPx > 0f) {
            if (y < topGuard || y > env.screenHeightPx - bottomGuard) return true;
        }
        return false;
    }

    public void setScreenLocked(boolean locked, long nowMs) {
        if (this.screenLocked == locked) return;
        if (locked) {
            this.screenLocked = true;
            cancel(InterruptReason.SCREEN_LOCKED, nowMs);
            transition(State.LOCKED_IDLE);
        } else {
            this.screenLocked = false;
            if (state == State.LOCKED_IDLE) {
                transition(restingState());
            }
        }
    }

    public void unlockLockedSpeed(long nowMs) {
        if (!speedLocked) return;
        float restore = computeRestoreSpeed();
        speedLocked = false;
        lockedSpeed = DEFAULT_BOOST_SPEED;
        if (state == State.SPEED_LOCKED) {
            transition(restingState());
        }
        listener.onSpeedUnlocked(restore);
    }

    /**
     * Handles pointer down (ACTION_DOWN or ACTION_POINTER_DOWN).
     *
     * @return {@code true} if the gesture state machine accepted the touch, or {@code false} if
     *     ignored (e.g. edge back guard or started inside visible controls).
     */
    public boolean onPointerDown(
            int pointerId, int pointerCount, float x, float y, long nowMs, Env env) {
        if (env != null) {
            lastEnv = env;
        }
        if (pointerCount > 1) {
            cancel(InterruptReason.MULTI_TOUCH, nowMs);
            return false;
        }
        if (lastEnv.miniOrPip) {
            if (state != State.IDLE && state != State.LOCKED_IDLE) {
                cancel(InterruptReason.PIP_OR_MINI, nowMs);
            }
            gestureAccepted = false;
            return false;
        }
        if (lastEnv.screenLocked || screenLocked) {
            screenLocked = true;
            if (state != State.LOCKED_IDLE) {
                cancel(InterruptReason.SCREEN_LOCKED, nowMs);
                transition(State.LOCKED_IDLE);
            }
            activePointerId = pointerId;
            downX = lastX = x;
            downY = lastY = y;
            downTimeMs = nowMs;
            movedBeyondSlop = false;
            gestureAccepted = true;
            return true;
        }
        if (lastEnv.startedInsideControls || isInEdgeOrSystemGuard(x, y, lastEnv)) {
            gestureAccepted = false;
            return false;
        }

        // Defensively clear any orphaned active drag/boost gesture before a fresh single-pointer
        // stream begins so lost UP/CANCEL events can never leave speed or seek stuck.
        if (state == State.HORIZONTAL_SEEK
                || state == State.VERTICAL_BRIGHTNESS
                || state == State.VERTICAL_VOLUME
                || state == State.LONG_PRESS_SPEED
                || state == State.SPEED_LOCK_READY) {
            cancel(InterruptReason.ACTION_CANCEL, nowMs);
        }

        // Flush expired timers first in case caller didn't tick right before down.
        onTick(nowMs);

        activePointerId = pointerId;
        downX = lastX = x;
        downY = lastY = y;
        downTimeMs = nowMs;
        movedBeyondSlop = false;
        gestureAccepted = true;

        if (state == State.MULTI_TAP_SEEK_WINDOW) {
            int zone = resolveZone(x, lastEnv.screenWidthPx);
            if (zone == multiTapSide && nowMs <= multiTapDeadlineMs) {
                multiTapDownActive = true;
                return true;
            }
            // Different side or center ends combo cleanly without triggering controls.
            endMultiTapWindow();
            gestureAccepted = false;
            return true;
        }

        if (state == State.WAIT_DOUBLE_TAP) {
            if (nowMs <= waitDoubleTapDeadlineMs) {
                float ddx = x - firstTapX;
                float ddy = y - firstTapY;
                float distSq = ddx * ddx + ddy * ddy;
                float slop = dp(DOUBLE_TAP_SLOP_DP);
                waitDoubleTapDeadlineMs = -1L;
                if (distSq <= slop * slop) {
                    longPressArmed = false;
                    longPressDeadlineMs = -1L;
                    transition(State.SECOND_TAP_DOWN);
                    return true;
                }
                // Far apart second tap: settle first single tap, then start fresh press.
                transition(restingState());
                listener.onSingleTap();
            } else {
                waitDoubleTapDeadlineMs = -1L;
                transition(restingState());
                listener.onSingleTap();
            }
        }

        armLongPress(nowMs);
        transition(State.DOWN_PENDING);
        return true;
    }

    private void armLongPress(long nowMs) {
        boolean eligible =
                !lastEnv.liveStream
                        && lastEnv.durationMs > 0
                        && lastEnv.prepared
                        && lastEnv.playing
                        && !lastEnv.screenLocked
                        && !lastEnv.miniOrPip;
        longPressArmed = eligible;
        longPressDeadlineMs = eligible ? nowMs + TOUCH_HOLD_SPEED_BOOST_THRESHOLD_MS : -1L;
    }

    public void onPointerMove(
            int pointerId, int pointerCount, float x, float y, long nowMs, Env env) {
        if (env != null) {
            lastEnv = env;
        }
        if (pointerCount > 1) {
            cancel(InterruptReason.MULTI_TOUCH, nowMs);
            return;
        }
        if (!gestureAccepted || pointerId != activePointerId) return;

        // Evaluate timer thresholds before processing movement at nowMs.
        onTick(nowMs);

        float dx = x - downX;
        float dy = y - downY;
        float stepDx = x - lastX;
        lastX = x;
        lastY = y;
        float slopPx = dp(TOUCH_SLOP_DP);

        if (state == State.LOCKED_IDLE) {
            if (Math.abs(dx) > slopPx || Math.abs(dy) > slopPx) {
                movedBeyondSlop = true;
            }
            return;
        }

        if (state == State.MULTI_TAP_SEEK_WINDOW) {
            if (Math.abs(dx) > slopPx || Math.abs(dy) > slopPx) {
                movedBeyondSlop = true;
                multiTapDownActive = false;
                endMultiTapWindow();
            }
            return;
        }

        if (state == State.DOWN_PENDING || state == State.SECOND_TAP_DOWN) {
            float adx = Math.abs(dx);
            float ady = Math.abs(dy);
            if (adx > slopPx || ady > slopPx) {
                movedBeyondSlop = true;
                longPressArmed = false;
                longPressDeadlineMs = -1L;
                if (adx > slopPx && adx >= ady * HORIZONTAL_RATIO_BIAS) {
                    if (!lastEnv.liveStream && lastEnv.durationMs > 0 && lastEnv.prepared) {
                        transition(State.HORIZONTAL_SEEK);
                        listener.onSeekBegin(downX, downY);
                        listener.onSeekMove(dx, stepDx, x, nowMs);
                    }
                } else if (ady > slopPx && ady > adx) {
                    if (downX < lastEnv.screenWidthPx * 0.5f) {
                        transition(State.VERTICAL_BRIGHTNESS);
                        listener.onBrightnessBegin();
                        listener.onBrightnessMove(dy);
                    } else {
                        transition(State.VERTICAL_VOLUME);
                        listener.onVolumeBegin();
                        listener.onVolumeMove(dy);
                    }
                }
            }
            return;
        }

        if (state == State.HORIZONTAL_SEEK) {
            listener.onSeekMove(dx, stepDx, x, nowMs);
            return;
        }

        if (state == State.VERTICAL_BRIGHTNESS) {
            listener.onBrightnessMove(dy);
            return;
        }

        if (state == State.VERTICAL_VOLUME) {
            listener.onVolumeMove(dy);
            return;
        }

        if (state == State.LONG_PRESS_SPEED || state == State.SPEED_LOCK_READY) {
            float slideDx = x - speedAnchorX;
            float slideDy = y - speedAnchorY;
            float stepPx = Math.max(1f, dp(SPEED_SLIDE_STEP_DP));
            int deltaSteps = (int) (slideDx / stepPx);
            int nextDetent =
                    Math.max(0, Math.min(SPEED_DETENTS.length - 1, baseDetentIndex + deltaSteps));
            if (nextDetent != currentDetentIndex) {
                currentDetentIndex = nextDetent;
                currentBoostSpeed = SPEED_DETENTS[nextDetent];
                listener.onSpeedBoostChanged(currentBoostSpeed, currentDetentIndex);
            }
            float lockThresholdPx = dp(SWIPE_LOCK_THRESHOLD_DP);
            float releaseHysteresisPx = dp(SWIPE_LOCK_HYSTERESIS_DP);
            if (state == State.LONG_PRESS_SPEED && slideDy <= lockThresholdPx) {
                transition(State.SPEED_LOCK_READY);
                listener.onSpeedLockReadyChanged(true, currentBoostSpeed);
            } else if (state == State.SPEED_LOCK_READY && slideDy > releaseHysteresisPx) {
                transition(State.LONG_PRESS_SPEED);
                listener.onSpeedLockReadyChanged(false, currentBoostSpeed);
            }
        }
    }

    public void onPointerUp(int pointerId, float x, float y, long nowMs, Env env) {
        if (env != null) {
            lastEnv = env;
        }
        if (!gestureAccepted || pointerId != activePointerId) return;

        onTick(nowMs);
        activePointerId = -1;
        gestureAccepted = false;
        longPressArmed = false;
        longPressDeadlineMs = -1L;

        float dx = x - downX;
        float dy = y - downY;
        float slopPx = dp(TOUCH_SLOP_DP);
        boolean withinSlop = !movedBeyondSlop && Math.abs(dx) <= slopPx && Math.abs(dy) <= slopPx;

        if (state == State.LOCKED_IDLE) {
            if (withinSlop) {
                listener.onLockedSingleTap();
            }
            return;
        }

        if (state == State.MULTI_TAP_SEEK_WINDOW) {
            if (multiTapDownActive && withinSlop && nowMs <= multiTapDeadlineMs) {
                multiTapDownActive = false;
                int step = config.sideSeekStepMs();
                if (step > 0 && !lastEnv.liveStream && lastEnv.durationMs > 0) {
                    int signedStep = multiTapSide == ZONE_LEFT ? -step : step;
                    multiTapAccumulatedMs += signedStep;
                    multiTapDeadlineMs = nowMs + MULTI_TAP_SEEK_WINDOW_MS;
                    listener.onDoubleTapSeek(signedStep, multiTapAccumulatedMs);
                    return;
                }
            }
            multiTapDownActive = false;
            endMultiTapWindow();
            return;
        }

        if (state == State.DOWN_PENDING) {
            long elapsed = nowMs - downTimeMs;
            if (withinSlop && elapsed < DOUBLE_TAP_TIMEOUT_MS) {
                int zone = resolveZone(x, lastEnv.screenWidthPx);
                boolean doubleTapDisabledHere =
                        zone == ZONE_CENTER && "none".equals(config.doubleTapCenter);
                if (doubleTapDisabledHere) {
                    transition(restingState());
                    listener.onSingleTap();
                } else {
                    firstTapX = x;
                    firstTapY = y;
                    waitDoubleTapDeadlineMs = nowMs + DOUBLE_TAP_TIMEOUT_MS;
                    transition(State.WAIT_DOUBLE_TAP);
                }
            } else if (withinSlop) {
                // Slow stationary tap (260ms <= elapsed < 350ms): toggle controls cleanly.
                transition(restingState());
                listener.onSingleTap();
            } else {
                transition(restingState());
            }
            return;
        }

        if (state == State.SECOND_TAP_DOWN) {
            if (withinSlop) {
                handleDoubleTapRelease(x, nowMs);
            } else {
                transition(restingState());
            }
            return;
        }

        if (state == State.HORIZONTAL_SEEK) {
            transition(restingState());
            listener.onSeekCommit();
            return;
        }

        if (state == State.VERTICAL_BRIGHTNESS || state == State.VERTICAL_VOLUME) {
            transition(restingState());
            listener.onVerticalDragEnd();
            return;
        }

        if (state == State.SPEED_LOCK_READY) {
            speedLocked = true;
            lockedSpeed = currentBoostSpeed;
            transition(State.SPEED_LOCKED);
            listener.onSpeedLocked(lockedSpeed);
            return;
        }

        if (state == State.LONG_PRESS_SPEED) {
            float restore = computeRestoreSpeed();
            speedLocked = false;
            transition(State.IDLE);
            listener.onSpeedBoostEnd(restore, false);
        }
    }

    private void handleDoubleTapRelease(float x, long nowMs) {
        int zone = resolveZone(x, lastEnv.screenWidthPx);
        if (zone == ZONE_LEFT || zone == ZONE_RIGHT) {
            int step = config.sideSeekStepMs();
            if (step > 0 && !lastEnv.liveStream && lastEnv.durationMs > 0) {
                int signedStep = zone == ZONE_LEFT ? -step : step;
                multiTapSide = zone;
                multiTapAccumulatedMs = signedStep;
                multiTapDeadlineMs = nowMs + MULTI_TAP_SEEK_WINDOW_MS;
                multiTapDownActive = false;
                transition(State.MULTI_TAP_SEEK_WINDOW);
                listener.onDoubleTapSeek(signedStep, multiTapAccumulatedMs);
                return;
            }
            if (config.isSidePlayPause() || lastEnv.liveStream || lastEnv.durationMs <= 0) {
                transition(restingState());
                listener.onDoubleTapPlayPause();
                return;
            }
            transition(restingState());
            return;
        }
        // Center zone
        if ("fullscreen".equals(config.doubleTapCenter)) {
            transition(restingState());
            listener.onDoubleTapFullscreen();
        } else if ("none".equals(config.doubleTapCenter)) {
            transition(restingState());
        } else {
            transition(restingState());
            listener.onDoubleTapPlayPause();
        }
    }

    /**
     * Re-evaluates scheduled timers with a fresh runtime environment snapshot so external pauses,
     * audio-focus loss, screen lock, or PiP transitions occurring during the 350ms hold window
     * prevent stale long-press speed activation.
     */
    public void onTick(long nowMs, Env currentEnv) {
        if (currentEnv != null) {
            lastEnv = currentEnv;
        }
        onTick(nowMs);
    }

    public void onTick(long nowMs) {
        if (state == State.DOWN_PENDING && longPressArmed && longPressDeadlineMs >= 0L) {
            if (nowMs >= longPressDeadlineMs && !movedBeyondSlop) {
                longPressArmed = false;
                longPressDeadlineMs = -1L;
                if (!lastEnv.liveStream
                        && lastEnv.durationMs > 0
                        && lastEnv.prepared
                        && lastEnv.playing
                        && !lastEnv.screenLocked
                        && !lastEnv.miniOrPip) {
                    if (!speedLocked) {
                        savedUserNormalSpeed =
                                lastEnv.userNormalSpeed > 0f ? lastEnv.userNormalSpeed : 1.0f;
                    }
                    boolean already2x = Math.abs(savedUserNormalSpeed - 2.0f) < 0.05f;
                    baseDetentIndex = already2x ? 3 : 2;
                    currentDetentIndex = baseDetentIndex;
                    currentBoostSpeed = SPEED_DETENTS[currentDetentIndex];
                    speedAnchorX = lastX;
                    speedAnchorY = lastY;
                    transition(State.LONG_PRESS_SPEED);
                    listener.onSpeedBoostStart(currentBoostSpeed, currentDetentIndex);
                }
            }
        }
        if (state == State.WAIT_DOUBLE_TAP
                && waitDoubleTapDeadlineMs >= 0L
                && nowMs >= waitDoubleTapDeadlineMs) {
            waitDoubleTapDeadlineMs = -1L;
            transition(restingState());
            listener.onSingleTap();
        }
        if (state == State.MULTI_TAP_SEEK_WINDOW
                && multiTapDeadlineMs >= 0L
                && nowMs >= multiTapDeadlineMs) {
            endMultiTapWindow();
        }
    }

    private void endMultiTapWindow() {
        multiTapDeadlineMs = -1L;
        multiTapAccumulatedMs = 0;
        multiTapSide = ZONE_CENTER;
        multiTapDownActive = false;
        transition(restingState());
        listener.onMultiTapSeekEnd();
    }

    public void cancel(InterruptReason reason, long nowMs) {
        activePointerId = -1;
        gestureAccepted = false;
        movedBeyondSlop = false;
        longPressArmed = false;
        longPressDeadlineMs = -1L;
        waitDoubleTapDeadlineMs = -1L;
        boolean hadMultiTap = state == State.MULTI_TAP_SEEK_WINDOW;
        multiTapDeadlineMs = -1L;
        multiTapAccumulatedMs = 0;
        multiTapSide = ZONE_CENTER;
        multiTapDownActive = false;

        boolean wasSeeking = state == State.HORIZONTAL_SEEK;
        boolean wasVertical = state == State.VERTICAL_BRIGHTNESS || state == State.VERTICAL_VOLUME;
        boolean wasSpeedBoosting =
                state == State.LONG_PRESS_SPEED || state == State.SPEED_LOCK_READY;

        boolean shouldUnlockSpeedLock =
                speedLocked
                        && (reason == InterruptReason.EPISODE_SWITCH
                                || reason == InterruptReason.EXIT_PLAYER
                                || reason == InterruptReason.BACKGROUND
                                || reason == InterruptReason.AUDIO_FOCUS_LOST
                                || reason == InterruptReason.PLAYBACK_PAUSED
                                || reason == InterruptReason.SCREEN_LOCKED
                                || reason == InterruptReason.MULTI_TOUCH
                                || reason == InterruptReason.PIP_OR_MINI
                                || reason == InterruptReason.MANUAL_SPEED_CHANGE);

        if (state != State.IDLE && state != State.LOCKED_IDLE && state != State.SPEED_LOCKED) {
            transition(State.CANCELLED);
        }

        if (wasSeeking) {
            listener.onSeekCancel();
        }
        if (wasVertical) {
            listener.onVerticalDragEnd();
        }
        if (hadMultiTap) {
            listener.onMultiTapSeekEnd();
        }
        if (wasSpeedBoosting) {
            float restore = computeRestoreSpeed();
            speedLocked = false;
            listener.onSpeedBoostEnd(restore, true);
        } else if (shouldUnlockSpeedLock) {
            float restore = computeRestoreSpeed();
            speedLocked = false;
            lockedSpeed = DEFAULT_BOOST_SPEED;
            if (reason != InterruptReason.MANUAL_SPEED_CHANGE) {
                listener.onSpeedUnlocked(restore);
            } else {
                // Manual speed change already applied the user's newly chosen speed.
                listener.onSpeedUnlocked(-1f);
            }
        }

        if (reason == InterruptReason.SCREEN_LOCKED) {
            screenLocked = true;
            transition(State.LOCKED_IDLE);
        } else {
            transition(restingState());
        }
    }
}
