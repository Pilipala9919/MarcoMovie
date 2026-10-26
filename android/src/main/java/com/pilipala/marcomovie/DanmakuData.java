package com.pilipala.marcomovie;
import org.json.*;
import java.io.*;
import java.util.*;
import javax.xml.parsers.*;
import org.w3c.dom.*;
/** Source-only comment decoding, independent of the screen and network. */
final class DanmakuData {
    static final class Comment {long time;int mode=1,color=0xffffff;String text;}
    static List<Comment> parse(String text)throws Exception{
        if(text.length()>8*1024*1024)throw new IOException("弹幕文件过大");List<Comment> out=new ArrayList<>();String content=text.trim();
        if(content.startsWith("<")){
            if(content.toUpperCase(Locale.ROOT).contains("<!DOCTYPE")||content.toUpperCase(Locale.ROOT).contains("<!ENTITY"))throw new IOException("弹幕不能包含外部实体");DocumentBuilderFactory f=DocumentBuilderFactory.newInstance();f.setExpandEntityReferences(false);Document d=f.newDocumentBuilder().parse(new ByteArrayInputStream(content.getBytes("UTF-8")));NodeList nodes=d.getElementsByTagName("d");
            for(int i=0;i<Math.min(20000,nodes.getLength());i++){Element element=(Element)nodes.item(i);String[] p=element.getAttribute("p").split(",");if(p.length<4)continue;try{Comment c=new Comment();c.time=(long)(Double.parseDouble(p[0])*1000);c.mode=Integer.parseInt(p[1]);c.color=Integer.parseInt(p[3]);c.text=element.getTextContent();add(out,c);}catch(NumberFormatException ignored){}}
        }else{
            Object root=new JSONTokener(content).nextValue();JSONArray list=root instanceof JSONArray?(JSONArray)root:((JSONObject)root).optJSONArray("danmuku");if(list==null&&root instanceof JSONObject)list=((JSONObject)root).optJSONArray("comments");if(list==null&&root instanceof JSONObject)list=((JSONObject)root).optJSONArray("data");if(list==null)throw new IOException("弹幕列表为空");
            for(int i=0;i<Math.min(20000,list.length());i++)try{Comment c=new Comment();Object item=list.get(i);if(item instanceof JSONArray){JSONArray a=(JSONArray)item;c.time=(long)(a.getDouble(0)*1000);c.mode=a.optInt(1,1);c.color=a.optInt(2,0xffffff);c.text=a.optString(3);}else if(item instanceof JSONObject){JSONObject o=(JSONObject)item;c.time=(long)(o.optDouble("time",o.optDouble("t",0))*1000);c.mode=o.optInt("mode",1);c.color=o.optInt("color",0xffffff);c.text=o.optString("text",o.optString("m",o.optString("content")));if(o.has("p")){String[] p=o.getString("p").split(",");c.time=(long)(Double.parseDouble(p[0])*1000);if(p.length>1)c.color=Integer.parseInt(p[1]);if(p.length>2)c.mode=Integer.parseInt(p[2]);}}else continue;add(out,c);}catch(Exception ignored){}
        }
        out.sort(Comparator.comparingLong(c->c.time));return out;
    }
    static void add(List<Comment> out,Comment c){if(c.time<0||c.text==null||c.text.trim().isEmpty())return;c.text=c.text.replaceAll("[\\p{Cntrl}]"," ");if(c.text.length()>180)c.text=c.text.substring(0,180);out.add(c);}
}
