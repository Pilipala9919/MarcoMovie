package com.pilipala.marcomovie;

import android.app.Instrumentation;
import android.os.SystemClock;
import java.io.File;
import java.io.FileOutputStream;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Callable;
import org.json.JSONArray;
import org.json.JSONObject;

/** Test APK only. Observes the original 12s/80ms wait; never pumps rendering or keys. */
final class HomeRenderDiagnostics {
    static final String[] COLUMNS = {
        "elapsed_ms",
        "cards",
        "rows",
        "grid_epoch",
        "pending_id",
        "ticket",
        "generation",
        "active",
        "content_attached",
        "content_shown",
        "busy",
        "ready",
        "window_start",
        "window_end",
        "page",
        "items",
        "home_id",
        "queue_ns",
        "condition_ns",
        "observer_ns",
        "condition_true"
    };
    static final String[] EVENT_COLUMNS = {
        "nano_time",
        "elapsed_ms",
        "kind",
        "start",
        "end",
        "captured_epoch",
        "current_epoch",
        "ticket",
        "generation",
        "rows",
        "last_row_cards",
        "pending_id",
        "value",
        "flags",
        "home_id"
    };
    static final String[] EVENT_NAMES = {
        "unused",
        "batch_enter",
        "build_begin",
        "build_end",
        "wire_begin",
        "wire_end",
        "focus_begin",
        "focus_end",
        "post_animation",
        "animation_arrive",
        "handler_post_result",
        "animation_rejected",
        "batch_rejected",
        "batch_exit",
        "cancel_begin",
        "cancel_end",
        "handler_arrive"
    };

    final MainActivity activity;
    final String stage;
    final List<long[]> samples = new ArrayList<>();
    final long startedMs, deadlineMs;
    Method begin, finish;
    boolean traceAttempted, traceAvailable;
    String fixtureSource = "unavailable", diagnosticError;
    long nextSampleMs, pollCount, maxQueueNs, maxConditionNs, observerNs;
    long[][] events = new long[][] {new long[6], new long[0]};

    HomeRenderDiagnostics(MainActivity a, String stage, long started, long deadline) {
        activity = a;
        this.stage = stage;
        startedMs = started;
        deadlineMs = deadline;
    }

    void error(Throwable failure) {
        if (diagnosticError == null) diagnosticError = failure.toString();
    }

    void startTrace(HomeScreen home) {
        if (traceAttempted) return;
        traceAttempted = true;
        try {
            Class<?> trace =
                    Class.forName(
                            "com.pilipala.marcomovie.HomeGridTrace",
                            true,
                            MainActivity.class.getClassLoader());
            begin = trace.getDeclaredMethod("begin", Object.class, long.class);
            finish = trace.getDeclaredMethod("finish");
            begin.setAccessible(true);
            finish.setAccessible(true);
            fixtureSource = String.valueOf(begin.invoke(null, home, deadlineMs));
            traceAvailable = true;
        } catch (Throwable unavailable) {
            error(unavailable);
        }
    }

    void sample(
            HomeScreen h,
            boolean satisfied,
            long queued,
            long entered,
            long conditionNs,
            long observationStarted) {
        try {
            long now = SystemClock.elapsedRealtime();
            pollCount++;
            maxQueueNs = Math.max(maxQueueNs, entered - queued);
            maxConditionNs = Math.max(maxConditionNs, conditionNs);
            // No post-deadline state samples. Stop/serialization below only freezes recorded data.
            if (now <= deadlineMs
                    && (samples.isEmpty() || now >= nextSampleMs || satisfied)
                    && samples.size() < 64) {
                int cards = 0;
                for (List<android.view.View> row : h.rows) cards += row.size();
                long[] row = {
                    now - startedMs,
                    cards,
                    h.rows.size(),
                    h.gridEpoch,
                    h.pendingGrid == null ? 0 : System.identityHashCode(h.pendingGrid),
                    h.ticket,
                    activity.generation,
                    h.active() ? 1 : 0,
                    h.content.isAttachedToWindow() ? 1 : 0,
                    h.content.isShown() ? 1 : 0,
                    h.busy ? 1 : 0,
                    h.state.ready ? 1 : 0,
                    h.state.windowStart,
                    h.windowEnd(),
                    h.state.page,
                    h.state.videos.size(),
                    System.identityHashCode(h),
                    entered - queued,
                    conditionNs,
                    0,
                    satisfied ? 1 : 0
                };
                samples.add(row);
                nextSampleMs = now + 250;
                row[19] = Math.max(0, System.nanoTime() - observationStarted - conditionNs);
            }
        } catch (Throwable failure) {
            error(failure);
        }
        observerNs += Math.max(0, System.nanoTime() - observationStarted - conditionNs);
    }

    void stopTrace() {
        if (!traceAvailable) return;
        try {
            events = (long[][]) finish.invoke(null);
        } catch (Throwable failure) {
            error(failure);
        }
    }

    JSONObject persist(JSONObject result, boolean satisfied, long waitEndedMs) throws Exception {
        JSONObject record =
                new JSONObject()
                        .put("schema", 1)
                        .put("stage", stage)
                        .put("started_elapsed_ms", startedMs)
                        .put("deadline_elapsed_ms", deadlineMs)
                        .put("wait_ended_elapsed_ms", waitEndedMs)
                        .put("timeout_ms", 12000)
                        .put("poll_sleep_ms", 80)
                        .put("sample_min_interval_ms", 250)
                        .put("condition_satisfied", satisfied)
                        .put("polls", pollCount)
                        .put("max_ui_queue_ns", maxQueueNs)
                        .put("max_condition_ns", maxConditionNs)
                        .put("observer_ns", observerNs)
                        .put("trace_available", traceAvailable)
                        .put("fixture_source", fixtureSource)
                        .put("sample_columns", new JSONArray(java.util.Arrays.asList(COLUMNS)))
                        .put("event_columns", new JSONArray(java.util.Arrays.asList(EVENT_COLUMNS)))
                        .put("event_names", new JSONArray(java.util.Arrays.asList(EVENT_NAMES)))
                        .put(
                                "event_flags",
                                "1=active,2=content-attached,4=busy,8=ready,16=finishing")
                        .put(
                                "capture_scope",
                                "Only this existing wait; first batch may precede capture. Callback/phase instrumentation changes timing. No frame-duration claim.");
        if (diagnosticError != null) record.put("diagnostic_error", diagnosticError);
        JSONArray sampleJson = new JSONArray();
        for (long[] row : samples) sampleJson.put(new JSONArray(row));
        record.put("samples", sampleJson);
        JSONArray eventJson = new JSONArray();
        long[] header = events[0], flat = events[1];
        for (int offset = 0;
                offset + EVENT_COLUMNS.length <= flat.length;
                offset += EVENT_COLUMNS.length) {
            JSONArray event = new JSONArray();
            for (int c = 0; c < EVENT_COLUMNS.length; c++) event.put(flat[offset + c]);
            eventJson.put(event);
        }
        record.put("events", eventJson)
                .put("event_count", header[0])
                .put("events_dropped_capacity", header[1])
                .put("events_after_deadline", header[2])
                .put("trace_errors", header[3])
                .put("trace_begin_ns", header[4])
                .put("trace_mark_ns", header[5]);
        JSONArray waits = result.optJSONArray("render_waits");
        if (waits == null) {
            waits = new JSONArray();
            result.put("render_waits", waits);
        }
        File destination =
                new File(
                        activity.getExternalFilesDir(null),
                        String.format(
                                java.util.Locale.US, "home-render-wait-%03d.json", waits.length()));
        // Large event arrays stay in a namespaced sidecar, never in a Binder result bundle.
        try (FileOutputStream out = new FileOutputStream(destination)) {
            out.write(
                    (record.toString(2) + "\n").getBytes(java.nio.charset.StandardCharsets.UTF_8));
        }
        JSONObject summary =
                new JSONObject()
                        .put("stage", stage)
                        .put("path", destination.getAbsolutePath())
                        .put("trace_available", traceAvailable)
                        .put("fixture_source", fixtureSource)
                        .put("condition_satisfied", satisfied)
                        .put("event_count", header[0])
                        .put("events_dropped_capacity", header[1])
                        .put("trace_errors", header[3])
                        .put("samples", samples.size())
                        .put("polls", pollCount)
                        .put("max_ui_queue_ns", maxQueueNs)
                        .put("max_condition_ns", maxConditionNs)
                        .put("observer_ns", observerNs);
        if (!samples.isEmpty())
            summary.put("first_cards", samples.get(0)[1])
                    .put("last_cards", samples.get(samples.size() - 1)[1]);
        if (diagnosticError != null) summary.put("diagnostic_error", diagnosticError);
        waits.put(summary);
        return summary;
    }

    static void awaitLastCard(
            Instrumentation instrumentation,
            MainActivity a,
            Callable<HomeScreen> home,
            Callable<Boolean> condition,
            JSONObject result,
            String stage)
            throws Exception {
        // Same deadline, sleep and assertion as HomeProbe.await. Observation never extends it.
        long end = SystemClock.elapsedRealtime() + 12000;
        HomeRenderDiagnostics diagnostic = new HomeRenderDiagnostics(a, stage, end - 12000, end);
        boolean satisfied = false;
        try {
            while (SystemClock.elapsedRealtime() < end) {
                boolean[] value = {false};
                final long queued = System.nanoTime();
                instrumentation.runOnMainSync(
                        () -> {
                            long entered = System.nanoTime();
                            try {
                                HomeScreen h = home.call();
                                diagnostic.startTrace(h);
                                long conditionStarted = System.nanoTime();
                                value[0] = condition.call();
                                long conditionNs = System.nanoTime() - conditionStarted;
                                diagnostic.sample(
                                        h, value[0], queued, entered, conditionNs, entered);
                            } catch (Exception e) {
                                throw new RuntimeException(e);
                            }
                        });
                if (value[0]) {
                    satisfied = true;
                    return;
                }
                SystemClock.sleep(80);
            }
            throw new AssertionError("Wait timed out");
        } finally {
            final long ended = SystemClock.elapsedRealtime();
            try {
                instrumentation.runOnMainSync(diagnostic::stopTrace);
                diagnostic.persist(result, satisfied, ended);
            } catch (Throwable captureFailure) {
                // Never mask the original failed wait or turn a false predicate into success.
                try {
                    result.put("render_diagnostic_error", captureFailure.toString());
                } catch (Exception ignored) {
                }
            }
        }
    }
}
