package com.pilipala.marcomovie;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Native AList v3 media library {@link SourceEngine}.
 *
 * <p>Supports public/guest mounts, username+password JWT auth (with automatic 401 refresh), static
 * token auth, folder passwords, recursive folder browsing via Marco Movie's {@code folder} route,
 * natural-sorted multi-episode folder grouping, automatic sibling subtitle discovery, direct stream
 * resolution, and AList search.
 */
final class AlistEngine implements SourceEngine {
    static final String PREFIX = "alist://mount/";
    private static final int MAX_RESPONSE_BYTES = 8 * 1024 * 1024;
    private static final int CONNECT_TIMEOUT_MS = 10_000;
    private static final int READ_TIMEOUT_MS = 20_000;

    private static final String[] VIDEO_EXTS = {
        ".mp4", ".mkv", ".m4v", ".webm", ".avi", ".mov", ".flv", ".ts", ".m2ts", ".rmvb", ".wmv",
        ".mpg", ".mpeg", ".3gp", ".m3u8", ".iso"
    };
    private static final String[] SUBTITLE_EXTS = {".srt", ".ass", ".ssa", ".vtt"};
    private static final String[] COVER_NAMES = {
        "poster.jpg",
        "poster.png",
        "poster.webp",
        "cover.jpg",
        "cover.png",
        "folder.jpg",
        "folder.png",
        "fanart.jpg",
        "backdrop.jpg"
    };

    static final class MountConfig {
        final String id;
        final String name;
        final String baseUrl;
        final String rootPath;
        final String username;
        final String password;
        final String token;
        final String folderPassword;

        MountConfig(
                String id,
                String name,
                String baseUrl,
                String rootPath,
                String username,
                String password,
                String token,
                String folderPassword) {
            this.baseUrl = normalizeBaseUrl(baseUrl);
            this.rootPath = normalizePath(rootPath);
            this.id =
                    id != null && !id.trim().isEmpty()
                            ? id.trim()
                            : generateMountId(this.baseUrl, this.rootPath);
            String cleanName = name == null ? "" : name.trim();
            this.name = cleanName.isEmpty() ? defaultNameForUrl(this.baseUrl) : cleanName;
            this.username = username == null ? "" : username.trim();
            this.password = password == null ? "" : password;
            this.token = token == null ? "" : token.trim();
            this.folderPassword = folderPassword == null ? "" : folderPassword;
        }

        String apiUri() {
            return PREFIX + id;
        }

        String siteKey() {
            return "alist_" + id;
        }

        JSONObject toJson() throws Exception {
            JSONObject o = new JSONObject();
            o.put("id", id);
            o.put("name", name);
            o.put("baseUrl", baseUrl);
            o.put("rootPath", rootPath);
            o.put("username", username);
            o.put("password", password);
            o.put("token", token);
            o.put("folderPassword", folderPassword);
            return o;
        }

        static MountConfig fromJson(JSONObject o) {
            if (o == null) return null;
            String url = Cms.optSafeString(o, "baseUrl");
            if (url.trim().isEmpty()) return null;
            return new MountConfig(
                    Cms.optSafeString(o, "id"),
                    Cms.optSafeString(o, "name"),
                    url,
                    Cms.optSafeString(o, "rootPath", "/"),
                    Cms.optSafeString(o, "username"),
                    Cms.optSafeString(o, "password"),
                    Cms.optSafeString(o, "token"),
                    Cms.optSafeString(o, "folderPassword"));
        }
    }

    static final class FsItem {
        final String name;
        final String path;
        final boolean isDir;
        final long size;
        final String thumb;
        final String sign;
        final String rawUrl;

        FsItem(
                String name,
                String path,
                boolean isDir,
                long size,
                String thumb,
                String sign,
                String rawUrl) {
            this.name = name == null ? "" : name;
            this.path = normalizePath(path);
            this.isDir = isDir;
            this.size = Math.max(0L, size);
            this.thumb = thumb == null ? "" : thumb.trim();
            this.sign = sign == null ? "" : sign.trim();
            this.rawUrl = rawUrl == null ? "" : rawUrl.trim();
        }
    }

    static final class ListResult {
        final List<FsItem> items;
        final int total;

        ListResult(List<FsItem> items, int total) {
            this.items = items;
            this.total = Math.max(items.size(), total);
        }
    }

    private final Client client;

    AlistEngine(MainActivity activity, Cms.Site site) throws Exception {
        MountConfig cfg = AlistAccounts.find(activity, site != null ? site.api : "");
        if (cfg == null) {
            throw new IOException("未找到对应的 AList 挂载配置，请在「片源与直播 → 挂载 AList」重新添加");
        }
        this.client = new Client(cfg);
    }

    AlistEngine(MountConfig config) {
        this.client = new Client(config);
    }

    static String parseMountId(String api) {
        if (api == null) return "";
        if (api.startsWith(PREFIX)) {
            return api.substring(PREFIX.length()).trim();
        }
        return api.trim();
    }

    static String generateMountId(String baseUrl, String rootPath) {
        String seed = normalizeBaseUrl(baseUrl) + "|" + normalizePath(rootPath);
        int hash = seed.hashCode() & 0x7fffffff;
        return Integer.toHexString(hash);
    }

    static String normalizeBaseUrl(String raw) {
        if (raw == null) return "";
        String s = raw.trim();
        if (s.isEmpty()) return "";
        if (!s.regionMatches(true, 0, "http://", 0, 7)
                && !s.regionMatches(true, 0, "https://", 0, 8)) {
            s = "http://" + s;
        }
        while (s.endsWith("/")) {
            s = s.substring(0, s.length() - 1);
        }
        return s;
    }

    static String defaultNameForUrl(String baseUrl) {
        try {
            URI u = URI.create(baseUrl);
            String host = u.getHost();
            if (host != null && !host.isEmpty()) {
                return u.getPort() > 0 ? host + ":" + u.getPort() : host;
            }
        } catch (Exception ignored) {
        }
        return "AList";
    }

    static String normalizePath(String raw) {
        if (raw == null || raw.trim().isEmpty()) return "/";
        String s = raw.trim().replace('\\', '/');
        while (s.contains("//")) {
            s = s.replace("//", "/");
        }
        if (!s.startsWith("/")) s = "/" + s;
        while (s.length() > 1 && s.endsWith("/")) {
            s = s.substring(0, s.length() - 1);
        }
        return s;
    }

    static String joinPath(String parent, String child) {
        String p = normalizePath(parent);
        String c = child == null ? "" : child.trim().replace('\\', '/');
        while (c.startsWith("/")) c = c.substring(1);
        if (c.isEmpty()) return p;
        return "/".equals(p) ? "/" + c : p + "/" + c;
    }

    static String parentPath(String path) {
        String p = normalizePath(path);
        int slash = p.lastIndexOf('/');
        if (slash <= 0) return "/";
        return p.substring(0, slash);
    }

    static String fileName(String path) {
        String p = normalizePath(path);
        int slash = p.lastIndexOf('/');
        return slash >= 0 && slash + 1 < p.length() ? p.substring(slash + 1) : p;
    }

    static String stripExtension(String name) {
        if (name == null) return "";
        int dot = name.lastIndexOf('.');
        if (dot > 0 && name.length() - dot <= 6) {
            return name.substring(0, dot);
        }
        return name;
    }

    static boolean isVideoFile(String name) {
        if (name == null || name.isEmpty()) return false;
        String lower = name.toLowerCase(Locale.ROOT);
        for (String ext : VIDEO_EXTS) {
            if (lower.endsWith(ext)) return true;
        }
        return false;
    }

    static boolean isSubtitleFile(String name) {
        if (name == null || name.isEmpty()) return false;
        String lower = name.toLowerCase(Locale.ROOT);
        for (String ext : SUBTITLE_EXTS) {
            if (lower.endsWith(ext)) return true;
        }
        return false;
    }

    static boolean isCoverImage(String name) {
        if (name == null || name.isEmpty()) return false;
        String lower = name.toLowerCase(Locale.ROOT);
        for (String cover : COVER_NAMES) {
            if (lower.equals(cover)) return true;
        }
        return false;
    }

    static String encodePathSegments(String path) {
        String norm = normalizePath(path);
        if ("/".equals(norm)) return "/";
        String[] parts = norm.substring(1).split("/");
        StringBuilder sb = new StringBuilder();
        for (String part : parts) {
            sb.append('/');
            try {
                sb.append(URLEncoder.encode(part, "UTF-8").replace("+", "%20"));
            } catch (Exception ignored) {
                sb.append(part);
            }
        }
        return sb.toString();
    }

    static String buildDirectDownloadUrl(String baseUrl, String path, String sign) {
        String base = normalizeBaseUrl(baseUrl);
        if (base.isEmpty()) return "";
        String url = base + "/d" + encodePathSegments(path);
        if (sign != null && !sign.trim().isEmpty()) {
            try {
                url += "?sign=" + URLEncoder.encode(sign.trim(), "UTF-8");
            } catch (Exception ignored) {
                url += "?sign=" + sign.trim();
            }
        }
        return url;
    }

    static String formatFileSize(long bytes) {
        if (bytes <= 0) return "";
        if (bytes >= 1024L * 1024L * 1024L) {
            return String.format(Locale.US, "%.2f GB", bytes / (1024.0 * 1024.0 * 1024.0));
        }
        if (bytes >= 1024L * 1024L) {
            return String.format(Locale.US, "%.1f MB", bytes / (1024.0 * 1024.0));
        }
        return (bytes / 1024L) + " KB";
    }

    /** Natural numeric-aware comparator so S01E2 sorts before S01E10. */
    static int naturalCompare(String a, String b) {
        String sa = a == null ? "" : a;
        String sb = b == null ? "" : b;
        int ia = 0, ib = 0;
        int na = sa.length(), nb = sb.length();
        while (ia < na && ib < nb) {
            char ca = sa.charAt(ia);
            char cb = sb.charAt(ib);
            if (Character.isDigit(ca) && Character.isDigit(cb)) {
                int za = ia;
                while (za < na && sa.charAt(za) == '0') za++;
                int zb = ib;
                while (zb < nb && sb.charAt(zb) == '0') zb++;
                int ea = za;
                while (ea < na && Character.isDigit(sa.charAt(ea))) ea++;
                int eb = zb;
                while (eb < nb && Character.isDigit(sb.charAt(eb))) eb++;
                int lenDiff = (ea - za) - (eb - zb);
                if (lenDiff != 0) return lenDiff;
                for (int k = 0; k < ea - za; k++) {
                    int diff = sa.charAt(za + k) - sb.charAt(zb + k);
                    if (diff != 0) return diff;
                }
                ia = ea;
                ib = eb;
            } else {
                int diff = Character.toLowerCase(ca) - Character.toLowerCase(cb);
                if (diff != 0) return diff;
                ia++;
                ib++;
            }
        }
        return (na - ia) - (nb - ib);
    }

    static List<FsItem> matchSiblingSubtitles(String videoName, List<FsItem> siblings) {
        List<FsItem> matched = new ArrayList<>();
        if (videoName == null || siblings == null || siblings.isEmpty()) return matched;
        String stem = stripExtension(videoName).toLowerCase(Locale.ROOT);
        int videoEp = HistoryResumeMatcher.extractEpisodeNumber(videoName);
        int videoCount = 0;
        List<FsItem> allSubs = new ArrayList<>();
        for (FsItem item : siblings) {
            if (item == null || item.isDir) continue;
            if (isVideoFile(item.name)) videoCount++;
            else if (isSubtitleFile(item.name)) allSubs.add(item);
        }
        if (allSubs.isEmpty()) return matched;
        for (FsItem sub : allSubs) {
            String subStem = stripExtension(sub.name).toLowerCase(Locale.ROOT);
            boolean stemMatch =
                    !stem.isEmpty() && (subStem.equals(stem) || subStem.startsWith(stem + "."));
            boolean epMatch =
                    videoEp > 0 && HistoryResumeMatcher.extractEpisodeNumber(sub.name) == videoEp;
            boolean singleMovieSub = videoCount <= 1;
            if (stemMatch || epMatch || singleMovieSub) {
                matched.add(sub);
            }
        }
        Collections.sort(
                matched,
                new Comparator<FsItem>() {
                    @Override
                    public int compare(FsItem x, FsItem y) {
                        int sx = subtitleSortWeight(x.name);
                        int sy = subtitleSortWeight(y.name);
                        if (sx != sy) return Integer.compare(sy, sx);
                        return naturalCompare(x.name, y.name);
                    }
                });
        return matched;
    }

    private static int subtitleSortWeight(String name) {
        String bucket = SubtitlePreferenceStore.detectLangBucket(name);
        if ("zh-hans-bi".equals(bucket)) return 5;
        if ("zh-hans".equals(bucket)) return 4;
        if ("zh".equals(bucket)) return 3;
        if ("zh-hant-bi".equals(bucket) || "zh-hant".equals(bucket)) return 2;
        return 1;
    }

    static final class Client {
        final MountConfig config;
        private volatile String activeToken;
        private final Map<String, List<FsItem>> dirCache = new ConcurrentHashMap<>();

        Client(MountConfig config) {
            this.config = config;
            this.activeToken = config.token;
        }

        private synchronized String ensureToken(boolean forceRefresh) throws IOException {
            if (!forceRefresh && activeToken != null && !activeToken.isEmpty()) {
                return activeToken;
            }
            if (!config.token.isEmpty()) {
                activeToken = config.token;
                return activeToken;
            }
            if (config.username.isEmpty()) {
                return "";
            }
            try {
                JSONObject body =
                        new JSONObject()
                                .put("username", config.username)
                                .put("password", config.password);
                JSONObject resp = rawPost("/api/auth/login", body, "");
                int code = resp.optInt("code", -1);
                if (code != 200) {
                    String msg = Cms.optSafeString(resp, "message", "登录失败");
                    throw new IOException("AList 登录失败：" + msg);
                }
                JSONObject data = resp.optJSONObject("data");
                String tok = data != null ? Cms.optSafeString(data, "token") : "";
                if (tok.isEmpty()) {
                    throw new IOException("AList 未返回有效登录凭据");
                }
                activeToken = tok;
                return tok;
            } catch (IOException e) {
                throw e;
            } catch (Exception e) {
                throw new IOException("AList 认证失败：" + e.getMessage(), e);
            }
        }

        private JSONObject rawPost(String apiPath, JSONObject payload, String authToken)
                throws IOException {
            String target = config.baseUrl + apiPath;
            HttpURLConnection conn = null;
            try {
                conn = (HttpURLConnection) new URL(target).openConnection();
                conn.setRequestMethod("POST");
                conn.setConnectTimeout(CONNECT_TIMEOUT_MS);
                conn.setReadTimeout(READ_TIMEOUT_MS);
                conn.setDoOutput(true);
                conn.setInstanceFollowRedirects(true);
                conn.setRequestProperty("Content-Type", "application/json; charset=UTF-8");
                conn.setRequestProperty("Accept", "application/json");
                conn.setRequestProperty("User-Agent", Cms.USER_AGENT);
                if (authToken != null && !authToken.isEmpty()) {
                    conn.setRequestProperty("Authorization", authToken);
                }
                byte[] bytes = payload.toString().getBytes(StandardCharsets.UTF_8);
                conn.setFixedLengthStreamingMode(bytes.length);
                try (OutputStream os = conn.getOutputStream()) {
                    os.write(bytes);
                }
                int status = conn.getResponseCode();
                InputStream in = status >= 400 ? conn.getErrorStream() : conn.getInputStream();
                String text = readBoundedUtf8(in);
                if (text.isEmpty()) {
                    throw new IOException("AList 服务返回空响应（HTTP " + status + "）");
                }
                return new JSONObject(text);
            } catch (IOException e) {
                throw e;
            } catch (Exception e) {
                throw new IOException("AList 响应解析失败：" + e.getMessage(), e);
            } finally {
                if (conn != null) conn.disconnect();
            }
        }

        private JSONObject postApi(String apiPath, JSONObject payload) throws IOException {
            String tok = ensureToken(false);
            JSONObject resp = rawPost(apiPath, payload, tok);
            int code = resp.optInt("code", -1);
            if (code == 401 && !config.username.isEmpty() && config.token.isEmpty()) {
                activeToken = "";
                tok = ensureToken(true);
                resp = rawPost(apiPath, payload, tok);
                code = resp.optInt("code", -1);
            }
            if (code != 200) {
                String msg = Cms.optSafeString(resp, "message", "错误码 " + code);
                throw new IOException("AList 接口异常：" + msg);
            }
            return resp;
        }

        ListResult listDirectory(String path, int page, int perPage) throws IOException {
            String norm = normalizePath(path);
            try {
                JSONObject payload =
                        new JSONObject()
                                .put("path", norm)
                                .put("password", config.folderPassword)
                                .put("page", Math.max(1, page))
                                .put("per_page", Math.max(1, perPage))
                                .put("refresh", false);
                JSONObject resp = postApi("/api/fs/list", payload);
                JSONObject data = resp.optJSONObject("data");
                List<FsItem> items = new ArrayList<>();
                int total = 0;
                if (data != null) {
                    total = data.optInt("total", 0);
                    JSONArray content = data.optJSONArray("content");
                    if (content != null) {
                        for (int i = 0; i < content.length(); i++) {
                            JSONObject o = content.optJSONObject(i);
                            if (o == null) continue;
                            String name = Cms.optSafeString(o, "name");
                            if (name.isEmpty()) continue;
                            boolean isDir = o.optBoolean("is_dir", false);
                            long size = o.optLong("size", 0L);
                            String thumb = Cms.optSafeString(o, "thumb");
                            String sign = Cms.optSafeString(o, "sign");
                            String rawUrl = Cms.optSafeString(o, "raw_url");
                            items.add(
                                    new FsItem(
                                            name,
                                            joinPath(norm, name),
                                            isDir,
                                            size,
                                            thumb,
                                            sign,
                                            rawUrl));
                        }
                    }
                }
                if (page == 1 && !items.isEmpty()) {
                    dirCache.put(norm, items);
                }
                return new ListResult(items, total);
            } catch (IOException e) {
                throw e;
            } catch (Exception e) {
                throw new IOException("读取 AList 目录失败：" + e.getMessage(), e);
            }
        }

        FsItem getFile(String path) throws IOException {
            String norm = normalizePath(path);
            try {
                JSONObject payload =
                        new JSONObject().put("path", norm).put("password", config.folderPassword);
                JSONObject resp = postApi("/api/fs/get", payload);
                JSONObject data = resp.optJSONObject("data");
                if (data == null) throw new IOException("AList 未返回文件详情");
                String name = Cms.optSafeString(data, "name", fileName(norm));
                boolean isDir = data.optBoolean("is_dir", false);
                long size = data.optLong("size", 0L);
                String thumb = Cms.optSafeString(data, "thumb");
                String sign = Cms.optSafeString(data, "sign");
                String rawUrl = Cms.optSafeString(data, "raw_url");
                return new FsItem(name, norm, isDir, size, thumb, sign, rawUrl);
            } catch (IOException e) {
                throw e;
            } catch (Exception e) {
                throw new IOException("获取 AList 文件地址失败：" + e.getMessage(), e);
            }
        }

        ListResult searchFiles(String keywords, int page, int perPage) throws IOException {
            String q = keywords == null ? "" : keywords.trim();
            if (q.isEmpty()) return new ListResult(Collections.<FsItem>emptyList(), 0);
            try {
                JSONObject resp;
                try {
                    resp = postSearch(q, 2, page, perPage);
                } catch (IOException scopeError) {
                    resp = postSearch(q, 0, page, perPage);
                }
                JSONObject data = resp.optJSONObject("data");
                List<FsItem> items = new ArrayList<>();
                int total = 0;
                if (data != null) {
                    total = data.optInt("total", 0);
                    JSONArray content = data.optJSONArray("content");
                    if (content != null) {
                        for (int i = 0; i < content.length(); i++) {
                            JSONObject o = content.optJSONObject(i);
                            if (o == null) continue;
                            String name = Cms.optSafeString(o, "name");
                            String parent = Cms.optSafeString(o, "parent", config.rootPath);
                            boolean isDir = o.optBoolean("is_dir", false);
                            if (name.isEmpty()) continue;
                            if (!isDir && !isVideoFile(name)) continue;
                            items.add(
                                    new FsItem(
                                            name,
                                            joinPath(parent, name),
                                            isDir,
                                            o.optLong("size", 0L),
                                            Cms.optSafeString(o, "thumb"),
                                            Cms.optSafeString(o, "sign"),
                                            Cms.optSafeString(o, "raw_url")));
                        }
                    }
                }
                return new ListResult(items, total);
            } catch (IOException e) {
                throw e;
            } catch (Exception e) {
                throw new IOException("AList 搜索失败：" + e.getMessage(), e);
            }
        }

        private JSONObject postSearch(String keywords, int scope, int page, int perPage)
                throws Exception {
            JSONObject payload =
                    new JSONObject()
                            .put("parent", config.rootPath)
                            .put("keywords", keywords)
                            .put("scope", scope)
                            .put("page", Math.max(1, page))
                            .put("password", config.folderPassword)
                            .put("per_page", Math.max(1, perPage));
            return postApi("/api/fs/search", payload);
        }

        int testConnection() throws IOException {
            ListResult res = listDirectory(config.rootPath, 1, 20);
            return res.total;
        }

        List<FsItem> cachedSiblings(String dirPath) {
            return dirCache.get(normalizePath(dirPath));
        }

        String resolvePlayableUrl(FsItem item) {
            if (item == null) return "";
            if (!item.rawUrl.isEmpty() && Cms.isHttp(item.rawUrl)) {
                return item.rawUrl;
            }
            return buildDirectDownloadUrl(config.baseUrl, item.path, item.sign);
        }

        String findFolderCover(List<FsItem> items) {
            if (items == null) return "";
            for (FsItem item : items) {
                if (item != null && !item.isDir && isCoverImage(item.name)) {
                    return resolvePlayableUrl(item);
                }
            }
            return "";
        }

        private static String readBoundedUtf8(InputStream in) throws IOException {
            if (in == null) return "";
            try (InputStream stream = in) {
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] buf = new byte[8192];
                int total = 0;
                int n;
                while ((n = stream.read(buf)) != -1) {
                    total += n;
                    if (total > MAX_RESPONSE_BYTES) {
                        throw new IOException("AList 响应体超过上限");
                    }
                    out.write(buf, 0, n);
                }
                return new String(out.toByteArray(), StandardCharsets.UTF_8);
            }
        }
    }

    @Override
    public String home() throws Exception {
        ListResult res = client.listDirectory(client.config.rootPath, 1, 100);
        JSONArray classes = new JSONArray();
        classes.put(
                new JSONObject().put("type_id", client.config.rootPath).put("type_name", "根目录"));
        List<FsItem> dirs = new ArrayList<>();
        for (FsItem item : res.items) {
            if (item.isDir) dirs.add(item);
        }
        Collections.sort(dirs, (a, b) -> naturalCompare(a.name, b.name));
        for (FsItem dir : dirs) {
            classes.put(new JSONObject().put("type_id", dir.path).put("type_name", dir.name));
        }
        JSONObject out = new JSONObject();
        out.put("class", classes);
        out.put("list", toVodArray(res.items, client.findFolderCover(res.items)));
        return out.toString();
    }

    @Override
    public String homeVideos() throws Exception {
        return category(client.config.rootPath, 1);
    }

    @Override
    public String category(String id, int page) throws Exception {
        String targetPath =
                id == null || id.trim().isEmpty() ? client.config.rootPath : normalizePath(id);
        int perPage = 60;
        ListResult res = client.listDirectory(targetPath, Math.max(1, page), perPage);
        String cover = client.findFolderCover(res.items);
        int pageCount = Math.max(1, (res.total + perPage - 1) / perPage);
        return new JSONObject()
                .put("page", Math.max(1, page))
                .put("pagecount", pageCount)
                .put("limit", perPage)
                .put("total", res.total)
                .put("list", toVodArray(res.items, cover))
                .toString();
    }

    @Override
    public String search(String term, int page) throws Exception {
        int perPage = 30;
        ListResult res = client.searchFiles(term, Math.max(1, page), perPage);
        int pageCount = Math.max(1, (res.total + perPage - 1) / perPage);
        return new JSONObject()
                .put("page", Math.max(1, page))
                .put("pagecount", pageCount)
                .put("limit", perPage)
                .put("total", res.total)
                .put("list", toVodArray(res.items, ""))
                .toString();
    }

    @Override
    public String detail(String id) throws Exception {
        String filePath = normalizePath(id);
        String parent = parentPath(filePath);
        List<FsItem> siblings = null;
        try {
            siblings = client.listDirectory(parent, 1, 200).items;
        } catch (Exception ignored) {
        }
        List<FsItem> videos = new ArrayList<>();
        String cover = "";
        if (siblings != null) {
            cover = client.findFolderCover(siblings);
            for (FsItem item : siblings) {
                if (!item.isDir && isVideoFile(item.name)) {
                    videos.add(item);
                }
            }
            Collections.sort(videos, (a, b) -> naturalCompare(a.name, b.name));
        }

        FsItem target = null;
        for (FsItem v : videos) {
            if (filePath.equals(v.path)) {
                target = v;
                break;
            }
        }
        if (target == null) {
            target = client.getFile(filePath);
            if (!target.isDir) {
                videos.add(0, target);
            }
        }

        StringBuilder playUrl = new StringBuilder();
        for (int i = 0; i < videos.size(); i++) {
            FsItem ep = videos.get(i);
            if (i > 0) playUrl.append('#');
            String epLabel = stripExtension(ep.name).replace("$", " ").replace("#", " ").trim();
            if (epLabel.isEmpty()) epLabel = "第" + (i + 1) + "集";
            playUrl.append(epLabel).append('$').append(ep.path);
        }

        String vodName;
        String remarks;
        if (videos.size() > 1 && !"/".equals(parent)) {
            vodName = fileName(parent);
            remarks = "共 " + videos.size() + " 集 · AList";
        } else {
            vodName = stripExtension(target.name);
            String sz = formatFileSize(target.size);
            remarks = sz.isEmpty() ? "AList 直连" : sz + " · AList";
        }
        String pic = !target.thumb.isEmpty() ? target.thumb : cover;
        JSONObject vod =
                new JSONObject()
                        .put("vod_id", filePath)
                        .put("vod_name", vodName)
                        .put("vod_pic", pic)
                        .put("vod_remarks", remarks)
                        .put("vod_content", "AList 路径：" + filePath)
                        .put("vod_play_from", "AList 直连")
                        .put("vod_play_url", playUrl.toString());
        return new JSONObject().put("list", new JSONArray().put(vod)).toString();
    }

    @Override
    public String player(String flag, String id) throws Exception {
        String filePath = normalizePath(id);
        FsItem item = client.getFile(filePath);
        String directUrl = client.resolvePlayableUrl(item);
        if (directUrl.isEmpty()) {
            throw new IOException("AList 未返回可播放直链");
        }
        JSONObject headers = new JSONObject();
        headers.put("User-Agent", Cms.USER_AGENT);
        JSONObject out = new JSONObject();
        out.put("parse", 0);
        out.put("url", directUrl);
        out.put("header", headers);

        // Attach matching sibling external subtitles (.srt / .ass / .vtt) automatically
        String parent = parentPath(filePath);
        List<FsItem> siblings = client.cachedSiblings(parent);
        if (siblings == null) {
            try {
                siblings = client.listDirectory(parent, 1, 200).items;
            } catch (Exception ignored) {
            }
        }
        List<FsItem> subs = matchSiblingSubtitles(item.name, siblings);
        if (!subs.isEmpty()) {
            JSONArray subArr = new JSONArray();
            int limit = Math.min(4, subs.size());
            for (int i = 0; i < limit; i++) {
                FsItem sub = subs.get(i);
                String subUrl = client.resolvePlayableUrl(sub);
                if (subUrl.isEmpty()) continue;
                String langBucket = SubtitlePreferenceStore.detectLangBucket(sub.name);
                String lang = langBucket.startsWith("zh") ? "zh" : "und";
                subArr.put(
                        new JSONObject()
                                .put("name", "外挂 · " + sub.name)
                                .put("url", subUrl)
                                .put("language", lang));
            }
            if (subArr.length() > 0) {
                out.put("subtitles", subArr);
            }
        }
        return out.toString();
    }

    private JSONArray toVodArray(List<FsItem> items, String folderCover) throws Exception {
        List<FsItem> dirs = new ArrayList<>();
        List<FsItem> videos = new ArrayList<>();
        for (FsItem item : items) {
            if (item == null) continue;
            if (item.isDir) dirs.add(item);
            else if (isVideoFile(item.name)) videos.add(item);
        }
        Collections.sort(dirs, (a, b) -> naturalCompare(a.name, b.name));
        Collections.sort(videos, (a, b) -> naturalCompare(a.name, b.name));

        JSONArray arr = new JSONArray();
        for (FsItem dir : dirs) {
            arr.put(
                    new JSONObject()
                            .put("vod_id", dir.path)
                            .put("vod_name", dir.name)
                            .put("vod_pic", dir.thumb)
                            .put("vod_remarks", "文件夹")
                            .put("vod_tag", "folder"));
        }
        for (FsItem vid : videos) {
            String sz = formatFileSize(vid.size);
            arr.put(
                    new JSONObject()
                            .put("vod_id", vid.path)
                            .put("vod_name", stripExtension(vid.name))
                            .put("vod_pic", !vid.thumb.isEmpty() ? vid.thumb : folderCover)
                            .put("vod_remarks", sz.isEmpty() ? "视频" : sz));
        }
        return arr;
    }

    @Override
    public boolean requiresExternalRuntime() {
        return false;
    }
}
