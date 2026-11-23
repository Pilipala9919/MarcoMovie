package androidx.media3.exoplayer.source;

import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.util.Consumer;
import androidx.media3.extractor.text.CuesWithTiming;
import androidx.media3.extractor.text.SubtitleParser;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public final class TvSubtitleDurationChecks {
    static void check(boolean value, String label) {
        if (!value) throw new AssertionError(label);
    }

    public static void main(String[] args) {
        check(
                TvSubtitleSource.finiteEnd(0, 60000000) == 60000000,
                "last cue END, not START plus 10ms");
        check(TvSubtitleSource.finiteEnd(65000000, 15000000) == 80000000, "later final cue");
        check(TvSubtitleSource.finiteEnd(-100, 200) == 100, "negative preroll");
        check(TvSubtitleSource.finiteEnd(-100, 50) == 0, "preroll before origin");
        check(TvSubtitleSource.finiteEnd(5, 0) == 5, "empty timed cue");
        check(TvSubtitleSource.finiteEnd(C.TIME_UNSET, 10) == C.TIME_UNSET, "unknown start");
        check(TvSubtitleSource.finiteEnd(10, C.TIME_UNSET) == C.TIME_UNSET, "unbounded duration");
        check(TvSubtitleSource.finiteEnd(Long.MAX_VALUE - 1, 2) == C.TIME_UNSET, "overflow");
        final CuesWithTiming a = new CuesWithTiming(Collections.emptyList(), 0, 60000000);
        final CuesWithTiming b = new CuesWithTiming(Collections.emptyList(), 65000000, 15000000);
        final boolean[] reset = {false};
        SubtitleParser delegate =
                new SubtitleParser() {
                    @Override
                    public void parse(
                            byte[] bytes,
                            int offset,
                            int length,
                            OutputOptions options,
                            Consumer<CuesWithTiming> out) {
                        check(
                                offset == 1
                                        && length == 2
                                        && options.startTimeUs == 15000000
                                        && options.outputAllCues,
                                "options forwarded");
                        out.accept(b);
                        out.accept(a);
                    }

                    @Override
                    public int getCueReplacementBehavior() {
                        return Format.CUE_REPLACEMENT_BEHAVIOR_MERGE;
                    }

                    @Override
                    public void reset() {
                        reset[0] = true;
                    }
                };
        TvSubtitleSource.DurationParser wrapper = new TvSubtitleSource.DurationParser(delegate);
        List<CuesWithTiming> emitted = new ArrayList<>();
        wrapper.parse(
                new byte[4],
                1,
                2,
                SubtitleParser.OutputOptions.cuesAfterThenRemainingCuesBefore(15000000),
                emitted::add);
        check(
                wrapper.durationUs == 80000000 && !wrapper.unknown,
                "maximum end across out-of-order output");
        check(
                emitted.size() == 2 && emitted.get(0) == b && emitted.get(1) == a,
                "original cue objects and ordering");
        check(
                wrapper.getCueReplacementBehavior() == Format.CUE_REPLACEMENT_BEHAVIOR_MERGE,
                "merge semantics");
        wrapper.reset();
        check(reset[0] && wrapper.durationUs == 0 && !wrapper.unknown, "release/reset delegated");
        System.out.println("TvSubtitleDurationChecks: 13 checks passed (JVM, not native playback)");
    }
}
