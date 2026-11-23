package com.pilipala.marcomovie;

import android.content.Context;
import android.net.wifi.WifiManager;
import android.os.Build;
import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.net.URL;
import java.net.URLEncoder;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.json.JSONArray;
import org.json.JSONObject;
import org.json.JSONTokener;

/**
 * Local-only Android companion implementation of the {@code marco-spider-gateway-v1} BYO protocol
 * consumed by Marco Movie on iOS, iPadOS, macOS, Windows, and HarmonyOS.
 *
 * <p>Advertises presence on UDP port 41978 when queried with {@code MARCO_SPIDER_GATEWAY_PROBE_V1}
 * (NEVER revealing the Bearer token in discovery replies), and serves authenticated LAN JSON
 * spider metadata calls ({@code home / homeVod / category / search / detail / play}) over HTTP
 * (default port 9981) using Android's native {@link CspEngine} / {@link GuardEngine} / {@link
 * JsEngine} / {@link DrpyEngine} runtimes.
 */
final class SpiderGatewayServer implements Closeable {
    static final String PROTOCOL_ID = "marco-spider-gateway-v1";
    static final int DEFAULT_HTTP_PORT = 9981;
    static final int DISCOVERY_UDP_PORT = 41978;
    static final String DISCOVERY_PROBE_PAYLOAD = "MARCO_SPIDER_GATEWAY_PROBE_V1";
    static final int MAX_BODY_BYTES = 2 * 1024 * 1024;
    private static final int MAX_CACHED_REMOTE_ENGINES = 12;

    interface ActionDispatcher {
        String dispatch(String action, JSONObject siteObj, JSONObject paramsObj) throws Exception;

        int routeCount();

        default void close() {}
    }

    final ServerSocket httpSocket;
    final DatagramSocket udpSocket;
    final int httpPort;
    final int discoveryPort;
    final String token;
    final String pairPath;
    final String engineName;
    final boolean supportsNativeSo;
    final ActionDispatcher dispatcher;
    final Runnable onStatusChanged;
    final WifiManager.MulticastLock multicastLock;
    final AtomicInteger servedRequests = new AtomicInteger();
    volatile String deviceName;
    volatile String lastActivity = "等待局域网设备连接…";
    volatile boolean closed;

    private final ThreadPoolExecutor httpPool =
            new ThreadPoolExecutor(
                    2,
                    8,
                    30,
                    TimeUnit.SECONDS,
                    new LinkedBlockingQueue<Runnable>(32),
                    r -> {
                        Thread t = new Thread(r, "marco-spider-gw-http");
                        t.setDaemon(true);
                        return t;
                    });

    SpiderGatewayServer(
            int requestedHttpPort,
            int requestedDiscoveryPort,
            String bearerToken,
            String friendlyName,
            String engineName,
            boolean supportsNativeSo,
            ActionDispatcher dispatcher,
            WifiManager.MulticastLock multicastLock,
            Runnable onStatusChanged)
            throws IOException {
        if (dispatcher == null) throw new IllegalArgumentException("dispatcher required");
        this.token =
                bearerToken != null && !bearerToken.trim().isEmpty()
                        ? bearerToken.trim()
                        : generateToken();
        this.deviceName =
                friendlyName != null && !friendlyName.trim().isEmpty()
                        ? friendlyName.trim()
                        : "Marco Movie Android 网关";
        this.engineName =
                engineName != null && !engineName.trim().isEmpty()
                        ? engineName.trim()
                        : "android-csp";
        this.supportsNativeSo = supportsNativeSo;
        this.dispatcher = dispatcher;
        this.multicastLock = multicastLock;
        this.onStatusChanged = onStatusChanged;
        this.pairPath = "/marco-gateway/v1/pair/" + randomHex(16);

        ServerSocket boundHttp = new ServerSocket();
        boundHttp.setReuseAddress(true);
        try {
            boundHttp.bind(new InetSocketAddress("0.0.0.0", Math.max(0, requestedHttpPort)));
        } catch (IOException portBusy) {
            if (requestedHttpPort == 0) throw portBusy;
            boundHttp.close();
            boundHttp = new ServerSocket();
            boundHttp.setReuseAddress(true);
            boundHttp.bind(new InetSocketAddress("0.0.0.0", 0));
        }
        this.httpSocket = boundHttp;
        this.httpPort = httpSocket.getLocalPort();

        DatagramSocket boundUdp = null;
        int boundUdpPort = 0;
        if (requestedDiscoveryPort >= 0) {
            try {
                DatagramSocket ds = new DatagramSocket(null);
                ds.setReuseAddress(true);
                ds.setBroadcast(true);
                ds.bind(new InetSocketAddress("0.0.0.0", requestedDiscoveryPort));
                ds.setSoTimeout(500);
                boundUdp = ds;
                boundUdpPort = ds.getLocalPort();
            } catch (IOException ignored) {
                // UDP 41978 busy — HTTP gateway still remains reachable by manual URL.
            }
        }
        this.udpSocket = boundUdp;
        this.discoveryPort = boundUdpPort;

        startAcceptLoop();
        if (this.udpSocket != null) {
            startDiscoveryLoop();
        }
    }

    static String generateToken() {
        return randomHex(8);
    }

    private static String randomHex(int numBytes) {
        byte[] bytes = new byte[Math.max(4, numBytes)];
        new SecureRandom().nextBytes(bytes);
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) sb.append(String.format(Locale.ROOT, "%02x", b & 255));
        return sb.toString();
    }

    static String defaultDeviceName(MainActivity a) {
        if (a != null && a.prefs != null) {
            String saved = a.prefs.getString(Prefs.SPIDER_GATEWAY_NAME, "").trim();
            if (!saved.isEmpty()) return saved;
            String castName = a.prefs.getString(Prefs.CAST_DEVICE_NAME, "").trim();
            if (!castName.isEmpty()) return castName;
        }
        String model = Build.MODEL != null ? Build.MODEL.trim() : "";
        if (!model.isEmpty()) {
            return model + " · Marco Movie";
        }
        return "Marco Movie Android 网关";
    }

    static String ensureToken(MainActivity a) {
        if (a == null || a.prefs == null) return generateToken();
        String existing = a.prefs.getString(Prefs.SPIDER_GATEWAY_TOKEN, "").trim();
        if (existing.length() >= 8) return existing;
        String fresh = generateToken();
        a.prefs.edit().putString(Prefs.SPIDER_GATEWAY_TOKEN, fresh).apply();
        return fresh;
    }

    static String resetToken(MainActivity a) {
        String fresh = generateToken();
        if (a != null && a.prefs != null) {
            a.prefs.edit().putString(Prefs.SPIDER_GATEWAY_TOKEN, fresh).apply();
        }
        return fresh;
    }

    static String formatDisplayToken(String token) {
        if (token == null || token.isEmpty()) return "";
        String clean = token.trim();
        if (clean.length() != 16) return clean;
        return clean.substring(0, 4)
                + " "
                + clean.substring(4, 8)
                + " "
                + clean.substring(8, 12)
                + " "
                + clean.substring(12, 16);
    }

    /** Discovery reply payload (never contains Bearer token). */
    static String buildDiscoveryReplyJson(
            int httpPort, String deviceName, String engineName, boolean supportsNativeSo) {
        try {
            return new JSONObject()
                    .put("protocol", PROTOCOL_ID)
                    .put("port", httpPort)
                    .put("deviceName", deviceName == null ? "" : deviceName)
                    .put("engine", engineName == null ? "android-csp" : engineName)
                    .put("supportsNativeSo", supportsNativeSo)
                    .put("requiresToken", true)
                    .toString();
        } catch (Exception e) {
            return "{\"protocol\":\""
                    + PROTOCOL_ID
                    + "\",\"port\":"
                    + httpPort
                    + ",\"requiresToken\":true}";
        }
    }

    static boolean isAuthorized(String authHeader, String expectedToken) {
        if (authHeader == null || expectedToken == null || expectedToken.isEmpty()) return false;
        String trimmed = authHeader.trim();
        if (trimmed.length() < 8) return false;
        String prefix = trimmed.substring(0, 7);
        if (!"bearer ".equalsIgnoreCase(prefix)) return false;
        String supplied = trimmed.substring(7).trim();
        return constantTimeEquals(supplied, expectedToken);
    }

    static boolean constantTimeEquals(String a, String b) {
        if (a == null || b == null) return false;
        try {
            return MessageDigest.isEqual(a.getBytes("UTF-8"), b.getBytes("UTF-8"));
        } catch (Exception e) {
            return false;
        }
    }

    private static final Pattern LOOPBACK_PROXY_URL_PATTERN =
            Pattern.compile(
                    "http" + "://(?:127\\.0\\.0\\.1|localhost):(\\d+)/proxy(\\?[^\"'\\s#$]*)?",
                    Pattern.CASE_INSENSITIVE);

    /**
     * Rewrites loopback {@code http://127.0.0.1:<port>/proxy?...} URLs inside a spider's {@code
     * play} response into authenticated LAN gateway proxy URLs so companion iOS/macOS/Windows
     * clients can stream spider-proxied media when required. Direct upstream CDN URLs are never
     * modified.
     */
    static String rewriteLoopbackProxyUrls(
            String rawPayload, String lanHost, int gatewayPort, String gatewayToken) {
        if (rawPayload == null
                || rawPayload.isEmpty()
                || lanHost == null
                || lanHost.trim().isEmpty()
                || gatewayPort <= 0
                || gatewayToken == null
                || gatewayToken.isEmpty()) {
            return rawPayload;
        }
        Matcher m = LOOPBACK_PROXY_URL_PATTERN.matcher(rawPayload);
        if (!m.find()) return rawPayload;
        String encodedToken;
        try {
            encodedToken = URLEncoder.encode(gatewayToken, "UTF-8");
        } catch (Exception e) {
            encodedToken = gatewayToken;
        }
        StringBuffer out = new StringBuffer(rawPayload.length() + 64);
        m.reset();
        while (m.find()) {
            String query = m.group(2);
            String rewrittenQuery;
            if (query == null || query.isEmpty() || "?".equals(query)) {
                rewrittenQuery = "?token=" + encodedToken;
            } else {
                rewrittenQuery = "?token=" + encodedToken + "&" + query.substring(1);
            }
            String replacement =
                    "http://"
                            + lanHost.trim()
                            + ":"
                            + gatewayPort
                            + "/marco-gateway/v1/proxy"
                            + rewrittenQuery;
            m.appendReplacement(out, Matcher.quoteReplacement(replacement));
        }
        m.appendTail(out);
        return out.toString();
    }

    String baseUrl(String lanHost) {
        if (lanHost == null || lanHost.trim().isEmpty()) return "";
        return "http://" + lanHost.trim() + ":" + httpPort;
    }

    String pairUrl(String lanHost) {
        String base = baseUrl(lanHost);
        return base.isEmpty() ? "" : base + pairPath;
    }

    void updateDeviceName(String next) {
        if (next != null && !next.trim().isEmpty()) {
            this.deviceName = next.trim();
        }
    }

    boolean isUdpDiscoveryActive() {
        return udpSocket != null && !udpSocket.isClosed() && discoveryPort > 0;
    }

    static SpiderGatewayServer startForActivity(MainActivity a, Runnable onStatusChanged)
            throws IOException {
        if (a == null) throw new IOException("Activity unavailable");
        int preferredPort =
                a.prefs != null
                        ? a.prefs.getInt(Prefs.SPIDER_GATEWAY_PORT, DEFAULT_HTTP_PORT)
                        : DEFAULT_HTTP_PORT;
        if (preferredPort < 1024 || preferredPort > 65535) preferredPort = DEFAULT_HTTP_PORT;
        String token = ensureToken(a);
        String name = defaultDeviceName(a);

        WifiManager.MulticastLock lock = null;
        try {
            WifiManager wm =
                    (WifiManager) a.getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            if (wm != null) {
                lock = wm.createMulticastLock("marcomovie-spider-gateway");
                lock.setReferenceCounted(false);
                lock.acquire();
            }
        } catch (Throwable ignored) {
        }

        AndroidSpiderDispatcher dispatcher = new AndroidSpiderDispatcher(a);
        try {
            return new SpiderGatewayServer(
                    preferredPort,
                    DISCOVERY_UDP_PORT,
                    token,
                    name,
                    "android-csp",
                    true,
                    dispatcher,
                    lock,
                    onStatusChanged);
        } catch (IOException ex) {
            dispatcher.close();
            releaseMulticastLock(lock);
            throw ex;
        }
    }

    private void startAcceptLoop() {
        Thread accept =
                new Thread(
                        () -> {
                            while (!closed) {
                                try {
                                    Socket client = httpSocket.accept();
                                    try {
                                        httpPool.execute(() -> serveHttp(client));
                                    } catch (RejectedExecutionException full) {
                                        closeQuietly(client);
                                    }
                                } catch (IOException err) {
                                    if (!closed) {
                                        AppLog.w("SpiderGateway", "HTTP accept closed", err);
                                    }
                                    break;
                                }
                            }
                        },
                        "marco-spider-gw-accept");
        accept.setDaemon(true);
        accept.start();
    }

    private void startDiscoveryLoop() {
        Thread udp =
                new Thread(
                        () -> {
                            byte[] buf = new byte[512];
                            while (!closed && udpSocket != null && !udpSocket.isClosed()) {
                                try {
                                    DatagramPacket packet = new DatagramPacket(buf, buf.length);
                                    udpSocket.receive(packet);
                                    InetAddress peer = packet.getAddress();
                                    if (!ConfigTransferServer.isAllowedLanPeer(peer)) continue;
                                    String payload =
                                            new String(
                                                            packet.getData(),
                                                            packet.getOffset(),
                                                            packet.getLength(),
                                                            "UTF-8")
                                                    .trim();
                                    if (!DISCOVERY_PROBE_PAYLOAD.equals(payload)) continue;
                                    byte[] replyBytes =
                                            buildDiscoveryReplyJson(
                                                            httpPort,
                                                            deviceName,
                                                            engineName,
                                                            supportsNativeSo)
                                                    .getBytes("UTF-8");
                                    DatagramPacket reply =
                                            new DatagramPacket(
                                                    replyBytes,
                                                    replyBytes.length,
                                                    packet.getSocketAddress());
                                    udpSocket.send(reply);
                                } catch (SocketTimeoutException ignored) {
                                } catch (IOException err) {
                                    if (!closed) {
                                        AppLog.w("SpiderGateway", "UDP discovery loop error", err);
                                    }
                                    break;
                                }
                            }
                        },
                        "marco-spider-gw-udp");
        udp.setDaemon(true);
        udp.start();
    }

    private void serveHttp(Socket client) {
        try (Socket s = client) {
            s.setSoTimeout(25000);
            InputStream in = s.getInputStream();
            OutputStream out = s.getOutputStream();
            InetAddress peer = s.getInetAddress();
            if (!ConfigTransferServer.isAllowedLanPeer(peer)) {
                sendJson(out, 403, new JSONObject().put("ok", false).put("error", "LAN only"));
                return;
            }
            String requestLine = ConfigTransferServer.line(in, 4096);
            String[] parts = requestLine.split(" ");
            if (parts.length < 3) return;
            String method = parts[0];
            String rawTarget = parts[1];
            String reqPath = rawTarget;
            String reqQuery = "";
            int qIdx = rawTarget.indexOf('?');
            if (qIdx >= 0) {
                reqPath = rawTarget.substring(0, qIdx);
                reqQuery = rawTarget.substring(qIdx + 1);
            }

            Map<String, String> headers = new HashMap<String, String>();
            int totalHeaderChars = 0;
            for (; ; ) {
                String line = ConfigTransferServer.line(in, 4096);
                totalHeaderChars += line.length();
                if (totalHeaderChars > 16384) throw new IOException("Header limit");
                if (line.isEmpty()) break;
                int colon = line.indexOf(':');
                if (colon > 0) {
                    headers.put(
                            line.substring(0, colon).trim().toLowerCase(Locale.ROOT),
                            line.substring(colon + 1).trim());
                }
            }

            if ("GET".equals(method) && pairPath.equals(reqPath)) {
                String hostHeader = headers.containsKey("host") ? headers.get("host") : "";
                String localAddr = s.getLocalAddress().getHostAddress();
                String expectedHost = localAddr + ":" + httpPort;
                if (!hostHeader.equals(expectedHost)) {
                    sendText(out, 403, "text/plain", "请使用电视屏幕上显示的配对二维码地址");
                    return;
                }
                sendText(out, 200, "text/html", renderPairingPage(localAddr));
                return;
            }

            if ("GET".equals(method) && "/marco-gateway/v1/proxy".equals(reqPath)) {
                handleLocalProxyRelay(s, out, headers, reqQuery);
                return;
            }

            if (!isAuthorized(headers.get("authorization"), token)) {
                sendJson(out, 401, new JSONObject().put("ok", false).put("error", "Unauthorized"));
                return;
            }

            if ("GET".equals(method) && "/marco-gateway/v1/health".equals(reqPath)) {
                noteActivity(peer, "health");
                JSONObject body =
                        new JSONObject()
                                .put("ok", true)
                                .put("protocol", PROTOCOL_ID)
                                .put("deviceName", deviceName)
                                .put("engine", engineName)
                                .put("supportsNativeSo", supportsNativeSo)
                                .put("routeCount", dispatcher.routeCount());
                sendJson(out, 200, body);
                return;
            }

            if ("POST".equals(method) && "/marco-gateway/v1/invoke".equals(reqPath)) {
                int contentLength;
                try {
                    contentLength =
                            Integer.parseInt(
                                    headers.containsKey("content-length")
                                            ? headers.get("content-length")
                                            : "-1");
                } catch (NumberFormatException e) {
                    contentLength = -1;
                }
                if (contentLength <= 0 || contentLength > MAX_BODY_BYTES) {
                    sendJson(
                            out,
                            400,
                            new JSONObject()
                                    .put("ok", false)
                                    .put("error", "Invalid request body size"));
                    return;
                }
                byte[] bodyBytes = readFully(in, contentLength);
                JSONObject req;
                try {
                    req = new JSONObject(new String(bodyBytes, "UTF-8"));
                } catch (Exception badJson) {
                    sendJson(
                            out,
                            400,
                            new JSONObject()
                                    .put("ok", false)
                                    .put("error", "Malformed JSON payload"));
                    return;
                }
                String action = Cms.optSafeString(req, "action").trim();
                JSONObject siteObj = req.optJSONObject("site");
                JSONObject paramsObj = req.optJSONObject("params");
                if (siteObj == null) siteObj = new JSONObject();
                if (paramsObj == null) paramsObj = new JSONObject();
                if (action.isEmpty()) {
                    sendJson(
                            out,
                            400,
                            new JSONObject().put("ok", false).put("error", "Missing action"));
                    return;
                }
                try {
                    String rawResult = dispatcher.dispatch(action, siteObj, paramsObj);
                    if ("play".equals(action) && rawResult != null && !rawResult.isEmpty()) {
                        String localIp = s.getLocalAddress().getHostAddress();
                        rawResult = rewriteLoopbackProxyUrls(rawResult, localIp, httpPort, token);
                    }
                    servedRequests.incrementAndGet();
                    noteActivity(peer, action);
                    JSONObject resp = new JSONObject().put("ok", true);
                    Object parsedData = parseJsonOrKeepString(rawResult);
                    resp.put("data", parsedData);
                    sendJson(out, 200, resp);
                } catch (Exception execErr) {
                    String msg = execErr.getMessage();
                    if (msg == null || msg.trim().isEmpty()) {
                        msg = execErr.getClass().getSimpleName();
                    }
                    sendJson(out, 502, new JSONObject().put("ok", false).put("error", msg));
                }
                return;
            }

            sendJson(out, 404, new JSONObject().put("ok", false).put("error", "Not found"));
        } catch (Exception ignored) {
        }
    }

    private void handleLocalProxyRelay(
            Socket client, OutputStream out, Map<String, String> headers, String reqQuery)
            throws Exception {
        boolean authed = isAuthorized(headers.get("authorization"), token);
        StringBuilder forwardedQuery = new StringBuilder();
        if (reqQuery != null && !reqQuery.isEmpty()) {
            String[] pairs = reqQuery.split("&");
            for (String p : pairs) {
                int eq = p.indexOf('=');
                String k = eq >= 0 ? p.substring(0, eq) : p;
                String v = eq >= 0 ? p.substring(eq + 1) : "";
                if ("token".equals(k)) {
                    String decoded = java.net.URLDecoder.decode(v, "UTF-8");
                    if (constantTimeEquals(decoded, token)) {
                        authed = true;
                    }
                    continue;
                }
                if (forwardedQuery.length() > 0) forwardedQuery.append('&');
                forwardedQuery.append(p);
            }
        }
        if (!authed) {
            sendJson(out, 401, new JSONObject().put("ok", false).put("error", "Unauthorized"));
            return;
        }
        int localProxyPort = ProxyAddress.port;
        if (localProxyPort <= 0) {
            sendJson(
                    out,
                    503,
                    new JSONObject().put("ok", false).put("error", "Local proxy unavailable"));
            return;
        }
        String targetUrl =
                "http://127.0.0.1:"
                        + localProxyPort
                        + "/proxy"
                        + (forwardedQuery.length() > 0 ? "?" + forwardedQuery : "");
        HttpURLConnection conn = (HttpURLConnection) new URL(targetUrl).openConnection();
        conn.setConnectTimeout(10000);
        conn.setReadTimeout(25000);
        conn.setInstanceFollowRedirects(true);
        if (headers.containsKey("range")) {
            conn.setRequestProperty("Range", headers.get("range"));
        }
        try {
            int status = conn.getResponseCode();
            String ctype = conn.getContentType();
            if (ctype == null || ctype.isEmpty()) ctype = "application/octet-stream";
            InputStream bodyStream = status >= 400 ? conn.getErrorStream() : conn.getInputStream();
            StringBuilder head = new StringBuilder();
            head.append("HTTP/1.1 ")
                    .append(status)
                    .append(' ')
                    .append(status == 206 ? "Partial Content" : (status == 200 ? "OK" : "Reply"))
                    .append("\r\nContent-Type: ")
                    .append(ctype)
                    .append("\r\nConnection: close\r\n");
            long len = conn.getContentLengthLong();
            if (len >= 0) head.append("Content-Length: ").append(len).append("\r\n");
            String cr = conn.getHeaderField("Content-Range");
            if (cr != null && !cr.isEmpty()) {
                head.append("Content-Range: ").append(cr).append("\r\n");
            }
            String ar = conn.getHeaderField("Accept-Ranges");
            if (ar != null && !ar.isEmpty()) {
                head.append("Accept-Ranges: ").append(ar).append("\r\n");
            }
            head.append("\r\n");
            out.write(head.toString().getBytes("ISO-8859-1"));
            if (bodyStream != null) {
                byte[] buf = new byte[16384];
                int n;
                while ((n = bodyStream.read(buf)) != -1) {
                    out.write(buf, 0, n);
                }
                bodyStream.close();
            }
            out.flush();
        } finally {
            conn.disconnect();
        }
    }

    private String renderPairingPage(String localAddr) {
        String escName = SearchInputServer.escapeHtml(deviceName);
        String escUrl = SearchInputServer.escapeHtml(baseUrl(localAddr));
        String escToken = SearchInputServer.escapeHtml(token);
        return "<!doctype html><html lang=zh-CN><meta charset=utf-8>"
                + "<meta name=viewport content='width=device-width,initial-scale=1'>"
                + "<title>局域网蜘蛛网关配对 · Marco Movie</title><style>"
                + "body{margin:0;background:#0e1118;color:#f5f7fb;font:16px -apple-system,BlinkMacSystemFont,sans-serif;padding:22px}"
                + "main{max-width:520px;margin:4vh auto;background:#171c26;border:1px solid rgba(255,255,255,.12);border-radius:20px;padding:22px}"
                + "h1{margin:0 0 6px;font-size:21px}p.sub{margin:0 0 16px;font-size:13.5px;color:#9aa8bc;line-height:1.55}"
                + ".box{background:#0f131b;border:1px solid rgba(255,255,255,.12);border-radius:14px;padding:12px 14px;margin:10px 0}"
                + ".lbl{font-size:12px;color:#8ea0b8;margin-bottom:4px}.val{font:600 15px ui-monospace,monospace;word-break:break-all;color:#66d4cf}"
                + "button{width:100%;border:0;border-radius:12px;padding:12px;margin-top:8px;font:600 14.5px inherit;background:#f5f7fb;color:#0e1118;cursor:pointer}"
                + "#tip{margin-top:12px;min-height:20px;font-size:13px;color:#5eead4}"
                + "</style><main><h1>"
                + escName
                + "</h1><p class=sub>在 iOS / macOS / Windows 端 Marco Movie 打开「设置 → 蜘蛛扩展与网关」，点击「局域网发现 Android 端」或复制下方地址与令牌填入即可。</p>"
                + "<div class=box><div class=lbl>网关地址</div><div class=val id=u>"
                + escUrl
                + "</div><button onclick=\"cp('u','已复制网关地址')\">复制网关地址</button></div>"
                + "<div class=box><div class=lbl>访问令牌（Bearer Token）</div><div class=val id=t>"
                + escToken
                + "</div><button onclick=\"cp('t','已复制访问令牌')\">复制访问令牌</button></div>"
                + "<div id=tip></div></main><script>"
                + "function cp(id,ok){var txt=document.getElementById(id).textContent;"
                + "if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(txt).then(function(){document.getElementById('tip').textContent='✓ '+ok;});}"
                + "else{var a=document.createElement('textarea');a.value=txt;document.body.appendChild(a);a.select();document.execCommand('copy');document.body.removeChild(a);document.getElementById('tip').textContent='✓ '+ok;}}"
                + "</script></html>";
    }

    private void noteActivity(InetAddress peer, String action) {
        String host = peer != null ? peer.getHostAddress() : "";
        String time =
                new java.text.SimpleDateFormat("HH:mm:ss", Locale.getDefault())
                        .format(new java.util.Date());
        lastActivity = "最近服务：" + host + " · " + action + " · " + time;
        if (onStatusChanged != null) {
            try {
                onStatusChanged.run();
            } catch (Throwable ignored) {
            }
        }
    }

    private static Object parseJsonOrKeepString(String raw) {
        if (raw == null) return new JSONObject();
        String trimmed = raw.trim();
        if (trimmed.isEmpty()) return new JSONObject();
        if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
            try {
                Object tok = new JSONTokener(trimmed).nextValue();
                if (tok instanceof JSONObject || tok instanceof JSONArray) {
                    return tok;
                }
            } catch (Exception ignored) {
            }
        }
        return trimmed;
    }

    private static byte[] readFully(InputStream in, int length) throws IOException {
        byte[] buf = new byte[length];
        int off = 0;
        while (off < length) {
            int n = in.read(buf, off, length - off);
            if (n < 0) throw new EOFException();
            off += n;
        }
        return buf;
    }

    private static void sendJson(OutputStream out, int code, JSONObject obj) throws IOException {
        sendText(out, code, "application/json", obj.toString());
    }

    private static void sendText(OutputStream out, int code, String contentType, String body)
            throws IOException {
        byte[] bytes = body.getBytes("UTF-8");
        String reason =
                code == 200
                        ? "OK"
                        : code == 400
                                ? "Bad Request"
                                : code == 401
                                        ? "Unauthorized"
                                        : code == 403
                                                ? "Forbidden"
                                                : code == 404
                                                        ? "Not Found"
                                                        : code == 502 ? "Bad Gateway" : "Error";
        ByteArrayOutputStream header = new ByteArrayOutputStream();
        header.write(
                ("HTTP/1.1 "
                                + code
                                + " "
                                + reason
                                + "\r\nContent-Type: "
                                + contentType
                                + "; charset=utf-8\r\nContent-Length: "
                                + bytes.length
                                + "\r\nX-Marco-Gateway-Protocol: "
                                + PROTOCOL_ID
                                + "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n")
                        .getBytes("ISO-8859-1"));
        out.write(header.toByteArray());
        out.write(bytes);
        out.flush();
    }

    private static void closeQuietly(Closeable c) {
        if (c == null) return;
        try {
            c.close();
        } catch (Throwable ignored) {
        }
    }

    private static void releaseMulticastLock(WifiManager.MulticastLock lock) {
        if (lock == null) return;
        try {
            if (lock.isHeld()) lock.release();
        } catch (Throwable ignored) {
        }
    }

    @Override
    public void close() {
        closed = true;
        closeQuietly(httpSocket);
        if (udpSocket != null) {
            try {
                udpSocket.close();
            } catch (Throwable ignored) {
            }
        }
        releaseMulticastLock(multicastLock);
        httpPool.shutdownNow();
        try {
            dispatcher.close();
        } catch (Throwable ignored) {
        }
    }

    /** Android runtime dispatcher bridging gateway calls into local Csp/Guard/Js/Drpy engines. */
    private static final class AndroidSpiderDispatcher implements ActionDispatcher {
        private final MainActivity a;
        private final Map<String, SourceEngine> remoteCache =
                new LinkedHashMap<String, SourceEngine>(16, 0.75f, true) {
                    @Override
                    protected boolean removeEldestEntry(Map.Entry<String, SourceEngine> eldest) {
                        if (size() > MAX_CACHED_REMOTE_ENGINES) {
                            final SourceEngine evict = eldest.getValue();
                            if (evict != null) {
                                new Thread(
                                                () -> {
                                                    try {
                                                        evict.close();
                                                    } catch (Throwable ignored) {
                                                    }
                                                },
                                                "gw-evict-engine")
                                        .start();
                            }
                            return true;
                        }
                        return false;
                    }
                };

        AndroidSpiderDispatcher(MainActivity host) {
            this.a = host;
        }

        @Override
        public int routeCount() {
            Cms.Config cfg = a.config;
            return cfg != null && cfg.sites != null ? cfg.sites.size() : 0;
        }

        @Override
        public String dispatch(String action, JSONObject siteObj, JSONObject paramsObj)
                throws Exception {
            SourceEngine engine = resolveEngine(siteObj);
            if ("home".equals(action)) {
                return engine.home();
            }
            if ("homeVod".equals(action)) {
                return engine.homeVideos();
            }
            if ("category".equals(action)) {
                String tid = Cms.optSafeString(paramsObj, "tid");
                int pg = Math.max(1, paramsObj.optInt("pg", 1));
                Map<String, String> filterMap = parseFilterMap(paramsObj.optJSONObject("filter"));
                return engine.category(tid, pg, filterMap);
            }
            if ("search".equals(action)) {
                String wd = Cms.optSafeString(paramsObj, "wd");
                int pg = Math.max(1, paramsObj.optInt("pg", 1));
                return engine.search(wd, pg);
            }
            if ("detail".equals(action)) {
                String id = Cms.optSafeString(paramsObj, "id");
                return engine.detail(id);
            }
            if ("play".equals(action)) {
                String flag = Cms.optSafeString(paramsObj, "flag");
                String id = Cms.optSafeString(paramsObj, "id");
                return engine.player(flag, id);
            }
            throw new IOException("Unsupported gateway action: " + action);
        }

        private SourceEngine resolveEngine(JSONObject siteObj) throws Exception {
            String api = Cms.optSafeString(siteObj, "api").trim();
            String key = Cms.optSafeString(siteObj, "key").trim();
            String name = Cms.optSafeString(siteObj, "name").trim();
            String jar = Cms.optSafeString(siteObj, "jar").trim();
            String spider = Cms.optSafeString(siteObj, "spider").trim();
            String playUrl = Cms.optSafeString(siteObj, "playUrl").trim();
            Object extObj = siteObj.isNull("ext") ? null : siteObj.opt("ext");
            String extStr = extObj == null ? "" : String.valueOf(extObj);
            int type = siteObj.optInt("type", 3);

            Cms.Config activeCfg = a.config;
            Cms.Site matchedLocal = findMatchingLocalSite(activeCfg, key, api, jar, extStr);
            if (matchedLocal != null) {
                return SourceController.engine(a, matchedLocal);
            }

            if (api.isEmpty()) {
                throw new IOException("请求缺少站点 api 标识");
            }
            Cms.Site remoteSite = new Cms.Site();
            remoteSite.key = key.isEmpty() ? "gw_" + Math.abs(api.hashCode()) : key;
            remoteSite.originalKey = remoteSite.key;
            remoteSite.name = name.isEmpty() ? api : name;
            remoteSite.api = api;
            remoteSite.originalApi = api;
            remoteSite.type = type;
            remoteSite.playUrl = playUrl;
            remoteSite.jar = jar;
            remoteSite.ext = extObj;

            Cms.Config remoteCfg = new Cms.Config();
            String effectiveSpider =
                    !spider.isEmpty()
                            ? spider
                            : (!jar.isEmpty()
                                    ? jar
                                    : (activeCfg != null && activeCfg.spider != null
                                            ? activeCfg.spider
                                            : ""));
            remoteCfg.spider = effectiveSpider;
            if (activeCfg != null && activeCfg.origin != null) {
                remoteCfg.origin = activeCfg.origin;
            }

            String cacheKey = api + "|" + jar + "|" + effectiveSpider + "|" + extStr;
            synchronized (remoteCache) {
                SourceEngine cached = remoteCache.get(cacheKey);
                if (cached != null
                        && !cached.isClosed()
                        && !(cached instanceof QueuedSourceEngine
                                && ((QueuedSourceEngine) cached).isWedged())) {
                    return cached;
                }
            }

            SourceEngine raw;
            if (HttpT4Engine.eligible(remoteSite)) {
                raw = new HttpT4Engine(remoteSite);
            } else if (remoteSite.supported()) {
                raw = new JsonCmsEngine(remoteSite);
            } else if (DrpyEngine.eligible(remoteSite)) {
                raw = new DrpyEngine(a, remoteCfg, remoteSite);
            } else if (GuardEngine.eligible(remoteSite)) {
                raw =
                        GuardEngine.open(
                                a,
                                remoteCfg,
                                remoteSite,
                                () -> {
                                    SourceController.ensureProxy(a, remoteCfg);
                                    return new CspEngine(a.getApplication(), remoteCfg, remoteSite);
                                });
            } else if (!JsEngine.eligible(remoteSite) && CspEngine.eligible(remoteSite)) {
                if (effectiveSpider.isEmpty() && remoteSite.jar.isEmpty()) {
                    throw new IOException("该 csp 线路缺少 jar/spider 地址，且 Android 端尚未导入对应订阅");
                }
                SourceController.ensureProxy(a, remoteCfg);
                raw = new CspEngine(a.getApplication(), remoteCfg, remoteSite);
            } else if (JsEngine.eligible(remoteSite)) {
                SourceController.ensureProxy(a, remoteCfg);
                try {
                    raw = new JsEngine(a.getApplication(), remoteCfg, remoteSite);
                    ((JsEngine) raw).activate();
                } catch (JsEngine.DrpyRuleDetected rule) {
                    raw = new DrpyEngine(a, remoteCfg, remoteSite, rule.source);
                }
            } else {
                throw new IOException("Android 蜘蛛网关暂不支持该站点类型：" + api);
            }
            SourceEngine wrapped = new QueuedSourceEngine(raw);
            synchronized (remoteCache) {
                SourceEngine prev = remoteCache.put(cacheKey, wrapped);
                if (prev != null && prev != wrapped) {
                    try {
                        prev.close();
                    } catch (Throwable ignored) {
                    }
                }
            }
            return wrapped;
        }

        private static Cms.Site findMatchingLocalSite(
                Cms.Config cfg, String key, String api, String jar, String extStr) {
            if (cfg == null || cfg.sites == null || api.isEmpty()) return null;
            Cms.Site fallbackApiMatch = null;
            for (Cms.Site s : cfg.sites) {
                if (s == null || s.api == null || !api.equalsIgnoreCase(s.api.trim())) continue;
                String sExt = s.ext == null ? "" : String.valueOf(s.ext);
                boolean sameExt = extStr.isEmpty() || extStr.equals(sExt);
                boolean sameJar =
                        jar.isEmpty()
                                || jar.equals(s.jar)
                                || (s.jar != null && s.jar.isEmpty() && jar.equals(cfg.spider));
                if (sameExt && sameJar) {
                    if (!key.isEmpty() && (key.equals(s.key) || key.equals(s.originalKey))) {
                        return s;
                    }
                    if (fallbackApiMatch == null) fallbackApiMatch = s;
                }
            }
            return fallbackApiMatch;
        }

        private static Map<String, String> parseFilterMap(JSONObject obj) {
            if (obj == null || obj.length() == 0) return Collections.emptyMap();
            Map<String, String> out = new LinkedHashMap<String, String>();
            Iterator<String> keys = obj.keys();
            while (keys.hasNext()) {
                String k = keys.next();
                String v = Cms.optSafeString(obj, k).trim();
                if (!v.isEmpty()) out.put(k, v);
            }
            return out;
        }

        @Override
        public void close() {
            List<SourceEngine> toClose;
            synchronized (remoteCache) {
                toClose = new ArrayList<SourceEngine>(remoteCache.values());
                remoteCache.clear();
            }
            if (!toClose.isEmpty()) {
                new Thread(
                                () -> {
                                    for (SourceEngine e : toClose) {
                                        try {
                                            e.close();
                                        } catch (Throwable ignored) {
                                        }
                                    }
                                },
                                "gw-close-engines")
                        .start();
            }
        }
    }
}
