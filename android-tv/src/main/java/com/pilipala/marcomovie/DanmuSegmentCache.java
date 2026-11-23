// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import com.pilipala.marcomovie.DanmuProvider.BlockFilter;
import com.pilipala.marcomovie.DanmuProvider.CancellationToken;
import com.pilipala.marcomovie.DanmuProvider.DanmuItem;
import com.pilipala.marcomovie.DanmuProvider.EpisodeSession;
import com.pilipala.marcomovie.DanmuProvider.HttpStatusException;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Windowed 30-second danmu cache with signed effective-clock snapshots, 3-window LRU pinning
 * ({@code {w-1, w, w+1}}), 60% prefetch, HTTP 410 singleflight epoch refresh, and 180ms seek-storm
 * debounce/cancellation. Also hosts the pure-Java collision-free {@link LayoutEngine} and TV {@link
 * FramePacingMonitor} shared with {@link DanmakuView}.
 */
public final class DanmuSegmentCache implements AutoCloseable {

    public static final int WINDOW_DURATION_MS = 30000;
    public static final int MAX_COMMENT_LIFETIME_MS = 12000;
    public static final int PREFETCH_OFFSET_MS = 18000; // 60% of 30s
    public static final int MAX_CACHED_WINDOWS = 24;
    public static final int MAX_WINDOW_ITEMS = 1500;
    public static final int MAX_TOTAL_ITEMS = 18000;
    public static final int MAX_SESSION_410_REFRESHES = 3;
    public static final long SEEK_DEBOUNCE_MS = 180L;

    public interface Listener {
        void onWindowReady(int windowIndex, int count);

        void onSessionReady(boolean segmented);

        void onError(String message);
    }

    private static final class RefreshFlight {
        final int fromEpoch;
        final CountDownLatch latch = new CountDownLatch(1);
        volatile EpisodeSession newSession;
        volatile boolean succeeded;

        RefreshFlight(int fromEpoch) {
            this.fromEpoch = fromEpoch;
        }
    }

    private static final class WindowEntry {
        final List<DanmuItem> rawItems;
        List<DanmuItem> filteredItems;

        WindowEntry(List<DanmuItem> rawItems, List<DanmuItem> filteredItems) {
            this.rawItems = rawItems;
            this.filteredItems = filteredItems;
        }
    }

    private final DanmuProvider provider;
    private final long seekDebounceMs;
    private final ExecutorService workerPool;
    private final ScheduledExecutorService scheduler;
    private final Object lock = new Object();

    // Access-order LRU map of windowIndex -> raw + pre-filtered DanmuItem lists
    private final LinkedHashMap<Integer, WindowEntry> windowCache =
            new LinkedHashMap<>(32, 0.75f, true);
    private final Map<Integer, CancellationToken> inFlightWindows = new HashMap<>();
    private final Set<Integer> retried410Windows = new HashSet<>();
    private final AtomicInteger activeTasks = new AtomicInteger(0);

    private String boundEpisodeId = "";
    private EpisodeSession activeSession;
    private CancellationToken openSessionToken;
    private boolean openSessionInFlight;
    private int pendingWindowAfterOpen = -1;
    private int activePrefetchWindow = -1;
    private int bindGeneration = 0;
    private int sessionEpoch = 0;
    private int session410RefreshCount = 0;
    private RefreshFlight activeRefreshFlight;

    private long timeOffsetMs = 0L;
    private int currentPinnedWindow = 0;
    private int totalCachedItems = 0;
    private boolean seeking = false;
    private long seekSequence = 0L;
    private ScheduledFuture<?> pendingSeekFuture;
    private BlockFilter blockFilter = BlockFilter.EMPTY;
    private int filterGeneration = 0;
    private int fastWindowIndex = -1;
    private List<DanmuItem> fastPrevFiltered;
    private List<DanmuItem> fastCurrFiltered;
    private boolean fastCurrCached = false;
    private boolean fastNextCached = false;
    private Listener listener;
    private boolean closed = false;

    public DanmuSegmentCache(DanmuProvider provider) {
        this(provider, SEEK_DEBOUNCE_MS);
    }

    public DanmuSegmentCache(DanmuProvider provider, long seekDebounceMs) {
        if (provider == null) throw new IllegalArgumentException("provider required");
        this.provider = provider;
        this.seekDebounceMs = Math.max(0L, seekDebounceMs);
        this.workerPool = Executors.newFixedThreadPool(3);
        this.scheduler = Executors.newSingleThreadScheduledExecutor();
    }

    public static long computeEffectiveMs(long rawPositionMs, long offsetMs) {
        return rawPositionMs + offsetMs;
    }

    public static int computeFetchWindowIndex(long effectiveMs) {
        if (effectiveMs < 0L) return 0;
        return (int) (effectiveMs / WINDOW_DURATION_MS);
    }

    public void setListener(Listener listener) {
        synchronized (lock) {
            this.listener = listener;
        }
    }

    static List<DanmuItem> filterItems(List<DanmuItem> raw, BlockFilter filter) {
        if (raw == null || raw.isEmpty()) return Collections.emptyList();
        if (filter == null || filter.isEmpty()) return raw;
        ArrayList<DanmuItem> kept = null;
        int n = raw.size();
        for (int i = 0; i < n; i++) {
            DanmuItem item = raw.get(i);
            if (filter.isBlocked(item.text)) {
                if (kept == null) {
                    kept = new ArrayList<>(Math.max(0, n - 1));
                    for (int j = 0; j < i; j++) {
                        kept.add(raw.get(j));
                    }
                }
            } else if (kept != null) {
                kept.add(item);
            }
        }
        if (kept == null) return raw;
        return kept.isEmpty()
                ? Collections.<DanmuItem>emptyList()
                : Collections.unmodifiableList(kept);
    }

    private void invalidateFastWindowLocked() {
        fastWindowIndex = -1;
        fastPrevFiltered = null;
        fastCurrFiltered = null;
        fastCurrCached = false;
        fastNextCached = false;
    }

    public void setBlockFilter(BlockFilter filter) {
        BlockFilter next = filter == null ? BlockFilter.EMPTY : filter;
        synchronized (lock) {
            if (this.blockFilter.sameRules(next)) {
                return;
            }
            this.blockFilter = next;
            this.filterGeneration++;
            for (WindowEntry entry : windowCache.values()) {
                entry.filteredItems = filterItems(entry.rawItems, next);
            }
            invalidateFastWindowLocked();
        }
    }

    public void setTimeOffsetMs(long offsetMs) {
        long clamped = Math.max(-30000L, Math.min(30000L, offsetMs));
        synchronized (lock) {
            this.timeOffsetMs = clamped;
        }
    }

    public long getTimeOffsetMs() {
        synchronized (lock) {
            return timeOffsetMs;
        }
    }

    public void bindSession(final String boundEpisodeId) {
        final int gen;
        final CancellationToken token;
        synchronized (lock) {
            if (closed) return;
            cancelInFlightLocked(true);
            this.bindGeneration++;
            gen = this.bindGeneration;
            this.boundEpisodeId = boundEpisodeId == null ? "" : boundEpisodeId.trim();
            this.activeSession = null;
            this.sessionEpoch = 0;
            this.session410RefreshCount = 0;
            this.activeRefreshFlight = null;
            this.retried410Windows.clear();
            this.windowCache.clear();
            invalidateFastWindowLocked();
            this.totalCachedItems = 0;
            this.currentPinnedWindow = 0;
            this.pendingWindowAfterOpen = -1;
            this.seeking = false;
            if (this.boundEpisodeId.isEmpty()) {
                this.openSessionInFlight = false;
                return;
            }
            token = new CancellationToken();
            this.openSessionToken = token;
            this.openSessionInFlight = true;
        }
        activeTasks.incrementAndGet();
        workerPool.execute(
                new Runnable() {
                    @Override
                    public void run() {
                        try {
                            EpisodeSession session =
                                    provider.openSession(boundEpisodeId.trim(), token);
                            Listener l;
                            int pendingW;
                            synchronized (lock) {
                                if (closed || gen != bindGeneration) return;
                                activeSession = session;
                                openSessionInFlight = false;
                                openSessionToken = null;
                                l = listener;
                                pendingW = pendingWindowAfterOpen;
                                pendingWindowAfterOpen = -1;
                                if (!seeking && pendingW >= 0) {
                                    startWindowFetchLocked(pendingW, false, gen);
                                }
                            }
                            if (l != null) {
                                l.onSessionReady(session.segmented);
                            }
                        } catch (Exception e) {
                            Listener l;
                            synchronized (lock) {
                                if (gen == bindGeneration) {
                                    openSessionInFlight = false;
                                    openSessionToken = null;
                                }
                                l = closed ? null : listener;
                            }
                            if (l != null && !token.isCancelled()) {
                                l.onError(e.getMessage() == null ? "弹幕会话初始化失败" : e.getMessage());
                            }
                        } finally {
                            finishTask();
                        }
                    }
                });
    }

    public void onPlaybackTick(long rawPositionMs, boolean playing) {
        synchronized (lock) {
            if (closed || boundEpisodeId.isEmpty()) return;
            long effectiveMs = computeEffectiveMs(rawPositionMs, timeOffsetMs);
            int w = computeFetchWindowIndex(effectiveMs);
            if (w == currentPinnedWindow
                    && w == fastWindowIndex
                    && fastCurrCached
                    && activeSession != null
                    && !seeking) {
                long windowStartMs = (long) w * WINDOW_DURATION_MS;
                if (!playing
                        || effectiveMs < windowStartMs + PREFETCH_OFFSET_MS
                        || fastNextCached
                        || activePrefetchWindow == w + 1) {
                    return;
                }
            }
            currentPinnedWindow = w;
            evictIfNeededLocked();
            if (seeking) return;

            if (activeSession == null) {
                pendingWindowAfterOpen = w;
                return;
            }
            if (!windowCache.containsKey(w) && !inFlightWindows.containsKey(w)) {
                startWindowFetchLocked(w, false, bindGeneration);
            }
            long windowStartMs = (long) w * WINDOW_DURATION_MS;
            if (playing && effectiveMs >= windowStartMs + PREFETCH_OFFSET_MS) {
                int nextW = w + 1;
                if (activePrefetchWindow == -1
                        && !windowCache.containsKey(nextW)
                        && !inFlightWindows.containsKey(nextW)) {
                    startWindowFetchLocked(nextW, true, bindGeneration);
                }
            }
        }
    }

    public void onSeekInitiated() {
        synchronized (lock) {
            if (closed) return;
            seeking = true;
            seekSequence++;
            cancelInFlightLocked(false);
        }
    }

    public void onSeekSettled(final long targetRawPositionMs) {
        final long seq;
        final int gen;
        synchronized (lock) {
            if (closed) return;
            seeking = true;
            seekSequence++;
            seq = seekSequence;
            gen = bindGeneration;
            cancelInFlightLocked(false);
            Runnable settleTask =
                    new Runnable() {
                        @Override
                        public void run() {
                            synchronized (lock) {
                                if (closed || seq != seekSequence || gen != bindGeneration) return;
                                seeking = false;
                                pendingSeekFuture = null;
                                long effectiveMs =
                                        computeEffectiveMs(targetRawPositionMs, timeOffsetMs);
                                int targetW = computeFetchWindowIndex(effectiveMs);
                                currentPinnedWindow = targetW;
                                evictIfNeededLocked();
                                if (activeSession == null) {
                                    pendingWindowAfterOpen = targetW;
                                    return;
                                }
                                if (!windowCache.containsKey(targetW)
                                        && !inFlightWindows.containsKey(targetW)) {
                                    startWindowFetchLocked(targetW, false, gen);
                                }
                            }
                        }
                    };
            if (seekDebounceMs == 0L) {
                settleTask.run();
            } else {
                pendingSeekFuture =
                        scheduler.schedule(settleTask, seekDebounceMs, TimeUnit.MILLISECONDS);
            }
        }
    }

    public List<DanmuItem> visibleWindowSnapshot(long rawPositionMs) {
        List<DanmuItem> out = new ArrayList<>();
        fillVisibleWindowSnapshot(rawPositionMs, out);
        return out.isEmpty() ? Collections.<DanmuItem>emptyList() : out;
    }

    /**
     * Zero-allocation snapshot helper for {@link DanmakuView#onDraw}: clears {@code reusableOut}
     * and populates pre-filtered active items from {@code w - 1} and {@code w} in chronological
     * order without per-frame regex/string matching or {@link Integer} boxing past 64 minutes.
     */
    public void fillVisibleWindowSnapshot(long rawPositionMs, List<DanmuItem> reusableOut) {
        reusableOut.clear();
        final long effectiveMs;
        final List<DanmuItem> prevItems;
        final List<DanmuItem> currItems;
        synchronized (lock) {
            effectiveMs = computeEffectiveMs(rawPositionMs, timeOffsetMs);
            if (effectiveMs < 0L) {
                return;
            }
            int w = (int) (effectiveMs / WINDOW_DURATION_MS);
            if (w == fastWindowIndex) {
                prevItems = fastPrevFiltered;
                currItems = fastCurrFiltered;
            } else {
                WindowEntry prevEntry = w > 0 ? windowCache.get(w - 1) : null;
                WindowEntry currEntry = windowCache.get(w);
                prevItems = prevEntry != null ? prevEntry.filteredItems : null;
                currItems = currEntry != null ? currEntry.filteredItems : null;
                fastWindowIndex = w;
                fastPrevFiltered = prevItems;
                fastCurrFiltered = currItems;
                fastCurrCached = currEntry != null;
                fastNextCached = windowCache.containsKey(w + 1);
            }
        }
        if ((prevItems == null || prevItems.isEmpty())
                && (currItems == null || currItems.isEmpty())) {
            return;
        }
        long minTimeMs = effectiveMs - MAX_COMMENT_LIFETIME_MS;
        appendVisibleNoAlloc(prevItems, minTimeMs, effectiveMs, reusableOut, 0);
        int prevAdded = reusableOut.size();
        appendVisibleNoAlloc(currItems, minTimeMs, effectiveMs, reusableOut, prevAdded);
    }

    private static void appendVisibleNoAlloc(
            List<DanmuItem> source,
            long minTimeMs,
            long maxTimeMs,
            List<DanmuItem> dest,
            int dedupLimit) {
        if (source == null || source.isEmpty()) return;
        int lo = 0;
        int hi = source.size();
        while (lo < hi) {
            int mid = (lo + hi) >>> 1;
            if (source.get(mid).timeMs < minTimeMs) lo = mid + 1;
            else hi = mid;
        }
        for (int i = lo; i < source.size(); i++) {
            DanmuItem item = source.get(i);
            if (item.timeMs > maxTimeMs) break;
            if (item.timeMs < minTimeMs) continue;
            if (dedupLimit > 0 && containsIdInPrefix(dest, dedupLimit, item.id)) continue;
            dest.add(item);
        }
    }

    private static boolean containsIdInPrefix(List<DanmuItem> list, int limit, String id) {
        for (int i = 0; i < limit; i++) {
            if (id.equals(list.get(i).id)) return true;
        }
        return false;
    }

    private void startWindowFetchLocked(
            final int windowIndex, final boolean isPrefetch, final int gen) {
        if (activeSession == null || windowIndex < 0) return;
        if (windowCache.containsKey(windowIndex) || inFlightWindows.containsKey(windowIndex))
            return;
        final EpisodeSession sessionSnapshot = activeSession;
        final int epochSnapshot = sessionEpoch;
        final CancellationToken token = new CancellationToken();
        inFlightWindows.put(windowIndex, token);
        if (isPrefetch) {
            activePrefetchWindow = windowIndex;
        }
        activeTasks.incrementAndGet();
        workerPool.execute(
                new Runnable() {
                    @Override
                    public void run() {
                        try {
                            List<DanmuItem> items =
                                    fetchWith410Handling(
                                            sessionSnapshot,
                                            epochSnapshot,
                                            windowIndex,
                                            gen,
                                            token);
                            if (items == null) return;
                            final BlockFilter filterSnap;
                            final int filterGenSnap;
                            synchronized (lock) {
                                filterSnap = blockFilter;
                                filterGenSnap = filterGeneration;
                            }
                            List<DanmuItem> bounded = boundWindowItems(items);
                            List<DanmuItem> prefiltered = filterItems(bounded, filterSnap);
                            Listener l = null;
                            synchronized (lock) {
                                if (!closed && gen == bindGeneration && !token.isCancelled()) {
                                    List<DanmuItem> finalFiltered =
                                            filterGenSnap == filterGeneration
                                                    ? prefiltered
                                                    : filterItems(bounded, blockFilter);
                                    putWindowLocked(windowIndex, bounded, finalFiltered);
                                    l = listener;
                                }
                            }
                            if (l != null) {
                                l.onWindowReady(windowIndex, items.size());
                            }
                        } catch (Exception e) {
                            Listener l;
                            synchronized (lock) {
                                l = (closed || token.isCancelled()) ? null : listener;
                            }
                            if (l != null) {
                                l.onError(e.getMessage() == null ? "分片弹幕拉取失败" : e.getMessage());
                            }
                        } finally {
                            synchronized (lock) {
                                if (inFlightWindows.get(windowIndex) == token) {
                                    inFlightWindows.remove(windowIndex);
                                }
                                if (isPrefetch && activePrefetchWindow == windowIndex) {
                                    activePrefetchWindow = -1;
                                }
                            }
                            finishTask();
                        }
                    }
                });
    }

    private List<DanmuItem> fetchWith410Handling(
            EpisodeSession sessionSnapshot,
            int usedEpoch,
            int windowIndex,
            int gen,
            CancellationToken token)
            throws IOException {
        try {
            return provider.fetchWindow(sessionSnapshot, windowIndex, token);
        } catch (HttpStatusException ex) {
            if (ex.statusCode != 410) {
                throw ex;
            }
            EpisodeSession retrySession =
                    resolveSingleflight410Refresh(usedEpoch, windowIndex, gen, token);
            if (retrySession == null) {
                return Collections.emptyList();
            }
            try {
                return provider.fetchWindow(retrySession, windowIndex, token);
            } catch (HttpStatusException retryErr) {
                if (retryErr.statusCode == 410) {
                    // Already retried once for this window; mark empty to stop loops.
                    return Collections.emptyList();
                }
                throw retryErr;
            }
        }
    }

    private EpisodeSession resolveSingleflight410Refresh(
            int usedEpoch, int windowIndex, int gen, CancellationToken token) throws IOException {
        RefreshFlight toLead = null;
        RefreshFlight toAwait = null;
        String currentBoundId;
        synchronized (lock) {
            if (closed || gen != bindGeneration || token.isCancelled()) return null;
            if (retried410Windows.contains(windowIndex)) {
                return null;
            }
            retried410Windows.add(windowIndex);

            // Already refreshed to a newer epoch by a concurrent caller: reuse without openSession!
            if (sessionEpoch > usedEpoch && activeSession != null) {
                return activeSession;
            }
            if (activeRefreshFlight != null && activeRefreshFlight.fromEpoch == usedEpoch) {
                toAwait = activeRefreshFlight;
                currentBoundId = boundEpisodeId;
            } else {
                if (session410RefreshCount >= MAX_SESSION_410_REFRESHES) {
                    return null;
                }
                session410RefreshCount++;
                toLead = new RefreshFlight(usedEpoch);
                activeRefreshFlight = toLead;
                currentBoundId = boundEpisodeId;
            }
        }

        if (toLead != null) {
            try {
                EpisodeSession refreshed = provider.openSession(currentBoundId, token);
                synchronized (lock) {
                    if (!closed && gen == bindGeneration && refreshed != null) {
                        activeSession = refreshed;
                        sessionEpoch++;
                        toLead.newSession = refreshed;
                        toLead.succeeded = true;
                    }
                    if (activeRefreshFlight == toLead) {
                        activeRefreshFlight = null;
                    }
                }
                return toLead.succeeded ? toLead.newSession : null;
            } catch (IOException err) {
                synchronized (lock) {
                    if (activeRefreshFlight == toLead) {
                        activeRefreshFlight = null;
                    }
                }
                return null;
            } finally {
                toLead.latch.countDown();
            }
        }

        if (toAwait != null) {
            try {
                while (!toAwait.latch.await(25L, TimeUnit.MILLISECONDS)) {
                    if (token.isCancelled()) {
                        token.throwIfCancelled();
                    }
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new DanmuProvider.CancelledException("410 singleflight wait interrupted");
            }
            return toAwait.succeeded ? toAwait.newSession : null;
        }
        return null;
    }

    private static List<DanmuItem> boundWindowItems(List<DanmuItem> items) {
        if (items == null || items.isEmpty()) {
            return Collections.emptyList();
        }
        if (items.size() > MAX_WINDOW_ITEMS) {
            return Collections.unmodifiableList(
                    new ArrayList<>(items.subList(0, MAX_WINDOW_ITEMS)));
        }
        return Collections.unmodifiableList(new ArrayList<>(items));
    }

    private void putWindowLocked(
            int windowIndex, List<DanmuItem> boundedRaw, List<DanmuItem> filtered) {
        WindowEntry entry = new WindowEntry(boundedRaw, filtered);
        WindowEntry prev = windowCache.put(windowIndex, entry);
        if (prev != null) {
            totalCachedItems -= prev.rawItems.size();
        }
        totalCachedItems += boundedRaw.size();
        invalidateFastWindowLocked();
        evictIfNeededLocked();
    }

    private boolean isPinnedLocked(int windowIndex) {
        int prev = Math.max(0, currentPinnedWindow - 1);
        return windowIndex == prev
                || windowIndex == currentPinnedWindow
                || windowIndex == currentPinnedWindow + 1;
    }

    private void evictIfNeededLocked() {
        while (windowCache.size() > MAX_CACHED_WINDOWS || totalCachedItems > MAX_TOTAL_ITEMS) {
            boolean evicted = false;
            Iterator<Map.Entry<Integer, WindowEntry>> it = windowCache.entrySet().iterator();
            while (it.hasNext()) {
                Map.Entry<Integer, WindowEntry> entry = it.next();
                if (!isPinnedLocked(entry.getKey())) {
                    totalCachedItems -= entry.getValue().rawItems.size();
                    it.remove();
                    invalidateFastWindowLocked();
                    evicted = true;
                    break;
                }
            }
            if (!evicted) break;
        }
    }

    private void cancelInFlightLocked(boolean cancelOpenSession) {
        if (pendingSeekFuture != null) {
            pendingSeekFuture.cancel(false);
            pendingSeekFuture = null;
        }
        for (CancellationToken token : inFlightWindows.values()) {
            token.cancel();
        }
        inFlightWindows.clear();
        activePrefetchWindow = -1;
        if (cancelOpenSession && openSessionToken != null) {
            openSessionToken.cancel();
            openSessionToken = null;
            openSessionInFlight = false;
        }
    }

    private void finishTask() {
        if (activeTasks.decrementAndGet() <= 0) {
            synchronized (activeTasks) {
                activeTasks.notifyAll();
            }
        }
    }

    public boolean awaitIdle(long timeoutMs) throws InterruptedException {
        long deadline = System.currentTimeMillis() + Math.max(0L, timeoutMs);
        synchronized (activeTasks) {
            while (activeTasks.get() > 0 || hasPendingSeek()) {
                long rem = deadline - System.currentTimeMillis();
                if (rem <= 0L) return false;
                activeTasks.wait(Math.min(rem, 20L));
            }
            return true;
        }
    }

    private boolean hasPendingSeek() {
        synchronized (lock) {
            return pendingSeekFuture != null && !pendingSeekFuture.isDone();
        }
    }

    public int getSessionEpoch() {
        synchronized (lock) {
            return sessionEpoch;
        }
    }

    public int getSession410RefreshCount() {
        synchronized (lock) {
            return session410RefreshCount;
        }
    }

    public int getCachedWindowCount() {
        synchronized (lock) {
            return windowCache.size();
        }
    }

    public int getTotalCachedItemCount() {
        synchronized (lock) {
            return totalCachedItems;
        }
    }

    public boolean isWindowCached(int windowIndex) {
        synchronized (lock) {
            return windowCache.containsKey(windowIndex);
        }
    }

    public EpisodeSession getCurrentSession() {
        synchronized (lock) {
            return activeSession;
        }
    }

    @Override
    public void close() {
        synchronized (lock) {
            if (closed) return;
            closed = true;
            cancelInFlightLocked(true);
            windowCache.clear();
            invalidateFastWindowLocked();
            totalCachedItems = 0;
        }
        scheduler.shutdownNow();
        workerPool.shutdownNow();
    }

    // -------------------------------------------------------------------------
    // Pure-Java Collision-Free Lane Allocator (Linear Kinematics Tail Clearance)
    // -------------------------------------------------------------------------

    public interface TextWidthMeasurer {
        float measureWidth(String text);
    }

    public static final class ActiveSlot {
        public boolean active;
        public String id;
        public String text;
        public int mode;
        public int rgbColor;
        public int lane;
        public long startMs;
        public long durationMs;
        public float widthPx;
        public double velocityPxPerMs;
        public float x;
        public float y;
    }

    /**
     * Zero-allocation-per-frame collision-free danmu layout engine enforcing >= 24px clearance at
     * both right entry ({@code x = W_view}) and left tail exit ({@code x = 0}).
     */
    public static final class LayoutEngine {
        public static final int MIN_ROWS = 2;
        public static final int MAX_SUPPORTED_LANES = 24;
        public static final int MAX_ACTIVE_SLOTS = 384;
        public static final float CLEARANCE_PX = 24.0f;
        public static final float LINE_HEIGHT_FACTOR = 1.42f;
        public static final long PINNED_DURATION_MS = 4000L;
        public static final long MOBILE_BASE_SCROLL_MS = 7600L;
        public static final long TV_BASE_SCROLL_MS = 8200L;
        private static final int DROPPED_RING_SIZE = 256;

        private final double[] entryClearTimeMs = new double[MAX_SUPPORTED_LANES];
        private final double[] tailExitTimeMs = new double[MAX_SUPPORTED_LANES];
        private final double[] prevVelocity = new double[MAX_SUPPORTED_LANES];
        private final long[] topPinnedUntilMs = new long[MAX_SUPPORTED_LANES];
        private final long[] bottomPinnedUntilMs = new long[MAX_SUPPORTED_LANES];
        private final ActiveSlot[] slots = new ActiveSlot[MAX_ACTIVE_SLOTS];
        private final String[] droppedIds = new String[DROPPED_RING_SIZE];

        private int droppedCursor = 0;
        private int activeCount = 0;
        private long lastEffectiveMs = Long.MIN_VALUE;
        private int lastViewW = -1;
        private int lastViewH = -1;
        private float lastFontSizePx = -1f;
        private float lastTopInsetPx = -1f;
        private float lastBottomSafeInsetPx = -1f;

        public LayoutEngine() {
            for (int i = 0; i < MAX_ACTIVE_SLOTS; i++) {
                slots[i] = new ActiveSlot();
            }
            reset();
        }

        public static int computeMaxRows(
                int viewHeightPx,
                float topInsetPx,
                float bottomSafeInsetPx,
                float area,
                float fontSizePx,
                int platformRowCap) {
            int cap = Math.max(MIN_ROWS, Math.min(MAX_SUPPORTED_LANES, platformRowCap));
            if (viewHeightPx <= 0 || fontSizePx <= 0f) return MIN_ROWS;
            float clampedArea = Math.max(0.25f, Math.min(1.0f, area));
            float bottomReserve = clampedArea >= 0.75f ? Math.max(0f, bottomSafeInsetPx) : 0f;
            float usableH = Math.max(0f, viewHeightPx - Math.max(0f, topInsetPx) - bottomReserve);
            int computed =
                    (int) Math.floor((usableH * clampedArea) / (fontSizePx * LINE_HEIGHT_FACTOR));
            return Math.max(MIN_ROWS, Math.min(cap, computed));
        }

        public static long computeScrollDurationMs(boolean isTv, float speedMultiplier) {
            float mult = Math.max(0.5f, Math.min(2.0f, speedMultiplier));
            long base = isTv ? TV_BASE_SCROLL_MS : MOBILE_BASE_SCROLL_MS;
            return Math.max(2500L, Math.round(base / mult));
        }

        public void reset() {
            for (int i = 0; i < MAX_SUPPORTED_LANES; i++) {
                entryClearTimeMs[i] = Double.NEGATIVE_INFINITY;
                tailExitTimeMs[i] = Double.NEGATIVE_INFINITY;
                prevVelocity[i] = 0.0;
                topPinnedUntilMs[i] = Long.MIN_VALUE;
                bottomPinnedUntilMs[i] = Long.MIN_VALUE;
            }
            for (int i = 0; i < MAX_ACTIVE_SLOTS; i++) {
                slots[i].active = false;
                slots[i].id = null;
                slots[i].text = null;
            }
            for (int i = 0; i < DROPPED_RING_SIZE; i++) {
                droppedIds[i] = null;
            }
            droppedCursor = 0;
            activeCount = 0;
            lastEffectiveMs = Long.MIN_VALUE;
        }

        public int allocateScrollLane(
                long startMs, float viewWidthPx, float textWidthPx, long durationMs, int maxRows) {
            int rows = Math.max(MIN_ROWS, Math.min(MAX_SUPPORTED_LANES, maxRows));
            double vCurr = (viewWidthPx + textWidthPx) / (double) durationMs;
            double arriveLeftMs = startMs + (viewWidthPx / vCurr);
            for (int r = 0; r < rows; r++) {
                if ((double) startMs < entryClearTimeMs[r]) continue;
                if (vCurr > prevVelocity[r] && arriveLeftMs < tailExitTimeMs[r]) continue;
                entryClearTimeMs[r] = startMs + (textWidthPx + CLEARANCE_PX) / vCurr;
                tailExitTimeMs[r] = startMs + durationMs + (CLEARANCE_PX / vCurr);
                prevVelocity[r] = vCurr;
                return r;
            }
            return -1;
        }

        public int allocateTopLane(long startMs, int maxRows) {
            int rows = Math.max(MIN_ROWS, Math.min(MAX_SUPPORTED_LANES, maxRows));
            for (int r = 0; r < rows; r++) {
                if (startMs >= topPinnedUntilMs[r]) {
                    topPinnedUntilMs[r] = startMs + PINNED_DURATION_MS;
                    return r;
                }
            }
            return -1;
        }

        public int allocateBottomLane(long startMs, int maxRows) {
            int rows = Math.max(MIN_ROWS, Math.min(MAX_SUPPORTED_LANES, maxRows));
            for (int r = 0; r < rows; r++) {
                if (startMs >= bottomPinnedUntilMs[r]) {
                    bottomPinnedUntilMs[r] = startMs + PINNED_DURATION_MS;
                    return r;
                }
            }
            return -1;
        }

        /**
         * Updates active slots for the current frame with zero object allocations.
         *
         * @return number of active visible slots stored in {@link #getSlots()}
         */
        public int step(
                long effectiveMs,
                List<DanmuItem> candidates,
                int viewW,
                int viewH,
                float fontSizePx,
                float topInsetPx,
                float bottomSafeInsetPx,
                float area,
                int platformRowCap,
                int maxOnScreenItems,
                long scrollDurationMs,
                boolean showScroll,
                boolean showTop,
                boolean showBottom,
                TextWidthMeasurer measurer) {
            return step(
                    effectiveMs,
                    candidates,
                    viewW,
                    viewH,
                    fontSizePx,
                    topInsetPx,
                    bottomSafeInsetPx,
                    area,
                    platformRowCap,
                    maxOnScreenItems,
                    scrollDurationMs,
                    showScroll,
                    showTop,
                    showBottom,
                    measurer,
                    null);
        }

        /**
         * Updates active slots for the current frame with zero object allocations. If an optional
         * {@code entryBlockFilter} is supplied (for unfiltered candidate feeds), each newly
         * arriving danmu is evaluated AT MOST ONCE on entry and recorded in {@code droppedIds}.
         *
         * @return number of active visible slots stored in {@link #getSlots()}
         */
        public int step(
                long effectiveMs,
                List<DanmuItem> candidates,
                int viewW,
                int viewH,
                float fontSizePx,
                float topInsetPx,
                float bottomSafeInsetPx,
                float area,
                int platformRowCap,
                int maxOnScreenItems,
                long scrollDurationMs,
                boolean showScroll,
                boolean showTop,
                boolean showBottom,
                TextWidthMeasurer measurer,
                BlockFilter entryBlockFilter) {
            if (viewW <= 0 || viewH <= 0 || effectiveMs < 0L) {
                reset();
                return 0;
            }
            int maxRows =
                    computeMaxRows(
                            viewH, topInsetPx, bottomSafeInsetPx, area, fontSizePx, platformRowCap);
            // Do NOT include maxRows/area here: adaptive TV row steps (6->4->2 / +1 recovery)
            // must only constrain NEW admissions so already in-flight danmu never reset or
            // teleport.
            boolean geometryChanged =
                    viewW != lastViewW
                            || viewH != lastViewH
                            || Math.abs(fontSizePx - lastFontSizePx) > 0.25f
                            || Math.abs(topInsetPx - lastTopInsetPx) > 0.5f
                            || Math.abs(bottomSafeInsetPx - lastBottomSafeInsetPx) > 0.5f;
            boolean timeJumped =
                    lastEffectiveMs != Long.MIN_VALUE
                            && (effectiveMs < lastEffectiveMs - 100L
                                    || effectiveMs > lastEffectiveMs + 3000L);
            if (geometryChanged || timeJumped) {
                reset();
                lastViewW = viewW;
                lastViewH = viewH;
                lastFontSizePx = fontSizePx;
                lastTopInsetPx = topInsetPx;
                lastBottomSafeInsetPx = bottomSafeInsetPx;
            }
            lastEffectiveMs = effectiveMs;

            // 1. Expire finished or mode-disabled slots in place
            int count = 0;
            for (int i = 0; i < MAX_ACTIVE_SLOTS; i++) {
                ActiveSlot slot = slots[i];
                if (!slot.active) continue;
                long age = effectiveMs - slot.startMs;
                boolean modeDisabled =
                        (slot.mode == 1 && !showScroll)
                                || (slot.mode == 5 && !showTop)
                                || (slot.mode == 4 && !showBottom);
                if (modeDisabled || age < 0L || age > slot.durationMs) {
                    slot.active = false;
                    slot.id = null;
                    slot.text = null;
                } else {
                    count++;
                }
            }
            activeCount = count;

            // 2. Admit newly arrived candidates
            int itemCap = Math.max(1, Math.min(MAX_ACTIVE_SLOTS, maxOnScreenItems));
            boolean hasEntryFilter = entryBlockFilter != null && !entryBlockFilter.isEmpty();
            if (candidates != null) {
                int n = candidates.size();
                for (int i = 0; i < n; i++) {
                    DanmuItem item = candidates.get(i);
                    long age = effectiveMs - item.timeMs;
                    if (age < 0L) break;
                    int mode = item.mode;
                    if (mode == 1 && !showScroll) continue;
                    if (mode == 5 && !showTop) continue;
                    if (mode == 4 && !showBottom) continue;
                    long duration =
                            (mode == 4 || mode == 5) ? PINNED_DURATION_MS : scrollDurationMs;
                    if (age > duration) continue;
                    if (isTrackedOrDropped(item.id)) continue;
                    if (hasEntryFilter && entryBlockFilter.isBlocked(item.text)) {
                        recordDropped(item.id);
                        continue;
                    }

                    if (activeCount >= itemCap) {
                        recordDropped(item.id);
                        continue;
                    }
                    float widthPx = measurer.measureWidth(item.text);
                    int lane;
                    if (mode == 5) {
                        lane = allocateTopLane(item.timeMs, maxRows);
                    } else if (mode == 4) {
                        lane = allocateBottomLane(item.timeMs, maxRows);
                    } else {
                        lane = allocateScrollLane(item.timeMs, viewW, widthPx, duration, maxRows);
                    }
                    if (lane < 0) {
                        recordDropped(item.id);
                        continue;
                    }
                    ActiveSlot free = findFreeSlot();
                    if (free == null) {
                        recordDropped(item.id);
                        continue;
                    }
                    free.active = true;
                    free.id = item.id;
                    free.text = item.text;
                    free.mode = mode;
                    free.rgbColor = item.rgbColor;
                    free.lane = lane;
                    free.startMs = item.timeMs;
                    free.durationMs = duration;
                    free.widthPx = widthPx;
                    free.velocityPxPerMs = (viewW + widthPx) / (double) duration;
                    activeCount++;
                }
            }

            // 3. Update draw coordinates for active slots
            float lineHeightPx = fontSizePx * LINE_HEIGHT_FACTOR;
            float baselineOffsetPx = fontSizePx * 0.22f;
            float safeBottom = Math.max(0f, bottomSafeInsetPx);
            for (int i = 0; i < MAX_ACTIVE_SLOTS; i++) {
                ActiveSlot slot = slots[i];
                if (!slot.active) continue;
                long age = effectiveMs - slot.startMs;
                if (slot.mode == 5) {
                    slot.x = (viewW - slot.widthPx) * 0.5f;
                    slot.y = topInsetPx + (slot.lane + 1) * lineHeightPx - baselineOffsetPx;
                } else if (slot.mode == 4) {
                    slot.x = (viewW - slot.widthPx) * 0.5f;
                    slot.y = viewH - safeBottom - slot.lane * lineHeightPx - baselineOffsetPx;
                } else {
                    slot.x = (float) (viewW - slot.velocityPxPerMs * age);
                    slot.y = topInsetPx + (slot.lane + 1) * lineHeightPx - baselineOffsetPx;
                }
            }
            return activeCount;
        }

        public ActiveSlot[] getSlots() {
            return slots;
        }

        public int getActiveCount() {
            return activeCount;
        }

        public void purgeBlocked(BlockFilter filter) {
            if (filter == null || filter.isEmpty()) return;
            int remaining = 0;
            for (int i = 0; i < MAX_ACTIVE_SLOTS; i++) {
                ActiveSlot s = slots[i];
                if (!s.active) continue;
                if (filter.isBlocked(s.text)) {
                    s.active = false;
                    s.id = null;
                    s.text = null;
                } else {
                    remaining++;
                }
            }
            activeCount = remaining;
        }

        public void onBlockFilterChanged(BlockFilter filter) {
            purgeBlocked(filter);
            for (int i = 0; i < DROPPED_RING_SIZE; i++) {
                droppedIds[i] = null;
            }
            droppedCursor = 0;
        }

        private boolean isTrackedOrDropped(String id) {
            if (id == null) return false;
            for (int i = 0; i < MAX_ACTIVE_SLOTS; i++) {
                ActiveSlot s = slots[i];
                if (s.active && id.equals(s.id)) return true;
            }
            for (int i = 0; i < DROPPED_RING_SIZE; i++) {
                if (id.equals(droppedIds[i])) return true;
            }
            return false;
        }

        private void recordDropped(String id) {
            droppedIds[droppedCursor] = id;
            droppedCursor = (droppedCursor + 1) % DROPPED_RING_SIZE;
        }

        private ActiveSlot findFreeSlot() {
            for (int i = 0; i < MAX_ACTIVE_SLOTS; i++) {
                if (!slots[i].active) return slots[i];
            }
            return null;
        }
    }

    // -------------------------------------------------------------------------
    // TV P90 Frame-Time Adaptive Lane Degradation (Zero Allocations)
    // -------------------------------------------------------------------------

    /**
     * Tracks 30-frame P90 intervals on Android TV to keep low-end ARM32 boxes >= 50fps:
     * 2 consecutive 30-frame windows with {@code P90 > 20.0ms} drop 2 rows (min 2 rows / 20 items);
     * 180 consecutive frames (6 windows) with {@code P90 < 15.5ms} recover +1 row up to ceiling.
     */
    public static final class FramePacingMonitor {
        public static final int WINDOW_FRAMES = 30;
        public static final double DEGRADE_P90_MS = 20.0;
        public static final double RECOVER_P90_MS = 15.5;
        public static final int DEGRADE_STREAK_WINDOWS = 2;
        public static final int RECOVER_CONSECUTIVE_FRAMES = 180;
        public static final int TV_MIN_ROWS = 2;
        public static final int TV_DEFAULT_ROWS = 6;
        public static final int TV_MAX_ROWS = 8;
        public static final int TV_MIN_ITEMS = 20;
        public static final int TV_DEFAULT_ITEMS = 48;

        private final double[] samples = new double[WINDOW_FRAMES];
        private final double[] scratch = new double[WINDOW_FRAMES];
        private int sampleCount = 0;
        private int ceilingRows;
        private int effectiveMaxRows;
        private int effectiveMaxItems;
        private int highLatencyWindowStreak = 0;
        private int lowLatencyFrameStreak = 0;
        private double lastP90Ms = 0.0;

        public FramePacingMonitor() {
            this(TV_DEFAULT_ROWS);
        }

        public FramePacingMonitor(int configuredTvRows) {
            this.ceilingRows = Math.max(TV_MIN_ROWS, Math.min(TV_MAX_ROWS, configuredTvRows));
            this.effectiveMaxRows = this.ceilingRows;
            this.effectiveMaxItems = computeItemsForRows(this.effectiveMaxRows);
        }

        public void setCeilingRows(int configuredTvRows) {
            this.ceilingRows = Math.max(TV_MIN_ROWS, Math.min(TV_MAX_ROWS, configuredTvRows));
            if (effectiveMaxRows > ceilingRows) {
                effectiveMaxRows = ceilingRows;
                effectiveMaxItems = computeItemsForRows(effectiveMaxRows);
            }
        }

        public void reset() {
            sampleCount = 0;
            highLatencyWindowStreak = 0;
            lowLatencyFrameStreak = 0;
            effectiveMaxRows = ceilingRows;
            effectiveMaxItems = computeItemsForRows(effectiveMaxRows);
            lastP90Ms = 0.0;
        }

        public boolean recordFrameIntervalMs(double dtMs) {
            if (dtMs <= 0.0 || dtMs > 250.0) return false;
            samples[sampleCount++] = dtMs;
            if (sampleCount < WINDOW_FRAMES) return false;
            sampleCount = 0;

            System.arraycopy(samples, 0, scratch, 0, WINDOW_FRAMES);
            // In-place insertion sort (zero allocations)
            for (int i = 1; i < WINDOW_FRAMES; i++) {
                double key = scratch[i];
                int j = i - 1;
                while (j >= 0 && scratch[j] > key) {
                    scratch[j + 1] = scratch[j];
                    j--;
                }
                scratch[j + 1] = key;
            }
            // Nearest-rank P90 of 30 samples = index 26 (27th smallest)
            double p90 = scratch[26];
            lastP90Ms = p90;
            int prevRows = effectiveMaxRows;

            if (p90 > DEGRADE_P90_MS) {
                highLatencyWindowStreak++;
                lowLatencyFrameStreak = 0;
                if (highLatencyWindowStreak >= DEGRADE_STREAK_WINDOWS) {
                    effectiveMaxRows = Math.max(TV_MIN_ROWS, effectiveMaxRows - 2);
                    effectiveMaxItems = computeItemsForRows(effectiveMaxRows);
                    highLatencyWindowStreak = 0;
                }
            } else if (p90 < RECOVER_P90_MS) {
                highLatencyWindowStreak = 0;
                lowLatencyFrameStreak += WINDOW_FRAMES;
                if (lowLatencyFrameStreak >= RECOVER_CONSECUTIVE_FRAMES) {
                    effectiveMaxRows = Math.min(ceilingRows, effectiveMaxRows + 1);
                    effectiveMaxItems = computeItemsForRows(effectiveMaxRows);
                    lowLatencyFrameStreak = 0;
                }
            } else {
                highLatencyWindowStreak = 0;
                lowLatencyFrameStreak = 0;
            }
            return effectiveMaxRows != prevRows;
        }

        private static int computeItemsForRows(int rows) {
            if (rows <= TV_MIN_ROWS) return TV_MIN_ITEMS;
            if (rows >= TV_DEFAULT_ROWS) return TV_DEFAULT_ITEMS;
            return Math.max(TV_MIN_ITEMS, (TV_DEFAULT_ITEMS * rows) / TV_DEFAULT_ROWS);
        }

        public int getEffectiveMaxRows() {
            return effectiveMaxRows;
        }

        public int getEffectiveMaxItems() {
            return effectiveMaxItems;
        }

        public double getLastP90Ms() {
            return lastP90Ms;
        }
    }

    /**
     * Monotonic sub-tick media clock interpolator that re-anchors smoothly whenever {@code
     * playSpeed} changes (e.g. M2 long-press 2.0x boost release -> 1.0x), preventing backward
     * jumps that would trigger {@link LayoutEngine#reset()}.
     */
    public static final class SmoothClock {
        private int lastRawPos = -1;
        private long smoothBasePosMs = -1L;
        private long lastSampleWallMs = 0L;
        private float playSpeed = 1.0f;

        public void reset() {
            lastRawPos = -1;
            smoothBasePosMs = -1L;
            lastSampleWallMs = 0L;
        }

        public float getPlaySpeed() {
            return playSpeed;
        }

        public void setPlaySpeed(float speed, int currentRawPos, boolean playing, long wallMs) {
            float clamped = Math.max(0.5f, Math.min(2.0f, speed));
            if (playing && lastRawPos >= 0) {
                smoothBasePosMs = sample(currentRawPos, true, wallMs);
                lastSampleWallMs = wallMs;
            }
            playSpeed = clamped;
        }

        public long sample(int raw, boolean playing, long wallMs) {
            if (!playing) {
                lastRawPos = raw;
                smoothBasePosMs = raw;
                lastSampleWallMs = wallMs;
                return raw;
            }
            if (lastRawPos < 0 || Math.abs(raw - lastRawPos) > 1200) {
                lastRawPos = raw;
                smoothBasePosMs = raw;
                lastSampleWallMs = wallMs;
                return raw;
            }
            if (raw != lastRawPos) {
                long prevElapsed = Math.max(0L, Math.min(500L, wallMs - lastSampleWallMs));
                long prevInterp = smoothBasePosMs + Math.round(prevElapsed * playSpeed);
                if (raw >= lastRawPos && raw < prevInterp) {
                    smoothBasePosMs = prevInterp;
                } else {
                    smoothBasePosMs = raw;
                }
                lastRawPos = raw;
                lastSampleWallMs = wallMs;
                return smoothBasePosMs;
            }
            long elapsed = Math.max(0L, Math.min(500L, wallMs - lastSampleWallMs));
            return smoothBasePosMs + Math.round(elapsed * playSpeed);
        }
    }
}
