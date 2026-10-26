package com.pilipala.marcomovie;

import android.app.Application;
import android.content.SharedPreferences;
import android.util.Base64;
import com.whl.quickjs.android.QuickJSLoader;
import com.whl.quickjs.wrapper.*;
import org.json.*;
import org.jsoup.Jsoup;
import org.jsoup.nodes.Element;
import org.jsoup.select.Elements;
import java.io.*;
import java.net.*;
import java.nio.charset.Charset;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;

/** Independent QuickJS host for user-provided ES-module spiders and DRPY rules. */
public final class JsEngine implements SourceEngine {
    private static final ConcurrentHashMap<String,JsEngine> ACTIVE=new ConcurrentHashMap<>();
    private final Application app;private final Cms.Site site;private final SharedPreferences storage;
    private final ExecutorService executor=Executors.newSingleThreadExecutor(r->{Thread t=new Thread(r,"movie-js-source");t.setDaemon(true);return t;});
    private final Map<String,String> modules=new HashMap<>();private final CookieManager cookies=new CookieManager(null,CookiePolicy.ACCEPT_ORIGINAL_SERVER);
    private QuickJSContext context;private volatile boolean closed;private volatile long deadline;
    private boolean catApi;
    public static boolean eligible(Cms.Site s){return s.type==3&&Cms.isHttp(s.api)&&s.api.split("\\?",2)[0].toLowerCase(Locale.ROOT).endsWith(".js");}
    public JsEngine(Application application,Cms.Config config,Cms.Site selected)throws Exception {
        app=application;site=selected;storage=app.getSharedPreferences("js-source-"+hash(site.key),0);
        if(!eligible(site))throw new IOException("这个来源不是支持的 JavaScript 模块地址");
        try{execute(()->{initialize();return null;});ACTIVE.put(site.key,this);}catch(Exception e){close();throw e;}
    }
    private <T>T execute(Callable<T> job)throws Exception {
        if(closed)throw new IOException("JavaScript 来源已关闭");
        Future<T> pending=executor.submit(()->{deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(45);return job.call();});
        try{return pending.get(48,TimeUnit.SECONDS);}catch(TimeoutException e){pending.cancel(true);throw new IOException("JavaScript 来源请求超时；请切换来源",e);}catch(ExecutionException e){Throwable cause=e.getCause();if(cause instanceof Exception)throw (Exception)cause;throw new IOException("JavaScript 运行异常："+cause.getClass().getSimpleName(),cause);}
    }
    private void checkBudget()throws IOException{if(closed||Thread.currentThread().isInterrupted()||System.nanoTime()>deadline)throw new IOException("JavaScript 请求已取消或超时");}
    private void initialize()throws Exception {
        QuickJSLoader.init();context=QuickJSContext.create();context.setMemoryLimit(48*1024*1024);context.setMaxStackSize(512*1024);
        JSObject global=context.getGlobalObject();
        bind(global,"__hostRequest",a->request(string(a,0),string(a,1)));
        bind(global,"__hostStorage",a->{String key=string(a,1)+"\n"+string(a,2);String operation=string(a,0);if(operation.equals("get"))return storage.getString(key,"");if(operation.equals("delete"))storage.edit().remove(key).apply();else storage.edit().putString(key,string(a,3)).apply();return "";});
        bind(global,"__hostHtml",a->html(string(a,0),string(a,1),string(a,2)));
        bind(global,"__hostJoin",a->{String base=string(a,0),part=string(a,1);if(part.isEmpty())return base;if(Cms.isHttp(part)||part.startsWith("magnet:")||part.startsWith("data:"))return part;try{return new URL(new URL(base),part).toString();}catch(Exception e){return part;}});
        bind(global,"__hostBase64",a->{boolean encode=Boolean.TRUE.equals(a[1]);return encode?Base64.encodeToString(string(a,0).getBytes("ISO-8859-1"),Base64.NO_WRAP):new String(Base64.decode(string(a,0),Base64.DEFAULT),"ISO-8859-1");});
        bind(global,"__hostEncode",a->URLEncoder.encode(string(a,0),string(a,1)));
        bind(global,"__hostDecode",a->URLDecoder.decode(string(a,0),string(a,1)));
        bind(global,"__hostSleep",a->{long ms=((Number)a[0]).longValue();if(ms<0||ms>5000)throw new IOException("脚本等待超过限制");Thread.sleep(ms);checkBudget();return null;});
        global.setProperty("__proxyAddress",ProxyAddress.base()+"/proxy?do=js&site="+URLEncoder.encode(site.key,"UTF-8"));
        context.evaluate(asset("js-host/bootstrap.js"),"host-bootstrap.js");context.evaluate(asset("js-host/crypto-js.js"),"crypto-js.js");
        context.setModuleLoader(new QuickJSContext.DefaultModuleLoader(){
            public String moduleNormalizeName(String parent,String name){if(name.startsWith("assets://")||Cms.isHttp(name))return name;try{return new URL(new URL(parent),name).toString();}catch(Exception e){return name;}}
            public String getModuleStringCode(String name){try{return module(name);}catch(Exception e){throw new IllegalStateException("JS module load failed: "+e.getClass().getSimpleName(),e);}}
        });
        String source=module(site.api);catApi=source.contains("__jsEvalReturn")&&!source.contains("export default");
        if(catApi){context.evaluate(source,site.api);context.evaluate("globalThis.__movieSpider=__jsEvalReturn();");}
        else context.evaluateModule("import spider from "+JSONObject.quote(site.api)+";globalThis.__movieSpider=spider;",site.api+".host-entry.mjs");
        Object ext=site.ext==null?"":site.ext;String value=ext instanceof JSONObject||ext instanceof JSONArray?ext.toString():JSONObject.quote(String.valueOf(ext));
        if(catApi)value="{stype:3,skey:"+JSONObject.quote(site.key)+",ext:"+value+"}";
        context.evaluate("__movieSpider.init("+value+");if(typeof __movieSpider.getRule==='function'){const r=__movieSpider.getRule();if(!r||(!r.host&&!r.title&&!r.class_name))throw new Error('DRPY rule failed to initialize');}","source-init.js");
    }
    private interface HostCall {Object run(Object[]args)throws Exception;}
    private void bind(JSObject global,String name,HostCall call){global.setProperty(name,(JSCallFunction)args->{try{checkBudget();return call.run(args);}catch(Exception e){throw new IllegalStateException(e.getMessage(),e);}});}
    private static String string(Object[]a,int i){return i<a.length&&a[i]!=null?String.valueOf(a[i]):"";}
    private String asset(String path)throws IOException{try(InputStream in=app.getAssets().open(path)){return new String(read(in,1024*1024),"UTF-8");}}
    private String module(String name)throws Exception {
        String found=modules.get(name);if(found!=null)return found;
        if(modules.size()>=64)throw new IOException("JS 模块数量超过限制");
        if(name.equals("assets://js/lib/cheerio.min.js"))found=asset("js-host/cheerio-bridge.mjs");
        else if(name.equals("assets://js/lib/crypto-js.js"))found="export default globalThis.CryptoJS;";
        else if(name.startsWith("assets://js-host/"))found=asset(name.substring(9));
        else if(name.startsWith("assets://js/lib/"))found=download(new URL(new URL(site.api),name.substring(name.lastIndexOf('/')+1)).toString());
        else if(Cms.isHttp(name))found=download(name);
        else throw new IOException("不支持的 JS 模块路径");
        modules.put(name,found);return found;
    }
    private String download(String address)throws Exception {
        File cache=new File(app.getCacheDir(),"js-modules");cache.mkdirs();File cached=new File(cache,hash(address)+".js");
        if(cached.isFile()&&System.currentTimeMillis()-cached.lastModified()<24*60*60*1000L)try(InputStream in=new FileInputStream(cached)){return new String(read(in,2*1024*1024),"UTF-8");}
        JSONObject response=new JSONObject(request(address,"{}"));int code=response.getInt("code");if(code<200||code>=300)throw new IOException("JS 模块返回 HTTP "+code);String codeText=response.getString("content");if(codeText.length()>2*1024*1024)throw new IOException("JS 模块超过大小限制");if(codeText.trim().toLowerCase(Locale.ROOT).startsWith("<!doctype html"))throw new IOException("JS 模块返回网页");
        try(OutputStream out=new FileOutputStream(cached)){out.write(codeText.getBytes("UTF-8"));}return codeText;
    }
    private String request(String address,String options)throws Exception {
        checkBudget();JSONObject opts=new JSONObject(options.isEmpty()?"{}":options);JSONObject inputHeaders=opts.optJSONObject("headers");String method=opts.optString("method","GET").toUpperCase(Locale.ROOT);
        if(!Arrays.asList("GET","POST","HEAD","PUT","DELETE","PATCH").contains(method))throw new IOException("不支持的请求方式");
        URL next=new URL(Cms.normalizeHttp(address));byte[] body=null;Object payload=opts.opt("body");if(payload==null)payload=opts.opt("data");
        if(payload instanceof JSONObject){StringBuilder form=new StringBuilder();Iterator<String> keys=((JSONObject)payload).keys();while(keys.hasNext()){String key=keys.next();if(form.length()>0)form.append('&');form.append(URLEncoder.encode(key,"UTF-8")).append('=').append(URLEncoder.encode(((JSONObject)payload).optString(key),"UTF-8"));}body=form.toString().getBytes("UTF-8");}
        else if(payload!=null&&payload!=JSONObject.NULL)body=String.valueOf(payload).getBytes("UTF-8");
        for(int redirect=0;redirect<6;redirect++){
            checkBudget();HttpURLConnection connection=(HttpURLConnection)next.openConnection();connection.setInstanceFollowRedirects(false);int timeout=Math.max(1000,Math.min(opts.optInt("timeout",15000),20000));connection.setConnectTimeout(timeout);connection.setReadTimeout(timeout);connection.setRequestMethod(method);connection.setRequestProperty("User-Agent",Cms.USER_AGENT);
            if(inputHeaders!=null){Iterator<String> keys=inputHeaders.keys();while(keys.hasNext()){String key=keys.next(),v=inputHeaders.optString(key);if(!key.contains("\n")&&!v.contains("\r")&&!v.contains("\n"))connection.setRequestProperty(key,v);}}
            URI uri=next.toURI();for(Map.Entry<String,List<String>> h:cookies.get(uri,new HashMap<>()).entrySet())if(!h.getValue().isEmpty()&&connection.getRequestProperty(h.getKey())==null)connection.setRequestProperty(h.getKey(),android.text.TextUtils.join("; ",h.getValue()));
            try {
                if(body!=null&&!method.equals("GET")&&!method.equals("HEAD")){connection.setDoOutput(true);try(OutputStream output=connection.getOutputStream()){output.write(body);}}
                int code=connection.getResponseCode();cookies.put(uri,connection.getHeaderFields());
                if(Arrays.asList(301,302,303,307,308).contains(code)&&opts.optInt("redirect",1)!=0){String location=connection.getHeaderField("Location");if(location==null)throw new IOException("JS 重定向缺少地址");next=new URL(next,location);if(!Cms.isHttp(next.toString()))throw new IOException("JS 重定向协议不支持");if(code==303||code==302&&method.equals("POST")){method="GET";body=null;}continue;}
                JSONObject headers=new JSONObject();for(Map.Entry<String,List<String>> h:connection.getHeaderFields().entrySet())if(h.getKey()!=null)headers.put(h.getKey().toLowerCase(Locale.ROOT),android.text.TextUtils.join(", ",h.getValue()));
                byte[] bytes;InputStream stream=code>=400?connection.getErrorStream():connection.getInputStream();String compression=connection.getContentEncoding();if(stream!=null&&"gzip".equalsIgnoreCase(compression))stream=new java.util.zip.GZIPInputStream(stream);else if(stream!=null&&"deflate".equalsIgnoreCase(compression))stream=new java.util.zip.InflaterInputStream(stream);if(stream==null)bytes=new byte[0];else try(InputStream in=stream){bytes=read(in,8*1024*1024);}
                JSONObject response=new JSONObject();response.put("code",code);response.put("headers",headers);response.put("url",next.toString());
                if(opts.optInt("buffer",0)==2)response.put("content",Base64.encodeToString(bytes,Base64.NO_WRAP));
                else if(opts.optInt("buffer",0)==1){JSONArray numbers=new JSONArray();for(byte b:bytes)numbers.put(b&255);response.put("content",numbers);}
                else {String encoding=opts.optString("encoding","UTF-8");java.util.regex.Matcher charset=java.util.regex.Pattern.compile("charset=([^;\\s]+)",java.util.regex.Pattern.CASE_INSENSITIVE).matcher(headers.optString("content-type"));if(charset.find())encoding=charset.group(1).replace("\"","");if(!Charset.isSupported(encoding))encoding="UTF-8";response.put("content",new String(bytes,encoding));}return response.toString();
            }finally{connection.disconnect();}
        }throw new IOException("JS 请求重定向过多");
    }
    private static byte[]read(InputStream in,int limit)throws IOException{ByteArrayOutputStream out=new ByteArrayOutputStream();byte[] buf=new byte[8192];int n;while((n=in.read(buf))!=-1){if(out.size()+n>limit)throw new IOException("JS 响应超过大小限制");out.write(buf,0,n);}return out.toByteArray();}
    private static String hash(String value){try{byte[] bytes=MessageDigest.getInstance("SHA-256").digest(value.getBytes("UTF-8"));StringBuilder s=new StringBuilder();for(byte b:bytes)s.append(String.format(Locale.ROOT,"%02x",b&255));return s.toString();}catch(Exception e){throw new IllegalStateException(e);}}
    private static String html(String source,String expression,String kind)throws Exception {
        String[] parts=expression.split("&&");Elements elements=new Elements(Jsoup.parse(source));boolean many=kind.equals("many");int end=many?parts.length:Math.max(0,parts.length-1);
        for(int i=0;i<end;i++){String selector=parts[i].trim();if(selector.isEmpty())continue;Elements next=new Elements();for(Element element:elements)next.addAll(element.select(selector));elements=next;if(!many&&elements.size()>1)elements=new Elements(elements.first());}
        if(many){JSONArray a=new JSONArray();for(Element element:elements)a.put(element.outerHtml());return a.toString();}
        if(elements.isEmpty())return "";Element first=elements.first();String attribute=parts.length==0?"Text":parts[parts.length-1].trim();if(attribute.equalsIgnoreCase("Text"))return first.text();if(attribute.equalsIgnoreCase("Html"))return first.html();return first.attr(attribute);
    }
    private String call(String function,Object...args)throws Exception{return execute(()->{JSONArray a=new JSONArray();for(Object value:args)a.put(value);String invocation="(()=>{const r=__movieSpider["+JSONObject.quote(function)+"](..."+a.toString()+");if(r&&typeof r.then==='function')throw new Error('Promise-based spider API is not supported');return typeof r==='string'?r:JSON.stringify(r);})()";Object result=context.evaluate(invocation,"source-"+function+".js");if(!(result instanceof String)||((String)result).isEmpty())throw new IOException("JS 来源未返回数据");return (String)result;});}
    public String home()throws Exception{return call("home",false);}
    public String homeVideos()throws Exception{return call("homeVod");}
    public String category(String id,int page)throws Exception{return call("category",id,page,false,new JSONObject());}
    public String detail(String id)throws Exception{return call("detail",catApi?new JSONArray().put(id):id);}
    public String search(String keyword,int page)throws Exception{return call("search",keyword,false,page);}
    public String player(String flag,String id)throws Exception{return normalizePlayerResult(call("play",flag,id,new JSONArray()));}
    /** DRPY may retain its sniff flag after lazy has already resolved a media URL. */
    static String normalizePlayerResult(String response)throws JSONException {
        JSONObject result=new JSONObject(response);
        if(result.optInt("parse",0)!=1||result.optInt("jx",-1)!=0||!result.optString("playUrl","").isEmpty())return response;
        String url=result.optString("url","");
        if(!Cms.isHttp(url))return response;
        try {
            String path=new URL(url).getPath().toLowerCase(Locale.ROOT);
            if(path.matches(".*\\.(mp4|m3u8|mpd|flv|m4a|mp3|webm)$")){result.put("parse",0);return result.toString();}
        }catch(MalformedURLException ignored){}
        return response;
    }
    public boolean requiresExternalRuntime(){return true;}
    public Object[] proxy(Map<String,String> params)throws Exception {JSONArray r=new JSONArray(call("proxy",new JSONObject(params)));if(r.length()<3)throw new IOException("JS 代理返回格式错误");Object content=r.get(2);byte[]bytes=r.optInt(4,0)==1?Base64.decode(String.valueOf(content),Base64.DEFAULT):String.valueOf(content).getBytes("UTF-8");Map<String,String>headers=new LinkedHashMap<>();JSONObject h=r.optJSONObject(3);if(h!=null){Iterator<String>k=h.keys();while(k.hasNext()){String key=k.next();headers.put(key,h.optString(key));}}return new Object[]{r.getInt(0),r.getString(1),new ByteArrayInputStream(bytes),headers};}
    public static Object[] proxyFor(Map<String,String> params)throws Exception{JsEngine engine=ACTIVE.get(params.get("site"));if(engine==null)throw new IOException("JS 代理来源尚未打开");return engine.proxy(params);}
    public void close(){if(closed)return;closed=true;ACTIVE.remove(site.key,this);try{executor.execute(()->{if(context!=null){context.destroy();context=null;}});}catch(RejectedExecutionException ignored){}executor.shutdown();}
}
