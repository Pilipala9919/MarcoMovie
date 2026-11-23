package com.pilipala.marcomovie;

import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URLDecoder;
import java.security.SecureRandom;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.SynchronousQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Short-lived, token-scoped LAN HTTP server for TV search mobile QR input. Runs only while the TV
 * search page or QR dialog is open; enforces LAN peer check, Host header check, and Origin /
 * Sec-Fetch-Site CSRF guards.
 */
final class SearchInputServer implements Closeable {
    static final int MAX_BODY_BYTES = 8192;
    static final int MAX_KEYWORD_CODEPOINTS = 80;

    interface Listener {
        void onKeyword(String keyword, boolean submitNow) throws Exception;

        default List<String> recentKeywords() {
            return Collections.emptyList();
        }

        default String currentKeyword() {
            return "";
        }
    }

    final ServerSocket socket;
    final String path;
    final long expires;
    final Listener listener;
    volatile boolean closed;
    final ThreadPoolExecutor requests =
            new ThreadPoolExecutor(
                    0,
                    3,
                    10,
                    TimeUnit.SECONDS,
                    new SynchronousQueue<>(),
                    r -> {
                        Thread t = new Thread(r, "movie-search-qr");
                        t.setDaemon(true);
                        return t;
                    });

    SearchInputServer(Listener handler) throws IOException {
        this(handler, TimeUnit.MINUTES.toMillis(10), new InetSocketAddress("0.0.0.0", 0));
    }

    SearchInputServer(Listener handler, long ttlMs, InetSocketAddress bind) throws IOException {
        if (handler == null) throw new IllegalArgumentException("listener required");
        listener = handler;
        expires = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(ttlMs);
        byte[] bytes = new byte[16];
        new SecureRandom().nextBytes(bytes);
        StringBuilder token = new StringBuilder(32);
        for (byte b : bytes) token.append(String.format(Locale.ROOT, "%02x", b & 255));
        path = "/search/" + token;
        socket = new ServerSocket();
        socket.bind(bind);
        Thread accept =
                new Thread(
                        () -> {
                            while (!closed) {
                                try {
                                    Socket client = socket.accept();
                                    try {
                                        requests.execute(() -> serve(client));
                                    } catch (RejectedExecutionException full) {
                                        client.close();
                                    }
                                } catch (IOException error) {
                                    if (!closed) close();
                                }
                            }
                        },
                        "movie-search-qr-listener");
        accept.setDaemon(true);
        accept.start();
    }

    String address(String host) {
        return "http://" + host + ":" + socket.getLocalPort() + path;
    }

    int port() {
        return socket.getLocalPort();
    }

    boolean expired() {
        return closed || System.nanoTime() >= expires;
    }

    static String sanitizeKeyword(String raw) {
        if (raw == null) return "";
        StringBuilder sb = new StringBuilder(raw.length());
        for (int i = 0; i < raw.length(); i++) {
            char c = raw.charAt(i);
            if (c == '\r' || c == '\n' || c == '\t') {
                sb.append(' ');
            } else if (c >= 0x20 && c != 0x7f) {
                sb.append(c);
            }
        }
        String trimmed = sb.toString().trim();
        if (trimmed.isEmpty()) return "";
        int count = trimmed.codePointCount(0, trimmed.length());
        if (count > MAX_KEYWORD_CODEPOINTS) {
            int end = trimmed.offsetByCodePoints(0, MAX_KEYWORD_CODEPOINTS);
            return trimmed.substring(0, end).trim();
        }
        return trimmed;
    }

    void serve(Socket client) {
        try (Socket s = client) {
            s.setSoTimeout(15000);
            InputStream in = s.getInputStream();
            OutputStream out = s.getOutputStream();
            InetAddress peer = s.getInetAddress();
            if (!ConfigTransferServer.isAllowedLanPeer(peer)) {
                reply(out, 403, "text/plain", "仅允许同一局域网设备访问");
                return;
            }
            String requestLine = ConfigTransferServer.line(in, 4096);
            String[] first = requestLine.split(" ");
            if (first.length != 3) return;
            Map<String, String> headers = new HashMap<>();
            int total = 0;
            for (; ; ) {
                String row = ConfigTransferServer.line(in, 4096);
                total += row.length();
                if (total > 16384) throw new IOException("Header limit");
                if (row.isEmpty()) break;
                int colon = row.indexOf(':');
                if (colon > 0) {
                    headers.put(
                            row.substring(0, colon).trim().toLowerCase(Locale.ROOT),
                            row.substring(colon + 1).trim());
                }
            }
            String reqPath = first[1];
            int qIdx = reqPath.indexOf('?');
            if (qIdx >= 0) reqPath = reqPath.substring(0, qIdx);
            boolean isMain = reqPath.equals(path);
            boolean isPush = reqPath.equals(path + "/push");
            boolean isState = reqPath.equals(path + "/state");
            if (!isMain && !isPush && !isState) {
                reply(out, 404, "text/plain", "页面不存在");
                return;
            }
            if (expired()) {
                reply(out, 410, "text/plain", "二维码已过期，请在电视搜索页重新扫码");
                return;
            }
            String host = headers.containsKey("host") ? headers.get("host") : "";
            String expected = s.getLocalAddress().getHostAddress() + ":" + socket.getLocalPort();
            if (!host.equals(expected)) {
                reply(out, 403, "text/plain", "请使用电视屏幕上显示的扫码地址");
                return;
            }
            String method = first[0];
            if ("GET".equals(method)) {
                if (isState) {
                    JSONObject state = new JSONObject();
                    state.put("ok", true);
                    state.put("current", safeString(listener.currentKeyword()));
                    JSONArray history = new JSONArray();
                    List<String> recent = listener.recentKeywords();
                    if (recent != null) {
                        for (int i = 0; i < Math.min(8, recent.size()); i++) {
                            String item = sanitizeKeyword(recent.get(i));
                            if (!item.isEmpty()) history.put(item);
                        }
                    }
                    state.put("history", history);
                    reply(out, 200, "application/json", state.toString());
                    return;
                }
                if (isMain) {
                    reply(
                            out,
                            200,
                            "text/html",
                            renderPage("", safeString(listener.currentKeyword())));
                    return;
                }
                reply(out, 405, "text/plain", "请求方式不支持");
                return;
            }
            if (!"POST".equals(method)) {
                reply(out, 405, "text/plain", "请求方式不支持");
                return;
            }
            String secFetchSite = headers.get("sec-fetch-site");
            if (secFetchSite != null
                    && !secFetchSite.equalsIgnoreCase("same-origin")
                    && !secFetchSite.equalsIgnoreCase("none")) {
                reply(out, 403, "text/plain", "跨站请求已拦截");
                return;
            }
            String origin = headers.get("origin");
            if (origin != null && !origin.equals("http://" + host)) {
                reply(out, 403, "text/plain", "来源校验未通过");
                return;
            }
            if (headers.containsKey("transfer-encoding")) {
                reply(out, 415, "text/plain", "不支持分块编码");
                return;
            }
            String contentType =
                    headers.containsKey("content-type")
                            ? headers.get("content-type").toLowerCase(Locale.ROOT)
                            : "";
            boolean isJson = contentType.startsWith("application/json");
            boolean isForm = contentType.startsWith("application/x-www-form-urlencoded");
            if (!isJson && !isForm) {
                reply(out, 415, "text/plain", "请通过扫码页面提交关键词");
                return;
            }
            int length;
            try {
                length =
                        Integer.parseInt(
                                headers.containsKey("content-length")
                                        ? headers.get("content-length")
                                        : "-1");
            } catch (NumberFormatException e) {
                length = -1;
            }
            if (length < 0 || length > MAX_BODY_BYTES) {
                reply(out, 413, "text/plain", "输入内容过长");
                return;
            }
            byte[] body = new byte[length];
            for (int n = 0; n < length; ) {
                int got = in.read(body, n, length - n);
                if (got < 0) throw new EOFException();
                n += got;
            }
            String rawText = new String(body, "UTF-8");
            String keyword = "";
            boolean submitNow = true;
            boolean clearAction = false;
            if (isJson) {
                JSONObject payload = new JSONObject(rawText);
                String mode = payload.optString("mode", "search");
                clearAction = "clear".equalsIgnoreCase(mode);
                keyword = clearAction ? "" : sanitizeKeyword(payload.optString("keyword", ""));
                submitNow =
                        !clearAction
                                && payload.optBoolean("submit", !"sync".equalsIgnoreCase(mode));
            } else {
                String mode = "search";
                for (String pair : rawText.split("&")) {
                    if (pair.isEmpty()) continue;
                    String[] kv = pair.split("=", 2);
                    String k = URLDecoder.decode(kv[0], "UTF-8");
                    String v = kv.length == 2 ? URLDecoder.decode(kv[1], "UTF-8") : "";
                    if ("keyword".equals(k)) keyword = sanitizeKeyword(v);
                    else if ("mode".equals(k)) mode = v.trim();
                }
                clearAction = "clear".equalsIgnoreCase(mode);
                if (clearAction) keyword = "";
                submitNow = !clearAction && !"sync".equalsIgnoreCase(mode);
            }
            if (!clearAction && keyword.isEmpty() && submitNow) {
                if (isJson || isPush) {
                    JSONObject err = new JSONObject();
                    err.put("ok", false);
                    err.put("message", "请输入片名、演员或拼音关键词");
                    reply(out, 400, "application/json", err.toString());
                } else {
                    reply(out, 400, "text/html", renderPage("请输入片名、演员或拼音关键词", ""));
                }
                return;
            }
            listener.onKeyword(keyword, submitNow);
            String notice =
                    clearAction
                            ? "已清空电视搜索框"
                            : (submitNow
                                    ? "已在电视发起搜索：「" + keyword + "」"
                                    : "已同步到电视搜索框：「" + keyword + "」");
            if (isJson || isPush) {
                JSONObject res = new JSONObject();
                res.put("ok", true);
                res.put("keyword", keyword);
                res.put("submitted", submitNow);
                res.put("message", notice);
                reply(out, 200, "application/json", res.toString());
            } else {
                reply(out, 200, "text/html", renderPage(notice, keyword));
            }
        } catch (Exception ignored) {
        }
    }

    private String renderPage(String bannerMessage, String initialValue) {
        StringBuilder chips = new StringBuilder();
        List<String> recent = listener.recentKeywords();
        if (recent != null && !recent.isEmpty()) {
            chips.append("<div class='sec'><div class='lbl'>电视最近搜索</div><div class='chips'>");
            int shown = 0;
            for (String item : recent) {
                String clean = sanitizeKeyword(item);
                if (clean.isEmpty()) continue;
                String esc = escapeHtml(clean);
                chips.append("<button type='button' class='chip' data-kw=\"")
                        .append(esc)
                        .append("\">")
                        .append(esc)
                        .append("</button>");
                if (++shown >= 8) break;
            }
            chips.append("</div></div>");
        }
        String escPath = escapeHtml(path);
        String escVal = escapeHtml(sanitizeKeyword(initialValue));
        String escMsg = escapeHtml(bannerMessage == null ? "" : bannerMessage);
        return "<!doctype html><html lang='zh-CN'><head><meta charset='utf-8'>"
                + "<meta name='viewport' content='width=device-width,initial-scale=1,maximum-scale=1'>"
                + "<title>Marco Movie 电视搜索输入</title>"
                + "<style>"
                + "*{box-sizing:border-box}"
                + "body{margin:0;background:#0e0f14;color:#f5f5f7;font:16px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;padding:20px}"
                + "main{max-width:480px;margin:2vh auto;background:#191b23;border:1px solid rgba(255,255,255,.09);border-radius:20px;padding:22px;box-shadow:0 18px 48px rgba(0,0,0,.45)}"
                + ".eyebrow{font-size:12px;letter-spacing:.12em;color:#7cb8ff;font-weight:600}"
                + "h1{margin:6px 0 8px;font-size:22px}"
                + "p.sub{margin:0 0 16px;color:#9ea2b0;font-size:14px}"
                + "input[type=text]{width:100%;padding:14px 16px;font-size:17px;color:#fff;background:#252834;border:1px solid rgba(255,255,255,.14);border-radius:14px;outline:none}"
                + "input[type=text]:focus{border-color:#5ac8fa;background:#2a2e3d}"
                + ".actions{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:14px}"
                + "button{padding:13px 14px;font-size:15px;font-weight:600;border-radius:13px;border:0;cursor:pointer}"
                + ".primary{grid-column:1/-1;background:#f5f5f7;color:#101013;font-size:16px}"
                + ".secondary{background:#282c3a;color:#e7e9f0;border:1px solid rgba(255,255,255,.1)}"
                + ".msg{margin-top:14px;padding:11px 14px;border-radius:12px;background:rgba(90,200,250,.14);color:#b7e6ff;font-size:14px;display:"
                + (escMsg.isEmpty() ? "none" : "block")
                + "}"
                + ".sec{margin-top:18px;padding-top:14px;border-top:1px solid rgba(255,255,255,.08)}"
                + ".lbl{font-size:12.5px;color:#9ea2b0;margin-bottom:8px}"
                + ".chips{display:flex;flex-wrap:wrap;gap:8px}"
                + ".chip{padding:7px 13px;font-size:13.5px;font-weight:500;border-radius:999px;background:#262936;color:#dfe2ec;border:1px solid rgba(255,255,255,.09)}"
                + "</style></head><body><main>"
                + "<div class='eyebrow'>MARCO MOVIE · TV SEARCH</div>"
                + "<h1>手机输入 · 电视搜片</h1>"
                + "<p class='sub'>输入中文片名、演员或拼音，点击搜索即可同步到电视全站搜索。</p>"
                + "<form id='f' method='post' action='"
                + escPath
                + "'>"
                + "<input id='kw' name='keyword' type='text' maxlength='80' autocomplete='off' enterkeyhint='search' placeholder='输入片名，例如：三体 / 流浪地球…' value=\""
                + escVal
                + "\" autofocus>"
                + "<input id='mode' name='mode' type='hidden' value='search'>"
                + "<div class='actions'>"
                + "<button type='submit' class='primary' data-mode='search'>立即在电视上搜索</button>"
                + "<button type='submit' class='secondary' data-mode='sync'>仅同步文字</button>"
                + "<button type='submit' class='secondary' data-mode='clear'>清空输入框</button>"
                + "</div></form>"
                + "<div id='msg' class='msg'>"
                + escMsg
                + "</div>"
                + chips
                + "</main><script>"
                + "(function(){"
                + "var f=document.getElementById('f'),kw=document.getElementById('kw'),md=document.getElementById('mode'),msg=document.getElementById('msg');"
                + "function show(t,err){msg.style.display='block';msg.style.background=err?'rgba(255,99,99,.16)':'rgba(90,200,250,.14)';msg.style.color=err?'#ffb8b8':'#b7e6ff';msg.textContent=t;}"
                + "function send(mode){"
                + "md.value=mode;"
                + "var val=mode==='clear'?'':kw.value;"
                + "if(mode==='clear')kw.value='';"
                + "fetch('"
                + escPath
                + "/push',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({keyword:val,mode:mode,submit:mode==='search'})})"
                + ".then(function(r){return r.json().then(function(j){return{status:r.status,body:j};});})"
                + ".then(function(x){show(x.body.message||(x.body.ok?'已发送':'发送失败'),!x.body.ok);})"
                + ".catch(function(){f.submit();});"
                + "}"
                + "var btns=f.querySelectorAll('button[data-mode]');"
                + "for(var i=0;i<btns.length;i++){(function(b){b.addEventListener('click',function(e){if(window.fetch){e.preventDefault();send(b.getAttribute('data-mode'));}});})(btns[i]);}"
                + "f.addEventListener('submit',function(e){if(window.fetch){e.preventDefault();send(md.value||'search');}});"
                + "var chips=document.querySelectorAll('.chip');"
                + "for(var j=0;j<chips.length;j++){(function(c){c.addEventListener('click',function(){kw.value=c.getAttribute('data-kw')||'';send('search');});})(chips[j]);}"
                + "})();"
                + "</script></body></html>";
    }

    private static String safeString(String s) {
        return s == null ? "" : s;
    }

    static String escapeHtml(String s) {
        if (s == null || s.isEmpty()) return "";
        StringBuilder out = new StringBuilder(s.length() + 16);
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '&':
                    out.append("&amp;");
                    break;
                case '<':
                    out.append("&lt;");
                    break;
                case '>':
                    out.append("&gt;");
                    break;
                case '"':
                    out.append("&quot;");
                    break;
                case '\'':
                    out.append("&#39;");
                    break;
                default:
                    out.append(c);
                    break;
            }
        }
        return out.toString();
    }

    private static void reply(OutputStream out, int code, String type, String body)
            throws IOException {
        byte[] bytes = body.getBytes("UTF-8");
        ByteArrayOutputStream head = new ByteArrayOutputStream(256);
        String status =
                code == 200
                        ? "OK"
                        : code == 400
                                ? "Bad Request"
                                : code == 403
                                        ? "Forbidden"
                                        : code == 404
                                                ? "Not Found"
                                                : code == 405
                                                        ? "Method Not Allowed"
                                                        : code == 410
                                                                ? "Gone"
                                                                : code == 413
                                                                        ? "Payload Too Large"
                                                                        : "Unsupported Media Type";
        head.write(
                ("HTTP/1.1 "
                                + code
                                + " "
                                + status
                                + "\r\nContent-Type: "
                                + type
                                + "; charset=utf-8\r\nContent-Length: "
                                + bytes.length
                                + "\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n")
                        .getBytes("US-ASCII"));
        out.write(head.toByteArray());
        out.write(bytes);
        out.flush();
    }

    @Override
    public void close() {
        closed = true;
        try {
            socket.close();
        } catch (IOException ignored) {
        }
        requests.shutdownNow();
    }
}
