import com.pilipala.marcomovie.Cms;
import com.pilipala.marcomovie.JsonCmsEngine;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLStreamHandler;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Synthetic CMS fixtures only; no user endpoints or response content. */
public final class DirectCmsImportChecks {
    private static int count;
    private static final List<String> requests = new ArrayList<>();
    private static final String RESPONSE =
            "{\"code\":1,\"page\":1,\"pagecount\":2,\"limit\":20,\"total\":21,"
                    + "\"class\":[{\"type_id\":\"7\",\"type_name\":\"Mock\"}],"
                    + "\"list\":[{\"vod_id\":\"42\",\"vod_name\":\"Mock video\",\"vod_play_from\":\"Mock\","
                    + "\"vod_play_url\":\"Episode$https://media.test/example.mp4\"}]}";

    private static void installMockTransport() {
        URL.setURLStreamHandlerFactory(
                protocol ->
                        "http".equals(protocol)
                                ? new URLStreamHandler() {
                                    @Override
                                    protected HttpURLConnection openConnection(URL url) {
                                        requests.add(url.toString());
                                        String host = url.getHost();
                                        return new HttpURLConnection(url) {
                                            private final java.util.Map<String, List<String>>
                                                    headers = new java.util.HashMap<>();
                                            private int responseCode = 200;
                                            private byte[] responseBody =
                                                    RESPONSE.getBytes(StandardCharsets.UTF_8);

                                            @Override
                                            public void setRequestProperty(
                                                    String key, String value) {
                                                super.setRequestProperty(key, value);
                                                if (key != null && value != null) {
                                                    List<String> list = new ArrayList<>();
                                                    list.add(value);
                                                    headers.put(key, list);
                                                }
                                            }

                                            public void connect() {}

                                            public void disconnect() {}

                                            public boolean usingProxy() {
                                                return false;
                                            }

                                            public int getResponseCode()
                                                    throws java.io.IOException {
                                                if ("timeout-no-retry.test".equals(host)) {
                                                    throw new java.net.SocketTimeoutException(
                                                            "connect timed out");
                                                }
                                                if ("dns-no-retry.test".equals(host)) {
                                                    throw new java.net.UnknownHostException(
                                                            "dns-no-retry.test");
                                                }
                                                if ("dual-ua.test".equals(host)) {
                                                    String ua = getRequestProperty("User-Agent");
                                                    if (Cms.USER_AGENT.equals(ua)) {
                                                        responseCode = 403;
                                                        responseBody =
                                                                "<html><body>403 Forbidden</body></html>"
                                                                        .getBytes(
                                                                                StandardCharsets
                                                                                        .UTF_8);
                                                    } else if (Cms.SAFARI_USER_AGENT.equals(ua)) {
                                                        responseCode = 200;
                                                        responseBody =
                                                                "{\"sites\":[{\"key\":\"dual\",\"name\":\"Dual\",\"api\":\"http://cms.test/api\"}]}"
                                                                        .getBytes(
                                                                                StandardCharsets
                                                                                        .UTF_8);
                                                    }
                                                } else if ("html-error.test".equals(host)) {
                                                    responseCode = 200;
                                                    headers.put(
                                                            "Content-Type",
                                                            Arrays.asList(
                                                                    "text/html; charset=utf-8"));
                                                    responseBody =
                                                            "<!DOCTYPE html><html><body>Login Required</body></html>"
                                                                    .getBytes(
                                                                            StandardCharsets.UTF_8);
                                                } else if ("cms-text-html.test".equals(host)) {
                                                    responseCode = 200;
                                                    headers.put(
                                                            "Content-Type",
                                                            Arrays.asList(
                                                                    "text/html; charset=utf-8"));
                                                    responseBody =
                                                            RESPONSE.getBytes(
                                                                    StandardCharsets.UTF_8);
                                                } else if ("share-page.test".equals(host)) {
                                                    responseCode = 200;
                                                    headers.put(
                                                            "Content-Type",
                                                            Arrays.asList(
                                                                    "text/html; charset=utf-8"));
                                                    responseBody =
                                                            "<!doctype html><html><body><script>var play='https://cdn.test/live.m3u8';</script></body></html>"
                                                                    .getBytes(
                                                                            StandardCharsets.UTF_8);
                                                } else if ("html-ua-fallback.test".equals(host)) {
                                                    String ua = getRequestProperty("User-Agent");
                                                    headers.put(
                                                            "Content-Type",
                                                            Arrays.asList(
                                                                    "text/html; charset=utf-8"));
                                                    if (Cms.USER_AGENT.equals(ua)) {
                                                        responseCode = 200;
                                                        responseBody =
                                                                "<html><body>WAF challenge</body></html>"
                                                                        .getBytes(
                                                                                StandardCharsets
                                                                                        .UTF_8);
                                                    } else if (Cms.SAFARI_USER_AGENT.equals(ua)) {
                                                        responseCode = 200;
                                                        responseBody =
                                                                "{\"sites\":[{\"key\":\"safari-ok\",\"name\":\"SafariOK\",\"api\":\"http://cms.test/api\"}]}"
                                                                        .getBytes(
                                                                                StandardCharsets
                                                                                        .UTF_8);
                                                    }
                                                } else if ("timeout-no-retry.test".equals(host)) {
                                                    throw new java.net.SocketTimeoutException(
                                                            "connect timed out");
                                                } else if ("dns-no-retry.test".equals(host)) {
                                                    throw new java.net.UnknownHostException(
                                                            "dns-no-retry.test");
                                                } else if ("http500-no-retry.test".equals(host)) {
                                                    responseCode = 500;
                                                    responseBody =
                                                            "server error"
                                                                    .getBytes(
                                                                            StandardCharsets.UTF_8);
                                                } else if ("cookie-redirect.test".equals(host)) {
                                                    String path = url.getPath();
                                                    if ("/step1".equals(path)) {
                                                        responseCode = 302;
                                                        headers.put(
                                                                "Location",
                                                                Arrays.asList(
                                                                        "http://cookie-redirect.test/step2"));
                                                        headers.put(
                                                                "Set-Cookie",
                                                                Arrays.asList(
                                                                        "session_id=abc12345; Path=/"));
                                                        responseBody = new byte[0];
                                                    } else if ("/step2".equals(path)) {
                                                        String cookie =
                                                                getRequestProperty("Cookie");
                                                        if (cookie != null
                                                                && cookie.contains(
                                                                        "session_id=abc12345")) {
                                                            responseCode = 302;
                                                            headers.put(
                                                                    "Location",
                                                                    Arrays.asList(
                                                                            "http://cross-domain.test/step3"));
                                                            responseBody = new byte[0];
                                                        } else {
                                                            responseCode = 500;
                                                            responseBody =
                                                                    "missing cookie"
                                                                            .getBytes(
                                                                                    StandardCharsets
                                                                                            .UTF_8);
                                                        }
                                                    }
                                                } else if ("cross-domain.test".equals(host)) {
                                                    String cookie = getRequestProperty("Cookie");
                                                    if (cookie == null
                                                            || !cookie.contains(
                                                                    "session_id=abc12345")) {
                                                        responseCode = 200;
                                                        responseBody =
                                                                "{\"sites\":[{\"key\":\"ok\",\"name\":\"OK\",\"api\":\"http://cms.test/api\"}]}"
                                                                        .getBytes(
                                                                                StandardCharsets
                                                                                        .UTF_8);
                                                    } else {
                                                        responseCode = 500;
                                                        responseBody =
                                                                "leaked cookie"
                                                                        .getBytes(
                                                                                StandardCharsets
                                                                                        .UTF_8);
                                                    }
                                                }
                                                return responseCode;
                                            }

                                            @Override
                                            public java.util.Map<String, List<String>>
                                                    getHeaderFields() {
                                                return headers;
                                            }

                                            @Override
                                            public String getHeaderField(String name) {
                                                for (java.util.Map.Entry<String, List<String>> e :
                                                        headers.entrySet()) {
                                                    if (e.getKey() != null
                                                            && e.getKey().equalsIgnoreCase(name)) {
                                                        List<String> list = e.getValue();
                                                        return (list != null && !list.isEmpty())
                                                                ? list.get(0)
                                                                : null;
                                                    }
                                                }
                                                return null;
                                            }

                                            public InputStream getInputStream() {
                                                return new ByteArrayInputStream(responseBody);
                                            }
                                        };
                                    }
                                }
                                : null);
    }

    private static void check(boolean condition, String label) {
        if (!condition) throw new AssertionError(label);
        System.out.println("PASS " + label);
        count++;
    }

    private static void rejects(String raw, String origin, String label) throws Exception {
        try {
            Cms.parseConfig(raw, origin);
        } catch (Exception expected) {
            check(true, label);
            return;
        }
        throw new AssertionError(label);
    }

    public static void main(String[] args) throws Exception {
        installMockTransport();
        String base = "http://cms.test/api.php/provide/vod/";
        String response = Cms.fetch(base, null);
        String origin = base + "?token=a%2Bb&at=json&ac=detail&ids=old&t=99&wd=old&pg=7#hint";
        Cms.Config config = Cms.parseConfig(response, origin);
        check(config.sites.size() == 1, "direct CMS response imports one site");
        Cms.Site site = config.sites.get(0);
        check(site.type == 1 && site.supported(), "direct JSON API uses native CMS engine");
        check(
                site.api.equals(base + "?token=a%2Bb&at=json"),
                "request filters removed; auth and format preserved");
        check(
                !site.name.contains("token") && !site.name.contains("a%2Bb"),
                "display name excludes query secrets");
        check(config.origin.equals(origin), "original import address retained for refresh");
        JSONObject saved = new JSONObject(config.raw);
        check(
                saved.optJSONArray("sites").length() == 1 && !saved.has("list"),
                "saved config contains site, not transient catalog");
        Cms.Config restored = Cms.parseConfig(config.raw, "");
        check(
                restored.sites.get(0).api.equals(site.api),
                "saved config reimports without original response");
        check(restored.sites.get(0).key.equals(site.key), "site identity survives restart");
        Cms.Config refreshed = Cms.parseConfig(response, site.api);
        check(
                refreshed.sites.get(0).key.equals(site.key),
                "identity independent of request filters");

        JsonCmsEngine engine = new JsonCmsEngine(site);
        check(Cms.categories(engine.home()).size() == 1, "imported source loads categories");
        check(
                Cms.listing(engine.category("7", 2)).videos.size() == 1,
                "imported source loads paged category");
        check(
                Cms.listing(engine.detail("42")).videos.get(0).lines.size() == 1,
                "imported source loads playable detail");
        check(
                Cms.listing(engine.search("中文", 1)).videos.size() == 1,
                "imported source supports search");
        String clean = base + "?token=a%2Bb&at=json&";
        check(
                requests.equals(
                        Arrays.asList(
                                base,
                                clean + "ac=list",
                                clean + "ac=detail&t=7&pg=2",
                                clean + "ac=detail&ids=42",
                                clean + "ac=detail&wd=%E4%B8%AD%E6%96%87&pg=1")),
                "all CMS requests preserve auth and exclude stale request filters");

        String categoriesOnly = "{\"class\":[{\"type_id\":7,\"type_name\":\"Mock\"}],\"list\":[]}";
        check(
                Cms.parseConfig(categoriesOnly, base).sites.size() == 1,
                "empty home with CMS categories imports");
        String empty =
                "{\"code\":1,\"page\":1,\"pagecount\":0,\"limit\":20,\"total\":0,\"list\":[]}";
        check(Cms.parseConfig(empty, base).sites.size() == 1, "valid empty paginated CMS imports");
        check(
                Cms.parseConfig("\uFEFF  " + response, base).sites.size() == 1,
                "BOM-prefixed CMS imports");
        String videosOnly = "{\"list\":[{\"vod_id\":42,\"vod_name\":\"Mock\"}]}";
        check(
                Cms.parseConfig(videosOnly, base).sites.size() == 1,
                "CMS detection uses payload, not URL suffix");
        check(
                Cms.parseConfig(videosOnly, "https://cms.test/custom?key=x").sites.size() == 1,
                "custom CMS path accepted");

        JSONObject tagged =
                new JSONObject(response)
                        .put("_marco_origin", base)
                        .put("_marco_warehouse", "https://config.test/warehouse.json")
                        .put(
                                "_marco_depots",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("name", "Mock")
                                                        .put("url", base)));
        Cms.Config warehouse =
                Cms.parseConfig(tagged.toString(), "https://config.test/warehouse.json");
        check(
                warehouse.sites.get(0).api.equals(base)
                        && warehouse.warehouse.equals("https://config.test/warehouse.json")
                        && warehouse.depots.length() == 1,
                "warehouse leaf retains endpoint and directory metadata");

        String existing =
                "{\"sites\":[{\"key\":\"keep\",\"name\":\"Existing\",\"type\":1,\"api\":\"https://cms.test/api\"}],\"list\":[{\"vod_id\":1,\"vod_name\":\"Mock\"}]}";
        check(
                Cms.parseConfig(existing, base).sites.get(0).key.equals("keep"),
                "explicit sites keep priority");
        check(
                Cms.parseConfig("{\"api\":\"https://cms.test/api\",\"type\":1}", base)
                        .sites
                        .get(0)
                        .api
                        .equals("https://cms.test/api"),
                "single-site descriptor still supported");
        rejects(response, null, "raw CMS data requires an HTTP origin");
        rejects(response, "file:///tmp/data.json", "local catalog dump is not an API");
        rejects("{\"list\":[{\"id\":1,\"name\":\"Other\"}]}", base, "generic JSON list rejected");
        rejects("{\"code\":1,\"list\":[]}", base, "ambiguous empty response rejected");
        rejects(
                "{\"sites\":[],\"list\":[{\"vod_id\":1,\"vod_name\":\"Mock\"}]}",
                base,
                "invalid explicit config not reclassified");
        rejects(
                "{\"code\":403,\"class\":[{\"type_id\":1,\"type_name\":\"Mock\"}],\"list\":[]}",
                base,
                "API error response rejected");
        rejects("<html><body>Login required</body></html>", base, "HTML response rejected");

        // Dual-UA retry on 403 and HTML, and Content-Type text/html acceptance
        String dualResult = Cms.fetchImport("http://dual-ua.test/config.json");
        check(
                dualResult.contains("\"key\":\"dual\""),
                "dual-UA retries with Safari UA on HTTP 403");

        String htmlFallbackResult = Cms.fetchImport("http://html-ua-fallback.test/config.json");
        check(
                htmlFallbackResult.contains("\"key\":\"safari-ok\""),
                "dual-UA retries with Safari UA on HTML body and accepts text/html JSON");

        String textHtmlJson = Cms.fetch("http://cms-text-html.test/api.php", null);
        check(
                textHtmlJson.contains("\"vod_id\":\"42\""),
                "generic Cms.fetch accepts JSON served with Content-Type text/html");
        String textHtmlImport = Cms.fetchImport("http://cms-text-html.test/api.php");
        check(
                textHtmlImport.contains("\"vod_id\":\"42\""),
                "Cms.fetchImport inspects body prefix rather than Content-Type text/html");

        int beforeShareFetch = requests.size();
        String shareHtml = Cms.fetch("http://share-page.test/watch/1", null);
        check(
                shareHtml.contains("https://cdn.test/live.m3u8")
                        && requests.size() - beforeShareFetch == 1,
                "generic Cms.fetch accepts HTML pages in a single request without UA retry");

        int beforeTimeout = requests.size();
        boolean timeoutCaught = false;
        try {
            Cms.fetchImport("http://timeout-no-retry.test/config.json");
        } catch (java.net.SocketTimeoutException expected) {
            timeoutCaught = true;
        }
        check(
                timeoutCaught && requests.size() - beforeTimeout == 1,
                "Cms.fetchImport does not retry Safari UA on timeout");

        int beforeDns = requests.size();
        boolean dnsCaught = false;
        try {
            Cms.fetchImport("http://dns-no-retry.test/config.json");
        } catch (java.net.UnknownHostException expected) {
            dnsCaught = true;
        }
        check(
                dnsCaught && requests.size() - beforeDns == 1,
                "Cms.fetchImport does not retry Safari UA on DNS failure");

        int before500 = requests.size();
        boolean err500Caught = false;
        try {
            Cms.fetchImport("http://http500-no-retry.test/config.json");
        } catch (java.io.IOException expected) {
            err500Caught = true;
        }
        check(
                err500Caught && requests.size() - before500 == 1,
                "Cms.fetchImport does not retry Safari UA on HTTP 500");

        // HTML diagnostic error
        boolean htmlDiagnosticCaught = false;
        try {
            Cms.fetchImport("http://html-error.test/page.html");
        } catch (java.io.IOException e) {
            htmlDiagnosticCaught =
                    e.getMessage() != null && e.getMessage().contains("地址返回的是网页而不是配置（可能需要登录或被拦截）");
        }
        check(htmlDiagnosticCaught, "HTML response throws diagnostic error message");

        // Cross-redirect cookie preservation and stripping
        String cookieResult = Cms.fetch("http://cookie-redirect.test/step1", null);
        check(
                cookieResult.contains("\"key\":\"ok\""),
                "cross-redirect preserves same-domain cookies and strips cross-domain");

        // Gzip bomb protection
        java.io.ByteArrayOutputStream bombOut = new java.io.ByteArrayOutputStream();
        try (java.util.zip.GZIPOutputStream gzos = new java.util.zip.GZIPOutputStream(bombOut)) {
            byte[] chunk = new byte[65536];
            for (int i = 0; i < 270; i++) {
                gzos.write(chunk);
            }
        }
        byte[] bombBytes = bombOut.toByteArray();
        boolean bombCaught = false;
        try {
            Cms.document(bombBytes);
        } catch (java.io.IOException e) {
            bombCaught = e.getMessage() != null && e.getMessage().contains("解压后内容超过大小限制");
        }
        check(bombCaught, "gzip bomb exceeding MAX_JSON is rejected");

        // Valid gzip payload decompression
        java.io.ByteArrayOutputStream validGzOut = new java.io.ByteArrayOutputStream();
        try (java.util.zip.GZIPOutputStream gzos = new java.util.zip.GZIPOutputStream(validGzOut)) {
            gzos.write(
                    "{\"sites\":[{\"key\":\"gz\",\"name\":\"GZ\",\"api\":\"http://cms.test/api\"}]}"
                            .getBytes(StandardCharsets.UTF_8));
        }
        String decompressed = Cms.document(validGzOut.toByteArray());
        check(decompressed.contains("\"key\":\"gz\""), "valid gzip payload is decompressed");

        // Capability status and limitation reasons (7 unified statuses)
        Cms.Site sOk = new Cms.Site();
        sOk.type = 1;
        sOk.api = "http://cms.test/api";
        check(
                Cms.Site.STATUS_OK.equals(sOk.capabilityStatus())
                        && "正常可用".equals(sOk.limitation()),
                "capability status ok");

        Cms.Site sJar = new Cms.Site();
        sJar.type = 3;
        sJar.api = "http://cms.test/spider.jar";
        check(
                Cms.Site.STATUS_NEEDS_JAR.equals(sJar.capabilityStatus())
                        && "此来源需要 Spider / JS / JAR 运行环境，基础版尚未支持".equals(sJar.limitation()),
                "capability status needs-jar");

        Cms.Site sType = new Cms.Site();
        sType.type = 99;
        sType.api = "http://cms.test/unknown";
        check(
                Cms.Site.STATUS_UNSUPPORTED_TYPE.equals(sType.capabilityStatus())
                        && "暂不支持此类型来源，已保留在列表中".equals(sType.limitation()),
                "capability status unsupported-type");

        Cms.Site sNetdisk = new Cms.Site();
        sNetdisk.type = 3;
        sNetdisk.api = "csp_Ali";
        sNetdisk.name = "阿里网盘";
        check(
                Cms.Site.STATUS_ADAPTER_MISSING.equals(sNetdisk.capabilityStatus())
                        && "此网盘源的原始插件尚未适配当前设备，无法读取原始网盘线路".equals(sNetdisk.limitation()),
                "capability status adapter-missing");

        Cms.Site sExt = new Cms.Site();
        sExt.type = 1;
        sExt.api = "http://cms.test/api";
        sExt.extTooLarge = true;
        check(
                Cms.Site.STATUS_EXT_TOO_LARGE.equals(sExt.capabilityStatus())
                        && "扩展参数超过大小上限，无法加载".equals(sExt.limitation()),
                "capability status ext-too-large");

        Cms.Site sUrl = new Cms.Site();
        sUrl.type = 1;
        sUrl.api = "custom://invalid";
        check(
                Cms.Site.STATUS_CUSTOM_SITE_URL.equals(sUrl.capabilityStatus())
                        && "此来源不是可直接请求的 HTTP(S) CMS".equals(sUrl.limitation()),
                "capability status custom-site-url");

        Cms.Site sParse = new Cms.Site();
        sParse.type = 1;
        sParse.api = "http://cms.test/api";
        sParse.requiresParser = true;
        sParse.playUrl = "";
        check(
                Cms.Site.STATUS_OK.equals(sParse.capabilityStatus())
                        && sParse.supported()
                        && "需要解析器，当前环境缺少可用解析配置".equals(sParse.playbackHint()),
                "capability status parser-required remains browseable with playbackHint");

        Cms.Config explicitJarCms =
                Cms.parseConfig(
                        "{\"sites\":["
                                + "{\"key\":\"cms1\",\"name\":\"CMS1\",\"type\":1,\"api\":\"http://cms.test/api.php/provide/vod/\",\"jar\":\"./custom_spider.jar;md5;deadbeef\"},"
                                + "{\"key\":\"cms0\",\"name\":\"CMS0\",\"type\":0,\"api\":\"http://cms.test/api.php/provide/vod/at/xml/\",\"jar\":\"./custom_spider.jar\"},"
                                + "{\"key\":\"jar_implicit\",\"name\":\"JarImplicit\",\"api\":\"http://cms.test/api\",\"jar\":\"./custom_spider.jar\"}"
                                + "]}",
                        "http://cms.test/box.json");
        check(
                Cms.Site.STATUS_OK.equals(explicitJarCms.sites.get(0).capabilityStatus())
                        && explicitJarCms.sites.get(0).supported()
                        && Cms.Site.STATUS_OK.equals(explicitJarCms.sites.get(1).capabilityStatus())
                        && explicitJarCms.sites.get(1).supported()
                        && Cms.Site.STATUS_NEEDS_JAR.equals(
                                explicitJarCms.sites.get(2).capabilityStatus())
                        && !explicitJarCms.sites.get(2).supported(),
                "explicit type 0/1 CMS sites with jar remain STATUS_OK while implicit jar-backed site requires jar");

        String contentOrigin =
                Cms.localImportOrigin(
                        "content",
                        "content://com.android.providers.downloads.documents/document/primary%3Atvbox.json");
        Cms.Config contentImported =
                Cms.parseConfig(
                        "{\"sites\":[{\"key\":\"s1\",\"name\":\"S1\",\"type\":1,\"api\":\"https://cms.test/api\",\"ext\":\"./sub.json\"}]}",
                        contentOrigin.isEmpty() ? null : contentOrigin);
        java.nio.file.Path realCfgPath =
                java.nio.file.Paths.get(
                        System.getProperty("java.io.tmpdir"), "mm_pkg_test", "config.json");
        java.nio.file.Path realSubPath =
                java.nio.file.Paths.get(
                        System.getProperty("java.io.tmpdir"), "mm_pkg_test", "sub.json");
        String fileOrigin = Cms.localImportOrigin("file", realCfgPath.toUri().toASCIIString());
        Cms.Config fileImported =
                Cms.parseConfig(
                        "{\"sites\":[{\"key\":\"s1\",\"name\":\"S1\",\"type\":1,\"api\":\"https://cms.test/api\",\"ext\":\"./sub.json\"}]}",
                        fileOrigin);
        check(
                contentOrigin.isEmpty()
                        && contentImported.origin.isEmpty()
                        && "./sub.json".equals(contentImported.sites.get(0).ext)
                        && realCfgPath.toUri().toASCIIString().equals(fileOrigin)
                        && realSubPath
                                .toUri()
                                .toASCIIString()
                                .equals(fileImported.sites.get(0).ext),
                "content:// import keeps origin empty instead of fabricating file:///document/...");

        System.out.println("OK " + count + " direct CMS import checks");
    }
}
