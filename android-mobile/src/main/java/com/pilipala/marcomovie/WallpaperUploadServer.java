package com.pilipala.marcomovie;

import java.io.*;
import java.net.*;
import java.security.SecureRandom;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Short-lived, token-scoped LAN HTTP server that receives a phone-selected wallpaper image over
 * Wi-Fi. Pure Java so offline unit checks can verify LAN/Host/Origin/payload-limit enforcement.
 */
final class WallpaperUploadServer implements Closeable {
    static final int MAX_IMAGE_BYTES = 16 * 1024 * 1024;

    interface Receiver {
        void apply(byte[] imageBytes) throws Exception;
    }

    final ServerSocket socket;
    final String path;
    final long expires;
    final Receiver receiver;
    volatile boolean closed;
    final AtomicBoolean uploading = new AtomicBoolean(), applied = new AtomicBoolean();
    final ThreadPoolExecutor requests =
            new ThreadPoolExecutor(
                    0,
                    2,
                    10,
                    TimeUnit.SECONDS,
                    new SynchronousQueue<>(),
                    r -> {
                        Thread t = new Thread(r, "movie-wallpaper-request");
                        t.setDaemon(true);
                        return t;
                    });

    WallpaperUploadServer(Receiver handler) throws IOException {
        this(handler, TimeUnit.MINUTES.toMillis(5), new InetSocketAddress("0.0.0.0", 0));
    }

    WallpaperUploadServer(Receiver handler, long ttl, InetSocketAddress bind) throws IOException {
        receiver = handler;
        expires = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(ttl);
        byte[] bytes = new byte[16];
        new SecureRandom().nextBytes(bytes);
        StringBuilder key = new StringBuilder();
        for (byte b : bytes) key.append(String.format(Locale.ROOT, "%02x", b & 255));
        path = "/wallpaper/" + key;
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
                        "movie-wallpaper-listener");
        accept.setDaemon(true);
        accept.start();
    }

    String address(String host) {
        return "http://" + host + ":" + socket.getLocalPort() + path;
    }

    boolean expired() {
        return closed || System.nanoTime() >= expires;
    }

    static boolean looksLikeSupportedImage(byte[] data) {
        if (data == null || data.length < 16) return false;
        int b0 = data[0] & 0xff, b1 = data[1] & 0xff, b2 = data[2] & 0xff, b3 = data[3] & 0xff;
        // JPEG
        if (b0 == 0xff && b1 == 0xd8 && b2 == 0xff) return true;
        // PNG
        if (b0 == 0x89 && b1 == 0x50 && b2 == 0x4e && b3 == 0x47) return true;
        // WebP (RIFF....WEBP)
        if (b0 == 0x52
                && b1 == 0x49
                && b2 == 0x46
                && b3 == 0x46
                && data[8] == 'W'
                && data[9] == 'E'
                && data[10] == 'B'
                && data[11] == 'P') return true;
        // GIF
        if (b0 == 'G' && b1 == 'I' && b2 == 'F' && b3 == '8') return true;
        // BMP
        if (b0 == 'B' && b1 == 'M') return true;
        return false;
    }

    void serve(Socket client) {
        try (Socket s = client) {
            s.setSoTimeout(30000);
            InputStream in = s.getInputStream();
            OutputStream out = s.getOutputStream();
            InetAddress peer = s.getInetAddress();
            if (!peer.isSiteLocalAddress() && !peer.isLoopbackAddress()) {
                reply(out, 403, "text/plain", "仅允许局域网设备上传壁纸");
                return;
            }
            String[] first = ConfigTransferServer.line(in, 4096).split(" ");
            if (first.length != 3) return;
            Map<String, String> headers = new HashMap<>();
            int total = 0;
            for (; ; ) {
                String row = ConfigTransferServer.line(in, 4096);
                total += row.length();
                if (total > 16384) throw new IOException("Header limit");
                if (row.isEmpty()) break;
                int colon = row.indexOf(':');
                if (colon > 0)
                    headers.put(
                            row.substring(0, colon).trim().toLowerCase(Locale.ROOT),
                            row.substring(colon + 1).trim());
            }
            if (!first[1].equals(path)) {
                reply(out, 404, "text/plain", "页面不存在");
                return;
            }
            if (expired()) {
                reply(out, 410, "text/plain", "二维码已过期，请在电视上重新打开");
                return;
            }
            String host = headers.containsKey("host") ? headers.get("host") : "";
            String expected = s.getLocalAddress().getHostAddress() + ":" + socket.getLocalPort();
            if (!host.equals(expected)) {
                reply(out, 403, "text/plain", "请使用电视上的二维码地址");
                return;
            }
            String origin = headers.get("origin");
            if (origin != null && !origin.equals("http://" + host)) {
                reply(out, 403, "text/plain", "页面来源不匹配");
                return;
            }
            if ("GET".equals(first[0])) {
                reply(out, 200, "text/html", uploadHtmlPage());
                return;
            }
            if (!"POST".equals(first[0])) {
                reply(out, 405, "text/plain", "请求方式不支持");
                return;
            }
            if (headers.containsKey("transfer-encoding")) {
                reply(out, 411, "text/plain", "请使用标准图片上传");
                return;
            }
            int length;
            try {
                String rawLen = headers.get("content-length");
                length = Integer.parseInt(rawLen != null ? rawLen : "-1");
            } catch (NumberFormatException e) {
                length = -1;
            }
            if (length < 16 || length > MAX_IMAGE_BYTES) {
                reply(
                        out,
                        413,
                        "application/json",
                        "{\"ok\":false,\"message\":\"图片大小需在 16 MB 以内\"}");
                return;
            }
            byte[] body = new byte[length];
            for (int n = 0; n < length; ) {
                int got = in.read(body, n, length - n);
                if (got < 0) throw new EOFException();
                n += got;
            }
            if (!looksLikeSupportedImage(body)) {
                reply(
                        out,
                        415,
                        "application/json",
                        "{\"ok\":false,\"message\":\"仅支持 JPG、PNG、WebP 图片\"}");
                return;
            }
            if (!uploading.compareAndSet(false, true)) {
                reply(
                        out,
                        409,
                        "application/json",
                        "{\"ok\":false,\"message\":\"电视正在处理上一张壁纸，请稍候\"}");
                return;
            }
            try {
                if (expired()) throw new IOException("Expired");
                receiver.apply(body);
                applied.set(true);
                reply(
                        out,
                        200,
                        "application/json",
                        "{\"ok\":true,\"message\":\"壁纸已上传并同步到电视，可以关闭此页面\"}");
            } catch (Exception error) {
                reply(
                        out,
                        400,
                        "application/json",
                        "{\"ok\":false,\"message\":\"图片无法解析，请更换一张 JPG/PNG/WebP 图片重试\"}");
            } finally {
                uploading.set(false);
            }
        } catch (Exception ignored) {
        }
    }

    static void reply(OutputStream out, int code, String type, String text) throws IOException {
        byte[] body = text.getBytes("UTF-8");
        String head =
                "HTTP/1.1 "
                        + code
                        + " Response\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: same-origin\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src blob: data:; connect-src 'self'; frame-ancestors 'none'\r\nContent-Type: "
                        + type
                        + "; charset=utf-8\r\nContent-Length: "
                        + body.length
                        + "\r\n\r\n";
        out.write(head.getBytes("US-ASCII"));
        out.write(body);
        out.flush();
    }

    static String uploadHtmlPage() {
        return "<!doctype html><html lang=zh-CN><meta charset=utf-8>"
                + "<meta name=viewport content='width=device-width,initial-scale=1'>"
                + "<title>Marco Movie 壁纸上传</title>"
                + "<style>"
                + "body{margin:0;min-height:100vh;background:radial-gradient(circle at 18% 15%,#1b3545,#0d0f14 68%);color:#f5f5f7;font:16px -apple-system,BlinkMacSystemFont,system-ui,sans-serif;padding:26px 20px;box-sizing:border-box}"
                + "main{max-width:460px;margin:4vh auto;background:rgba(28,32,42,.82);border:1px solid rgba(255,255,255,.14);border-radius:24px;padding:24px;box-shadow:0 24px 60px rgba(0,0,0,.45)}"
                + "h1{margin:0 0 8px;font-size:24px;font-weight:700;letter-spacing:-.02em}"
                + "p{margin:0 0 16px;line-height:1.6;color:#a9b2be;font-size:14px}"
                + ".drop{display:block;border:1.5px dashed rgba(255,255,255,.26);border-radius:18px;padding:22px 16px;text-align:center;cursor:pointer;background:rgba(255,255,255,.04);margin-bottom:14px}"
                + ".drop input{display:none}"
                + "#preview{display:none;width:100%;max-height:220px;object-fit:cover;border-radius:14px;margin:0 0 14px;border:1px solid rgba(255,255,255,.15)}"
                + "button{width:100%;border:0;border-radius:16px;padding:15px;font:600 16px inherit;background:#f5f5f7;color:#101013;cursor:pointer}"
                + "button:disabled{opacity:.45}"
                + ".msg{margin-top:14px;font-size:14px;color:#8cc8ff;min-height:20px;text-align:center}"
                + "</style>"
                + "<main>"
                + "<h1>替换电视首页壁纸</h1>"
                + "<p>从手机相册选择一张横版高清图片（JPG / PNG / WebP，16 MB 以内），自动适配电视 16:9 屏幕。</p>"
                + "<label class=drop><span id=pickText>点击选择手机相册图片</span><input id=file type=file accept='image/jpeg,image/png,image/webp,image/*'></label>"
                + "<img id=preview alt='壁纸预览'>"
                + "<button id=btn disabled>上传并设为电视壁纸</button>"
                + "<div id=msg class=msg></div>"
                + "</main>"
                + "<script>"
                + "const f=document.getElementById('file'),p=document.getElementById('preview'),b=document.getElementById('btn'),m=document.getElementById('msg'),t=document.getElementById('pickText');"
                + "let sel=null;"
                + "f.onchange=()=>{sel=f.files&&f.files[0];if(!sel){b.disabled=true;return;}t.textContent=sel.name+' ('+(sel.size/1024/1024).toFixed(2)+' MB)';p.src=URL.createObjectURL(sel);p.style.display='block';b.disabled=false;m.textContent='';};"
                + "b.onclick=async()=>{if(!sel)return;if(sel.size>16*1024*1024){m.textContent='图片超过 16 MB 限制，请压缩后再试';return;}b.disabled=true;m.textContent='正在上传到电视…';try{const r=await fetch(location.pathname,{method:'POST',headers:{'Content-Type':'application/octet-stream'},body:sel});const j=await r.json().catch(()=>({ok:r.ok,message:r.ok?'壁纸已更新':'上传失败'}));m.textContent=j.message||'完成';if(!j.ok)b.disabled=false;}catch(e){m.textContent='网络中断，请确认与电视在同一局域网';b.disabled=false;}};"
                + "</script></html>";
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
