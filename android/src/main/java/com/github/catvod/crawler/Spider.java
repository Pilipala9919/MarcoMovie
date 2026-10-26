package com.github.catvod.crawler;

import android.content.Context;
import java.util.*;

/** Independently written host ABI from the operator-supplied plugin's public descriptors. */
public class Spider {
    public Spider(){}
    public void init(Context context,String extend)throws Exception{init(context);}
    public void init(Context context)throws Exception{}
    public String homeContent(boolean filter)throws Exception{return "{}";}
    public String homeVideoContent()throws Exception{return "{\"list\":[]}";}
    public String categoryContent(String tid,String page,boolean filter,HashMap<String,String> extend)throws Exception{return "{\"list\":[]}";}
    public String detailContent(List<String> ids)throws Exception{return "{\"list\":[]}";}
    public String playerContent(String flag,String id,List<String> vipFlags)throws Exception{return "{}";}
    public String searchContent(String key,boolean quick)throws Exception{return "{\"list\":[]}";}
    public String searchContent(String key,boolean quick,String page)throws Exception{return searchContent(key,quick);}
    public String action(String action)throws Exception{return "";}
    public void destroy(){}
    public boolean isVideoFormat(String url){return false;}
    public boolean manualVideoCheck(){return false;}
    public Object[] proxyLocal(Map<String,String> parameters)throws Exception{return null;}
    public void cancelByTag(){}
    public String liveContent(String url){return "";}
}
