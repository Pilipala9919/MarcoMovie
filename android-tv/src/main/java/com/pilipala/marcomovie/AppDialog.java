package com.pilipala.marcomovie;

import android.app.Dialog;
import android.content.DialogInterface;
import android.graphics.Canvas;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.*;
import android.widget.*;
import java.util.*;

/** Shared app-owned dialog chrome for lists, confirmations, text and forms. */
final class AppDialog extends Dialog {
    final MainActivity a;
    final Map<Integer, Button> actions = new HashMap<>();
    final View anchor;
    final Builder spec;

    AppDialog(Builder b) {
        super(b.a);
        a = b.a;
        spec = b;
        anchor = a.getCurrentFocus();
        requestWindowFeature(Window.FEATURE_NO_TITLE);
    }

    Button getButton(int which) {
        return actions.get(which);
    }

    private boolean useLiquidGlassButtons() {
        return a.isTvDevice()
                && (a.prefs == null || !a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false));
    }

    private GradientDrawable liquidButtonBg(boolean focused) {
        GradientDrawable d =
                new GradientDrawable(
                        GradientDrawable.Orientation.TOP_BOTTOM,
                        focused
                                ? new int[] {0xf8ffffff, 0xe8ebf2fc}
                                : new int[] {0x38ffffff, 0x1effffff});
        d.setCornerRadius(a.dp(18));
        d.setStroke(Math.max(1, a.dp(focused ? 1.2f : 1f)), focused ? 0xffffffff : 0x48ffffff);
        return d;
    }

    private void applyLiquidButtonState(Button button, boolean focused) {
        button.setBackground(liquidButtonBg(focused));
        button.setTextColor(focused ? MainActivity.DARK : MainActivity.WHITE);
        float targetScale = focused ? (a.reduced ? 1.0f : 1.025f) : 1.0f;
        button.animate().cancel();
        if (a.reduced || !button.isAttachedToWindow()) {
            button.setScaleX(targetScale);
            button.setScaleY(targetScale);
        } else {
            button.animate().scaleX(targetScale).scaleY(targetScale).setDuration(120).start();
        }
    }

    void style(Button button) {
        if (useLiquidGlassButtons()) {
            UiCompat.setDefaultFocusHighlightEnabled(button, false);
            applyLiquidButtonState(button, button.isFocused());
            button.setOnFocusChangeListener(
                    (v, focused) -> applyLiquidButtonState(button, focused));
            return;
        }
        button.setBackground(a.bg(0xff33333b, 18));
        button.setOnFocusChangeListener(
                (v, focused) -> {
                    FocusMotion.style(
                            a,
                            button,
                            focused,
                            0xff33333b,
                            MainActivity.WHITE,
                            18,
                            MainActivity.WHITE,
                            MainActivity.DARK,
                            false,
                            1.015f);
                });
    }

    static int resolveInitialFocusActionCode(
            int requestedButton,
            boolean hasSelectedChoice,
            boolean hasFocusableContent,
            boolean hasPositive,
            boolean hasNegative,
            boolean hasNeutral) {
        if (requestedButton == DialogInterface.BUTTON_POSITIVE && hasPositive)
            return DialogInterface.BUTTON_POSITIVE;
        if (requestedButton == DialogInterface.BUTTON_NEGATIVE && hasNegative)
            return DialogInterface.BUTTON_NEGATIVE;
        if (requestedButton == DialogInterface.BUTTON_NEUTRAL && hasNeutral)
            return DialogInterface.BUTTON_NEUTRAL;
        if (hasSelectedChoice || hasFocusableContent) return 0;
        if (hasPositive) return DialogInterface.BUTTON_POSITIVE;
        if (hasNegative) return DialogInterface.BUTTON_NEGATIVE;
        if (hasNeutral) return DialogInterface.BUTTON_NEUTRAL;
        return 0;
    }

    static int computeMaxContentHeight(int winH, int chromeH, int outerMarginY, int minH) {
        int available = Math.max(0, winH - Math.max(0, outerMarginY) - Math.max(0, chromeH));
        return Math.max(minH, available);
    }

    @Override
    public void show() {
        LinearLayout panel = a.vertical();
        panel.setTag("app-dialog");
        panel.setMinimumWidth(0);
        int padH = a.dp(a.isTvDevice() ? 22 : 20);
        int padTop = a.dp(a.isTvDevice() ? 20 : 20);
        int padBottom = a.dp(16);
        panel.setPadding(padH, padTop, padH, padBottom);
        a.glass(panel, 28);
        TextView titleView = null;
        if (spec.title != null) {
            titleView = a.text(spec.title, a.isTvDevice() ? 22 : 20, MainActivity.WHITE);
            titleView.setTypeface(null, Typeface.BOLD);
            panel.addView(titleView);
            a.gap(panel, 12);
        }
        LinearLayout content = a.vertical();
        content.setClipChildren(false);
        content.setClipToPadding(false);
        content.setPadding(a.dp(6), a.dp(4), a.dp(6), a.dp(4));
        TextView messageView = null;
        if (spec.message != null) {
            messageView = a.text(spec.message, 15, 0xffd0d0d5);
            messageView.setLineSpacing(a.dp(4), 1);
            messageView.setFocusable(false);
            content.addView(messageView);
            a.gap(content, 10);
        }
        if (spec.view != null) {
            ViewGroup.LayoutParams vlp = spec.view.getLayoutParams();
            if (vlp != null && vlp.width > 0) {
                vlp.width = ViewGroup.LayoutParams.MATCH_PARENT;
                spec.view.setLayoutParams(vlp);
            }
            content.addView(spec.view);
        }
        View selected = null;
        if (spec.labels != null)
            for (int i = 0; i < spec.labels.length; i++) {
                final int index = i;
                boolean checked = i == spec.selected;
                Button item =
                        a.button(
                                (checked ? "✓  " : "") + spec.labels[i],
                                "dialog-option:" + i,
                                () -> {
                                    dismiss();
                                    if (spec.pick != null) spec.pick.onClick(this, index);
                                });
                item.setTextSize(15);
                item.setSingleLine(!spec.wrapChoices);
                item.setEllipsize(spec.wrapChoices ? null : android.text.TextUtils.TruncateAt.END);
                if (spec.wrapChoices) item.setMaxLines(Integer.MAX_VALUE);
                LinearLayout.LayoutParams lp =
                        new LinearLayout.LayoutParams(-1, spec.wrapChoices ? -2 : a.dp(46));
                lp.bottomMargin = a.dp(6);
                content.addView(item, lp);
                if (checked || selected == null) selected = item;
            }
        int marginH = a.isTvDevice() ? a.dp(72) : a.dp(32);
        int width =
                Math.min(
                        a.dp(spec.wide ? 840 : (spec.view == null ? 520 : 660)),
                        a.windowWidth() - marginH);
        int innerWidth = Math.max(a.dp(200), width - padH * 2);

        LinearLayout footer = a.row();
        footer.setGravity(Gravity.RIGHT | Gravity.CENTER_VERTICAL);
        int totalActionChars = 0;
        for (String lbl : spec.buttons.values()) {
            if (lbl != null) totalActionChars += lbl.length();
        }
        boolean compactFooter =
                spec.buttons.size() >= 3
                        || !a.isTvDevice()
                        || (spec.buttons.size() == 2 && totalActionChars > 10);
        List<Button> orderedActions = new ArrayList<>();
        for (int code : new int[] {-3, -2, -1})
            if (spec.buttons.containsKey(code)) {
                Button button =
                        a.button(
                                spec.buttons.get(code),
                                "dialog-action:" + code,
                                () -> {
                                    dismiss();
                                    DialogInterface.OnClickListener action =
                                            spec.callbacks.get(code);
                                    if (action != null) action.onClick(this, code);
                                });
                if (button.getId() == View.NO_ID) button.setId(View.generateViewId());
                button.setSingleLine(true);
                button.setEllipsize(android.text.TextUtils.TruncateAt.END);
                button.setMinWidth(0);
                button.setMinimumWidth(0);
                button.setMaxWidth(
                        Math.max(
                                a.dp(96), innerWidth / Math.max(1, spec.buttons.size()) - a.dp(8)));
                if (compactFooter) {
                    button.setTextSize(spec.buttons.size() >= 3 ? 13f : 14f);
                    button.setPadding(a.dp(10), a.dp(6), a.dp(10), a.dp(6));
                    LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, a.dp(42), 1);
                    lp.setMargins(a.dp(4), a.dp(4), a.dp(4), a.dp(4));
                    footer.addView(button, lp);
                } else {
                    button.setTextSize(14);
                    a.addButton(footer, button);
                }
                actions.put(code, button);
                orderedActions.add(button);
            }

        int chromeHeight = padTop + padBottom;
        if (titleView != null) {
            titleView.measure(
                    View.MeasureSpec.makeMeasureSpec(innerWidth, View.MeasureSpec.AT_MOST),
                    View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED));
            chromeHeight += titleView.getMeasuredHeight() + a.dp(12);
        }
        if (footer.getChildCount() > 0) {
            footer.measure(
                    View.MeasureSpec.makeMeasureSpec(innerWidth, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED));
            chromeHeight += footer.getMeasuredHeight() + a.dp(14);
        }
        int outerMarginY = a.dp(a.isTvDevice() ? 56 : 96);
        final int maxHeight =
                computeMaxContentHeight(a.windowHeight(), chromeHeight, outerMarginY, a.dp(110));

        content.measure(
                View.MeasureSpec.makeMeasureSpec(innerWidth, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED));
        boolean contentScrollable = content.getMeasuredHeight() > maxHeight;
        if (messageView != null && (contentScrollable || orderedActions.isEmpty())) {
            messageView.setFocusable(true);
            messageView.setFocusableInTouchMode(a.isTvDevice());
        }
        ScrollView scroller = new TvScrollView(a);
        if (contentScrollable && spec.labels == null && spec.view == null) {
            ((TvScrollView) scroller).readingMode = true;
        }
        scroller.setVerticalScrollBarEnabled(false);
        scroller.addView(content, new ScrollView.LayoutParams(-1, -2));
        final FrameLayout clip =
                new FrameLayout(a) {
                    protected void dispatchDraw(Canvas c) {
                        int save = c.save();
                        c.clipRect(0, 0, getWidth(), getHeight());
                        super.dispatchDraw(c);
                        c.restoreToCount(save);
                    }
                };
        clip.setTag("scroll-viewport-clip");
        clip.setClipChildren(true);
        clip.setClipToPadding(true);
        clip.addView(scroller, new FrameLayout.LayoutParams(-1, -1));
        panel.addView(
                clip,
                new LinearLayout.LayoutParams(
                        -1, Math.min(maxHeight, Math.max(a.dp(24), content.getMeasuredHeight()))));
        content.addOnLayoutChangeListener(
                (v, l, t, r, b, ol, ot, orr, ob) -> {
                    int desired = Math.min(maxHeight, Math.max(a.dp(24), b - t));
                    ViewGroup.LayoutParams clp = clip.getLayoutParams();
                    if (clp != null && clp.height != desired) {
                        clp.height = desired;
                        clip.setLayoutParams(clp);
                    }
                });
        if (footer.getChildCount() > 0) {
            a.gap(panel, 12);
            panel.addView(footer, new LinearLayout.LayoutParams(-1, -2));
        }
        for (int i = 0; i < content.getChildCount(); i++)
            if (content.getChildAt(i) instanceof Button) style((Button) content.getChildAt(i));
        for (Button button : actions.values()) style(button);
        setContentView(panel);
        setOnCancelListener(spec.cancel);
        super.show();
        a.appDialog = this;
        Window w = getWindow();
        w.setBackgroundDrawableResource(android.R.color.transparent);
        w.getDecorView().setMinimumWidth(0);
        w.setLayout(width, -2);
        w.setGravity(Gravity.CENTER);
        w.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
        WindowManager.LayoutParams attrs = w.getAttributes();
        attrs.dimAmount = a.isTvDevice() ? .5f : .62f;
        w.setAttributes(attrs);
        if (a.isTvDevice()) {
            w.getDecorView().setSystemUiVisibility(5894);
            w.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN);
            ArrayList<View> focusableContent = new ArrayList<>();
            content.addFocusables(focusableContent, View.FOCUS_FORWARD);
            boolean hasFocusableContent = !focusableContent.isEmpty();
            if (!orderedActions.isEmpty()) {
                for (int i = 0; i < orderedActions.size(); i++) {
                    Button cur = orderedActions.get(i);
                    Button left = i > 0 ? orderedActions.get(i - 1) : cur;
                    Button right = i + 1 < orderedActions.size() ? orderedActions.get(i + 1) : cur;
                    cur.setNextFocusLeftId(left.getId());
                    cur.setNextFocusRightId(right.getId());
                    cur.setNextFocusDownId(cur.getId());
                    if (!hasFocusableContent) {
                        cur.setNextFocusUpId(cur.getId());
                    }
                }
            }
            int actionCode =
                    resolveInitialFocusActionCode(
                            spec.defaultFocusButton,
                            selected != null,
                            hasFocusableContent,
                            actions.containsKey(DialogInterface.BUTTON_POSITIVE),
                            actions.containsKey(DialogInterface.BUTTON_NEGATIVE),
                            actions.containsKey(DialogInterface.BUTTON_NEUTRAL));
            View first = actionCode != 0 ? actions.get(actionCode) : null;
            if (first == null) first = selected;
            if (first == null && hasFocusableContent) first = focusableContent.get(0);
            if (first == null) first = actions.get(DialogInterface.BUTTON_POSITIVE);
            if (first == null && !orderedActions.isEmpty()) first = orderedActions.get(0);
            if (first != null) {
                first.requestFocus();
                if (first instanceof Button && useLiquidGlassButtons()) {
                    applyLiquidButtonState((Button) first, true);
                }
            }
        } else {
            w.setSoftInputMode(
                    WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
                            | WindowManager.LayoutParams.SOFT_INPUT_STATE_HIDDEN);
        }
        if (!a.reduced) {
            panel.setAlpha(0.02f);
            panel.setScaleX(.96f);
            panel.setScaleY(.96f);
            panel.animate()
                    .alpha(1f)
                    .scaleX(1f)
                    .scaleY(1f)
                    .setDuration(160)
                    .withEndAction(() -> com.pilipala.glass.GlassworkSurface.forceRecapture(panel))
                    .start();
        } else {
            panel.post(() -> com.pilipala.glass.GlassworkSurface.forceRecapture(panel));
        }
    }

    @Override
    public void dismiss() {
        super.dismiss();
        if (a.appDialog == this) a.appDialog = null;
        if (anchor != null && anchor.isAttachedToWindow()) anchor.requestFocus();
    }

    static final class Builder {
        final MainActivity a;
        boolean wrapChoices;
        boolean wide;
        String title, message;
        String[] labels;
        int selected = -1;
        int defaultFocusButton;
        View view;
        DialogInterface.OnClickListener pick;
        DialogInterface.OnCancelListener cancel;
        final Map<Integer, String> buttons = new HashMap<>();
        final Map<Integer, DialogInterface.OnClickListener> callbacks = new HashMap<>();

        Builder(MainActivity activity) {
            a = activity;
        }

        Builder setTitle(String value) {
            title = value;
            return this;
        }

        Builder setMessage(String value) {
            message = value;
            return this;
        }

        Builder setView(View value) {
            view = value;
            return this;
        }

        Builder wrapChoices() {
            wrapChoices = true;
            return this;
        }

        Builder setWide(boolean value) {
            wide = value;
            return this;
        }

        Builder setItems(String[] values, DialogInterface.OnClickListener action) {
            labels = values;
            pick = action;
            return this;
        }

        Builder setSingleChoiceItems(
                String[] values, int checked, DialogInterface.OnClickListener action) {
            selected = checked;
            return setItems(values, action);
        }

        Builder button(int code, String value, DialogInterface.OnClickListener action) {
            buttons.put(code, value);
            callbacks.put(code, action);
            return this;
        }

        Builder setPositiveButton(String value, DialogInterface.OnClickListener action) {
            return button(-1, value, action);
        }

        Builder setNegativeButton(String value, DialogInterface.OnClickListener action) {
            return button(-2, value, action);
        }

        Builder setNeutralButton(String value, DialogInterface.OnClickListener action) {
            return button(-3, value, action);
        }

        Builder setDefaultFocusButton(int which) {
            defaultFocusButton = which;
            return this;
        }

        Builder setOnCancelListener(DialogInterface.OnCancelListener action) {
            cancel = action;
            return this;
        }

        AppDialog create() {
            return new AppDialog(this);
        }

        AppDialog show() {
            AppDialog dialog = create();
            dialog.show();
            return dialog;
        }
    }
}
