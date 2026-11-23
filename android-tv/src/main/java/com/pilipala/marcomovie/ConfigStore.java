package com.pilipala.marcomovie;

import java.io.*;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicLong;

/** Configuration destination, independent from preferences and media/account storage. */
final class ConfigStore {
    static final ExecutorService WRITE_EXECUTOR =
            Executors.newSingleThreadExecutor(
                    r -> {
                        Thread t = new Thread(r, "config-store-writer");
                        t.setDaemon(true);
                        return t;
                    });

    static final class PointerSnapshot {
        final String origin;
        final String selectedSite;
        final Object stateTag;

        PointerSnapshot(String origin, String selectedSite) {
            this(origin, selectedSite, null);
        }

        PointerSnapshot(String origin, String selectedSite, Object stateTag) {
            this.origin = origin;
            this.selectedSite = selectedSite;
            this.stateTag = stateTag;
        }
    }

    interface PointerStore {
        PointerSnapshot readCurrentPointers();

        void applyPointers(PointerSnapshot snapshot);
    }

    interface FailureCallback {
        void onWriteFailed(long seq, Exception error, PointerSnapshot rolledBackTo);
    }

    final File directory;
    private final Object pointerLock = new Object();
    private final AtomicLong writeSeq = new AtomicLong();
    private PointerSnapshot confirmedPointers;

    ConfigStore(File target) {
        directory = target;
    }

    long latestWriteSeq() {
        return writeSeq.get();
    }

    Future<Boolean> saveAsync(
            final String raw,
            final PointerSnapshot nextPointers,
            final PointerStore pointerStore,
            final FailureCallback onFailure) {
        final long seq;
        synchronized (pointerLock) {
            if (confirmedPointers == null && pointerStore != null) {
                confirmedPointers = pointerStore.readCurrentPointers();
            }
            seq = writeSeq.incrementAndGet();
            if (pointerStore != null && nextPointers != null) {
                pointerStore.applyPointers(nextPointers);
            }
        }
        return WRITE_EXECUTOR.submit(
                new Callable<Boolean>() {
                    @Override
                    public Boolean call() {
                        if (seq < writeSeq.get()) {
                            return Boolean.FALSE;
                        }
                        try {
                            write(raw);
                            synchronized (pointerLock) {
                                confirmedPointers = nextPointers;
                            }
                            return Boolean.TRUE;
                        } catch (Exception error) {
                            AppLog.w(
                                    "ConfigStore",
                                    "Sequenced config write #" + seq + " failed",
                                    error);
                            PointerSnapshot rollback = null;
                            boolean notify = false;
                            synchronized (pointerLock) {
                                if (seq == writeSeq.get()) {
                                    rollback = confirmedPointers;
                                    if (pointerStore != null && rollback != null) {
                                        pointerStore.applyPointers(rollback);
                                    }
                                    notify = true;
                                }
                            }
                            if (notify && onFailure != null) {
                                onFailure.onWriteFailed(seq, error, rollback);
                            }
                            return Boolean.FALSE;
                        }
                    }
                });
    }

    void writeSequenced(final String raw, final PointerSnapshot confirmedAfterWrite)
            throws IOException {
        final long seq;
        synchronized (pointerLock) {
            seq = writeSeq.incrementAndGet();
        }
        Future<Void> future =
                WRITE_EXECUTOR.submit(
                        new Callable<Void>() {
                            @Override
                            public Void call() throws Exception {
                                if (seq < writeSeq.get()) {
                                    return null;
                                }
                                write(raw);
                                synchronized (pointerLock) {
                                    confirmedPointers = confirmedAfterWrite;
                                }
                                return null;
                            }
                        });
        awaitSequenced(future);
    }

    void deleteSequenced() throws IOException {
        final long seq;
        synchronized (pointerLock) {
            seq = writeSeq.incrementAndGet();
        }
        Future<Void> future =
                WRITE_EXECUTOR.submit(
                        new Callable<Void>() {
                            @Override
                            public Void call() {
                                if (seq < writeSeq.get()) {
                                    return null;
                                }
                                synchronized (ConfigStore.this) {
                                    new File(directory, "config.json").delete();
                                }
                                synchronized (pointerLock) {
                                    confirmedPointers = new PointerSnapshot(null, null, null);
                                }
                                return null;
                            }
                        });
        awaitSequenced(future);
    }

    private static void awaitSequenced(Future<Void> future) throws IOException {
        try {
            future.get();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new InterruptedIOException("配置写入中断");
        } catch (ExecutionException e) {
            Throwable cause = e.getCause();
            if (cause instanceof IOException) throw (IOException) cause;
            throw new IOException(
                    cause != null && cause.getMessage() != null ? cause.getMessage() : "无法保存配置",
                    cause);
        }
    }

    synchronized void write(String raw) throws IOException {
        if (!directory.exists() && !directory.mkdirs()) throw new IOException("配置目录不可用");
        File pending = File.createTempFile("config-", ".tmp", directory);
        try {
            try (FileOutputStream out = new FileOutputStream(pending)) {
                out.write(raw.getBytes("UTF-8"));
                out.getFD().sync();
            }
            File target = new File(directory, "config.json");
            if (!pending.renameTo(target)) {
                // Windows cannot rename over an existing file; Android uses the atomic path above.
                File backup = new File(directory, "config.json.bak");
                if (!target.isFile()
                        || (backup.exists() && !backup.delete())
                        || !target.renameTo(backup)) {
                    throw new IOException("无法保存配置，原配置已保留");
                }
                if (!pending.renameTo(target)) {
                    backup.renameTo(target);
                    throw new IOException("无法保存配置，原配置已保留");
                }
                backup.delete();
            }
        } finally {
            pending.delete();
        }
    }
}
