package com.pilipala.marcomovie;

/** One request owns the paging busy state; stale completion cannot release its successor. */
final class TvSearchPageSlot {
    private SearchCoordinator owner;

    SearchCoordinator get() {
        return owner;
    }

    void bind(SearchCoordinator request) {
        if (owner != null) throw new IllegalStateException("page request already active");
        owner = request;
    }

    boolean finish(SearchCoordinator request) {
        if (request == null || owner != request) return false;
        cancel();
        return true;
    }

    void cancel() {
        SearchCoordinator old = owner;
        owner = null;
        if (old != null) old.close();
    }
}
