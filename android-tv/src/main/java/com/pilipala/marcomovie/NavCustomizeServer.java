// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.SynchronousQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/**
 * Ephemeral LAN HTTP server for phone-based touch drag-and-drop reordering and renaming of TV
 * navigation modules. Mirrors the security posture of {@link SearchInputServer}: ephemeral random
 * port, 128-bit hex path token, 10-minute TTL, LAN-peer restriction, strict Host/Origin validation,
 * and CSP headers.
 */
final class NavCustomizeServer implements Closeable {
    static final long TTL_MS = 10 * 60 * 1000L;
    private static final int MAX_BODY = 16 * 1024;
    private static final String CSP =
            "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; "
                    + "connect-src 'self'; frame-ancestors 'none'";

    interface Listener {
        List<TvNavConfig.Module> currentModules();

        void onModulesSaved(List<TvNavConfig.Module> updated);

        void onModulesReset(List<TvNavConfig.Module> defaults);
    }

    private final ServerSocket socket;
    private final String host;
    private final int port;
    private final String token;
    private final long expiresAtNanos;
    private final Listener listener;
    private final ExecutorService workers;
    private volatile boolean closed;

    NavCustomizeServer(String lanHost, Listener listener) throws IOException {
        this.host = lanHost == null || lanHost.trim().isEmpty() ? "127.0.0.1" : lanHost.trim();
        this.listener = listener;
        byte[] rawToken = new byte[16];
        new SecureRandom().nextBytes(rawToken);
        StringBuilder tok = new StringBuilder(32);
        for (byte b : rawToken) tok.append(String.format(Locale.US, "%02x", b & 0xff));
        this.token = tok.toString();
        this.expiresAtNanos = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(TTL_MS);
        this.socket = new ServerSocket(0, 8, InetAddress.getByName("0.0.0.0"));
        this.port = this.socket.getLocalPort();
        this.workers =
                new ThreadPoolExecutor(
                        0,
                        3,
                        10L,
                        TimeUnit.SECONDS,
                        new SynchronousQueue<Runnable>(),
                        r -> {
                            Thread t = new Thread(r, "nav-customize-http");
                            t.setDaemon(true);
                            return t;
                        });
        Thread accept =
                new Thread(
                        () -> {
                            while (!closed) {
                                try {
                                    Socket client = socket.accept();
                                    try {
                                        workers.execute(() -> handle(client));
                                    } catch (RejectedExecutionException busy) {
                                        try {
                                            client.close();
                                        } catch (IOException ignored) {
                                        }
                                    }
                                } catch (IOException ignored) {
                                    break;
                                }
                            }
                        },
                        "nav-customize-accept");
        accept.setDaemon(true);
        accept.start();
    }

    String url() {
        return "http://" + host + ":" + port + "/nav/" + token;
    }

    int port() {
        return port;
    }

    private boolean expired() {
        return System.nanoTime() > expiresAtNanos;
    }

    private void handle(Socket client) {
        try (Socket s = client) {
            s.setSoTimeout(8000);
            if (!ConfigTransferServer.isAllowedLanPeer(s.getInetAddress())) {
                writeJson(s.getOutputStream(), 403, "{\"ok\":false,\"error\":\"lan_only\"}");
                return;
            }
            InputStream in = s.getInputStream();
            OutputStream out = s.getOutputStream();
            String requestLine = ConfigTransferServer.line(in, 2048);
            if (requestLine == null || requestLine.isEmpty()) return;
            String[] parts = requestLine.split(" ");
            if (parts.length < 2) {
                writeJson(out, 400, "{\"ok\":false,\"error\":\"bad_request\"}");
                return;
            }
            String method = parts[0].trim();
            String path = parts[1].trim();
            int q = path.indexOf('?');
            if (q >= 0) path = path.substring(0, q);

            Map<String, String> headers = new HashMap<>();
            for (int i = 0; i < 48; i++) {
                String h = ConfigTransferServer.line(in, 4096);
                if (h == null || h.isEmpty()) break;
                int colon = h.indexOf(':');
                if (colon > 0) {
                    headers.put(
                            h.substring(0, colon).trim().toLowerCase(Locale.ROOT),
                            h.substring(colon + 1).trim());
                }
            }

            if (expired()) {
                writeJson(out, 410, "{\"ok\":false,\"error\":\"expired\"}");
                return;
            }

            String expectedHost = host + ":" + port;
            String reqHost = headers.get("host");
            if (reqHost != null && !reqHost.equalsIgnoreCase(expectedHost)) {
                // Allow localhost during automated loopback tests
                if (!reqHost.equalsIgnoreCase("127.0.0.1:" + port)
                        && !reqHost.equalsIgnoreCase("localhost:" + port)) {
                    writeJson(out, 403, "{\"ok\":false,\"error\":\"host_mismatch\"}");
                    return;
                }
            }

            String base = "/nav/" + token;
            if ("GET".equals(method) && base.equals(path)) {
                List<TvNavConfig.Module> mods =
                        listener != null ? listener.currentModules() : TvNavConfig.defaultModules();
                writeHtml(out, 200, buildEditorHtml(base, TvNavConfig.toJson(mods)));
                return;
            }
            if ("GET".equals(method) && (base + "/state").equals(path)) {
                List<TvNavConfig.Module> mods =
                        listener != null ? listener.currentModules() : TvNavConfig.defaultModules();
                writeJson(out, 200, TvNavConfig.toJson(mods));
                return;
            }
            if ("POST".equals(method)
                    && ((base + "/save").equals(path) || (base + "/reset").equals(path))) {
                String secFetch = headers.get("sec-fetch-site");
                if (secFetch != null
                        && !"same-origin".equalsIgnoreCase(secFetch)
                        && !"none".equalsIgnoreCase(secFetch)) {
                    writeJson(out, 403, "{\"ok\":false,\"error\":\"cross_site\"}");
                    return;
                }
                String origin = headers.get("origin");
                if (origin != null
                        && !origin.equalsIgnoreCase("http://" + expectedHost)
                        && !origin.equalsIgnoreCase("http://127.0.0.1:" + port)
                        && !origin.equalsIgnoreCase("http://localhost:" + port)) {
                    writeJson(out, 403, "{\"ok\":false,\"error\":\"origin_mismatch\"}");
                    return;
                }
                if (headers.containsKey("transfer-encoding")) {
                    writeJson(out, 400, "{\"ok\":false,\"error\":\"chunked_not_supported\"}");
                    return;
                }
                int len = 0;
                try {
                    String cl = headers.get("content-length");
                    if (cl != null) len = Integer.parseInt(cl.trim());
                } catch (NumberFormatException ignored) {
                    writeJson(out, 400, "{\"ok\":false,\"error\":\"bad_length\"}");
                    return;
                }
                if (len < 0 || len > MAX_BODY) {
                    writeJson(out, 413, "{\"ok\":false,\"error\":\"payload_too_large\"}");
                    return;
                }
                String body = readExact(in, len);
                if ((base + "/reset").equals(path)) {
                    List<TvNavConfig.Module> defs = TvNavConfig.defaultModules();
                    if (listener != null) listener.onModulesReset(defs);
                    writeJson(out, 200, "{\"ok\":true,\"data\":" + TvNavConfig.toJson(defs) + "}");
                    return;
                }
                List<TvNavConfig.Module> parsed = TvNavConfig.parseJson(body);
                if (listener != null) listener.onModulesSaved(parsed);
                writeJson(out, 200, "{\"ok\":true,\"data\":" + TvNavConfig.toJson(parsed) + "}");
                return;
            }
            writeJson(out, 404, "{\"ok\":false,\"error\":\"not_found\"}");
        } catch (IOException ignored) {
        }
    }

    private static String readExact(InputStream in, int length) throws IOException {
        if (length <= 0) return "";
        ByteArrayOutputStream out = new ByteArrayOutputStream(length);
        byte[] buf = new byte[Math.min(4096, length)];
        int remaining = length;
        while (remaining > 0) {
            int n = in.read(buf, 0, Math.min(buf.length, remaining));
            if (n < 0) break;
            out.write(buf, 0, n);
            remaining -= n;
        }
        return new String(out.toByteArray(), StandardCharsets.UTF_8);
    }

    private static void writeHtml(OutputStream out, int code, String html) throws IOException {
        byte[] data = html.getBytes(StandardCharsets.UTF_8);
        String head =
                "HTTP/1.1 "
                        + code
                        + " OK\r\n"
                        + "Content-Type: text/html; charset=utf-8\r\n"
                        + "Content-Length: "
                        + data.length
                        + "\r\n"
                        + "Cache-Control: no-store\r\n"
                        + "Content-Security-Policy: "
                        + CSP
                        + "\r\n"
                        + "Connection: close\r\n\r\n";
        out.write(head.getBytes(StandardCharsets.US_ASCII));
        out.write(data);
        out.flush();
    }

    private static void writeJson(OutputStream out, int code, String json) throws IOException {
        byte[] data = json.getBytes(StandardCharsets.UTF_8);
        String status = code == 200 ? "OK" : code == 403 ? "Forbidden" : "Error";
        String head =
                "HTTP/1.1 "
                        + code
                        + " "
                        + status
                        + "\r\n"
                        + "Content-Type: application/json; charset=utf-8\r\n"
                        + "Content-Length: "
                        + data.length
                        + "\r\n"
                        + "Cache-Control: no-store\r\n"
                        + "Content-Security-Policy: "
                        + CSP
                        + "\r\n"
                        + "Connection: close\r\n\r\n";
        out.write(head.getBytes(StandardCharsets.US_ASCII));
        out.write(data);
        out.flush();
    }

    static String buildEditorHtml(String basePath, String initialJson) {
        String safeJson = initialJson.replace("</", "<\\/");
        return "<!doctype html><html lang='zh-CN'><head><meta charset='utf-8'/>"
                + "<meta name='viewport' content='width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no'/>"
                + "<title>电视导航栏自定义</title><style>"
                + "*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}"
                + "body{margin:0;padding:18px 16px 96px;font-family:-apple-system,BlinkMacSystemFont,'PingFang SC','Microsoft YaHei',sans-serif;"
                + "background:#0e121a;color:#f3f6fc;min-height:100vh}"
                + ".hdr{margin-bottom:14px}.ttl{font-size:20px;font-weight:700;margin:0 0 6px}"
                + ".sub{font-size:13px;color:#98a6bd;margin:0;line-height:1.45}"
                + ".pv{display:flex;flex-wrap:wrap;gap:6px;padding:10px 12px;border-radius:16px;"
                + "background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.12);margin:14px 0}"
                + ".chip{padding:5px 11px;border-radius:999px;background:rgba(255,255,255,.10);font-size:12px;font-weight:600;color:#eef3fb}"
                + ".chip:first-child{background:#f5f7fb;color:#111622}"
                + ".list{display:flex;flex-direction:column;gap:10px;touch-action:pan-y}"
                + ".row{display:flex;align-items:center;gap:10px;padding:10px 12px;border-radius:16px;"
                + "background:rgba(255,255,255,.07);border:1px solid rgba(255,255,255,.13);transition:transform .14s,background .14s}"
                + ".row.dragging{background:rgba(90,200,250,.22);border-color:#5ac8fa;transform:scale(1.02);box-shadow:0 10px 26px rgba(0,0,0,.45)}"
                + ".grip{width:34px;height:38px;display:flex;align-items:center;justify-content:center;border-radius:10px;"
                + "background:rgba(255,255,255,.08);color:#c4d0e3;font-size:18px;cursor:grab;touch-action:none;user-select:none}"
                + ".idx{width:22px;text-align:center;font-size:12px;font-weight:700;color:#7f90aa}"
                + ".fld{flex:1;min-width:0;display:flex;flex-direction:column;gap:3px}"
                + ".inp{width:100%;height:36px;padding:0 11px;border-radius:10px;border:1px solid rgba(255,255,255,.18);"
                + "background:rgba(8,11,17,.68);color:#fff;font-size:15px;font-weight:600;outline:none}"
                + ".inp:focus{border-color:#5ac8fa;background:rgba(14,20,30,.92)}"
                + ".meta{font-size:11px;color:#8091ab}"
                + ".mv{display:flex;gap:4px}.mbtn{width:32px;height:32px;border-radius:9px;border:1px solid rgba(255,255,255,.14);"
                + "background:rgba(255,255,255,.08);color:#e6eefc;font-size:14px;font-weight:700}"
                + ".mbtn:active{background:rgba(255,255,255,.22)}"
                + ".bar{position:fixed;left:0;right:0;bottom:0;padding:12px 16px calc(12px + env(safe-area-inset-bottom));"
                + "background:rgba(14,18,26,.94);backdrop-filter:blur(16px);border-top:1px solid rgba(255,255,255,.12);"
                + "display:flex;gap:10px;align-items:center}"
                + ".btn{flex:1;height:44px;border-radius:12px;border:0;font-size:15px;font-weight:700}"
                + ".btn-pri{background:#f5f7fb;color:#101521}.btn-sec{flex:0 0 104px;background:rgba(255,255,255,.12);color:#e7eefb}"
                + ".toast{position:fixed;top:14px;left:50%;transform:translateX(-50%);padding:8px 16px;border-radius:999px;"
                + "background:rgba(16,185,129,.95);color:#06231a;font-size:13px;font-weight:700;opacity:0;pointer-events:none;transition:opacity .2s}"
                + ".toast.show{opacity:1}"
                + "</style></head><body>"
                + "<div class='hdr'><div class='ttl'>电视导航栏自定义</div>"
                + "<p class='sub'>按住左侧 <b>≡</b> 上下拖动排序，直接修改文本框即可更改模块名称，保存后实时同步到电视。</p></div>"
                + "<div id='pv' class='pv'></div>"
                + "<div id='list' class='list'></div>"
                + "<div id='toast' class='toast'>已同步到电视 ✓</div>"
                + "<div class='bar'><button class='btn btn-sec' id='resetBtn'>恢复默认</button>"
                + "<button class='btn btn-pri' id='saveBtn'>保存到电视</button></div>"
                + "<script>"
                + "const BASE='"
                + basePath
                + "';"
                + "let items=("
                + safeJson
                + ").items||[];"
                + "const listEl=document.getElementById('list');"
                + "const pvEl=document.getElementById('pv');"
                + "const toastEl=document.getElementById('toast');"
                + "let toastTimer=null;"
                + "function showToast(msg,err){toastEl.textContent=msg;toastEl.style.background=err?'rgba(248,113,113,.95)':'rgba(52,211,153,.95)';toastEl.classList.add('show');clearTimeout(toastTimer);toastTimer=setTimeout(()=>toastEl.classList.remove('show'),2000);}"
                + "function renderPreview(){pvEl.innerHTML='';items.forEach(it=>{const s=document.createElement('span');s.className='chip';s.textContent=(it.label||'').trim()||it.defaultLabel;pvEl.appendChild(s);});}"
                + "function move(from,to){if(to<0||to>=items.length||from===to)return;const [x]=items.splice(from,1);items.splice(to,0,x);render();sync(false);}"
                + "function render(){listEl.innerHTML='';items.forEach((it,idx)=>{const row=document.createElement('div');row.className='row';row.dataset.index=idx;"
                + "const grip=document.createElement('div');grip.className='grip';grip.textContent='≡';"
                + "const num=document.createElement('div');num.className='idx';num.textContent=idx+1;"
                + "const fld=document.createElement('div');fld.className='fld';"
                + "const inp=document.createElement('input');inp.className='inp';inp.maxLength=8;inp.value=it.label;inp.placeholder=it.defaultLabel;"
                + "inp.addEventListener('input',()=>{it.label=inp.value;renderPreview();});"
                + "inp.addEventListener('blur',()=>{it.label=(inp.value||'').trim()||it.defaultLabel;inp.value=it.label;renderPreview();sync(false);});"
                + "const meta=document.createElement('div');meta.className='meta';meta.textContent='默认：'+it.defaultLabel;"
                + "fld.appendChild(inp);fld.appendChild(meta);"
                + "const mv=document.createElement('div');mv.className='mv';"
                + "const up=document.createElement('button');up.className='mbtn';up.textContent='↑';up.onclick=()=>move(idx,idx-1);"
                + "const dn=document.createElement('button');dn.className='mbtn';dn.textContent='↓';dn.onclick=()=>move(idx,idx+1);"
                + "mv.appendChild(up);mv.appendChild(dn);"
                + "bindDrag(grip,row,idx);"
                + "row.appendChild(grip);row.appendChild(num);row.appendChild(fld);row.appendChild(mv);listEl.appendChild(row);});renderPreview();}"
                + "function bindDrag(handle,row,startIdx){let active=false;let curIdx=startIdx;"
                + "function onStart(e){active=true;curIdx=Number(row.dataset.index);row.classList.add('dragging');if(e.cancelable)e.preventDefault();}"
                + "function onMove(e){if(!active)return;if(e.cancelable)e.preventDefault();"
                + "const y=(e.touches&&e.touches[0]?e.touches[0].clientY:e.clientY);"
                + "const rows=Array.from(listEl.children);"
                + "for(let i=0;i<rows.length;i++){const r=rows[i].getBoundingClientRect();if(y>=r.top&&y<=r.bottom&&i!==curIdx){"
                + "const [m]=items.splice(curIdx,1);items.splice(i,0,m);curIdx=i;render();"
                + "const newRow=listEl.children[curIdx];if(newRow)newRow.classList.add('dragging');break;}}}"
                + "function onEnd(){if(!active)return;active=false;Array.from(listEl.children).forEach(r=>r.classList.remove('dragging'));sync(false);}"
                + "handle.addEventListener('touchstart',onStart,{passive:false});"
                + "window.addEventListener('touchmove',onMove,{passive:false});"
                + "window.addEventListener('touchend',onEnd);"
                + "handle.addEventListener('mousedown',onStart);"
                + "window.addEventListener('mousemove',onMove);"
                + "window.addEventListener('mouseup',onEnd);}"
                + "async function sync(explicit){try{const payload={items:items.map(it=>({key:it.key,label:(it.label||'').trim()||it.defaultLabel}))};"
                + "const res=await fetch(BASE+'/save',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});"
                + "const j=await res.json();if(j.ok){if(j.data&&j.data.items){items=j.data.items;renderPreview();}showToast(explicit?'已保存到电视 ✓':'已实时同步到电视 ✓',false);}"
                + "else showToast('同步失败：'+(j.error||'未知错误'),true);}catch(err){showToast('网络已断开，请重新扫码',true);}}"
                + "document.getElementById('saveBtn').onclick=()=>sync(true);"
                + "document.getElementById('resetBtn').onclick=async()=>{try{const res=await fetch(BASE+'/reset',{method:'POST'});const j=await res.json();if(j.ok&&j.data&&j.data.items){items=j.data.items;render();showToast('已恢复默认顺序与名称 ✓',false);}}catch(err){showToast('重置失败',true);}};"
                + "render();</script></body></html>";
    }

    @Override
    public void close() {
        closed = true;
        try {
            socket.close();
        } catch (IOException ignored) {
        }
        workers.shutdownNow();
    }
}
