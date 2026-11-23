package com.pilipala.marcomovie;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** One storage worker; completion is emitted only after both durable stages. */
final class MarkerClearTask {
    interface Write {
        void run() throws Exception;
    }

    interface Complete {
        void run(boolean newerCleared, Exception failure);
    }

    private static volatile Thread storageThread;
    private static final ExecutorService WORK =
            Executors.newSingleThreadExecutor(
                    r -> {
                        Thread t = new Thread(r, "marker-clear-storage");
                        t.setDaemon(true);
                        storageThread = t;
                        return t;
                    });

    static void requireWorker() {
        if (Thread.currentThread() != storageThread)
            throw new IllegalStateException("Marker clear requires its storage worker");
    }

    static void submit(Write newer, Write legacy, Complete complete) {
        WORK.execute(
                () -> {
                    boolean done = false;
                    Exception failure = null;
                    try {
                        requireWorker();
                        newer.run();
                        done = true;
                        legacy.run();
                    } catch (Exception e) {
                        failure = e;
                    }
                    complete.run(done, failure);
                });
    }
}
