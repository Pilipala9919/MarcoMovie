package com.pilipala.marcomovie;
import java.nio.file.*;
import java.io.*;
import java.util.*;
import org.json.*;
public final class CompatChecks {
    static int count;static void check(boolean value,String label){if(!value)throw new AssertionError(label);System.out.println("PASS "+label);count++;}
    public static void main(String[] args)throws Exception{
        Path assets=Paths.get(args[0],"android/src/main/assets/search");PhoneticSearchIndex index=new PhoneticSearchIndex(Files.newInputStream(assets.resolve("pinyin-characters.tsv")),Files.newInputStream(assets.resolve("pinyin-phrases.dict.yaml")));
        index.learn("三体");index.learn("流浪地球2");index.learn("长安十二时辰");
        check(index.expand("st").contains("三体"),"initials match learned real title");check(index.expand("santi").contains("三体"),"full pinyin matches same title by default");
        check(index.matches("流浪地球2","lldq"),"initials prefix supports digits in title");check(index.matches("流浪地球2","liulangdiqiu"),"full pinyin prefix supports title suffix");
        check(index.matches("长安十二时辰","changanshiershichen"),"polyphonic readings are retained");check(index.expand("BATMAN").contains("BATMAN"),"English source query is preserved");
        PhoneticSearchIndex fresh=new PhoneticSearchIndex(Files.newInputStream(assets.resolve("pinyin-characters.tsv")),Files.newInputStream(assets.resolve("pinyin-phrases.dict.yaml")));
        check(fresh.expand("santi").contains("三体"),"full pinyin decoded without learned title");check(fresh.expand("liulangdiqiu").contains("流浪地球"),"phrase decoding joins multiple words");
        check(index.expand("三体").equals(Collections.singletonList("三体")),"Chinese query is unchanged");
        Cms.Site site=new Cms.Site();site.headers.put("user-agent","old");Cms.Episode ep=new Cms.Episode();ep.name="episode";
        JSONObject response=new JSONObject("{\"url\":\"https://media.test/movie.mp4\",\"UA\":\"source-agent\",\"header\":{\"Referer\":\"https://catalog.test/\"},\"subt\":[{\"url\":\"subtitle.vtt\",\"name\":\"中文\"}],\"drm\":{\"scheme\":\"widevine\",\"licenseUrl\":\"https://license.test/\"}}");Cms.Episode normalized=MediaOptions.episode(site,ep,response);
        check(normalized.headers.get("User-Agent").equals("source-agent")&&!normalized.headers.containsKey("user-agent"),"player UA overrides inherited header case-insensitively");
        check(normalized.media.getJSONArray("subtitles").getJSONObject(0).getString("url").equals("https://media.test/subtitle.vtt"),"relative source subtitle normalized");check(normalized.media.getJSONObject("drm").getString("scheme").equals("widevine"),"DRM license declaration preserved without bypass");
        check(MediaOptions.subtitleMime("x.ASS?token=a","").equals("text/x-ssa"),"external ASS MIME recognized");
        Cms.Video action=Cms.listing("{\"list\":[{\"vod_id\":\"0000\",\"vod_name\":\"登录\",\"action\":\"LoginShow\"},{\"vod_id\":\"huya_1\",\"vod_tag\":\"folder\"}]}").videos.get(0);check(action.action.equals("LoginShow"),"account action not discarded by CMS parser");
        List<DanmakuData.Comment> comments=DanmakuData.parse("<i><d p=\"1.5,1,25,16711680\">hello</d><d p=\"3,5,25,16777215\"><![CDATA[top & text]]></d></i>");check(comments.size()==2&&comments.get(0).time==1500&&comments.get(0).color==0xff0000,"Bili XML comment timing and color");check(comments.get(1).mode==5&&comments.get(1).text.equals("top & text"),"fixed comment mode and CDATA");
        comments=DanmakuData.parse("{\"danmuku\":[[2,1,16777215,\"text\"]]}");check(comments.size()==1&&comments.get(0).time==2000,"source JSON comments");
        comments=DanmakuData.parse("{\"comments\":[{\"p\":\"4.5,16711680,1,user\",\"m\":\"test\"}]}");check(comments.get(0).time==4500&&comments.get(0).color==0xff0000,"Dandan-style comment schema");
        boolean refused=false;try{DanmakuData.parse("<!DOCTYPE i [<!ENTITY x SYSTEM 'file:///private'>]><i><d p=\"0,1,25,1\">&x;</d></i>");}catch(IOException expected){refused=true;}check(refused,"external XML entities rejected");
        check(ProxyAddress.rewrite("http://127.0.0.1:9978/proxy?do=a&url=x%2By%3D",42123).equals("http://127.0.0.1:42123/proxy?do=a&url=x%2By%3D"),"reserved proxy relocated without altering encoded query");
        check(ProxyAddress.rewrite("http://127.0.0.1:-1/proxy?do=a",42123).equals("http://127.0.0.1:42123/proxy?do=a"),"unresolved plugin proxy port repaired");
        check(ProxyAddress.rewrite("http://localhost:9980/proxy?do=a",42123).equals("http://127.0.0.1:42123/proxy?do=a"),"discovery range routes to this application's proxy");
        check(ProxyAddress.rewrite("http://127.0.0.1:9978/other",42123).equals("http://127.0.0.1:9978/other"),"other loopback services left unchanged");
        check(ProxyAddress.rewrite("https://media.test:9978/proxy?do=a",42123).equals("https://media.test:9978/proxy?do=a"),"remote proxy URLs left unchanged");
        System.out.println("OK "+count+" compatibility checks; network and playback not implied");
    }
}
