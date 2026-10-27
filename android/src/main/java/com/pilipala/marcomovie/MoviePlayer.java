package com.pilipala.marcomovie;

import android.content.Context;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.view.Surface;
import androidx.media3.common.C;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.VideoSize;
import androidx.media3.common.util.Util;
import androidx.media3.datasource.DefaultDataSource;
import androidx.media3.datasource.DefaultHttpDataSource;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;

/** Small Media3 adapter for the app's existing TV controls. All player access is
 * marshalled to the main looper, including reads made by device instrumentation. */
public class MoviePlayer {
    public interface OnPreparedListener {void onPrepared(MoviePlayer player);}
    public interface OnCompletionListener {void onCompletion(MoviePlayer player);}
    public interface OnVideoSizeChangedListener {void onVideoSizeChanged(MoviePlayer player,int width,int height);}
    public interface OnErrorListener {boolean onError(MoviePlayer player,int what,int extra);}
    private final Handler main=new Handler(Looper.getMainLooper());
    private final Context context;
    private ExoPlayer exo;
    private Uri uri;
    private Map<String,String> headers=Collections.emptyMap();
    private OnPreparedListener preparedListener;
    private OnCompletionListener completionListener;
    private OnVideoSizeChangedListener sizeListener;
    private OnErrorListener errorListener;
    private boolean readySent,unsupportedVideo;
    private volatile boolean released;
    private int preparation;
    private String lastError="";
    private String videoDecoder="",audioDecoder="";private int lastHttpStatus,lastErrorTrack;
    private org.json.JSONObject options=new org.json.JSONObject();
    private DefaultMediaSourceFactory mediaSourceFactory;
    private String mediaMime;
    public interface SubtitleListener {void text(CharSequence text);}
    private SubtitleListener subtitleListener;
    public interface CueListener {void cues(androidx.media3.common.text.CueGroup group);}
    private CueListener cueListener;

    public MoviePlayer(Context context) {this(context,true,-1);}
    public MoviePlayer(Context context,int decoderMode){this(context,true,decoderMode);}
    protected MoviePlayer(Context context,boolean initializeExo){this(context,initializeExo,-1);}
    private MoviePlayer(Context context,boolean initializeExo,int requestedDecoder) {
        this.context=context.getApplicationContext();
        if(!initializeExo)return;
        onMain(()->{
            int decoderMode=requestedDecoder<0?this.context.getSharedPreferences("movie",0).getInt("decoder_mode",0):requestedDecoder;
            DefaultRenderersFactory renderers=new DecoderRenderersFactory(this.context,decoderMode);
            if(decoderMode!=0&&decoderMode!=3)renderers.setMediaCodecSelector((mime,secure,tunneling)->{
                java.util.List<androidx.media3.exoplayer.mediacodec.MediaCodecInfo> selected=new java.util.ArrayList<>();
                for(androidx.media3.exoplayer.mediacodec.MediaCodecInfo codec:androidx.media3.exoplayer.mediacodec.MediaCodecUtil.getDecoderInfos(mime,secure,tunneling))
                    if(!mime.startsWith("video/")||(decoderMode==2?codec.softwareOnly:codec.hardwareAccelerated))selected.add(codec);
                return selected;
            });
            int buffer=Math.max(15,Math.min(50,this.context.getSharedPreferences("movie",0).getInt("buffer_seconds",30)))*1000;
            exo=new ExoPlayer.Builder(this.context,renderers).setLoadControl(new androidx.media3.exoplayer.DefaultLoadControl.Builder().setBufferDurationsMs(buffer,buffer,1500,3000).setTargetBufferBytes(32*1024*1024).build()).setLooper(Looper.getMainLooper()).build();
            if(this.context.getSharedPreferences("movie",0).getBoolean("prefer_aac",false))exo.setTrackSelectionParameters(exo.getTrackSelectionParameters().buildUpon().setPreferredAudioMimeTypes(MimeTypes.AUDIO_AAC).build());
            exo.addAnalyticsListener(new androidx.media3.exoplayer.analytics.AnalyticsListener(){
                @Override public void onVideoDecoderInitialized(EventTime time,String name,long completed,long duration){videoDecoder=name;}
                @Override public void onAudioDecoderInitialized(EventTime time,String name,long completed,long duration){audioDecoder=name;}
            });
            exo.addListener(new Player.Listener(){
                @Override public void onPlaybackStateChanged(int state){
                    if(released)return;
                    if(state==Player.STATE_READY&&!readySent&&!unsupportedVideo){readySent=true;if(preparedListener!=null)preparedListener.onPrepared(MoviePlayer.this);}
                    else if(state==Player.STATE_ENDED&&completionListener!=null)completionListener.onCompletion(MoviePlayer.this);
                }
                @Override public void onTracksChanged(androidx.media3.common.Tracks tracks){
                    boolean video=false,supported=false;
                    for(androidx.media3.common.Tracks.Group group:tracks.getGroups())if(group.getType()==C.TRACK_TYPE_VIDEO){video=true;supported|=group.isSupported();}
                    if(video&&!supported&&!unsupportedVideo){unsupportedVideo=true;lastError="ERROR_CODE_DECODING_FORMAT_UNSUPPORTED";lastErrorTrack=C.TRACK_TYPE_VIDEO;exo.pause();if(errorListener!=null)errorListener.onError(MoviePlayer.this,PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,0);}
                }
                @Override public void onVideoSizeChanged(VideoSize size){
                    if(!released&&sizeListener!=null)sizeListener.onVideoSizeChanged(MoviePlayer.this,Math.round(size.width*size.pixelWidthHeightRatio),size.height);
                }
                @Override public void onPlayerError(PlaybackException error){
                    if(released)return;
                    lastError=error.getErrorCodeName();lastErrorTrack=error instanceof androidx.media3.exoplayer.ExoPlaybackException?(((androidx.media3.exoplayer.ExoPlaybackException)error).rendererFormat==null?C.TRACK_TYPE_UNKNOWN:MimeTypes.getTrackType(((androidx.media3.exoplayer.ExoPlaybackException)error).rendererFormat.sampleMimeType)):C.TRACK_TYPE_UNKNOWN;
                    lastHttpStatus=0;for(Throwable cause=error;cause!=null;cause=cause.getCause())if(cause instanceof androidx.media3.datasource.HttpDataSource.InvalidResponseCodeException){lastHttpStatus=((androidx.media3.datasource.HttpDataSource.InvalidResponseCodeException)cause).responseCode;break;}
                    if(errorListener!=null)errorListener.onError(MoviePlayer.this,error.errorCode,0);
                }
                @Override public void onCues(androidx.media3.common.text.CueGroup group){
                    if(cueListener!=null)cueListener.cues(group);
                    if(subtitleListener!=null){StringBuilder text=new StringBuilder();for(androidx.media3.common.text.Cue cue:group.cues)if(cue.text!=null){if(text.length()>0)text.append('\n');text.append(cue.text);}subtitleListener.text(text);}
                }
            });
            return null;
        });
    }

    public void setAudioAttributes(android.media.AudioAttributes attributes){onMain(()->{check();exo.setAudioAttributes(new androidx.media3.common.AudioAttributes.Builder().setUsage(attributes.getUsage()).setContentType(attributes.getContentType()).build(),true);return null;});}
    public void setDataSource(Context unused,Uri uri,Map<String,String> headers){onMain(()->{check();this.uri=uri;this.headers=Collections.unmodifiableMap(new LinkedHashMap<>(headers));return null;});}
    public void setSurface(Surface surface){onMain(()->{check();exo.setVideoSurface(surface);return null;});}
    public void setOnPreparedListener(OnPreparedListener listener){onMain(()->{preparedListener=listener;return null;});}
    public void setOnCompletionListener(OnCompletionListener listener){onMain(()->{completionListener=listener;return null;});}
    public void setOnVideoSizeChangedListener(OnVideoSizeChangedListener listener){onMain(()->{sizeListener=listener;return null;});}
    public void setOnErrorListener(OnErrorListener listener){onMain(()->{errorListener=listener;return null;});}
    public void setOptions(org.json.JSONObject metadata){onMain(()->{options=new org.json.JSONObject(metadata.toString());return null;});}

    public void prepareAsync(){onMain(()->{
        check();if(uri==null)throw new IllegalStateException("No media item");
        final int ticket=++preparation;final Uri address=uri;final Map<String,String> requestHeaders=headers;readySent=false;
        // Local proxy and signed URLs often have no extension. Inspect a bounded
        // response prefix off the UI thread so HLS/DASH uses the correct parser.
        Thread sniff=new Thread(()->{
            String declared=MediaOptions.mime(options);String mime=declared==null?sniffMime(address,requestHeaders):declared;
            main.post(()->{
                if(released||ticket!=preparation)return;
                try{
                    String userAgent="MarcoMovie/0.2.0";for(Map.Entry<String,String> header:requestHeaders.entrySet())if(header.getKey().equalsIgnoreCase("User-Agent"))userAgent=header.getValue();
                    DefaultHttpDataSource.Factory http=new DefaultHttpDataSource.Factory().setUserAgent(userAgent)
                        .setDefaultRequestProperties(requestHeaders).setAllowCrossProtocolRedirects(true).setConnectTimeoutMs(12000).setReadTimeoutMs(25000);
                    DefaultDataSource.Factory data=new DefaultDataSource.Factory(context,http);
                    mediaMime=mime;mediaSourceFactory=new DefaultMediaSourceFactory(data);
                    exo.setMediaSource(mediaSourceFactory.createMediaSource(mediaItem(address)));exo.prepare();
                }catch(Exception error){lastError=error.getClass().getSimpleName();if(errorListener!=null)errorListener.onError(MoviePlayer.this,PlaybackException.ERROR_CODE_UNSPECIFIED,0);}
            });
        },"media-type-probe");sniff.setDaemon(true);sniff.start();return null;
    });}

    private static String sniffMime(Uri address,Map<String,String> requestHeaders){
        int type=Util.inferContentType(address);
        if(type==C.CONTENT_TYPE_HLS)return MimeTypes.APPLICATION_M3U8;
        if(type==C.CONTENT_TYPE_DASH)return MimeTypes.APPLICATION_MPD;
        String path=address.getPath();if(path!=null&&path.toLowerCase(Locale.ROOT).matches(".*\\.(mp4|mkv|webm|mp3|aac|flac|ogg|ts|flv|mov)$"))return null;
        String scheme=address.getScheme();if(!"http".equalsIgnoreCase(scheme)&&!"https".equalsIgnoreCase(scheme))return null;
        HttpURLConnection connection=null;
        try{
            connection=(HttpURLConnection)new URL(address.toString()).openConnection();connection.setConnectTimeout(8000);connection.setReadTimeout(8000);connection.setInstanceFollowRedirects(true);
            connection.setRequestProperty("User-Agent","MarcoMovie/0.2.0");for(Map.Entry<String,String> header:requestHeaders.entrySet())connection.setRequestProperty(header.getKey(),header.getValue());
            String contentType=connection.getContentType();if(contentType!=null){String lower=contentType.toLowerCase(Locale.ROOT);if(lower.contains("mpegurl"))return MimeTypes.APPLICATION_M3U8;if(lower.contains("dash+xml"))return MimeTypes.APPLICATION_MPD;if(lower.startsWith("video/")||lower.startsWith("audio/"))return null;}
            byte[] prefix=new byte[1024];int count=0;
            try(InputStream stream=connection.getInputStream()){while(count<prefix.length){int n=stream.read(prefix,count,prefix.length-count);if(n<0)break;count+=n;String partial=new String(prefix,0,count,"UTF-8").trim();if(partial.startsWith("\ufeff"))partial=partial.substring(1).trim();if(partial.startsWith("#EXTM3U"))return MimeTypes.APPLICATION_M3U8;if(partial.contains("<MPD"))return MimeTypes.APPLICATION_MPD;if(count>=16&&!partial.startsWith("<")&&!partial.startsWith("#"))return null;}}
            String start=new String(prefix,0,count,"UTF-8").trim();if(start.startsWith("\ufeff"))start=start.substring(1).trim();
            if(start.startsWith("#EXTM3U"))return MimeTypes.APPLICATION_M3U8;if(start.contains("<MPD"))return MimeTypes.APPLICATION_MPD;
        }catch(Exception ignored){/* The real loader reports transport failures. */}finally{if(connection!=null)connection.disconnect();}
        return null;
    }

    public void start(){onMain(()->{check();exo.play();return null;});}
    public void pause(){onMain(()->{if(!released)exo.pause();return null;});}
    public void seekTo(int ms){onMain(()->{check();exo.seekTo(Math.max(0,ms));return null;});}
    public boolean isPlaying(){return onMain(()->!released&&exo.isPlaying());}
    public int getCurrentPosition(){return onMain(()->released?0:milliseconds(exo.getCurrentPosition()));}
    public int getDuration(){return onMain(()->released?0:milliseconds(exo.getDuration()));}
    public int getVideoWidth(){return onMain(()->released?0:Math.round(exo.getVideoSize().width*exo.getVideoSize().pixelWidthHeightRatio));}
    public int getVideoHeight(){return onMain(()->released?0:exo.getVideoSize().height);}
    public String getLastError(){return onMain(()->lastError);}
    public int softFallbackMode(){return onMain(()->lastErrorTrack==C.TRACK_TYPE_AUDIO?3:2);}
    public String getFailureMessage(int code){return onMain(()->PlaybackFailure.message(code,lastHttpStatus));}
    public org.json.JSONObject decoderDiagnostics(){return onMain(()->{
        org.json.JSONObject info=new org.json.JSONObject().put("video_decoder",videoDecoder).put("audio_decoder",audioDecoder);
        if(released)return info;
        androidx.media3.common.Format vf=exo.getVideoFormat(),af=exo.getAudioFormat();
        if(vf!=null)info.put("video_mime",vf.sampleMimeType).put("width",vf.width).put("height",vf.height);
        if(af!=null)info.put("audio_mime",af.sampleMimeType).put("channels",af.channelCount);
        androidx.media3.exoplayer.DecoderCounters vc=exo.getVideoDecoderCounters(),ac=exo.getAudioDecoderCounters();
        if(vc!=null){vc.ensureUpdated();info.put("video_rendered",vc.renderedOutputBufferCount).put("video_dropped",vc.droppedBufferCount);}
        if(ac!=null){ac.ensureUpdated();info.put("audio_rendered",ac.renderedOutputBufferCount);}
        return info;
    });}
    public String playbackInfo(){org.json.JSONObject d=decoderDiagnostics();return "Media3\n视频："+d.optString("video_mime","尚未识别")+" · "+d.optString("video_decoder","尚未启动")+"\n音频："+d.optString("audio_mime","尚未识别")+" · "+d.optString("audio_decoder","尚未启动")+"\n"+d.optInt("width")+" × "+d.optInt("height")+(getLastError().isEmpty()?"":"\n"+getLastError());}
    public int getAudioSessionId(){return onMain(()->released?0:exo.getAudioSessionId());}
    public void setCuesListener(CueListener listener){onMain(()->{cueListener=listener;return null;});}
    private MediaItem mediaItem(Uri address)throws Exception{
        MediaItem.Builder item=new MediaItem.Builder().setUri(address);if(mediaMime!=null)item.setMimeType(mediaMime);
        java.util.List<MediaItem.SubtitleConfiguration> tracks=new java.util.ArrayList<>();org.json.JSONArray subtitles=options.optJSONArray("subtitles");
        if(subtitles!=null)for(int i=0;i<subtitles.length();i++){
            org.json.JSONObject sub=subtitles.optJSONObject(i);if(sub==null||sub.optString("url").isEmpty())continue;
            tracks.add(new MediaItem.SubtitleConfiguration.Builder(Uri.parse(sub.optString("url"))).setMimeType(MediaOptions.subtitleMime(sub.optString("url"),sub.optString("mimeType"))).setLabel(sub.optString("name","外挂字幕")).setLanguage(sub.optString("language","zh")).setSelectionFlags(i==0?C.SELECTION_FLAG_DEFAULT:0).build());
        }
        item.setSubtitleConfigurations(tracks);
        org.json.JSONObject drm=options.optJSONObject("drm");String scheme=drm==null?options.optString("drmScheme"):drm.optString("scheme",drm.optString("type"));String license=drm==null?options.optString("drmLicenseUrl"):drm.optString("licenseUrl",drm.optString("licenseUri"));
        if(!scheme.isEmpty()){
            java.util.UUID uuid=Util.getDrmUuid(scheme);if(uuid==null||!Cms.isHttp(license))throw new IllegalArgumentException("来源缺少有效DRM许可配置");
            java.util.Map<String,String> licenseHeaders=new LinkedHashMap<>();if(drm!=null&&drm.optJSONObject("headers")!=null)MediaOptions.headers(licenseHeaders,drm.optJSONObject("headers"));
            item.setDrmConfiguration(new MediaItem.DrmConfiguration.Builder(uuid).setLicenseUri(license).setLicenseRequestHeaders(licenseHeaders).build());
        }
        return item.build();
    }
    public void addExternalSubtitle(Uri subtitle,String name,String mime){onMain(()->{
        check();if(mediaSourceFactory==null)throw new IllegalStateException("请等待视频开始播放");
        org.json.JSONArray tracks=options.optJSONArray("subtitles");if(tracks==null){tracks=new org.json.JSONArray();options.put("subtitles",tracks);}tracks.put(new org.json.JSONObject().put("url",subtitle.toString()).put("name",name).put("mimeType",mime));
        long position=exo.getCurrentPosition();boolean play=exo.getPlayWhenReady();exo.setMediaSource(mediaSourceFactory.createMediaSource(mediaItem(uri)),position);exo.prepare();exo.setPlayWhenReady(play);return null;
    });}
    public void setSubtitleListener(SubtitleListener listener){onMain(()->{subtitleListener=listener;return null;});}
    public void setSpeed(float speed){onMain(()->{check();exo.setPlaybackSpeed(speed);return null;});}
    public float getSpeed(){return onMain(()->exo.getPlaybackParameters().speed);}
    public void setRepeatOne(boolean repeat){onMain(()->{check();exo.setRepeatMode(repeat?Player.REPEAT_MODE_ONE:Player.REPEAT_MODE_OFF);return null;});}
    public java.util.List<String> trackLabels(int type){return onMain(()->{java.util.List<String> out=new java.util.ArrayList<>();for(androidx.media3.common.Tracks.Group group:exo.getCurrentTracks().getGroups())if(group.getType()==type)for(int i=0;i<group.length;i++)if(group.isTrackSupported(i)){androidx.media3.common.Format f=group.getTrackFormat(i);String label=f.label!=null?f.label:f.language!=null?f.language:"轨道 "+(out.size()+1);if(f.channelCount>0)label+=" · "+f.channelCount+" 声道";out.add((group.isTrackSelected(i)?"✓ ":"")+label);}return out;});}
    public void selectTrack(int type,int index){onMain(()->{check();androidx.media3.common.TrackSelectionParameters.Builder p=exo.getTrackSelectionParameters().buildUpon().clearOverridesOfType(type).setTrackTypeDisabled(type,index==-2);if(index>=0){int count=0;for(androidx.media3.common.Tracks.Group group:exo.getCurrentTracks().getGroups())if(group.getType()==type)for(int i=0;i<group.length;i++)if(group.isTrackSupported(i)&&count++==index)p.addOverride(new androidx.media3.common.TrackSelectionOverride(group.getMediaTrackGroup(),i));}exo.setTrackSelectionParameters(p.build());return null;});}
    public void release(){onMain(()->{if(!released){released=true;preparation++;exo.release();}return null;});}
    private static int milliseconds(long value){return value==C.TIME_UNSET||value<0?0:(int)Math.min(Integer.MAX_VALUE,value);}
    private void check(){if(released)throw new IllegalStateException("Player released");}
    private <T>T onMain(Callable<T> work){
        if(Looper.myLooper()==Looper.getMainLooper())try{return work.call();}catch(RuntimeException e){throw e;}catch(Exception e){throw new IllegalStateException(e);}
        FutureTask<T> task=new FutureTask<>(work);if(!main.post(task))throw new IllegalStateException("Main looper unavailable");
        try{return task.get(15,TimeUnit.SECONDS);}catch(InterruptedException e){Thread.currentThread().interrupt();throw new IllegalStateException("Player call interrupted",e);}catch(ExecutionException e){Throwable cause=e.getCause();if(cause instanceof RuntimeException)throw (RuntimeException)cause;throw new IllegalStateException(cause);}catch(java.util.concurrent.TimeoutException e){task.cancel(false);throw new IllegalStateException("Player UI thread timed out",e);}
    }
}
