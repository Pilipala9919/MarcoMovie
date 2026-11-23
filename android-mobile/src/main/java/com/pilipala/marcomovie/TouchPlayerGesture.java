package com.pilipala.marcomovie;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Rect;
import android.graphics.RectF;
import android.media.AudioManager;
import android.os.Build;
import android.os.SystemClock;
import android.view.Gravity;
import android.view.HapticFeedbackConstants;
import android.view.MotionEvent;
import android.view.VelocityTracker;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewTreeObserver;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import com.pilipala.marcomovie.hud.PlaybackStateProbe;
import com.pilipala.marcomovie.hud.PlayerHudPrefs;
import com.pilipala.marcomovie.hud.SpeedLockCapsule;
import java.util.Locale;

/**
 * Touch gesture controller for phone and tablet playback backed by {@link
 * PlayerGestureStateMachine}: single-tap controls toggle, toggleable release-validated double-tap
 * (center play/pause or fullscreen; left/right 28% seek with 650ms multi-tap combo), mutual-
 * exclusion horizontal seek / brightness / volume drags, and upgraded long-press (>= 350ms) speed
 * boost with horizontal detent stepping (1.25x / 1.5x / 2.0x / 3.0x) and swipe-up speed lock.
 */
final class TouchPlayerGesture implements View.OnTouchListener {
    private final MainActivity a;
    private final LinearLayout hudCard;
    private final TextView hud;
    private final SeekProgressBarView hudProgress;
    private final SpeedLockCapsule speedLockCapsule;
    final PlayerGestureStateMachine fsm;

    private final Rect hitRect = new Rect();
    private final Rect rootRect = new Rect();
    private VelocityTracker velocityTracker;
    private long lastMoveTimeMs;
    private int startPositionMs, durationMs, targetSeekMs;
    private float startBrightness = 0.5f;
    private float startVolume = 0.5f;
    private float miniDownX, miniDownY;
    private boolean miniTapCandidate;
    private boolean briefNoticeActive;
    private PlayerGestureStateMachine.InterruptReason activeCancelReason;

    private final Runnable fsmTickRunnable = this::handleFsmTick;
    private final Runnable hideNoticeRunnable = this::handleHideNotice;
    private final Runnable runtimeSyncRunnable = this::syncRuntimeState;

    private void handleFsmTick() {
        if (a.touchPlayerGesture != this) return;
        syncRuntimeState();
        long nowMs = SystemClock.uptimeMillis();
        PlayerGestureStateMachine.Env freshEnv = buildEnv(0f, 0f, false);
        fsm.onTick(nowMs, freshEnv);
        scheduleNextFsmTick();
    }

    private void handleHideNotice() {
        briefNoticeActive = false;
        PlayerGestureStateMachine.State st = fsm.getState();
        if (st == PlayerGestureStateMachine.State.IDLE
                || st == PlayerGestureStateMachine.State.LOCKED_IDLE
                || st == PlayerGestureStateMachine.State.SPEED_LOCKED) {
            hideHud();
        }
    }

    static final class SeekProgressBarView extends View {
        private final Paint trackPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint fillPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final RectF rect = new RectF();
        private float progressFraction = 0f;

        SeekProgressBarView(MainActivity activity) {
            super(activity);
            trackPaint.setColor(0x38ffffff);
            fillPaint.setColor(0xff34d399);
        }

        void setProgressFraction(float fraction) {
            float clamped = Math.max(0f, Math.min(1f, fraction));
            if (Math.abs(clamped - progressFraction) > 0.002f) {
                progressFraction = clamped;
                invalidate();
            }
        }

        @Override
        protected void onDraw(Canvas canvas) {
            float w = getWidth();
            float h = getHeight();
            if (w <= 0 || h <= 0) return;
            float r = h / 2f;
            rect.set(0, 0, w, h);
            canvas.drawRoundRect(rect, r, r, trackPaint);
            float fillW = Math.max(h, w * progressFraction);
            rect.set(0, 0, Math.min(w, fillW), h);
            canvas.drawRoundRect(rect, r, r, fillPaint);
        }
    }

    private TouchPlayerGesture(MainActivity activity) {
        this.a = activity;
        this.hudCard = activity.vertical();
        this.hudCard.setGravity(Gravity.CENTER_HORIZONTAL);
        this.hudCard.setPadding(activity.dp(18), activity.dp(10), activity.dp(18), activity.dp(10));
        UiCompat.setBackground(this.hudCard, activity.bg(0xdc181d1b, 20));
        this.hudCard.setVisibility(View.GONE);

        this.hud = activity.text("", 13.5f, MainActivity.WHITE);
        this.hud.setTag("player-touch-hud");
        this.hud.setGravity(Gravity.CENTER);
        this.hudCard.addView(this.hud, new LinearLayout.LayoutParams(-2, -2));

        this.hudProgress = new SeekProgressBarView(activity);
        this.hudProgress.setVisibility(View.GONE);
        LinearLayout.LayoutParams barLp =
                new LinearLayout.LayoutParams(activity.dp(190), activity.dp(5));
        barLp.topMargin = activity.dp(7);
        this.hudCard.addView(this.hudProgress, barLp);

        FrameLayout.LayoutParams lp =
                new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.CENTER_HORIZONTAL);
        lp.topMargin = activity.dp(36);
        activity.playbackLayer.addView(this.hudCard, lp);

        this.speedLockCapsule = new SpeedLockCapsule(activity);
        boolean reducedTransparency =
                activity.prefs != null
                        && activity.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false);
        this.speedLockCapsule.setAccessibilityFlags(activity.reduced, reducedTransparency);
        FrameLayout.LayoutParams speedLp =
                new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.CENTER_HORIZONTAL);
        speedLp.topMargin = activity.dp(16);
        activity.playbackLayer.addView(this.speedLockCapsule, speedLp);

        this.fsm = new PlayerGestureStateMachine(createListener());
        refreshConfigFromPrefs();
        attachLifecycleGuards(activity.root);
    }

    private void attachLifecycleGuards(View hostRoot) {
        if (hostRoot == null) return;
        final ViewTreeObserver.OnWindowFocusChangeListener focusListener =
                hasFocus -> {
                    if (!hasFocus) {
                        cancelWithReason(
                                a.foreground
                                        ? PlayerGestureStateMachine.InterruptReason
                                                .WINDOW_FOCUS_LOST
                                        : PlayerGestureStateMachine.InterruptReason.BACKGROUND);
                        // onWindowFocusChanged(false) often fires before MainActivity.onStop()
                        // clears a.foreground or enters PiP; re-check shortly after focus loss.
                        a.ui.removeCallbacks(runtimeSyncRunnable);
                        a.ui.postDelayed(runtimeSyncRunnable, 150L);
                        a.ui.postDelayed(runtimeSyncRunnable, 450L);
                    } else {
                        a.ui.removeCallbacks(runtimeSyncRunnable);
                        syncRuntimeState();
                    }
                };
        final boolean[] focusRegistered = {false};
        final Runnable registerFocus =
                () -> {
                    if (focusRegistered[0] || Build.VERSION.SDK_INT < 18) return;
                    ViewTreeObserver vto = hostRoot.getViewTreeObserver();
                    if (vto != null && vto.isAlive()) {
                        vto.addOnWindowFocusChangeListener(focusListener);
                        focusRegistered[0] = true;
                    }
                };
        if (UiCompat.isAttached(hostRoot)) {
            registerFocus.run();
        }
        hostRoot.addOnAttachStateChangeListener(
                new View.OnAttachStateChangeListener() {
                    @Override
                    public void onViewAttachedToWindow(View v) {
                        registerFocus.run();
                    }

                    @Override
                    public void onViewDetachedFromWindow(View v) {
                        a.ui.removeCallbacks(runtimeSyncRunnable);
                        a.ui.removeCallbacks(hideNoticeRunnable);
                        a.ui.removeCallbacks(fsmTickRunnable);
                        if (focusRegistered[0] && Build.VERSION.SDK_INT >= 18) {
                            ViewTreeObserver vto = v.getViewTreeObserver();
                            if (vto != null && vto.isAlive()) {
                                vto.removeOnWindowFocusChangeListener(focusListener);
                            }
                            focusRegistered[0] = false;
                        }
                        cancelWithReason(PlayerGestureStateMachine.InterruptReason.EXIT_PLAYER);
                    }
                });
    }

    private PlayerGestureStateMachine.Listener createListener() {
        return new PlayerGestureStateMachine.ListenerAdapter() {
            @Override
            public void onSingleTap() {
                if (a.miniMode) {
                    a.expandPlayback();
                    return;
                }
                if (a.playerLocked) return;
                a.showControls(!a.controlsVisible);
            }

            @Override
            public void onLockedSingleTap() {
                if (!a.miniMode && a.playerLocked) {
                    PlaybackController.toggleUnlockButton(a);
                }
            }

            @Override
            public void onDoubleTapPlayPause() {
                if (a.miniMode || a.playerLocked) return;
                a.togglePlayback();
                a.showControls(true);
            }

            @Override
            public void onDoubleTapFullscreen() {
                if (a.miniMode || a.playerLocked) return;
                a.togglePlayerOrientation();
            }

            @Override
            public void onDoubleTapSeek(int stepMs, int accumulatedMs) {
                if (a.miniMode || a.playerLocked || a.player == null || !a.prepared) return;
                int dur = a.player.getDuration();
                if (dur <= 0) return;
                int cur =
                        a.playbackControls != null
                                ? a.playbackControls.displayPosition(a.player.getCurrentPosition())
                                : a.player.getCurrentPosition();
                int next = Math.max(0, Math.min(dur, cur + stepMs));
                if (a.playbackControls != null) {
                    a.playbackControls.recordUserSeek(next);
                }
                a.player.seekTo(next);
                if (a.playClock != null) {
                    a.playClock.setText(
                            PlaybackController.formatTime(next)
                                    + " / "
                                    + PlaybackController.formatTime(dur));
                }
                int absSec = Math.abs(accumulatedMs) / 1000;
                String dirText = accumulatedMs >= 0 ? "快进 +" : "快退 -";
                showBriefNotice(dirText + absSec + " 秒");
            }

            @Override
            public void onSeekBegin(float downX, float downY) {
                if (a.root != null && a.root.getParent() != null) {
                    a.root.getParent().requestDisallowInterceptTouchEvent(true);
                }
                if (a.player != null && a.prepared) {
                    startPositionMs = a.player.getCurrentPosition();
                    durationMs = a.player.getDuration();
                    targetSeekMs = startPositionMs;
                    if (a.playbackControls != null) {
                        a.playbackControls.onDanmuSeekInitiated();
                    }
                }
            }

            @Override
            public void onSeekMove(float dx, float stepDx, float rawX, long nowMs) {
                if (a.player == null || !a.prepared || durationMs <= 0) return;
                int width = effectiveHostWidth();
                long dtMs = Math.max(1L, nowMs - lastMoveTimeMs);
                lastMoveTimeMs = nowMs;
                float vx = (stepDx * 1000f) / dtMs;
                if (velocityTracker != null) {
                    velocityTracker.computeCurrentVelocity(1000);
                    float trackedVx = velocityTracker.getXVelocity();
                    if (Math.abs(trackedVx) > 10f) vx = trackedVx;
                }
                float speedMul = SeekGesture.linearSeekSpeedMultiplier(vx, width);
                targetSeekMs =
                        SeekGesture.stepLinearSeekTarget(
                                targetSeekMs, durationMs, stepDx, vx, width);
                if (a.playbackControls != null) {
                    a.playbackControls.touchSeeking = true;
                    a.playbackControls.timeline.setProgress(targetSeekMs);
                }
                if (!a.controlsVisible) {
                    PlaybackController.showControls(a, true, true);
                }
                String speedText = String.format(Locale.US, "%.1f×", speedMul);
                if (a.playClock != null) {
                    a.playClock.setText(
                            PlaybackController.formatTime(targetSeekMs)
                                    + " / "
                                    + PlaybackController.formatTime(durationMs));
                }
                if (a.playerChrome != null && a.playerChrome.seekHint != null) {
                    a.playerChrome.seekHint.setText(
                            (dx >= 0 ? "快进 " : "快退 ") + speedText + " · 松手跳转");
                    a.playerChrome.seekHint.setVisibility(View.VISIBLE);
                }
                float frac = durationMs > 0 ? (targetSeekMs / (float) durationMs) : 0f;
                showHud(
                        (dx >= 0 ? "快进至 " : "快退至 ")
                                + PlaybackController.formatTime(targetSeekMs)
                                + " / "
                                + PlaybackController.formatTime(durationMs)
                                + "  ·  "
                                + speedText,
                        frac);
            }

            @Override
            public void onSeekCommit() {
                if (a.playbackControls != null) {
                    a.playbackControls.touchSeeking = false;
                }
                if (a.player != null && a.prepared && durationMs > 0) {
                    if (a.playbackControls != null) {
                        a.playbackControls.recordUserSeek(targetSeekMs);
                    }
                    a.player.seekTo(targetSeekMs);
                    if (a.playClock != null) {
                        a.playClock.setText(
                                PlaybackController.formatTime(targetSeekMs)
                                        + " / "
                                        + PlaybackController.formatTime(durationMs));
                    }
                    if (a.playerChrome != null && a.playerChrome.seekHint != null) {
                        a.playerChrome.seekHint.setText("");
                        a.playerChrome.seekHint.setVisibility(View.GONE);
                    }
                    if (a.playerChrome != null && a.playerChrome.progressOnlyMode) {
                        a.showControls(false);
                    } else {
                        a.scheduleHide();
                    }
                }
                hideHud();
            }

            @Override
            public void onSeekCancel() {
                if (a.touchPlayerGesture == TouchPlayerGesture.this) {
                    if (a.playbackControls != null) {
                        a.playbackControls.touchSeeking = false;
                        if (a.player != null && a.prepared) {
                            a.playbackControls.onDanmuSeekSettled(a.player.getCurrentPosition());
                        }
                    }
                    if (a.playerChrome != null && a.playerChrome.seekHint != null) {
                        a.playerChrome.seekHint.setText("");
                        a.playerChrome.seekHint.setVisibility(View.GONE);
                    }
                    if (a.playerChrome != null
                            && a.playerChrome.progressOnlyMode
                            && activeCancelReason
                                    != PlayerGestureStateMachine.InterruptReason.EXIT_PLAYER) {
                        a.showControls(false);
                    }
                }
                hideHud();
            }

            @Override
            public void onBrightnessBegin() {
                if (a.root != null && a.root.getParent() != null) {
                    a.root.getParent().requestDisallowInterceptTouchEvent(true);
                }
            }

            @Override
            public void onBrightnessMove(float dy) {
                if (a.mobilePrefs().getBoolean(Prefs.SWIPE_SWAP_LR, false)) {
                    adjustVolumeByDrag(dy);
                } else {
                    adjustBrightnessByDrag(dy);
                }
            }

            @Override
            public void onVolumeBegin() {
                if (a.root != null && a.root.getParent() != null) {
                    a.root.getParent().requestDisallowInterceptTouchEvent(true);
                }
            }

            @Override
            public void onVolumeMove(float dy) {
                if (a.mobilePrefs().getBoolean(Prefs.SWIPE_SWAP_LR, false)) {
                    adjustBrightnessByDrag(dy);
                } else {
                    adjustVolumeByDrag(dy);
                }
            }

            @Override
            public void onVerticalDragEnd() {
                hideHud();
            }

            @Override
            public void onSpeedBoostStart(float speed, int detentIndex) {
                applyPlayerSpeedSafely(speed);
                performTickHaptic();
                hideHud();
                speedLockCapsule.showBoosting(speed, detentIndex, false);
            }

            @Override
            public void onSpeedBoostChanged(float speed, int detentIndex) {
                applyPlayerSpeedSafely(speed);
                performTickHaptic();
                boolean lockReady =
                        fsm.getState() == PlayerGestureStateMachine.State.SPEED_LOCK_READY;
                speedLockCapsule.showBoosting(speed, detentIndex, lockReady);
            }

            @Override
            public void onSpeedLockReadyChanged(boolean lockReady, float speed) {
                performTickHaptic();
                speedLockCapsule.showBoosting(speed, fsm.getCurrentDetentIndex(), lockReady);
            }

            @Override
            public void onSpeedLocked(float lockedSpeed) {
                performTickHaptic();
                speedLockCapsule.showLocked(lockedSpeed, TouchPlayerGesture.this::unlockSpeedLock);
            }

            @Override
            public void onSpeedBoostEnd(float restoredSpeed, boolean cancelled) {
                if (activeCancelReason != PlayerGestureStateMachine.InterruptReason.EXIT_PLAYER
                        || a.touchPlayerGesture == TouchPlayerGesture.this) {
                    applyPlayerSpeedSafely(restoredSpeed);
                }
                speedLockCapsule.hide();
            }

            @Override
            public void onSpeedUnlocked(float restoredSpeed) {
                speedLockCapsule.hide();
                if (restoredSpeed > 0f) {
                    if (activeCancelReason != PlayerGestureStateMachine.InterruptReason.EXIT_PLAYER
                            || a.touchPlayerGesture == TouchPlayerGesture.this) {
                        applyPlayerSpeedSafely(restoredSpeed);
                    }
                    if (shouldShowUnlockNotice(activeCancelReason)) {
                        showBriefNotice(
                                "已恢复 " + SpeedLockCapsule.formatSpeed(restoredSpeed) + " 播放");
                    }
                }
            }
        };
    }

    static boolean shouldShowUnlockNotice(PlayerGestureStateMachine.InterruptReason reason) {
        return reason != PlayerGestureStateMachine.InterruptReason.EXIT_PLAYER
                && reason != PlayerGestureStateMachine.InterruptReason.SCREEN_LOCKED;
    }

    static boolean shouldPreserveNoticeOnCancel(
            PlayerGestureStateMachine.InterruptReason reason, boolean noticeActive) {
        return noticeActive && reason == PlayerGestureStateMachine.InterruptReason.SCREEN_LOCKED;
    }

    static void mergeSystemGestureInsets(
            PlayerGestureStateMachine.Env env,
            int chromeLeft,
            int chromeTop,
            int chromeRight,
            int chromeBottom,
            int gestureLeft,
            int gestureTop,
            int gestureRight,
            int gestureBottom) {
        if (env == null) return;
        env.systemGestureInsetLeftPx = Math.max(0, Math.max(chromeLeft, gestureLeft));
        env.systemGestureInsetRightPx = Math.max(0, Math.max(chromeRight, gestureRight));
        env.systemInsetTopPx = Math.max(0, Math.max(chromeTop, gestureTop));
        env.systemInsetBottomPx = Math.max(0, Math.max(chromeBottom, gestureBottom));
    }

    static void disableMotionEventSplitting(ViewGroup group) {
        if (group == null) return;
        group.setMotionEventSplittingEnabled(false);
    }

    static void attach(MainActivity activity, View surfaceView) {
        TouchPlayerGesture listener = new TouchPlayerGesture(activity);
        activity.touchPlayerGesture = listener;
        disableMotionEventSplitting(activity.root);
        disableMotionEventSplitting(activity.playbackLayer);
        if (activity.playerChrome != null) {
            disableMotionEventSplitting(activity.playerChrome.overlay);
        }
        activity.root.setOnTouchListener(listener);
        listener.restoreRememberedSourceBrightness();
    }

    private float twoFingerStartY;
    private boolean twoFingerActive;
    private boolean twoFingerTriggered;

    private void adjustBrightnessByDrag(float dy) {
        int height = effectiveHostHeight();
        float level = SeekGesture.dragVerticalLevel(startBrightness, dy, height);
        float clamped = Math.max(0.02f, Math.min(1.0f, level));
        WindowManager.LayoutParams attrs = a.getWindow().getAttributes();
        attrs.screenBrightness = clamped;
        a.getWindow().setAttributes(attrs);
        saveRememberedSourceBrightness(clamped);
        showHud("屏幕亮度 " + Math.round(clamped * 100) + "%", clamped);
    }

    private void adjustVolumeByDrag(float dy) {
        int height = effectiveHostHeight();
        float level = SeekGesture.dragVerticalLevel(startVolume, dy, height);
        AudioManager audio = (AudioManager) a.getSystemService(Context.AUDIO_SERVICE);
        if (audio != null) {
            int max = Math.max(1, audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC));
            int vol = Math.round(level * max);
            audio.setStreamVolume(AudioManager.STREAM_MUSIC, vol, 0);
        }
        showHud("媒体音量 " + Math.round(level * 100) + "%", level);
    }

    private void restoreRememberedSourceBrightness() {
        if (!a.mobilePrefs().getBoolean(Prefs.REMEMBER_SOURCE_BRIGHTNESS, true)) return;
        String siteKey =
                (a.playbackControls != null && a.playbackControls.site != null)
                        ? a.playbackControls.site.key
                        : "";
        if (siteKey == null || siteKey.isEmpty()) return;
        try {
            org.json.JSONObject map =
                    new org.json.JSONObject(
                            a.mobilePrefs().getString(Prefs.SOURCE_BRIGHTNESS_MAP, "{}"));
            if (map.has(siteKey)) {
                float saved = (float) map.optDouble(siteKey, -1.0);
                if (saved >= 0.02f && saved <= 1.0f) {
                    WindowManager.LayoutParams attrs = a.getWindow().getAttributes();
                    attrs.screenBrightness = saved;
                    a.getWindow().setAttributes(attrs);
                }
            }
        } catch (Exception ignored) {
        }
    }

    private void saveRememberedSourceBrightness(float level) {
        if (!a.mobilePrefs().getBoolean(Prefs.REMEMBER_SOURCE_BRIGHTNESS, true)) return;
        String siteKey =
                (a.playbackControls != null && a.playbackControls.site != null)
                        ? a.playbackControls.site.key
                        : "";
        if (siteKey == null || siteKey.isEmpty()) return;
        try {
            org.json.JSONObject map =
                    new org.json.JSONObject(
                            a.mobilePrefs().getString(Prefs.SOURCE_BRIGHTNESS_MAP, "{}"));
            map.put(siteKey, Math.round(level * 100f) / 100.0);
            a.mobilePrefs().edit().putString(Prefs.SOURCE_BRIGHTNESS_MAP, map.toString()).apply();
        } catch (Exception ignored) {
        }
    }

    private int effectiveHostWidth() {
        if (a.root != null && a.root.getWidth() > 0) return a.root.getWidth();
        return Math.max(1, a.windowWidth());
    }

    private int effectiveHostHeight() {
        if (a.root != null && a.root.getHeight() > 0) return a.root.getHeight();
        return Math.max(1, a.windowHeight());
    }

    void updateSafeTop(int safeTopPx) {
        if (speedLockCapsule != null) {
            speedLockCapsule.updateSafeTop(safeTopPx);
        }
    }

    void unlockSpeedLock() {
        fsm.unlockLockedSpeed(SystemClock.uptimeMillis());
        scheduleNextFsmTick();
    }

    void onEpisodeSwitch() {
        cancelWithReason(PlayerGestureStateMachine.InterruptReason.EPISODE_SWITCH);
    }

    void onManualSpeedChanged() {
        cancelWithReason(PlayerGestureStateMachine.InterruptReason.MANUAL_SPEED_CHANGE);
    }

    void onDialogOpened() {
        cancelWithReason(PlayerGestureStateMachine.InterruptReason.DIALOG_OPEN);
    }

    /**
     * Proactively invoked right before locking the screen so SPEED_LOCKED unlocks immediately even
     * though PlaybackController.setPlayerLocked() sets a.playerLocked after cancelActiveGesture().
     */
    void onScreenLockRequested() {
        cancelWithReason(PlayerGestureStateMachine.InterruptReason.SCREEN_LOCKED);
    }

    /**
     * Synchronizes gesture/speed-lock state with external runtime transitions (miniMode/PiP entry,
     * Home backgrounding after focus loss, screen lock, or external pause/audio-focus loss).
     */
    void syncRuntimeState() {
        if (a.touchPlayerGesture != this) return;
        boolean inPip = Build.VERSION.SDK_INT >= 24 && a.isInPictureInPictureMode();
        if (a.miniMode || inPip) {
            if (fsm.getState() != PlayerGestureStateMachine.State.IDLE
                    || fsm.isAnySpeedOverrideActive()) {
                cancelWithReason(PlayerGestureStateMachine.InterruptReason.PIP_OR_MINI);
            }
            return;
        }
        if (!a.foreground) {
            if (fsm.getState() != PlayerGestureStateMachine.State.IDLE
                    || fsm.isAnySpeedOverrideActive()) {
                cancelWithReason(PlayerGestureStateMachine.InterruptReason.BACKGROUND);
            }
            return;
        }
        if (a.playerLocked) {
            if (fsm.getState() != PlayerGestureStateMachine.State.LOCKED_IDLE
                    || fsm.isAnySpeedOverrideActive()) {
                cancelWithReason(PlayerGestureStateMachine.InterruptReason.SCREEN_LOCKED);
            }
            return;
        }
        if (fsm.getState() == PlayerGestureStateMachine.State.LOCKED_IDLE) {
            fsm.setScreenLocked(false, SystemClock.uptimeMillis());
        }
        if (fsm.isAnySpeedOverrideActive()) {
            PlaybackStateProbe.Snapshot snap =
                    a.player != null && a.prepared ? PlaybackStateProbe.inspect(a.player) : null;
            boolean intended = PlaybackStateProbe.isPlaybackIntended(a.playing, snap);
            if (!intended) {
                cancelWithReason(
                        PlaybackStateProbe.isAudioFocusSuppressed(snap)
                                ? PlayerGestureStateMachine.InterruptReason.AUDIO_FOCUS_LOST
                                : PlayerGestureStateMachine.InterruptReason.PLAYBACK_PAUSED);
            }
        }
    }

    void cancelActiveGesture() {
        cancelWithReason(
                a.playerLocked
                        ? PlayerGestureStateMachine.InterruptReason.SCREEN_LOCKED
                        : PlayerGestureStateMachine.InterruptReason.ACTION_CANCEL);
    }

    private void cancelWithReason(PlayerGestureStateMachine.InterruptReason reason) {
        a.ui.removeCallbacks(fsmTickRunnable);
        boolean keepNotice = shouldPreserveNoticeOnCancel(reason, briefNoticeActive);
        if (!keepNotice) {
            a.ui.removeCallbacks(hideNoticeRunnable);
            if (reason == PlayerGestureStateMachine.InterruptReason.EXIT_PLAYER
                    || reason == PlayerGestureStateMachine.InterruptReason.PIP_OR_MINI
                    || reason == PlayerGestureStateMachine.InterruptReason.BACKGROUND) {
                hideHud();
            }
        }
        recycleVelocityTracker();
        PlayerGestureStateMachine.InterruptReason prev = activeCancelReason;
        activeCancelReason = reason;
        try {
            fsm.cancel(reason, SystemClock.uptimeMillis());
        } finally {
            activeCancelReason = prev;
        }
        if (reason == PlayerGestureStateMachine.InterruptReason.EXIT_PLAYER) {
            a.ui.removeCallbacks(hideNoticeRunnable);
            hideHud();
        }
    }

    private void refreshConfigFromPrefs() {
        PlayerGestureStateMachine.Config cfg = fsm.config();
        cfg.doubleTapCenter = PlayerHudPrefs.getDoubleTapCenter(a);
        cfg.doubleTapSides = PlayerHudPrefs.getDoubleTapSides(a);
        cfg.longPressRestoreMode = PlayerHudPrefs.getLongPressRestoreMode(a);
        boolean reducedTransparency =
                a.prefs != null && a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false);
        speedLockCapsule.setAccessibilityFlags(a.reduced, reducedTransparency);
    }

    private void applyPlayerSpeedSafely(float speed) {
        if (a.player != null && a.prepared && speed > 0f) {
            try {
                a.player.setSpeed(speed);
                if (a.playbackControls != null) {
                    a.playbackControls.onDanmuPlaySpeedChanged(speed);
                }
            } catch (Exception ignored) {
            }
        }
    }

    private void performTickHaptic() {
        if (a.root != null) {
            try {
                a.root.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK);
            } catch (Exception ignored) {
            }
        }
    }

    private void scheduleNextFsmTick() {
        a.ui.removeCallbacks(fsmTickRunnable);
        long deadline = fsm.nextDeadlineMs();
        if (deadline >= 0L) {
            long delay = Math.max(0L, deadline - SystemClock.uptimeMillis());
            a.ui.postDelayed(fsmTickRunnable, delay);
        }
    }

    private void recycleVelocityTracker() {
        if (velocityTracker != null) {
            velocityTracker.recycle();
            velocityTracker = null;
        }
    }

    void showBriefNotice(String text) {
        if (a.touchPlayerGesture != this) return;
        // PlaybackController.setPlayerLocked(a, true) sets a.playerLocked = true right before
        // calling showBriefNotice(); synchronize LOCKED_IDLE & unlock SPEED_LOCKED immediately
        // without clobbering the notice we are about to show.
        if (a.playerLocked
                && (fsm.getState() != PlayerGestureStateMachine.State.LOCKED_IDLE
                        || fsm.isAnySpeedOverrideActive())) {
            cancelWithReason(PlayerGestureStateMachine.InterruptReason.SCREEN_LOCKED);
        } else if (!a.playerLocked
                && fsm.getState() == PlayerGestureStateMachine.State.LOCKED_IDLE) {
            fsm.setScreenLocked(false, SystemClock.uptimeMillis());
        }
        a.ui.removeCallbacks(hideNoticeRunnable);
        briefNoticeActive = true;
        showHud(text, -1f);
        a.ui.postDelayed(hideNoticeRunnable, 1300L);
    }

    private void showHud(String text, float progressFraction) {
        hud.setText(text);
        if (progressFraction >= 0f) {
            briefNoticeActive = false;
            hudProgress.setProgressFraction(progressFraction);
            hudProgress.setVisibility(View.VISIBLE);
        } else {
            hudProgress.setVisibility(View.GONE);
        }
        hudCard.setVisibility(View.VISIBLE);
    }

    private void hideHud() {
        briefNoticeActive = false;
        hudCard.setVisibility(View.GONE);
        hudProgress.setVisibility(View.GONE);
    }

    /**
     * Tests whether a view-local touch point relative to {@code a.root} falls inside a child view's
     * Activity-window {@link View#getGlobalVisibleRect(Rect)} bounds. Converting {@code (localX,
     * localY)} into the same Window coordinate space avoids split-screen and freeform physical
     * screen-offset skew caused by comparing {@code getRawX()/getRawY()} against Window rects.
     */
    static boolean isLocalTouchInsideWindowRect(
            float localX,
            float localY,
            int rootGlobalLeft,
            int rootGlobalTop,
            int targetLeft,
            int targetTop,
            int targetRight,
            int targetBottom) {
        int winX = Math.round(rootGlobalLeft + localX);
        int winY = Math.round(rootGlobalTop + localY);
        return winX >= targetLeft && winX < targetRight && winY >= targetTop && winY < targetBottom;
    }

    private boolean isTouchInsideView(
            View view, float localX, float localY, int rootGlobalLeft, int rootGlobalTop) {
        if (view == null || !view.isShown()) return false;
        if (!view.getGlobalVisibleRect(hitRect)) return false;
        return isLocalTouchInsideWindowRect(
                localX,
                localY,
                rootGlobalLeft,
                rootGlobalTop,
                hitRect.left,
                hitRect.top,
                hitRect.right,
                hitRect.bottom);
    }

    private boolean isTouchInsideControls(float localX, float localY) {
        int rootLeft = 0;
        int rootTop = 0;
        if (a.root != null && a.root.getGlobalVisibleRect(rootRect)) {
            rootLeft = rootRect.left;
            rootTop = rootRect.top;
        }
        if (speedLockCapsule != null
                && speedLockCapsule.getVisibility() == View.VISIBLE
                && isTouchInsideView(speedLockCapsule, localX, localY, rootLeft, rootTop)) {
            return true;
        }
        if (a.playbackControls != null) {
            if (a.playbackControls.skipCountdownPill != null
                    && a.playbackControls.skipCountdownPill.getVisibility() == View.VISIBLE
                    && isTouchInsideView(
                            a.playbackControls.skipCountdownPill,
                            localX,
                            localY,
                            rootLeft,
                            rootTop)) {
                return true;
            }
            if (a.playbackControls.sleepWarningPill != null
                    && a.playbackControls.sleepWarningPill.getVisibility() == View.VISIBLE
                    && isTouchInsideView(
                            a.playbackControls.sleepWarningPill,
                            localX,
                            localY,
                            rootLeft,
                            rootTop)) {
                return true;
            }
        }
        if (!a.controlsVisible || a.playerChrome == null) return false;
        return isTouchInsideView(a.playerChrome.dock, localX, localY, rootLeft, rootTop)
                || isTouchInsideView(a.playerChrome.heading, localX, localY, rootLeft, rootTop)
                || isTouchInsideView(a.playerChrome.progress, localX, localY, rootLeft, rootTop)
                || isTouchInsideView(a.playerChrome.lockBtn, localX, localY, rootLeft, rootTop);
    }

    @SuppressWarnings("deprecation")
    private PlayerGestureStateMachine.Env buildEnv(float localX, float localY, boolean downEvent) {
        PlayerGestureStateMachine.Env env = new PlayerGestureStateMachine.Env();
        env.density = a.getResources().getDisplayMetrics().density;
        env.screenWidthPx = effectiveHostWidth();
        env.screenHeightPx = effectiveHostHeight();
        int chromeLeft = a.playerChrome != null ? a.playerChrome.windowInsets.left : 0;
        int chromeTop = a.playerChrome != null ? a.playerChrome.windowInsets.top : 0;
        int chromeRight = a.playerChrome != null ? a.playerChrome.windowInsets.right : 0;
        int chromeBottom = a.playerChrome != null ? a.playerChrome.windowInsets.bottom : 0;
        int gestureLeft = 0;
        int gestureTop = 0;
        int gestureRight = 0;
        int gestureBottom = 0;
        if (Build.VERSION.SDK_INT >= 29 && a.root != null) {
            WindowInsets rootInsets = a.root.getRootWindowInsets();
            if (rootInsets != null) {
                if (Build.VERSION.SDK_INT >= 30) {
                    android.graphics.Insets g =
                            rootInsets.getInsets(WindowInsets.Type.systemGestures());
                    gestureLeft = g.left;
                    gestureTop = g.top;
                    gestureRight = g.right;
                    gestureBottom = g.bottom;
                } else {
                    android.graphics.Insets g = rootInsets.getSystemGestureInsets();
                    gestureLeft = g.left;
                    gestureTop = g.top;
                    gestureRight = g.right;
                    gestureBottom = g.bottom;
                }
            }
        }
        mergeSystemGestureInsets(
                env,
                chromeLeft,
                chromeTop,
                chromeRight,
                chromeBottom,
                gestureLeft,
                gestureTop,
                gestureRight,
                gestureBottom);
        env.screenLocked = a.playerLocked;
        boolean inPip = Build.VERSION.SDK_INT >= 24 && a.isInPictureInPictureMode();
        env.miniOrPip = a.miniMode || inPip;
        env.liveStream = a.isLive();
        env.prepared = a.prepared;
        PlaybackStateProbe.Snapshot snap =
                a.player != null && a.prepared ? PlaybackStateProbe.inspect(a.player) : null;
        env.playing = PlaybackStateProbe.isPlaybackIntended(a.playing, snap);
        env.durationMs =
                a.player != null && a.prepared ? Math.max(0, a.player.getDuration()) : durationMs;
        env.controlsVisible = a.controlsVisible;
        env.startedInsideControls = downEvent && isTouchInsideControls(localX, localY);
        env.userNormalSpeed = a.prefs != null ? a.prefs.getFloat(Prefs.PLAY_SPEED, 1.0f) : 1.0f;
        return env;
    }

    @Override
    public boolean onTouch(View v, MotionEvent event) {
        if (a.miniMode) {
            syncRuntimeState();
            return handleMiniModeTouch(event);
        }
        long nowMs = SystemClock.uptimeMillis();
        int action = event.getActionMasked();
        int pointerCount = event.getPointerCount();
        int pointerId = event.getPointerId(0);
        // View-local coordinates relative to a.root ensure split-screen / freeform windows match
        // effectiveHostWidth/Height and map consistently into Window-space HUD hit rects.
        float localX = event.getX();
        float localY = event.getY();

        if (action == MotionEvent.ACTION_POINTER_DOWN || pointerCount > 1) {
            cancelWithReason(PlayerGestureStateMachine.InterruptReason.MULTI_TOUCH);
            int epMode = a.mobilePrefs().getInt(Prefs.VERTICAL_SWIPE_EPISODE, 1);
            if (epMode > 0 && !a.playerLocked && pointerCount == 2) {
                float avgY = (event.getY(0) + event.getY(1)) * 0.5f;
                if (action == MotionEvent.ACTION_POINTER_DOWN || !twoFingerActive) {
                    twoFingerActive = true;
                    twoFingerTriggered = false;
                    twoFingerStartY = avgY;
                } else if (action == MotionEvent.ACTION_MOVE && !twoFingerTriggered) {
                    float dy = avgY - twoFingerStartY;
                    if (Math.abs(dy) >= a.dp(72) && a.playbackControls != null) {
                        twoFingerTriggered = true;
                        int step = dy < 0 ? 1 : -1;
                        if (a.isLive()) {
                            a.liveStep(step);
                        } else if (!a.playbackControls.step(step)) {
                            a.toast(step > 0 ? "已是最后一集" : "已是第一集");
                        }
                    }
                }
            }
            if (action == MotionEvent.ACTION_POINTER_UP
                    || action == MotionEvent.ACTION_UP
                    || action == MotionEvent.ACTION_CANCEL) {
                twoFingerActive = false;
                twoFingerTriggered = false;
            }
            return true;
        }
        twoFingerActive = false;

        if (action == MotionEvent.ACTION_DOWN) {
            refreshConfigFromPrefs();
            fsm.setScreenLocked(a.playerLocked, nowMs);
            lastMoveTimeMs = nowMs;
            if (velocityTracker == null) {
                velocityTracker = VelocityTracker.obtain();
            } else {
                velocityTracker.clear();
            }
            velocityTracker.addMovement(event);
            if (a.playbackControls != null) {
                a.playbackControls.touchSeeking = false;
            }
            if (a.player != null && a.prepared) {
                startPositionMs = a.player.getCurrentPosition();
                durationMs = a.player.getDuration();
                targetSeekMs = startPositionMs;
            }
            WindowManager.LayoutParams attrs = a.getWindow().getAttributes();
            startBrightness =
                    attrs.screenBrightness >= 0f && attrs.screenBrightness <= 1f
                            ? attrs.screenBrightness
                            : 0.5f;
            AudioManager audio = (AudioManager) a.getSystemService(Context.AUDIO_SERVICE);
            if (audio != null) {
                int max = Math.max(1, audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC));
                int cur = audio.getStreamVolume(AudioManager.STREAM_MUSIC);
                startVolume = cur / (float) max;
            }
            PlayerGestureStateMachine.Env env = buildEnv(localX, localY, true);
            boolean accepted =
                    fsm.onPointerDown(pointerId, pointerCount, localX, localY, nowMs, env);
            scheduleNextFsmTick();
            // Return false if ignored by edge guard so system back swipe works cleanly.
            return accepted || a.playerLocked;
        }

        if (action == MotionEvent.ACTION_MOVE) {
            if (velocityTracker != null) velocityTracker.addMovement(event);
            PlayerGestureStateMachine.Env env = buildEnv(localX, localY, false);
            fsm.onPointerMove(pointerId, pointerCount, localX, localY, nowMs, env);
            scheduleNextFsmTick();
            return true;
        }

        if (action == MotionEvent.ACTION_UP) {
            PlayerGestureStateMachine.Env env = buildEnv(localX, localY, false);
            fsm.onPointerUp(pointerId, localX, localY, nowMs, env);
            recycleVelocityTracker();
            scheduleNextFsmTick();
            return true;
        }

        if (action == MotionEvent.ACTION_CANCEL) {
            cancelWithReason(PlayerGestureStateMachine.InterruptReason.ACTION_CANCEL);
            return true;
        }

        return true;
    }

    private boolean handleMiniModeTouch(MotionEvent event) {
        int action = event.getActionMasked();
        if (action == MotionEvent.ACTION_DOWN) {
            miniDownX = event.getRawX();
            miniDownY = event.getRawY();
            miniTapCandidate = true;
            return true;
        }
        if (action == MotionEvent.ACTION_MOVE && miniTapCandidate) {
            float slop = a.dp(PlayerGestureStateMachine.TOUCH_SLOP_DP);
            if (Math.abs(event.getRawX() - miniDownX) > slop
                    || Math.abs(event.getRawY() - miniDownY) > slop) {
                miniTapCandidate = false;
            }
            return true;
        }
        if (action == MotionEvent.ACTION_UP && miniTapCandidate) {
            miniTapCandidate = false;
            a.expandPlayback();
            return true;
        }
        miniTapCandidate = false;
        return true;
    }
}
