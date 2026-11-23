package com.pilipala.marcomovie;

import android.view.KeyEvent;
import com.pilipala.marcomovie.PlayerGestureStateMachine.Env;
import com.pilipala.marcomovie.PlayerGestureStateMachine.InterruptReason;
import com.pilipala.marcomovie.PlayerGestureStateMachine.State;
import com.pilipala.marcomovie.hud.FastForwardScrubCapsule;
import com.pilipala.marcomovie.hud.PlaybackStateProbe;
import com.pilipala.marcomovie.hud.PlayerHudPrefs;
import com.pilipala.marcomovie.hud.SkipCountdownPill;
import com.pilipala.marcomovie.hud.SleepTimerSheet;
import com.pilipala.marcomovie.hud.StartSpecBanner;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/**
 * Pure-JVM deterministic verification suite for M2 Android Player HUD & Touch Gesture State
 * Machine.
 */
public final class PlayerGestureChecks {
    private static int checks;

    private static void check(boolean ok, String label) {
        if (!ok) {
            throw new AssertionError("FAILED: " + label);
        }
        checks++;
        System.out.println("PASS " + label);
    }

    private static Env defaultEnv() {
        Env env = new Env();
        env.density = 1.0f; // 1px == 1dp for clean deterministic math
        env.screenWidthPx = 1000f;
        env.screenHeightPx = 500f;
        env.prepared = true;
        env.playing = true;
        env.durationMs = 3_600_000;
        env.userNormalSpeed = 1.25f;
        return env;
    }

    private static final class Spy extends PlayerGestureStateMachine.ListenerAdapter {
        final List<State> states = new ArrayList<>();
        int singleTaps;
        int lockedSingleTaps;
        int doubleTapPlayPauses;
        int doubleTapFullscreens;
        int doubleTapSeekCalls;
        int lastSeekStepMs;
        int lastSeekAccumulatedMs;
        int multiTapEnds;
        int seekBegins;
        int seekMoves;
        int seekCommits;
        int seekCancels;
        int brightnessBegins;
        int brightnessMoves;
        int volumeBegins;
        int volumeMoves;
        int verticalEnds;
        int boostStarts;
        int boostChanges;
        float lastBoostSpeed;
        int lastDetentIndex = -1;
        boolean lastLockReady;
        int lockReadyChanges;
        int speedLocks;
        float lastLockedSpeed;
        int boostEnds;
        float lastRestoredSpeed;
        boolean lastBoostEndCancelled;
        int speedUnlocks;
        float lastUnlockedSpeed;

        @Override
        public void onStateChanged(State from, State to) {
            states.add(to);
        }

        @Override
        public void onSingleTap() {
            singleTaps++;
        }

        @Override
        public void onLockedSingleTap() {
            lockedSingleTaps++;
        }

        @Override
        public void onDoubleTapPlayPause() {
            doubleTapPlayPauses++;
        }

        @Override
        public void onDoubleTapFullscreen() {
            doubleTapFullscreens++;
        }

        @Override
        public void onDoubleTapSeek(int stepMs, int accumulatedMs) {
            doubleTapSeekCalls++;
            lastSeekStepMs = stepMs;
            lastSeekAccumulatedMs = accumulatedMs;
        }

        @Override
        public void onMultiTapSeekEnd() {
            multiTapEnds++;
        }

        @Override
        public void onSeekBegin(float downX, float downY) {
            seekBegins++;
        }

        @Override
        public void onSeekMove(float dx, float stepDx, float rawX, long nowMs) {
            seekMoves++;
        }

        @Override
        public void onSeekCommit() {
            seekCommits++;
        }

        @Override
        public void onSeekCancel() {
            seekCancels++;
        }

        @Override
        public void onBrightnessBegin() {
            brightnessBegins++;
        }

        @Override
        public void onBrightnessMove(float dy) {
            brightnessMoves++;
        }

        @Override
        public void onVolumeBegin() {
            volumeBegins++;
        }

        @Override
        public void onVolumeMove(float dy) {
            volumeMoves++;
        }

        @Override
        public void onVerticalDragEnd() {
            verticalEnds++;
        }

        @Override
        public void onSpeedBoostStart(float speed, int detentIndex) {
            boostStarts++;
            lastBoostSpeed = speed;
            lastDetentIndex = detentIndex;
        }

        @Override
        public void onSpeedBoostChanged(float speed, int detentIndex) {
            boostChanges++;
            lastBoostSpeed = speed;
            lastDetentIndex = detentIndex;
        }

        @Override
        public void onSpeedLockReadyChanged(boolean lockReady, float speed) {
            lockReadyChanges++;
            lastLockReady = lockReady;
            lastBoostSpeed = speed;
        }

        @Override
        public void onSpeedLocked(float lockedSpeed) {
            speedLocks++;
            lastLockedSpeed = lockedSpeed;
        }

        @Override
        public void onSpeedBoostEnd(float restoredSpeed, boolean cancelled) {
            boostEnds++;
            lastRestoredSpeed = restoredSpeed;
            lastBoostEndCancelled = cancelled;
        }

        @Override
        public void onSpeedUnlocked(float restoredSpeed) {
            speedUnlocks++;
            lastUnlockedSpeed = restoredSpeed;
        }
    }

    public static void main(String[] args) {
        testSingleTapAndDoubleTapCenterModes();
        testSecondTapDragDoesNotTriggerDoubleTap();
        testMultiTapSideSeekComboNeverTogglesControls();
        testEdgeAndSystemVerticalGuards();
        testMutualExclusionDragsCancelLongPress();
        testLongPressSpeedDetentsAndReleaseRestore();
        testLongPressAlreadyAt2xStartsAt3x();
        testSwipeUpLockHysteresisAndUnlockMatrix();
        testAllInterruptionSafetyResets();
        testLockedIdleAndLiveStreamGuards();
        testStartSpecDualChannelFusionAndAntiOverlap();
        testSkipCountdownControllerAndTvKeyRouting();
        testSleepTimerControllerPresetsWarningExtendAndExpiry();
        testPrefsNormalizersAndScrubFormatting();
        testRound2Regressions();
        testGate1_S01_MultiTouchCrossViewOrphanGuard();
        testGate1_S02_BufferingNotPausedAndHoldTickRecheck();
        testGate1_S03_SkipCountdownSilentCancelOnPauseBackgroundCallPipLock();
        testGate1_S05_TvSkipCountdownStartupFocusShowControlsAndBackRepeatGuard();
        testGate1_M01_ScreenLockUnlocksSpeedLockedAndPreservesNoticeTimer();
        testGate1_M02_SplitScreenLocalCoordsAndApi29SystemGestureInsets();
        testGate1_M07_SlimProgressToggleDecoupledFromHorizontalSeekPreview();
        testGate1_M08_SleepTimerTvReachabilityMobileSafeTopAndSessionReset();
        testGate1_L01_ExitPlayerSkipsUnlockNoticeAndOwnershipGuard();
        System.out.println("ALL PASS (" + checks + " Android M2 HUD & gesture checks)");
    }

    private static void testSingleTapAndDoubleTapCenterModes() {
        Spy spy = new Spy();
        PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
        Env env = defaultEnv();

        check(fsm.onPointerDown(0, 1, 500, 250, 1000, env), "Center pointer down accepted");
        check(fsm.getState() == State.DOWN_PENDING, "Enters DOWN_PENDING on pointer down");
        fsm.onPointerUp(0, 504, 252, 1080, env);
        check(fsm.getState() == State.WAIT_DOUBLE_TAP, "Short release enters WAIT_DOUBLE_TAP");
        fsm.onTick(1339);
        check(spy.singleTaps == 0, "Single tap waits full 260ms window");
        fsm.onTick(1340);
        check(spy.singleTaps == 1 && fsm.getState() == State.IDLE, "Single tap fires at 260ms");

        // Double-tap center -> play/pause (must trigger on UP, not DOWN)
        fsm.onPointerDown(0, 1, 500, 250, 2000, env);
        fsm.onPointerUp(0, 500, 250, 2050, env);
        fsm.onPointerDown(0, 1, 510, 255, 2150, env);
        check(
                fsm.getState() == State.SECOND_TAP_DOWN && spy.doubleTapPlayPauses == 0,
                "Second tap down enters SECOND_TAP_DOWN without firing before UP");
        fsm.onPointerUp(0, 512, 255, 2210, env);
        check(
                spy.doubleTapPlayPauses == 1 && fsm.getState() == State.IDLE,
                "Center double-tap fires play/pause on second UP");

        // Toggle center mode to fullscreen
        fsm.config().doubleTapCenter = PlayerHudPrefs.CENTER_FULLSCREEN;
        fsm.onPointerDown(0, 1, 500, 250, 3000, env);
        fsm.onPointerUp(0, 500, 250, 3040, env);
        fsm.onPointerDown(0, 1, 500, 250, 3120, env);
        fsm.onPointerUp(0, 500, 250, 3160, env);
        check(spy.doubleTapFullscreens == 1, "Center double-tap supports fullscreen toggle");

        // Far-apart second tap (> 42dp) settles first single tap then starts fresh press
        fsm.config().doubleTapCenter = PlayerHudPrefs.CENTER_PLAY_PAUSE;
        int prevSingle = spy.singleTaps;
        fsm.onPointerDown(0, 1, 450, 250, 4000, env);
        fsm.onPointerUp(0, 450, 250, 4040, env);
        fsm.onPointerDown(0, 1, 550, 250, 4120, env);
        check(
                spy.singleTaps == prevSingle + 1 && fsm.getState() == State.DOWN_PENDING,
                "Far-apart second tap settles first single tap and begins fresh DOWN_PENDING");
        fsm.cancel(InterruptReason.ACTION_CANCEL, 4130);
    }

    private static void testSecondTapDragDoesNotTriggerDoubleTap() {
        Spy spy = new Spy();
        PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
        Env env = defaultEnv();

        fsm.onPointerDown(0, 1, 500, 250, 1000, env);
        fsm.onPointerUp(0, 500, 250, 1050, env);
        fsm.onPointerDown(0, 1, 500, 250, 1150, env);
        check(fsm.getState() == State.SECOND_TAP_DOWN, "Entered SECOND_TAP_DOWN");
        fsm.onPointerMove(0, 1, 530, 252, 1180, env);
        check(
                fsm.getState() == State.HORIZONTAL_SEEK && spy.seekBegins == 1,
                "Horizontal drag from SECOND_TAP_DOWN transitions to HORIZONTAL_SEEK");
        fsm.onPointerUp(0, 560, 252, 1220, env);
        check(
                spy.seekCommits == 1 && spy.doubleTapPlayPauses == 0 && spy.doubleTapSeekCalls == 0,
                "Drag from second tap commits seek and never falsely fires double-tap");
    }

    private static void testMultiTapSideSeekComboNeverTogglesControls() {
        Spy spy = new Spy();
        PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
        Env env = defaultEnv();

        // Double tap on left 28% (x = 150 / 1000) -> -10s
        fsm.onPointerDown(0, 1, 150, 250, 1000, env);
        fsm.onPointerUp(0, 150, 250, 1040, env);
        fsm.onPointerDown(0, 1, 152, 250, 1140, env);
        fsm.onPointerUp(0, 152, 250, 1180, env);
        check(
                fsm.getState() == State.MULTI_TAP_SEEK_WINDOW
                        && spy.doubleTapSeekCalls == 1
                        && spy.lastSeekStepMs == -10000
                        && spy.lastSeekAccumulatedMs == -10000,
                "Left-28% double-tap triggers -10s and enters MULTI_TAP_SEEK_WINDOW");

        // 3rd tap (odd!) within 650ms accumulates -20s without toggling controls
        fsm.onPointerDown(0, 1, 160, 250, 1500, env);
        fsm.onPointerUp(0, 160, 250, 1540, env);
        check(
                fsm.getState() == State.MULTI_TAP_SEEK_WINDOW
                        && spy.doubleTapSeekCalls == 2
                        && spy.lastSeekAccumulatedMs == -20000
                        && spy.singleTaps == 0,
                "3rd tap inside 650ms accumulates -20s without toggling controls");

        // Timeout after 650ms ends window cleanly without toggling controls
        fsm.onTick(1540 + 650);
        check(
                fsm.getState() == State.IDLE && spy.multiTapEnds == 1 && spy.singleTaps == 0,
                "Multi-tap seek window expires cleanly to IDLE with zero false single-taps");

        // Right-28% with 15s step, then tapping opposite side ends combo cleanly
        fsm.config().doubleTapSides = PlayerHudPrefs.SIDES_SEEK_15S;
        fsm.onPointerDown(0, 1, 850, 250, 3000, env);
        fsm.onPointerUp(0, 850, 250, 3040, env);
        fsm.onPointerDown(0, 1, 855, 250, 3120, env);
        fsm.onPointerUp(0, 855, 250, 3160, env);
        check(spy.lastSeekAccumulatedMs == 15000, "Right-28% double-tap respects seek_15s config");
        fsm.onPointerDown(0, 1, 150, 250, 3300, env);
        check(
                fsm.getState() == State.IDLE && spy.singleTaps == 0,
                "Tapping opposite side ends multi-tap combo without toggling controls");

        // Side mode toggled to full-screen play/pause
        fsm.config().doubleTapSides = PlayerHudPrefs.SIDES_PLAY_PAUSE;
        fsm.onPointerDown(0, 1, 150, 250, 5000, env);
        fsm.onPointerUp(0, 150, 250, 5040, env);
        fsm.onPointerDown(0, 1, 150, 250, 5120, env);
        fsm.onPointerUp(0, 150, 250, 5160, env);
        check(
                spy.doubleTapPlayPauses == 1,
                "Side double-tap can be toggled back to full-screen play/pause");
    }

    private static void testEdgeAndSystemVerticalGuards() {
        Spy spy = new Spy();
        PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
        Env env = defaultEnv();
        env.systemGestureInsetLeftPx = 32f;
        env.systemGestureInsetRightPx = 30f;

        check(!fsm.onPointerDown(0, 1, 20, 250, 1000, env), "Left edge back guard rejects touch");
        check(
                !fsm.onPointerDown(0, 1, 31, 250, 1010, env),
                "System gesture left inset (>24dp) rejects touch");
        check(!fsm.onPointerDown(0, 1, 980, 250, 1020, env), "Right edge back guard rejects touch");
        check(!fsm.onPointerDown(0, 1, 500, 20, 1030, env), "Top vertical guard (<28dp) rejects");
        check(
                !fsm.onPointerDown(0, 1, 500, 480, 1040, env),
                "Bottom vertical guard (>h-28dp) rejects");

        env.startedInsideControls = true;
        check(
                !fsm.onPointerDown(0, 1, 500, 250, 1050, env),
                "Touch starting inside visible controls/dock is ignored");
        check(fsm.getState() == State.IDLE, "Ignored guards leave FSM in IDLE");
    }

    private static void testMutualExclusionDragsCancelLongPress() {
        Spy spy = new Spy();
        PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
        Env env = defaultEnv();

        // Left half vertical drag -> brightness, cancels long-press
        fsm.onPointerDown(0, 1, 250, 250, 1000, env);
        fsm.onPointerMove(0, 1, 252, 225, 1100, env);
        check(
                fsm.getState() == State.VERTICAL_BRIGHTNESS
                        && !fsm.isLongPressArmed()
                        && spy.brightnessBegins == 1,
                "Left vertical drag enters VERTICAL_BRIGHTNESS and disarms long-press");
        fsm.onTick(1600);
        check(spy.boostStarts == 0, "Long-press never fires during brightness drag");
        fsm.onPointerUp(0, 252, 180, 1650, env);
        check(
                fsm.getState() == State.IDLE && spy.verticalEnds == 1,
                "Brightness drag ends cleanly");

        // Right half vertical drag -> volume
        fsm.onPointerDown(0, 1, 750, 250, 2000, env);
        fsm.onPointerMove(0, 1, 752, 220, 2080, env);
        check(
                fsm.getState() == State.VERTICAL_VOLUME && spy.volumeBegins == 1,
                "Right vertical drag enters VERTICAL_VOLUME");
        fsm.onPointerUp(0, 752, 190, 2200, env);

        // Horizontal seek before 350ms -> seek, cancels long-press, commits single seek on UP
        fsm.onPointerDown(0, 1, 500, 250, 3000, env);
        fsm.onPointerMove(0, 1, 530, 252, 3100, env);
        check(fsm.getState() == State.HORIZONTAL_SEEK, "Horizontal drag enters HORIZONTAL_SEEK");
        fsm.onTick(3600);
        check(spy.boostStarts == 0, "Long-press never fires during horizontal seek");
        fsm.onPointerUp(0, 620, 252, 3650, env);
        check(spy.seekCommits == 1, "Horizontal seek commits single seekTo on UP");
    }

    private static void testLongPressSpeedDetentsAndReleaseRestore() {
        Spy spy = new Spy();
        PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
        Env env = defaultEnv();
        env.userNormalSpeed = 1.25f;

        fsm.onPointerDown(0, 1, 500, 250, 1000, env);
        fsm.onTick(1349);
        check(
                fsm.getState() == State.DOWN_PENDING && spy.boostStarts == 0,
                "Stationary hold < 350ms does not activate speed boost");
        fsm.onTick(1350);
        check(
                fsm.getState() == State.LONG_PRESS_SPEED
                        && spy.boostStarts == 1
                        && Math.abs(spy.lastBoostSpeed - 2.0f) < 0.001f
                        && spy.lastDetentIndex == 2,
                "Stationary hold >= 350ms activates LONG_PRESS_SPEED at 2.0x");

        // Slide right +36dp -> 3.0x
        fsm.onPointerMove(0, 1, 536, 250, 1400, env);
        check(
                Math.abs(spy.lastBoostSpeed - 3.0f) < 0.001f && spy.lastDetentIndex == 3,
                "Horizontal slide +36dp steps up to 3.0x");

        // Slide left -36dp from anchor -> 1.5x
        fsm.onPointerMove(0, 1, 464, 250, 1450, env);
        check(
                Math.abs(spy.lastBoostSpeed - 1.5f) < 0.001f && spy.lastDetentIndex == 1,
                "Horizontal slide -36dp from anchor steps down to 1.5x");

        // Slide left -72dp from anchor -> 1.25x (clamped)
        fsm.onPointerMove(0, 1, 400, 250, 1500, env);
        check(
                Math.abs(spy.lastBoostSpeed - 1.25f) < 0.001f && spy.lastDetentIndex == 0,
                "Horizontal slide <= -72dp clamps to 1.25x");

        // Release without swipe-up restores userNormalSpeed (1.25x)
        fsm.onPointerUp(0, 400, 250, 1550, env);
        check(
                fsm.getState() == State.IDLE
                        && !fsm.isSpeedLocked()
                        && spy.boostEnds == 1
                        && !spy.lastBoostEndCancelled
                        && Math.abs(spy.lastRestoredSpeed - 1.25f) < 0.001f,
                "Release without lock restores userNormalSpeed (1.25x)");

        // Restore mode = "1.0x"
        fsm.config().longPressRestoreMode = PlayerHudPrefs.RESTORE_ONE_X;
        fsm.onPointerDown(0, 1, 500, 250, 2000, env);
        fsm.onTick(2350);
        fsm.onPointerUp(0, 500, 250, 2400, env);
        check(
                Math.abs(spy.lastRestoredSpeed - 1.0f) < 0.001f,
                "Restore mode 1.0x forces 1.0x on release");
    }

    private static void testLongPressAlreadyAt2xStartsAt3x() {
        Spy spy = new Spy();
        PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
        Env env = defaultEnv();
        env.userNormalSpeed = 2.0f;

        fsm.onPointerDown(0, 1, 500, 250, 1000, env);
        fsm.onTick(1350);
        check(
                fsm.getState() == State.LONG_PRESS_SPEED
                        && Math.abs(spy.lastBoostSpeed - 3.0f) < 0.001f
                        && spy.lastDetentIndex == 3,
                "Long-press when userNormalSpeed == 2.0x auto-elevates initial boost to 3.0x");
        fsm.onPointerUp(0, 500, 250, 1400, env);
        check(
                Math.abs(spy.lastRestoredSpeed - 2.0f) < 0.001f,
                "Releasing 3.0x boost restores userNormalSpeed 2.0x");
    }

    private static void testSwipeUpLockHysteresisAndUnlockMatrix() {
        Spy spy = new Spy();
        PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
        Env env = defaultEnv();
        env.userNormalSpeed = 1.5f;

        fsm.onPointerDown(0, 1, 500, 300, 1000, env);
        fsm.onTick(1350);
        // Move right to 3.0x, then swipe up -47dp (not yet locked)
        fsm.onPointerMove(0, 1, 540, 253, 1400, env);
        check(
                fsm.getState() == State.LONG_PRESS_SPEED,
                "Swipe up -47dp does not yet trigger SPEED_LOCK_READY");

        // Swipe up -48dp -> SPEED_LOCK_READY
        fsm.onPointerMove(0, 1, 540, 252, 1420, env);
        check(
                fsm.getState() == State.SPEED_LOCK_READY && spy.lastLockReady,
                "Swipe up dy <= -48dp enters SPEED_LOCK_READY");

        // Pull back to -40dp -> hysteresis keeps SPEED_LOCK_READY
        fsm.onPointerMove(0, 1, 540, 260, 1440, env);
        check(
                fsm.getState() == State.SPEED_LOCK_READY,
                "Hysteresis retains SPEED_LOCK_READY at dy = -40dp");

        // Pull back to -35dp -> exits back to LONG_PRESS_SPEED
        fsm.onPointerMove(0, 1, 540, 265, 1460, env);
        check(
                fsm.getState() == State.LONG_PRESS_SPEED && !spy.lastLockReady,
                "Pulling below -36dp cancels SPEED_LOCK_READY back to LONG_PRESS_SPEED");

        // Swipe up again to -54dp and release -> SPEED_LOCKED at 3.0x
        fsm.onPointerMove(0, 1, 540, 246, 1480, env);
        fsm.onPointerUp(0, 540, 246, 1500, env);
        check(
                fsm.getState() == State.SPEED_LOCKED
                        && fsm.isSpeedLocked()
                        && spy.speedLocks == 1
                        && Math.abs(spy.lastLockedSpeed - 3.0f) < 0.001f,
                "Releasing inside lock zone enters SPEED_LOCKED at 3.0x");

        // Tap unlock capsule -> restores 1.5x and returns IDLE
        fsm.unlockLockedSpeed(2000);
        check(
                fsm.getState() == State.IDLE
                        && !fsm.isSpeedLocked()
                        && spy.speedUnlocks == 1
                        && Math.abs(spy.lastUnlockedSpeed - 1.5f) < 0.001f,
                "Clicking unlock capsule restores userNormalSpeed (1.5x) and exits SPEED_LOCKED");

        // Auto-unlock matrix: episode switch, exit, background, audio focus, pause, lock,
        // multi-touch, PiP, manual
        InterruptReason[] autoUnlockReasons = {
            InterruptReason.EPISODE_SWITCH,
            InterruptReason.EXIT_PLAYER,
            InterruptReason.BACKGROUND,
            InterruptReason.AUDIO_FOCUS_LOST,
            InterruptReason.PLAYBACK_PAUSED,
            InterruptReason.SCREEN_LOCKED,
            InterruptReason.MULTI_TOUCH,
            InterruptReason.PIP_OR_MINI,
            InterruptReason.MANUAL_SPEED_CHANGE
        };
        long t = 3000;
        for (InterruptReason reason : autoUnlockReasons) {
            fsm.setScreenLocked(false, t);
            fsm.onPointerDown(0, 1, 500, 300, t, env);
            fsm.onTick(t + 350);
            fsm.onPointerMove(0, 1, 500, 245, t + 400, env);
            fsm.onPointerUp(0, 500, 245, t + 420, env);
            check(fsm.isSpeedLocked(), "Precondition locked before " + reason);
            int prevUnlocks = spy.speedUnlocks;
            fsm.cancel(reason, t + 500);
            boolean expectedUnlock = spy.speedUnlocks == prevUnlocks + 1;
            boolean expectedSpeed =
                    reason == InterruptReason.MANUAL_SPEED_CHANGE
                            ? spy.lastUnlockedSpeed < 0f
                            : Math.abs(spy.lastUnlockedSpeed - 1.5f) < 0.001f;
            check(
                    !fsm.isSpeedLocked() && expectedUnlock && expectedSpeed,
                    "SPEED_LOCKED auto-unlocks cleanly on " + reason);
            t += 1000;
        }
    }

    private static void testAllInterruptionSafetyResets() {
        InterruptReason[] reasons = {
            InterruptReason.ACTION_CANCEL,
            InterruptReason.MULTI_TOUCH,
            InterruptReason.WINDOW_FOCUS_LOST,
            InterruptReason.BACKGROUND,
            InterruptReason.AUDIO_FOCUS_LOST,
            InterruptReason.PLAYBACK_PAUSED,
            InterruptReason.PIP_OR_MINI,
            InterruptReason.DIALOG_OPEN,
            InterruptReason.EPISODE_SWITCH,
            InterruptReason.SCREEN_LOCKED
        };
        for (InterruptReason reason : reasons) {
            Spy spy = new Spy();
            PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
            Env env = defaultEnv();
            env.userNormalSpeed = 1.25f;

            // Interrupt during SPEED_LOCK_READY: must NOT lock, MUST restore 1.25x
            fsm.onPointerDown(0, 1, 500, 300, 1000, env);
            fsm.onTick(1350);
            fsm.onPointerMove(0, 1, 500, 240, 1400, env);
            check(fsm.getState() == State.SPEED_LOCK_READY, "In SPEED_LOCK_READY before " + reason);
            fsm.cancel(reason, 1450);
            State expectedEnd =
                    reason == InterruptReason.SCREEN_LOCKED ? State.LOCKED_IDLE : State.IDLE;
            check(
                    fsm.getState() == expectedEnd
                            && !fsm.isSpeedLocked()
                            && spy.boostEnds == 1
                            && spy.lastBoostEndCancelled
                            && Math.abs(spy.lastRestoredSpeed - 1.25f) < 0.001f
                            && spy.states.contains(State.CANCELLED),
                    "Interrupt " + reason + " during SPEED_LOCK_READY cancels & restores 1.25x");
        }

        // Interrupt during HORIZONTAL_SEEK discards preview without committing seek
        Spy seekSpy = new Spy();
        PlayerGestureStateMachine seekFsm = new PlayerGestureStateMachine(seekSpy);
        Env env = defaultEnv();
        seekFsm.onPointerDown(0, 1, 500, 250, 1000, env);
        seekFsm.onPointerMove(0, 1, 560, 250, 1050, env);
        seekFsm.onPointerDown(1, 2, 600, 250, 1080, env); // 2nd finger multi-touch interrupt
        check(
                seekFsm.getState() == State.IDLE
                        && seekSpy.seekCancels == 1
                        && seekSpy.seekCommits == 0,
                "Multi-touch during HORIZONTAL_SEEK cancels preview without committing seekTo");
    }

    private static void testLockedIdleAndLiveStreamGuards() {
        Spy spy = new Spy();
        PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
        Env env = defaultEnv();
        env.screenLocked = true;
        fsm.setScreenLocked(true, 1000);
        check(fsm.getState() == State.LOCKED_IDLE, "setScreenLocked(true) enters LOCKED_IDLE");

        fsm.onPointerDown(0, 1, 500, 250, 1100, env);
        fsm.onPointerUp(0, 502, 251, 1160, env);
        check(
                spy.lockedSingleTaps == 1 && spy.singleTaps == 0,
                "Single tap in LOCKED_IDLE toggles unlock capsule only");

        fsm.onPointerDown(0, 1, 500, 250, 1500, env);
        fsm.onTick(2000);
        fsm.onPointerMove(0, 1, 700, 250, 2050, env);
        fsm.onPointerUp(0, 700, 250, 2100, env);
        check(
                spy.boostStarts == 0 && spy.seekBegins == 0,
                "LOCKED_IDLE blocks long-press speed boost and horizontal seek");

        // Live stream: blocks horizontal seek & long-press speed boost
        fsm.setScreenLocked(false, 3000);
        env.screenLocked = false;
        env.liveStream = true;
        env.durationMs = 0;
        fsm.onPointerDown(0, 1, 500, 250, 3100, env);
        fsm.onTick(3600);
        check(spy.boostStarts == 0, "Live stream blocks long-press speed boost");
        fsm.onPointerMove(0, 1, 600, 250, 3650, env);
        check(
                fsm.getState() != State.HORIZONTAL_SEEK && spy.seekBegins == 0,
                "Live stream blocks horizontal seek");
    }

    private static void testStartSpecDualChannelFusionAndAntiOverlap() {
        // 960x540 video on "4K专线" line MUST NOT mislabel 4K!
        List<StartSpecBanner.Badge> lowRes =
                StartSpecBanner.fuseSpecBadges(
                        Arrays.asList("H.264", "AAC"), 960, 540, "4K专线 · 超清", "第01集 4K");
        boolean has4k = false;
        boolean hasSd = false;
        for (StartSpecBanner.Badge b : lowRes) {
            if ("4K".equals(b.label)) has4k = true;
            if ("SD".equals(b.label)) hasSd = true;
        }
        check(
                !has4k && hasSd,
                "Dual-channel fusion prevents 960x540 stream on '4K专线' from mislabeling 4K");

        // 3840x2160 stream with DV + Atmos + REMUX metadata -> 4K, DV · ATMOS, REMUX, HEVC (<= 5)
        List<StartSpecBanner.Badge> uhd =
                StartSpecBanner.fuseSpecBadges(
                        Arrays.asList("Dolby Vision", "Dolby Atmos", "HEVC"),
                        3840,
                        2160,
                        "原盘 REMUX 专线",
                        "S01E01");
        List<String> labels = new ArrayList<>();
        for (StartSpecBanner.Badge b : uhd) labels.add(b.label);
        check(
                labels.contains("4K")
                        && labels.contains("DV · ATMOS")
                        && labels.contains("REMUX")
                        && labels.contains("HEVC")
                        && labels.size() <= StartSpecBanner.MAX_BADGES,
                "Dual-channel fusion combines DV + Atmos into DV · ATMOS and preserves 4K/REMUX");

        // Anti-overlap safe margins
        int[] hiddenMargins = StartSpecBanner.computeSafeMargins(40, 24, 120, false, 1.0f);
        check(
                hiddenMargins[0] == 52 && hiddenMargins[1] == 36,
                "StartSpecBanner hidden-controls margins respect safeLeft+12dp and safeTop+12dp");
        int[] visibleMargins = StartSpecBanner.computeSafeMargins(40, 24, 120, true, 1.0f);
        check(
                visibleMargins[1] == 130,
                "StartSpecBanner visible-controls margin shifts below topHeaderBottom+10dp");
    }

    private static void testSkipCountdownControllerAndTvKeyRouting() {
        SkipCountdownPill.Controller ctl = new SkipCountdownPill.Controller();
        ctl.start(true, 95_000, 1000L, true);
        check(
                ctl.isActive()
                        && ctl.isIntro()
                        && ctl.ownsTvFocus()
                        && ctl.getRemainingSecondsCeil() == 3,
                "SkipCountdown starts 3s active countdown owning TV focus");
        check(!ctl.tick(2500L) && ctl.getRemainingSecondsCeil() == 2, "Countdown at 1.5s shows 2s");
        check(
                ctl.tick(4000L)
                        && !ctl.isActive()
                        && !ctl.ownsTvFocus()
                        && ctl.getState() == SkipCountdownPill.Controller.STATE_SKIPPED,
                "Countdown expires at 3000ms and releases TV focus");

        // Cancel via TV directional/back keys
        ctl.start(false, 2_500_000, 5000L, true);
        check(
                SkipCountdownPill.Controller.classifyTvKey(KeyEvent.KEYCODE_DPAD_CENTER) == 1
                        && SkipCountdownPill.Controller.classifyTvKey(KeyEvent.KEYCODE_ENTER) == 1,
                "TV confirm keys map to immediate skip");
        check(
                SkipCountdownPill.Controller.classifyTvKey(KeyEvent.KEYCODE_BACK) == -1
                        && SkipCountdownPill.Controller.classifyTvKey(KeyEvent.KEYCODE_DPAD_LEFT)
                                == -1
                        && SkipCountdownPill.Controller.classifyTvKey(KeyEvent.KEYCODE_DPAD_UP)
                                == -1,
                "TV directional and Back keys map to immediate cancel");
        check(
                ctl.cancel()
                        && !ctl.isActive()
                        && !ctl.ownsTvFocus()
                        && ctl.getState() == SkipCountdownPill.Controller.STATE_CANCELLED,
                "Canceling countdown clears active state and releases TV focus");
    }

    private static void testSleepTimerControllerPresetsWarningExtendAndExpiry() {
        SleepTimerSheet.Controller sleep = new SleepTimerSheet.Controller();
        check(!sleep.isActive() && sleep.getMode() == SleepTimerSheet.MODE_OFF, "Cold-start OFF");

        sleep.selectPreset(SleepTimerSheet.MODE_15M, 10_000L);
        check(
                sleep.isActive() && sleep.remainingMs(10_000L) == 900_000L,
                "15m preset schedules 900,000ms countdown");
        check(
                !sleep.shouldShowPreExpiryWarning(10_000L + 869_000L),
                "No pre-expiry warning at 31s remaining");
        check(
                sleep.shouldShowPreExpiryWarning(10_000L + 870_000L),
                "Pre-expiry warning triggers at <= 30s remaining");

        // Extend 15 minutes
        sleep.extend15Minutes(10_000L + 875_000L);
        check(
                !sleep.shouldShowPreExpiryWarning(10_000L + 875_000L)
                        && sleep.remainingMs(10_000L + 875_000L) == 925_000L,
                "Extending sleep timer adds 15 minutes and dismisses warning");

        // Expiry
        check(
                sleep.tick(10_000L + 1_800_000L) && !sleep.isActive() && sleep.isExpired(),
                "Sleep timer expires at deadline and turns off");

        // End of episode mode
        sleep.selectPreset(SleepTimerSheet.MODE_END_OF_EPISODE, 5_000_000L);
        check(
                sleep.isEndOfEpisodeMode() && !sleep.tick(9_000_000L),
                "End-of-episode mode does not expire on wall clock");
        check(
                sleep.onEpisodeCompleted() && !sleep.isActive(),
                "End-of-episode mode triggers cleanly on episode completion");
    }

    private static void testPrefsNormalizersAndScrubFormatting() {
        check(
                PlayerHudPrefs.CENTER_PLAY_PAUSE.equals(
                        PlayerHudPrefs.normalizeDoubleTapCenter("invalid")),
                "Unknown doubleTapCenter falls back to play_pause");
        check(
                PlayerHudPrefs.SIDES_SEEK_10S.equals(
                        PlayerHudPrefs.normalizeDoubleTapSides("invalid")),
                "Unknown doubleTapSides falls back to seek_10s");
        check(
                PlayerHudPrefs.RESTORE_PREVIOUS.equals(
                        PlayerHudPrefs.normalizeLongPressRestoreMode("invalid")),
                "Unknown longPressRestoreMode falls back to previous");
        check(
                "1:05:09".equals(FastForwardScrubCapsule.formatClock(3_909_000))
                        && "+00:45".equals(FastForwardScrubCapsule.formatSignedOffset(45_000))
                        && "-01:30".equals(FastForwardScrubCapsule.formatSignedOffset(-90_000)),
                "TV scrub capsule formats hours, minutes, and signed offsets accurately");
        // Verify null-safe fallback for empty track badges
        check(
                StartSpecBanner.fuseSpecBadges(Collections.emptyList(), 0, 0, "", "").isEmpty(),
                "Empty track & metadata fusion returns empty list safely");
    }

    private static void testRound2Regressions() {
        // 1. Slow stationary tap (260ms <= elapsed < 350ms) toggles controls instead of dropping
        Spy slowSpy = new Spy();
        PlayerGestureStateMachine slowFsm = new PlayerGestureStateMachine(slowSpy);
        Env env = defaultEnv();
        slowFsm.onPointerDown(0, 1, 500, 250, 1000, env);
        slowFsm.onPointerUp(0, 502, 251, 1300, env);
        check(
                slowSpy.singleTaps == 1 && slowFsm.getState() == State.IDLE,
                "Slow stationary tap (300ms, 260..350ms) fires single-tap instead of dropping");

        // 2. isSpeedBoostActive / isAnySpeedOverrideActive across boost, lock-ready, locked, pause
        Spy spdSpy = new Spy();
        PlayerGestureStateMachine spdFsm = new PlayerGestureStateMachine(spdSpy);
        env.userNormalSpeed = 1.25f;
        check(
                !spdFsm.isSpeedBoostActive() && !spdFsm.isAnySpeedOverrideActive(),
                "Idle FSM reports no active speed override");
        spdFsm.onPointerDown(0, 1, 500, 300, 2000, env);
        spdFsm.onTick(2350);
        check(
                spdFsm.isSpeedBoostActive() && spdFsm.isAnySpeedOverrideActive(),
                "LONG_PRESS_SPEED reports both speedBoostActive and anySpeedOverrideActive");
        spdFsm.onPointerMove(0, 1, 500, 240, 2400, env);
        check(
                spdFsm.isSpeedBoostActive() && spdFsm.isAnySpeedOverrideActive(),
                "SPEED_LOCK_READY reports both speedBoostActive and anySpeedOverrideActive");
        spdFsm.onPointerUp(0, 500, 240, 2450, env);
        check(
                !spdFsm.isSpeedBoostActive()
                        && spdFsm.isSpeedLocked()
                        && spdFsm.isAnySpeedOverrideActive(),
                "SPEED_LOCKED reports speedLocked & anySpeedOverrideActive");
        // External pause / audio-focus loss unlocks SPEED_LOCKED and restores 1.25x
        spdFsm.cancel(InterruptReason.PLAYBACK_PAUSED, 3000);
        check(
                !spdFsm.isAnySpeedOverrideActive()
                        && spdFsm.getState() == State.IDLE
                        && Math.abs(spdSpy.lastUnlockedSpeed - 1.25f) < 0.001f,
                "PLAYBACK_PAUSED auto-unlocks SPEED_LOCKED and restores userNormalSpeed");

        // 3. Outro skip honors end-of-episode sleep timer once, preventing episode advance
        SleepTimerSheet.Controller sleep = new SleepTimerSheet.Controller();
        sleep.selectPreset(SleepTimerSheet.MODE_END_OF_EPISODE, 1000L);
        check(
                sleep.onEpisodeCompleted() && !sleep.isActive() && !sleep.onEpisodeCompleted(),
                "End-of-episode sleep timer fires once on outro skip and does not double-fire");
    }

    private static String readSourceFile(String relativePath) {
        try {
            return new String(Files.readAllBytes(Paths.get(relativePath)), StandardCharsets.UTF_8);
        } catch (Exception e) {
            throw new AssertionError("Failed reading source: " + relativePath, e);
        }
    }

    private static void testGate1_S01_MultiTouchCrossViewOrphanGuard() {
        Spy spy = new Spy();
        PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
        Env env = defaultEnv();
        env.userNormalSpeed = 1.25f;

        // 1. Multi-touch during active LONG_PRESS_SPEED cancels and restores userNormalSpeed
        fsm.onPointerDown(0, 1, 500, 250, 1000, env);
        fsm.onTick(1350, env);
        check(
                fsm.getState() == State.LONG_PRESS_SPEED,
                "S-01 precondition: active LONG_PRESS_SPEED at 2.0x");
        fsm.onPointerMove(0, 2, 500, 250, 1400, env);
        check(
                fsm.getState() == State.IDLE
                        && !fsm.isAnySpeedOverrideActive()
                        && spy.boostEnds == 1
                        && spy.lastBoostEndCancelled
                        && Math.abs(spy.lastRestoredSpeed - 1.25f) < 0.001f,
                "S-01: multi-touch during LONG_PRESS_SPEED cancels and restores 1.25x");

        // 2. Orphaned active gesture cleared defensively if a fresh single-finger ACTION_DOWN
        // arrives after a child view swallowed prior stream
        Spy orphanSpy = new Spy();
        PlayerGestureStateMachine orphanFsm = new PlayerGestureStateMachine(orphanSpy);
        orphanFsm.onPointerDown(0, 1, 500, 250, 2000, env);
        orphanFsm.onTick(2350, env);
        check(
                orphanFsm.getState() == State.LONG_PRESS_SPEED,
                "S-01 precondition: LONG_PRESS_SPEED active before fresh DOWN");
        orphanFsm.onPointerDown(1, 1, 500, 250, 2600, env);
        check(
                orphanSpy.boostEnds == 1
                        && orphanSpy.lastBoostEndCancelled
                        && orphanFsm.getState() == State.DOWN_PENDING,
                "S-01: fresh ACTION_DOWN defensively clears any orphaned LONG_PRESS_SPEED");

        // 3. Verify motion event splitting is disabled and child controls proactively cancel
        String touchSrc =
                readSourceFile(
                        "android-mobile/src/main/java/com/pilipala/marcomovie/TouchPlayerGesture.java");
        String chromeSrc =
                readSourceFile(
                        "android-mobile/src/main/java/com/pilipala/marcomovie/PlayerChrome.java");
        String controlsSrc =
                readSourceFile(
                        "android-mobile/src/main/java/com/pilipala/marcomovie/PlaybackControls.java");
        check(
                touchSrc.contains("setMotionEventSplittingEnabled(false)")
                        && touchSrc.contains("disableMotionEventSplitting(activity.root)")
                        && touchSrc.contains("disableMotionEventSplitting(activity.playbackLayer)"),
                "S-01: TouchPlayerGesture disables motion event splitting on root & playbackLayer");
        check(
                chromeSrc.contains("overlay.setMotionEventSplittingEnabled(false)")
                        && chromeSrc.contains("cancelActiveTouchGesture()"),
                "S-01: PlayerChrome disables splitting and cancels active gesture on child taps");
        check(
                controlsSrc.contains("dockOverlay.setMotionEventSplittingEnabled(false)")
                        && controlsSrc.contains("a.touchPlayerGesture.cancelActiveGesture()"),
                "S-01: PlaybackControls disables splitting and cancels gesture on seekbar/button");
    }

    private static void testGate1_S02_BufferingNotPausedAndHoldTickRecheck() {
        // 1. Media3 STATE_BUFFERING with playWhenReady=true and no suppression MUST stay intended
        check(
                PlaybackStateProbe.isPlaybackIntended(
                        true,
                        true,
                        true,
                        PlaybackStateProbe.STATE_BUFFERING,
                        PlaybackStateProbe.SUPPRESSION_NONE,
                        false),
                "S-02: Media3 STATE_BUFFERING with playWhenReady=true is NOT mistaken for paused");
        check(
                PlaybackStateProbe.isPlaybackIntended(
                        true,
                        true,
                        true,
                        PlaybackStateProbe.STATE_READY,
                        PlaybackStateProbe.SUPPRESSION_NONE,
                        true),
                "S-02: Media3 STATE_READY with playWhenReady=true is intended to play");

        // 2. Transient audio-focus loss or playWhenReady=false or STATE_ENDED MUST report paused
        PlaybackStateProbe.Snapshot focusLostSnap =
                new PlaybackStateProbe.Snapshot(
                        true,
                        true,
                        PlaybackStateProbe.STATE_READY,
                        PlaybackStateProbe.SUPPRESSION_TRANSIENT_AUDIO_FOCUS_LOSS,
                        false);
        check(
                !PlaybackStateProbe.isPlaybackIntended(true, focusLostSnap)
                        && PlaybackStateProbe.isAudioFocusSuppressed(focusLostSnap),
                "S-02: transient audio-focus suppression reports not intended & focus suppressed");
        check(
                !PlaybackStateProbe.isPlaybackIntended(
                        true,
                        true,
                        false,
                        PlaybackStateProbe.STATE_READY,
                        PlaybackStateProbe.SUPPRESSION_NONE,
                        false),
                "S-02: playWhenReady=false reports paused even if activityPlaying flag is stale");
        check(
                !PlaybackStateProbe.isPlaybackIntended(
                        true,
                        true,
                        true,
                        PlaybackStateProbe.STATE_ENDED,
                        PlaybackStateProbe.SUPPRESSION_NONE,
                        false),
                "S-02: STATE_ENDED reports not playing");

        // 3. handleFsmTick() at 350ms with refreshed Env (playing=false due to audio-focus loss
        // after ACTION_DOWN) MUST NOT enter LONG_PRESS_SPEED
        Spy spy = new Spy();
        PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
        Env downEnv = defaultEnv();
        downEnv.playing = true;
        fsm.onPointerDown(0, 1, 500, 250, 1000, downEnv);
        check(
                fsm.getState() == State.DOWN_PENDING && fsm.isLongPressArmed(),
                "S-02 precondition: long-press armed on ACTION_DOWN while playing");
        Env tickEnv = defaultEnv();
        tickEnv.playing = false;
        fsm.onTick(1350, tickEnv);
        check(
                fsm.getState() == State.DOWN_PENDING && spy.boostStarts == 0,
                "S-02: 350ms tick with refreshed playing=false never boosts to 2.0x");
    }

    private static void testGate1_S03_SkipCountdownSilentCancelOnPauseBackgroundCallPipLock() {
        // 1. Lifecycle guard matrix
        check(
                PlaybackStateProbe.canRunSkipCountdown(
                        true, false, false, false, true, true, false, false),
                "S-03: skip countdown allowed in foreground active playback");
        check(
                !PlaybackStateProbe.canRunSkipCountdown(
                        true, false, false, false, true, false, false, false),
                "S-03: skip countdown blocked on pause / audio-focus loss");
        check(
                !PlaybackStateProbe.canRunSkipCountdown(
                        false, false, false, false, true, true, false, false),
                "S-03: skip countdown blocked in background (!foreground)");
        check(
                !PlaybackStateProbe.canRunSkipCountdown(
                        true, false, true, false, true, true, false, false),
                "S-03: skip countdown blocked in PiP");
        check(
                !PlaybackStateProbe.canRunSkipCountdown(
                        true, true, false, false, true, true, false, false),
                "S-03: skip countdown blocked in miniMode");
        check(
                !PlaybackStateProbe.canRunSkipCountdown(
                        true, false, false, true, true, true, false, false),
                "S-03: skip countdown blocked on screen lock");

        // 2. Controller guard silently resets (STATE_IDLE, NOT STATE_CANCELLED) and blocks expiry
        SkipCountdownPill.Controller ctl = new SkipCountdownPill.Controller();
        ctl.start(false, 2_400_000, 1000L, true);
        check(
                !ctl.guardPlaybackCondition(false)
                        && !ctl.isActive()
                        && ctl.getState() == SkipCountdownPill.Controller.STATE_IDLE
                        && !ctl.ownsTvFocus(),
                "S-03: lifecycle guard silently resets outro countdown without marking cancelled");
        check(
                !ctl.tick(5000L) && ctl.getState() == SkipCountdownPill.Controller.STATE_IDLE,
                "S-03: silently dismissed countdown never auto-triggers step(1) at 3000ms");

        // 3. Re-evaluating cleanly after returning to foreground playback starts fresh countdown
        ctl.start(false, 2_400_000, 6000L, true);
        check(
                ctl.isActive() && ctl.guardPlaybackCondition(true) && ctl.tick(9000L),
                "S-03: foreground resume re-evaluates and completes outro skip cleanly");
    }

    private static void testGate1_S05_TvSkipCountdownStartupFocusShowControlsAndBackRepeatGuard() {
        // 1. TV takes focus even when controlsVisible == true on startup/autoplay
        check(
                SkipCountdownPill.Controller.shouldTakeTvFocus(true, false),
                "S-05: TV startup skip pill takes TV focus even when controlsVisible == true");
        check(
                !SkipCountdownPill.Controller.shouldTakeTvFocus(true, true),
                "S-05: TV skip pill yields when another modal dialog is already open");
        check(
                !SkipCountdownPill.Controller.shouldTakeTvFocus(false, false),
                "S-05: mobile touch skip pill never takes TV dialog focus");

        // 2. OK / Confirm skips on UP and freezes timer during hold
        SkipCountdownPill.Controller okCtl = new SkipCountdownPill.Controller();
        okCtl.start(true, 90_000, 1000L, true);
        check(
                okCtl.handleTvKeyEvent(KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.ACTION_DOWN, 0)
                                == SkipCountdownPill.Controller.KEY_CONSUMED
                        && okCtl.isActive(),
                "S-05: TV OK ACTION_DOWN is consumed while keeping pill active");
        check(
                okCtl.handleTvKeyEvent(KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.ACTION_UP, 0)
                                == SkipCountdownPill.Controller.KEY_COMMIT_SKIP
                        && okCtl.getState() == SkipCountdownPill.Controller.STATE_SKIPPED
                        && !okCtl.ownsTvFocus(),
                "S-05: TV OK ACTION_UP immediately commits skip and releases TV focus");

        // 3. Long-press Back (repeatCount >= 1) swallows ALL repeats and cancels only on ACTION_UP
        SkipCountdownPill.Controller backCtl = new SkipCountdownPill.Controller();
        backCtl.start(true, 90_000, 2000L, true);
        check(
                backCtl.handleTvKeyEvent(KeyEvent.KEYCODE_BACK, KeyEvent.ACTION_DOWN, 0)
                                == SkipCountdownPill.Controller.KEY_CONSUMED
                        && backCtl.ownsTvFocus(),
                "S-05: TV Back ACTION_DOWN(repeat=0) consumed while keeping dialogOpen/focus");
        check(
                backCtl.handleTvKeyEvent(KeyEvent.KEYCODE_BACK, KeyEvent.ACTION_DOWN, 1)
                                == SkipCountdownPill.Controller.KEY_CONSUMED
                        && backCtl.handleTvKeyEvent(KeyEvent.KEYCODE_BACK, KeyEvent.ACTION_DOWN, 2)
                                == SkipCountdownPill.Controller.KEY_CONSUMED
                        && backCtl.ownsTvFocus(),
                "S-05: TV Back repeatCount >= 1 is swallowed so it never leaks to PiP/exit");
        check(
                !backCtl.tick(6000L) && backCtl.isActive(),
                "S-05: countdown does not auto-skip while Back key is held down");
        check(
                backCtl.handleTvKeyEvent(KeyEvent.KEYCODE_BACK, KeyEvent.ACTION_UP, 0)
                                == SkipCountdownPill.Controller.KEY_COMMIT_CANCEL
                        && backCtl.getState() == SkipCountdownPill.Controller.STATE_CANCELLED
                        && !backCtl.ownsTvFocus(),
                "S-05: TV Back ACTION_UP cancels countdown cleanly and releases dialogOpen/focus");

        // 4. D-pad key cancels on UP without leaking repeat into SeekGesture
        SkipCountdownPill.Controller dpadCtl = new SkipCountdownPill.Controller();
        dpadCtl.start(true, 90_000, 7000L, true);
        check(
                dpadCtl.handleTvKeyEvent(KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.ACTION_DOWN, 0)
                                == SkipCountdownPill.Controller.KEY_CONSUMED
                        && dpadCtl.handleTvKeyEvent(
                                        KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.ACTION_DOWN, 1)
                                == SkipCountdownPill.Controller.KEY_CONSUMED
                        && dpadCtl.handleTvKeyEvent(
                                        KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.ACTION_UP, 0)
                                == SkipCountdownPill.Controller.KEY_COMMIT_CANCEL,
                "S-05: TV D-pad cancels pill cleanly on UP without leaking repeats to seek");

        // 5. F-A1: external controls shown / focus loss while playing MUST cancel (STATE_CANCELLED)
        // so tick() never respawns the pill or steals focus back 1s later; when paused/suspended,
        // it silently resets (STATE_IDLE) so foreground resume can re-evaluate.
        SkipCountdownPill.Controller extActiveCtl = new SkipCountdownPill.Controller();
        extActiveCtl.start(false, 2_400_000, 8000L, true);
        check(
                extActiveCtl.dismissOnExternalControlsOrFocusLoss(true)
                                == SkipCountdownPill.Controller.STATE_CANCELLED
                        && extActiveCtl.getState() == SkipCountdownPill.Controller.STATE_CANCELLED
                        && !extActiveCtl.isActive()
                        && !extActiveCtl.ownsTvFocus(),
                "F-A1: external controls/focus loss while playing cancels (STATE_CANCELLED) to prevent respawn");
        SkipCountdownPill.Controller extPausedCtl = new SkipCountdownPill.Controller();
        extPausedCtl.start(false, 2_400_000, 9000L, true);
        check(
                extPausedCtl.dismissOnExternalControlsOrFocusLoss(false)
                                == SkipCountdownPill.Controller.STATE_IDLE
                        && extPausedCtl.getState() == SkipCountdownPill.Controller.STATE_IDLE
                        && !extPausedCtl.isActive()
                        && !extPausedCtl.ownsTvFocus(),
                "F-A1: external controls/focus loss while paused silently suspends (STATE_IDLE)");

        // 6. F-A1: TV hardware MEDIA_PLAY_PAUSE / MEDIA_PAUSE / MEDIA_PLAY and MENU keys work
        // while SkipCountdownPill holds dialogOpen == true
        SkipCountdownPill.Controller mediaCtl = new SkipCountdownPill.Controller();
        mediaCtl.start(false, 2_400_000, 10_000L, true);
        check(
                mediaCtl.handleTvKeyEvent(
                                        KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.ACTION_DOWN, 0)
                                == SkipCountdownPill.Controller.KEY_MEDIA_PLAYBACK
                        && mediaCtl.handleTvKeyEvent(
                                        KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.ACTION_DOWN, 1)
                                == SkipCountdownPill.Controller.KEY_CONSUMED
                        && mediaCtl.handleTvKeyEvent(
                                        KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.ACTION_UP, 0)
                                == SkipCountdownPill.Controller.KEY_CONSUMED,
                "F-A1: TV MEDIA_PLAY_PAUSE forwards on DOWN(repeat=0) and swallows repeats/UP");
        check(
                mediaCtl.handleTvKeyEvent(KeyEvent.KEYCODE_MEDIA_PAUSE, KeyEvent.ACTION_DOWN, 0)
                                == SkipCountdownPill.Controller.KEY_MEDIA_PLAYBACK
                        && mediaCtl.handleTvKeyEvent(
                                        KeyEvent.KEYCODE_MEDIA_PLAY, KeyEvent.ACTION_DOWN, 0)
                                == SkipCountdownPill.Controller.KEY_MEDIA_PLAYBACK,
                "F-A1: TV MEDIA_PAUSE and MEDIA_PLAY forward cleanly during active countdown");
        SkipCountdownPill.Controller menuCtl = new SkipCountdownPill.Controller();
        menuCtl.start(true, 90_000, 11_000L, true);
        check(
                menuCtl.handleTvKeyEvent(KeyEvent.KEYCODE_MENU, KeyEvent.ACTION_DOWN, 0)
                                == SkipCountdownPill.Controller.KEY_CONSUMED
                        && menuCtl.handleTvKeyEvent(KeyEvent.KEYCODE_MENU, KeyEvent.ACTION_DOWN, 1)
                                == SkipCountdownPill.Controller.KEY_CONSUMED
                        && menuCtl.isActive(),
                "F-A1: TV KEYCODE_MENU ACTION_DOWN consumes repeats while holding focus");
        check(
                menuCtl.handleTvKeyEvent(KeyEvent.KEYCODE_MENU, KeyEvent.ACTION_UP, 0)
                                == SkipCountdownPill.Controller.KEY_COMMIT_MENU
                        && menuCtl.getState() == SkipCountdownPill.Controller.STATE_CANCELLED
                        && !menuCtl.ownsTvFocus(),
                "F-A1: TV KEYCODE_MENU ACTION_UP cancels countdown and routes to TV primary menu");
    }

    private static void testGate1_M01_ScreenLockUnlocksSpeedLockedAndPreservesNoticeTimer() {
        Spy spy = new Spy();
        PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
        Env env = defaultEnv();
        env.userNormalSpeed = 1.25f;

        // Enter SPEED_LOCKED at 2.0x
        fsm.onPointerDown(0, 1, 500, 300, 1000, env);
        fsm.onTick(1350, env);
        fsm.onPointerMove(0, 1, 500, 240, 1400, env);
        fsm.onPointerUp(0, 500, 240, 1450, env);
        check(
                fsm.getState() == State.SPEED_LOCKED && fsm.isSpeedLocked(),
                "M-01 precondition: SPEED_LOCKED active before locking screen");

        // Immediate screen lock request unlocks SPEED_LOCKED and transitions directly to
        // LOCKED_IDLE
        fsm.cancel(InterruptReason.SCREEN_LOCKED, 1500);
        check(
                fsm.getState() == State.LOCKED_IDLE
                        && !fsm.isSpeedLocked()
                        && spy.speedUnlocks == 1
                        && Math.abs(spy.lastUnlockedSpeed - 1.25f) < 0.001f,
                "M-01: locking screen immediately unlocks SPEED_LOCKED and enters LOCKED_IDLE");

        // Notice preservation invariant: SCREEN_LOCKED preserves active brief notice hide timer
        check(
                TouchPlayerGesture.shouldPreserveNoticeOnCancel(
                        InterruptReason.SCREEN_LOCKED, true),
                "M-01: SCREEN_LOCKED preserves active brief-notice auto-hide runnable");
        check(
                !TouchPlayerGesture.shouldShowUnlockNotice(InterruptReason.SCREEN_LOCKED),
                "M-01: SCREEN_LOCKED suppresses redundant speed-restore toast");
        check(
                !TouchPlayerGesture.shouldPreserveNoticeOnCancel(InterruptReason.EXIT_PLAYER, true),
                "M-01: EXIT_PLAYER cancels brief-notice runnable cleanly");
    }

    private static void testGate1_M02_SplitScreenLocalCoordsAndApi29SystemGestureInsets() {
        // 1. Split-screen / freeform local coordinates (window 500x500 positioned at raw 540,960)
        Spy spy = new Spy();
        PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
        Env splitEnv = defaultEnv();
        splitEnv.density = 1.0f;
        splitEnv.screenWidthPx = 500f;
        splitEnv.screenHeightPx = 500f;
        // Raw screen coords (790, 1210) would fail edge guard, while view-local (250, 250) succeeds
        check(
                PlayerGestureStateMachine.isInEdgeOrSystemGuard(790f, 1210f, splitEnv),
                "M-02 precondition: raw screen coords > split window fail edge guard");
        check(
                !PlayerGestureStateMachine.isInEdgeOrSystemGuard(250f, 250f, splitEnv)
                        && fsm.onPointerDown(0, 1, 250f, 250f, 1000L, splitEnv),
                "M-02: view-local coords relative to a.root work 100% in split-screen windows");

        // 2. API 29 system gesture inset merging overrides zero chrome side insets
        Env api29Env = defaultEnv();
        api29Env.density = 1.0f;
        api29Env.screenWidthPx = 1000f;
        api29Env.screenHeightPx = 500f;
        TouchPlayerGesture.mergeSystemGestureInsets(api29Env, 0, 24, 0, 20, 44, 0, 44, 32);
        check(
                api29Env.systemGestureInsetLeftPx == 44f
                        && api29Env.systemGestureInsetRightPx == 44f
                        && api29Env.systemInsetTopPx == 24f
                        && api29Env.systemInsetBottomPx == 32f,
                "M-02: mergeSystemGestureInsets combines API 29 system gesture insets via max()");
        check(
                PlayerGestureStateMachine.isInEdgeOrSystemGuard(35f, 250f, api29Env)
                        && PlayerGestureStateMachine.isInEdgeOrSystemGuard(965f, 250f, api29Env),
                "M-02: API 29 44px side gesture inset guards touches at 35px / width-35px");

        // 3. F-A2: consistent Window-space HUD hit-exclusion in bottom-half split-screen & freeform
        // Bottom-half split-screen (1080x2400 phone, windowTop=1200, window height=1200):
        // a.root globalVisibleRect=(0,0..1080,1200), progress bar
        // globalVisibleRect=(20,1080..1060,1180).
        // Touching progress at local (500, 1120) [rawY=2320] MUST hit progress; touching empty
        // upper video at local (500, 100) [rawY=1300] MUST NOT falsely hit progress!
        check(
                TouchPlayerGesture.isLocalTouchInsideWindowRect(
                        500f, 1120f, 0, 0, 20, 1080, 1060, 1180),
                "F-A2: bottom-half split-screen touch on progress bar hits Window-space HUD rect");
        check(
                !TouchPlayerGesture.isLocalTouchInsideWindowRect(
                        500f, 100f, 0, 0, 20, 1000, 1060, 1200),
                "F-A2: freeform upper video touch (localY=100, rawY=1100) does not hit bottom HUD");
        check(
                TouchPlayerGesture.isLocalTouchInsideWindowRect(
                                200f, 420f, 40, 120, 100, 500, 400, 600)
                        && !TouchPlayerGesture.isLocalTouchInsideWindowRect(
                                200f, 300f, 40, 120, 100, 500, 400, 600),
                "F-A2: non-zero rootGlobalLeft/Top offset maps local coords cleanly into Window rect");

        // Verify TouchPlayerGesture uses event.getX()/getY() for FSM & Window-space HUD hit tests
        String touchSrc =
                readSourceFile(
                        "android-mobile/src/main/java/com/pilipala/marcomovie/TouchPlayerGesture.java");
        check(
                touchSrc.contains("event.getX()")
                        && touchSrc.contains("event.getY()")
                        && touchSrc.contains("getSystemGestureInsets()")
                        && touchSrc.contains("isLocalTouchInsideWindowRect(")
                        && !touchSrc.contains("isTouchInsideControls(rawX"),
                "M-02/F-A2: TouchPlayerGesture uses view-local coords + Window-space hit rects + API 29 insets");
    }

    private static void testGate1_M07_SlimProgressToggleDecoupledFromHorizontalSeekPreview() {
        check(
                PlayerChrome.resolveProgressOnlyMode(true, false),
                "M-07: disabling player_slim_progress still allows progress-only horizontal seek");
        check(
                !PlayerChrome.resolveProgressOnlyMode(false, true),
                "M-07: non-progress-only mode remains full controls");
        check(
                !PlayerChrome.shouldShowSlimProgressBar(false, false, false, true, 600_000, false),
                "M-07: 2dp SlimProgressBar stays hidden when player_slim_progress is disabled");
        check(
                PlayerChrome.shouldShowSlimProgressBar(false, false, false, true, 600_000, true),
                "M-07: 2dp SlimProgressBar shows when player_slim_progress is enabled & HUD hidden");
    }

    private static void testGate1_M08_SleepTimerTvReachabilityMobileSafeTopAndSessionReset() {
        // (a) TV WarningPill D-pad Up reachability
        check(
                SleepTimerSheet.resolveActionUpFocusId(true, 9001, 1001) == 9001,
                "M-08(a): visible WarningPill overrides self-locked modernTv nextFocusUpId");
        check(
                SleepTimerSheet.resolveActionUpFocusId(false, 9001, 1001) == 1001,
                "M-08(a): hidden WarningPill restores fallback nextFocusUpId");

        // (b) Mobile safe.top inset avoids notch/status bar clipping
        check(
                SleepTimerSheet.computeWarningTopMarginPx(false, 88, 2.0f) == 124,
                "M-08(b): mobile sleepWarningPill topMargin adds safe.top (88 + 18dp*2 = 124px)");
        check(
                SleepTimerSheet.computeWarningTopMarginPx(false, 0, 2.0f) == 36,
                "M-08(b): mobile sleepWarningPill keeps 18dp base when safe.top is 0");
        check(
                SleepTimerSheet.computeWarningTopMarginPx(true, 88, 2.0f) == 48,
                "M-08(b): TV sleepWarningPill preserves 24dp topMargin");

        // (c) Session-scoped sleep timer cleanup on exit/detach/new session
        SleepTimerSheet.Controller sleep = new SleepTimerSheet.Controller();
        sleep.selectPreset(SleepTimerSheet.MODE_15M, 10_000L);
        // Exiting playback (not an in-place switch) immediately clears timer
        sleep.onPlayerSessionClosed(false);
        check(
                !sleep.isActive() && !sleep.tick(2_000_000L),
                "M-08(c): leaving playback clears sleep timer so a later video never pauses");

        // Re-arm and verify abandoned timer cannot pause a brand-new playback session
        sleep.selectPreset(SleepTimerSheet.MODE_15M, 10_000L);
        sleep.onNewPlaybackSession(false, 2_000_000L);
        check(
                !sleep.isActive() && !sleep.tick(2_000_001L),
                "M-08(c): new playback session without in-place switch resets stale sleep timer");

        // In-place episode switch preserves active unexpired timer
        sleep.selectPreset(SleepTimerSheet.MODE_15M, 10_000L);
        sleep.onPlayerSessionClosed(true);
        sleep.onNewPlaybackSession(true, 100_000L);
        check(
                sleep.isActive() && sleep.remainingMs(100_000L) == 810_000L,
                "M-08(c): in-place episode switch preserves unexpired session sleep timer");

        // Even an in-place switch whose timer already expired while loading cancels cleanly
        sleep.onNewPlaybackSession(true, 2_000_000L);
        check(
                !sleep.isActive() && !sleep.tick(2_000_001L),
                "M-08(c): already-expired timer on new playback session cancels instead of pausing");
    }

    private static void testGate1_L01_ExitPlayerSkipsUnlockNoticeAndOwnershipGuard() {
        check(
                !TouchPlayerGesture.shouldShowUnlockNotice(InterruptReason.EXIT_PLAYER),
                "L-01: EXIT_PLAYER skips showBriefNotice so hideNoticeRunnable is not re-posted");
        check(
                TouchPlayerGesture.shouldShowUnlockNotice(InterruptReason.PLAYBACK_PAUSED)
                        && TouchPlayerGesture.shouldShowUnlockNotice(
                                InterruptReason.EPISODE_SWITCH),
                "L-01: normal unlock reasons still display brief restore notice");

        Spy spy = new Spy();
        PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
        Env env = defaultEnv();
        env.userNormalSpeed = 1.25f;
        fsm.onPointerDown(0, 1, 500, 300, 1000, env);
        fsm.onTick(1350, env);
        fsm.onPointerMove(0, 1, 500, 240, 1400, env);
        fsm.onPointerUp(0, 500, 240, 1450, env);
        fsm.cancel(InterruptReason.EXIT_PLAYER, 1600);
        check(
                !fsm.isSpeedLocked()
                        && fsm.getState() == State.IDLE
                        && spy.speedUnlocks == 1
                        && Math.abs(spy.lastUnlockedSpeed - 1.25f) < 0.001f,
                "L-01: EXIT_PLAYER unlocks SPEED_LOCKED cleanly in FSM");

        String touchSrc =
                readSourceFile(
                        "android-mobile/src/main/java/com/pilipala/marcomovie/TouchPlayerGesture.java");
        check(
                touchSrc.contains("a.touchPlayerGesture == TouchPlayerGesture.this")
                        && touchSrc.contains("if (a.touchPlayerGesture != this) return;"),
                "L-01: TouchPlayerGesture verifies ownership before mutating shared UI/state");
    }
}
