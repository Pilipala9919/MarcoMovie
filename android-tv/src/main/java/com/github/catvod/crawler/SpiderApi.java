package com.github.catvod.crawler;

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import java.io.InputStream;
import java.net.URLEncoder;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.zip.GZIPInputStream;
import okhttp3.Headers;
import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;
import okhttp3.ResponseBody;

/** Host callback ABI expected by Spider.initApi(SpiderApi) in third-party JAR extensions. */
public class SpiderApi {
    private static final int MAX_CONCURRENCY = 16;
    private static final int MAX_BATCH_SIZE = 128;
    private static final int MAX_RESPONSE_BYTES = 8 * 1024 * 1024;
    private static final long BATCH_TIMEOUT_MS = 45_000L;
    private static final Pattern CHARSET_PATTERN =
            Pattern.compile("charset\\s*=\\s*[\"']?([^;\"'\\s]+)", Pattern.CASE_INSENSITIVE);

    private static final AtomicInteger WORKER_ID = new AtomicInteger(1);
    private static final ExecutorService MULTI_REQ_EXECUTOR =
            Executors.newFixedThreadPool(
                    MAX_CONCURRENCY,
                    r -> {
                        Thread t =
                                new Thread(
                                        r, "marco-spider-multireq-" + WORKER_ID.getAndIncrement());
                        t.setDaemon(true);
                        return t;
                    });

    public SpiderApi() {}

    public void log(String message) {}

    public String getAddress(boolean local) {
        return "http://127.0.0.1:" + com.pilipala.marcomovie.CspEngine.proxyPort() + "/";
    }

    public String getPort() {
        return String.valueOf(com.pilipala.marcomovie.CspEngine.proxyPort());
    }

    public String multiReq(JsonArray requests) {
        if (requests == null || requests.size() == 0) {
            return "[]";
        }
        final int count = Math.min(requests.size(), MAX_BATCH_SIZE);
        List<Future<JsonObject>> futures = new ArrayList<>(count);
        for (int i = 0; i < count; i++) {
            final JsonElement spec = requests.get(i);
            Callable<JsonObject> task = () -> executeSingleRequest(spec);
            futures.add(MULTI_REQ_EXECUTOR.submit(task));
        }

        long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(BATCH_TIMEOUT_MS);
        JsonArray results = new JsonArray();
        for (int i = 0; i < count; i++) {
            Future<JsonObject> future = futures.get(i);
            long remainingMs =
                    Math.max(1L, TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime()));
            try {
                results.add(future.get(remainingMs, TimeUnit.MILLISECONDS));
            } catch (TimeoutException te) {
                future.cancel(true);
                results.add(
                        failureResult(
                                extractUrl(requests.get(i)),
                                "TimeoutException: request timed out"));
            } catch (InterruptedException ie) {
                for (int j = i; j < count; j++) futures.get(j).cancel(true);
                Thread.currentThread().interrupt();
                results.add(failureResult(extractUrl(requests.get(i)), "InterruptedException"));
            } catch (Exception ex) {
                Throwable cause = ex.getCause() != null ? ex.getCause() : ex;
                results.add(
                        failureResult(
                                extractUrl(requests.get(i)),
                                cause.getClass().getSimpleName()
                                        + (cause.getMessage() != null
                                                ? ": " + cause.getMessage()
                                                : "")));
            }
        }
        return results.toString();
    }

    public String webParse(String url, String extra) {
        return "";
    }

    private static String extractUrl(JsonElement element) {
        if (element == null || element.isJsonNull()) return "";
        if (element.isJsonPrimitive()) return element.getAsString();
        if (element.isJsonObject()) {
            JsonObject obj = element.getAsJsonObject();
            String url = optString(obj, "url", "");
            if (url.isEmpty()) url = optString(obj, "address", "");
            return url;
        }
        return "";
    }

    private static JsonObject executeSingleRequest(JsonElement element) {
        String rawUrl = extractUrl(element).trim();
        if (rawUrl.isEmpty()
                || !(rawUrl.regionMatches(true, 0, "http://", 0, 7)
                        || rawUrl.regionMatches(true, 0, "https://", 0, 8))) {
            return failureResult(rawUrl, "Invalid HTTP(S) URL");
        }
        JsonObject root = element.isJsonObject() ? element.getAsJsonObject() : new JsonObject();
        JsonObject opts =
                root.has("options") && root.get("options").isJsonObject()
                        ? root.getAsJsonObject("options")
                        : root;

        try {
            String targetUrl = appendQueryParams(rawUrl, getObject(opts, root, "params"));
            String method =
                    optString(opts, "method", optString(root, "method", "GET"))
                            .trim()
                            .toUpperCase(Locale.ROOT);
            if (method.isEmpty()) method = "GET";
            if ("HEADER".equals(method)) method = "HEAD";

            JsonObject hdrObj = getObject(opts, root, "headers");
            if (hdrObj == null) hdrObj = getObject(opts, root, "header");

            Request.Builder reqBuilder = new Request.Builder().url(targetUrl);
            boolean hasUa = false;
            String contentTypeHeader = null;
            if (hdrObj != null) {
                for (Map.Entry<String, JsonElement> entry : hdrObj.entrySet()) {
                    String k = entry.getKey();
                    JsonElement vEl = entry.getValue();
                    if (k == null || vEl == null || vEl.isJsonNull() || !vEl.isJsonPrimitive())
                        continue;
                    String v = vEl.getAsString();
                    if (k.indexOf('\r') >= 0
                            || k.indexOf('\n') >= 0
                            || v.indexOf('\r') >= 0
                            || v.indexOf('\n') >= 0) {
                        continue;
                    }
                    if ("User-Agent".equalsIgnoreCase(k)) hasUa = true;
                    if ("Content-Type".equalsIgnoreCase(k)) contentTypeHeader = v;
                    reqBuilder.header(k, v);
                }
            }
            if (!hasUa) {
                reqBuilder.header("User-Agent", "okhttp/3.15");
            }

            RequestBody requestBody = buildRequestBody(method, opts, root, contentTypeHeader);
            reqBuilder.method(method, requestBody);

            OkHttpClient baseClient = Spider.client();
            boolean followRedirects = parseRedirectFlag(opts, root);
            int timeoutMs = optInt(opts, root, "timeout", -1);

            OkHttpClient callClient = baseClient;
            if (!followRedirects || timeoutMs > 0) {
                OkHttpClient.Builder cb = baseClient.newBuilder();
                if (!followRedirects) {
                    cb.followRedirects(false).followSslRedirects(false);
                }
                if (timeoutMs > 0) {
                    int bounded = Math.max(500, Math.min(timeoutMs, 30_000));
                    cb.connectTimeout(bounded, TimeUnit.MILLISECONDS)
                            .readTimeout(bounded, TimeUnit.MILLISECONDS)
                            .writeTimeout(bounded, TimeUnit.MILLISECONDS);
                }
                callClient = cb.build();
            }

            int bufferMode = optInt(opts, root, "buffer", 0);
            String requestedCharset = optString(opts, "encoding", optString(opts, "charset", ""));

            try (Response response = callClient.newCall(reqBuilder.build()).execute()) {
                int code = response.code();
                Headers resHeaders = response.headers();
                JsonObject headersJson = new JsonObject();
                for (String name : resHeaders.names()) {
                    List<String> values = resHeaders.values(name);
                    if (values != null && !values.isEmpty()) {
                        StringBuilder joined = new StringBuilder();
                        for (int i = 0; i < values.size(); i++) {
                            if (i > 0) joined.append(", ");
                            joined.append(values.get(i));
                        }
                        headersJson.addProperty(name.toLowerCase(Locale.ROOT), joined.toString());
                    }
                }

                byte[] bytes = new byte[0];
                ResponseBody body = response.body();
                if (body != null && !"HEAD".equals(method)) {
                    InputStream stream = body.byteStream();
                    if ("gzip".equalsIgnoreCase(response.header("Content-Encoding"))) {
                        stream = new GZIPInputStream(stream);
                    }
                    try (InputStream in = stream) {
                        bytes = Spider.readBoundedBytes(in, MAX_RESPONSE_BYTES);
                    }
                }

                JsonObject out = new JsonObject();
                out.addProperty("code", code);
                out.add("headers", headersJson);
                out.addProperty("url", response.request().url().toString());
                if (bufferMode == 2) {
                    out.addProperty("content", base64Encode(bytes));
                } else if (bufferMode == 1) {
                    JsonArray arr = new JsonArray();
                    for (byte b : bytes) arr.add(b & 0xff);
                    out.add("content", arr);
                } else {
                    Charset cs = resolveCharset(requestedCharset, response.header("Content-Type"));
                    out.addProperty("content", new String(bytes, cs));
                }
                if (root.has("id") && root.get("id").isJsonPrimitive()) {
                    out.add("id", root.get("id"));
                }
                return out;
            }
        } catch (Exception e) {
            JsonObject err =
                    failureResult(
                            rawUrl,
                            e.getClass().getSimpleName()
                                    + (e.getMessage() != null ? ": " + e.getMessage() : ""));
            if (root.has("id") && root.get("id").isJsonPrimitive()) {
                err.add("id", root.get("id"));
            }
            return err;
        }
    }

    private static RequestBody buildRequestBody(
            String method, JsonObject opts, JsonObject root, String contentTypeHeader)
            throws Exception {
        if ("GET".equals(method) || "HEAD".equals(method)) {
            return null;
        }
        JsonElement bodyEl = opts.has("body") ? opts.get("body") : root.get("body");
        JsonElement dataEl = opts.has("data") ? opts.get("data") : root.get("data");
        String postType =
                optString(opts, "postType", optString(root, "postType", ""))
                        .toLowerCase(Locale.ROOT);

        if (bodyEl != null && !bodyEl.isJsonNull()) {
            String media =
                    contentTypeHeader != null ? contentTypeHeader : "text/plain; charset=utf-8";
            if (bodyEl.isJsonPrimitive()) {
                return RequestBody.create(
                        MediaType.parse(media), bodyEl.getAsString().getBytes("UTF-8"));
            }
            return RequestBody.create(
                    MediaType.parse(
                            contentTypeHeader != null
                                    ? contentTypeHeader
                                    : "application/json; charset=utf-8"),
                    bodyEl.toString().getBytes("UTF-8"));
        }

        if (dataEl != null && !dataEl.isJsonNull()) {
            boolean form =
                    "form".equals(postType)
                            || (contentTypeHeader != null
                                    && contentTypeHeader
                                            .toLowerCase(Locale.ROOT)
                                            .contains("application/x-www-form-urlencoded"));
            if (form && dataEl.isJsonObject()) {
                StringBuilder sb = new StringBuilder();
                for (Map.Entry<String, JsonElement> entry : dataEl.getAsJsonObject().entrySet()) {
                    JsonElement v = entry.getValue();
                    if (v == null || v.isJsonNull()) continue;
                    if (sb.length() > 0) sb.append('&');
                    sb.append(URLEncoder.encode(entry.getKey(), "UTF-8"))
                            .append('=')
                            .append(
                                    URLEncoder.encode(
                                            v.isJsonPrimitive() ? v.getAsString() : v.toString(),
                                            "UTF-8"));
                }
                return RequestBody.create(
                        MediaType.parse("application/x-www-form-urlencoded; charset=UTF-8"),
                        sb.toString().getBytes("UTF-8"));
            }
            if (dataEl.isJsonPrimitive()) {
                String media =
                        contentTypeHeader != null
                                ? contentTypeHeader
                                : ("form".equals(postType)
                                        ? "application/x-www-form-urlencoded; charset=UTF-8"
                                        : "text/plain; charset=utf-8");
                return RequestBody.create(
                        MediaType.parse(media), dataEl.getAsString().getBytes("UTF-8"));
            }
            return RequestBody.create(
                    MediaType.parse(
                            contentTypeHeader != null
                                    ? contentTypeHeader
                                    : "application/json; charset=utf-8"),
                    dataEl.toString().getBytes("UTF-8"));
        }

        if ("POST".equals(method) || "PUT".equals(method) || "PATCH".equals(method)) {
            return RequestBody.create(null, new byte[0]);
        }
        return null;
    }

    private static String appendQueryParams(String url, JsonObject params) throws Exception {
        if (params == null || params.entrySet().isEmpty()) return url;
        int hashIdx = url.indexOf('#');
        String base = hashIdx >= 0 ? url.substring(0, hashIdx) : url;
        String fragment = hashIdx >= 0 ? url.substring(hashIdx) : "";
        StringBuilder sb = new StringBuilder();
        for (Map.Entry<String, JsonElement> entry : params.entrySet()) {
            JsonElement val = entry.getValue();
            if (val == null || val.isJsonNull()) continue;
            if (val.isJsonArray()) {
                for (JsonElement item : val.getAsJsonArray()) {
                    if (item == null || item.isJsonNull() || !item.isJsonPrimitive()) continue;
                    if (sb.length() > 0) sb.append('&');
                    sb.append(URLEncoder.encode(entry.getKey(), "UTF-8"))
                            .append('=')
                            .append(URLEncoder.encode(item.getAsString(), "UTF-8"));
                }
            } else if (val.isJsonPrimitive()) {
                if (sb.length() > 0) sb.append('&');
                sb.append(URLEncoder.encode(entry.getKey(), "UTF-8"))
                        .append('=')
                        .append(URLEncoder.encode(val.getAsString(), "UTF-8"));
            }
        }
        if (sb.length() == 0) return url;
        return base + (base.contains("?") ? "&" : "?") + sb + fragment;
    }

    private static Charset resolveCharset(String requested, String contentType) {
        String candidate = requested != null ? requested.trim() : "";
        if (candidate.isEmpty() && contentType != null) {
            Matcher m = CHARSET_PATTERN.matcher(contentType);
            if (m.find()) candidate = m.group(1).trim();
        }
        if (!candidate.isEmpty()) {
            try {
                if (Charset.isSupported(candidate)) return Charset.forName(candidate);
            } catch (Exception ignored) {
            }
        }
        return Charset.forName("UTF-8");
    }

    private static JsonObject failureResult(String url, String error) {
        JsonObject out = new JsonObject();
        out.addProperty("code", 0);
        out.addProperty("content", "");
        out.add("headers", new JsonObject());
        out.addProperty("url", url == null ? "" : url);
        out.addProperty("error", error == null ? "Request failed" : error);
        return out;
    }

    private static JsonObject getObject(JsonObject primary, JsonObject secondary, String key) {
        if (primary != null && primary.has(key) && primary.get(key).isJsonObject()) {
            return primary.getAsJsonObject(key);
        }
        if (secondary != null && secondary.has(key) && secondary.get(key).isJsonObject()) {
            return secondary.getAsJsonObject(key);
        }
        return null;
    }

    private static String optString(JsonObject obj, String key, String fallback) {
        if (obj == null || !obj.has(key)) return fallback;
        JsonElement el = obj.get(key);
        if (el == null || el.isJsonNull() || !el.isJsonPrimitive()) return fallback;
        return el.getAsString();
    }

    private static int optInt(JsonObject primary, JsonObject secondary, String key, int fallback) {
        for (JsonObject src : new JsonObject[] {primary, secondary}) {
            if (src != null && src.has(key)) {
                JsonElement el = src.get(key);
                if (el != null && el.isJsonPrimitive()) {
                    try {
                        return el.getAsInt();
                    } catch (Exception ignored) {
                    }
                }
            }
        }
        return fallback;
    }

    private static boolean parseRedirectFlag(JsonObject primary, JsonObject secondary) {
        for (JsonObject src : new JsonObject[] {primary, secondary}) {
            if (src != null && src.has("redirect")) {
                JsonElement el = src.get("redirect");
                if (el != null && el.isJsonPrimitive()) {
                    if (el.getAsJsonPrimitive().isBoolean()) return el.getAsBoolean();
                    try {
                        return el.getAsInt() != 0;
                    } catch (Exception ignored) {
                    }
                }
            }
        }
        return true;
    }

    private static String base64Encode(byte[] input) {
        String alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        StringBuilder out = new StringBuilder(((input.length + 2) / 3) * 4);
        for (int i = 0; i < input.length; i += 3) {
            int a = input[i] & 0xff;
            int b = i + 1 < input.length ? input[i + 1] & 0xff : 0;
            int c = i + 2 < input.length ? input[i + 2] & 0xff : 0;
            out.append(alphabet.charAt(a >> 2));
            out.append(alphabet.charAt(((a & 0x03) << 4) | (b >> 4)));
            out.append(
                    i + 1 < input.length ? alphabet.charAt(((b & 0x0f) << 2) | (c >> 6)) : '=');
            out.append(i + 2 < input.length ? alphabet.charAt(c & 0x3f) : '=');
        }
        return out.toString();
    }
}
