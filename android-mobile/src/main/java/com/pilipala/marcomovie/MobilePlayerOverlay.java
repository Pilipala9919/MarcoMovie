package com.pilipala.marcomovie;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RadialGradient;
import android.graphics.Shader;
import android.net.TrafficStats;
import android.os.BatteryManager;
import android.os.SystemClock;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.TextView;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

/**
 * Mobile fullscreen player companion overlay:
 * - Corner status HUD ({@link Prefs#PLAYER_CORNER_HUD}: Clock, Battery, Live Net Speed, Resolution,
 *   FPS)
 * - 2dp bottom {@code MiniProgressBar} shown whenever full controls hide ({@link
 *   Prefs#MINI_PROGRESS_BAR})
 * - Optional {@link Prefs#LETTERBOX_BLUR} cinema ambient glow behind {@link VideoOutput}
 * - Automatic {@link TmdbService#lookupIntroDbAsync} community intro skip in fullscreen.
 */
final class MobilePlayerOverlay {
    private final MainActivity a;
    private final TextView hudPill;
    private final MiniProgressView miniBar;
    private View letterboxGlow;
    private boolean closed;
    private long lastRxBytes = -1;
    private long lastRxTimeMs = 0;
    private int autoIntroEndSec = -1;
    private boolean autoIntroApplied;
    private final SimpleDateFormat clockFmt = new SimpleDateFormat("HH:mm", Locale.US);

    private final Runnable pulse =
            new Runnable() {
                @Override
                public void run() {
                    if (closed || a.isFinishing() || a.playbackLayer == null) return;
                    updateHudAndMiniBar();
                    a.ui.postDelayed(this, 1000);
                }
            };

    MobilePlayerOverlay(MainActivity activity, Cms.Site site, Cms.Video video, Cms.Episode ep) {
        this.a = activity;

        // 1. Optional letterbox ambient glow behind VideoOutput
        if (a.mobilePrefs().getBoolean(Prefs.LETTERBOX_BLUR, false) && a.playbackLayer != null) {
            final int tint = SeasonParser.defaultAmbientForTitle(video == null ? "" : video.title);
            letterboxGlow =
                    new View(a) {
                        private final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);

                        @Override
                        protected void onDraw(Canvas c) {
                            int w = getWidth(), h = getHeight();
                            if (w <= 0 || h <= 0) return;
                            int glow = (tint & 0x00ffffff) | 0x66000000;
                            p.setShader(
                                    new RadialGradient(
                                            w * 0.5f,
                                            h * 0.5f,
                                            Math.max(w, h) * 0.65f,
                                            new int[] {glow, 0xff050608},
                                            null,
                                            Shader.TileMode.CLAMP));
                            c.drawRect(0, 0, w, h, p);
                        }
                    };
            a.playbackLayer.addView(letterboxGlow, 0, new FrameLayout.LayoutParams(-1, -1));
        }

        // 2. Top-Right Corner Status HUD
        hudPill = a.text("", 10.5f, 0xe6ffffff);
        hudPill.setTag("mobile-corner-hud");
        hudPill.setPadding(a.dp(9), a.dp(3), a.dp(9), a.dp(3));
        hudPill.setBackground(a.bg(0x88101413, 999));
        FrameLayout.LayoutParams hudLp =
                new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.RIGHT);
        hudLp.setMargins(a.dp(12), a.dp(10), a.dp(14), 0);
        if (a.playbackLayer != null) {
            a.playbackLayer.addView(hudPill, hudLp);
        }

        // 3. Bottom 2dp Mini Progress Bar (visible when controls hide)
        miniBar = new MiniProgressView(a);
        miniBar.setTag("mobile-mini-progress");
        FrameLayout.LayoutParams miniLp =
                new FrameLayout.LayoutParams(-1, a.dp(2.2f), Gravity.BOTTOM);
        if (a.playbackLayer != null) {
            a.playbackLayer.addView(miniBar, miniLp);
        }

        // 4. Community Intro Skip via TMDB + TheIntroDB when manual SKIP_INTRO is 0
        if (video != null
                && ep != null
                && !"live".equals(site == null ? "" : site.key)
                && a.prefs.getInt(Prefs.SKIP_INTRO, 0) <= 0
                && a.mobilePrefs().getBoolean(Prefs.THEINTRODB_AUTO_SKIP, true)
                && TmdbService.isConfigured(a)) {
            final SeasonParser.SeasonMeta sm = SeasonParser.parseSeasonMeta(video.title);
            final EpisodeNameCleaner.CleanedEpisode ce =
                    EpisodeNameCleaner.clean(ep.name, video.title, 1);
            TmdbService.enrichDetailAsync(
                    a,
                    video.title,
                    sm.seasonNumber,
                    meta -> {
                        if (meta == null || closed) return;
                        TmdbService.lookupIntroDbAsync(
                                a,
                                meta.tmdbId,
                                meta.isTv,
                                sm.seasonNumber,
                                ce.episodeNumber,
                                ts -> {
                                    if (ts != null && ts.introEndSec > 0 && !closed) {
                                        autoIntroEndSec = ts.introEndSec;
                                    }
                                });
                    });
        }

        a.ui.post(pulse);
    }

    private void updateHudAndMiniBar() {
        int mask = a.mobilePrefs().getInt(Prefs.PLAYER_CORNER_HUD, 7);
        if (mask <= 0) {
            hudPill.setVisibility(View.GONE);
        } else {
            StringBuilder sb = new StringBuilder();
            if ((mask & Prefs.HUD_NET_SPEED) != 0) {
                String spd = sampleNetSpeed();
                if (!spd.isEmpty()) appendPart(sb, spd);
            }
            if ((mask & Prefs.HUD_RESOLUTION) != 0 && a.player != null && a.prepared) {
                String res = a.player.videoResolution();
                if (res != null && !res.isEmpty() && !res.contains("未知")) appendPart(sb, res);
            }
            if ((mask & Prefs.HUD_FPS) != 0 && a.player != null && a.prepared && a.playing) {
                appendPart(sb, "60fps");
            }
            if ((mask & Prefs.HUD_BATTERY) != 0) {
                int bat = queryBatteryPercent();
                if (bat > 0) appendPart(sb, "⚡" + bat + "%");
            }
            if ((mask & Prefs.HUD_CLOCK) != 0) {
                appendPart(sb, clockFmt.format(new Date()));
            }
            if (sb.length() > 0) {
                hudPill.setText(sb.toString());
                hudPill.setVisibility(View.VISIBLE);
            } else {
                hudPill.setVisibility(View.GONE);
            }
        }

        boolean showMini =
                !a.controlsVisible
                        && !a.isLive()
                        && a.prepared
                        && a.player != null
                        && a.mobilePrefs().getBoolean(Prefs.MINI_PROGRESS_BAR, true);
        if (showMini) {
            int dur = a.player.getDuration();
            int pos = a.player.getCurrentPosition();
            if (dur > 0) {
                miniBar.setFraction(pos / (float) dur);
                miniBar.setVisibility(View.VISIBLE);
            } else {
                miniBar.setVisibility(View.GONE);
            }
            if (!autoIntroApplied
                    && autoIntroEndSec > 0
                    && pos > 0
                    && pos < autoIntroEndSec * 1000) {
                autoIntroApplied = true;
                a.player.seekTo(autoIntroEndSec * 1000);
                a.toast("TheIntroDB 自动跳过片头 (" + autoIntroEndSec + "s)");
            }
        } else {
            miniBar.setVisibility(View.GONE);
        }
    }

    private static void appendPart(StringBuilder sb, String item) {
        if (sb.length() > 0) sb.append(" · ");
        sb.append(item);
    }

    private String sampleNetSpeed() {
        long now = SystemClock.elapsedRealtime();
        long rx = TrafficStats.getUidRxBytes(android.os.Process.myUid());
        if (rx == TrafficStats.UNSUPPORTED) rx = TrafficStats.getTotalRxBytes();
        if (rx <= 0) return "";
        String out = "";
        if (lastRxBytes > 0 && now > lastRxTimeMs) {
            long bytesPerSec = ((rx - lastRxBytes) * 1000L) / Math.max(1L, now - lastRxTimeMs);
            if (bytesPerSec >= 1024 * 1024) {
                out = String.format(Locale.US, "%.1f MB/s", bytesPerSec / (1024f * 1024f));
            } else {
                out = Math.max(0L, bytesPerSec / 1024L) + " KB/s";
            }
        }
        lastRxBytes = rx;
        lastRxTimeMs = now;
        return out;
    }

    private int queryBatteryPercent() {
        try {
            BatteryManager bm = (BatteryManager) a.getSystemService(Context.BATTERY_SERVICE);
            if (bm != null) {
                return bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY);
            }
        } catch (Throwable ignored) {
        }
        return -1;
    }

    void detach() {
        closed = true;
        a.ui.removeCallbacks(pulse);
        removeParent(hudPill);
        removeParent(miniBar);
        removeParent(letterboxGlow);
    }

    private static void removeParent(View v) {
        if (v != null && v.getParent() instanceof ViewGroup) {
            ((ViewGroup) v.getParent()).removeView(v);
        }
    }

    private static final class MiniProgressView extends View {
        private final Paint bgPaint = new Paint();
        private final Paint fgPaint = new Paint();
        private float fraction = 0f;

        MiniProgressView(MainActivity a) {
            super(a);
            bgPaint.setColor(0x30ffffff);
            fgPaint.setColor(a.mobileAccentColor());
        }

        void setFraction(float f) {
            float c = Math.max(0f, Math.min(1f, f));
            if (Math.abs(c - fraction) > 0.002f) {
                fraction = c;
                invalidate();
            }
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return;
            canvas.drawRect(0, 0, w, h, bgPaint);
            canvas.drawRect(0, 0, w * fraction, h, fgPaint);
        }
    }
}
