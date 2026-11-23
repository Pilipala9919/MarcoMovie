package com.pilipala.marcomovie;

import android.view.KeyEvent;
import android.view.View;

/** A MENU action requires a matched, uncancelled release and uninterrupted focus. */
final class TvMenuAction {
    static final class Release {
        long downTime = -1;

        void reset() {
            downTime = -1;
        }

        boolean key(int action, int repeat, long time, boolean canceled) {
            if (action == KeyEvent.ACTION_DOWN && repeat == 0) downTime = time;
            if (action != KeyEvent.ACTION_UP) return false;
            boolean commit = downTime >= 0 && downTime == time && !canceled;
            reset();
            return commit;
        }
    }

    static void bind(View view, Runnable action) {
        Release release = new Release();
        View.OnFocusChangeListener previous = view.getOnFocusChangeListener();
        view.setOnFocusChangeListener(
                (v, focused) -> {
                    if (!focused) release.reset();
                    if (previous != null) previous.onFocusChange(v, focused);
                });
        view.setOnKeyListener(
                (v, key, event) -> {
                    if (key != KeyEvent.KEYCODE_MENU) {
                        release.reset();
                        return false;
                    }
                    if (!v.hasFocus() || !v.isShown()) {
                        release.reset();
                        return true;
                    }
                    if (release.key(
                            event.getAction(),
                            event.getRepeatCount(),
                            event.getDownTime(),
                            event.isCanceled())) action.run();
                    return true;
                });
    }
}
