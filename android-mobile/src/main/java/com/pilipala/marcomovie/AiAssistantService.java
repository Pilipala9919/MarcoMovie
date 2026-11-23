package com.pilipala.marcomovie;

import android.content.SharedPreferences;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * User-configured OpenAI-compatible LLM client (DeepSeek, Qwen, SiliconFlow, Kimi, Zhipu GLM,
 * Ollama, or custom endpoint) for episode title purification, search title cleaning, Python spider
 * static security auditing, and bilingual subtitle translation. Zero built-in keys; falls back to
 * {@link EpisodeNameCleaner} when unconfigured.
 */
final class AiAssistantService {
    interface ResultCallback<T> {
        void onResult(T value);
    }

    static final String[] PROVIDER_IDS = {
        "deepseek", "qwen", "siliconflow", "kimi", "glm", "ollama", "custom"
    };
    static final String[] PROVIDER_LABELS = {
        "DeepSeek 官方",
        "阿里云百炼 (通义千问)",
        "SiliconFlow 硅基流动",
        "Moonshot (Kimi)",
        "智谱清言 (GLM)",
        "Ollama 局域网本地",
        "自定义 OpenAI 兼容接口"
    };

    private static final Pattern PY_SUSPICIOUS =
            Pattern.compile(
                    "(?i)\\b(os\\.system|subprocess\\.(?:Popen|call|run|check_output)|pty\\.spawn|shutil\\.rmtree|socket\\.socket)\\b");

    private AiAssistantService() {}

    static String defaultBaseUrl(String provider) {
        if ("qwen".equals(provider)) return "https://dashscope.aliyuncs.com/compatible-mode/v1";
        if ("siliconflow".equals(provider)) return "https://api.siliconflow.cn/v1";
        if ("kimi".equals(provider)) return "https://api.moonshot.cn/v1";
        if ("glm".equals(provider)) return "https://open.bigmodel.cn/api/paas/v4";
        if ("ollama".equals(provider)) return "http://127.0.0.1:11434/v1";
        if ("custom".equals(provider)) return "";
        return "https://api.deepseek.com/v1";
    }

    static String defaultModel(String provider) {
        if ("qwen".equals(provider)) return "qwen-plus";
        if ("siliconflow".equals(provider)) return "Qwen/Qwen2.5-7B-Instruct";
        if ("kimi".equals(provider)) return "moonshot-v1-8k";
        if ("glm".equals(provider)) return "glm-4-flash";
        if ("ollama".equals(provider)) return "qwen2.5:7b";
        return "deepseek-chat";
    }

    static String providerLabel(String provider) {
        for (int i = 0; i < PROVIDER_IDS.length; i++) {
            if (PROVIDER_IDS[i].equals(provider)) return PROVIDER_LABELS[i];
        }
        return PROVIDER_LABELS[0];
    }

    static boolean isConfigured(MainActivity a) {
        if (a == null || a.isTvDevice()) return false;
        SharedPreferences mp = a.mobilePrefs();
        if (!mp.getBoolean(Prefs.AI_ENABLED, false)) return false;
        String provider = mp.getString(Prefs.AI_PROVIDER, "deepseek");
        String base = resolveBaseUrl(a);
        if (base.isEmpty()) return false;
        if ("ollama".equals(provider)) return true;
        String key = a.secretsPrefs().getString(Prefs.SECRET_AI_API_KEY, "").trim();
        return !key.isEmpty();
    }

    static String resolveBaseUrl(MainActivity a) {
        SharedPreferences mp = a.mobilePrefs();
        String provider = mp.getString(Prefs.AI_PROVIDER, "deepseek");
        String custom = mp.getString(Prefs.AI_BASE_URL, "").trim();
        String url = custom.isEmpty() ? defaultBaseUrl(provider) : custom;
        while (url.endsWith("/")) url = url.substring(0, url.length() - 1);
        return url;
    }

    static String resolveModel(MainActivity a) {
        SharedPreferences mp = a.mobilePrefs();
        String provider = mp.getString(Prefs.AI_PROVIDER, "deepseek");
        String m = mp.getString(Prefs.AI_MODEL, "").trim();
        return m.isEmpty() ? defaultModel(provider) : m;
    }

    /** Fast local heuristic security scan before running user-imported Python spiders. */
    static String staticSafetyScanPython(String pySource) {
        if (pySource == null || pySource.isEmpty()) return null;
        java.util.regex.Matcher m = PY_SUSPICIOUS.matcher(pySource);
        if (m.find()) {
            return "检测到高危系统调用 (" + m.group(1) + ")，请确认脚本来源可信";
        }
        return null;
    }

    static void cleanEpisodesAsync(
            final MainActivity a,
            final String seriesTitle,
            final List<Cms.Episode> episodes,
            final ResultCallback<Map<String, String>> callback) {
        if (!isConfigured(a) || episodes == null || episodes.isEmpty() || callback == null) {
            return;
        }
        final int count = Math.min(episodes.size(), 60);
        final List<String> rawNames = new ArrayList<>(count);
        StringBuilder sig = new StringBuilder(seriesTitle == null ? "" : seriesTitle);
        for (int i = 0; i < count; i++) {
            String n = episodes.get(i).name == null ? "" : episodes.get(i).name;
            rawNames.add(n);
            sig.append('|').append(n);
        }
        final String cacheKey = "ep_" + sha256(sig.toString());
        final int ticket = a.generation;
        a.worker.execute(
                () -> {
                    try {
                        String cached = readDiskCache(a, cacheKey);
                        JSONObject parsed;
                        if (cached != null && !cached.isEmpty()) {
                            parsed = new JSONObject(cached);
                        } else {
                            JSONArray arr = new JSONArray();
                            for (String n : rawNames) arr.put(n);
                            String sys =
                                    "你是影视剧集标题净化助手。将输入数组中的杂乱文件名整理为简短规范的中文集名（如“第 1 集”或“第 1 集 副标题”或“1080P 正片”），去除广告、网盘引流词与编码后缀。严格只输出 JSON 对象：{\"items\":[\"净化名1\",...]}，数组长度必须与输入完全一致。";
                            String usr =
                                    "片名："
                                            + (seriesTitle == null ? "" : seriesTitle)
                                            + "\n原始集名数组："
                                            + arr.toString();
                            String reply = chatCompletion(a, sys, usr, 1200);
                            parsed = extractJsonObject(reply);
                            if (parsed != null) writeDiskCache(a, cacheKey, parsed.toString());
                        }
                        if (parsed == null) return;
                        JSONArray outArr = parsed.optJSONArray("items");
                        if (outArr == null || outArr.length() != rawNames.size()) return;
                        final Map<String, String> map = new HashMap<>();
                        for (int i = 0; i < rawNames.size(); i++) {
                            String clean = outArr.optString(i, "").trim();
                            if (!clean.isEmpty()) map.put(rawNames.get(i), clean);
                        }
                        a.ui.post(
                                () -> {
                                    if (!a.isFinishing() && ticket == a.generation) {
                                        callback.onResult(map);
                                    }
                                });
                    } catch (Exception e) {
                        AppLog.w("AiAssistant", "cleanEpisodesAsync failed", e);
                    }
                });
    }

    static void translateSubtitleLinesAsync(
            final MainActivity a,
            final List<String> sourceLines,
            final ResultCallback<List<String>> callback) {
        if (!isConfigured(a) || sourceLines == null || sourceLines.isEmpty() || callback == null) {
            return;
        }
        final List<String> batch =
                new ArrayList<>(sourceLines.subList(0, Math.min(40, sourceLines.size())));
        final String cacheKey = "sub_" + sha256(batch.toString());
        a.worker.execute(
                () -> {
                    try {
                        String cached = readDiskCache(a, cacheKey);
                        JSONObject parsed;
                        if (cached != null) {
                            parsed = new JSONObject(cached);
                        } else {
                            JSONArray arr = new JSONArray(batch);
                            String sys =
                                    "你是影视字幕翻译专家。将输入外语台词数组逐条自然翻译为简体中文。严格只返回 JSON 对象：{\"zh\":[\"译文1\",...]}，条数与输入完全一致。";
                            String reply = chatCompletion(a, sys, arr.toString(), 1800);
                            parsed = extractJsonObject(reply);
                            if (parsed != null) writeDiskCache(a, cacheKey, parsed.toString());
                        }
                        if (parsed == null) return;
                        JSONArray zh = parsed.optJSONArray("zh");
                        if (zh == null || zh.length() != batch.size()) return;
                        final List<String> result = new ArrayList<>(zh.length());
                        for (int i = 0; i < zh.length(); i++) {
                            result.add(zh.optString(i, ""));
                        }
                        a.ui.post(
                                () -> {
                                    if (!a.isFinishing()) callback.onResult(result);
                                });
                    } catch (Exception e) {
                        AppLog.w("AiAssistant", "translateSubtitleLinesAsync failed", e);
                    }
                });
    }

    static void testConnectionAsync(MainActivity a, final ResultCallback<String> callback) {
        a.worker.execute(
                () -> {
                    try {
                        String reply =
                                chatCompletion(
                                        a, "Reply concisely in Chinese.", "请回复“连接正常”四个字。", 64);
                        final String msg = "连接成功：" + (reply == null ? "" : reply.trim());
                        a.ui.post(() -> callback.onResult(msg));
                    } catch (Exception e) {
                        final String err = "连接失败：" + a.message(e);
                        a.ui.post(() -> callback.onResult(err));
                    }
                });
    }

    private static String chatCompletion(
            MainActivity a, String systemPrompt, String userPrompt, int maxTokens)
            throws Exception {
        String base = resolveBaseUrl(a);
        if (base.isEmpty()) throw new IllegalStateException("未配置 AI 接口地址");
        String endpoint = base.endsWith("/chat/completions") ? base : (base + "/chat/completions");
        String apiKey = a.secretsPrefs().getString(Prefs.SECRET_AI_API_KEY, "").trim();
        String model = resolveModel(a);

        JSONObject body = new JSONObject();
        body.put("model", model);
        body.put("temperature", 0.2);
        body.put("max_tokens", maxTokens);
        JSONArray messages = new JSONArray();
        messages.put(new JSONObject().put("role", "system").put("content", systemPrompt));
        messages.put(new JSONObject().put("role", "user").put("content", userPrompt));
        body.put("messages", messages);

        HttpURLConnection conn = (HttpURLConnection) new URL(endpoint).openConnection();
        conn.setRequestMethod("POST");
        conn.setDoOutput(true);
        conn.setConnectTimeout(12000);
        conn.setReadTimeout(25000);
        conn.setRequestProperty("Content-Type", "application/json; charset=UTF-8");
        if (!apiKey.isEmpty()) {
            conn.setRequestProperty("Authorization", "Bearer " + apiKey);
        }
        byte[] payload = body.toString().getBytes("UTF-8");
        try (OutputStream out = conn.getOutputStream()) {
            out.write(payload);
        }
        int code = conn.getResponseCode();
        InputStream stream =
                code >= 200 && code < 300 ? conn.getInputStream() : conn.getErrorStream();
        String respText = "";
        if (stream != null) {
            try (InputStream in = stream;
                    ByteArrayOutputStream bos = new ByteArrayOutputStream()) {
                byte[] buf = new byte[4096];
                int n;
                while ((n = in.read(buf)) != -1) {
                    if (bos.size() + n > 512 * 1024) break;
                    bos.write(buf, 0, n);
                }
                respText = new String(bos.toByteArray(), "UTF-8");
            }
        }
        conn.disconnect();
        if (code < 200 || code >= 300) {
            throw new java.io.IOException("HTTP " + code);
        }
        JSONObject root = new JSONObject(respText);
        JSONArray choices = root.optJSONArray("choices");
        if (choices == null || choices.length() == 0) return "";
        JSONObject msg = choices.getJSONObject(0).optJSONObject("message");
        return msg == null ? "" : msg.optString("content", "");
    }

    private static JSONObject extractJsonObject(String raw) {
        if (raw == null) return null;
        int start = raw.indexOf('{');
        int end = raw.lastIndexOf('}');
        if (start >= 0 && end > start) {
            try {
                return new JSONObject(raw.substring(start, end + 1));
            } catch (Exception ignored) {
            }
        }
        return null;
    }

    private static File cacheDir(MainActivity a) {
        File d = new File(a.getCacheDir(), "ai_cache_v1");
        if (!d.exists()) d.mkdirs();
        return d;
    }

    private static String readDiskCache(MainActivity a, String key) {
        File f = new File(cacheDir(a), key + ".json");
        if (!f.exists() || System.currentTimeMillis() - f.lastModified() > 14L * 86400_000L) {
            return null;
        }
        try (InputStream in = new FileInputStream(f)) {
            return Cms.read(in, 256 * 1024);
        } catch (Exception ignored) {
            return null;
        }
    }

    private static void writeDiskCache(MainActivity a, String key, String json) {
        File f = new File(cacheDir(a), key + ".json");
        try (OutputStream out = new FileOutputStream(f)) {
            out.write(json.getBytes("UTF-8"));
        } catch (Exception ignored) {
        }
    }

    static long cacheBytes(MainActivity a) {
        File d = new File(a.getCacheDir(), "ai_cache_v1");
        File[] files = d.listFiles();
        long sum = 0;
        if (files != null) for (File f : files) sum += f.length();
        return sum;
    }

    static void clearCache(MainActivity a) {
        File d = new File(a.getCacheDir(), "ai_cache_v1");
        File[] files = d.listFiles();
        if (files != null) for (File f : files) f.delete();
    }

    private static String sha256(String s) {
        try {
            byte[] d = MessageDigest.getInstance("SHA-256").digest(s.getBytes("UTF-8"));
            StringBuilder sb = new StringBuilder(32);
            for (int i = 0; i < 16; i++) {
                sb.append(String.format(Locale.US, "%02x", d[i] & 0xff));
            }
            return sb.toString();
        } catch (Exception e) {
            return Integer.toHexString(s.hashCode());
        }
    }
}
