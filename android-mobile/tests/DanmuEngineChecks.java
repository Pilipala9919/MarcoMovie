// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import com.pilipala.marcomovie.DanmuProvider.BlockFilter;
import com.pilipala.marcomovie.DanmuProvider.Candidate;
import com.pilipala.marcomovie.DanmuProvider.CancellationToken;
import com.pilipala.marcomovie.DanmuProvider.DanmuItem;
import com.pilipala.marcomovie.DanmuProvider.EpisodeSession;
import com.pilipala.marcomovie.DanmuProvider.HttpStatusException;
import com.pilipala.marcomovie.DanmuProvider.MatchQuery;
import com.pilipala.marcomovie.DanmuSegmentCache.ActiveSlot;
import com.pilipala.marcomovie.DanmuSegmentCache.FramePacingMonitor;
import com.pilipala.marcomovie.DanmuSegmentCache.LayoutEngine;
import com.pilipala.marcomovie.DanmuSegmentCache.SmoothClock;
import com.pilipala.marcomovie.DanmuSegmentCache.TextWidthMeasurer;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Standalone pure-JVM + local loopback (127.0.0.1) verification suite for Wave 1 M3a segmented
 * danmu protocol, caching, HTTP 410 singleflight refresh, seek debounce, ReDoS protection,
 * collision-free linear kinematics layout, and Android TV P90 adaptive lane degradation.
 */
public final class DanmuEngineChecks {

    private static final Charset UTF_8 = Charset.forName("UTF-8");
    private static int passed = 0;

    private static ExecutorService daemonPool(int threads) {
        return Executors.newFixedThreadPool(
                threads,
                new ThreadFactory() {
                    @Override
                    public Thread newThread(Runnable r) {
                        Thread t = new Thread(r, "danmu-test-http");
                        t.setDaemon(true);
                        return t;
                    }
                });
    }

    private static void check(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError("FAIL: " + message);
        }
        passed++;
        System.out.println("PASS: " + message);
    }

    private static void sendResponse(HttpExchange ex, int status, String contentType, String body)
            throws IOException {
        byte[] bytes = body.getBytes(UTF_8);
        ex.getResponseHeaders().set("Content-Type", contentType);
        ex.sendResponseHeaders(status, bytes.length);
        try (OutputStream os = ex.getResponseBody()) {
            os.write(bytes);
        }
    }

    public static void main(String[] args) throws Exception {
        testDefaultEmptyServerAndCrypto();
        testSourceBindingAndSsrfWhitelist();
        testBlockFilterAndReDoS();
        testCollisionFreeLinearKinematics();
        testTvP90AdaptiveDegradation();
        testSpeedBoostMonotonicReAnchorAndModePurge();
        testLocalHttpProtocolAndFullEpisodeFallback();
        testBoundaryContinuityNegativeOffsetAndPinning();
        testConcurrent410SingleflightAndCap();
        testSeekStormDebounceAndCancellation();
        testRateLimitingAnd429RetryAfter();
        testTvPerFrameZeroRepeatFilterAndZeroAllocPast64Min();
        System.out.println("ALL DANMU ENGINE CHECKS PASSED (" + passed + " assertions)");
    }

    private static void testDefaultEmptyServerAndCrypto() throws Exception {
        DandanplayProvider def = new DandanplayProvider();
        check(
                DandanplayProvider.DEFAULT_SERVER_URLS.isEmpty(),
                "Default server URL constant is empty string");
        check(
                def.getConfiguredOrigins().isEmpty(),
                "Default DandanplayProvider has zero configured origins");

        // RFC 4648 Base64url no-padding roundtrip across lengths 0..6 and URL-unsafe bytes
        byte[][] samples =
                new byte[][] {
                    new byte[0],
                    new byte[] {(byte) 0xFB},
                    new byte[] {(byte) 0xFB, (byte) 0xFF},
                    new byte[] {(byte) 0xFB, (byte) 0xFF, (byte) 0xBF},
                    "https://danmu.example:8443/v2".getBytes(UTF_8),
                    "a+b/c=d?e&f".getBytes(UTF_8)
                };
        for (byte[] sample : samples) {
            String enc = DandanplayProvider.base64UrlEncodeNoPad(sample);
            check(!enc.contains("="), "Base64url has no padding '=' for len=" + sample.length);
            check(!enc.contains("+") && !enc.contains("/"), "Base64url uses - and _ alphabet");
            byte[] dec = DandanplayProvider.base64UrlDecode(enc);
            check(Arrays.equals(sample, dec), "Base64url roundtrip len=" + sample.length);
        }

        // SHA-256 standard vector for "abc"
        byte[] abcHash = DandanplayProvider.sha256("abc".getBytes(UTF_8));
        StringBuilder hex = new StringBuilder();
        for (byte b : abcHash) {
            hex.append(String.format("%02x", b & 0xFF));
        }
        check(
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
                        .equals(hex.toString()),
                "SHA-256 matches FIPS 180-4 test vector for 'abc'");

        // Standard Base64 of SHA-256 signature
        String sig =
                DandanplayProvider.computeOpenApiSignature(
                        "demoApp", 1700000000L, "/api/v2/match", "demoSecret");
        check(
                sig.length() == 44 && sig.endsWith("="),
                "Open API v2 signature is padded Base64 SHA-256");
    }

    private static void testSourceBindingAndSsrfWhitelist() throws Exception {
        String origin = "https://node-a.danmu.test:8443/prefix/";
        String normalized = DandanplayProvider.normalizeOriginOrNull(origin);
        check(
                "https://node-a.danmu.test:8443/prefix".equals(normalized),
                "Origin normalization strips trailing slash");

        String bound = DandanplayProvider.encodeBoundEpisodeId(origin, "ep+42/sub");
        check(bound.startsWith("mmdanmu://v1?src="), "Bound URI uses mmdanmu://v1 scheme");
        check(!bound.contains("=" + "&"), "src param has no base64 padding");

        List<String> whitelist = Collections.singletonList("https://node-a.danmu.test:8443/prefix");
        DandanplayProvider.BoundEpisode decoded =
                DandanplayProvider.decodeBoundEpisodeId(bound, whitelist);
        check(
                "https://node-a.danmu.test:8443/prefix".equals(decoded.origin)
                        && "ep+42/sub".equals(decoded.rawEpisodeId),
                "SourceBoundEpisodeId roundtrip preserves origin and literal '+' in episodeId");

        // SSRF whitelist rejection: unlisted host
        boolean rejectedUnlisted = false;
        try {
            String evilBound =
                    DandanplayProvider.encodeBoundEpisodeId("https://evil.invalid", "1001");
            DandanplayProvider.decodeBoundEpisodeId(evilBound, whitelist);
        } catch (IOException expected) {
            rejectedUnlisted = true;
        }
        check(rejectedUnlisted, "SSRF guard rejects unlisted host in mmdanmu://v1");

        // SSRF scheme & userinfo rejection
        check(
                DandanplayProvider.normalizeOriginOrNull("file:///etc/passwd") == null,
                "Origin normalizer rejects file:// scheme");
        check(
                DandanplayProvider.normalizeOriginOrNull("ftp://danmu.example") == null,
                "Origin normalizer rejects ftp:// scheme");
        check(
                DandanplayProvider.normalizeOriginOrNull("https://user@danmu.example") == null
                        && DandanplayProvider.normalizeOriginOrNull(
                                        "https" + "://u:p@danmu.example")
                                == null,
                "Origin normalizer rejects userinfo credentials");
        check(
                DandanplayProvider.normalizeOriginOrNull("http://danmu.example/a b") == null
                        && DandanplayProvider.normalizeOriginOrNull("http://bad_host.test") == null,
                "Origin normalizer rejects raw spaces and underscore hostnames");

        // IPv6 origin normalization & bound episode roundtrip
        String httpProto = "http";
        String httpsProto = "https";
        String ipv6Port =
                DandanplayProvider.normalizeOriginOrNull(httpProto + "://[::1]:8080/path/");
        check(
                (httpProto + "://[::1]:8080/path").equals(ipv6Port)
                        && java.net.URI.create(ipv6Port).getPort() == 8080,
                "IPv6 origin normalization preserves brackets, port and path");
        String ipv6HttpsDefault =
                DandanplayProvider.normalizeOriginOrNull(httpsProto + "://[2001:DB8::1]:443/api/");
        check(
                (httpsProto + "://[2001:db8::1]/api").equals(ipv6HttpsDefault),
                "IPv6 origin normalization lowercases hex and strips default 443 port");
        check(
                (httpProto + "://[::1]")
                                .equals(
                                        DandanplayProvider.normalizeOriginOrNull(
                                                httpProto + "://[::1]:80"))
                        && (httpProto + "://[::1]")
                                .equals(
                                        DandanplayProvider.normalizeOriginOrNull(
                                                httpProto + "://[::1]")),
                "IPv6 loopback origin normalizes cleanly with and without default port 80");
        String ipv6Bound = DandanplayProvider.encodeBoundEpisodeId(ipv6Port, "ep-v6");
        DandanplayProvider.BoundEpisode ipv6Decoded =
                DandanplayProvider.decodeBoundEpisodeId(
                        ipv6Bound, Collections.singletonList(ipv6Port));
        check(
                ipv6Port.equals(ipv6Decoded.origin) && "ep-v6".equals(ipv6Decoded.rawEpisodeId),
                "IPv6 SourceBoundEpisodeId roundtrip succeeds");

        // Cap at 8 servers
        String tenUrls =
                String.join(
                        "\n",
                        "https://s1.danmu.test",
                        "https://s2.danmu.test",
                        "https://s3.danmu.test",
                        "https://s4.danmu.test",
                        "https://s5.danmu.test",
                        "https://s6.danmu.test",
                        "https://s7.danmu.test",
                        "https://s8.danmu.test",
                        "https://s9.danmu.test",
                        "https://s10.danmu.test");
        check(
                DandanplayProvider.parseConfiguredOrigins(tenUrls).size() == 8,
                "Configured origins capped at 8 servers");
    }

    private static void testBlockFilterAndReDoS() {
        // Must reject catastrophic & high-polynomial backtracking (100% parity vector with Dart)
        String[] rejected =
                new String[] {
                    // Report bypasses (ungrouped adjacent quantifiers)
                    "re:a+a+a+a+a+a+a+a+b",
                    "re:[^x]*[^x]*[^x]*[^x]*[^x]*[^x]*[^x]*b",
                    // Additional ungrouped / chained / hidden-group / alternation adversarial rules
                    "re:a+a+b",
                    "re:a+a+a+a+b",
                    "re:[^x]*[^x]*[^x]*b",
                    "re:\\w+\\w+\\w+\\w+!",
                    "re:\\d+\\d+\\d+\\d+x",
                    "re:[a-z]{1,10}[a-z]{1,10}[a-z]{1,10}[a-z]{1,10}z",
                    "re:a+b?a+b?a+c",
                    "re:(?:a+)(?:a+)(?:a+)b",
                    "re:a+.*a+.*a+b",
                    "re:.*.*b",
                    "re:(?:a|aa)+$",
                    "re:(a|a)(a|a)(a|a)(a|a)(a|a)(a|a)(a|a)(a|a)(a|a)(a|a)b",
                    "re:(a|ab)(a|ab)(a|ab)(a|ab)(a|ab)(a|ab)(a|ab)(a|ab)(a|ab)(a|ab)b",
                    "re:a?a?a?a?a?a?a?a?a?a?b",
                    "re:a++",
                    "re:a+*",
                    "re:a??",
                    "re:a*?+",
                    "re:a{1,2}*",
                    "re:(?=a)b",
                    "re:(?!a)b",
                    "re:\\k<x>",
                    "re:^+a",
                    "re:$+",
                    "re:\\b+a",
                    "re:a{1,65}",
                    "re:a{0}",
                    "re:[a-z]{1,20}[a-z]{1,20}z",
                    "re:[a-z]{1,30}[a-z]{1,30}z",
                    "re:(a|a)(a|a)(a|a)(a|a)(a|a)(a|a)z",
                    "re:a+z|a+z|a+z|a+z",
                    "re:a.*b|c.*d|e.*f|g.*h",
                    // Gate 1 R1 F-1A ({N}/literal suffix amplification & Cartesian alternation)
                    "re:a+a{30}a{30}b|a+a{30}a{30}b|a+a{30}a{30}b",
                    "re:[a-z]{1,5}[a-z]{1,5}a{60}b|[a-z]{1,5}[a-z]{1,5}a{60}b|[a-z]{1,5}[a-z]{1,5}a{60}b|[a-z]{1,5}[a-z]{1,5}a{60}b",
                    "re:([a-z]|[a-z]|[a-z])[a-z]+[a-z]{60}b",
                    "re:[a-z]+[a-z]{1,3}[a-z]{60}b",
                    "re:[a-z]*?[a-z]{1,3}?[a-z]{60}b",
                    "re:(a|a|a)a+a{60}b",
                    "re:a+" + repeatChar('a', 110) + "b",
                    "re:(a|aa)(a|aa)(a|aa)(a|aa)(a|aa)Z",
                    "re:[^x]*[a-z]{0,2}y",
                    "re:[a-z]{1,5}[a-z]{1,5}z",
                    "re:(a|a|a)[a-z]+z",
                    // Gate 1 R2 F-1D (prefix chains, TwoByte 3-branch unbounded & bounded spikes)
                    "re:a{20}a{20}a{20}a{20}a+b",
                    "re:a{20}a+x|a{20}a+y|a{20}a+z",
                    "re:[^x]{20}[^x]{20}[^x]{20}[^x]{20}[^x]+y|[^x]{20}[^x]{20}[^x]{20}[^x]{20}[^x]+z",
                    "re:[a-z]{20}[a-z]{20}[a-z]{20}[a-z]{15}[a-z]+[a-z]{2}z",
                    "re:[a-z]+z|[a-z]+z|[a-z]+z",
                    "re:[a-z]{1,4}[a-z]{1,4}[a-z]{3}z|[a-z]{1,3}[a-z]{1,3}[a-z]{6}z",
                    "re:(a|aa|aaa|aaaa)(a|aa|aaa|aaaa)[a-z]{3}z|(a|aa|aaa)(a|aa|aaa)z",
                    "re:a+a{15}b",
                    "re:[a-z]+[a-z]{6}z",
                    "re:.*aaaaaaaaab",
                    "re:.*ababababax",
                    "re:a.*b|c.*d|e.*f",
                    // Gate 1 R3 F-1F (non-ASCII case-folded literal delimiter & suffix bucketing)
                    "re:\u00E9+\u00C9.*z",
                    "re:\u0151+\u0150.*z",
                    "re:\u03B1+\u0391.*z",
                    "re:\u03B1+\u0391[^\\n]*z",
                    "re:.*\u00E9\u00C9\u00E9\u00C9\u00E9\u00C9\u00E9\u00C9\u00E9z",
                    // Gate 1 R1 F-1B (UTF-16 surrogates / supplementary codepoints parity)
                    "re:[\uD83D\uDE00-\\uFFFF]",
                    "re:[\\uD83D\\uDE00-\\uFFFF]",
                    "re:[\uD83D\uDE00-\uFF5E]",
                    "re:\uD83D\uDE00",
                    // Gate 1 R1 F-1C (Java vs Dart whitespace trimming parity)
                    "\u3000",
                    "re:\u3000",
                    "\u3000re:(a|aa)+$",
                    "\u00A0re:(a|aa)+$",
                    "\uFEFFre:(a|aa)+$",
                    "\u0000re:(a|aa)+$",
                    "\u001Fre:(a|aa)+$",
                    "re:\\Qfoo\\E",
                    "re:[a[b]]",
                    "re:[a-z&&[^bc]]",
                    "re:[]a]",
                    "re:a||b",
                    "re:()a",
                    // Existing spec rejection suite
                    "re:(a|aa)+$",
                    "re:(a+)+",
                    "re:(a?)+",
                    "re:(.*a){20}",
                    "re:([a-z]|a)+$",
                    "re:(foo)?",
                    "re:(bar)*",
                    "re:([0-9]+){2,5}",
                    "re:abc\\1",
                    "re:(?<=pre)word",
                    "re:(?<!pre)word",
                    "re:(?i)spoiler",
                    "re:a.*b.*c.*d.*e",
                    "re:" + repeatChar('a', 121),
                    "re:",
                    "   "
                };
        for (String rule : rejected) {
            BlockFilter.ValidationResult vr = BlockFilter.validateRule(rule);
            check(!vr.valid, "ReDoS validator rejects unsafe rule: " + rule);
        }

        // Must accept safe plain text, top-level alternation, non-quantified groups, char class
        // quantifiers, and worst-case in-budget patterns
        String[] accepted =
                new String[] {
                    "剧透",
                    "\uD83D\uDE00",
                    "re:剧透|打卡",
                    "re:第(一|二)章",
                    "re:(第|共)(一|二|三)章",
                    "re:[0-9]{4,}",
                    "re:foo\\)bar+",
                    "re:foo.*bar",
                    "re:剧透.+结局",
                    "re:.*剧透预警",
                    "re:\\s+keyword",
                    "re:[a-z]+\\.com",
                    "re:第\\d+集.*剧透预警",
                    "re:广告.*链接",
                    "re:(微信|QQ|VX)\\d{5,}",
                    "re:https?://[a-z0-9.-]+",
                    "re:a.*b|c.*d",
                    "re:^前排|沙发$",
                    "re:[a-z]{1,4}[0-9]{1,4}",
                    "re:(a|aa)(a|aa)z",
                    "re:[a-z]+z|[a-z]+z",
                    "re:(a|a)[a-z]+z",
                    "re:[a-z]+[a-z]{2}z",
                    "re:[^x]{20}[^x]+y|[^x]{20}[^x]+z",
                    "re:剧+透.*预警",
                    "re:(?:foo|bar).*?z"
                };
        String[] adversarialInputs =
                new String[] {
                    repeatChar('a', 179) + "!",
                    repeatChar('a', 179) + "\u4e00",
                    repeatChar('\u0150', 179) + "!",
                    repeatChar('\u4e00', 179) + "!",
                    repeatChar('1', 179) + "!"
                };
        for (String rule : accepted) {
            BlockFilter.ValidationResult vr = BlockFilter.validateRule(rule);
            check(vr.valid, "ReDoS validator accepts safe rule: " + rule + " (" + vr.error + ")");
            BlockFilter single = BlockFilter.compile(Collections.singletonList(rule));
            double maxCallMs = 0.0;
            for (String sample : adversarialInputs) {
                for (int run = 0; run < 6; run++) {
                    long t0 = System.nanoTime();
                    single.isBlocked(sample);
                    double ms = (System.nanoTime() - t0) / 1_000_000.0;
                    if (ms > maxCallMs) maxCallMs = ms;
                }
            }
            check(
                    maxCallMs < 5.0,
                    "Accepted rule completes < 5ms across OneByte & TwoByte 180-char inputs (max="
                            + String.format(java.util.Locale.US, "%.3f", maxCallMs)
                            + "ms): "
                            + rule);
        }

        List<String> rules = new ArrayList<>();
        rules.add("Spoiler");
        rules.add("re:第(一|二)章");
        rules.add("re:(a|aa)+$"); // silently skipped by compile
        BlockFilter filter = BlockFilter.compile(rules);
        check(filter.ruleCount() == 2, "BlockFilter compiles only valid rules");
        check(filter.isBlocked("huge SPOILER alert"), "Plain substring filter is case-insensitive");
        check(filter.isBlocked("请看第二章内容"), "Safe regex group matches correctly");
        check(!filter.isBlocked("普通弹幕内容"), "Non-matching comment passes filter");

        // 100-rule cap
        List<String> manyRules = new ArrayList<>();
        for (int i = 0; i < 130; i++) manyRules.add("word" + i);
        check(
                BlockFilter.compile(manyRules).ruleCount() == 100,
                "BlockFilter enforces 100-rule maximum");
    }

    private static void testCollisionFreeLinearKinematics() {
        LayoutEngine engine = new LayoutEngine();
        final float viewW = 1920f;
        final long duration = 7600L;

        // Fast long danmu immediately after short slower danmu must NOT share lane 0
        int laneSlow = engine.allocateScrollLane(0L, viewW, 80f, duration, 6);
        int laneFast = engine.allocateScrollLane(500L, viewW, 700f, duration, 6);
        check(
                laneSlow == 0 && laneFast == 1,
                "Fast long danmu avoids overtaking slow danmu on lane 0");

        // Stress sweep: 80 mixed-width danmu over 6 lanes, verify >= 24px clearance at ALL times
        engine.reset();
        List<DanmuItem> burst = new ArrayList<>();
        for (int i = 0; i < 80; i++) {
            String text = repeatChar('弹', 2 + (i % 18));
            burst.add(new DanmuItem("b_" + i, i * 180L, 1, 0xFFFFFF, text));
        }
        TextWidthMeasurer fixedMeasurer =
                new TextWidthMeasurer() {
                    @Override
                    public float measureWidth(String text) {
                        return text.length() * 28f;
                    }
                };
        int maxObservedActive = 0;
        for (long t = 0L; t <= 16000L; t += 100L) {
            int active =
                    engine.step(
                            t,
                            burst,
                            1920,
                            1080,
                            24f,
                            0f,
                            44f,
                            0.50f,
                            6,
                            48,
                            duration,
                            true,
                            true,
                            true,
                            fixedMeasurer);
            if (active > maxObservedActive) maxObservedActive = active;
            ActiveSlot[] slots = engine.getSlots();
            for (int i = 0; i < slots.length; i++) {
                ActiveSlot a = slots[i];
                if (!a.active || a.mode != 1) continue;
                for (int j = i + 1; j < slots.length; j++) {
                    ActiveSlot b = slots[j];
                    if (!b.active || b.mode != 1 || a.lane != b.lane) continue;
                    ActiveSlot left = a.x <= b.x ? a : b;
                    ActiveSlot right = a.x <= b.x ? b : a;
                    float gap = right.x - (left.x + left.widthPx);
                    if (gap < 23.5f) {
                        throw new AssertionError(
                                "Collision on lane "
                                        + a.lane
                                        + " at t="
                                        + t
                                        + ": gap="
                                        + gap
                                        + "px");
                    }
                }
            }
        }
        check(
                maxObservedActive > 0 && maxObservedActive <= 48,
                "Dense 80-item burst maintained >= 24px clearance across all timestamps (peak active="
                        + maxObservedActive
                        + ")");

        // Pinned top/bottom 4000ms exclusivity & bottom safe inset
        engine.reset();
        List<DanmuItem> pinned =
                Arrays.asList(
                        new DanmuItem("t1", 1000L, 5, 0xFFFFFF, "顶部一"),
                        new DanmuItem("t2", 2000L, 5, 0xFFFFFF, "顶部二"),
                        new DanmuItem("bot1", 1000L, 4, 0xFFFFFF, "底部一"));
        engine.step(
                2500L,
                pinned,
                1920,
                1080,
                24f,
                0f,
                80f,
                0.50f,
                6,
                48,
                duration,
                true,
                true,
                true,
                fixedMeasurer);
        float bottomY = -1f;
        int topLane1 = -1;
        int topLane2 = -1;
        for (ActiveSlot s : engine.getSlots()) {
            if (!s.active) continue;
            if ("t1".equals(s.id)) topLane1 = s.lane;
            if ("t2".equals(s.id)) topLane2 = s.lane;
            if ("bot1".equals(s.id)) bottomY = s.y;
        }
        check(topLane1 == 0 && topLane2 == 1, "Top pinned danmu stack without overlap");
        check(
                bottomY > 0f && bottomY <= 1080f - 80f,
                "Bottom pinned danmu respects bottomSafeInset");
    }

    private static void testTvP90AdaptiveDegradation() {
        FramePacingMonitor mon = new FramePacingMonitor(6);
        check(
                mon.getEffectiveMaxRows() == 6 && mon.getEffectiveMaxItems() == 48,
                "TV monitor starts at 6 rows / 48 items");

        // 1 window of 22ms (> 20ms) should NOT degrade yet (needs 2 consecutive windows)
        for (int i = 0; i < 30; i++) mon.recordFrameIntervalMs(22.0);
        check(mon.getEffectiveMaxRows() == 6, "1 high-latency window does not prematurely degrade");

        // 2nd consecutive window of 22ms -> degrades by 2 rows to 4
        for (int i = 0; i < 30; i++) mon.recordFrameIntervalMs(22.0);
        check(mon.getEffectiveMaxRows() == 4, "2 consecutive windows > 20ms degrade 6 -> 4 rows");

        // 2 more windows of 25ms -> degrades to floor 2 rows / 20 items
        for (int i = 0; i < 60; i++) mon.recordFrameIntervalMs(25.0);
        check(
                mon.getEffectiveMaxRows() == 2 && mon.getEffectiveMaxItems() == 20,
                "Further high-latency degrades to floor 2 rows / 20 items");

        // Extra high-latency never drops below 2 rows
        for (int i = 0; i < 60; i++) mon.recordFrameIntervalMs(30.0);
        check(mon.getEffectiveMaxRows() == 2, "Floor stays clamped at minRows = 2");

        // 180 frames (6 windows) with P90 < 15.5ms recovers +1 row (2 -> 3)
        for (int i = 0; i < 180; i++) mon.recordFrameIntervalMs(14.0);
        check(
                mon.getEffectiveMaxRows() == 3,
                "180 consecutive frames < 15.5ms recover +1 row (2 -> 3)");

        // Adaptive row-cap steps (6 -> 4 -> 5) must NOT reset or teleport already in-flight danmu!
        LayoutEngine engine = new LayoutEngine();
        TextWidthMeasurer measurer =
                new TextWidthMeasurer() {
                    @Override
                    public float measureWidth(String text) {
                        return 200f;
                    }
                };
        List<DanmuItem> initialWave = new ArrayList<>();
        for (int i = 0; i < 6; i++) {
            initialWave.add(new DanmuItem("lane_" + i, 1000L, 1, 0xFFFFFF, "弹幕" + i));
        }
        engine.step(
                1200L,
                initialWave,
                1920,
                1080,
                24f,
                0f,
                44f,
                0.50f,
                6,
                48,
                8200L,
                true,
                true,
                true,
                measurer);
        int lane4Before = -1;
        int lane5Before = -1;
        float x4Before = -1f;
        for (ActiveSlot s : engine.getSlots()) {
            if (!s.active) continue;
            if ("lane_4".equals(s.id)) {
                lane4Before = s.lane;
                x4Before = s.x;
            }
            if ("lane_5".equals(s.id)) lane5Before = s.lane;
        }
        check(lane4Before == 4 && lane5Before == 5, "Initial 6-row wave fills lanes 0..5");

        // Degrade rowCap 6 -> 4 and admit a new comment wave; in-flight lanes 4 & 5 keep exact
        // lanes
        List<DanmuItem> wave2 = new ArrayList<>(initialWave);
        wave2.add(new DanmuItem("after_degrade", 2600L, 1, 0xFFFFFF, "降级后新弹幕"));
        engine.step(
                2700L, wave2, 1920, 1080, 24f, 0f, 44f, 0.50f, 4, 32, 8200L, true, true, true,
                measurer);
        int lane4After = -1;
        int lane5After = -1;
        float x4After = -1f;
        int newAfterDegradeLane = -1;
        for (ActiveSlot s : engine.getSlots()) {
            if (!s.active) continue;
            if ("lane_4".equals(s.id)) {
                lane4After = s.lane;
                x4After = s.x;
            }
            if ("lane_5".equals(s.id)) lane5After = s.lane;
            if ("after_degrade".equals(s.id)) newAfterDegradeLane = s.lane;
        }
        check(
                lane4After == 4 && lane5After == 5 && x4After < x4Before,
                "P90 degradation 6->4 keeps in-flight lanes 4 & 5 intact without teleporting");
        check(
                newAfterDegradeLane >= 0 && newAfterDegradeLane < 4,
                "New admission under degraded rowCap=4 stays strictly within lanes 0..3");

        // Recover rowCap 4 -> 5; in-flight items still stay on their original lanes
        engine.step(
                3200L, wave2, 1920, 1080, 24f, 0f, 44f, 0.50f, 5, 40, 8200L, true, true, true,
                measurer);
        int lane4Recover = -1;
        for (ActiveSlot s : engine.getSlots()) {
            if (s.active && "lane_4".equals(s.id)) lane4Recover = s.lane;
        }
        check(lane4Recover == 4, "P90 recovery 4->5 preserves in-flight lane continuity");
    }

    private static void testSpeedBoostMonotonicReAnchorAndModePurge() throws Exception {
        // M2 speed boost (1.0x -> 2.0x -> 1.0x) mid-tick must NEVER jump backwards or wipe danmu
        SmoothClock clock = new SmoothClock();
        clock.setPlaySpeed(2.0f, 10000, true, 0L);
        long t0 = clock.sample(10000, true, 0L);
        long t180 = clock.sample(10000, true, 180L);
        check(t0 == 10000L && t180 == 10360L, "SmoothClock interpolates 2.0x speed accurately");

        LayoutEngine engine = new LayoutEngine();
        TextWidthMeasurer measurer =
                new TextWidthMeasurer() {
                    @Override
                    public float measureWidth(String text) {
                        return 180f;
                    }
                };
        List<DanmuItem> items =
                Arrays.asList(
                        new DanmuItem("s1", 9000L, 1, 0xFFFFFF, "普通弹幕"),
                        new DanmuItem("s2", 9100L, 1, 0xFFFFFF, "剧透内容"),
                        new DanmuItem("top1", 9200L, 5, 0xFFFFFF, "顶部固定"));
        engine.step(
                t180, items, 1920, 1080, 24f, 0f, 44f, 0.50f, 6, 48, 7600L, true, true, true,
                measurer);
        int s1LaneBefore = -1;
        for (ActiveSlot s : engine.getSlots()) {
            if (s.active && "s1".equals(s.id)) s1LaneBefore = s.lane;
        }
        check(
                engine.getActiveCount() == 3 && s1LaneBefore == 0,
                "Active danmu admitted before 2.0x -> 1.0x release");

        // Release 2.0x boost back to 1.0x at wall=180ms before next player tick
        clock.setPlaySpeed(1.0f, 10000, true, 180L);
        long t196 = clock.sample(10000, true, 196L);
        check(
                t196 == 10376L && t196 >= t180,
                "SmoothClock re-anchors monotonically on 2.0x -> 1.0x release (" + t196 + "ms)");

        // Even if delayed player tick reports 10350ms at wall=200ms, clock stays monotonic
        long t200 = clock.sample(10350, true, 200L);
        check(t200 >= t196, "Delayed forward player tick stays monotonic after speed release");

        // Step LayoutEngine at t196 with ONLY new-arriving empty list: active danmu MUST survive!
        engine.step(
                t196,
                Collections.<DanmuItem>emptyList(),
                1920,
                1080,
                24f,
                0f,
                44f,
                0.50f,
                6,
                48,
                7600L,
                true,
                true,
                true,
                measurer);
        int s1LaneAfter = -1;
        for (ActiveSlot s : engine.getSlots()) {
            if (s.active && "s1".equals(s.id)) s1LaneAfter = s.lane;
        }
        check(
                engine.getActiveCount() == 3 && s1LaneAfter == s1LaneBefore,
                "Releasing 2.0x -> 1.0x preserves all active danmu intact without LayoutEngine reset");

        // Toggling showTop=false must immediately expire active top danmu on next step
        engine.step(
                t196 + 16L,
                Collections.<DanmuItem>emptyList(),
                1920,
                1080,
                24f,
                0f,
                44f,
                0.50f,
                6,
                48,
                7600L,
                true,
                false,
                true,
                measurer);
        check(
                engine.getActiveCount() == 2,
                "Disabling showTop immediately expires active top danmu without resetting scroll danmu");

        // Live block-rule purge removes newly blocked active danmu while keeping unblocked ones
        engine.purgeBlocked(BlockFilter.compile(Collections.singletonList("剧透")));
        check(
                engine.getActiveCount() == 1,
                "purgeBlocked immediately removes newly blocked active danmu while preserving safe ones");

        // Cross-language X-Signature rawPath parity on percent-encoded episodeId
        final AtomicReference<String> seenRawPath = new AtomicReference<>();
        final AtomicReference<String> seenTs = new AtomicReference<>();
        final AtomicReference<String> seenSig = new AtomicReference<>();
        HttpServer srv = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        srv.setExecutor(daemonPool(2));
        String origin = "http://127.0.0.1:" + srv.getAddress().getPort();
        srv.createContext(
                "/api/v2/comment/",
                new HttpHandler() {
                    @Override
                    public void handle(HttpExchange ex) throws IOException {
                        seenRawPath.set(ex.getRequestURI().getRawPath());
                        seenTs.set(ex.getRequestHeaders().getFirst("X-Timestamp"));
                        seenSig.set(ex.getRequestHeaders().getFirst("X-Signature"));
                        sendResponse(ex, 200, "application/json", "{\"comments\":[]}");
                    }
                });
        srv.start();
        try {
            DandanplayProvider signed = new DandanplayProvider(origin, "appX", "secY", 4, 0L);
            String bound = DandanplayProvider.encodeBoundEpisodeId(origin, "ep+42/sub");
            signed.openSession(bound, null);
            String expected =
                    DandanplayProvider.computeOpenApiSignature(
                            "appX",
                            Long.parseLong(seenTs.get()),
                            "/api/v2/comment/ep%2B42%2Fsub",
                            "secY");
            check(
                    "/api/v2/comment/ep%2B42%2Fsub".equals(seenRawPath.get())
                            && expected.equals(seenSig.get()),
                    "Java X-Signature signs raw percent-encoded path matching Dart");
        } finally {
            srv.stop(0);
        }
    }

    private static void testLocalHttpProtocolAndFullEpisodeFallback() throws Exception {
        final AtomicReference<String> seenAppId = new AtomicReference<>();
        final AtomicReference<String> seenTs = new AtomicReference<>();
        final AtomicReference<String> seenSig = new AtomicReference<>();
        final AtomicReference<String> seenPath = new AtomicReference<>();

        HttpServer goodServer = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        goodServer.setExecutor(daemonPool(4));
        final String goodOrigin = "http://127.0.0.1:" + goodServer.getAddress().getPort();

        HttpServer badServer = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        badServer.setExecutor(daemonPool(2));
        final String badOrigin = "http://127.0.0.1:" + badServer.getAddress().getPort();
        badServer.createContext(
                "/",
                new HttpHandler() {
                    @Override
                    public void handle(HttpExchange ex) throws IOException {
                        sendResponse(ex, 500, "text/plain", "faulty source");
                    }
                });

        goodServer.createContext(
                "/api/v2/match",
                new HttpHandler() {
                    @Override
                    public void handle(HttpExchange ex) throws IOException {
                        seenAppId.set(ex.getRequestHeaders().getFirst("X-AppId"));
                        seenTs.set(ex.getRequestHeaders().getFirst("X-Timestamp"));
                        seenSig.set(ex.getRequestHeaders().getFirst("X-Signature"));
                        seenPath.set(ex.getRequestURI().getPath());
                        String body =
                                "{\"isMatched\":true,\"matches\":[{\"episodeId\":10001,\"animeId\":500,\"animeTitle\":\"Sample Show\",\"episodeTitle\":\"Ep 1\"}]}";
                        sendResponse(ex, 200, "application/json", body);
                    }
                });
        goodServer.createContext(
                "/api/v2/bangumi/500",
                new HttpHandler() {
                    @Override
                    public void handle(HttpExchange ex) throws IOException {
                        String body =
                                "{\"bangumi\":{\"animeTitle\":\"Sample Show\",\"episodes\":[{\"episodeId\":10001,\"episodeTitle\":\"Ep 1\"},{\"episodeId\":10002,\"episodeTitle\":\"Ep 2\"}]}}";
                        sendResponse(ex, 200, "application/json", body);
                    }
                });
        goodServer.createContext(
                "/api/v2/comment/10001",
                new HttpHandler() {
                    @Override
                    public void handle(HttpExchange ex) throws IOException {
                        // Full-episode fallback (no segments[])
                        String body =
                                "{\"count\":3,\"comments\":["
                                        + "{\"cid\":1,\"p\":\"2.5,1,16777215,u1\",\"m\":\"first\"},"
                                        + "{\"cid\":2,\"p\":\"35.0,5,16711680,u2\",\"m\":\"second window\"},"
                                        + "{\"cid\":1,\"p\":\"2.5,1,16777215,u1\",\"m\":\"dup ignored\"}"
                                        + "]}";
                        sendResponse(ex, 200, "application/json", body);
                    }
                });
        goodServer.createContext(
                "/api/v2/comment/evilseg",
                new HttpHandler() {
                    @Override
                    public void handle(HttpExchange ex) throws IOException {
                        String body =
                                "{\"segments\":[{\"startMs\":0,\"endMs\":30000,\"segmentUrl\":\"https://unlisted.invalid/s0.json\"}]}";
                        sendResponse(ex, 200, "application/json", body);
                    }
                });

        goodServer.start();
        badServer.start();
        try {
            // Multi-source fault isolation + Open API v2 signature check
            DandanplayProvider signed =
                    new DandanplayProvider(
                            badOrigin + "\n" + goodOrigin, "testAppId", "testSecret", 4, 0L);
            List<Candidate> matches =
                    signed.matchOrSearch(new MatchQuery("Sample Show", "Ep 1", 1, 1440), null);
            check(matches.size() == 1, "Multi-source match isolates faulty source and returns hit");
            check(
                    "testAppId".equals(seenAppId.get())
                            && seenTs.get() != null
                            && seenSig.get() != null,
                    "Signed provider attaches X-AppId, X-Timestamp, X-Signature");
            String expectedSig =
                    DandanplayProvider.computeOpenApiSignature(
                            "testAppId",
                            Long.parseLong(seenTs.get()),
                            seenPath.get(),
                            "testSecret");
            check(
                    expectedSig.equals(seenSig.get()),
                    "Server received exact SHA-256 Base64 signature");

            // Unsigned provider omits signature headers
            seenAppId.set(null);
            DandanplayProvider unsigned = new DandanplayProvider(goodOrigin, "", "", 4, 0L);
            unsigned.matchOrSearch(new MatchQuery("Sample Show", "Ep 1", 1, 1440), null);
            check(seenAppId.get() == null, "Unsigned provider omits X-AppId/X-Signature headers");

            // Stage 2: listEpisodes
            List<Candidate> eps = unsigned.listEpisodes(goodOrigin, "500", null);
            check(
                    eps.size() == 2 && eps.get(0).boundEpisodeId.startsWith("mmdanmu://v1?"),
                    "listEpisodes returns source-bound IDs");

            // Stage 3: Full-episode fallback + dedup + window slicing
            EpisodeSession fullSession = unsigned.openSession(eps.get(0).boundEpisodeId, null);
            check(!fullSession.segmented, "Full-episode payload sets segmented=false");
            check(fullSession.preloadComments.size() == 2, "Full-episode deduplicates by cid");
            List<DanmuItem> w0 = unsigned.fetchWindow(fullSession, 0, null);
            List<DanmuItem> w1 = unsigned.fetchWindow(fullSession, 1, null);
            check(
                    w0.size() == 1 && "first".equals(w0.get(0).text),
                    "Full-episode fallback slices window 0");
            check(
                    w1.size() == 1 && "second window".equals(w1.get(0).text),
                    "Full-episode fallback slices window 1");

            // Malicious segmentUrl SSRF rejection
            String evilEp = DandanplayProvider.encodeBoundEpisodeId(goodOrigin, "evilseg");
            boolean blockedEvilSeg = false;
            try {
                unsigned.openSession(evilEp, null);
            } catch (IOException expected) {
                blockedEvilSeg = true;
            }
            check(blockedEvilSeg, "openSession blocks unlisted SSRF segmentUrl");

            // XML DOCTYPE/ENTITY rejection
            boolean blockedDtd = false;
            try {
                DandanplayProvider.parseDanmuPayload(
                        "<?xml version=\"1.0\"?><!DOCTYPE x [<!ENTITY e \"boom\">]><i><d p=\"1,1,25,16777215\">&e;</d></i>",
                        100);
            } catch (IOException expected) {
                blockedDtd = true;
            }
            check(blockedDtd, "XML parser rejects <!DOCTYPE / <!ENTITY payloads");
        } finally {
            goodServer.stop(0);
            badServer.stop(0);
        }
    }

    private static void testBoundaryContinuityNegativeOffsetAndPinning() throws Exception {
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.setExecutor(daemonPool(4));
        final String origin = "http://127.0.0.1:" + server.getAddress().getPort();
        final List<Integer> fetchedWindows = new CopyOnWriteArrayList<>();

        server.createContext(
                "/api/v2/comment/ep-seg",
                new HttpHandler() {
                    @Override
                    public void handle(HttpExchange ex) throws IOException {
                        StringBuilder segs = new StringBuilder("{\"segments\":[");
                        for (int w = 0; w < 30; w++) {
                            if (w > 0) segs.append(',');
                            segs.append("{\"startMs\":")
                                    .append(w * 30000L)
                                    .append(",\"endMs\":")
                                    .append((w + 1) * 30000L)
                                    .append(",\"segmentUrl\":\"/seg/")
                                    .append(w)
                                    .append("\"}");
                        }
                        segs.append("]}");
                        sendResponse(ex, 200, "application/json", segs.toString());
                    }
                });
        server.createContext(
                "/seg/",
                new HttpHandler() {
                    @Override
                    public void handle(HttpExchange ex) throws IOException {
                        int w =
                                Integer.parseInt(
                                        ex.getRequestURI().getPath().substring("/seg/".length()));
                        fetchedWindows.add(w);
                        String body;
                        if (w == 0) {
                            body =
                                    "{\"comments\":["
                                            + "{\"cid\":\"c0\",\"p\":\"0.0,1,16777215\",\"m\":\"intro-zero\"},"
                                            + "{\"cid\":\"c285\",\"p\":\"28.5,1,16777215\",\"m\":\"crossing-boundary\"}"
                                            + "]}";
                        } else if (w == 1) {
                            body =
                                    "{\"comments\":["
                                            + "{\"cid\":\"c305\",\"p\":\"30.5,1,16777215\",\"m\":\"after-boundary\"}"
                                            + "]}";
                        } else {
                            // Populate 900 items per window to test 18,000 total item cap eviction
                            StringBuilder sb = new StringBuilder("{\"comments\":[");
                            for (int i = 0; i < 900; i++) {
                                if (i > 0) sb.append(',');
                                double sec = w * 30.0 + (i * 0.02);
                                sb.append("{\"cid\":\"w")
                                        .append(w)
                                        .append("_")
                                        .append(i)
                                        .append("\",\"p\":\"")
                                        .append(sec)
                                        .append(",1,16777215\",\"m\":\"msg-")
                                        .append(i)
                                        .append("\"}");
                            }
                            sb.append("]}");
                            body = sb.toString();
                        }
                        sendResponse(ex, 200, "application/json", body);
                    }
                });
        server.start();
        try {
            DandanplayProvider provider = new DandanplayProvider(origin, "", "", 4, 0L);
            String boundId = DandanplayProvider.encodeBoundEpisodeId(origin, "ep-seg");
            try (DanmuSegmentCache cache = new DanmuSegmentCache(provider, 180L)) {
                cache.bindSession(boundId);
                check(cache.awaitIdle(3000L), "Segmented session bound cleanly");
                check(
                        cache.getCurrentSession() != null && cache.getCurrentSession().segmented,
                        "Session detected segmented=true");

                // Negative time offset (-10000ms): 0.0s danmu MUST NOT freeze during first 10s!
                cache.setTimeOffsetMs(-10000L);
                cache.onPlaybackTick(0L, true);
                check(cache.awaitIdle(2000L), "Window 0 pre-fetched despite negative effectiveMs");
                check(cache.isWindowCached(0), "Window 0 cached via non-negative fetchWindowIndex");
                check(
                        cache.visibleWindowSnapshot(0L).isEmpty()
                                && cache.visibleWindowSnapshot(5000L).isEmpty()
                                && cache.visibleWindowSnapshot(9999L).isEmpty(),
                        "Negative offset (-10s) yields empty snapshot for rawPos < 10000ms (0.0s danmu not frozen)");
                List<DanmuItem> at10s = cache.visibleWindowSnapshot(10000L);
                check(
                        at10s.size() == 1 && "intro-zero".equals(at10s.get(0).text),
                        "At rawPos=10000ms with -10s offset, 0.0s danmu appears right on cue");

                // Reset offset to 0; test 60% prefetch (18000ms) + 30s boundary continuity
                cache.setTimeOffsetMs(0L);
                cache.onPlaybackTick(18500L, true);
                check(cache.awaitIdle(2000L), "60% prefetch tick settled");
                check(cache.isWindowCached(1), "Crossing 60% (18500ms) prefetched window 1");

                // At 31500ms (inside window 1), both w-1 (28500ms) and w (30500ms) MUST be visible!
                cache.onPlaybackTick(31500L, true);
                List<DanmuItem> boundary = cache.visibleWindowSnapshot(31500L);
                check(
                        boundary.size() == 2
                                && "crossing-boundary".equals(boundary.get(0).text)
                                && "after-boundary".equals(boundary.get(1).text),
                        "30s boundary snapshot merges w-1 and w so in-flight danmu never disappear");

                // Load 26 windows (900 items each -> would exceed 18,000 items & 24 windows)
                for (int w = 2; w < 28; w++) {
                    cache.onPlaybackTick(w * 30000L + 1000L, false);
                    check(cache.awaitIdle(2000L), "Loaded window " + w);
                }
                // Current pinned window is 27 -> {26, 27, 28} pinned; total items <= 18000 &
                // windows <= 24
                check(
                        cache.getCachedWindowCount() <= DanmuSegmentCache.MAX_CACHED_WINDOWS,
                        "LRU respects 24-window cap (" + cache.getCachedWindowCount() + ")");
                check(
                        cache.getTotalCachedItemCount() <= DanmuSegmentCache.MAX_TOTAL_ITEMS,
                        "LRU respects 18,000-item total cap ("
                                + cache.getTotalCachedItemCount()
                                + ")");
                check(
                        cache.isWindowCached(26) && cache.isWindowCached(27),
                        "3-window pinning preserves w-1 (26) and w (27) under heavy eviction");
            }
        } finally {
            server.stop(0);
        }
    }

    private static void testConcurrent410SingleflightAndCap() throws Exception {
        final AtomicInteger openCount = new AtomicInteger(0);
        final AtomicInteger epochVersion = new AtomicInteger(0);
        final Map<Integer, AtomicInteger> segFetchCounts = new HashMap<>();
        for (int i = 0; i < 6; i++) segFetchCounts.put(i, new AtomicInteger(0));
        final AtomicBoolean always410 = new AtomicBoolean(false);
        final CountDownLatch bothEntered410 = new CountDownLatch(2);

        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.setExecutor(daemonPool(6));
        final String origin = "http://127.0.0.1:" + server.getAddress().getPort();

        server.createContext(
                "/api/v2/comment/ep-410",
                new HttpHandler() {
                    @Override
                    public void handle(HttpExchange ex) throws IOException {
                        int call = openCount.incrementAndGet();
                        // Delay refresh slightly so concurrent 410s definitely collide in
                        // singleflight
                        if (call > 1) {
                            try {
                                Thread.sleep(120L);
                            } catch (InterruptedException ignored) {
                            }
                        }
                        int epVer = epochVersion.incrementAndGet();
                        StringBuilder segs = new StringBuilder("{\"segments\":[");
                        for (int w = 0; w < 6; w++) {
                            if (w > 0) segs.append(',');
                            segs.append("{\"startMs\":")
                                    .append(w * 30000L)
                                    .append(",\"endMs\":")
                                    .append((w + 1) * 30000L)
                                    .append(",\"segmentUrl\":\"/seg410/v")
                                    .append(epVer)
                                    .append("/")
                                    .append(w)
                                    .append("\"}");
                        }
                        segs.append("]}");
                        sendResponse(ex, 200, "application/json", segs.toString());
                    }
                });
        server.createContext(
                "/seg410/",
                new HttpHandler() {
                    @Override
                    public void handle(HttpExchange ex) throws IOException {
                        String[] parts = ex.getRequestURI().getPath().split("/");
                        int ver = Integer.parseInt(parts[2].substring(1));
                        int w = Integer.parseInt(parts[3]);
                        segFetchCounts.get(w).incrementAndGet();

                        if (always410.get()) {
                            sendResponse(ex, 410, "text/plain", "expired");
                            return;
                        }
                        if (ver == 1 && (w == 0 || w == 1)) {
                            bothEntered410.countDown();
                            try {
                                bothEntered410.await(500L, TimeUnit.MILLISECONDS);
                            } catch (InterruptedException ignored) {
                            }
                            sendResponse(ex, 410, "text/plain", "stale epoch 1");
                            return;
                        }
                        String body =
                                "{\"comments\":[{\"cid\":\"ok_"
                                        + w
                                        + "\",\"p\":\""
                                        + (w * 30 + 1)
                                        + ".0,1,16777215\",\"m\":\"recovered-"
                                        + w
                                        + "\"}]}";
                        sendResponse(ex, 200, "application/json", body);
                    }
                });
        server.start();
        try {
            DandanplayProvider provider = new DandanplayProvider(origin, "", "", 4, 0L);
            String boundId = DandanplayProvider.encodeBoundEpisodeId(origin, "ep-410");
            try (DanmuSegmentCache cache = new DanmuSegmentCache(provider, 180L)) {
                cache.bindSession(boundId);
                check(cache.awaitIdle(3000L), "410 test session opened");
                // Trigger window 0 AND prefetch window 1 simultaneously at 19000ms (60% of w0)
                // Both fetch v1/0 and v1/1 and concurrently receive HTTP 410!
                cache.onPlaybackTick(19000L, true);
                check(cache.awaitIdle(4000L), "Concurrent 410 singleflight settled");

                check(
                        cache.getSession410RefreshCount() == 1 && openCount.get() == 2,
                        "Concurrent 410 on w=0 & w=1 triggered ONLY 1 singleflight openSession refresh (openCount="
                                + openCount.get()
                                + ")");
                check(cache.getSessionEpoch() == 1, "Session epoch incremented once to 1");
                check(
                        cache.visibleWindowSnapshot(1500L).size() == 1
                                && cache.visibleWindowSnapshot(31500L).size() == 1,
                        "Both w=0 and w=1 recovered cleanly on single retry");

                // Now simulate persistent 410 across windows 2, 3, 4, 5 -> cap total refreshes at
                // <= 3!
                always410.set(true);
                for (int w = 2; w <= 5; w++) {
                    cache.onPlaybackTick(w * 30000L + 1000L, false);
                    check(
                            cache.awaitIdle(3000L),
                            "Persistent 410 window " + w + " settled without loop");
                }
                check(
                        cache.getSession410RefreshCount()
                                <= DanmuSegmentCache.MAX_SESSION_410_REFRESHES,
                        "Total 410 refreshes strictly capped at <= 3 ("
                                + cache.getSession410RefreshCount()
                                + ")");
                check(
                        segFetchCounts.get(2).get() <= 2
                                && segFetchCounts.get(3).get() <= 2
                                && segFetchCounts.get(4).get() <= 2
                                && segFetchCounts.get(5).get() <= 2,
                        "Every window retried at most once (<= 2 total attempts)");
            }
        } finally {
            server.stop(0);
        }
    }

    private static void testSeekStormDebounceAndCancellation() throws Exception {
        final List<Integer> requestedWindows = new CopyOnWriteArrayList<>();
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.setExecutor(daemonPool(4));
        final String origin = "http://127.0.0.1:" + server.getAddress().getPort();

        server.createContext(
                "/api/v2/comment/ep-seek",
                new HttpHandler() {
                    @Override
                    public void handle(HttpExchange ex) throws IOException {
                        StringBuilder segs = new StringBuilder("{\"segments\":[");
                        for (int w = 0; w <= 12; w++) {
                            if (w > 0) segs.append(',');
                            segs.append("{\"startMs\":")
                                    .append(w * 30000L)
                                    .append(",\"endMs\":")
                                    .append((w + 1) * 30000L)
                                    .append(",\"segmentUrl\":\"/seekseg/")
                                    .append(w)
                                    .append("\"}");
                        }
                        segs.append("]}");
                        sendResponse(ex, 200, "application/json", segs.toString());
                    }
                });
        server.createContext(
                "/seekseg/",
                new HttpHandler() {
                    @Override
                    public void handle(HttpExchange ex) throws IOException {
                        int w =
                                Integer.parseInt(
                                        ex.getRequestURI()
                                                .getPath()
                                                .substring("/seekseg/".length()));
                        requestedWindows.add(w);
                        if (w == 0) {
                            // Slow window 0 that should be cancelled when seek storm begins
                            try {
                                Thread.sleep(600L);
                            } catch (InterruptedException ignored) {
                            }
                        }
                        String body =
                                "{\"comments\":[{\"cid\":\"s"
                                        + w
                                        + "\",\"p\":\""
                                        + (w * 30 + 2)
                                        + ".0,1,16777215\",\"m\":\"seek-win-"
                                        + w
                                        + "\"}]}";
                        sendResponse(ex, 200, "application/json", body);
                    }
                });
        server.start();
        try {
            DandanplayProvider provider = new DandanplayProvider(origin, "", "", 4, 0L);
            String boundId = DandanplayProvider.encodeBoundEpisodeId(origin, "ep-seek");
            try (DanmuSegmentCache cache = new DanmuSegmentCache(provider, 180L)) {
                cache.bindSession(boundId);
                Thread.sleep(80L);
                // Rapid seek storm across windows 2, 4, 6, 8 within 80ms, finally settling at
                // window 10
                cache.onSeekInitiated();
                cache.onSeekSettled(2 * 30000L + 5000L);
                Thread.sleep(25L);
                cache.onSeekSettled(4 * 30000L + 5000L);
                Thread.sleep(25L);
                cache.onSeekSettled(6 * 30000L + 5000L);
                Thread.sleep(25L);
                cache.onSeekSettled(8 * 30000L + 5000L);
                Thread.sleep(25L);
                cache.onSeekSettled(10 * 30000L + 5000L);

                // Before 180ms elapses, none of intermediate windows 2/4/6/8/10 should be fetched
                check(
                        !requestedWindows.contains(2)
                                && !requestedWindows.contains(4)
                                && !requestedWindows.contains(6)
                                && !requestedWindows.contains(8),
                        "180ms seek debounce suppressed all intermediate storm windows");

                check(cache.awaitIdle(3000L), "Final seek target settled after 180ms debounce");
                check(
                        requestedWindows.contains(10)
                                && !requestedWindows.contains(2)
                                && !requestedWindows.contains(4)
                                && !requestedWindows.contains(6)
                                && !requestedWindows.contains(8),
                        "Only final target window 10 was fetched after seek storm");
                List<DanmuItem> snap = cache.visibleWindowSnapshot(10 * 30000L + 5000L);
                check(
                        snap.size() == 1 && "seek-win-10".equals(snap.get(0).text),
                        "Final seek target window 10 snapshot is immediately visible");
            }
        } finally {
            server.stop(0);
        }
    }

    private static void testRateLimitingAnd429RetryAfter() throws Exception {
        check(
                DandanplayProvider.parseRetryAfterMs("3") == 3000L,
                "Retry-After header parses seconds");
        check(
                DandanplayProvider.parseRetryAfterMs(null) == 2000L,
                "Missing Retry-After defaults to 2000ms");

        final AtomicInteger callCount = new AtomicInteger(0);
        final List<Long> timestamps = new CopyOnWriteArrayList<>();
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.setExecutor(daemonPool(2));
        final String origin = "http://127.0.0.1:" + server.getAddress().getPort();

        server.createContext(
                "/api/v2/bangumi/",
                new HttpHandler() {
                    @Override
                    public void handle(HttpExchange ex) throws IOException {
                        timestamps.add(System.currentTimeMillis());
                        int n = callCount.incrementAndGet();
                        if (n == 3) {
                            ex.getResponseHeaders().set("Retry-After", "1");
                            sendResponse(ex, 429, "text/plain", "slow down");
                            return;
                        }
                        sendResponse(ex, 200, "application/json", "{\"episodes\":[]}");
                    }
                });
        server.start();
        try {
            DandanplayProvider limited = new DandanplayProvider(origin, "", "", 4, 200L);
            limited.listEpisodes(origin, "1", null);
            limited.listEpisodes(origin, "2", null);
            long deltaMs = timestamps.get(1) - timestamps.get(0);
            check(
                    deltaMs >= 180L,
                    "Per-domain rate limiter enforces >= 200ms spacing (actual=" + deltaMs + "ms)");

            boolean got429 = false;
            long retryAfter = 0L;
            try {
                limited.listEpisodes(origin, "3", null);
            } catch (HttpStatusException e) {
                got429 = e.statusCode == 429;
                retryAfter = e.retryAfterMs;
            }
            check(
                    got429 && retryAfter == 1000L,
                    "HTTP 429 parses Retry-After=1s into 1000ms backoff");
        } finally {
            server.stop(0);
        }
    }

    private static com.sun.management.ThreadMXBean resolveSunThreadMxBean() {
        try {
            java.lang.management.ThreadMXBean mx =
                    java.lang.management.ManagementFactory.getThreadMXBean();
            if (mx instanceof com.sun.management.ThreadMXBean) {
                com.sun.management.ThreadMXBean sunMx = (com.sun.management.ThreadMXBean) mx;
                if (sunMx.isThreadAllocatedMemorySupported()) {
                    if (!sunMx.isThreadAllocatedMemoryEnabled()) {
                        sunMx.setThreadAllocatedMemoryEnabled(true);
                    }
                    return sunMx;
                }
            }
        } catch (Throwable ignored) {
        }
        return null;
    }

    private static void testTvPerFrameZeroRepeatFilterAndZeroAllocPast64Min() throws Exception {
        // M-01 & L-04: TV-side steady-state zero-repeat-filter & zero-allocation verification with
        // active `re:` regex block rules, including past 64 minutes (windowIndex = 180 >= 128).
        final int targetWindow = 180; // 90 minutes (5,400,000 ms), well past Integer cache 127
        final long baseMs = (long) targetWindow * DanmuSegmentCache.WINDOW_DURATION_MS;
        final List<DanmuItem> winPrev = new ArrayList<>();
        final List<DanmuItem> winCurr = new ArrayList<>();
        for (int i = 0; i < 60; i++) {
            String text;
            if (i % 5 == 0) {
                text = "广告推广" + i + "链接点这里";
            } else if (i % 5 == 1) {
                text = "SPOILER 剧透预警 " + i;
            } else if (i % 5 == 2) {
                text = "请看第二章内容 " + i;
            } else {
                text = "正常电视弹幕内容 " + i;
            }
            winPrev.add(new DanmuItem("p_" + i, baseMs - 6000L + i * 90L, 1, 0xFFFFFF, text));
            winCurr.add(new DanmuItem("c_" + i, baseMs + 500L + i * 90L, 1, 0xFFFFFF, text));
        }

        DanmuProvider mockProvider =
                new DanmuProvider() {
                    @Override
                    public List<Candidate> matchOrSearch(
                            MatchQuery query, CancellationToken token) {
                        return Collections.emptyList();
                    }

                    @Override
                    public List<Candidate> listEpisodes(
                            String sourceOrigin, String animeId, CancellationToken token) {
                        return Collections.emptyList();
                    }

                    @Override
                    public EpisodeSession openSession(
                            String boundEpisodeId, CancellationToken token) {
                        return new EpisodeSession(
                                boundEpisodeId,
                                true,
                                Collections.<SegmentDescriptor>emptyList(),
                                Collections.<DanmuItem>emptyList());
                    }

                    @Override
                    public List<DanmuItem> fetchWindow(
                            EpisodeSession session, int windowIndex, CancellationToken token) {
                        if (windowIndex == targetWindow - 1) return winPrev;
                        if (windowIndex == targetWindow) return winCurr;
                        return Collections.emptyList();
                    }
                };

        BlockFilter initialFilter =
                BlockFilter.compile(Arrays.asList("spoiler", "re:广告.*链接", "re:第(一|二)章"));
        try (DanmuSegmentCache cache = new DanmuSegmentCache(mockProvider, 0L)) {
            cache.setBlockFilter(initialFilter);
            cache.bindSession("mmdanmu://v1?src=dGVzdA&ep=tv90m");
            check(cache.awaitIdle(2000L), "M-01 mock segmented session initialized");

            // Load both w-1 (179) and w (180) plus prefetch w+1 (181)
            cache.onPlaybackTick(baseMs - 5000L, true);
            check(cache.awaitIdle(2000L), "M-01 window 179 ingested");
            cache.onPlaybackTick(baseMs + 20000L, true);
            check(cache.awaitIdle(2000L), "M-01 windows 180 and 181 ingested");

            long evalAfterIngest = initialFilter.getEvaluationCount();
            check(
                    evalAfterIngest == winPrev.size() + winCurr.size(),
                    "M-01 filter evaluated each ingested item exactly once (actual="
                            + evalAfterIngest
                            + ", expected="
                            + (winPrev.size() + winCurr.size())
                            + ")");

            LayoutEngine tvEngine = new LayoutEngine();
            TextWidthMeasurer tvMeasurer =
                    new TextWidthMeasurer() {
                        @Override
                        public float measureWidth(String text) {
                            return text.length() * 24f;
                        }
                    };
            ArrayList<DanmuItem> frameBuf = new ArrayList<>(128);

            // Warm up JIT & fastWindowIndex cache so HotSpot C1/C2 compilation settles before
            // measuring strict 0-byte per-frame heap allocation.
            for (int w = 0; w < 400; w++) {
                long t = baseMs + 4000L + (w % 10) * 16L;
                cache.onPlaybackTick(t, true);
                cache.fillVisibleWindowSnapshot(t, frameBuf);
                tvEngine.step(
                        t,
                        frameBuf,
                        1920,
                        1080,
                        24f,
                        0f,
                        44f,
                        0.50f,
                        6,
                        48,
                        8200L,
                        true,
                        true,
                        true,
                        tvMeasurer);
            }
            tvEngine.reset();
            cache.onPlaybackTick(baseMs + 4084L, true);
            cache.fillVisibleWindowSnapshot(baseMs + 4084L, frameBuf);
            tvEngine.step(
                    baseMs + 4084L,
                    frameBuf,
                    1920,
                    1080,
                    24f,
                    0f,
                    44f,
                    0.50f,
                    6,
                    48,
                    8200L,
                    true,
                    true,
                    true,
                    tvMeasurer);

            com.sun.management.ThreadMXBean sunMx = resolveSunThreadMxBean();
            long tid = Thread.currentThread().getId();
            if (sunMx != null) {
                sunMx.getThreadAllocatedBytes(tid);
                sunMx.getThreadAllocatedBytes(tid);
            }
            long evalBeforeSteady = initialFilter.getEvaluationCount();
            long allocBefore = sunMx != null ? sunMx.getThreadAllocatedBytes(tid) : -1L;
            for (int f = 0; f < 120; f++) {
                long t = baseMs + 4100L + f * 16L;
                cache.onPlaybackTick(t, true);
                cache.fillVisibleWindowSnapshot(t, frameBuf);
                tvEngine.step(
                        t,
                        frameBuf,
                        1920,
                        1080,
                        24f,
                        0f,
                        44f,
                        0.50f,
                        6,
                        48,
                        8200L,
                        true,
                        true,
                        true,
                        tvMeasurer);
            }
            long allocAfter = sunMx != null ? sunMx.getThreadAllocatedBytes(tid) : -1L;
            long evalAfterSteady = initialFilter.getEvaluationCount();

            check(
                    evalAfterSteady == evalBeforeSteady,
                    "M-01 steady-state 120 TV frames invoke BlockFilter.isBlocked 0 times (delta="
                            + (evalAfterSteady - evalBeforeSteady)
                            + ")");
            check(
                    !frameBuf.isEmpty(),
                    "M-01 steady-state TV window still yields safe unblocked danmu ("
                            + frameBuf.size()
                            + ")");
            for (DanmuItem item : frameBuf) {
                if (item.text.contains("广告")
                        || item.text.contains("SPOILER")
                        || item.text.contains("第二章")) {
                    throw new AssertionError("M-01 blocked item leaked into frame: " + item.text);
                }
            }
            if (allocBefore >= 0L && allocAfter >= 0L) {
                long deltaBytes = allocAfter - allocBefore;
                check(
                        deltaBytes == 0L,
                        "M-01 + L-04 steady-state 120 TV frames at 90min (w=180>=128) allocated 0 bytes (delta="
                                + deltaBytes
                                + ")");
            }

            // Seek within already-cached window 180 must also invoke isBlocked 0 times
            cache.onSeekInitiated();
            cache.onSeekSettled(baseMs + 2000L);
            check(cache.awaitIdle(1000L), "M-01 seek settled inside cached window");
            tvEngine.reset();
            for (int f = 0; f < 30; f++) {
                long t = baseMs + 2000L + f * 16L;
                cache.fillVisibleWindowSnapshot(t, frameBuf);
                tvEngine.step(
                        t,
                        frameBuf,
                        1920,
                        1080,
                        24f,
                        0f,
                        44f,
                        0.50f,
                        6,
                        48,
                        8200L,
                        true,
                        true,
                        true,
                        tvMeasurer);
            }
            check(
                    initialFilter.getEvaluationCount() == evalBeforeSteady,
                    "M-01 seek inside cached window invokes isBlocked 0 times");

            // Applying an identical rule set must NOT redundantly re-filter cached windows
            BlockFilter identicalFilter =
                    BlockFilter.compile(Arrays.asList("spoiler", "re:广告.*链接", "re:第(一|二)章"));
            cache.setBlockFilter(identicalFilter);
            check(
                    identicalFilter.getEvaluationCount() == 0L,
                    "M-01 identical rule re-apply skips redundant cached window re-filtering");

            // Changing rules (removing re:广告.*链接, adding re:正常电视弹幕.*0$) re-evaluates once
            BlockFilter updatedFilter =
                    BlockFilter.compile(Arrays.asList("spoiler", "re:正常电视弹幕.*3$"));
            cache.setBlockFilter(updatedFilter);
            long evalAfterRuleChange = updatedFilter.getEvaluationCount();
            check(
                    evalAfterRuleChange == winPrev.size() + winCurr.size(),
                    "M-01 rule change re-evaluates cached windows exactly once (actual="
                            + evalAfterRuleChange
                            + ")");
            cache.fillVisibleWindowSnapshot(baseMs + 5000L, frameBuf);
            boolean sawRestoredAd = false;
            boolean sawNewlyBlocked3 = false;
            for (DanmuItem item : frameBuf) {
                if (item.text.contains("广告推广")) sawRestoredAd = true;
                if (item.text.endsWith(" 3")) sawNewlyBlocked3 = true;
            }
            check(
                    sawRestoredAd && !sawNewlyBlocked3,
                    "M-01 rule change restores unblocked items and hides newly blocked regex matches");
            for (int f = 0; f < 60; f++) {
                cache.fillVisibleWindowSnapshot(baseMs + 5000L + f * 16L, frameBuf);
            }
            check(
                    updatedFilter.getEvaluationCount() == evalAfterRuleChange,
                    "M-01 60 frames after rule change invoke updatedFilter.isBlocked 0 times");
        }

        // Direct LayoutEngine.step(..., entryBlockFilter) evaluates each newly arriving item at
        // most once and records blocked IDs in droppedIds so subsequent steady-state frames call
        // isBlocked 0 times.
        LayoutEngine directEngine = new LayoutEngine();
        BlockFilter entryFilter = BlockFilter.compile(Arrays.asList("re:剧透|广告", "spam"));
        List<DanmuItem> rawFeed = new ArrayList<>();
        for (int i = 0; i < 40; i++) {
            String txt = (i < 3) ? ("安全弹幕" + i) : ("剧透第" + i + "集");
            rawFeed.add(new DanmuItem("d_" + i, 1000L + i * 20L, 1, 0xFFFFFF, txt));
        }
        TextWidthMeasurer simpleMeasurer =
                new TextWidthMeasurer() {
                    @Override
                    public float measureWidth(String text) {
                        return 160f;
                    }
                };
        directEngine.step(
                2000L,
                rawFeed,
                1920,
                1080,
                24f,
                0f,
                44f,
                0.50f,
                6,
                48,
                8200L,
                true,
                true,
                true,
                simpleMeasurer,
                entryFilter);
        long afterEntryEvals = entryFilter.getEvaluationCount();
        check(
                afterEntryEvals == rawFeed.size(),
                "M-01 direct LayoutEngine.step evaluates each arriving item once (actual="
                        + afterEntryEvals
                        + ")");
        for (ActiveSlot slot : directEngine.getSlots()) {
            if (slot.active && slot.text != null && slot.text.contains("剧透")) {
                throw new AssertionError("M-01 direct LayoutEngine admitted blocked item");
            }
        }
        for (int f = 1; f <= 60; f++) {
            directEngine.step(
                    2000L + f * 16L,
                    rawFeed,
                    1920,
                    1080,
                    24f,
                    0f,
                    44f,
                    0.50f,
                    6,
                    48,
                    8200L,
                    true,
                    true,
                    true,
                    simpleMeasurer,
                    entryFilter);
        }
        check(
                entryFilter.getEvaluationCount() == afterEntryEvals,
                "M-01 direct LayoutEngine.step invokes entryFilter 0 times across 60 steady frames");
        directEngine.onBlockFilterChanged(BlockFilter.EMPTY);
        directEngine.step(
                3000L,
                rawFeed,
                1920,
                1080,
                24f,
                0f,
                44f,
                0.50f,
                6,
                48,
                8200L,
                true,
                true,
                true,
                simpleMeasurer,
                BlockFilter.EMPTY);
        boolean admittedPreviouslyBlocked = false;
        for (ActiveSlot slot : directEngine.getSlots()) {
            if (slot.active && slot.text != null && slot.text.contains("剧透")) {
                admittedPreviouslyBlocked = true;
                break;
            }
        }
        check(
                admittedPreviouslyBlocked,
                "M-01 LayoutEngine.onBlockFilterChanged clears droppedIds when rules relax");
    }

    private static String repeatChar(char c, int count) {
        StringBuilder sb = new StringBuilder(count);
        for (int i = 0; i < count; i++) sb.append(c);
        return sb.toString();
    }
}
