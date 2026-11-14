import com.pilipala.marcomovie.*;
import com.pilipala.source.Json;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import org.json.*;

public final class CmsChecks {
    static int count;

    static void check(boolean b, String label) {
        if (!b) throw new AssertionError(label);
        System.out.println("PASS " + label);
        count++;
    }

    public static void main(String[] args) throws Exception {
        check(
                Cms.normalizeHttp("https://例子.test/config")
                        .equals("https://xn--fsqu00a.test/config"),
                "IDN host converted");
        String cfg =
                "{\"sites\":[{\"key\":\"a\",\"name\":\"Local\",\"type\":1,\"api\":\"/cms?token=x&ac=old\",\"header\":{\"Referer\":\"http://example.test/\"}}]}";
        Cms.Config c = Cms.parseConfig(cfg, args[1]);
        Cms.Site s = c.sites.get(0);
        check(s.supported(), "standard type1 selected");
        String query = Cms.query(s.api, "ac", "list");
        check(
                query.contains("token=x") && !query.contains("ac=old"),
                "query replaces parameters and retains credentials privately");
        SourceEngine engine = new JsonCmsEngine(s);
        check(Cms.categories(engine.home()).size() == 1, "mock CMS category fetch");
        Cms.Listing list = Cms.listing(engine.category("7", 1));
        check(list.videos.size() == 1 && list.pageCount == 2, "mock paged listing");
        Cms.Video v = Cms.listing(engine.detail("42")).videos.get(0);
        check(
                v.lines.size() == 2 && v.lines.get(0).episodes.size() == 2,
                "multi-line and episode separators");
        check(v.lines.get(0).episodes.get(0).url.contains("x=1$2"), "episode URL dollar retained");
        check(Cms.listing(engine.search("中文", 1)).videos.size() == 1, "mock unicode search");
        boolean blocked = false;
        try {
            Cms.assertMedia(args[1] + "web", s.headers);
        } catch (IOException e) {
            blocked = true;
        }
        check(blocked, "HTML parser page rejected before player");
        Cms.assertMedia(args[1] + "video.mp4", s.headers);
        check(true, "direct media accepted");
        blocked = false;
        try {
            Cms.parseConfig("{\"sites\":[]}", null);
        } catch (IOException e) {
            blocked = true;
        }
        check(blocked, "empty config failure");
        check(
                Cms.withoutComments("{\"a\":\"https://x/*y*/\",/*z*/\"b\":1//e\n}")
                        .contains("https://x/*y*/"),
                "comments stripped without changing URL strings");
        Cms.ImageRequest picture =
                Cms.imageRequest(
                        "https://image.test/p.jpg@Referer=https://catalog.test/@User-Agent=Mozilla/5.0");
        check(
                picture.url.equals("https://image.test/p.jpg")
                        && picture.headers.get("Referer").equals("https://catalog.test/")
                        && picture.headers.get("User-Agent").equals("Mozilla/5.0"),
                "actual poster header suffix separated from image URL");
        testLaneCAdditions();
        System.out.println("OK " + count + " checks");
    }

    private static void testLaneCAdditions() throws Exception {
        // C1: Direct Json class behavior
        JSONObject testObj = new JSONObject();
        testObj.put("nullKey", JSONObject.NULL);
        testObj.put("strKey", "  hello  ");
        testObj.put("intKey", 42);
        testObj.put("boolKey", true);
        check(Json.str(testObj, "nullKey", "fb").equals("fb"), "Json.str nullKey returns fallback");
        check(
                Json.str(testObj, "missingKey", "fb").equals("fb"),
                "Json.str missingKey returns fallback");
        check(Json.str(testObj, "strKey", "fb").equals("hello"), "Json.str trims non-null string");
        check(
                Json.str(testObj, "strKey").equals("hello"),
                "Json.str two-arg overload trims non-null string");
        check(
                Json.str(testObj, "nullKey").equals(""),
                "Json.str two-arg overload returns empty string on null");
        check(Json.integer(testObj, "nullKey", 99) == 99, "Json.integer nullKey returns fallback");
        check(Json.integer(testObj, "intKey", 99) == 42, "Json.integer intKey returns value");
        check(!Json.bool(testObj, "nullKey", false), "Json.bool nullKey returns fallback");
        check(Json.bool(testObj, "boolKey", false), "Json.bool boolKey returns value");

        // C1: Config parsing with explicit JSONObject.NULL
        JSONObject nullCfg = new JSONObject();
        nullCfg.put("spider", JSONObject.NULL);
        nullCfg.put("jar", JSONObject.NULL);
        nullCfg.put(com.pilipala.source.Warehouse.ROOT, JSONObject.NULL);
        JSONArray siteArr = new JSONArray();
        JSONObject siteObj = new JSONObject();
        siteObj.put("key", "null-site");
        siteObj.put("name", "Null Site");
        siteObj.put("api", "http://127.0.0.1/api.php?ac=videolist");
        siteObj.put("playUrl", JSONObject.NULL);
        siteObj.put("ua", JSONObject.NULL);
        siteObj.put("jar", JSONObject.NULL);
        siteObj.put("ext", JSONObject.NULL);
        siteArr.put(siteObj);
        nullCfg.put("sites", siteArr);
        Cms.Config parsedNullCfg =
                Cms.parseConfig(nullCfg.toString(), "http://127.0.0.1/config.json");
        check(parsedNullCfg.spider.isEmpty(), "spider with null degrades to empty string");
        check(parsedNullCfg.warehouse.isEmpty(), "warehouse with null degrades to empty string");
        Cms.Site sNull = parsedNullCfg.sites.get(0);
        check(sNull.playUrl.isEmpty(), "playUrl with null degrades to empty string");
        check(!sNull.requiresParser, "playUrl null does not falsely trigger requiresParser");
        check(
                Cms.USER_AGENT.equals(sNull.headers.get("User-Agent")),
                "User-Agent null does not overwrite default with literal null");
        check(
                sNull.jar == null || sNull.jar.isEmpty(),
                "jar null does not produce literal null string");

        // C2: Missing type HTTP CMS defaults
        String missingTypeXml =
                "{\"sites\":[{\"key\":\"xml1\",\"name\":\"Xml1\",\"api\":\"http://127.0.0.1/vod.xml\"}]}";
        Cms.Config cXml = Cms.parseConfig(missingTypeXml, "http://127.0.0.1/config.json");
        check(
                cXml.sites.get(0).type == 0 && cXml.sites.get(0).supported(),
                "missing type vod.xml defaults to type 0 XML and is supported");

        String missingTypeXmlPath =
                "{\"sites\":[{\"key\":\"xml2\",\"name\":\"Xml2\",\"api\":\"http://127.0.0.1/api.php/provide/vod/at/xml\"}]}";
        Cms.Config cXmlPath = Cms.parseConfig(missingTypeXmlPath, "http://127.0.0.1/config.json");
        check(
                cXmlPath.sites.get(0).type == 0 && cXmlPath.sites.get(0).supported(),
                "missing type with xml in path defaults to type 0 XML and is supported");

        String missingTypeJson =
                "{\"sites\":[{\"key\":\"json1\",\"name\":\"Json1\",\"api\":\"http://127.0.0.1/api.php?ac=videolist\"}]}";
        Cms.Config cJson = Cms.parseConfig(missingTypeJson, "http://127.0.0.1/config.json");
        check(
                cJson.sites.get(0).type == 1 && cJson.sites.get(0).supported(),
                "missing type non-xml defaults to type 1 JSON and is supported");

        String missingTypeXmlHost =
                "{\"sites\":[{\"key\":\"xmlhost\",\"name\":\"XmlHost\",\"api\":\"https://xmlcms.test/api.php/provide/vod\"}]}";
        Cms.Config cXmlHost =
                Cms.parseConfig(missingTypeXmlHost, "https://xmlcms.test/config.json");
        check(
                cXmlHost.sites.get(0).type == 1 && cXmlHost.sites.get(0).supported(),
                "missing type checks URL path only and does not misclassify xml host as XML");

        for (String scriptApi :
                new String[] {
                    "https://site.example/spider.js",
                    "https://site.example/spider.mjs",
                    "https://site.example/spider.py",
                    "https://site.example/spider.jar",
                    "csp_CustomSpider"
                }) {
            String rawNoType =
                    "{\"sites\":[{\"key\":\"noType\",\"name\":\"NoType\",\"api\":\""
                            + scriptApi
                            + "\"}]}";
            Cms.Site noTypeSite =
                    Cms.parseConfig(rawNoType, "https://site.example/config.json").sites.get(0);
            check(
                    noTypeSite.type == -1 && !noTypeSite.supported(),
                    "missing type script/jar api not treated as CMS: " + scriptApi);
        }

        String missingTypeWithJar =
                "{\"sites\":[{\"key\":\"withJar\",\"name\":\"WithJar\",\"api\":\"https://site.example/api/vod\",\"jar\":\"./custom.jar\"}]}";
        Cms.Site jarSite =
                Cms.parseConfig(missingTypeWithJar, "https://site.example/config.json")
                        .sites
                        .get(0);
        check(
                jarSite.type == -1 && !jarSite.supported(),
                "missing type site with jar field is not treated as CMS");

        // C4: Relative ext resolution with HTTP and file origins
        String httpOrigin = "https://site.example/sub/config.json";
        String httpRelCfg =
                "{\"sites\":[{\"key\":\"rel1\",\"name\":\"Rel1\",\"type\":1,\"api\":\"https://site.example/api\",\"ext\":\"./rules/custom.json\"}]}";
        Cms.Config cRelHttp = Cms.parseConfig(httpRelCfg, httpOrigin);
        check(
                "https://site.example/sub/rules/custom.json".equals(cRelHttp.sites.get(0).ext),
                "HTTP origin resolves relative string ext ./");

        String httpDotDotCfg =
                "{\"sites\":[{\"key\":\"rel2\",\"name\":\"Rel2\",\"type\":1,\"api\":\"https://site.example/api\",\"ext\":\"../top_rule.js\"}]}";
        Cms.Config cDotDotHttp = Cms.parseConfig(httpDotDotCfg, httpOrigin);
        check(
                "https://site.example/top_rule.js".equals(cDotDotHttp.sites.get(0).ext),
                "HTTP origin resolves relative string ext ../");

        JSONObject objExtCfg = new JSONObject();
        JSONArray objExtSites = new JSONArray();
        JSONObject siteObjExt = new JSONObject();
        siteObjExt.put("key", "relObj");
        siteObjExt.put("name", "RelObj");
        siteObjExt.put("type", 1);
        siteObjExt.put("api", "https://site.example/api");
        JSONObject innerExt = new JSONObject();
        innerExt.put("json", "./data/data.json");
        innerExt.put("url", "../remote/feed.json");
        innerExt.put("rule", "./script.js");
        innerExt.put("normal", "keepMe");
        siteObjExt.put("ext", innerExt);
        objExtSites.put(siteObjExt);
        objExtCfg.put("sites", objExtSites);
        Cms.Config cObjExt = Cms.parseConfig(objExtCfg.toString(), httpOrigin);
        JSONObject resolvedExtObj = (JSONObject) cObjExt.sites.get(0).ext;
        check(
                "https://site.example/sub/data/data.json".equals(resolvedExtObj.optString("json")),
                "HTTP origin resolves object ext.json ./");
        check(
                "https://site.example/remote/feed.json".equals(resolvedExtObj.optString("url")),
                "HTTP origin resolves object ext.url ../");
        check(
                "https://site.example/sub/script.js".equals(resolvedExtObj.optString("rule")),
                "HTTP origin resolves object ext.rule ./");
        check(
                "keepMe".equals(resolvedExtObj.optString("normal")),
                "HTTP origin leaves non-path object ext fields untouched");

        String fileOrigin = "file:///sdcard/Download/tvbox.json";
        String fileRelCfg =
                "{\"sites\":[{\"key\":\"fileRel\",\"name\":\"FileRel\",\"type\":1,\"api\":\"http://site.example/api\",\"ext\":\"./local_rules.json\"}]}";
        Cms.Config cRelFile = Cms.parseConfig(fileRelCfg, fileOrigin);
        String resolvedFileExt = (String) cRelFile.sites.get(0).ext;
        check(
                resolvedFileExt != null
                        && resolvedFileExt.startsWith("file://")
                        && resolvedFileExt.endsWith("/sdcard/Download/local_rules.json"),
                "File origin resolves relative string ext ./");

        // Douban score parsing & MacCMS placeholder rejection
        check(
                Math.abs(Cms.parseValidDoubanScore("8.7") - 8.7) < 0.001
                        && Math.abs(Cms.parseValidDoubanScore(" 9.3分 ") - 9.3) < 0.001
                        && Math.abs(Cms.parseValidDoubanScore("2.0") - 2.0) < 0.001
                        && Math.abs(Cms.parseValidDoubanScore("9.9") - 9.9) < 0.001,
                "Cms.parseValidDoubanScore accepts valid [2.0, 9.9] ratings");
        check(
                Cms.parseValidDoubanScore(null) == 0.0
                        && Cms.parseValidDoubanScore("") == 0.0
                        && Cms.parseValidDoubanScore("0") == 0.0
                        && Cms.parseValidDoubanScore("0.0") == 0.0
                        && Cms.parseValidDoubanScore("0.00") == 0.0
                        && Cms.parseValidDoubanScore("10.0") == 0.0
                        && Cms.parseValidDoubanScore("1.2") == 0.0,
                "Cms.parseValidDoubanScore rejects 0.0 and 10.0 MacCMS placeholders");

        String jsonWithDouban =
                "{\"list\":["
                        + "{\"vod_id\":\"101\",\"vod_name\":\"奥本海默\",\"vod_douban_score\":\"8.8\",\"vod_score\":\"10.0\",\"vod_play_from\":\"L1\",\"vod_play_url\":\"正片$https://media.test/1.m3u8\"},"
                        + "{\"vod_id\":\"102\",\"vod_name\":\"沙丘2\",\"vod_douban_score\":\"0.0\",\"vod_score\":\"8.2\",\"vod_play_from\":\"L1\",\"vod_play_url\":\"正片$https://media.test/2.m3u8\"},"
                        + "{\"vod_id\":\"103\",\"vod_name\":\"未评分片\",\"vod_douban_score\":\"0.0\",\"vod_score\":\"10.0\",\"vod_play_from\":\"L1\",\"vod_play_url\":\"正片$https://media.test/3.m3u8\"}"
                        + "]}";
        Cms.Listing dbList = Cms.listing(jsonWithDouban);
        check(
                "8.8".equals(dbList.videos.get(0).doubanScore)
                        && "8.2".equals(dbList.videos.get(1).doubanScore)
                        && "".equals(dbList.videos.get(2).doubanScore),
                "JSON CMS extracts vod_douban_score/vod_score and drops 0.0/10.0 placeholders");

        String xmlWithDouban =
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?><rss><list page=\"1\" pagecount=\"1\">"
                        + "<video><id>201</id><name>漫长的季节</name><douban>9.4</douban><dl><dd flag=\"m3u8\">第1集$https://media.test/ep1.m3u8</dd></dl></video>"
                        + "<video><id>202</id><name>无分剧集</name><douban>0.0</douban><score>10.0</score><dl><dd flag=\"m3u8\">第1集$https://media.test/ep2.m3u8</dd></dl></video>"
                        + "</list></rss>";
        Cms.Listing xmlDbList = Cms.listing(xmlWithDouban);
        check(
                "9.4".equals(xmlDbList.videos.get(0).doubanScore)
                        && "".equals(xmlDbList.videos.get(1).doubanScore),
                "XML CMS extracts <douban>/<score> and drops 0.0/10.0 placeholders");
    }
}
