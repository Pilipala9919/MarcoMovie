package com.pilipala.marcomovie;

import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.List;

/**
 * Immersive live-video backdrop shallow detail overlay when pressing Back during TV playback.
 *
 * <p>Mirrors {@link TvV17DetailScreen}: keeps the live playing video surface full-bleed across the
 * upper showcase window with a smooth lower feather scrim into the hero stage, with both Episodes
 * and Seasons tucked neatly into popup trigger buttons beside "返回全屏播放" (no sprawling inline
 * episode/season grids below).
 */
final class MiniDetails {
    static final boolean INLINE_EPISODES_COLLAPSED = true;
    static final String TAG_EPISODES_TRIGGER = "mini-episodes-trigger";
    static final String TAG_SEASONS_TRIGGER = "mini-seasons-trigger";

    final MainActivity a;
    final FrameLayout page;
    final View hit;
    final PlaybackControls controls;

    MiniDetails(MainActivity host) {
        a = host;
        controls = a.playbackControls;
        final Cms.Video video = controls.video;
        final Cms.Site site = controls.site;

        // Keep the live video surface full-screen at the bottom layer so it acts as the
        // uninterrupted immersive dynamic hero background.
        UiCompat.setClipToOutline(a.playbackLayer, false);
        a.playbackLayer.setBackgroundColor(Color.BLACK);
        a.playbackLayer.setLayoutParams(new FrameLayout.LayoutParams(-1, -1));

        page = new FrameLayout(a);
        page.setTag("mini-details");
        page.setClipChildren(false);
        page.setClipToPadding(false);
        page.setBackgroundColor(Color.TRANSPARENT);

        final LiveVideoScrimView scrim = new LiveVideoScrimView();
        page.addView(scrim, new FrameLayout.LayoutParams(-1, -1));

        // Invisible carrier keeps mini-cover tag & non-overlapping bounds for device probes
        ImmersivePoster cover = new ImmersivePoster(a, "mini-cover");
        cover.immersiveMode = true;
        FrameLayout.LayoutParams coverSize =
                new FrameLayout.LayoutParams(a.dp(260), a.dp(390), Gravity.TOP | Gravity.LEFT);
        coverSize.leftMargin = -a.dp(260);
        page.addView(cover, coverSize);
        cover.load(video.poster, video.title, video.year, video.actor, video.director, false);

        final TvScrollView list = new TvScrollView(a);
        list.setFillViewport(true);
        list.setClipChildren(false);
        list.setClipToPadding(false);
        list.setVerticalScrollBarEnabled(false);
        list.getViewTreeObserver()
                .addOnScrollChangedListener(() -> scrim.setScrollOffset(list.getScrollY()));
        page.addView(list, new FrameLayout.LayoutParams(-1, -1));

        LinearLayout content = a.vertical();
        content.setClipChildren(false);
        content.setClipToPadding(false);
        list.addView(content, new ScrollView.LayoutParams(-1, -2));

        // 1. Top Liquid Glass Navigation Bar (Back on left, Favorite on right)
        LinearLayout topBar = a.row();
        topBar.setClipChildren(false);
        topBar.setClipToPadding(false);
        topBar.setGravity(Gravity.CENTER_VERTICAL);
        topBar.setPadding(a.dp(38), a.dp(20), a.dp(38), a.dp(8));

        Button back =
                DetailScreen.glassNavButton(a, "‹ 退出播放", "mini-back", false, a::onBackPressed);
        back.setId(View.generateViewId());
        topBar.addView(back, new LinearLayout.LayoutParams(-2, a.dp(38)));

        View topSpacer = new View(a);
        topBar.addView(topSpacer, new LinearLayout.LayoutParams(0, 1, 1f));

        boolean initialFav =
                Favorites.contains(a.prefs.getString(Prefs.FAVORITES, "[]"), site.key, video.id);
        Button favorite =
                DetailScreen.glassNavButton(
                        a, initialFav ? "♥ 已收藏" : "♡ 加入收藏", "mini-favorite", initialFav, () -> {});
        favorite.setId(View.generateViewId());
        back.setNextFocusRightId(favorite.getId());
        favorite.setNextFocusLeftId(back.getId());
        DetailScreen.bindFavoriteAction(a, site, video, favorite);
        topBar.addView(favorite, new LinearLayout.LayoutParams(-2, a.dp(38)));
        content.addView(topBar, new LinearLayout.LayoutParams(-1, -2));

        // 2. Generous Upper Live Video Showcase Window (clicking it returns to full-screen
        // playback)
        float screenHeightDp = a.windowHeight() / a.getResources().getDisplayMetrics().density;
        int videoShowcaseDp = Math.max(132, Math.min(220, Math.round(screenHeightDp * 0.30f)));
        View videoTouchZone = new View(a);
        videoTouchZone.setFocusable(false);
        videoTouchZone.setOnClickListener(v -> a.expandPlayback());
        content.addView(videoTouchZone, new LinearLayout.LayoutParams(-1, a.dp(videoShowcaseDp)));

        // 3. Shallow Hero Stage matching TvV17DetailScreen (episodes & seasons tucked into popups)
        LinearLayout hero = a.vertical();
        hero.setGravity(Gravity.LEFT);
        hero.setClipChildren(false);
        hero.setClipToPadding(false);
        hero.setPadding(a.dp(48), a.dp(4), a.dp(48), a.dp(36));
        content.addView(hero, new LinearLayout.LayoutParams(-1, -2));

        // Live playing episode badge pill
        String currentEpName =
                controls.resolved != null && controls.resolved.name != null
                        ? controls.resolved.name
                        : (a.activeEpisode != null && a.activeEpisode.name != null
                                ? a.activeEpisode.name
                                : "");
        if (!currentEpName.isEmpty()) {
            TextView liveBadge =
                    a.text((a.playing ? "● 正在播放 · " : "Ⅱ 已暂停 · ") + currentEpName, 12, 0xff90caf9);
            liveBadge.setSingleLine(true);
            liveBadge.setEllipsize(TextUtils.TruncateAt.END);
            liveBadge.setMaxWidth(a.dp(620));
            liveBadge.setPadding(a.dp(12), a.dp(4), a.dp(12), a.dp(4));
            GradientDrawable badgeBg = new GradientDrawable();
            badgeBg.setCornerRadius(a.dp(14));
            badgeBg.setColor(0x88101826);
            badgeBg.setStroke(Math.max(1, a.dp(1)), 0x5564b5f6);
            liveBadge.setBackground(badgeBg);
            LinearLayout.LayoutParams badgeLp = new LinearLayout.LayoutParams(-2, -2);
            badgeLp.gravity = Gravity.LEFT;
            badgeLp.bottomMargin = a.dp(6);
            hero.addView(liveBadge, badgeLp);
        }

        TextView title = a.text(video.title, 28, MainActivity.WHITE);
        title.setTypeface(null, Typeface.BOLD);
        title.setGravity(Gravity.LEFT);
        title.setMaxLines(2);
        title.setEllipsize(TextUtils.TruncateAt.END);
        title.setShadowLayer(a.dp(12), 0, a.dp(3), 0xcc000000);
        LinearLayout.LayoutParams titleLp = new LinearLayout.LayoutParams(-2, -2);
        titleLp.gravity = Gravity.LEFT;
        hero.addView(title, titleLp);

        LinearLayout metaRow = a.row();
        metaRow.setGravity(Gravity.LEFT);
        List<String> pills = DetailScreen.collectMetaPills(video);
        for (int i = 0; i < pills.size(); i++) {
            TextView pill = DetailScreen.makeGlassMetaPill(a, pills.get(i));
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
            if (i > 0) lp.leftMargin = a.dp(8);
            metaRow.addView(pill, lp);
        }
        if (metaRow.getChildCount() > 0) {
            LinearLayout.LayoutParams metaLp = new LinearLayout.LayoutParams(-2, -2);
            metaLp.gravity = Gravity.LEFT;
            metaLp.topMargin = a.dp(8);
            hero.addView(metaRow, metaLp);
        }

        LinearLayout ratingRow = DetailScreen.buildRatingAndCastRow(a, site, video);
        LinearLayout.LayoutParams ratingLp = new LinearLayout.LayoutParams(-2, -2);
        ratingLp.gravity = Gravity.LEFT;
        ratingLp.topMargin = a.dp(6);
        hero.addView(ratingRow, ratingLp);

        Button synopsisBtn = null;
        if (video.description != null && !video.description.isEmpty()) {
            LinearLayout synopsisRow = a.vertical();
            synopsisRow.setGravity(Gravity.LEFT);
            TextView synopsis = a.text(video.description, 14, 0xdcebebf5);
            synopsis.setGravity(Gravity.LEFT);
            synopsis.setLineSpacing(a.dp(2), 1.06f);
            synopsis.setMaxLines(2);
            synopsis.setEllipsize(TextUtils.TruncateAt.END);
            synopsis.setMaxWidth(a.dp(760));
            synopsis.setShadowLayer(a.dp(6), 0, a.dp(1), 0x88000000);
            synopsisRow.addView(synopsis, new LinearLayout.LayoutParams(-2, -2));

            Button moreBtn =
                    DetailScreen.glassNavButton(
                            a,
                            "展开完整简介与演职员 ›",
                            "mini-synopsis",
                            false,
                            () ->
                                    new AppDialog.Builder(a)
                                            .setTitle(video.title)
                                            .setMessage(
                                                    DetailScreen.buildFullSynopsisMessage(video))
                                            .setPositiveButton("关闭", null)
                                            .show());
            moreBtn.setId(View.generateViewId());
            moreBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
            moreBtn.setMinHeight(a.dp(28));
            moreBtn.setMinimumHeight(a.dp(28));
            moreBtn.setPadding(a.dp(12), a.dp(3), a.dp(12), a.dp(3));
            LinearLayout.LayoutParams moreLp = new LinearLayout.LayoutParams(-2, a.dp(28));
            moreLp.topMargin = a.dp(6);
            synopsisRow.addView(moreBtn, moreLp);
            synopsisBtn = moreBtn;

            LinearLayout.LayoutParams synLp = new LinearLayout.LayoutParams(-2, -2);
            synLp.gravity = Gravity.LEFT;
            synLp.topMargin = a.dp(8);
            hero.addView(synopsisRow, synLp);
        }

        // Primary Action Row: Return to Playback + Tucked-away Episodes Popup + Tucked-away Seasons
        // Popup
        LinearLayout actionRow = a.row();
        actionRow.setGravity(Gravity.CENTER_VERTICAL);
        actionRow.setClipChildren(false);
        actionRow.setClipToPadding(false);
        LinearLayout.LayoutParams actionRowLp = new LinearLayout.LayoutParams(-1, -2);
        actionRowLp.topMargin = a.dp(14);
        hero.addView(actionRow, actionRowLp);

        Button expand =
                DetailScreen.heroPlayButton(a, "►  返回全屏播放", "mini-expand", a::expandPlayback);
        expand.setId(View.generateViewId());
        expand.setSingleLine(true);
        expand.setEllipsize(TextUtils.TruncateAt.END);
        expand.setMinWidth(a.dp(168));
        expand.setMinimumWidth(a.dp(168));
        expand.setPadding(a.dp(24), 0, a.dp(24), 0);
        actionRow.addView(expand, new LinearLayout.LayoutParams(-2, a.dp(46)));
        hit = expand;

        final boolean hasEpisodes = video.lines != null && !video.lines.isEmpty();
        final int activeLineIdx = hasEpisodes ? Math.max(0, video.lines.indexOf(a.activeLine)) : 0;
        final Button episodesBtn =
                DetailScreen.glassNavButton(
                        a,
                        TvDetailHost.buildEpisodesButtonLabel(video, activeLineIdx),
                        TAG_EPISODES_TRIGGER,
                        false,
                        () -> {
                            if (video.lines == null || video.lines.isEmpty()) {
                                a.toast("当前内容没有可选择的剧集");
                                return;
                            }
                            int curLineIdx = Math.max(0, video.lines.indexOf(a.activeLine));
                            Cms.Line curLine = video.lines.get(curLineIdx);
                            int epIdx =
                                    curLine == null || curLine.episodes == null
                                            ? 0
                                            : Math.max(
                                                    0, curLine.episodes.indexOf(a.activeEpisode));
                            int epCount =
                                    curLine == null || curLine.episodes == null
                                            ? 0
                                            : curLine.episodes.size();
                            int pageIdx =
                                    EpisodeSelection.pageFor(
                                            epIdx,
                                            epCount,
                                            a.prefs.getBoolean(Prefs.EPISODES_DESCENDING, false));
                            TvDetailHost.showEpisodesDialog(
                                    a, site, video, curLineIdx, pageIdx, null);
                        });
        episodesBtn.setId(View.generateViewId());
        episodesBtn.setVisibility(hasEpisodes ? View.VISIBLE : View.GONE);
        episodesBtn.setSingleLine(true);
        episodesBtn.setEllipsize(TextUtils.TruncateAt.END);
        episodesBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f);
        episodesBtn.setPadding(a.dp(20), a.dp(10), a.dp(20), a.dp(10));
        LinearLayout.LayoutParams epBtnLp = new LinearLayout.LayoutParams(-2, a.dp(46));
        epBtnLp.leftMargin = a.dp(12);
        actionRow.addView(episodesBtn, epBtnLp);

        final DetailScreen.RelatedSeasons[] discoveredSeasons = {null};
        final Button seasonsBtn =
                DetailScreen.glassNavButton(
                        a,
                        "☰ 选季",
                        TAG_SEASONS_TRIGGER,
                        false,
                        () -> {
                            if (discoveredSeasons[0] != null) {
                                DetailScreen.showTvSeasonsPopup(
                                        a, site, video, discoveredSeasons[0], true);
                            }
                        });
        seasonsBtn.setId(View.generateViewId());
        seasonsBtn.setVisibility(View.GONE);
        seasonsBtn.setSingleLine(true);
        seasonsBtn.setEllipsize(TextUtils.TruncateAt.END);
        seasonsBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f);
        seasonsBtn.setPadding(a.dp(18), a.dp(10), a.dp(18), a.dp(10));
        LinearLayout.LayoutParams seasonBtnLp = new LinearLayout.LayoutParams(-2, a.dp(46));
        seasonBtnLp.leftMargin = a.dp(12);
        actionRow.addView(seasonsBtn, seasonBtnLp);

        // Subtle active route & episode caption beneath the button row
        String routeCaption =
                TvV17DetailScreen.formatEpisodeFileCaption(a.activeLine, a.activeEpisode);
        if (!routeCaption.isEmpty()) {
            TextView captionView = a.text("当前播放：" + routeCaption, 12.5f, 0xb8ebebf5);
            captionView.setSingleLine(true);
            captionView.setEllipsize(TextUtils.TruncateAt.END);
            captionView.setShadowLayer(a.dp(6), 0, a.dp(1), 0x80000000);
            LinearLayout.LayoutParams capLp = new LinearLayout.LayoutParams(-1, -2);
            capLp.topMargin = a.dp(10);
            hero.addView(captionView, capLp);
        }

        // Clean D-pad focus links between top bar, synopsis trigger, and horizontal action row
        final int aboveActionId = synopsisBtn != null ? synopsisBtn.getId() : back.getId();
        expand.setNextFocusUpId(aboveActionId);
        episodesBtn.setNextFocusUpId(aboveActionId);
        seasonsBtn.setNextFocusUpId(aboveActionId);
        if (synopsisBtn != null) {
            synopsisBtn.setNextFocusUpId(back.getId());
            synopsisBtn.setNextFocusDownId(expand.getId());
            back.setNextFocusDownId(synopsisBtn.getId());
            favorite.setNextFocusDownId(synopsisBtn.getId());
        } else {
            back.setNextFocusDownId(expand.getId());
            favorite.setNextFocusDownId(expand.getId());
        }

        // Discover related seasons asynchronously and reveal the tucked-away 选季 popup button
        DetailScreen.discoverTvRelatedSeasons(
                a,
                site,
                video,
                page,
                seasons -> {
                    if (!a.miniMode) return;
                    discoveredSeasons[0] = seasons;
                    seasonsBtn.setText("☰ 选季 · 共 " + seasons.count() + " 季");
                    seasonsBtn.setVisibility(View.VISIBLE);
                });

        int layerIdx = a.root.indexOfChild(a.playbackLayer);
        a.root.addView(
                page, layerIdx >= 0 ? layerIdx + 1 : 0, new FrameLayout.LayoutParams(-1, -1));

        a.playbackLayer.post(
                () -> {
                    if (a.miniMode) {
                        controls.resize(controls.videoWidth, controls.videoHeight);
                        hit.requestFocus();
                    }
                });
    }

    void remove() {
        a.root.removeView(page);
        if (hit != null && hit.getParent() == a.playbackLayer) {
            a.playbackLayer.removeView(hit);
        }
        View hint = a.playbackLayer.findViewWithTag("mini-hint");
        if (hint != null) a.playbackLayer.removeView(hint);
    }

    /**
     * Draws a transparent upper showcase window over the live video surface and smoothly feathers
     * it into a solid dark ambient surface for the centered hero controls and bottom episode grid.
     */
    private final class LiveVideoScrimView extends View {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private float scrollProgress = 0f;

        LiveVideoScrimView() {
            super(a);
            setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        }

        void setScrollOffset(int scrollY) {
            int h = getHeight();
            float range = h > 0 ? h * 0.42f : a.dp(240);
            float next = Math.max(0f, Math.min(1f, scrollY / Math.max(1f, range)));
            if (Math.abs(next - scrollProgress) > 0.004f) {
                scrollProgress = next;
                invalidate();
            }
        }

        @Override
        protected void onDraw(Canvas c) {
            int w = getWidth();
            int h = getHeight();
            if (w <= 0 || h <= 0) return;

            float winH = h * 0.78f;

            // 1. Top floating bar subtle legibility scrim
            paint.setShader(
                    new LinearGradient(
                            0,
                            0,
                            0,
                            h * 0.16f,
                            new int[] {0x7c000000, 0x28000000, 0x00000000},
                            new float[] {0f, 0.55f, 1f},
                            Shader.TileMode.CLAMP));
            c.drawRect(0, 0, w, h * 0.16f, paint);
            paint.setShader(null);

            // 2. Smooth feather gradient from transparent live video into sleek dark hero stage
            paint.setShader(
                    new LinearGradient(
                            0,
                            h * 0.28f,
                            0,
                            h,
                            new int[] {0x00090c14, 0x48090c14, 0xb8090c14, 0xe8090c14, 0xf8090c14},
                            new float[] {0f, 0.28f, 0.56f, 0.80f, 1f},
                            Shader.TileMode.CLAMP));
            c.drawRect(0, h * 0.28f, w, h, paint);
            paint.setShader(null);

            // 3. Scroll-driven veil if user scrolls on shorter viewports
            if (scrollProgress > 0.005f) {
                int alpha = Math.min(220, Math.round(scrollProgress * 220f));
                paint.setColor(Color.argb(alpha, 9, 12, 20));
                c.drawRect(0, 0, w, winH, paint);
            }
        }
    }
}
