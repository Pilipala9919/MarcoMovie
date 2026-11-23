package com.pilipala.marcomovie;

import android.content.ComponentCallbacks2;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.view.View;
import android.widget.ImageView;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.Future;
import java.util.concurrent.ThreadPoolExecutor;

/**
 * Bounded asynchronous poster/artwork loader, memory cache trimming, and background atmosphere
 * rendering extracted from {@link MainActivity}.
 */
final class ImageLoader {
    private static final java.util.Map<String, java.util.List<ImageView>> IN_FLIGHT =
            new java.util.HashMap<>();

    private ImageLoader() {}

    static void cancel(MainActivity a) {
        synchronized (IN_FLIGHT) {
            IN_FLIGHT.clear();
        }
        for (Future<?> request : a.artworkRequests) request.cancel(true);
        a.artworkRequests.clear();
        ((ThreadPoolExecutor) a.artwork).purge();
    }

    static void trimMemory(MainActivity a, int level) {
        if (a.images == null) return;
        if (level >= ComponentCallbacks2.TRIM_MEMORY_BACKGROUND || level >= 15) {
            a.images.evictAll();
        } else if (level >= 10) {
            UiCompat.trimCache(a.images, a.images.maxSize() / 2);
        }
    }

    static boolean isLocalArtworkAddress(String address) {
        if (address == null) return false;
        String lower = address.trim().toLowerCase(Locale.ROOT);
        return lower.startsWith("file://") || lower.startsWith("content://");
    }

    static void poster(MainActivity a, String address, ImageView image, boolean detail) {
        String normalized = normalizeArtworkAddress(address);
        image.setTag(normalized);
        if (!Cms.isHttp(normalized)
                && !normalized.startsWith("catpaw://")
                && !isLocalArtworkAddress(normalized)) return;
        address = normalized;
        final int ticket = a.generation;
        int initialW = ImageDecodePolicy.targetWidth(image.getWidth(), detail);
        int initialH = ImageDecodePolicy.targetHeight(image.getHeight(), detail);
        boolean initialCrop = image.getScaleType() == ImageView.ScaleType.CENTER_CROP;
        String initialKey =
                ImageDecodePolicy.cacheKey(address, initialW, initialH, initialCrop, detail);
        Bitmap immediate = a.images.get(initialKey);
        if (immediate != null && !immediate.isRecycled()) {
            image.setImageBitmap(immediate);
            if (!a.isTvDevice()) com.pilipala.glass.GlassworkSurface.invalidateBackdrop(image);
            return;
        }
        Bitmap preview = a.images.get(address);
        if ((preview == null || preview.isRecycled()) && detail) {
            String gridKey =
                    ImageDecodePolicy.cacheKey(
                            address,
                            ImageDecodePolicy.targetWidth(0, false),
                            ImageDecodePolicy.targetHeight(0, false),
                            true,
                            false);
            preview = a.images.get(gridKey);
        }
        if (preview != null && !preview.isRecycled()) {
            image.setImageBitmap(preview);
            if (!a.isTvDevice()) com.pilipala.glass.GlassworkSurface.invalidateBackdrop(image);
            if (!detail || (preview.getWidth() >= initialW && preview.getHeight() >= initialH)) {
                return;
            }
        }
        startPosterLoad(a, address, image, detail, ticket);
    }

    private static byte[] readLocalArtworkBytes(Context context, String uriStr) {
        if (context == null || uriStr == null || uriStr.isEmpty()) return null;
        InputStream in = null;
        try {
            android.net.Uri uri = android.net.Uri.parse(uriStr);
            if ("file".equalsIgnoreCase(uri.getScheme()) && uri.getPath() != null) {
                File f = new File(uri.getPath());
                if (!f.exists() || !f.canRead() || f.length() > 16 * 1024 * 1024) return null;
                in = new java.io.FileInputStream(f);
            } else {
                in = context.getContentResolver().openInputStream(uri);
            }
            if (in == null) return null;
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[16 * 1024];
            int total = 0;
            int n;
            while ((n = in.read(buf)) > 0) {
                total += n;
                if (total > 16 * 1024 * 1024) return null;
                bos.write(buf, 0, n);
            }
            return bos.toByteArray();
        } catch (Throwable ignored) {
            return null;
        } finally {
            if (in != null) {
                try {
                    in.close();
                } catch (IOException ignored) {
                }
            }
        }
    }

    private static void startPosterLoad(
            MainActivity a, String address, ImageView image, boolean detail, final int ticket) {
        if (ticket != a.generation || !address.equals(image.getTag())) return;
        final int width = ImageDecodePolicy.targetWidth(image.getWidth(), detail);
        final int height = ImageDecodePolicy.targetHeight(image.getHeight(), detail);
        final boolean crop = image.getScaleType() == ImageView.ScaleType.CENTER_CROP;
        final String key = ImageDecodePolicy.cacheKey(address, width, height, crop, detail);
        Bitmap cached = a.images.get(key);
        if (cached != null && !cached.isRecycled()) {
            image.setImageBitmap(cached);
            if (!a.isTvDevice()) com.pilipala.glass.GlassworkSurface.invalidateBackdrop(image);
            return;
        }
        final java.util.List<ImageView> owned = new java.util.ArrayList<>(2);
        synchronized (IN_FLIGHT) {
            java.util.List<ImageView> waiters = IN_FLIGHT.get(key);
            if (waiters != null) {
                if (!waiters.contains(image)) waiters.add(image);
                return;
            }
            owned.add(image);
            IN_FLIGHT.put(key, owned);
        }
        Future<?> request =
                RequestScope.submit(
                        a.artwork,
                        () -> {
                            if (ticket != a.generation) {
                                synchronized (IN_FLIGHT) {
                                    if (IN_FLIGHT.get(key) == owned) IN_FLIGHT.remove(key);
                                }
                                return;
                            }
                            HttpURLConnection connection = null;
                            try {
                                byte[] bytes;
                                if (isLocalArtworkAddress(address)) {
                                    bytes = readLocalArtworkBytes(a, address);
                                } else {
                                    Cms.ImageRequest source = Cms.imageRequest(address);
                                    String resolvedUrl = Cms.normalizeHttp(source.url);
                                    if (resolvedUrl.startsWith("catpaw://")) {
                                        resolvedUrl =
                                                new com.pilipala.catpaw.CatPawHost(a)
                                                        .resolve(resolvedUrl);
                                    }
                                    String targetUrl = upgradePosterUrl(resolvedUrl, detail);
                                    bytes =
                                            fetchPosterBytesWithFallback(
                                                    a, source, resolvedUrl, targetUrl, detail);
                                }
                                if (bytes == null || bytes.length == 0) return;
                                BitmapFactory.Options options = new BitmapFactory.Options();
                                options.inJustDecodeBounds = true;
                                BitmapFactory.decodeByteArray(bytes, 0, bytes.length, options);
                                if (options.outWidth <= 0 || options.outHeight <= 0) return;
                                options.inSampleSize =
                                        ImageDecodePolicy.sample(
                                                options.outWidth,
                                                options.outHeight,
                                                width,
                                                height,
                                                crop,
                                                detail);
                                if (!detail && a.isTvDevice()) {
                                    options.inPreferredConfig = Bitmap.Config.RGB_565;
                                }
                                options.inJustDecodeBounds = false;
                                RequestScope.current().check();
                                Bitmap bitmap =
                                        BitmapFactory.decodeByteArray(
                                                bytes, 0, bytes.length, options);
                                if (bitmap != null) {
                                    if (ticket != a.generation
                                            || Thread.currentThread().isInterrupted()) {
                                        bitmap.recycle();
                                        return;
                                    }
                                    a.images.put(key, bitmap);
                                    final java.util.List<ImageView> targets;
                                    synchronized (IN_FLIGHT) {
                                        java.util.List<ImageView> removed =
                                                IN_FLIGHT.get(key) == owned
                                                        ? IN_FLIGHT.remove(key)
                                                        : null;
                                        targets =
                                                removed == null
                                                        ? java.util.Collections.singletonList(image)
                                                        : new java.util.ArrayList<>(removed);
                                    }
                                    a.ui.post(
                                            () -> {
                                                if (ticket != a.generation || a.isFinishing())
                                                    return;
                                                boolean tv = a.isTvDevice();
                                                for (ImageView target : targets) {
                                                    if (target != null
                                                            && address.equals(target.getTag())) {
                                                        target.setImageBitmap(bitmap);
                                                        if (!tv) {
                                                            com.pilipala.glass.GlassworkSurface
                                                                    .invalidateBackdrop(target);
                                                        }
                                                    }
                                                }
                                            });
                                }
                            } catch (Throwable ignored) {
                            } finally {
                                synchronized (IN_FLIGHT) {
                                    if (IN_FLIGHT.get(key) == owned) IN_FLIGHT.remove(key);
                                }
                                if (connection != null) {
                                    RequestScope.detach(connection);
                                    connection.disconnect();
                                }
                            }
                        });
        for (java.util.Iterator<Future<?>> it = a.artworkRequests.iterator(); it.hasNext(); ) {
            if (it.next().isDone()) it.remove();
        }
        a.artworkRequests.add(request);
    }

    private static File diskCacheFile(MainActivity a, String url) {
        try {
            File dir = new File(a.getCacheDir(), "posters_v2");
            if (!dir.exists()) dir.mkdirs();
            java.security.MessageDigest md = java.security.MessageDigest.getInstance("SHA-256");
            byte[] d = md.digest(url.getBytes("UTF-8"));
            StringBuilder sb = new StringBuilder(32);
            for (int i = 0; i < 16; i++) {
                sb.append(String.format(java.util.Locale.ROOT, "%02x", d[i] & 255));
            }
            return new File(dir, sb.toString() + ".img");
        } catch (Exception e) {
            return null;
        }
    }

    private static byte[] readDiskCachedPoster(MainActivity a, String url) {
        try {
            File f = diskCacheFile(a, url);
            if (f == null || !f.isFile()) return null;
            long len = f.length();
            if (len <= 128 || len > 8 * 1024 * 1024) return null;
            if (System.currentTimeMillis() - f.lastModified() > 7L * 24 * 3600 * 1000L) {
                return null;
            }
            byte[] buf = new byte[(int) len];
            try (java.io.FileInputStream in = new java.io.FileInputStream(f)) {
                int off = 0;
                while (off < buf.length) {
                    int r = in.read(buf, off, buf.length - off);
                    if (r < 0) break;
                    off += r;
                }
                if (off != buf.length) return null;
            }
            return buf;
        } catch (Exception e) {
            return null;
        }
    }

    private static void writeDiskCachedPoster(MainActivity a, String url, byte[] bytes) {
        try {
            File f = diskCacheFile(a, url);
            if (f == null) return;
            try (java.io.FileOutputStream out = new java.io.FileOutputStream(f)) {
                out.write(bytes);
            }
        } catch (Exception ignored) {
        }
    }

    static String normalizeArtworkAddress(String raw) {
        if (raw == null) return "";
        String trimmed = raw.trim();
        if (trimmed.startsWith("//")) return "https:" + trimmed;
        return trimmed;
    }

    private static final String BROWSER_IMAGE_UA =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

    private static byte[] fetchPosterBytesWithFallback(
            MainActivity a,
            Cms.ImageRequest source,
            String resolvedUrl,
            String targetUrl,
            boolean detail)
            throws Exception {
        String[] candidates =
                detail && !targetUrl.equals(resolvedUrl)
                        ? new String[] {
                            targetUrl, upgradePosterUrl(resolvedUrl, false), resolvedUrl
                        }
                        : new String[] {targetUrl, resolvedUrl};
        Exception lastError = null;
        java.util.HashSet<String> tried = new java.util.HashSet<>();
        boolean hasCustomUa = source.headers.containsKey("User-Agent");
        String[] userAgents =
                hasCustomUa
                        ? new String[] {source.headers.get("User-Agent")}
                        : new String[] {BROWSER_IMAGE_UA, Cms.USER_AGENT};
        for (String candidate : candidates) {
            if (candidate == null || candidate.isEmpty() || !tried.add(candidate)) continue;
            byte[] cached = readDiskCachedPoster(a, candidate);
            if (cached != null) return cached;
            for (String ua : userAgents) {
                HttpURLConnection connection = null;
                try {
                    String currentUrl = candidate;
                    for (int hop = 0; hop < 4; hop++) {
                        if (connection != null) {
                            RequestScope.detach(connection);
                            connection.disconnect();
                        }
                        connection = ProxyAddress.openHttpConnection(new URL(currentUrl));
                        connection.setInstanceFollowRedirects(false);
                        for (Map.Entry<String, String> header : source.headers.entrySet())
                            connection.setRequestProperty(header.getKey(), header.getValue());
                        String fragment = new URL(currentUrl).getRef();
                        if (fragment != null && fragment.startsWith("mm-emby=")) {
                            com.pilipala.emby.EmbyLibrary library =
                                    com.pilipala.emby.EmbyAccounts.open(
                                            a, "emby://account/" + fragment.substring(8));
                            for (Map.Entry<String, String> h :
                                    library.imageHeaders(currentUrl).entrySet())
                                connection.setRequestProperty(h.getKey(), h.getValue());
                        }
                        applyArtworkHeaders(connection, currentUrl, source.headers);
                        connection.setConnectTimeout(4500);
                        connection.setReadTimeout(5500);
                        if (!hasCustomUa && ua != null) {
                            connection.setRequestProperty("User-Agent", ua);
                        }
                        RequestScope.attach(connection);
                        int code = connection.getResponseCode();
                        if (code >= 300 && code < 400 && code != 304) {
                            String loc = connection.getHeaderField("Location");
                            if (loc == null || loc.trim().isEmpty()) break;
                            currentUrl = new URL(new URL(currentUrl), loc.trim()).toString();
                            continue;
                        }
                        break;
                    }
                    if (connection == null) continue;
                    try (InputStream in = connection.getInputStream()) {
                        ByteArrayOutputStream out = new ByteArrayOutputStream();
                        byte[] buffer = new byte[8192];
                        int n;
                        while ((n = in.read(buffer)) != -1) {
                            RequestScope.current().check();
                            if (out.size() + n > (detail ? 8 : 3) * 1024 * 1024)
                                throw new IOException("Poster too large");
                            out.write(buffer, 0, n);
                        }
                        byte[] bytes = out.toByteArray();
                        if (bytes.length > 128) {
                            writeDiskCachedPoster(a, candidate, bytes);
                            return bytes;
                        }
                    }
                } catch (Exception e) {
                    lastError = e;
                } finally {
                    if (connection != null) {
                        RequestScope.detach(connection);
                        connection.disconnect();
                    }
                }
            }
        }
        if (lastError != null) throw lastError;
        return null;
    }

    static String upgradePosterUrl(String rawUrl, boolean detail) {
        if (rawUrl == null || rawUrl.isEmpty()) return "";
        String url = rawUrl;
        if (url.contains("doubanio.com")) {
            url =
                    url.replaceAll(
                            "https?://(?:img[4-9]|qnmob\\d*-sign)\\.doubanio\\.com/",
                            "https://img1.doubanio.com/");
            int qIdx = url.indexOf('?');
            if (qIdx > 0 && url.substring(0, qIdx).endsWith(".jpg")) {
                url = url.substring(0, qIdx);
            }
            if (detail) {
                url =
                        url.replace("/s_ratio_poster/", "/l_ratio_poster/")
                                .replace("/m_ratio_poster/", "/l_ratio_poster/")
                                .replace("/view/photo/spic/", "/view/photo/lpic/")
                                .replace("/view/photo/mpic/", "/view/photo/lpic/")
                                .replace("/view/photo/s/", "/view/photo/l/")
                                .replace("/view/photo/m/", "/view/photo/l/")
                                .replace("/view/photo/large/", "/view/photo/l/");
            } else {
                url =
                        url.replace("/s_ratio_poster/", "/m_ratio_poster/")
                                .replace("/view/photo/spic/", "/view/photo/mpic/");
            }
        }
        if (url.contains("image.tmdb.org/t/p/")) {
            if (detail) {
                url =
                        url.replace("/t/p/w185/", "/t/p/w780/")
                                .replace("/t/p/w300/", "/t/p/w780/")
                                .replace("/t/p/w342/", "/t/p/w780/")
                                .replace("/t/p/w500/", "/t/p/w780/");
            } else {
                url =
                        url.replace("/t/p/w185/", "/t/p/w500/")
                                .replace("/t/p/w300/", "/t/p/w500/")
                                .replace("/t/p/w342/", "/t/p/w500/");
            }
        }
        if (detail) {
            if (url.contains("lain.bgm.tv") || url.contains("bgm.tv/pic/cover/")) {
                url =
                        url.replace("/pic/cover/c/", "/pic/cover/l/")
                                .replace("/pic/cover/m/", "/pic/cover/l/")
                                .replace("/pic/cover/s/", "/pic/cover/l/")
                                .replace("/r/400/", "/r/800/");
            }
            if (url.contains("hdslb.com") || url.contains("biliimg.com")) {
                int at = url.indexOf('@');
                if (at > 0) url = url.substring(0, at);
            }
            if (url.contains("bcebos.com")) {
                int q = url.indexOf('?');
                if (q > 0) url = url.substring(0, q);
            }
        }
        return url;
    }

    static void applyArtworkHeaders(
            HttpURLConnection connection, String url, Map<String, String> existing) {
        if (existing != null && existing.containsKey("Referer")) return;
        String lower = url.toLowerCase(Locale.ROOT);
        if (lower.contains("doubanio.com") || lower.contains("douban.com")) {
            connection.setRequestProperty("Referer", "https://movie.douban.com/");
        } else if (lower.contains("hdslb.com")
                || lower.contains("biliimg.com")
                || lower.contains("bilibili.com")) {
            connection.setRequestProperty("Referer", "https://www.bilibili.com/");
        } else if (lower.contains("bcebos.com") || lower.contains("baidu.com")) {
            connection.setRequestProperty("Referer", "https://baike.baidu.com/");
        } else if (lower.contains("bgm.tv") || lower.contains("bangumi.tv")) {
            connection.setRequestProperty("Referer", "https://bgm.tv/");
        } else if (lower.contains("bing.net") || lower.contains("bing.com")) {
            connection.setRequestProperty("Referer", "https://cn.bing.com/");
        } else if (lower.contains("qpic.cn") || lower.contains("gtimg.cn")) {
            connection.setRequestProperty("Referer", "https://v.qq.com/");
        } else if (lower.contains("sinaimg.cn")) {
            connection.setRequestProperty("Referer", "https://weibo.com/");
        }
    }

    static View createAtmosphere(MainActivity a) {
        return new Atmosphere(a);
    }

    static final class Atmosphere extends View {
        final MainActivity a;
        final Paint paint = new Paint(3);
        Bitmap wallpaper;

        Atmosphere(Context c) {
            super(c);
            a = (MainActivity) c;
            reloadWallpaper();
        }

        void reloadWallpaper() {
            wallpaper = null;
            boolean showWallpaper =
                    a.isTvDevice()
                            ? HomeAmbient.effectiveBgMode(a) == Prefs.BG_MODE_WALLPAPER
                            : a.prefs.getBoolean(Prefs.WALLPAPER_ENABLED, false);
            if (showWallpaper) {
                File f = new File(a.getFilesDir(), "wallpaper.jpg");
                if (f.exists()) {
                    try {
                        BitmapFactory.Options bounds = new BitmapFactory.Options();
                        bounds.inJustDecodeBounds = true;
                        BitmapFactory.decodeFile(f.getAbsolutePath(), bounds);
                        if (bounds.outWidth > 0 && bounds.outHeight > 0) {
                            BitmapFactory.Options opts = new BitmapFactory.Options();
                            int sample = 1;
                            while ((bounds.outWidth / (sample * 2)) >= 1280
                                    && (bounds.outHeight / (sample * 2)) >= 720) {
                                sample *= 2;
                            }
                            opts.inSampleSize = sample;
                            opts.inPreferredConfig = Bitmap.Config.RGB_565;
                            wallpaper = BitmapFactory.decodeFile(f.getAbsolutePath(), opts);
                        }
                    } catch (Throwable ignored) {
                        wallpaper = null;
                    }
                }
            }
            invalidate();
        }

        @Override
        protected void onDraw(Canvas canvas) {
            canvas.drawColor(MainActivity.DARK);
            if (wallpaper != null && !wallpaper.isRecycled()) {
                float scale =
                        Math.max(
                                (float) getWidth() / wallpaper.getWidth(),
                                (float) getHeight() / wallpaper.getHeight());
                float w = wallpaper.getWidth() * scale, h = wallpaper.getHeight() * scale;
                canvas.drawBitmap(
                        wallpaper,
                        null,
                        new RectF(
                                (getWidth() - w) / 2,
                                (getHeight() - h) / 2,
                                (getWidth() + w) / 2,
                                (getHeight() + h) / 2),
                        paint);
                int dim = Prefs.clampWallpaperDim(a.prefs.getInt(Prefs.WALLPAPER_DIM, 60));
                canvas.drawColor(Color.argb(Math.round(255 * dim / 100f), 0, 0, 0));
            }
        }

        @Override
        protected void onDetachedFromWindow() {
            super.onDetachedFromWindow();
            wallpaper = null;
        }
    }
}
