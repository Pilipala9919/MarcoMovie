package com.pilipala.marcomovie;

import java.io.Closeable;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.SynchronousQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/**
 * Short-lived, token-scoped LAN HTTP server used as the QR fallback when automatic GitHub Issue
 * submission fails. Serves a mobile-friendly HTML page where the user can open a pre-filled GitHub
 * Issue with one tap, copy the full sanitized log, or download it as a {@code .txt} file.
 */
final class CrashReportShareServer implements Closeable {
    final ServerSocket socket;
    final String path;
    final long expires;
    final String title;
    final String markdownReport;
    final String githubNewIssueUrl;
    volatile boolean closed;

    final ThreadPoolExecutor requests =
            new ThreadPoolExecutor(
                    0,
                    2,
                    10,
                    TimeUnit.SECONDS,
                    new SynchronousQueue<>(),
                    r -> {
                        Thread t = new Thread(r, "movie-crash-share");
                        t.setDaemon(true);
                        return t;
                    });

    CrashReportShareServer(List<CrashReportStore.CrashReport> reports) throws IOException {
        this(reports, TimeUnit.MINUTES.toMillis(5), new InetSocketAddress("0.0.0.0", 0));
    }

    CrashReportShareServer(
            List<CrashReportStore.CrashReport> reports, long ttlMs, InetSocketAddress bind)
            throws IOException {
        this.title = CrashReportStore.formatIssueTitle(reports);
        this.markdownReport = CrashReportStore.formatIssueMarkdown(reports);
        this.githubNewIssueUrl = CrashReportStore.buildGithubNewIssueUrl(reports);
        this.expires = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(ttlMs);

        byte[] bytes = new byte[16];
        new SecureRandom().nextBytes(bytes);
        StringBuilder key = new StringBuilder(32);
        for (byte b : bytes) key.append(String.format(Locale.US, "%02x", b & 0xff));
        this.path = "/crash/" + key;

        this.socket = new ServerSocket();
        this.socket.bind(bind);

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
                                } catch (IOException e) {
                                    if (!closed) close();
                                }
                            }
                        },
                        "movie-crash-share-accept");
        accept.setDaemon(true);
        accept.start();
    }

    String address(String host) {
        return "http://" + host + ":" + socket.getLocalPort() + path;
    }

    boolean expired() {
        return closed || System.nanoTime() >= expires;
    }

    void serve(Socket client) {
        try (Socket s = client) {
            s.setSoTimeout(15000);
            InputStream in = s.getInputStream();
            OutputStream out = s.getOutputStream();
            InetAddress peer = s.getInetAddress();
            if (!ConfigTransferServer.isAllowedLanPeer(peer)) {
                reply(out, 403, "text/plain; charset=utf-8", "仅允许局域网设备访问", null);
                return;
            }
            String requestLine = readLine(in, 4096);
            String[] parts = requestLine.split(" ");
            if (parts.length < 2) return;
            String method = parts[0];
            String reqPath = parts[1];
            int qIdx = reqPath.indexOf('?');
            if (qIdx >= 0) reqPath = reqPath.substring(0, qIdx);

            Map<String, String> headers = new HashMap<>();
            int headerBytes = 0;
            for (; ; ) {
                String row = readLine(in, 4096);
                headerBytes += row.length();
                if (headerBytes > 16384) throw new IOException("Header too large");
                if (row.isEmpty()) break;
                int colon = row.indexOf(':');
                if (colon > 0) {
                    headers.put(
                            row.substring(0, colon).trim().toLowerCase(Locale.US),
                            row.substring(colon + 1).trim());
                }
            }
            if (expired()) {
                reply(out, 410, "text/plain; charset=utf-8", "二维码已过期，请在电视上重新打开崩溃日志反馈", null);
                return;
            }
            String host = headers.containsKey("host") ? headers.get("host") : "";
            String expected = s.getLocalAddress().getHostAddress() + ":" + socket.getLocalPort();
            if (!host.equals(expected)) {
                reply(out, 403, "text/plain; charset=utf-8", "请使用电视屏幕上显示的二维码地址访问", null);
                return;
            }
            if (!"GET".equals(method)) {
                reply(out, 405, "text/plain; charset=utf-8", "Method Not Allowed", null);
                return;
            }
            if (reqPath.equals(path)) {
                reply(out, 200, "text/html; charset=utf-8", renderHtmlPage(), null);
                return;
            }
            if (reqPath.equals(path + "/download")) {
                reply(
                        out,
                        200,
                        "text/plain; charset=utf-8",
                        markdownReport,
                        "attachment; filename=\"MarcoMovie-crash-report.txt\"");
                return;
            }
            reply(out, 404, "text/plain; charset=utf-8", "Not Found", null);
        } catch (Exception ignored) {
        }
    }

    private String renderHtmlPage() {
        String escapedTitle = escapeHtml(title);
        String escapedBody = escapeHtml(markdownReport);
        String escapedIssueUrl = escapeHtml(githubNewIssueUrl);
        String downloadHref = escapeHtml(path + "/download");
        return "<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">"
                + "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
                + "<title>Marco Movie 崩溃日志提交</title>"
                + "<style>"
                + "body{margin:0;padding:18px;font-family:-apple-system,BlinkMacSystemFont,sans-serif;"
                + "background:#0c1118;color:#f1f5f9;line-height:1.55}"
                + ".card{max-width:720px;margin:0 auto;background:#141b26;border:1px solid #263244;"
                + "border-radius:16px;padding:18px}"
                + "h1{margin:0 0 6px;font-size:18px}p.sub{margin:0 0 14px;color:#94a3b8;font-size:13px}"
                + ".btns{display:flex;flex-wrap:wrap;gap:10px;margin-bottom:14px}"
                + "a.btn,button.btn{flex:1 1 160px;text-align:center;text-decoration:none;border:none;"
                + "border-radius:10px;padding:12px 14px;font-size:14px;font-weight:600;cursor:pointer}"
                + ".primary{background:#16a34a;color:#fff}.secondary{background:#2563eb;color:#fff}"
                + ".ghost{background:#1e293b;color:#e2e8f0;border:1px solid #334155}"
                + "#status{font-size:13px;color:#4ade80;min-height:20px;margin-bottom:8px}"
                + "pre{background:#090d14;border:1px solid #1e293b;border-radius:10px;padding:12px;"
                + "overflow:auto;max-height:55vh;font-size:12px;white-space:pre-wrap;word-break:break-all;color:#cbd5e1}"
                + "</style></head><body><div class=\"card\">"
                + "<h1>Marco Movie 崩溃日志（已脱敏）</h1>"
                + "<p class=\"sub\">"
                + escapedTitle
                + " · 不含片源地址与账号凭证</p>"
                + "<div class=\"btns\">"
                + "<a class=\"btn primary\" id=\"ghBtn\" href=\""
                + escapedIssueUrl
                + "\" target=\"_blank\" rel=\"noopener\">一键前往 GitHub 提交 Issue</a>"
                + "<button class=\"btn secondary\" id=\"copyBtn\" type=\"button\">复制完整日志</button>"
                + "<a class=\"btn ghost\" href=\""
                + downloadHref
                + "\">下载 .txt 文件</a>"
                + "</div><div id=\"status\"></div>"
                + "<pre id=\"logText\">"
                + escapedBody
                + "</pre></div><script>"
                + "function copyLog(msg){var t=document.getElementById('logText').innerText;"
                + "var st=document.getElementById('status');"
                + "if(navigator.clipboard&&navigator.clipboard.writeText){"
                + "navigator.clipboard.writeText(t).then(function(){st.textContent=msg;},"
                + "function(){fallbackCopy(t,msg);});}else{fallbackCopy(t,msg);}}"
                + "function fallbackCopy(t,msg){var ta=document.createElement('textarea');"
                + "ta.value=t;ta.style.position='fixed';ta.style.opacity='0';document.body.appendChild(ta);"
                + "ta.select();try{document.execCommand('copy');document.getElementById('status').textContent=msg;}"
                + "catch(e){document.getElementById('status').textContent='请长按下方日志手动复制';}"
                + "document.body.removeChild(ta);}"
                + "document.getElementById('copyBtn').onclick=function(){copyLog('已复制完整脱敏日志，可直接粘贴发送');};"
                + "document.getElementById('ghBtn').onclick=function(){copyLog('已复制完整日志并打开 GitHub Issue 页面');};"
                + "</script></body></html>";
    }

    private static String escapeHtml(String s) {
        if (s == null) return "";
        return s.replace("&", "&amp;")
                .replace("<", "&lt;")
                .replace(">", "&gt;")
                .replace("\"", "&quot;")
                .replace("'", "&#39;");
    }

    private static void reply(
            OutputStream out, int code, String contentType, String body, String contentDisposition)
            throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        StringBuilder head =
                new StringBuilder()
                        .append("HTTP/1.1 ")
                        .append(code)
                        .append(" ")
                        .append(code == 200 ? "OK" : "Error")
                        .append("\r\nContent-Type: ")
                        .append(contentType)
                        .append("\r\nContent-Length: ")
                        .append(bytes.length)
                        .append(
                                "\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n");
        if (contentDisposition != null && !contentDisposition.isEmpty()) {
            head.append("Content-Disposition: ").append(contentDisposition).append("\r\n");
        }
        head.append("Connection: close\r\n\r\n");
        out.write(head.toString().getBytes(StandardCharsets.ISO_8859_1));
        out.write(bytes);
        out.flush();
    }

    private static String readLine(InputStream in, int maxLen) throws IOException {
        StringBuilder sb = new StringBuilder();
        int prev = -1;
        for (int i = 0; i < maxLen; i++) {
            int c = in.read();
            if (c < 0) break;
            if (c == '\n') {
                if (prev == '\r' && sb.length() > 0) sb.setLength(sb.length() - 1);
                break;
            }
            sb.append((char) c);
            prev = c;
        }
        return sb.toString();
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
