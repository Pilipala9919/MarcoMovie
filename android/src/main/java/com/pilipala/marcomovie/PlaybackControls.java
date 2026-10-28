package com.pilipala.marcomovie;

import android.app.Dialog;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.view.*;
import android.widget.*;
import java.util.*;

/** Independent TV playback controls. Every visible action is wired to playback state. */
final class PlaybackControls {
    final MainActivity a;final Cms.Site site;final Cms.Video video;final Cms.Episode resolved;
    final SeekBar timeline;final androidx.media3.ui.SubtitleView subtitle;final TextureView surface;
    final PlaybackEffects effects=new PlaybackEffects();
    final DanmakuView danmaku; boolean danmakuLoaded;
    final Map<String,Button> buttons=new LinkedHashMap<>();
    Dialog activeDialog;View menuAnchor;String lastSubtitle="";boolean dialogOpen,transitioning;int videoWidth,videoHeight;
    PlaybackControls(MainActivity host,LinearLayout overlay,LinearLayout progress,TextureView texture,Cms.Site s,Cms.Video v,Cms.Episode ep){
        a=host;site=s;video=v;resolved=ep;surface=texture;danmaku=new DanmakuView(a,new DanmakuView.Clock(){public int position(){return a.player==null?0:a.player.getCurrentPosition();}public boolean playing(){return a.player!=null&&a.player.isPlaying();}});a.playbackLayer.addView(danmaku,1,new FrameLayout.LayoutParams(-1,-1));danmaku.enabled(false);
        subtitle=new androidx.media3.ui.SubtitleView(a);subtitle.setFractionalTextSize(Math.max(25,Math.min(65,a.prefs.getInt("subtitle_size",45)))/1000f);subtitle.setUserDefaultStyle();subtitle.setPadding(a.dp(40),0,a.dp(40),a.dp(24));FrameLayout.LayoutParams caption=new FrameLayout.LayoutParams(-1,-1,Gravity.BOTTOM);caption.bottomMargin=a.dp(168);a.playbackLayer.addView(subtitle,1,caption);
        timeline=new SeekBar(a);timeline.setTag("timeline");timeline.setBackgroundColor(Color.TRANSPARENT);timeline.setFocusable(true);timeline.setProgressTintList(ColorStateList.valueOf(0xfff5f5f7));timeline.setThumbTintList(ColorStateList.valueOf(Color.WHITE));timeline.setKeyProgressIncrement(10000);progress.addView(timeline,new LinearLayout.LayoutParams(-1,a.dp(32)));
        timeline.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener(){public void onStartTrackingTouch(SeekBar b){a.scheduleHide();}public void onStopTrackingTouch(SeekBar b){a.scheduleHide();}public void onProgressChanged(SeekBar b,int position,boolean user){if(user&&a.prepared&&a.player!=null){a.player.seekTo(position);a.scheduleHide();}}});
        HorizontalScrollView scroller=new HorizontalScrollView(a);scroller.setHorizontalScrollBarEnabled(false);scroller.setFillViewport(true);scroller.setClipToPadding(false);LinearLayout row=a.row();row.setGravity(Gravity.CENTER);row.setClipChildren(false);row.setPadding(a.dp(1),a.dp(2),a.dp(1),a.dp(2));scroller.addView(row);overlay.addView(scroller);
        add(row,"下集","next-episode",()->step(1));add(row,"选集","episodes",()->chooseEpisodes());add(row,"线路","lines",()->chooseLine());
        add(row,"1.0×","speed",()->speed());add(row,"画面","aspect",()->aspect());add(row,"字幕","subtitles",()->tracks(3));add(row,"更多","more",()->more());
        timeline.setId(View.generateViewId());
        List<Button> all=new ArrayList<>(buttons.values());for(Button b:all)b.setId(View.generateViewId());for(Button b:all)b.setNextFocusUpId(timeline.getId());timeline.setNextFocusDownId(all.get(0).getId());
        all.get(0).setNextFocusLeftId(all.get(all.size()-1).getId());all.get(all.size()-1).setNextFocusRightId(all.get(0).getId());
        all.get(0).setOnKeyListener((view,key,event)->{if(key!=KeyEvent.KEYCODE_DPAD_LEFT)return false;if(event.getAction()==KeyEvent.ACTION_DOWN)all.get(all.size()-1).requestFocus();return true;});
        all.get(all.size()-1).setOnKeyListener((view,key,event)->{if(key!=KeyEvent.KEYCODE_DPAD_RIGHT)return false;if(event.getAction()==KeyEvent.ACTION_DOWN)all.get(0).requestFocus();return true;});
        updateLabels();
    }
    Button add(LinearLayout row,String title,String key,Runnable action){Button b=a.button(title,key,()->{menuAnchor=buttons.get(key);action.run();});b.setSingleLine(true);b.setTextSize(13);b.setMinWidth(0);b.setMinimumWidth(0);b.setMinHeight(a.dp(42));b.setMinimumHeight(a.dp(42));b.setPadding(a.dp(6),0,a.dp(6),0);b.setBackground(a.bg(0x16ffffff,19));b.setOnFocusChangeListener((view,focused)->{view.animate().cancel();b.setTextColor(focused?MainActivity.DARK:MainActivity.WHITE);b.setBackground(a.bg(focused?0xfff5f5f7:0x16ffffff,19));view.animate().scaleX(focused&&!a.reduced?1.04f:1).scaleY(focused&&!a.reduced?1.04f:1).setDuration(a.reduced?0:150).start();});LinearLayout.LayoutParams size=new LinearLayout.LayoutParams(a.dp(68),a.dp(42));size.setMargins(a.dp(4),a.dp(4),a.dp(4),a.dp(4));row.addView(b,size);buttons.put(key,b);return b;}
    int lineIndex(){return a.activeLine==null?-1:video.lines.indexOf(a.activeLine);}
    int episodeIndex(){return a.activeLine==null?-1:a.activeLine.episodes.indexOf(a.activeEpisode);}
    void choose(String title,String[] labels,int selected,java.util.function.IntConsumer action){
        showBubble(title,labels,selected,action,"");
    }
    void message(String text){showBubble("播放提示",new String[]{"完成"},-1,i->{},text);}
    void showBubble(String title,String[] labels,int selected,java.util.function.IntConsumer action,String message){
        if(activeDialog!=null){activeDialog.dismiss();activeDialog=null;}
        if(menuAnchor==null||!menuAnchor.isAttachedToWindow())menuAnchor=buttons.get("more");
        dialogOpen=true;if(a.hideControls!=null)a.ui.removeCallbacks(a.hideControls);
        final Dialog[] holder=new Dialog[1];holder[0]=PlayerBubble.show(a,menuAnchor,title,labels,selected,action,()->{if(activeDialog==holder[0]){activeDialog=null;dialogOpen=false;a.scheduleHide();}},message);activeDialog=holder[0];
    }
    void chooseEpisodes(){int l=lineIndex();if(l<0){message("此内容没有可切换的剧集。");return;}Cms.Line line=video.lines.get(l);String[] labels=new String[line.episodes.size()];for(int i=0;i<labels.length;i++)labels[i]=line.episodes.get(i).name;choose(line.name+" · 选集",labels,episodeIndex(),i->a.changeEpisode(site,video,line,line.episodes.get(i),0));}
    void chooseLine(){if(video.lines.isEmpty()){message("此内容只有当前地址。");return;}String[] labels=new String[video.lines.size()];for(int i=0;i<labels.length;i++)labels[i]=video.lines.get(i).name;choose("选择播放线路",labels,lineIndex(),i->{Cms.Line line=video.lines.get(i);if(!line.episodes.isEmpty()){int n=Math.min(Math.max(0,episodeIndex()),line.episodes.size()-1);a.changeEpisode(site,video,line,line.episodes.get(n),0);}});}
    boolean step(int direction){int i=episodeIndex(),l=lineIndex();if(l<0||i<0)return false;Cms.Line line=video.lines.get(l);int next=i+direction;if(a.prefs.getInt("repeat_mode",0)==2)next=(next+line.episodes.size())%line.episodes.size();if(next<0||next>=line.episodes.size())return false;transitioning=true;a.changeEpisode(site,video,line,line.episodes.get(next),0);return true;}
    void reload(boolean preserve){int position=preserve&&a.prepared&&a.player!=null?a.player.getCurrentPosition():0;if(a.activeLine!=null&&a.activeEpisode!=null)a.changeEpisode(site,video,a.activeLine,a.activeEpisode,position);else{a.resumeAt=position;a.playerPage(site,video,resolved);}}
    void speed(){if(a.player==null)return;float[] speeds={.5f,.75f,1f,1.25f,1.5f,1.75f,2f};String[] labels={"0.5×","0.75×","1.0×","1.25×","1.5×","1.75×","2.0×"};int current=2;for(int i=0;i<speeds.length;i++)if(speeds[i]==a.player.getSpeed())current=i;choose("播放速度",labels,current,i->{if(a.player!=null)a.player.setSpeed(speeds[i]);a.prefs.edit().putFloat("play_speed",speeds[i]).apply();updateLabels();});}
    void aspect(){String[] labels={"适应画面","铺满屏幕","16:9","4:3","裁切填充"};choose("画面比例",labels,a.prefs.getInt("aspect",0),i->{a.prefs.edit().putInt("aspect",i).apply();resize(videoWidth,videoHeight);updateLabels();});}
    void engine(){choose("选择播放器",new String[]{"Media3 · 网络与字幕优先","系统播放器"},a.prefs.getInt("player_engine",0),i->{a.prefs.edit().putInt("player_engine",i).apply();reload(true);});}
    void decoder(){choose("选择解码方式",new String[]{"自动选择（默认）","设备硬件解码","软件解码优先（高分辨率可能较慢）"},a.prefs.getInt("decoder_mode",0),i->{a.prefs.edit().putInt("decoder_mode",i).apply();reload(true);});}
    void danmaku(){choose("弹幕",new String[]{"开启 / 重新加载来源弹幕","关闭弹幕","导入本地弹幕 XML / JSON"},-1,i->{if(i==1){danmaku.enabled(false);return;}if(i==2){a.pickDanmaku();return;}String address=resolved.media.optString("danmaku");if(address.isEmpty()){message("当前来源没有提供弹幕，可导入本地 XML / JSON。");return;}danmaku.enabled(true);danmaku.load(address,resolved.headers,new DanmakuView.Listener(){public void loaded(int count){a.toast("已加载 "+count+" 条弹幕");}public void error(String message){message(message);}});});}
    void soundEffect(){choose("音效",new String[]{"原声","影院","人声清晰","柔和低音"},a.prefs.getInt("audio_effect",0),i->{try{if(a.player==null)throw new IllegalStateException();effects.audio(a.player.getAudioSessionId(),i);a.prefs.edit().putInt("audio_effect",i).apply();}catch(Exception error){message("这台设备当前音轨未提供可用音效接口。");}});}
    void pictureEffect(){choose("画面色彩",new String[]{"原始画面","明亮","影院","柔和"},a.prefs.getInt("picture_effect",0),i->{PlaybackEffects.picture(surface,i);a.prefs.edit().putInt("picture_effect",i).apply();});}
    void close(){if(activeDialog!=null){activeDialog.dismiss();activeDialog=null;}effects.close();danmaku.close();}
    void tracks(int type){
        if(a.player==null||!a.prepared){message("请等待视频开始播放。");return;}
        List<String> tracks=a.player.trackLabels(type);List<String> labels=new ArrayList<>();labels.add(type==3?"关闭字幕":"自动选择");labels.addAll(tracks);if(type==3)labels.add("导入字幕文件…");
        if(type!=3&&tracks.isEmpty()){message("当前视频没有可选择的音轨。");return;}
        choose(type==3?"字幕":"音轨",labels.toArray(new String[0]),-1,i->{if(type==3&&i==labels.size()-1)a.pickSubtitle();else if(a.player!=null)a.player.selectTrack(type,i==0?(type==3?-2:-1):i-1);});
    }
    void skip(boolean intro){int[] seconds={0,15,30,60,90,120,180};String[] labels={"关闭","15 秒","30 秒","1 分钟","1 分 30 秒","2 分钟","3 分钟"};String key=intro?"skip_intro":"skip_outro";int selected=0;for(int i=0;i<seconds.length;i++)if(seconds[i]==a.prefs.getInt(key,0))selected=i;choose(intro?"自动跳过片头":"自动跳过片尾",labels,selected,i->{a.prefs.edit().putInt(key,seconds[i]).apply();updateLabels();});}
    void repeat(){choose("循环播放",new String[]{"关闭","单集循环","列表循环"},a.prefs.getInt("repeat_mode",0),i->{a.prefs.edit().putInt("repeat_mode",i).apply();if(a.player!=null)a.player.setRepeatOne(i==1&&a.prefs.getInt("skip_outro",0)==0);updateLabels();});}
    void more(){String[] labels={"音轨","播放器与解码","刷新播放","从头重播","上一集","跳过片头 / 片尾","弹幕","音效","画面色彩","循环播放","自动播放下集："+(a.prefs.getBoolean("auto_next",true)?"开启":"关闭"),"播放信息","返回详情"};choose("更多",labels,-1,i->{switch(i){case 0:tracks(1);break;case 1:choose("播放器与解码",new String[]{"切换播放器","切换解码方式"},-1,n->{if(n==0)engine();else decoder();});break;case 2:reload(true);break;case 3:if(a.player!=null&&a.prepared){a.player.seekTo(0);a.player.start();a.playing=true;}else reload(false);break;case 4:if(!step(-1))message("已经是第一集。");break;case 5:choose("自动跳过",new String[]{"片头 · "+skipLabel(a.prefs.getInt("skip_intro",0)),"片尾 · "+skipLabel(a.prefs.getInt("skip_outro",0))},-1,n->skip(n==0));break;case 6:danmaku();break;case 7:soundEffect();break;case 8:pictureEffect();break;case 9:repeat();break;case 10:a.prefs.edit().putBoolean("auto_next",!a.prefs.getBoolean("auto_next",true)).apply();break;case 11:message(a.player==null?"播放器尚未准备好。":a.player.playbackInfo());break;case 12:a.leavePlayback();break;}});}
    void updateLabels(){buttons.get("speed").setText(a.prefs.getFloat("play_speed",1)+"×");}
    String skipLabel(int seconds){return seconds==0?"关闭":a.time(seconds*1000);}
    void prepared(){if(a.player==null)return;if(a.prefs.getBoolean("danmaku_default",false)&&!danmakuLoaded&&!resolved.media.optString("danmaku").isEmpty()){danmakuLoaded=true;danmaku.enabled(true);danmaku.load(resolved.media.optString("danmaku"),resolved.headers,new DanmakuView.Listener(){public void loaded(int count){}public void error(String message){}});}PlaybackEffects.picture(surface,a.prefs.getInt("picture_effect",0));try{effects.audio(a.player.getAudioSessionId(),a.prefs.getInt("audio_effect",0));}catch(Exception ignored){}int duration=a.player.getDuration();timeline.setEnabled(duration>0);timeline.setMax(Math.max(1,duration));timeline.setKeyProgressIncrement(10000);int seek=a.resumeAt>0?a.resumeAt:a.prefs.getInt("skip_intro",0)*1000;a.resumeAt=0;if(duration>0&&seek>0&&seek<duration-1000)a.player.seekTo(seek);a.player.setSpeed(a.prefs.getFloat("play_speed",1));a.player.setRepeatOne(a.prefs.getInt("repeat_mode",0)==1&&a.prefs.getInt("skip_outro",0)==0);int index=episodeIndex();buttons.get("next-episode").setEnabled(a.activeLine!=null&&index>=0&&index<a.activeLine.episodes.size()-1);}
    void tick(){if(a.player==null||!a.prepared)return;int duration=a.player.getDuration(),position=a.player.getCurrentPosition();timeline.setMax(Math.max(1,duration));timeline.setProgress(position);int tail=a.prefs.getInt("skip_outro",0)*1000;if(!transitioning&&a.playing&&duration>0&&tail>0&&tail<duration&&position>=duration-tail){if(a.prefs.getInt("repeat_mode",0)==1)a.player.seekTo(a.prefs.getInt("skip_intro",0)*1000);else if(!step(1)){transitioning=true;a.player.pause();a.playing=false;a.playStatus.setText("已跳过片尾");a.showControls(true);}}}
    void completed(){if(!transitioning&&(a.prefs.getBoolean("auto_next",true)||a.prefs.getInt("repeat_mode",0)==2)&&step(1))return;a.showControls(true);a.playStatus.setText("播放结束 · 按确认重播");}
    void resize(int width,int height){videoWidth=width;videoHeight=height;if(a.playerChrome!=null)a.playerChrome.resolution(width,height);if(width<=0||height<=0||a.playbackLayer.getWidth()==0)return;int w=a.playbackLayer.getWidth(),h=a.playbackLayer.getHeight(),mode=a.prefs.getInt("aspect",0);float ratio=mode==2?16f/9:mode==3?4f/3:(float)width/height;if(mode!=1){if(mode==4){if((float)w/h>ratio)h=Math.round(w/ratio);else w=Math.round(h*ratio);}else if((float)w/h>ratio)w=Math.round(h*ratio);else h=Math.round(w/ratio);}surface.setLayoutParams(new FrameLayout.LayoutParams(w,h,Gravity.CENTER));}
    void visible(boolean visible){FrameLayout.LayoutParams lp=(FrameLayout.LayoutParams)subtitle.getLayoutParams();lp.bottomMargin=visible?a.dp(168):a.dp(24);subtitle.setLayoutParams(lp);}
}

