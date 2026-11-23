package com.pilipala.marcomovie;

import android.app.Application;
import android.os.Build;
import android.util.Base64;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.Callable;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Built-in native CPython 3.11 source engine using {@code libmarco_python.so} + {@code
 * libpython3.11.so}. Supports full Python 3.11 syntax, stdlib, requests, SSL/TLS with certifi CA
 * roots, pure-Python AES/Crypto, and HTML/XPath/BeautifulSoup spiders.
 */
public final class NativePythonEngine implements SourceEngine {
    private static final long DEFAULT_TIMEOUT_MS = 45000L;
    private static final ConcurrentHashMap<String, NativePythonEngine> ACTIVE =
            new ConcurrentHashMap<>();
    private static final Object INIT_LOCK = new Object();
    private static volatile Boolean nativeAvailable;
    private static volatile boolean runtimeReady;

    private static native byte[] nativeInit(
            byte[] homeDir,
            byte[] stdlibZip,
            byte[] dynloadDir,
            byte[] siteDir,
            byte[] runnerDir,
            byte[] cacertPath);

    private static native byte[] nativeCall(
            byte[] siteKey,
            byte[] scriptPath,
            byte[] extJson,
            byte[] proxyBase,
            byte[] methodName,
            byte[] argsJson);

    private static native byte[] nativeProxy(byte[] siteKey, byte[] paramsJson);

    private static native void nativeRelease(byte[] siteKey);

    public static boolean eligible(Cms.Site s) {
        if (s == null || s.type != 3) return false;
        if ("csp_LocalPython".equals(s.api) && s.ext instanceof String) return true;
        if (s.api != null && (Cms.isHttp(s.api) || s.api.startsWith("file://"))) {
            String clean = s.api.split("[?#]", 2)[0].toLowerCase(Locale.ROOT);
            if (clean.endsWith(".py")) return true;
        }
        return false;
    }

    public static boolean isAvailable() {
        Boolean cached = nativeAvailable;
        if (cached != null) return cached;
        synchronized (INIT_LOCK) {
            if (nativeAvailable == null) {
                try {
                    System.loadLibrary("python3.11");
                    System.loadLibrary("marco_python");
                    nativeAvailable = Boolean.TRUE;
                } catch (Throwable error) {
                    nativeAvailable = Boolean.FALSE;
                }
            }
            return nativeAvailable;
        }
    }

    static Object[] proxyFor(Map<String, String> params) throws Exception {
        String key = params.get("siteKey");
        if (key == null) key = params.get("site");
        if (key == null) return null;
        NativePythonEngine engine = ACTIVE.get(key);
        if (engine == null || engine.closed) return null;
        return engine.proxy(params);
    }

    private final Application app;
    private final Cms.Site site;
    private final String proxyKey = UUID.randomUUID().toString().replace("-", "");
    private final String instanceKey;
    private final String scriptPath;
    private final String extString;
    private final ExecutorService executor =
            Executors.newSingleThreadExecutor(
                    r -> {
                        Thread t = new Thread(r, "movie-native-python");
                        t.setDaemon(true);
                        return t;
                    });
    private volatile boolean closed;

    public NativePythonEngine(Application application, Cms.Config config, Cms.Site selected)
            throws Exception {
        if (!isAvailable()) {
            throw new IOException("设备未加载内置 CPython 3.11 运行时");
        }
        this.app = application;
        this.site = selected;
        this.instanceKey = selected.key + ":" + proxyKey.substring(0, 8);
        ensureRuntimeInitialized(application);
        this.scriptPath = materializeScript(application, selected);
        this.extString = resolveExtString(selected);
        LocalProxy.nativePythonProxy = NativePythonEngine::proxyFor;
        ACTIVE.put(proxyKey, this);
        try {
            callPython("init", new JSONArray());
        } catch (Exception error) {
            close();
            throw error;
        }
    }

    private static void ensureRuntimeInitialized(Application app) throws IOException {
        if (runtimeReady) return;
        synchronized (INIT_LOCK) {
            if (runtimeReady) return;
            File root = new File(app.getFilesDir(), "python311");
            File versionFile = new File(root, ".version");
            String expectedVersion = readAssetText(app, "python-native/runtime-version.txt").trim();
            String currentVersion = versionFile.isFile() ? readFileText(versionFile).trim() : "";

            File stdlibZip = new File(root, "stdlib-pyc.zip");
            File siteDir = new File(root, "site-packages");
            File dynloadDir = new File(root, "lib-dynload");
            File runnerDir = new File(root, "runner");
            File cacert = new File(siteDir, "certifi/cacert.pem");

            if (!expectedVersion.equals(currentVersion)
                    || !stdlibZip.isFile()
                    || !cacert.isFile()
                    || !new File(runnerDir, "android_runner.py").isFile()) {
                deleteRecursive(root);
                root.mkdirs();
                copyAssetToFile(app, "python-native/stdlib-pyc.zip", stdlibZip);
                extractAssetZip(app, "python-native/site-packages.zip", siteDir);
                String abi = chooseDynloadAbi(app);
                extractAssetZip(app, "python-native/lib-dynload-" + abi + ".zip", dynloadDir);
                copyAssetToFile(
                        app,
                        "python-native/android_runner.py",
                        new File(runnerDir, "android_runner.py"));
                copyAssetToFile(
                        app, "python-native/base/spider.py", new File(runnerDir, "base/spider.py"));
                File baseInit = new File(runnerDir, "base/__init__.py");
                if (!baseInit.exists()) {
                    baseInit.getParentFile().mkdirs();
                    writeBytes(baseInit, new byte[0]);
                }
                writeBytes(versionFile, expectedVersion.getBytes(StandardCharsets.UTF_8));
            }

            byte[] initResultBytes =
                    nativeInit(
                            utf8(root.getAbsolutePath()),
                            utf8(stdlibZip.getAbsolutePath()),
                            utf8(dynloadDir.getAbsolutePath()),
                            utf8(siteDir.getAbsolutePath()),
                            utf8(runnerDir.getAbsolutePath()),
                            utf8(cacert.getAbsolutePath()));
            JSONObject status = parseEnvelope(initResultBytes);
            if (!status.optBoolean("ok", false)) {
                throw new IOException("内置 Python 初始化失败：" + status.optString("error", "unknown"));
            }
            runtimeReady = true;
        }
    }

    static String selectDynloadAbi(
            String[] supportedAbis,
            boolean process64Bit,
            boolean hasArm64Asset,
            boolean hasArm32Asset) {
        // Always match the running process bitness (Process.is64Bit()), never a 64-bit SoC's
        // Build.SUPPORTED_ABIS when running a 32-bit APK, to avoid dlopen/SIGABRT mismatches.
        if (process64Bit) {
            if (hasArm64Asset) return "arm64-v8a";
        } else {
            if (hasArm32Asset) return "armeabi-v7a";
        }
        if (supportedAbis != null) {
            for (String abi : supportedAbis) {
                if ("arm64-v8a".equals(abi) && process64Bit && hasArm64Asset) return "arm64-v8a";
                if ("armeabi-v7a".equals(abi) && !process64Bit && hasArm32Asset)
                    return "armeabi-v7a";
            }
        }
        return process64Bit ? "arm64-v8a" : "armeabi-v7a";
    }

    private static String chooseDynloadAbi(Application app) {
        return selectDynloadAbi(
                Build.SUPPORTED_ABIS,
                CspEngine.isCurrentProcess64Bit(),
                assetExists(app, "python-native/lib-dynload-arm64-v8a.zip"),
                assetExists(app, "python-native/lib-dynload-armeabi-v7a.zip"));
    }

    private static boolean assetExists(Application app, String path) {
        try (InputStream ignored = app.getAssets().open(path)) {
            return true;
        } catch (IOException missing) {
            return false;
        }
    }

    private static String materializeScript(Application app, Cms.Site s) throws Exception {
        if ("csp_LocalPython".equals(s.api) && s.ext instanceof String) {
            String extPath = ((String) s.ext).trim();
            if (extPath.startsWith("file://")) {
                extPath = extPath.substring("file://".length());
            }
            File local = new File(extPath);
            if (local.isFile()) return local.getAbsolutePath();
            if (Cms.isHttp(extPath)) {
                return downloadScript(app, s.key, extPath, s.headers);
            }
        }
        if (s.api != null && s.api.startsWith("file://")) {
            File local = new File(s.api.substring("file://".length()));
            if (local.isFile()) return local.getAbsolutePath();
        }
        if (Cms.isHttp(s.api)) {
            return downloadScript(app, s.key, s.api, s.headers);
        }
        throw new IOException("无法定位 Python 爬虫脚本地址");
    }

    private static String downloadScript(
            Application app, String siteKey, String url, Map<String, String> headers)
            throws Exception {
        String code = Cms.fetch(url, headers);
        if (code == null || code.trim().isEmpty()) {
            throw new IOException("Python 爬虫脚本内容为空");
        }
        File dir = new File(app.getCacheDir(), "python-spiders/" + sha16(siteKey + ":" + url));
        dir.mkdirs();
        File target = new File(dir, "spider.py");
        writeBytes(target, code.getBytes(StandardCharsets.UTF_8));
        return target.getAbsolutePath();
    }

    private static String resolveExtString(Cms.Site s) {
        if ("csp_LocalPython".equals(s.api)) return "";
        if (s.ext == null) return "";
        if (s.ext instanceof String) return (String) s.ext;
        return String.valueOf(s.ext);
    }

    private String proxyBaseUrl() {
        String base = LocalProxy.address() + "/proxy?do=py&siteKey=" + proxyKey;
        if (ProxyAddress.token != null && !ProxyAddress.token.isEmpty()) {
            base += "&_mm_token=" + ProxyAddress.token;
        }
        return base;
    }

    private String callPython(String method, JSONArray args) throws Exception {
        return runBounded(
                () -> {
                    byte[] raw =
                            nativeCall(
                                    utf8(instanceKey),
                                    utf8(scriptPath),
                                    utf8(extString),
                                    utf8(proxyBaseUrl()),
                                    utf8(method),
                                    utf8(args.toString()));
                    JSONObject env = parseEnvelope(raw);
                    if (!env.optBoolean("ok", false)) {
                        throw new IOException("Python 源执行失败：" + env.optString("error", "unknown"));
                    }
                    return env.optString("data", "{}");
                });
    }

    private <T> T runBounded(Callable<T> task) throws Exception {
        if (closed) throw new IOException("Python 来源已关闭");
        Future<T> future = executor.submit(task);
        try {
            return future.get(DEFAULT_TIMEOUT_MS, TimeUnit.MILLISECONDS);
        } catch (Exception e) {
            future.cancel(true);
            if (e.getCause() instanceof Exception) throw (Exception) e.getCause();
            throw new IOException("Python 来源调用超时或中断", e);
        }
    }

    @Override
    public String home() throws Exception {
        return callPython("homeContent", new JSONArray().put(true));
    }

    @Override
    public String homeVideos() throws Exception {
        return callPython("homeVideoContent", new JSONArray());
    }

    @Override
    public String category(String categoryId, int page) throws Exception {
        return category(categoryId, page, null);
    }

    @Override
    public String category(String categoryId, int page, Map<String, String> filters)
            throws Exception {
        JSONObject ext = filters == null ? new JSONObject() : new JSONObject(filters);
        JSONArray args =
                new JSONArray()
                        .put(categoryId)
                        .put(String.valueOf(page))
                        .put(filters != null && !filters.isEmpty())
                        .put(ext);
        return callPython("categoryContent", args);
    }

    @Override
    public String detail(String videoId) throws Exception {
        JSONArray ids = new JSONArray().put(videoId);
        return callPython("detailContent", new JSONArray().put(ids));
    }

    @Override
    public String search(String keyword, int page) throws Exception {
        JSONArray args = new JSONArray().put(keyword).put(false).put(String.valueOf(page));
        return callPython("searchContent", args);
    }

    @Override
    public String player(String flag, String id) throws Exception {
        JSONArray args = new JSONArray().put(flag).put(id).put(new JSONArray());
        return callPython("playerContent", args);
    }

    @Override
    public String action(String action) throws Exception {
        return callPython("action", new JSONArray().put(action));
    }

    Object[] proxy(Map<String, String> params) throws Exception {
        return runBounded(
                () -> {
                    byte[] raw =
                            nativeProxy(utf8(instanceKey), utf8(new JSONObject(params).toString()));
                    JSONObject env = parseEnvelope(raw);
                    if (!env.optBoolean("ok", false)) {
                        throw new IOException(
                                "Python localProxy 失败：" + env.optString("error", "unknown"));
                    }
                    int code = env.optInt("code", 200);
                    String mime = env.optString("mime", "application/octet-stream");
                    byte[] body = Base64.decode(env.optString("body_b64", ""), Base64.DEFAULT);
                    Map<String, String> headers = new LinkedHashMap<>();
                    JSONObject hdrs = env.optJSONObject("headers");
                    if (hdrs != null) {
                        Iterator<String> keys = hdrs.keys();
                        while (keys.hasNext()) {
                            String k = keys.next();
                            headers.put(k, hdrs.optString(k, ""));
                        }
                    }
                    return new Object[] {code, mime, body, headers};
                });
    }

    @Override
    public boolean requiresExternalRuntime() {
        return false;
    }

    @Override
    public boolean isClosed() {
        return closed;
    }

    @Override
    public void close() {
        if (closed) return;
        closed = true;
        ACTIVE.remove(proxyKey);
        executor.execute(
                () -> {
                    try {
                        if (runtimeReady) nativeRelease(utf8(instanceKey));
                    } catch (Throwable ignored) {
                    }
                });
        executor.shutdown();
    }

    private static byte[] utf8(String text) {
        return (text == null ? "" : text).getBytes(StandardCharsets.UTF_8);
    }

    private static JSONObject parseEnvelope(byte[] raw) throws IOException {
        if (raw == null || raw.length == 0) {
            throw new IOException("Empty native Python response");
        }
        try {
            return new JSONObject(new String(raw, StandardCharsets.UTF_8));
        } catch (Exception e) {
            throw new IOException("Malformed native Python response", e);
        }
    }

    private static String readAssetText(Application app, String assetPath) throws IOException {
        try (InputStream in = app.getAssets().open(assetPath)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream(256);
            byte[] buf = new byte[1024];
            int n;
            while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    private static String readFileText(File file) throws IOException {
        try (InputStream in = new java.io.FileInputStream(file)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream(256);
            byte[] buf = new byte[1024];
            int n;
            while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    private static void copyAssetToFile(Application app, String assetPath, File dst)
            throws IOException {
        dst.getParentFile().mkdirs();
        try (InputStream in = app.getAssets().open(assetPath);
                FileOutputStream out = new FileOutputStream(dst)) {
            byte[] buf = new byte[16384];
            int n;
            while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
        }
    }

    private static void extractAssetZip(Application app, String assetPath, File dstDir)
            throws IOException {
        dstDir.mkdirs();
        String canonicalRoot = dstDir.getCanonicalPath() + File.separator;
        try (InputStream in = app.getAssets().open(assetPath);
                ZipInputStream zis = new ZipInputStream(in)) {
            byte[] buf = new byte[16384];
            ZipEntry entry;
            while ((entry = zis.getNextEntry()) != null) {
                if (entry.isDirectory()) continue;
                File outFile = new File(dstDir, entry.getName());
                if (!outFile.getCanonicalPath().startsWith(canonicalRoot)) {
                    throw new IOException("Unsafe zip entry: " + entry.getName());
                }
                outFile.getParentFile().mkdirs();
                try (FileOutputStream fos = new FileOutputStream(outFile)) {
                    int n;
                    while ((n = zis.read(buf)) != -1) fos.write(buf, 0, n);
                }
                zis.closeEntry();
            }
        }
    }

    private static void writeBytes(File dst, byte[] data) throws IOException {
        dst.getParentFile().mkdirs();
        try (FileOutputStream fos = new FileOutputStream(dst)) {
            fos.write(data);
        }
    }

    private static void deleteRecursive(File file) {
        if (file == null || !file.exists()) return;
        if (file.isDirectory()) {
            File[] children = file.listFiles();
            if (children != null) {
                for (File child : children) deleteRecursive(child);
            }
        }
        file.delete();
    }

    private static String sha16(String input) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] digest = md.digest(input.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < 8; i++)
                sb.append(String.format(Locale.ROOT, "%02x", digest[i] & 0xFF));
            return sb.toString();
        } catch (Exception ignored) {
            return Integer.toHexString(input.hashCode());
        }
    }
}
