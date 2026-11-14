package com.pilipala.marcomovie;

import android.content.Context;
import android.media.MediaCodecInfo.CodecCapabilities;
import android.media.MediaCrypto;
import android.media.MediaFormat;
import android.os.Build;
import android.os.Handler;
import androidx.media3.common.C;
import androidx.media3.common.ColorInfo;
import androidx.media3.common.Format;
import androidx.media3.common.MimeTypes;
import androidx.media3.exoplayer.DecoderReuseEvaluation;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlaybackException;
import androidx.media3.exoplayer.FormatHolder;
import androidx.media3.exoplayer.Renderer;
import androidx.media3.exoplayer.RendererCapabilities;
import androidx.media3.exoplayer.mediacodec.MediaCodecAdapter;
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo;
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector;
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil;
import androidx.media3.exoplayer.video.MediaCodecVideoRenderer;
import androidx.media3.exoplayer.video.VideoRendererEventListener;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Keep audio extensions available even when hardware-only video is requested. */
final class DecoderRenderersFactory extends DefaultRenderersFactory {
    private static final Pattern DV_CODEC_PROFILE_PATTERN =
            Pattern.compile("(?:dvhe|dvh1|dvav|dva1|dav1)\\.0?(\\d+)", Pattern.CASE_INSENSITIVE);

    private final Context appContext;
    private final int mode;

    DecoderRenderersFactory(Context context, int decoderMode) {
        super(context);
        DecoderSupport.configure();
        appContext = context.getApplicationContext();
        mode = decoderMode;
        setEnableDecoderFallback(true);
        setExtensionRendererMode(
                (mode == 2
                                || mode == 3
                                || context.getSharedPreferences(Prefs.FILE, 0)
                                        .getBoolean(Prefs.SOFTWARE_AUDIO, false))
                        ? EXTENSION_RENDERER_MODE_PREFER
                        : EXTENSION_RENDERER_MODE_ON);
    }

    static boolean isSoftwareCodec(MediaCodecInfo info) {
        if (info == null) return false;
        if (info.softwareOnly) return true;
        String lower = info.name == null ? "" : info.name.toLowerCase(Locale.ROOT);
        return lower.startsWith("omx.google.")
                || lower.startsWith("c2.android.")
                || lower.contains("ffmpeg")
                || lower.contains("libvpx")
                || lower.contains("dav1d");
    }

    private static boolean isDolbyVisionConfigRecord(byte[] buf) {
        // ISO/MKV dvcC / dvvC record starts with dv_version_major=1, dv_version_minor=0.
        // In contrast, hvcC byte[1] carries general_profile_idc (>=1 for Main/Main10).
        return buf != null && buf.length >= 4 && buf.length <= 64 && buf[0] == 1 && buf[1] == 0;
    }

    static int extractDolbyVisionProfile(Format format) {
        if (format == null) return -1;
        if (format.codecs != null && !format.codecs.isEmpty()) {
            Matcher m = DV_CODEC_PROFILE_PATTERN.matcher(format.codecs);
            if (m.find()) {
                try {
                    return Integer.parseInt(m.group(1));
                } catch (NumberFormatException ignored) {
                }
            }
        }
        if (format.initializationData != null) {
            for (byte[] buf : format.initializationData) {
                if (isDolbyVisionConfigRecord(buf)) {
                    return (buf[2] & 0xFE) >> 1;
                }
            }
        }
        return MimeTypes.VIDEO_DOLBY_VISION.equals(format.sampleMimeType) ? 0 : -1;
    }

    static int extractDolbyVisionCompatibilityId(Format format) {
        if (format == null || format.initializationData == null) return -1;
        for (byte[] buf : format.initializationData) {
            if (isDolbyVisionConfigRecord(buf) && buf.length >= 5) {
                return (buf[4] & 0xF0) >> 4;
            }
        }
        return -1;
    }

    static boolean isDolbyVisionProfile5(Format format) {
        return extractDolbyVisionProfile(format) == 5;
    }

    private static Format ensureDolbyVisionMime(Format format) {
        if (format == null || MimeTypes.VIDEO_DOLBY_VISION.equals(format.sampleMimeType)) {
            return format;
        }
        return format.buildUpon().setSampleMimeType(MimeTypes.VIDEO_DOLBY_VISION).build();
    }

    static boolean hasNativeDolbyVisionDecoder() {
        return hasNativeDolbyVisionDecoder(null);
    }

    static boolean hasNativeDolbyVisionDecoder(Format format) {
        try {
            Format dvFormat = format != null ? ensureDolbyVisionMime(format) : null;
            boolean requireProfile5 = dvFormat != null && isDolbyVisionProfile5(dvFormat);
            for (MediaCodecInfo info :
                    MediaCodecUtil.getDecoderInfos(MimeTypes.VIDEO_DOLBY_VISION, false, false)) {
                if (!info.hardwareAccelerated || isSoftwareCodec(info)) continue;
                if (!requireProfile5) return true;
                try {
                    if (info.isFormatSupported(dvFormat)) return true;
                } catch (Throwable ignored) {
                }
                // Check CodecProfileLevel for DolbyVisionProfileDvheStn (0x20 = Profile 5)
                android.media.MediaCodecInfo.CodecProfileLevel[] levels = info.getProfileLevels();
                if (levels == null || levels.length == 0) {
                    return true;
                }
                for (android.media.MediaCodecInfo.CodecProfileLevel pl : levels) {
                    if (pl != null && pl.profile == 0x20) {
                        return true;
                    }
                }
            }
        } catch (Throwable ignored) {
        }
        return false;
    }

    static ColorInfo normalizeBaseLayerColorInfo(
            ColorInfo existing, int dvProfile, int compatibilityId) {
        int defaultSpace = C.COLOR_SPACE_BT2020;
        int defaultTransfer = C.COLOR_TRANSFER_ST2084;
        if (dvProfile == 4 || compatibilityId == 2) {
            defaultSpace = C.COLOR_SPACE_BT709;
            defaultTransfer = C.COLOR_TRANSFER_SDR;
        } else if (compatibilityId == 4) {
            defaultSpace = C.COLOR_SPACE_BT2020;
            defaultTransfer = C.COLOR_TRANSFER_HLG;
        }
        if (existing == null) {
            return new ColorInfo.Builder()
                    .setColorSpace(defaultSpace)
                    .setColorRange(C.COLOR_RANGE_LIMITED)
                    .setColorTransfer(defaultTransfer)
                    .build();
        }
        boolean missingSpace = existing.colorSpace == Format.NO_VALUE;
        boolean missingTransfer = existing.colorTransfer == Format.NO_VALUE;
        boolean missingRange = existing.colorRange == Format.NO_VALUE;
        if (!missingSpace && !missingTransfer && !missingRange) {
            return existing;
        }
        return existing.buildUpon()
                .setColorSpace(missingSpace ? defaultSpace : existing.colorSpace)
                .setColorRange(missingRange ? C.COLOR_RANGE_LIMITED : existing.colorRange)
                .setColorTransfer(missingTransfer ? defaultTransfer : existing.colorTransfer)
                .build();
    }

    static Format toBaseLayerFormat(Format format) {
        if (format == null) return null;
        // Dolby Vision Profile 5 uses proprietary IPT-PQ-C2 without an HEVC YCbCr base layer.
        // Converting it to video/hevc causes severe green/magenta color corruption on all TVs.
        if (isDolbyVisionProfile5(format)) {
            return ensureDolbyVisionMime(format);
        }
        if (!MimeTypes.VIDEO_DOLBY_VISION.equals(format.sampleMimeType)) {
            return format;
        }
        String codecsLower = format.codecs == null ? "" : format.codecs.toLowerCase(Locale.ROOT);
        String altMime =
                codecsLower.startsWith("dav1")
                        ? MimeTypes.VIDEO_AV1
                        : (codecsLower.startsWith("dvav")
                                        || codecsLower.startsWith("dva1")
                                        || codecsLower.startsWith("avc"))
                                ? MimeTypes.VIDEO_H264
                                : MimeTypes.VIDEO_H265;
        List<byte[]> initData = format.initializationData;
        if (initData != null && !initData.isEmpty()) {
            List<byte[]> filtered = new ArrayList<>(initData.size());
            for (byte[] buf : initData) {
                if (!isDolbyVisionConfigRecord(buf)) {
                    filtered.add(buf);
                }
            }
            if (!filtered.isEmpty()) {
                initData = filtered;
            } else if (initData.size() > 1 && MimeTypes.VIDEO_H265.equals(altMime)) {
                initData = Collections.singletonList(initData.get(0));
            }
        }
        int dvProfile = extractDolbyVisionProfile(format);
        int compatId = extractDolbyVisionCompatibilityId(format);
        ColorInfo normalizedColor =
                normalizeBaseLayerColorInfo(format.colorInfo, dvProfile, compatId);
        return format.buildUpon()
                .setSampleMimeType(altMime)
                .setCodecs(null)
                .setColorInfo(normalizedColor)
                .setInitializationData(initData != null ? initData : Collections.emptyList())
                .build();
    }

    static Format fallbackVideoFormat(Format format) {
        if (format == null) return null;
        if (isDolbyVisionProfile5(format)) {
            return ensureDolbyVisionMime(format);
        }
        if (!MimeTypes.VIDEO_DOLBY_VISION.equals(format.sampleMimeType)) {
            return format;
        }
        if (hasNativeDolbyVisionDecoder(format)) {
            return format;
        }
        return toBaseLayerFormat(format);
    }

    static List<MediaCodecInfo> prioritizeHardwareDecoders(List<MediaCodecInfo> decoders) {
        if (decoders == null || decoders.size() <= 1) return decoders;
        List<MediaCodecInfo> hw = new ArrayList<>(decoders.size());
        List<MediaCodecInfo> sw = new ArrayList<>();
        for (MediaCodecInfo info : decoders) {
            if (isSoftwareCodec(info)) sw.add(info);
            else hw.add(info);
        }
        if (hw.isEmpty() || sw.isEmpty()) return decoders;
        hw.addAll(sw);
        return hw;
    }

    private static void appendUnique(List<MediaCodecInfo> target, List<MediaCodecInfo> additions) {
        if (additions == null) return;
        for (MediaCodecInfo info : additions) {
            if (info == null) continue;
            boolean exists = false;
            for (MediaCodecInfo c : target) {
                if (c.name.equals(info.name)) {
                    exists = true;
                    break;
                }
            }
            if (!exists) target.add(info);
        }
    }

    @Override
    protected void buildVideoRenderers(
            Context context,
            int extensionMode,
            MediaCodecSelector selector,
            boolean fallback,
            Handler handler,
            VideoRendererEventListener listener,
            long joiningMs,
            ArrayList<Renderer> out) {
        int effectiveMode =
                mode == 1
                        ? EXTENSION_RENDERER_MODE_OFF
                        : mode == 2 ? EXTENSION_RENDERER_MODE_PREFER : EXTENSION_RENDERER_MODE_ON;
        super.buildVideoRenderers(
                context, effectiveMode, selector, fallback, handler, listener, joiningMs, out);
        MediaCodecVideoRenderer doviFallbackRenderer =
                new MediaCodecVideoRenderer(
                        context,
                        getCodecAdapterFactory(),
                        selector,
                        joiningMs,
                        fallback,
                        handler,
                        listener,
                        MAX_DROPPED_VIDEO_FRAME_COUNT_TO_NOTIFY) {
                    @Override
                    protected int supportsFormat(
                            MediaCodecSelector mediaCodecSelector, Format format)
                            throws MediaCodecUtil.DecoderQueryException {
                        if (format != null && isDolbyVisionProfile5(format)) {
                            Format dvFormat = ensureDolbyVisionMime(format);
                            if (mode == 2 || !hasNativeDolbyVisionDecoder(dvFormat)) {
                                return RendererCapabilities.create(C.FORMAT_UNSUPPORTED_SUBTYPE);
                            }
                            return super.supportsFormat(mediaCodecSelector, dvFormat);
                        }
                        if (format != null
                                && MimeTypes.VIDEO_DOLBY_VISION.equals(format.sampleMimeType)) {
                            if (mode == 2 || !hasNativeDolbyVisionDecoder(format)) {
                                return super.supportsFormat(
                                        mediaCodecSelector, toBaseLayerFormat(format));
                            }
                            int dvSupport = super.supportsFormat(mediaCodecSelector, format);
                            if ((dvSupport & 7) >= C.FORMAT_HANDLED) {
                                return dvSupport;
                            }
                            int baseSupport =
                                    super.supportsFormat(
                                            mediaCodecSelector, toBaseLayerFormat(format));
                            return (baseSupport & 7) > (dvSupport & 7) ? baseSupport : dvSupport;
                        }
                        return super.supportsFormat(mediaCodecSelector, format);
                    }

                    @Override
                    protected List<MediaCodecInfo> getDecoderInfos(
                            MediaCodecSelector mediaCodecSelector,
                            Format format,
                            boolean requiresSecureDecoder)
                            throws MediaCodecUtil.DecoderQueryException {
                        if (format != null && isDolbyVisionProfile5(format)) {
                            Format dvFormat = ensureDolbyVisionMime(format);
                            if (mode == 2 || !hasNativeDolbyVisionDecoder(dvFormat)) {
                                return Collections.emptyList();
                            }
                            List<MediaCodecInfo> dvOnly = new ArrayList<>();
                            for (MediaCodecInfo info :
                                    super.getDecoderInfos(
                                            mediaCodecSelector, dvFormat, requiresSecureDecoder)) {
                                if (MimeTypes.VIDEO_DOLBY_VISION.equals(info.mimeType)
                                        && !isSoftwareCodec(info)) {
                                    dvOnly.add(info);
                                }
                            }
                            return dvOnly;
                        }
                        if (format != null
                                && MimeTypes.VIDEO_DOLBY_VISION.equals(format.sampleMimeType)) {
                            List<MediaCodecInfo> combined = new ArrayList<>();
                            if (mode != 2 && hasNativeDolbyVisionDecoder(format)) {
                                try {
                                    for (MediaCodecInfo info :
                                            super.getDecoderInfos(
                                                    mediaCodecSelector,
                                                    format,
                                                    requiresSecureDecoder)) {
                                        if (MimeTypes.VIDEO_DOLBY_VISION.equals(info.mimeType)) {
                                            combined.add(info);
                                        }
                                    }
                                } catch (Throwable ignored) {
                                }
                            }
                            try {
                                appendUnique(
                                        combined,
                                        super.getDecoderInfos(
                                                mediaCodecSelector,
                                                toBaseLayerFormat(format),
                                                requiresSecureDecoder));
                            } catch (Throwable ignored) {
                            }
                            if (!combined.isEmpty()) {
                                return mode == 2 ? combined : prioritizeHardwareDecoders(combined);
                            }
                        }
                        Format resolvedFormat = fallbackVideoFormat(format);
                        List<MediaCodecInfo> decoders =
                                new ArrayList<>(
                                        super.getDecoderInfos(
                                                mediaCodecSelector,
                                                resolvedFormat,
                                                requiresSecureDecoder));
                        if (mode != 2
                                && resolvedFormat != null
                                && resolvedFormat.codecs != null
                                && (MimeTypes.VIDEO_H265.equals(resolvedFormat.sampleMimeType)
                                        || MimeTypes.VIDEO_H264.equals(
                                                resolvedFormat.sampleMimeType))) {
                            // Ensure hardware decoders omitted due to conservative vendor XML
                            // Main10/level declarations are still attempted ahead of c2.android.*
                            try {
                                Format relaxed = resolvedFormat.buildUpon().setCodecs(null).build();
                                appendUnique(
                                        decoders,
                                        super.getDecoderInfos(
                                                mediaCodecSelector,
                                                relaxed,
                                                requiresSecureDecoder));
                            } catch (Throwable ignored) {
                            }
                        }
                        return mode == 2 ? decoders : prioritizeHardwareDecoders(decoders);
                    }

                    @Override
                    protected DecoderReuseEvaluation canReuseCodec(
                            MediaCodecInfo codecInfo, Format oldFormat, Format newFormat) {
                        DecoderReuseEvaluation eval =
                                super.canReuseCodec(codecInfo, oldFormat, newFormat);
                        if (eval.result == DecoderReuseEvaluation.REUSE_RESULT_NO
                                && (eval.discardReasons
                                                & ~DecoderReuseEvaluation
                                                        .DISCARD_REASON_VIDEO_COLOR_INFO_CHANGED)
                                        == 0
                                && oldFormat.colorInfo != null
                                && newFormat.colorInfo != null
                                && ColorInfo.isTransferHdr(newFormat.colorInfo)
                                && oldFormat.colorInfo.colorSpace == newFormat.colorInfo.colorSpace
                                && oldFormat.colorInfo.colorTransfer
                                        == newFormat.colorInfo.colorTransfer) {
                            return new DecoderReuseEvaluation(
                                    codecInfo.name,
                                    oldFormat,
                                    newFormat,
                                    DecoderReuseEvaluation.REUSE_RESULT_YES_WITHOUT_RECONFIGURATION,
                                    0);
                        }
                        return eval;
                    }

                    @Override
                    protected MediaCodecAdapter.Configuration getMediaCodecConfiguration(
                            MediaCodecInfo codecInfo,
                            Format format,
                            MediaCrypto crypto,
                            float codecOperatingRate) {
                        Format resolved =
                                codecInfo != null
                                                && !MimeTypes.VIDEO_DOLBY_VISION.equals(
                                                        codecInfo.mimeType)
                                        ? toBaseLayerFormat(format)
                                        : format;
                        MediaCodecAdapter.Configuration config =
                                super.getMediaCodecConfiguration(
                                        codecInfo, resolved, crypto, codecOperatingRate);
                        MediaFormat mf = config.mediaFormat;
                        if (mf != null && Build.VERSION.SDK_INT >= 24) {
                            boolean isHdr =
                                    resolved != null && ColorInfo.isTransferHdr(resolved.colorInfo);
                            if (!isHdr
                                    && resolved != null
                                    && MimeTypes.VIDEO_H265.equals(resolved.sampleMimeType)) {
                                if (!mf.containsKey(MediaFormat.KEY_COLOR_STANDARD)) {
                                    boolean hd = resolved.width >= 1280 || resolved.height >= 720;
                                    mf.setInteger(
                                            MediaFormat.KEY_COLOR_STANDARD,
                                            hd
                                                    ? MediaFormat.COLOR_STANDARD_BT709
                                                    : MediaFormat.COLOR_STANDARD_BT601_PAL);
                                }
                                if (!mf.containsKey(MediaFormat.KEY_COLOR_TRANSFER)) {
                                    mf.setInteger(
                                            MediaFormat.KEY_COLOR_TRANSFER,
                                            MediaFormat.COLOR_TRANSFER_SDR_VIDEO);
                                }
                                if (!mf.containsKey(MediaFormat.KEY_COLOR_RANGE)) {
                                    mf.setInteger(
                                            MediaFormat.KEY_COLOR_RANGE,
                                            MediaFormat.COLOR_RANGE_LIMITED);
                                }
                            }
                            if (codecInfo != null && isSoftwareCodec(codecInfo)) {
                                mf.setInteger(
                                        MediaFormat.KEY_COLOR_FORMAT,
                                        CodecCapabilities.COLOR_FormatYUV420Flexible);
                                if (isHdr && Build.VERSION.SDK_INT >= 31) {
                                    mf.setInteger(
                                            "color-transfer-request",
                                            MediaFormat.COLOR_TRANSFER_SDR_VIDEO);
                                }
                            } else if (isHdr
                                    && Build.VERSION.SDK_INT >= 31
                                    && !VideoOutput.displaySupportsHdr(appContext)) {
                                mf.setInteger(
                                        "color-transfer-request",
                                        MediaFormat.COLOR_TRANSFER_SDR_VIDEO);
                            }
                        }
                        return config;
                    }

                    @Override
                    protected DecoderReuseEvaluation onInputFormatChanged(FormatHolder formatHolder)
                            throws ExoPlaybackException {
                        if (formatHolder != null && formatHolder.format != null) {
                            if (isDolbyVisionProfile5(formatHolder.format)) {
                                formatHolder.format = ensureDolbyVisionMime(formatHolder.format);
                            } else if (mode == 2
                                    || !hasNativeDolbyVisionDecoder(formatHolder.format)) {
                                formatHolder.format = toBaseLayerFormat(formatHolder.format);
                            }
                        }
                        return super.onInputFormatChanged(formatHolder);
                    }
                };
        for (int i = 0; i < out.size(); i++) {
            if (out.get(i) instanceof MediaCodecVideoRenderer) {
                out.set(i, doviFallbackRenderer);
                break;
            }
        }
    }
}
