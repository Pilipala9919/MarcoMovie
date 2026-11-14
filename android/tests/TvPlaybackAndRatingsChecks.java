package com.pilipala.marcomovie;

import androidx.media3.common.C;
import androidx.media3.common.ColorInfo;
import androidx.media3.common.Format;
import androidx.media3.common.MimeTypes;
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/**
 * Pure JVM regression checks for Android TV HDR10/HEVC/Dolby Vision color handling, verified
 * Douban & Rotten Tomatoes rating resolution, modern skip-intro/outro icon constants, and TV HUD
 * preferences.
 */
public final class TvPlaybackAndRatingsChecks {
    private static int checks;

    private static void check(boolean ok, String label) {
        if (!ok) {
            throw new AssertionError("FAILED: " + label);
        }
        checks++;
        System.out.println("PASS " + label);
    }

    public static void main(String[] args) {
        testDolbyVisionProfile5Protection();
        testDolbyVisionBaseLayerAndColorInfoNormalization();
        testHardwareDecoderPrioritization();
        testRatingsExtractionAndStrictVerification();
        testTvHudAndModernControlInvariants();
        System.out.println("ALL PASS (" + checks + " TV playback & ratings checks)");
    }

    private static void testDolbyVisionProfile5Protection() {
        // 1. Standard MP4/MKV Dolby Vision Profile 5 with dvhe.05.06 codec string
        Format dvP5Codec =
                new Format.Builder()
                        .setSampleMimeType(MimeTypes.VIDEO_DOLBY_VISION)
                        .setCodecs("dvhe.05.06")
                        .build();
        check(
                DecoderRenderersFactory.extractDolbyVisionProfile(dvP5Codec) == 5
                        && DecoderRenderersFactory.isDolbyVisionProfile5(dvP5Codec),
                "DV Profile 5 detected from dvhe.05.06 codec string");
        Format p5Base = DecoderRenderersFactory.toBaseLayerFormat(dvP5Codec);
        check(
                MimeTypes.VIDEO_DOLBY_VISION.equals(p5Base.sampleMimeType),
                "DV Profile 5 is never converted to video/hevc (prevents IPT-PQ-C2 green screen)");

        // 2. HLS/MP4 stream mislabeled as video/hevc with dvh1.05.07 codec string
        Format mislabeledHlsP5 =
                new Format.Builder()
                        .setSampleMimeType(MimeTypes.VIDEO_H265)
                        .setCodecs("dvh1.05.07")
                        .build();
        check(
                DecoderRenderersFactory.isDolbyVisionProfile5(mislabeledHlsP5),
                "Mislabeled video/hevc + dvh1.05.07 recognized as DV Profile 5");
        Format mislabeledFallback = DecoderRenderersFactory.toBaseLayerFormat(mislabeledHlsP5);
        check(
                MimeTypes.VIDEO_DOLBY_VISION.equals(mislabeledFallback.sampleMimeType),
                "Mislabeled video/hevc + dvh1.05.07 promoted to video/dolby-vision instead of HEVC");

        // 3. MKV stream without codec string, carrying ISO dvcC record (profile=5 ->
        // byte[2]=5<<1=0x0A)
        byte[] fakeHvcc = new byte[] {0x01, 0x02, 0x20, 0x00, 0x00, 0x00};
        byte[] dvccProfile5 = new byte[] {0x01, 0x00, (byte) (5 << 1), 0x06, 0x00, 0x00};
        Format mkvP5 =
                new Format.Builder()
                        .setSampleMimeType(MimeTypes.VIDEO_DOLBY_VISION)
                        .setInitializationData(Arrays.asList(fakeHvcc, dvccProfile5))
                        .build();
        check(
                DecoderRenderersFactory.extractDolbyVisionProfile(mkvP5) == 5
                        && DecoderRenderersFactory.isDolbyVisionProfile5(mkvP5),
                "DV Profile 5 detected from raw dvcC initializationData record");
        check(
                MimeTypes.VIDEO_DOLBY_VISION.equals(
                        DecoderRenderersFactory.toBaseLayerFormat(mkvP5).sampleMimeType),
                "dvcC DV Profile 5 remains video/dolby-vision");
    }

    private static void testDolbyVisionBaseLayerAndColorInfoNormalization() {
        byte[] fakeHvcc = new byte[] {0x01, 0x02, 0x60, 0x00, 0x00, 0x00, 0x01, 0x02};
        // Profile 8.1 (HDR10 base layer: profile=8 -> 0x10, compatId=1 -> 0x10)
        byte[] dvccP81 = new byte[] {0x01, 0x00, (byte) (8 << 1), 0x06, (byte) (1 << 4), 0x00};
        Format dvP81 =
                new Format.Builder()
                        .setSampleMimeType(MimeTypes.VIDEO_DOLBY_VISION)
                        .setCodecs("dvhe.08.06")
                        .setInitializationData(Arrays.asList(fakeHvcc, dvccP81))
                        .build();
        check(
                DecoderRenderersFactory.extractDolbyVisionProfile(dvP81) == 8
                        && DecoderRenderersFactory.extractDolbyVisionCompatibilityId(dvP81) == 1
                        && !DecoderRenderersFactory.isDolbyVisionProfile5(dvP81),
                "DV Profile 8.1 profile and compatibilityId=1 extracted accurately");
        Format hevcHdr10 = DecoderRenderersFactory.toBaseLayerFormat(dvP81);
        check(
                MimeTypes.VIDEO_H265.equals(hevcHdr10.sampleMimeType)
                        && hevcHdr10.codecs == null
                        && hevcHdr10.initializationData.size() == 1
                        && hevcHdr10.initializationData.get(0) == fakeHvcc,
                "DV Profile 8.1 falls back to video/hevc and strips dvcC record while keeping hvcC");
        check(
                hevcHdr10.colorInfo != null
                        && hevcHdr10.colorInfo.colorSpace == C.COLOR_SPACE_BT2020
                        && hevcHdr10.colorInfo.colorTransfer == C.COLOR_TRANSFER_ST2084
                        && hevcHdr10.colorInfo.colorRange == C.COLOR_RANGE_LIMITED,
                "DV Profile 8.1 base layer receives normalized BT2020 + ST2084 PQ ColorInfo");

        // Profile 8.4 (HLG base layer: compatId=4)
        ColorInfo hlgColor = DecoderRenderersFactory.normalizeBaseLayerColorInfo(null, 8, 4);
        check(
                hlgColor.colorSpace == C.COLOR_SPACE_BT2020
                        && hlgColor.colorTransfer == C.COLOR_TRANSFER_HLG,
                "DV Profile 8.4 base layer receives BT2020 + HLG ColorInfo");

        // Profile 8.2 / Profile 4 (SDR base layer: compatId=2)
        ColorInfo sdrColor = DecoderRenderersFactory.normalizeBaseLayerColorInfo(null, 8, 2);
        check(
                sdrColor.colorSpace == C.COLOR_SPACE_BT709
                        && sdrColor.colorTransfer == C.COLOR_TRANSFER_SDR,
                "DV Profile 8.2 SDR base layer receives BT709 + SDR ColorInfo");
    }

    private static void testHardwareDecoderPrioritization() {
        MediaCodecInfo swGoogle =
                MediaCodecInfo.newInstance(
                        "c2.android.hevc.decoder",
                        MimeTypes.VIDEO_H265,
                        MimeTypes.VIDEO_H265,
                        null,
                        false,
                        true,
                        false,
                        false,
                        false);
        MediaCodecInfo hwVendor =
                MediaCodecInfo.newInstance(
                        "OMX.amlogic.hevc.decoder.awesome",
                        MimeTypes.VIDEO_H265,
                        MimeTypes.VIDEO_H265,
                        null,
                        true,
                        false,
                        true,
                        false,
                        false);
        check(
                DecoderRenderersFactory.isSoftwareCodec(swGoogle)
                        && !DecoderRenderersFactory.isSoftwareCodec(hwVendor),
                "isSoftwareCodec distinguishes c2.android.* software codec from vendor hardware codec");
        List<MediaCodecInfo> ordered =
                DecoderRenderersFactory.prioritizeHardwareDecoders(
                        Arrays.asList(swGoogle, hwVendor));
        check(
                ordered.size() == 2 && ordered.get(0) == hwVendor && ordered.get(1) == swGoogle,
                "prioritizeHardwareDecoders places hardware HEVC decoder ahead of c2.android.hevc.decoder");
    }

    private static void testRatingsExtractionAndStrictVerification() {
        check(
                Math.abs(
                                ImmersivePoster.extractDoubanScoreFromText(
                                                "◎豆瓣评分　8.9/10 from 50,000 users")
                                        - 8.9)
                        < 0.001,
                "extractDoubanScoreFromText parses standard Douban synopsis block");
        check(
                ImmersivePoster.extractDoubanScoreFromText("豆瓣评分 10.0") == 0.0,
                "extractDoubanScoreFromText rejects unverified 10.0 placeholder");
        check(
                ImmersivePoster.extractRtPercentFromText("本片烂番茄新鲜度高达 94%，口碑爆棚") == 94
                        && ImmersivePoster.extractRtPercentFromText("获得 88% 的烂番茄好评") == 88
                        && ImmersivePoster.extractRtPercentFromText("Tomatometer: 96%") == 96,
                "extractRtPercentFromText parses Chinese and English Rotten Tomatoes percentages");

        String matchingBingHtml =
                "<ol id=\"b_results\">"
                        + "<li class=\"b_algo\"><h2>奥本海默 (2023) 影评</h2>"
                        + "<div class=\"b_caption\"><p>克里斯托弗·诺兰执导《奥本海默》(2023) 烂番茄新鲜度 93%，豆瓣评分 8.8 分。</p></div></li>"
                        + "</ol>";
        check(
                ImmersivePoster.extractRtPercentFromBingHtml(
                                matchingBingHtml, "奥本海默 4K HDR", "Oppenheimer", 2023)
                        == 93,
                "extractRtPercentFromBingHtml extracts verified RT score when title and year match");
        check(
                Math.abs(
                                ImmersivePoster.extractDoubanScoreFromBingHtml(
                                                matchingBingHtml, "奥本海默", 2023)
                                        - 8.8)
                        < 0.001,
                "extractDoubanScoreFromBingHtml extracts verified Douban score when title and year match");

        // Mismatched year (e.g. 1995 version vs 2024 remake) must be strictly rejected (-1)
        check(
                ImmersivePoster.extractRtPercentFromBingHtml(
                                matchingBingHtml, "奥本海默", "Oppenheimer", 1995)
                        == -1,
                "extractRtPercentFromBingHtml rejects snippet from wrong release year (never fabricates)");

        // Unrelated title snippet must be strictly rejected (-1)
        check(
                ImmersivePoster.extractRtPercentFromBingHtml(
                                matchingBingHtml,
                                "周处除三害",
                                "The Pig, the Snake and the Pigeon",
                                2023)
                        == -1,
                "extractRtPercentFromBingHtml rejects snippet for different movie title");

        // English title + rottentomatoes.com domain snippet verification
        String rtEnglishBingHtml =
                "<ol id=\"b_results\">"
                        + "<li class=\"b_algo\"><h2>Dune: Part Two (2024) | Rotten Tomatoes</h2>"
                        + "<cite>www.rottentomatoes.com/m/dune_part_two</cite>"
                        + "<div class=\"b_caption\"><p>Critics Consensus: 92% Tomatometer based on 410 reviews (2024).</p></div></li>"
                        + "</ol>";
        check(
                ImmersivePoster.extractRtPercentFromBingHtml(
                                rtEnglishBingHtml, "沙丘2", "Dune: Part Two", 2024)
                        == 92,
                "extractRtPercentFromBingHtml matches verified Douban English sub_title against RT result");

        // Immediate CMS Video rating extraction without network
        Cms.Video v = new Cms.Video();
        v.title = "测试电影";
        v.year = "2024";
        v.doubanScore = "8.5";
        v.description = "烂番茄指数：91%，年度佳作。";
        ImmersivePoster.Ratings immediate = ImmersivePoster.extractImmediateRatings(v);
        check(
                Math.abs(immediate.douban - 8.5) < 0.001 && immediate.rtPercent == 91,
                "extractImmediateRatings combines CMS doubanScore and description RT score immediately");

        Cms.Video unrated = new Cms.Video();
        unrated.title = "自制短片无评分";
        unrated.year = "2025";
        unrated.doubanScore = "0.0";
        unrated.description = "这是一段没有任何评分信息的普通剧情简介。";
        ImmersivePoster.Ratings emptyRatings = ImmersivePoster.extractImmediateRatings(unrated);
        check(
                emptyRatings.douban == 0.0 && emptyRatings.rtPercent == -1,
                "extractImmediateRatings returns 0.0/-1 when unrated (hides badges cleanly)");
    }

    private static void testTvHudAndModernControlInvariants() {
        check(
                "tv_player_top_right_hud".equals(Prefs.TV_PLAYER_TOP_RIGHT_HUD),
                "Prefs.TV_PLAYER_TOP_RIGHT_HUD key is stable");
        check(
                PlaybackControls.ICON_SKIP_INTRO != PlaybackControls.ICON_NEXT
                        && PlaybackControls.ICON_SKIP_OUTRO != PlaybackControls.ICON_NEXT
                        && PlaybackControls.ICON_SKIP_INTRO != PlaybackControls.ICON_SKIP_OUTRO,
                "Modern card skip-intro and skip-outro use distinct icon identifiers from next-episode");
        CharSequence hudText = PlayerChrome.formatTvHudProgress("12:34", "45:20");
        check(
                "12:34/45:20".equals(hudText.toString())
                        && "".equals(PlayerChrome.formatTvHudProgress("", "45:20").toString())
                        && "12:34".equals(PlayerChrome.formatTvHudProgress("12:34", "").toString()),
                "PlayerChrome.formatTvHudProgress formats elapsed/total cleanly");
    }
}
