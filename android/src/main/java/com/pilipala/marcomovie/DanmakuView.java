package com.pilipala.marcomovie;

import android.content.Context;
import com.pilipala.marcomovie.DanmakuData.Comment;
import android.graphics.*;
import android.view.View;
import org.json.*;
import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;
import javax.xml.parsers.*;
import org.w3c.dom.*;

/** A bounded source-provided comment overlay; animation is derived from the media clock. */
final class DanmakuView extends View implements AutoCloseable {
    interface Clock {int position();boolean playing();}
    interface Listener {void loaded(int count);void error(String message);}
    final Clock clock;final Paint paint=new Paint(3);final ExecutorService loader=Executors.newSingleThreadExecutor();
    List<Comment> comments=Collections.emptyList();boolean closed,enabled;int request;float textSize=23,opacity=.85f,area=.5f;
    DanmakuView(Context context,Clock clock){super(context);this.clock=clock;setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);setLayerType(View.LAYER_TYPE_SOFTWARE,null);}
    void enabled(boolean value){enabled=value;setVisibility(value?VISIBLE:GONE);invalidate();}
    void load(String url,Map<String,String> headers,Listener listener){final int ticket=++request;loader.execute(()->{HttpURLConnection connection=null;try{
        String address=LocalProxy.rewrite(url);if(!Cms.isHttp(address))throw new IOException("来源没有提供有效弹幕地址");connection=(HttpURLConnection)new URL(Cms.normalizeHttp(address)).openConnection();connection.setConnectTimeout(8000);connection.setReadTimeout(12000);connection.setRequestProperty("User-Agent",Cms.USER_AGENT);for(Map.Entry<String,String> h:headers.entrySet())connection.setRequestProperty(h.getKey(),h.getValue());String body;try(InputStream in=connection.getInputStream()){body=Cms.read(in,8*1024*1024);}List<Comment> values=DanmakuData.parse(body);post(()->{if(!closed&&ticket==request){comments=values;listener.loaded(values.size());invalidate();}});
    }catch(Exception error){post(()->{if(!closed&&ticket==request)listener.error("弹幕暂时不可用，可导入本地 XML / JSON 文件。");});}finally{if(connection!=null)connection.disconnect();}});}
    void loadText(String text,Listener listener){final int ticket=++request;loader.execute(()->{try{List<Comment> values=DanmakuData.parse(text);post(()->{if(!closed&&ticket==request){comments=values;listener.loaded(values.size());invalidate();}});}catch(Exception error){post(()->{if(!closed&&ticket==request)listener.error("无法识别弹幕文件。");});}});}
    @Override protected void onDraw(Canvas canvas){super.onDraw(canvas);if(!enabled||closed)return;long now=clock.position();float density=getResources().getDisplayMetrics().density;paint.setTextSize(textSize*density);paint.setTypeface(Typeface.create("sans-serif",Typeface.BOLD));paint.setShadowLayer(2*density,0,1*density,Color.BLACK);int lanes=Math.max(1,Math.min(6,(int)(getHeight()*area/(textSize*density*1.5f))));int lo=0,hi=comments.size();while(lo<hi){int middle=(lo+hi)>>>1;if(comments.get(middle).time<now-8000)lo=middle+1;else hi=middle;}int drawn=0;
        for(int i=lo;i<comments.size()&&drawn<60;i++){Comment c=comments.get(i);long age=now-c.time;if(age<0)break;long duration=c.mode==4||c.mode==5?4000:8000;if(age>duration)continue;float width=paint.measureText(c.text),x=(getWidth()+width)*(1-age/(float)duration)-width;float y=(i%lanes+1)*textSize*density*1.45f;if(c.mode==4){x=(getWidth()-width)/2;y=getHeight()-textSize*density*(1.5f+i%2);}else if(c.mode==5)x=(getWidth()-width)/2;paint.setColor(0xff000000|(c.color&0xffffff));paint.setAlpha((int)(opacity*255));canvas.drawText(c.text,x,y,paint);drawn++;}
        if(clock.playing())postInvalidateDelayed(33);
    }
    @Override public void close(){closed=true;request++;loader.shutdownNow();comments=Collections.emptyList();}
}
