package com.pilipala.marcomovie;

import org.json.*;
import java.io.*;
import java.net.*;
import java.util.*;

/** A bounded, non-executing adapter for standard TVBox type-1 JSON CMS sites. */
public final class Cms {
    public static final int MAX_JSON = 4 * 1024 * 1024;
    public static final String USER_AGENT = "okhttp/3.15";
    public static final class Config {
        public final List<Site> sites = new ArrayList<>();
        public String raw;
        public String spider;
    }
    public static final class Site {
        public String key, name, api, playUrl;
        public int type;
        public final Map<String,String> headers = new LinkedHashMap<>();
        public boolean requiresParser;
        public boolean searchable=true;
        public Object ext;
        public boolean supported() { return type == 1 && isHttp(api) && !requiresParser; }
        public String limitation() {
            if (requiresParser) return "此来源需要网页解析，基础版尚未支持。";
            if (type == 3 || api.startsWith("csp_") || api.endsWith(".js")) return "此来源需要 Spider / JS / JAR 运行环境，基础版尚未支持。";
            if (type != 1) return "基础版暂支持 type 1 JSON CMS，此来源已保留但不能浏览。";
            return "此来源不是可直接请求的 HTTP(S) JSON CMS。";
        }
    }
    public static final class Category { public String id,name; }
    public static final class Video {
        public String id,title,poster,remarks,year,area,actor,director,description,action,tag;
        public final List<Line> lines = new ArrayList<>();
    }
    public static final class Line { public String name; public final List<Episode> episodes = new ArrayList<>(); }
    public static final class Episode { public String name,url; public final Map<String,String> headers=new LinkedHashMap<>(); public JSONObject media=new JSONObject(); }
    public static final class Listing { public int page=1,pageCount=1; public final List<Video> videos=new ArrayList<>(); }
    public static final class ImageRequest {public String url;public final Map<String,String> headers=new LinkedHashMap<>();}
    public static ImageRequest imageRequest(String value){
        ImageRequest out=new ImageRequest();out.url=value;
        java.util.regex.Matcher m=java.util.regex.Pattern.compile("@(?i:Referer|User-Agent)=").matcher(value);
        int first=-1;String key=null;int start=0;
        while(m.find()){if(first<0)first=m.start();if(key!=null)out.headers.put(key,value.substring(start,m.start()));key=value.substring(m.start()+1,m.end()-1);start=m.end();}
        if(key!=null){out.headers.put(key,value.substring(start));out.url=value.substring(0,first);}
        out.headers.entrySet().removeIf(e->e.getValue().contains("\r")||e.getValue().contains("\n"));return out;
    }

    public static boolean isMedia(String value){return isHttp(value)||(value!=null&&(value.startsWith("rtsp://")||value.startsWith("udp://")));}
    public static boolean isHttp(String value) {
        try { URL u=new URL(value); return (u.getProtocol().equals("http")||u.getProtocol().equals("https")) && !u.getHost().isEmpty(); }
        catch(Exception e) { return false; }
    }
    public static String normalizeHttp(String value) throws Exception {
        URL u=new URL(value);String host=u.getHost();
        if(!host.startsWith("["))host=IDN.toASCII(host);
        return u.getProtocol()+"://"+(u.getUserInfo()!=null?u.getUserInfo()+"@":"")+host+(u.getPort()>=0?":"+u.getPort():"")+u.getFile()+(u.getRef()!=null?"#"+u.getRef():"");
    }
    private static String resolve(String origin,String target) {
        if (target==null) return "";
        if (isHttp(target) || target.startsWith("csp_") || origin==null || !isHttp(origin)) return target;
        try { return new URL(new URL(origin),target).toString(); } catch(Exception e){return target;}
    }
    public static Config parseConfig(String text,String origin) throws Exception {
        if(text==null || text.length()>MAX_JSON) throw new IOException("配置超过 4 MB 限制");
        JSONObject root=new JSONObject(withoutComments(text.trim().replaceFirst("^\\uFEFF", "")));
        JSONArray sites=root.optJSONArray("sites");
        if(sites==null || sites.length()==0) throw new IOException("配置中没有 sites 来源列表");
        if(sites.length()>500) throw new IOException("来源超过 500 个限制");
        Config out=new Config(); out.raw=text;out.spider=resolve(origin,root.optString("spider",""));
        Set<String> keys=new HashSet<>();
        for(int i=0;i<sites.length();i++) {
            JSONObject j=sites.optJSONObject(i); if(j==null)continue;
            Site s=new Site(); s.key=j.optString("key","site-"+i); s.name=j.optString("name",s.key);
            if(!keys.add(s.key))s.key=s.key+"-"+i;
            s.type=j.optInt("type",-1); s.api=resolve(origin,j.optString("api","")); s.playUrl=j.optString("playUrl", "");
            s.searchable=j.optInt("searchable",1)!=0;
            s.ext=j.opt("ext");
            s.requiresParser=!s.playUrl.isEmpty() || j.optInt("parse",0)==1 || j.optInt("jx",0)==1;
            s.headers.put("User-Agent", USER_AGENT);
            Object h=j.opt("header");
            if(h instanceof String) {try {h=new JSONObject((String)h);}catch(Exception ignored){h=null;}}
            if(h instanceof JSONObject) {
                JSONObject o=(JSONObject)h;Iterator<String> it=o.keys();
                while(it.hasNext()){String k=it.next(); if(k.equalsIgnoreCase("User-Agent")||k.equalsIgnoreCase("Referer")) s.headers.put(k,o.optString(k));}
            }
            out.sites.add(s);
        }
        if(out.sites.isEmpty())throw new IOException("配置没有可识别的站点");
        return out;
    }
    public static String withoutComments(String source)throws IOException {
        StringBuilder clean=new StringBuilder();boolean quoted=false,escaped=false;
        for(int i=0;i<source.length();i++){
            char ch=source.charAt(i);
            if(quoted){clean.append(ch);if(escaped)escaped=false;else if(ch=='\\')escaped=true;else if(ch=='"')quoted=false;continue;}
            if(ch=='"'){quoted=true;clean.append(ch);continue;}
            if(ch=='/'&&i+1<source.length()&&source.charAt(i+1)=='/'){while(i<source.length()&&source.charAt(i)!='\n')i++;clean.append('\n');continue;}
            if(ch=='/'&&i+1<source.length()&&source.charAt(i+1)=='*'){i+=2;while(i+1<source.length()&&!(source.charAt(i)=='*'&&source.charAt(i+1)=='/'))i++;if(i+1>=source.length())throw new IOException("配置注释没有结束");i++;clean.append(' ');continue;}
            clean.append(ch);
        }
        return clean.toString();
    }
    public static String read(InputStream in,int limit) throws IOException {
        ByteArrayOutputStream out=new ByteArrayOutputStream();byte[] buf=new byte[8192];int n;
        while((n=in.read(buf))!=-1){if(out.size()+n>limit)throw new IOException("响应超过大小限制");out.write(buf,0,n);}
        return document(out.toByteArray());
    }
    /** Some operator-provided TVBox configs are JPEG + '**' + Base64(JSON). */
    public static String document(byte[] bytes)throws IOException {
        if(bytes.length>=2&&(bytes[0]&255)==255&&(bytes[1]&255)==216){
            int end=-1;for(int i=2;i<bytes.length-1;i++)if((bytes[i]&255)==255&&(bytes[i+1]&255)==217){end=i+2;break;}
            int marker=-1;if(end>=0)for(int i=end;i<Math.min(bytes.length-1,end+128);i++)if(bytes[i]=='*'&&bytes[i+1]=='*'){marker=i+2;break;}
            if(marker<0)throw new IOException("配置图片中没有受支持的 JSON 载荷");
            ByteArrayOutputStream decoded=new ByteArrayOutputStream();int bits=0,count=0;String alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
            for(int i=marker;i<bytes.length;i++){char ch=(char)(bytes[i]&255);if(ch=='=')break;if(Character.isWhitespace(ch))continue;int v=alphabet.indexOf(ch);if(v<0)throw new IOException("配置图片中的 Base64 格式不受支持");bits=(bits<<6)|v;count+=6;if(count>=8){count-=8;decoded.write((bits>>count)&255);}}
            return new String(decoded.toByteArray(),"UTF-8");
        }
        return new String(bytes,"UTF-8");
    }
    public static String fetch(String address,Map<String,String> headers) throws Exception {
        if(!isHttp(address))throw new IOException("只支持 HTTP(S) 地址");
        URL next=new URL(normalizeHttp(address));
        for(int hop=0;hop<5;hop++) {
            HttpURLConnection c=(HttpURLConnection)next.openConnection();c.setConnectTimeout(12000);c.setReadTimeout(18000);c.setInstanceFollowRedirects(false);
            c.setRequestProperty("User-Agent",USER_AGENT);if(headers!=null)for(Map.Entry<String,String>e:headers.entrySet())c.setRequestProperty(e.getKey(),e.getValue());
            try {
                int status=c.getResponseCode();
                if(status==301||status==302||status==303||status==307||status==308){String loc=c.getHeaderField("Location");if(loc==null)throw new IOException("重定向缺少地址");next=new URL(next,loc);if(!isHttp(next.toString()))throw new IOException("不支持此重定向协议");continue;}
                if(status<200||status>=300)throw new IOException("来源返回 HTTP "+status);
                try(InputStream input=c.getInputStream()){return read(input,MAX_JSON);}
            } finally {c.disconnect();}
        }
        throw new IOException("来源重定向次数过多");
    }
    public static String query(String address,String... pairs) throws Exception {
        URI u=new URI(address);String existing=u.getRawQuery();List<String> p=new ArrayList<>();Set<String> replaced=new HashSet<>();
        for(int i=0;i<pairs.length;i+=2)replaced.add(pairs[i]);
        if(existing!=null)for(String part:existing.split("&")){String key=URLDecoder.decode(part.split("=",2)[0],"UTF-8");if(!replaced.contains(key))p.add(part);}
        for(int i=0;i<pairs.length;i+=2)p.add(URLEncoder.encode(pairs[i],"UTF-8")+"="+URLEncoder.encode(pairs[i+1],"UTF-8"));
        String base=address.split("[?#]",2)[0];StringBuilder joined=new StringBuilder();for(String part:p){if(joined.length()>0)joined.append('&');joined.append(part);}return base+"?"+joined;
    }
    public static List<Category> categories(String json) throws Exception {
        JSONObject o=new JSONObject(json);JSONArray a=o.optJSONArray("class");List<Category> result=new ArrayList<>();
        if(a!=null)for(int i=0;i<a.length();i++){JSONObject j=a.optJSONObject(i);if(j==null)continue;Category c=new Category();c.id=j.optString("type_id");c.name=j.optString("type_name",c.id);if(!c.id.isEmpty())result.add(c);}
        return result;
    }
    public static String searchTitle(Video v){if(v.id!=null&&v.id.startsWith("msearch:")){String[] parts=v.id.substring(8).split("###",-1);for(String part:parts)if(!part.trim().isEmpty()&&!isHttp(part))return part.trim();}return v.title;}
    private static Video video(JSONObject j) {
        Video v=new Video();v.id=j.optString("vod_id");v.title=j.optString("vod_name","未命名影片");v.poster=j.optString("vod_pic");v.remarks=j.optString("vod_remarks");
        Object action=j.opt("action");v.action=action==null||action==JSONObject.NULL?"":action.toString();v.tag=j.optString("vod_tag");
        v.year=j.optString("vod_year");v.area=j.optString("vod_area");v.actor=j.optString("vod_actor");v.director=j.optString("vod_director");v.description=j.optString("vod_content").replaceAll("<[^>]*>"," ").replace("&nbsp;"," ").trim();
        String[] from=j.optString("vod_play_from").split("\\$\\$\\$",-1), urls=j.optString("vod_play_url").split("\\$\\$\\$",-1);
        for(int i=0;i<urls.length;i++) {
            if(urls[i].isEmpty())continue;Line l=new Line();l.name=i<from.length&&!from[i].isEmpty()?from[i]:"线路 "+(i+1);
            for(String part:urls[i].split("#")){if(part.trim().isEmpty())continue;int at=part.indexOf('$');Episode e=new Episode();e.name=at>=0?part.substring(0,at):"播放";e.url=at>=0?part.substring(at+1):part;l.episodes.add(e);}
            if(!l.episodes.isEmpty())v.lines.add(l);
        }
        return v;
    }
    public static Listing listing(String json) throws Exception {
        JSONObject o=new JSONObject(json);Listing l=new Listing();l.page=Math.max(1,o.optInt("page",1));l.pageCount=Math.max(l.page,o.optInt("pagecount",l.page));
        JSONArray a=o.optJSONArray("list");if(a==null)throw new IOException("来源没有返回 JSON list");
        if(a.length()>500)throw new IOException("单页超过 500 项限制");
        for(int i=0;i<a.length();i++){JSONObject j=a.optJSONObject(i);if(j!=null)l.videos.add(video(j));}return l;
    }
    public static void assertMedia(String address,Map<String,String> headers) throws Exception {
        if(!isHttp(address))throw new IOException("此剧集不是 HTTP(S) 直连媒体，基础版不能播放");
        HttpURLConnection c=(HttpURLConnection)new URL(normalizeHttp(address)).openConnection();c.setRequestMethod("HEAD");c.setConnectTimeout(12000);c.setReadTimeout(12000);c.setInstanceFollowRedirects(true);
        c.setRequestProperty("User-Agent",USER_AGENT);for(Map.Entry<String,String>e:headers.entrySet())c.setRequestProperty(e.getKey(),e.getValue());
        try {int status=c.getResponseCode();String type=c.getContentType();if(type!=null&&(type.toLowerCase(Locale.ROOT).contains("text/html")||type.toLowerCase(Locale.ROOT).contains("application/json")))throw new IOException("剧集返回网页或 JSON，需要额外解析，基础版尚未支持");if(status>=400&&status!=405)throw new IOException("媒体地址返回 HTTP "+status);} finally {c.disconnect();}
    }
    private Cms(){}
}
