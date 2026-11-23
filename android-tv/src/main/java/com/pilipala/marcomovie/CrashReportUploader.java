package com.pilipala.marcomovie;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Automatic GitHub Issue crash-report submitter via the official Marco Movie HTTPS relay endpoint.
 *
 * <p>No GitHub token is ever bundled inside the APK. When the relay endpoint succeeds, it creates
 * or comments on a GitHub Issue in {@link CrashReportStore#GITHUB_REPO} and returns the issue
 * number/URL; on any network or relay failure, callers fall back seamlessly to the QR export flow.
 */
final class CrashReportUploader {
    static final int CONNECT_TIMEOUT_MS = 8000;
    static final int READ_TIMEOUT_MS = 12000;
    static final int MAX_RESPONSE_BYTES = 16 * 1024;

    static final class UploadResult {
        final boolean ok;
        final int issueNumber;
        final String issueUrl;
        final String errorMessage;

        private UploadResult(boolean ok, int issueNumber, String issueUrl, String errorMessage) {
            this.ok = ok;
            this.issueNumber = issueNumber;
            this.issueUrl = issueUrl == null ? "" : issueUrl;
            this.errorMessage = errorMessage == null ? "" : errorMessage;
        }

        static UploadResult success(int issueNumber, String issueUrl) {
            return new UploadResult(true, issueNumber, issueUrl, "");
        }

        static UploadResult failure(String errorMessage) {
            return new UploadResult(false, 0, "", errorMessage);
        }
    }

    interface Transport {
        Response postJson(String endpointUrl, byte[] jsonBody) throws IOException;
    }

    static final class Response {
        final int statusCode;
        final String body;

        Response(int statusCode, String body) {
            this.statusCode = statusCode;
            this.body = body == null ? "" : body;
        }
    }

    private CrashReportUploader() {}

    static UploadResult submit(List<CrashReportStore.CrashReport> reports) {
        return submit(CrashReportStore.RELAY_ENDPOINT, reports, CrashReportUploader::httpPostJson);
    }

    static UploadResult submit(
            String endpointUrl, List<CrashReportStore.CrashReport> reports, Transport transport) {
        if (reports == null || reports.isEmpty()) {
            return UploadResult.failure("未选择需要提交的崩溃日志");
        }
        if (endpointUrl == null || !endpointUrl.startsWith("https://")) {
            return UploadResult.failure("上报地址无效");
        }
        try {
            byte[] payload =
                    buildRequestPayload(reports).toString().getBytes(StandardCharsets.UTF_8);
            Response resp = transport.postJson(endpointUrl, payload);
            if (resp == null) {
                return UploadResult.failure("未收到服务端响应");
            }
            if (resp.statusCode < 200 || resp.statusCode >= 300) {
                return UploadResult.failure(friendlyHttpError(resp.statusCode));
            }
            return parseSuccessResponse(resp.body);
        } catch (java.net.SocketTimeoutException e) {
            return UploadResult.failure("连接超时");
        } catch (IOException e) {
            return UploadResult.failure("网络连接失败");
        } catch (Exception e) {
            return UploadResult.failure("上报异常：" + e.getClass().getSimpleName());
        }
    }

    static JSONObject buildRequestPayload(List<CrashReportStore.CrashReport> reports)
            throws Exception {
        CrashReportStore.CrashReport primary = reports.get(0);
        JSONObject payload = new JSONObject();
        payload.put("repo", CrashReportStore.GITHUB_REPO);
        payload.put("fingerprint", primary.fingerprint);
        payload.put("title", CrashReportStore.formatIssueTitle(reports));
        payload.put("body", CrashReportStore.formatIssueMarkdown(reports));
        JSONArray labels = new JSONArray();
        for (String label : CrashReportStore.buildIssueLabels(primary)) {
            labels.put(label);
        }
        payload.put("labels", labels);
        payload.put("app_version", primary.appVersion);
        payload.put("version_code", primary.appVersionCode);
        payload.put("edition", primary.edition);
        payload.put("sdk_int", primary.sdkInt);
        payload.put("device", (primary.manufacturer + " " + primary.deviceModel).trim());
        payload.put("report_count", reports.size());
        return payload;
    }

    static UploadResult parseSuccessResponse(String body) {
        if (body == null || body.trim().isEmpty()) {
            return UploadResult.failure("服务端返回内容为空");
        }
        try {
            JSONObject obj = new JSONObject(body);
            if (!obj.optBoolean("ok", false)) {
                String msg = obj.optString("error", obj.optString("message", "服务端拒绝接收"));
                return UploadResult.failure(msg);
            }
            int issueNumber = obj.optInt("issue_number", obj.optInt("number", 0));
            String issueUrl = obj.optString("issue_url", obj.optString("html_url", ""));
            if (!issueUrl.isEmpty()
                    && !issueUrl.startsWith(
                            "https://github.com/" + CrashReportStore.GITHUB_REPO + "/issues/")) {
                issueUrl = "";
            }
            if (issueNumber <= 0 && issueUrl.isEmpty()) {
                return UploadResult.failure("服务端未返回有效 Issue 编号");
            }
            return UploadResult.success(issueNumber, issueUrl);
        } catch (Exception e) {
            return UploadResult.failure("服务端返回格式无法识别");
        }
    }

    static String friendlyHttpError(int statusCode) {
        if (statusCode == 404 || statusCode == 405) return "自动上报网关未启用（HTTP " + statusCode + "）";
        if (statusCode == 429) return "提交过于频繁，请稍后再试（HTTP 429）";
        if (statusCode >= 500) return "上报服务暂不可用（HTTP " + statusCode + "）";
        return "上报被拒绝（HTTP " + statusCode + "）";
    }

    private static Response httpPostJson(String endpointUrl, byte[] jsonBody) throws IOException {
        HttpURLConnection conn = null;
        try {
            conn = (HttpURLConnection) new URL(endpointUrl).openConnection();
            conn.setRequestMethod("POST");
            conn.setConnectTimeout(CONNECT_TIMEOUT_MS);
            conn.setReadTimeout(READ_TIMEOUT_MS);
            conn.setDoOutput(true);
            conn.setInstanceFollowRedirects(false);
            conn.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            conn.setRequestProperty("Accept", "application/json");
            conn.setRequestProperty("User-Agent", "MarcoMovie-CrashReporter/1.0");
            conn.setFixedLengthStreamingMode(jsonBody.length);
            try (OutputStream out = conn.getOutputStream()) {
                out.write(jsonBody);
                out.flush();
            }
            int code = conn.getResponseCode();
            InputStream in = code >= 400 ? conn.getErrorStream() : conn.getInputStream();
            String text = "";
            if (in != null) {
                try (InputStream stream = in;
                        ByteArrayOutputStream buf = new ByteArrayOutputStream()) {
                    byte[] chunk = new byte[2048];
                    int n;
                    int total = 0;
                    while ((n = stream.read(chunk)) != -1) {
                        total += n;
                        if (total > MAX_RESPONSE_BYTES) break;
                        buf.write(chunk, 0, n);
                    }
                    text = new String(buf.toByteArray(), StandardCharsets.UTF_8);
                }
            }
            return new Response(code, text);
        } finally {
            if (conn != null) conn.disconnect();
        }
    }
}
