package com.pilipala.marcomovie.hud;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.os.SystemClock;
import android.text.TextPaint;
import android.text.TextUtils;
import android.view.KeyEvent;
import android.view.View;

/**
 * TV playback long-press (3s) DPAD_UP / DPAD_DOWN episode switch overlay.
 *
 * <p>Short presses (&lt; {@link Controller#HOLD_SHOW_DELAY_MS}) fall back seamlessly to the
 * original DPAD_UP / DPAD_DOWN action. Holding for 3 seconds renders a centered circular countdown
 * ring with a continuously rotating orbital arc and 3-2-1 countdown before switching episodes.
 * Zero per-frame allocations and zero {@code Canvas.saveLayer} calls for API 23+ GPU safety.
 */
public final class EpisodeHoldSwitchOverlay extends View {
    public interface Listener {
        void onCommit(int direction);
    }

    /** Pure-JVM testable state machine for 3-second hold-to-switch episode gestures. */
    public static final class Controller {
        public static final int KEYCODE_DPAD_UP = 19;
        public static final int KEYCODE_DPAD_DOWN = 20;

        public static final int DIR_PREV = -1;
        public static final int DIR_NEXT = 1;

        public static final long HOLD_SHOW_DELAY_MS = 320L;
        public static final long HOLD_DURATION_MS = 3000L;

        public static final int STATE_IDLE = 0;
        public static final int STATE_ARMED = 1;
        public static final int STATE_HOLDING = 2;
        public static final int STATE_COMMITTED = 3;

        public static final int TICK_NONE = 0;
        public static final int TICK_SHOWING = 1;
        public static final int TICK_COMMIT = 2;

        public static final int UP_IGNORED = 0;
        public static final int UP_SHORT_PRESS = 1;
        public static final int UP_CANCELLED = 2;
        public static final int UP_ALREADY_COMMITTED = 3;

        private int state = STATE_IDLE;
        private int keyCode;
        private int direction;
        private long downTimeMs;
        private long startUptimeMs;
        private long elapsedMs;
        private boolean hasTarget;
        private String targetLabel = "";

        public static int directionForKeyCode(int keyCode) {
            if (keyCode == KEYCODE_DPAD_UP) return DIR_PREV;
            if (keyCode == KEYCODE_DPAD_DOWN) return DIR_NEXT;
            return 0;
        }

        public boolean begin(
                int keyCode,
                long downTimeMs,
                long nowUptimeMs,
                boolean hasTarget,
                String targetLabel) {
            int dir = directionForKeyCode(keyCode);
            if (dir == 0) return false;
            this.state = STATE_ARMED;
            this.keyCode = keyCode;
            this.direction = dir;
            this.downTimeMs = downTimeMs;
            this.startUptimeMs = nowUptimeMs;
            this.elapsedMs = 0L;
            this.hasTarget = hasTarget;
            this.targetLabel = targetLabel == null ? "" : targetLabel.trim();
            return true;
        }

        public int onTick(long nowUptimeMs) {
            if (state != STATE_ARMED && state != STATE_HOLDING) {
                return TICK_NONE;
            }
            elapsedMs = Math.max(0L, nowUptimeMs - startUptimeMs);
            if (elapsedMs >= HOLD_DURATION_MS) {
                elapsedMs = HOLD_DURATION_MS;
                state = STATE_COMMITTED;
                return TICK_COMMIT;
            }
            if (elapsedMs >= HOLD_SHOW_DELAY_MS) {
                state = STATE_HOLDING;
                return TICK_SHOWING;
            }
            return TICK_NONE;
        }

        public int onKeyUp(int keyCode, boolean canceled, long nowUptimeMs) {
            if (state == STATE_IDLE || this.keyCode != keyCode) {
                return UP_IGNORED;
            }
            int prevState = state;
            if (prevState == STATE_COMMITTED) {
                cancel();
                return UP_ALREADY_COMMITTED;
            }
            long held = Math.max(0L, nowUptimeMs - startUptimeMs);
            cancel();
            if (!canceled && prevState == STATE_ARMED && held < HOLD_SHOW_DELAY_MS) {
                return UP_SHORT_PRESS;
            }
            return UP_CANCELLED;
        }

        public void cancel() {
            state = STATE_IDLE;
            keyCode = 0;
            direction = 0;
            downTimeMs = 0L;
            startUptimeMs = 0L;
            elapsedMs = 0L;
            hasTarget = false;
            targetLabel = "";
        }

        public int getState() {
            return state;
        }

        public boolean isTracking() {
            return state != STATE_IDLE;
        }

        public boolean isTrackingKey(int keyCode) {
            return state != STATE_IDLE && this.keyCode == keyCode;
        }

        public boolean isOverlayVisible() {
            return state == STATE_HOLDING;
        }

        public int getDirection() {
            return direction;
        }

        public long getDownTimeMs() {
            return downTimeMs;
        }

        public long getElapsedMs() {
            return elapsedMs;
        }

        public boolean hasTarget() {
            return hasTarget;
        }

        public String getTargetLabel() {
            return targetLabel;
        }

        /** Countdown seconds remaining: 3 -> 2 -> 1 during the 3-second hold. */
        public int countdownSeconds() {
            long rem = Math.max(0L, HOLD_DURATION_MS - elapsedMs);
            if (rem <= 0L) return 0;
            int sec = (int) ((rem + 999L) / 1000L);
            return Math.max(1, Math.min(3, sec));
        }

        /** Smooth progress fraction [0..1] across the 3-second hold duration. */
        public float progressFraction() {
            return Math.max(0f, Math.min(1f, elapsedMs / (float) HOLD_DURATION_MS));
        }
    }

    private static final float SPIN_PERIOD_MS = 1050f;

    private final Controller controller = new Controller();
    private final float density;
    private final Listener listener;
    private boolean reducedMotion;

    private final Paint cardPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint borderPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint innerCirclePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint trackPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint progressPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint spinnerPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint orbPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint orbHaloPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final TextPaint countdownPaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
    private final TextPaint titlePaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
    private final TextPaint subPaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
    private final TextPaint arrowPaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);

    private final RectF cardRect = new RectF();
    private final RectF ringRect = new RectF();
    private final RectF outerSpinRect = new RectF();

    private String cachedSubInput = "";
    private String cachedSubEllipsized = "";
    private float cachedSubMaxWidth = -1f;

    private final Runnable frameLoop =
            new Runnable() {
                @Override
                public void run() {
                    if (!controller.isTracking()) {
                        setVisibility(View.GONE);
                        return;
                    }
                    int tick = controller.onTick(SystemClock.uptimeMillis());
                    if (tick == Controller.TICK_COMMIT) {
                        int dir = controller.getDirection();
                        setVisibility(View.GONE);
                        if (listener != null) {
                            listener.onCommit(dir);
                        }
                        return;
                    }
                    if (tick == Controller.TICK_SHOWING) {
                        if (getVisibility() != View.VISIBLE) {
                            setVisibility(View.VISIBLE);
                        }
                        invalidate();
                    }
                    postOnAnimation(this);
                }
            };

    public EpisodeHoldSwitchOverlay(Context context, Listener listener) {
        super(context);
        this.listener = listener;
        this.density =
                context != null && context.getResources() != null
                        ? context.getResources().getDisplayMetrics().density
                        : 1f;
        setTag("player-episode-hold-switch");
        setFocusable(false);
        setClickable(false);
        setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        setVisibility(View.GONE);

        cardPaint.setStyle(Paint.Style.FILL);
        cardPaint.setColor(0xe6121620);

        borderPaint.setStyle(Paint.Style.STROKE);
        borderPaint.setStrokeWidth(Math.max(1f, dp(1.1f)));
        borderPaint.setColor(0x40ffffff);

        innerCirclePaint.setStyle(Paint.Style.FILL);
        innerCirclePaint.setColor(0x78090c12);

        trackPaint.setStyle(Paint.Style.STROKE);
        trackPaint.setStrokeWidth(dp(4.8f));
        trackPaint.setColor(0x2effffff);

        progressPaint.setStyle(Paint.Style.STROKE);
        progressPaint.setStrokeWidth(dp(5.2f));
        progressPaint.setStrokeCap(Paint.Cap.ROUND);
        progressPaint.setColor(0xff34d399);

        spinnerPaint.setStyle(Paint.Style.STROKE);
        spinnerPaint.setStrokeWidth(dp(2.6f));
        spinnerPaint.setStrokeCap(Paint.Cap.ROUND);
        spinnerPaint.setColor(0xd87dd3fc);

        orbPaint.setStyle(Paint.Style.FILL);
        orbPaint.setColor(0xfff0fdf4);

        orbHaloPaint.setStyle(Paint.Style.FILL);
        orbHaloPaint.setColor(0x5534d399);

        countdownPaint.setColor(0xffffffff);
        countdownPaint.setTextAlign(Paint.Align.CENTER);
        countdownPaint.setTextSize(dp(34f));
        countdownPaint.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));

        titlePaint.setColor(0xfff8fafc);
        titlePaint.setTextAlign(Paint.Align.CENTER);
        titlePaint.setTextSize(dp(15f));
        titlePaint.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));

        subPaint.setColor(0xbce2e8f0);
        subPaint.setTextAlign(Paint.Align.CENTER);
        subPaint.setTextSize(dp(12f));
        subPaint.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL));

        arrowPaint.setColor(0xaa94a3b8);
        arrowPaint.setTextAlign(Paint.Align.CENTER);
        arrowPaint.setTextSize(dp(11f));
        arrowPaint.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
    }

    public static int preferredWidthPx(Context context) {
        float d =
                context != null && context.getResources() != null
                        ? context.getResources().getDisplayMetrics().density
                        : 1f;
        return Math.round(236f * d);
    }

    public static int preferredHeightPx(Context context) {
        float d =
                context != null && context.getResources() != null
                        ? context.getResources().getDisplayMetrics().density
                        : 1f;
        return Math.round(212f * d);
    }

    public void setReducedMotion(boolean reducedMotion) {
        this.reducedMotion = reducedMotion;
    }

    public boolean isTracking() {
        return controller.isTracking();
    }

    public boolean isTrackingKey(int keyCode) {
        return controller.isTrackingKey(keyCode);
    }

    public boolean beginHold(int keyCode, long downTimeMs, boolean hasTarget, String targetLabel) {
        removeCallbacks(frameLoop);
        long now = SystemClock.uptimeMillis();
        if (!controller.begin(keyCode, downTimeMs, now, hasTarget, targetLabel)) {
            return false;
        }
        cachedSubInput = "";
        cachedSubEllipsized = "";
        setVisibility(View.GONE);
        postOnAnimation(frameLoop);
        return true;
    }

    public void onKeyRepeat(int keyCode) {
        if (!controller.isTrackingKey(keyCode)) return;
        int tick = controller.onTick(SystemClock.uptimeMillis());
        if (tick == Controller.TICK_COMMIT) {
            removeCallbacks(frameLoop);
            int dir = controller.getDirection();
            setVisibility(View.GONE);
            if (listener != null) {
                listener.onCommit(dir);
            }
        } else if (tick == Controller.TICK_SHOWING) {
            if (getVisibility() != View.VISIBLE) {
                setVisibility(View.VISIBLE);
            }
            invalidate();
        }
    }

    public int handleKeyUp(int keyCode, boolean canceled) {
        int result = controller.onKeyUp(keyCode, canceled, SystemClock.uptimeMillis());
        if (result != Controller.UP_IGNORED) {
            removeCallbacks(frameLoop);
            setVisibility(View.GONE);
        }
        return result;
    }

    public void cancel() {
        removeCallbacks(frameLoop);
        controller.cancel();
        if (getVisibility() != View.GONE) {
            setVisibility(View.GONE);
        }
    }

    @Override
    protected void onDetachedFromWindow() {
        removeCallbacks(frameLoop);
        controller.cancel();
        super.onDetachedFromWindow();
    }

    @Override
    protected void onDraw(Canvas canvas) {
        if (!controller.isOverlayVisible()) return;
        int w = getWidth();
        int h = getHeight();
        if (w <= 0 || h <= 0) return;

        float inset = dp(1f);
        cardRect.set(inset, inset, w - inset, h - inset);
        float radius = dp(24f);
        canvas.drawRoundRect(cardRect, radius, radius, cardPaint);
        canvas.drawRoundRect(cardRect, radius, radius, borderPaint);

        boolean hasTarget = controller.hasTarget();
        int accent = hasTarget ? 0xff34d399 : 0xfff59e0b;
        int spinAccent = hasTarget ? 0xe07dd3fc : 0xd8fde68a;
        int haloAccent = hasTarget ? 0x5534d399 : 0x55f59e0b;
        progressPaint.setColor(accent);
        spinnerPaint.setColor(spinAccent);
        orbHaloPaint.setColor(haloAccent);

        float cx = w * 0.5f;
        float cy = dp(78f);
        float ringRadius = dp(44f);
        float outerSpinRadius = ringRadius + dp(8f);

        // Direction chevron above ring
        String arrow = controller.getDirection() < 0 ? "▲" : "▼";
        canvas.drawText(arrow, cx, dp(19f), arrowPaint);

        // Inner medallion + circular track
        canvas.drawCircle(cx, cy, ringRadius - dp(2.5f), innerCirclePaint);
        ringRect.set(cx - ringRadius, cy - ringRadius, cx + ringRadius, cy + ringRadius);
        canvas.drawArc(ringRect, 0f, 360f, false, trackPaint);

        // 3-second countdown progress sweep arc
        float progress = controller.progressFraction();
        float sweepAngle = 360f * progress;
        if (sweepAngle > 0.5f) {
            canvas.drawArc(ringRect, -90f, sweepAngle, false, progressPaint);
        }

        // Continuously spinning outer orbital ring + leading glowing dot
        outerSpinRect.set(
                cx - outerSpinRadius,
                cy - outerSpinRadius,
                cx + outerSpinRadius,
                cy + outerSpinRadius);
        float spinAngle =
                reducedMotion
                        ? (-90f + sweepAngle)
                        : (((controller.getElapsedMs() % (long) SPIN_PERIOD_MS) / SPIN_PERIOD_MS)
                                        * 360f
                                - 90f);
        canvas.drawArc(outerSpinRect, spinAngle, 86f, false, spinnerPaint);

        double tipRad = Math.toRadians(spinAngle + 86f);
        float tipX = cx + (float) Math.cos(tipRad) * outerSpinRadius;
        float tipY = cy + (float) Math.sin(tipRad) * outerSpinRadius;
        canvas.drawCircle(tipX, tipY, dp(5.2f), orbHaloPaint);
        canvas.drawCircle(tipX, tipY, dp(2.7f), orbPaint);

        // Center 3 -> 2 -> 1 countdown numeral
        int sec = controller.countdownSeconds();
        String secText = sec > 0 ? String.valueOf(sec) : "1";
        Paint.FontMetrics fm = countdownPaint.getFontMetrics();
        float textBaseline = cy - (fm.ascent + fm.descent) * 0.5f;
        canvas.drawText(secText, cx, textBaseline, countdownPaint);

        // Primary title + target episode subtitle
        String title;
        if (!hasTarget) {
            title = controller.getDirection() < 0 ? "已是第一集" : "已是最后一集";
        } else {
            title = controller.getDirection() < 0 ? "切换上一集" : "切换下一集";
        }
        titlePaint.setColor(hasTarget ? 0xfff8fafc : 0xfffde68a);
        canvas.drawText(title, cx, dp(164f), titlePaint);

        String target = controller.getTargetLabel();
        String subRaw;
        if (!hasTarget) {
            subRaw = "松开返回播放";
        } else if (!target.isEmpty()) {
            subRaw = target + " · 松开取消";
        } else {
            subRaw = "继续按住切换 · 松开取消";
        }
        float maxSubWidth = w - dp(28f);
        if (!subRaw.equals(cachedSubInput) || Math.abs(maxSubWidth - cachedSubMaxWidth) > 0.5f) {
            cachedSubInput = subRaw;
            cachedSubMaxWidth = maxSubWidth;
            cachedSubEllipsized =
                    TextUtils.ellipsize(subRaw, subPaint, maxSubWidth, TextUtils.TruncateAt.END)
                            .toString();
        }
        canvas.drawText(cachedSubEllipsized, cx, dp(188f), subPaint);
    }

    private float dp(float v) {
        return v * density;
    }

    public static boolean isEpisodeHoldKey(int keyCode) {
        return keyCode == KeyEvent.KEYCODE_DPAD_UP || keyCode == KeyEvent.KEYCODE_DPAD_DOWN;
    }
}
