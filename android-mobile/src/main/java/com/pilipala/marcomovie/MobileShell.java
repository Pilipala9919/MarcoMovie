package com.pilipala.marcomovie;

import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.view.View;

/**
 * Compatibility facade bridging legacy {@code MobileShell} callers in shared dialogs and
 * controllers to the modular {@link MobileRootShell} & {@link UiWidgets} architecture.
 */
final class MobileShell {
    static int activeTab = 0;
    private static int lastSyncedLegacyTab = 0;
    static int mySubTab = 0;
    static int settingsSubPage = 0;
    static String pendingSearchKeyword = "";
    static SearchCoordinator activeSearchCoordinator;

    private MobileShell() {}

    static int toRootTab(int legacyTab) {
        switch (legacyTab) {
            case 1:
                return MobileRootShell.TAB_SEARCH;
            case 2:
                return MobileRootShell.TAB_LIVE;
            case 3:
                return MobileRootShell.TAB_LIBRARY;
            case 4:
                return MobileRootShell.TAB_SETTINGS;
            case 0:
            default:
                return MobileRootShell.TAB_HOME;
        }
    }

    static int toLegacyTab(int rootTab) {
        switch (rootTab) {
            case MobileRootShell.TAB_SEARCH:
                return 1;
            case MobileRootShell.TAB_LIVE:
                return 2;
            case MobileRootShell.TAB_LIBRARY:
                return 3;
            case MobileRootShell.TAB_SETTINGS:
                return 4;
            case MobileRootShell.TAB_HOME:
            default:
                return 0;
        }
    }

    static void syncFromRootTab(int rootTab) {
        int leg = toLegacyTab(rootTab);
        activeTab = leg;
        lastSyncedLegacyTab = leg;
    }

    static void clearSearchSession() {
        if (activeSearchCoordinator != null) {
            activeSearchCoordinator.close();
            activeSearchCoordinator = null;
        }
        pendingSearchKeyword = "";
        MobileSearchPage.clearCachedResults();
    }

    static void show(MainActivity a) {
        if (activeTab != lastSyncedLegacyTab) {
            MobileRootShell.activeTab = toRootTab(activeTab);
            lastSyncedLegacyTab = activeTab;
        } else {
            syncFromRootTab(MobileRootShell.activeTab);
        }
        MobileRootShell.show(a);
    }

    static void openSearchTab(MainActivity a, String initialKeyword) {
        String kw = initialKeyword == null ? "" : initialKeyword.trim();
        if (!kw.isEmpty()) {
            MobileRootShell.pendingSearchKeyword = kw;
        }
        syncFromRootTab(MobileRootShell.TAB_SEARCH);
        MobileRootShell.openTab(a, MobileRootShell.TAB_SEARCH);
    }

    static void showMobileImportDialog(MainActivity a) {
        UiWidgets.showMobileImportDialog(a);
    }

    static GradientDrawable glassBg(
            int topColor, int bottomColor, float radiusPx, float strokePx, int strokeColor) {
        return UiWidgets.glassBg(topColor, bottomColor, radiusPx, strokePx, strokeColor);
    }

    static void bindCardTouchFeedback(
            MainActivity a, View card, Drawable normalBg, Drawable pressedBg) {
        UiWidgets.bindCardTouchFeedback(a, card, normalBg, pressedBg);
    }

    static void showDrawerPicker(
            MainActivity a,
            String title,
            String[] options,
            int selectedIndex,
            PlayerBubble.IntAction onSelect) {
        UiWidgets.showDrawerPicker(a, title, "", options, selectedIndex, onSelect);
    }

    static void showDrawerPicker(
            MainActivity a,
            String title,
            String subtitle,
            String[] options,
            int selectedIndex,
            PlayerBubble.IntAction onSelect) {
        UiWidgets.showDrawerPicker(a, title, subtitle, options, selectedIndex, onSelect);
    }

    static final class IosSwitchView extends UiWidgets.IosSwitchView {
        IosSwitchView(MainActivity activity, boolean initialChecked) {
            super(activity, initialChecked);
        }
    }

    static final class SettingIconView extends UiWidgets.SettingIconView {
        SettingIconView(MainActivity activity, int kind) {
            super(activity, kind);
        }
    }
}
