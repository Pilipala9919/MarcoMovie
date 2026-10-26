package com.pilipala.marcomovie;
import java.net.URI;
/** Pure URL routing for the reserved source proxy endpoint. */
final class ProxyAddress {
    static volatile int port=9978;
    static String base(){return "http://127.0.0.1:"+port;}
    static String rewrite(String value,int port){
        if(value==null||port<1||port>65535)return value;
        try{String candidate=value.replace("http://127.0.0.1:-1/","http://127.0.0.1:9978/").replace("http://localhost:-1/","http://localhost:9978/");URI uri=new URI(candidate);String host=uri.getHost();int original=uri.getPort();if(!"http".equalsIgnoreCase(uri.getScheme())||!("127.0.0.1".equals(host)||"localhost".equalsIgnoreCase(host)||"[::1]".equals(host))||!"/proxy".equals(uri.getPath())||original<9978||original>9999)return value;return "http://127.0.0.1:"+port+uri.getRawPath()+(uri.getRawQuery()==null?"":"?"+uri.getRawQuery())+(uri.getRawFragment()==null?"":"#"+uri.getRawFragment());}catch(Exception ignored){return value;}
    }
}
