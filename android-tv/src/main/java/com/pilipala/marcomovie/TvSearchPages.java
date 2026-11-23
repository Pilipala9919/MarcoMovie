package com.pilipala.marcomovie;

import java.io.IOException;
import java.util.*;

/** Immutable search-page transactions; publish only after the host rechecks its context token. */
final class TvSearchPages {
    static final int MAX_RESULTS = 5000;

    interface Fetch {
        Cms.Listing get(String term, int page) throws Exception;
    }

    static final class Cursor {
        final String term;
        final int page, pages;
        final Set<String> seen;

        Cursor(String term, int page, int pages, Set<String> seen) {
            this.term = term;
            this.page = page;
            this.pages = pages;
            this.seen = Collections.unmodifiableSet(new HashSet<>(seen));
        }

        boolean more() {
            return page < pages && page < Integer.MAX_VALUE;
        }
    }

    final String query;
    final List<Cms.Video> videos;
    final List<Cursor> cursors;
    final boolean limited;

    private TvSearchPages(
            String query, List<Cms.Video> videos, List<Cursor> cursors, boolean limited) {
        this.query = query;
        this.videos = Collections.unmodifiableList(new ArrayList<>(videos));
        this.cursors = Collections.unmodifiableList(new ArrayList<>(cursors));
        this.limited = limited;
    }

    boolean hasMore() {
        if (limited) return false;
        for (Cursor c : cursors) if (c.more()) return true;
        return false;
    }

    static TvSearchPages first(
            String query, List<String> variants, SearchVariants.Match match, Fetch fetch)
            throws Exception {
        List<Cursor> cursors = new ArrayList<>();
        List<Cms.Video> raw =
                SearchVariants.run(
                        query,
                        variants,
                        match,
                        term -> {
                            Cms.Listing page = fetch.get(term, 1);
                            requirePage(page, 1);
                            Set<String> seen = new HashSet<>();
                            for (Cms.Video v : page.videos) if (playable(v)) seen.add(v.id);
                            cursors.add(
                                    new Cursor(
                                            term,
                                            1,
                                            page.videos.isEmpty() ? 1 : page.pageCount,
                                            seen));
                            return page.videos;
                        });
        List<Cms.Video> videos = new ArrayList<>();
        Set<String> ids = new HashSet<>();
        for (Cms.Video v : raw) if (playable(v) && ids.add(v.id)) videos.add(v);
        return new TvSearchPages(query, videos, cursors, false);
    }

    TvSearchPages next(SearchVariants.Match match, Fetch fetch) throws Exception {
        if (!hasMore()) return this;
        List<Cursor> next = new ArrayList<>(cursors);
        List<Cms.Video> merged = new ArrayList<>(videos);
        Set<String> ids = new HashSet<>();
        for (Cms.Video v : videos) ids.add(v.id);
        for (int i = 0; i < next.size(); i++) {
            Cursor cursor = next.get(i);
            if (!cursor.more()) continue;
            int requested = cursor.page + 1;
            Cms.Listing page = fetch.get(cursor.term, requested);
            requirePage(page, requested);
            boolean newId = false, limited = false;
            Set<String> seen = new HashSet<>(cursor.seen);
            boolean direct =
                    cursor.term.equalsIgnoreCase(query)
                            || SearchVariants.sequelVariants(query).contains(cursor.term);
            for (Cms.Video v : page.videos) {
                if (!playable(v)) continue;
                if (seen.add(v.id)) newId = true;
                if (ids.contains(v.id)) continue;
                if (!direct && !match.test(v.title)) continue;
                if (merged.size() == MAX_RESULTS) {
                    limited = true;
                    break;
                }
                ids.add(v.id);
                merged.add(v);
            }
            // A server that repeats its results cannot keep the user in an endless page loop.
            next.set(
                    i,
                    new Cursor(
                            cursor.term,
                            requested,
                            !newId ? requested : Math.max(requested, page.pageCount),
                            seen));
            return new TvSearchPages(query, merged, next, limited || merged.size() >= MAX_RESULTS);
        }
        return this;
    }

    private static void requirePage(Cms.Listing page, int requested) throws IOException {
        if (page == null || page.page != requested)
            throw new IOException("来源返回的搜索页码与请求不符，请重试或更换来源");
        if (page.videos.size() > 500) throw new IOException("单页超过 500 项限制");
    }

    private static boolean playable(Cms.Video v) {
        return v != null && v.id != null && !v.id.isEmpty() && !v.id.startsWith("msearch:");
    }
}
