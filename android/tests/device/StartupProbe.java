package com.pilipala.marcomovie;

import android.app.*;
import android.content.*;
import android.os.*;
import android.view.*;
import android.graphics.Bitmap;
import java.io.*;
import java.util.concurrent.*;
import org.json.JSONObject;

/** Startup lifecycle checks; preferences are redirected to a disposable file. */
public final class StartupProbe extends Instrumentation {
    MainActivity a;final CountDownLatch launched=new CountDownLatch(1);final JSONObject report=new JSONObject();
    @Override public void onCreate(Bundle args){super.onCreate(args);start();}
    @Override public void callActivityOnCreate(Activity activity,Bundle state){super.callActivityOnCreate(activity,state);if(activity instanceof MainActivity){a=(MainActivity)activity;launched.countDown();}}
    boolean ui(Callable<Boolean> fn){boolean[] value={false};runOnMainSync(()->{try{value[0]=fn.call();}catch(Exception e){throw new RuntimeException(e);}});return value[0];}
    void check(String key,boolean ok)throws Exception{report.put(key,ok);if(!ok)throw new AssertionError(key);}
    void await(Callable<Boolean> fn,int ms)throws Exception{long end=SystemClock.elapsedRealtime()+ms;while(SystemClock.elapsedRealtime()<end){if(ui(fn))return;SystemClock.sleep(30);}throw new AssertionError("timeout");}
    void frame(String name)throws Exception{Bitmap b=getUiAutomation().takeScreenshot();try(FileOutputStream out=new FileOutputStream(new File(a.getExternalFilesDir(null),name+".png"))){b.compress(Bitmap.CompressFormat.PNG,100,out);}b.recycle();}
    @Override public void onStart(){SharedPreferences original=null;boolean reduced=false;try{
        Context c=getTargetContext();c.startActivity(new Intent(c,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));if(!launched.await(15,TimeUnit.SECONDS))throw new AssertionError("launch");
        check("cold_launch_overlay",ui(()->a.startupIntro!=null));await(()->a.startupIntro!=null&&a.startupIntro.rendered,4000);StartupIntro first=a.startupIntro;
        check("video_produces_frame",ui(()->first.media!=null&&first.media.getVideoWidth()==1280&&first.media.getVideoHeight()==720));
        report.put("intro_width",first.video.getWidth()).put("root_width",a.root.getWidth()).put("overlay_width",first.getWidth());check("intro_compact_and_not_upscaled",ui(()->first.video.getWidth()<=1280&&first.video.getWidth()<a.root.getWidth()*.57f&&first.video.getWidth()>a.root.getWidth()*.5f));check("intro_centered",ui(()->Math.abs(first.video.getX()+first.video.getWidth()/2f-first.getWidth()/2f)<2));
        check("homepage_loads_under_overlay",ui(()->a.current.home&&a.root.findViewWithTag("nav-home")!=null));
        check("fullscreen_black_overlay",ui(()->first.getWidth()==a.getWindow().getDecorView().getWidth()&&first.getHeight()==a.getWindow().getDecorView().getHeight()));
        SystemClock.sleep(1400);frame("startup-playing");await(()->a.startupIntro==null,5000);check("completion_releases_player",first.released&&first.media==null&&first.getParent()==null);check("home_focus_preserved",ui(()->a.getCurrentFocus()!=null));frame("startup-home");
        original=a.prefs;reduced=a.reduced;SharedPreferences fixture=c.getSharedPreferences("startup_probe_fixture",0);fixture.edit().clear().putBoolean("startup_animation",true).commit();runOnMainSync(()->{a.prefs=fixture;a.reduced=false;StartupIntro.show(a);});await(()->a.startupIntro!=null&&a.startupIntro.rendered,4000);
        runOnMainSync(()->{a.dispatchKeyEvent(new KeyEvent(KeyEvent.ACTION_DOWN,KeyEvent.KEYCODE_BACK));a.dispatchKeyEvent(new KeyEvent(KeyEvent.ACTION_UP,KeyEvent.KEYCODE_BACK));});await(()->a.startupIntro==null,1000);check("back_skips_without_exiting",ui(()->!a.isFinishing()&&a.current.home));
        runOnMainSync(()->StartupIntro.show(a));StartupIntro confirmed=a.startupIntro;runOnMainSync(()->{a.dispatchKeyEvent(new KeyEvent(KeyEvent.ACTION_DOWN,KeyEvent.KEYCODE_DPAD_CENTER));a.dispatchKeyEvent(new KeyEvent(KeyEvent.ACTION_UP,KeyEvent.KEYCODE_DPAD_CENTER));});await(()->a.startupIntro==null,1000);check("confirm_skips_without_opening_content",ui(()->a.current.home&&!a.isFinishing()));check("skip_releases_player",confirmed.released&&confirmed.getParent()==null);
        runOnMainSync(()->StartupIntro.show(a));StartupIntro stopped=a.startupIntro;runOnMainSync(()->callActivityOnStop(a));check("background_releases_intro",ui(()->a.startupIntro==null&&stopped.released));runOnMainSync(()->callActivityOnStart(a));check("resume_does_not_replay",ui(()->a.startupIntro==null));
        runOnMainSync(()->{a.reduced=true;StartupIntro.show(a);});check("reduced_motion_skips_intro",ui(()->a.startupIntro==null));
        runOnMainSync(()->{a.reduced=false;fixture.edit().putBoolean("startup_animation",false).commit();StartupIntro.show(a);});check("setting_disables_intro",ui(()->a.startupIntro==null));
        runOnMainSync(()->{fixture.edit().putBoolean("startup_animation",true).commit();StartupIntro.show(a);});StartupIntro fallback=a.startupIntro;runOnMainSync(fallback.timeout);check("timeout_falls_back_to_home",ui(()->a.startupIntro==null&&fallback.released&&!a.isFinishing()));
        report.put("passed",true);
    }catch(Throwable e){try{report.put("passed",false).put("error",e.toString());}catch(Exception ignored){}}finally{if(a!=null){SharedPreferences prefs=original;boolean motion=reduced;runOnMainSync(()->{if(a.startupIntro!=null)a.startupIntro.cancel();if(prefs!=null){a.prefs=prefs;a.reduced=motion;}});}}
        Bundle result=new Bundle();result.putString("result",report.toString());sendStatus(0,result);finish(Activity.RESULT_OK,new Bundle());
    }
}
