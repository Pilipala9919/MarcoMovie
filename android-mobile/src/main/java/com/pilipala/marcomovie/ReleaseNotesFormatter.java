// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Automatically condenses, deduplicates, and categorizes raw Markdown release notes into concise,
 * user-friendly Chinese sections without build-record or checksum clutter.
 */
public final class ReleaseNotesFormatter {
    public static final class Section {
        public final String title;
        public final List<String> items;

        Section(String title, List<String> items) {
            this.title = title;
            this.items = items;
        }
    }

    public static final class Summary {
        public final String overview;
        public final List<Section> sections;
        public final int totalItems;

        Summary(String overview, List<Section> sections, int totalItems) {
            this.overview = overview;
            this.sections = sections;
            this.totalItems = totalItems;
        }
    }

    private static final String CAT_PLAYBACK = "片源与播放";
    private static final String CAT_UI = "界面与交互";
    private static final String CAT_FEATURE = "功能与同步";
    private static final String CAT_FIX = "问题修复与优化";
    private static final String CAT_NOTE = "注意事项";

    private static final Pattern HEADING_RE = Pattern.compile("^#{1,6}\\s+(.+)$");
    private static final Pattern NUMBERED_BOLD_RE =
            Pattern.compile("^\\d+[.)、]\\s*\\*\\*(.+?)\\*\\*\\s*$");
    private static final Pattern BULLET_RE = Pattern.compile("^(?:[-*•]|\\d+[.)、])\\s+(.+)$");
    private static final Pattern MD_LINK_RE = Pattern.compile("\\[([^\\]\\n]+)\\]\\(([^)\\s]+)\\)");
    private static final Pattern TECH_PAREN_RE =
            Pattern.compile(
                    "[（(][^）)]*(?:`[^`]+`|[A-Za-z_][A-Za-z0-9_./:-]{3,}|SHA-256|MKCOL)[^）)]*[）)]");
    private static final Pattern META_SENTENCE_RE =
            Pattern.compile("^(?:发布日期|应用版本|版本代码|构建号|最低系统要求)[：:][^。\\n]*[。.]?\\s*");

    private ReleaseNotesFormatter() {}

    public static Summary summarize(String rawNotes) {
        if (rawNotes == null || rawNotes.trim().isEmpty()) {
            return new Summary("", new ArrayList<Section>(), 0);
        }
        String[] lines = rawNotes.replace("\r\n", "\n").replace('\r', '\n').split("\n");
        String overview = "";
        boolean skipSection = false;
        boolean inVerificationSection = false;
        String pendingTopic = "";

        Map<String, List<String>> buckets = new LinkedHashMap<String, List<String>>();
        buckets.put(CAT_PLAYBACK, new ArrayList<String>());
        buckets.put(CAT_UI, new ArrayList<String>());
        buckets.put(CAT_FEATURE, new ArrayList<String>());
        buckets.put(CAT_FIX, new ArrayList<String>());
        buckets.put(CAT_NOTE, new ArrayList<String>());
        Set<String> seenKeys = new LinkedHashSet<String>();

        for (String rawLine : lines) {
            String trimmed = rawLine == null ? "" : rawLine.trim();
            if (trimmed.isEmpty()) continue;

            Matcher hm = HEADING_RE.matcher(trimmed);
            if (hm.matches()) {
                String h = cleanInline(hm.group(1));
                pendingTopic = "";
                if (isTopVersionHeading(h)) {
                    skipSection = false;
                    inVerificationSection = false;
                    continue;
                }
                if (isBuildArtifactHeading(h)) {
                    skipSection = true;
                    inVerificationSection = false;
                    continue;
                }
                if (isVerificationHeading(h)) {
                    skipSection = true;
                    inVerificationSection = true;
                    continue;
                }
                skipSection = false;
                inVerificationSection = false;
                continue;
            }

            Matcher nbm = NUMBERED_BOLD_RE.matcher(trimmed);
            if (nbm.matches()) {
                if (!skipSection) {
                    pendingTopic = cleanInline(nbm.group(1));
                }
                continue;
            }

            Matcher bm = BULLET_RE.matcher(trimmed);
            String content = bm.matches() ? bm.group(1).trim() : trimmed;

            if (isKnownLimitationLine(content)) {
                String item = condenseItem(cleanInline(content), 88);
                addUnique(buckets, seenKeys, CAT_NOTE, item);
                continue;
            }

            if (skipSection) {
                if (inVerificationSection && content.contains("已知限制")) {
                    addUnique(buckets, seenKeys, CAT_NOTE, condenseItem(cleanInline(content), 88));
                }
                continue;
            }

            if (isNoiseMetadataLine(content)) {
                String extracted = extractOverviewFromMetaLine(content);
                if (!extracted.isEmpty() && overview.isEmpty()) {
                    overview = extracted;
                }
                continue;
            }

            if (!bm.matches()
                    && overview.isEmpty()
                    && bucketsTotal(buckets) == 0
                    && content.startsWith("本次更新")) {
                overview = condenseItem(cleanInline(content), 86);
                continue;
            }

            String cleaned = cleanInline(content);
            if (cleaned.isEmpty() || isNoiseMetadataLine(cleaned)) continue;

            if (!pendingTopic.isEmpty() && !cleaned.startsWith(pendingTopic)) {
                if (!cleaned.contains("：") && !cleaned.contains(":")) {
                    cleaned = pendingTopic + "：" + cleaned;
                }
                pendingTopic = "";
            }

            String condensed = condenseItem(cleaned, 84);
            if (condensed.isEmpty()) continue;
            String category = classify(condensed);
            addUnique(buckets, seenKeys, category, condensed);
        }

        List<Section> sections = new ArrayList<Section>();
        int total = 0;
        for (Map.Entry<String, List<String>> entry : buckets.entrySet()) {
            if (!entry.getValue().isEmpty()) {
                sections.add(new Section(entry.getKey(), entry.getValue()));
                total += entry.getValue().size();
            }
        }
        return new Summary(overview, sections, total);
    }

    public static String formatPlainText(String rawNotes) {
        Summary summary = summarize(rawNotes);
        if (summary.sections.isEmpty()) {
            return summary.overview.isEmpty() ? rawNotes.trim() : summary.overview;
        }
        if (summary.totalItems == 1 && summary.overview.isEmpty()) {
            return "• " + summary.sections.get(0).items.get(0);
        }
        StringBuilder sb = new StringBuilder();
        if (!summary.overview.isEmpty()) {
            sb.append(summary.overview).append("\n\n");
        } else if (summary.totalItems >= 2) {
            sb.append("本次升级共归纳 ").append(summary.totalItems).append(" 项重点改进：\n\n");
        }
        for (int i = 0; i < summary.sections.size(); i++) {
            Section sec = summary.sections.get(i);
            if (summary.sections.size() > 1 || summary.totalItems >= 3) {
                sb.append("【").append(sec.title).append("】\n");
            }
            for (String item : sec.items) {
                sb.append("• ").append(item).append("\n");
            }
            if (i + 1 < summary.sections.size()) {
                sb.append("\n");
            }
        }
        return sb.toString().trim();
    }

    private static int bucketsTotal(Map<String, List<String>> buckets) {
        int sum = 0;
        for (List<String> list : buckets.values()) sum += list.size();
        return sum;
    }

    private static void addUnique(
            Map<String, List<String>> buckets, Set<String> seen, String cat, String item) {
        String norm =
                item.toLowerCase(Locale.ROOT).replaceAll("[\\s·•:：,，.。!！?？;；()（）\\[\\]【】「」]", "");
        if (norm.isEmpty() || !seen.add(norm)) return;
        buckets.get(cat).add(item);
    }

    private static boolean isTopVersionHeading(String h) {
        String lower = h.toLowerCase(Locale.ROOT);
        return lower.startsWith("marco movie")
                || lower.matches("^v?\\d+\\.\\d+\\.\\d+.*")
                || h.equals("更新内容")
                || h.equals("核心修复与优化")
                || lower.equals("changes");
    }

    private static boolean isBuildArtifactHeading(String h) {
        String lower = h.toLowerCase(Locale.ROOT);
        return h.contains("包信息")
                || h.contains("构建记录")
                || h.contains("文件校验")
                || h.contains("安装包校验")
                || lower.contains("checksum")
                || lower.contains("artifact");
    }

    private static boolean isVerificationHeading(String h) {
        return h.contains("验证范围") || h.contains("测试记录") || h.contains("自动化验证");
    }

    private static boolean isKnownLimitationLine(String line) {
        return line.startsWith("已知限制：") || line.startsWith("已知限制:") || line.startsWith("注意事项：");
    }

    private static boolean isNoiseMetadataLine(String line) {
        String lower = line.toLowerCase(Locale.ROOT);
        if (line.startsWith("发布日期：") || line.startsWith("发布日期:")) return true;
        if (lower.startsWith("platform:") || lower.startsWith("- platform:")) return true;
        if (lower.startsWith("commit:") || lower.startsWith("- commit:")) return true;
        if (lower.contains("sha-256") || lower.contains("sha256:")) return true;
        if (line.contains("构建提交") || line.contains("对应源码包")) return true;
        if (line.startsWith("通过公共内容守卫检查")) return true;
        if (line.startsWith("自动化与") && line.contains("实机验收")) return true;
        if (line.startsWith("未签名 IPA 支持巨魔") && line.contains("长期可用性承诺")) return true;
        return false;
    }

    private static String extractOverviewFromMetaLine(String line) {
        String rest = line;
        while (true) {
            Matcher m = META_SENTENCE_RE.matcher(rest);
            if (m.find()) {
                rest = rest.substring(m.end()).trim();
            } else {
                break;
            }
        }
        if (rest.isEmpty()) return "";
        return condenseItem(cleanInline(rest), 86);
    }

    private static String cleanInline(String raw) {
        if (raw == null) return "";
        String s = TECH_PAREN_RE.matcher(raw).replaceAll("");
        s = MD_LINK_RE.matcher(s).replaceAll("$1");
        s = s.replace("**", "").replace("__", "").replace("`", "");
        s = s.replaceAll("\\s+", " ").trim();
        return s;
    }

    private static String condenseItem(String cleaned, int maxLen) {
        String s = cleaned.trim();
        if (s.isEmpty()) return "";
        if (s.length() <= maxLen) {
            return stripTrailingPunctuation(s);
        }
        int semi = s.indexOf('；');
        if (semi >= 14 && semi <= maxLen + 8) {
            s = s.substring(0, semi);
        }
        int period = s.indexOf('。');
        if (period >= 14 && period <= maxLen + 8) {
            s = s.substring(0, period);
        }
        if (s.length() > maxLen) {
            int comma = s.lastIndexOf('，', maxLen);
            if (comma >= maxLen / 2) {
                s = s.substring(0, comma);
            } else {
                s = s.substring(0, maxLen - 1) + "…";
            }
        }
        return stripTrailingPunctuation(s);
    }

    private static String stripTrailingPunctuation(String s) {
        int end = s.length();
        while (end > 0) {
            char c = s.charAt(end - 1);
            if (c == '。' || c == '；' || c == ';' || c == '，' || c == ',') {
                end--;
            } else {
                break;
            }
        }
        return s.substring(0, end).trim();
    }

    private static String classify(String item) {
        if (isKnownLimitationLine(item)) return CAT_NOTE;
        if (item.startsWith("修复")
                || containsAny(item, "报错", "异常", "崩溃", "闪退", "观看历史", "观影记录", "桌面快捷方式", "桌面图标")) {
            return CAT_FIX;
        }
        if (containsAny(
                item, "片源", "线路", "网盘", "玩偶", "夸克", "百度", "阿里", "UC", "播放", "片头", "片尾", "常显时间",
                "解码", "直播", "弹幕", "字幕", "插件", "嗅探")) {
            return CAT_PLAYBACK;
        }
        if (containsAny(
                item, "界面", "海报", "首页", "筛选", "分类", "窗口", "标题栏", "沉浸式", "中文", "安装程序", "安装向导", "闪烁",
                "加载更多", "导航", "遥控", "设置页")) {
            return CAT_UI;
        }
        if (containsAny(item, "同步", "WebDAV", "局域网", "收藏", "新增", "支持", "引入", "升级")) {
            return CAT_FEATURE;
        }
        return CAT_FIX;
    }

    private static boolean containsAny(String text, String... keywords) {
        for (String kw : keywords) {
            if (text.contains(kw)) return true;
        }
        return false;
    }
}
