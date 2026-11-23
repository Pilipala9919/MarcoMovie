package com.pilipala.marcomovie;

import com.sun.net.httpserver.HttpServer;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Additional adversarial transport/content checks; local synthetic responses only. */
public final class MediaProbeBoundaryChecks {
    static int passed, failed;

    static void check(boolean value, String label) {
        System.out.println((value ? "PASS " : "FAIL ") + label);
        if (value) passed++;
        else failed++;
    }

    static String classify(String value, String mime) {
        byte[] b = value.getBytes(StandardCharsets.UTF_8);
        return MediaContentProbe.classify(b, b.length, mime);
    }

    public static void main(String[] args) throws Exception {
        check(
                classify("# access denied", "application/x-mpegURL") == null,
                "comment-like error does not become HLS from MIME");
        check(
                classify("#", "application/vnd.apple.mpegurl") == null,
                "partial first byte cannot select HLS early");
        check(
                classify("#EXTM3U", "application/x-mpegURL") == null,
                "split first line waits for delimiter");
        check(
                classify("#EXTM3UX invalid", "application/x-mpegURL") == null,
                "misleading MIME does not override invalid HLS magic");
        check(
                classify("#EXTM3U not-a-header\n", "application/x-mpegURL") == null,
                "first line does not accept arbitrary suffix text");
        check(
                MediaContentProbe.HLS.equals(classify("#EXTM3U\r\n", "audio/mpeg")),
                "complete CRLF HLS header overrides wrong MIME");
        check(
                MediaContentProbe.initialRangeLength("bytes 0-0/1") == 1,
                "single-byte range is valid");
        check(
                MediaContentProbe.initialRangeLength("bytes 0-511/*") == 512,
                "unknown total keeps legal initial range");
        check(
                MediaContentProbe.initialRangeLength("bytes 0-999999999999999999999999/*") == -1,
                "oversized end cannot overflow range length");
        check(
                MediaContentProbe.initialRangeLength("bytes 0-9223372036854775807/*") == -1,
                "maximum end cannot wrap length negative");
        check(
                MediaContentProbe.initialRangeLength("bytes 0-511/512") == 512,
                "inclusive end fits exact total");
        check(
                MediaContentProbe.initialRangeLength("bytes 0-512/512") == -1,
                "inclusive end cannot equal total");
        check(
                "audio/flac".equals(classify("fLaC", "application/x-mpegURL")),
                "FLAC container wins wrong playlist MIME");
        check(
                MediaContentProbe.BINARY.equals(classify("OggS", "application/x-mpegURL")),
                "Ogg remains generic container under wrong MIME");
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        ExecutorService workers = Executors.newCachedThreadPool();
        server.setExecutor(workers);
        AtomicInteger loops = new AtomicInteger(), calls = new AtomicInteger();
        CountDownLatch entered = new CountDownLatch(1), release = new CountDownLatch(1);
        server.createContext(
                "/",
                x -> {
                    calls.incrementAndGet();
                    String path = x.getRequestURI().getPath();
                    try {
                        if (path.equals("/loop")) {
                            loops.incrementAndGet();
                            x.getResponseHeaders().set("Location", "/loop");
                            x.sendResponseHeaders(302, -1);
                            return;
                        }
                        byte[] body = "#EXTM3U\n#EXT-X-ENDLIST\n".getBytes(StandardCharsets.UTF_8);
                        if (path.equals("/slow")) {
                            x.getResponseHeaders().set("Content-Type", "application/octet-stream");
                            x.sendResponseHeaders(200, 100);
                            x.getResponseBody().write('a');
                            x.getResponseBody().flush();
                            entered.countDown();
                            try {
                                release.await(5, TimeUnit.SECONDS);
                            } catch (InterruptedException e) {
                                Thread.currentThread().interrupt();
                            }
                            return;
                        }
                        x.getResponseHeaders().set("Content-Type", "application/octet-stream");
                        x.getResponseHeaders()
                                .set(
                                        "Content-Range",
                                        path.equals("/invalid-total")
                                                ? "bytes 0-99/10"
                                                : path.equals("/zero-total")
                                                        ? "bytes 0-0/0"
                                                        : "bytes 0-"
                                                                + (body.length - 1)
                                                                + "/"
                                                                + body.length);
                        x.sendResponseHeaders(
                                path.equals("/ignored-range") ? 200 : 206, body.length);
                        x.getResponseBody().write(body);
                    } finally {
                        x.close();
                    }
                });
        server.start();
        String root = "http://127.0.0.1:" + server.getAddress().getPort();
        Map<String, String> headers = new HashMap<>();
        try {
            check(
                    MediaContentProbe.probe(new URL(root + "/invalid-total"), headers, "test", null)
                            == null,
                    "206 range end must fit total length");
            check(
                    MediaContentProbe.probe(new URL(root + "/zero-total"), headers, "test", null)
                            == null,
                    "206 zero total is not a usable range");
            check(
                    MediaContentProbe.HLS.equals(
                            MediaContentProbe.probe(
                                    new URL(root + "/ignored-range"), headers, "test", null)),
                    "200 ignoring Range still supports bounded manifest read");
            check(
                    MediaContentProbe.probe(new URL(root + "/loop"), headers, "test", null) == null
                            && loops.get() == 4,
                    "redirect loop has exactly three followups");
            headers.put("Range", "bytes=0-10,20-30");
            int before = calls.get();
            check(
                    MediaContentProbe.probe(new URL(root + "/clip.iso"), headers, "test", null)
                                    == null
                            && calls.get() == before,
                    "multi-range is not rewritten or probed");
            headers.clear();
            RequestScope scope = new RequestScope();
            ExecutorService client = Executors.newSingleThreadExecutor();
            try {
                Future<String> pending =
                        client.submit(
                                () ->
                                        scope.call(
                                                () ->
                                                        MediaContentProbe.probe(
                                                                new URL(root + "/slow"),
                                                                headers,
                                                                "test",
                                                                scope)));
                check(
                        entered.await(3, TimeUnit.SECONDS),
                        "active probe reached controlled response");
                scope.cancel();
                check(
                        pending.get(3, TimeUnit.SECONDS) == null,
                        "active request cancellation returns without a type");
                check(scope.connections.isEmpty(), "cancelled connection detached from scope");
            } finally {
                release.countDown();
                client.shutdownNow();
            }
        } finally {
            release.countDown();
            server.stop(0);
            workers.shutdownNow();
        }
        System.out.println("RESULT passed=" + passed + " failed=" + failed);
        if (failed > 0) throw new AssertionError("boundary failures " + failed);
    }
}
