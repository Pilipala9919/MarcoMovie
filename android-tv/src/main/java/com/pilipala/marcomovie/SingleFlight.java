package com.pilipala.marcomovie;

import java.util.concurrent.*;

/** Share in-progress initialization without holding a global lock during plugin work. */
final class SingleFlight<T> {
    private static final long STALE_PENDING_NANOS = TimeUnit.SECONDS.toNanos(30);

    private static final class Pending<T> {
        final FutureTask<T> task;
        final long createdAtNanos;

        Pending(FutureTask<T> task) {
            this.task = task;
            this.createdAtNanos = System.nanoTime();
        }
    }

    private final ConcurrentHashMap<String, Pending<T>> pending = new ConcurrentHashMap<>();

    T get(String key, Callable<T> factory) throws Exception {
        Pending<T> existing = pending.get(key);
        if (existing != null
                && !existing.task.isDone()
                && (System.nanoTime() - existing.createdAtNanos) >= STALE_PENDING_NANOS) {
            pending.remove(key, existing);
        }
        Pending<T> candidate = new Pending<>(new FutureTask<>(factory));
        Pending<T> entry = pending.putIfAbsent(key, candidate);
        if (entry == null) {
            entry = candidate;
            entry.task.run();
        }
        try {
            return entry.task.get();
        } catch (ExecutionException failure) {
            Throwable cause = failure.getCause();
            if (cause instanceof Exception) throw (Exception) cause;
            if (cause != null)
                throw new java.io.IOException(
                        "运行环境或扩展异常：" + cause.getClass().getSimpleName(), cause);
            throw new IllegalStateException(failure);
        } finally {
            // A cancelled waiter must not remove an initialization still used by others.
            if (entry.task.isDone()) pending.remove(key, entry);
        }
    }
}
