package com.pilipala.marcomovie;

import android.app.ActivityManager;
import android.app.ApplicationExitInfo;
import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.regex.Pattern;
import org.json.JSONObject;

/**
 * Local crash report capture, privacy redaction, bounded storage, and GitHub Issue Markdown
 * formatting.
 *
 * <p>Never records or surfaces reports while Privacy Space ({@code privateMode}) is active.
 * Strict API 23 compatibility: all Android 11+ ({@code ApplicationExitInfo}) APIs are isolated in
 * {@link Api30ExitReasonHelper}.
 */
final class CrashReportStore {
    static final String GITHUB_REPO = "Pilipala9919/MarcoMovie";
    static final String RELAY_ENDPOINT = "https://marcotv.wlj9919.top/movie/api/crash-report";
    static final String GITHUB_ISSUES_NEW_URL =
            "https://github.com/Pilipala9919/MarcoMovie/issues/new";

    static final String DIR_NAME = "crash_reports";
    static final int MAX_REPORTS = 5;
    static final int MAX_REPORT_BYTES = 60 * 1024;
    static final long MAX_AGE_MS = 14L * 24L * 60L * 60L * 1000L;
    static final int MAX_APPLOG_LINES = 80;
    static final int MAX_STACK_CHARS = 12_000;
    static final int MAX_GITHUB_URL_BODY_CHARS = 3400;

    static final String KIND_JAVA = "java_exception";
    static final String KIND_NATIVE = "native_crash";
    static final String KIND_LOW_MEMORY = "low_memory";
    static final String KIND_ANR = "anr";
    static final String KIND_DIAGNOSTIC = "manual_diagnostic";

    private static final Pattern URL_PATTERN =
            Pattern.compile("(?i)(https?|rtsp|rtmp|magnet|davs?|ftp)://[^\\s\"'<>()\\]]+");
    private static final Pattern SECRET_KV_PATTERN =
            Pattern.compile(
                    "(?i)\\b(cookie|set-cookie|authorization|token|access_token|refresh_token|"
                            + "password|passwd|pwd|secret|puus|bduss|stoken|api_key|apikey)"
                            + "\\s*[:=]\\s*[^\\s,;\"'&\\r\\n]+");
    private static final Pattern BEARER_PATTERN =
            Pattern.compile("(?i)\\bBearer\\s+[A-Za-z0-9._~+/=-]{8,}");
    private static final Pattern GH_TOKEN_PATTERN =
            Pattern.compile("(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})");
    private static final Pattern LAN_IP_PATTERN =
            Pattern.compile(
                    "\\b(?:10\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}|"
                            + "192\\.168\\.\\d{1,3}\\.\\d{1,3}|"
                            + "172\\.(?:1[6-9]|2\\d|3[01])\\.\\d{1,3}\\.\\d{1,3})\\b");
    private static final Pattern FILE_PATH_PATTERN =
            Pattern.compile(
                    "(?i)(?:file://)?(?:/storage/emulated/[^\\s\"'<>]+|/sdcard/[^\\s\"'<>]+)");

    static final class CrashReport {
        String id = "";
        long timestampMs;
        String kind = KIND_JAVA;
        String screen = "未知页面";
        String summary = "";
        String fingerprint = "";
        String appVersion = "";
        int appVersionCode;
        String edition = "android-tv";
        String deviceModel = "";
        String manufacturer = "";
        String board = "";
        String hardware = "";
        String abi = "";
        String androidRelease = "";
        int sdkInt;
        int memoryClassMb;
        String playbackSnapshot = "";
        String stackTrace = "";
        String recentLogs = "";
        boolean submitted;
        int submittedIssueNumber;
        String submittedIssueUrl = "";

        JSONObject toJson() throws Exception {
            JSONObject o = new JSONObject();
            o.put("id", id);
            o.put("timestampMs", timestampMs);
            o.put("kind", kind);
            o.put("screen", screen);
            o.put("summary", summary);
            o.put("fingerprint", fingerprint);
            o.put("appVersion", appVersion);
            o.put("appVersionCode", appVersionCode);
            o.put("edition", edition);
            o.put("deviceModel", deviceModel);
            o.put("manufacturer", manufacturer);
            o.put("board", board);
            o.put("hardware", hardware);
            o.put("abi", abi);
            o.put("androidRelease", androidRelease);
            o.put("sdkInt", sdkInt);
            o.put("memoryClassMb", memoryClassMb);
            o.put("playbackSnapshot", playbackSnapshot);
            o.put("stackTrace", stackTrace);
            o.put("recentLogs", recentLogs);
            o.put("submitted", submitted);
            o.put("submittedIssueNumber", submittedIssueNumber);
            o.put("submittedIssueUrl", submittedIssueUrl);
            return o;
        }

        static CrashReport fromJson(JSONObject o) {
            if (o == null) return null;
            CrashReport r = new CrashReport();
            r.id = o.optString("id", "");
            r.timestampMs = o.optLong("timestampMs", 0L);
            r.kind = o.optString("kind", KIND_JAVA);
            r.screen = o.optString("screen", "未知页面");
            r.summary = o.optString("summary", "");
            r.fingerprint = o.optString("fingerprint", "");
            r.appVersion = o.optString("appVersion", "");
            r.appVersionCode = o.optInt("appVersionCode", 0);
            r.edition = o.optString("edition", "android-tv");
            r.deviceModel = o.optString("deviceModel", "");
            r.manufacturer = o.optString("manufacturer", "");
            r.board = o.optString("board", "");
            r.hardware = o.optString("hardware", "");
            r.abi = o.optString("abi", "");
            r.androidRelease = o.optString("androidRelease", "");
            r.sdkInt = o.optInt("sdkInt", 0);
            r.memoryClassMb = o.optInt("memoryClassMb", 0);
            r.playbackSnapshot = o.optString("playbackSnapshot", "");
            r.stackTrace = o.optString("stackTrace", "");
            r.recentLogs = o.optString("recentLogs", "");
            r.submitted = o.optBoolean("submitted", false);
            r.submittedIssueNumber = o.optInt("submittedIssueNumber", 0);
            r.submittedIssueUrl = o.optString("submittedIssueUrl", "");
            return r.id.isEmpty() ? null : r;
        }

        String displayTime() {
            SimpleDateFormat fmt = new SimpleDateFormat("MM-dd HH:mm", Locale.US);
            return fmt.format(new Date(timestampMs > 0 ? timestampMs : System.currentTimeMillis()));
        }

        String kindLabel() {
            if (KIND_NATIVE.equals(kind)) return "Native 底层崩溃";
            if (KIND_LOW_MEMORY.equals(kind)) return "内存不足 (OOM/LMK)";
            if (KIND_ANR.equals(kind)) return "无响应 (ANR)";
            if (KIND_DIAGNOSTIC.equals(kind)) return "运行诊断日志";
            return "应用异常闪退";
        }
    }

    private CrashReportStore() {}

    static File reportDir(File filesDir) {
        return new File(filesDir, DIR_NAME);
    }

    /** Strips URLs, tokens, cookies, credentials, LAN IPs, and storage paths before writing. */
    static String sanitize(String raw) {
        if (raw == null || raw.isEmpty()) return "";
        String s = raw;
        s = URL_PATTERN.matcher(s).replaceAll("[URL_REDACTED]");
        s = GH_TOKEN_PATTERN.matcher(s).replaceAll("[TOKEN_REDACTED]");
        s = BEARER_PATTERN.matcher(s).replaceAll("Bearer [REDACTED]");
        s = SECRET_KV_PATTERN.matcher(s).replaceAll("$1=[REDACTED]");
        s = LAN_IP_PATTERN.matcher(s).replaceAll("[LAN_IP]");
        s = FILE_PATH_PATTERN.matcher(s).replaceAll("[PATH_REDACTED]");
        return s;
    }

    static String computeFingerprint(String kind, String exceptionType, String stackTrace) {
        String topFrame = "";
        if (stackTrace != null && !stackTrace.isEmpty()) {
            String[] lines = stackTrace.split("\n");
            for (String line : lines) {
                String t = line.trim();
                if (t.startsWith("at com.pilipala.marcomovie.")) {
                    topFrame = t;
                    break;
                }
            }
            if (topFrame.isEmpty()) {
                for (String line : lines) {
                    String t = line.trim();
                    if (t.startsWith("at ")) {
                        topFrame = t;
                        break;
                    }
                }
            }
        }
        String seed =
                (kind == null ? "" : kind)
                        + "|"
                        + (exceptionType == null ? "" : exceptionType)
                        + "|"
                        + topFrame;
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] digest = md.digest(seed.getBytes(StandardCharsets.UTF_8));
            StringBuilder hex = new StringBuilder(12);
            for (int i = 0; i < 6 && i < digest.length; i++) {
                hex.append(String.format(Locale.US, "%02x", digest[i] & 0xff));
            }
            return hex.toString();
        } catch (Exception e) {
            return String.format(Locale.US, "%08x", seed.hashCode());
        }
    }

    static String formatStackTrace(Throwable error) {
        if (error == null) return "";
        StringWriter sw = new StringWriter(2048);
        PrintWriter pw = new PrintWriter(sw);
        error.printStackTrace(pw);
        pw.flush();
        String sanitized = sanitize(sw.toString());
        if (sanitized.length() > MAX_STACK_CHARS) {
            return sanitized.substring(0, MAX_STACK_CHARS) + "\n... [truncated]";
        }
        return sanitized;
    }

    static String collectSanitizedAppLogs(int maxLines) {
        List<String> all = AppLog.entries();
        if (all.isEmpty()) return "";
        int start = Math.max(0, all.size() - Math.max(1, maxLines));
        StringBuilder sb = new StringBuilder();
        for (int i = start; i < all.size(); i++) {
            if (sb.length() > 0) sb.append('\n');
            sb.append(sanitize(all.get(i)));
        }
        return sb.toString();
    }

    /**
     * Synchronously captures an uncaught Java crash on the crashing thread before handing control
     * to the system default uncaught exception handler.
     */
    static void recordUncaughtCrash(MainActivity activity, Thread thread, Throwable error) {
        if (activity == null || activity.privateMode || error == null) return;
        try {
            File filesDir = activity.getFilesDir();
            if (filesDir == null) return;
            CrashReport report = createBaseReport(activity, KIND_JAVA);
            report.screen = detectScreenLabel(activity);
            report.playbackSnapshot = capturePlaybackSnapshot(activity);
            String exName = error.getClass().getSimpleName();
            if (exName.isEmpty()) exName = error.getClass().getName();
            String msg = sanitize(error.getMessage());
            if (msg.length() > 120) msg = msg.substring(0, 120) + "…";
            report.summary = report.screen + " · " + exName + (msg.isEmpty() ? "" : (": " + msg));
            String threadName = thread == null ? "?" : sanitize(thread.getName());
            report.stackTrace = "Thread: " + threadName + "\n" + formatStackTrace(error);
            report.fingerprint = computeFingerprint(KIND_JAVA, exName, report.stackTrace);
            report.recentLogs = collectSanitizedAppLogs(MAX_APPLOG_LINES);
            saveReport(filesDir, report);
        } catch (Throwable ignored) {
            // Never throw inside an uncaught exception handler.
        }
    }

    /** Creates a manual sanitized diagnostic snapshot (never written inside Privacy Space). */
    static CrashReport buildManualDiagnostic(MainActivity activity) {
        CrashReport report = createBaseReport(activity, KIND_DIAGNOSTIC);
        report.screen = "设置 · 运行诊断";
        report.summary = "手动反馈运行诊断日志";
        report.playbackSnapshot = capturePlaybackSnapshot(activity);
        report.stackTrace = "(用户手动导出当前运行态日志，无未捕获异常堆栈)";
        report.fingerprint =
                computeFingerprint(
                        KIND_DIAGNOSTIC,
                        report.appVersion + "_" + report.sdkInt,
                        report.deviceModel);
        report.recentLogs = collectSanitizedAppLogs(MAX_APPLOG_LINES);
        return report;
    }

    private static CrashReport createBaseReport(MainActivity activity, String kind) {
        CrashReport r = new CrashReport();
        long now = System.currentTimeMillis();
        r.timestampMs = now;
        r.kind = kind;
        r.id = "crash_" + now + "_" + String.format(Locale.US, "%04x", (int) (now & 0xffff));
        try {
            r.appVersion = UpdateManager.installedVersion(activity);
            r.appVersionCode = UpdateManager.installedCode(activity);
            r.edition = activity.isTvDevice() ? "android-tv" : "android-mobile";
        } catch (Throwable ignored) {
        }
        r.deviceModel = safeStr(Build.MODEL);
        r.manufacturer = safeStr(Build.MANUFACTURER);
        r.board = safeStr(Build.BOARD);
        r.hardware = safeStr(Build.HARDWARE);
        r.androidRelease = safeStr(Build.VERSION.RELEASE);
        r.sdkInt = Build.VERSION.SDK_INT;
        if (Build.VERSION.SDK_INT >= 21
                && Build.SUPPORTED_ABIS != null
                && Build.SUPPORTED_ABIS.length > 0) {
            r.abi = safeStr(Build.SUPPORTED_ABIS[0]);
        } else {
            r.abi = safeStr(Build.CPU_ABI);
        }
        try {
            ActivityManager am =
                    (ActivityManager) activity.getSystemService(Context.ACTIVITY_SERVICE);
            if (am != null) r.memoryClassMb = am.getMemoryClass();
        } catch (Throwable ignored) {
        }
        return r;
    }

    private static String detectScreenLabel(MainActivity a) {
        try {
            if (a.current == null) return "启动中";
            if (a.current.player) return a.isLive() ? "直播播放页" : "点播播放页";
            if (a.current.home) return "首页";
            if (a.searchScreen != null) return "搜索页";
            return "详情/浏览页";
        } catch (Throwable ignored) {
            return "未知页面";
        }
    }

    private static String capturePlaybackSnapshot(MainActivity a) {
        try {
            StringBuilder sb = new StringBuilder();
            if (a.prefs != null) {
                int engine = a.prefs.getInt(Prefs.PLAYER_ENGINE, 0);
                int dec = a.prefs.getInt(Prefs.DECODER_MODE, 0);
                int out = a.prefs.getInt(Prefs.VIDEO_OUTPUT, 0);
                sb.append("engine=")
                        .append(engine)
                        .append(", decoder=")
                        .append(dec)
                        .append(", output=")
                        .append(out);
            }
            if (a.player != null) {
                sb.append(", prepared=").append(a.prepared);
                sb.append(", hdr=").append(a.player.isHdrVideo());
                String res = sanitize(a.player.videoResolution());
                if (!res.isEmpty()) sb.append(", res=").append(res);
            }
            return sb.toString();
        } catch (Throwable ignored) {
            return "";
        }
    }

    /**
     * On Android 11+ (API 30+), imports recent Native crashes / LMK OOM kills / ANRs from {@link
     * ActivityManager#getHistoricalProcessExitReasons} so even native/LMK exits (e.g. Android 14
     * TV boxes) can be reviewed and reported on next launch.
     */
    static void collectHistoricalExitReasons(MainActivity activity) {
        if (activity == null || activity.privateMode || Build.VERSION.SDK_INT < 30) return;
        try {
            Api30ExitReasonHelper.collect(activity);
        } catch (Throwable ignored) {
        }
    }

    private static final class Api30ExitReasonHelper {
        static void collect(MainActivity activity) {
            if (Build.VERSION.SDK_INT < 30) return;
            ActivityManager am =
                    (ActivityManager) activity.getSystemService(Context.ACTIVITY_SERVICE);
            SharedPreferences prefs = activity.prefs;
            File filesDir = activity.getFilesDir();
            if (am == null || prefs == null || filesDir == null) return;
            long lastSeenTs = prefs.getLong(Prefs.CRASH_LAST_EXIT_TS, 0L);
            List<ApplicationExitInfo> reasons =
                    am.getHistoricalProcessExitReasons(activity.getPackageName(), 0, 5);
            if (reasons == null || reasons.isEmpty()) return;

            List<CrashReport> existing = loadReports(filesDir);
            long newestTs = lastSeenTs;
            for (ApplicationExitInfo info : reasons) {
                if (info == null) continue;
                long ts = info.getTimestamp();
                if (ts <= lastSeenTs) continue;
                if (ts > newestTs) newestTs = ts;
                int reason = info.getReason();
                String kind;
                if (reason == ApplicationExitInfo.REASON_CRASH_NATIVE) {
                    kind = KIND_NATIVE;
                } else if (reason == ApplicationExitInfo.REASON_LOW_MEMORY) {
                    kind = KIND_LOW_MEMORY;
                } else if (reason == ApplicationExitInfo.REASON_ANR) {
                    kind = KIND_ANR;
                } else {
                    continue;
                }
                // Dedupe if a Java uncaught crash already captured the same process death (±5s).
                boolean nearExisting = false;
                for (CrashReport ex : existing) {
                    if (Math.abs(ex.timestampMs - ts) <= 5000L) {
                        nearExisting = true;
                        break;
                    }
                }
                if (nearExisting) continue;

                CrashReport r = createBaseReport(activity, kind);
                r.timestampMs = ts;
                r.id = "exit_" + ts + "_" + String.format(Locale.US, "%04x", reason & 0xffff);
                r.screen = "上次运行进程异常终止";
                String desc = sanitize(info.getDescription());
                if (desc.length() > 140) desc = desc.substring(0, 140) + "…";
                r.summary =
                        r.kindLabel()
                                + " (status="
                                + info.getStatus()
                                + (desc.isEmpty() ? ")" : ", " + desc + ")");
                r.stackTrace =
                        "ProcessExitReason: "
                                + reason
                                + "\nStatus/Signal: "
                                + info.getStatus()
                                + "\nPSS(KB): "
                                + info.getPss()
                                + " / RSS(KB): "
                                + info.getRss()
                                + (desc.isEmpty() ? "" : ("\nDescription: " + desc));
                r.fingerprint =
                        computeFingerprint(
                                kind, "reason_" + reason + "_sig_" + info.getStatus(), desc);
                saveReport(filesDir, r);
                existing.add(r);
            }
            if (newestTs > lastSeenTs) {
                prefs.edit().putLong(Prefs.CRASH_LAST_EXIT_TS, newestTs).apply();
            }
        }
    }

    static synchronized void saveReport(File filesDir, CrashReport report) {
        if (filesDir == null || report == null) return;
        File dir = reportDir(filesDir);
        if (!dir.exists() && !dir.mkdirs()) return;
        try {
            byte[] data = encodeBoundedJson(report);
            File target = new File(dir, sanitizeFileName(report.id) + ".json");
            File tmp = new File(dir, target.getName() + ".tmp");
            try (FileOutputStream out = new FileOutputStream(tmp)) {
                out.write(data);
                out.flush();
            }
            if (!tmp.renameTo(target)) {
                // Fallback direct overwrite on filesystems where rename over existing fails.
                try (FileOutputStream out = new FileOutputStream(target)) {
                    out.write(data);
                    out.flush();
                }
                tmp.delete();
            }
            pruneReports(filesDir, System.currentTimeMillis());
        } catch (Exception ignored) {
        }
    }

    private static byte[] encodeBoundedJson(CrashReport report) throws Exception {
        byte[] raw = report.toJson().toString().getBytes(StandardCharsets.UTF_8);
        if (raw.length <= MAX_REPORT_BYTES) return raw;
        if (report.recentLogs != null && report.recentLogs.length() > 2048) {
            report.recentLogs = report.recentLogs.substring(report.recentLogs.length() - 2048);
            raw = report.toJson().toString().getBytes(StandardCharsets.UTF_8);
        }
        if (raw.length > MAX_REPORT_BYTES
                && report.stackTrace != null
                && report.stackTrace.length() > 4096) {
            report.stackTrace =
                    report.stackTrace.substring(0, 4096) + "\n... [truncated to 60KB budget]";
            raw = report.toJson().toString().getBytes(StandardCharsets.UTF_8);
        }
        return raw;
    }

    static synchronized List<CrashReport> loadReports(File filesDir) {
        List<CrashReport> list = new ArrayList<>();
        if (filesDir == null) return list;
        pruneReports(filesDir, System.currentTimeMillis());
        File dir = reportDir(filesDir);
        File[] files = dir.listFiles();
        if (files == null) return list;
        for (File f : files) {
            if (!f.isFile() || !f.getName().endsWith(".json")) continue;
            try {
                byte[] bytes = readAllBytes(f, MAX_REPORT_BYTES + 4096);
                JSONObject obj = new JSONObject(new String(bytes, StandardCharsets.UTF_8));
                CrashReport r = CrashReport.fromJson(obj);
                if (r != null) list.add(r);
            } catch (Exception ignored) {
                f.delete();
            }
        }
        Collections.sort(list, (a, b) -> Long.compare(b.timestampMs, a.timestampMs));
        return list;
    }

    static List<CrashReport> loadUnsubmittedReports(File filesDir) {
        List<CrashReport> all = loadReports(filesDir);
        List<CrashReport> out = new ArrayList<>();
        for (CrashReport r : all) {
            if (!r.submitted) out.add(r);
        }
        return out;
    }

    static synchronized void markSubmitted(
            File filesDir, List<CrashReport> reports, int issueNumber, String issueUrl) {
        if (filesDir == null || reports == null) return;
        for (CrashReport r : reports) {
            if (r == null || r.id.isEmpty()) continue;
            r.submitted = true;
            r.submittedIssueNumber = issueNumber;
            r.submittedIssueUrl = issueUrl == null ? "" : issueUrl;
            if (!KIND_DIAGNOSTIC.equals(r.kind)) {
                saveReport(filesDir, r);
            }
        }
    }

    static synchronized void clearAll(File filesDir) {
        if (filesDir == null) return;
        File dir = reportDir(filesDir);
        File[] files = dir.listFiles();
        if (files == null) return;
        for (File f : files) {
            f.delete();
        }
    }

    static synchronized void pruneReports(File filesDir, long nowMs) {
        File dir = reportDir(filesDir);
        File[] files = dir.listFiles();
        if (files == null || files.length == 0) return;
        List<File> valid = new ArrayList<>();
        for (File f : files) {
            if (!f.isFile() || !f.getName().endsWith(".json")) {
                f.delete();
                continue;
            }
            if (nowMs - f.lastModified() > MAX_AGE_MS && f.lastModified() > 0) {
                f.delete();
                continue;
            }
            valid.add(f);
        }
        if (valid.size() <= MAX_REPORTS) return;
        Collections.sort(valid, (a, b) -> Long.compare(b.lastModified(), a.lastModified()));
        for (int i = MAX_REPORTS; i < valid.size(); i++) {
            valid.get(i).delete();
        }
    }

    static String formatIssueTitle(List<CrashReport> reports) {
        if (reports == null || reports.isEmpty()) {
            return "[Crash] MarcoMovie 异常反馈";
        }
        CrashReport first = reports.get(0);
        String ed = "android-mobile".equals(first.edition) ? "Mobile" : "TV";
        String ver = first.appVersion.isEmpty() ? "unknown" : first.appVersion;
        String sum =
                first.summary == null || first.summary.isEmpty()
                        ? first.kindLabel()
                        : first.summary;
        if (sum.length() > 72) sum = sum.substring(0, 72) + "…";
        String suffix = reports.size() > 1 ? " (+" + (reports.size() - 1) + "条)" : "";
        return "[Crash][" + ed + " " + ver + "] " + sum + suffix;
    }

    static String formatIssueMarkdown(List<CrashReport> reports) {
        if (reports == null || reports.isEmpty()) return "";
        CrashReport primary = reports.get(0);
        StringBuilder sb = new StringBuilder(4096);
        sb.append("<!-- crash-fingerprint: ").append(primary.fingerprint).append(" -->\n");
        sb.append("### 设备与版本信息\n");
        sb.append("| 字段 | 值 |\n| --- | --- |\n");
        sb.append("| 应用版本 | `")
                .append(primary.appVersion)
                .append("` (code ")
                .append(primary.appVersionCode)
                .append(", ")
                .append(primary.edition)
                .append(") |\n");
        sb.append("| 设备型号 | `")
                .append(primary.manufacturer)
                .append(' ')
                .append(primary.deviceModel)
                .append("` (board=`")
                .append(primary.board)
                .append("`, hw=`")
                .append(primary.hardware)
                .append("`, abi=`")
                .append(primary.abi)
                .append("`) |\n");
        sb.append("| 系统版本 | Android ")
                .append(primary.androidRelease)
                .append(" (API ")
                .append(primary.sdkInt)
                .append(") · 堆内存上限 ")
                .append(primary.memoryClassMb)
                .append(" MB |\n");
        if (!primary.playbackSnapshot.isEmpty()) {
            sb.append("| 播放状态 | `").append(sanitize(primary.playbackSnapshot)).append("` |\n");
        }
        sb.append("| 崩溃指纹 | `").append(primary.fingerprint).append("` |\n\n");

        for (int i = 0; i < reports.size(); i++) {
            CrashReport r = reports.get(i);
            sb.append("### 记录 #")
                    .append(i + 1)
                    .append(" · ")
                    .append(r.displayTime())
                    .append(" · ")
                    .append(r.kindLabel())
                    .append("\n");
            sb.append("- **页面**：").append(r.screen).append('\n');
            sb.append("- **摘要**：").append(sanitize(r.summary)).append("\n\n");
            if (!r.stackTrace.isEmpty()) {
                sb.append("<details>\n<summary>异常堆栈 / 进程退出信息（已脱敏）</summary>\n\n```text\n")
                        .append(sanitize(r.stackTrace))
                        .append("\n```\n</details>\n\n");
            }
            if (!r.recentLogs.isEmpty()) {
                sb.append("<details>\n<summary>最近运行日志（已脱敏）</summary>\n\n```text\n")
                        .append(sanitize(r.recentLogs))
                        .append("\n```\n</details>\n\n");
            }
        }
        sb.append("_由 Marco Movie 客户端脱敏生成（不含片源链接、网盘凭证与个人隐私数据）。_\n");
        return sb.toString();
    }

    /**
     * Builds a pre-filled GitHub New Issue URL within browser URL length limits so users on mobile
     * can file a GitHub Issue with one tap when the automatic relay is unreachable.
     */
    static String buildGithubNewIssueUrl(List<CrashReport> reports) {
        String title = formatIssueTitle(reports);
        String body = formatIssueMarkdown(reports);
        if (body.length() > MAX_GITHUB_URL_BODY_CHARS) {
            body =
                    body.substring(0, MAX_GITHUB_URL_BODY_CHARS)
                            + "\n\n...(完整日志已截断，请点击页面「一键复制完整日志」粘贴补充)";
        }
        try {
            return GITHUB_ISSUES_NEW_URL
                    + "?labels="
                    + URLEncoder.encode("bug,crash-report", "UTF-8")
                    + "&title="
                    + URLEncoder.encode(title, "UTF-8")
                    + "&body="
                    + URLEncoder.encode(body, "UTF-8");
        } catch (Exception e) {
            return GITHUB_ISSUES_NEW_URL;
        }
    }

    private static String sanitizeFileName(String raw) {
        if (raw == null || raw.isEmpty()) return "crash_" + System.currentTimeMillis();
        return raw.replaceAll("[^A-Za-z0-9_.-]", "_");
    }

    private static String safeStr(String s) {
        return s == null ? "" : s.trim();
    }

    private static byte[] readAllBytes(File file, int maxBytes) throws IOException {
        try (FileInputStream in = new FileInputStream(file);
                ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buf = new byte[4096];
            int n;
            int total = 0;
            while ((n = in.read(buf)) != -1) {
                total += n;
                if (total > maxBytes) throw new IOException("Crash report exceeds size limit");
                out.write(buf, 0, n);
            }
            return out.toByteArray();
        }
    }

    static List<String> buildIssueLabels(CrashReport primary) {
        String edition =
                primary != null && "android-mobile".equals(primary.edition)
                        ? "android-mobile"
                        : "android-tv";
        return Arrays.asList("bug", "crash-report", edition);
    }
}
