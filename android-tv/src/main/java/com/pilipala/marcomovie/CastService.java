package com.pilipala.marcomovie;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.MulticastSocket;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URI;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.SynchronousQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;
import org.json.JSONObject;
import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.Node;
import org.w3c.dom.NodeList;

/**
 * Dual-mode LAN TV Cast Receiver:
 *
 * <ol>
 *   <li>UPnP / DLNA Digital Media Renderer (DMR): SSDP multicast {@code 239.255.255.250:1900} +
 *       {@code device.xml}, SCPD descriptors, GENA event subscription, and XXE-hardened SOAP
 *       control ({@code AVTransport:1}, {@code RenderingControl:1}, {@code ConnectionManager:1}).
 *   <li>Token-scoped QR Web Direct Cast &amp; Remote Control ({@code /cast/<token>}) for pushing
 *       {@code .m3u8}/{@code .mp4}/HTTP(S) streams from any phone browser on the same LAN.
 * </ol>
 */
final class CastService implements Closeable {
    static final String SSDP_ADDR = "239.255.255.250";
    static final int SSDP_PORT = 1900;
    static final int PREFERRED_HTTP_PORT = 18652;
    static final String BONJOUR_SERVICE_TYPE = "_marcomovie-cast._tcp.";
    static final int MAX_HTTP_BODY = 65536;

    static final String NT_ROOT = "upnp:rootdevice";
    static final String NT_RENDERER = "urn:schemas-upnp-org:device:MediaRenderer:1";
    static final String NT_RENDERER_2 = "urn:schemas-upnp-org:device:MediaRenderer:2";
    static final String NT_AV_TRANSPORT = "urn:schemas-upnp-org:service:AVTransport:1";
    static final String NT_AV_TRANSPORT_2 = "urn:schemas-upnp-org:service:AVTransport:2";
    static final String NT_RENDERING_CONTROL = "urn:schemas-upnp-org:service:RenderingControl:1";
    static final String NT_RENDERING_CONTROL_2 = "urn:schemas-upnp-org:service:RenderingControl:2";
    static final String NT_CONNECTION_MANAGER = "urn:schemas-upnp-org:service:ConnectionManager:1";

    interface Bridge {
        void openMedia(String url, String title, Map<String, String> headers, int startMs);

        void resume();

        void pause();

        void stop();

        void seekTo(int posMs);

        int positionMs();

        int durationMs();

        /** Returns {@code PLAYING}, {@code PAUSED_PLAYBACK}, {@code TRANSITIONING}, or {@code STOPPED}. */
        String transportState();

        int getVolumePercent();

        void setVolumePercent(int percent);

        boolean isMuted();

        void setMuted(boolean muted);

        default void setSpeed(float speed) {}

        default void onStatusChanged(String message) {}

        default void onClosed() {}
    }

    final String deviceUuid;
    volatile String friendlyName;
    volatile String lanIp;
    final Bridge bridge;
    final ServerSocket httpSocket;
    final String webCastPath;
    volatile boolean closed;

    volatile String currentUri = "";
    volatile String currentMetaData = "";
    volatile String currentTitle = "";
    volatile String nextUri = "";
    volatile String nextMetaData = "";
    volatile String lastClientInfo = "等待同一局域网设备投屏…";
    volatile boolean mediaOpened;
    volatile boolean ssdpActive;
    volatile boolean bonjourActive;

    MulticastSocket ssdpSocket;
    DatagramSocket notifySocket;
    ScheduledExecutorService scheduler;

    final ThreadPoolExecutor httpPool =
            new ThreadPoolExecutor(
                    0,
                    6,
                    15,
                    TimeUnit.SECONDS,
                    new SynchronousQueue<>(),
                    r -> {
                        Thread t = new Thread(r, "movie-cast-http");
                        t.setDaemon(true);
                        return t;
                    });

    CastService(
            String uuid,
            String friendlyName,
            String lanIp,
            Bridge bridge,
            boolean enableSsdp,
            InetSocketAddress httpBind)
            throws IOException {
        if (bridge == null) throw new IllegalArgumentException("bridge required");
        this.deviceUuid = normalizeUuid(uuid);
        this.friendlyName =
                friendlyName == null || friendlyName.trim().isEmpty()
                        ? "Marco Movie 电视投屏"
                        : friendlyName.trim();
        this.lanIp = lanIp == null ? "" : lanIp.trim();
        this.bridge = bridge;

        byte[] tokenBytes = new byte[16];
        new SecureRandom().nextBytes(tokenBytes);
        StringBuilder token = new StringBuilder(32);
        for (byte b : tokenBytes) token.append(String.format(Locale.ROOT, "%02x", b & 255));
        this.webCastPath = "/cast/" + token;

        this.httpSocket = new ServerSocket();
        this.httpSocket.setReuseAddress(true);
        this.httpSocket.bind(httpBind);

        Thread acceptThread =
                new Thread(
                        () -> {
                            while (!closed) {
                                try {
                                    Socket client = httpSocket.accept();
                                    try {
                                        httpPool.execute(() -> serveHttp(client));
                                    } catch (RejectedExecutionException full) {
                                        client.close();
                                    }
                                } catch (IOException err) {
                                    if (!closed) close();
                                }
                            }
                        },
                        "movie-cast-http-accept");
        acceptThread.setDaemon(true);
        acceptThread.start();

        if (enableSsdp && !this.lanIp.isEmpty()) {
            startSsdp();
        }
    }

    static String normalizeUuid(String raw) {
        if (raw == null || raw.trim().isEmpty()) {
            return UUID.randomUUID().toString();
        }
        String clean = raw.trim();
        if (clean.startsWith("uuid:")) clean = clean.substring(5).trim();
        clean = clean.replaceAll("[^A-Za-z0-9-]", "");
        return clean.isEmpty() ? UUID.randomUUID().toString() : clean;
    }

    int httpPort() {
        return httpSocket.getLocalPort();
    }

    String webCastUrl() {
        if (lanIp == null || lanIp.isEmpty()) return "";
        return "http://" + lanIp + ":" + httpPort() + webCastPath;
    }

    String dlnaLocationUrl() {
        if (lanIp == null || lanIp.isEmpty()) return "";
        return "http://" + lanIp + ":" + httpPort() + "/dlna/device.xml";
    }

    void updateFriendlyName(String name) {
        if (name == null || name.trim().isEmpty()) return;
        this.friendlyName = name.trim();
        if (scheduler != null && !closed) {
            scheduler.execute(() -> sendNotify("ssdp:alive"));
        }
    }

    private void startSsdp() {
        try {
            notifySocket = new DatagramSocket();
        } catch (Exception ignored) {
        }
        try {
            MulticastSocket ms = new MulticastSocket(null);
            ms.setReuseAddress(true);
            ms.bind(new InetSocketAddress(SSDP_PORT));
            InetAddress group = InetAddress.getByName(SSDP_ADDR);
            boolean joined = false;
            try {
                for (NetworkInterface nif :
                        Collections.list(NetworkInterface.getNetworkInterfaces())) {
                    if (!nif.isUp() || nif.isLoopback() || !nif.supportsMulticast()) continue;
                    for (InetAddress addr : Collections.list(nif.getInetAddresses())) {
                        if (addr instanceof Inet4Address && addr.isSiteLocalAddress()) {
                            try {
                                ms.joinGroup(new InetSocketAddress(group, SSDP_PORT), nif);
                                joined = true;
                            } catch (Exception ignored) {
                            }
                        }
                    }
                }
            } catch (Exception ignored) {
            }
            if (!joined) {
                try {
                    ms.joinGroup(group);
                } catch (Exception ignored) {
                }
            }
            ssdpSocket = ms;
            ssdpActive = true;
            Thread ssdpReader =
                    new Thread(
                            () -> {
                                byte[] buf = new byte[4096];
                                while (!closed && ssdpSocket != null) {
                                    try {
                                        DatagramPacket pkt = new DatagramPacket(buf, buf.length);
                                        ssdpSocket.receive(pkt);
                                        handleSsdpPacket(pkt);
                                    } catch (IOException err) {
                                        if (closed) break;
                                    }
                                }
                            },
                            "movie-cast-ssdp");
            ssdpReader.setDaemon(true);
            ssdpReader.start();
        } catch (Exception e) {
            AppLog.w("CastService", "SSDP multicast bind failed; HTTP/QR cast remains active", e);
        }

        scheduler =
                Executors.newSingleThreadScheduledExecutor(
                        r -> {
                            Thread t = new Thread(r, "movie-cast-announce");
                            t.setDaemon(true);
                            return t;
                        });
        scheduler.execute(() -> sendNotify("ssdp:alive"));
        scheduler.scheduleWithFixedDelay(() -> sendNotify("ssdp:alive"), 25, 45, TimeUnit.SECONDS);
    }

    static List<String[]> matchSsdpReplies(String text, String deviceUuid) {
        List<String[]> replies = new ArrayList<>();
        if (text == null || text.isEmpty()) return replies;
        String trimmed = text.trim();
        if (!trimmed.regionMatches(true, 0, "M-SEARCH", 0, 8)) return replies;
        String man = "";
        String st = "";
        for (String line : text.split("\r?\n")) {
            int colon = line.indexOf(':');
            if (colon <= 0) continue;
            String k = line.substring(0, colon).trim().toLowerCase(Locale.ROOT);
            String v = line.substring(colon + 1).trim();
            if ("man".equals(k)) man = v;
            else if ("st".equals(k)) st = v;
        }
        if (!man.toLowerCase(Locale.ROOT).contains("ssdp:discover") || st.isEmpty()) return replies;
        String udn = "uuid:" + normalizeUuid(deviceUuid);
        if ("ssdp:all".equalsIgnoreCase(st)) {
            replies.add(new String[] {NT_ROOT, udn + "::" + NT_ROOT});
            replies.add(new String[] {udn, udn});
            replies.add(new String[] {NT_RENDERER, udn + "::" + NT_RENDERER});
            replies.add(new String[] {NT_AV_TRANSPORT, udn + "::" + NT_AV_TRANSPORT});
            replies.add(new String[] {NT_RENDERING_CONTROL, udn + "::" + NT_RENDERING_CONTROL});
            replies.add(new String[] {NT_CONNECTION_MANAGER, udn + "::" + NT_CONNECTION_MANAGER});
        } else if (NT_ROOT.equalsIgnoreCase(st)) {
            replies.add(new String[] {NT_ROOT, udn + "::" + NT_ROOT});
        } else if (udn.equalsIgnoreCase(st)) {
            replies.add(new String[] {udn, udn});
        } else if (NT_RENDERER.equalsIgnoreCase(st) || NT_RENDERER_2.equalsIgnoreCase(st)) {
            replies.add(new String[] {NT_RENDERER, udn + "::" + NT_RENDERER});
        } else if (NT_AV_TRANSPORT.equalsIgnoreCase(st) || NT_AV_TRANSPORT_2.equalsIgnoreCase(st)) {
            replies.add(new String[] {NT_AV_TRANSPORT, udn + "::" + NT_AV_TRANSPORT});
        } else if (NT_RENDERING_CONTROL.equalsIgnoreCase(st)
                || NT_RENDERING_CONTROL_2.equalsIgnoreCase(st)) {
            replies.add(new String[] {NT_RENDERING_CONTROL, udn + "::" + NT_RENDERING_CONTROL});
        } else if (NT_CONNECTION_MANAGER.equalsIgnoreCase(st)) {
            replies.add(new String[] {NT_CONNECTION_MANAGER, udn + "::" + NT_CONNECTION_MANAGER});
        }
        return replies;
    }

    private void handleSsdpPacket(DatagramPacket pkt) {
        InetAddress sender = pkt.getAddress();
        if (!ConfigTransferServer.isAllowedLanPeer(sender)) return;
        String text;
        try {
            text = new String(pkt.getData(), pkt.getOffset(), pkt.getLength(), "UTF-8");
        } catch (Exception e) {
            return;
        }
        String location = dlnaLocationUrl();
        if (location.isEmpty()) return;
        List<String[]> replies = matchSsdpReplies(text, deviceUuid);
        if (replies.isEmpty()) return;

        DatagramSocket sock = notifySocket != null ? notifySocket : ssdpSocket;
        if (sock == null) return;
        for (String[] pair : replies) {
            String resp =
                    "HTTP/1.1 200 OK\r\n"
                            + "CACHE-CONTROL: max-age=1800\r\n"
                            + "EXT:\r\n"
                            + "LOCATION: "
                            + location
                            + "\r\n"
                            + "SERVER: Android/12 UPnP/1.0 MarcoMovie/1.0\r\n"
                            + "ST: "
                            + pair[0]
                            + "\r\n"
                            + "USN: "
                            + pair[1]
                            + "\r\n"
                            + "Content-Length: 0\r\n\r\n";
            try {
                byte[] bytes = resp.getBytes("UTF-8");
                sock.send(new DatagramPacket(bytes, bytes.length, sender, pkt.getPort()));
            } catch (Exception ignored) {
            }
        }
    }

    private void sendNotify(String nts) {
        String location = dlnaLocationUrl();
        if (location.isEmpty()) return;
        try {
            InetAddress group = InetAddress.getByName(SSDP_ADDR);
            String udn = "uuid:" + deviceUuid;
            String[][] types = {
                {NT_ROOT, udn + "::" + NT_ROOT},
                {udn, udn},
                {NT_RENDERER, udn + "::" + NT_RENDERER},
                {NT_AV_TRANSPORT, udn + "::" + NT_AV_TRANSPORT},
                {NT_RENDERING_CONTROL, udn + "::" + NT_RENDERING_CONTROL},
                {NT_CONNECTION_MANAGER, udn + "::" + NT_CONNECTION_MANAGER}
            };
            List<NetworkInterface> nifs = DlnaCastClient.activeLanInterfaces();
            boolean sentOnNif = false;
            for (NetworkInterface nif : nifs) {
                try (MulticastSocket ms = new MulticastSocket()) {
                    ms.setNetworkInterface(nif);
                    ms.setTimeToLive(4);
                    for (String[] pair : types) {
                        byte[] bytes = buildNotifyPacket(location, pair[0], pair[1], nts);
                        ms.send(new DatagramPacket(bytes, bytes.length, group, SSDP_PORT));
                    }
                    sentOnNif = true;
                } catch (Exception ignored) {
                }
            }
            if (!sentOnNif) {
                DatagramSocket sock = notifySocket != null ? notifySocket : ssdpSocket;
                if (sock == null) return;
                for (String[] pair : types) {
                    byte[] bytes = buildNotifyPacket(location, pair[0], pair[1], nts);
                    sock.send(new DatagramPacket(bytes, bytes.length, group, SSDP_PORT));
                }
            }
        } catch (Exception ignored) {
        }
    }

    private static byte[] buildNotifyPacket(String location, String nt, String usn, String nts)
            throws Exception {
        String msg =
                "NOTIFY * HTTP/1.1\r\n"
                        + "HOST: "
                        + SSDP_ADDR
                        + ":"
                        + SSDP_PORT
                        + "\r\n"
                        + "CACHE-CONTROL: max-age=1800\r\n"
                        + "LOCATION: "
                        + location
                        + "\r\n"
                        + "NT: "
                        + nt
                        + "\r\n"
                        + "NTS: "
                        + nts
                        + "\r\n"
                        + "SERVER: Android/12 UPnP/1.0 MarcoMovie/1.0\r\n"
                        + "USN: "
                        + usn
                        + "\r\n"
                        + "Content-Length: 0\r\n\r\n";
        return msg.getBytes("UTF-8");
    }

    static String validateCastMediaUrl(String raw) {
        if (raw == null) return "";
        String url = raw.trim();
        if (url.isEmpty() || url.length() > 8192) return "";
        for (int i = 0; i < url.length(); i++) {
            char c = url.charAt(i);
            if (c < 0x20 || c == 0x7f) return "";
        }
        // Encode unescaped spaces / pipes / braces in path/query (common in CDN cast URLs)
        // without altering host brackets or IPv6 literals.
        String parseTarget = url;
        int schemeEnd = url.indexOf("://");
        if (schemeEnd > 0) {
            int pathStart = url.indexOf('/', schemeEnd + 3);
            if (pathStart > 0) {
                String head = url.substring(0, pathStart);
                String tail =
                        url.substring(pathStart)
                                .replace(" ", "%20")
                                .replace("|", "%7C")
                                .replace("[", "%5B")
                                .replace("]", "%5D")
                                .replace("{", "%7B")
                                .replace("}", "%7D");
                parseTarget = head + tail;
            }
        }
        try {
            URI uri = new URI(parseTarget);
            String scheme = uri.getScheme();
            if (scheme == null) return "";
            String lowerScheme = scheme.toLowerCase(Locale.ROOT);
            if (!"http".equals(lowerScheme) && !"https".equals(lowerScheme)) {
                return "";
            }
            String host = uri.getHost();
            if (host == null || host.trim().isEmpty()) return "";
            String lowerHost = host.trim().toLowerCase(Locale.ROOT);
            if (lowerHost.startsWith("[") && lowerHost.endsWith("]")) {
                lowerHost = lowerHost.substring(1, lowerHost.length() - 1);
            }
            if ("localhost".equals(lowerHost)
                    || "0.0.0.0".equals(lowerHost)
                    || "::1".equals(lowerHost)
                    || "0:0:0:0:0:0:0:1".equals(lowerHost)
                    || lowerHost.startsWith("127.")) {
                return "";
            }
            return parseTarget;
        } catch (Exception bad) {
            return "";
        }
    }

    private void serveHttp(Socket client) {
        try (Socket s = client) {
            s.setSoTimeout(15000);
            InputStream in = s.getInputStream();
            OutputStream out = s.getOutputStream();
            InetAddress peer = s.getInetAddress();
            if (!ConfigTransferServer.isAllowedLanPeer(peer)) {
                replyHttp(out, 403, "text/plain", "Forbidden", null);
                return;
            }
            String reqLine = ConfigTransferServer.line(in, 4096);
            String[] first = reqLine.split(" ");
            if (first.length != 3) return;
            String method = first[0].trim().toUpperCase(Locale.ROOT);
            String reqPath = first[1].trim();
            int qIdx = reqPath.indexOf('?');
            if (qIdx >= 0) reqPath = reqPath.substring(0, qIdx);

            Map<String, String> headers = new HashMap<>();
            int headerBytes = 0;
            for (; ; ) {
                String row = ConfigTransferServer.line(in, 4096);
                headerBytes += row.length();
                if (headerBytes > 16384) throw new IOException("Header limit");
                if (row.isEmpty()) break;
                int colon = row.indexOf(':');
                if (colon > 0) {
                    headers.put(
                            row.substring(0, colon).trim().toLowerCase(Locale.ROOT),
                            row.substring(colon + 1).trim());
                }
            }

            if (reqPath.startsWith("/dlna/")) {
                serveDlna(s, method, reqPath, headers, in, out);
                return;
            }
            if (reqPath.equals(webCastPath) || reqPath.equals(webCastPath + "/api")) {
                serveWebCast(s, method, reqPath, headers, in, out);
                return;
            }
            replyHttp(out, 404, "text/plain", "Not Found", null);
        } catch (Exception ignored) {
        }
    }

    private void serveDlna(
            Socket s,
            String method,
            String reqPath,
            Map<String, String> headers,
            InputStream in,
            OutputStream out)
            throws IOException {
        if (headers.containsKey("origin") || headers.containsKey("sec-fetch-site")) {
            replyHttp(out, 403, "text/plain", "Browser cross-origin UPnP blocked", null);
            return;
        }
        if ("GET".equals(method)) {
            if ("/dlna/device.xml".equals(reqPath)) {
                replyHttp(out, 200, "text/xml", buildDeviceXml(), null);
                return;
            }
            if ("/dlna/AVTransport.xml".equals(reqPath)) {
                replyHttp(out, 200, "text/xml", buildAvTransportScpd(), null);
                return;
            }
            if ("/dlna/RenderingControl.xml".equals(reqPath)) {
                replyHttp(out, 200, "text/xml", buildRenderingControlScpd(), null);
                return;
            }
            if ("/dlna/ConnectionManager.xml".equals(reqPath)) {
                replyHttp(out, 200, "text/xml", buildConnectionManagerScpd(), null);
                return;
            }
            replyHttp(out, 404, "text/plain", "Not Found", null);
            return;
        }
        if ("SUBSCRIBE".equals(method) && reqPath.startsWith("/dlna/event/")) {
            Map<String, String> extra = new LinkedHashMap<>();
            String sid = headers.get("sid");
            if (sid == null || sid.isEmpty()) sid = "uuid:" + UUID.randomUUID();
            extra.put("SID", sid);
            extra.put("TIMEOUT", "Second-1800");
            replyHttp(out, 200, "text/plain", "", extra);
            return;
        }
        if ("UNSUBSCRIBE".equals(method) && reqPath.startsWith("/dlna/event/")) {
            replyHttp(out, 200, "text/plain", "", null);
            return;
        }
        if (!"POST".equals(method) || !reqPath.startsWith("/dlna/control/")) {
            replyHttp(out, 405, "text/plain", "Method Not Allowed", null);
            return;
        }
        byte[] body;
        String te = headers.get("transfer-encoding");
        if (te != null && te.toLowerCase(Locale.ROOT).contains("chunked")) {
            try {
                body = readChunkedBody(in, MAX_HTTP_BODY);
            } catch (IOException err) {
                replyHttp(out, 413, "text/plain", "Invalid chunked SOAP body", null);
                return;
            }
            if (body.length == 0) {
                replyHttp(out, 400, "text/plain", "Empty SOAP body", null);
                return;
            }
        } else {
            if (te != null && !te.trim().isEmpty()) {
                replyHttp(out, 415, "text/plain", "Unsupported Transfer-Encoding", null);
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
            if (length <= 0 || length > MAX_HTTP_BODY) {
                replyHttp(out, 413, "text/plain", "Invalid SOAP body length", null);
                return;
            }
            body = readExact(in, length);
        }
        String xml = new String(body, "UTF-8");
        Element actionEl;
        try {
            actionEl = parseSoapActionElement(xml);
        } catch (Exception badXml) {
            replyHttp(out, 400, "text/plain", "Malformed or forbidden XML", null);
            return;
        }
        if (actionEl == null) {
            replyHttp(out, 400, "text/plain", "Missing SOAP action", null);
            return;
        }
        String actionName = localNameOf(actionEl);
        String soapActionHeader = headers.get("soapaction");
        if (actionName.isEmpty() && soapActionHeader != null) {
            int hash = soapActionHeader.indexOf('#');
            if (hash > 0) {
                actionName = soapActionHeader.substring(hash + 1).replace("\"", "").trim();
            }
        }
        Map<String, String> args = childElementMap(actionEl);
        String peerHost = s.getInetAddress() != null ? s.getInetAddress().getHostAddress() : "局域网";
        handleSoapAction(reqPath, actionName, args, peerHost, out);
    }

    private static DocumentBuilder newSafeDocumentBuilder() throws Exception {
        DocumentBuilderFactory dbf = DocumentBuilderFactory.newInstance();
        dbf.setNamespaceAware(true);
        try {
            dbf.setXIncludeAware(false);
        } catch (Throwable ignored) {
        }
        try {
            dbf.setExpandEntityReferences(false);
        } catch (Throwable ignored) {
        }
        String[] trueFeatures = {"http://apache.org/xml/features/disallow-doctype-decl"};
        for (String f : trueFeatures) {
            try {
                dbf.setFeature(f, true);
            } catch (Throwable ignored) {
            }
        }
        String[] falseFeatures = {
            "http://xml.org/sax/features/external-general-entities",
            "http://xml.org/sax/features/external-parameter-entities",
            "http://apache.org/xml/features/nonvalidating/load-external-dtd"
        };
        for (String f : falseFeatures) {
            try {
                dbf.setFeature(f, false);
            } catch (Throwable ignored) {
            }
        }
        return dbf.newDocumentBuilder();
    }

    static Element parseSoapActionElement(String xml) throws Exception {
        if (xml == null) return null;
        if (xml.indexOf('\0') >= 0) throw new IOException("Null byte in XML");
        String upper = xml.toUpperCase(Locale.ROOT);
        if (upper.contains("<!DOCTYPE") || upper.contains("<!ENTITY")) {
            throw new IOException("DOCTYPE/ENTITY forbidden");
        }
        DocumentBuilder db = newSafeDocumentBuilder();
        Document doc = db.parse(new ByteArrayInputStream(xml.getBytes("UTF-8")));
        Element root = doc.getDocumentElement();
        if (root == null) return null;
        NodeList children = root.getChildNodes();
        for (int i = 0; i < children.getLength(); i++) {
            Node n = children.item(i);
            if (n.getNodeType() == Node.ELEMENT_NODE && "Body".equalsIgnoreCase(localNameOf(n))) {
                NodeList bodyKids = n.getChildNodes();
                for (int j = 0; j < bodyKids.getLength(); j++) {
                    Node action = bodyKids.item(j);
                    if (action.getNodeType() == Node.ELEMENT_NODE) {
                        return (Element) action;
                    }
                }
            }
        }
        return null;
    }

    private static String localNameOf(Node node) {
        String ln = node.getLocalName();
        if (ln != null && !ln.isEmpty()) return ln;
        String name = node.getNodeName();
        if (name == null) return "";
        int colon = name.indexOf(':');
        return colon >= 0 ? name.substring(colon + 1) : name;
    }

    private static Map<String, String> childElementMap(Element parent) {
        Map<String, String> map = new LinkedHashMap<>();
        NodeList kids = parent.getChildNodes();
        for (int i = 0; i < kids.getLength(); i++) {
            Node k = kids.item(i);
            if (k.getNodeType() == Node.ELEMENT_NODE) {
                String name = localNameOf(k);
                String text = k.getTextContent();
                map.put(name, text == null ? "" : text.trim());
            }
        }
        return map;
    }

    static String extractDidlTitle(String metadataXml) {
        if (metadataXml == null || metadataXml.trim().isEmpty()) return "";
        try {
            if (metadataXml.indexOf('\0') >= 0) return "";
            String upper = metadataXml.toUpperCase(Locale.ROOT);
            if (upper.contains("<!DOCTYPE") || upper.contains("<!ENTITY")) return "";
            Document doc =
                    newSafeDocumentBuilder()
                            .parse(new ByteArrayInputStream(metadataXml.getBytes("UTF-8")));
            NodeList all = doc.getElementsByTagName("*");
            for (int i = 0; i < all.getLength(); i++) {
                Node n = all.item(i);
                if ("title".equalsIgnoreCase(localNameOf(n))) {
                    String t = n.getTextContent();
                    if (t != null && !t.trim().isEmpty()) return t.trim();
                }
            }
        } catch (Exception ignored) {
        }
        return "";
    }

    private void handleSoapAction(
            String reqPath,
            String action,
            Map<String, String> args,
            String peerHost,
            OutputStream out)
            throws IOException {
        String serviceNs =
                reqPath.endsWith("RenderingControl")
                        ? NT_RENDERING_CONTROL
                        : reqPath.endsWith("ConnectionManager")
                                ? NT_CONNECTION_MANAGER
                                : NT_AV_TRANSPORT;

        if ("SetAVTransportURI".equalsIgnoreCase(action)) {
            String rawUri = args.containsKey("CurrentURI") ? args.get("CurrentURI") : "";
            String validUrl = validateCastMediaUrl(rawUri);
            if (validUrl.isEmpty()) {
                replySoapFault(out, "716", "Resource not found or unsupported URL");
                return;
            }
            String meta =
                    args.containsKey("CurrentURIMetaData") ? args.get("CurrentURIMetaData") : "";
            String title = extractDidlTitle(meta);
            if (title.isEmpty()) title = "DLNA 无线投屏";
            currentUri = validUrl;
            currentMetaData = meta;
            currentTitle = title;
            mediaOpened = true;
            lastClientInfo = "DLNA 投屏已连接 (" + peerHost + ") · " + title;
            bridge.onStatusChanged(lastClientInfo);
            bridge.openMedia(validUrl, title, Collections.emptyMap(), 0);
            replySoap(out, NT_AV_TRANSPORT, "SetAVTransportURI", "");
            return;
        }
        if ("SetNextAVTransportURI".equalsIgnoreCase(action)) {
            String rawNext = args.containsKey("NextURI") ? args.get("NextURI") : "";
            String validNext = validateCastMediaUrl(rawNext);
            if (!validNext.isEmpty()) {
                nextUri = validNext;
                nextMetaData =
                        args.containsKey("NextURIMetaData") ? args.get("NextURIMetaData") : "";
            }
            replySoap(out, NT_AV_TRANSPORT, "SetNextAVTransportURI", "");
            return;
        }
        if ("Play".equalsIgnoreCase(action)) {
            float speed = parseDlnaSpeed(args.get("Speed"));
            if (!mediaOpened && !currentUri.isEmpty()) {
                mediaOpened = true;
                bridge.openMedia(
                        currentUri,
                        currentTitle.isEmpty() ? "DLNA 无线投屏" : currentTitle,
                        Collections.emptyMap(),
                        0);
            } else {
                bridge.resume();
            }
            if (speed > 0f) bridge.setSpeed(speed);
            replySoap(out, NT_AV_TRANSPORT, "Play", "");
            return;
        }
        if ("Pause".equalsIgnoreCase(action)) {
            bridge.pause();
            replySoap(out, NT_AV_TRANSPORT, "Pause", "");
            return;
        }
        if ("Stop".equalsIgnoreCase(action)) {
            mediaOpened = false;
            lastClientInfo = "投屏已结束 · 等待新的投屏连接";
            bridge.onStatusChanged(lastClientInfo);
            bridge.stop();
            replySoap(out, NT_AV_TRANSPORT, "Stop", "");
            return;
        }
        if ("Seek".equalsIgnoreCase(action)) {
            String target = args.containsKey("Target") ? args.get("Target") : "";
            int targetMs = parseDlnaTimeMs(target);
            if (targetMs >= 0) bridge.seekTo(targetMs);
            replySoap(out, NT_AV_TRANSPORT, "Seek", "");
            return;
        }
        if ("GetPositionInfo".equalsIgnoreCase(action)) {
            int posMs = Math.max(0, bridge.positionMs());
            int durMs = Math.max(0, bridge.durationMs());
            String durStr = formatDlnaTime(durMs);
            String posStr = formatDlnaTime(posMs);
            String inner =
                    "<Track>"
                            + (currentUri.isEmpty() ? "0" : "1")
                            + "</Track>"
                            + "<TrackDuration>"
                            + durStr
                            + "</TrackDuration>"
                            + "<TrackMetaData>"
                            + SearchInputServer.escapeHtml(currentMetaData)
                            + "</TrackMetaData>"
                            + "<TrackURI>"
                            + SearchInputServer.escapeHtml(currentUri)
                            + "</TrackURI>"
                            + "<RelTime>"
                            + posStr
                            + "</RelTime>"
                            + "<AbsTime>"
                            + posStr
                            + "</AbsTime>"
                            + "<RelCount>2147483647</RelCount>"
                            + "<AbsCount>2147483647</AbsCount>";
            replySoap(out, NT_AV_TRANSPORT, "GetPositionInfo", inner);
            return;
        }
        if ("GetTransportInfo".equalsIgnoreCase(action)) {
            String state = bridge.transportState();
            if (state == null || state.isEmpty()) state = "STOPPED";
            String inner =
                    "<CurrentTransportState>"
                            + SearchInputServer.escapeHtml(state)
                            + "</CurrentTransportState>"
                            + "<CurrentTransportStatus>OK</CurrentTransportStatus>"
                            + "<CurrentSpeed>1</CurrentSpeed>";
            replySoap(out, NT_AV_TRANSPORT, "GetTransportInfo", inner);
            return;
        }
        if ("GetMediaInfo".equalsIgnoreCase(action)) {
            String durStr = formatDlnaTime(Math.max(0, bridge.durationMs()));
            String inner =
                    "<NrTracks>"
                            + (currentUri.isEmpty() ? "0" : "1")
                            + "</NrTracks>"
                            + "<MediaDuration>"
                            + durStr
                            + "</MediaDuration>"
                            + "<CurrentURI>"
                            + SearchInputServer.escapeHtml(currentUri)
                            + "</CurrentURI>"
                            + "<CurrentURIMetaData>"
                            + SearchInputServer.escapeHtml(currentMetaData)
                            + "</CurrentURIMetaData>"
                            + "<NextURI>"
                            + SearchInputServer.escapeHtml(nextUri)
                            + "</NextURI>"
                            + "<NextURIMetaData>"
                            + SearchInputServer.escapeHtml(nextMetaData)
                            + "</NextURIMetaData>"
                            + "<PlayMedium>NETWORK</PlayMedium>"
                            + "<RecordMedium>NOT_IMPLEMENTED</RecordMedium>"
                            + "<WriteStatus>NOT_IMPLEMENTED</WriteStatus>";
            replySoap(out, NT_AV_TRANSPORT, "GetMediaInfo", inner);
            return;
        }
        if ("GetDeviceCapabilities".equalsIgnoreCase(action)) {
            replySoap(
                    out,
                    NT_AV_TRANSPORT,
                    "GetDeviceCapabilities",
                    "<PlayMedia>NETWORK,NONE</PlayMedia><RecMedia>NOT_IMPLEMENTED</RecMedia><RecQualityModes>NOT_IMPLEMENTED</RecQualityModes>");
            return;
        }
        if ("GetTransportSettings".equalsIgnoreCase(action)) {
            replySoap(
                    out,
                    NT_AV_TRANSPORT,
                    "GetTransportSettings",
                    "<PlayMode>NORMAL</PlayMode><RecQualityMode>NOT_IMPLEMENTED</RecQualityMode>");
            return;
        }
        if ("GetVolume".equalsIgnoreCase(action)) {
            int vol = Math.max(0, Math.min(100, bridge.getVolumePercent()));
            replySoap(
                    out,
                    NT_RENDERING_CONTROL,
                    "GetVolume",
                    "<CurrentVolume>" + vol + "</CurrentVolume>");
            return;
        }
        if ("SetVolume".equalsIgnoreCase(action)) {
            try {
                int desired =
                        Integer.parseInt(
                                args.containsKey("DesiredVolume")
                                        ? args.get("DesiredVolume")
                                        : "50");
                bridge.setVolumePercent(Math.max(0, Math.min(100, desired)));
            } catch (NumberFormatException ignored) {
            }
            replySoap(out, NT_RENDERING_CONTROL, "SetVolume", "");
            return;
        }
        if ("GetMute".equalsIgnoreCase(action)) {
            replySoap(
                    out,
                    NT_RENDERING_CONTROL,
                    "GetMute",
                    "<CurrentMute>" + (bridge.isMuted() ? "1" : "0") + "</CurrentMute>");
            return;
        }
        if ("SetMute".equalsIgnoreCase(action)) {
            String rawMute = args.containsKey("DesiredMute") ? args.get("DesiredMute") : "0";
            boolean mute = "1".equals(rawMute) || "true".equalsIgnoreCase(rawMute);
            bridge.setMuted(mute);
            replySoap(out, NT_RENDERING_CONTROL, "SetMute", "");
            return;
        }
        if ("GetProtocolInfo".equalsIgnoreCase(action)) {
            String sink =
                    "http-get:*:video/mp4:*,http-get:*:video/x-matroska:*,http-get:*:video/mpeg:*,"
                            + "http-get:*:video/avi:*,http-get:*:video/x-flv:*,http-get:*:video/*:*,"
                            + "http-get:*:application/vnd.apple.mpegurl:*,http-get:*:application/x-mpegURL:*,"
                            + "http-get:*:audio/mpeg:*,http-get:*:audio/mp4:*,http-get:*:audio/*:*";
            replySoap(
                    out,
                    NT_CONNECTION_MANAGER,
                    "GetProtocolInfo",
                    "<Source></Source><Sink>" + sink + "</Sink>");
            return;
        }
        if ("GetCurrentConnectionIDs".equalsIgnoreCase(action)) {
            replySoap(
                    out,
                    NT_CONNECTION_MANAGER,
                    "GetCurrentConnectionIDs",
                    "<ConnectionIDs>0</ConnectionIDs>");
            return;
        }
        if ("GetCurrentConnectionInfo".equalsIgnoreCase(action)) {
            replySoap(
                    out,
                    NT_CONNECTION_MANAGER,
                    "GetCurrentConnectionInfo",
                    "<RcsID>0</RcsID><AVTransportID>0</AVTransportID><ProtocolInfo></ProtocolInfo>"
                            + "<PeerConnectionManager></PeerConnectionManager><PeerConnectionID>-1</PeerConnectionID>"
                            + "<Direction>Input</Direction><Status>OK</Status>");
            return;
        }
        replySoap(out, serviceNs, action, "");
    }

    static int parseDlnaTimeMs(String raw) {
        if (raw == null) return -1;
        String s = raw.trim();
        if (s.isEmpty()) return -1;
        try {
            if (s.contains(":")) {
                String[] parts = s.split(":");
                if (parts.length == 3) {
                    int h = Integer.parseInt(parts[0].trim());
                    int m = Integer.parseInt(parts[1].trim());
                    double sec = Double.parseDouble(parts[2].trim());
                    return Math.max(
                            0, (int) Math.round((h * 3600L + m * 60L) * 1000.0 + sec * 1000.0));
                }
                if (parts.length == 2) {
                    int m = Integer.parseInt(parts[0].trim());
                    double sec = Double.parseDouble(parts[1].trim());
                    return Math.max(0, (int) Math.round(m * 60000.0 + sec * 1000.0));
                }
            }
            return Math.max(0, (int) Math.round(Double.parseDouble(s) * 1000.0));
        } catch (NumberFormatException bad) {
            return -1;
        }
    }

    static float parseDlnaSpeed(String raw) {
        if (raw == null) return -1f;
        String s = raw.trim();
        if (s.isEmpty()) return -1f;
        try {
            int slash = s.indexOf('/');
            float val;
            if (slash > 0 && slash < s.length() - 1) {
                float num = Float.parseFloat(s.substring(0, slash).trim());
                float den = Float.parseFloat(s.substring(slash + 1).trim());
                if (den <= 0f) return -1f;
                val = num / den;
            } else {
                val = Float.parseFloat(s);
            }
            if (!Float.isFinite(val) || val <= 0f) return -1f;
            return Math.max(0.5f, Math.min(3.0f, val));
        } catch (NumberFormatException bad) {
            return -1f;
        }
    }

    static String formatDlnaTime(int ms) {
        int totalSec = Math.max(0, ms / 1000);
        int h = totalSec / 3600;
        int m = (totalSec % 3600) / 60;
        int s = totalSec % 60;
        return String.format(Locale.ROOT, "%02d:%02d:%02d", h, m, s);
    }

    private void serveWebCast(
            Socket s,
            String method,
            String reqPath,
            Map<String, String> headers,
            InputStream in,
            OutputStream out)
            throws IOException {
        String host = headers.containsKey("host") ? headers.get("host") : "";
        String expected = s.getLocalAddress().getHostAddress() + ":" + httpSocket.getLocalPort();
        if (!host.equals(expected)) {
            replyHttp(out, 403, "text/plain", "请使用电视投屏页显示的扫码地址访问", null);
            return;
        }
        boolean isApi = reqPath.equals(webCastPath + "/api");
        if ("GET".equals(method)) {
            if (isApi) {
                replyHttp(
                        out,
                        200,
                        "application/json",
                        buildWebStatusJson(true, "").toString(),
                        null);
                return;
            }
            replyHttp(out, 200, "text/html", renderWebCastHtml(), null);
            return;
        }
        if (!"POST".equals(method) || !isApi) {
            replyHttp(out, 405, "text/plain", "Method Not Allowed", null);
            return;
        }
        String secFetch = headers.get("sec-fetch-site");
        if (secFetch != null
                && !secFetch.equalsIgnoreCase("same-origin")
                && !secFetch.equalsIgnoreCase("none")) {
            replyHttp(out, 403, "text/plain", "跨站请求已拦截", null);
            return;
        }
        String origin = headers.get("origin");
        if (origin != null && !origin.equals("http://" + host)) {
            replyHttp(out, 403, "text/plain", "来源不匹配", null);
            return;
        }
        if (headers.containsKey("transfer-encoding")) {
            replyHttp(out, 415, "text/plain", "Chunked unsupported", null);
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
        if (length <= 0 || length > MAX_HTTP_BODY) {
            replyHttp(out, 413, "text/plain", "请求体过大", null);
            return;
        }
        String bodyText = new String(readExact(in, length), "UTF-8");
        JSONObject req;
        try {
            req = new JSONObject(bodyText);
        } catch (Exception badJson) {
            replyHttp(out, 400, "application/json", "{\"ok\":false,\"message\":\"请求格式无效\"}", null);
            return;
        }
        String cmd = req.optString("action", "play").trim().toLowerCase(Locale.ROOT);
        String peerHost = s.getInetAddress() != null ? s.getInetAddress().getHostAddress() : "手机网页";
        if ("play".equals(cmd)) {
            String validUrl = validateCastMediaUrl(req.optString("url", ""));
            if (validUrl.isEmpty()) {
                JSONObject err =
                        buildWebStatusJson(false, "请输入有效的 HTTP / HTTPS 视频直链（不支持本机回环或本地文件协议）");
                replyHttp(out, 400, "application/json", err.toString(), null);
                return;
            }
            String title = SearchInputServer.sanitizeKeyword(req.optString("title", ""));
            if (title.isEmpty()) title = "手机网页直投";
            Map<String, String> mediaHeaders = new LinkedHashMap<>();
            String referer = req.optString("referer", "").trim();
            if (!referer.isEmpty() && referer.indexOf('\r') < 0 && referer.indexOf('\n') < 0) {
                mediaHeaders.put("Referer", referer);
            }
            String ua = req.optString("userAgent", "").trim();
            if (!ua.isEmpty() && ua.indexOf('\r') < 0 && ua.indexOf('\n') < 0) {
                mediaHeaders.put("User-Agent", ua);
            }
            currentUri = validUrl;
            currentTitle = title;
            currentMetaData = "";
            mediaOpened = true;
            lastClientInfo = "扫码直投已连接 (" + peerHost + ") · " + title;
            bridge.onStatusChanged(lastClientInfo);
            bridge.openMedia(validUrl, title, mediaHeaders, 0);
            replyHttp(
                    out,
                    200,
                    "application/json",
                    buildWebStatusJson(true, "已在电视开始播放：" + title).toString(),
                    null);
            return;
        }
        if ("toggle".equals(cmd)) {
            if ("PLAYING".equalsIgnoreCase(bridge.transportState())) {
                bridge.pause();
                replyHttp(
                        out,
                        200,
                        "application/json",
                        buildWebStatusJson(true, "已暂停").toString(),
                        null);
            } else {
                bridge.resume();
                replyHttp(
                        out,
                        200,
                        "application/json",
                        buildWebStatusJson(true, "继续播放").toString(),
                        null);
            }
            return;
        }
        if ("pause".equals(cmd)) {
            bridge.pause();
            replyHttp(
                    out, 200, "application/json", buildWebStatusJson(true, "已暂停").toString(), null);
            return;
        }
        if ("resume".equals(cmd)) {
            bridge.resume();
            replyHttp(
                    out,
                    200,
                    "application/json",
                    buildWebStatusJson(true, "继续播放").toString(),
                    null);
            return;
        }
        if ("stop".equals(cmd)) {
            mediaOpened = false;
            lastClientInfo = "投屏已结束 · 等待新的投屏连接";
            bridge.onStatusChanged(lastClientInfo);
            bridge.stop();
            replyHttp(
                    out,
                    200,
                    "application/json",
                    buildWebStatusJson(true, "已结束电视投屏").toString(),
                    null);
            return;
        }
        if ("seek".equals(cmd)) {
            int deltaSec = req.optInt("deltaSeconds", 0);
            int absSec = req.optInt("positionSeconds", -1);
            int targetMs =
                    absSec >= 0
                            ? absSec * 1000
                            : Math.max(0, bridge.positionMs() + deltaSec * 1000);
            bridge.seekTo(targetMs);
            replyHttp(
                    out,
                    200,
                    "application/json",
                    buildWebStatusJson(true, "已跳转至 " + formatDlnaTime(targetMs)).toString(),
                    null);
            return;
        }
        if ("volume".equals(cmd)) {
            int delta = req.optInt("delta", 0);
            int set = req.optInt("value", -1);
            int next =
                    set >= 0
                            ? Math.max(0, Math.min(100, set))
                            : Math.max(0, Math.min(100, bridge.getVolumePercent() + delta));
            bridge.setVolumePercent(next);
            replyHttp(
                    out,
                    200,
                    "application/json",
                    buildWebStatusJson(true, "电视音量：" + next + "%").toString(),
                    null);
            return;
        }
        if ("mute".equals(cmd)) {
            boolean nextMute = !bridge.isMuted();
            bridge.setMuted(nextMute);
            replyHttp(
                    out,
                    200,
                    "application/json",
                    buildWebStatusJson(true, nextMute ? "电视已静音" : "已恢复声音").toString(),
                    null);
            return;
        }
        replyHttp(
                out, 400, "application/json", buildWebStatusJson(false, "未知控制指令").toString(), null);
    }

    private JSONObject buildWebStatusJson(boolean ok, String message) {
        JSONObject j = new JSONObject();
        try {
            j.put("ok", ok);
            j.put("message", message == null ? "" : message);
            j.put("deviceName", friendlyName);
            j.put("state", bridge.transportState());
            j.put("title", currentTitle);
            j.put("positionMs", Math.max(0, bridge.positionMs()));
            j.put("durationMs", Math.max(0, bridge.durationMs()));
            j.put("volume", Math.max(0, Math.min(100, bridge.getVolumePercent())));
            j.put("muted", bridge.isMuted());
        } catch (Exception ignored) {
        }
        return j;
    }

    private String renderWebCastHtml() {
        String escApi = SearchInputServer.escapeHtml(webCastPath + "/api");
        String escName = SearchInputServer.escapeHtml(friendlyName);
        return "<!doctype html><html lang='zh-CN'><head><meta charset='utf-8'>"
                + "<meta name='viewport' content='width=device-width,initial-scale=1,maximum-scale=1'>"
                + "<title>"
                + escName
                + " · 无线投屏</title>"
                + "<style>"
                + "*{box-sizing:border-box}"
                + "body{margin:0;background:#0d0e13;color:#f5f5f7;font:15px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;padding:18px}"
                + "main{max-width:500px;margin:1vh auto;display:flex;flex-direction:column;gap:14px}"
                + ".card{background:#181a22;border:1px solid rgba(255,255,255,.09);border-radius:20px;padding:20px;box-shadow:0 16px 40px rgba(0,0,0,.4)}"
                + ".badge{display:inline-block;font-size:12px;color:#66d4cf;background:rgba(102,212,207,.14);padding:3px 10px;border-radius:999px;font-weight:600}"
                + "h1{margin:8px 0 4px;font-size:21px}"
                + "p.sub{margin:0 0 14px;color:#9da2b3;font-size:13.5px}"
                + "label{display:block;font-size:12.5px;color:#aeb3c2;margin:10px 0 5px}"
                + "input{width:100%;padding:12px 14px;font-size:16px;color:#fff;background:#242734;border:1px solid rgba(255,255,255,.13);border-radius:12px;outline:none}"
                + "input:focus{border-color:#5ac8fa}"
                + "button{padding:12px 14px;font-size:14.5px;font-weight:600;border-radius:12px;border:0;cursor:pointer;background:#282c3a;color:#eef0f6}"
                + "button.primary{width:100%;margin-top:14px;background:#f5f5f7;color:#101013;font-size:16px;padding:13px}"
                + ".grid{display:grid;grid-template-columns:repeat(3,1fr);gap:9px;margin-top:12px}"
                + ".status{font-size:13.5px;color:#b8e5ff;margin-top:10px;min-height:20px}"
                + ".prog{font-family:ui-monospace,monospace;font-size:14px;color:#cfd4e3;margin-top:4px}"
                + "</style></head><body><main>"
                + "<section class='card'>"
                + "<span class='badge'>已连接 · "
                + escName
                + "</span>"
                + "<h1>扫码直投视频链接</h1>"
                + "<p class='sub'>粘贴 m3u8 / mp4 / 直播流地址即可推送到电视播放；哔哩哔哩、腾讯、爱奇艺、优酷、夸克等 App 也可直接在视频播放页点「TV 投屏」选择「"
                + escName
                + "」。</p>"
                + "<label>视频流地址 (HTTP / HTTPS)</label>"
                + "<input id='url' type='url' placeholder='https://media.example/video.m3u8' autocomplete='off'>"
                + "<label>显示标题（选填）</label>"
                + "<input id='title' type='text' maxlength='80' placeholder='例如：周末电影夜'>"
                + "<details style='margin-top:10px'><summary style='color:#9da2b3;font-size:13px;cursor:pointer'>高级请求头（Referer / User-Agent，选填）</summary>"
                + "<label>Referer</label><input id='ref' type='url' placeholder='选填'>"
                + "<label>User-Agent</label><input id='ua' type='text' placeholder='选填'></details>"
                + "<button class='primary' id='castBtn'>立即投屏到电视</button>"
                + "<div class='status' id='msg'>准备就绪</div>"
                + "</section>"
                + "<section class='card'>"
                + "<h1 style='margin-top:0;font-size:18px'>电视播放遥控</h1>"
                + "<div class='prog' id='prog'>状态：空闲 · 00:00:00 / 00:00:00</div>"
                + "<div class='grid'>"
                + "<button data-cmd='seek' data-val='-15'>快退 15s</button>"
                + "<button data-cmd='toggle'>播放 / 暂停</button>"
                + "<button data-cmd='seek' data-val='30'>快进 30s</button>"
                + "<button data-cmd='volume' data-val='-10'>音量 -</button>"
                + "<button data-cmd='mute'>静音切换</button>"
                + "<button data-cmd='volume' data-val='10'>音量 +</button>"
                + "<button data-cmd='stop' style='grid-column:1/-1;background:rgba(255,89,89,.18);color:#ffb4b4'>结束投屏</button>"
                + "</div></section></main>"
                + "<script>"
                + "(function(){"
                + "var api='"
                + escApi
                + "',msg=document.getElementById('msg'),prog=document.getElementById('prog');"
                + "function fmt(ms){var s=Math.max(0,Math.floor((ms||0)/1000)),h=Math.floor(s/3600),m=Math.floor((s%3600)/60),x=s%60;"
                + "return (h<10?'0':'')+h+':'+(m<10?'0':'')+m+':'+(x<10?'0':'')+x;}"
                + "function render(j){if(!j)return;if(j.message)msg.textContent=j.message;"
                + "prog.textContent='状态：'+(j.state||'STOPPED')+(j.title?' · '+j.title:'')+' · '+fmt(j.positionMs)+' / '+fmt(j.durationMs)+' · 音量 '+(j.volume||0)+'%';}"
                + "function post(payload){fetch(api,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)})"
                + ".then(function(r){return r.json();}).then(render).catch(function(){msg.textContent='连接电视失败，请确认仍在同一局域网';});}"
                + "document.getElementById('castBtn').addEventListener('click',function(){"
                + "post({action:'play',url:document.getElementById('url').value,title:document.getElementById('title').value,"
                + "referer:document.getElementById('ref').value,userAgent:document.getElementById('ua').value});});"
                + "var bs=document.querySelectorAll('button[data-cmd]');"
                + "for(var i=0;i<bs.length;i++){(function(b){b.addEventListener('click',function(){"
                + "var c=b.getAttribute('data-cmd'),v=parseInt(b.getAttribute('data-val')||'0',10);"
                + "if(c==='seek')post({action:'seek',deltaSeconds:v});"
                + "else if(c==='volume')post({action:'volume',delta:v});"
                + "else post({action:c});});})(bs[i]);}"
                + "setInterval(function(){fetch(api).then(function(r){return r.json();}).then(render).catch(function(){});},3000);"
                + "})();"
                + "</script></body></html>";
    }

    private String buildDeviceXml() {
        String escName = SearchInputServer.escapeHtml(friendlyName);
        String escUuid = SearchInputServer.escapeHtml(deviceUuid);
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                + "<root xmlns=\"urn:schemas-upnp-org:device-1-0\">"
                + "<specVersion><major>1</major><minor>0</minor></specVersion>"
                + "<device>"
                + "<deviceType>"
                + NT_RENDERER
                + "</deviceType>"
                + "<friendlyName>"
                + escName
                + "</friendlyName>"
                + "<manufacturer>Marco Movie</manufacturer>"
                + "<modelDescription>Marco Movie Wireless Cast Renderer</modelDescription>"
                + "<modelName>Marco Movie TV</modelName>"
                + "<modelNumber>1.0</modelNumber>"
                + "<UDN>uuid:"
                + escUuid
                + "</UDN>"
                + "<dlna:X_DLNADOC xmlns:dlna=\"urn:schemas-dlna-org:device-1-0\">DMR-1.50</dlna:X_DLNADOC>"
                + "<serviceList>"
                + "<service>"
                + "<serviceType>"
                + NT_AV_TRANSPORT
                + "</serviceType>"
                + "<serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>"
                + "<SCPDURL>/dlna/AVTransport.xml</SCPDURL>"
                + "<controlURL>/dlna/control/AVTransport</controlURL>"
                + "<eventSubURL>/dlna/event/AVTransport</eventSubURL>"
                + "</service>"
                + "<service>"
                + "<serviceType>"
                + NT_RENDERING_CONTROL
                + "</serviceType>"
                + "<serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>"
                + "<SCPDURL>/dlna/RenderingControl.xml</SCPDURL>"
                + "<controlURL>/dlna/control/RenderingControl</controlURL>"
                + "<eventSubURL>/dlna/event/RenderingControl</eventSubURL>"
                + "</service>"
                + "<service>"
                + "<serviceType>"
                + NT_CONNECTION_MANAGER
                + "</serviceType>"
                + "<serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>"
                + "<SCPDURL>/dlna/ConnectionManager.xml</SCPDURL>"
                + "<controlURL>/dlna/control/ConnectionManager</controlURL>"
                + "<eventSubURL>/dlna/event/ConnectionManager</eventSubURL>"
                + "</service>"
                + "</serviceList>"
                + "</device>"
                + "</root>";
    }

    private static String buildAvTransportScpd() {
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                + "<scpd xmlns=\"urn:schemas-upnp-org:service-1-0\">"
                + "<specVersion><major>1</major><minor>0</minor></specVersion>"
                + "<actionList>"
                + scpdAction(
                        "SetAVTransportURI",
                        new String[][] {
                            {"InstanceID", "in", "A_ARG_TYPE_InstanceID"},
                            {"CurrentURI", "in", "AVTransportURI"},
                            {"CurrentURIMetaData", "in", "AVTransportURIMetaData"}
                        })
                + scpdAction(
                        "SetNextAVTransportURI",
                        new String[][] {
                            {"InstanceID", "in", "A_ARG_TYPE_InstanceID"},
                            {"NextURI", "in", "NextAVTransportURI"},
                            {"NextURIMetaData", "in", "NextAVTransportURIMetaData"}
                        })
                + scpdAction(
                        "Play",
                        new String[][] {
                            {"InstanceID", "in", "A_ARG_TYPE_InstanceID"},
                            {"Speed", "in", "TransportPlaySpeed"}
                        })
                + scpdAction(
                        "Pause", new String[][] {{"InstanceID", "in", "A_ARG_TYPE_InstanceID"}})
                + scpdAction("Stop", new String[][] {{"InstanceID", "in", "A_ARG_TYPE_InstanceID"}})
                + scpdAction(
                        "Seek",
                        new String[][] {
                            {"InstanceID", "in", "A_ARG_TYPE_InstanceID"},
                            {"Unit", "in", "A_ARG_TYPE_SeekMode"},
                            {"Target", "in", "A_ARG_TYPE_SeekTarget"}
                        })
                + scpdAction(
                        "GetPositionInfo",
                        new String[][] {
                            {"InstanceID", "in", "A_ARG_TYPE_InstanceID"},
                            {"Track", "out", "CurrentTrack"},
                            {"TrackDuration", "out", "CurrentTrackDuration"},
                            {"TrackMetaData", "out", "CurrentTrackMetaData"},
                            {"TrackURI", "out", "CurrentTrackURI"},
                            {"RelTime", "out", "RelativeTimePosition"},
                            {"AbsTime", "out", "AbsoluteTimePosition"},
                            {"RelCount", "out", "RelativeCounterPosition"},
                            {"AbsCount", "out", "AbsoluteCounterPosition"}
                        })
                + scpdAction(
                        "GetTransportInfo",
                        new String[][] {
                            {"InstanceID", "in", "A_ARG_TYPE_InstanceID"},
                            {"CurrentTransportState", "out", "TransportState"},
                            {"CurrentTransportStatus", "out", "TransportStatus"},
                            {"CurrentSpeed", "out", "TransportPlaySpeed"}
                        })
                + scpdAction(
                        "GetMediaInfo",
                        new String[][] {
                            {"InstanceID", "in", "A_ARG_TYPE_InstanceID"},
                            {"NrTracks", "out", "NumberOfTracks"},
                            {"MediaDuration", "out", "CurrentMediaDuration"},
                            {"CurrentURI", "out", "AVTransportURI"},
                            {"CurrentURIMetaData", "out", "AVTransportURIMetaData"},
                            {"NextURI", "out", "NextAVTransportURI"},
                            {"NextURIMetaData", "out", "NextAVTransportURIMetaData"},
                            {"PlayMedium", "out", "PlaybackStorageMedium"},
                            {"RecordMedium", "out", "RecordStorageMedium"},
                            {"WriteStatus", "out", "RecordMediumWriteStatus"}
                        })
                + "</actionList>"
                + "<serviceStateTable>"
                + stateVar("A_ARG_TYPE_InstanceID", "ui4")
                + stateVar("AVTransportURI", "string")
                + stateVar("AVTransportURIMetaData", "string")
                + stateVar("NextAVTransportURI", "string")
                + stateVar("NextAVTransportURIMetaData", "string")
                + stateVar("TransportPlaySpeed", "string")
                + stateVar("TransportState", "string")
                + stateVar("TransportStatus", "string")
                + stateVar("A_ARG_TYPE_SeekMode", "string")
                + stateVar("A_ARG_TYPE_SeekTarget", "string")
                + stateVar("CurrentTrack", "ui4")
                + stateVar("CurrentTrackDuration", "string")
                + stateVar("CurrentTrackMetaData", "string")
                + stateVar("CurrentTrackURI", "string")
                + stateVar("RelativeTimePosition", "string")
                + stateVar("AbsoluteTimePosition", "string")
                + stateVar("RelativeCounterPosition", "i4")
                + stateVar("AbsoluteCounterPosition", "i4")
                + stateVar("NumberOfTracks", "ui4")
                + stateVar("CurrentMediaDuration", "string")
                + stateVar("PlaybackStorageMedium", "string")
                + stateVar("RecordStorageMedium", "string")
                + stateVar("RecordMediumWriteStatus", "string")
                + "</serviceStateTable>"
                + "</scpd>";
    }

    private static String buildRenderingControlScpd() {
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                + "<scpd xmlns=\"urn:schemas-upnp-org:service-1-0\">"
                + "<specVersion><major>1</major><minor>0</minor></specVersion>"
                + "<actionList>"
                + scpdAction(
                        "GetVolume",
                        new String[][] {
                            {"InstanceID", "in", "A_ARG_TYPE_InstanceID"},
                            {"Channel", "in", "A_ARG_TYPE_Channel"},
                            {"CurrentVolume", "out", "Volume"}
                        })
                + scpdAction(
                        "SetVolume",
                        new String[][] {
                            {"InstanceID", "in", "A_ARG_TYPE_InstanceID"},
                            {"Channel", "in", "A_ARG_TYPE_Channel"},
                            {"DesiredVolume", "in", "Volume"}
                        })
                + scpdAction(
                        "GetMute",
                        new String[][] {
                            {"InstanceID", "in", "A_ARG_TYPE_InstanceID"},
                            {"Channel", "in", "A_ARG_TYPE_Channel"},
                            {"CurrentMute", "out", "Mute"}
                        })
                + scpdAction(
                        "SetMute",
                        new String[][] {
                            {"InstanceID", "in", "A_ARG_TYPE_InstanceID"},
                            {"Channel", "in", "A_ARG_TYPE_Channel"},
                            {"DesiredMute", "in", "Mute"}
                        })
                + "</actionList>"
                + "<serviceStateTable>"
                + stateVar("A_ARG_TYPE_InstanceID", "ui4")
                + stateVar("A_ARG_TYPE_Channel", "string")
                + stateVar("Volume", "ui2")
                + stateVar("Mute", "boolean")
                + "</serviceStateTable>"
                + "</scpd>";
    }

    private static String buildConnectionManagerScpd() {
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                + "<scpd xmlns=\"urn:schemas-upnp-org:service-1-0\">"
                + "<specVersion><major>1</major><minor>0</minor></specVersion>"
                + "<actionList>"
                + scpdAction(
                        "GetProtocolInfo",
                        new String[][] {
                            {"Source", "out", "SourceProtocolInfo"},
                            {"Sink", "out", "SinkProtocolInfo"}
                        })
                + scpdAction(
                        "GetCurrentConnectionIDs",
                        new String[][] {{"ConnectionIDs", "out", "CurrentConnectionIDs"}})
                + "</actionList>"
                + "<serviceStateTable>"
                + stateVar("SourceProtocolInfo", "string")
                + stateVar("SinkProtocolInfo", "string")
                + stateVar("CurrentConnectionIDs", "string")
                + "</serviceStateTable>"
                + "</scpd>";
    }

    private static String scpdAction(String name, String[][] args) {
        StringBuilder sb = new StringBuilder();
        sb.append("<action><name>").append(name).append("</name><argumentList>");
        for (String[] a : args) {
            sb.append("<argument><name>")
                    .append(a[0])
                    .append("</name><direction>")
                    .append(a[1])
                    .append("</direction><relatedStateVariable>")
                    .append(a[2])
                    .append("</relatedStateVariable></argument>");
        }
        sb.append("</argumentList></action>");
        return sb.toString();
    }

    private static String stateVar(String name, String type) {
        return "<stateVariable sendEvents=\"no\"><name>"
                + name
                + "</name><dataType>"
                + type
                + "</dataType></stateVariable>";
    }

    private static void replySoap(
            OutputStream out, String serviceNs, String action, String innerXml) throws IOException {
        String safeAction = action == null || action.isEmpty() ? "Action" : action;
        String envelope =
                "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                        + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
                        + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
                        + "<s:Body><u:"
                        + safeAction
                        + "Response xmlns:u=\""
                        + serviceNs
                        + "\">"
                        + (innerXml == null ? "" : innerXml)
                        + "</u:"
                        + safeAction
                        + "Response></s:Body></s:Envelope>";
        Map<String, String> extra = new LinkedHashMap<>();
        extra.put("EXT", "");
        replyHttp(out, 200, "text/xml", envelope, extra);
    }

    private static void replySoapFault(OutputStream out, String errCode, String errDesc)
            throws IOException {
        String fault =
                "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                        + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
                        + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
                        + "<s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>"
                        + "<detail><UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\">"
                        + "<errorCode>"
                        + errCode
                        + "</errorCode><errorDescription>"
                        + SearchInputServer.escapeHtml(errDesc)
                        + "</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>";
        replyHttp(out, 500, "text/xml", fault, null);
    }

    static byte[] readChunkedBody(InputStream in, int maxBytes) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        while (true) {
            String sizeLine = ConfigTransferServer.line(in, 256).trim();
            int semi = sizeLine.indexOf(';');
            if (semi >= 0) sizeLine = sizeLine.substring(0, semi).trim();
            if (sizeLine.isEmpty()) throw new IOException("Empty chunk header");
            int chunkSize;
            try {
                chunkSize = Integer.parseInt(sizeLine, 16);
            } catch (NumberFormatException e) {
                throw new IOException("Bad chunk size");
            }
            if (chunkSize < 0 || out.size() + chunkSize > maxBytes) {
                throw new IOException("Chunk exceeds max body");
            }
            if (chunkSize == 0) {
                // Consume optional trailer lines until empty line
                for (int t = 0; t < 32; t++) {
                    String trailer = ConfigTransferServer.line(in, 512);
                    if (trailer.isEmpty()) break;
                }
                break;
            }
            byte[] chunk = readExact(in, chunkSize);
            out.write(chunk);
            String crlf = ConfigTransferServer.line(in, 16);
            if (!crlf.isEmpty()) throw new IOException("Expected CRLF after chunk");
        }
        return out.toByteArray();
    }

    private static byte[] readExact(InputStream in, int length) throws IOException {
        byte[] body = new byte[length];
        for (int n = 0; n < length; ) {
            int got = in.read(body, n, length - n);
            if (got < 0) throw new EOFException();
            n += got;
        }
        return body;
    }

    private static void replyHttp(
            OutputStream out,
            int code,
            String contentType,
            String body,
            Map<String, String> extraHeaders)
            throws IOException {
        byte[] bytes = (body == null ? "" : body).getBytes("UTF-8");
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
                                                        : code == 413
                                                                ? "Payload Too Large"
                                                                : code == 415
                                                                        ? "Unsupported Media Type"
                                                                        : "Internal Server Error";
        StringBuilder head = new StringBuilder(256);
        head.append("HTTP/1.1 ").append(code).append(' ').append(status).append("\r\n");
        head.append("Content-Type: ").append(contentType).append("; charset=utf-8\r\n");
        head.append("Content-Length: ").append(bytes.length).append("\r\n");
        head.append("Cache-Control: no-store\r\n");
        head.append("X-Content-Type-Options: nosniff\r\n");
        head.append("Server: Android/12 UPnP/1.0 MarcoMovie/1.0\r\n");
        if (extraHeaders != null) {
            for (Map.Entry<String, String> e : extraHeaders.entrySet()) {
                head.append(e.getKey()).append(": ").append(e.getValue()).append("\r\n");
            }
        }
        head.append("Connection: close\r\n\r\n");
        out.write(head.toString().getBytes("US-ASCII"));
        out.write(bytes);
        out.flush();
    }

    @Override
    public void close() {
        if (closed) return;
        closed = true;
        ssdpActive = false;
        bonjourActive = false;
        final java.util.concurrent.ScheduledExecutorService sched = scheduler;
        scheduler = null;
        if (sched != null) {
            try {
                sched.shutdownNow();
            } catch (Exception ignored) {
            }
        }
        final MulticastSocket oldSsdp = ssdpSocket;
        ssdpSocket = null;
        final DatagramSocket oldNotify = notifySocket;
        notifySocket = null;
        httpPool.shutdownNow();
        try {
            bridge.onClosed();
        } catch (Exception ignored) {
        }
        // Never send SSDP UDP multicast packets or close sockets synchronously on the Android UI
        // thread during Activity.onStop()/onDestroy() (prevents NetworkOnMainThread / ANR).
        Thread closer =
                new Thread(
                        () -> {
                            try {
                                if (oldNotify != null && !oldNotify.isClosed()) {
                                    notifySocket = oldNotify;
                                    sendNotify("ssdp:byebye");
                                    notifySocket = null;
                                }
                            } catch (Throwable ignored) {
                            }
                            if (oldSsdp != null) {
                                try {
                                    oldSsdp.close();
                                } catch (Exception ignored) {
                                }
                            }
                            if (oldNotify != null) {
                                try {
                                    oldNotify.close();
                                } catch (Exception ignored) {
                                }
                            }
                            try {
                                httpSocket.close();
                            } catch (Exception ignored) {
                            }
                        },
                        "cast-service-close");
        closer.setDaemon(true);
        closer.start();
    }

    /** Creates and starts a live {@link CastService} bound to an active TV {@link MainActivity}. */
    static CastService startForActivity(final MainActivity a, final Runnable uiObserver)
            throws Exception {
        String lanIp = PhoneConfigDialog.lanAddress();
        String uuid = a.prefs.getString(Prefs.CAST_DEVICE_UUID, "");
        if (uuid == null || uuid.trim().isEmpty()) {
            uuid = UUID.randomUUID().toString();
            a.prefs.edit().putString(Prefs.CAST_DEVICE_UUID, uuid).apply();
        }
        String defaultName = "Marco Movie 电视端";
        String name = a.prefs.getString(Prefs.CAST_DEVICE_NAME, defaultName);
        if (name == null || name.trim().isEmpty()) name = defaultName;

        android.net.wifi.WifiManager.MulticastLock mcastLock = null;
        try {
            android.net.wifi.WifiManager wm =
                    (android.net.wifi.WifiManager)
                            a.getApplicationContext()
                                    .getSystemService(android.content.Context.WIFI_SERVICE);
            if (wm != null) {
                mcastLock = wm.createMulticastLock("marcomovie-dlna-cast");
                mcastLock.setReferenceCounted(false);
                mcastLock.acquire();
            }
        } catch (Throwable ignored) {
        }
        final android.net.wifi.WifiManager.MulticastLock heldLock = mcastLock;
        final Runnable[] nsdCleanup = new Runnable[1];
        final android.media.AudioManager audio =
                (android.media.AudioManager)
                        a.getSystemService(android.content.Context.AUDIO_SERVICE);

        Bridge bridge =
                new Bridge() {
                    @Override
                    public void openMedia(
                            String url, String title, Map<String, String> headers, int startMs) {
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing() || a.isDestroyed() || a.privateMode) return;
                                    Cms.Site castSite = new Cms.Site();
                                    castSite.key = "cast";
                                    castSite.originalKey = "cast";
                                    castSite.name = "无线投屏";
                                    castSite.api = "";
                                    castSite.type = 1;
                                    castSite.searchable = false;

                                    Cms.Video video = new Cms.Video();
                                    video.id = "cast:" + url;
                                    video.title = title == null || title.isEmpty() ? "无线投屏" : title;

                                    Cms.Episode ep = new Cms.Episode();
                                    ep.name = video.title;
                                    ep.url = url;
                                    if (headers != null) ep.headers.putAll(headers);

                                    a.clearPlaybackLoading();
                                    a.stopWeb();
                                    a.stopMagnet();
                                    a.activeLine = null;
                                    a.activeEpisode = null;
                                    a.playingBookmark = null;
                                    a.resumeAt = Math.max(0, startMs);

                                    if (a.current != null && a.current.player) {
                                        if (a.miniMode) a.expandPlayback();
                                        PlaybackController.playerPage(a, castSite, video, ep);
                                    } else {
                                        MainActivity.Screen screen =
                                                new MainActivity.Screen(
                                                        () ->
                                                                PlaybackController.playerPage(
                                                                        a, castSite, video, ep));
                                        screen.player = true;
                                        a.open(screen, true);
                                    }
                                    a.toast("正在接收投屏：" + video.title);
                                });
                    }

                    @Override
                    public void resume() {
                        a.ui.post(
                                () -> {
                                    if (a.player != null && a.prepared && !a.playing) {
                                        try {
                                            a.player.start();
                                            a.playing = true;
                                            if (a.playerChrome != null) a.playerChrome.update();
                                        } catch (Exception ignored) {
                                        }
                                    }
                                });
                    }

                    @Override
                    public void pause() {
                        a.ui.post(
                                () -> {
                                    if (a.player != null && a.prepared && a.playing) {
                                        try {
                                            a.player.pause();
                                            a.playing = false;
                                            if (a.playerChrome != null) a.playerChrome.update();
                                        } catch (Exception ignored) {
                                        }
                                    }
                                });
                    }

                    @Override
                    public void stop() {
                        a.ui.post(
                                () -> {
                                    if (a.isCast() && a.current != null && a.current.player) {
                                        a.leavePlayback();
                                    }
                                });
                    }

                    @Override
                    public void seekTo(int posMs) {
                        a.ui.post(
                                () -> {
                                    if (a.player != null && a.prepared) {
                                        try {
                                            a.player.seekTo(Math.max(0, posMs));
                                            if (a.playerChrome != null) a.playerChrome.update();
                                        } catch (Exception ignored) {
                                        }
                                    }
                                });
                    }

                    @Override
                    public int positionMs() {
                        try {
                            if (a.isCast() && a.player != null && a.prepared) {
                                return Math.max(0, a.player.getCurrentPosition());
                            }
                        } catch (Exception ignored) {
                        }
                        return 0;
                    }

                    @Override
                    public int durationMs() {
                        try {
                            if (a.isCast() && a.player != null && a.prepared) {
                                return Math.max(0, a.player.getDuration());
                            }
                        } catch (Exception ignored) {
                        }
                        return 0;
                    }

                    @Override
                    public String transportState() {
                        if (!a.isCast() || a.current == null || !a.current.player) {
                            return "STOPPED";
                        }
                        if (!a.prepared) return "TRANSITIONING";
                        return a.playing ? "PLAYING" : "PAUSED_PLAYBACK";
                    }

                    @Override
                    public int getVolumePercent() {
                        if (audio == null) return 80;
                        try {
                            int max =
                                    Math.max(
                                            1,
                                            audio.getStreamMaxVolume(
                                                    android.media.AudioManager.STREAM_MUSIC));
                            int cur =
                                    audio.getStreamVolume(android.media.AudioManager.STREAM_MUSIC);
                            return Math.max(0, Math.min(100, Math.round(cur * 100f / max)));
                        } catch (Exception ignored) {
                            return 80;
                        }
                    }

                    @Override
                    public void setVolumePercent(int percent) {
                        if (audio == null) return;
                        a.ui.post(
                                () -> {
                                    try {
                                        int max =
                                                Math.max(
                                                        1,
                                                        audio.getStreamMaxVolume(
                                                                android.media.AudioManager
                                                                        .STREAM_MUSIC));
                                        int target =
                                                Math.round(
                                                        Math.max(0, Math.min(100, percent))
                                                                * max
                                                                / 100f);
                                        audio.setStreamVolume(
                                                android.media.AudioManager.STREAM_MUSIC,
                                                target,
                                                android.media.AudioManager.FLAG_SHOW_UI);
                                    } catch (Exception ignored) {
                                    }
                                });
                    }

                    @Override
                    public boolean isMuted() {
                        if (audio == null) return false;
                        try {
                            return audio.isStreamMute(android.media.AudioManager.STREAM_MUSIC);
                        } catch (Exception ignored) {
                            return getVolumePercent() == 0;
                        }
                    }

                    @Override
                    public void setMuted(boolean muted) {
                        if (audio == null) return;
                        a.ui.post(
                                () -> {
                                    try {
                                        audio.adjustStreamVolume(
                                                android.media.AudioManager.STREAM_MUSIC,
                                                muted
                                                        ? android.media.AudioManager.ADJUST_MUTE
                                                        : android.media.AudioManager.ADJUST_UNMUTE,
                                                android.media.AudioManager.FLAG_SHOW_UI);
                                    } catch (Exception ignored) {
                                    }
                                });
                    }

                    @Override
                    public void setSpeed(float speed) {
                        float clamped = Math.max(0.5f, Math.min(3.0f, speed));
                        a.ui.post(
                                () -> {
                                    if (a.player != null) {
                                        try {
                                            a.player.setSpeed(clamped);
                                            if (a.playerChrome != null) a.playerChrome.update();
                                        } catch (Exception ignored) {
                                        }
                                    }
                                });
                    }

                    @Override
                    public void onStatusChanged(String message) {
                        if (uiObserver != null) a.ui.post(uiObserver);
                    }

                    @Override
                    public void onClosed() {
                        Runnable unreg = nsdCleanup[0];
                        nsdCleanup[0] = null;
                        if (unreg != null) {
                            try {
                                unreg.run();
                            } catch (Throwable ignored) {
                            }
                        }
                        if (heldLock != null) {
                            try {
                                if (heldLock.isHeld()) heldLock.release();
                            } catch (Throwable ignored) {
                            }
                        }
                    }
                };

        CastService svc = startWithPreferredPort(uuid, name, lanIp, bridge);
        registerBonjour(a, svc, name, lanIp, uiObserver, nsdCleanup);
        return svc;
    }

    private static CastService startWithPreferredPort(
            String uuid, String name, String lanIp, Bridge bridge) throws IOException {
        int[] ports = {PREFERRED_HTTP_PORT, PREFERRED_HTTP_PORT + 1, 0};
        IOException last = null;
        for (int port : ports) {
            try {
                return new CastService(
                        uuid, name, lanIp, bridge, true, new InetSocketAddress("0.0.0.0", port));
            } catch (IOException err) {
                last = err;
            }
        }
        throw last != null ? last : new IOException("Unable to bind cast HTTP port");
    }

    private static void registerBonjour(
            MainActivity a,
            CastService svc,
            String name,
            String lanIp,
            Runnable uiObserver,
            Runnable[] cleanupSlot) {
        try {
            android.net.nsd.NsdManager nsd =
                    (android.net.nsd.NsdManager)
                            a.getApplicationContext()
                                    .getSystemService(android.content.Context.NSD_SERVICE);
            if (nsd == null) return;
            android.net.nsd.NsdServiceInfo info = new android.net.nsd.NsdServiceInfo();
            info.setServiceName(name);
            info.setServiceType(BONJOUR_SERVICE_TYPE);
            info.setPort(svc.httpPort());
            info.setAttribute("dlna", "/dlna/device.xml");
            info.setAttribute("uuid", svc.deviceUuid);
            if (lanIp != null && !lanIp.isEmpty()) info.setAttribute("ip", lanIp);
            android.net.nsd.NsdManager.RegistrationListener reg =
                    new android.net.nsd.NsdManager.RegistrationListener() {
                        @Override
                        public void onServiceRegistered(android.net.nsd.NsdServiceInfo s) {
                            svc.bonjourActive = true;
                            if (uiObserver != null) a.ui.post(uiObserver);
                        }

                        @Override
                        public void onRegistrationFailed(
                                android.net.nsd.NsdServiceInfo s, int err) {
                            svc.bonjourActive = false;
                        }

                        @Override
                        public void onServiceUnregistered(android.net.nsd.NsdServiceInfo s) {
                            svc.bonjourActive = false;
                        }

                        @Override
                        public void onUnregistrationFailed(
                                android.net.nsd.NsdServiceInfo s, int err) {}
                    };
            nsd.registerService(info, android.net.nsd.NsdManager.PROTOCOL_DNS_SD, reg);
            cleanupSlot[0] = () -> unregisterBonjour(nsd, reg);
        } catch (Throwable ignored) {
        }
    }

    private static void unregisterBonjour(
            android.net.nsd.NsdManager nsd, android.net.nsd.NsdManager.RegistrationListener reg) {
        try {
            nsd.unregisterService(reg);
        } catch (Throwable ignored) {
        }
    }
}
