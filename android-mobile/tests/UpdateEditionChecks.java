package com.pilipala.marcomovie;

import org.json.JSONObject;

/** Exercises the metadata actually used by UpdateManager, without networking. */
public final class UpdateEditionChecks {
    static int count;

    static void check(boolean value, String name) {
        if (!value) throw new AssertionError(name);
        count++;
    }

    interface Work {
        void run() throws Exception;
    }

    static void rejects(String name, Work work) throws Exception {
        try {
            work.run();
        } catch (Exception expected) {
            count++;
            return;
        }
        throw new AssertionError(name);
    }

    static JSONObject feed(boolean mobile, String version, int code) throws Exception {
        String platform = UpdatePolicy.platform(mobile);
        String name = "MarcoMovie-" + version + "-" + platform + ".apk";
        return new JSONObject()
                .put("schema", 1)
                .put("platform", platform)
                .put("versionName", version)
                .put("versionCode", code)
                .put("minSdk", 23)
                .put("size", 100)
                .put("sha256", new String(new char[64]).replace('\0', 'a'))
                .put("url", UpdatePolicy.MIRROR + name)
                .put(
                        "githubUrl",
                        "https://github.com/Pilipala9919/MarcoMovie/releases/download/"
                                + platform
                                + "-v"
                                + version
                                + "/"
                                + name)
                .put("prerelease", false)
                .put("notes", platform + " fixes");
    }

    public static void main(String[] args) throws Exception {
        for (boolean mobile : new boolean[] {true, false}) {
            String platform = UpdatePolicy.platform(mobile);
            for (String channel : new String[] {"stable", "preview"}) {
                String[] feeds = UpdatePolicy.feeds(channel, mobile);
                check(feeds[0].contains("/" + platform), "own mirror feed first");
                check(feeds[1].contains("/" + platform), "own raw feed second");
                check(
                        feeds[2].equals(UpdatePolicy.feeds(channel)[0]),
                        "legacy transition fallback");
            }
            JSONObject own = feed(mobile, "0.5.7", 57);
            UpdateRelease release = new UpdateRelease(own, "stable", mobile);
            check(release.code == 57 && release.version.equals("0.5.7"), "own version");
            check(
                    release.downloads[1].contains("/" + platform + "-v0.5.7/"),
                    "actual release tag retained");
            rejects("opposite edition metadata", () -> new UpdateRelease(own, "stable", !mobile));
            JSONObject mislabeled = feed(!mobile, "0.5.7", 57).put("platform", platform);
            rejects(
                    "opposite APK despite feed label",
                    () -> new UpdateRelease(mislabeled, "stable", mobile));
            own.put(
                    "githubUrl",
                    own.getString("githubUrl")
                            .replace(platform + "-v", UpdatePolicy.platform(!mobile) + "-v"));
            rejects("cross edition fallback tag", () -> new UpdateRelease(own, "stable", mobile));
            JSONObject preview = feed(mobile, "0.5.8", 58).put("prerelease", true);
            rejects("stable rejects preview", () -> new UpdateRelease(preview, "stable", mobile));
            check(
                    new UpdateRelease(preview, "preview", mobile).preview,
                    "preview channel accepts preview");
            JSONObject github = feed(mobile, "0.5.7", 57);
            github.put("url", github.getString("githubUrl"));
            UpdateRelease mirrorFirst = new UpdateRelease(github, "stable", mobile);
            check(
                    mirrorFirst.downloads[0].startsWith(UpdatePolicy.MIRROR)
                            && mirrorFirst.downloads[1].equals(github.getString("githubUrl")),
                    "mirror prioritized first with GitHub fallback");
            JSONObject missingTag = feed(mobile, "0.5.7", 57);
            missingTag.remove("githubUrl");
            rejects(
                    "never invent canonical release tag",
                    () -> new UpdateRelease(missingTag, "stable", mobile));
        }
        JSONObject legacy = feed(false, "0.5.0", 50);
        legacy.remove("platform");
        legacy.remove("githubUrl");
        legacy.put("url", UpdatePolicy.downloads("0.5.0", false)[0]);
        check(new UpdateRelease(legacy, "stable", false).code == 50, "legacy TV feed");
        rejects(
                "phone never falls back to TV root",
                () -> new UpdateRelease(legacy, "stable", true));
        JSONObject mobile = feed(true, "0.5.3", 53);
        mobile.remove("platform");
        legacy.put("mobile", mobile);
        UpdateRelease phone = new UpdateRelease(legacy, "stable", true);
        check(
                phone.code == 53 && phone.version.equals("0.5.3"),
                "phone uses nested version rather than TV version");
        check(phone.notes.equals("android-mobile fixes"), "phone notes isolated");
        check(
                new UpdateRelease(legacy, "stable", false).code == 50,
                "phone update leaves TV version intact");
        mobile.remove("versionCode");
        mobile.remove("versionName");
        mobile.remove("githubUrl");
        mobile.put("url", UpdatePolicy.downloads("0.5.0", true)[0]);
        check(
                new UpdateRelease(legacy, "stable", true).code == 50,
                "old shared version feed supported");
        for (String edition : new String[] {null, "", "lite", "Mobile", "unexpected"})
            rejects("unknown edition fails closed", () -> UpdatePolicy.mobileEdition(edition));
        check(
                UpdatePolicy.mobileEdition("mobile") && !UpdatePolicy.mobileEdition("tv"),
                "explicit installed edition");
        String noisyNotes =
                "# Marco Movie Android 电视 / 盒子 0.5.22\n\n"
                        + "发布日期：2026-11-12。版本代码：`81`。本次更新带来独立片头片尾记忆与首页自动加载体验。\n\n"
                        + "## 核心修复与优化\n\n"
                        + "- **独立片头片尾跳过记录**：每部影片单独保存片头片尾时间（`VideoSkipStore`），不再全局覆盖其他剧集。\n"
                        + "- **首页海报自动翻页与防闪烁**：滑动至底部自动加载下一页海报，移除多余按钮并消除刷新闪烁。\n"
                        + "- **返回首页即时刷新观看历史**：看完影片返回首页立即展示最新观影记录。\n"
                        + "- **独立片头片尾跳过记录**：每部影片单独保存片头片尾时间，不再全局覆盖其他剧集。\n\n"
                        + "## 包信息与构建记录\n\n"
                        + "- **SHA-256**：`aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`\n"
                        + "- **构建提交**：`0123456789abcdef`\n\n"
                        + "## 验证范围与已知限制\n\n"
                        + "- 通过公共内容守卫检查与离线回归测试。\n"
                        + "- 已知限制：部分外部源仍受限于上游网络环境。\n";
        ReleaseNotesFormatter.Summary summary = ReleaseNotesFormatter.summarize(noisyNotes);
        check(
                summary.overview.contains("本次更新带来独立片头片尾记忆") && !summary.overview.contains("发布日期"),
                "overview strips metadata prefix");
        check(summary.totalItems == 4, "deduplicates bullets and strips checksums/CI logs");
        String plain = ReleaseNotesFormatter.formatPlainText(noisyNotes);
        check(
                plain.contains("【片源与播放】")
                        && plain.contains("【界面与交互】")
                        && plain.contains("【问题修复与优化】")
                        && plain.contains("【注意事项】")
                        && !plain.contains("SHA-256")
                        && !plain.contains("公共内容守卫"),
                "grouped plain text omits build clutter");
        System.out.println("OK " + count + " update edition checks");
    }
}
