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
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.SynchronousQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import org.json.JSONObject;

/**
 * Short-lived, token-scoped LAN HTTP server for TV QR mobile input on any text field (URL,
 * credentials, device name, multiline rule/M3U, or numeric PIN). Enforces LAN peer checks, Host
 * header validation, and Origin / Sec-Fetch-Site CSRF guards.
 */
final class RemoteInputServer implements Closeable {
    static final int MAX_BODY_BYTES = 128 * 1024;
    static final int MAX_FILE_BYTES = LiveCatalog.MAX_BYTES;
    static final int DEFAULT_MAX_CHARS = 8192;

    static final class FieldSpec {
        final String title;
        final String hint;
        final String initialValue;
        final boolean multiline;
        final boolean password;
        final boolean numericPin;
        final int maxChars;
        final String fileAccept;
        final String fileHint;

        FieldSpec(
                String title,
                String hint,
                String initialValue,
                boolean multiline,
                boolean password,
                boolean numericPin,
                int maxChars) {
            this(title, hint, initialValue, multiline, password, numericPin, maxChars, "", "");
        }

        FieldSpec(
                String title,
                String hint,
                String initialValue,
                boolean multiline,
                boolean password,
                boolean numericPin,
                int maxChars,
                String fileAccept,
                String fileHint) {
            this.title = title == null || title.trim().isEmpty() ? "手机扫码输入" : title.trim();
            this.hint = hint == null ? "" : hint.trim();
            this.initialValue = password || initialValue == null ? "" : initialValue;
            this.multiline = multiline && !numericPin && !password;
            this.password = password;
            this.numericPin = numericPin;
            this.maxChars =
                    numericPin
                            ? Math.max(1, Math.min(16, maxChars > 0 ? maxChars : 4))
                            : Math.max(
                                    1,
                                    Math.min(65536, maxChars > 0 ? maxChars : DEFAULT_MAX_CHARS));
            this.fileAccept = fileAccept == null ? "" : fileAccept.trim();
            this.fileHint = fileHint == null ? "" : fileHint.trim();
        }
    }

    interface Listener {
        void onText(String text, boolean clear) throws Exception;
    }

    interface FileListener {
        String onFile(String fileName, byte[] data) throws Exception;
    }

    final ServerSocket socket;
    final String path;
    final long expires;
    final FieldSpec spec;
    final Listener listener;
    final FileListener fileListener;
    volatile boolean closed;
    final ThreadPoolExecutor requests =
            new ThreadPoolExecutor(
                    0,
                    3,
                    10,
                    TimeUnit.SECONDS,
                    new SynchronousQueue<Runnable>(),
                    r -> {
                        Thread t = new Thread(r, "movie-remote-input");
                        t.setDaemon(true);
                        return t;
                    });

    RemoteInputServer(FieldSpec fieldSpec, Listener handler) throws IOException {
        this(
                fieldSpec,
                handler,
                null,
                TimeUnit.MINUTES.toMillis(10),
                new InetSocketAddress("0.0.0.0", 0));
    }

    RemoteInputServer(FieldSpec fieldSpec, Listener handler, FileListener fileHandler)
            throws IOException {
        this(
                fieldSpec,
                handler,
                fileHandler,
                TimeUnit.MINUTES.toMillis(10),
                new InetSocketAddress("0.0.0.0", 0));
    }

    RemoteInputServer(FieldSpec fieldSpec, Listener handler, long ttlMs, InetSocketAddress bind)
            throws IOException {
        this(fieldSpec, handler, null, ttlMs, bind);
    }

    RemoteInputServer(
            FieldSpec fieldSpec,
            Listener handler,
            FileListener fileHandler,
            long ttlMs,
            InetSocketAddress bind)
            throws IOException {
        if (fieldSpec == null || handler == null) {
            throw new IllegalArgumentException("fieldSpec and listener required");
        }
        spec = fieldSpec;
        listener = handler;
        fileListener = fileHandler;
        expires = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(ttlMs);
        byte[] bytes = new byte[16];
        new SecureRandom().nextBytes(bytes);
        StringBuilder token = new StringBuilder(32);
        for (byte b : bytes) token.append(String.format(Locale.ROOT, "%02x", b & 255));
        path = "/input/" + token;
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
                        "movie-remote-input-listener");
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

    static String sanitizeInput(String raw, boolean multiline, boolean numericPin, int maxChars) {
        if (raw == null) return "";
        int limit = Math.max(1, maxChars);
        StringBuilder sb = new StringBuilder(Math.min(raw.length(), limit));
        for (int i = 0; i < raw.length() && sb.length() < limit; i++) {
            char c = raw.charAt(i);
            if (numericPin) {
                if (c >= '0' && c <= '9') sb.append(c);
                continue;
            }
            if (c == '\r') continue;
            if (c == '\n') {
                if (multiline) sb.append('\n');
                else sb.append(' ');
            } else if (c == '\t') {
                sb.append(' ');
            } else if (c >= 0x20 && c != 0x7f) {
                sb.append(c);
            }
        }
        String out = sb.toString();
        return multiline ? out.trim() : out.trim();
    }

    static String sanitizeFileName(String raw) {
        if (raw == null) return "live.txt";
        String s = raw.trim();
        int slash = Math.max(s.lastIndexOf('/'), s.lastIndexOf('\\'));
        if (slash >= 0) s = s.substring(slash + 1);
        StringBuilder sb = new StringBuilder(Math.min(s.length(), 80));
        for (int i = 0; i < s.length() && sb.length() < 80; i++) {
            char c = s.charAt(i);
            if (c >= 0x20 && c != 0x7f && c != '<' && c != '>' && c != ':' && c != '"' && c != '|'
                    && c != '?' && c != '*') {
                sb.append(c);
            }
        }
        String out = sb.toString().trim();
        while (out.contains("..")) out = out.replace("..", ".");
        while (out.startsWith(".")) out = out.substring(1);
        return out.isEmpty() ? "live.txt" : out;
    }

    void serve(Socket client) {
        try (Socket s = client) {
            s.setSoTimeout(30000);
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
            Map<String, String> headers = new HashMap<String, String>();
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
            String rawTarget = first[1];
            String reqPath = rawTarget;
            String queryString = "";
            int qIdx = rawTarget.indexOf('?');
            if (qIdx >= 0) {
                reqPath = rawTarget.substring(0, qIdx);
                queryString = rawTarget.substring(qIdx + 1);
            }
            boolean isMain = reqPath.equals(path);
            boolean isPush = reqPath.equals(path + "/push");
            boolean isUpload = fileListener != null && reqPath.equals(path + "/upload");
            if (!isMain && !isPush && !isUpload) {
                reply(out, 404, "text/plain", "页面不存在");
                return;
            }
            if (expired()) {
                reply(out, 410, "text/plain", "二维码已过期，请在电视上重新打开扫码图标");
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
                if (isMain) {
                    reply(out, 200, "text/html", renderPage(""));
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
            if (isUpload) {
                if (length <= 0) {
                    reply(out, 400, "application/json", "{\"ok\":false,\"error\":\"请选择非空文件后再上传\"}");
                    return;
                }
                if (length > MAX_FILE_BYTES) {
                    reply(
                            out,
                            413,
                            "application/json",
                            "{\"ok\":false,\"error\":\"文件过大，最大支持 8MB\"}");
                    return;
                }
                byte[] fileBytes = readFully(in, length);
                String rawName = parseFormValue(queryString, "name");
                if (rawName.isEmpty() && headers.containsKey("x-file-name")) {
                    try {
                        rawName = URLDecoder.decode(headers.get("x-file-name"), "UTF-8");
                    } catch (Exception ignored) {
                        rawName = headers.get("x-file-name");
                    }
                }
                String fileName = sanitizeFileName(rawName);
                try {
                    String okMsg = fileListener.onFile(fileName, fileBytes);
                    JSONObject resp = new JSONObject();
                    try {
                        resp.put("ok", true);
                        resp.put(
                                "message",
                                okMsg == null || okMsg.trim().isEmpty()
                                        ? "已成功导入 " + fileName
                                        : okMsg);
                    } catch (Exception ignored) {
                    }
                    reply(out, 200, "application/json", resp.toString());
                } catch (Exception err) {
                    String msg =
                            err.getMessage() == null || err.getMessage().trim().isEmpty()
                                    ? "文件解析失败"
                                    : err.getMessage().trim();
                    JSONObject resp = new JSONObject();
                    try {
                        resp.put("ok", false);
                        resp.put("error", msg);
                    } catch (Exception ignored) {
                    }
                    reply(out, 400, "application/json", resp.toString());
                }
                return;
            }
            String contentType =
                    headers.containsKey("content-type")
                            ? headers.get("content-type").toLowerCase(Locale.ROOT)
                            : "";
            boolean isJson = contentType.startsWith("application/json");
            boolean isForm = contentType.startsWith("application/x-www-form-urlencoded");
            if (!isJson && !isForm) {
                reply(out, 415, "text/plain", "请通过扫码页面提交内容");
                return;
            }
            if (length < 0 || length > MAX_BODY_BYTES) {
                reply(out, 413, "text/plain", "输入内容过长");
                return;
            }
            byte[] body = readFully(in, length);
            String bodyText = new String(body, "UTF-8");
            String rawText = "";
            boolean clear = false;
            if (isJson) {
                try {
                    JSONObject obj = new JSONObject(bodyText);
                    rawText = obj.optString("text", "");
                    clear = obj.optBoolean("clear", false);
                } catch (Exception badJson) {
                    reply(out, 400, "application/json", "{\"ok\":false,\"error\":\"请求格式无效\"}");
                    return;
                }
            } else {
                rawText = parseFormValue(bodyText, "text");
                clear = "1".equals(parseFormValue(bodyText, "clear"));
            }
            String sanitized =
                    clear
                            ? ""
                            : sanitizeInput(
                                    rawText, spec.multiline, spec.numericPin, spec.maxChars);
            if (!clear && sanitized.isEmpty()) {
                if (isJson) {
                    reply(out, 400, "application/json", "{\"ok\":false,\"error\":\"请输入内容后再发送\"}");
                } else {
                    reply(out, 400, "text/html", renderPage("请输入内容后再发送"));
                }
                return;
            }
            try {
                listener.onText(sanitized, clear);
                if (isJson) {
                    reply(out, 200, "application/json", "{\"ok\":true}");
                } else {
                    reply(out, 200, "text/html", renderPage(clear ? "已清空电视输入框" : "已成功发送到电视"));
                }
            } catch (Exception err) {
                String msg = err.getMessage() == null ? "发送失败" : err.getMessage();
                if (isJson) {
                    JSONObject resp = new JSONObject();
                    try {
                        resp.put("ok", false);
                        resp.put("error", msg);
                    } catch (Exception ignored) {
                    }
                    reply(out, 500, "application/json", resp.toString());
                } else {
                    reply(out, 500, "text/html", renderPage(msg));
                }
            }
        } catch (Exception ignored) {
        }
    }

    private String renderPage(String notice) {
        String escTitle = SearchInputServer.escapeHtml(spec.title);
        String escHint =
                SearchInputServer.escapeHtml(spec.hint.isEmpty() ? "在此输入或粘贴内容，点击发送到电视" : spec.hint);
        String escVal = SearchInputServer.escapeHtml(spec.initialValue);
        String escNotice = SearchInputServer.escapeHtml(notice == null ? "" : notice);
        String escPath = SearchInputServer.escapeHtml(path);
        String fieldHtml;
        if (spec.multiline) {
            fieldHtml =
                    "<textarea id=txt name=text rows=5 maxlength="
                            + spec.maxChars
                            + " placeholder='"
                            + escHint
                            + "'>"
                            + escVal
                            + "</textarea>";
        } else {
            String inputType = spec.password ? "password" : (spec.numericPin ? "tel" : "text");
            String extra =
                    spec.numericPin
                            ? " inputmode=numeric pattern='[0-9]*'"
                            : " autocomplete=off autocapitalize=off spellcheck=false";
            fieldHtml =
                    "<input id=txt name=text type="
                            + inputType
                            + extra
                            + " maxlength="
                            + spec.maxChars
                            + " value='"
                            + escVal
                            + "' placeholder='"
                            + escHint
                            + "'>";
        }
        boolean hasFileUpload = fileListener != null;
        String escFileHint =
                SearchInputServer.escapeHtml(
                        spec.fileHint.isEmpty()
                                ? "支持选择手机本地 TXT / JSON / M3U / M3U8 文件直接导入电视（最大 8MB）"
                                : spec.fileHint);
        String uploadSectionHtml = "";
        String uploadScript = "";
        if (hasFileUpload) {
            uploadSectionHtml =
                    "<div class=sep><span>或从手机导入本地文件</span></div>"
                            + "<label class=pick for=file id=pickLbl>"
                            + "<span class=pick-ico>📂</span>"
                            + "<span class=pick-txt><b id=fname>选择文件（TXT / JSON / M3U / M3U8）</b>"
                            + "<small>"
                            + escFileHint
                            + "</small></span>"
                            + "</label>"
                            + "<input id=file type=file style='position:absolute;width:1px;height:1px;opacity:0;overflow:hidden'>"
                            + "<div class=row><button class=acc type=button id=upBtn disabled>上传并导入到电视</button></div>"
                            + "<div id=fmsg></div>";
            uploadScript =
                    "var fi=document.getElementById('file'),ub=document.getElementById('upBtn'),"
                            + "fn=document.getElementById('fname'),fm=document.getElementById('fmsg'),selFile=null;"
                            + "function fmtSize(n){return n<1024?n+' B':n<1048576?(n/1024).toFixed(1)+' KB':(n/1048576).toFixed(2)+' MB';}"
                            + "function doUpload(){if(!selFile)return;if(selFile.size>"
                            + MAX_FILE_BYTES
                            + "){fm.className='err';fm.textContent='文件超过 8MB 限制';return;}"
                            + "ub.disabled=true;fm.className='';fm.textContent='正在上传并解析 '+selFile.name+'…';"
                            + "fetch('"
                            + escPath
                            + "/upload?name='+encodeURIComponent(selFile.name),{method:'POST',headers:{'Content-Type':'application/octet-stream'},body:selFile})"
                            + ".then(function(r){return r.json().then(function(d){return {ok:r.ok&&d.ok,msg:d.message,err:d.error};});})"
                            + ".then(function(res){ub.disabled=false;if(res.ok){fm.textContent='✓ '+(res.msg||'导入成功');selFile=null;if(fi)fi.value='';fn.textContent='继续选择其他文件（TXT / JSON / M3U / M3U8）';ub.disabled=true;}"
                            + "else{fm.className='err';fm.textContent=res.err||'导入失败';}})"
                            + ".catch(function(){ub.disabled=false;fm.className='err';fm.textContent='连接已断开，请重新扫描电视二维码';});}"
                            + "if(fi){fi.onchange=function(){selFile=fi.files&&fi.files[0]?fi.files[0]:null;"
                            + "if(selFile){fn.textContent=selFile.name+'（'+fmtSize(selFile.size)+'）';ub.disabled=false;fm.className='';fm.textContent='已选择文件，点击下方按钮立即导入';}"
                            + "else{fn.textContent='选择文件（TXT / JSON / M3U / M3U8）';ub.disabled=true;}};}"
                            + "if(ub){ub.onclick=doUpload;}";
        }
        return "<!doctype html><html lang=zh-CN><meta charset=utf-8>"
                + "<meta name=viewport content='width=device-width,initial-scale=1,maximum-scale=1'>"
                + "<title>"
                + escTitle
                + " · Marco Movie</title><style>"
                + "body{margin:0;background:#0e1118;color:#f5f7fb;font:16px -apple-system,BlinkMacSystemFont,sans-serif;padding:22px}"
                + "main{max-width:520px;margin:3vh auto;background:#171c26;border:1px solid rgba(255,255,255,.12);border-radius:20px;padding:22px}"
                + "h1{margin:0 0 6px;font-size:22px}p.sub{margin:0 0 16px;font-size:13.5px;color:#9aa8bc;line-height:1.5}"
                + "input,textarea{box-sizing:border-box;width:100%;border:1px solid rgba(255,255,255,.16);border-radius:14px;padding:14px;font:inherit;background:#0f131b;color:#fff;outline:none;resize:vertical}"
                + "input:focus,textarea:focus{border-color:#4ea1ff}"
                + ".row{display:flex;gap:10px;margin-top:14px}"
                + "button{flex:1;border:0;border-radius:14px;padding:14px;font:600 15px inherit;cursor:pointer}"
                + "button:disabled{opacity:.42;cursor:not-allowed}"
                + ".pri{background:#f5f7fb;color:#0e1118}.sec{background:#252c3b;color:#d6e0ee;flex:0 0 auto;padding:14px 18px}"
                + ".acc{background:#0a84ff;color:#fff}"
                + ".sep{display:flex;align-items:center;gap:12px;margin:20px 0 14px;color:#7e8da3;font-size:12.5px}"
                + ".sep:before,.sep:after{content:'';flex:1;height:1px;background:rgba(255,255,255,.12)}"
                + ".pick{display:flex;align-items:center;gap:12px;padding:14px 16px;border-radius:14px;border:1.5px dashed rgba(96,165,250,.48);background:rgba(10,132,255,.08);cursor:pointer}"
                + ".pick-ico{font-size:24px;line-height:1}.pick-txt{display:flex;flex-direction:column;gap:3px;min-width:0}"
                + ".pick-txt b{font-size:14.5px;color:#f5f7fb;word-break:break-all}.pick-txt small{font-size:12px;color:#9aa8bc;line-height:1.4}"
                + "#msg,#fmsg{margin-top:12px;font-size:13.5px;min-height:20px;color:#5eead4}"
                + ".err{color:#fca5a5!important}"
                + "</style><main><h1>"
                + escTitle
                + "</h1><p class=sub>"
                + (hasFileUpload
                        ? "手机输入/粘贴直播源网址，或直接选择本地 TXT / JSON / M3U 文件上传到电视。仅限同一局域网有效。"
                        : "手机输入或粘贴内容后，将实时填入电视端当前输入框。仅限同一局域网有效。")
                + "</p>"
                + "<form id=f method=post action='"
                + escPath
                + "/push'>"
                + fieldHtml
                + "<div class=row><button class=pri type=submit>发送到电视</button>"
                + "<button class=sec type=button id=clr>清空</button></div></form>"
                + "<div id=msg>"
                + escNotice
                + "</div>"
                + uploadSectionHtml
                + "</main><script>"
                + "var f=document.getElementById('f'),t=document.getElementById('txt'),m=document.getElementById('msg');"
                + "function send(clear){m.className='';m.textContent=clear?'正在清空…':'正在发送…';"
                + "fetch('"
                + escPath
                + "/push',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({text:clear?'':t.value,clear:!!clear})})"
                + ".then(function(r){return r.json().then(function(d){return {ok:r.ok&&d.ok,err:d.error};});})"
                + ".then(function(res){if(res.ok){m.textContent=clear?'✓ 已清空电视输入框':'✓ 已发送到电视';if(clear)t.value='';}"
                + "else{m.className='err';m.textContent=res.err||'发送失败';}})"
                + ".catch(function(){m.className='err';m.textContent='连接已断开，请重新扫描电视二维码';});}"
                + "f.onsubmit=function(e){e.preventDefault();send(false);};"
                + "document.getElementById('clr').onclick=function(){send(true);};"
                + uploadScript
                + "if(t){t.focus();}"
                + "</script></html>";
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

    private static String parseFormValue(String body, String key) {
        if (body == null || body.isEmpty()) return "";
        String[] parts = body.split("&");
        for (String part : parts) {
            int eq = part.indexOf('=');
            if (eq <= 0) continue;
            if (key.equals(part.substring(0, eq))) {
                try {
                    return URLDecoder.decode(part.substring(eq + 1), "UTF-8");
                } catch (Exception ignored) {
                    return part.substring(eq + 1);
                }
            }
        }
        return "";
    }

    private static void reply(OutputStream out, int code, String contentType, String body)
            throws IOException {
        byte[] bytes = body.getBytes("UTF-8");
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
                                                                        : code == 415
                                                                                ? "Unsupported Media Type"
                                                                                : "Error";
        ByteArrayOutputStream header = new ByteArrayOutputStream();
        header.write(
                ("HTTP/1.1 "
                                + code
                                + " "
                                + status
                                + "\r\nContent-Type: "
                                + contentType
                                + "; charset=utf-8\r\nContent-Length: "
                                + bytes.length
                                + "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n")
                        .getBytes("ISO-8859-1"));
        out.write(header.toByteArray());
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
