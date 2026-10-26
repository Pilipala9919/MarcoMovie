import com.pilipala.marcomovie.LiveCatalog;
import java.nio.file.*;
import java.util.*;
import java.io.*;

public final class LiveCatalogChecks {
    static int count;
    static void check(boolean value,String message){if(!value)throw new AssertionError(message);System.out.println("PASS "+message);count++;}
    static LiveCatalog.Channel first(LiveCatalog.Catalog c){return c.groups.get(0).channels.get(0);}
    public static void main(String[] args)throws Exception {
        Map<String,String> inherited=new LinkedHashMap<>();inherited.put("User-Agent","Source-UA");
        String m3u="\uFEFF#EXTM3U x-tvg-url=\"https://epg.test/e.xml\"\n#EXTINF:-1 tvg-id=\"c1\" tvg-logo=\"../logo.png\" group-title=\"News, World\" http-user-agent=\"Channel-UA\",News, live\n#EXTVLCOPT:http-referrer=https://ref.test/\n#KODIPROP:inputstream.adaptive.manifest_type=hls\n../live/a.m3u8\n#EXTINF:-1 group-title=\"Second\",Other\nhttps://video.test/x.m3u8\n";
        LiveCatalog.Catalog c=LiveCatalog.parse(m3u,"https://list.test/lists/index.m3u",inherited);LiveCatalog.Channel channel=first(c);LiveCatalog.Stream stream=channel.streams.get(0);
        check(c.groups.size()==2&&c.channelCount()==2,"M3U grouping and commas inside metadata");
        check(channel.name.equals("News, live")&&channel.id.equals("c1"),"M3U display name and tvg id");
        check(channel.logo.equals("https://list.test/logo.png")&&stream.url.equals("https://list.test/live/a.m3u8"),"relative image and stream URL resolution");
        check(stream.headers.get("User-Agent").equals("Channel-UA")&&stream.headers.get("Referer").equals("https://ref.test/"),"M3U channel header override and VLC referrer");
        check(c.groups.get(1).channels.get(0).streams.get(0).headers.get("User-Agent").equals("Source-UA")&&!c.groups.get(1).channels.get(0).streams.get(0).headers.containsKey("Referer"),"per-channel headers do not leak into next channel");
        check(stream.options.get("inputstream.adaptive.manifest_type").equals("hls")&&c.options.containsKey("x-tvg-url"),"preserve player metadata and EPG declaration");
        c=LiveCatalog.parse("新闻,#genre#\n测试,http://stream.test/a#https://backup.test/b\n有片段,http://stream.test/a#keep\n选项,https://stream.test/p|User-Agent=UA%2F1&Referer=https%3A%2F%2Fr.test%2F\n",null,inherited);
        check(c.groups.get(0).name.equals("新闻")&&first(c).streams.size()==2,"TXT group and alternative stream URLs");
        check(c.groups.get(0).channels.get(1).streams.get(0).url.endsWith("#keep"),"URL fragment preserved instead of split");
        check(c.groups.get(0).channels.get(2).streams.get(0).headers.get("User-Agent").equals("UA/1"),"URL pipe options percent decoded");
        c=LiveCatalog.parse("{\"groups\":[{\"name\":\"电视\",\"ua\":\"Group-UA\",\"channels\":[{\"name\":\"A\",\"urls\":[\"a.m3u8\",{\"name\":\"备用\",\"url\":\"b.m3u8\",\"headers\":{\"Referer\":\"https://r.test/\"}}]}]}]}","https://list.test/index.json",inherited);
        check(c.groups.get(0).name.equals("电视")&&first(c).streams.size()==2,"TVBox inline groups and array URLs");
        check(first(c).streams.get(1).label.equals("备用")&&first(c).streams.get(1).headers.get("User-Agent").equals("Group-UA"),"inline alternative metadata and inherited headers");
        check(first(c).streams.get(1).headers.get("Referer").equals("https://r.test/"),"inline per-stream header");
        boolean failed=false;try{LiveCatalog.parse("<!doctype html><html>upstream error</html>",null,inherited);}catch(IOException e){failed=true;}check(failed,"HTML error response is rejected");
        failed=false;try{LiveCatalog.parse("#EXTM3U\n#EXTINF:-1,Missing",null,inherited);}catch(IOException e){failed=true;}check(failed,"empty M3U never reported as parsed channel");
        failed=false;try{LiveCatalog.parse("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment.ts",null,inherited);}catch(IOException e){failed=true;}check(failed,"HLS media segments are not mistaken for live channels");
        c=LiveCatalog.parse("A,http://media.test/v?token=x$2",null,inherited);check(first(c).streams.get(0).url.endsWith("token=x$2"),"dollar in URL query remains intact");
        if(args.length>1){String base=args[1];LiveCatalog.Source s=new LiveCatalog.Source();s.url=base+"redirect";s.timeoutMs=4000;c=LiveCatalog.load(s);check(first(c).streams.get(0).url.equals(base+"media/test.m3u8"),"HTTP relative redirect resolves playlist stream against final URL");s.url=base+"failure";failed=false;try{LiveCatalog.load(s);}catch(IOException e){failed=e.getMessage().contains("503");}check(failed,"HTTP failure status retained");s.url=base+"loop";failed=false;try{LiveCatalog.load(s);}catch(IOException e){failed=e.getMessage().contains("重定向");}check(failed,"redirect loop bounded");}
        System.out.println("OK "+count+" live checks");
    }
}
