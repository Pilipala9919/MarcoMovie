package com.pilipala.marcomovie;

import android.app.*;
import android.content.*;
import android.os.*;
import android.view.*;
import android.widget.*;
import android.graphics.*;
import java.io.*;
import java.util.concurrent.*;
import org.json.*;

/** Synthetic source with a separate preference file; never writes user playback records. */
public final class HomeProbe extends Instrumentation {
    MainActivity a;final CountDownLatch launched=new CountDownLatch(1);final JSONObject result=new JSONObject();
    @Override public void callActivityOnCreate(Activity activity,Bundle state){super.callActivityOnCreate(activity,state);if(activity instanceof MainActivity){a=(MainActivity)activity;launched.countDown();}}
    @Override public void onCreate(Bundle args){super.onCreate(args);start();}
    boolean ui(Callable<Boolean> call){boolean[] out={false};runOnMainSync(()->{try{out[0]=call.call();}catch(Exception e){throw new RuntimeException(e);}});return out[0];}
    void check(String name,boolean value)throws Exception{result.put(name,value);if(!value)throw new AssertionError(name);}
    View tag(String name){return a.root.findViewWithTag(name);}
    void await(Callable<Boolean> condition)throws Exception{long end=SystemClock.elapsedRealtime()+12000;while(SystemClock.elapsedRealtime()<end){if(ui(condition))return;SystemClock.sleep(80);}throw new AssertionError("Wait timed out");}
    void click(String name){runOnMainSync(()->{View v=tag(name);if(v==null)throw new AssertionError(name);v.requestFocus();v.performClick();});SystemClock.sleep(200);}
    void key(int code){long end=SystemClock.elapsedRealtime()+5000;while(SystemClock.elapsedRealtime()<end&&!ui(()->a.hasWindowFocus()||a.appDialog!=null))SystemClock.sleep(100);if(!ui(()->a.hasWindowFocus()||a.appDialog!=null))throw new AssertionError("Application lost window focus");sendKeyDownUpSync(code);SystemClock.sleep(300);}
    boolean noNav(){return tag("nav-home")==null&&tag("nav-settings")==null&&tag("nav-search")==null;}
    void frame(String name)throws Exception{SystemClock.sleep(250);Bitmap b=getUiAutomation().takeScreenshot();try(FileOutputStream out=new FileOutputStream(new File(a.getExternalFilesDir(null),"home-"+name+".png"))){b.compress(Bitmap.CompressFormat.PNG,100,out);}b.recycle();}
    String listing(String prefix,int count,int page)throws Exception{JSONArray list=new JSONArray();for(int i=0;i<count;i++)list.put(new JSONObject().put("vod_id",prefix+"-"+page+"-"+i).put("vod_name",prefix+" · "+(i+1)).put("vod_pic","https://fixture.test/poster.png").put("vod_remarks","合成样本"));return new JSONObject().put("page",page).put("pagecount",2).put("list",list).toString();}
    @Override public void onStart(){Cms.Config original=null;String history=null,selected=null;Integer columns=null;boolean hadHistory=false,hadSelected=false;try{
        Context context=getTargetContext();SharedPreferences before=context.getSharedPreferences("movie",0);Bundle inspection=new Bundle();inspection.putInt("history_entries_before",WatchHistory.read(before.getString("watch_history","[]")).size());inspection.putBoolean("synthetic_selected_before",before.getString("selected_site","").equals("home-fixture"));sendStatus(1,inspection);
        // Exercise a separate preference file; a process crash cannot overwrite user records.
        SharedPreferences fixture=context.getSharedPreferences("home_probe_fixture",0);SharedPreferences.Editor copy=fixture.edit().clear();for(java.util.Map.Entry<String,?> e:before.getAll().entrySet()){Object value=e.getValue();if(value instanceof String)copy.putString(e.getKey(),(String)value);else if(value instanceof Integer)copy.putInt(e.getKey(),(Integer)value);else if(value instanceof Boolean)copy.putBoolean(e.getKey(),(Boolean)value);else if(value instanceof Long)copy.putLong(e.getKey(),(Long)value);else if(value instanceof Float)copy.putFloat(e.getKey(),(Float)value);}copy.commit();
        context.startActivity(new Intent(context,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));if(!launched.await(15,TimeUnit.SECONDS))throw new AssertionError("launch");
        runOnMainSync(()->a.prefs=fixture);original=a.config;history=a.prefs.getString("watch_history","[]");selected=a.prefs.getString("selected_site","");hadHistory=a.prefs.contains("watch_history");hadSelected=a.prefs.contains("selected_site");if(a.prefs.contains("home_columns"))columns=a.prefs.getInt("home_columns",5);
        Cms.Site site=new Cms.Site();site.key="home-fixture";site.name="测试片库";site.api="https://fixture.test/api";site.type=1;
        Bitmap art=Bitmap.createBitmap(300,450,Bitmap.Config.ARGB_8888);Canvas canvas=new Canvas(art);Paint p=new Paint(3);p.setShader(new LinearGradient(0,0,300,450,0xff42636a,0xff272b35,Shader.TileMode.CLAMP));canvas.drawRect(0,0,300,450,p);p.setShader(null);p.setColor(0xffd4d2c4);canvas.drawCircle(150,130,72,p);p.setColor(Color.WHITE);p.setTextSize(28);p.setTextAlign(Paint.Align.CENTER);canvas.drawText("山海之间",150,340,p);a.images.put("https://fixture.test/poster.png",art);
        JSONArray records=new JSONArray();for(int i=0;i<3;i++){WatchHistory.Entry e=new WatchHistory.Entry();e.site=site.key;e.id="history-"+i;e.title="继续观看 · "+(i+1);e.poster="https://fixture.test/poster.png";e.episode="第 6 集";e.line="样本";e.position=1200000;e.duration=2400000;e.updated=System.currentTimeMillis();records.put(e.json());}
        final String savedRecords=records.toString();runOnMainSync(()->{Cms.Config config=new Cms.Config();config.raw="{}";config.sites.add(site);a.config=config;a.prefs.edit().putString("selected_site",site.key).putString("watch_history",savedRecords).remove("home_columns").commit();a.engines.put(site.key,new SourceEngine(){
            boolean failed;
            public String home()throws Exception{JSONObject o=new JSONObject(listing("推荐",12,1));JSONArray cats=new JSONArray();for(int i=1;i<=7;i++)cats.put(new JSONObject().put("type_id","c"+i).put("type_name",new String[]{"电影","电视剧","动漫","纪录片","综艺","其他","空分类"}[i-1]));return o.put("class",cats).toString();}
            public String category(String id,int page)throws Exception{if(id.equals("c1"))SystemClock.sleep(850);if(id.equals("c3")&&!failed){failed=true;throw new IOException("fixture failure");}return listing(id,id.equals("c7")?0:page==1?12:3,page);}
            public String search(String q,int page)throws Exception{return listing(q,2,1);}public boolean requiresExternalRuntime(){return false;}
            public String detail(String id)throws Exception{return new JSONObject().put("list",new JSONArray().put(new JSONObject().put("vod_id",id).put("vod_name","详情样本").put("vod_pic","https://fixture.test/poster.png").put("vod_content","用于检查返回后分类、焦点与位置恢复。").put("vod_play_from","样本").put("vod_play_url","第 1 集$https://fixture.test/sample.mp4"))).toString();}
        });a.back.clear();a.open(new MainActivity.Screen(a::home),false);});
        await(()->tag("home-video:11")!=null);SystemClock.sleep(300);
        check("home_has_navigation",ui(()->tag("nav-home")!=null));
        check("history_compact_landscape",ui(()->tag("home-history:0").getWidth()>tag("home-history:0").getHeight()*2));
        check("five_columns",ui(()->((ViewGroup)tag("home-video:0").getParent()).getChildCount()==5));
        check("portrait_ratio",ui(()->{View image=((ViewGroup)tag("home-video:0")).getChildAt(0);return Math.abs(image.getHeight()/(float)image.getWidth()-1.5)<.02;}));
        check("larger_posters",ui(()->((ViewGroup)tag("home-video:0")).getChildAt(0).getWidth()>=a.dp(145)));
        frame("overview");runOnMainSync(()->tag("home-video:0").requestFocus());String source=((TextView)tag("source-switcher")).getText().toString();key(KeyEvent.KEYCODE_DPAD_RIGHT);check("source_label_stable",ui(()->source.equals(((TextView)tag("source-switcher")).getText().toString())));
        key(KeyEvent.KEYCODE_DPAD_UP);check("poster_up_to_category",ui(()->tag("home-tab:0").hasFocus()));key(KeyEvent.KEYCODE_DPAD_UP);check("category_up_to_source",ui(()->tag("source-switcher").hasFocus()));key(KeyEvent.KEYCODE_DPAD_UP);check("source_up_to_history",ui(()->tag("home-history:2").hasFocus()));
        click("home-tab:1");click("home-tab:2");await(()->a.current.homeState.ready&&a.current.homeState.category.equals("c2"));SystemClock.sleep(1000);check("late_category_cannot_overwrite",ui(()->a.current.homeState.videos.get(0).id.startsWith("c2")));
        click("home-load-more");await(()->tag("home-video:14")!=null);check("pagination_appends",ui(()->a.current.homeState.videos.size()==15&&a.current.homeState.page==2));check("page_end_hides_more",ui(()->!tag("home-load-more").isShown()));
        click("home-video:11");await(()->tag("detail-favorite")!=null);check("details_hide_nav",ui(this::noNav));key(KeyEvent.KEYCODE_BACK);await(()->tag("home-video:14")!=null);check("back_restores_category_and_pages",ui(()->a.current.homeState.category.equals("c2")&&a.current.homeState.page==2));check("back_restores_card_focus",ui(()->tag("home-video:11").hasFocus()));
        click("home-tab:3");await(()->tag("home-load-more").isShown());check("failure_has_retry",ui(()->((TextView)tag("home-load-more")).getText().toString().equals("重新加载")));click("home-load-more");await(()->a.current.homeState.ready);check("retry_recovers",ui(()->a.current.homeState.videos.get(0).id.startsWith("c3")));
        click("home-category-more");check("overflow_custom_dialog",ui(()->a.appDialog!=null&&a.appDialog.findViewById(android.R.id.content).findViewWithTag("app-dialog")!=null));runOnMainSync(()->a.appDialog.findViewById(android.R.id.content).findViewWithTag("dialog-option:6").performClick());await(()->a.current.homeState.ready&&a.current.homeState.category.equals("c7"));check("empty_category_no_stale_posters",ui(()->tag("home-video:0")==null));
        click("home-tab:0");await(()->tag("home-video:0")!=null);
        click("nav-search");check("search_hides_nav",ui(this::noNav));check("search_has_focus",ui(()->a.getCurrentFocus()!=null));key(KeyEvent.KEYCODE_BACK);await(()->tag("nav-home")!=null);
        click("nav-favorites");check("favorites_hide_nav",ui(this::noNav));key(KeyEvent.KEYCODE_BACK);await(()->tag("nav-home")!=null);
        click("nav-live");check("live_hides_nav",ui(this::noNav));key(KeyEvent.KEYCODE_BACK);await(()->tag("nav-home")!=null);
        click("nav-settings");check("settings_hide_nav",ui(this::noNav));check("settings_has_focus",ui(()->a.getCurrentFocus()!=null));frame("settings");click("settings-appearance");check("nested_settings_hide_nav",ui(this::noNav));key(KeyEvent.KEYCODE_BACK);check("back_to_settings_no_nav",ui(this::noNav));key(KeyEvent.KEYCODE_BACK);await(()->tag("nav-home")!=null);check("home_restores_nav_focus",ui(()->tag("nav-settings").hasFocus()));
        click("home-history-all");check("history_hides_nav",ui(this::noNav));key(KeyEvent.KEYCODE_BACK);await(()->tag("home-history:0")!=null);
        runOnMainSync(()->{a.prefs.edit().putString("watch_history","[]").commit();a.refresh();});await(()->tag("home-video:0")!=null);check("no_history_no_blank_section",ui(()->tag("home-history:0")==null));frame("no-history");
        result.put("passed",true);
    }catch(Throwable e){try{result.put("passed",false).put("error",e.toString());}catch(Exception ignored){}}
    finally{if(a!=null&&history!=null){String h=history,s=selected;boolean hh=hadHistory,hs=hadSelected;Integer c=columns;Cms.Config cfg=original;runOnMainSync(()->{if(a.appDialog!=null)a.appDialog.dismiss();SharedPreferences.Editor edit=a.prefs.edit();if(hh)edit.putString("watch_history",h);else edit.remove("watch_history");if(hs)edit.putString("selected_site",s);else edit.remove("selected_site");if(c!=null)edit.putInt("home_columns",c);else edit.remove("home_columns");edit.commit();a.prefs=getTargetContext().getSharedPreferences("movie",0);a.config=cfg;a.engines.remove("home-fixture");a.homeData.remove("home-fixture");a.back.clear();a.open(new MainActivity.Screen(a::home),false);});}}
    Bundle report=new Bundle();report.putString("result",result.toString());sendStatus(0,report);finish(Activity.RESULT_OK,new Bundle());}
}
