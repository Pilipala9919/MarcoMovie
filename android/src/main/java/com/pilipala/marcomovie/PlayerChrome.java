package com.pilipala.marcomovie;

import android.graphics.*;
import android.graphics.drawable.GradientDrawable;
import android.view.*;
import android.widget.*;

/** Three independent floating regions with one visibility/focus owner. */
final class PlayerChrome {
    final MainActivity a;
    final FrameLayout overlay;
    final LinearLayout dock,progress,heading;
    final StateGlyph state;

    PlayerChrome(MainActivity host,Cms.Video video,Cms.Episode episode){
        a=host;overlay=new FrameLayout(a);overlay.setTag("player-chrome");overlay.setClipChildren(false);
        View topShade=new View(a);topShade.setBackground(new GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM,new int[]{0xa8000000,0x00000000}));
        overlay.addView(topShade,new FrameLayout.LayoutParams(-1,a.dp(160),Gravity.TOP));
        View bottomShade=new View(a);bottomShade.setBackground(new GradientDrawable(GradientDrawable.Orientation.BOTTOM_TOP,new int[]{0xb8000000,0x00000000}));
        overlay.addView(bottomShade,new FrameLayout.LayoutParams(-1,a.dp(210),Gravity.BOTTOM));
        heading=a.vertical();heading.setTag("player-heading");
        TextView title=a.text(video.title,26,MainActivity.WHITE);title.setTypeface(null,Typeface.BOLD);title.setSingleLine();title.setEllipsize(android.text.TextUtils.TruncateAt.END);title.setShadowLayer(a.dp(6),0,a.dp(2),0x99000000);heading.addView(title);
        String line=a.activeLine==null?"":a.activeLine.name;
        TextView episodeLabel=a.text(episode.name+(line.isEmpty()?"":"  ·  "+line),14,0xffdddddf);episodeLabel.setTag("player-episode");episodeLabel.setSingleLine();episodeLabel.setEllipsize(android.text.TextUtils.TruncateAt.END);episodeLabel.setPadding(0,a.dp(6),0,0);heading.addView(episodeLabel);
        a.playStatus=a.text("正在连接所选剧集…",12,MainActivity.MUTED);a.playStatus.setPadding(0,a.dp(6),0,0);heading.addView(a.playStatus);
        FrameLayout.LayoutParams top=new FrameLayout.LayoutParams(-1,-2,Gravity.TOP);top.setMargins(a.dp(44),a.dp(30),a.dp(44),0);overlay.addView(heading,top);

        progress=a.vertical();progress.setTag("player-progress");
        a.playClock=a.text("--:-- / --:--",12,MainActivity.WHITE);a.playClock.setGravity(Gravity.RIGHT);a.playClock.setPadding(0,0,a.dp(12),0);progress.addView(a.playClock);
        int width=a.getResources().getDisplayMetrics().widthPixels;
        FrameLayout.LayoutParams track=new FrameLayout.LayoutParams(Math.min(a.dp(760),width-a.dp(88)),-2,Gravity.BOTTOM|Gravity.CENTER_HORIZONTAL);track.bottomMargin=a.dp(106);overlay.addView(progress,track);

        dock=a.vertical();dock.setTag("player-dock");dock.setPadding(a.dp(10),a.dp(5),a.dp(10),a.dp(5));dock.setClipChildren(false);
        GradientDrawable glass=a.bg(0xed262629,30);glass.setStroke(a.dp(1),0x30ffffff);dock.setBackground(glass);dock.setElevation(a.dp(10));
        FrameLayout.LayoutParams bottom=new FrameLayout.LayoutParams(Math.min(a.dp(552),width-a.dp(64)),-2,Gravity.BOTTOM|Gravity.CENTER_HORIZONTAL);bottom.bottomMargin=a.dp(28);overlay.addView(dock,bottom);

        state=new StateGlyph();state.setTag("player-state");state.setFocusable(false);state.setOnClickListener(v->{a.togglePlayback();a.showControls(true);});
        overlay.addView(state,new FrameLayout.LayoutParams(a.dp(72),a.dp(72),Gravity.CENTER));
        a.root.addView(overlay,new FrameLayout.LayoutParams(-1,-1));a.playerOverlay=overlay;a.controlsVisible=true;
    }
    void update(){state.setContentDescription(!a.prepared?"正在准备":a.playing?"正在播放，确认暂停":"已暂停，确认继续");state.invalidate();}
    final class StateGlyph extends View {
        final Paint paint=new Paint(3);
        StateGlyph(){super(a);}
        @Override protected void onDraw(Canvas canvas){
            float cx=getWidth()/2f,cy=getHeight()/2f;paint.setColor(0x99303034);canvas.drawCircle(cx,cy,getWidth()/2f,paint);paint.setColor(MainActivity.WHITE);
            if(!a.prepared){paint.setStrokeWidth(a.dp(3));paint.setStyle(Paint.Style.STROKE);canvas.drawCircle(cx,cy,a.dp(12),paint);paint.setStyle(Paint.Style.FILL);return;}
            if(a.playing){canvas.drawRoundRect(cx-a.dp(10),cy-a.dp(13),cx-a.dp(3),cy+a.dp(13),a.dp(2),a.dp(2),paint);canvas.drawRoundRect(cx+a.dp(3),cy-a.dp(13),cx+a.dp(10),cy+a.dp(13),a.dp(2),a.dp(2),paint);}
            else{Path p=new Path();p.moveTo(cx-a.dp(8),cy-a.dp(14));p.lineTo(cx+a.dp(15),cy);p.lineTo(cx-a.dp(8),cy+a.dp(14));p.close();paint.setStrokeJoin(Paint.Join.ROUND);paint.setStrokeWidth(a.dp(3));paint.setStyle(Paint.Style.FILL_AND_STROKE);canvas.drawPath(p,paint);paint.setStyle(Paint.Style.FILL);}
        }
    }
}
