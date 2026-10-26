package com.pilipala.marcomovie;

import android.app.Application;
import android.content.Context;
import dalvik.system.DexClassLoader;
import com.github.catvod.crawler.Spider;
import java.io.*;
import java.net.*;
import java.lang.reflect.*;
import java.security.*;
import java.util.*;
import java.util.zip.*;
import org.json.*;

/** Experimental ordinary CSP host. Never unwraps, patches, or bypasses plugin protection. */
public final class CspEngine implements SourceEngine {
    static final Map<String,DexClassLoader> LOADERS=new HashMap<>();
    final Application app;final Cms.Site site;final Spider spider;final Object pluginLock;public final String pluginSha256;
    public CspEngine(Application application,Cms.Config config,Cms.Site selected)throws Exception {
        app=application;site=selected;
        if(!eligible(selected))throw new IOException("此来源不是实验 CSP JAR 接口支持的 csp_ 站点");
        try {
            File artifact=obtain(application,config.spider);pluginSha256=digest(artifact,"SHA-256");
            DexClassLoader loader=loader(app,artifact,pluginSha256);pluginLock=new Object();
            try(InputStream resource=loader.getResourceAsStream("classes.dex")){if(resource==null)throw new IOException("插件类加载器无法读取原始资源");}
            String className="com.github.catvod.spider."+site.api.substring(4);
            Object candidate=loader.loadClass(className).getDeclaredConstructor().newInstance();
            if(!(candidate instanceof Spider))throw new IOException("插件父接口与当前宿主不兼容");
            spider=(Spider)candidate;synchronized(pluginLock){spider.init(app,site.ext==null?"":site.ext.toString());}
            diagnostic("loaded",className,null);
        }catch(Throwable error){Throwable cause=unwrap(error);diagnostic("load_failed",site.api,cause);throw new EngineException("扩展引擎初始化失败："+cause.getClass().getSimpleName()+"。此来源尚未验证兼容。",cause);}
    }
    static synchronized DexClassLoader loader(Application app,File artifact,String sha)throws Exception {
        DexClassLoader existing=LOADERS.get(sha);if(existing!=null)return existing;
        File optimized=new File(app.getCodeCacheDir(),"csp-opt");if(!optimized.exists()&&!optimized.mkdirs())throw new IOException("无法创建插件私有目录");
        DexClassLoader loader=new DexClassLoader(artifact.getAbsolutePath(),optimized.getAbsolutePath(),null,app.getClassLoader());
        loader.loadClass("com.github.catvod.spider.Init").getMethod("init",Context.class).invoke(null,app);LOADERS.put(sha,loader);return loader;
    }
    public static boolean eligible(Cms.Site s){return s.type==3&&s.api.startsWith("csp_")&&s.api.substring(4).matches("[A-Za-z0-9_$.]+");}
    public static Object[] proxy(Application app,Cms.Config config,Map<String,String> params)throws Exception{
        File artifact=obtain(app,config.spider);DexClassLoader loader=loader(app,artifact,digest(artifact,"SHA-256"));
        // playerContent may call its own HTTP proxy synchronously. Holding its
        // catalogue lock here would deadlock that reentrant network request.
        try{return (Object[])loader.loadClass("com.github.catvod.spider.Proxy").getMethod("proxy",Map.class).invoke(null,params);}catch(InvocationTargetException e){throw new IOException("来源代理执行失败",unwrap(e));}
    }
    public static final class EngineException extends Exception {EngineException(String message,Throwable t){super(message,t);}}
    private interface Call{String run()throws Exception;}
    private String call(String operation,Call c)throws Exception{synchronized(pluginLock){try{String result=c.run();if(result==null||result.trim().isEmpty())throw new IOException("插件返回空结果");new JSONObject(result);diagnostic(operation+"_ok",site.api,null);return result;}catch(Throwable t){Throwable error=unwrap(t);diagnostic(operation+"_failed",site.api,error);throw new EngineException("扩展来源请求失败："+error.getClass().getSimpleName()+"。请检查来源或稍后重试。",error);}}}
    public String home()throws Exception{return call("home",()->spider.homeContent(false));}
    public String homeVideos()throws Exception{return call("recommendations",()->spider.homeVideoContent());}
    public String category(String id,int page)throws Exception{return call("category",()->spider.categoryContent(id,""+page,false,new HashMap<String,String>()));}
    public String detail(String id)throws Exception{return call("detail",()->spider.detailContent(Collections.singletonList(id)));}
    public String search(String keyword,int page)throws Exception{return call("search",()->spider.searchContent(keyword,false,""+page));}
    public String player(String flag,String id)throws Exception{return call("player",()->spider.playerContent(flag,id,Collections.emptyList()));}
    public String action(String value)throws Exception{synchronized(pluginLock){try{return spider.action(value);}catch(Throwable error){throw new EngineException("来源交互失败："+unwrap(error).getClass().getSimpleName(),unwrap(error));}}}
    public boolean requiresExternalRuntime(){return true;}
    public void close(){synchronized(pluginLock){try{spider.destroy();}catch(Throwable ignored){}}}
    static Throwable unwrap(Throwable t){while(t instanceof InvocationTargetException&&((InvocationTargetException)t).getCause()!=null)t=((InvocationTargetException)t).getCause();return t;}
    static String digest(File file,String algorithm)throws Exception{MessageDigest d=MessageDigest.getInstance(algorithm);try(InputStream in=new FileInputStream(file)){byte[]b=new byte[8192];int n;while((n=in.read(b))!=-1)d.update(b,0,n);}StringBuilder out=new StringBuilder();for(byte v:d.digest())out.append(String.format(Locale.ROOT,"%02x",v&255));return out.toString();}
    static synchronized File obtain(Application app,String declaration)throws Exception {
        if(declaration==null||declaration.trim().isEmpty())throw new IOException("配置没有声明 spider 插件");
        String[]parts=declaration.split(";md5;",2);String address=parts[0];if(!Cms.isHttp(address))throw new IOException("spider 需要 HTTP(S) 插件地址");String expected=parts.length==2?parts[1].trim().toLowerCase(Locale.ROOT):"";
        if(!expected.isEmpty()&&!expected.matches("[0-9a-f]{32}"))throw new IOException("插件 MD5 声明无效");
        File folder=new File(app.getFilesDir(),"csp");if(!folder.exists()&&!folder.mkdirs())throw new IOException("插件目录不可用");
        String key=hex(declaration.getBytes("UTF-8"));File identity=new File(folder,"selection-"+key+".txt");
        if(identity.exists()){String sha;try(InputStream in=new FileInputStream(identity)){sha=Cms.read(in,128).trim();}if(sha.matches("[0-9a-f]{64}")){File cached=new File(folder,sha+".jar");if(cached.exists()&&sha.equals(digest(cached,"SHA-256"))&&(expected.isEmpty()||expected.equals(digest(cached,"MD5"))))return cached;}}
        File temp=File.createTempFile("incoming-",".tmp",folder);try {
            URL next=new URL(Cms.normalizeHttp(address));boolean done=false;
            for(int redirect=0;redirect<5&&!done;redirect++){HttpURLConnection c=(HttpURLConnection)next.openConnection();c.setConnectTimeout(12000);c.setReadTimeout(20000);c.setInstanceFollowRedirects(false);c.setRequestProperty("User-Agent",Cms.USER_AGENT);
                try{int code=c.getResponseCode();if(code==301||code==302||code==303||code==307||code==308){String loc=c.getHeaderField("Location");if(loc==null)throw new IOException("插件重定向无地址");next=new URL(next,loc);if(!Cms.isHttp(next.toString()))throw new IOException("插件重定向协议不受支持");continue;}if(code<200||code>=300)throw new IOException("插件下载失败 HTTP "+code);try(InputStream in=c.getInputStream();OutputStream out=new FileOutputStream(temp)){byte[]b=new byte[8192];int n,total=0;while((n=in.read(b))!=-1){total+=n;if(total>20*1024*1024)throw new IOException("插件超过 20 MB 限制");out.write(b,0,n);}}done=true;}finally{c.disconnect();}}
            if(!done)throw new IOException("插件重定向次数过多");
            if(!expected.isEmpty()&&!expected.equals(digest(temp,"MD5")))throw new IOException("插件 MD5 与配置不一致，已拒绝加载");
            try(ZipFile zip=new ZipFile(temp)){if(zip.getEntry("classes.dex")==null)throw new IOException("插件不含 classes.dex");}
            String sha=digest(temp,"SHA-256");File artifact=new File(folder,sha+".jar");if(artifact.exists()){if(!sha.equals(digest(artifact,"SHA-256")))throw new IOException("缓存插件摘要不一致");}else if(!temp.renameTo(artifact))throw new IOException("无法保存插件");
            artifact.setReadOnly();try(OutputStream out=new FileOutputStream(identity)){out.write(sha.getBytes("UTF-8"));}return artifact;
        }finally{temp.delete();}
    }
    static String hex(byte[]bytes)throws Exception{byte[]d=MessageDigest.getInstance("SHA-256").digest(bytes);StringBuilder s=new StringBuilder();for(byte b:d)s.append(String.format(Locale.ROOT,"%02x",b&255));return s.toString();}
    void diagnostic(String state,String className,Throwable error){try{JSONObject j=new JSONObject();j.put("state",state);j.put("class",className);j.put("error_type",error==null?JSONObject.NULL:error.getClass().getName());j.put("elapsed_ms",android.os.SystemClock.elapsedRealtime());if(error!=null){JSONArray stack=new JSONArray();StackTraceElement[]elements=error.getStackTrace();for(int i=0;i<Math.min(8,elements.length);i++)stack.put(elements[i].getClassName()+"."+elements[i].getMethodName());j.put("frames",stack);}try(OutputStream out=app.openFileOutput("csp-diagnostic.json",Context.MODE_PRIVATE)){out.write(j.toString(2).getBytes("UTF-8"));}}catch(Exception ignored){}}
}
