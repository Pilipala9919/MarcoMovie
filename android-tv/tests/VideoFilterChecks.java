package com.pilipala.marcomovie;

import com.sun.net.httpserver.HttpServer;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.atomic.AtomicReference;

public final class VideoFilterChecks {
    static void check(boolean value, String label) {
        if (!value) throw new AssertionError(label);
        System.out.println("PASS " + label);
    }

    public static void main(String[] args) throws Exception {
        String schema =
                "{\"filters\":{\"movie\":[{\"key\":\"class\",\"name\":\"类型\",\"value\":[{\"n\":\"全部\",\"v\":\"\"},{\"n\":\"剧情\",\"v\":\"genre-7\"}]},{\"key\":\"area\",\"name\":\"地区\",\"value\":[{\"n\":\"美国\",\"v\":\"US\"}]},{\"key\":\"year\",\"name\":\"年份\",\"value\":[{\"n\":\"2026\",\"v\":\"2026\"}]}]}}";
        List<VideoFilters.Definition> definitions =
                VideoFilters.definitions(schema, "movie", Collections.emptyList());
        Map<String, String> selected = new LinkedHashMap<>();
        selected.put("class", "genre-7");
        selected.put("area", "US");
        selected.put("year", "2026");
        Map<String, String> wire = VideoFilters.remoteValues(definitions, selected);
        check(wire.equals(selected), "remote opaque filter values preserved across all dimensions");
        check(
                definitions.get(0).labelFor("genre-7").equals("剧情"),
                "opaque source value has readable label");
        check(
                VideoFilters.remoteValues(
                                VideoFilters.definitions(schema, "series", Collections.emptyList()),
                                selected)
                        .isEmpty(),
                "category-specific schema never leaks to another category");
        List<Cms.Video> videos =
                Cms.listing(
                                "{\"list\":[{\"vod_id\":\"1\",\"vod_class\":\"剧情 / 悬疑\",\"vod_area\":\"大陆 / 香港\",\"vod_year\":\"2026\"},{\"vod_id\":\"2\",\"vod_class\":\"剧情\",\"vod_area\":\"美国\",\"vod_year\":\"2026\"},{\"vod_id\":\"3\",\"vod_class\":\"剧情\",\"vod_area\":\"内地\",\"vod_year\":\"2025\"},{\"vod_id\":\"4\"}]}")
                        .videos;
        List<VideoFilters.Definition> fallback = VideoFilters.definitions("{}", "movie", videos);
        Map<String, String> local = new LinkedHashMap<>();
        local.put("class", "剧情");
        local.put("area", "中国大陆");
        local.put("year", "2026");
        List<Cms.Video> filtered = VideoFilters.apply(videos, fallback, local);
        check(
                filtered.size() == 1 && filtered.get(0).id.equals("1"),
                "local filters combine with AND and normalize country aliases");
        check(
                VideoFilters.apply(videos, fallback, Collections.emptyMap()).size() == 4,
                "clearing filters restores all loaded results");
        check(
                VideoFilters.apply(videos, definitions, selected).size() == 4,
                "remote filtering does not reject missing listing metadata");
        check(
                !VideoFilters.matches("20260", "2026", "year"),
                "year does not partially match another number");
        check(
                VideoFilters.definitions("not json", "movie", videos).size() == 3,
                "malformed schema retains usable metadata filters");

        String spiderSchema =
                "{\"filters\":{\"1\":[{\"key\":\"cateId\",\"name\":\"剧情\",\"value\":[{\"n\":\"全部\",\"v\":\"\"},{\"n\":\"科幻\",\"v\":\"scifi-1\"}]},{\"key\":\"area\",\"name\":\"产地\",\"value\":[{\"n\":\"全部\",\"v\":\"\"},{\"n\":\"欧美\",\"v\":\"west\"}]},{\"key\":\"yr\",\"name\":\"年份\",\"value\":[{\"n\":\"全部\",\"v\":\"\"},{\"n\":\"2025\",\"v\":\"2025\"}]}]}}";
        List<VideoFilters.Definition> spiderDefs =
                VideoFilters.definitions(spiderSchema, "1", Collections.emptyList());
        Map<String, String> spiderSelected = new LinkedHashMap<>();
        spiderSelected.put("class", "scifi-1");
        spiderSelected.put("area", "west");
        spiderSelected.put("year", "2025");
        Map<String, String> spiderWire = VideoFilters.remoteValues(spiderDefs, spiderSelected);
        check(
                "scifi-1".equals(spiderWire.get("cateId"))
                        && "west".equals(spiderWire.get("area"))
                        && "2025".equals(spiderWire.get("yr")),
                "spider filter keys (cateId/产地/yr) map cleanly to TV filter rows and wire keys");

        Map<String, String> cmsFallbackWire = VideoFilters.remoteValues(fallback, local, true);
        check(
                "剧情".equals(cmsFallbackWire.get("class"))
                        && "大陆".equals(cmsFallbackWire.get("area"))
                        && "2026".equals(cmsFallbackWire.get("year"))
                        && VideoFilters.hasLocal(fallback, local),
                "HTTP CMS fallback sends normalized query params while retaining local verification");

        List<Cms.Video> xmlVideos =
                Cms.listing(
                                "<rss><list page=\"1\" pagecount=\"2\"><video><id>x1</id><name>星际样本</name><type>科幻片</type><area>美国</area><year>2026</year></video><video><id>x2</id><name>古装样本</name><type>电影</type><note>HD / 2025 / 大陆 / 喜剧</note></video></list></rss>")
                        .videos;
        List<VideoFilters.Definition> xmlDefs = VideoFilters.definitions("{}", "1", xmlVideos);
        Map<String, String> xmlSelect = new LinkedHashMap<>();
        xmlSelect.put("class", "科幻");
        xmlSelect.put("area", "美国");
        xmlSelect.put("year", "2026");
        List<Cms.Video> xmlMatched = VideoFilters.apply(xmlVideos, xmlDefs, xmlSelect);
        check(
                xmlMatched.size() == 1 && "x1".equals(xmlMatched.get(0).id),
                "XML listing populates genre from <type> and filters accurately");
        Map<String, String> remarksSelect = new LinkedHashMap<>();
        remarksSelect.put("class", "喜剧");
        remarksSelect.put("area", "中国大陆");
        remarksSelect.put("year", "2025");
        List<Cms.Video> remarksMatched = VideoFilters.apply(xmlVideos, xmlDefs, remarksSelect);
        check(
                remarksMatched.size() == 1 && "x2".equals(remarksMatched.get(0).id),
                "remarks metadata fallback matches when structured area/year/genre are generic");

        AtomicReference<String> query = new AtomicReference<>();
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext(
                "/api",
                exchange -> {
                    query.set(exchange.getRequestURI().getRawQuery());
                    byte[] body =
                            "{\"page\":3,\"pagecount\":8,\"list\":[]}"
                                    .getBytes(StandardCharsets.UTF_8);
                    exchange.sendResponseHeaders(200, body.length);
                    exchange.getResponseBody().write(body);
                    exchange.close();
                });
        server.start();
        try {
            Cms.Site site = new Cms.Site();
            site.type = 1;
            site.api = "http://127.0.0.1:" + server.getAddress().getPort() + "/api";
            SourceEngine engine = new QueuedSourceEngine(new JsonCmsEngine(site));
            wire.put("ac", "player");
            wire.put("ids", "unwanted");
            Cms.Listing page = Cms.listing(engine.category("movie", 3, wire));
            String sent = URLDecoder.decode(query.get(), "UTF-8");
            check(
                    sent.contains("class=genre-7")
                            && sent.contains("area=US")
                            && sent.contains("year=2026")
                            && sent.contains("pg=3"),
                    "queued HTTP transport forwards every filter on later pages");
            check(
                    sent.contains("ac=detail")
                            && !sent.contains("unwanted")
                            && !sent.contains("player"),
                    "filter metadata cannot rewrite routing parameters");
            check(
                    page.videos.isEmpty() && page.pageCount == 8,
                    "empty filtered page retains server pagination");
        } finally {
            server.stop(0);
        }

        // Refactored multi-format & multi-dimension spider filters (JSON string, type_name key,
        // sort/lang/letter/extra groups preserved instead of dropped)
        String stringEncodedSchema =
                "{\"class\":[{\"type_id\":\"1\",\"type_name\":\"电影\"}],"
                        + "\"filters\":\"{\\\"电影\\\":[{\\\"key\\\":\\\"class\\\",\\\"name\\\":\\\"类型\\\",\\\"value\\\":[{\\\"n\\\":\\\"全部\\\",\\\"v\\\":\\\"\\\"},{\\\"n\\\":\\\"喜剧\\\",\\\"v\\\":\\\"comedy\\\"}]},{\\\"key\\\":\\\"by\\\",\\\"name\\\":\\\"排序\\\",\\\"value\\\":[{\\\"n\\\":\\\"按更新\\\",\\\"v\\\":\\\"time\\\"},{\\\"n\\\":\\\"高分优先\\\",\\\"v\\\":\\\"score\\\"}]},{\\\"key\\\":\\\"lang\\\",\\\"name\\\":\\\"语言\\\",\\\"value\\\":[{\\\"n\\\":\\\"国语\\\",\\\"v\\\":\\\"zh\\\"}]},{\\\"key\\\":\\\"plot\\\",\\\"name\\\":\\\"剧情\\\",\\\"value\\\":[{\\\"n\\\":\\\"悬疑\\\",\\\"v\\\":\\\"suspense\\\"}]}]}\"}";
        List<VideoFilters.Definition> multiDefs =
                VideoFilters.definitions(stringEncodedSchema, "1", Collections.emptyList());
        check(
                multiDefs.size() == 4
                        && VideoFilters.hasRemoteDefinitions(multiDefs)
                        && "class".equals(multiDefs.get(0).dimension)
                        && "by".equals(multiDefs.get(1).key)
                        && "排序".equals(multiDefs.get(1).label)
                        && "lang".equals(multiDefs.get(2).key)
                        && "plot".equals(multiDefs.get(3).key),
                "JSON-string filters keyed by type_name parse cleanly and preserve sort/lang/extra groups");
        Map<String, String> multiSelected = new LinkedHashMap<>();
        multiSelected.put(multiDefs.get(0).dimension, "comedy");
        multiSelected.put(multiDefs.get(1).dimension, "score");
        multiSelected.put(multiDefs.get(2).dimension, "zh");
        multiSelected.put(multiDefs.get(3).dimension, "suspense");
        Map<String, String> multiWire = VideoFilters.remoteValues(multiDefs, multiSelected);
        check(
                "comedy".equals(multiWire.get("class"))
                        && "score".equals(multiWire.get("by"))
                        && "zh".equals(multiWire.get("lang"))
                        && "suspense".equals(multiWire.get("plot")),
                "all multi-dimension remote spider keys forward intact without colliding");

        // Sub-category resolution for MacCMS sources lacking remote filter schemas
        List<Cms.Category> cmsCats =
                Arrays.asList(
                        new Cms.Category("1", "电影"),
                        new Cms.Category("6", "动作片"),
                        new Cms.Category("7", "喜剧片"),
                        new Cms.Category("2", "连续剧"),
                        new Cms.Category("13", "国产剧"),
                        new Cms.Category("16", "欧美剧"));
        List<VideoFilters.Definition> cmsLocalDefs =
                VideoFilters.definitions("{}", "1", Collections.emptyList());
        Map<String, String> movieComedy = new LinkedHashMap<>();
        movieComedy.put("class", "喜剧");
        VideoFilters.SubCategoryMatch subMovie =
                VideoFilters.resolveMatchingSubCategory(cmsCats, "1", cmsLocalDefs, movieComedy);
        check(
                subMovie != null
                        && "7".equals(subMovie.categoryId)
                        && "class".equals(subMovie.satisfiedDimension),
                "MacCMS parent movie category + 喜剧 resolves to concrete sub-category 喜剧片 (id=7)");
        Map<String, String> dramaUs = new LinkedHashMap<>();
        dramaUs.put("area", "美国");
        VideoFilters.SubCategoryMatch subDrama =
                VideoFilters.resolveMatchingSubCategory(cmsCats, "2", cmsLocalDefs, dramaUs);
        check(
                subDrama != null
                        && "16".equals(subDrama.categoryId)
                        && "area".equals(subDrama.satisfiedDimension),
                "MacCMS parent drama category + 美国 resolves to concrete sub-category 欧美剧 (id=16)");

        // Remote-filter honoring verification + automatic local fallback
        List<Cms.Video> year2026Videos =
                Cms.listing(
                                "{\"list\":[{\"vod_id\":\"a\",\"vod_year\":\"2026\",\"vod_area\":\"美国\"},{\"vod_id\":\"b\",\"vod_year\":\"2026\",\"vod_area\":\"美国\"},{\"vod_id\":\"c\",\"vod_year\":\"2026\",\"vod_area\":\"美国\"},{\"vod_id\":\"d\",\"vod_year\":\"2026\",\"vod_area\":\"美国\"}]}")
                        .videos;
        Map<String, String> want2024 = new LinkedHashMap<>();
        want2024.put("year", "2024");
        check(
                !VideoFilters.looksSourceHonored(year2026Videos, definitions, want2024),
                "looksSourceHonored detects when remote source ignored explicit year filter");
        check(
                VideoFilters.isIdenticalListing(year2026Videos, new ArrayList<>(year2026Videos)),
                "isIdenticalListing detects unchanged unfiltered feed returned for filtered query");
        check(
                VideoFilters.applyAll(year2026Videos, definitions, want2024, null).isEmpty(),
                "applyAll enforces local filtering even on remote definitions when server ignores filter");
    }
}
