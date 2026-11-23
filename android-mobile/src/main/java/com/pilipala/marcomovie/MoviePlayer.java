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
import androidx.media3.datasource.okhttp.OkHttpDataSource;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory;
import okhttp3.ConnectionPool;
import okhttp3.OkHttpClient;
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
    public interface OnPreparedListener {
        void onPrepared(MoviePlayer player);
    }

    public interface OnCompletionListener {
        void onCompletion(MoviePlayer player);
    }

    /** Optional TV marker observer, not a command or a seek request acknowledgement. */
    interface OnSeekPositionListener {
        void position(MoviePlayer player, long actualPosition);
    }

    private OnSeekPositionListener seekPositionListener;

    void setOnSeekPositionListener(OnSeekPositionListener listener) {
        onMain(
                () -> {
                    seekPositionListener = listener;
                    return null;
                });
    }

    protected final void observeSeekPosition(long actualPosition) {
        if (seekPositionListener != null) seekPositionListener.position(this, actualPosition);
    }

    public interface OnVideoSizeChangedListener {
        void onVideoSizeChanged(MoviePlayer player, int width, int height);
    }

    public interface OnErrorListener {
        boolean onError(MoviePlayer player, int what, int extra);
    }

    public interface OnTextTracksChangedListener {
        void onTextTracksChanged();
    }

    public interface OnAudioTracksChangedListener {
        void onAudioTracksChanged();
    }

    private OnTextTracksChangedListener textTracksChangedListener;
    private OnAudioTracksChangedListener audioTracksChangedListener;

    public void setOnTextTracksChangedListener(OnTextTracksChangedListener listener) {
        onMain(
                () -> {
                    textTracksChangedListener = listener;
                    return null;
                });
    }

    public void setOnAudioTracksChangedListener(OnAudioTracksChangedListener listener) {
        onMain(
                () -> {
                    audioTracksChangedListener = listener;
                    return null;
                });
    }

    private static volatile String sDefaultUserAgent = null;
    private static volatile OkHttpClient sharedMediaHttp;

    static OkHttpClient mediaHttpClient() {
        OkHttpClient existing = sharedMediaHttp;
        if (existing != null) return existing;
        synchronized (MoviePlayer.class) {
            if (sharedMediaHttp == null) {
                sharedMediaHttp =
                        new OkHttpClient.Builder()
                                .connectTimeout(15, TimeUnit.SECONDS)
                                .readTimeout(30, TimeUnit.SECONDS)
                                .followRedirects(true)
                                .followSslRedirects(true)
                                .retryOnConnectionFailure(true)
                                .connectionPool(new ConnectionPool(8, 5, TimeUnit.MINUTES))
                                .build();
            }
            return sharedMediaHttp;
        }
    }

    static int safeBufferBytes(long maxHeapBytes) {
        long minBytes = 48L * 1024L * 1024L;
        long maxBytes = 256L * 1024L * 1024L;
        long scaled = (maxHeapBytes * 45L) / 100L;
        return (int) Math.max(minBytes, Math.min(maxBytes, scaled));
    }

    static boolean isPlatformSoftwareDecoder(String decoderName) {
        if (decoderName == null || decoderName.isEmpty()) return false;
        String lower = decoderName.toLowerCase(Locale.ROOT);
        return lower.startsWith("c2.android.")
                || lower.startsWith("omx.google.")
                || lower.contains("ffmpeg")
                || lower.contains("libvpx")
                || lower.contains("dav1d");
    }

    static String defaultUserAgent(Context context) {
        if (sDefaultUserAgent != null) return sDefaultUserAgent;
        String version = null;
        if (context != null) {
            try {
                version =
                        context.getPackageManager()
                                .getPackageInfo(context.getPackageName(), 0)
                                .versionName;
            } catch (Exception ignored) {
            }
        }
        if (version == null || version.isEmpty() || "未知".equals(version)) {
            version = "0.5.22";
        }
        sDefaultUserAgent = "MarcoMovie/" + version;
        return sDefaultUserAgent;
    }

    private final Handler main = new Handler(Looper.getMainLooper());
    private final Context context;
    private ExoPlayer exo;
    private Uri uri;
    private Map<String, String> headers = Collections.emptyMap();
    private OnPreparedListener preparedListener;
    private OnCompletionListener completionListener;
    private OnVideoSizeChangedListener sizeListener;
    private OnErrorListener errorListener;
    private OnHdrChangedListener hdrChangedListener;
    private volatile boolean readySent;
    private boolean unsupportedVideo, hdrVideo, unsupportedDvProfile5;
    private volatile boolean released;
    private int preparation;
    private volatile RequestScope probeScope;
    private long prepareStarted, firstFrameMs = -1;
    private String lastError = "";
    private String videoDecoder = "", audioDecoder = "";
    private int lastHttpStatus, lastErrorTrack;
    private org.json.JSONObject options = new org.json.JSONObject();
    private DefaultMediaSourceFactory mediaSourceFactory;
    private androidx.media3.datasource.DataSource.Factory subtitleDataSourceFactory;
    private final boolean televisionSubtitles;
    private String mediaMime;
    private boolean hlsFallbackAttempted;
    private final boolean ijkMode;

    public interface OnHdrChangedListener {
        void onHdrChanged(boolean hdr);
    }

    public interface SubtitleListener {
        void text(CharSequence text);
    }

    private SubtitleListener subtitleListener;

    public interface CueListener {
        void cues(androidx.media3.common.text.CueGroup group);
    }

    private CueListener cueListener;

    public static MoviePlayer createIjk(Context context) {
        return new MoviePlayer(context, true, -1, true);
    }

    public MoviePlayer(Context context) {
        this(context, true, -1, false);
    }

    public MoviePlayer(Context context, int decoderMode) {
        this(context, true, decoderMode, false);
    }

    public MoviePlayer(Context context, int decoderMode, boolean forceIjk) {
        this(context, true, decoderMode, forceIjk);
    }

    protected MoviePlayer(Context context, boolean initializeExo) {
        this(context, initializeExo, -1, false);
    }

    private MoviePlayer(
            Context context, boolean initializeExo, int requestedDecoder, boolean forceIjk) {
        this.context = context.getApplicationContext();
        televisionSubtitles =
                context instanceof MainActivity && ((MainActivity) context).isTvDevice();
        this.ijkMode = forceIjk;
        if (!initializeExo) return;
        onMain(
                () -> {
                    int userDecoder =
                            this.context
                                    .getSharedPreferences(Prefs.FILE, 0)
                                    .getInt(Prefs.DECODER_MODE, 0);
                    int decoderMode =
                            requestedDecoder >= 0
                                    ? requestedDecoder
                                    : (this.ijkMode && userDecoder == 0 ? 3 : userDecoder);
                    DefaultRenderersFactory renderers =
                            new DecoderRenderersFactory(this.context, decoderMode);
                    renderers.setMediaCodecSelector(
                            (mime, secure, tunneling) -> {
                                java.util.List<androidx.media3.exoplayer.mediacodec.MediaCodecInfo>
                                        raw =
                                                new java.util.ArrayList<>(
                                                        androidx.media3.exoplayer.mediacodec
                                                                .MediaCodecUtil.getDecoderInfos(
                                                                mime, secure, tunneling));
                                if (MimeTypes.AUDIO_E_AC3_JOC.equals(mime)) {
                                    for (androidx.media3.exoplayer.mediacodec.MediaCodecInfo eac3 :
                                            androidx.media3.exoplayer.mediacodec.MediaCodecUtil
                                                    .getDecoderInfos(
                                                            MimeTypes.AUDIO_E_AC3,
                                                            secure,
                                                            tunneling)) {
                                        boolean exists = false;
                                        for (androidx.media3.exoplayer.mediacodec.MediaCodecInfo c :
                                                raw) {
                                            if (c.name.equals(eac3.name)) {
                                                exists = true;
                                                break;
                                            }
                                        }
                                        if (!exists) raw.add(eac3);
                                    }
                                }
                                if (mime.startsWith("video/") && decoderMode != 2) {
                                    raw = DecoderRenderersFactory.prioritizeHardwareDecoders(raw);
                                }
                                if (decoderMode == 0 || decoderMode == 3) return raw;
                                java.util.List<androidx.media3.exoplayer.mediacodec.MediaCodecInfo>
                                        selected = new java.util.ArrayList<>();
                                for (androidx.media3.exoplayer.mediacodec.MediaCodecInfo codec :
                                        raw)
                                    if (!mime.startsWith("video/")
                                            || (decoderMode == 2
                                                    ? DecoderRenderersFactory.isSoftwareCodec(codec)
                                                    : (!DecoderRenderersFactory.isSoftwareCodec(
                                                                    codec)
                                                            && codec.hardwareAccelerated)))
                                        selected.add(codec);
                                return selected.isEmpty() ? raw : selected;
                            });
                    int userBufferSec =
                            this.context
                                    .getSharedPreferences(Prefs.FILE, 0)
                                    .getInt(Prefs.BUFFER_SECONDS, 30);
                    int memoryClassMb = 256;
                    boolean lowRamDevice = false;
                    try {
                        android.app.ActivityManager am =
                                (android.app.ActivityManager)
                                        this.context.getSystemService(Context.ACTIVITY_SERVICE);
                        if (am != null) {
                            memoryClassMb = am.getMemoryClass();
                            lowRamDevice =
                                    android.os.Build.VERSION.SDK_INT >= 19 && am.isLowRamDevice();
                        }
                    } catch (Throwable ignored) {
                    }
                    LoadControlProfile loadProfile =
                            resolveLoadControlProfile(
                                    memoryClassMb, lowRamDevice, userBufferSec, this.ijkMode);
                    exo =
                            new ExoPlayer.Builder(this.context, renderers)
                                    .setVideoChangeFrameRateStrategy(
                                            C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_OFF)
                                    .setLoadControl(
                                            new androidx.media3.exoplayer.DefaultLoadControl
                                                            .Builder()
                                                    .setBufferDurationsMs(
                                                            loadProfile.minBufferMs,
                                                            loadProfile.maxBufferMs,
                                                            loadProfile.startBufferMs,
                                                            loadProfile.rebufferMs)
                                                    .setPrioritizeTimeOverSizeThresholds(
                                                            loadProfile.prioritizeTimeOverSize)
                                                    .setTargetBufferBytes(
                                                            loadProfile.targetBufferBytes)
                                                    .build())
                                    .setLooper(Looper.getMainLooper())
                                    .build();
                    androidx.media3.exoplayer.trackselection.DefaultTrackSelector.Parameters.Builder
                            trackParams =
                                    new androidx.media3.exoplayer.trackselection
                                                    .DefaultTrackSelector.Parameters.Builder(
                                                    this.context)
                                            .setExceedRendererCapabilitiesIfNecessary(true)
                                            .setExceedVideoConstraintsIfNecessary(true)
                                            .setExceedAudioConstraintsIfNecessary(true)
                                            .setPreferredTextLanguages(
                                                    "zh-Hans", "zh-CN", "zh", "zho", "chi",
                                                    "zh-Hant", "zh-TW");
                    android.content.SharedPreferences sp =
                            this.context.getSharedPreferences(Prefs.FILE, 0);
                    int audioPrefMode = sp.getInt(Prefs.AUDIO_TRACK_PREFERENCE, 0);
                    if (audioPrefMode == SubtitlePreferenceStore.AUDIO_PREF_CHINESE) {
                        trackParams.setPreferredAudioLanguages(
                                "zh-Hans", "zh-CN", "zh", "zho", "chi", "cmn");
                    }
                    if (sp.getBoolean(Prefs.PREFER_AAC, false))
                        trackParams.setPreferredAudioMimeTypes(MimeTypes.AUDIO_AAC);
                    if (!this.ijkMode && sp.getBoolean(Prefs.TUNNELED_PLAYBACK, false))
                        trackParams.setTunnelingEnabled(true);
                    exo.setTrackSelectionParameters(trackParams.build());
                    exo.addAnalyticsListener(
                            new androidx.media3.exoplayer.analytics.AnalyticsListener() {
                                @Override
                                public void onVideoDecoderInitialized(
                                        EventTime time,
                                        String name,
                                        long completed,
                                        long duration) {
                                    videoDecoder = name;
                                }

                                @Override
                                public void onAudioDecoderInitialized(
                                        EventTime time,
                                        String name,
                                        long completed,
                                        long duration) {
                                    audioDecoder = name;
                                }

                                @Override
                                public void onRenderedFirstFrame(
                                        EventTime time, Object output, long renderTimeMs) {
                                    firstFrameMs =
                                            android.os.SystemClock.elapsedRealtime()
                                                    - prepareStarted;
                                }
                            });
                    exo.addListener(
                            new Player.Listener() {
                                @Override
                                public void onPositionDiscontinuity(
                                        Player.PositionInfo oldPosition,
                                        Player.PositionInfo newPosition,
                                        int reason) {
                                    if (!released
                                            && (reason == Player.DISCONTINUITY_REASON_SEEK
                                                    || reason
                                                            == Player
                                                                    .DISCONTINUITY_REASON_SEEK_ADJUSTMENT))
                                        observeSeekPosition(newPosition.positionMs);
                                }

                                @Override
                                public void onPlaybackStateChanged(int state) {
                                    if (released) return;
                                    if (state == Player.STATE_READY
                                            && !readySent
                                            && !unsupportedVideo) {
                                        readySent = true;
                                        if (preparedListener != null)
                                            preparedListener.onPrepared(MoviePlayer.this);
                                    } else if (state == Player.STATE_ENDED
                                            && completionListener != null)
                                        completionListener.onCompletion(MoviePlayer.this);
                                }

                                @Override
                                public void onTracksChanged(androidx.media3.common.Tracks tracks) {
                                    boolean video = false,
                                            supported = false,
                                            hasText = false,
                                            hasAudio = false;
                                    boolean detectedHdr = false, detectedDvP5 = false;
                                    for (androidx.media3.common.Tracks.Group group :
                                            tracks.getGroups())
                                        if (group.getType() == C.TRACK_TYPE_TEXT
                                                && group.length > 0) {
                                            hasText = true;
                                        } else if (group.getType() == C.TRACK_TYPE_AUDIO
                                                && group.length > 0) {
                                            hasAudio = true;
                                        } else if (group.getType() == C.TRACK_TYPE_VIDEO) {
                                            video = true;
                                            supported |=
                                                    group.isSupported(true) || group.isSelected();
                                            for (int i = 0; i < group.length; i++) {
                                                androidx.media3.common.Format f =
                                                        group.getTrackFormat(i);
                                                if (DecoderRenderersFactory.isDolbyVisionProfile5(
                                                        f)) {
                                                    detectedDvP5 = true;
                                                }
                                                if (group.isTrackSelected(i)
                                                        && (androidx.media3.common.ColorInfo
                                                                        .isTransferHdr(f.colorInfo)
                                                                || MimeTypes.VIDEO_DOLBY_VISION
                                                                        .equals(
                                                                                f.sampleMimeType))) {
                                                    detectedHdr = true;
                                                }
                                            }
                                        }
                                    if (hasText && textTracksChangedListener != null) {
                                        textTracksChangedListener.onTextTracksChanged();
                                    }
                                    if (hasAudio && audioTracksChangedListener != null) {
                                        audioTracksChangedListener.onAudioTracksChanged();
                                    }
                                    if (hdrVideo != detectedHdr) {
                                        hdrVideo = detectedHdr;
                                        if (hdrChangedListener != null) {
                                            hdrChangedListener.onHdrChanged(hdrVideo);
                                        }
                                    }
                                    if (video && !supported && !unsupportedVideo) {
                                        unsupportedVideo = true;
                                        unsupportedDvProfile5 = detectedDvP5;
                                        lastError = "ERROR_CODE_DECODING_FORMAT_UNSUPPORTED";
                                        lastErrorTrack = C.TRACK_TYPE_VIDEO;
                                        exo.pause();
                                        if (errorListener != null)
                                            errorListener.onError(
                                                    MoviePlayer.this,
                                                    PlaybackException
                                                            .ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
                                                    0);
                                    }
                                }

                                @Override
                                public void onVideoSizeChanged(VideoSize size) {
                                    if (!released && sizeListener != null)
                                        sizeListener.onVideoSizeChanged(
                                                MoviePlayer.this,
                                                Math.round(size.width * size.pixelWidthHeightRatio),
                                                size.height);
                                }

                                @Override
                                public void onPlayerError(PlaybackException error) {
                                    if (released) return;
                                    if (!hlsFallbackAttempted
                                            && uri != null
                                            && mediaSourceFactory != null) {
                                        String scheme = uri.getScheme();
                                        if ("http".equalsIgnoreCase(scheme)
                                                || "https".equalsIgnoreCase(scheme)) {
                                            String epName =
                                                    options != null
                                                            ? options.optString("_episodeName", "")
                                                            : "";
                                            if ((error.errorCode
                                                                    == PlaybackException
                                                                            .ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED
                                                            || error.errorCode
                                                                    == PlaybackException
                                                                            .ERROR_CODE_PARSING_CONTAINER_MALFORMED)
                                                    && shouldRetryAsHlsFallback(
                                                            mediaMime, epName, uri)) {
                                                hlsFallbackAttempted = true;
                                                mediaMime = MimeTypes.APPLICATION_M3U8;
                                                try {
                                                    exo.setMediaSource(playbackSource(uri));
                                                    exo.prepare();
                                                    return;
                                                } catch (Exception ignored) {
                                                }
                                            } else if ((ijkMode
                                                            || options.optBoolean("live", false))
                                                    && MimeTypes.APPLICATION_M3U8.equalsIgnoreCase(
                                                            mediaMime)
                                                    && (error.errorCode
                                                                    == PlaybackException
                                                                            .ERROR_CODE_PARSING_MANIFEST_MALFORMED
                                                            || error.errorCode
                                                                    == PlaybackException
                                                                            .ERROR_CODE_PARSING_CONTAINER_MALFORMED)) {
                                                hlsFallbackAttempted = true;
                                                mediaMime = null;
                                                try {
                                                    exo.setMediaSource(playbackSource(uri));
                                                    exo.prepare();
                                                    return;
                                                } catch (Exception ignored) {
                                                }
                                            }
                                        }
                                    }
                                    lastError = error.getErrorCodeName();
                                    lastErrorTrack =
                                            error
                                                            instanceof
                                                            androidx.media3.exoplayer
                                                                    .ExoPlaybackException
                                                    ? (((androidx.media3.exoplayer
                                                                                            .ExoPlaybackException)
                                                                                    error)
                                                                            .rendererFormat
                                                                    == null
                                                            ? C.TRACK_TYPE_UNKNOWN
                                                            : MimeTypes.getTrackType(
                                                                    ((androidx.media3.exoplayer
                                                                                            .ExoPlaybackException)
                                                                                    error)
                                                                            .rendererFormat
                                                                            .sampleMimeType))
                                                    : C.TRACK_TYPE_UNKNOWN;
                                    lastHttpStatus = 0;
                                    for (Throwable cause = error;
                                            cause != null;
                                            cause = cause.getCause())
                                        if (cause
                                                instanceof
                                                androidx.media3.datasource.HttpDataSource
                                                        .InvalidResponseCodeException) {
                                            lastHttpStatus =
                                                    ((androidx.media3.datasource.HttpDataSource
                                                                            .InvalidResponseCodeException)
                                                                    cause)
                                                            .responseCode;
                                            break;
                                        }
                                    if (errorListener != null)
                                        errorListener.onError(MoviePlayer.this, error.errorCode, 0);
                                }

                                @Override
                                public void onCues(androidx.media3.common.text.CueGroup group) {
                                    if (cueListener != null) cueListener.cues(group);
                                    if (subtitleListener != null) {
                                        StringBuilder text = new StringBuilder();
                                        for (androidx.media3.common.text.Cue cue : group.cues)
                                            if (cue.text != null) {
                                                if (text.length() > 0) text.append('\n');
                                                text.append(cue.text);
                                            }
                                        subtitleListener.text(text);
                                    }
                                }
                            });
                    return null;
                });
    }

    public void configureDefaultAudio() {
        if (android.os.Build.VERSION.SDK_INT >= 21) {
            setAudioAttributes(
                    new android.media.AudioAttributes.Builder()
                            .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                            .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MOVIE)
                            .build());
        }
    }

    void bindSubtitles(final SubtitleOverlayView view, final SubtitleListener textCallback) {
        setCuesListener(
                group -> {
                    if (view != null) {
                        view.setCues(group.cues);
                    }
                    if (textCallback != null) {
                        textCallback.text(
                                group.cues.isEmpty() ? "" : String.valueOf(group.cues.get(0).text));
                    }
                });
    }

    public void setAudioAttributes(android.media.AudioAttributes attributes) {
        onMain(
                () -> {
                    check();
                    exo.setAudioAttributes(
                            new androidx.media3.common.AudioAttributes.Builder()
                                    .setUsage(attributes.getUsage())
                                    .setContentType(attributes.getContentType())
                                    .build(),
                            true);
                    return null;
                });
    }

    public void setDataSource(Context unused, Uri uri, Map<String, String> headers) {
        onMain(
                () -> {
                    check();
                    this.uri = uri;
                    this.headers = Collections.unmodifiableMap(new LinkedHashMap<>(headers));
                    return null;
                });
    }

    public void setSurface(Surface surface) {
        onMain(
                () -> {
                    check();
                    exo.setVideoSurface(surface);
                    return null;
                });
    }

    public void setSurfaceSize(int width, int height) {}

    public void setOnPreparedListener(OnPreparedListener listener) {
        onMain(
                () -> {
                    preparedListener = listener;
                    return null;
                });
    }

    public void setOnCompletionListener(OnCompletionListener listener) {
        onMain(
                () -> {
                    completionListener = listener;
                    return null;
                });
    }

    public void setOnVideoSizeChangedListener(OnVideoSizeChangedListener listener) {
        onMain(
                () -> {
                    sizeListener = listener;
                    return null;
                });
    }

    public void setOnErrorListener(OnErrorListener listener) {
        onMain(
                () -> {
                    errorListener = listener;
                    return null;
                });
    }

    public void setOnHdrChangedListener(OnHdrChangedListener listener) {
        if (exo == null) return;
        onMain(
                () -> {
                    hdrChangedListener = listener;
                    if (listener != null && hdrVideo) {
                        listener.onHdrChanged(true);
                    }
                    return null;
                });
    }

    public boolean isHdrVideo() {
        if (exo == null) return false;
        return onMain(
                () -> {
                    if (released) return false;
                    if (hdrVideo) return true;
                    androidx.media3.common.Format vf = exo.getVideoFormat();
                    return vf != null
                            && (androidx.media3.common.ColorInfo.isTransferHdr(vf.colorInfo)
                                    || MimeTypes.VIDEO_DOLBY_VISION.equals(vf.sampleMimeType));
                });
    }

    public boolean isUnsupportedDolbyVisionProfile5() {
        if (exo == null) return false;
        return onMain(() -> unsupportedDvProfile5);
    }

    public String activeVideoMimeType() {
        if (exo == null) return "";
        return onMain(
                () -> {
                    if (released) return "";
                    androidx.media3.common.Format vf = exo.getVideoFormat();
                    return vf != null && vf.sampleMimeType != null ? vf.sampleMimeType : "";
                });
    }

    private static final java.util.regex.Pattern DV_WORD_PATTERN =
            java.util.regex.Pattern.compile("(?i)(?:^|[^a-z0-9])dv(?:$|[^a-z0-9])");
    private static final java.util.regex.Pattern HDR_WORD_PATTERN =
            java.util.regex.Pattern.compile("(?i)(?:^|[^a-z0-9])hdr(?:$|[^a-z0-9])");

    /**
     * Detects when a pure Dolby Vision (typically Netflix Profile 5 IPT-PQ-C2) netdisk source is
     * being played via an H.264 cloud-transcoded fallback stream, which commonly bakes green/purple
     * color distortion into the transcoded frames because server-side transcoders omit Profile 5
     * IPT reshaping. Hybrid DV+HDR10 streams carry an HDR10 base layer and are excluded.
     */
    static boolean looksLikeTranscodedDolbyVisionColorRisk(
            String episodeName, String lineName, String actualVideoMime) {
        if (actualVideoMime == null || actualVideoMime.isEmpty()) return false;
        String mimeLower = actualVideoMime.toLowerCase(Locale.ROOT);
        if (!mimeLower.contains("avc") && !mimeLower.contains("h264")) return false;
        String meta =
                ((episodeName == null ? "" : episodeName)
                                + " "
                                + (lineName == null ? "" : lineName))
                        .toLowerCase(Locale.ROOT)
                        .trim();
        if (meta.isEmpty()) return false;
        boolean mentionsDv =
                meta.contains("杜比视界")
                        || meta.contains("dolby vision")
                        || meta.contains("dolby.vision")
                        || meta.contains("dovi")
                        || DV_WORD_PATTERN.matcher(meta).find();
        if (!mentionsDv) return false;
        boolean mentionsHdrBase =
                meta.contains("hdr10")
                        || meta.contains("hdr+")
                        || meta.contains("dv.hdr")
                        || meta.contains("dv+hdr")
                        || meta.contains("hdr.dv")
                        || meta.contains("hdr+dv")
                        || HDR_WORD_PATTERN.matcher(meta).find();
        return !mentionsHdrBase;
    }

    public void setOptions(org.json.JSONObject metadata) {
        onMain(
                () -> {
                    options = new org.json.JSONObject(metadata.toString());
                    return null;
                });
    }

    static final int PROBE_BUDGET_MS = MediaContentProbe.BUDGET_MS;
    static final int PROBE_MAX_BYTES = MediaContentProbe.MAX_BYTES;

    private static Map<String, String> sanitizeHeadersForAddress(
            Uri address, Map<String, String> sourceHeaders) {
        Map<String, String> out = new LinkedHashMap<>(sourceHeaders);
        if (address != null && ProxyAddress.isLoopbackHost(address.getHost())) {
            for (java.util.Iterator<Map.Entry<String, String>> it = out.entrySet().iterator();
                    it.hasNext(); ) {
                Map.Entry<String, String> e = it.next();
                String k = e.getKey();
                if ("Origin".equalsIgnoreCase(k)) {
                    String v = e.getValue();
                    it.remove();
                    if (v != null && !v.isEmpty()) out.put("X-Movie-Origin", v);
                    break;
                }
            }
            for (java.util.Iterator<Map.Entry<String, String>> it = out.entrySet().iterator();
                    it.hasNext(); ) {
                Map.Entry<String, String> e = it.next();
                String k = e.getKey();
                if ("Host".equalsIgnoreCase(k)) {
                    String v = e.getValue();
                    it.remove();
                    if (v != null && !v.isEmpty()) out.put("X-Movie-Host", v);
                    break;
                }
            }
        }
        return out;
    }

    public void prepareAsync() {
        onMain(
                () -> {
                    check();
                    if (uri == null) throw new IllegalStateException("No media item");
                    final int ticket = ++preparation;
                    RequestScope previousScope = probeScope;
                    if (previousScope != null) previousScope.cancel();
                    final RequestScope scope = new RequestScope();
                    probeScope = scope;
                    final Uri address = uri;
                    final Map<String, String> requestHeaders =
                            sanitizeHeadersForAddress(address, headers);
                    final String epName =
                            options.optString("_episodeName", "").toLowerCase(Locale.ROOT);
                    final boolean isLive = options.optBoolean("live", false);
                    readySent = false;
                    hlsFallbackAttempted = false;
                    maxKnownDurationMs = 0;
                    prepareStarted = android.os.SystemClock.elapsedRealtime();
                    firstFrameMs = -1;

                    String declared = MediaOptions.mime(options);
                    String fullLower = address.toString().toLowerCase(Locale.ROOT);
                    // Query tokens and display names are not container signatures.
                    int uriType = Util.inferContentType(address);
                    boolean explicitHls = uriType == C.CONTENT_TYPE_HLS;
                    boolean explicitDash = uriType == C.CONTENT_TYPE_DASH;
                    boolean disguised = MediaContentProbe.disguisedPath(address.getPath());
                    boolean knownContainer =
                            !explicitHls
                                    && !explicitDash
                                    && !detectKnownContainer(epName, address).isEmpty();
                    boolean cloudOrLocalProxy =
                            !isLive
                                    && !explicitHls
                                    && !explicitDash
                                    && isCloudDriveOrLocalProxyContainer(address, fullLower);
                    if (!disguised
                            && (isLive
                                    || declared != null
                                    || explicitHls
                                    || explicitDash
                                    || knownContainer
                                    || cloudOrLocalProxy)) {
                        String fastMime =
                                declared != null
                                        ? declared
                                        : explicitHls
                                                ? MimeTypes.APPLICATION_M3U8
                                                : explicitDash ? MimeTypes.APPLICATION_MPD : null;
                        startExoPrepare(address, requestHeaders, scope, fastMime, ticket);
                        return null;
                    }

                    // Ambiguous extensionless HTTP URLs: inspect a bounded response prefix off the
                    // UI thread so HLS/DASH uses the right parser without blocking main looper.
                    Thread sniff =
                            new Thread(
                                    () -> {
                                        String mime = null;
                                        try {
                                            mime =
                                                    scope.call(
                                                            () ->
                                                                    sniffMime(
                                                                            context,
                                                                            address,
                                                                            requestHeaders,
                                                                            scope));
                                        } catch (Exception ignored) {
                                        }
                                        if (scope.cancelled) return;
                                        final String resolvedMime = mime != null ? mime : declared;
                                        main.post(
                                                () ->
                                                        startExoPrepare(
                                                                address,
                                                                requestHeaders,
                                                                scope,
                                                                resolvedMime,
                                                                ticket));
                                    },
                                    "media-type-probe");
                    sniff.setDaemon(true);
                    sniff.start();
                    return null;
                });
    }

    private void startExoPrepare(
            Uri address,
            Map<String, String> requestHeaders,
            RequestScope scope,
            String resolvedMime,
            int ticket) {
        if (released || (scope != null && scope.cancelled) || ticket != preparation) return;
        try {
            String userAgent =
                    options.optBoolean("live", false) ? Cms.USER_AGENT : defaultUserAgent(context);
            for (Map.Entry<String, String> header : requestHeaders.entrySet())
                if (header.getKey().equalsIgnoreCase("User-Agent")) userAgent = header.getValue();
            OkHttpClient client =
                    ijkMode
                            ? mediaHttpClient()
                                    .newBuilder()
                                    .connectTimeout(20, TimeUnit.SECONDS)
                                    .readTimeout(45, TimeUnit.SECONDS)
                                    .build()
                            : mediaHttpClient();
            OkHttpDataSource.Factory http =
                    new OkHttpDataSource.Factory(client)
                            .setUserAgent(userAgent)
                            .setDefaultRequestProperties(requestHeaders);
            StartupState startupState = () -> readySent;
            DefaultDataSource.Factory data =
                    new DefaultDataSource.Factory(
                            context, new ChunkedProxyDataSource.Factory(http, startupState));
            mediaMime = resolvedMime;
            androidx.media3.extractor.DefaultExtractorsFactory extractors =
                    new androidx.media3.extractor.DefaultExtractorsFactory()
                            .setConstantBitrateSeekingEnabled(true)
                            .setTsExtractorTimestampSearchBytes((ijkMode ? 3600 : 1500) * 188);
            if (ijkMode) {
                extractors.setTsExtractorFlags(
                        androidx.media3.extractor.ts.DefaultTsPayloadReaderFactory
                                        .FLAG_ALLOW_NON_IDR_KEYFRAMES
                                | androidx.media3.extractor.ts.DefaultTsPayloadReaderFactory
                                        .FLAG_DETECT_ACCESS_UNITS
                                | androidx.media3.extractor.ts.DefaultTsPayloadReaderFactory
                                        .FLAG_ENABLE_HDMV_DTS_AUDIO_STREAMS
                                | androidx.media3.extractor.ts.DefaultTsPayloadReaderFactory
                                        .FLAG_IGNORE_SPLICE_INFO_STREAM);
            }
            mediaSourceFactory =
                    new DefaultMediaSourceFactory(data, wrapDisguisedMp3Extractors(extractors))
                            .setLoadErrorHandlingPolicy(
                                    new ResilientLoadErrorPolicy(
                                            options.optBoolean("live", false), startupState));
            subtitleDataSourceFactory = data;
            boolean forceHighest =
                    options.optBoolean("live", false)
                            && options.optBoolean("livePreferHighQuality", true);
            exo.setTrackSelectionParameters(
                    exo.getTrackSelectionParameters()
                            .buildUpon()
                            .setForceHighestSupportedBitrate(forceHighest)
                            .build());
            exo.setMediaSource(playbackSource(address));
            exo.prepare();
        } catch (Exception error) {
            lastError = error.getClass().getSimpleName();
            if (errorListener != null)
                errorListener.onError(
                        MoviePlayer.this, PlaybackException.ERROR_CODE_UNSPECIFIED, 0);
        }
    }

    static boolean shouldRetryAsHlsFallback(String mediaMime, String episodeName, Uri address) {
        if (address == null) return false;
        return shouldRetryAsHlsFallback(
                mediaMime,
                episodeName,
                address.getScheme(),
                address.getHost(),
                address.getPath(),
                address.getQuery(),
                address.toString());
    }

    static boolean shouldRetryAsHlsFallback(
            String mediaMime,
            String episodeName,
            String scheme,
            String host,
            String path,
            String query,
            String fullUrl) {
        if (mediaMime != null && !mediaMime.isEmpty()) return false;
        if (!"http".equalsIgnoreCase(scheme) && !"https".equalsIgnoreCase(scheme)) return false;
        String fullLower = fullUrl == null ? "" : fullUrl.toLowerCase(Locale.ROOT);
        if (fullLower.contains("m3u8") || fullLower.contains("hls")) return true;
        if (!matchContainerToken(episodeName, CONTAINER_EXT_PATTERN).isEmpty()
                || !matchContainerToken(path, CONTAINER_EXT_PATTERN).isEmpty()
                || !matchContainerToken(query, QUERY_CONTAINER_EXT_PATTERN).isEmpty()) {
            return false;
        }
        String hostLower = host == null ? "" : host.toLowerCase(Locale.ROOT);
        if (isCloudDriveOrLocalProxyHost(hostLower, fullLower)) return false;
        return true;
    }

    static boolean isCloudDriveOrLocalProxyContainer(Uri address, String fullLower) {
        if (fullLower == null || fullLower.isEmpty()) return false;
        if (fullLower.contains("m3u8") || fullLower.contains(".mpd")) return false;
        String host =
                address == null || address.getHost() == null
                        ? ""
                        : address.getHost().toLowerCase(Locale.ROOT);
        return isCloudDriveOrLocalProxyHost(host, fullLower);
    }

    private static boolean isCloudDriveOrLocalProxyHost(String host, String fullLower) {
        if (fullLower == null || fullLower.isEmpty()) return false;
        if (fullLower.contains("m3u8") || fullLower.contains(".mpd")) return false;
        if (("127.0.0.1".equals(host) || "localhost".equals(host))
                && fullLower.contains("/proxy")) {
            return true;
        }
        return host.contains("quark.cn")
                || host.contains("uc.cn")
                || host.contains("aliyundrive")
                || host.contains("alipan")
                || host.contains("baidupcs")
                || host.contains("pcs.baidu")
                || host.contains("115.com")
                || host.contains("115cdn")
                || host.contains("123pan")
                || host.contains("189.cn")
                || host.contains("139.com")
                || host.contains("xunlei");
    }

    static androidx.media3.extractor.ExtractorsFactory wrapDisguisedMp3Extractors(
            final androidx.media3.extractor.DefaultExtractorsFactory base) {
        return new androidx.media3.extractor.ExtractorsFactory() {
            @Override
            public androidx.media3.extractor.Extractor[] createExtractors() {
                return reorderDisguisedMp3Extractors(base.createExtractors());
            }

            @Override
            public androidx.media3.extractor.Extractor[] createExtractors(
                    Uri uri, Map<String, java.util.List<String>> responseHeaders) {
                return reorderDisguisedMp3Extractors(base.createExtractors(uri, responseHeaders));
            }
        };
    }

    /**
     * Netdisk shares frequently rename MP4/MKV/FLV video files to {@code .mp3} to evade content
     * filters (#31). When Media3 places {@code Mp3Extractor} at index 0 based on the {@code .mp3}
     * suffix or {@code audio/mpeg} header, its permissive sync-word scan can false-match H.264/HEVC
     * bitstreams and drop the video track. Moving strict magic-byte video container extractors
     * ahead of {@code Mp3Extractor} lets real video containers match at byte 0 while genuine MP3
     * audio files fall through to {@code Mp3Extractor} immediately.
     */
    static androidx.media3.extractor.Extractor[] reorderDisguisedMp3Extractors(
            androidx.media3.extractor.Extractor[] list) {
        if (list == null || list.length <= 1) return list;
        if (!list[0].getClass().getSimpleName().contains("Mp3")) return list;
        java.util.List<androidx.media3.extractor.Extractor> strictVideo =
                new java.util.ArrayList<androidx.media3.extractor.Extractor>(6);
        java.util.List<androidx.media3.extractor.Extractor> rest =
                new java.util.ArrayList<androidx.media3.extractor.Extractor>(list.length);
        for (int i = 0; i < list.length; i++) {
            androidx.media3.extractor.Extractor ex = list[i];
            String name = ex.getClass().getSimpleName();
            if (name.contains("Mp4")
                    || name.contains("Matroska")
                    || name.contains("Mkv")
                    || name.contains("Flv")
                    || name.contains("Avi")) {
                strictVideo.add(ex);
            } else {
                rest.add(ex);
            }
        }
        if (strictVideo.isEmpty()) return list;
        androidx.media3.extractor.Extractor[] out =
                new androidx.media3.extractor.Extractor[list.length];
        int idx = 0;
        for (int i = 0; i < strictVideo.size(); i++) out[idx++] = strictVideo.get(i);
        for (int i = 0; i < rest.size(); i++) out[idx++] = rest.get(i);
        return out;
    }

    private static String sniffMime(
            Context context, Uri address, Map<String, String> requestHeaders, RequestScope scope) {
        if (scope != null && scope.cancelled) return null;
        try {
            Map<String, String> probeHeaders = new LinkedHashMap<>(requestHeaders);
            if (ProxyAddress.isLoopbackHost(address.getHost()))
                probeHeaders.put(ChunkedProxyDataSource.HEADER_CHUNKED_CLIENT, "1");
            return MediaContentProbe.probe(
                    new URL(address.toString()), probeHeaders, defaultUserAgent(context), scope);
        } catch (Exception ignored) {
            return null;
        }
    }

    public void start() {
        onMain(
                () -> {
                    check();
                    exo.play();
                    return null;
                });
    }

    public void pause() {
        onMain(
                () -> {
                    if (!released && exo != null) exo.pause();
                    return null;
                });
    }

    public void seekTo(int ms) {
        onMain(
                () -> {
                    check();
                    exo.seekTo(Math.max(0, ms));
                    return null;
                });
    }

    public boolean isPlaying() {
        return onMain(() -> !released && exo != null && exo.isPlaying());
    }

    public int getCurrentPosition() {
        return onMain(() -> released || exo == null ? 0 : milliseconds(exo.getCurrentPosition()));
    }

    private int maxKnownDurationMs = 0;

    public int getDuration() {
        return onMain(
                () -> {
                    if (released || exo == null) return 0;
                    long raw = exo.getDuration();
                    if (raw == C.TIME_UNSET || raw <= 0) {
                        raw = exo.getContentDuration();
                    }
                    int ms = milliseconds(raw);
                    if (ms > maxKnownDurationMs) {
                        maxKnownDurationMs = ms;
                    }
                    return ms > 0 ? ms : maxKnownDurationMs;
                });
    }

    public int getVideoWidth() {
        return onMain(
                () ->
                        released || exo == null
                                ? 0
                                : Math.round(
                                        exo.getVideoSize().width
                                                * exo.getVideoSize().pixelWidthHeightRatio));
    }

    private static String shortVideoCodec(String mime) {
        if (mime == null) return "";
        String m = mime.toLowerCase(Locale.ROOT);
        if (m.contains("dolby-vision") || m.contains("dvhe") || m.contains("dvh1")) return "杜比视界";
        if (m.contains("hevc") || m.contains("h265")) return "HEVC";
        if (m.contains("avc") || m.contains("h264")) return "H.264";
        if (m.contains("av01") || m.contains("av1")) return "AV1";
        if (m.contains("vp9")) return "VP9";
        if (m.contains("mp4v")) return "MPEG4";
        return "";
    }

    private static String shortAudioCodec(String mime) {
        if (mime == null) return "";
        String m = mime.toLowerCase(Locale.ROOT);
        if (m.contains("eac3")) return "EAC3";
        if (m.contains("ac3")) return "AC3";
        if (m.contains("truehd")) return "TrueHD";
        if (m.contains("dts")) return "DTS";
        if (m.contains("flac")) return "FLAC";
        if (m.contains("opus")) return "Opus";
        if (m.contains("mp4a") || m.contains("aac")) return "AAC";
        if (m.contains("mpeg") || m.contains("mp3")) return "MP3";
        return "";
    }

    private static final java.util.regex.Pattern CONTAINER_EXT_PATTERN =
            java.util.regex.Pattern.compile(
                    "(?i)\\.(mkv|mp4|m4v|webm|avi|mov|flv|ts|m2ts)(?:$|[^a-z0-9])");

    private static final java.util.regex.Pattern QUERY_CONTAINER_EXT_PATTERN =
            java.util.regex.Pattern.compile(
                    "(?i)\\.(mkv|mp4|m4v|webm|avi|mov|flv|m2ts)(?:$|[^a-z0-9])");

    static String detectKnownContainer(String epName, Uri address) {
        String candidate = matchContainerToken(epName, CONTAINER_EXT_PATTERN);
        if (!candidate.isEmpty()) return candidate;
        if (address != null) {
            candidate = matchContainerToken(address.getPath(), CONTAINER_EXT_PATTERN);
            if (!candidate.isEmpty()) return candidate;
            candidate = matchContainerToken(address.getQuery(), QUERY_CONTAINER_EXT_PATTERN);
            if (!candidate.isEmpty()) return candidate;
        }
        return "";
    }

    private static String matchContainerToken(String input, java.util.regex.Pattern pattern) {
        if (input == null || input.isEmpty()) return "";
        java.util.regex.Matcher m = pattern.matcher(input);
        if (!m.find()) return "";
        String ext = m.group(1).toLowerCase(Locale.ROOT);
        switch (ext) {
            case "mkv":
                return "MKV";
            case "mp4":
            case "m4v":
                return "MP4";
            case "webm":
                return "WebM";
            case "avi":
                return "AVI";
            case "mov":
                return "MOV";
            case "flv":
                return "FLV";
            case "ts":
            case "m2ts":
                return "TS";
            default:
                return "";
        }
    }

    private String shortContainerFormat() {
        String epName =
                options != null
                        ? options.optString("_episodeName", "").toLowerCase(Locale.ROOT)
                        : "";
        String u = uri != null ? uri.toString().toLowerCase(Locale.ROOT) : "";
        String m = mediaMime != null ? mediaMime.toLowerCase(Locale.ROOT) : "";
        if (m.contains("mpegurl") || u.contains(".m3u8")) return "HLS";
        if (m.contains("dash") || u.contains(".mpd")) return "DASH";
        if (m.contains("matroska")) return "MKV";
        String detected = detectKnownContainer(epName, uri);
        if (!detected.isEmpty()) return detected;
        return "";
    }

    public String videoResolution() {
        return onMain(
                () -> {
                    if (released || exo == null) return "分辨率未知";
                    androidx.media3.common.Format format = exo.getVideoFormat();
                    androidx.media3.common.Format audioFormat = exo.getAudioFormat();
                    int w =
                            format != null && format.width > 0
                                    ? format.width
                                    : exo.getVideoSize().width;
                    int h =
                            format != null && format.height > 0
                                    ? format.height
                                    : exo.getVideoSize().height;
                    if (w <= 0 || h <= 0) return "分辨率未知";
                    int longEdge = Math.max(w, h);
                    String tier =
                            longEdge >= 3800
                                    ? "4K "
                                    : longEdge >= 2500
                                            ? "2K "
                                            : longEdge >= 1900
                                                    ? "1080P "
                                                    : longEdge >= 1200 ? "720P " : "";
                    StringBuilder sb = new StringBuilder();
                    sb.append(tier).append(w).append(" × ").append(h);
                    String vCodec = format != null ? shortVideoCodec(format.sampleMimeType) : "";
                    if (!vCodec.isEmpty()) sb.append(" · ").append(vCodec);
                    if (format != null
                            && format.colorInfo != null
                            && androidx.media3.common.ColorInfo.isTransferHdr(format.colorInfo)
                            && !"杜比视界".equals(vCodec)) {
                        sb.append(" HDR");
                    }
                    String aCodec =
                            audioFormat != null ? shortAudioCodec(audioFormat.sampleMimeType) : "";
                    if (!aCodec.isEmpty()) sb.append(" · ").append(aCodec);
                    String container = shortContainerFormat();
                    if (!container.isEmpty()) sb.append(" · ").append(container);
                    return sb.toString();
                });
    }

    public java.util.List<String> mediaBadges() {
        return onMain(
                () -> {
                    java.util.List<String> out = new java.util.ArrayList<>(4);
                    if (released || exo == null) return out;
                    androidx.media3.common.Format vf = exo.getVideoFormat();
                    androidx.media3.common.Format af = exo.getAudioFormat();
                    int w = vf != null && vf.width > 0 ? vf.width : exo.getVideoSize().width;
                    int h = vf != null && vf.height > 0 ? vf.height : exo.getVideoSize().height;
                    int longEdge = Math.max(w, h);
                    String tier =
                            longEdge >= 3800
                                    ? "4K"
                                    : longEdge >= 2500
                                            ? "2K"
                                            : longEdge >= 1900
                                                    ? "1080P"
                                                    : longEdge >= 1200
                                                            ? "720P"
                                                            : (w > 0 && h > 0 ? h + "P" : "");
                    String vMime =
                            vf != null && vf.sampleMimeType != null
                                    ? vf.sampleMimeType.toLowerCase(Locale.ROOT)
                                    : "";
                    String vCodecs =
                            vf != null && vf.codecs != null
                                    ? vf.codecs.toLowerCase(Locale.ROOT)
                                    : "";
                    boolean isDv =
                            vMime.contains("dolby-vision")
                                    || vCodecs.contains("dvhe")
                                    || vCodecs.contains("dvh1")
                                    || vCodecs.contains("dav1");
                    String dvProfile = "";
                    if (isDv) {
                        java.util.regex.Matcher m =
                                java.util.regex.Pattern.compile("(?:dvhe|dvh1|dav1)\\.0*(\\d+)")
                                        .matcher(vCodecs);
                        if (m.find()) dvProfile = "P" + m.group(1);
                    }
                    if (!dvProfile.isEmpty() && !tier.isEmpty()) {
                        out.add("DOLBY " + dvProfile + " · " + tier);
                    } else if (!tier.isEmpty()) {
                        out.add(tier);
                    }

                    if (isDv) {
                        out.add("DOLBY VISION");
                    } else if (vf != null
                            && vf.colorInfo != null
                            && androidx.media3.common.ColorInfo.isTransferHdr(vf.colorInfo)) {
                        out.add(
                                vf.colorInfo.colorTransfer == C.COLOR_TRANSFER_HLG
                                        ? "HLG HDR"
                                        : "HDR10");
                    } else if (vf != null) {
                        String vc = shortVideoCodec(vf.sampleMimeType);
                        if (!vc.isEmpty() && !"杜比视界".equals(vc)) out.add(vc);
                    }

                    if (af != null && af.sampleMimeType != null) {
                        String am = af.sampleMimeType.toLowerCase(Locale.ROOT);
                        int ch = af.channelCount;
                        String chTag =
                                ch >= 8
                                        ? " 7.1"
                                        : ch == 6
                                                ? " 5.1"
                                                : ch == 2
                                                        ? " 2.0"
                                                        : ch == 1
                                                                ? " 1.0"
                                                                : (ch > 0 ? " " + ch + "CH" : "");
                        if (am.contains("eac3-joc")) out.add("DD+ ATMOS" + chTag);
                        else if (am.contains("eac3")) out.add("DD+" + chTag);
                        else if (am.contains("ac3")) out.add("DOLBY AUDIO" + chTag);
                        else if (am.contains("truehd")) out.add("TRUEHD" + chTag);
                        else if (am.contains("vnd.dts.hd")) out.add("DTS-HD" + chTag);
                        else if (am.contains("dts")) out.add("DTS" + chTag);
                        else if (am.contains("flac")) out.add("FLAC" + chTag);
                        else if (am.contains("opus")) out.add("OPUS" + chTag);
                        else if (am.contains("mp4a") || am.contains("aac")) out.add("AAC" + chTag);
                        else if (am.contains("mpeg") || am.contains("mp3")) out.add("MP3");
                    }

                    String dec = videoDecoder == null ? "" : videoDecoder.toLowerCase(Locale.ROOT);
                    boolean swDec =
                            dec.contains("ffmpeg")
                                    || dec.contains("dav1d")
                                    || dec.contains("libvpx")
                                    || dec.startsWith("c2.android.")
                                    || dec.startsWith("omx.google.");
                    out.add(ijkMode ? "IJK 播放" : (swDec ? "软解播放" : "原生播放"));
                    return out;
                });
    }

    public int getVideoHeight() {
        return onMain(() -> released || exo == null ? 0 : exo.getVideoSize().height);
    }

    public String getLastError() {
        return onMain(() -> lastError);
    }

    public int softFallbackMode() {
        return onMain(() -> lastErrorTrack == C.TRACK_TYPE_AUDIO ? 3 : 2);
    }

    public String getFailureMessage(int code) {
        return onMain(() -> PlaybackFailure.message(code, lastHttpStatus));
    }

    public org.json.JSONObject decoderDiagnostics() {
        return onMain(
                () -> {
                    org.json.JSONObject info =
                            new org.json.JSONObject()
                                    .put("video_decoder", videoDecoder)
                                    .put("audio_decoder", audioDecoder);
                    if (released || exo == null) return info;
                    androidx.media3.common.Format vf = exo.getVideoFormat(),
                            af = exo.getAudioFormat();
                    if (vf != null) {
                        info.put("video_mime", vf.sampleMimeType)
                                .put("width", vf.width)
                                .put("height", vf.height)
                                .put("frame_rate", vf.frameRate);
                        if (vf.colorInfo != null)
                            info.put("color_space", vf.colorInfo.colorSpace)
                                    .put("color_transfer", vf.colorInfo.colorTransfer)
                                    .put("color_range", vf.colorInfo.colorRange)
                                    .put("luma_bitdepth", vf.colorInfo.lumaBitdepth)
                                    .put(
                                            "hdr",
                                            androidx.media3.common.ColorInfo.isTransferHdr(
                                                    vf.colorInfo));
                    }
                    info.put("first_frame_ms", firstFrameMs);
                    if (af != null)
                        info.put("audio_mime", af.sampleMimeType).put("channels", af.channelCount);
                    androidx.media3.exoplayer.DecoderCounters vc = exo.getVideoDecoderCounters(),
                            ac = exo.getAudioDecoderCounters();
                    if (vc != null) {
                        vc.ensureUpdated();
                        info.put("video_rendered", vc.renderedOutputBufferCount)
                                .put("video_dropped", vc.droppedBufferCount);
                    }
                    if (ac != null) {
                        ac.ensureUpdated();
                        info.put("audio_rendered", ac.renderedOutputBufferCount);
                    }
                    return info;
                });
    }

    public String playbackInfo() {
        org.json.JSONObject d = decoderDiagnostics();
        return (ijkMode ? "IJK 兼容模式 (Media3 + FFmpeg)\n视频：" : "Exo (Media3)\n视频：")
                + d.optString("video_mime", "尚未识别")
                + " · "
                + d.optString("video_decoder", "尚未启动")
                + "\n音频："
                + d.optString("audio_mime", "尚未识别")
                + " · "
                + d.optString("audio_decoder", "尚未启动")
                + "\n"
                + d.optInt("width")
                + " × "
                + d.optInt("height")
                + (getLastError().isEmpty() ? "" : "\n" + getLastError());
    }

    public int getAudioSessionId() {
        return onMain(() -> released || exo == null ? 0 : exo.getAudioSessionId());
    }

    public long getFirstFrameMs() {
        return firstFrameMs;
    }

    public void setCuesListener(CueListener listener) {
        onMain(
                () -> {
                    cueListener = listener;
                    return null;
                });
    }

    private String resolveLocalClearKeyJson() {
        org.json.JSONObject drm = options == null ? null : options.optJSONObject("drm");
        if (drm != null) {
            String explicit = drm.optString("clearKeyJson", "").trim();
            if (!explicit.isEmpty()) return explicit;
        }
        String scheme =
                drm == null
                        ? (options == null ? "" : options.optString("drmScheme"))
                        : drm.optString("scheme", drm.optString("type"));
        if (!LiveQualityPolicy.isClearKeyScheme(scheme)) return null;
        String rawLicense =
                drm == null
                        ? (options == null ? "" : options.optString("drmLicenseUrl"))
                        : drm.optString(
                                "licenseUrl",
                                drm.optString("licenseUri", drm.optString("licenseKey")));
        return LiveQualityPolicy.normalizeClearKeyJwkJson(rawLicense);
    }

    private androidx.media3.exoplayer.source.MediaSource playbackSource(Uri address)
            throws Exception {
        String localClearKeyJson = resolveLocalClearKeyJson();
        if (localClearKeyJson != null && !localClearKeyJson.isEmpty()) {
            androidx.media3.exoplayer.drm.LocalMediaDrmCallback callback =
                    new androidx.media3.exoplayer.drm.LocalMediaDrmCallback(
                            localClearKeyJson.getBytes("UTF-8"));
            final androidx.media3.exoplayer.drm.DefaultDrmSessionManager drmManager =
                    new androidx.media3.exoplayer.drm.DefaultDrmSessionManager.Builder()
                            .setUuidAndExoMediaDrmProvider(
                                    C.CLEARKEY_UUID,
                                    androidx.media3.exoplayer.drm.FrameworkMediaDrm
                                            .DEFAULT_PROVIDER)
                            .setMultiSession(false)
                            .build(callback);
            mediaSourceFactory.setDrmSessionManagerProvider(unused -> drmManager);
        }
        MediaItem item = mediaItem(address, localClearKeyJson != null);
        androidx.media3.exoplayer.source.MediaSource video =
                televisionSubtitles
                        ? androidx.media3.exoplayer.source.TvSubtitleSource.create(
                                mediaSourceFactory, subtitleDataSourceFactory, item)
                        : mediaSourceFactory.createMediaSource(item);
        org.json.JSONObject extra = options.optJSONObject("extra");
        String audio = extra == null ? "" : extra.optString("audio");
        if (!Cms.isHttp(audio)) return video;
        return new androidx.media3.exoplayer.source.MergingMediaSource(
                true, video, mediaSourceFactory.createMediaSource(MediaItem.fromUri(audio)));
    }

    private MediaItem mediaItem(Uri address, boolean usingLocalClearKey) throws Exception {
        MediaItem.Builder item = new MediaItem.Builder().setUri(address);
        if (mediaMime != null
                && (MimeTypes.APPLICATION_M3U8.equalsIgnoreCase(mediaMime)
                        || MimeTypes.APPLICATION_MPD.equalsIgnoreCase(mediaMime)
                        || MimeTypes.APPLICATION_SS.equalsIgnoreCase(mediaMime))) {
            item.setMimeType(mediaMime);
        }
        if (options.optBoolean("live", false)) {
            item.setLiveConfiguration(
                    new MediaItem.LiveConfiguration.Builder()
                            .setTargetOffsetMs(3500)
                            .setMinPlaybackSpeed(0.97f)
                            .setMaxPlaybackSpeed(1.04f)
                            .build());
        }
        java.util.List<MediaItem.SubtitleConfiguration> tracks = new java.util.ArrayList<>();
        org.json.JSONArray subtitles = options.optJSONArray("subtitles");
        if (subtitles != null)
            for (int i = 0; i < subtitles.length(); i++) {
                org.json.JSONObject sub = subtitles.optJSONObject(i);
                if (sub == null || sub.optString("url").isEmpty()) continue;
                tracks.add(
                        new MediaItem.SubtitleConfiguration.Builder(Uri.parse(sub.optString("url")))
                                .setMimeType(
                                        MediaOptions.subtitleMime(
                                                sub.optString("url"), sub.optString("mimeType")))
                                .setLabel(sub.optString("name", "外挂字幕"))
                                .setLanguage(sub.optString("language", "zh"))
                                .setSelectionFlags(i == 0 ? C.SELECTION_FLAG_DEFAULT : 0)
                                .build());
            }
        item.setSubtitleConfigurations(tracks);
        if (!usingLocalClearKey) {
            org.json.JSONObject drm = options.optJSONObject("drm");
            String scheme =
                    drm == null
                            ? options.optString("drmScheme")
                            : drm.optString("scheme", drm.optString("type"));
            String license =
                    drm == null
                            ? options.optString("drmLicenseUrl")
                            : drm.optString("licenseUrl", drm.optString("licenseUri"));
            if (!scheme.isEmpty()) {
                java.util.UUID uuid = Util.getDrmUuid(scheme);
                if (uuid == null || !Cms.isHttp(license))
                    throw new IllegalArgumentException("来源缺少有效DRM许可配置");
                java.util.Map<String, String> licenseHeaders = new LinkedHashMap<>();
                if (drm != null && drm.optJSONObject("headers") != null)
                    MediaOptions.headers(licenseHeaders, drm.optJSONObject("headers"));
                item.setDrmConfiguration(
                        new MediaItem.DrmConfiguration.Builder(uuid)
                                .setLicenseUri(license)
                                .setLicenseRequestHeaders(licenseHeaders)
                                .build());
            }
        }
        return item.build();
    }

    public void addExternalSubtitle(Uri subtitle, String name, String mime) {
        onMain(
                () -> {
                    check();
                    if (mediaSourceFactory == null) throw new IllegalStateException("请等待视频开始播放");
                    org.json.JSONArray tracks = options.optJSONArray("subtitles");
                    if (tracks == null) {
                        tracks = new org.json.JSONArray();
                        options.put("subtitles", tracks);
                    }
                    tracks.put(
                            new org.json.JSONObject()
                                    .put("url", subtitle.toString())
                                    .put("name", name)
                                    .put("mimeType", mime));
                    long position = exo.getCurrentPosition();
                    boolean play = exo.getPlayWhenReady();
                    exo.setMediaSource(playbackSource(uri), position);
                    exo.prepare();
                    exo.setPlayWhenReady(play);
                    return null;
                });
    }

    public void setSubtitleListener(SubtitleListener listener) {
        onMain(
                () -> {
                    subtitleListener = listener;
                    return null;
                });
    }

    public void setSpeed(float speed) {
        onMain(
                () -> {
                    check();
                    exo.setPlaybackSpeed(speed);
                    return null;
                });
    }

    public float getSpeed() {
        return onMain(() -> released || exo == null ? 1.0f : exo.getPlaybackParameters().speed);
    }

    public void setRepeatOne(boolean repeat) {
        onMain(
                () -> {
                    check();
                    exo.setRepeatMode(repeat ? Player.REPEAT_MODE_ONE : Player.REPEAT_MODE_OFF);
                    return null;
                });
    }

    private static String readableLanguage(String lang) {
        if (lang == null) return "";
        String l = lang.trim().toLowerCase(Locale.ROOT);
        if (l.isEmpty() || "und".equals(l) || "unknown".equals(l)) return "";
        if (l.equals("zh-hans") || l.equals("zh-cn") || l.equals("zh_cn") || l.equals("chs")) {
            return "简体中文";
        }
        if (l.equals("zh-hant")
                || l.equals("zh-tw")
                || l.equals("zh_tw")
                || l.equals("zh-hk")
                || l.equals("cht")) {
            return "繁体中文";
        }
        if (l.equals("yue") || l.startsWith("yue-")) return "粤语";
        if (l.equals("zh")
                || l.startsWith("zh-")
                || l.equals("zho")
                || l.equals("chi")
                || l.equals("cmn")) {
            return "中文";
        }
        if (l.equals("en") || l.startsWith("en-") || l.equals("eng")) return "英语";
        if (l.equals("ja") || l.startsWith("ja-") || l.equals("jpn")) return "日语";
        if (l.equals("ko") || l.startsWith("ko-") || l.equals("kor")) return "韩语";
        if (l.equals("fr") || l.equals("fre") || l.equals("fra")) return "法语";
        if (l.equals("de") || l.equals("ger") || l.equals("deu")) return "德语";
        if (l.equals("es") || l.equals("spa")) return "西班牙语";
        if (l.equals("ru") || l.equals("rus")) return "俄语";
        if (l.equals("th") || l.equals("tha")) return "泰语";
        if (l.equals("vi") || l.equals("vie")) return "越南语";
        return lang.trim();
    }

    public java.util.List<String> trackLabels(int type) {
        return onMain(
                () -> {
                    java.util.List<String> out = new java.util.ArrayList<>();
                    if (released || exo == null) return out;
                    for (androidx.media3.common.Tracks.Group group :
                            exo.getCurrentTracks().getGroups())
                        if (group.getType() == type)
                            for (int i = 0; i < group.length; i++)
                                if (group.isTrackSupported(i)) {
                                    androidx.media3.common.Format f = group.getTrackFormat(i);
                                    String rawLbl = f.label == null ? "" : f.label.trim();
                                    String langName = readableLanguage(f.language);
                                    String label;
                                    if (!rawLbl.isEmpty() && !langName.isEmpty()) {
                                        String rawBucket =
                                                SubtitlePreferenceStore.detectLangBucket(rawLbl);
                                        String langBucket =
                                                SubtitlePreferenceStore.detectLangBucket(langName);
                                        if (!rawBucket.isEmpty() && rawBucket.equals(langBucket)) {
                                            label = rawLbl;
                                        } else {
                                            label = rawLbl + " · " + langName;
                                        }
                                    } else if (!rawLbl.isEmpty()) {
                                        label = rawLbl;
                                    } else if (!langName.isEmpty()) {
                                        label = langName;
                                    } else {
                                        label = "轨道 " + (out.size() + 1);
                                    }
                                    if (type == C.TRACK_TYPE_AUDIO) {
                                        String codec = shortAudioCodec(f.sampleMimeType);
                                        if (!codec.isEmpty() && !label.contains(codec)) {
                                            label += " · " + codec;
                                        }
                                        if (f.channelCount > 0) {
                                            label += " · " + f.channelCount + " 声道";
                                        }
                                    } else if (f.channelCount > 0) {
                                        label += " · " + f.channelCount + " 声道";
                                    }
                                    out.add((group.isTrackSelected(i) ? "✓ " : "") + label);
                                }
                    return out;
                });
    }

    public void selectTrack(int type, int index) {
        onMain(
                () -> {
                    check();
                    androidx.media3.common.TrackSelectionParameters.Builder p =
                            exo.getTrackSelectionParameters()
                                    .buildUpon()
                                    .clearOverridesOfType(type)
                                    .setTrackTypeDisabled(type, index == -2);
                    if (index >= 0) {
                        int count = 0;
                        for (androidx.media3.common.Tracks.Group group :
                                exo.getCurrentTracks().getGroups())
                            if (group.getType() == type)
                                for (int i = 0; i < group.length; i++)
                                    if (group.isTrackSupported(i) && count++ == index)
                                        p.addOverride(
                                                new androidx.media3.common.TrackSelectionOverride(
                                                        group.getMediaTrackGroup(), i));
                    }
                    exo.setTrackSelectionParameters(p.build());
                    return null;
                });
    }

    public void release() {
        RequestScope activeScope = probeScope;
        if (activeScope != null) activeScope.cancel();
        onMain(
                () -> {
                    if (!released) {
                        released = true;
                        preparation++;
                        RequestScope current = probeScope;
                        if (current != null) current.cancel();
                        if (exo != null) exo.release();
                    }
                    return null;
                });
    }

    private static int milliseconds(long value) {
        return value == C.TIME_UNSET || value < 0 ? 0 : (int) Math.min(Integer.MAX_VALUE, value);
    }

    private void check() {
        if (released || exo == null) throw new IllegalStateException("Player released");
    }

    private <T> T onMain(Callable<T> work) {
        if (Looper.myLooper() == Looper.getMainLooper())
            try {
                return work.call();
            } catch (RuntimeException e) {
                throw e;
            } catch (Exception e) {
                throw new IllegalStateException(e);
            }
        FutureTask<T> task = new FutureTask<>(work);
        if (!main.post(task)) throw new IllegalStateException("Main looper unavailable");
        try {
            return task.get(15, TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("Player call interrupted", e);
        } catch (ExecutionException e) {
            Throwable cause = e.getCause();
            if (cause instanceof RuntimeException) throw (RuntimeException) cause;
            throw new IllegalStateException(cause);
        } catch (java.util.concurrent.TimeoutException e) {
            task.cancel(false);
            throw new IllegalStateException("Player UI thread timed out", e);
        }
    }

    static final class LoadControlProfile {
        final int minBufferMs;
        final int maxBufferMs;
        final int startBufferMs;
        final int rebufferMs;
        final int targetBufferBytes;
        final boolean prioritizeTimeOverSize;

        LoadControlProfile(
                int minBufferMs,
                int maxBufferMs,
                int startBufferMs,
                int rebufferMs,
                int targetBufferBytes,
                boolean prioritizeTimeOverSize) {
            this.minBufferMs = minBufferMs;
            this.maxBufferMs = maxBufferMs;
            this.startBufferMs = startBufferMs;
            this.rebufferMs = rebufferMs;
            this.targetBufferBytes = targetBufferBytes;
            this.prioritizeTimeOverSize = prioritizeTimeOverSize;
        }
    }

    /**
     * Scales Media3 buffer ceilings to device heap limits so 1GB-RAM Android 6.0.1 TVs (e.g.,
     * MiTV OS 1.3.130 with 96–128MB heap) and 2GB TV boxes streaming multi-GB 4K MKVs never OOM
     * from unbounded time-prioritized allocations.
     */
    static LoadControlProfile resolveLoadControlProfile(
            int memoryClassMb, boolean lowRamDevice, int userBufferSeconds, boolean ijkMode) {
        int userBufferMs = Math.max(15, Math.min(50, userBufferSeconds)) * 1000;
        int startBufferMs = ijkMode ? 400 : 500;
        int rebufferMs = ijkMode ? 1000 : 1400;
        if (lowRamDevice || (memoryClassMb > 0 && memoryClassMb <= 128)) {
            int maxBuf = Math.max(10000, Math.min(userBufferMs, 16000));
            return new LoadControlProfile(
                    6000, maxBuf, startBufferMs, rebufferMs, 16 * 1024 * 1024, false);
        }
        if (memoryClassMb > 0 && memoryClassMb <= 256) {
            int maxBuf = Math.max(15000, Math.min(userBufferMs, 30000));
            return new LoadControlProfile(
                    Math.min(10000, maxBuf),
                    maxBuf,
                    startBufferMs,
                    rebufferMs,
                    32 * 1024 * 1024,
                    false);
        }
        int minBuf = Math.min(12000, userBufferMs);
        int maxBuf = Math.max(20000, userBufferMs);
        return new LoadControlProfile(
                minBuf, maxBuf, startBufferMs, rebufferMs, 64 * 1024 * 1024, false);
    }

    /**
     * Detects premature progressive EOF (e.g., upstream HTTP connection reset on an online MKV)
     * well before the real end of the title so the player can seamlessly reconnect at the current
     * timestamp instead of prematurely ending playback.
     */
    static boolean isPrematureProgressiveEnd(boolean live, int positionMs, int durationMs) {
        return !live
                && durationMs >= 60_000
                && positionMs >= 5_000
                && positionMs < durationMs - 15_000;
    }

    /** API-23-safe startup indicator read from ExoPlayer loader threads. */
    interface StartupState {
        boolean isPlaybackStarted();
    }

    static boolean isSocketTimeout(Throwable error) {
        Throwable cur = error;
        for (int depth = 0; cur != null && depth < 5; depth++) {
            if (cur instanceof java.net.SocketTimeoutException) return true;
            cur = cur.getCause();
        }
        return false;
    }

    static final class ResilientLoadErrorPolicy
            extends androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy {
        private final boolean live;
        private final StartupState startupState;

        ResilientLoadErrorPolicy(boolean live) {
            this(live, null);
        }

        ResilientLoadErrorPolicy(boolean live, StartupState startupState) {
            super(live ? 4 : 6);
            this.live = live;
            this.startupState = startupState;
        }

        private boolean isStarted() {
            return startupState == null || startupState.isPlaybackStarted();
        }

        @Override
        public int getMinimumLoadableRetryCount(int dataType) {
            if (!isStarted()) {
                return 1;
            }
            return live ? 4 : 6;
        }

        @Override
        public long getRetryDelayMsFor(LoadErrorInfo loadErrorInfo) {
            if (loadErrorInfo == null || loadErrorInfo.exception == null) {
                return C.TIME_UNSET;
            }
            java.io.IOException ex = loadErrorInfo.exception;
            if (ex instanceof androidx.media3.common.ParserException
                    || ex instanceof java.io.FileNotFoundException) {
                return C.TIME_UNSET;
            }
            if (ex
                    instanceof
                    androidx.media3.datasource.HttpDataSource.InvalidResponseCodeException) {
                int code =
                        ((androidx.media3.datasource.HttpDataSource.InvalidResponseCodeException)
                                        ex)
                                .responseCode;
                if (code == 400 || code == 401 || code == 403 || code == 404 || code == 410) {
                    return C.TIME_UNSET;
                }
            }
            if (!isStarted()) {
                if (isSocketTimeout(ex) || loadErrorInfo.errorCount > 1) {
                    return C.TIME_UNSET;
                }
                return 400L;
            }
            long cap = live ? 2500L : 4000L;
            return Math.min(cap, 500L * Math.max(1, loadErrorInfo.errorCount));
        }
    }

    /**
     * Transparently chains loopback 206 byte-range chunks for {@link LocalProxy}.
     *
     * <p>Media3's {@code DefaultHttpDataSource} computes stream length from {@code (b - a + 1)}
     * rather than {@code /total}, which would otherwise truncate multi-GB MKV/MP4 files at the
     * first chunk. This wrapper exposes {@code total - position} to the extractor, chains
     * subsequent chunks on demand, retries transient chunk drops/truncations from exact byte
     * offsets, and closes each chunk cleanly in sub-millisecond time when {@code MatroskaExtractor}
     * seeks to end-of-file {@code Cues}.
     */
    static final class ChunkedProxyDataSource implements androidx.media3.datasource.DataSource {
        static final String HEADER_CHUNKED_CLIENT = "X-Movie-Chunked-Client";
        static final int MAX_CHUNK_RETRIES = 3;
        private static final long[] CHUNK_RETRY_BACKOFF_MS = {250L, 600L, 1200L};

        static final class Factory implements androidx.media3.datasource.DataSource.Factory {
            private final androidx.media3.datasource.DataSource.Factory innerFactory;
            private final StartupState startupState;

            Factory(androidx.media3.datasource.DataSource.Factory innerFactory) {
                this(innerFactory, null);
            }

            Factory(
                    androidx.media3.datasource.DataSource.Factory innerFactory,
                    StartupState startupState) {
                this.innerFactory = innerFactory;
                this.startupState = startupState;
            }

            @Override
            public androidx.media3.datasource.DataSource createDataSource() {
                return new ChunkedProxyDataSource(innerFactory.createDataSource(), startupState);
            }
        }

        private final androidx.media3.datasource.DataSource inner;
        private final StartupState startupState;
        private androidx.media3.datasource.DataSpec baseSpec;
        private Uri lastUri;
        private Map<String, java.util.List<String>> lastHeaders = Collections.emptyMap();
        private boolean innerOpen;
        private boolean chunkMode;
        private long totalLength = C.LENGTH_UNSET;
        private long currentPos;
        private long chunkRemaining;
        private int consecutiveReadRecoveries;

        ChunkedProxyDataSource(androidx.media3.datasource.DataSource inner) {
            this(inner, null);
        }

        ChunkedProxyDataSource(
                androidx.media3.datasource.DataSource inner, StartupState startupState) {
            this.inner = inner;
            this.startupState = startupState;
        }

        static int resolveOpenMaxRetries(long position, boolean playbackStarted, Throwable error) {
            if (!playbackStarted && position == 0L) {
                return isSocketTimeout(error) ? 0 : 1;
            }
            return MAX_CHUNK_RETRIES;
        }

        static boolean isRetryableChunkError(Throwable error) {
            if (error == null || Thread.currentThread().isInterrupted()) return false;
            if (isSocketTimeout(error)) return true;
            if (error instanceof java.io.InterruptedIOException) return false;
            if (error
                    instanceof
                    androidx.media3.datasource.HttpDataSource.InvalidResponseCodeException) {
                int code =
                        ((androidx.media3.datasource.HttpDataSource.InvalidResponseCodeException)
                                        error)
                                .responseCode;
                return code == 408 || code == 429 || (code >= 500 && code < 600);
            }
            return error instanceof java.io.IOException;
        }

        private static void sleepRetryBackoff(int attempt) throws java.io.IOException {
            int idx = Math.max(0, Math.min(CHUNK_RETRY_BACKOFF_MS.length - 1, attempt));
            try {
                Thread.sleep(CHUNK_RETRY_BACKOFF_MS[idx]);
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
                throw new java.io.InterruptedIOException("Interrupted during chunk retry");
            }
        }

        @Override
        public void addTransferListener(androidx.media3.datasource.TransferListener listener) {
            inner.addTransferListener(listener);
        }

        @Override
        public long open(androidx.media3.datasource.DataSpec spec) throws java.io.IOException {
            closeInnerQuietly();
            baseSpec = spec;
            chunkMode = false;
            totalLength = C.LENGTH_UNSET;
            currentPos = Math.max(0L, spec.position);
            chunkRemaining = 0L;
            consecutiveReadRecoveries = 0;
            lastUri = spec.uri;
            lastHeaders = Collections.emptyMap();

            boolean eligible =
                    spec.uri != null
                            && ProxyAddress.isLoopbackHost(spec.uri.getHost())
                            && spec.length == C.LENGTH_UNSET;
            if (!eligible) {
                long len = inner.open(spec);
                innerOpen = true;
                if (inner.getUri() != null) lastUri = inner.getUri();
                lastHeaders = inner.getResponseHeaders();
                return len;
            }

            boolean started = startupState == null || startupState.isPlaybackStarted();
            java.io.IOException lastError = null;
            for (int attempt = 0; attempt <= MAX_CHUNK_RETRIES; attempt++) {
                try {
                    long innerLen = inner.open(buildChunkSpec(spec, currentPos));
                    innerOpen = true;
                    if (inner.getUri() != null) lastUri = inner.getUri();
                    lastHeaders = inner.getResponseHeaders();
                    long[] cr = parseResponseContentRange(lastHeaders);
                    if (cr != null && (cr[2] == C.LENGTH_UNSET || cr[2] > currentPos)) {
                        if (cr[0] > currentPos || cr[1] < currentPos) {
                            throw new java.io.IOException(
                                    "Unexpected Content-Range "
                                            + cr[0]
                                            + "-"
                                            + cr[1]
                                            + " at offset "
                                            + currentPos);
                        }
                        if (cr[0] < currentPos) {
                            skipInnerFully(currentPos - cr[0]);
                        }
                        chunkMode = true;
                        totalLength = cr[2];
                        chunkRemaining = (cr[1] - currentPos) + 1L;
                        return totalLength != C.LENGTH_UNSET
                                ? (totalLength - currentPos)
                                : C.LENGTH_UNSET;
                    }
                    return innerLen;
                } catch (java.io.IOException e) {
                    closeInnerQuietly();
                    lastError = e;
                    int maxRetries = resolveOpenMaxRetries(currentPos, started, e);
                    if (attempt >= maxRetries || !isRetryableChunkError(e)) {
                        throw e;
                    }
                    sleepRetryBackoff(attempt);
                } catch (RuntimeException e) {
                    closeInnerQuietly();
                    throw e;
                }
            }
            throw lastError != null ? lastError : new java.io.IOException("Chunk open failed");
        }

        @Override
        public int read(byte[] buffer, int offset, int length) throws java.io.IOException {
            if (length == 0) return 0;
            if (!chunkMode) {
                return inner.read(buffer, offset, length);
            }
            if (totalLength != C.LENGTH_UNSET && currentPos >= totalLength) {
                return C.RESULT_END_OF_INPUT;
            }
            while (true) {
                while (chunkRemaining <= 0L) {
                    if (totalLength != C.LENGTH_UNSET && currentPos >= totalLength) {
                        return C.RESULT_END_OF_INPUT;
                    }
                    if (!openNextChunk()) {
                        return C.RESULT_END_OF_INPUT;
                    }
                }
                int toRead = (int) Math.min((long) length, chunkRemaining);
                try {
                    int n = inner.read(buffer, offset, toRead);
                    if (n == C.RESULT_END_OF_INPUT) {
                        if (totalLength != C.LENGTH_UNSET && currentPos >= totalLength) {
                            return C.RESULT_END_OF_INPUT;
                        }
                        if (consecutiveReadRecoveries < MAX_CHUNK_RETRIES
                                && !Thread.currentThread().isInterrupted()) {
                            int attempt = consecutiveReadRecoveries++;
                            closeInnerQuietly();
                            chunkRemaining = 0L;
                            sleepRetryBackoff(attempt);
                            continue;
                        }
                        throw new java.io.EOFException(
                                "Chunk stream truncated at offset "
                                        + currentPos
                                        + " (missing "
                                        + chunkRemaining
                                        + " bytes)");
                    }
                    if (n > 0) {
                        consecutiveReadRecoveries = 0;
                        currentPos += n;
                        chunkRemaining -= n;
                    }
                    return n;
                } catch (java.io.IOException e) {
                    if (consecutiveReadRecoveries < MAX_CHUNK_RETRIES && isRetryableChunkError(e)) {
                        int attempt = consecutiveReadRecoveries++;
                        closeInnerQuietly();
                        chunkRemaining = 0L;
                        sleepRetryBackoff(attempt);
                        continue;
                    }
                    throw e;
                }
            }
        }

        @Override
        public Uri getUri() {
            Uri active = innerOpen ? inner.getUri() : null;
            return active != null ? active : lastUri;
        }

        @Override
        public Map<String, java.util.List<String>> getResponseHeaders() {
            return innerOpen ? inner.getResponseHeaders() : lastHeaders;
        }

        @Override
        public void close() throws java.io.IOException {
            chunkMode = false;
            chunkRemaining = 0L;
            consecutiveReadRecoveries = 0;
            closeInner();
        }

        private boolean openNextChunk() throws java.io.IOException {
            java.io.IOException lastError = null;
            for (int attempt = 0; attempt <= MAX_CHUNK_RETRIES; attempt++) {
                closeInnerQuietly();
                long innerLen;
                try {
                    innerLen = inner.open(buildChunkSpec(baseSpec, currentPos));
                    innerOpen = true;
                } catch (androidx.media3.datasource.HttpDataSource.InvalidResponseCodeException e) {
                    closeInnerQuietly();
                    if (e.responseCode == 416
                            && (totalLength == C.LENGTH_UNSET || currentPos >= totalLength)) {
                        return false;
                    }
                    lastError = e;
                    if (attempt >= MAX_CHUNK_RETRIES || !isRetryableChunkError(e)) {
                        throw e;
                    }
                    sleepRetryBackoff(attempt);
                    continue;
                } catch (java.io.IOException e) {
                    closeInnerQuietly();
                    lastError = e;
                    if (attempt >= MAX_CHUNK_RETRIES || !isRetryableChunkError(e)) {
                        throw e;
                    }
                    sleepRetryBackoff(attempt);
                    continue;
                }
                try {
                    if (inner.getUri() != null) lastUri = inner.getUri();
                    lastHeaders = inner.getResponseHeaders();
                    long[] cr = parseResponseContentRange(lastHeaders);
                    if (cr != null) {
                        if (cr[2] > 0) {
                            totalLength = cr[2];
                        }
                        if (cr[0] > currentPos || cr[1] < currentPos) {
                            throw new java.io.IOException(
                                    "Unexpected Content-Range "
                                            + cr[0]
                                            + "-"
                                            + cr[1]
                                            + " at offset "
                                            + currentPos);
                        }
                        if (cr[0] < currentPos) {
                            skipInnerFully(currentPos - cr[0]);
                        }
                        chunkRemaining = (cr[1] - currentPos) + 1L;
                        return chunkRemaining > 0L;
                    }
                    if (innerLen == 0L) {
                        return false;
                    }
                    chunkRemaining = innerLen != C.LENGTH_UNSET ? innerLen : Long.MAX_VALUE;
                    return true;
                } catch (java.io.IOException e) {
                    closeInnerQuietly();
                    lastError = e;
                    if (attempt >= MAX_CHUNK_RETRIES || !isRetryableChunkError(e)) {
                        throw e;
                    }
                    sleepRetryBackoff(attempt);
                } catch (RuntimeException e) {
                    closeInnerQuietly();
                    throw e;
                }
            }
            throw lastError != null ? lastError : new java.io.IOException("Next chunk open failed");
        }

        private void skipInnerFully(long bytesToSkip) throws java.io.IOException {
            if (bytesToSkip <= 0L) return;
            byte[] scratch = new byte[(int) Math.min(16384L, bytesToSkip)];
            long remaining = bytesToSkip;
            while (remaining > 0L) {
                if (Thread.currentThread().isInterrupted()) {
                    throw new java.io.InterruptedIOException();
                }
                int n = inner.read(scratch, 0, (int) Math.min((long) scratch.length, remaining));
                if (n == C.RESULT_END_OF_INPUT) {
                    throw new java.io.EOFException(
                            "Unexpected EOF skipping " + bytesToSkip + " bytes");
                }
                remaining -= n;
            }
        }

        private void closeInner() throws java.io.IOException {
            if (innerOpen) {
                innerOpen = false;
                inner.close();
            }
        }

        private void closeInnerQuietly() {
            if (innerOpen) {
                innerOpen = false;
                try {
                    inner.close();
                } catch (java.io.IOException ignored) {
                }
            }
        }

        private static androidx.media3.datasource.DataSpec buildChunkSpec(
                androidx.media3.datasource.DataSpec template, long offset) {
            Map<String, String> reqHeaders = new LinkedHashMap<>(template.httpRequestHeaders);
            reqHeaders.put(HEADER_CHUNKED_CLIENT, "1");
            reqHeaders.put("Range", "bytes=" + offset + "-");
            return template.buildUpon()
                    .setPosition(offset)
                    .setLength(C.LENGTH_UNSET)
                    .setHttpRequestHeaders(reqHeaders)
                    .build();
        }

        private static long[] parseResponseContentRange(
                Map<String, java.util.List<String>> responseHeaders) {
            if (responseHeaders == null) return null;
            for (Map.Entry<String, java.util.List<String>> e : responseHeaders.entrySet()) {
                if (e.getKey() != null
                        && "Content-Range".equalsIgnoreCase(e.getKey())
                        && e.getValue() != null
                        && !e.getValue().isEmpty()) {
                    long[] parsed = LocalProxy.parseContentRange(e.getValue().get(0));
                    if (parsed != null) {
                        if (parsed[2] < 0) parsed[2] = C.LENGTH_UNSET;
                        return parsed;
                    }
                }
            }
            return null;
        }
    }
}
