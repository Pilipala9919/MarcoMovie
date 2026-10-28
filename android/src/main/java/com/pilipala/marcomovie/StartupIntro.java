package com.pilipala.marcomovie;

import android.content.res.AssetFileDescriptor;
import android.graphics.Color;
import android.graphics.SurfaceTexture;
import android.media.MediaPlayer;
import android.view.*;
import android.widget.*;

/** Local, silent launch overlay. Loading and focus underneath continue normally. */
final class StartupIntro extends FrameLayout implements TextureView.SurfaceTextureListener {
    final MainActivity a;final TextureView video;MediaPlayer media;Surface surface;
    boolean closing,released,rendered;final Runnable timeout=()->finish(false);
    static void show(MainActivity a){if(a.reduced||!a.prefs.getBoolean("startup_animation",true)||a.startupIntro!=null)return;StartupIntro intro=new StartupIntro(a);a.startupIntro=intro;((FrameLayout)a.findViewById(android.R.id.content)).addView(intro,new FrameLayout.LayoutParams(-1,-1));intro.postDelayed(intro.timeout,5000);}
    StartupIntro(MainActivity a){super(a);this.a=a;setTag("startup-intro");setBackgroundColor(Color.BLACK);setClickable(true);setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS);
        video=new TextureView(a);video.setOpaque(true);video.setAlpha(0);video.setSurfaceTextureListener(this);addView(video,new FrameLayout.LayoutParams(-1,-1,Gravity.CENTER));setOnClickListener(v->finish(true));
    }
    @Override protected void onSizeChanged(int w,int h,int ow,int oh){super.onSizeChanged(w,h,ow,oh);if(w<=0||h<=0)return;int width=w,height=Math.round(w*9f/16);if(height>h){height=h;width=Math.round(h*16f/9);}FrameLayout.LayoutParams p=new FrameLayout.LayoutParams(width,height,Gravity.CENTER);video.setLayoutParams(p);}
    @Override public void onSurfaceTextureAvailable(SurfaceTexture texture,int w,int h){if(closing)return;try{
        surface=new Surface(texture);media=new MediaPlayer();media.setSurface(surface);media.setVolume(0,0);media.setLooping(false);
        media.setOnPreparedListener(p->{if(!closing)p.start();});
        media.setOnInfoListener((p,what,extra)->{if(what==MediaPlayer.MEDIA_INFO_VIDEO_RENDERING_START&&!closing){rendered=true;video.setAlpha(1);}return false;});
        media.setOnCompletionListener(p->finish(true));media.setOnErrorListener((p,what,extra)->{finish(false);return true;});
        try(AssetFileDescriptor asset=a.getAssets().openFd("branding/startup.mp4")){media.setDataSource(asset.getFileDescriptor(),asset.getStartOffset(),asset.getLength());}media.prepareAsync();
    }catch(Exception e){finish(false);}}
    void release(){if(released)return;released=true;if(media!=null){media.setOnPreparedListener(null);media.setOnCompletionListener(null);media.setOnErrorListener(null);media.setOnInfoListener(null);media.release();media=null;}if(surface!=null){surface.release();surface=null;}}
    void finish(boolean fade){if(closing)return;closing=true;removeCallbacks(timeout);if(fade&&isAttachedToWindow()&&!a.reduced){animate().alpha(0).setDuration(260).withEndAction(this::remove).start();}else remove();}
    void remove(){animate().cancel();release();if(getParent() instanceof android.view.ViewGroup)((android.view.ViewGroup)getParent()).removeView(this);if(a.startupIntro==this)a.startupIntro=null;}
    void cancel(){closing=true;removeCallbacks(timeout);remove();}
    @Override protected void onDetachedFromWindow(){removeCallbacks(timeout);animate().cancel();release();super.onDetachedFromWindow();}
    @Override public boolean onSurfaceTextureDestroyed(SurfaceTexture texture){release();return true;}
    @Override public void onSurfaceTextureSizeChanged(SurfaceTexture texture,int w,int h){}
    @Override public void onSurfaceTextureUpdated(SurfaceTexture texture){}
}
