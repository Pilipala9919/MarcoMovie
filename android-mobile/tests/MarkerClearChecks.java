package com.pilipala.marcomovie;

import android.content.SharedPreferences;
import java.lang.reflect.Proxy;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

public final class MarkerClearChecks {
    static void check(boolean ok, String name) {
        if (!ok) throw new AssertionError(name);
        System.out.println("PASS " + name);
    }

    public static void main(String[] args) throws Exception {
        AtomicInteger edits = new AtomicInteger();
        AtomicBoolean commitOk = new AtomicBoolean(true);
        SharedPreferences.Editor editor =
                (SharedPreferences.Editor)
                        Proxy.newProxyInstance(
                                MarkerClearChecks.class.getClassLoader(),
                                new Class[] {SharedPreferences.Editor.class},
                                (o, m, a) -> {
                                    MarkerClearTask.requireWorker();
                                    if (m.getName().equals("remove")) {
                                        check(
                                                Prefs.VIDEO_SKIP_RECORDS.equals(a[0]),
                                                "only legacy skip key removed");
                                        return o;
                                    }
                                    if (m.getName().equals("commit")) {
                                        edits.incrementAndGet();
                                        return commitOk.get();
                                    }
                                    throw new AssertionError(m.getName());
                                });
        SharedPreferences prefs =
                (SharedPreferences)
                        Proxy.newProxyInstance(
                                MarkerClearChecks.class.getClassLoader(),
                                new Class[] {SharedPreferences.class},
                                (o, m, a) -> editor);
        boolean rejected = false;
        try {
            MarkerLegacyCommit.clear(prefs);
        } catch (IllegalStateException e) {
            rejected = true;
        }
        check(rejected && edits.get() == 0, "UI/direct commit rejected before preference access");
        List<String> order = Collections.synchronizedList(new ArrayList<>());
        CountDownLatch started = new CountDownLatch(1),
                release = new CountDownLatch(1),
                done = new CountDownLatch(2);
        AtomicReference<Throwable> error = new AtomicReference<>();
        MarkerClearTask.submit(
                () -> {
                    order.add("new1");
                    started.countDown();
                    if (!release.await(5, TimeUnit.SECONDS)) throw new AssertionError();
                },
                () -> {
                    MarkerLegacyCommit.clear(prefs);
                    order.add("old1");
                },
                (n, e) -> {
                    if (!n || e != null) error.set(new AssertionError());
                    order.add("done1");
                    done.countDown();
                });
        check(started.await(5, TimeUnit.SECONDS), "worker entered without blocking caller");
        MarkerClearTask.submit(
                () -> order.add("new2"),
                () -> order.add("old2"),
                (n, e) -> {
                    order.add("done2");
                    done.countDown();
                });
        check(order.equals(Arrays.asList("new1")), "second transaction waits behind first");
        release.countDown();
        check(done.await(5, TimeUnit.SECONDS), "two completions delivered");
        check(
                error.get() == null
                        && order.equals(
                                Arrays.asList("new1", "old1", "done1", "new2", "old2", "done2")),
                "new-before-old ordering and serialization");
        CountDownLatch failed = new CountDownLatch(1);
        AtomicBoolean oldCalled = new AtomicBoolean();
        AtomicBoolean result = new AtomicBoolean();
        MarkerClearTask.submit(
                () -> {
                    throw new java.io.IOException("new failure");
                },
                () -> oldCalled.set(true),
                (n, e) -> {
                    result.set(!n && e != null);
                    failed.countDown();
                });
        check(
                failed.await(5, TimeUnit.SECONDS) && result.get() && !oldCalled.get(),
                "new failure preserves legacy and reports failure");
        commitOk.set(false);
        CountDownLatch oldFail = new CountDownLatch(1);
        result.set(false);
        MarkerClearTask.submit(
                () -> {},
                () -> MarkerLegacyCommit.clear(prefs),
                (n, e) -> {
                    result.set(n && e instanceof java.io.IOException);
                    oldFail.countDown();
                });
        check(
                oldFail.await(5, TimeUnit.SECONDS) && result.get(),
                "legacy commit false reports partial clear, never success");
        check(edits.get() == 2, "captured preferences used only by accepted worker transactions");
    }
}
