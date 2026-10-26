package com.pilipala.marcomovie;
import java.nio.file.*;
import org.json.*;

public final class JsPlayerChecks {
    private static int checks;
    private static void check(boolean pass,String label){if(!pass)throw new AssertionError(label);checks++;System.out.println("PASS "+label);}
    private static JSONObject normalize(JSONObject result)throws Exception{return new JSONObject(JsEngine.normalizePlayerResult(result.toString()));}
    public static void main(String[]args)throws Exception {
        JSONObject direct=new JSONObject("{\"parse\":1,\"jx\":0,\"url\":\"https://media.example/clip.MP4?token=fixture#part\",\"header\":{\"Referer\":\"https://site.example/\"},\"flag\":\"line\"}");
        check(normalize(direct).getInt("parse")==0,"direct media suffix with query and fragment");
        check(normalize(direct).getJSONObject("header").getString("Referer").equals("https://site.example/"),"per-source header retained");
        direct.put("jx",1);check(normalize(direct).getInt("parse")==1,"external parser request preserved");
        direct.put("jx",0).put("playUrl","https://parser.example/?url=");check(normalize(direct).getInt("parse")==1,"configured parser prefix preserved");
        direct.put("playUrl","").put("url","https://site.example/watch?video=clip.mp4");check(normalize(direct).getInt("parse")==1,"media suffix in query is not direct media");
        direct.put("url","file:///clip.mp4");check(normalize(direct).getInt("parse")==1,"non-HTTP URI preserved");
        direct.put("url","https://media.example/clip.mp4").remove("jx");check(normalize(direct).getInt("parse")==1,"missing parser intent preserved");
        System.out.println(checks+" JS player checks passed; no live media playback implied.");
    }
}
