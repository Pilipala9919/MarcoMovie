package com.pilipala.marcomovie;

import java.util.*;

public final class SearchVariantsChecks {
    static int checks;

    static void check(boolean value) {
        if (!value) throw new AssertionError("check " + checks);
        checks++;
    }

    static Cms.Video video(String id, String title) {
        Cms.Video v = new Cms.Video();
        v.id = id;
        v.title = title;
        v.tag = "folder";
        return v;
    }

    public static void main(String[] args) throws Exception {
        int[] calls = {0};
        List<Cms.Video> found =
                SearchVariants.run(
                        "sample",
                        Arrays.asList("样本", "另一写法", "sample"),
                        t -> t.equals("样本"),
                        term -> {
                            calls[0]++;
                            if (calls[0] > 1)
                                throw new AssertionError(
                                        "useful result must not wait for another spelling");
                            return Arrays.asList(video("folder", "样本"));
                        });
        check(calls[0] == 1 && found.size() == 1 && found.get(0).tag.equals("folder"));
        calls[0] = 0;
        found =
                SearchVariants.run(
                        "sample",
                        Arrays.asList("无结果", "sample"),
                        t -> true,
                        term -> {
                            calls[0]++;
                            return calls[0] == 1
                                    ? Collections.emptyList()
                                    : Arrays.asList(
                                            video("a", "title"),
                                            video("a", "title"),
                                            video("", "title"));
                        });
        check(calls[0] == 2 && found.size() == 1);
        found =
                SearchVariants.run(
                        "sample",
                        Arrays.asList("错误", "sample"),
                        t -> true,
                        term -> {
                            if (term.equals("错误")) throw new java.io.IOException();
                            return Arrays.asList(video("a", "title"));
                        });
        check(found.size() == 1);
        boolean failed = false;
        try {
            SearchVariants.run(
                    "sample",
                    Arrays.asList("a", "b"),
                    t -> true,
                    term -> {
                        throw new java.io.IOException();
                    });
        } catch (java.io.IOException expected) {
            failed = true;
        }
        check(failed);
        found =
                SearchVariants.run(
                        "sample",
                        Arrays.asList("样本", "sample"),
                        t -> t.equals("样本"),
                        term -> Arrays.asList(video("a", "unmatched"), video("a", "样本")));
        check(found.size() == 1 && found.get(0).title.equals("样本"));
        Thread.currentThread().interrupt();
        boolean cancelled = false;
        try {
            SearchVariants.run("x", Arrays.asList("x"), t -> true, term -> Collections.emptyList());
        } catch (InterruptedException expected) {
            cancelled = true;
        } finally {
            Thread.interrupted();
        }
        check(cancelled);
        calls[0] = 0;
        cancelled = false;
        try {
            SearchVariants.run(
                    "x",
                    Arrays.asList("a", "b"),
                    t -> true,
                    term -> {
                        calls[0]++;
                        throw new InterruptedException();
                    });
        } catch (InterruptedException expected) {
            cancelled = Thread.currentThread().isInterrupted();
        } finally {
            Thread.interrupted();
        }
        check(cancelled && calls[0] == 1);
        calls[0] = 0;
        boolean verification = false;
        try {
            SearchVariants.run(
                    "x",
                    Arrays.asList("a", "b"),
                    t -> true,
                    term -> {
                        calls[0]++;
                        throw new SearchCoordinator.VerificationRequiredException();
                    });
        } catch (SearchCoordinator.VerificationRequiredException expected) {
            verification = true;
        }
        check(verification && calls[0] == 1);

        List<String> sequelForms = SearchVariants.sequelVariants("斗罗大陆2");
        check(
                sequelForms.contains("斗罗大陆2")
                        && sequelForms.contains("斗罗大陆II")
                        && sequelForms.contains("斗罗大陆第二季"));
        List<String> mergedTerms =
                SearchVariants.mergeTerms("斗罗大陆2", Collections.singletonList("斗罗大陆2"));
        check(mergedTerms.indexOf("斗罗大陆2") == 0 && mergedTerms.contains("斗罗大陆II"));

        calls[0] = 0;
        found =
                SearchVariants.run(
                        "斗罗大陆2",
                        mergedTerms,
                        t -> false,
                        term -> {
                            calls[0]++;
                            if ("斗罗大陆2".equals(term)) {
                                Cms.Video comic = video("comic_dl2", "斗罗大陆2动态漫");
                                comic.tag = "短漫剧";
                                return Collections.singletonList(comic);
                            }
                            if ("斗罗大陆II".equals(term)) {
                                Cms.Video anime = video("anime_dl2", "斗罗大陆II绝世唐门");
                                anime.tag = "动漫";
                                return Collections.singletonList(anime);
                            }
                            return Collections.emptyList();
                        });
        check(
                calls[0] == 2
                        && found.size() == 2
                        && "anime_dl2".equals(found.get(0).id)
                        && "comic_dl2".equals(found.get(1).id));
        calls[0] = 0;
        found =
                SearchVariants.run(
                        "斗罗大陆2",
                        mergedTerms,
                        t -> false,
                        term -> {
                            calls[0]++;
                            Cms.Video primary = video("anime_direct", "斗罗大陆2：绝世唐门");
                            primary.tag = "动漫";
                            return Collections.singletonList(primary);
                        });
        check(calls[0] == 1 && found.size() == 1 && "anime_direct".equals(found.get(0).id));
        check(
                SearchVariants.canonicalSearchKey("斗罗大陆2")
                                .equals(SearchVariants.canonicalSearchKey("斗罗大陆II"))
                        && SearchVariants.canonicalSearchKey("庆余年 第二季")
                                .equals(SearchVariants.canonicalSearchKey("庆余年 S02"))
                        && SearchVariants.canonicalSearchKey("庆余年 第一季")
                                .equals(SearchVariants.canonicalSearchKey("庆余年"))
                        && !SearchVariants.canonicalSearchKey("庆余年 第二季")
                                .equals(SearchVariants.canonicalSearchKey("庆余年")));
        check(!SearchVariants.wantsComicOrShortDrama("斗罗大陆2"));
        check(SearchVariants.wantsComicOrShortDrama("斗罗大陆2漫剧"));
        System.out.println("OK " + checks + " search fallback checks");
    }
}
