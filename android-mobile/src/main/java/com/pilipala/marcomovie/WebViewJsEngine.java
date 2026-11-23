package com.pilipala.marcomovie;

import android.app.Application;
import android.content.SharedPreferences;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Base64;
import android.webkit.JavascriptInterface;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicInteger;
import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;
import okhttp3.ResponseBody;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Off-screen Chromium WebView JavaScript fallback engine for async Promise/ES2022+/DOMParser
 * spiders that fail inside the lightweight QuickJS sandbox.
 */
public final class WebViewJsEngine implements SourceEngine {
    private static final long DEFAULT_TIMEOUT_MS = 25000L;
    private static final int MAX_RESPONSE_BYTES = 12 * 1024 * 1024;
    private static final ConcurrentHashMap<String, WebViewJsEngine> ACTIVE =
            new ConcurrentHashMap<>();

    private static final class PendingSlot {
        private final CountDownLatch latch = new CountDownLatch(1);
        private volatile String value;
        private volatile Throwable failure;

        boolean isDone() {
            return latch.getCount() == 0;
        }

        void complete(String result) {
            if (latch.getCount() == 0) return;
            value = result;
            latch.countDown();
        }

        void completeExceptionally(Throwable error) {
            if (latch.getCount() == 0) return;
            failure = error;
            latch.countDown();
        }

        String get(long timeoutMs) throws Exception {
            if (!latch.await(timeoutMs, TimeUnit.MILLISECONDS)) {
                throw new TimeoutException("timed out after " + timeoutMs + "ms");
            }
            if (failure != null) {
                if (failure instanceof Exception) throw (Exception) failure;
                throw new IOException(failure.getMessage(), failure);
            }
            return value;
        }
    }

    private final Application app;
    private final Cms.Site site;
    private final SharedPreferences storage;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final String proxyKey = UUID.randomUUID().toString().replace("-", "");
    private final ConcurrentHashMap<String, PendingSlot> pending = new ConcurrentHashMap<>();
    private final AtomicInteger callIds = new AtomicInteger(1);
    private WebView webView;
    private volatile boolean closed;

    static boolean shouldFallbackFromJsError(Throwable error) {
        if (error == null) return false;
        if (error instanceof JsEngine.DrpyRuleDetected) return false;
        if (error instanceof java.net.UnknownHostException
                || error instanceof java.net.ConnectException
                || error instanceof java.net.SocketTimeoutException
                || error instanceof javax.net.ssl.SSLException
                || error instanceof InterruptedException) {
            return false;
        }
        String msg = error.getMessage();
        if (msg == null) return true;
        String lower = msg.toLowerCase(Locale.ROOT);
        if (lower.contains("来源返回 http") || lower.contains("配置已更改") || lower.contains("已关闭")) {
            return false;
        }
        return lower.contains("syntaxerror")
                || lower.contains("referenceerror")
                || lower.contains("typeerror")
                || lower.contains("promise")
                || lower.contains("settimeout")
                || lower.contains("domparser")
                || lower.contains("window")
                || lower.contains("document")
                || lower.contains("unexpected")
                || lower.contains("quickjs")
                || lower.contains("not a function")
                || lower.contains("not defined")
                || lower.contains("async")
                || lower.contains("es module");
    }

    static Object[] proxyFor(Map<String, String> params) throws Exception {
        String key = params.get("site");
        if (key == null) return null;
        WebViewJsEngine engine = ACTIVE.get(key);
        if (engine == null || engine.closed) return null;
        return engine.proxy(params);
    }

    public WebViewJsEngine(Application application, Cms.Config config, Cms.Site selected)
            throws Exception {
        this.app = application;
        this.site = selected;
        this.storage = app.getSharedPreferences("wvjs-source-" + sha16(site.key), 0);
        String sourceCode = loadSourceScript(selected);
        if (sourceCode == null || sourceCode.trim().isEmpty()) {
            throw new IOException("WebView JS 引擎未能读取脚本源码");
        }
        if (JsEngine.isQuickJsBytecode(sourceCode)) {
            throw new IOException("QuickJS 字节码脚本无法在 WebView 引擎执行");
        }
        try {
            initWebView();
            JSONObject cfg = new JSONObject();
            cfg.put("skey", site.key);
            cfg.put("stype", site.type);
            cfg.put("ext", site.ext == null ? "" : site.ext);
            cfg.put("proxyUrl", LocalProxy.address() + "/proxy?do=js&site=" + proxyKey);
            String callId = nextCallId();
            PendingSlot future = registerFuture(callId);
            String js =
                    "window.__mmHost.load("
                            + JSONObject.quote(callId)
                            + ","
                            + JSONObject.quote(sourceCode)
                            + ","
                            + JSONObject.quote(cfg.toString())
                            + ");";
            evalOnMain(js);
            awaitFuture(callId, future, DEFAULT_TIMEOUT_MS);
            LocalProxy.webViewJsProxy = WebViewJsEngine::proxyFor;
            ACTIVE.put(proxyKey, this);
        } catch (Exception error) {
            close();
            throw error;
        }
    }

    private String loadSourceScript(Cms.Site s) throws Exception {
        if (s.ext instanceof JSONObject) {
            String embedded = Cms.optSafeString((JSONObject) s.ext, "_mm_entrySource", "");
            if (!embedded.isEmpty()) return embedded;
        }
        if (Cms.isHttp(s.api)) {
            return Cms.fetch(s.api, s.headers);
        }
        throw new IOException("不支持的 WebView JS 地址");
    }

    private void initWebView() throws Exception {
        final String cryptoJs = readAsset("js-host/crypto-js.js");
        final String hostJs = readAsset("js-host/webview-drpy-host.js");
        final PendingSlot ready = new PendingSlot();
        main.post(
                () -> {
                    try {
                        WebView wv = new WebView(app);
                        WebSettings settings = wv.getSettings();
                        settings.setJavaScriptEnabled(true);
                        settings.setDomStorageEnabled(true);
                        settings.setAllowFileAccess(false);
                        settings.setAllowContentAccess(false);
                        if (Build.VERSION.SDK_INT >= 21) {
                            settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
                        }
                        wv.addJavascriptInterface(new HostBridge(), "__mmBridge");
                        wv.setWebViewClient(createWebViewClient(ready, cryptoJs, hostJs));
                        webView = wv;
                        wv.loadDataWithBaseURL(
                                "https://localhost/",
                                "<!doctype html><html><head><meta charset=\"utf-8\"></head><body></body></html>",
                                "text/html",
                                "utf-8",
                                null);
                    } catch (Throwable error) {
                        ready.completeExceptionally(error);
                    }
                });
        try {
            ready.get(10000L);
        } catch (Exception e) {
            throw new IOException("WebView JS 环境初始化失败：" + e.getMessage(), e);
        }
    }

    private WebViewClient createWebViewClient(PendingSlot ready, String cryptoJs, String hostJs) {
        if (Build.VERSION.SDK_INT >= 26) {
            return new Api26WebViewClient(ready, cryptoJs, hostJs);
        }
        return new BaseWebViewClient(ready, cryptoJs, hostJs);
    }

    private class BaseWebViewClient extends WebViewClient {
        private final PendingSlot ready;
        private final String cryptoJs;
        private final String hostJs;

        BaseWebViewClient(PendingSlot ready, String cryptoJs, String hostJs) {
            this.ready = ready;
            this.cryptoJs = cryptoJs;
            this.hostJs = hostJs;
        }

        @Override
        public void onPageFinished(WebView view, String url) {
            if (ready.isDone()) return;
            if (Build.VERSION.SDK_INT >= 19) {
                view.evaluateJavascript(
                        cryptoJs + "\n;" + hostJs + "\n;'ready';", val -> ready.complete("ok"));
            } else {
                ready.completeExceptionally(new IOException("WebView API 版本过低"));
            }
        }
    }

    private final class Api26WebViewClient extends BaseWebViewClient {
        Api26WebViewClient(PendingSlot ready, String cryptoJs, String hostJs) {
            super(ready, cryptoJs, hostJs);
        }

        @Override
        public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
            failAllPending("WebView JS 渲染进程已异常退出");
            close();
            return true;
        }
    }

    private String readAsset(String path) throws IOException {
        try (InputStream in = app.getAssets().open(path)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream(8192);
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    private final class HostBridge {
        @JavascriptInterface
        public String req(String url, String optJson) {
            JSONObject out = new JSONObject();
            try {
                if (!Cms.isHttp(url)) {
                    return out.put("code", 0).put("content", "").toString();
                }
                JSONObject opt =
                        (optJson == null || optJson.isEmpty())
                                ? new JSONObject()
                                : new JSONObject(optJson);
                String method = opt.optString("method", "GET").toUpperCase(Locale.ROOT);
                int bufferMode = opt.optInt("buffer", 0);
                int redirect = opt.optInt("redirect", 1);
                int timeoutMs = Math.max(2000, Math.min(20000, opt.optInt("timeout", 15000)));
                OkHttpClient.Builder clientBuilder =
                        MoviePlayer.mediaHttpClient()
                                .newBuilder()
                                .connectTimeout(timeoutMs, TimeUnit.MILLISECONDS)
                                .readTimeout(timeoutMs, TimeUnit.MILLISECONDS)
                                .followRedirects(redirect != 0)
                                .followSslRedirects(redirect != 0);
                OkHttpClient client = clientBuilder.build();
                Request.Builder reqBuilder = new Request.Builder().url(url);
                JSONObject hdrs = opt.optJSONObject("headers");
                String contentType = null;
                boolean hasUa = false;
                if (hdrs != null) {
                    Iterator<String> keys = hdrs.keys();
                    while (keys.hasNext()) {
                        String k = keys.next();
                        String v = hdrs.optString(k, "");
                        if (k.equalsIgnoreCase("User-Agent")) hasUa = true;
                        if (k.equalsIgnoreCase("Content-Type")) contentType = v;
                        if (!v.isEmpty()) reqBuilder.header(k, v);
                    }
                }
                if (!hasUa) reqBuilder.header("User-Agent", Cms.MOBILE_USER_AGENT);
                if ("POST".equals(method) || "PUT".equals(method) || "PATCH".equals(method)) {
                    Object rawData = opt.has("data") ? opt.opt("data") : opt.opt("body");
                    String bodyStr = rawData == null ? "" : String.valueOf(rawData);
                    String postType = opt.optString("postType", "");
                    MediaType mediaType =
                            MediaType.parse(
                                    contentType != null
                                            ? contentType
                                            : ("form".equalsIgnoreCase(postType)
                                                    ? "application/x-www-form-urlencoded; charset=utf-8"
                                                    : "application/json; charset=utf-8"));
                    reqBuilder.method(method, RequestBody.create(mediaType, bodyStr));
                } else if ("HEAD".equals(method)) {
                    reqBuilder.head();
                } else {
                    reqBuilder.get();
                }
                try (Response resp = client.newCall(reqBuilder.build()).execute()) {
                    out.put("code", resp.code());
                    JSONObject respHeaders = new JSONObject();
                    for (String name : resp.headers().names()) {
                        respHeaders.put(name.toLowerCase(Locale.ROOT), resp.header(name));
                    }
                    out.put("headers", respHeaders);
                    ResponseBody body = resp.body();
                    byte[] raw = body == null ? new byte[0] : readBounded(body.byteStream());
                    if (bufferMode == 2) {
                        out.put("content", Base64.encodeToString(raw, Base64.NO_WRAP));
                    } else if (bufferMode == 1) {
                        JSONArray arr = new JSONArray();
                        for (byte b : raw) arr.put(b & 0xFF);
                        out.put("content", arr);
                    } else {
                        out.put("content", new String(raw, StandardCharsets.UTF_8));
                    }
                }
            } catch (Exception error) {
                try {
                    out.put("code", 0).put("content", "").put("error", error.getMessage());
                } catch (Exception ignored) {
                }
            }
            return out.toString();
        }

        @JavascriptInterface
        public String localGet(String key) {
            return storage.getString(key, "");
        }

        @JavascriptInterface
        public void localSet(String key, String value) {
            storage.edit().putString(key, value == null ? "" : value).apply();
        }

        @JavascriptInterface
        public void localDelete(String key) {
            storage.edit().remove(key).apply();
        }

        @JavascriptInterface
        public void resolve(String callId, String result) {
            PendingSlot future = pending.remove(callId);
            if (future != null) future.complete(result == null ? "" : result);
        }

        @JavascriptInterface
        public void reject(String callId, String message) {
            PendingSlot future = pending.remove(callId);
            if (future != null) {
                future.completeExceptionally(
                        new IOException(message == null ? "WebView JS 执行异常" : message));
            }
        }
    }

    private static byte[] readBounded(InputStream in) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream(8192);
        byte[] buf = new byte[8192];
        int n;
        int total = 0;
        while ((n = in.read(buf)) != -1) {
            total += n;
            if (total > MAX_RESPONSE_BYTES) break;
            out.write(buf, 0, n);
        }
        return out.toByteArray();
    }

    private String nextCallId() {
        return "c" + callIds.getAndIncrement();
    }

    private PendingSlot registerFuture(String callId) {
        PendingSlot future = new PendingSlot();
        pending.put(callId, future);
        return future;
    }

    private void evalOnMain(String js) throws IOException {
        if (closed) throw new IOException("WebView JS 引擎已关闭");
        main.post(
                () -> {
                    if (!closed && webView != null && Build.VERSION.SDK_INT >= 19) {
                        webView.evaluateJavascript(js, null);
                    }
                });
    }

    private String awaitFuture(String callId, PendingSlot future, long timeoutMs) throws Exception {
        try {
            return future.get(timeoutMs);
        } catch (Exception e) {
            pending.remove(callId);
            if (e.getCause() instanceof Exception) throw (Exception) e.getCause();
            if (e instanceof IOException) throw e;
            throw new IOException("WebView JS 调用超时或失败：" + e.getMessage(), e);
        }
    }

    private synchronized String invoke(String method, Object... args) throws Exception {
        if (closed) throw new IOException("WebView JS 引擎已关闭");
        JSONArray arr = new JSONArray();
        for (Object arg : args) arr.put(arg == null ? JSONObject.NULL : arg);
        String callId = nextCallId();
        PendingSlot future = registerFuture(callId);
        String js =
                "window.__mmHost.call("
                        + JSONObject.quote(callId)
                        + ","
                        + JSONObject.quote(method)
                        + ","
                        + JSONObject.quote(arr.toString())
                        + ");";
        evalOnMain(js);
        return awaitFuture(callId, future, DEFAULT_TIMEOUT_MS);
    }

    private void failAllPending(String reason) {
        IOException error = new IOException(reason);
        for (Map.Entry<String, PendingSlot> entry : pending.entrySet()) {
            entry.getValue().completeExceptionally(error);
        }
        pending.clear();
    }

    @Override
    public String home() throws Exception {
        return invoke("home", true);
    }

    @Override
    public String homeVideos() throws Exception {
        return invoke("homeVod");
    }

    @Override
    public String category(String categoryId, int page) throws Exception {
        return category(categoryId, page, null);
    }

    @Override
    public String category(String categoryId, int page, Map<String, String> filters)
            throws Exception {
        JSONObject ext = filters == null ? new JSONObject() : new JSONObject(filters);
        return invoke(
                "category",
                categoryId,
                String.valueOf(page),
                filters != null && !filters.isEmpty(),
                ext);
    }

    @Override
    public String detail(String videoId) throws Exception {
        return invoke("detail", videoId);
    }

    @Override
    public String search(String keyword, int page) throws Exception {
        return invoke("search", keyword, false, String.valueOf(page));
    }

    @Override
    public String player(String flag, String id) throws Exception {
        return invoke("play", flag, id, new JSONArray());
    }

    @Override
    public String action(String action) throws Exception {
        return invoke("action", action);
    }

    Object[] proxy(Map<String, String> params) throws Exception {
        JSONObject map = new JSONObject(params);
        String raw = invoke("proxy", map);
        JSONArray arr = new JSONArray(raw);
        int code = arr.optInt(0, 200);
        String mime = arr.optString(1, "application/octet-stream");
        Object body = arr.opt(2);
        Map<String, String> headers = new LinkedHashMap<>();
        JSONObject hdrs = arr.optJSONObject(3);
        if (hdrs != null) {
            Iterator<String> keys = hdrs.keys();
            while (keys.hasNext()) {
                String k = keys.next();
                headers.put(k, hdrs.optString(k, ""));
            }
        }
        byte[] payload;
        if (body instanceof String && arr.optInt(4, 0) == 1) {
            payload = Base64.decode((String) body, Base64.DEFAULT);
        } else {
            payload =
                    body == null
                            ? new byte[0]
                            : String.valueOf(body).getBytes(StandardCharsets.UTF_8);
        }
        return new Object[] {code, mime, payload, headers};
    }

    @Override
    public boolean requiresExternalRuntime() {
        return false;
    }

    @Override
    public boolean isClosed() {
        return closed;
    }

    @Override
    public void close() {
        if (closed) return;
        closed = true;
        ACTIVE.remove(proxyKey);
        failAllPending("WebView JS 引擎已关闭");
        main.post(
                () -> {
                    WebView wv = webView;
                    webView = null;
                    if (wv != null) {
                        try {
                            wv.stopLoading();
                            wv.loadUrl("about:blank");
                            wv.destroy();
                        } catch (Throwable ignored) {
                        }
                    }
                });
    }

    private static String sha16(String input) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] digest = md.digest(String.valueOf(input).getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < 8; i++)
                sb.append(String.format(Locale.ROOT, "%02x", digest[i] & 0xFF));
            return sb.toString();
        } catch (Exception ignored) {
            return Integer.toHexString(String.valueOf(input).hashCode());
        }
    }
}
