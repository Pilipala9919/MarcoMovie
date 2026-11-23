package com.pilipala.marcomovie;

import android.graphics.Color;
import android.view.View;
import android.widget.ImageView;
import android.widget.TextView;

/** Presentation only: callers own image loading, identity, actions and focus restoration. */
final class TvV17PosterCard {
    static void artwork(MainActivity a, ImageView art) {
        art.setScaleType(ImageView.ScaleType.CENTER_CROP);
        art.setBackground(TvV17Surface.rounded(0xff252c35, a.dp(10), Color.TRANSPARENT, 0));
        art.setClipToOutline(true);
    }

    static void focus(MainActivity a, View card, TextView title, boolean focused) {
        FocusMotion.style(
                a,
                card,
                focused,
                Color.TRANSPARENT,
                Color.TRANSPARENT,
                12,
                TvV17Theme.FOCUS,
                TvV17Theme.FOCUS,
                true,
                1.035f);
        title.setTextColor(focused ? TvV17Theme.TEXT : TvV17Theme.MUTED);
    }
}
