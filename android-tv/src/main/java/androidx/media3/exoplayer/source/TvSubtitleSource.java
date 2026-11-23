package androidx.media3.exoplayer.source;

import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.MediaItem;
import androidx.media3.common.util.Consumer;
import androidx.media3.datasource.DataSource;
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory;
import androidx.media3.exoplayer.source.MediaSource;
import androidx.media3.exoplayer.source.MergingMediaSource;
import androidx.media3.exoplayer.source.ProgressiveMediaSource;
import androidx.media3.extractor.Extractor;
import androidx.media3.extractor.ExtractorInput;
import androidx.media3.extractor.ExtractorOutput;
import androidx.media3.extractor.IndexSeekMap;
import androidx.media3.extractor.PositionHolder;
import androidx.media3.extractor.text.CuesWithTiming;
import androidx.media3.extractor.text.DefaultSubtitleParserFactory;
import androidx.media3.extractor.text.SubtitleExtractor;
import androidx.media3.extractor.text.SubtitleParser;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

/**
 * Media3 1.5.1 adapter for TV sideloaded subtitles. This package is required to retain
 * ProgressiveMediaSource.Factory.setSuppressPrepareError: missing optional subtitles
 * must not make the video fail. No Media3 class is replaced.
 */
public final class TvSubtitleSource {
    private TvSubtitleSource() {}

    public static MediaSource create(DefaultMediaSourceFactory factory, DataSource.Factory data, MediaItem item) {
        List<MediaItem.SubtitleConfiguration> subtitles = item.localConfiguration.subtitleConfigurations;
        if (subtitles.isEmpty()) return factory.createMediaSource(item);
        DefaultSubtitleParserFactory parsers = new DefaultSubtitleParserFactory();
        List<MediaItem.SubtitleConfiguration> fallback = new ArrayList<>();
        List<MediaSource> sources = new ArrayList<>();
        for (MediaItem.SubtitleConfiguration subtitle : subtitles) {
            Format format = new Format.Builder().setSampleMimeType(subtitle.mimeType)
                    .setLanguage(subtitle.language).setSelectionFlags(subtitle.selectionFlags)
                    .setRoleFlags(subtitle.roleFlags).setLabel(subtitle.label).setId(subtitle.id).build();
            if (!parsers.supportsFormat(format)) {
                fallback.add(subtitle);
                continue;
            }
            sources.add(new ProgressiveMediaSource.Factory(data,
                    () -> new Extractor[] {new DurationExtractor(parsers.create(format), format)})
                    .setSuppressPrepareError(true).createMediaSource(MediaItem.fromUri(subtitle.uri)));
        }
        if (sources.isEmpty()) return factory.createMediaSource(item);
        sources.add(0, factory.createMediaSource(item.buildUpon().setSubtitleConfigurations(fallback).build()));
        // The first (video) source still owns the timeline. Do not clip video to subtitle duration.
        return new MergingMediaSource(sources.toArray(new MediaSource[0]));
    }

    /** No cue text, timing, ordering, selection, or renderer output is changed. */
    static final class DurationParser implements SubtitleParser {
        private final SubtitleParser delegate;
        long durationUs = 0;
        boolean unknown;

        DurationParser(SubtitleParser delegate) { this.delegate = delegate; }

        @Override
        public void parse(byte[] data, int offset, int length, OutputOptions options,
                Consumer<CuesWithTiming> output) {
            delegate.parse(data, offset, length, options, cues -> {
                long end = finiteEnd(cues.startTimeUs, cues.durationUs);
                if (end == C.TIME_UNSET) unknown = true;
                else durationUs = Math.max(durationUs, end);
                output.accept(cues);
            });
        }

        @Override public int getCueReplacementBehavior() { return delegate.getCueReplacementBehavior(); }
        @Override public void reset() { delegate.reset(); durationUs = 0; unknown = false; }
    }

    static long finiteEnd(long startUs, long durationUs) {
        if (startUs == C.TIME_UNSET || durationUs == C.TIME_UNSET || durationUs < 0
                || startUs > Long.MAX_VALUE - durationUs) return C.TIME_UNSET;
        return Math.max(0, startUs + durationUs);
    }

    private static final class DurationExtractor extends SubtitleExtractor {
        private final DurationParser parser;
        private ExtractorOutput output;

        DurationExtractor(SubtitleParser parser, Format format) { this(new DurationParser(parser), format); }
        private DurationExtractor(DurationParser parser, Format format) {
            super(parser, format);
            this.parser = parser;
        }

        @Override public void init(ExtractorOutput output) {
            this.output = output;
            super.init(output);
        }

        @Override public int read(ExtractorInput input, PositionHolder seekPosition) throws IOException {
            int result = super.read(input, seekPosition);
            if (result == Extractor.RESULT_END_OF_INPUT) {
                // The default unknown duration becomes last sample START + 10 ms in
                // ProgressiveMediaPeriod, incorrectly dropping a seek into that final cue.
                // Publish the parsed END before load completion instead. Unbounded cues
                // remain unbounded; never truncate one by guessing a finite end.
                output.seekMap(new IndexSeekMap(new long[] {0}, new long[] {0},
                        parser.unknown ? Long.MAX_VALUE : parser.durationUs));
            }
            return result;
        }
    }
}
