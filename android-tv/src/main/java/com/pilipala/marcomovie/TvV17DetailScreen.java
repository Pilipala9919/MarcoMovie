package com.pilipala.marcomovie;

import android.graphics.Outline;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewOutlineProvider;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.List;

/**
 * Apple TV+ inspired immersive TV detail screen.
 *
 * <p>Spacious, left-aligned cinema hierarchy over a full-bleed official HD landscape backdrop:
 * - Row 1: Giant bold title + small circular Heart favorite button beside it
 * - Row 2: Unified nameplate badge bar — Year · Country/Region · Real episode count & season count
 *          (when multi-season) · 4K/HDR/Dolby spec badges · authentic Douban/RT ratings · source
 * - Row 3: Drama/movie synopsis (+ full synopsis trigger when truncated)
 * - Row 4: Action row — Play / Continue button + Episodes/Lines popup button (+ optional source switch)
 * - Row 5: Small subtitle beneath buttons showing last played route's resource name when continuing
 * - Row 6: Display-only cast strip (circular portrait avatar badges)
 * - Row 7: Related multi-season shelf (if multi-season)
 */
final class TvV17DetailScreen {
    interface Actions {
        void back();

        void play();

        void episodes();

        void favorite();

        void synopsis();
    }

    private static final int[] AVATAR_ACCENTS = {
        0xff2b4c6f, 0xff4b3a69, 0xff28544b, 0xff6b4431, 0xff3b4c63, 0xff5a374b
    };

    final FrameLayout view;
    final ImmersivePoster cover;
    final LinearLayout seasonHost;
    final Button back;
    final Button play;
    final Button episodesBtn;
    final Button seasonsBtn;
    final Button scrapeBtn;
    final Button switchSourceBtn;
    final Button favorite;
    final TextView episodeFileView;
    final TextView historyView;
    final TextView statusView;
    final TvScrollView scroll;
    final LinearLayout content;
    private final MainActivity host;
    private Cms.Site site;
    private Cms.Video video;
    private final MediaBadgeView.BadgeFlowLayout nameplateRow;
    private final TextView synopsisView;
    private final Button synopsisMoreBtn;
    private final LinearLayout castSection;
    private final LinearLayout castRow;
    private Runnable seasonsAction;
    private Runnable scrapeAction;
    private Runnable switchSourceAction;
    private ImmersivePoster.SubjectDetails officialDetails;
    private int detectedSeasonCount;
    private double resolvedDouban = 0.0;
    private int resolvedRt = -1;
    private WatchHistory.Entry currentBookmark;

    TvV17DetailScreen(
            MainActivity a,
            Cms.Site site,
            Cms.Video video,
            String verifiedBackdrop,
            boolean isFavorite,
            boolean playEnabled,
            String playLabel,
            String episodesButtonLabel,
            String episodeFileCaption,
            String historyCaption,
            Actions actions) {
        if (a == null || site == null || video == null || actions == null)
            throw new IllegalArgumentException();
        this.host = a;
        this.site = site;
        this.video = video;

        int initialAmbient = MobileDetailScreen.defaultAmbientForTitle(video.title);
        view = new FrameLayout(a);
        view.setTag("tv-v17-detail");
        view.setBackgroundColor(initialAmbient);

        // Full-bleed cinema backdrop with Apple TV+ left-aligned directional vignette
        cover = new ImmersivePoster(a, "detail-cover");
        cover.immersiveMode = true;
        cover.backdrop.setTag("detail-backdrop");
        cover.backdrop.leftAlignedHero = true;
        cover.backdrop.ambientColor = initialAmbient;
        cover.onAmbientChanged = color -> view.setBackgroundColor(color);
        view.addView(cover.backdrop, new FrameLayout.LayoutParams(-1, -1));
        view.addView(
                cover,
                new FrameLayout.LayoutParams(a.dp(260), a.dp(390), Gravity.TOP | Gravity.START));

        scroll = new TvScrollView(a);
        scroll.setTag("detail-scroll");
        scroll.readingMode = true;
        scroll.setFillViewport(true);
        scroll.setClipChildren(false);
        scroll.setClipToPadding(false);
        scroll.setVerticalScrollBarEnabled(false);
        scroll.getViewTreeObserver()
                .addOnScrollChangedListener(
                        () -> cover.backdrop.setScrollOffset(scroll.getScrollY()));
        view.addView(scroll, new FrameLayout.LayoutParams(-1, -1));

        content = a.vertical();
        content.setPadding(a.dp(56), a.dp(26), a.dp(56), a.dp(64));
        content.setClipChildren(false);
        content.setClipToPadding(false);
        scroll.addView(content, new ScrollView.LayoutParams(-1, -2));

        // Top-left floating frosted back button
        back = DetailScreen.glassNavButton(a, "‹ 返回", "detail-back", false, actions::back);
        back.setId(View.generateViewId());
        content.addView(back, new LinearLayout.LayoutParams(-2, a.dp(38)));

        // Balanced upper artwork breathing window (~38-42% viewport) so title, nameplate badges,
        // synopsis, play/episodes buttons and last-played caption all sit cleanly above the fold.
        float density = Math.max(1f, a.getResources().getDisplayMetrics().density);
        float screenHeightDp = a.windowHeight() / density;
        float screenWidthDp = a.windowWidth() / density;
        int targetTitleTopDp = Math.round(screenHeightDp * 0.36f);
        int breathingDp = Math.max(96, Math.min(220, targetTitleTopDp - 58));
        View breathingRoom = new View(a);
        content.addView(breathingRoom, new LinearLayout.LayoutParams(1, a.dp(breathingDp)));

        int heroWidthPx = a.dp(Math.max(480, Math.min(760, Math.round(screenWidthDp * 0.66f))));
        LinearLayout heroColumn = a.vertical();
        heroColumn.setTag("detail-hero");
        heroColumn.setClipChildren(false);
        heroColumn.setClipToPadding(false);
        content.addView(heroColumn, new LinearLayout.LayoutParams(heroWidthPx, -2));

        // 1. Bold Title + small circular Heart Favorite button beside it
        LinearLayout titleRow = a.row();
        titleRow.setGravity(Gravity.CENTER_VERTICAL);
        titleRow.setClipChildren(false);
        titleRow.setClipToPadding(false);

        TextView title = a.text(video.title == null ? "" : video.title, 36, 0xfff5f5f7);
        title.setTag("detail-title");
        title.setTypeface(null, Typeface.BOLD);
        title.setMaxLines(2);
        title.setEllipsize(TextUtils.TruncateAt.END);
        title.setMaxWidth(heroWidthPx - a.dp(54));
        title.setLineSpacing(a.dp(2), 1.05f);
        title.setShadowLayer(a.dp(14), 0, a.dp(3), 0xb8000000);
        titleRow.addView(title, new LinearLayout.LayoutParams(-2, -2));

        favorite = a.button("", "detail-favorite", actions::favorite);
        favorite.setId(View.generateViewId());
        favorite.setMinWidth(0);
        favorite.setMinimumWidth(0);
        favorite.setMinHeight(0);
        favorite.setMinimumHeight(0);
        favorite.setPadding(0, 0, 0, 0);
        favorite.setGravity(Gravity.CENTER);
        favorite.setIncludeFontPadding(false);
        favorite.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16.5f);
        favorite.setOnFocusChangeListener(
                (v, focused) -> styleHeartFavorite(focused, favorite.isSelected()));
        setFavorite(isFavorite);
        LinearLayout.LayoutParams favLp = new LinearLayout.LayoutParams(a.dp(34), a.dp(34));
        favLp.leftMargin = a.dp(12);
        titleRow.addView(favorite, favLp);
        heroColumn.addView(titleRow, new LinearLayout.LayoutParams(-1, -2));

        // 2. Unified Nameplate Badges Row: Year · Country/Region · Seasons · Episodes ·
        // 4K/HDR/Dolby · Ratings · Source
        nameplateRow = MediaBadgeView.createRow(a, "detail-nameplates", false);
        nameplateRow.setGapPx(a.dp(8));
        LinearLayout.LayoutParams nameplateLp = new LinearLayout.LayoutParams(-1, -2);
        nameplateLp.topMargin = a.dp(14);
        heroColumn.addView(nameplateRow, nameplateLp);

        // 3. Plot Synopsis directly below nameplate badges, ABOVE Play & Episodes buttons
        String initialSynopsis = cleanSynopsisText(video.description);
        synopsisView = a.text(initialSynopsis, 14, 0xd8e8edf7);
        synopsisView.setTag("detail-synopsis");
        synopsisView.setMaxLines(3);
        synopsisView.setEllipsize(TextUtils.TruncateAt.END);
        synopsisView.setLineSpacing(a.dp(3), 1.18f);
        synopsisView.setShadowLayer(a.dp(6), 0, a.dp(1), 0x80000000);
        synopsisView.setVisibility(initialSynopsis.isEmpty() ? View.GONE : View.VISIBLE);
        LinearLayout.LayoutParams synopsisLp = new LinearLayout.LayoutParams(-1, -2);
        synopsisLp.topMargin = a.dp(14);
        heroColumn.addView(synopsisView, synopsisLp);

        synopsisMoreBtn =
                DetailScreen.glassNavButton(a, "查看完整简介 ›", "synopsis", false, actions::synopsis);
        synopsisMoreBtn.setId(View.generateViewId());
        synopsisMoreBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f);
        synopsisMoreBtn.setMinHeight(a.dp(30));
        synopsisMoreBtn.setMinimumHeight(a.dp(30));
        synopsisMoreBtn.setPadding(a.dp(13), a.dp(4), a.dp(13), a.dp(4));
        synopsisMoreBtn.setVisibility(initialSynopsis.length() > 64 ? View.VISIBLE : View.GONE);
        LinearLayout.LayoutParams moreLp = new LinearLayout.LayoutParams(-2, a.dp(30));
        moreLp.topMargin = a.dp(8);
        heroColumn.addView(synopsisMoreBtn, moreLp);

        // 4. Primary Action Row directly below synopsis: Play + Episodes (+ optional Source Switch)
        LinearLayout buttons = a.row();
        buttons.setGravity(Gravity.CENTER_VERTICAL);
        buttons.setClipChildren(false);
        buttons.setClipToPadding(false);
        LinearLayout.LayoutParams buttonsLp = new LinearLayout.LayoutParams(-1, -2);
        buttonsLp.topMargin = a.dp(18);
        heroColumn.addView(buttons, buttonsLp);

        play = DetailScreen.heroPlayButton(a, playLabel, "detail-play", actions::play);
        play.setId(View.generateViewId());
        play.setEnabled(playEnabled);
        play.setSingleLine(true);
        play.setEllipsize(TextUtils.TruncateAt.END);
        play.setMinWidth(a.dp(168));
        play.setMinimumWidth(a.dp(168));
        play.setMaxWidth(a.dp(236));
        play.setPadding(a.dp(24), 0, a.dp(24), 0);
        buttons.addView(play, new LinearLayout.LayoutParams(-2, a.dp(46)));

        episodesBtn =
                DetailScreen.glassNavButton(
                        a,
                        episodesButtonLabel,
                        "detail-episodes-trigger",
                        false,
                        actions::episodes);
        episodesBtn.setId(View.generateViewId());
        episodesBtn.setEnabled(playEnabled);
        episodesBtn.setVisibility(playEnabled ? View.VISIBLE : View.GONE);
        episodesBtn.setSingleLine(true);
        episodesBtn.setEllipsize(TextUtils.TruncateAt.END);
        episodesBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f);
        episodesBtn.setPadding(a.dp(20), a.dp(10), a.dp(20), a.dp(10));
        LinearLayout.LayoutParams epBtnLp = new LinearLayout.LayoutParams(-2, a.dp(46));
        epBtnLp.leftMargin = a.dp(12);
        buttons.addView(episodesBtn, epBtnLp);

        seasonsBtn =
                DetailScreen.glassNavButton(
                        a,
                        "☰ 选季",
                        "detail-seasons-trigger",
                        false,
                        () -> {
                            if (seasonsAction != null) seasonsAction.run();
                        });
        seasonsBtn.setId(View.generateViewId());
        seasonsBtn.setVisibility(View.GONE);
        seasonsBtn.setSingleLine(true);
        seasonsBtn.setEllipsize(TextUtils.TruncateAt.END);
        seasonsBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f);
        seasonsBtn.setPadding(a.dp(18), a.dp(10), a.dp(18), a.dp(10));
        LinearLayout.LayoutParams seasonBtnLp = new LinearLayout.LayoutParams(-2, a.dp(46));
        seasonBtnLp.leftMargin = a.dp(12);
        buttons.addView(seasonsBtn, seasonBtnLp);

        scrapeBtn =
                DetailScreen.glassNavButton(
                        a,
                        "✨ 剧集刮削",
                        "detail-scrape-trigger",
                        false,
                        () -> {
                            if (scrapeAction != null) scrapeAction.run();
                        });
        scrapeBtn.setId(View.generateViewId());
        scrapeBtn.setVisibility(View.GONE);
        scrapeBtn.setSingleLine(true);
        scrapeBtn.setEllipsize(TextUtils.TruncateAt.END);
        scrapeBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13.5f);
        scrapeBtn.setPadding(a.dp(18), a.dp(10), a.dp(18), a.dp(10));
        LinearLayout.LayoutParams scrapeBtnLp = new LinearLayout.LayoutParams(-2, a.dp(46));
        scrapeBtnLp.leftMargin = a.dp(12);
        buttons.addView(scrapeBtn, scrapeBtnLp);

        switchSourceBtn =
                DetailScreen.glassNavButton(
                        a,
                        "⇄ 切换来源",
                        "detail-switch-source",
                        false,
                        () -> {
                            if (switchSourceAction != null) switchSourceAction.run();
                        });
        switchSourceBtn.setId(View.generateViewId());
        switchSourceBtn.setVisibility(View.GONE);
        switchSourceBtn.setSingleLine(true);
        switchSourceBtn.setEllipsize(TextUtils.TruncateAt.END);
        switchSourceBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13.5f);
        switchSourceBtn.setPadding(a.dp(18), a.dp(10), a.dp(18), a.dp(10));
        LinearLayout.LayoutParams swLp = new LinearLayout.LayoutParams(-2, a.dp(46));
        swLp.leftMargin = a.dp(12);
        buttons.addView(switchSourceBtn, swLp);

        // 5. Small subtitle beneath Play/Episodes showing last played route resource name (+
        // progress)
        episodeFileView =
                a.text(episodeFileCaption == null ? "" : episodeFileCaption, 12.5f, 0xb8ebebf5);
        episodeFileView.setTag("detail-episode-file");
        episodeFileView.setMaxLines(2);
        episodeFileView.setEllipsize(TextUtils.TruncateAt.END);
        episodeFileView.setLineSpacing(a.dp(2), 1.12f);
        episodeFileView.setShadowLayer(a.dp(6), 0, a.dp(1), 0x80000000);
        episodeFileView.setVisibility(
                episodeFileView.getText().length() > 0 ? View.VISIBLE : View.GONE);
        LinearLayout.LayoutParams fileLp = new LinearLayout.LayoutParams(-1, -2);
        fileLp.topMargin = a.dp(10);
        heroColumn.addView(episodeFileView, fileLp);

        historyView = a.text(historyCaption == null ? "" : historyCaption, 12, 0x9cd4dae8);
        historyView.setTag("detail-history");
        historyView.setVisibility(historyView.getText().length() > 0 ? View.VISIBLE : View.GONE);
        LinearLayout.LayoutParams historyLp = new LinearLayout.LayoutParams(-1, -2);
        historyLp.topMargin = a.dp(4);
        heroColumn.addView(historyView, historyLp);

        statusView = a.text("", 12.5f, MainActivity.MUTED);
        statusView.setTag("detail-loading");
        statusView.setVisibility(View.GONE);
        LinearLayout.LayoutParams statusLp = new LinearLayout.LayoutParams(-1, -2);
        statusLp.topMargin = a.dp(6);
        heroColumn.addView(statusView, statusLp);

        // 6. Display-Only Cast Strip with Circular Portrait Avatar Badges (directly below buttons)
        castSection = a.vertical();
        castSection.setTag("detail-cast-section");
        castSection.setFocusable(false);
        castSection.setFocusableInTouchMode(false);
        castSection.setClickable(false);
        castSection.setClipChildren(false);
        castSection.setClipToPadding(false);
        LinearLayout.LayoutParams castSecLp = new LinearLayout.LayoutParams(-1, -2);
        castSecLp.topMargin = a.dp(22);
        content.addView(castSection, castSecLp);

        TextView castLabel = a.text("演职员", 13.5f, 0xb8ebebf5);
        castLabel.setTypeface(null, Typeface.BOLD);
        castSection.addView(castLabel, new LinearLayout.LayoutParams(-2, -2));

        HorizontalScrollView castScroll = new HorizontalScrollView(a);
        castScroll.setTag("detail-cast-strip");
        castScroll.setHorizontalScrollBarEnabled(false);
        castScroll.setFocusable(false);
        castScroll.setFocusableInTouchMode(false);
        castScroll.setClickable(false);
        castScroll.setClipChildren(false);
        castScroll.setClipToPadding(false);
        castScroll.setPadding(0, a.dp(12), 0, a.dp(6));
        castRow = a.row();
        castRow.setFocusable(false);
        castRow.setFocusableInTouchMode(false);
        castRow.setClipChildren(false);
        castRow.setClipToPadding(false);
        castScroll.addView(castRow, new FrameLayout.LayoutParams(-2, -2));
        castSection.addView(castScroll, new LinearLayout.LayoutParams(-1, -2));

        // 7. Related Multi-Season Shelf (below cast strip if multi-season)
        seasonHost = a.vertical();
        seasonHost.setTag("detail-seasons");
        seasonHost.setClipChildren(false);
        seasonHost.setClipToPadding(false);
        LinearLayout.LayoutParams seasonLp = new LinearLayout.LayoutParams(-1, -2);
        seasonLp.topMargin = a.dp(22);
        content.addView(seasonHost, seasonLp);

        wireHeroFocus();
        applyRatings(0.0, -1);
        rebuildNameplateBadges();
        populateCast(ImmersivePoster.parseCastNamesFallback(video.director, video.actor));

        // Kick off verified official HD landscape artwork, ratings, and Douban metadata/cast
        boolean likelyTv =
                hasMultipleEpisodes(video) || (video.tag != null && video.tag.contains("剧"));
        String artwork =
                verifiedBackdrop != null && !verifiedBackdrop.trim().isEmpty()
                        ? verifiedBackdrop.trim()
                        : video.poster;
        cover.load(artwork, video.title, video.year, video.actor, video.director, true, likelyTv);

        ImmersivePoster.resolveMediaRatings(
                a,
                video,
                ratings -> {
                    if (ratings != null) {
                        applyRatings(ratings.douban, ratings.rtPercent);
                    }
                });

        ImmersivePoster.resolveSubjectDetails(
                a,
                video,
                details -> {
                    if (details == null) return;
                    officialDetails = details;
                    if (details.doubanScore >= 2.0 || details.rtPercent > 0) {
                        applyRatings(details.doubanScore, details.rtPercent);
                    } else {
                        rebuildNameplateBadges();
                    }
                    String existingSynopsis = cleanSynopsisText(this.video.description);
                    if (!details.intro.isEmpty()
                            && (existingSynopsis.isEmpty() || existingSynopsis.length() < 18)) {
                        this.video.description = details.intro;
                        updateSynopsisText(details.intro);
                    }
                    if (!details.cast.isEmpty()) {
                        populateCast(details.cast);
                    }
                    if (!details.posterUrl.isEmpty()
                            && cover.backdrop.wideBitmap == null
                            && (cover.backdrop.rawBitmap == null
                                    || cover.backdrop.rawBitmap.isRecycled())) {
                        a.poster(details.posterUrl, cover.image, true);
                    }
                });
    }

    private void wireHeroFocus() {
        int abovePlayId =
                synopsisMoreBtn.getVisibility() == View.VISIBLE
                        ? synopsisMoreBtn.getId()
                        : favorite.getId();
        play.setNextFocusUpId(abovePlayId);
        episodesBtn.setNextFocusUpId(abovePlayId);
        seasonsBtn.setNextFocusUpId(abovePlayId);
        scrapeBtn.setNextFocusUpId(abovePlayId);
        switchSourceBtn.setNextFocusUpId(abovePlayId);
        synopsisMoreBtn.setNextFocusUpId(favorite.getId());
        synopsisMoreBtn.setNextFocusDownId(play.isEnabled() ? play.getId() : View.NO_ID);
        favorite.setNextFocusUpId(back.getId());
        back.setNextFocusDownId(favorite.getId());
        if (synopsisMoreBtn.getVisibility() == View.VISIBLE) {
            favorite.setNextFocusDownId(synopsisMoreBtn.getId());
        } else if (play.isEnabled()) {
            favorite.setNextFocusDownId(play.getId());
        } else if (switchSourceBtn.getVisibility() == View.VISIBLE) {
            favorite.setNextFocusDownId(switchSourceBtn.getId());
        }
    }

    static String cleanSynopsisText(String raw) {
        if (raw == null) return "";
        String text = raw.trim();
        if (text.isEmpty() || TvCuratedHome.looksLikeMetadataSubtitle(text)) return "";
        return text;
    }

    private void updateSynopsisText(String raw) {
        String text = cleanSynopsisText(raw);
        synopsisView.setText(text);
        synopsisView.setVisibility(text.isEmpty() ? View.GONE : View.VISIBLE);
        synopsisMoreBtn.setVisibility(text.length() > 64 ? View.VISIBLE : View.GONE);
        wireHeroFocus();
    }

    void setDetectedSeasonCount(int seasons) {
        if (seasons > detectedSeasonCount) {
            detectedSeasonCount = seasons;
            rebuildNameplateBadges();
        }
    }

    void setBookmark(WatchHistory.Entry bookmark) {
        this.currentBookmark = bookmark;
        rebuildNameplateBadges();
    }

    void setLoadingStatus(String message) {
        String text = message == null ? "" : message.trim();
        statusView.setText(text);
        statusView.setVisibility(text.isEmpty() ? View.GONE : View.VISIBLE);
    }

    void setSeasonsAction(String label, Runnable action) {
        this.seasonsAction = action;
        if (action == null || label == null || label.trim().isEmpty()) {
            seasonsBtn.setVisibility(View.GONE);
        } else {
            seasonsBtn.setText(label.trim());
            seasonsBtn.setVisibility(View.VISIBLE);
        }
        wireHeroFocus();
    }

    void setScrapeAction(Runnable action) {
        this.scrapeAction = action;
        scrapeBtn.setVisibility(action == null ? View.GONE : View.VISIBLE);
        wireHeroFocus();
    }

    void setSourceSwitchAction(String label, Runnable action) {
        this.switchSourceAction = action;
        if (action == null || label == null || label.trim().isEmpty()) {
            switchSourceBtn.setVisibility(View.GONE);
        } else {
            switchSourceBtn.setText(label.trim());
            switchSourceBtn.setVisibility(View.VISIBLE);
        }
        wireHeroFocus();
    }

    /**
     * Patches the live detail screen in-place when async source detail / curated lookup finishes,
     * keeping the official backdrop and Douban enrichment completely intact with zero screen flash.
     */
    void bindResolvedVideo(
            Cms.Site resolvedSite,
            Cms.Video resolvedVideo,
            WatchHistory.Entry bookmark,
            boolean isFavorite,
            String playLabel,
            String episodesButtonLabel,
            String episodeFileCaption,
            String historyCaption) {
        if (resolvedSite != null) this.site = resolvedSite;
        if (resolvedVideo != null) this.video = resolvedVideo;
        this.currentBookmark = bookmark;

        boolean playable =
                this.video != null && this.video.lines != null && !this.video.lines.isEmpty();
        play.setEnabled(playable);
        play.setText(playLabel != null && !playLabel.isEmpty() ? playLabel : "► 开始播放");
        episodesBtn.setEnabled(playable);
        episodesBtn.setVisibility(playable ? View.VISIBLE : View.GONE);
        if (episodesButtonLabel != null && !episodesButtonLabel.isEmpty()) {
            episodesBtn.setText(episodesButtonLabel);
        }
        setFavorite(isFavorite);

        String continueLine =
                formatContinuePlaySubtitle(bookmark, episodeFileCaption, historyCaption);
        if (!continueLine.isEmpty()) {
            episodeFileView.setText(continueLine);
            episodeFileView.setVisibility(View.VISIBLE);
            historyView.setText("");
            historyView.setVisibility(View.GONE);
        } else {
            episodeFileView.setText(episodeFileCaption == null ? "" : episodeFileCaption);
            episodeFileView.setVisibility(
                    episodeFileView.getText().length() > 0 ? View.VISIBLE : View.GONE);
            historyView.setText(historyCaption == null ? "" : historyCaption);
            historyView.setVisibility(
                    historyView.getText().length() > 0 ? View.VISIBLE : View.GONE);
        }

        String resolvedDesc = this.video != null ? cleanSynopsisText(this.video.description) : "";
        if (!resolvedDesc.isEmpty()
                && (synopsisView.getText().length() < 18
                        || officialDetails == null
                        || officialDetails.intro.isEmpty())) {
            updateSynopsisText(resolvedDesc);
        }
        if (this.video != null
                && (officialDetails == null || officialDetails.cast.isEmpty())
                && castRow.getChildCount() == 0) {
            populateCast(
                    ImmersivePoster.parseCastNamesFallback(this.video.director, this.video.actor));
        }
        if (this.video != null
                && cover.backdrop.wideBitmap == null
                && this.video.poster != null
                && !this.video.poster.trim().isEmpty()) {
            cover.load(
                    this.video.poster,
                    this.video.title,
                    this.video.year,
                    this.video.actor,
                    this.video.director,
                    true,
                    hasMultipleEpisodes(this.video));
        }
        rebuildNameplateBadges();
        wireHeroFocus();
    }

    static String formatContinuePlaySubtitle(
            WatchHistory.Entry bookmark, String episodeFileCaption, String historyCaption) {
        if (bookmark == null) return "";
        String resource = episodeFileCaption == null ? "" : episodeFileCaption.trim();
        if (resource.isEmpty()) {
            String line = bookmark.line == null ? "" : bookmark.line.trim();
            String ep = bookmark.episode == null ? "" : bookmark.episode.trim();
            if (!line.isEmpty() && !ep.isEmpty()) resource = line + "  ·  " + ep;
            else if (!ep.isEmpty()) resource = ep;
            else resource = line;
        }
        if (resource.isEmpty()) return historyCaption == null ? "" : historyCaption.trim();
        String progress =
                bookmark.complete()
                        ? "已看完"
                        : PlaybackController.formatTime(bookmark.position)
                                + (bookmark.duration > 0
                                        ? " / " + PlaybackController.formatTime(bookmark.duration)
                                        : "");
        if (!progress.isEmpty()) {
            return "上次播放：" + resource + "  ·  " + progress;
        }
        return "上次播放：" + resource;
    }

    static String formatEpisodeFileCaption(Cms.Line line, Cms.Episode episode) {
        if (episode == null) return "";
        String lineName = line == null || line.name == null ? "" : line.name.trim();
        String epName = episode.name == null ? "" : episode.name.trim();
        String urlFile = extractFilenameFromUrl(episode.url);
        String display = epName;
        if (!urlFile.isEmpty()
                && !urlFile.equalsIgnoreCase(epName)
                && (epName.isEmpty()
                        || epName.length() <= 8
                        || "播放".equals(epName)
                        || "正片".equals(epName)
                        || "高清".equals(epName)
                        || "HD".equalsIgnoreCase(epName))) {
            display = epName.isEmpty() ? urlFile : (epName + " · " + urlFile);
        }
        if (display.isEmpty()) return "";
        return lineName.isEmpty() ? display : (lineName + "  ·  " + display);
    }

    static String extractFilenameFromUrl(String rawUrl) {
        if (rawUrl == null || rawUrl.trim().isEmpty()) return "";
        String trimmed = rawUrl.trim();
        if (!trimmed.regionMatches(true, 0, "http://", 0, 7)
                && !trimmed.regionMatches(true, 0, "https://", 0, 8)) {
            return "";
        }
        String path = extractRawHttpPath(trimmed);
        if (path.isEmpty()) return "";
        int slash = path.lastIndexOf('/');
        String base = slash >= 0 ? path.substring(slash + 1) : path;
        if (base.isEmpty()) return "";
        String decoded = MediaBadges.percentDecodeUtf8PreservePlus(base).trim();
        String lower = decoded.toLowerCase(java.util.Locale.ROOT);
        if (lower.equals("index.m3u8")
                || lower.equals("playlist.m3u8")
                || lower.equals("master.m3u8")
                || lower.equals("video.m3u8")
                || lower.equals("play.m3u8")
                || lower.equals("stream.m3u8")
                || lower.equals("stream.ts")
                || lower.endsWith(".php")
                || lower.endsWith(".html")
                || decoded.length() < 5
                || decoded.matches("^[0-9a-fA-F]{16,}\\.[a-z0-9]{2,5}$")) {
            return "";
        }
        if (lower.endsWith(".mp4")
                || lower.endsWith(".mkv")
                || lower.endsWith(".mov")
                || lower.endsWith(".avi")
                || lower.endsWith(".ts")
                || lower.endsWith(".flv")
                || lower.endsWith(".webm")
                || lower.endsWith(".m3u8")) {
            return decoded;
        }
        return "";
    }

    static String extractRawHttpPath(String url) {
        if (url == null) return "";
        int schemeEnd = url.indexOf("://");
        if (schemeEnd < 0) return "";
        int authorityStart = schemeEnd + 3;
        int end = url.length();
        int queryIdx = url.indexOf('?', authorityStart);
        if (queryIdx >= 0 && queryIdx < end) end = queryIdx;
        int hashIdx = url.indexOf('#', authorityStart);
        if (hashIdx >= 0 && hashIdx < end) end = hashIdx;
        int pathStart = url.indexOf('/', authorityStart);
        if (pathStart < 0 || pathStart >= end) return "";
        return url.substring(pathStart, end);
    }

    void updateEpisodeCaption(String caption, String buttonLabel) {
        if (caption != null) {
            String continueLine = formatContinuePlaySubtitle(currentBookmark, caption, "");
            if (!continueLine.isEmpty()) {
                episodeFileView.setText(continueLine);
                episodeFileView.setVisibility(View.VISIBLE);
                historyView.setVisibility(View.GONE);
            } else {
                episodeFileView.setText(caption);
                episodeFileView.setVisibility(caption.isEmpty() ? View.GONE : View.VISIBLE);
            }
        }
        if (buttonLabel != null && !buttonLabel.isEmpty()) {
            episodesBtn.setText(buttonLabel);
        }
        rebuildNameplateBadges();
    }

    private TextView buildNameplatePill(
            String text, int textColor, int fillColor, int strokeColor) {
        TextView pill = host.text(text, 12.5f, textColor);
        pill.setSingleLine(true);
        pill.setTypeface(null, Typeface.BOLD);
        pill.setIncludeFontPadding(false);
        pill.setPadding(host.dp(10), host.dp(4.5f), host.dp(10), host.dp(4.5f));
        pill.setBackground(MobileDetailScreen.glassBg(host, fillColor, strokeColor, 8));
        return pill;
    }

    private void rebuildNameplateBadges() {
        nameplateRow.removeAllViews();
        if (video == null) {
            nameplateRow.setVisibility(View.GONE);
            return;
        }
        boolean reduceTransparency =
                host.prefs != null && host.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false);
        int neutralFill = reduceTransparency ? 0xe6202633 : 0x52161c28;
        int neutralStroke = reduceTransparency ? 0x99ffffff : 0x42ffffff;

        // 1. Official facts nameplates: Year, Country/Region, Season count (when multi-season),
        //    real episode count / duration, and primary genre
        java.util.List<String> factTokens =
                ImmersivePoster.buildOfficialFactBadges(
                        video, officialDetails, detectedSeasonCount);
        for (String token : factTokens) {
            if (token == null || token.trim().isEmpty()) continue;
            TextView pill =
                    buildNameplatePill(token.trim(), 0xf2f4f7fc, neutralFill, neutralStroke);
            nameplateRow.addView(pill, new android.view.ViewGroup.LayoutParams(-2, -2));
        }

        // 2. 4K / HDR / Dolby Vision / Atmos technical spec nameplate badges
        WatchHistory.Entry bookmark = currentBookmark;
        if (bookmark == null && site != null && video.id != null) {
            for (WatchHistory.Entry entry : host.watchHistory()) {
                if (site.key.equals(entry.site) && video.id.equals(entry.id)) {
                    bookmark = entry;
                    break;
                }
            }
        }
        Cms.Line activeLine = null;
        Cms.Episode activeEpisode = null;
        if (video.lines != null && !video.lines.isEmpty()) {
            int[] sel =
                    TvDetailHost.initialSelection(
                            video,
                            bookmark,
                            host.prefs.getString(Prefs.PREFERRED_LINE, ""),
                            host.current == null ? null : host.current.selection,
                            host.prefs.getBoolean(Prefs.EPISODES_DESCENDING, false));
            int lineIdx = Math.max(0, Math.min(sel[0], video.lines.size() - 1));
            activeLine = video.lines.get(lineIdx);
            if (activeLine.episodes != null && !activeLine.episodes.isEmpty()) {
                activeEpisode = activeLine.episodes.get(0);
                if (bookmark != null
                        && activeLine.name.equals(bookmark.line)
                        && bookmark.episode != null) {
                    for (Cms.Episode ep : activeLine.episodes) {
                        if (bookmark.episode.equals(ep.name)) {
                            activeEpisode = ep;
                            break;
                        }
                    }
                }
            }
        }
        List<MediaBadges.Badge> specs =
                MediaBadgeView.extractForHero(host, video.remarks, activeLine, activeEpisode);
        if (specs != null) {
            int maxSpecs = Math.min(MediaBadgeView.HERO_MAX_BADGES, specs.size());
            for (int i = 0; i < maxSpecs; i++) {
                TextView specPill = MediaBadgeView.createPill(host, specs.get(i), false, true);
                nameplateRow.addView(specPill, new android.view.ViewGroup.LayoutParams(-2, -2));
            }
        }

        // 3. Authentic Douban & Rotten Tomatoes rating nameplates
        double db = resolvedDouban;
        if (db < 2.0) {
            db = Cms.parseValidDoubanScore(video.doubanScore);
        }
        if (db >= 2.0 && db <= 9.9) {
            TextView dbPill =
                    buildNameplatePill(
                            String.format(java.util.Locale.US, "豆瓣 %.1f", db),
                            0xff6ee7b7,
                            reduceTransparency ? 0xe6113a26 : 0x4200b51d,
                            0x7034d399);
            dbPill.setTag("detail-douban-rating");
            nameplateRow.addView(dbPill, new android.view.ViewGroup.LayoutParams(-2, -2));
        }
        if (resolvedRt >= 1 && resolvedRt <= 100) {
            TextView rtPill =
                    buildNameplatePill(
                            "烂番茄 " + resolvedRt + "%",
                            0xffffb4a2,
                            reduceTransparency ? 0xe6451b14 : 0x42fa320a,
                            0x70ff6b4a);
            rtPill.setTag("detail-rt-rating");
            nameplateRow.addView(rtPill, new android.view.ViewGroup.LayoutParams(-2, -2));
        }

        // 4. Active source pill
        if (site != null
                && site.name != null
                && !site.name.trim().isEmpty()
                && !TvCuratedHome.isCuratedSite(site)) {
            TextView srcPill =
                    buildNameplatePill(
                            site.name.trim(),
                            0xdceef3ff,
                            reduceTransparency ? 0xe61d2433 : 0x36ffffff,
                            0x48ffffff);
            nameplateRow.addView(srcPill, new android.view.ViewGroup.LayoutParams(-2, -2));
        }

        nameplateRow.setVisibility(nameplateRow.getChildCount() > 0 ? View.VISIBLE : View.GONE);
    }

    private static boolean hasMultipleEpisodes(Cms.Video video) {
        if (video == null || video.lines == null) return false;
        for (Cms.Line line : video.lines) {
            if (line != null && line.episodes != null && line.episodes.size() > 1) return true;
        }
        return false;
    }

    private void applyRatings(double dbScore, int rtPercent) {
        if (dbScore >= 2.0 && dbScore <= 9.9) {
            resolvedDouban = dbScore;
        }
        if (rtPercent >= 1 && rtPercent <= 100) {
            resolvedRt = rtPercent;
        }
        rebuildNameplateBadges();
    }

    private void populateCast(List<ImmersivePoster.CastMember> members) {
        castRow.removeAllViews();
        if (members == null || members.isEmpty()) {
            castSection.setVisibility(View.GONE);
            return;
        }
        castSection.setVisibility(View.VISIBLE);
        int limit = Math.min(12, members.size());
        for (int i = 0; i < limit; i++) {
            LinearLayout card = buildCastCard(members.get(i), i);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(host.dp(88), -2);
            if (i > 0) lp.leftMargin = host.dp(18);
            castRow.addView(card, lp);
        }
    }

    static int castAvatarAccent(String name) {
        String safe = name == null ? "" : name;
        return AVATAR_ACCENTS[(safe.hashCode() & 0x7fffffff) % AVATAR_ACCENTS.length];
    }

    private LinearLayout buildCastCard(final ImmersivePoster.CastMember member, int index) {
        final String safeName = member == null || member.name == null ? "" : member.name;
        final String safeAvatar =
                member == null || member.avatarUrl == null ? "" : member.avatarUrl;
        LinearLayout card = host.vertical();
        card.setTag("detail-cast:" + index);
        card.setGravity(Gravity.CENTER_HORIZONTAL);
        // Display-only: cast cards must never steal D-pad focus or trigger clicks.
        card.setFocusable(false);
        card.setFocusableInTouchMode(false);
        card.setClickable(false);
        card.setClipChildren(false);
        card.setClipToPadding(false);
        card.setPadding(host.dp(4), host.dp(4), host.dp(4), host.dp(4));

        int avatarPx = host.dp(58);
        final FrameLayout avatarFrame = new FrameLayout(host);
        int accent = castAvatarAccent(safeName);
        GradientDrawable monogramBg = new GradientDrawable();
        monogramBg.setShape(GradientDrawable.OVAL);
        monogramBg.setColor(accent);
        avatarFrame.setBackground(monogramBg);
        avatarFrame.setOutlineProvider(
                new ViewOutlineProvider() {
                    @Override
                    public void getOutline(View v, Outline outline) {
                        outline.setOval(0, 0, v.getWidth(), v.getHeight());
                    }
                });
        avatarFrame.setClipToOutline(true);

        String initial =
                safeName.isEmpty() ? "?" : safeName.substring(0, Math.min(1, safeName.length()));
        TextView monogram = host.text(initial, 19, 0xf0ffffff);
        monogram.setTypeface(null, Typeface.BOLD);
        monogram.setGravity(Gravity.CENTER);
        avatarFrame.addView(monogram, new FrameLayout.LayoutParams(-1, -1));

        if (!safeAvatar.isEmpty()) {
            ImageView photo = new ImageView(host);
            photo.setScaleType(ImageView.ScaleType.CENTER_CROP);
            avatarFrame.addView(photo, new FrameLayout.LayoutParams(-1, -1));
            host.poster(safeAvatar, photo, false);
        }

        FrameLayout ringWrap = new FrameLayout(host);
        int ringPad = host.dp(2);
        ringWrap.setPadding(ringPad, ringPad, ringPad, ringPad);
        GradientDrawable ring = new GradientDrawable();
        ring.setShape(GradientDrawable.OVAL);
        ring.setColor(0x00000000);
        ring.setStroke(Math.max(1, host.dp(1)), 0x36ffffff);
        ringWrap.setBackground(ring);
        ringWrap.addView(avatarFrame, new FrameLayout.LayoutParams(avatarPx, avatarPx));
        card.addView(
                ringWrap,
                new LinearLayout.LayoutParams(avatarPx + ringPad * 2, avatarPx + ringPad * 2));

        TextView nameTv = host.text(safeName, 12.5f, 0xeeffffff);
        nameTv.setSingleLine(true);
        nameTv.setEllipsize(TextUtils.TruncateAt.END);
        nameTv.setGravity(Gravity.CENTER);
        nameTv.setTypeface(null, Typeface.BOLD);
        LinearLayout.LayoutParams nameLp = new LinearLayout.LayoutParams(-1, -2);
        nameLp.topMargin = host.dp(8);
        card.addView(nameTv, nameLp);

        if (!member.role.isEmpty()) {
            TextView roleTv = host.text(member.role, 11, 0x9cd4dae6);
            roleTv.setSingleLine(true);
            roleTv.setEllipsize(TextUtils.TruncateAt.END);
            roleTv.setGravity(Gravity.CENTER);
            LinearLayout.LayoutParams roleLp = new LinearLayout.LayoutParams(-1, -2);
            roleLp.topMargin = host.dp(2);
            card.addView(roleTv, roleLp);
        }
        return card;
    }

    private void styleHeartFavorite(boolean focused, boolean selected) {
        FocusMotion.unclipAncestors(favorite);
        GradientDrawable d = new GradientDrawable();
        d.setShape(GradientDrawable.OVAL);
        if (focused) {
            d.setColor(0xffffffff);
            d.setStroke(Math.max(1, host.dp(1.5f)), 0xffffffff);
            favorite.setTextColor(selected ? 0xffff3b30 : 0xff14161c);
            favorite.setElevation(host.dp(6));
            favorite.animate().scaleX(1.14f).scaleY(1.14f).setDuration(130).start();
        } else if (selected) {
            d.setColor(0x3aff3b30);
            d.setStroke(Math.max(1, host.dp(1)), 0x80ff453a);
            favorite.setTextColor(0xffff3b30);
            favorite.setElevation(0);
            favorite.animate().scaleX(1f).scaleY(1f).setDuration(130).start();
        } else {
            d.setColor(0x58181d28);
            d.setStroke(Math.max(1, host.dp(1)), 0x42ffffff);
            favorite.setTextColor(0xecffffff);
            favorite.setElevation(0);
            favorite.animate().scaleX(1f).scaleY(1f).setDuration(130).start();
        }
        favorite.setBackground(d);
    }

    void setFavorite(boolean selected) {
        favorite.setText(selected ? "♥" : "♡");
        favorite.setSelected(selected);
        favorite.setContentDescription(selected ? "已收藏，点击取消收藏" : "收藏");
        styleHeartFavorite(favorite.hasFocus(), selected);
    }
}
