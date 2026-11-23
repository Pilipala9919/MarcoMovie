// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import java.nio.charset.Charset;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.List;

/** Offline JVM verification for OnboardingScreen and FirstPlayGestureHint state machines. */
public final class OnboardingStateChecks {
    private static int passed;

    private static void check(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError("FAILED: " + message);
        }
        passed++;
    }

    public static void main(String[] args) throws Exception {
        // 1. Fresh launch state and 5-act navigation
        OnboardingScreen.MemoryStore store = new OnboardingScreen.MemoryStore();
        check(
                OnboardingScreen.Controller.shouldShowOnLaunch(store),
                "Fresh store should show onboarding");

        OnboardingScreen.Controller ctrl = new OnboardingScreen.Controller(store);
        check(ctrl.getCurrentAct() == 0 && ctrl.isFirstAct(), "Starts at Act 1 (index 0)");
        check(!ctrl.previousAct(), "Cannot step before Act 1");
        for (int i = 1; i < OnboardingScreen.ACT_COUNT; i++) {
            check(ctrl.nextAct(), "Step forward to act " + i);
            check(ctrl.getCurrentAct() == i, "Current act equals " + i);
        }
        check(ctrl.isLastAct(), "Reached Act 5 (index 4)");
        check(!ctrl.nextAct(), "Cannot step past Act 5");

        // 2. Back key steps back on TV/mobile until Act 1, then skips & persists
        check(!ctrl.handleBack(), "Back on Act 5 steps to Act 4");
        check(ctrl.getCurrentAct() == 3, "Act is now 3");
        ctrl.goToAct(0);
        check(ctrl.handleBack(), "Back on Act 1 exits onboarding");
        check(ctrl.isFinished() && ctrl.isSkipped(), "Marked finished and skipped");
        check(
                !OnboardingScreen.Controller.shouldShowOnLaunch(store),
                "Completed version suppresses relaunch");
        check(
                store.getInt(OnboardingScreen.KEY_ONBOARDING_DONE_VERSION, 0)
                        == OnboardingScreen.CURRENT_VERSION,
                "Stored onboarding_done_version == 1");

        // 3. Personalization constraints & Act 4 HUD demo cycle
        ctrl.goToAct(4);
        ctrl.setReduceMotion(true);
        ctrl.setReduceTransparency(true);
        ctrl.setUiScalePercent(120);
        check(ctrl.getCurrentAct() == 4, "Personalization changes keep active act on Act 5");
        check(
                ctrl.isReduceMotion() && ctrl.isReduceTransparency(),
                "Accessibility flags persisted in controller");
        check(ctrl.getUiScalePercent() == 120, "Valid scale 120% accepted");
        ctrl.setUiScalePercent(999);
        check(ctrl.getUiScalePercent() == 120, "Invalid scale ignored");
        check(ctrl.getHudDemoStep() == 0, "HUD demo starts at step 0");
        check(ctrl.cycleHudDemoStep() == 1, "HUD demo cycles to step 1");
        check(ctrl.cycleHudDemoStep() == 2, "HUD demo cycles to step 2");
        check(ctrl.cycleHudDemoStep() == 0, "HUD demo wraps back to step 0");

        // 4. FirstPlayGestureHint max-3-displays policy
        OnboardingScreen.MemoryStore hintStore = new OnboardingScreen.MemoryStore();
        check(FirstPlayGestureHint.Policy.shouldShow(hintStore), "Hint eligible initially");
        check(FirstPlayGestureHint.Policy.recordShown(hintStore) == 1, "Count 1");
        check(FirstPlayGestureHint.Policy.shouldShow(hintStore), "Hint eligible after 1 show");
        check(FirstPlayGestureHint.Policy.recordShown(hintStore) == 2, "Count 2");
        check(FirstPlayGestureHint.Policy.shouldShow(hintStore), "Hint eligible after 2 shows");
        check(FirstPlayGestureHint.Policy.recordShown(hintStore) == 3, "Count 3");
        check(!FirstPlayGestureHint.Policy.shouldShow(hintStore), "Hint suppressed after 3 shows");

        // 5. One-tap dismiss forever
        OnboardingScreen.MemoryStore dismissStore = new OnboardingScreen.MemoryStore();
        check(
                FirstPlayGestureHint.Policy.shouldShow(dismissStore),
                "Dismiss store eligible initially");
        FirstPlayGestureHint.Policy.dismissForever(dismissStore);
        check(
                !FirstPlayGestureHint.Policy.shouldShow(dismissStore),
                "Dismissed forever suppresses hint");
        check(FirstPlayGestureHint.Policy.isDismissed(dismissStore), "isDismissed == true");

        // 6. Replay reset clears both onboarding and play hint counters
        OnboardingScreen.Controller.resetForReplay(dismissStore);
        check(
                OnboardingScreen.Controller.shouldShowOnLaunch(dismissStore),
                "Replay re-enables onboarding");
        check(
                FirstPlayGestureHint.Policy.shouldShow(dismissStore),
                "Replay re-enables first-play hint");

        // 7. Bilingual copy checks (Touch & TV)
        check(
                FirstPlayGestureHint.Policy.hintCopy(false, true).contains("2.0×"),
                "Touch ZH copy mentions 2.0x speed");
        check(
                FirstPlayGestureHint.Policy.hintCopy(true, true).contains("长按左右键"),
                "TV ZH copy mentions long-press left/right");
        check(
                FirstPlayGestureHint.Policy.hintCopy(false, false).contains("2.0×"),
                "Touch EN copy mentions 2.0x speed");
        check(
                FirstPlayGestureHint.Policy.hintCopy(true, false).contains("Left/Right"),
                "TV EN copy mentions Left/Right");

        // 8. Parse generated android-tv/src/main/assets/demo/manifest.json
        if (args.length > 0) {
            Path manifestPath = Paths.get(args[0]);
            String raw = new String(Files.readAllBytes(manifestPath), Charset.forName("UTF-8"));
            List<OnboardingScreen.DemoItem> items = OnboardingScreen.parseManifest(raw);
            check(items.size() == 14, "Manifest contains exactly 14 demo items");
            for (OnboardingScreen.DemoItem item : items) {
                check("示例".equals(item.badgeZh), "Item " + item.id + " badgeZh == 示例");
                check("DEMO".equals(item.badgeEn), "Item " + item.id + " badgeEn == DEMO");
                check(item.titleZh.startsWith("示例"), "Item " + item.id + " titleZh starts with 示例");
                check(
                        item.titleEn.startsWith("Sample"),
                        "Item " + item.id + " titleEn starts with Sample");
                check(!item.specs.isEmpty(), "Item " + item.id + " has spec tags");
            }
        }

        System.out.println("PASS OnboardingStateChecks (" + passed + " assertions)");
    }
}
