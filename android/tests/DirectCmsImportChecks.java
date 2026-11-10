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
                                        return new HttpURLConnection(url) {
                                            public void connect() {}

                                            public void disconnect() {}

                                            public boolean usingProxy() {
                                                return false;
                                            }

                                            public int getResponseCode() {
                                                return 200;
                                            }

                                            public InputStream getInputStream() {
                                                return new ByteArrayInputStream(
                                                        RESPONSE.getBytes(StandardCharsets.UTF_8));
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
        System.out.println("OK " + count + " direct CMS import checks");
    }
}
