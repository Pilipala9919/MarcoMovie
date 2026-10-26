package com.pilipala.marcomovie;

/** Stable host-side boundary. Implementations must return CMS-shaped JSON, never UI. */
public interface SourceEngine {
    String home() throws Exception;
    String category(String categoryId, int page) throws Exception;
    String detail(String videoId) throws Exception;
    String search(String keyword, int page) throws Exception;
    boolean requiresExternalRuntime();
    default String homeVideos()throws Exception{return "{\"list\":[]}";}
    default String player(String flag,String id)throws Exception{return new org.json.JSONObject().put("parse",0).put("url",id).toString();}
    default String action(String action)throws Exception{throw new java.io.IOException("此来源没有提供交互接口");}
    default void close(){}
}
