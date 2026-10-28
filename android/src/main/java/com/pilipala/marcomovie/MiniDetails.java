package com.pilipala.marcomovie;

import android.graphics.Typeface;
import android.view.*;
import android.widget.*;

/** Keeps the existing video surface attached while browsing the episode list. */
final class MiniDetails {
    final MainActivity a;final FrameLayout page;final View hit;final PlaybackControls controls;
    MiniDetails(MainActivity host){
        a=host;controls=a.playbackControls;Cms.Video video=controls.video;Cms.Site site=controls.site;
        page=new FrameLayout(a);page.setTag("mini-details");page.setBackgroundColor(MainActivity.DARK);
        ImmersivePoster cover=new ImmersivePoster(a,"mini-cover");page.addView(cover.backdrop,new FrameLayout.LayoutParams(-1,-1));cover.load(video.poster);
        float height=a.getResources().getDisplayMetrics().heightPixels/a.getResources().getDisplayMetrics().density;
        int posterWidth=Math.round(Math.min(300,Math.max(224,(height-132)/1.5f)));
        FrameLayout.LayoutParams posterSize=new FrameLayout.LayoutParams(a.dp(posterWidth),a.dp(posterWidth*1.5f),Gravity.TOP|Gravity.LEFT);posterSize.leftMargin=a.dp(34);posterSize.topMargin=a.dp(54);page.addView(cover,posterSize);
        TextView back=a.navButton("‹ 返回","mini-back",a::onBackPressed);FrameLayout.LayoutParams backSize=new FrameLayout.LayoutParams(a.dp(82),a.dp(32));backSize.leftMargin=a.dp(34);backSize.topMargin=a.dp(14);page.addView(back,backSize);
        int left=a.dp(34+posterWidth+30),right=a.dp(40);int available=a.getResources().getDisplayMetrics().widthPixels-left-right;
        int width=Math.min(a.dp(360),available),videoTop=a.dp(108),videoHeight=width*9/16;
        LinearLayout copy=a.vertical();FrameLayout.LayoutParams copySize=new FrameLayout.LayoutParams(available,-2);copySize.leftMargin=left;copySize.topMargin=a.dp(38);page.addView(copy,copySize);
        TextView title=a.text(video.title,25,MainActivity.WHITE);title.setTypeface(null,Typeface.BOLD);title.setSingleLine();title.setEllipsize(android.text.TextUtils.TruncateAt.END);copy.addView(title);a.gap(copy,7);TextView episode=a.text(controls.resolved.name,13,MainActivity.MUTED);episode.setSingleLine();episode.setEllipsize(android.text.TextUtils.TruncateAt.END);copy.addView(episode);
        Button favorite=a.button(Favorites.contains(a.prefs.getString("favorites","[]"),site.key,video.id)?"已收藏":"加入收藏","mini-favorite",()->{});favorite.setTextSize(12);favorite.setOnClickListener(v->{a.prefs.edit().putString("favorites",Favorites.toggle(a.prefs.getString("favorites","[]"),site.key,video)).apply();favorite.setText(Favorites.contains(a.prefs.getString("favorites","[]"),site.key,video.id)?"已收藏":"加入收藏");});
        FrameLayout.LayoutParams favSize=new FrameLayout.LayoutParams(a.dp(106),a.dp(36));favSize.leftMargin=left+width+a.dp(14);favSize.topMargin=videoTop;boolean beside=available-width>=a.dp(124);if(beside)page.addView(favorite,favSize);
        ScrollView list=new ScrollView(a);list.setClipToPadding(true);LinearLayout episodes=a.vertical();list.addView(episodes);FrameLayout.LayoutParams listSize=new FrameLayout.LayoutParams(available,-1);listSize.leftMargin=left;listSize.topMargin=videoTop+videoHeight+a.dp(14);listSize.bottomMargin=a.dp(20);page.addView(list,listSize);
        if(!video.lines.isEmpty()){int line=Math.max(0,video.lines.indexOf(a.activeLine));int index=a.activeLine==null?0:Math.max(0,a.activeLine.episodes.indexOf(a.activeEpisode));a.renderEpisodes(site,video,line,index/50,episodes);}else episodes.addView(a.text("当前内容没有可选择的剧集。",15,MainActivity.MUTED));
        if(!beside)a.addButton(episodes,favorite);
        a.root.addView(page,0,new FrameLayout.LayoutParams(-1,-1));
        FrameLayout.LayoutParams size=new FrameLayout.LayoutParams(width,videoHeight,Gravity.TOP|Gravity.LEFT);size.leftMargin=left;size.topMargin=videoTop;a.playbackLayer.setLayoutParams(size);a.playbackLayer.setBackground(a.bg(0xff000000,18));a.playbackLayer.setClipToOutline(true);
        Button expand=a.button("","mini-expand",a::expandPlayback);expand.setBackground(a.bg(0x00000000,18));expand.setOnFocusChangeListener((v,f)->{FocusMotion.style(a,expand,f,0,0,18,MainActivity.WHITE,MainActivity.WHITE,true,1);});a.playbackLayer.addView(expand,new FrameLayout.LayoutParams(-1,-1));hit=expand;
        TextView hint=a.text("确认返回全屏",12,MainActivity.WHITE);hint.setGravity(Gravity.CENTER);hint.setBackground(a.bg(0xaa16161b,0));FrameLayout.LayoutParams caption=new FrameLayout.LayoutParams(-1,a.dp(26),Gravity.BOTTOM);a.playbackLayer.addView(hint,caption);hint.setTag("mini-hint");
        a.playbackLayer.post(()->{if(a.miniMode){controls.resize(controls.videoWidth,controls.videoHeight);hit.requestFocus();}});
    }
    void remove(){a.root.removeView(page);a.playbackLayer.removeView(hit);View hint=a.playbackLayer.findViewWithTag("mini-hint");if(hint!=null)a.playbackLayer.removeView(hint);}
}
