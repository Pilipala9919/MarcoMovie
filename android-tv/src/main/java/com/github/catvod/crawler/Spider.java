package com.github.catvod.crawler;

import android.content.Context;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.IDN;
import java.net.InetAddress;
import java.net.Socket;
import java.net.UnknownHostException;
import java.security.SecureRandom;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.Callable;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorCompletionService;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import javax.net.ssl.HostnameVerifier;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;
import okhttp3.ConnectionPool;
import okhttp3.ConnectionSpec;
import okhttp3.Dispatcher;
import okhttp3.Dns;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;
import org.json.JSONArray;
import org.json.JSONObject;

/** Independently written host ABI from the operator-supplied plugin's public descriptors. */
public class Spider {
    public String siteKey = "";
    private String token = "";

    private static final String[] DEFAULT_DOH_ENDPOINTS = {
        "https://223.5.5.5/dns-query", "https://1.12.12.12/dns-query"
    };
    private static volatile String[] dohEndpoints = DEFAULT_DOH_ENDPOINTS;

    private static final int DNS_CACHE_MAX_ENTRIES = 512;
    private static final long MIN_DNS_TTL_SECONDS = 60L;
    private static final long MAX_DNS_TTL_SECONDS = 600L;
    private static final long DEFAULT_DNS_TTL_SECONDS = 300L;
    private static final long DOH_RACE_TIMEOUT_MS = 3500L;

    private static final ConcurrentHashMap<String, DnsCacheEntry> DNS_CACHE =
            new ConcurrentHashMap<>();

    private static final AtomicInteger DOH_THREAD_ID = new AtomicInteger(1);
    private static final ExecutorService DOH_EXECUTOR =
            Executors.newCachedThreadPool(
                    r -> {
                        Thread t =
                                new Thread(
                                        r, "marco-spider-doh-" + DOH_THREAD_ID.getAndIncrement());
                        t.setDaemon(true);
                        return t;
                    });

    private static final Dns SAFE_DNS = Spider::resolveSafeDns;

    private static final class DnsCacheEntry {
        final List<InetAddress> addresses;
        final long expiresAtNanos;

        DnsCacheEntry(List<InetAddress> addresses, long ttlSeconds) {
            this.addresses = Collections.unmodifiableList(new ArrayList<>(addresses));
            long clamped =
                    Math.max(MIN_DNS_TTL_SECONDS, Math.min(MAX_DNS_TTL_SECONDS, ttlSeconds));
            this.expiresAtNanos = System.nanoTime() + TimeUnit.SECONDS.toNanos(clamped);
        }

        boolean valid() {
            return System.nanoTime() - expiresAtNanos < 0;
        }
    }

    private static final class DohAnswer {
        final List<InetAddress> addresses;
        final long ttlSeconds;

        DohAnswer(List<InetAddress> addresses, long ttlSeconds) {
            this.addresses = addresses;
            this.ttlSeconds = ttlSeconds;
        }
    }

    private static final class DohClientHolder {
        static final OkHttpClient INSTANCE = buildDohClient();

        private static OkHttpClient buildDohClient() {
            Dispatcher dispatcher =
                    new Dispatcher(
                            Executors.newCachedThreadPool(
                                    r -> {
                                        Thread t = new Thread(r, "marco-doh-http");
                                        t.setDaemon(true);
                                        return t;
                                    }));
            dispatcher.setMaxRequests(32);
            dispatcher.setMaxRequestsPerHost(8);
            return new OkHttpClient.Builder()
                    .dispatcher(dispatcher)
                    .dns(Dns.SYSTEM)
                    .connectionPool(new ConnectionPool(4, 2, TimeUnit.MINUTES))
                    .connectTimeout(3, TimeUnit.SECONDS)
                    .readTimeout(3, TimeUnit.SECONDS)
                    .writeTimeout(3, TimeUnit.SECONDS)
                    .followRedirects(false)
                    .retryOnConnectionFailure(true)
                    .build();
        }
    }

    private static final class SharedClientHolder {
        static final OkHttpClient INSTANCE = buildSharedClient();

        private static OkHttpClient buildSharedClient() {
            Dispatcher dispatcher =
                    new Dispatcher(
                            Executors.newCachedThreadPool(
                                    r -> {
                                        Thread t = new Thread(r, "marco-spider-http");
                                        t.setDaemon(true);
                                        return t;
                                    }));
            dispatcher.setMaxRequests(64);
            dispatcher.setMaxRequestsPerHost(16);
            OkHttpClient.Builder builder =
                    new OkHttpClient.Builder()
                            .dispatcher(dispatcher)
                            .dns(safeDns())
                            .connectionPool(new ConnectionPool(16, 5, TimeUnit.MINUTES))
                            .connectTimeout(15, TimeUnit.SECONDS)
                            .readTimeout(30, TimeUnit.SECONDS)
                            .writeTimeout(30, TimeUnit.SECONDS)
                            .followRedirects(true)
                            .followSslRedirects(true)
                            .retryOnConnectionFailure(true)
                            .connectionSpecs(
                                    Arrays.asList(
                                            ConnectionSpec.MODERN_TLS,
                                            ConnectionSpec.COMPATIBLE_TLS,
                                            ConnectionSpec.CLEARTEXT));
            configureCompatibleSsl(builder);
            return builder.build();
        }
    }

    public Spider() {}

    public void initApi(SpiderApi api) {}

    public void init(Context context, String extend) throws Exception {
        init(context);
    }

    public void init(Context context) throws Exception {}

    public String homeContent(boolean filter) throws Exception {
        return "{}";
    }

    public String homeVideoContent() throws Exception {
        return "{\"list\":[]}";
    }

    public String categoryContent(
            String tid, String page, boolean filter, HashMap<String, String> extend)
            throws Exception {
        return "{\"list\":[]}";
    }

    public String detailContent(List<String> ids) throws Exception {
        return "{\"list\":[]}";
    }

    public String playerContent(String flag, String id, List<String> vipFlags) throws Exception {
        return "{}";
    }

    public String searchContent(String key, boolean quick) throws Exception {
        return "{\"list\":[]}";
    }

    public String searchContent(String key, boolean quick, String page) throws Exception {
        return searchContent(key, quick);
    }

    public String action(String action) throws Exception {
        return "";
    }

    public void destroy() {}

    public boolean isVideoFormat(String url) {
        return false;
    }

    public boolean manualVideoCheck() {
        return false;
    }

    public Object[] proxyLocal(Map<String, String> parameters) throws Exception {
        return null;
    }

    public Object[] proxy(Map<String, String> parameters) throws Exception {
        return proxyLocal(parameters);
    }

    public void cancelByTag() {}

    public String liveContent(String url) throws Exception {
        return "";
    }

    public String getToken() {
        return token;
    }

    public void setToken(String value) {
        token = value == null ? "" : value;
    }

    public static okhttp3.Dns safeDns() {
        return SAFE_DNS;
    }

    public static okhttp3.OkHttpClient client() {
        return SharedClientHolder.INSTANCE;
    }

    static void setDohEndpointsForTest(String... endpoints) {
        dohEndpoints =
                endpoints == null || endpoints.length == 0
                        ? DEFAULT_DOH_ENDPOINTS
                        : endpoints.clone();
        DNS_CACHE.clear();
    }

    static void clearDnsCacheForTest() {
        DNS_CACHE.clear();
    }

    private static List<InetAddress> resolveSafeDns(String hostname) throws UnknownHostException {
        if (hostname == null || hostname.trim().isEmpty()) {
            throw new UnknownHostException("hostname == null");
        }
        String trimmed = hostname.trim();
        if (shouldBypassDoh(trimmed)) {
            return Dns.SYSTEM.lookup(trimmed);
        }
        String asciiHost;
        try {
            String clean =
                    trimmed.endsWith(".") ? trimmed.substring(0, trimmed.length() - 1) : trimmed;
            asciiHost = IDN.toASCII(clean).toLowerCase(Locale.ROOT);
        } catch (Exception e) {
            return Dns.SYSTEM.lookup(trimmed);
        }
        if (asciiHost.isEmpty() || shouldBypassDoh(asciiHost)) {
            return Dns.SYSTEM.lookup(trimmed);
        }

        DnsCacheEntry cached = DNS_CACHE.get(asciiHost);
        if (cached != null) {
            if (cached.valid()) {
                return new ArrayList<>(cached.addresses);
            }
            DNS_CACHE.remove(asciiHost, cached);
        }

        String[] endpoints = dohEndpoints;
        if (endpoints != null && endpoints.length > 0) {
            DohAnswer won = raceDohEndpoints(asciiHost, trimmed, endpoints);
            if (won != null && !won.addresses.isEmpty()) {
                cacheDnsAnswer(asciiHost, won);
                return new ArrayList<>(won.addresses);
            }
        }
        return Dns.SYSTEM.lookup(trimmed);
    }

    private static void cacheDnsAnswer(String key, DohAnswer answer) {
        if (DNS_CACHE.size() >= DNS_CACHE_MAX_ENTRIES) {
            for (Iterator<Map.Entry<String, DnsCacheEntry>> it = DNS_CACHE.entrySet().iterator();
                    it.hasNext(); ) {
                if (!it.next().getValue().valid()) {
                    it.remove();
                }
            }
            if (DNS_CACHE.size() >= DNS_CACHE_MAX_ENTRIES) {
                Iterator<String> keys = DNS_CACHE.keySet().iterator();
                if (keys.hasNext()) {
                    DNS_CACHE.remove(keys.next());
                }
            }
        }
        DNS_CACHE.put(key, new DnsCacheEntry(answer.addresses, answer.ttlSeconds));
    }

    private static DohAnswer raceDohEndpoints(
            final String asciiHost, final String originalHost, final String[] endpoints) {
        byte[] wireQuery;
        try {
            wireQuery = buildDnsWireQuery(asciiHost, 1);
        } catch (Exception invalidHost) {
            return null;
        }
        final String dnsParam = base64UrlEncodeNoPad(wireQuery);
        ExecutorCompletionService<DohAnswer> completion =
                new ExecutorCompletionService<>(DOH_EXECUTOR);
        List<Future<DohAnswer>> futures = new ArrayList<>(endpoints.length);
        for (final String endpoint : endpoints) {
            if (endpoint == null || endpoint.trim().isEmpty()) continue;
            Callable<DohAnswer> task =
                    () -> querySingleDoh(endpoint.trim(), asciiHost, originalHost, dnsParam);
            try {
                futures.add(completion.submit(task));
            } catch (RuntimeException ignored) {
            }
        }
        if (futures.isEmpty()) return null;

        long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(DOH_RACE_TIMEOUT_MS);
        try {
            int remainingTasks = futures.size();
            while (remainingTasks > 0) {
                long waitMs = TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime());
                if (waitMs <= 0) break;
                Future<DohAnswer> done = completion.poll(waitMs, TimeUnit.MILLISECONDS);
                if (done == null) break;
                remainingTasks--;
                try {
                    DohAnswer answer = done.get();
                    if (answer != null && !answer.addresses.isEmpty()) {
                        return answer;
                    }
                } catch (ExecutionException ignored) {
                }
            }
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
        } finally {
            for (Future<DohAnswer> f : futures) {
                f.cancel(true);
            }
        }
        return null;
    }

    private static DohAnswer querySingleDoh(
            String endpoint, String asciiHost, String originalHost, String dnsParam)
            throws Exception {
        boolean allowLoopback = isLoopbackEndpoint(endpoint);
        String sep = endpoint.contains("?") ? "&" : "?";
        String url = endpoint + sep + "dns=" + dnsParam + "&name=" + asciiHost + "&type=A";
        Request request =
                new Request.Builder()
                        .url(url)
                        .header("Accept", "application/dns-message, application/dns-json;q=0.9")
                        .header("User-Agent", "okhttp/3.15")
                        .get()
                        .build();
        try (Response response = DohClientHolder.INSTANCE.newCall(request).execute()) {
            if (!response.isSuccessful()) return null;
            ResponseBody body = response.body();
            if (body == null) return null;
            byte[] payload = readBoundedBytes(body.byteStream(), 65536);
            if (payload.length == 0) return null;
            String contentType = response.header("Content-Type", "");
            return parseDohPayload(payload, contentType, originalHost, allowLoopback);
        }
    }

    static DohAnswer parseDohPayload(
            byte[] payload, String contentType, String originalHost, boolean allowLoopback)
            throws Exception {
        if (payload == null || payload.length == 0) return null;
        String ct = contentType == null ? "" : contentType.toLowerCase(Locale.ROOT);
        int firstNonWs = 0;
        while (firstNonWs < payload.length
                && Character.isWhitespace((char) (payload[firstNonWs] & 0xff))) {
            firstNonWs++;
        }
        if (ct.contains("json") || (firstNonWs < payload.length && payload[firstNonWs] == '{')) {
            return parseDohJson(new String(payload, "UTF-8"), originalHost, allowLoopback);
        }
        return parseDnsWireResponse(payload, originalHost, allowLoopback);
    }

    private static DohAnswer parseDohJson(
            String jsonText, String originalHost, boolean allowLoopback) throws Exception {
        JSONObject obj = new JSONObject(jsonText);
        if (obj.optInt("Status", 0) != 0) return null;
        JSONArray answers = obj.optJSONArray("Answer");
        if (answers == null || answers.length() == 0) return null;
        List<InetAddress> out = new ArrayList<>();
        long minTtl = Long.MAX_VALUE;
        for (int i = 0; i < answers.length(); i++) {
            JSONObject rec = answers.optJSONObject(i);
            if (rec == null) continue;
            int type = rec.optInt("type", 0);
            if (type != 1 && type != 28) continue;
            String data = rec.isNull("data") ? "" : String.valueOf(rec.opt("data")).trim();
            if (data.isEmpty() || !isIpLiteral(data)) continue;
            byte[] rawIp = InetAddress.getByName(data).getAddress();
            InetAddress addr = InetAddress.getByAddress(originalHost, rawIp);
            if (isUsableDohAddress(addr, allowLoopback)) {
                out.add(addr);
                long ttl = rec.optLong("TTL", DEFAULT_DNS_TTL_SECONDS);
                if (ttl > 0 && ttl < minTtl) minTtl = ttl;
            }
        }
        if (out.isEmpty()) return null;
        return new DohAnswer(out, minTtl == Long.MAX_VALUE ? DEFAULT_DNS_TTL_SECONDS : minTtl);
    }

    static byte[] buildDnsWireQuery(String asciiHost, int qtype) throws IOException {
        String[] labels = asciiHost.split("\\.");
        if (labels.length == 0) throw new IOException("Empty DNS host");
        ByteArrayOutputStream out = new ByteArrayOutputStream(64);
        // Header: ID=0 (RFC 8484 S4.1), Flags=0x0100 (RD=1), QDCOUNT=1
        out.write(0x00);
        out.write(0x00);
        out.write(0x01);
        out.write(0x00);
        out.write(0x00);
        out.write(0x01);
        out.write(0x00);
        out.write(0x00);
        out.write(0x00);
        out.write(0x00);
        out.write(0x00);
        out.write(0x00);
        for (String label : labels) {
            if (label.isEmpty() || label.length() > 63) {
                throw new IOException("Invalid DNS label");
            }
            byte[] bytes = label.getBytes("US-ASCII");
            out.write(bytes.length & 0xff);
            out.write(bytes);
        }
        out.write(0x00);
        out.write((qtype >> 8) & 0xff);
        out.write(qtype & 0xff);
        out.write(0x00);
        out.write(0x01);
        return out.toByteArray();
    }

    private static DohAnswer parseDnsWireResponse(
            byte[] msg, String originalHost, boolean allowLoopback) throws IOException {
        if (msg == null || msg.length < 12) return null;
        int flags = u16(msg, 2);
        if ((flags & 0x8000) == 0 || (flags & 0x000f) != 0) return null;
        int qdCount = u16(msg, 4);
        int anCount = u16(msg, 6);
        if (anCount <= 0) return null;
        int pos = 12;
        for (int q = 0; q < qdCount; q++) {
            pos = skipDnsName(msg, pos);
            if (pos < 0 || pos + 4 > msg.length) return null;
            pos += 4;
        }
        List<InetAddress> out = new ArrayList<>();
        long minTtl = Long.MAX_VALUE;
        for (int a = 0; a < anCount; a++) {
            pos = skipDnsName(msg, pos);
            if (pos < 0 || pos + 10 > msg.length) return null;
            int type = u16(msg, pos);
            int cls = u16(msg, pos + 2);
            long ttl = u32(msg, pos + 4);
            int rdLength = u16(msg, pos + 8);
            pos += 10;
            if (pos + rdLength > msg.length) return null;
            if (cls == 1 && ((type == 1 && rdLength == 4) || (type == 28 && rdLength == 16))) {
                byte[] rawIp = Arrays.copyOfRange(msg, pos, pos + rdLength);
                InetAddress addr = InetAddress.getByAddress(originalHost, rawIp);
                if (isUsableDohAddress(addr, allowLoopback)) {
                    out.add(addr);
                    if (ttl > 0 && ttl < minTtl) minTtl = ttl;
                }
            }
            pos += rdLength;
        }
        if (out.isEmpty()) return null;
        return new DohAnswer(out, minTtl == Long.MAX_VALUE ? DEFAULT_DNS_TTL_SECONDS : minTtl);
    }

    private static int skipDnsName(byte[] msg, int pos) {
        int steps = 0;
        while (pos < msg.length && steps++ < 128) {
            int len = msg[pos] & 0xff;
            if (len == 0) {
                return pos + 1;
            }
            if ((len & 0xc0) == 0xc0) {
                return pos + 2 <= msg.length ? pos + 2 : -1;
            }
            if ((len & 0xc0) != 0) {
                return -1;
            }
            pos += 1 + len;
        }
        return -1;
    }

    private static int u16(byte[] b, int offset) {
        return ((b[offset] & 0xff) << 8) | (b[offset + 1] & 0xff);
    }

    private static long u32(byte[] b, int offset) {
        return ((long) (b[offset] & 0xff) << 24)
                | ((long) (b[offset + 1] & 0xff) << 16)
                | ((long) (b[offset + 2] & 0xff) << 8)
                | ((long) (b[offset + 3] & 0xff));
    }

    private static boolean isUsableDohAddress(InetAddress address, boolean allowLoopback) {
        if (address == null || address.isAnyLocalAddress() || address.isMulticastAddress()) {
            return false;
        }
        if (!allowLoopback && address.isLoopbackAddress()) {
            return false;
        }
        byte[] raw = address.getAddress();
        if (raw.length == 4
                && (raw[0] & 0xff) == 255
                && (raw[1] & 0xff) == 255
                && (raw[2] & 0xff) == 255
                && (raw[3] & 0xff) == 255) {
            return false;
        }
        return true;
    }

    private static boolean isLoopbackEndpoint(String endpoint) {
        if (endpoint == null) return false;
        String lower = endpoint.toLowerCase(Locale.ROOT);
        String rest =
                lower.startsWith("http://")
                        ? lower.substring(7)
                        : lower.startsWith("https://") ? lower.substring(8) : "";
        return rest.startsWith("127.0.0.1")
                || rest.startsWith("localhost")
                || rest.startsWith("[::1]");
    }

    private static boolean shouldBypassDoh(String host) {
        String lower = host.toLowerCase(Locale.ROOT);
        if ("localhost".equals(lower)
                || lower.endsWith(".localhost")
                || lower.endsWith(".local")
                || lower.endsWith(".lan")
                || !lower.contains(".")) {
            return true;
        }
        return isIpLiteral(lower);
    }

    private static boolean isIpLiteral(String host) {
        if (host.contains(":")) return true;
        String[] parts = host.split("\\.", -1);
        if (parts.length != 4) return false;
        for (String part : parts) {
            if (part.isEmpty() || part.length() > 3) return false;
            int val = 0;
            for (int i = 0; i < part.length(); i++) {
                char c = part.charAt(i);
                if (c < '0' || c > '9') return false;
                val = val * 10 + (c - '0');
            }
            if (val > 255) return false;
        }
        return true;
    }

    static String base64UrlEncodeNoPad(byte[] input) {
        String alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        StringBuilder out = new StringBuilder((input.length * 4 + 2) / 3);
        for (int i = 0; i < input.length; i += 3) {
            int a = input[i] & 0xff;
            int b = i + 1 < input.length ? input[i + 1] & 0xff : 0;
            int c = i + 2 < input.length ? input[i + 2] & 0xff : 0;
            out.append(alphabet.charAt(a >> 2));
            out.append(alphabet.charAt(((a & 0x03) << 4) | (b >> 4)));
            if (i + 1 < input.length) {
                out.append(alphabet.charAt(((b & 0x0f) << 2) | (c >> 6)));
            }
            if (i + 2 < input.length) {
                out.append(alphabet.charAt(c & 0x3f));
            }
        }
        return out.toString();
    }

    static byte[] readBoundedBytes(InputStream in, int maxBytes) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = in.read(buf)) != -1) {
            if (out.size() + n > maxBytes) {
                throw new IOException("Response exceeds limit: " + maxBytes);
            }
            out.write(buf, 0, n);
        }
        return out.toByteArray();
    }

    private static void configureCompatibleSsl(OkHttpClient.Builder builder) {
        try {
            final X509TrustManager trustAll =
                    new X509TrustManager() {
                        @Override
                        public void checkClientTrusted(X509Certificate[] chain, String authType) {}

                        @Override
                        public void checkServerTrusted(X509Certificate[] chain, String authType) {}

                        @Override
                        public X509Certificate[] getAcceptedIssuers() {
                            return new X509Certificate[0];
                        }
                    };
            SSLContext sslContext = SSLContext.getInstance("TLS");
            sslContext.init(null, new TrustManager[] {trustAll}, new SecureRandom());
            SSLSocketFactory compatFactory =
                    new TlsCompatSocketFactory(sslContext.getSocketFactory());
            HostnameVerifier allowAllHost =
                    (hostname, session) -> hostname != null && !hostname.isEmpty();
            builder.sslSocketFactory(compatFactory, trustAll).hostnameVerifier(allowAllHost);
        } catch (Exception ignored) {
        }
    }

    private static final class TlsCompatSocketFactory extends SSLSocketFactory {
        private final SSLSocketFactory delegate;

        TlsCompatSocketFactory(SSLSocketFactory delegate) {
            this.delegate = delegate;
        }

        private Socket enableModernTls(Socket socket) {
            if (socket instanceof SSLSocket) {
                SSLSocket ssl = (SSLSocket) socket;
                List<String> supported = Arrays.asList(ssl.getSupportedProtocols());
                List<String> enabled = new ArrayList<>();
                for (String proto : new String[] {"TLSv1.3", "TLSv1.2", "TLSv1.1", "TLSv1"}) {
                    if (supported.contains(proto)) enabled.add(proto);
                }
                if (!enabled.isEmpty()) {
                    ssl.setEnabledProtocols(enabled.toArray(new String[0]));
                }
            }
            return socket;
        }

        @Override
        public String[] getDefaultCipherSuites() {
            return delegate.getDefaultCipherSuites();
        }

        @Override
        public String[] getSupportedCipherSuites() {
            return delegate.getSupportedCipherSuites();
        }

        @Override
        public Socket createSocket() throws IOException {
            return enableModernTls(delegate.createSocket());
        }

        @Override
        public Socket createSocket(Socket s, String host, int port, boolean autoClose)
                throws IOException {
            return enableModernTls(delegate.createSocket(s, host, port, autoClose));
        }

        @Override
        public Socket createSocket(String host, int port) throws IOException {
            return enableModernTls(delegate.createSocket(host, port));
        }

        @Override
        public Socket createSocket(String host, int port, InetAddress localHost, int localPort)
                throws IOException {
            return enableModernTls(delegate.createSocket(host, port, localHost, localPort));
        }

        @Override
        public Socket createSocket(InetAddress host, int port) throws IOException {
            return enableModernTls(delegate.createSocket(host, port));
        }

        @Override
        public Socket createSocket(
                InetAddress address, int port, InetAddress localAddress, int localPort)
                throws IOException {
            return enableModernTls(delegate.createSocket(address, port, localAddress, localPort));
        }
    }
}
