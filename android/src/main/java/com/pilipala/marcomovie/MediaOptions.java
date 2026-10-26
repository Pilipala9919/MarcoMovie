package com.pilipala.marcomovie;

import org.json.*;
import java.net.URL;
import java.util.*;

/** Normalizes playback metadata returned by a source, without persisting signed URLs. */
final class MediaOptions {
    static Cms.Episode episode(Cms.Site site,Cms.Episode original,JSONObject result)throws Exception{
        Cms.Episode out=new Cms.Episode();out.name=original.name;out.url=result.optString("url");out.headers.putAll(site.headers);out.headers.putAll(original.headers);out.media=new JSONObject(result.toString());
        Object value=result.opt("header");if(value instanceof String)try{value=new JSONObject((String)value);}catch(JSONException ignored){}
        if(value instanceof JSONObject)headers(out.headers,(JSONObject)value);
        for(String key:new String[]{"User-Agent","UA","ua"})if(!result.optString(key).isEmpty())put(out.headers,"User-Agent",result.optString(key));
        for(String key:new String[]{"Referer","referer"})if(!result.optString(key).isEmpty())put(out.headers,"Referer",result.optString(key));
        Object subtitles=result.opt("subtitles");if(subtitles==null)subtitles=result.opt("subt");if(subtitles==null)subtitles=result.opt("sub");
        if(subtitles instanceof String){String text=((String)subtitles).trim();try{subtitles=text.startsWith("[")?new JSONArray(text):text.startsWith("{")?new JSONObject(text):text;}catch(JSONException ignored){}}
        JSONArray normalized=new JSONArray();if(subtitles instanceof JSONArray){JSONArray items=(JSONArray)subtitles;for(int i=0;i<items.length();i++)subtitle(normalized,items.opt(i),out.url);}else if(subtitles!=null)subtitle(normalized,subtitles,out.url);
        out.media.put("subtitles",normalized);return out;
    }
    static void put(Map<String,String> target,String key,String value){if(!key.matches("[A-Za-z0-9-]+")||value.contains("\r")||value.contains("\n"))return;target.keySet().removeIf(existing->existing.equalsIgnoreCase(key));target.put(key,value);}
    static void headers(Map<String,String> target,JSONObject object){Iterator<String> keys=object.keys();while(keys.hasNext()){String key=keys.next();put(target,key,object.optString(key));}}
    static void subtitle(JSONArray target,Object value,String origin)throws JSONException{
        JSONObject item;if(value instanceof JSONObject)item=new JSONObject(value.toString());else if(value instanceof String)item=new JSONObject().put("url",value);else return;
        String url=item.optString("url",item.optString("uri"));try{url=new URL(new URL(origin),url).toString();}catch(Exception ignored){}
        if(!Cms.isHttp(url)&&!url.startsWith("content://")&&!url.startsWith("file://"))return;
        item.put("url",url);if(!item.has("name"))item.put("name",item.optString("label","外挂字幕"));target.put(item);
    }
    static String subtitleMime(String uri,String declared){if(declared!=null&&!declared.isEmpty())return declared;String path=uri.split("[?#]",2)[0].toLowerCase(Locale.ROOT);if(path.endsWith(".vtt"))return "text/vtt";if(path.endsWith(".ass")||path.endsWith(".ssa"))return "text/x-ssa";if(path.endsWith(".ttml")||path.endsWith(".xml"))return "application/ttml+xml";return "application/x-subrip";}
    static String mime(JSONObject options){String type=options.optString("mimeType",options.optString("type","")).toLowerCase(Locale.ROOT);if(type.equals("hls")||type.equals("m3u8"))return "application/x-mpegURL";if(type.equals("dash")||type.equals("mpd"))return "application/dash+xml";return type.contains("/")?type:null;}
}
