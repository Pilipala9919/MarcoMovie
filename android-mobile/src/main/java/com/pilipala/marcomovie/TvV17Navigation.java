package com.pilipala.marcomovie;

import android.view.View;

/** Remembers a content tag rather than holding a potentially detached View. */
final class TvV17Navigation {
    private String returnTag;

    void remember(View view) {
        if (view != null && view.getTag() instanceof String) returnTag = (String) view.getTag();
    }

    View restore(View root, View fallback) {
        View target = returnTag == null ? null : root.findViewWithTag(returnTag);
        return usable(target) ? target : usable(fallback) ? fallback : null;
    }

    private boolean usable(View view) {
        return view != null
                && view.isAttachedToWindow()
                && view.isShown()
                && view.isFocusable()
                && view.isEnabled();
    }
}
