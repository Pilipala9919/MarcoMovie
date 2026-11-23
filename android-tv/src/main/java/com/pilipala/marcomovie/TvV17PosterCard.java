package com.pilipala.marcomovie;

import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.TextView;

/** Presentation only: callers own image loading, identity, actions and focus restoration. */
final class TvV17PosterCard {
    static void artwork(MainActivity a, ImageView art) {
        art.setScaleType(ImageView.ScaleType.CENTER_CROP);
        art.setBackground(TvV17Surface.rounded(0xff252c35, a.dp(10), Color.TRANSPARENT, 0));
        art.setClipToOutline(true);
    }

    /** Creates a consistent, sleek top-right Douban rating badge pill over poster artwork. */
    static TextView createDoubanBadge(MainActivity a) {
        TextView badge = a.text("", 10.5f, 0xfffbbf24);
        badge.setTag("card-douban-score");
        badge.setTypeface(null, Typeface.BOLD);
        badge.setSingleLine(true);
        badge.setIncludeFontPadding(false);
        badge.setPadding(a.dp(6), a.dp(2.5f), a.dp(6), a.dp(2.5f));
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(0xd010141c);
        bg.setCornerRadius(a.dp(6));
        bg.setStroke(Math.max(1, a.dp(0.8f)), 0x44fbbf24);
        badge.setBackground(bg);
        badge.setVisibility(View.GONE);
        return badge;
    }

    static void attachDoubanBadge(MainActivity a, FrameLayout container, Cms.Video video) {
        if (a == null || container == null || video == null) return;
        TextView badge = createDoubanBadge(a);
        FrameLayout.LayoutParams lp =
                new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.END);
        lp.topMargin = a.dp(6);
        lp.rightMargin = a.dp(6);
        container.addView(badge, lp);
        DoubanScoreRepository.bindBadge(a, badge, video);
    }

    static FrameLayout wrapArtworkWithDoubanBadge(
            MainActivity a, ImageView art, Cms.Video video, boolean showBadge) {
        FrameLayout wrap = new FrameLayout(a);
        wrap.setClipChildren(true);
        wrap.addView(art, new FrameLayout.LayoutParams(-1, -1));
        if (showBadge && video != null) {
            attachDoubanBadge(a, wrap, video);
        }
        return wrap;
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
