package com.pilipala.marcomovie;

import android.graphics.Color;
import android.graphics.Typeface;
import android.net.Uri;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.Surface;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.SeekBar;
import android.widget.TextView;
import java.util.Map;
import java.util.Objects;

/**
 * Portrait inline {@code 16:9} mini-player mounted at the top of {@link MobileDetailScreen} when
 * {@link Prefs#DETAIL_TAP_MODE} is {@code 0} ("详情页内嵌小窗起播"). Intercepts resolved episodes from
 * {@link PlaybackController#openPlayer}, plays directly inside the detail page, supports automatic
 * TheIntroDB / manual intro skip, and seamlessly expands to landscape fullscreen without
 * re-resolving the stream URL.
 */
final class MobileInlinePlayer {
    private final MainActivity a;
    private final FrameLayout hostSlot;
    private final Runnable onClosed;
    private final FrameLayout container;
    private final VideoOutput surfaceView;
    private final TextView titleLabel;
    private final TextView statusLabel;
    private final TextView playPauseBtn;
    private final TextView clockLabel;
    private final SeekBar seekBar;

    private Cms.Site site;
    private Cms.Video video;
    private Cms.Line activeLine;
    private Cms.Episode rawEpisode;
    private Cms.Episode resolvedEpisode;
    private MoviePlayer player;
    private Surface renderSurface;
    private boolean prepared;
    private boolean userSeeking;
    private boolean closed;
    private int introEndSec = -1;
    private int outroStartSec = -1;
    private boolean introSkipped;

    private final Runnable ticker =
            new Runnable() {
                @Override
                public void run() {
                    if (closed || player == null || !prepared) return;
                    try {
                        int pos = player.getCurrentPosition();
                        int dur = player.getDuration();
                        if (!userSeeking && dur > 0) {
                            seekBar.setMax(dur);
                            seekBar.setProgress(pos);
                            clockLabel.setText(
                                    PlaybackController.formatTime(pos)
                                            + " / "
                                            + PlaybackController.formatTime(dur));
                        }
                        if (!introSkipped && introEndSec > 0 && pos < introEndSec * 1000) {
                            introSkipped = true;
                            player.seekTo(introEndSec * 1000);
                            a.toast("已自动跳过片头 (" + introEndSec + "s)");
                        }
                        if (outroStartSec > 0
                                && dur > (outroStartSec + 5) * 1000
                                && pos >= dur - outroStartSec * 1000) {
                            outroStartSec = -1;
                            stepNextEpisode();
                            return;
                        }
                        saveHistoryProgress(pos, dur);
                    } catch (Exception ignored) {
                    }
                    a.ui.postDelayed(this, 1000);
                }
            };

    MobileInlinePlayer(MainActivity activity, FrameLayout hostSlot, Runnable onClosed) {
        this.a = activity;
        this.hostSlot = hostSlot;
        this.onClosed = onClosed;

        int stageH = Math.round(activity.windowWidth() * 9f / 16f);
        int topInset = activity.statusBarHeight();
        container = new FrameLayout(activity);
        container.setBackgroundColor(Color.BLACK);
        FrameLayout.LayoutParams slotLp = new FrameLayout.LayoutParams(-1, stageH + topInset);
        hostSlot.removeAllViews();
        hostSlot.addView(container, slotLp);
        hostSlot.setVisibility(View.VISIBLE);

        FrameLayout videoArea = new FrameLayout(activity);
        FrameLayout.LayoutParams vLp = new FrameLayout.LayoutParams(-1, stageH, Gravity.BOTTOM);
        container.addView(videoArea, vLp);

        surfaceView = new VideoOutput(activity, activity.prefs.getInt(Prefs.VIDEO_OUTPUT, 0) == 1);
        videoArea.addView(surfaceView, new FrameLayout.LayoutParams(-1, -1, Gravity.CENTER));

        // Top bar inside inline window: Collapse '×', Title, Expand Fullscreen '⛶'
        LinearLayout topBar = activity.row();
        topBar.setGravity(Gravity.CENTER_VERTICAL);
        topBar.setPadding(activity.dp(10), activity.dp(6), activity.dp(10), activity.dp(6));
        topBar.setBackgroundColor(0x88000000);

        TextView closeBtn = activity.text("✕ 收起", 11.5f, Color.WHITE);
        closeBtn.setPadding(activity.dp(10), activity.dp(4), activity.dp(10), activity.dp(4));
        closeBtn.setBackground(activity.bg(0x40ffffff, 999));
        UiWidgets.bindTouchFeedback(closeBtn);
        closeBtn.setOnClickListener(
                v -> {
                    detach();
                    if (this.onClosed != null) this.onClosed.run();
                });
        topBar.addView(closeBtn);

        titleLabel = activity.text("", 12.5f, Color.WHITE);
        titleLabel.setTypeface(null, Typeface.BOLD);
        titleLabel.setSingleLine(true);
        titleLabel.setEllipsize(TextUtils.TruncateAt.END);
        titleLabel.setPadding(activity.dp(8), 0, activity.dp(8), 0);
        topBar.addView(titleLabel, new LinearLayout.LayoutParams(0, -2, 1f));

        TextView expandBtn = activity.text("⛶ 横屏全屏", 11.5f, 0xff08120e);
        expandBtn.setTypeface(null, Typeface.BOLD);
        expandBtn.setPadding(activity.dp(11), activity.dp(4), activity.dp(11), activity.dp(4));
        expandBtn.setBackground(activity.bg(activity.mobileAccentColor(), 999));
        UiWidgets.bindTouchFeedback(expandBtn);
        expandBtn.setOnClickListener(v -> expandToFullscreen());
        topBar.addView(expandBtn);

        videoArea.addView(topBar, new FrameLayout.LayoutParams(-1, -2, Gravity.TOP));

        statusLabel = activity.text("正在解析播放地址…", 12.5f, 0xffe5e7eb);
        statusLabel.setPadding(activity.dp(14), activity.dp(7), activity.dp(14), activity.dp(7));
        statusLabel.setBackground(activity.bg(0xb8141a18, 999));
        videoArea.addView(statusLabel, new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER));

        // Bottom mini transport bar
        LinearLayout bottomBar = activity.row();
        bottomBar.setGravity(Gravity.CENTER_VERTICAL);
        bottomBar.setPadding(activity.dp(10), activity.dp(4), activity.dp(10), activity.dp(4));
        bottomBar.setBackgroundColor(0x99000000);

        playPauseBtn = activity.text("❚❚", 13f, Color.WHITE);
        playPauseBtn.setTypeface(null, Typeface.BOLD);
        playPauseBtn.setPadding(activity.dp(8), activity.dp(4), activity.dp(8), activity.dp(4));
        UiWidgets.bindTouchFeedback(playPauseBtn);
        playPauseBtn.setOnClickListener(v -> togglePlayPause());
        bottomBar.addView(playPauseBtn);

        seekBar = new SeekBar(activity);
        UiCompat.tintSeekBar(seekBar, activity.mobileAccentColor(), Color.WHITE);
        seekBar.setOnSeekBarChangeListener(
                new SeekBar.OnSeekBarChangeListener() {
                    @Override
                    public void onProgressChanged(SeekBar b, int progress, boolean fromUser) {
                        if (fromUser && player != null && prepared) {
                            clockLabel.setText(
                                    PlaybackController.formatTime(progress)
                                            + " / "
                                            + PlaybackController.formatTime(player.getDuration()));
                        }
                    }

                    @Override
                    public void onStartTrackingTouch(SeekBar b) {
                        userSeeking = true;
                    }

                    @Override
                    public void onStopTrackingTouch(SeekBar b) {
                        userSeeking = false;
                        if (player != null && prepared) {
                            player.seekTo(b.getProgress());
                        }
                    }
                });
        bottomBar.addView(seekBar, new LinearLayout.LayoutParams(0, activity.dp(26), 1f));

        clockLabel = activity.text("--:-- / --:--", 10.5f, 0xffe5e7eb);
        clockLabel.setPadding(activity.dp(4), 0, 0, 0);
        bottomBar.addView(clockLabel);

        videoArea.addView(bottomBar, new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM));

        // Tap video center to toggle play/pause; double tap to expand fullscreen
        videoArea.setOnClickListener(v -> togglePlayPause());

        surfaceView.listen(
                new VideoOutput.Listener() {
                    @Override
                    public void available(Surface value) {
                        renderSurface = value;
                        if (player != null) {
                            player.setSurface(value);
                        } else if (resolvedEpisode != null) {
                            startResolvedStream();
                        }
                    }

                    @Override
                    public void resized(int width, int height) {
                        if (player != null) player.setSurfaceSize(width, height);
                    }

                    @Override
                    public void destroyed() {
                        renderSurface = null;
                        if (player != null) player.setSurface(null);
                    }
                });
    }

    void startEpisode(
            Cms.Site s,
            Cms.Video v,
            Cms.Line line,
            Cms.Episode ep,
            int tmdbId,
            boolean isTv,
            int seasonNum,
            int epNum) {
        releaseInternalPlayer();
        this.site = s;
        this.video = v;
        this.activeLine = line;
        this.rawEpisode = ep;
        this.resolvedEpisode = null;
        this.introSkipped = false;
        this.introEndSec = Prefs.clampSkipSeconds(a.prefs.getInt(Prefs.SKIP_INTRO, 0));
        this.outroStartSec = Prefs.clampSkipSeconds(a.prefs.getInt(Prefs.SKIP_OUTRO, 0));

        a.activeLine = line;
        a.activeEpisode = ep;
        a.inlinePlayer = this;
        a.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        EpisodeNameCleaner.CleanedEpisode cleaned =
                EpisodeNameCleaner.clean(ep.name, v.title, epNum);
        titleLabel.setText(v.title + " · " + cleaned.shortLabel);
        statusLabel.setText("正在解析 " + cleaned.shortLabel + " …");
        statusLabel.setVisibility(View.VISIBLE);

        if (tmdbId > 0) {
            TmdbService.lookupIntroDbAsync(
                    a,
                    tmdbId,
                    isTv,
                    seasonNum,
                    epNum,
                    ts -> {
                        if (ts != null && !closed) {
                            if (introEndSec <= 0 && ts.introEndSec > 0) {
                                introEndSec = ts.introEndSec;
                            }
                            if (outroStartSec <= 0 && ts.outroStartSec > 0) {
                                outroStartSec = ts.outroStartSec;
                            }
                        }
                    });
        }

        a.resolvePlayer(s, v, line, ep);
    }

    boolean acceptsResolved(Cms.Site s, Cms.Video v) {
        return !closed
                && hostSlot.isAttachedToWindow()
                && site != null
                && video != null
                && Objects.equals(site.key, s.key)
                && Objects.equals(video.id, v.id);
    }

    void playResolved(Cms.Site s, Cms.Video v, Cms.Episode resolved) {
        this.resolvedEpisode = resolved;
        if (renderSurface != null && renderSurface.isValid()) {
            startResolvedStream();
        }
    }

    private void startResolvedStream() {
        releaseInternalPlayer();
        final Cms.Episode ep = resolvedEpisode;
        if (ep == null || closed) return;
        statusLabel.setText("正在缓冲画面…");
        statusLabel.setVisibility(View.VISIBLE);
        final int ticket = a.generation;
        a.worker.execute(
                () -> {
                    try {
                        Map<String, String> headers =
                                Cms.inheritedHeaders(site.api, ep.url, site.headers);
                        Cms.mergeHeaders(headers, ep.headers);
                        String normUrl =
                                Cms.isHttp(ep.url)
                                        ? Cms.normalizeHttp(LocalProxy.rewrite(ep.url))
                                        : LocalProxy.rewrite(ep.url);
                        String effective = normUrl;
                        String mime = ep.media != null ? ep.media.optString("mimeType", "") : "";
                        if (a.prefs.getBoolean(Prefs.HLS_PROXY_ENABLED, true)
                                && HlsStreamProxy.looksLikeHls(normUrl, mime)) {
                            try {
                                SourceController.ensureProxy(
                                        a, a.config != null ? a.config : new Cms.Config());
                                effective =
                                        HlsStreamProxy.register(
                                                normUrl,
                                                headers,
                                                a.prefs.getBoolean(Prefs.HLS_AD_STRIP, false));
                            } catch (Exception ignored) {
                            }
                        }
                        final MoviePlayer mp = new MoviePlayer(a);
                        mp.configureDefaultAudio();
                        mp.setDataSource(a, Uri.parse(effective), headers);
                        mp.setOptions(ep.media);
                        a.ui.post(
                                () -> {
                                    if (closed
                                            || a.isFinishing()
                                            || ticket != a.generation
                                            || renderSurface == null
                                            || !renderSurface.isValid()) {
                                        mp.release();
                                        return;
                                    }
                                    player = mp;
                                    mp.setSurface(renderSurface);
                                    mp.setOnPreparedListener(
                                            p -> {
                                                prepared = true;
                                                statusLabel.setVisibility(View.GONE);
                                                float spd = a.prefs.getFloat(Prefs.PLAY_SPEED, 1f);
                                                if (Math.abs(spd - 1f) > 0.02f) p.setSpeed(spd);
                                                if (a.resumeAt > 0) {
                                                    p.seekTo(a.resumeAt);
                                                    a.resumeAt = 0;
                                                }
                                                p.start();
                                                playPauseBtn.setText("❚❚");
                                                a.ui.removeCallbacks(ticker);
                                                a.ui.post(ticker);
                                            });
                                    mp.setOnCompletionListener(p -> stepNextEpisode());
                                    mp.setOnErrorListener(
                                            (p, what, extra) -> {
                                                statusLabel.setVisibility(View.VISIBLE);
                                                statusLabel.setText("小窗解码异常，点击右上角「横屏全屏」切核重试");
                                                return true;
                                            });
                                    mp.prepareAsync();
                                });
                    } catch (Exception e) {
                        a.ui.post(
                                () -> {
                                    statusLabel.setVisibility(View.VISIBLE);
                                    statusLabel.setText("播放失败：" + a.message(e));
                                });
                    }
                });
    }

    private void stepNextEpisode() {
        if (!a.prefs.getBoolean(Prefs.AUTO_NEXT, true)
                || activeLine == null
                || rawEpisode == null) {
            return;
        }
        int idx = activeLine.episodes.indexOf(rawEpisode);
        if (idx >= 0 && idx + 1 < activeLine.episodes.size()) {
            Cms.Episode next = activeLine.episodes.get(idx + 1);
            a.resumeAt = 0;
            startEpisode(site, video, activeLine, next, 0, true, 1, idx + 2);
        }
    }

    private void togglePlayPause() {
        if (player == null || !prepared) return;
        if (player.isPlaying()) {
            player.pause();
            playPauseBtn.setText("▶");
        } else {
            player.start();
            playPauseBtn.setText("❚❚");
        }
    }

    void pause() {
        if (player != null && prepared && player.isPlaying()) {
            player.pause();
            playPauseBtn.setText("▶");
        }
    }

    private void expandToFullscreen() {
        Cms.Site s = site;
        Cms.Video v = video;
        Cms.Line l = activeLine;
        Cms.Episode raw = rawEpisode;
        Cms.Episode res = resolvedEpisode;
        int pos = (player != null && prepared) ? Math.max(0, player.getCurrentPosition()) : 0;
        detach();
        if (onClosed != null) onClosed.run();
        a.activeLine = l;
        a.activeEpisode = raw;
        a.resumeAt = pos;
        if (res != null) {
            PlaybackController.openPlayer(a, s, v, res);
        } else if (s != null && v != null && l != null && raw != null) {
            a.resolvePlayer(s, v, l, raw);
        }
    }

    private void saveHistoryProgress(int pos, int dur) {
        if (site == null || video == null || activeLine == null || rawEpisode == null || dur <= 0) {
            return;
        }
        WatchHistory.Entry entry = new WatchHistory.Entry();
        entry.site = site.key;
        entry.id = video.id;
        entry.title = video.title;
        entry.poster = video.poster;
        entry.line = activeLine.name;
        entry.episode = rawEpisode.name;
        entry.index = activeLine.episodes.indexOf(rawEpisode);
        entry.position = pos;
        entry.duration = dur;
        entry.updated = System.currentTimeMillis();
        a.prefs
                .edit()
                .putString(
                        Prefs.WATCH_HISTORY,
                        WatchHistory.upsert(a.prefs.getString(Prefs.WATCH_HISTORY, "[]"), entry))
                .apply();
    }

    private void releaseInternalPlayer() {
        a.ui.removeCallbacks(ticker);
        prepared = false;
        if (player != null) {
            try {
                player.release();
            } catch (Exception ignored) {
            }
            player = null;
        }
    }

    void detach() {
        closed = true;
        releaseInternalPlayer();
        if (a.inlinePlayer == this) {
            a.inlinePlayer = null;
        }
        if (container.getParent() instanceof ViewGroup) {
            ((ViewGroup) container.getParent()).removeView(container);
        }
        hostSlot.setVisibility(View.GONE);
    }
}
