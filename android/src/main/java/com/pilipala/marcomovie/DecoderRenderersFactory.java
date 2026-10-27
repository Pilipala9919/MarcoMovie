package com.pilipala.marcomovie;

import android.content.Context;
import android.os.Handler;
import java.util.ArrayList;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.Renderer;
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector;
import androidx.media3.exoplayer.video.VideoRendererEventListener;

/** Keep audio extensions available even when hardware-only video is requested. */
final class DecoderRenderersFactory extends DefaultRenderersFactory {
    private final int mode;
    DecoderRenderersFactory(Context context,int decoderMode){
        super(context);DecoderSupport.configure();mode=decoderMode;
        setEnableDecoderFallback(true);
        setExtensionRendererMode((mode==2||mode==3||context.getSharedPreferences("movie",0).getBoolean("software_audio",false))?EXTENSION_RENDERER_MODE_PREFER:EXTENSION_RENDERER_MODE_ON);
    }
    @Override protected void buildVideoRenderers(Context context,int extensionMode,
        MediaCodecSelector selector,boolean fallback,Handler handler,
        VideoRendererEventListener listener,long joiningMs,ArrayList<Renderer> out){
        super.buildVideoRenderers(context,mode==1?EXTENSION_RENDERER_MODE_OFF:mode==2?EXTENSION_RENDERER_MODE_PREFER:EXTENSION_RENDERER_MODE_ON,
            selector,fallback,handler,listener,joiningMs,out);
    }
}
