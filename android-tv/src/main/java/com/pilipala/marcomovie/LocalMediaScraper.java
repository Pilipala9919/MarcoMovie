// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.content.Context;
import android.graphics.Bitmap;
import android.media.MediaMetadataRetriever;
import android.net.Uri;
import java.io.File;
import java.io.FileOutputStream;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.JSONObject;

/**
 * Automatic three-tier poster & metadata scraper for local USB hard drive libraries:
 *
 * <ol>
 *   <li>Local {@code poster.jpg / cover.jpg / folder.jpg} and {@code .nfo} (instant, zero network)
 *   <li>Zero-config online lookup via Douban Rexxar + Bangumi (HD poster, score, year, synopsis)
 *   <li>Offline local video frame extraction via {@link MediaMetadataRetriever} cached to disk
 * </ol>
 */
final class LocalMediaScraper {
    private static final ExecutorService SCRAPE_POOL =
            Executors.newFixedThreadPool(
                    2,
                    r -> {
                        Thread t = new Thread(r, "local-media-scraper");
                        t.setDaemon(true);
                        return t;
                    });

    interface ProgressCallback {
        void onItemScraped(LocalMediaLibrary.LocalVideoItem item, int completed, int total);

        void onAllComplete(List<LocalMediaLibrary.LocalVideoItem> items);
    }

    private LocalMediaScraper() {}

    static void scrapeMissingAsync(
            final Context context,
            final List<LocalMediaLibrary.LocalVideoItem> items,
            final int generationToken,
            final MainActivity a,
            final ProgressCallback callback) {
        if (context == null || items == null || items.isEmpty()) {
            if (callback != null && a != null) {
                a.ui.post(() -> callback.onAllComplete(items));
            }
            return;
        }
        final int total = items.size();
        final AtomicInteger done = new AtomicInteger(0);
        for (final LocalMediaLibrary.LocalVideoItem item : items) {
            SCRAPE_POOL.execute(
                    () -> {
                        if (a != null && (a.isFinishing() || a.generation != generationToken)) {
                            return;
                        }
                        try {
                            boolean updated = scrapeSingleItem(context, item);
                            int completed = done.incrementAndGet();
                            if (updated && callback != null && a != null) {
                                a.ui.post(
                                        () -> {
                                            if (!a.isFinishing()
                                                    && a.generation == generationToken) {
                                                callback.onItemScraped(item, completed, total);
                                            }
                                        });
                            }
                            if (completed >= total) {
                                LocalMediaLibrary.saveCache(context, items);
                                if (callback != null && a != null) {
                                    a.ui.post(
                                            () -> {
                                                if (!a.isFinishing()
                                                        && a.generation == generationToken) {
                                                    callback.onAllComplete(items);
                                                }
                                            });
                                }
                            }
                        } catch (Throwable ignored) {
                            int completed = done.incrementAndGet();
                            if (completed >= total && callback != null && a != null) {
                                LocalMediaLibrary.saveCache(context, items);
                                a.ui.post(
                                        () -> {
                                            if (!a.isFinishing()
                                                    && a.generation == generationToken) {
                                                callback.onAllComplete(items);
                                            }
                                        });
                            }
                        }
                    });
        }
    }

    private static boolean scrapeSingleItem(
            Context context, LocalMediaLibrary.LocalVideoItem item) {
        if (item == null) return false;
        boolean changed = false;

        // 1. Honor any manual per-series override stored by user
        SeriesScrapeStore.OverrideRecord ov =
                SeriesScrapeStore.load(
                        context, LocalMediaLibrary.LOCAL_SITE_KEY, item.id, item.title);
        if (ov != null) {
            if (!ov.matchedTitle.isEmpty()) item.title = ov.matchedTitle;
            if (!ov.posterUrl.isEmpty()) item.posterUrl = ov.posterUrl;
            if (!ov.synopsis.isEmpty()) item.synopsis = ov.synopsis;
            if (!ov.year.isEmpty()) item.year = ov.year;
            if (ov.doubanScore > 0.1) item.doubanScore = ov.doubanScore;
            item.scrapedOnline = true;
            return true;
        }

        // 2. Zero-config online Douban + Bangumi metadata & HD poster lookup
        if (!item.scrapedOnline && item.title != null && !item.title.trim().isEmpty()) {
            try {
                List<TvSeriesScrapeDialog.MediaCandidate> candidates =
                        TvSeriesScrapeDialog.searchDoubanAndBangumi(item.title);
                TvSeriesScrapeDialog.MediaCandidate best = pickBestCandidate(item, candidates);
                if (best != null) {
                    if (item.posterUrl.isEmpty() && !best.posterUrl.isEmpty()) {
                        item.posterUrl = best.posterUrl;
                        changed = true;
                    }
                    if (item.year.isEmpty() && !best.year.isEmpty()) {
                        item.year = best.year;
                        changed = true;
                    }
                    if (item.doubanScore <= 0.1 && best.score > 0.1) {
                        item.doubanScore = best.score;
                        changed = true;
                    }
                    if (item.synopsis.isEmpty() && !best.synopsis.isEmpty()) {
                        item.synopsis = best.synopsis;
                        changed = true;
                    }
                    if ("douban".equals(best.source)
                            && (item.synopsis.isEmpty() || item.posterUrl.isEmpty())) {
                        JSONObject detail =
                                TvSeriesScrapeDialog.fetchDoubanDetail(best.kind, best.subjectId);
                        if (detail != null) {
                            String intro = detail.optString("intro", "").trim();
                            if (!intro.isEmpty() && item.synopsis.isEmpty()) {
                                item.synopsis = intro;
                                changed = true;
                            }
                            JSONObject pic = detail.optJSONObject("pic");
                            if (pic != null && item.posterUrl.isEmpty()) {
                                String large = pic.optString("large", "").trim();
                                if (!large.isEmpty()) {
                                    item.posterUrl = large;
                                    changed = true;
                                }
                            }
                        }
                    }
                }
                item.scrapedOnline = true;
            } catch (Throwable ignored) {
            }
        }

        // 3. Offline / home-video fallback: extract frame thumbnail to local cache JPEG
        if (item.posterUrl.isEmpty() && !item.episodes.isEmpty()) {
            String thumbUri = extractAndCacheFrame(context, item.id, item.episodes.get(0).uri);
            if (!thumbUri.isEmpty()) {
                item.posterUrl = thumbUri;
                changed = true;
            }
        }
        return changed;
    }

    static TvSeriesScrapeDialog.MediaCandidate pickBestCandidate(
            LocalMediaLibrary.LocalVideoItem item,
            List<TvSeriesScrapeDialog.MediaCandidate> candidates) {
        if (item == null || candidates == null || candidates.isEmpty()) return null;
        String targetCore = TvSeriesScraper.normalizeCoreKey(item.title);
        TvSeriesScrapeDialog.MediaCandidate best = null;
        int bestScore = -100;
        for (TvSeriesScrapeDialog.MediaCandidate c : candidates) {
            if (c == null || c.title == null || c.title.trim().isEmpty()) continue;
            int score = 0;
            String candCore = TvSeriesScraper.normalizeCoreKey(c.title);
            if (!targetCore.isEmpty() && targetCore.equals(candCore)) {
                score += 60;
            } else if (!targetCore.isEmpty()
                    && (candCore.contains(targetCore) || targetCore.contains(candCore))) {
                score += 35 - Math.min(20, Math.abs(candCore.length() - targetCore.length()) * 2);
            } else {
                score -= 20;
            }
            if (!item.year.isEmpty() && item.year.equals(c.year)) {
                score += 20;
            }
            if (item.isSeries && "tv".equals(c.kind)) score += 12;
            if (!item.isSeries && "movie".equals(c.kind)) score += 12;
            if (!c.posterUrl.isEmpty()) score += 8;
            if (c.score > 1.0) score += 5;
            if (score > bestScore) {
                bestScore = score;
                best = c;
            }
        }
        return bestScore >= 20 ? best : null;
    }

    private static String extractAndCacheFrame(Context context, String itemId, String mediaUri) {
        if (context == null || mediaUri == null || mediaUri.isEmpty()) return "";
        File dir = new File(context.getCacheDir(), "local-thumbs");
        if (!dir.exists()) dir.mkdirs();
        File outFile = new File(dir, itemId + ".jpg");
        if (outFile.exists() && outFile.length() > 1024) {
            return Uri.fromFile(outFile).toString();
        }
        MediaMetadataRetriever retriever = new MediaMetadataRetriever();
        try {
            Uri uri = Uri.parse(mediaUri);
            if ("file".equalsIgnoreCase(uri.getScheme()) && uri.getPath() != null) {
                retriever.setDataSource(uri.getPath());
            } else {
                retriever.setDataSource(context, uri);
            }
            long durationMs = 0L;
            String durStr = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION);
            if (durStr != null) {
                try {
                    durationMs = Long.parseLong(durStr.trim());
                } catch (NumberFormatException ignored) {
                }
            }
            long timeUs =
                    durationMs > 30000L ? Math.min(180_000_000L, (durationMs * 150L)) : 5_000_000L;
            Bitmap frame =
                    retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC);
            if (frame == null) frame = retriever.getFrameAtTime(0L);
            if (frame == null) return "";
            int maxDim = 480;
            int w = frame.getWidth();
            int h = frame.getHeight();
            Bitmap scaled = frame;
            if (Math.max(w, h) > maxDim) {
                float ratio = (float) maxDim / Math.max(w, h);
                scaled =
                        Bitmap.createScaledBitmap(
                                frame,
                                Math.max(1, Math.round(w * ratio)),
                                Math.max(1, Math.round(h * ratio)),
                                true);
                if (scaled != frame) frame.recycle();
            }
            try (FileOutputStream fos = new FileOutputStream(outFile)) {
                scaled.compress(Bitmap.CompressFormat.JPEG, 82, fos);
                fos.flush();
            } finally {
                scaled.recycle();
            }
            return Uri.fromFile(outFile).toString();
        } catch (Throwable ignored) {
            return "";
        } finally {
            try {
                retriever.release();
            } catch (Throwable ignored) {
            }
        }
    }

    static String formatDriveStats(int driveCount, int mediaCount) {
        if (driveCount <= 0 && mediaCount <= 0) return "接入 U 盘 / 硬盘";
        if (mediaCount > 0) return driveCount + " 盘 · " + mediaCount + " 部";
        return String.format(Locale.US, "已挂载 %d 个硬盘", driveCount);
    }
}
