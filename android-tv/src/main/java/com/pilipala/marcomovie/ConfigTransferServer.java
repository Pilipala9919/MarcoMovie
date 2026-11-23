package com.pilipala.marcomovie;

import java.io.*;
import java.net.*;
import java.security.SecureRandom;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

/** Short-lived, token-scoped LAN configuration and sync receiver; separate from playback proxy. */
final class ConfigTransferServer implements Closeable {
    static final int MAX_SYNC_BYTES = 8 * 1024 * 1024;

    interface Importer {
        void apply(String address) throws Exception;
    }

    interface BatchImporter {
        void apply(String address, boolean appendMerge) throws Exception;
    }

    interface SyncHandler {
        String sync(String remotePayloadJson) throws Exception;
    }

    final ServerSocket socket;
    final String path;
    final long expires;
    final BatchImporter importer;
    final SyncHandler syncHandler;
    volatile boolean closed;
    final AtomicBoolean importing = new AtomicBoolean(), applied = new AtomicBoolean();
    final ThreadPoolExecutor requests =
            new ThreadPoolExecutor(
                    0,
                    2,
                    10,
                    TimeUnit.SECONDS,
                    new SynchronousQueue<>(),
                    r -> {
                        Thread t = new Thread(r, "movie-config-request");
                        t.setDaemon(true);
                        return t;
                    });

    private static BatchImporter wrapImporter(final Importer handler) {
        if (handler == null) return null;
        return new BatchImporter() {
            @Override
            public void apply(String address, boolean appendMerge) throws Exception {
                handler.apply(address);
            }
        };
    }

    ConfigTransferServer(Importer handler) throws IOException {
        this(
                wrapImporter(handler),
                null,
                TimeUnit.MINUTES.toMillis(5),
                new InetSocketAddress("0.0.0.0", 0),
                true);
    }

    ConfigTransferServer(Importer handler, SyncHandler sync) throws IOException {
        this(
                wrapImporter(handler),
                sync,
                TimeUnit.MINUTES.toMillis(5),
                new InetSocketAddress("0.0.0.0", 0),
                true);
    }

    static ConfigTransferServer withBatchImporter(BatchImporter handler, SyncHandler sync)
            throws IOException {
        return new ConfigTransferServer(
                handler,
                sync,
                TimeUnit.MINUTES.toMillis(5),
                new InetSocketAddress("0.0.0.0", 0),
                true);
    }

    ConfigTransferServer(Importer handler, long ttl, InetSocketAddress bind) throws IOException {
        this(wrapImporter(handler), null, ttl, bind, true);
    }

    ConfigTransferServer(Importer handler, SyncHandler sync, long ttl, InetSocketAddress bind)
            throws IOException {
        this(wrapImporter(handler), sync, ttl, bind, true);
    }

    private ConfigTransferServer(
            BatchImporter handler,
            SyncHandler sync,
            long ttl,
            InetSocketAddress bind,
            boolean internal)
            throws IOException {
        importer = handler;
        syncHandler = sync;
        expires = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(ttl);
        byte[] bytes = new byte[16];
        new SecureRandom().nextBytes(bytes);
        StringBuilder key = new StringBuilder();
        for (byte b : bytes) key.append(String.format(Locale.ROOT, "%02x", b & 255));
        path = "/configure/" + key;
        socket = new ServerSocket();
        socket.bind(bind);
        Thread accept =
                new Thread(
                        () -> {
                            while (!closed)
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
                        },
                        "movie-config-listener");
        accept.setDaemon(true);
        accept.start();
    }

    String address(String host) {
        return "http://" + host + ":" + socket.getLocalPort() + path;
    }

    boolean expired() {
        return closed || System.nanoTime() >= expires;
    }

    static boolean isAllowedLanPeer(InetAddress peer) {
        if (peer == null) return false;
        if (peer.isSiteLocalAddress() || peer.isLoopbackAddress() || peer.isLinkLocalAddress())
            return true;
        byte[] raw = peer.getAddress();
        if (raw != null && raw.length == 4) {
            int b0 = raw[0] & 0xff, b1 = raw[1] & 0xff;
            if (b0 == 100 && b1 >= 64 && b1 <= 127) return true;
        }
        return false;
    }

    void serve(Socket client) {
        try (Socket s = client) {
            s.setSoTimeout(20000);
            InputStream in = s.getInputStream();
            OutputStream out = s.getOutputStream();
            InetAddress peer = s.getInetAddress();
            if (!isAllowedLanPeer(peer)) {
                reply(out, 403, "text/plain", "仅允许局域网连接");
                return;
            }
            String[] first = line(in, 4096).split(" ");
            if (first.length != 3) return;
            Map<String, String> headers = new HashMap<>();
            int total = 0;
            for (; ; ) {
                String row = line(in, 4096);
                total += row.length();
                if (total > 16384) throw new IOException("Header limit");
                if (row.isEmpty()) break;
                int colon = row.indexOf(':');
                if (colon > 0)
                    headers.put(
                            row.substring(0, colon).trim().toLowerCase(Locale.ROOT),
                            row.substring(colon + 1).trim());
            }
            String reqPath = first[1];
            int qIdx = reqPath.indexOf('?');
            if (qIdx >= 0) reqPath = reqPath.substring(0, qIdx);
            boolean isSyncRequest = syncHandler != null && reqPath.equals(path + "/sync");
            if (!reqPath.equals(path) && !isSyncRequest) {
                reply(out, 404, "text/plain", "页面不存在");
                return;
            }
            if (expired()) {
                reply(out, 410, "text/plain", "二维码已过期，请在设备上重新打开");
                return;
            }
            String host = headers.containsKey("host") ? headers.get("host") : "";
            String expected = s.getLocalAddress().getHostAddress() + ":" + socket.getLocalPort();
            if (!host.equals(expected)) {
                reply(out, 403, "text/plain", "请使用设备上的二维码地址");
                return;
            }
            if (isSyncRequest) {
                serveSync(first[0], headers, host, in, out);
                return;
            }
            if (first[0].equals("GET")) {
                reply(out, 200, "text/html", importer == null ? syncOnlyPage() : page(""));
                return;
            }
            if (importer == null) {
                reply(out, 405, "text/plain", "此接收码仅用于局域网多端同步");
                return;
            }
            if (!first[0].equals("POST")) {
                reply(out, 405, "text/plain", "请求方式不支持");
                return;
            }
            String origin = headers.get("origin");
            if (origin != null && !origin.equals("http://" + host)) {
                reply(out, 403, "text/plain", "页面来源不匹配");
                return;
            }
            String contentType =
                    headers.containsKey("content-type") ? headers.get("content-type") : "";
            if (!contentType.startsWith("application/x-www-form-urlencoded")
                    || headers.containsKey("transfer-encoding")) {
                reply(out, 415, "text/plain", "请使用配置页面提交");
                return;
            }
            int length;
            try {
                String lenVal =
                        headers.containsKey("content-length")
                                ? headers.get("content-length")
                                : "-1";
                length = Integer.parseInt(lenVal);
            } catch (NumberFormatException e) {
                length = -1;
            }
            if (length < 0 || length > 32768) {
                reply(out, 413, "text/plain", "地址过长");
                return;
            }
            byte[] body = new byte[length];
            for (int n = 0; n < length; ) {
                int got = in.read(body, n, length - n);
                if (got < 0) throw new EOFException();
                n += got;
            }
            String address = "";
            boolean appendMerge = false;
            for (String pair : new String(body, "UTF-8").split("&")) {
                String[] p = pair.split("=", 2);
                String field = URLDecoder.decode(p[0], "UTF-8");
                if (field.equals("address") && p.length == 2) {
                    address = URLDecoder.decode(p[1], "UTF-8").trim();
                } else if (field.equals("merge") && p.length == 2) {
                    String mv = URLDecoder.decode(p[1], "UTF-8").trim();
                    appendMerge =
                            "1".equals(mv)
                                    || "true".equalsIgnoreCase(mv)
                                    || "on".equalsIgnoreCase(mv);
                }
            }
            try {
                address = SubscriptionManager.validateTransferAddressInput(address);
            } catch (Exception bad) {
                reply(out, 400, "text/html", page("请输入有效的 HTTP 或 HTTPS 配置地址（多源请每行粘贴一个地址）"));
                return;
            }
            if (applied.get()) {
                reply(out, 409, "text/html", page("电视已完成导入，请关闭此页面"));
                return;
            }
            if (!importing.compareAndSet(false, true)) {
                reply(out, 409, "text/html", page("正在导入，请稍候查看电视"));
                return;
            }
            try {
                if (applied.get()) {
                    reply(out, 409, "text/html", page("电视已完成导入，请关闭此页面"));
                    return;
                }
                if (expired()) throw new IOException();
                importer.apply(address, appendMerge);
                applied.set(true);
                reply(out, 200, "text/html", page("配置已导入电视，可以关闭此页面"));
            } catch (Exception error) {
                reply(out, 400, "text/html", page("导入未完成，请检查配置地址与电视网络后重试"));
            } finally {
                importing.set(false);
            }
        } catch (Exception ignored) {
        }
    }

    private void serveSync(
            String method,
            Map<String, String> headers,
            String host,
            InputStream in,
            OutputStream out)
            throws IOException {
        String origin = headers.get("origin");
        if (origin != null && !origin.equals("http://" + host)) {
            reply(out, 403, "text/plain", "来源不匹配");
            return;
        }
        if ("GET".equals(method)) {
            if (!importing.compareAndSet(false, true)) {
                reply(out, 409, "text/plain", "正在同步中，请稍候");
                return;
            }
            try {
                if (expired()) throw new IOException("Session expired");
                String payload = syncHandler.sync(null);
                reply(out, 200, "application/json", payload == null ? "{}" : payload);
            } catch (Exception error) {
                reply(out, 500, "text/plain", "读取本机同步数据失败");
            } finally {
                importing.set(false);
            }
            return;
        }
        if (!"POST".equals(method)) {
            reply(out, 405, "text/plain", "请求方式不支持");
            return;
        }
        String contentType =
                headers.containsKey("content-type")
                        ? headers.get("content-type").toLowerCase(Locale.ROOT)
                        : "";
        if (!contentType.startsWith("application/json")
                || headers.containsKey("transfer-encoding")) {
            reply(out, 415, "text/plain", "仅接受 JSON 同步数据");
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
        if (length < 0 || length > MAX_SYNC_BYTES) {
            reply(out, 413, "text/plain", "同步数据超出大小限制");
            return;
        }
        byte[] body = new byte[length];
        for (int n = 0; n < length; ) {
            int got = in.read(body, n, length - n);
            if (got < 0) throw new EOFException();
            n += got;
        }
        if (!importing.compareAndSet(false, true)) {
            reply(out, 409, "text/plain", "正在同步中，请稍候");
            return;
        }
        try {
            if (expired()) throw new IOException("Session expired");
            String merged = syncHandler.sync(new String(body, "UTF-8"));
            reply(out, 200, "application/json", merged == null ? "{}" : merged);
        } catch (Exception error) {
            reply(out, 400, "text/plain", "同步合并失败");
        } finally {
            importing.set(false);
        }
    }

    static String syncOnlyPage() {
        return "<!doctype html><html lang=zh-CN><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>Marco Movie 局域网同步</title><style>body{margin:0;background:#101013;color:#f5f5f7;font:17px system-ui;padding:28px}main{max-width:520px;margin:8vh auto}h1{font-size:28px}p{line-height:1.7;color:#bfbfc7}code{display:block;background:#22232a;padding:14px;border-radius:12px;color:#5ac8fa;word-break:break-all}</style><main><h1>Marco Movie 局域网同步已就绪</h1><p>请复制当前浏览器地址栏链接，在另一台设备的 Marco Movie「设置 → 多端网络同步 → 连接局域网其他设备」中粘贴并点击同步。</p></main></html>";
    }

    static String line(InputStream in, int max) throws IOException {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        for (int c; (c = in.read()) != -1; ) {
            if (c == '\n') break;
            if (c != '\r') b.write(c);
            if (b.size() > max) throw new IOException("Line limit");
        }
        return b.toString("ISO-8859-1");
    }

    static void reply(OutputStream out, int code, String type, String text) throws IOException {
        byte[] body = text.getBytes("UTF-8");
        String head =
                "HTTP/1.1 "
                        + code
                        + " Response\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: same-origin\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'\r\nContent-Type: "
                        + type
                        + "; charset=utf-8\r\nContent-Length: "
                        + body.length
                        + "\r\n\r\n";
        out.write(head.getBytes("US-ASCII"));
        out.write(body);
        out.flush();
    }

    static String page(String note) {
        return "<!doctype html><html lang=zh-CN><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>Marco Movie 配置</title><style>body{margin:0;background:#101013;color:#f5f5f7;font:17px system-ui;padding:28px}main{max-width:520px;margin:8vh auto}h1{font-size:30px}p{line-height:1.7;color:#bfbfc7}textarea,button{box-sizing:border-box;width:100%;border:0;border-radius:18px;padding:16px;font:inherit;margin:10px 0}textarea{background:#292930;color:white;min-height:124px;resize:vertical}button{background:#f5f5f7;color:#101013;font-weight:600}label.opt{display:flex;align-items:center;gap:10px;color:#d8e8ff;font-size:15px;margin:6px 2px 12px}label.opt input{width:20px;height:20px}.note{color:#d8e8ff}</style><main><h1>Marco Movie</h1><p>粘贴 1 个或多个自行获取的配置地址到下方（每行一个，可选「分组名,网址」格式），多源导入将自动按源分组。</p><p class=note>"
                + note
                + "</p><form method=post accept-charset=UTF-8><textarea name=address required maxlength=16384 autocomplete=off autocapitalize=off spellcheck=false placeholder='粘贴配置地址，支持多行导入多个源，如：&#10;源A,https://source-a.example/a.json&#10;源B,https://source-b.example/b.json'></textarea><label class=opt><input type=checkbox name=merge value=1>追加到电视已有片源并按源自动分组</label><button>导入到电视</button></form><p>本产品仅为工具，不内置影视资源。此页面只在本次扫码配置期间可用。</p></main></html>";
    }

    public void close() {
        closed = true;
        try {
            socket.close();
        } catch (IOException ignored) {
        }
        requests.shutdownNow();
    }
}
