package com.pilipala.marcomovie;

import android.content.Context;
import android.content.SharedPreferences;
import android.media.AudioAttributes;
import android.media.AudioManager;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.Surface;
import androidx.media3.common.C;
import dev.jdtech.mpv.MPVLib;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Optional native libmpv playback engine for high-bitrate 4K/HDR, libplacebo tone-mapping,
 * libass styled subtitles, and Anime4K GLSL super-resolution shaders.
 */
public final class MpvPlayer extends MoviePlayer {
    static final String ANIME4K_ASSET = "shaders/Anime4K_Upscale_CNN_x2_S.glsl";

    private static volatile Boolean available;
    private static MpvPlayer activeInstance;
    private static final Object MPV_NATIVE_LOCK = new Object();
    private static final java.util.concurrent.ExecutorService MPV_DESTROY_POOL =
            java.util.concurrent.Executors.newSingleThreadExecutor(
                    r -> {
                        Thread t = new Thread(r, "mpv-native-destroy");
                        t.setDaemon(true);
                        return t;
                    });
    private static volatile java.util.concurrent.Future<?> pendingNativeDestroy;

    private static void awaitPendingDestroy(long timeoutMs) {
        java.util.concurrent.Future<?> pending = pendingNativeDestroy;
        if (pending == null || pending.isDone()) return;
        try {
            pending.get(Math.max(100L, timeoutMs), TimeUnit.MILLISECONDS);
        } catch (Throwable ignored) {
        }
    }

    /**
     * Disables libplacebo GLES compute-shader HDR peak detection by default on Android to prevent
     * GPU driver / libplacebo __assert2 SIGABRT crashes (observed on Android 15-17 arm64-v8a and
     * 32-bit TV Mali/Adreno drivers).
     */
    static String resolveHdrComputePeak(boolean is64Bit) {
        return "no";
    }

    static long effectiveHeapBudgetBytes(int memoryClassMb, long runtimeMaxHeapBytes) {
        long safeMax = runtimeMaxHeapBytes > 0L ? runtimeMaxHeapBytes : 256L * 1024L * 1024L;
        if (memoryClassMb > 0) {
            long stdBytes = memoryClassMb * 1024L * 1024L;
            return Math.min(safeMax, stdBytes);
        }
        return safeMax;
    }

    private static long readEffectiveHeapBudgetBytes(Context ctx) {
        int memClassMb = 0;
        try {
            if (ctx != null) {
                android.app.ActivityManager am =
                        (android.app.ActivityManager)
                                ctx.getSystemService(Context.ACTIVITY_SERVICE);
                if (am != null) memClassMb = am.getMemoryClass();
            }
        } catch (Throwable ignored) {
        }
        return effectiveHeapBudgetBytes(memClassMb, Runtime.getRuntime().maxMemory());
    }

    public static boolean isAvailable() {
        Boolean cached = available;
        if (cached != null) return cached;
        synchronized (MpvPlayer.class) {
            if (available == null) {
                try {
                    Class.forName("dev.jdtech.mpv.MPVLib");
                    available = Boolean.TRUE;
                } catch (Throwable error) {
                    available = Boolean.FALSE;
                }
            }
            return available;
        }
    }

    static Set<String> loadUnsafeCodecs(String csv) {
        Set<String> out = new LinkedHashSet<>();
        if (csv == null || csv.trim().isEmpty()) return out;
        for (String part : csv.split(",")) {
            String clean = part.trim().toLowerCase(Locale.ROOT);
            if (!clean.isEmpty()) out.add(clean);
        }
        return out;
    }

    static String addUnsafeCodec(String csv, String codec) {
        Set<String> set = loadUnsafeCodecs(csv);
        if (codec != null && !codec.trim().isEmpty()) {
            set.add(codec.trim().toLowerCase(Locale.ROOT));
        }
        StringBuilder sb = new StringBuilder();
        for (String item : set) {
            if (sb.length() > 0) sb.append(',');
            sb.append(item);
        }
        return sb.toString();
    }

    static String selectHwdecMode(
            int decoderMode,
            boolean anime4k,
            boolean hdrToneMapping,
            boolean displaySupportsHdr,
            String unsafeCsv,
            String knownCodec) {
        if (decoderMode == 2) return "no";
        if (anime4k) return "mediacodec-copy";
        if (hdrToneMapping && !displaySupportsHdr) return "mediacodec-copy";
        if (knownCodec != null
                && !knownCodec.trim().isEmpty()
                && loadUnsafeCodecs(unsafeCsv)
                        .contains(knownCodec.trim().toLowerCase(Locale.ROOT))) {
            return "mediacodec-copy";
        }
        return "mediacodec,mediacodec-copy";
    }

    static String selectVo(boolean hdrToneMapping, boolean anime4k) {
        return (hdrToneMapping || anime4k) ? "gpu-next" : "gpu";
    }

    static int mpvBufferBytes(long maxHeapBytes, boolean is64Bit) {
        int base = safeBufferBytes(maxHeapBytes);
        if (is64Bit) return base;
        int cap = maxHeapBytes <= 256L * 1024L * 1024L ? 32 * 1024 * 1024 : 48 * 1024 * 1024;
        return Math.min(base, cap);
    }

    private static boolean is64BitProcess() {
        try {
            if (android.os.Build.VERSION.SDK_INT >= 23) {
                return android.os.Process.is64Bit();
            }
        } catch (Throwable ignored) {
        }
        String arch = System.getProperty("os.arch", "");
        return arch != null && arch.contains("64");
    }

    static boolean isHdrGammaOrCodec(String videoGamma, String videoCodec) {
        String g = videoGamma == null ? "" : videoGamma.trim().toLowerCase(Locale.ROOT);
        if (g.contains("pq")
                || g.contains("smpte2084")
                || g.contains("st2084")
                || g.contains("hlg")
                || g.contains("arib-std-b67")) {
            return true;
        }
        String vc = videoCodec == null ? "" : videoCodec.trim().toLowerCase(Locale.ROOT);
        return vc.contains("dolby")
                || vc.contains("dovi")
                || vc.contains("dvhe")
                || vc.contains("dvh1");
    }

    static String normalizeVideoMime(String videoCodec) {
        if (videoCodec == null || videoCodec.trim().isEmpty()) return "";
        String c = videoCodec.trim().toLowerCase(Locale.ROOT);
        if (c.contains("dolby") || c.contains("dovi") || c.contains("dvhe") || c.contains("dvh1")) {
            return "video/dolby-vision";
        }
        if (c.contains("hevc") || c.contains("h.265") || c.contains("h265")) return "video/hevc";
        if (c.contains("h.264") || c.contains("h264") || c.contains("avc")) return "video/avc";
        if (c.contains("av1") || c.contains("av01")) return "video/av01";
        if (c.contains("vp9")) return "video/x-vnd.on2.vp9";
        if (c.contains("mpeg4") || c.contains("mp4v")) return "video/mp4v-es";
        return "";
    }

    static List<String> buildMediaBadges(
            int width,
            int height,
            String videoCodec,
            String audioCodec,
            String videoGamma,
            String hwdecCurrent,
            boolean anime4kActive) {
        List<String> out = new ArrayList<>(4);
        int longEdge = Math.max(width, height);
        String tier =
                longEdge >= 3800
                        ? "4K"
                        : longEdge >= 2500
                                ? "2K"
                                : longEdge >= 1900
                                        ? "1080P"
                                        : longEdge >= 1200
                                                ? "720P"
                                                : (width > 0 && height > 0 ? height + "P" : "");
        if (!tier.isEmpty()) out.add(tier);

        String vc = videoCodec == null ? "" : videoCodec.trim().toLowerCase(Locale.ROOT);
        String g = videoGamma == null ? "" : videoGamma.trim().toLowerCase(Locale.ROOT);
        if (vc.contains("dolby")
                || vc.contains("dovi")
                || vc.contains("dvhe")
                || vc.contains("dvh1")) {
            out.add("DOLBY VISION");
        } else if (g.contains("hlg") || g.contains("arib-std-b67")) {
            out.add("HLG HDR");
        } else if (g.contains("pq") || g.contains("smpte2084") || g.contains("st2084")) {
            out.add("HDR10");
        } else if (vc.contains("hevc") || vc.contains("h.265") || vc.contains("h265")) {
            out.add("HEVC");
        } else if (vc.contains("h.264") || vc.contains("h264") || vc.contains("avc")) {
            out.add("H.264");
        } else if (vc.contains("av1") || vc.contains("av01")) {
            out.add("AV1");
        } else if (vc.contains("vp9")) {
            out.add("VP9");
        } else if (vc.contains("mpeg4") || vc.contains("mp4v")) {
            out.add("MPEG4");
        }

        String ac = audioCodec == null ? "" : audioCodec.trim().toLowerCase(Locale.ROOT);
        if (ac.contains("eac3") || ac.contains("ec-3")) out.add("DD+");
        else if (ac.contains("ac3") || ac.contains("ac-3")) out.add("DOLBY AUDIO");
        else if (ac.contains("truehd")) out.add("TRUEHD");
        else if (ac.contains("dts-hd") || ac.contains("dtshd")) out.add("DTS-HD");
        else if (ac.contains("dts")) out.add("DTS");
        else if (ac.contains("flac")) out.add("FLAC");
        else if (ac.contains("opus")) out.add("OPUS");
        else if (ac.contains("aac") || ac.contains("mp4a")) out.add("AAC");
        else if (ac.contains("mp3")) out.add("MP3");

        String hw = hwdecCurrent == null ? "" : hwdecCurrent.trim().toLowerCase(Locale.ROOT);
        if (anime4kActive) {
            out.add("MPV Anime4K");
        } else if ("no".equals(hw)) {
            out.add("MPV 软解");
        } else {
            out.add("MPV 播放");
        }
        return out;
    }

    private final Context context;
    private final SharedPreferences prefs;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final AudioManager audio;
    private boolean nativeCreated;
    private boolean initialized;
    private boolean surfaceAttached;
    private Surface attachedSurface;
    private boolean focusHeld;
    private boolean repeatOne;
    private boolean wantPlay;
    private float speed = 1.0f;
    private String configuredVo = "gpu";
    private String configuredHwdec = "mediacodec,mediacodec-copy";
    private boolean anime4kActive;
    private boolean hdrToneMappingActive;
    private volatile boolean prepared;
    private volatile boolean released;
    private volatile boolean paused = true;
    private volatile boolean eofReached;
    private volatile int width;
    private volatile int height;
    private volatile double positionSec;
    private volatile double durationSec;
    private volatile String videoCodec = "";
    private volatile String audioCodec = "";
    private volatile String videoGamma = "";
    private volatile String hwdecCurrent = "";
    private volatile String lastError = "";
    private volatile boolean pausedForCache;
    private volatile int cacheBufferingState = -1;
    private volatile long cacheSpeedBytesPerSec = -1L;
    private volatile long prepareStarted;
    private volatile long firstFrameMs = -1;
    private Uri mediaUri;
    private Map<String, String> headers = Collections.emptyMap();
    private JSONObject options = new JSONObject();
    private OnPreparedListener preparedListener;
    private OnCompletionListener completionListener;
    private OnVideoSizeChangedListener sizeListener;
    private OnErrorListener errorListener;
    private volatile OnHdrChangedListener hdrChangedListener;
    private OnTextTracksChangedListener textTracksChangedListener;
    private OnAudioTracksChangedListener audioTracksChangedListener;
    private SubtitleListener subtitleListener;

    private final AudioManager.OnAudioFocusChangeListener focusChange =
            change -> {
                if (released || !initialized) return;
                if (change == AudioManager.AUDIOFOCUS_LOSS
                        || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
                    pause();
                } else if (change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK) {
                    onMain(
                            () -> {
                                if (!released && initialized) MPVLib.setPropertyInt("volume", 25);
                                return null;
                            });
                } else if (change == AudioManager.AUDIOFOCUS_GAIN) {
                    onMain(
                            () -> {
                                if (!released && initialized) MPVLib.setPropertyInt("volume", 100);
                                return null;
                            });
                }
            };

    private final MPVLib.EventObserver observer =
            new MPVLib.EventObserver() {
                @Override
                public void eventProperty(String property) {}

                @Override
                public void eventProperty(String property, long value) {
                    if (released) return;
                    if ("dwidth".equals(property)) {
                        width = (int) Math.max(0L, value);
                        notifyVideoSize();
                    } else if ("dheight".equals(property)) {
                        height = (int) Math.max(0L, value);
                        notifyVideoSize();
                    } else if ("cache-speed".equals(property)) {
                        cacheSpeedBytesPerSec = Math.max(0L, value);
                    } else if ("cache-buffering-state".equals(property)) {
                        cacheBufferingState = (int) Math.max(0L, Math.min(100L, value));
                        if (pausedForCache && prepared) {
                            notifyBufferingChanged(true, cacheBufferingState);
                        }
                    }
                }

                @Override
                public void eventProperty(String property, double value) {
                    if (released) return;
                    if ("time-pos".equals(property) && value >= 0) {
                        positionSec = value;
                    } else if ("duration".equals(property) && value > 0) {
                        durationSec = value;
                    }
                }

                @Override
                public void eventProperty(String property, boolean value) {
                    if (released) return;
                    if ("pause".equals(property)) {
                        paused = value;
                    } else if ("eof-reached".equals(property)) {
                        eofReached = value;
                    } else if ("paused-for-cache".equals(property)) {
                        pausedForCache = value;
                        if (prepared) {
                            notifyBufferingChanged(value, value ? cacheBufferingState : 100);
                        }
                    }
                }

                @Override
                public void eventProperty(String property, String value) {
                    if (released) return;
                    String text = value == null ? "" : value;
                    if ("video-codec".equals(property)) {
                        videoCodec = text;
                    } else if ("audio-codec-name".equals(property)) {
                        audioCodec = text;
                    } else if ("video-params/gamma".equals(property)) {
                        boolean wasHdr = isHdrGammaOrCodec(videoGamma, videoCodec);
                        videoGamma = text;
                        boolean nowHdr = isHdrGammaOrCodec(videoGamma, videoCodec);
                        if (nowHdr != wasHdr) {
                            final OnHdrChangedListener listener = hdrChangedListener;
                            if (listener != null) {
                                final boolean hdrFlag = nowHdr;
                                main.post(
                                        () -> {
                                            if (!released) listener.onHdrChanged(hdrFlag);
                                        });
                            }
                        }
                    } else if ("hwdec-current".equals(property)) {
                        hwdecCurrent = text;
                    } else if ("sub-text".equals(property)) {
                        final SubtitleListener listener = subtitleListener;
                        if (listener != null) {
                            main.post(
                                    () -> {
                                        if (!released) listener.text(text);
                                    });
                        }
                    }
                }

                @Override
                public void event(int eventId) {
                    if (released) return;
                    if (eventId == MPVLib.MPV_EVENT_FILE_LOADED) {
                        main.post(MpvPlayer.this::handleFileLoaded);
                    } else if (eventId == MPVLib.MPV_EVENT_VIDEO_RECONFIG) {
                        main.post(MpvPlayer.this::syncVideoDimensions);
                    } else if (eventId == MPVLib.MPV_EVENT_END_FILE) {
                        main.post(MpvPlayer.this::handleEndFile);
                    }
                }
            };

    @Override
    protected void notifyBufferingChanged(boolean buffering, int percent) {
        if (released) return;
        super.notifyBufferingChanged(buffering, percent);
    }

    public MpvPlayer(Context host) {
        super(host, false);
        this.context = host.getApplicationContext();
        this.prefs = this.context.getSharedPreferences(Prefs.FILE, 0);
        this.audio = (AudioManager) this.context.getSystemService(Context.AUDIO_SERVICE);
        if (!isAvailable()) {
            throw new IllegalStateException("libmpv native library unavailable");
        }
        if (Looper.myLooper() != Looper.getMainLooper()) {
            awaitPendingDestroy(8000L);
        }
        final java.util.concurrent.atomic.AtomicBoolean abandoned =
                new java.util.concurrent.atomic.AtomicBoolean(false);
        try {
            onMain(
                    () -> {
                        if (abandoned.get()) return null;
                        if (activeInstance != null && activeInstance != MpvPlayer.this) {
                            activeInstance.releaseInternal();
                        }
                        awaitPendingDestroy(2500L);
                        activeInstance = MpvPlayer.this;
                        initNativeMpv();
                        if (abandoned.get()) {
                            releaseInternal();
                        }
                        return null;
                    });
        } catch (RuntimeException err) {
            abandoned.set(true);
            throw err;
        }
    }

    private void initNativeMpv() {
        synchronized (MPV_NATIVE_LOCK) {
            MPVLib.create(context);
            nativeCreated = true;
            try {
                int decoderMode = prefs.getInt(Prefs.DECODER_MODE, 0);
                anime4kActive = prefs.getBoolean(Prefs.ANIME4K_ENABLED, false);
                hdrToneMappingActive = prefs.getBoolean(Prefs.HDR_TONE_MAPPING, true);
                boolean displayHdr = DecoderRenderersFactory.hasDisplayHdrSupport(context);
                boolean is64Bit = is64BitProcess();
                String unsafeCsv = prefs.getString(Prefs.MPV_UNSAFE_DIRECT_CODECS, "");
                configuredVo = selectVo(hdrToneMappingActive, anime4kActive);
                configuredHwdec =
                        selectHwdecMode(
                                decoderMode,
                                anime4kActive,
                                hdrToneMappingActive,
                                displayHdr,
                                unsafeCsv,
                                "");
                int bufferSeconds =
                        Math.max(15, Math.min(60, prefs.getInt(Prefs.BUFFER_SECONDS, 30)));
                int maxBytes = mpvBufferBytes(readEffectiveHeapBudgetBytes(context), is64Bit);
                int backBytes = Math.min(16 * 1024 * 1024, maxBytes / 4);

                // Start with vo=null until an Android Surface is attached; enabling gpu/gpu-next
                // with
                // wid=0 before attachSurface() can trigger EGL/libplacebo aborts on TV Mali
                // drivers.
                MPVLib.setOptionString("vo", "null");
                MPVLib.setOptionString("gpu-context", "android");
                MPVLib.setOptionString("opengl-es", "yes");
                MPVLib.setOptionString("ao", "audiotrack,opensles");
                MPVLib.setOptionString("hwdec", configuredHwdec);
                MPVLib.setOptionString("hwdec-codecs", "all");
                MPVLib.setOptionString("vd-lavc-threads", is64Bit ? "0" : "4");
                MPVLib.setOptionString("cache", "yes");
                MPVLib.setOptionString("cache-pause", "yes");
                MPVLib.setOptionString("cache-pause-wait", "1");
                MPVLib.setOptionString("demuxer-max-bytes", String.valueOf(maxBytes));
                MPVLib.setOptionString("demuxer-max-back-bytes", String.valueOf(backBytes));
                MPVLib.setOptionString("demuxer-readahead-secs", String.valueOf(bufferSeconds));
                MPVLib.setOptionString("network-timeout", "20");
                MPVLib.setOptionString("hls-bitrate", "max");
                MPVLib.setOptionString("deinterlace", "auto");
                MPVLib.setOptionString("hr-seek", "yes");
                MPVLib.setOptionString("hr-seek-framedrop", "yes");
                MPVLib.setOptionString("sub-auto", "no");
                MPVLib.setOptionString("sub-ass", "yes");
                MPVLib.setOptionString("sub-ass-override", "scale");
                MPVLib.setOptionString("embeddedfonts", "yes");
                MPVLib.setOptionString("sub-font-size", "44");
                MPVLib.setOptionString("keep-open", "no");
                MPVLib.setOptionString("idle", "yes");
                MPVLib.setOptionString("force-window", "no");
                MPVLib.setOptionString("save-position-on-quit", "no");
                MPVLib.setOptionString("volume-max", "200");
                MPVLib.setOptionString("pause", "yes");
                if (hdrToneMappingActive) {
                    MPVLib.setOptionString("tone-mapping", "auto");
                    MPVLib.setOptionString("hdr-compute-peak", resolveHdrComputePeak(is64Bit));
                    MPVLib.setOptionString("gamut-mapping-mode", "auto");
                    MPVLib.setOptionString("target-colorspace-hint", displayHdr ? "yes" : "no");
                }
                if (anime4kActive) {
                    File shader = extractAnime4kShader(context);
                    if (shader != null && shader.isFile()) {
                        MPVLib.setOptionString("glsl-shaders", shader.getAbsolutePath());
                        MPVLib.setOptionString("scale", "bilinear");
                        MPVLib.setOptionString("cscale", "bilinear");
                        MPVLib.setOptionString("dscale", "mitchell");
                    }
                }
                MPVLib.init();
                initialized = true;
                MPVLib.addObserver(observer);
                MPVLib.observeProperty("time-pos", MPVLib.MPV_FORMAT_DOUBLE);
                MPVLib.observeProperty("duration", MPVLib.MPV_FORMAT_DOUBLE);
                MPVLib.observeProperty("pause", MPVLib.MPV_FORMAT_FLAG);
                MPVLib.observeProperty("eof-reached", MPVLib.MPV_FORMAT_FLAG);
                MPVLib.observeProperty("dwidth", MPVLib.MPV_FORMAT_INT64);
                MPVLib.observeProperty("dheight", MPVLib.MPV_FORMAT_INT64);
                MPVLib.observeProperty("video-codec", MPVLib.MPV_FORMAT_STRING);
                MPVLib.observeProperty("audio-codec-name", MPVLib.MPV_FORMAT_STRING);
                MPVLib.observeProperty("video-params/gamma", MPVLib.MPV_FORMAT_STRING);
                MPVLib.observeProperty("hwdec-current", MPVLib.MPV_FORMAT_STRING);
                MPVLib.observeProperty("sub-text", MPVLib.MPV_FORMAT_STRING);
                MPVLib.observeProperty("paused-for-cache", MPVLib.MPV_FORMAT_FLAG);
                MPVLib.observeProperty("cache-buffering-state", MPVLib.MPV_FORMAT_INT64);
                MPVLib.observeProperty("cache-speed", MPVLib.MPV_FORMAT_INT64);
            } catch (Throwable error) {
                releaseInternal();
                if (error instanceof RuntimeException) throw (RuntimeException) error;
                throw new IllegalStateException("MPV initialization failed", error);
            }
        }
    }

    private static File extractAnime4kShader(Context context) {
        File dir = new File(context.getCacheDir(), "shaders");
        if (!dir.exists() && !dir.mkdirs()) return null;
        File out = new File(dir, "Anime4K_Upscale_CNN_x2_S.glsl");
        if (out.isFile() && out.length() > 1024L) return out;
        try (InputStream in = context.getAssets().open(ANIME4K_ASSET);
                FileOutputStream fos = new FileOutputStream(out)) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) >= 0) {
                if (n > 0) fos.write(buf, 0, n);
            }
            return out;
        } catch (Exception error) {
            AppLog.w("MpvPlayer", "failed to extract Anime4K shader", error);
            return null;
        }
    }

    private void notifyVideoSize() {
        final int w = width;
        final int h = height;
        if (w <= 0 || h <= 0) return;
        main.post(
                () -> {
                    if (!released && sizeListener != null) {
                        sizeListener.onVideoSizeChanged(MpvPlayer.this, w, h);
                    }
                });
    }

    private void syncVideoDimensions() {
        if (released || !initialized) return;
        Integer w = MPVLib.getPropertyInt("dwidth");
        Integer h = MPVLib.getPropertyInt("dheight");
        if (w == null || w <= 0) w = MPVLib.getPropertyInt("width");
        if (h == null || h <= 0) h = MPVLib.getPropertyInt("height");
        if (w != null && w > 0 && h != null && h > 0) {
            width = w;
            height = h;
            if (sizeListener != null) sizeListener.onVideoSizeChanged(MpvPlayer.this, w, h);
        }
    }

    private void handleFileLoaded() {
        if (released || !initialized) return;
        prepared = true;
        if (prepareStarted > 0 && firstFrameMs < 0) {
            firstFrameMs = SystemClock.elapsedRealtime() - prepareStarted;
        }
        syncVideoDimensions();
        try {
            if (Math.abs(speed - 1.0f) > 0.01f) {
                MPVLib.setPropertyDouble("speed", (double) speed);
            }
            MPVLib.setPropertyString("loop-file", repeatOne ? "inf" : "no");
            JSONObject extra = options.optJSONObject("extra");
            String extraAudio = extra == null ? "" : extra.optString("audio");
            if (Cms.isHttp(extraAudio)) {
                MPVLib.command(new String[] {"audio-add", extraAudio, "select"});
            }
            JSONArray subtitles = options.optJSONArray("subtitles");
            if (subtitles != null) {
                for (int i = 0; i < subtitles.length(); i++) {
                    JSONObject sub = subtitles.optJSONObject(i);
                    if (sub == null) continue;
                    String subUrl = sub.optString("url", "").trim();
                    if (!subUrl.isEmpty()) {
                        String resolvedSub = resolveMpvTarget(Uri.parse(subUrl));
                        if (!resolvedSub.isEmpty()) {
                            MPVLib.command(
                                    new String[] {
                                        "sub-add", resolvedSub, i == 0 ? "select" : "auto"
                                    });
                        }
                    }
                }
            }
            if (wantPlay) {
                MPVLib.setPropertyBoolean("pause", Boolean.FALSE);
            }
        } catch (Exception error) {
            AppLog.w("MpvPlayer", "post-load setup failed", error);
        }
        if (preparedListener != null) {
            preparedListener.onPrepared(MpvPlayer.this);
        }
        if (audioTracksChangedListener != null) {
            audioTracksChangedListener.onAudioTracksChanged();
        }
        if (textTracksChangedListener != null) {
            textTracksChangedListener.onTextTracksChanged();
        }
    }

    private void handleEndFile() {
        if (released) return;
        if (prepared) {
            if (eofReached && completionListener != null) {
                completionListener.onCompletion(MpvPlayer.this);
            }
            return;
        }
        if ("mediacodec".equalsIgnoreCase(hwdecCurrent) && !videoCodec.isEmpty()) {
            String updated =
                    addUnsafeCodec(prefs.getString(Prefs.MPV_UNSAFE_DIRECT_CODECS, ""), videoCodec);
            prefs.edit().putString(Prefs.MPV_UNSAFE_DIRECT_CODECS, updated).apply();
        }
        lastError = "MPV_LOAD_FAILED";
        if (errorListener != null) {
            errorListener.onError(MpvPlayer.this, -1, 0);
        }
    }

    @Override
    public void setAudioAttributes(AudioAttributes attributes) {
        // Audio routing and focus are handled through AudioManager in start()/release().
    }

    @Override
    public void bindSubtitles(final SubtitleOverlayView view, final SubtitleListener textCallback) {
        // libmpv renders styled ASS/SRT/PGS subtitles natively on its GPU output.
        if (view != null) {
            view.setCues(Collections.emptyList());
        }
        setSubtitleListener(textCallback);
    }

    @Override
    public void setDataSource(Context unused, Uri uri, Map<String, String> requestHeaders) {
        onMain(
                () -> {
                    checkState();
                    mediaUri = uri;
                    headers = Collections.unmodifiableMap(new LinkedHashMap<>(requestHeaders));
                    return null;
                });
    }

    @Override
    public void setSurface(Surface surface) {
        onMain(
                () -> {
                    if (released || !initialized) return null;
                    if (surface != null && surface.isValid()) {
                        if (surfaceAttached && attachedSurface == surface) {
                            return null;
                        }
                        if (surfaceAttached) {
                            MPVLib.setPropertyString("vo", "null");
                            MPVLib.detachSurface();
                            surfaceAttached = false;
                            attachedSurface = null;
                        }
                        MPVLib.attachSurface(surface);
                        attachedSurface = surface;
                        surfaceAttached = true;
                        MPVLib.setPropertyString("vo", configuredVo);
                    } else if (surfaceAttached) {
                        MPVLib.setPropertyString("vo", "null");
                        MPVLib.detachSurface();
                        surfaceAttached = false;
                        attachedSurface = null;
                    }
                    return null;
                });
    }

    @Override
    public void setSurfaceSize(int width, int height) {
        if (width <= 0 || height <= 0) return;
        onMain(
                () -> {
                    if (!released && initialized) {
                        MPVLib.setPropertyString("android-surface-size", width + "x" + height);
                    }
                    return null;
                });
    }

    @Override
    public void setOnPreparedListener(OnPreparedListener listener) {
        onMain(
                () -> {
                    preparedListener = listener;
                    return null;
                });
    }

    @Override
    public void setOnCompletionListener(OnCompletionListener listener) {
        onMain(
                () -> {
                    completionListener = listener;
                    return null;
                });
    }

    @Override
    public void setOnVideoSizeChangedListener(OnVideoSizeChangedListener listener) {
        onMain(
                () -> {
                    sizeListener = listener;
                    return null;
                });
    }

    @Override
    public void setOnErrorListener(OnErrorListener listener) {
        onMain(
                () -> {
                    errorListener = listener;
                    return null;
                });
    }

    @Override
    public void setOnHdrChangedListener(OnHdrChangedListener listener) {
        onMain(
                () -> {
                    hdrChangedListener = listener;
                    if (listener != null && isHdrVideo()) {
                        listener.onHdrChanged(true);
                    }
                    return null;
                });
    }

    @Override
    public void setOnTextTracksChangedListener(OnTextTracksChangedListener listener) {
        onMain(
                () -> {
                    textTracksChangedListener = listener;
                    return null;
                });
    }

    @Override
    public void setOnAudioTracksChangedListener(OnAudioTracksChangedListener listener) {
        onMain(
                () -> {
                    audioTracksChangedListener = listener;
                    return null;
                });
    }

    @Override
    public boolean isHdrVideo() {
        return !released && isHdrGammaOrCodec(videoGamma, videoCodec);
    }

    @Override
    public String activeVideoMimeType() {
        return released ? "" : normalizeVideoMime(videoCodec);
    }

    @Override
    public void setSubtitleListener(SubtitleListener listener) {
        onMain(
                () -> {
                    subtitleListener = listener;
                    return null;
                });
    }

    @Override
    public void setCuesListener(CueListener listener) {}

    @Override
    public void setOptions(JSONObject metadata) {
        onMain(
                () -> {
                    checkState();
                    options = new JSONObject(metadata.toString());
                    JSONObject drm = options.optJSONObject("drm");
                    String scheme =
                            drm == null
                                    ? options.optString("drmScheme")
                                    : drm.optString("scheme", drm.optString("type"));
                    if (!scheme.isEmpty()) {
                        throw new IllegalArgumentException("此 DRM 来源请使用 Media3 播放器");
                    }
                    return null;
                });
    }

    @Override
    public long networkSpeedBytesPerSec() {
        return cacheSpeedBytesPerSec;
    }

    @Override
    public void prepareAsync() {
        onMain(
                () -> {
                    checkState();
                    if (mediaUri == null) throw new IllegalStateException("No media item");
                    prepared = false;
                    eofReached = false;
                    positionSec = 0;
                    durationSec = 0;
                    firstFrameMs = -1;
                    prepareStarted = SystemClock.elapsedRealtime();

                    String userAgent = defaultUserAgent(context);
                    String referer = "";
                    MPVLib.setPropertyString("http-header-fields", "");
                    for (Map.Entry<String, String> entry : headers.entrySet()) {
                        String key = entry.getKey();
                        String value = entry.getValue();
                        if (key == null || value == null || value.isEmpty()) continue;
                        if (key.equalsIgnoreCase("User-Agent")) {
                            userAgent = value;
                        } else if (key.equalsIgnoreCase("Referer")) {
                            referer = value;
                        } else if (!key.equalsIgnoreCase("Host")) {
                            MPVLib.command(
                                    new String[] {
                                        "change-list",
                                        "http-header-fields",
                                        "append",
                                        key + ": " + value
                                    });
                        }
                    }
                    MPVLib.setPropertyString("user-agent", userAgent);
                    if (!referer.isEmpty()) {
                        MPVLib.setPropertyString("referrer", referer);
                    }
                    MPVLib.setPropertyBoolean("pause", Boolean.TRUE);
                    String targetPath = resolveMpvTarget(mediaUri);
                    MPVLib.command(new String[] {"loadfile", targetPath, "replace"});
                    return null;
                });
    }

    private static String resolveMpvTarget(Uri uri) {
        if (uri == null) return "";
        String scheme = uri.getScheme();
        if ("file".equalsIgnoreCase(scheme)) {
            String path = uri.getPath();
            if (path != null && !path.isEmpty()) return path;
        }
        if ("content".equalsIgnoreCase(scheme)) {
            String bridged = LocalProxy.registerContentUri(uri);
            if (!bridged.isEmpty()) return bridged;
        }
        return uri.toString();
    }

    @Override
    public void start() {
        onMain(
                () -> {
                    checkState();
                    wantPlay = true;
                    if (audio != null && !focusHeld) {
                        focusHeld =
                                audio.requestAudioFocus(
                                                focusChange,
                                                AudioManager.STREAM_MUSIC,
                                                AudioManager.AUDIOFOCUS_GAIN)
                                        == AudioManager.AUDIOFOCUS_REQUEST_GRANTED;
                    }
                    MPVLib.setPropertyBoolean("pause", Boolean.FALSE);
                    paused = false;
                    return null;
                });
    }

    @Override
    public void pause() {
        onMain(
                () -> {
                    wantPlay = false;
                    if (!released && initialized) {
                        MPVLib.setPropertyBoolean("pause", Boolean.TRUE);
                        paused = true;
                    }
                    return null;
                });
    }

    @Override
    public void seekTo(int ms) {
        onMain(
                () -> {
                    checkState();
                    double seconds = Math.max(0, ms) / 1000.0;
                    MPVLib.command(
                            new String[] {
                                "seek", String.format(Locale.ROOT, "%.3f", seconds), "absolute"
                            });
                    positionSec = seconds;
                    return null;
                });
    }

    @Override
    public boolean isPlaying() {
        return !released && prepared && !paused;
    }

    @Override
    public int getCurrentPosition() {
        return released
                ? 0
                : (int) Math.min(Integer.MAX_VALUE, Math.max(0L, Math.round(positionSec * 1000.0)));
    }

    @Override
    public int getDuration() {
        return released
                ? 0
                : (int) Math.min(Integer.MAX_VALUE, Math.max(0L, Math.round(durationSec * 1000.0)));
    }

    @Override
    public int getVideoWidth() {
        return released ? 0 : width;
    }

    @Override
    public int getVideoHeight() {
        return released ? 0 : height;
    }

    @Override
    public int getAudioSessionId() {
        return 0;
    }

    public void applyLoudnessBoost(int boostDb) {
        onMain(
                () -> {
                    if (!released && initialized) {
                        int clamped = Math.max(0, Math.min(15, boostDb));
                        MPVLib.setPropertyInt("volume", Math.min(200, 100 + clamped * 6));
                    }
                    return null;
                });
    }

    @Override
    public long getFirstFrameMs() {
        return firstFrameMs > 0 ? firstFrameMs : -1L;
    }

    @Override
    public String getLastError() {
        return lastError;
    }

    @Override
    public String getFailureMessage(int code) {
        return "MPV 引擎未能播放当前流。可切换 Media3 或刷新线路重试。";
    }

    @Override
    public String videoResolution() {
        if (released || width <= 0 || height <= 0) return "分辨率未知";
        int longEdge = Math.max(width, height);
        String tier =
                longEdge >= 3800
                        ? "4K "
                        : longEdge >= 2500
                                ? "2K "
                                : longEdge >= 1900 ? "1080P " : longEdge >= 1200 ? "720P " : "";
        StringBuilder sb = new StringBuilder();
        sb.append(tier).append(width).append(" × ").append(height);
        if (!videoCodec.isEmpty()) sb.append(" · ").append(videoCodec.toUpperCase(Locale.ROOT));
        if (!audioCodec.isEmpty()) sb.append(" · ").append(audioCodec.toUpperCase(Locale.ROOT));
        sb.append(" · MPV");
        if (anime4kActive) sb.append(" Anime4K");
        return sb.toString();
    }

    @Override
    public List<String> mediaBadges() {
        if (released) return Collections.emptyList();
        return buildMediaBadges(
                width, height, videoCodec, audioCodec, videoGamma, hwdecCurrent, anime4kActive);
    }

    @Override
    public JSONObject decoderDiagnostics() {
        JSONObject info = new JSONObject();
        try {
            info.put("engine", "mpv");
            info.put("vo", configuredVo);
            info.put("hwdec", hwdecCurrent.isEmpty() ? configuredHwdec : hwdecCurrent);
            info.put("video_decoder", hwdecCurrent.isEmpty() ? configuredHwdec : hwdecCurrent);
            info.put("audio_decoder", audioCodec);
            info.put("video_mime", videoCodec);
            info.put("audio_mime", audioCodec);
            info.put("width", width);
            info.put("height", height);
            info.put("anime4k", anime4kActive);
            info.put("hdr_tone_mapping", hdrToneMappingActive);
            info.put("first_frame_ms", firstFrameMs);
        } catch (Exception ignored) {
        }
        return info;
    }

    @Override
    public String playbackInfo() {
        StringBuilder sb = new StringBuilder("MPV (");
        sb.append(configuredVo).append(")\n视频：");
        sb.append(videoCodec.isEmpty() ? "尚未识别" : videoCodec)
                .append(" · ")
                .append(hwdecCurrent.isEmpty() ? configuredHwdec : hwdecCurrent)
                .append("\n音频：")
                .append(audioCodec.isEmpty() ? "尚未识别" : audioCodec)
                .append("\n")
                .append(width)
                .append(" × ")
                .append(height);
        if (hdrToneMappingActive) sb.append("\nHDR 映射：libplacebo 自动峰值色调映射");
        if (anime4kActive) sb.append("\n超分滤镜：Anime4K CNN x2");
        if (!lastError.isEmpty()) sb.append("\n").append(lastError);
        return sb.toString();
    }

    @Override
    public void addExternalSubtitle(Uri subtitle, String name, String mime) {
        onMain(
                () -> {
                    checkState();
                    if (subtitle != null) {
                        MPVLib.command(new String[] {"sub-add", subtitle.toString(), "select"});
                    }
                    return null;
                });
    }

    @Override
    public void setSpeed(float value) {
        onMain(
                () -> {
                    checkState();
                    speed = Math.max(0.25f, Math.min(4.0f, value));
                    MPVLib.setPropertyDouble("speed", (double) speed);
                    return null;
                });
    }

    @Override
    public float getSpeed() {
        return speed;
    }

    @Override
    public void setRepeatOne(boolean repeat) {
        onMain(
                () -> {
                    checkState();
                    repeatOne = repeat;
                    MPVLib.setPropertyString("loop-file", repeat ? "inf" : "no");
                    return null;
                });
    }

    private String mpvTrackType(int type) {
        if (type == C.TRACK_TYPE_VIDEO) return "video";
        if (type == C.TRACK_TYPE_AUDIO) return "audio";
        if (type == C.TRACK_TYPE_TEXT) return "sub";
        return "";
    }

    private List<JSONObject> mpvTracks(int type) {
        List<JSONObject> out = new ArrayList<>();
        String target = mpvTrackType(type);
        if (target.isEmpty() || released || !initialized) return out;
        try {
            String raw = MPVLib.getPropertyString("track-list");
            if (raw == null || raw.isEmpty()) return out;
            JSONArray array = new JSONArray(raw);
            for (int i = 0; i < array.length(); i++) {
                JSONObject item = array.optJSONObject(i);
                if (item != null && target.equals(item.optString("type"))) {
                    out.add(item);
                }
            }
        } catch (Exception ignored) {
        }
        return out;
    }

    @Override
    public List<String> trackLabels(int type) {
        return onMain(
                () -> {
                    List<String> labels = new ArrayList<>();
                    List<JSONObject> tracks = mpvTracks(type);
                    for (int i = 0; i < tracks.size(); i++) {
                        JSONObject t = tracks.get(i);
                        boolean selected = t.optBoolean("selected", false);
                        String title = t.optString("title", "").trim();
                        String lang = t.optString("lang", "").trim();
                        String codec = t.optString("codec", "").trim();
                        String label;
                        if (type == C.TRACK_TYPE_VIDEO) {
                            int w = t.optInt("demux-w", 0);
                            int h = t.optInt("demux-h", 0);
                            label = w > 0 && h > 0 ? (w + "×" + h) : ("视频轨 " + (i + 1));
                            if (!codec.isEmpty()) label += " · " + codec.toUpperCase(Locale.ROOT);
                        } else {
                            label =
                                    !title.isEmpty()
                                            ? title
                                            : (!lang.isEmpty() ? lang : "轨道 " + (i + 1));
                            int ch = t.optInt("demux-channel-count", 0);
                            if (ch > 0) label += " · " + ch + " 声道";
                            if (!codec.isEmpty()) label += " · " + codec.toUpperCase(Locale.ROOT);
                        }
                        labels.add((selected ? "✓ " : "") + label);
                    }
                    return labels;
                });
    }

    @Override
    public void selectTrack(int type, int index) {
        onMain(
                () -> {
                    checkState();
                    String prop =
                            type == C.TRACK_TYPE_VIDEO
                                    ? "vid"
                                    : type == C.TRACK_TYPE_AUDIO
                                            ? "aid"
                                            : type == C.TRACK_TYPE_TEXT ? "sid" : "";
                    if (prop.isEmpty()) return null;
                    if (index == -2) {
                        MPVLib.setPropertyString(prop, "no");
                    } else if (index < 0) {
                        MPVLib.setPropertyString(prop, "auto");
                    } else {
                        List<JSONObject> tracks = mpvTracks(type);
                        if (index < tracks.size()) {
                            int id = tracks.get(index).optInt("id", index + 1);
                            MPVLib.setPropertyString(prop, String.valueOf(id));
                        }
                    }
                    return null;
                });
    }

    @Override
    public void release() {
        onMain(
                () -> {
                    releaseInternal();
                    return null;
                });
    }

    private void releaseInternal() {
        if (released) return;
        released = true;
        markBaseReleased();
        prepared = false;
        main.removeCallbacksAndMessages(null);
        if (audio != null && focusHeld) {
            audio.abandonAudioFocus(focusChange);
            focusHeld = false;
        }
        if (initialized) {
            initialized = false;
            try {
                MPVLib.removeObserver(observer);
            } catch (Throwable ignored) {
            }
            try {
                MPVLib.setPropertyBoolean("pause", Boolean.TRUE);
            } catch (Throwable ignored) {
            }
            if (surfaceAttached) {
                surfaceAttached = false;
                attachedSurface = null;
                try {
                    MPVLib.setPropertyString("vo", "null");
                } catch (Throwable ignored) {
                }
                try {
                    MPVLib.detachSurface();
                } catch (Throwable ignored) {
                }
            }
        }
        if (activeInstance == this) {
            activeInstance = null;
        }
        if (nativeCreated) {
            nativeCreated = false;
            // Offload blocking native MPVLib.destroy() off the Android UI thread (prevents ANR
            // when libmpv is waiting on a stalled demuxer socket), while serializing against the
            // next MPVLib.create() via MPV_NATIVE_LOCK + pendingNativeDestroy.
            pendingNativeDestroy =
                    MPV_DESTROY_POOL.submit(
                            () -> {
                                synchronized (MPV_NATIVE_LOCK) {
                                    try {
                                        MPVLib.destroy();
                                    } catch (Throwable ignored) {
                                    }
                                }
                            });
        }
    }

    private void checkState() {
        if (released || !initialized) throw new IllegalStateException("MPV player released");
    }

    private <T> T onMain(Callable<T> work) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            try {
                return work.call();
            } catch (RuntimeException e) {
                throw e;
            } catch (Exception e) {
                throw new IllegalStateException(e);
            }
        }
        FutureTask<T> task = new FutureTask<>(work);
        if (!main.post(task)) throw new IllegalStateException("Main looper unavailable");
        try {
            return task.get(15, TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("MPV call interrupted", e);
        } catch (ExecutionException e) {
            Throwable cause = e.getCause();
            if (cause instanceof RuntimeException) throw (RuntimeException) cause;
            throw new IllegalStateException(cause);
        } catch (java.util.concurrent.TimeoutException e) {
            task.cancel(false);
            throw new IllegalStateException("MPV UI thread timed out", e);
        }
    }
}
