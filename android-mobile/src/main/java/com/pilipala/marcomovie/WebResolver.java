package com.pilipala.marcomovie;

import android.app.Activity;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.view.ViewGroup;
import android.webkit.CookieManager;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import java.io.ByteArrayInputStream;
import java.net.URI;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;
import org.json.JSONArray;
import org.json.JSONTokener;

/**
 * Loads the configured playback page, applies config sniff rules & ad-host blocking, injects
 * optional click scripts & cookies, observes media requests, and preserves playback headers.
 */
public final class WebResolver {
    public interface Listener {
        void media(String url, Map<String, String> headers);

        void failed(String reason);
    }

    private static final Pattern MEDIA_EXT_PATTERN =
            Pattern.compile("(?i).*\\.(m3u8|mp4|mpd|flv|m4v|webm|mkv|m4a|mp3|aac)([?&#].*)?$");
    private static final Pattern STATIC_ASSET_PATTERN =
            Pattern.compile(
                    "(?i).*\\.(html?|css|js|mjs|json|xml|png|jpe?g|gif|webp|svg|ico|woff2?|ttf|otf|eot|map)([?&#].*)?$");
    private static final Pattern EMBEDDED_URL_PARAM_PATTERN =
            Pattern.compile("(?i)[?&](?:url|v|play|src|redirect|link|next)=https?(?::|%3a)");

    final WebView view;
    final Handler main = new Handler(Looper.getMainLooper());
    final Listener callback;
    final Map<String, String> initial;
    final String origin;
    final List<Cms.SniffRule> rules;
    final List<String> ads;
    final String clickScript;
    boolean scriptExecuted;
    boolean stopped;

    private final class LegacyClient extends WebViewClient {
        @Override
        @SuppressWarnings("deprecation")
        public WebResourceResponse shouldInterceptRequest(WebView web, String url) {
            if (url != null) {
                if (isBlockedAdUrl(url, ads)) return emptyResponse();
                if (isMedia(url, origin, rules)) found(url, Collections.<String, String>emptyMap());
            }
            return null;
        }

        @Override
        public void onPageFinished(WebView web, String url) {
            runPageScripts(url);
            scan();
        }

        @Override
        @SuppressWarnings("deprecation")
        public boolean shouldOverrideUrlLoading(WebView web, String url) {
            if (url != null && isDirectStreamScheme(url)) {
                found(url, Collections.<String, String>emptyMap());
                return true;
            }
            return url == null || !Cms.isHttp(url);
        }
    }

    private class Api21Client extends WebViewClient {
        @Override
        public WebResourceResponse shouldInterceptRequest(WebView web, WebResourceRequest request) {
            String url = request.getUrl().toString();
            if (isBlockedAdUrl(url, ads)) return emptyResponse();
            if (isMedia(url, origin, rules)) found(url, request.getRequestHeaders());
            return null;
        }

        @Override
        public void onPageFinished(WebView web, String url) {
            runPageScripts(url);
            scan();
        }

        @Override
        public boolean shouldOverrideUrlLoading(WebView web, WebResourceRequest r) {
            String url = r.getUrl().toString();
            if (isDirectStreamScheme(url)) {
                found(url, r.getRequestHeaders());
                return true;
            }
            return !Cms.isHttp(url);
        }
    }

    private final class Api26Client extends Api21Client {
        @Override
        public boolean onRenderProcessGone(WebView web, RenderProcessGoneDetail detail) {
            if (!stopped) {
                stop();
                callback.failed("网页渲染进程已重启，请重试解析。");
            }
            return true;
        }
    }

    public WebResolver(
            Activity activity, String address, Map<String, String> headers, Listener listener) {
        this(
                activity,
                address,
                headers,
                Collections.emptyList(),
                Collections.emptyList(),
                "",
                listener);
    }

    public WebResolver(
            Activity activity,
            String address,
            Map<String, String> headers,
            List<Cms.SniffRule> sniffRules,
            List<String> adHosts,
            String clickJs,
            Listener listener) {
        origin = address;
        initial = new LinkedHashMap<>(headers);
        rules = sniffRules == null ? Collections.emptyList() : new ArrayList<>(sniffRules);
        ads = adHosts == null ? Collections.emptyList() : new ArrayList<>(adHosts);
        clickScript = clickJs == null ? "" : clickJs.trim();
        callback = listener;
        WebView created = null;
        try {
            created = new WebView(activity);
            WebSettings settings = created.getSettings();
            settings.setJavaScriptEnabled(true);
            settings.setDomStorageEnabled(true);
            settings.setDatabaseEnabled(true);
            settings.setAllowFileAccess(false);
            settings.setAllowContentAccess(false);
            if (Build.VERSION.SDK_INT >= 17) {
                settings.setMediaPlaybackRequiresUserGesture(false);
            }
            if (Build.VERSION.SDK_INT >= 21) {
                settings.setMixedContentMode(WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE);
            }
            String customUa = headerIgnoreCase(headers, "User-Agent");
            if (customUa != null && !customUa.isEmpty()) {
                settings.setUserAgentString(customUa);
            }
            try {
                CookieManager cm = CookieManager.getInstance();
                cm.setAcceptCookie(true);
                if (Build.VERSION.SDK_INT >= 21) {
                    cm.setAcceptThirdPartyCookies(created, true);
                }
                String initialCookie = headerIgnoreCase(headers, "Cookie");
                if (initialCookie != null && !initialCookie.isEmpty()) {
                    for (String piece : initialCookie.split(";")) {
                        String trimmed = piece.trim();
                        if (!trimmed.isEmpty()) cm.setCookie(address, trimmed);
                    }
                    if (Build.VERSION.SDK_INT >= 21) cm.flush();
                }
            } catch (Throwable ignored) {
            }
            created.setWebViewClient(
                    Build.VERSION.SDK_INT >= 26
                            ? new Api26Client()
                            : (Build.VERSION.SDK_INT >= 21
                                    ? new Api21Client()
                                    : new LegacyClient()));
        } catch (Throwable unavailable) {
            AppLog.w("WebResolver", "System WebView unavailable", unavailable);
            if (created != null) {
                try {
                    created.destroy();
                } catch (Throwable ignored) {
                }
                created = null;
            }
        }
        view = created;
        if (view == null) {
            stopped = true;
            main.post(() -> callback.failed("当前系统缺少 WebView 组件，无法网页嗅探此播放地址。"));
            return;
        }
        main.postDelayed(
                () -> {
                    if (!stopped) {
                        callback.failed("页面未返回可直接播放的视频。可在下方网页完成登录或验证，再重试。");
                    }
                },
                30000);
        view.loadUrl(address, headers);
    }

    public WebView view() {
        return view;
    }

    private static WebResourceResponse emptyResponse() {
        return new WebResourceResponse(
                "text/plain", "utf-8", new ByteArrayInputStream(new byte[0]));
    }

    private static String headerIgnoreCase(Map<String, String> headers, String key) {
        if (headers == null) return null;
        for (Map.Entry<String, String> entry : headers.entrySet()) {
            if (key.equalsIgnoreCase(entry.getKey())) return entry.getValue();
        }
        return null;
    }

    static String extractHost(String url) {
        if (url == null || url.isEmpty()) return "";
        try {
            String host = new URI(url).getHost();
            return host == null ? "" : host.toLowerCase(Locale.ROOT);
        } catch (Exception ignored) {
            return "";
        }
    }

    static boolean isDirectStreamScheme(String url) {
        if (url == null) return false;
        String lower = url.toLowerCase(Locale.ROOT);
        return lower.startsWith("rtmp://") || lower.startsWith("rtsp://");
    }

    static boolean isBlockedAdUrl(String url, List<String> adHosts) {
        if (url == null || adHosts == null || adHosts.isEmpty()) return false;
        String host = extractHost(url);
        if (host.isEmpty()) return false;
        for (String item : adHosts) {
            if (item == null) continue;
            String pattern = item.trim().toLowerCase(Locale.ROOT);
            if (pattern.isEmpty()) continue;
            if (pattern.startsWith("*.")) pattern = pattern.substring(2);
            if (host.equals(pattern) || host.endsWith("." + pattern)) {
                return true;
            }
        }
        return false;
    }

    static boolean isMedia(String url) {
        return isMedia(url, "", Collections.emptyList());
    }

    static boolean isMedia(String url, String pageUrl, List<Cms.SniffRule> rules) {
        if (url == null || url.isEmpty()) return false;
        if (isDirectStreamScheme(url)) return true;
        if (!Cms.isHttp(url)) return false;

        // Apply matching host SniffRule exclude & regex first.
        boolean matchedCustomRegex = false;
        if (rules != null && !rules.isEmpty()) {
            for (Cms.SniffRule rule : rules) {
                if (rule == null || !rule.matchesHost(pageUrl)) continue;
                for (String ex : rule.exclude) {
                    if (matchesSafeRegex(ex, url)) return false;
                }
                for (String rx : rule.regex) {
                    if (matchesSafeRegex(rx, url)) {
                        matchedCustomRegex = true;
                        break;
                    }
                }
            }
        }
        if (matchedCustomRegex) return true;

        // Reject query-embedded wrapper URLs (e.g. player.php?url=https://cdn.example/a.m3u8) and
        // static assets.
        if (EMBEDDED_URL_PARAM_PATTERN.matcher(url).find()) return false;
        if (STATIC_ASSET_PATTERN.matcher(url).matches()) return false;

        if (MEDIA_EXT_PATTERN.matcher(url).matches()) return true;
        String lower = url.toLowerCase(Locale.ROOT);
        return lower.contains("/video/tos/")
                || lower.contains("mime=video")
                || lower.contains("index.m3u8")
                || lower.contains("master.m3u8")
                || lower.contains("playlist.m3u8");
    }

    private static boolean matchesSafeRegex(String regex, String target) {
        if (regex == null || regex.trim().isEmpty()) return false;
        try {
            return Pattern.compile(regex).matcher(target).find();
        } catch (Exception ignored) {
            return target.contains(regex);
        }
    }

    void runPageScripts(String pageUrl) {
        if (stopped || view == null || scriptExecuted || Build.VERSION.SDK_INT < 19) return;
        StringBuilder combined = new StringBuilder();
        if (!clickScript.isEmpty()) {
            combined.append(clickScript).append(";\n");
        }
        for (Cms.SniffRule rule : rules) {
            if (rule != null
                    && rule.script != null
                    && !rule.script.trim().isEmpty()
                    && rule.matchesHost(pageUrl)) {
                combined.append(rule.script.trim()).append(";\n");
            }
        }
        if (combined.length() == 0) return;
        scriptExecuted = true;
        final String js = "try{" + combined + "}catch(e){}";
        main.postDelayed(
                () -> {
                    if (!stopped && view != null) {
                        view.evaluateJavascript(js, null);
                    }
                },
                600L);
    }

    void scan() {
        if (stopped || view == null) return;
        if (Build.VERSION.SDK_INT >= 19) {
            view.evaluateJavascript(
                    "(function(){var u=[];"
                            + "document.querySelectorAll('video,audio,source').forEach(function(v){var s=v.currentSrc||v.src;if(s)u.push(s);});"
                            + "return JSON.stringify(u);})()",
                    value -> {
                        if (stopped || view == null) return;
                        try {
                            Object decoded = new JSONTokener(value).nextValue();
                            JSONArray urls = new JSONArray(String.valueOf(decoded));
                            for (int i = 0; i < urls.length(); i++) {
                                String u = urls.optString(i);
                                if ((Cms.isHttp(u) || isDirectStreamScheme(u))
                                        && !STATIC_ASSET_PATTERN.matcher(u).matches()) {
                                    found(u, Collections.<String, String>emptyMap());
                                    return;
                                }
                            }
                        } catch (Exception ignored) {
                        }
                        main.postDelayed(this::scan, 1500);
                    });
        }
    }

    void found(String url, Map<String, String> captured) {
        main.post(
                () -> {
                    if (stopped || view == null) return;
                    Map<String, String> headers = new LinkedHashMap<>(initial);
                    headers.putAll(captured);
                    headers.remove("Host");
                    headers.remove("host");
                    headers.remove("Range");
                    headers.remove("range");
                    headers.put("User-Agent", view.getSettings().getUserAgentString());
                    if (!headers.containsKey("Referer") && !headers.containsKey("referer"))
                        headers.put("Referer", view.getUrl() == null ? origin : view.getUrl());
                    try {
                        String cookie = CookieManager.getInstance().getCookie(url);
                        if (cookie != null && !cookie.isEmpty()) headers.put("Cookie", cookie);
                    } catch (Throwable ignored) {
                    }
                    stop();
                    callback.media(url, headers);
                });
    }

    public void stop() {
        if (stopped) return;
        stopped = true;
        main.removeCallbacksAndMessages(null);
        if (view == null) return;
        view.stopLoading();
        view.loadUrl("about:blank");
        if (view.getParent() instanceof ViewGroup) ((ViewGroup) view.getParent()).removeView(view);
        view.destroy();
    }
}
