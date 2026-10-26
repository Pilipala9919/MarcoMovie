package com.pilipala.marcomovie;

import android.app.Application;
import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;
import org.json.JSONObject;

/** Independent loopback-only implementation of the observed CSP HTTP response ABI. */
public final class LocalProxy implements Closeable {
    final Application app;final Cms.Config config;final ServerSocket server;
    final ThreadPoolExecutor requests=new ThreadPoolExecutor(0,4,30,TimeUnit.SECONDS,new SynchronousQueue<Runnable>());
    volatile boolean closed;
    public LocalProxy(Application application,Cms.Config source)throws IOException{
        app=application;config=source;server=bind();ProxyAddress.port=server.getLocalPort();
        Thread accept=new Thread(()->{while(!closed)try{Socket socket=server.accept();try{requests.execute(()->serve(socket));}catch(RejectedExecutionException full){socket.close();}}catch(IOException e){if(!closed)close();}},"movie-loopback-proxy");accept.setDaemon(true);accept.start();
    }
    static ServerSocket bind()throws IOException{ServerSocket socket=new ServerSocket();try{socket.setReuseAddress(true);socket.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"),9978));return socket;}catch(BindException occupied){socket.close();ServerSocket fallback=new ServerSocket();try{fallback.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"),0));return fallback;}catch(IOException failure){fallback.close();throw failure;}}catch(IOException error){socket.close();throw error;}}
    static String address(){return ProxyAddress.base();}
    /** Only the CSP host's reserved /proxy URLs are relocated, never arbitrary loopback services. */
    static String rewrite(String value){return ProxyAddress.rewrite(value,ProxyAddress.port);}
    static String line(InputStream in,int limit)throws IOException{ByteArrayOutputStream b=new ByteArrayOutputStream();int c;while((c=in.read())!=-1){if(c=='\n')break;if(c!='\r')b.write(c);if(b.size()>limit)throw new IOException("HTTP line too large");}return b.toString("ISO-8859-1");}
    void serve(Socket socket){try(Socket connection=socket){connection.setSoTimeout(10000);InputStream in=connection.getInputStream();OutputStream out=connection.getOutputStream();String[] request=line(in,8192).split(" ");if(request.length<2)return;
        String method=request[0];URI uri=new URI(request[1]);if(!uri.getPath().equals("/proxy")||(!method.equals("GET")&&!method.equals("HEAD"))){simple(out,404,"Not found");return;}
        Map<String,String> headers=new LinkedHashMap<>(),params=new LinkedHashMap<>();int size=0;
        for(;;){String h=line(in,8192);size+=h.length();if(size>32768)throw new IOException("Headers too large");if(h.isEmpty())break;int at=h.indexOf(':');if(at>0)headers.put(h.substring(0,at).toLowerCase(Locale.ROOT),h.substring(at+1).trim());}
        params.putAll(headers);String query=uri.getRawQuery();if(query!=null)for(String pair:query.split("&")){String[] p=pair.split("=",2);params.put(URLDecoder.decode(p[0],"UTF-8"),p.length==2?URLDecoder.decode(p[1],"UTF-8"):"");}
        params.put("request-headers",new JSONObject(headers).toString());
        Object[] response;
        try{response="js".equals(params.get("do"))?JsEngine.proxyFor(params):CspEngine.proxy(app,config,params);}catch(Throwable e){simple(out,502,"Source proxy failed");return;}
        if(response==null||response.length<3||!(response[0] instanceof Number)){simple(out,502,"Invalid source response");return;}
        int code=((Number)response[0]).intValue();if(code<100||code>599)code=502;String mime=String.valueOf(response[1]);
        InputStream body=response[2] instanceof InputStream?(InputStream)response[2]:new ByteArrayInputStream(response[2]==null?new byte[0]:response[2].toString().getBytes("UTF-8"));
        try(InputStream payload=body){StringBuilder head=new StringBuilder("HTTP/1.1 "+code+" Response\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n");if(safe(mime))head.append("Content-Type: ").append(mime).append("\r\n");
            if(response.length>3&&response[3] instanceof Map)for(Object item:((Map<?,?>)response[3]).entrySet()){Map.Entry<?,?> e=(Map.Entry<?,?>)item;String k=String.valueOf(e.getKey()),v=String.valueOf(e.getValue());if(safe(k)&&safe(v)&&!k.equalsIgnoreCase("Content-Length")&&!k.equalsIgnoreCase("Transfer-Encoding")&&!k.equalsIgnoreCase("Connection")&&!k.equalsIgnoreCase("Content-Type"))head.append(k).append(": ").append(v).append("\r\n");}
            head.append("\r\n");out.write(head.toString().getBytes("ISO-8859-1"));if(!method.equals("HEAD")){byte[] buffer=new byte[32*1024];int n;while((n=payload.read(buffer))!=-1){out.write((Integer.toHexString(n)+"\r\n").getBytes("US-ASCII"));out.write(buffer,0,n);out.write(new byte[]{13,10});}out.write("0\r\n\r\n".getBytes("US-ASCII"));}out.flush();}
    }catch(Exception ignored){}}
    static boolean safe(String s){return s.indexOf('\r')<0&&s.indexOf('\n')<0;}
    static void simple(OutputStream o,int status,String message)throws IOException{byte[] b=message.getBytes("UTF-8");o.write(("HTTP/1.1 "+status+" Response\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\nContent-Length: "+b.length+"\r\n\r\n").getBytes("US-ASCII"));o.write(b);o.flush();}
    public void close(){closed=true;try{server.close();}catch(IOException ignored){}requests.shutdownNow();}
}
