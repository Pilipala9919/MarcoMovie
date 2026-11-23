package com.pilipala.marcomovie;

import android.content.pm.ActivityInfo;
import android.view.KeyEvent;

/**
 * Pure JVM regression checks for Android mobile/tablet playback screen lock: TV device exclusion,
 * active gesture cancellation, orientation locking, control overlay suppression, back-press
 * interception, hardware/keyboard key blocking, auto-hide unlock hint scheduling, and lifecycle
 * cleanup.
 */
public final class PlayerLockChecks {
    private static int checks;

    private static void check(boolean ok, String label) {
        if (!ok) {
            throw new AssertionError("FAILED: " + label);
        }
        checks++;
        System.out.println("PASS " + label);
    }

    private static void shutdownPools(MainActivity a) {
        a.worker.shutdownNow();
        a.details.shutdownNow();
        a.artwork.shutdownNow();
        a.phoneticWork.shutdownNow();
    }

    public static void main(String[] args) {
        testTvDeviceNeverLocks();
        testMobileLandscapeLockBlocksAllInteractions();
        testTabletPortraitLockAndOrientationRestore();
        testLeavePlaybackAndReleasePlayerCleanup();
        System.out.println("ALL PASS (" + checks + " Android player lock checks)");
    }

    private static void testTvDeviceNeverLocks() {
        MainActivity tv = new MainActivity();
        try {
            tv.formFactor = TvLayoutPolicy.FORM_TV;
            tv.usableWidth = 1920;
            tv.usableHeight = 1080;
            tv.privateMode = true;
            MainActivity.Screen playerScreen = new MainActivity.Screen(() -> {});
            playerScreen.player = true;
            tv.current = playerScreen;
            tv.controlsVisible = true;

            PlaybackController.setPlayerLocked(tv, true);
            check(
                    !tv.playerLocked && !PlaybackController.isPlayerLocked(tv),
                    "Android TV device ignores setPlayerLocked(true)");
            check(tv.controlsVisible, "Android TV controlsVisible remains untouched");

            tv.playerLocked = true;
            check(
                    !PlaybackController.isPlayerLocked(tv),
                    "isPlayerLocked returns false on Android TV even if flag were set");
            tv.playerLocked = false;
        } finally {
            shutdownPools(tv);
        }
    }

    private static void testMobileLandscapeLockBlocksAllInteractions() {
        MainActivity phone = new MainActivity();
        try {
            phone.formFactor = TvLayoutPolicy.FORM_PHONE;
            phone.usableWidth = 2400;
            phone.usableHeight = 1080;
            phone.privateMode = true;
            phone.prepared = true;
            phone.playing = true;
            phone.controlsVisible = true;

            final int[] detailRenders = {0};
            MainActivity.Screen detailScreen = new MainActivity.Screen(() -> detailRenders[0]++);
            phone.back.push(detailScreen);
            MainActivity.Screen playerScreen = new MainActivity.Screen(() -> {});
            playerScreen.player = true;
            phone.current = playerScreen;

            // Start an active seek gesture prior to locking
            phone.seekGesture.begin(1, 30_000, 120_000, 1000L);
            check(phone.seekGesture.active, "Precondition: seekGesture is active before lock");

            PlaybackController.setPlayerLocked(phone, true);
            check(
                    phone.playerLocked && PlaybackController.isPlayerLocked(phone),
                    "Phone enters locked state via setPlayerLocked(true)");
            check(
                    !phone.seekGesture.active,
                    "Locking cancels active seekGesture without committing jump");
            check(!phone.controlsVisible, "Locking immediately hides playback controls");
            check(
                    phone.getRequestedOrientation() == ActivityInfo.SCREEN_ORIENTATION_LOCKED,
                    "Locking pins screen orientation to SCREEN_ORIENTATION_LOCKED");
            check(
                    phone.hideLockButton != null && phone.ui.hasCallbacks(phone.hideLockButton),
                    "Locking schedules 3.5s auto-hide callback for floating unlock button");

            // Attempting to show controls while locked must keep controls hidden
            PlaybackController.showControls(phone, true);
            check(
                    !phone.controlsVisible,
                    "showControls(true) is suppressed while playback screen is locked");

            // Attempting to toggle orientation while locked must be ignored
            phone.togglePlayerOrientation();
            check(
                    phone.getRequestedOrientation() == ActivityInfo.SCREEN_ORIENTATION_LOCKED,
                    "togglePlayerOrientation() is blocked while playback screen is locked");

            // System back press / gesture navigation must be intercepted without leaving player
            phone.onBackPressed();
            check(
                    phone.current == playerScreen
                            && phone.back.size() == 1
                            && detailRenders[0] == 0
                            && phone.playerLocked,
                    "onBackPressed() is intercepted while locked and does not pop player screen");

            // Hardware / external keyboard keys must all be consumed without side effects
            int[] blockedKeys = {
                KeyEvent.KEYCODE_SPACE,
                KeyEvent.KEYCODE_DPAD_CENTER,
                KeyEvent.KEYCODE_DPAD_RIGHT,
                KeyEvent.KEYCODE_VOLUME_UP,
                KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
                KeyEvent.KEYCODE_BACK
            };
            for (int code : blockedKeys) {
                boolean downConsumed =
                        phone.dispatchKeyEvent(new KeyEvent(KeyEvent.ACTION_DOWN, code));
                boolean upConsumed = phone.dispatchKeyEvent(new KeyEvent(KeyEvent.ACTION_UP, code));
                check(
                        downConsumed && upConsumed,
                        "dispatchKeyEvent consumes keyCode=" + code + " while locked");
            }
            check(
                    phone.playing
                            && !phone.controlsVisible
                            && !phone.seekGesture.active
                            && phone.current == playerScreen,
                    "Blocked key events do not pause, reveal controls, seek, or exit playback");

            // Auto-hide runnable clears scheduled state cleanly, and revealLockedHint re-arms it
            Runnable scheduledHide = phone.hideLockButton;
            phone.ui.removeCallbacks(scheduledHide);
            scheduledHide.run();
            check(
                    !phone.ui.hasCallbacks(phone.hideLockButton),
                    "Auto-hide runnable hides unlock pill without leaving stale callbacks");
            PlaybackController.revealLockedHint(phone);
            check(
                    phone.hideLockButton != null && phone.ui.hasCallbacks(phone.hideLockButton),
                    "revealLockedHint re-schedules unlock button auto-hide timer");

            // Unlock restores landscape sensor orientation and reveals controls
            PlaybackController.setPlayerLocked(phone, false);
            check(
                    !phone.playerLocked && !PlaybackController.isPlayerLocked(phone),
                    "setPlayerLocked(false) clears lock state");
            check(
                    phone.getRequestedOrientation()
                            == ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE,
                    "Unlocking in landscape restores SCREEN_ORIENTATION_SENSOR_LANDSCAPE");
            check(phone.controlsVisible, "Unlocking restores playback controls visibility");
            check(
                    !phone.ui.hasCallbacks(phone.hideLockButton),
                    "Unlocking cancels pending hideLockButton timer");
        } finally {
            shutdownPools(phone);
        }
    }

    private static void testTabletPortraitLockAndOrientationRestore() {
        MainActivity tablet = new MainActivity();
        try {
            tablet.formFactor = TvLayoutPolicy.FORM_TABLET;
            tablet.usableWidth = 800;
            tablet.usableHeight = 1280;
            tablet.privateMode = true;
            MainActivity.Screen playerScreen = new MainActivity.Screen(() -> {});
            playerScreen.player = true;
            tablet.current = playerScreen;

            PlaybackController.setPlayerLocked(tablet, true);
            check(
                    tablet.playerLocked
                            && tablet.getRequestedOrientation()
                                    == ActivityInfo.SCREEN_ORIENTATION_LOCKED,
                    "Tablet portrait playback locks orientation to SCREEN_ORIENTATION_LOCKED");

            PlaybackController.setPlayerLocked(tablet, false);
            check(
                    !tablet.playerLocked
                            && tablet.getRequestedOrientation()
                                    == ActivityInfo.SCREEN_ORIENTATION_PORTRAIT,
                    "Unlocking in portrait restores SCREEN_ORIENTATION_PORTRAIT");
        } finally {
            shutdownPools(tablet);
        }
    }

    private static void testLeavePlaybackAndReleasePlayerCleanup() {
        MainActivity phone = new MainActivity();
        try {
            phone.formFactor = TvLayoutPolicy.FORM_PHONE;
            phone.usableWidth = 2400;
            phone.usableHeight = 1080;
            phone.privateMode = true;

            final int[] detailRenders = {0};
            MainActivity.Screen detailScreen = new MainActivity.Screen(() -> detailRenders[0]++);
            phone.back.push(detailScreen);
            MainActivity.Screen playerScreen = new MainActivity.Screen(() -> {});
            playerScreen.player = true;
            phone.current = playerScreen;

            PlaybackController.setPlayerLocked(phone, true);
            Runnable firstTimer = phone.hideLockButton;
            PlaybackController.leavePlayback(phone);
            check(
                    !phone.playerLocked
                            && phone.hideLockButton == null
                            && !phone.ui.hasCallbacks(firstTimer),
                    "leavePlayback clears playerLocked and removes hideLockButton callback");
            check(
                    phone.getRequestedOrientation() == ActivityInfo.SCREEN_ORIENTATION_USER
                            && phone.current == detailScreen
                            && detailRenders[0] == 1,
                    "leavePlayback restores user orientation and returns to previous screen");

            // Also verify direct releasePlayer cleanup
            phone.current = playerScreen;
            phone.usableWidth = 2400;
            phone.usableHeight = 1080;
            PlaybackController.setPlayerLocked(phone, true);
            Runnable secondTimer = phone.hideLockButton;
            PlaybackController.releasePlayer(phone);
            check(
                    !phone.playerLocked
                            && phone.hideLockButton == null
                            && !phone.ui.hasCallbacks(secondTimer),
                    "releasePlayer clears playerLocked and cancels hideLockButton timer");
        } finally {
            shutdownPools(phone);
        }
    }
}
