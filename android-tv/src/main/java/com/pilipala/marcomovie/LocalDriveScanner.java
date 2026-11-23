// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.content.Context;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.os.StatFs;
import android.os.storage.StorageManager;
import android.os.storage.StorageVolume;
import android.provider.DocumentsContract;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import org.json.JSONArray;

/**
 * Multi-strategy external USB hard drive / U-disk discovery and bounded recursive media scanner for
 * Android TV (API 23–35). Supports direct filesystem mounts ({@link StorageManager}, {@code
 * getExternalFilesDirs}, {@code /proc/self/mounts}) plus SAF {@code ACTION_OPEN_DOCUMENT_TREE}
 * persisted tree URIs.
 */
final class LocalDriveScanner {
    static final int REQ_LOCAL_DRIVE_TREE = 48;
    private static final String PREF_FILE = "local_drive_library";
    private static final String PREF_CUSTOM_TREES = "custom_tree_uris_v1";
    private static final int MAX_SCAN_DEPTH = 6;
    private static final int MAX_SCAN_FILES = 8000;
    private static final long MIN_VIDEO_BYTES = 10L * 1024L * 1024L; // 10 MB skips ads/samples

    private static final Set<String> VIDEO_EXTENSIONS =
            new HashSet<>(
                    Arrays.asList(
                            "mp4", "mkv", "avi", "mov", "ts", "m2ts", "flv", "rmvb", "rm", "wmv",
                            "webm", "m4v", "mpg", "mpeg", "vob", "3gp", "f4v", "strm"));
    private static final Set<String> SUBTITLE_EXTENSIONS =
            new HashSet<>(Arrays.asList("srt", "ass", "ssa", "vtt", "sup"));
    private static final Set<String> IMAGE_EXTENSIONS =
            new HashSet<>(Arrays.asList("jpg", "jpeg", "png", "webp"));
    private static final Set<String> IGNORED_DIRS =
            new HashSet<>(
                    Arrays.asList(
                            "android",
                            "$recycle.bin",
                            "system volume information",
                            "lost.dir",
                            "@eadir",
                            "#recycle",
                            ".trash",
                            ".trashes",
                            ".thumbnails",
                            ".spotlight-v100",
                            ".fseventsd",
                            "recycled",
                            "auxdata",
                            "clipinf",
                            "backup",
                            "meta"));
    private static final Set<String> USB_FS_TYPES =
            new HashSet<>(
                    Arrays.asList(
                            "vfat",
                            "exfat",
                            "ntfs",
                            "ntfs3",
                            "fuseblk",
                            "ext4",
                            "ext3",
                            "ext2",
                            "sdfat",
                            "texfat",
                            "ufsd",
                            "fuse",
                            "sdcardfs",
                            "f2fs"));

    static final class DriveRoot {
        final String id;
        final String label;
        final String path; // filesystem path (empty if SAF tree)
        final String treeUri; // SAF tree URI string (empty if filesystem)
        final long totalBytes;
        final long freeBytes;
        final boolean removable;

        DriveRoot(
                String id,
                String label,
                String path,
                String treeUri,
                long totalBytes,
                long freeBytes,
                boolean removable) {
            this.id = id == null ? "" : id;
            this.label = label == null ? "" : label;
            this.path = path == null ? "" : path;
            this.treeUri = treeUri == null ? "" : treeUri;
            this.totalBytes = Math.max(0L, totalBytes);
            this.freeBytes = Math.max(0L, freeBytes);
            this.removable = removable;
        }

        boolean isSafTree() {
            return path.isEmpty() && !treeUri.isEmpty();
        }

        String subtitle() {
            if (totalBytes > 0) {
                return "可用 " + formatBytes(freeBytes) + " / 共 " + formatBytes(totalBytes);
            }
            return isSafTree() ? "手动授权目录" : path;
        }
    }

    static final class ScannedFile {
        final String driveId;
        final String driveLabel;
        final String fileName;
        final String folderPath; // normalized logical folder path
        final String folderName;
        final String parentFolderName;
        final String mediaUri; // file://... or content://...
        final long sizeBytes;
        final long lastModified;
        final String localPosterUri;
        final String localFanartUri;
        final String nfoPath;
        final List<String> subtitleUris;

        ScannedFile(
                String driveId,
                String driveLabel,
                String fileName,
                String folderPath,
                String folderName,
                String parentFolderName,
                String mediaUri,
                long sizeBytes,
                long lastModified,
                String localPosterUri,
                String localFanartUri,
                String nfoPath,
                List<String> subtitleUris) {
            this.driveId = driveId == null ? "" : driveId;
            this.driveLabel = driveLabel == null ? "" : driveLabel;
            this.fileName = fileName == null ? "" : fileName;
            this.folderPath = folderPath == null ? "" : folderPath;
            this.folderName = folderName == null ? "" : folderName;
            this.parentFolderName = parentFolderName == null ? "" : parentFolderName;
            this.mediaUri = mediaUri == null ? "" : mediaUri;
            this.sizeBytes = Math.max(0L, sizeBytes);
            this.lastModified = lastModified;
            this.localPosterUri = localPosterUri == null ? "" : localPosterUri;
            this.localFanartUri = localFanartUri == null ? "" : localFanartUri;
            this.nfoPath = nfoPath == null ? "" : nfoPath;
            this.subtitleUris =
                    subtitleUris == null ? Collections.<String>emptyList() : subtitleUris;
        }
    }

    private LocalDriveScanner() {}

    static boolean isVideoFileName(String name) {
        String ext = extensionOf(name);
        return !ext.isEmpty() && VIDEO_EXTENSIONS.contains(ext);
    }

    static boolean isSubtitleFileName(String name) {
        String ext = extensionOf(name);
        return !ext.isEmpty() && SUBTITLE_EXTENSIONS.contains(ext);
    }

    static boolean isIgnoredDirectoryName(String name) {
        if (name == null || name.trim().isEmpty()) return true;
        String lower = name.trim().toLowerCase(Locale.ROOT);
        if (lower.startsWith(".")) return true;
        return IGNORED_DIRS.contains(lower);
    }

    static String extensionOf(String name) {
        if (name == null) return "";
        int dot = name.lastIndexOf('.');
        if (dot < 0 || dot >= name.length() - 1) return "";
        return name.substring(dot + 1).trim().toLowerCase(Locale.ROOT);
    }

    static String stripExtension(String name) {
        if (name == null) return "";
        int dot = name.lastIndexOf('.');
        if (dot <= 0) return name.trim();
        return name.substring(0, dot).trim();
    }

    static String formatBytes(long bytes) {
        if (bytes < 1024L) return bytes + " B";
        double kb = bytes / 1024.0;
        if (kb < 1024.0) return String.format(Locale.US, "%.0f KB", kb);
        double mb = kb / 1024.0;
        if (mb < 1024.0) return String.format(Locale.US, "%.1f MB", mb);
        double gb = mb / 1024.0;
        if (gb < 1024.0) return String.format(Locale.US, "%.1f GB", gb);
        return String.format(Locale.US, "%.2f TB", gb / 1024.0);
    }

    /**
     * Pure-JVM parser for {@code /proc/self/mounts} returning mounted removable/USB root paths
     * while strictly filtering out internal emulated storage and OS partitions.
     */
    static List<String> parseProcMounts(String mountsContent) {
        if (mountsContent == null || mountsContent.trim().isEmpty()) {
            return Collections.emptyList();
        }
        Set<String> roots = new LinkedHashSet<>();
        String[] lines = mountsContent.split("\n");
        for (String line : lines) {
            if (line == null || line.trim().isEmpty()) continue;
            String[] parts = line.trim().split("\\s+");
            if (parts.length < 3) continue;
            String mountPoint = parts[1].replace("\\040", " ").trim();
            String fsType = parts[2].trim().toLowerCase(Locale.ROOT);
            if (!USB_FS_TYPES.contains(fsType)) continue;
            if (!isCandidateExternalMountPath(mountPoint)) continue;
            roots.add(mountPoint);
        }
        return new ArrayList<>(roots);
    }

    static boolean isCandidateExternalMountPath(String rawPath) {
        if (rawPath == null || rawPath.trim().isEmpty()) return false;
        String p = rawPath.trim();
        String lower = p.toLowerCase(Locale.ROOT);
        if (lower.equals("/storage")
                || lower.equals("/mnt")
                || lower.startsWith("/storage/emulated")
                || lower.startsWith("/storage/self")
                || lower.startsWith("/mnt/runtime")
                || lower.startsWith("/mnt/pass_through")
                || lower.startsWith("/mnt/user")
                || lower.startsWith("/mnt/installer")
                || lower.startsWith("/mnt/androidwritable")
                || lower.startsWith("/mnt/obb")
                || lower.startsWith("/mnt/asec")
                || lower.startsWith("/mnt/vendor")
                || lower.startsWith("/mnt/product")
                || lower.startsWith("/mnt/shell")) {
            return false;
        }
        return lower.startsWith("/storage/")
                || lower.startsWith("/mnt/usb")
                || lower.startsWith("/mnt/media_rw/")
                || lower.startsWith("/mnt/sda")
                || lower.startsWith("/mnt/sdb")
                || lower.startsWith("/mnt/sdc")
                || lower.startsWith("/mnt/external")
                || lower.startsWith("/mnt/udisk")
                || lower.startsWith("/udisk");
    }

    /** Discovers all mounted USB / removable drives plus any user-persisted SAF folders. */
    static List<DriveRoot> discoverDrives(Context context) {
        Map<String, DriveRoot> byKey = new LinkedHashMap<>();
        String primaryInternalPath = "";
        try {
            File ext = Environment.getExternalStorageDirectory();
            if (ext != null) primaryInternalPath = ext.getCanonicalPath();
        } catch (Exception ignored) {
        }

        // 1. StorageManager.getStorageVolumes() (API 24+)
        if (context != null && Build.VERSION.SDK_INT >= 24) {
            try {
                StorageManager sm =
                        (StorageManager) context.getSystemService(Context.STORAGE_SERVICE);
                if (sm != null) {
                    List<StorageVolume> volumes = sm.getStorageVolumes();
                    if (volumes != null) {
                        for (StorageVolume vol : volumes) {
                            if (vol == null || vol.isPrimary()) continue;
                            String state = vol.getState();
                            if (state != null && !Environment.MEDIA_MOUNTED.equals(state)) continue;
                            File dir = resolveStorageVolumeDir(vol);
                            if (dir == null || !dir.exists() || !dir.isDirectory()) continue;
                            String canonical = safeCanonical(dir);
                            if (canonical.equals(primaryInternalPath)) continue;
                            String desc = vol.getDescription(context);
                            if (desc == null || desc.trim().isEmpty()) {
                                desc = "移动硬盘 (" + dir.getName() + ")";
                            }
                            addFileDrive(byKey, canonical, desc.trim(), vol.isRemovable());
                        }
                    }
                }
            } catch (Throwable ignored) {
            }
        }

        // 2. Context.getExternalFilesDirs(null) root extraction
        if (context != null) {
            try {
                File[] dirs = context.getExternalFilesDirs(null);
                if (dirs != null) {
                    for (int i = 1; i < dirs.length; i++) {
                        File f = dirs[i];
                        if (f == null) continue;
                        String abs = f.getAbsolutePath();
                        int idx = abs.indexOf("/Android/data/");
                        if (idx > 0) {
                            File root = new File(abs.substring(0, idx));
                            if (root.exists() && root.isDirectory()) {
                                String canonical = safeCanonical(root);
                                if (!canonical.equals(primaryInternalPath)
                                        && !byKey.containsKey(canonical)) {
                                    addFileDrive(
                                            byKey, canonical, "外接硬盘 · " + root.getName(), true);
                                }
                            }
                        }
                    }
                }
            } catch (Throwable ignored) {
            }
        }

        // 3. /proc/self/mounts scan for USB volumes on OEM TV boxes
        String mountsText = readMountsFile();
        for (String mp : parseProcMounts(mountsText)) {
            File dir = new File(mp);
            if (!dir.exists() || !dir.isDirectory() || !dir.canRead()) continue;
            String canonical = safeCanonical(dir);
            if (canonical.equals(primaryInternalPath) || byKey.containsKey(canonical)) continue;
            addFileDrive(byKey, canonical, "移动硬盘 · " + dir.getName(), true);
        }

        // 4. Direct scan of /storage children (catches OEM TV ROMs hiding /proc/mounts)
        File storageDir = new File("/storage");
        File[] storageChildren = storageDir.listFiles();
        if (storageChildren != null) {
            for (File child : storageChildren) {
                if (child == null || !child.isDirectory() || !child.canRead()) continue;
                String abs = child.getAbsolutePath();
                if (!isCandidateExternalMountPath(abs)) continue;
                String canonical = safeCanonical(child);
                if (canonical.equals(primaryInternalPath) || byKey.containsKey(canonical)) continue;
                addFileDrive(byKey, canonical, "移动硬盘 · " + child.getName(), true);
            }
        }

        // 5. User-added SAF document tree URIs
        if (context != null) {
            for (String treeUriStr : loadPersistedTreeUris(context)) {
                String label = "授权目录 · " + extractTreeLabel(treeUriStr);
                String id = "saf:" + treeUriStr;
                byKey.put(id, new DriveRoot(id, label, "", treeUriStr, 0L, 0L, true));
            }
        }

        return new ArrayList<>(byKey.values());
    }

    private static void addFileDrive(
            Map<String, DriveRoot> byKey, String canonicalPath, String label, boolean removable) {
        long total = 0L;
        long free = 0L;
        try {
            StatFs stat = new StatFs(canonicalPath);
            total = stat.getTotalBytes();
            free = stat.getAvailableBytes();
        } catch (Throwable ignored) {
        }
        String id = "fs:" + canonicalPath;
        byKey.put(
                canonicalPath, new DriveRoot(id, label, canonicalPath, "", total, free, removable));
    }

    private static File resolveStorageVolumeDir(StorageVolume vol) {
        if (Build.VERSION.SDK_INT >= 30) {
            try {
                Method m = StorageVolume.class.getMethod("getDirectory");
                Object res = m.invoke(vol);
                if (res instanceof File) return (File) res;
            } catch (Throwable ignored) {
            }
        }
        try {
            Method m = StorageVolume.class.getMethod("getPath");
            Object res = m.invoke(vol);
            if (res instanceof String && !((String) res).trim().isEmpty()) {
                return new File((String) res);
            }
        } catch (Throwable ignored) {
        }
        return null;
    }

    private static String safeCanonical(File f) {
        try {
            return f.getCanonicalPath();
        } catch (Exception ignored) {
            return f.getAbsolutePath();
        }
    }

    private static String readMountsFile() {
        for (String path : new String[] {"/proc/self/mounts", "/proc/mounts"}) {
            File f = new File(path);
            if (!f.exists() || !f.canRead()) continue;
            StringBuilder sb = new StringBuilder();
            try (BufferedReader br = new BufferedReader(new FileReader(f))) {
                String line;
                int lines = 0;
                while ((line = br.readLine()) != null && lines < 512) {
                    sb.append(line).append('\n');
                    lines++;
                }
                return sb.toString();
            } catch (Exception ignored) {
            }
        }
        return "";
    }

    static List<String> loadPersistedTreeUris(Context context) {
        List<String> out = new ArrayList<>();
        if (context == null) return out;
        SharedPreferences sp = context.getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE);
        String raw = sp.getString(PREF_CUSTOM_TREES, "");
        if (raw == null || raw.trim().isEmpty()) return out;
        try {
            JSONArray arr = new JSONArray(raw);
            for (int i = 0; i < arr.length(); i++) {
                String u = arr.optString(i, "").trim();
                if (!u.isEmpty() && !out.contains(u)) out.add(u);
            }
        } catch (Exception ignored) {
        }
        return out;
    }

    static void addPersistedTreeUri(Context context, String uriStr) {
        if (context == null || uriStr == null || uriStr.trim().isEmpty()) return;
        List<String> cur = loadPersistedTreeUris(context);
        if (!cur.contains(uriStr.trim())) {
            cur.add(uriStr.trim());
            JSONArray arr = new JSONArray();
            for (String u : cur) arr.put(u);
            SharedPreferences sp = context.getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE);
            sp.edit().putString(PREF_CUSTOM_TREES, arr.toString()).apply();
        }
    }

    static void removePersistedTreeUri(Context context, String uriStr) {
        if (context == null || uriStr == null) return;
        List<String> cur = loadPersistedTreeUris(context);
        if (cur.remove(uriStr.trim())) {
            JSONArray arr = new JSONArray();
            for (String u : cur) arr.put(u);
            SharedPreferences sp = context.getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE);
            sp.edit().putString(PREF_CUSTOM_TREES, arr.toString()).apply();
        }
    }

    private static String extractTreeLabel(String treeUriStr) {
        try {
            Uri uri = Uri.parse(treeUriStr);
            String docId = DocumentsContract.getTreeDocumentId(uri);
            if (docId != null && !docId.trim().isEmpty()) {
                int slash = docId.lastIndexOf('/');
                if (slash >= 0 && slash < docId.length() - 1) {
                    return docId.substring(slash + 1);
                }
                return docId.replace(":", " ");
            }
        } catch (Throwable ignored) {
        }
        return "外接目录";
    }

    /** Scans a single drive (either filesystem path or SAF document tree) for video files. */
    static List<ScannedFile> scanDrive(Context context, DriveRoot drive) {
        List<ScannedFile> out = new ArrayList<>();
        if (drive == null) return out;
        int[] counter = {0};
        if (drive.isSafTree()) {
            if (context != null) {
                Uri treeUri = Uri.parse(drive.treeUri);
                String rootDocId = DocumentsContract.getTreeDocumentId(treeUri);
                scanSafFolder(
                        context,
                        drive,
                        treeUri,
                        rootDocId,
                        drive.label,
                        drive.label,
                        "",
                        0,
                        counter,
                        out);
            }
        } else {
            File root = new File(drive.path);
            if (root.exists() && root.isDirectory()) {
                scanFsFolder(drive, root, "", 0, counter, out);
            }
        }
        return out;
    }

    private static void scanFsFolder(
            DriveRoot drive,
            File dir,
            String parentName,
            int depth,
            int[] counter,
            List<ScannedFile> out) {
        if (depth > MAX_SCAN_DEPTH || counter[0] >= MAX_SCAN_FILES) return;
        File[] children = dir.listFiles();
        if (children == null || children.length == 0) return;

        List<File> videos = new ArrayList<>();
        List<File> subs = new ArrayList<>();
        List<File> subDirs = new ArrayList<>();
        Map<String, File> imagesByBase = new HashMap<>();
        Map<String, File> nfosByBase = new HashMap<>();
        File folderPoster = null;
        File folderFanart = null;
        File folderNfo = null;

        for (File child : children) {
            if (child == null) continue;
            String name = child.getName();
            if (child.isDirectory()) {
                if (!isIgnoredDirectoryName(name)) {
                    subDirs.add(child);
                }
                continue;
            }
            if (!child.isFile() || !child.canRead()) continue;
            String ext = extensionOf(name);
            String baseLower = stripExtension(name).toLowerCase(Locale.ROOT);
            if (VIDEO_EXTENSIONS.contains(ext)) {
                long len = child.length();
                if (!"strm".equals(ext) && len > 0 && len < MIN_VIDEO_BYTES) {
                    continue;
                }
                String lower = name.toLowerCase(Locale.ROOT);
                if (lower.contains("sample.") || lower.startsWith("sample-")) continue;
                videos.add(child);
            } else if (SUBTITLE_EXTENSIONS.contains(ext)) {
                subs.add(child);
            } else if (IMAGE_EXTENSIONS.contains(ext)) {
                imagesByBase.put(baseLower, child);
                if ("poster".equals(baseLower)
                        || "cover".equals(baseLower)
                        || "folder".equals(baseLower)
                        || "movie".equals(baseLower)) {
                    if (folderPoster == null || "poster".equals(baseLower)) folderPoster = child;
                } else if ("fanart".equals(baseLower)
                        || "backdrop".equals(baseLower)
                        || "landscape".equals(baseLower)) {
                    folderFanart = child;
                }
            } else if ("nfo".equals(ext)) {
                nfosByBase.put(baseLower, child);
                if ("tvshow".equals(baseLower) || "movie".equals(baseLower)) {
                    folderNfo = child;
                }
            }
        }

        // Also check common "Subs" subfolder for sibling subtitles
        for (File sd : subDirs) {
            String sdLower = sd.getName().toLowerCase(Locale.ROOT);
            if ("subs".equals(sdLower) || "subtitles".equals(sdLower) || "sub".equals(sdLower)) {
                File[] subFiles = sd.listFiles();
                if (subFiles != null) {
                    for (File sf : subFiles) {
                        if (sf != null && sf.isFile() && isSubtitleFileName(sf.getName())) {
                            subs.add(sf);
                        }
                    }
                }
            }
        }

        String folderPath = dir.getAbsolutePath();
        String folderName = dir.getName();
        for (File v : videos) {
            if (counter[0] >= MAX_SCAN_FILES) break;
            counter[0]++;
            String baseLower = stripExtension(v.getName()).toLowerCase(Locale.ROOT);
            File poster = imagesByBase.get(baseLower + "-poster");
            if (poster == null) poster = imagesByBase.get(baseLower);
            if (poster == null) poster = folderPoster;

            File fanart = imagesByBase.get(baseLower + "-fanart");
            if (fanart == null) fanart = folderFanart;

            File nfo = nfosByBase.get(baseLower);
            if (nfo == null) nfo = folderNfo;

            List<String> matchedSubs = matchSubtitlesForVideo(v.getName(), subs);
            out.add(
                    new ScannedFile(
                            drive.id,
                            drive.label,
                            v.getName(),
                            folderPath,
                            folderName,
                            parentName,
                            Uri.fromFile(v).toString(),
                            v.length(),
                            v.lastModified(),
                            poster != null ? Uri.fromFile(poster).toString() : "",
                            fanart != null ? Uri.fromFile(fanart).toString() : "",
                            nfo != null ? nfo.getAbsolutePath() : "",
                            matchedSubs));
        }

        for (File sd : subDirs) {
            if (counter[0] >= MAX_SCAN_FILES) break;
            String sdLower = sd.getName().toLowerCase(Locale.ROOT);
            if ("subs".equals(sdLower) || "subtitles".equals(sdLower)) continue;
            scanFsFolder(drive, sd, folderName, depth + 1, counter, out);
        }
    }

    private static List<String> matchSubtitlesForVideo(String videoName, List<File> subs) {
        if (subs == null || subs.isEmpty()) return Collections.emptyList();
        String baseLower = stripExtension(videoName).toLowerCase(Locale.ROOT);
        int epNum = TvSeriesScraper.extractEpisodeNumber(videoName);
        List<String> exact = new ArrayList<>();
        List<String> byEp = new ArrayList<>();
        for (File s : subs) {
            String sBase = stripExtension(s.getName()).toLowerCase(Locale.ROOT);
            if (sBase.equals(baseLower) || sBase.startsWith(baseLower + ".")) {
                exact.add(Uri.fromFile(s).toString());
            } else if (epNum > 0 && TvSeriesScraper.extractEpisodeNumber(s.getName()) == epNum) {
                byEp.add(Uri.fromFile(s).toString());
            }
        }
        return !exact.isEmpty() ? exact : byEp;
    }

    private static void scanSafFolder(
            Context context,
            DriveRoot drive,
            Uri treeUri,
            String docId,
            String folderPath,
            String folderName,
            String parentName,
            int depth,
            int[] counter,
            List<ScannedFile> out) {
        if (depth > MAX_SCAN_DEPTH || counter[0] >= MAX_SCAN_FILES) return;
        Uri childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, docId);
        String[] projection = {
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED
        };
        List<String[]> subDirs = new ArrayList<>();
        List<Object[]> videos = new ArrayList<>();
        Map<String, String> imagesByBase = new HashMap<>();
        String folderPoster = "";
        String folderFanart = "";

        Cursor cursor = null;
        try {
            cursor = context.getContentResolver().query(childrenUri, projection, null, null, null);
            if (cursor == null) return;
            while (cursor.moveToNext()) {
                String childDocId = cursor.getString(0);
                String name = cursor.getString(1);
                String mime = cursor.getString(2);
                long size = cursor.getLong(3);
                long mod = cursor.getLong(4);
                if (childDocId == null || name == null) continue;
                if (DocumentsContract.Document.MIME_TYPE_DIR.equals(mime)) {
                    if (!isIgnoredDirectoryName(name)) {
                        subDirs.add(new String[] {childDocId, name});
                    }
                    continue;
                }
                String ext = extensionOf(name);
                String baseLower = stripExtension(name).toLowerCase(Locale.ROOT);
                Uri docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, childDocId);
                if (VIDEO_EXTENSIONS.contains(ext)) {
                    if (!"strm".equals(ext) && size > 0 && size < MIN_VIDEO_BYTES) continue;
                    videos.add(new Object[] {name, docUri.toString(), size, mod});
                } else if (IMAGE_EXTENSIONS.contains(ext)) {
                    imagesByBase.put(baseLower, docUri.toString());
                    if ("poster".equals(baseLower)
                            || "cover".equals(baseLower)
                            || "folder".equals(baseLower)) {
                        if (folderPoster.isEmpty() || "poster".equals(baseLower)) {
                            folderPoster = docUri.toString();
                        }
                    } else if ("fanart".equals(baseLower) || "backdrop".equals(baseLower)) {
                        folderFanart = docUri.toString();
                    }
                }
            }
        } catch (Throwable ignored) {
        } finally {
            if (cursor != null) {
                try {
                    cursor.close();
                } catch (Throwable ignored) {
                }
            }
        }

        for (Object[] v : videos) {
            if (counter[0] >= MAX_SCAN_FILES) break;
            counter[0]++;
            String name = (String) v[0];
            String uriStr = (String) v[1];
            long size = ((Long) v[2]).longValue();
            long mod = ((Long) v[3]).longValue();
            String baseLower = stripExtension(name).toLowerCase(Locale.ROOT);
            String poster = imagesByBase.get(baseLower + "-poster");
            if (poster == null) poster = imagesByBase.get(baseLower);
            if (poster == null) poster = folderPoster;
            out.add(
                    new ScannedFile(
                            drive.id,
                            drive.label,
                            name,
                            folderPath,
                            folderName,
                            parentName,
                            uriStr,
                            size,
                            mod,
                            poster,
                            folderFanart,
                            "",
                            Collections.<String>emptyList()));
        }

        for (String[] sd : subDirs) {
            if (counter[0] >= MAX_SCAN_FILES) break;
            scanSafFolder(
                    context,
                    drive,
                    treeUri,
                    sd[0],
                    folderPath + "/" + sd[1],
                    sd[1],
                    folderName,
                    depth + 1,
                    counter,
                    out);
        }
    }
}
