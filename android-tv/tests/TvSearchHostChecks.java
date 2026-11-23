package com.pilipala.marcomovie;

import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import org.json.*;

/** Executes real CMS HTTP pagination, coordinator limits and revocation; no Android UI/device. */
public final class TvSearchHostChecks {
    static int checks;

    static void check(boolean ok, String label) {
        if (!ok) throw new AssertionError(label);
        checks++;
        System.out.println("PASS " + label);
    }

    static Cms.Listing page(int page, int pages, int first, int count) {
        Cms.Listing out = new Cms.Listing();
        out.page = page;
        out.pageCount = pages;
        for (int i = first; i < first + count; i++) {
            Cms.Video v = new Cms.Video();
            v.id = "v" + i;
            v.title = "Title " + i;
            out.videos.add(v);
        }
        return out;
    }

    public static void main(String[] args) throws Exception {
        Object config = new Object();
        TvSearchContext publicContext = new TvSearchContext(config, false, 7);
        check(publicContext.matches(config, false, 7), "same public context remains reusable");
        check(
                !publicContext.matches(new Object(), false, 7),
                "equal-looking replacement config invalidates");
        check(!publicContext.matches(config, true, 7), "space flag mismatch invalidates");
        check(!publicContext.matches(config, false, 8), "engine epoch mismatch invalidates");
        TvSearchContext.revokeAll();
        check(
                !publicContext.matches(config, false, 7),
                "revocation blocks old Activity before its fields change");
        TvSearchContext privateContext = new TvSearchContext(config, true, 7);
        TvSearchContext.revokeAll();
        check(
                !privateContext.matches(config, true, 7),
                "exit invalidates retained private context too");

        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        List<Integer> requested = Collections.synchronizedList(new ArrayList<>());
        server.createContext(
                "/cms",
                exchange -> {
                    try {
                        int number =
                                exchange.getRequestURI().getRawQuery().contains("pg=2") ? 2 : 1;
                        requested.add(number);
                        JSONArray list = new JSONArray();
                        int first = number == 1 ? 0 : 500, end = number == 1 ? 500 : 501;
                        for (int i = first; i < end; i++)
                            list.put(
                                    new JSONObject()
                                            .put("vod_id", "v" + i)
                                            .put("vod_name", "Title " + i));
                        byte[] bytes =
                                new JSONObject()
                                        .put("page", number)
                                        .put("pagecount", 2)
                                        .put("list", list)
                                        .toString()
                                        .getBytes(StandardCharsets.UTF_8);
                        exchange.sendResponseHeaders(200, bytes.length);
                        exchange.getResponseBody().write(bytes);
                    } catch (Exception failure) {
                        throw new RuntimeException(failure);
                    } finally {
                        exchange.close();
                    }
                });
        server.start();
        try {
            Cms.Site site = new Cms.Site();
            site.key = "fixture";
            site.name = "Fixture";
            site.type = 1;
            site.api = "http://127.0.0.1:" + server.getAddress().getPort() + "/cms";
            JsonCmsEngine engine = new JsonCmsEngine(site);
            TvSearchPages.Fetch fetch = (term, p) -> Cms.listing(engine.search(term, p));
            TvSearchPages first =
                    TvSearchPages.first("Title", Arrays.asList("Title"), t -> true, fetch);
            check(
                    first.videos.size() == 500 && first.hasMore(),
                    "first legal 500-item page is fully retained");
            TvSearchPages second = first.next(t -> true, fetch);
            check(
                    second.videos.size() == 501 && !second.hasMore(),
                    "real engine appends page two and observes terminal metadata");
            check(
                    requested.equals(Arrays.asList(1, 2)),
                    "HTTP fixture received pg=1 then pg=2, not two first-page requests");
            check(
                    first.videos.size() == 500 && first.hasMore(),
                    "page transaction does not mutate cached predecessor");
            CountDownLatch legacyDone = new CountDownLatch(1), tvDone = new CountDownLatch(1);
            AtomicInteger legacy = new AtomicInteger(), tv = new AtomicInteger();
            try (SearchCoordinator old =
                            new SearchCoordinator(
                                    (s, q) -> first.videos,
                                    (s, v, o) -> {
                                        legacy.set(v.size());
                                        legacyDone.countDown();
                                    });
                    SearchCoordinator expanded =
                            new SearchCoordinator(
                                    (s, q) -> first.videos,
                                    (s, v, o) -> {
                                        tv.set(v.size());
                                        tvDone.countDown();
                                    },
                                    2000,
                                    5000,
                                    TvSearchPages.MAX_RESULTS)) {
                old.start(Arrays.asList(site), "Title");
                expanded.start(Arrays.asList(site), "Title");
                check(
                        legacyDone.await(5, TimeUnit.SECONDS) && tvDone.await(5, TimeUnit.SECONDS),
                        "both coordinator policies finish");
                check(
                        legacy.get() == 24 && tv.get() == 500,
                        "mobile/default 24 policy preserved while TV receives all 500");
            }
        } finally {
            server.stop(0);
        }

        TvSearchPages base =
                TvSearchPages.first(
                        "q", Arrays.asList("q"), t -> true, (t, p) -> page(1, 4, 0, 25));
        check(base.videos.size() == 25, "25th single-source result is not lost");
        check(
                !base.next(t -> true, (t, p) -> page(p, 4, 0, 25)).hasMore(),
                "repeated page stops without duplicating cards");
        check(
                !base.next(t -> true, (t, p) -> page(p, 4, 0, 0)).hasMore(),
                "empty next page terminates advertised endless pagination");
        try {
            base.next(
                    t -> true,
                    (t, p) -> {
                        throw new java.io.IOException("fixture failure");
                    });
            throw new AssertionError();
        } catch (java.io.IOException expected) {
            check(
                    base.hasMore() && base.videos.size() == 25,
                    "failed request leaves retry cursor and first results intact");
        }
        check(
                base.next(t -> true, (t, p) -> page(p, 2, 25, 1)).videos.size() == 26,
                "retry requests same missing page and appends once");
        try {
            base.next(t -> true, (t, p) -> page(1, 4, 25, 1));
            throw new AssertionError();
        } catch (java.io.IOException expected) {
            check(base.hasMore(), "wrong returned page is rejected without advancing cursor");
        }
        TvSearchPages noMetadata =
                TvSearchPages.first(
                        "q", Arrays.asList("q"), t -> true, (t, p) -> page(1, 1, 0, 25));
        check(
                !noMetadata.hasMore(),
                "no invented remote pages when source supplies no more-page evidence");
        try {
            TvSearchPages.first("q", Arrays.asList("q"), t -> true, (t, p) -> page(1, 2, 0, 501));
            throw new AssertionError();
        } catch (java.io.IOException expected) {
            check(true, "single-page 500 limit is preserved");
        }
        TvSearchPages many =
                TvSearchPages.first(
                        "q", Arrays.asList("q"), t -> true, (t, p) -> page(1, 100, 0, 500));
        while (many.hasMore())
            many = many.next(t -> true, (t, p) -> page(p, 100, (p - 1) * 500, 500));
        check(
                many.limited && many.videos.size() == 5000,
                "bounded retained search explicitly marks its 5000-item limit");

        Object cfg = new Object();
        TvSearchContext oldContext = new TvSearchContext(cfg, false, 1);
        CountDownLatch started = new CountDownLatch(1),
                release = new CountDownLatch(1),
                delivered = new CountDownLatch(1);
        AtomicInteger accepted = new AtomicInteger();
        Cms.Site stub = new Cms.Site();
        stub.key = "late";
        stub.type = 1;
        stub.api = "http://fixture.invalid";
        try (SearchCoordinator work =
                new SearchCoordinator(
                        (s, q) -> {
                            started.countDown();
                            release.await();
                            return page(1, 1, 0, 1).videos;
                        },
                        (s, v, o) -> {
                            if (oldContext.matches(cfg, false, 1)) accepted.incrementAndGet();
                            delivered.countDown();
                        })) {
            work.start(Arrays.asList(stub), "q");
            check(started.await(5, TimeUnit.SECONDS), "late response fixture actually started");
            TvSearchContext.revokeAll();
            release.countDown();
            check(
                    delivered.await(5, TimeUnit.SECONDS) && accepted.get() == 0,
                    "late response cannot publish with revoked scope despite unchanged Activity fields");
        }
        System.out.println("ALL PASS (" + checks + " search host checks; no Android UI/device)");
    }
}
