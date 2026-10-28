package com.pilipala.marcomovie;

import android.graphics.Typeface;
import android.view.*;
import android.widget.*;

/** Keeps the existing video surface attached while browsing the episode list. */
final class MiniDetails {
    final MainActivity a;final LinearLayout page;final View hit;final PlaybackControls controls;
    MiniDetails(MainActivity host){
        a=host;controls=a.playbackControls;Cms.Video video=controls.video;Cms.Site site=controls.site;
        page=a.vertical();page.setTag("mini-details");page.setPadding(a.dp(40),a.dp(20),a.dp(40),a.dp(24));page.setBackgroundColor(MainActivity.DARK);
        a.addButton(page,a.navButton("‹ 返回","mini-back",a::onBackPressed));
        LinearLayout hero=a.row();hero.setGravity(Gravity.TOP);page.addView(hero,new LinearLayout.LayoutParams(-1,a.dp(218)));
        FrameLayout cover=new FrameLayout(a);cover.setTag("mini-cover");cover.setBackground(a.bg(0xff29292e,18));cover.setClipToOutline(true);TextView fallback=a.text("暂无封面",12,MainActivity.MUTED);fallback.setGravity(Gravity.CENTER);cover.addView(fallback,new FrameLayout.LayoutParams(-1,-1));ImageView poster=new ImageView(a);poster.setScaleType(ImageView.ScaleType.CENTER_CROP);cover.addView(poster,new FrameLayout.LayoutParams(-1,-1));a.poster(video.poster,poster);LinearLayout.LayoutParams coverSize=new LinearLayout.LayoutParams(a.dp(126),a.dp(189));coverSize.setMargins(0,a.dp(10),a.dp(20),0);hero.addView(cover,coverSize);
        LinearLayout copy=a.vertical();copy.setPadding(0,a.dp(12),a.dp(24),0);hero.addView(copy,new LinearLayout.LayoutParams(0,-2,1));TextView title=a.text(video.title,23,MainActivity.WHITE);title.setTypeface(null,Typeface.BOLD);title.setMaxLines(2);title.setEllipsize(android.text.TextUtils.TruncateAt.END);copy.addView(title);a.gap(copy,10);copy.addView(a.text(controls.resolved.name,13,MainActivity.MUTED));a.gap(copy,10);TextView summary=a.text(video.description,13,MainActivity.MUTED);summary.setMaxLines(3);summary.setEllipsize(android.text.TextUtils.TruncateAt.END);copy.addView(summary);
        Button favorite=a.button(Favorites.contains(a.prefs.getString("favorites","[]"),site.key,video.id)?"已收藏":"加入收藏","mini-favorite",()->{});favorite.setTextSize(13);favorite.setOnClickListener(v->{a.prefs.edit().putString("favorites",Favorites.toggle(a.prefs.getString("favorites","[]"),site.key,video)).apply();favorite.setText(Favorites.contains(a.prefs.getString("favorites","[]"),site.key,video.id)?"已收藏":"加入收藏");});a.addButton(copy,favorite);
        int width=Math.min(a.dp(340),a.root.getWidth()*38/100);hero.addView(new View(a),new LinearLayout.LayoutParams(width,1));
        ScrollView list=new ScrollView(a);list.setClipToPadding(true);LinearLayout episodes=a.vertical();list.addView(episodes);page.addView(list,new LinearLayout.LayoutParams(-1,0,1));
        if(!video.lines.isEmpty()){int line=Math.max(0,video.lines.indexOf(a.activeLine));int index=a.activeLine==null?0:Math.max(0,a.activeLine.episodes.indexOf(a.activeEpisode));a.renderEpisodes(site,video,line,index/50,episodes);}else episodes.addView(a.text("当前内容没有可选择的剧集。",15,MainActivity.MUTED));
        a.root.addView(page,0,new FrameLayout.LayoutParams(-1,-1));
        FrameLayout.LayoutParams size=new FrameLayout.LayoutParams(width,width*9/16,Gravity.TOP|Gravity.RIGHT);size.setMargins(0,a.dp(84),a.dp(40),0);a.playbackLayer.setLayoutParams(size);a.playbackLayer.setBackground(a.bg(0xff000000,18));a.playbackLayer.setClipToOutline(true);
        Button expand=a.button("","mini-expand",a::expandPlayback);expand.setBackground(a.bg(0x00000000,18));expand.setOnFocusChangeListener((v,f)->{android.graphics.drawable.GradientDrawable border=a.bg(0x00000000,18);if(f)border.setStroke(a.dp(2),MainActivity.WHITE);expand.setBackground(border);});a.playbackLayer.addView(expand,new FrameLayout.LayoutParams(-1,-1));hit=expand;
        TextView hint=a.text("确认返回全屏",12,MainActivity.WHITE);hint.setGravity(Gravity.CENTER);hint.setBackground(a.bg(0xaa16161b,0));FrameLayout.LayoutParams caption=new FrameLayout.LayoutParams(-1,a.dp(26),Gravity.BOTTOM);a.playbackLayer.addView(hint,caption);hint.setTag("mini-hint");
        a.playbackLayer.post(()->{if(a.miniMode){controls.resize(controls.videoWidth,controls.videoHeight);hit.requestFocus();}});
    }
    void remove(){a.root.removeView(page);a.playbackLayer.removeView(hit);View hint=a.playbackLayer.findViewWithTag("mini-hint");if(hint!=null)a.playbackLayer.removeView(hint);}
}
