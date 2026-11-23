package com.pilipala.marcomovie;

import android.util.AtomicFile;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.UUID;

/** Atomic public sidecar; private and unidentified media never touch a file. */
final class VideoMarkerRepository {
    interface Valid {
        boolean get();
    }

    interface Backend {
        String read() throws IOException;

        void write(String value) throws IOException;

        void preserve(String value) throws IOException;
    }

    private static final Object LOCK = new Object();
    private static volatile boolean clearing;

    static boolean clearing() {
        return clearing;
    }

    static void finishClear() {
        clearing = false;
    }

    private static String privateDocument = "";
    private static long privateEpoch;
    final VideoMarkerStore.Identity identity;
    final boolean persistent;
    private final Backend backend;
    private final Valid valid;

    VideoMarkerRepository(
            VideoMarkerStore.Identity identity, boolean persistent, Backend backend, Valid valid) {
        this.identity = identity;
        this.persistent = persistent;
        this.backend = backend;
        this.valid = valid;
    }

    static void clearPrivate() {
        synchronized (LOCK) {
            privateDocument = "";
            privateEpoch++;
        }
    }

    VideoMarkerStore.Document read() throws IOException {
        synchronized (LOCK) {
            if (clearing || !valid.get()) throw new IOException("播放上下文已失效");
            String raw = backend.read();
            try {
                return VideoMarkerStore.read(raw);
            } catch (IOException corrupt) {
                try {
                    backend.preserve(raw);
                } catch (IOException backupFailed) {
                    corrupt.addSuppressed(backupFailed);
                }
                throw corrupt;
            }
        }
    }

    long write(long revision, boolean intro, VideoMarkerStore.Field value) throws IOException {
        synchronized (LOCK) {
            if (clearing || !valid.get()) throw new IOException("播放上下文已失效");
            read(); // Corrupt/unsupported documents are preserved, never replaced by an empty one.
            String next = VideoMarkerStore.update(backend.read(), revision, identity, intro, value);
            if (clearing || !valid.get()) throw new IOException("播放上下文已失效");
            backend.write(next); // Must succeed before the transaction may resume playback.
            return revision + 1;
        }
    }

    static boolean opaqueId(String value) {
        return value != null && value.matches("[A-Za-z0-9_-]{1,256}");
    }

    static VideoMarkerStore.Identity identify(
            Cms.Config config,
            Cms.Site site,
            Cms.Video video,
            Cms.Line line,
            Cms.Episode episode,
            boolean privateMode) {
        try {
            if (config == null
                    || config.raw == null
                    || config.raw.isEmpty()
                    || site == null
                    || video == null
                    || line == null
                    || episode == null
                    || "live".equals(site.key)
                    || !opaqueId(video.id)
                    || !opaqueId(episode.url)
                    || site.key == null
                    || site.key.isEmpty()
                    || line.name == null
                    || line.name.isEmpty()) return null;
            int lines = 0, episodes = 0;
            for (Cms.Line l : video.lines) if (line.name.equals(l.name)) lines++;
            for (Cms.Episode e : line.episodes) if (episode.url.equals(e.url)) episodes++;
            if (lines != 1 || episodes != 1 || !line.episodes.contains(episode)) return null;
            // The original opaque source player ID is allowed; resolved/signed playback URLs are
            // not.
            return new VideoMarkerStore.Identity(
                    privateMode ? "private" : "public",
                    ConfigLibrary.hash(
                            ConfigLibrary.identity(config.origin, config.raw)
                                    + ConfigLibrary.hash(config.raw)),
                    ConfigLibrary.hash(site.siteId()),
                    ConfigLibrary.hash(video.id),
                    ConfigLibrary.hash(episode.url),
                    ConfigLibrary.hash(line.name));
        } catch (Exception unavailable) {
            return null;
        }
    }

    static VideoMarkerRepository open(MainActivity a, PlaybackControls controls, Valid valid) {
        VideoMarkerStore.Identity id =
                identify(
                        a.config,
                        controls.site,
                        controls.video,
                        a.activeLine,
                        a.activeEpisode,
                        a.privateMode);
        boolean stable = id != null;
        if (!stable) {
            try {
                String nonce = ConfigLibrary.hash(UUID.randomUUID().toString());
                id = new VideoMarkerStore.Identity("session", nonce, nonce, nonce, nonce, nonce);
            } catch (Exception impossible) {
                throw new IllegalStateException(impossible);
            }
        }
        if (a.privateMode && stable) {
            final long epoch = privateEpoch;
            return new VideoMarkerRepository(
                    id,
                    false,
                    new Backend() {
                        public String read() throws IOException {
                            check();
                            return privateDocument;
                        }

                        public void write(String value) throws IOException {
                            check();
                            privateDocument = value;
                        }

                        public void preserve(
                                String value) {} // Original private bytes stay in memory.

                        private void check() throws IOException {
                            if (epoch != privateEpoch) throw new IOException("隐私会话已结束");
                        }
                    },
                    valid);
        }
        if (!stable)
            return new VideoMarkerRepository(
                    id,
                    false,
                    new Backend() {
                        String raw = "";

                        public String read() {
                            return raw;
                        }

                        public void write(String value) {
                            raw = value;
                        }

                        public void preserve(String value) {}
                    },
                    valid);
        return new VideoMarkerRepository(id, true, publicBackend(a.getFilesDir()), valid);
    }

    private static Backend publicBackend(final File directory) {
        final AtomicFile file = new AtomicFile(new File(directory, "video-markers-v2.json"));
        return new Backend() {
            public String read() throws IOException {
                if (!file.getBaseFile().exists() && !new File(file.getBaseFile() + ".bak").exists())
                    return "";
                try (InputStream in = file.openRead();
                        ByteArrayOutputStream bytes = new ByteArrayOutputStream()) {
                    byte[] buffer = new byte[4096];
                    int n;
                    while ((n = in.read(buffer)) >= 0) {
                        if (bytes.size() + n > 2 * 1024 * 1024)
                            throw new IOException("标记文件过大，原文件已保留");
                        bytes.write(buffer, 0, n);
                    }
                    return new String(bytes.toByteArray(), StandardCharsets.UTF_8);
                }
            }

            public void write(String value) throws IOException {
                atomic(file, value);
            }

            public void preserve(String value) throws IOException {
                try {
                    AtomicFile backup =
                            new AtomicFile(
                                    new File(
                                            directory,
                                            "video-markers-v2.corrupt-"
                                                    + ConfigLibrary.hash(value)));
                    if (!backup.getBaseFile().exists()) atomic(backup, value);
                } catch (Exception e) {
                    throw new IOException("故障备份失败，原文件仍保留", e);
                }
            }
        };
    }

    static int count(MainActivity a) {
        synchronized (LOCK) {
            if (clearing) return -1;
            try {
                return VideoMarkerStore.read(
                                a.privateMode
                                        ? privateDocument
                                        : publicBackend(a.getFilesDir()).read())
                        .records
                        .size();
            } catch (IOException corrupt) {
                return -1;
            }
        }
    }

    // Capture only the already selected public directory on UI; never consult Activity on worker.
    static MarkerClearTask.Write preparePublicClear(File directory) {
        synchronized (LOCK) {
            if (clearing) return null;
            final Backend backend = publicBackend(directory);
            clearing = true;
            return () -> {
                MarkerClearTask.requireWorker();
                String raw = backend.read();
                long revision;
                try {
                    revision = VideoMarkerStore.read(raw).revision;
                } catch (IOException corrupt) {
                    backend.preserve(raw);
                    revision = 0;
                }
                if (revision == Long.MAX_VALUE) throw new IOException("标记版本已达上限，原文件已保留");
                backend.write("{\"schema\":2,\"revision\":" + (revision + 1) + ",\"records\":[]}");
            };
        }
    }

    private static void atomic(AtomicFile file, String value) throws IOException {
        FileOutputStream stream = null;
        try {
            stream = file.startWrite();
            stream.write(value.getBytes(StandardCharsets.UTF_8));
            stream.getFD().sync();
            file.finishWrite(stream);
            stream = null; // A read-back failure must not delete an already committed document.
            if (!value.equals(new String(file.readFully(), StandardCharsets.UTF_8)))
                throw new IOException("写入后校验失败，保持暂停并请重新读取");
        } catch (IOException e) {
            if (stream != null) file.failWrite(stream);
            throw e;
        }
    }
}
