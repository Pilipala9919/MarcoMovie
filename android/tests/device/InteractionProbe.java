package com.pilipala.marcomovie;

import android.app.*;
import android.content.*;
import android.os.*;
import android.view.*;
import android.graphics.*;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;
import org.json.*;

/** Synthetic content only. Existing favorites and playback preferences are restored. */
public final class InteractionProbe extends Instrumentation {
    Bundle args;MainActivity a;final CountDownLatch launched=new CountDownLatch(1);JSONObject result=new JSONObject();
    @Override public void callActivityOnCreate(Activity activity,Bundle state){super.callActivityOnCreate(activity,state);if(activity instanceof MainActivity){a=(MainActivity)activity;launched.countDown();}}
    @Override public void onCreate(Bundle input){super.onCreate(input);args=input;start();}
    void check(String name,boolean pass)throws Exception{result.put(name,pass);if(!pass)throw new AssertionError(name);}
    boolean ui(java.util.concurrent.Callable<Boolean> action){boolean[] value={false};runOnMainSync(()->{try{value[0]=action.call();}catch(Exception e){throw new RuntimeException(e);}});return value[0];}
    void key(int code){sendKeyDownUpSync(code);SystemClock.sleep(220);}
    void frame(String name)throws Exception{Bitmap bitmap=getUiAutomation().takeScreenshot();if(bitmap==null)throw new IOException("Screenshot unavailable");File file=new File(a.getExternalFilesDir(null),"test-"+name+".png");try(OutputStream out=new FileOutputStream(file)){bitmap.compress(Bitmap.CompressFormat.PNG,100,out);}bitmap.recycle();}
    @Override public void onStart(){String favorites=null;boolean hadFavorites=false;Cms.Config original=null;
        try{
            Context context=getTargetContext();context.startActivity(new Intent(context,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));if(!launched.await(15,TimeUnit.SECONDS))throw new IOException("Launch timeout");
            favorites=a.prefs.getString("favorites","[]");hadFavorites=a.prefs.contains("favorites");original=a.config;
            Cms.Site site=new Cms.Site();site.key="interaction-test";site.name="Synthetic";site.type=1;site.api="https://fixture.test/api";
            Cms.Video video=new Cms.Video();video.id="sample";video.title="Marco Movie · 测试画面";video.poster="";video.remarks="本地合成样本";
            Cms.Episode ep=new Cms.Episode();ep.name="遥控体验";ep.url=args.getString("base")+"h264-aac.mp4";
            runOnMainSync(()->{a.activeLine=null;a.activeEpisode=null;a.openPlayer(site,video,ep);});
            long until=SystemClock.elapsedRealtime()+25000;while(SystemClock.elapsedRealtime()<until&&!ui(()->a.prepared))SystemClock.sleep(100);
            check("real_video_prepared",ui(()->a.prepared));runOnMainSync(()->{a.player.setRepeatOne(true);a.showControls(false);});SystemClock.sleep(250);
            check("no_pause_button",ui(()->!a.playbackControls.buttons.containsKey("primary")));
            key(KeyEvent.KEYCODE_DPAD_CENTER);check("confirm_pauses",ui(()->!a.player.isPlaying()&&a.controlsVisible));int pos=a.player.getCurrentPosition();SystemClock.sleep(450);check("paused_clock_stable",Math.abs(a.player.getCurrentPosition()-pos)<120);frame("dock");
            key(KeyEvent.KEYCODE_DPAD_CENTER);check("confirm_resumes",ui(()->a.player.isPlaying()));
            runOnMainSync(()->a.showControls(false));key(KeyEvent.KEYCODE_DPAD_UP);check("up_opens_progress",ui(()->a.controlsVisible&&a.getCurrentFocus()==a.playbackControls.timeline));
            runOnMainSync(()->a.showControls(false));key(KeyEvent.KEYCODE_DPAD_DOWN);check("down_opens_progress",ui(()->a.controlsVisible&&a.getCurrentFocus()==a.playbackControls.timeline));
            key(KeyEvent.KEYCODE_DPAD_DOWN);check("dock_buttons_reachable",ui(()->a.getCurrentFocus()==a.playbackControls.buttons.get("episodes")));
            runOnMainSync(()->a.playbackControls.buttons.get("speed").requestFocus());key(KeyEvent.KEYCODE_DPAD_CENTER);check("confirm_activates_focused_action",ui(()->a.playbackControls.dialogOpen));key(KeyEvent.KEYCODE_BACK);
            key(KeyEvent.KEYCODE_BACK);check("back_hides_dock",ui(()->!a.controlsVisible));
            runOnMainSync(()->{a.releasePlayer();a.prefs.edit().putString("favorites","[]").commit();a.engines.put(site.key,new SourceEngine(){
                public String home(){return "{}";}public String category(String id,int page){return "{}";}public String search(String q,int page){return "{}";}public boolean requiresExternalRuntime(){return false;}
                public String detail(String id)throws Exception{return new JSONObject().put("list",new JSONArray().put(new JSONObject().put("vod_id",video.id).put("vod_name",video.title).put("vod_pic",""))).toString();}
            });a.open(new MainActivity.Screen(()->a.detail(site,video)),true);});
            long detailLimit=SystemClock.elapsedRealtime()+10000;while(SystemClock.elapsedRealtime()<detailLimit&&!ui(()->a.root.findViewWithTag("detail-favorite")!=null))SystemClock.sleep(100);
            check("detail_favorite_button",ui(()->a.root.findViewWithTag("detail-favorite")!=null));runOnMainSync(()->a.root.findViewWithTag("detail-favorite").requestFocus());key(KeyEvent.KEYCODE_DPAD_CENTER);check("detail_adds_favorite",Favorites.contains(a.prefs.getString("favorites","[]"),site.key,video.id));
            runOnMainSync(()->a.open(new MainActivity.Screen(()->new FavoritesScreen(a).show()),true));
            check("favorites_entry",ui(()->a.root.findViewWithTag("nav-favorites")!=null&&a.root.findViewWithTag("favorite:"+site.key+"\n"+video.id)!=null));SystemClock.sleep(350);frame("favorites");
            runOnMainSync(()->a.root.findViewWithTag("favorite:"+site.key+"\n"+video.id).requestFocus());key(KeyEvent.KEYCODE_MENU);
            android.view.accessibility.AccessibilityNodeInfo tree=getUiAutomation().getRootInActiveWindow();boolean removed=false;
            if(tree!=null)for(android.view.accessibility.AccessibilityNodeInfo node:tree.findAccessibilityNodeInfosByText("取消收藏")){android.view.accessibility.AccessibilityNodeInfo click=node;while(click!=null&&!click.isClickable())click=click.getParent();if(click!=null){removed=click.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK);break;}}
            check("favorite_remove_action",removed);SystemClock.sleep(350);
            check("favorites_empty_state",ui(()->Favorites.read(a.prefs.getString("favorites","[]")).isEmpty()));
            runOnMainSync(()->{a.open(new MainActivity.Screen(()->new SettingsScreen(a).show()),true);});check("no_duplicate_account_settings",ui(()->a.root.findViewWithTag("settings-accounts")==null));
            runOnMainSync(()->a.root.findViewWithTag("nav-accounts").performClick());SystemClock.sleep(350);check("account_popup_visible",ui(()->a.accountDialog!=null&&a.accountDialog.isShowing()));check("single_login_entry",ui(()->a.accountDialog.findViewById(android.R.id.content).findViewWithTag("account-action:LoginShow")!=null));frame("accounts");key(KeyEvent.KEYCODE_BACK);check("account_focus_restored",ui(()->a.accountDialog==null&&a.getCurrentFocus()==a.root.findViewWithTag("nav-accounts")));
            result.put("passed",true);
        }catch(Throwable error){try{result.put("passed",false).put("error",error.toString());}catch(Exception ignored){}}
        finally{if(a!=null){String saved=favorites;boolean present=hadFavorites;Cms.Config config=original;runOnMainSync(()->{a.releasePlayer();if(a.accountDialog!=null)a.accountDialog.dismiss();if(saved!=null){if(present)a.prefs.edit().putString("favorites",saved).commit();else a.prefs.edit().remove("favorites").commit();}a.engines.remove("interaction-test");a.config=config;});}}
        Bundle report=new Bundle();report.putString("result",result.toString());sendStatus(0,report);finish(Activity.RESULT_OK,new Bundle());
    }
}
