package com.pilipala.marcomovie;

import android.view.View;
import android.widget.FrameLayout;

/** Apple TV frosted glass container for the line switcher and episode grid. */
final class TvV17EpisodePanel {
    private TvV17EpisodePanel() {}

    static FrameLayout wrap(MainActivity a, View content) {
        FrameLayout panel = new FrameLayout(a);
        panel.setTag("tv-v17-episode-panel");
        panel.setClipChildren(false);
        panel.setClipToPadding(false);
        panel.setPadding(a.dp(24), a.dp(20), a.dp(24), a.dp(22));
        panel.setBackground(TvV17Surface.rounded(0xd411151d, a.dp(22), 0x26ffffff, a.dp(1)));
        panel.addView(content, new FrameLayout.LayoutParams(-1, -2));
        return panel;
    }
}
