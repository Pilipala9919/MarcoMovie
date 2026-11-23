package com.pilipala.marcomovie;

import android.graphics.Color;
import android.graphics.Typeface;
import android.view.Gravity;
import android.view.KeyEvent;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;

/** A local marking transaction. Player control, persistence and global key routing belong to A. */
final class TvV17MarkerOverlay extends FrameLayout {
    interface Listener {
        void confirm(boolean intro, long selectedTimeMs, long durationMs);

        void cancel();

        void preview(long selectedTimeMs);
    }

    /** No clock or player reference: only a frozen position and explicit adjustments can change it. */
    static final class State {
        static final int UNHANDLED = 0, HANDLED = 1, CONFIRM = 2, CANCEL = 3;
        boolean frozen;
        boolean closed;
        boolean intro;
        boolean editingTime;
        long entryPositionMs;
        long selectedTimeMs;
        long durationMs;
        private int pendingActionKey = -1;
        private long pendingDownTime = -1;

        boolean freeze(long positionMs, long durationMs) {
            if (frozen || closed) return false;
            frozen = true;
            this.durationMs = Math.max(0, durationMs);
            entryPositionMs = Math.max(0, positionMs);
            selectedTimeMs = entryPositionMs;
            intro = durationMs <= 0 || entryPositionMs < durationMs / 2;
            return true;
        }

        boolean canConfirm() {
            return frozen
                    && !closed
                    && selectedTimeMs > 0
                    && (durationMs <= 0 || selectedTimeMs < durationMs);
        }

        void adjust(long deltaMs) {
            if (!frozen || closed) return;
            long max = durationMs > 0 ? durationMs - 1 : Long.MAX_VALUE;
            if (deltaMs > 0 && deltaMs > max - selectedTimeMs) selectedTimeMs = max;
            else if (deltaMs < 0 && deltaMs < -selectedTimeMs) selectedTimeMs = 0;
            else selectedTimeMs += deltaMs;
            selectedTimeMs = Math.max(0, Math.min(max, selectedTimeMs));
        }

        int key(int key, int action, int repeat, boolean canceled) {
            return key(key, action, repeat, canceled, 0);
        }

        int key(int key, int action, int repeat, boolean canceled, long downTime) {
            if (key == KeyEvent.KEYCODE_MENU
                    || key == KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
                    || key == KeyEvent.KEYCODE_MEDIA_PLAY
                    || key == KeyEvent.KEYCODE_MEDIA_PAUSE
                    || key == KeyEvent.KEYCODE_MEDIA_FAST_FORWARD
                    || key == KeyEvent.KEYCODE_MEDIA_REWIND) {
                if (action == KeyEvent.ACTION_DOWN) pendingActionKey = -1;
                return HANDLED;
            }
            if (key != KeyEvent.KEYCODE_BACK
                    && key != KeyEvent.KEYCODE_DPAD_LEFT
                    && key != KeyEvent.KEYCODE_DPAD_RIGHT
                    && key != KeyEvent.KEYCODE_DPAD_UP
                    && key != KeyEvent.KEYCODE_DPAD_DOWN
                    && key != KeyEvent.KEYCODE_DPAD_CENTER
                    && key != KeyEvent.KEYCODE_ENTER
                    && key != KeyEvent.KEYCODE_NUMPAD_ENTER) {
                if (action == KeyEvent.ACTION_DOWN) pendingActionKey = -1;
                return UNHANDLED;
            }
            if (closed) return HANDLED;
            boolean actionKey =
                    key == KeyEvent.KEYCODE_BACK
                            || key == KeyEvent.KEYCODE_DPAD_CENTER
                            || key == KeyEvent.KEYCODE_ENTER
                            || key == KeyEvent.KEYCODE_NUMPAD_ENTER;
            if (actionKey) {
                if (action == KeyEvent.ACTION_DOWN && repeat == 0) {
                    if (canceled || pendingActionKey != -1) pendingActionKey = -1;
                    else {
                        pendingActionKey = key;
                        pendingDownTime = downTime;
                    }
                } else if (action == KeyEvent.ACTION_DOWN
                        && (canceled || pendingActionKey != key || pendingDownTime != downTime)) {
                    pendingActionKey = -1;
                } else if (action == KeyEvent.ACTION_UP) {
                    boolean commit =
                            pendingActionKey == key && pendingDownTime == downTime && !canceled;
                    pendingActionKey = -1;
                    if (commit && key == KeyEvent.KEYCODE_BACK) {
                        closed = true;
                        return CANCEL;
                    }
                    if (commit && !editingTime && canConfirm()) {
                        closed = true;
                        return CONFIRM;
                    }
                }
            } else if (action == KeyEvent.ACTION_DOWN) {
                pendingActionKey = -1;
                if (frozen && !canceled) {
                    if (key == KeyEvent.KEYCODE_DPAD_DOWN) editingTime = true;
                    else if (key == KeyEvent.KEYCODE_DPAD_UP) editingTime = false;
                    else if (editingTime)
                        adjust(key == KeyEvent.KEYCODE_DPAD_LEFT ? -10000 : 10000);
                    else if (repeat == 0) intro = key == KeyEvent.KEYCODE_DPAD_LEFT;
                }
            }
            return HANDLED;
        }
    }

    private final Listener listener;
    final State state = new State();
    private final TextView status;
    private final TextView choices;
    private final TextView hint;
    private final ProgressBar progress;
    private String scopeNote = "";

    TvV17MarkerOverlay(MainActivity a, Listener listener) {
        super(a);
        if (listener == null) throw new IllegalArgumentException("listener");
        this.listener = listener;
        setTag("tv-v17-marker");
        UiCompat.setBackground(this, UiCompat.createFocusSafeColorBackground(Color.TRANSPARENT));
        UiCompat.setDefaultFocusHighlightEnabled(this, false);
        setFocusable(true);
        setFocusableInTouchMode(true);
        LinearLayout card = a.vertical();
        card.setPadding(a.dp(22), a.dp(12), a.dp(22), a.dp(12));
        card.setBackground(TvV17Surface.rounded(0xe61b2528, a.dp(25), 0x33ffffff, a.dp(1)));
        FrameLayout.LayoutParams lp =
                new FrameLayout.LayoutParams(-2, -2, Gravity.RIGHT | Gravity.BOTTOM);
        lp.setMargins(a.dp(32), 0, a.dp(48), a.dp(78));
        addView(card, lp);
        status = a.text("正在暂停…", 15, TvV17Theme.MUTED);
        card.addView(status);
        choices = a.text("片头结束     片尾开始", 20, TvV17Theme.TEXT);
        choices.setTypeface(null, Typeface.BOLD);
        LinearLayout.LayoutParams choiceLp = new LinearLayout.LayoutParams(-2, -2);
        choiceLp.topMargin = a.dp(6);
        card.addView(choices, choiceLp);
        progress = new ProgressBar(a, null, android.R.attr.progressBarStyleHorizontal);
        progress.setMax(1000);
        progress.setFocusable(false);
        LinearLayout.LayoutParams progressLp = new LinearLayout.LayoutParams(a.dp(340), a.dp(8));
        progressLp.topMargin = a.dp(10);
        card.addView(progress, progressLp);
        hint = a.text("← → 选择    ↓ 调整时间    OK 记录    返回 取消", 12, TvV17Theme.MUTED);
        LinearLayout.LayoutParams hintLp = new LinearLayout.LayoutParams(-2, -2);
        hintLp.topMargin = a.dp(8);
        card.addView(hint, hintLp);
    }

    /** Call once after the host has paused and observed the frozen player position. */
    void frozen(long positionMs, long durationMs) {
        if (state.freeze(positionMs, durationMs)) render();
    }

    /** The host routes keys only while this overlay owns input, before global playback handlers. */
    boolean handleKey(KeyEvent event) {
        long before = state.selectedTimeMs;
        int result =
                state.key(
                        event.getKeyCode(),
                        event.getAction(),
                        event.getRepeatCount(),
                        event.isCanceled(),
                        event.getDownTime());
        if (result == State.UNHANDLED) return false;
        if (before != state.selectedTimeMs) listener.preview(state.selectedTimeMs);
        if (result == State.CONFIRM)
            listener.confirm(state.intro, state.selectedTimeMs, state.durationMs);
        else if (result == State.CANCEL) listener.cancel();
        else if (state.frozen && !state.closed) render();
        return true;
    }

    void failed(String message) {
        state.closed = false;
        state.pendingActionKey = -1;
        render();
        status.setText(message + " · 保持暂停，可重试或返回");
    }

    void scopeLabel(boolean persistent) {
        scopeNote = persistent ? " · 本集本线路，仅存本机" : " · 仅当前会话";
        setContentDescription(scopeNote);
        render();
    }

    private void render() {
        String time =
                PlaybackController.formatTime(
                        (int) Math.min(Integer.MAX_VALUE, state.selectedTimeMs));
        status.setText("已暂停  " + time + scopeNote);
        choices.setText(
                (state.intro ? "● " : "○ ") + "片头结束     " + (!state.intro ? "● " : "○ ") + "片尾开始");
        int percent =
                state.durationMs > 0
                        ? (int)
                                Math.max(
                                        0,
                                        Math.min(
                                                1000,
                                                1000.0 * state.selectedTimeMs / state.durationMs))
                        : 0;
        progress.setProgress(percent);
        progress.setContentDescription("标记时间 " + time);
        if (state.editingTime) hint.setText("← → 调整 10 秒    ↑ 返回选择    返回 取消");
        else if (state.durationMs <= 0)
            hint.setText("时长未知，仅记录节点，不能自动跳片尾    ↓ 调整    OK 记录    返回 取消");
        else hint.setText("← → 选择    ↓ 调整时间    OK 记录    返回 取消");
        if (!state.canConfirm() && state.durationMs > 0) {
            hint.setText("请选择片内时间    ↓ 调整时间    返回 取消");
        }
    }
}
