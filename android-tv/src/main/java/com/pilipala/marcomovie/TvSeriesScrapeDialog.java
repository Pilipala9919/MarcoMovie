// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.content.DialogInterface;
import android.text.InputType;
import android.widget.EditText;
import java.io.IOException;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Interactive TV in-series scraping & episode-correction hub. Works uniformly for ALL resources
 * (subscription CMS/plugins, cloud drives, AList, Emby, and local USB drives) and can be launched
 * from either the TV Detail Screen or the Player menu.
 */
final class TvSeriesScrapeDialog {

    private static final OkHttpClient HTTP =
            new OkHttpClient.Builder()
                    .connectTimeout(6, TimeUnit.SECONDS)
                    .readTimeout(8, TimeUnit.SECONDS)
                    .followRedirects(true)
                    .build();

    private static final int[] OFFSET_PRESETS = {-24, -12, -3, -2, -1, 0, 1, 2, 3, 12, 24, 36, 50};

    static final class MediaCandidate {
        final String source; // "douban" or "bangumi"
        final String subjectId;
        final String kind; // "tv" or "movie"
        final String title;
        final String year;
        final double score;
        final int totalEpisodes;
        final String posterUrl;
        final String synopsis;

        MediaCandidate(
                String source,
                String subjectId,
                String kind,
                String title,
                String year,
                double score,
                int totalEpisodes,
                String posterUrl,
                String synopsis) {
            this.source = source;
            this.subjectId = subjectId;
            this.kind = kind;
            this.title = title;
            this.year = year;
            this.score = score;
            this.totalEpisodes = totalEpisodes;
            this.posterUrl = posterUrl;
            this.synopsis = synopsis;
        }

        String displayLabel() {
            String src = "bangumi".equals(source) ? "Bangumi" : "豆瓣";
            StringBuilder sb = new StringBuilder();
            sb.append("[").append(src).append("] ").append(title);
            if (!year.isEmpty()) sb.append(" (").append(year).append(")");
            if (score > 0.1) sb.append(String.format(Locale.US, " · %.1f分", score));
            if (totalEpisodes > 0) sb.append(" · ").append(totalEpisodes).append("集");
            return sb.toString();
        }
    }

    private TvSeriesScrapeDialog() {}

    static void show(
            final MainActivity a,
            final Cms.Site site,
            final Cms.Video video,
            final Cms.Line activeLine,
            final Runnable onUpdated) {
        if (a == null || video == null) return;
        final String siteKey = site != null && site.key != null ? site.key : "";
        final String videoId = video.id != null ? video.id : "";
        final String rawTitle = video.title != null ? video.title.trim() : "";

        final SeriesScrapeStore.OverrideRecord existing =
                SeriesScrapeStore.load(a, siteKey, videoId, rawTitle);
        final SeriesScrapeStore.OverrideRecord record =
                existing != null ? existing : new SeriesScrapeStore.OverrideRecord();

        final Cms.Line line =
                activeLine != null
                        ? activeLine
                        : (video.lines != null && !video.lines.isEmpty()
                                ? video.lines.get(0)
                                : null);
        final List<Cms.Episode> episodes =
                line != null && line.episodes != null
                        ? line.episodes
                        : Collections.<Cms.Episode>emptyList();
        final TvSeriesScraper.ScrapedLine scraped =
                TvSeriesScraper.scrapeLine(rawTitle, episodes, record);

        boolean effectiveSort =
                record.sortPreferenceExplicit
                        ? record.sortByScrapedEpisode
                        : scraped.sourceOrderScrambled;

        StringBuilder msg = new StringBuilder();
        msg.append("作品：")
                .append(
                        record.matchedTitle.isEmpty()
                                ? TvSeriesScraper.cleanWorkTitle(rawTitle)
                                : record.matchedTitle);
        if (!record.metadataSource.isEmpty()) {
            msg.append("（已刮削：")
                    .append("bangumi".equals(record.metadataSource) ? "Bangumi" : "豆瓣")
                    .append("）");
        }
        msg.append("\n当前线路：共 ")
                .append(episodes.size())
                .append(" 项（识别正片 ")
                .append(scraped.regularCount)
                .append(" 集");
        if (scraped.specialCount > 0) {
            msg.append("，特辑/预告 ").append(scraped.specialCount).append(" 项");
        }
        msg.append("）");
        if (scraped.sourceOrderScrambled) {
            msg.append(" · 检测到片源乱序");
        }
        if (record.episodeOffset != 0) {
            msg.append("\n集数偏移：")
                    .append(record.episodeOffset > 0 ? "+" : "")
                    .append(record.episodeOffset);
        }
        if (!record.danmuAnimeId.isEmpty()) {
            msg.append("\n已绑定弹幕番剧：")
                    .append(
                            record.danmuTitleOverride.isEmpty()
                                    ? record.danmuAnimeId
                                    : record.danmuTitleOverride);
        }

        String offsetText =
                record.episodeOffset == 0
                        ? "0（无偏移）"
                        : ((record.episodeOffset > 0 ? "+" : "") + record.episodeOffset);

        String[] items = {
            "🔍 搜索并重新刮削剧集（豆瓣 / Bangumi）",
            "🔢 集数整体偏移校正 · 当前：" + offsetText,
            "↕ 按刮削集数智能排序 · 当前：" + (effectiveSort ? "已开启" : "已关闭"),
            "🎬 隐藏预告 / 花絮 / SP 特辑 · 当前：" + (record.hideSpecials ? "已隐藏" : "全部显示"),
            "✏️ 手动校正单集集号"
                    + (record.episodeNumberOverrides.isEmpty()
                            ? ""
                            : "（已校正 " + record.episodeNumberOverrides.size() + " 集）"),
            "💬 绑定精准弹幕番剧（解决弹幕错集）",
            "↺ 清除本剧刮削覆盖（恢复自动识别）"
        };

        new AppDialog.Builder(a)
                .setTitle("剧集内刮削与集数校正")
                .setMessage(msg.toString())
                .setWide(true)
                .setItems(
                        items,
                        (dialog, which) -> {
                            if (which == 0) {
                                showMetadataSearchPrompt(a, site, video, line, record, onUpdated);
                            } else if (which == 1) {
                                showOffsetPicker(a, siteKey, videoId, rawTitle, record, onUpdated);
                            } else if (which == 2) {
                                record.sortPreferenceExplicit = true;
                                record.sortByScrapedEpisode = !effectiveSort;
                                SeriesScrapeStore.save(a, siteKey, videoId, rawTitle, record);
                                a.toast(
                                        record.sortByScrapedEpisode
                                                ? "已开启按刮削集数智能排序"
                                                : "已切换为片源原始顺序");
                                if (onUpdated != null) onUpdated.run();
                            } else if (which == 3) {
                                record.hideSpecials = !record.hideSpecials;
                                SeriesScrapeStore.save(a, siteKey, videoId, rawTitle, record);
                                a.toast(record.hideSpecials ? "已隐藏预告与特辑" : "已恢复显示全部条目");
                                if (onUpdated != null) onUpdated.run();
                            } else if (which == 4) {
                                showEpisodeManualCorrectList(
                                        a, siteKey, videoId, rawTitle, line, record, onUpdated);
                            } else if (which == 5) {
                                showDanmuAnimeBinder(
                                        a, siteKey, videoId, rawTitle, record, onUpdated);
                            } else if (which == 6) {
                                SeriesScrapeStore.remove(a, siteKey, videoId, rawTitle);
                                a.toast("已清除本剧刮削覆盖，恢复自动识别");
                                if (onUpdated != null) onUpdated.run();
                            }
                        })
                .setNegativeButton("关闭", null)
                .show();
    }

    private static void showOffsetPicker(
            final MainActivity a,
            final String siteKey,
            final String videoId,
            final String rawTitle,
            final SeriesScrapeStore.OverrideRecord record,
            final Runnable onUpdated) {
        String[] labels = new String[OFFSET_PRESETS.length];
        int checked = 5;
        for (int i = 0; i < OFFSET_PRESETS.length; i++) {
            int v = OFFSET_PRESETS[i];
            if (v == record.episodeOffset) checked = i;
            if (v == 0) {
                labels[i] = "0（不偏移 / 默认）";
            } else if (v > 0) {
                labels[i] = "+" + v + " 集（例如源第1集实际为第" + (1 + v) + "集）";
            } else {
                labels[i] = v + " 集（例如源多出 " + (-v) + " 个前导项）";
            }
        }
        new AppDialog.Builder(a)
                .setTitle("集数整体偏移校正")
                .setMessage("当多季连播或片源缺少前导集导致整体错位时，可统一修正显示集号与弹幕匹配集号。")
                .setSingleChoiceItems(
                        labels,
                        checked,
                        (d, idx) -> {
                            record.episodeOffset = OFFSET_PRESETS[idx];
                            SeriesScrapeStore.save(a, siteKey, videoId, rawTitle, record);
                            a.toast(
                                    record.episodeOffset == 0
                                            ? "已恢复集数偏移为 0"
                                            : "已设置集数偏移："
                                                    + (record.episodeOffset > 0 ? "+" : "")
                                                    + record.episodeOffset);
                            if (onUpdated != null) onUpdated.run();
                        })
                .setNegativeButton("取消", null)
                .show();
    }

    private static void showEpisodeManualCorrectList(
            final MainActivity a,
            final String siteKey,
            final String videoId,
            final String rawTitle,
            final Cms.Line line,
            final SeriesScrapeStore.OverrideRecord record,
            final Runnable onUpdated) {
        if (line == null || line.episodes == null || line.episodes.isEmpty()) {
            a.toast("当前线路没有可校正的剧集");
            return;
        }
        final TvSeriesScraper.ScrapedLine scraped =
                TvSeriesScraper.scrapeLine(rawTitle, line.episodes, record);
        final int count = Math.min(scraped.episodes.size(), 200);
        String[] labels = new String[count];
        for (int i = 0; i < count; i++) {
            TvSeriesScraper.ScrapedEpisode ep = scraped.episodes.get(i);
            String recognized =
                    ep.isSpecial
                            ? ("特辑：" + ep.specialLabel)
                            : (ep.episodeNumber > 0
                                    ? ep.cleanDisplayLabel + (ep.manualOverride ? "（已手动指定）" : "")
                                    : "未识别集号");
            labels[i] = (i + 1) + ". " + ep.rawName + "  →  " + recognized;
        }
        new AppDialog.Builder(a)
                .setTitle("选择要校正集号的条目")
                .setWide(true)
                .setItems(
                        labels,
                        (d, idx) ->
                                showSingleEpisodeNumberInput(
                                        a,
                                        siteKey,
                                        videoId,
                                        rawTitle,
                                        line,
                                        idx,
                                        scraped.episodes.get(idx),
                                        record,
                                        onUpdated))
                .setNegativeButton("返回", null)
                .show();
    }

    private static void showSingleEpisodeNumberInput(
            final MainActivity a,
            final String siteKey,
            final String videoId,
            final String rawTitle,
            final Cms.Line line,
            final int sourceIndex,
            final TvSeriesScraper.ScrapedEpisode current,
            final SeriesScrapeStore.OverrideRecord record,
            final Runnable onUpdated) {
        final EditText input = new EditText(a);
        input.setInputType(InputType.TYPE_CLASS_NUMBER);
        input.setSingleLine(true);
        input.setTextColor(MainActivity.WHITE);
        input.setHintTextColor(0x88ffffff);
        input.setHint("输入真实集号（如 5，留空则恢复自动识别）");
        if (current != null && current.episodeNumber > 0) {
            input.setText(String.valueOf(current.episodeNumber));
            input.setSelection(input.getText().length());
        }
        input.setPadding(a.dp(14), a.dp(10), a.dp(14), a.dp(10));
        input.setBackground(a.bg(0x28ffffff, 12));

        new AppDialog.Builder(a)
                .setTitle("校正单集集号")
                .setMessage("原始条目：" + (current != null ? current.rawName : ""))
                .setView(input)
                .setPositiveButton(
                        "保存",
                        (d, w) -> {
                            String val = input.getText().toString().trim();
                            if (val.isEmpty()) {
                                record.episodeNumberOverrides.remove(sourceIndex);
                                a.toast("已清除该集手动覆盖");
                            } else {
                                int num = TvSeriesScraper.parsePositiveInt(val);
                                if (num <= 0 || num > 5000) {
                                    a.toast("请输入 1–5000 之间的有效集号");
                                    return;
                                }
                                record.episodeNumberOverrides.put(sourceIndex, num);
                                a.toast("已将该集校正为第 " + num + " 集");
                            }
                            SeriesScrapeStore.save(a, siteKey, videoId, rawTitle, record);
                            if (onUpdated != null) onUpdated.run();
                        })
                .setNegativeButton("取消", null)
                .setDefaultFocusButton(DialogInterface.BUTTON_POSITIVE)
                .show();
    }

    private static void showMetadataSearchPrompt(
            final MainActivity a,
            final Cms.Site site,
            final Cms.Video video,
            final Cms.Line line,
            final SeriesScrapeStore.OverrideRecord record,
            final Runnable onUpdated) {
        final String defaultQuery =
                !record.matchedTitle.isEmpty()
                        ? record.matchedTitle
                        : TvSeriesScraper.cleanWorkTitle(video.title);
        final EditText input = new EditText(a);
        input.setSingleLine(true);
        input.setText(defaultQuery);
        input.setSelection(defaultQuery.length());
        input.setTextColor(MainActivity.WHITE);
        input.setHintTextColor(0x88ffffff);
        input.setHint("输入剧名关键词（支持豆瓣与 Bangumi 联合刮削）");
        input.setPadding(a.dp(14), a.dp(10), a.dp(14), a.dp(10));
        input.setBackground(a.bg(0x28ffffff, 12));

        new AppDialog.Builder(a)
                .setTitle("搜索并刮削剧集元数据")
                .setMessage("将同时检索豆瓣与 Bangumi，获取正确剧名、海报、评分及官方分集标题。")
                .setView(input)
                .setPositiveButton(
                        "开始刮削",
                        (d, w) -> {
                            String q = input.getText().toString().trim();
                            if (q.isEmpty()) q = defaultQuery;
                            runMetadataSearch(a, site, video, q, record, onUpdated);
                        })
                .setNegativeButton("取消", null)
                .setDefaultFocusButton(DialogInterface.BUTTON_POSITIVE)
                .show();
    }

    private static void runMetadataSearch(
            final MainActivity a,
            final Cms.Site site,
            final Cms.Video video,
            final String query,
            final SeriesScrapeStore.OverrideRecord record,
            final Runnable onUpdated) {
        a.toast("正在刮削「" + query + "」…");
        final int ticket = a.generation;
        final String siteKey = site != null && site.key != null ? site.key : "";
        final String videoId = video.id != null ? video.id : "";
        final String rawTitle = video.title != null ? video.title.trim() : "";

        a.worker.execute(
                () -> {
                    final List<MediaCandidate> candidates = searchDoubanAndBangumi(query);
                    a.ui.post(
                            () -> {
                                if (a.isFinishing() || ticket != a.generation) return;
                                if (candidates.isEmpty()) {
                                    a.toast("未检索到匹配作品，可缩短剧名关键词重试");
                                    return;
                                }
                                String[] labels = new String[candidates.size()];
                                for (int i = 0; i < candidates.size(); i++) {
                                    labels[i] = candidates.get(i).displayLabel();
                                }
                                new AppDialog.Builder(a)
                                        .setTitle("选择正确匹配作品（" + candidates.size() + "）")
                                        .setWide(true)
                                        .setItems(
                                                labels,
                                                (d, idx) ->
                                                        applyCandidateAsync(
                                                                a,
                                                                siteKey,
                                                                videoId,
                                                                rawTitle,
                                                                video,
                                                                candidates.get(idx),
                                                                record,
                                                                onUpdated))
                                        .setNegativeButton("取消", null)
                                        .show();
                            });
                });
    }

    private static void applyCandidateAsync(
            final MainActivity a,
            final String siteKey,
            final String videoId,
            final String rawTitle,
            final Cms.Video video,
            final MediaCandidate cand,
            final SeriesScrapeStore.OverrideRecord record,
            final Runnable onUpdated) {
        a.toast("正在同步「" + cand.title + "」分集信息…");
        a.worker.execute(
                () -> {
                    Map<Integer, String> epTitles = new LinkedHashMap<>();
                    String poster = cand.posterUrl;
                    String synopsis = cand.synopsis;
                    double score = cand.score;
                    int totalEps = cand.totalEpisodes;
                    String year = cand.year;

                    if ("bangumi".equals(cand.source)) {
                        epTitles = fetchBangumiEpisodeTitles(cand.subjectId);
                    } else if ("douban".equals(cand.source)) {
                        JSONObject detail = fetchDoubanDetail(cand.kind, cand.subjectId);
                        if (detail != null) {
                            String intro = detail.optString("intro", "").trim();
                            if (!intro.isEmpty()) synopsis = intro;
                            JSONObject pic = detail.optJSONObject("pic");
                            if (pic != null) {
                                String large = pic.optString("large", "").trim();
                                if (!large.isEmpty()) poster = large;
                            }
                            JSONObject rating = detail.optJSONObject("rating");
                            if (rating != null && rating.optDouble("value", 0) > 0) {
                                score = rating.optDouble("value", score);
                            }
                            int epCnt = detail.optInt("episodes_count", 0);
                            if (epCnt > 0) totalEps = epCnt;
                            String y = detail.optString("year", "").trim();
                            if (!y.isEmpty()) year = y;
                        }
                    }

                    record.matchedTitle = cand.title;
                    record.metadataSource = cand.source;
                    record.subjectId = cand.subjectId;
                    record.posterUrl = poster;
                    record.synopsis = synopsis;
                    record.year = year;
                    record.doubanScore = score;
                    record.totalEpisodes = totalEps;
                    record.danmuTitleOverride = cand.title;
                    if (!epTitles.isEmpty()) {
                        record.officialEpisodeTitles.clear();
                        record.officialEpisodeTitles.putAll(epTitles);
                    }
                    SeriesScrapeStore.save(a, siteKey, videoId, rawTitle, record);

                    final int hydratedCount = epTitles.size();
                    a.ui.post(
                            () -> {
                                if (a.isFinishing()) return;
                                applyOverrideToVideo(video, record);
                                String msg = "已绑定「" + cand.title + "」";
                                if (hydratedCount > 0) {
                                    msg += " · 已同步 " + hydratedCount + " 集官方标题";
                                }
                                a.toast(msg);
                                if (onUpdated != null) onUpdated.run();
                            });
                });
    }

    static void applyOverrideToVideo(Cms.Video video, SeriesScrapeStore.OverrideRecord record) {
        if (video == null || record == null) return;
        if (!record.posterUrl.isEmpty()) video.poster = record.posterUrl;
        if (!record.synopsis.isEmpty()) video.description = record.synopsis;
        if (!record.year.isEmpty()) video.year = record.year;
        if (record.doubanScore > 0.1) {
            video.doubanScore = String.format(Locale.US, "%.1f", record.doubanScore);
        }
    }

    private static void showDanmuAnimeBinder(
            final MainActivity a,
            final String siteKey,
            final String videoId,
            final String rawTitle,
            final SeriesScrapeStore.OverrideRecord record,
            final Runnable onUpdated) {
        DanmuSettingsPanel.DanmuConfig cfg = DanmuSettingsPanel.loadConfig(a, a.isTvDevice());
        final DandanplayProvider provider = cfg.createProvider();
        if (provider.getConfiguredOrigins().isEmpty()) {
            a.toast("尚未配置弹幕服务源，请先在播放器的「弹幕设置」中填写弹幕服务器地址");
            return;
        }
        final String defaultQuery =
                !record.danmuTitleOverride.isEmpty()
                        ? record.danmuTitleOverride
                        : (!record.matchedTitle.isEmpty()
                                ? record.matchedTitle
                                : TvSeriesScraper.cleanWorkTitle(rawTitle));
        final EditText input = new EditText(a);
        input.setSingleLine(true);
        input.setText(defaultQuery);
        input.setSelection(defaultQuery.length());
        input.setTextColor(MainActivity.WHITE);
        input.setHintTextColor(0x88ffffff);
        input.setHint("输入番剧 / 剧集名称搜索弹幕库");
        input.setPadding(a.dp(14), a.dp(10), a.dp(14), a.dp(10));
        input.setBackground(a.bg(0x28ffffff, 12));

        new AppDialog.Builder(a)
                .setTitle("绑定精准弹幕番剧")
                .setMessage("绑定后，本剧所有剧集都将固定从所选番剧按刮削后的真实集号拉取弹幕。")
                .setView(input)
                .setPositiveButton(
                        "搜索弹幕库",
                        (d, w) -> {
                            final String q =
                                    input.getText().toString().trim().isEmpty()
                                            ? defaultQuery
                                            : input.getText().toString().trim();
                            a.toast("正在检索弹幕番剧「" + q + "」…");
                            a.worker.execute(
                                    () -> {
                                        try {
                                            DanmuProvider.CancellationToken token =
                                                    new DanmuProvider.CancellationToken();
                                            List<DanmuProvider.Candidate> found =
                                                    provider.matchOrSearch(
                                                            new DanmuProvider.MatchQuery(
                                                                    q, "", 0, 0L),
                                                            token);
                                            final Map<String, DanmuProvider.Candidate> uniqueAnime =
                                                    new LinkedHashMap<>();
                                            if (found != null) {
                                                for (DanmuProvider.Candidate c : found) {
                                                    if (c == null
                                                            || c.animeId == null
                                                            || c.animeId.isEmpty()) continue;
                                                    String k = c.sourceOrigin + "|" + c.animeId;
                                                    if (!uniqueAnime.containsKey(k)) {
                                                        uniqueAnime.put(k, c);
                                                    }
                                                }
                                            }
                                            final List<DanmuProvider.Candidate> animeList =
                                                    new ArrayList<>(uniqueAnime.values());
                                            a.ui.post(
                                                    () -> {
                                                        if (a.isFinishing()) return;
                                                        if (animeList.isEmpty()) {
                                                            a.toast("弹幕库未找到匹配番剧，请更换关键词");
                                                            return;
                                                        }
                                                        String[] opts =
                                                                new String[animeList.size()];
                                                        for (int i = 0; i < animeList.size(); i++) {
                                                            DanmuProvider.Candidate c =
                                                                    animeList.get(i);
                                                            opts[i] =
                                                                    c.animeTitle
                                                                            + "  (ID: "
                                                                            + c.animeId
                                                                            + ")";
                                                        }
                                                        new AppDialog.Builder(a)
                                                                .setTitle("选择要绑定的弹幕番剧")
                                                                .setWide(true)
                                                                .setItems(
                                                                        opts,
                                                                        (dlg, idx) -> {
                                                                            DanmuProvider.Candidate
                                                                                    picked =
                                                                                            animeList
                                                                                                    .get(
                                                                                                            idx);
                                                                            record.danmuAnimeId =
                                                                                    picked.animeId;
                                                                            record.danmuTitleOverride =
                                                                                    picked.animeTitle;
                                                                            record.danmuOrigin =
                                                                                    picked.sourceOrigin;
                                                                            SeriesScrapeStore.save(
                                                                                    a, siteKey,
                                                                                    videoId,
                                                                                    rawTitle,
                                                                                    record);
                                                                            a.toast(
                                                                                    "已绑定弹幕番剧："
                                                                                            + picked.animeTitle);
                                                                            if (onUpdated != null)
                                                                                onUpdated.run();
                                                                        })
                                                                .setNegativeButton("取消", null)
                                                                .show();
                                                    });
                                        } catch (Exception e) {
                                            AppLog.w(
                                                    "TvSeriesScrapeDialog",
                                                    "Danmu search failed",
                                                    e);
                                            a.ui.post(() -> a.toast("弹幕番剧搜索失败，请检查弹幕服务地址"));
                                        }
                                    });
                        })
                .setNegativeButton("取消", null)
                .setDefaultFocusButton(DialogInterface.BUTTON_POSITIVE)
                .show();
    }

    static List<MediaCandidate> searchDoubanAndBangumi(String query) {
        List<MediaCandidate> merged = new ArrayList<>();
        String clean = TvSeriesScraper.cleanWorkTitle(query);
        if (clean.isEmpty()) return merged;
        merged.addAll(searchDouban(clean));
        merged.addAll(searchBangumi(clean));
        return merged;
    }

    private static List<MediaCandidate> searchDouban(String query) {
        List<MediaCandidate> out = new ArrayList<>();
        try {
            String url =
                    "https://m.douban.com/rexxar/api/v2/search/weixin?q="
                            + URLEncoder.encode(query, StandardCharsets.UTF_8.name())
                            + "&start=0&count=8";
            String body =
                    httpGet(
                            url,
                            "https://m.douban.com/",
                            "Mozilla/5.0 (Linux; Android 10; TV) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36");
            if (body == null || body.isEmpty()) return out;
            JSONObject root = new JSONObject(body);
            JSONObject subjects = root.optJSONObject("subjects");
            JSONArray items = subjects != null ? subjects.optJSONArray("items") : null;
            if (items == null) return out;
            for (int i = 0; i < items.length() && out.size() < 6; i++) {
                JSONObject item = items.optJSONObject(i);
                if (item == null) continue;
                JSONObject target = item.optJSONObject("target");
                if (target == null) continue;
                String id = target.optString("id", "").trim();
                String title = target.optString("title", "").trim();
                if (id.isEmpty() || title.isEmpty()) continue;
                String type = item.optString("target_type", "movie");
                String kind = "tv".equalsIgnoreCase(type) ? "tv" : "movie";
                String year = target.optString("year", "").trim();
                double score = 0.0;
                JSONObject rating = target.optJSONObject("rating");
                if (rating != null) score = rating.optDouble("value", 0.0);
                String poster = target.optString("cover_url", "").trim();
                out.add(new MediaCandidate("douban", id, kind, title, year, score, 0, poster, ""));
            }
        } catch (Exception ignored) {
        }
        return out;
    }

    private static List<MediaCandidate> searchBangumi(String query) {
        List<MediaCandidate> out = new ArrayList<>();
        try {
            String url =
                    "https://api.bgm.tv/search/subject/"
                            + URLEncoder.encode(query, StandardCharsets.UTF_8.name())
                            + "?responseGroup=large&max_results=6";
            String body = httpGet(url, null, "MarcoMovie/0.6.3 (AndroidTV)");
            if (body == null || body.isEmpty()) return out;
            JSONObject root = new JSONObject(body);
            JSONArray list = root.optJSONArray("list");
            if (list == null) return out;
            for (int i = 0; i < list.length() && out.size() < 6; i++) {
                JSONObject item = list.optJSONObject(i);
                if (item == null) continue;
                int type = item.optInt("type", 0);
                if (type != 2 && type != 6) continue; // 2=anime, 6=real TV/drama
                String id = String.valueOf(item.optInt("id", 0));
                if ("0".equals(id)) continue;
                String nameCn = item.optString("name_cn", "").trim();
                String name = nameCn.isEmpty() ? item.optString("name", "").trim() : nameCn;
                if (name.isEmpty()) continue;
                String airDate = item.optString("air_date", "").trim();
                String year = airDate.length() >= 4 ? airDate.substring(0, 4) : "";
                double score = 0.0;
                JSONObject rating = item.optJSONObject("rating");
                if (rating != null) score = rating.optDouble("score", 0.0);
                int eps = item.optInt("eps_count", item.optInt("eps", 0));
                String poster = "";
                JSONObject images = item.optJSONObject("images");
                if (images != null) {
                    poster = images.optString("large", images.optString("common", "")).trim();
                }
                String summary = item.optString("summary", "").trim();
                out.add(
                        new MediaCandidate(
                                "bangumi", id, "tv", name, year, score, eps, poster, summary));
            }
        } catch (Exception ignored) {
        }
        return out;
    }

    static JSONObject fetchDoubanDetail(String kind, String subjectId) {
        if (subjectId == null || subjectId.isEmpty()) return null;
        try {
            String url = "https://m.douban.com/rexxar/api/v2/" + kind + "/" + subjectId;
            String body =
                    httpGet(
                            url,
                            "https://m.douban.com/",
                            "Mozilla/5.0 (Linux; Android 10; TV) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36");
            if (body != null && body.trim().startsWith("{")) {
                return new JSONObject(body);
            }
        } catch (Exception ignored) {
        }
        return null;
    }

    static Map<Integer, String> fetchBangumiEpisodeTitles(String subjectId) {
        Map<Integer, String> map = new LinkedHashMap<>();
        if (subjectId == null || subjectId.isEmpty()) return map;
        try {
            String url =
                    "https://api.bgm.tv/v0/episodes?subject_id="
                            + URLEncoder.encode(subjectId, StandardCharsets.UTF_8.name())
                            + "&type=0&limit=100";
            String body = httpGet(url, null, "MarcoMovie/0.6.3 (AndroidTV)");
            if (body == null || body.isEmpty()) return map;
            JSONObject root = new JSONObject(body);
            JSONArray data = root.optJSONArray("data");
            if (data == null) return map;
            for (int i = 0; i < data.length(); i++) {
                JSONObject ep = data.optJSONObject(i);
                if (ep == null) continue;
                int epNum = (int) Math.round(ep.optDouble("ep", ep.optDouble("sort", 0)));
                if (epNum <= 0) continue;
                String nameCn = ep.optString("name_cn", "").trim();
                String name = nameCn.isEmpty() ? ep.optString("name", "").trim() : nameCn;
                if (!name.isEmpty()) {
                    map.put(epNum, name);
                }
            }
        } catch (Exception ignored) {
        }
        return map;
    }

    private static String httpGet(String url, String referer, String ua) throws IOException {
        Request.Builder rb = new Request.Builder().url(url).header("User-Agent", ua);
        if (referer != null && !referer.isEmpty()) {
            rb.header("Referer", referer);
        }
        try (Response resp = HTTP.newCall(rb.build()).execute()) {
            if (!resp.isSuccessful() || resp.body() == null) return "";
            return resp.body().string();
        }
    }
}
