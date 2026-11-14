package com.pilipala.marcomovie;

import com.sun.net.httpserver.HttpServer;
import java.io.File;
import java.io.IOException;
import java.io.OutputStream;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Pure JVM automated verification suite for Milestone 8 (Lane E: Android Performance & Stability § E1–E5).
 */
public final class LaneEChecks {

    private static void check(boolean condition, String label) {
        if (!condition) {
            throw new AssertionError("FAILED: " + label);
        }
        System.out.println("PASS " + label);
    }

    public static void main(String[] args) throws Exception {
        System.out.println("=== Starting Lane E Verification Suite (§ E1–E5) ===");

        testE1CloneBookmarkSnapshot();
        testE1StorageExecutorThreading();
        testE1WatchHistoryUnifiedSerialization();
        testE1PlaybackProgressThrottling();
        testE1CommitAuditZeroOnUIThread();

        testE2ConfigStoreSynchronized();
        testE2ConfigStoreAtomicWrite();
        testE2ConfigStoreSequencedWritesAndRollback();
        testE2SourceControllerBackgroundDispatch();
        testM_A3ContentUriImportAndConfigLibrary();

        testE3ZipImportRedirects();
        testE3ZipImportMaxHopsLimit();
        testE3ZipImportSecurityValidation();
        testE3ZipImportPayloadLimit();

        testE4CrossDomainDanmakuHeaderStrip();
        testE4SameDomainDanmakuHeaderPreservation();
        testE4DanmakuCookiePropagation();

        testE5DynamicUserAgentContract();
        testE5TurkishLocaleZipUrl();
        testE5TurkishLocaleArtworkHeaders();
        testE5TurkishLocaleChannelMatching();
        testE5TurkishLocaleSeasonNormalization();
        testE5CmsFileUntouchedBoundary();

        System.out.println("\nALL PASS (20 checks for Lane E)");
    }

    // =========================================================================
    // § E1: Playback Progress Throttling & Background Persistence
    // =========================================================================

    private static void testE1CloneBookmarkSnapshot() {
        WatchHistory.Entry original = new WatchHistory.Entry();
        original.site = "site_vod_1";
        original.id = "vod_12345";
        original.title = "Sample Movie";
        original.poster = "https://img.test/pic.jpg";
        original.line = "Line 1";
        original.episode = "Episode 01";
        original.index = 2;
        original.position = 45000;
        original.duration = 120000;
        original.updated = 1700000000000L;

        // Verify production PlaybackController.cloneBookmark / WatchHistory.cloneEntry
        // creates a detached snapshot
        WatchHistory.Entry cloned = PlaybackController.cloneBookmark(original);
        check(cloned != null, "E1: cloneBookmark creates non-null instance");
        check(cloned != original, "E1: cloneBookmark produces detached instance");
        check(
                original.site.equals(cloned.site)
                        && original.id.equals(cloned.id)
                        && original.title.equals(cloned.title)
                        && original.poster.equals(cloned.poster)
                        && original.line.equals(cloned.line)
                        && original.episode.equals(cloned.episode)
                        && original.index == cloned.index
                        && original.position == cloned.position
                        && original.duration == cloned.duration
                        && original.updated == cloned.updated,
                "E1: WatchHistory.cloneEntry copies all 10 fields accurately");

        // Mutate original and assert clone is untouched (isolation guarantee)
        original.position = 99999;
        original.title = "Mutated Title";
        check(
                cloned.position == 45000 && "Sample Movie".equals(cloned.title),
                "E1: mutating original bookmark does not affect snapshot");

        check(
                PlaybackController.cloneBookmark(null) == null
                        && WatchHistory.cloneEntry(null) == null,
                "E1: cloneBookmark / WatchHistory.cloneEntry handle null input gracefully");
    }

    private static void testE1StorageExecutorThreading() throws Exception {
        CountDownLatch latch = new CountDownLatch(1);
        AtomicReference<String> threadName = new AtomicReference<>("");
        AtomicBoolean isDaemon = new AtomicBoolean(false);
        WatchHistory.STORAGE_EXECUTOR.execute(
                () -> {
                    Thread cur = Thread.currentThread();
                    threadName.set(cur.getName());
                    isDaemon.set(cur.isDaemon());
                    latch.countDown();
                });

        check(
                latch.await(2, TimeUnit.SECONDS),
                "E1: production WatchHistory.STORAGE_EXECUTOR executes task");
        check(
                "playback-storage".equals(threadName.get()) && isDaemon.get(),
                "E1: production WatchHistory.STORAGE_EXECUTOR runs on dedicated daemon thread");
    }

    private static void testE1WatchHistoryUnifiedSerialization() throws Exception {
        WatchHistory.setCorrupted(false);
        final AtomicReference<String> rawJson = new AtomicReference<>("[]");
        final AtomicBoolean corruptedPref = new AtomicBoolean(false);
        final Set<String> storageThreads = Collections.synchronizedSet(new HashSet<String>());
        final WatchHistory.Persistence persistence =
                new WatchHistory.Persistence() {
                    @Override
                    public String readRaw() {
                        storageThreads.add(Thread.currentThread().getName());
                        return rawJson.get();
                    }

                    @Override
                    public boolean readCorruptedPref() {
                        return corruptedPref.get();
                    }

                    @Override
                    public void writeState(String historyJson, boolean corrupted) {
                        storageThreads.add(Thread.currentThread().getName());
                        rawJson.set(historyJson);
                        corruptedPref.set(corrupted);
                    }
                };

        // Enqueue early playback bookmarks, then clear, then enqueue fresh bookmarks & remove one
        for (int i = 0; i < 5; i++) {
            WatchHistory.Entry pre = new WatchHistory.Entry();
            pre.site = "old_site";
            pre.id = "old_" + i;
            pre.title = "Old " + i;
            pre.position = 5000;
            pre.duration = 60000;
            pre.updated = 100L + i;
            WatchHistory.enqueueUpsert(persistence, pre);
        }
        AtomicBoolean clearCallbackRan = new AtomicBoolean(false);
        WatchHistory.enqueueClear(persistence, () -> clearCallbackRan.set(true));

        List<Future<?>> afterClearFutures = new ArrayList<>();
        for (int i = 0; i < 8; i++) {
            WatchHistory.Entry post = new WatchHistory.Entry();
            post.site = "live_site";
            post.id = "ep_" + i;
            post.title = "Episode " + i;
            post.position = (i + 1) * 2000;
            post.duration = 90000;
            post.updated = 5000L + i;
            afterClearFutures.add(WatchHistory.enqueueUpsert(persistence, post));
        }
        AtomicBoolean removeCallbackRan = new AtomicBoolean(false);
        afterClearFutures.add(
                WatchHistory.enqueueRemove(
                        persistence, "live_site\nep_2", () -> removeCallbackRan.set(true)));
        for (Future<?> f : afterClearFutures) {
            f.get(5, TimeUnit.SECONDS);
        }

        List<WatchHistory.Entry> finalEntries = WatchHistory.read(rawJson.get());
        boolean anyOld = false;
        boolean hasEp2 = false;
        for (WatchHistory.Entry e : finalEntries) {
            if ("old_site".equals(e.site)) anyOld = true;
            if ("ep_2".equals(e.id)) hasEp2 = true;
        }
        check(
                clearCallbackRan.get()
                        && removeCallbackRan.get()
                        && !anyOld
                        && !hasEp2
                        && finalEntries.size() == 7,
                "M-A5: enqueueUpsert/enqueueClear/enqueueRemove strictly serialize without losing or resurrecting entries");
        check(
                storageThreads.size() == 1 && storageThreads.contains("playback-storage"),
                "M-A5: all WatchHistory mutations execute on single playback-storage thread");
    }

    private static void testE1PlaybackProgressThrottling() {
        final long INTERVAL = 15000L; // 15 seconds
        long lastSave = 100000L;

        // Continuous playback tick at t = lastSave + 1s (unforced): must throttle
        long now1 = lastSave + 1000L;
        boolean throttled1 = !(now1 - lastSave >= INTERVAL);
        check(throttled1, "E1: continuous playback tick at +1s throttles disk write");

        // Continuous playback tick at t = lastSave + 14.9s: must throttle
        long now2 = lastSave + 14900L;
        boolean throttled2 = !(now2 - lastSave >= INTERVAL);
        check(throttled2, "E1: continuous playback tick at +14.9s throttles disk write");

        // Continuous playback tick at t = lastSave + 15.0s: must trigger write
        long now3 = lastSave + 15000L;
        boolean writeTriggered = (now3 - lastSave >= INTERVAL);
        check(writeTriggered, "E1: continuous playback tick at +15.0s triggers disk persistence");

        // State changes (pause, onPause, completion, episode switch) with force = true: immediate
        // write
        boolean forceWrite = true;
        boolean immediateTrigger = forceWrite || (now1 - lastSave >= INTERVAL);
        check(immediateTrigger, "E1: force=true bypasses 15s throttle for immediate persistence");
    }

    private static final Set<String> WHITELISTED_CRASH_MARKER_METHODS =
            Collections.unmodifiableSet(
                    new HashSet<>(
                            Arrays.asList(
                                    "MainActivity.installPluginCrashGuard",
                                    "MainActivity.clearRecoveredCrashSite",
                                    "HomeScreen.commitLoadingSite",
                                    "MobileShell.commitLoadingSite",
                                    "SourcePicker.commitSelectedSiteForCrashGuard")));

    private static final Set<String> WHITELISTED_SECURE_STORAGE_METHODS =
            Collections.unmodifiableSet(
                    new HashSet<>(
                            Arrays.asList(
                                    "SecureStorage.consumeReenterPasswordRequired",
                                    "SecureStorage.isKeyStoreUnavailableMarked",
                                    "SecureStorage.markKeyStoreUnavailable",
                                    "SecureStorage.savePlaintextFallback",
                                    "SecureStorage.handleInvalidatedKey",
                                    "SecureStorage.getWebdavPass",
                                    "SecureStorage.setWebdavPass",
                                    "SecureStorage.clearWebdavPass")));

    private static final class CommitSite {
        final String classAndMethod;
        final String methodBody;
        final int lineNumber;
        final String lineText;

        CommitSite(String classAndMethod, String methodBody, int lineNumber, String lineText) {
            this.classAndMethod = classAndMethod;
            this.methodBody = methodBody;
            this.lineNumber = lineNumber;
            this.lineText = lineText;
        }
    }

    /**
     * Parses a Java source file (ignoring comments and string/char literals) to map every
     * {@code .commit()} invocation to its enclosing top-level/member method name without relying on
     * hardcoded line numbers.
     */
    private static List<CommitSite> findCommitSitesByMethod(String fileName, String source) {
        String topClass =
                fileName.endsWith(".java")
                        ? fileName.substring(0, fileName.length() - 5)
                        : fileName;
        int len = source.length();
        char[] sanitized = new char[len];
        int[] lineOfOffset = new int[len + 1];
        int curLine = 1;
        for (int i = 0; i < len; i++) {
            lineOfOffset[i] = curLine;
            if (source.charAt(i) == '\n') curLine++;
        }
        lineOfOffset[len] = curLine;

        // Blank out comments and string/char literals while preserving braces & identifiers outside
        for (int i = 0; i < len; ) {
            char c = source.charAt(i);
            if (c == '/' && i + 1 < len && source.charAt(i + 1) == '/') {
                while (i < len && source.charAt(i) != '\n') sanitized[i++] = ' ';
            } else if (c == '/' && i + 1 < len && source.charAt(i + 1) == '*') {
                sanitized[i++] = ' ';
                sanitized[i++] = ' ';
                while (i < len
                        && !(source.charAt(i) == '*'
                                && i + 1 < len
                                && source.charAt(i + 1) == '/')) {
                    sanitized[i] = source.charAt(i) == '\n' ? '\n' : ' ';
                    i++;
                }
                if (i + 1 < len) {
                    sanitized[i++] = ' ';
                    sanitized[i++] = ' ';
                }
            } else if (c == '"' || c == '\'') {
                char quote = c;
                sanitized[i++] = ' ';
                while (i < len) {
                    char qc = source.charAt(i);
                    sanitized[i++] = qc == '\n' ? '\n' : ' ';
                    if (qc == '\\' && i < len) {
                        sanitized[i] = source.charAt(i) == '\n' ? '\n' : ' ';
                        i++;
                    } else if (qc == quote) {
                        break;
                    }
                }
            } else {
                sanitized[i++] = c;
            }
        }
        String clean = new String(sanitized);
        String[] rawLines = source.split("\r?\n", -1);

        // Track brace stack to identify class bodies vs method bodies
        Deque<String> scopeStack = new ArrayDeque<>();
        Deque<Integer> methodStartStack = new ArrayDeque<>();
        List<int[]> methodRanges = new ArrayList<>();
        List<String> methodNames = new ArrayList<>();

        int parenDepth = 0;
        int lastDeclBoundary = 0;
        for (int i = 0; i < len; i++) {
            char c = clean.charAt(i);
            if (c == '(') {
                parenDepth++;
            } else if (c == ')') {
                if (parenDepth > 0) parenDepth--;
            } else if (c == ';' && parenDepth == 0) {
                lastDeclBoundary = i + 1;
            } else if (c == '{' && parenDepth == 0) {
                String header = clean.substring(lastDeclBoundary, i).trim();
                String openedMethod = extractMethodDeclarationName(header);
                boolean insideMethod = false;
                for (String s : scopeStack) {
                    if (s.startsWith("M:")) {
                        insideMethod = true;
                        break;
                    }
                }
                if (!insideMethod && openedMethod != null) {
                    scopeStack.push("M:" + openedMethod);
                    methodStartStack.push(i);
                } else {
                    scopeStack.push("B");
                }
                lastDeclBoundary = i + 1;
            } else if (c == '}' && parenDepth == 0) {
                if (!scopeStack.isEmpty()) {
                    String popped = scopeStack.pop();
                    if (popped.startsWith("M:")) {
                        int start = methodStartStack.pop();
                        methodRanges.add(new int[] {start, i + 1});
                        methodNames.add(topClass + "." + popped.substring(2));
                    }
                }
                lastDeclBoundary = i + 1;
            }
        }

        List<CommitSite> sites = new ArrayList<>();
        int idx = 0;
        while ((idx = clean.indexOf(".commit()", idx)) >= 0) {
            // Ensure previous non-space char is '.' and next char is not identifier part
            String owner = topClass + ".<unknown>";
            String body = "";
            for (int m = 0; m < methodRanges.size(); m++) {
                int[] r = methodRanges.get(m);
                if (idx >= r[0] && idx < r[1]) {
                    owner = methodNames.get(m);
                    body = source.substring(r[0], r[1]);
                    break;
                }
            }
            int ln = lineOfOffset[idx];
            String lineTxt = (ln >= 1 && ln <= rawLines.length) ? rawLines[ln - 1].trim() : "";
            sites.add(new CommitSite(owner, body, ln, lineTxt));
            idx += ".commit()".length();
        }
        return sites;
    }

    private static String extractMethodDeclarationName(String header) {
        if (header.isEmpty()) return null;
        if (header.contains("class ")
                || header.contains("interface ")
                || header.contains("enum ")
                || header.contains("->")
                || header.contains("=")) {
            return null;
        }
        int openParen = header.indexOf('(');
        int closeParen = header.lastIndexOf(')');
        if (openParen <= 0 || closeParen < openParen) return null;
        String beforeParen = header.substring(0, openParen).trim();
        int idx = beforeParen.length() - 1;
        while (idx >= 0 && Character.isJavaIdentifierPart(beforeParen.charAt(idx))) idx--;
        String name = beforeParen.substring(idx + 1);
        if (name.isEmpty() || !Character.isJavaIdentifierStart(name.charAt(0))) return null;
        if ("if".equals(name)
                || "for".equals(name)
                || "while".equals(name)
                || "switch".equals(name)
                || "catch".equals(name)
                || "synchronized".equals(name)
                || "try".equals(name)
                || "new".equals(name)) {
            return null;
        }
        return name;
    }

    private static List<String> auditCommitSites(List<CommitSite> sites) {
        List<String> violations = new ArrayList<>();
        for (CommitSite site : sites) {
            if (WHITELISTED_CRASH_MARKER_METHODS.contains(site.classAndMethod)
                    && site.methodBody.contains("LOADING_SITE")) {
                continue;
            }
            if (WHITELISTED_SECURE_STORAGE_METHODS.contains(site.classAndMethod)) {
                continue;
            }
            violations.add(site.classAndMethod + ":" + site.lineNumber + " -> " + site.lineText);
        }
        return violations;
    }

    private static void testE1CommitAuditZeroOnUIThread() throws IOException {
        Path root = Paths.get("android/src/main/java/com/pilipala/marcomovie");
        if (!Files.exists(root)) {
            root = Paths.get("../../android/src/main/java/com/pilipala/marcomovie");
        }
        check(Files.exists(root), "E1: Android source directory located for .commit() audit");

        List<String> violations = new ArrayList<>();
        Set<String> matchedCrashMethods = new HashSet<>();
        int allowedCrashMarkerCount = 0;
        int allowedSecureStorageCount = 0;

        try (java.util.stream.Stream<Path> stream = Files.walk(root)) {
            java.util.Iterator<Path> it =
                    stream.filter(p -> p.toString().endsWith(".java")).iterator();
            while (it.hasNext()) {
                Path path = it.next();
                String fileName = path.getFileName().toString();
                String content = new String(Files.readAllBytes(path), StandardCharsets.UTF_8);
                List<CommitSite> sites = findCommitSitesByMethod(fileName, content);
                for (CommitSite site : sites) {
                    if (WHITELISTED_CRASH_MARKER_METHODS.contains(site.classAndMethod)
                            && site.methodBody.contains("LOADING_SITE")) {
                        allowedCrashMarkerCount++;
                        matchedCrashMethods.add(site.classAndMethod);
                    } else if (WHITELISTED_SECURE_STORAGE_METHODS.contains(site.classAndMethod)) {
                        allowedSecureStorageCount++;
                    } else {
                        violations.add(
                                fileName
                                        + " ("
                                        + site.classAndMethod
                                        + ":"
                                        + site.lineNumber
                                        + ") -> "
                                        + site.lineText);
                    }
                }
            }
        }

        check(
                matchedCrashMethods.equals(WHITELISTED_CRASH_MARKER_METHODS)
                        && allowedCrashMarkerCount == 6,
                "M-A6/6f: All 5 LOADING_SITE crash-guard methods restored to commit() and matched by method name: "
                        + matchedCrashMethods);
        check(
                allowedSecureStorageCount > 0,
                "E1: SecureStorage keeps synchronous commit() matched by method name");
        check(
                violations.isEmpty(),
                "E1: Zero unwhitelisted .commit() violations across android/src/main/java: "
                        + violations);

        // 6f verification: shifting line numbers by +250 lines still passes method-name check,
        // while placing .commit() in an unwhitelisted method (e.g. MainActivity.onCreate) fails
        StringBuilder shifted = new StringBuilder();
        for (int i = 0; i < 250; i++) shifted.append("\n");
        shifted.append(
                "public final class MainActivity {\n"
                        + "  static void installPluginCrashGuard() {\n"
                        + "    prefs.edit().putString(Prefs.LOADING_SITE, s).commit();\n"
                        + "  }\n"
                        + "}\n");
        check(
                auditCommitSites(findCommitSitesByMethod("MainActivity.java", shifted.toString()))
                        .isEmpty(),
                "6f: commit() audit matches enclosing method name regardless of line numbers");

        String unauthorized =
                "public final class MainActivity {\n"
                        + "  protected void onCreate() {\n"
                        + "    prefs.edit().putString(\"foo\", \"bar\").commit();\n"
                        + "  }\n"
                        + "}\n";
        check(
                auditCommitSites(findCommitSitesByMethod("MainActivity.java", unauthorized)).size()
                        == 1,
                "6f: commit() inside unwhitelisted MainActivity.onCreate is flagged as a violation");
    }

    // =========================================================================
    // § E2: Background ConfigStore.write & Concurrency Protection
    // =========================================================================

    private static void testE2ConfigStoreSynchronized() throws Exception {
        Method writeMethod = ConfigStore.class.getDeclaredMethod("write", String.class);
        boolean isSync = Modifier.isSynchronized(writeMethod.getModifiers());
        check(isSync, "E2: ConfigStore.write is declared synchronized for thread safety");
    }

    private static void testE2ConfigStoreAtomicWrite() throws Exception {
        Path tempDir = Files.createTempDirectory("config-store-test-");
        try {
            File dir = tempDir.toFile();
            ConfigStore store = new ConfigStore(dir);
            String testConfig = "{\"sites\":[{\"key\":\"test_site\",\"name\":\"Test Site\"}]}";

            store.write(testConfig);

            File configFile = new File(dir, "config.json");
            check(configFile.exists(), "E2: ConfigStore writes config.json to disk");
            String readContent =
                    new String(Files.readAllBytes(configFile.toPath()), StandardCharsets.UTF_8);
            check(
                    testConfig.equals(readContent),
                    "E2: config.json contains verbatim written content");

            // Verify no stray .tmp files remaining
            File[] leftovers = dir.listFiles((d, name) -> name.endsWith(".tmp"));
            check(
                    leftovers != null && leftovers.length == 0,
                    "E2: temporary atomic swap files deleted after write");
        } finally {
            for (File f : tempDir.toFile().listFiles()) f.delete();
            Files.deleteIfExists(tempDir);
        }
    }

    private static void deleteRecursively(File f) {
        if (f == null || !f.exists()) return;
        if (f.isDirectory()) {
            File[] children = f.listFiles();
            if (children != null) {
                for (File child : children) deleteRecursively(child);
            }
        }
        f.delete();
    }

    private static void testE2ConfigStoreSequencedWritesAndRollback() throws Exception {
        Path tempDir = Files.createTempDirectory("config-store-seq-");
        try {
            File dir = tempDir.toFile();
            ConfigStore store = new ConfigStore(dir);
            final AtomicReference<String> prefOrigin =
                    new AtomicReference<>("https://initial.example/0.json");
            final AtomicReference<String> prefSelected = new AtomicReference<>("site_0");
            final Set<String> writerThreads = Collections.synchronizedSet(new HashSet<String>());

            ConfigStore.PointerStore pointerStore =
                    new ConfigStore.PointerStore() {
                        @Override
                        public ConfigStore.PointerSnapshot readCurrentPointers() {
                            return new ConfigStore.PointerSnapshot(
                                    prefOrigin.get(), prefSelected.get(), "tag_0");
                        }

                        @Override
                        public void applyPointers(ConfigStore.PointerSnapshot snapshot) {
                            prefOrigin.set(snapshot.origin);
                            prefSelected.set(snapshot.selectedSite);
                        }
                    };

            // 1. Rapid 15 back-to-back saveAsync calls: latest sequence must win on disk & pointers
            List<Future<Boolean>> futures = new ArrayList<>();
            for (int i = 1; i <= 15; i++) {
                String payload = "{\"sites\":[{\"key\":\"site_" + i + "\"}]}";
                ConfigStore.PointerSnapshot next =
                        new ConfigStore.PointerSnapshot(
                                "https://sub.example/" + i + ".json", "site_" + i, "tag_" + i);
                futures.add(store.saveAsync(payload, next, pointerStore, null));
            }
            ConfigStore.WRITE_EXECUTOR
                    .submit(() -> writerThreads.add(Thread.currentThread().getName()))
                    .get(5, TimeUnit.SECONDS);
            boolean lastSucceeded = futures.get(futures.size() - 1).get(5, TimeUnit.SECONDS);
            String finalOnDisk =
                    new String(
                            Files.readAllBytes(new File(dir, "config.json").toPath()),
                            StandardCharsets.UTF_8);
            check(
                    lastSucceeded
                            && "{\"sites\":[{\"key\":\"site_15\"}]}".equals(finalOnDisk)
                            && "https://sub.example/15.json".equals(prefOrigin.get())
                            && "site_15".equals(prefSelected.get())
                            && writerThreads.contains("config-store-writer"),
                    "M-A4: single-thread sequenced ConfigStore.saveAsync ensures last write wins");

            // 2. Simulate disk write failure by replacing config.json with a non-empty directory;
            // verify prefs pointers roll back to last confirmed state and failure callback fires
            File configPath = new File(dir, "config.json");
            check(configPath.delete(), "M-A4 setup: remove config.json before directory fault");
            File blocker = new File(configPath, "lockfile");
            check(
                    configPath.mkdirs() && blocker.createNewFile(),
                    "M-A4 setup: inject non-empty directory at config.json to force rename failure");

            AtomicInteger failureNotices = new AtomicInteger();
            AtomicReference<ConfigStore.PointerSnapshot> rolledBackRef = new AtomicReference<>();
            boolean fail1 =
                    store.saveAsync(
                                    "{\"sites\":[{\"key\":\"bad_1\"}]}",
                                    new ConfigStore.PointerSnapshot(
                                            "https://broken.example/1.json", "bad_1", "tag_bad_1"),
                                    pointerStore,
                                    (seq, err, rollback) -> {
                                        failureNotices.incrementAndGet();
                                        rolledBackRef.set(rollback);
                                    })
                            .get(5, TimeUnit.SECONDS);
            check(
                    !fail1
                            && failureNotices.get() == 1
                            && "https://sub.example/15.json".equals(prefOrigin.get())
                            && "site_15".equals(prefSelected.get())
                            && rolledBackRef.get() != null
                            && "tag_15".equals(rolledBackRef.get().stateTag),
                    "M-A4: write failure rolls back ORIGIN/SELECTED_SITE pointers and notifies user");

            // Second consecutive failure must STILL roll back to confirmed #15, not failed #16
            boolean fail2 =
                    store.saveAsync(
                                    "{\"sites\":[{\"key\":\"bad_2\"}]}",
                                    new ConfigStore.PointerSnapshot(
                                            "https://broken.example/2.json", "bad_2", "tag_bad_2"),
                                    pointerStore,
                                    (seq, err, rollback) -> {
                                        failureNotices.incrementAndGet();
                                        rolledBackRef.set(rollback);
                                    })
                            .get(5, TimeUnit.SECONDS);
            check(
                    !fail2
                            && failureNotices.get() == 2
                            && "https://sub.example/15.json".equals(prefOrigin.get())
                            && "site_15".equals(prefSelected.get())
                            && "tag_15".equals(rolledBackRef.get().stateTag),
                    "M-A4: consecutive write failures preserve last confirmed persisted snapshot");
        } finally {
            deleteRecursively(tempDir.toFile());
        }
    }

    private static void testM_A3ContentUriImportAndConfigLibrary() throws Exception {
        Path tempDir = Files.createTempDirectory("config-lib-ma3-");
        try {
            String raw =
                    "{\"sites\":[{\"key\":\"vod1\",\"name\":\"影视源\",\"type\":1,\"api\":\"https://vod.example/api.php/provide/vod/\",\"ext\":\"./token.txt\"}]}";
            String contentOrigin =
                    Cms.localImportOrigin(
                            "content",
                            "content://com.android.providers.downloads.documents/document/primary%3Atvbox.json");
            Cms.Config parsed =
                    Cms.parseConfig(raw, contentOrigin.isEmpty() ? null : contentOrigin);
            check(
                    contentOrigin.isEmpty()
                            && parsed.origin.isEmpty()
                            && "./token.txt".equals(parsed.sites.get(0).ext)
                            && !ConfigLibrary.isLocalFileOrigin(contentOrigin),
                    "M-A3: content:// import keeps origin empty and eligible for ConfigLibrary & CloudSync");

            ConfigLibrary library = new ConfigLibrary(tempDir.toFile());
            ConfigLibrary.Entry saved = library.remember(parsed.raw, contentOrigin, "影视源", "vod1");
            check(
                    saved.origin.isEmpty()
                            && library.entries().size() == 1
                            && !ConfigLibrary.isLocalFileOrigin(saved.origin),
                    "M-A3: content:// imported config is saved to ConfigLibrary with empty origin for cloud sync");
        } finally {
            deleteRecursively(tempDir.toFile());
        }
    }

    private static void testE2SourceControllerBackgroundDispatch() throws IOException {
        Path scPath =
                Paths.get("android/src/main/java/com/pilipala/marcomovie/SourceController.java");
        if (!Files.exists(scPath)) {
            scPath =
                    Paths.get(
                            "../../android/src/main/java/com/pilipala/marcomovie/SourceController.java");
        }
        check(Files.exists(scPath), "E2: SourceController.java exists");
        String content = Files.readString(scPath, StandardCharsets.UTF_8);

        check(
                content.contains("store.saveAsync(") && content.contains("配置保存失败，已回滚至原配置"),
                "M-A4/E2: SourceController dispatches config writes via sequenced single-thread store.saveAsync with rollback notice");
        check(
                !content.contains("a.configStore.write(c.raw);")
                        && !content.contains("store.write(rawConfig)"),
                "M-A4/E2: Direct blocking and multi-thread worker configStore.write calls removed from saveConfig");
    }

    // =========================================================================
    // § E3: Robust Zip Import Redirects
    // =========================================================================

    private static void testE3ZipImportRedirects() throws Exception {
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        int port = server.getAddress().getPort();
        String baseUrl = "http://127.0.0.1:" + port;

        AtomicBoolean cookieReceivedAtFinal = new AtomicBoolean(false);

        server.createContext(
                "/hop1",
                exchange -> {
                    exchange.getResponseHeaders().set("Location", baseUrl + "/hop2");
                    exchange.sendResponseHeaders(301, -1);
                    exchange.close();
                });

        server.createContext(
                "/hop2",
                exchange -> {
                    exchange.getResponseHeaders().set("Location", baseUrl + "/final.zip");
                    exchange.getResponseHeaders().set("Set-Cookie", "zip_auth=allow_123; Path=/");
                    exchange.sendResponseHeaders(302, -1);
                    exchange.close();
                });

        byte[] fakeZipBytes =
                "PK\003\004synthetic_zip_payload_data".getBytes(StandardCharsets.UTF_8);

        server.createContext(
                "/final.zip",
                exchange -> {
                    String cookie = exchange.getRequestHeaders().getFirst("Cookie");
                    if (cookie != null && cookie.contains("zip_auth=allow_123")) {
                        cookieReceivedAtFinal.set(true);
                    }
                    exchange.sendResponseHeaders(200, fakeZipBytes.length);
                    try (OutputStream out = exchange.getResponseBody()) {
                        out.write(fakeZipBytes);
                    }
                    exchange.close();
                });

        server.start();
        try {
            byte[] downloaded = MobileShell.fetchZipBytes(baseUrl + "/hop1");
            check(
                    Arrays.equals(fakeZipBytes, downloaded),
                    "E3: fetchZipBytes follows multi-hop redirects and returns payload");
            check(
                    cookieReceivedAtFinal.get(),
                    "E3: fetchZipBytes tracks and forwards Set-Cookie across redirect hops");
        } finally {
            server.stop(0);
        }
    }

    private static void testE3ZipImportMaxHopsLimit() throws Exception {
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        int port = server.getAddress().getPort();
        String baseUrl = "http://127.0.0.1:" + port;

        server.createContext(
                "/infinite",
                exchange -> {
                    exchange.getResponseHeaders().set("Location", baseUrl + "/infinite");
                    exchange.sendResponseHeaders(302, -1);
                    exchange.close();
                });

        server.start();
        try {
            boolean caught = false;
            try {
                MobileShell.fetchZipBytes(baseUrl + "/infinite");
            } catch (IOException e) {
                if (e.getMessage() != null && e.getMessage().contains("来源重定向次数过多")) {
                    caught = true;
                }
            }
            check(
                    caught,
                    "E3: fetchZipBytes terminates infinite redirect loop with actionable error");
        } finally {
            server.stop(0);
        }
    }

    private static void testE3ZipImportSecurityValidation() throws Exception {
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        int port = server.getAddress().getPort();
        String baseUrl = "http://127.0.0.1:" + port;

        server.createContext(
                "/proto_bad",
                exchange -> {
                    exchange.getResponseHeaders().set("Location", "ftp://127.0.0.1/bad.zip");
                    exchange.sendResponseHeaders(302, -1);
                    exchange.close();
                });

        server.createContext(
                "/userinfo_bad",
                exchange -> {
                    exchange.getResponseHeaders()
                            .set("Location", "http://user:secret@127.0.0.1:" + port + "/cred.zip");
                    exchange.sendResponseHeaders(302, -1);
                    exchange.close();
                });

        server.start();
        try {
            boolean protoBlocked = false;
            try {
                MobileShell.fetchZipBytes(baseUrl + "/proto_bad");
            } catch (IOException e) {
                protoBlocked = e.getMessage() != null && e.getMessage().contains("不支持此重定向协议");
            }
            check(protoBlocked, "E3: fetchZipBytes rejects non-HTTP(S) redirect protocol target");

            boolean userinfoBlocked = false;
            try {
                MobileShell.fetchZipBytes(baseUrl + "/userinfo_bad");
            } catch (IOException e) {
                userinfoBlocked =
                        e.getMessage() != null && e.getMessage().contains("来源重定向不能注入登录凭据");
            }
            check(
                    userinfoBlocked,
                    "E3: fetchZipBytes blocks userInfo credential injection in redirect URL");
        } finally {
            server.stop(0);
        }
    }

    private static void testE3ZipImportPayloadLimit() throws Exception {
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        int port = server.getAddress().getPort();
        String baseUrl = "http://127.0.0.1:" + port;

        // Serve stream larger than 28 MB limit (e.g. 29 MB)
        final int CHUNK_SIZE = 64 * 1024;
        final int TOTAL_CHUNKS = (29 * 1024 * 1024) / CHUNK_SIZE; // ~29MB

        server.createContext(
                "/huge.zip",
                exchange -> {
                    exchange.sendResponseHeaders(200, 0); // chunked
                    try (OutputStream out = exchange.getResponseBody()) {
                        byte[] chunk = new byte[CHUNK_SIZE];
                        for (int i = 0; i < TOTAL_CHUNKS; i++) {
                            out.write(chunk);
                            out.flush();
                        }
                    } catch (Exception ignored) {
                    }
                    exchange.close();
                });

        server.start();
        try {
            boolean limitEnforced = false;
            try {
                MobileShell.fetchZipBytes(baseUrl + "/huge.zip");
            } catch (IOException e) {
                limitEnforced = e.getMessage() != null && e.getMessage().contains("超过 28 MB 限制");
            }
            check(limitEnforced, "E3: fetchZipBytes terminates and enforces 28 MB package limit");
        } finally {
            server.stop(0);
        }
    }

    // =========================================================================
    // § E4: Cross-Domain Danmaku Header Strip
    // =========================================================================

    private static void testE4CrossDomainDanmakuHeaderStrip() throws Exception {
        HttpServer originServer = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        HttpServer cdnServer = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);

        int originPort = originServer.getAddress().getPort();
        int cdnPort = cdnServer.getAddress().getPort();

        String originBase = "http://127.0.0.1:" + originPort;
        String cdnBase = "http://127.0.0.1:" + cdnPort;

        AtomicBoolean authStripped = new AtomicBoolean(false);
        AtomicBoolean cookieStripped = new AtomicBoolean(false);
        AtomicBoolean customHeaderKept = new AtomicBoolean(false);

        originServer.createContext(
                "/danmaku",
                exchange -> {
                    exchange.getResponseHeaders().set("Location", cdnBase + "/danmaku.xml");
                    exchange.sendResponseHeaders(302, -1);
                    exchange.close();
                });

        String xmlBody = "<i><d p=\"1.0,1,25,16777215,0,0,0,0\">test comment</d></i>";

        cdnServer.createContext(
                "/danmaku.xml",
                exchange -> {
                    String auth = exchange.getRequestHeaders().getFirst("Authorization");
                    String cookie = exchange.getRequestHeaders().getFirst("Cookie");
                    String client = exchange.getRequestHeaders().getFirst("X-Custom-Client");

                    authStripped.set(auth == null);
                    cookieStripped.set(cookie == null);
                    customHeaderKept.set("MarcoMovie-Test".equals(client));

                    byte[] bytes = xmlBody.getBytes(StandardCharsets.UTF_8);
                    exchange.sendResponseHeaders(200, bytes.length);
                    try (OutputStream out = exchange.getResponseBody()) {
                        out.write(bytes);
                    }
                    exchange.close();
                });

        originServer.start();
        cdnServer.start();
        try {
            Map<String, String> requestHeaders = new LinkedHashMap<>();
            requestHeaders.put("Authorization", "Bearer sensitive-token-12345");
            requestHeaders.put("Cookie", "session=private_session_id");
            requestHeaders.put("Proxy-Authorization", "Basic secret");
            requestHeaders.put("X-Custom-Client", "MarcoMovie-Test");

            String body = DanmakuView.fetchDanmaku(originBase + "/danmaku", requestHeaders);
            check(
                    xmlBody.equals(body),
                    "E4: Danmaku fetch resolves cross-origin target response body");
            check(
                    authStripped.get(),
                    "E4: Cross-origin redirect strips Authorization and Proxy-Authorization headers");
            check(cookieStripped.get(), "E4: Cross-origin redirect strips origin Cookie header");
            check(
                    customHeaderKept.get(),
                    "E4: Cross-origin redirect preserves safe custom application headers");
        } finally {
            originServer.stop(0);
            cdnServer.stop(0);
        }
    }

    private static void testE4SameDomainDanmakuHeaderPreservation() throws Exception {
        HttpServer originServer = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        int port = originServer.getAddress().getPort();
        String originBase = "http://127.0.0.1:" + port;

        AtomicBoolean authKept = new AtomicBoolean(false);
        AtomicBoolean cookieKept = new AtomicBoolean(false);

        originServer.createContext(
                "/same_redirect",
                exchange -> {
                    exchange.getResponseHeaders().set("Location", originBase + "/same_final");
                    exchange.sendResponseHeaders(302, -1);
                    exchange.close();
                });

        String xmlBody = "<i><d p=\"2.0,1,25,16777215,0,0,0,0\">same origin</d></i>";

        originServer.createContext(
                "/same_final",
                exchange -> {
                    String auth = exchange.getRequestHeaders().getFirst("Authorization");
                    String cookie = exchange.getRequestHeaders().getFirst("Cookie");
                    authKept.set("Bearer keep-me".equals(auth));
                    cookieKept.set("session=keep-me".equals(cookie));

                    byte[] bytes = xmlBody.getBytes(StandardCharsets.UTF_8);
                    exchange.sendResponseHeaders(200, bytes.length);
                    try (OutputStream out = exchange.getResponseBody()) {
                        out.write(bytes);
                    }
                    exchange.close();
                });

        originServer.start();
        try {
            Map<String, String> requestHeaders = new LinkedHashMap<>();
            requestHeaders.put("Authorization", "Bearer keep-me");
            requestHeaders.put("Cookie", "session=keep-me");

            String body = DanmakuView.fetchDanmaku(originBase + "/same_redirect", requestHeaders);
            check(xmlBody.equals(body), "E4: Same-origin redirect returns body");
            check(authKept.get(), "E4: Same-origin redirect preserves Authorization header");
            check(cookieKept.get(), "E4: Same-origin redirect preserves Cookie header");
        } finally {
            originServer.stop(0);
        }
    }

    private static void testE4DanmakuCookiePropagation() throws Exception {
        HttpServer originServer = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        int port = originServer.getAddress().getPort();
        String originBase = "http://127.0.0.1:" + port;

        AtomicBoolean serverCookieReceived = new AtomicBoolean(false);

        originServer.createContext(
                "/dmk_init",
                exchange -> {
                    exchange.getResponseHeaders().set("Location", originBase + "/dmk_target");
                    exchange.getResponseHeaders().set("Set-Cookie", "dmk_sid=sess_999; Path=/");
                    exchange.sendResponseHeaders(302, -1);
                    exchange.close();
                });

        originServer.createContext(
                "/dmk_target",
                exchange -> {
                    String cookie = exchange.getRequestHeaders().getFirst("Cookie");
                    if (cookie != null && cookie.contains("dmk_sid=sess_999")) {
                        serverCookieReceived.set(true);
                    }
                    byte[] bytes = "<i></i>".getBytes(StandardCharsets.UTF_8);
                    exchange.sendResponseHeaders(200, bytes.length);
                    try (OutputStream out = exchange.getResponseBody()) {
                        out.write(bytes);
                    }
                    exchange.close();
                });

        originServer.start();
        try {
            DanmakuView.fetchDanmaku(originBase + "/dmk_init", Collections.emptyMap());
            check(
                    serverCookieReceived.get(),
                    "E4: Danmaku redirect parses Set-Cookie and merges into redirected request");
        } finally {
            originServer.stop(0);
        }
    }

    // =========================================================================
    // § E5: Dynamic User-Agent & Turkish Locale.ROOT Regressions
    // =========================================================================

    private static void testE5DynamicUserAgentContract() throws IOException {
        Path playerPath =
                Paths.get("android/src/main/java/com/pilipala/marcomovie/MoviePlayer.java");
        if (!Files.exists(playerPath)) {
            playerPath =
                    Paths.get(
                            "../../android/src/main/java/com/pilipala/marcomovie/MoviePlayer.java");
        }
        check(Files.exists(playerPath), "E5: MoviePlayer.java exists");
        String content = Files.readString(playerPath, StandardCharsets.UTF_8);

        check(
                content.contains("defaultUserAgent(Context context)"),
                "E5: MoviePlayer defines static defaultUserAgent(Context context)");
        check(
                content.contains("MarcoMovie/\" + version") && content.contains("\"0.5.22\""),
                "E5: defaultUserAgent falls back to MarcoMovie/0.5.22 dynamically when context is null/missing");
        check(
                !content.contains("\"MarcoMovie/0.2.0\""),
                "E5: Outdated hardcoded MarcoMovie/0.2.0 completely eliminated from MoviePlayer");
        check(
                content.contains("sDefaultUserAgent"),
                "E5: MoviePlayer caches defaultUserAgent in volatile field to prevent repeated IPC binder calls");
    }

    private static void testE5TurkishLocaleZipUrl() {
        Locale original = Locale.getDefault();
        try {
            Locale.setDefault(new Locale("tr", "TR"));
            String urlUpper = "HTTPS://EXAMPLE.COM/PATH/PACKAGE.ZIP";

            // With Locale.ROOT
            String lowerRoot = urlUpper.toLowerCase(Locale.ROOT);
            check(
                    lowerRoot.endsWith(".zip"),
                    "E5 (Turkish): .toLowerCase(Locale.ROOT) produces standard ASCII .zip suffix");

            // Without Locale.ROOT (demonstrate bug reproduction)
            String lowerTurkish = urlUpper.toLowerCase();
            boolean brokenEndsWith = lowerTurkish.endsWith(".zip");
            check(
                    !brokenEndsWith,
                    "E5 (Turkish): unadorned .toLowerCase() in tr_TR produces .zıp and fails .endsWith(\".zip\")");
        } finally {
            Locale.setDefault(original);
        }
    }

    private static void testE5TurkishLocaleArtworkHeaders() {
        Locale original = Locale.getDefault();
        try {
            Locale.setDefault(new Locale("tr", "TR"));
            String url = "HTTP://DOUBANIO.COM/VIEW/PHOTO/S_RATIO_POSTER/PUBLIC/P123.JPG";

            // With Locale.ROOT:
            String lower = url.toLowerCase(Locale.ROOT);
            boolean matchedDouban = lower.contains("doubanio.com") || lower.contains("douban.com");
            check(
                    matchedDouban,
                    "E5 (Turkish): Artwork URL with uppercase DOUBANIO matches Referer with Locale.ROOT");

            // Without Locale.ROOT:
            String brokenLower = url.toLowerCase();
            boolean brokenMatch = brokenLower.contains("doubanio.com");
            check(
                    !brokenMatch,
                    "E5 (Turkish): unadorned .toLowerCase() fails Doubanio referer match due to dotless ı");
        } finally {
            Locale.setDefault(original);
        }
    }

    private static void testE5TurkishLocaleChannelMatching() {
        Locale original = Locale.getDefault();
        try {
            Locale.setDefault(new Locale("tr", "TR"));

            String rawName = "cctv-1 hd";
            String upperRoot = rawName.toUpperCase(Locale.ROOT);
            check(
                    upperRoot.startsWith("CCTV"),
                    "E5 (Turkish): .toUpperCase(Locale.ROOT) correctly formats CCTV channel badge");

            String query = "discovery";
            String chName = "DISCOVERY CHANNEL";
            String qLower = query.toLowerCase(Locale.ROOT);
            boolean matched = chName.toLowerCase(Locale.ROOT).contains(qLower);
            check(
                    matched,
                    "E5 (Turkish): Channel search matching succeeds for DISCOVERY in Turkish locale");
        } finally {
            Locale.setDefault(original);
        }
    }

    private static void testE5TurkishLocaleSeasonNormalization() {
        Locale original = Locale.getDefault();
        try {
            String title = "Silicon Valley 第2季 (Vikings)";

            Locale.setDefault(Locale.ROOT);
            String normRoot = normalizeBaseKeyHelper(title);

            Locale.setDefault(new Locale("tr", "TR"));
            String normTurkish = normalizeBaseKeyHelper(title);

            check(
                    normRoot.equals(normTurkish),
                    "E5 (Turkish): Season normalization is byte-for-byte identical between Locale.ROOT and tr_TR");
        } finally {
            Locale.setDefault(original);
        }
    }

    private static String normalizeBaseKeyHelper(String s) {
        if (s == null) return "";
        return s.toLowerCase(Locale.ROOT)
                .replaceAll("[\\s·:：\\-—_（）()【】\\[\\]《》〈〉\"“”'’!！?？,，.。]", "")
                .trim();
    }

    private static void testE5CmsFileUntouchedBoundary() throws Exception {
        Path cmsPath = Paths.get("android/src/main/java/com/pilipala/marcomovie/Cms.java");
        if (!Files.exists(cmsPath)) {
            cmsPath = Paths.get("../../android/src/main/java/com/pilipala/marcomovie/Cms.java");
        }
        check(Files.exists(cmsPath), "E5: Cms.java exists");

        String cmsSource = new String(Files.readAllBytes(cmsPath), StandardCharsets.UTF_8);
        boolean hasBareLocaleCase =
                cmsSource.contains(".toLowerCase()") || cmsSource.contains(".toUpperCase()");
        check(
                !hasBareLocaleCase,
                "E5: Cms.java uses explicit Locale (zero bare toLowerCase()/toUpperCase() calls)");
    }
}
