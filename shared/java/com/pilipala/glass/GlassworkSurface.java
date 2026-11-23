package com.pilipala.glass;

import android.graphics.Bitmap;
import android.graphics.BitmapShader;
import android.graphics.Canvas;
import android.graphics.ColorFilter;
import android.graphics.LinearGradient;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.PixelFormat;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.drawable.Drawable;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewParent;
import android.view.ViewTreeObserver;
import java.lang.ref.WeakReference;
import java.util.ArrayList;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/** Bounded backdrop capture for API 14+. Unreadable video/hardware surfaces use the tint fallback. */
public final class GlassworkSurface extends Drawable
        implements View.OnAttachStateChangeListener,
                ViewTreeObserver.OnScrollChangedListener,
                ViewTreeObserver.OnGlobalLayoutListener {
    public interface Options {
        boolean reduceTransparency();
    }

    /** Implemented by a native video view; older clients need no PixelCopy API reference. */
    public interface FrameSource {
        void prepareGlassFrame(Runnable ready);

        boolean glassFrameAdvancing();
    }

    public static boolean isCapturingBackdrop() {
        return Boolean.TRUE.equals(CAPTURING.get());
    }

    private static final ThreadLocal<Boolean> CAPTURING = new ThreadLocal<Boolean>();
    private static final ArrayList<WeakReference<GlassworkSurface>> SURFACES = new ArrayList<>();
    private static final ThreadPoolExecutor WORK =
            new ThreadPoolExecutor(0, 1, 15, TimeUnit.SECONDS, new ArrayBlockingQueue<Runnable>(4));

    private static final class MainHolder {
        static final Handler INSTANCE = new Handler(Looper.getMainLooper());
    }

    private static Handler mainHandler() {
        return MainHolder.INSTANCE;
    }

    private final View target;
    private final View backdrop;
    private final Options options;
    private final float radius;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
    private final RectF rect = new RectF(), srcRect = new RectF();
    private final Matrix shaderMatrix = new Matrix();
    private final int[] screen = new int[2], base = new int[2];
    private Bitmap material, shaderBitmap;
    private BitmapShader materialShader;
    private LinearGradient bevelShader;
    private float bevelTop = Float.NaN, bevelBottom = Float.NaN;
    private ViewTreeObserver observer;
    private ViewTreeObserver targetObserver;
    private boolean attached, pending, dirty = true, scheduled;
    private int generation,
            retryCount,
            opacity = 255,
            lastW = -1,
            lastH = -1,
            lastL = Integer.MIN_VALUE,
            lastT = Integer.MIN_VALUE;
    private long lastCapture;
    private final Runnable refresh =
            new Runnable() {
                public void run() {
                    scheduled = false;
                    capture();
                }
            };

    private GlassworkSurface(View target, View backdrop, float radius, Options options) {
        this.target = target;
        this.backdrop = backdrop;
        this.radius = radius;
        this.options = options;
    }

    @SuppressWarnings("deprecation")
    public static void attach(View target, View backdrop, float radius, Options options) {
        if (target == null || backdrop == null) return;
        if (target.getBackground() instanceof GlassworkSurface) {
            GlassworkSurface old = (GlassworkSurface) target.getBackground();
            old.onViewDetachedFromWindow(target);
            target.removeOnAttachStateChangeListener(old);
        }
        int l = target.getPaddingLeft(), t = target.getPaddingTop();
        int r = target.getPaddingRight(), b = target.getPaddingBottom();
        GlassworkSurface surface = new GlassworkSurface(target, backdrop, radius, options);
        target.setBackgroundDrawable(surface);
        target.setPadding(l, t, r, b);
        target.addOnAttachStateChangeListener(surface);
        if (target.getWindowToken() != null) surface.onViewAttachedToWindow(target);
    }

    /** Call when an asynchronously loaded image or ambient background changes. UI thread only. */
    public static void invalidateBackdrop(View root) {
        for (int i = SURFACES.size() - 1; i >= 0; i--) {
            GlassworkSurface s = SURFACES.get(i).get();
            if (s == null || !s.attached) SURFACES.remove(i);
            else if (root == s.backdrop || root.getRootView() == s.backdrop.getRootView())
                s.backdropChanged();
        }
    }

    /** Forces an immediate recapture for a specific glass view (e.g. after dialog entrance). */
    public static void forceRecapture(View target) {
        if (target != null && target.getBackground() instanceof GlassworkSurface) {
            GlassworkSurface surface = (GlassworkSurface) target.getBackground();
            surface.retryCount = 0;
            surface.dirty = true;
            surface.lastCapture = 0;
            surface.changed();
        }
    }

    /** Pure-JVM helper determining whether capture should retry instead of abandoning silently. */
    public static boolean shouldRetryBlockedCapture(
            boolean attached,
            boolean pending,
            boolean dirty,
            boolean reduceTransparency,
            boolean shown,
            float alpha,
            int width,
            int height,
            int retryCount) {
        if (!attached || pending || !dirty || reduceTransparency) return false;
        boolean ready = shown && alpha >= .01f && width > 0 && height > 0;
        return !ready && retryCount < 24;
    }

    public void onViewAttachedToWindow(View view) {
        if (attached) return;
        attached = true;
        retryCount = 0;
        observer = backdrop.getViewTreeObserver();
        observer.addOnScrollChangedListener(this);
        observer.addOnGlobalLayoutListener(this);
        ViewTreeObserver tvto = target.getViewTreeObserver();
        if (tvto != null && tvto != observer) {
            targetObserver = tvto;
            targetObserver.addOnGlobalLayoutListener(this);
        }
        SURFACES.add(new WeakReference<GlassworkSurface>(this));
        changed();
    }

    @SuppressWarnings("deprecation")
    public void onViewDetachedFromWindow(View view) {
        attached = false;
        generation++;
        retryCount = 0;
        pending = false;
        material = null;
        shaderBitmap = null;
        materialShader = null;
        mainHandler().removeCallbacks(refresh);
        scheduled = false;
        if (observer != null && observer.isAlive()) {
            observer.removeOnScrollChangedListener(this);
            observer.removeGlobalOnLayoutListener(this);
        }
        observer = null;
        if (targetObserver != null && targetObserver.isAlive()) {
            targetObserver.removeGlobalOnLayoutListener(this);
        }
        targetObserver = null;
        for (int i = SURFACES.size() - 1; i >= 0; i--) {
            GlassworkSurface s = SURFACES.get(i).get();
            if (s == null || s == this) SURFACES.remove(i);
        }
    }

    public void onScrollChanged() {
        dirty = true;
        if (!attached || options.reduceTransparency()) return;
        mainHandler().removeCallbacks(refresh);
        scheduled = true;
        mainHandler().postDelayed(refresh, 180);
    }

    public void onGlobalLayout() {
        int w = target.getWidth(),
                h = target.getHeight(),
                l = target.getLeft(),
                t = target.getTop();
        if (w == lastW && h == lastH && l == lastL && t == lastT && material != null) return;
        lastW = w;
        lastH = h;
        lastL = l;
        lastT = t;
        changed();
    }

    private void changed() {
        dirty = true;
        invalidateSelf();
        schedule();
    }

    private void backdropChanged() {
        dirty = true;
        if (material == null) {
            changed();
            return;
        }
        if (!attached || options.reduceTransparency()) {
            invalidateSelf();
            return;
        }
        mainHandler().removeCallbacks(refresh);
        scheduled = true;
        mainHandler().postDelayed(refresh, 160);
    }

    private void schedule() {
        if (!attached || pending || scheduled || !dirty || options.reduceTransparency()) return;
        scheduled = true;
        mainHandler()
                .postDelayed(
                        refresh,
                        Math.max(0, 100 - (android.os.SystemClock.uptimeMillis() - lastCapture)));
    }

    private static FrameSource findFrameSource(View view) {
        if (view.getVisibility() != View.VISIBLE) return null;
        if (view instanceof FrameSource) return (FrameSource) view;
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) view;
            for (int i = 0; i < group.getChildCount(); i++) {
                FrameSource found = findFrameSource(group.getChildAt(i));
                if (found != null) return found;
            }
        }
        return null;
    }

    private void capture() {
        capture(false);
    }

    private void capture(boolean framePrepared) {
        if (!attached || pending || !dirty || options.reduceTransparency()) return;
        int w = target.getWidth(), h = target.getHeight();
        if (!target.isShown() || target.getAlpha() < .01f || w <= 0 || h <= 0) {
            if (shouldRetryBlockedCapture(
                            attached,
                            pending,
                            dirty,
                            false,
                            target.isShown(),
                            target.getAlpha(),
                            w,
                            h,
                            retryCount)
                    && !scheduled) {
                retryCount++;
                scheduled = true;
                mainHandler().postDelayed(refresh, 32);
            }
            return;
        }
        retryCount = 0;
        final FrameSource frames = findFrameSource(backdrop);
        if (!framePrepared && frames != null) {
            final int token = generation;
            pending = true;
            try {
                frames.prepareGlassFrame(
                        new Runnable() {
                            public void run() {
                                if (!attached || generation != token) return;
                                pending = false;
                                capture(true);
                            }
                        });
            } catch (RuntimeException unavailable) {
                pending = false;
                capture(true);
            }
            return;
        }
        double scale =
                Math.min(
                        1, Math.min(384.0 / Math.max(w, h), Math.sqrt(24576.0 / ((double) w * h))));
        final int width = Math.max(1, (int) (w * scale)), height = Math.max(1, (int) (h * scale));
        final float sx = (float) width / w;
        Bitmap scene = null;
        try {
            scene = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
            Canvas canvas = new Canvas(scene);
            canvas.drawColor(GlassworkMaterial.DARK_TINT);
            target.getLocationOnScreen(screen);
            backdrop.getLocationOnScreen(base);
            canvas.scale(sx, (float) height / h);
            canvas.translate(base[0] - screen[0], base[1] - screen[1]);
            CAPTURING.set(Boolean.TRUE);
            drawBehind(canvas, backdrop, target);
            final int[] pixels = new int[width * height];
            scene.getPixels(pixels, 0, width, 0, 0, width, height);
            final int token = generation;
            final float density = target.getResources().getDisplayMetrics().density * sx;
            pending = true;
            dirty = false;
            lastCapture = android.os.SystemClock.uptimeMillis();
            WORK.execute(
                    new Runnable() {
                        public void run() {
                            Bitmap result = null;
                            try {
                                int[] rendered =
                                        GlassworkMaterial.render(
                                                pixels, width, height, radius * sx, density, true);
                                result =
                                        Bitmap.createBitmap(
                                                rendered, width, height, Bitmap.Config.ARGB_8888);
                            } catch (RuntimeException ignored) {
                                // An unreadable/unsupported backdrop keeps the material fallback.
                            }
                            final Bitmap ready = result;
                            mainHandler()
                                    .post(
                                            new Runnable() {
                                                public void run() {
                                                    if (generation != token || !attached) return;
                                                    pending = false;
                                                    material = ready;
                                                    if (frames != null
                                                            && frames.glassFrameAdvancing())
                                                        dirty = true;
                                                    invalidateSelf();
                                                    schedule();
                                                }
                                            });
                        }
                    });
        } catch (RejectedExecutionException busy) {
            pending = false;
            dirty = true;
            lastCapture = android.os.SystemClock.uptimeMillis();
            schedule();
        } catch (RuntimeException ignored) {
            pending = false;
            dirty = false;
            material = null;
        } finally {
            CAPTURING.remove();
            if (scene != null) scene.recycle();
        }
    }

    private static boolean contains(View parent, View child) {
        for (View at = child; at != null; ) {
            if (at == parent) return true;
            ViewParent p = at.getParent();
            at = p instanceof View ? (View) p : null;
        }
        return false;
    }

    /** Ancestor backgrounds and earlier siblings only: never rasterize the target's text into glass. */
    private static void drawBehind(Canvas canvas, View view, View stop) {
        if (view == stop || view.getVisibility() != View.VISIBLE || view.getAlpha() <= 0) return;
        if (!contains(view, stop)) {
            // Other glass surfaces must not recursively capture themselves or their foreground.
            if (!(view.getBackground() instanceof GlassworkSurface)) view.draw(canvas);
            return;
        }
        Drawable bg = view.getBackground();
        if (bg != null) bg.draw(canvas);
        if (!(view instanceof ViewGroup)) return;
        ViewGroup group = (ViewGroup) view;
        for (int i = 0; i < group.getChildCount(); i++) {
            View child = group.getChildAt(i);
            if (child == stop) break;
            int save = canvas.save();
            canvas.translate(
                    child.getLeft() - view.getScrollX(), child.getTop() - view.getScrollY());
            canvas.concat(child.getMatrix());
            if (child.getAlpha() < 1)
                canvas.saveLayerAlpha(
                        0,
                        0,
                        child.getWidth(),
                        child.getHeight(),
                        (int) (child.getAlpha() * 255),
                        Canvas.ALL_SAVE_FLAG);
            drawBehind(canvas, child, stop);
            canvas.restoreToCount(save);
            if (contains(child, stop)) break;
        }
    }

    @Override
    public void draw(Canvas canvas) {
        if (Boolean.TRUE.equals(CAPTURING.get())) return;
        rect.set(getBounds());
        if (rect.width() <= 0 || rect.height() <= 0) return;
        float corner = Math.min(radius, Math.min(rect.width(), rect.height()) / 2);
        paint.setStyle(Paint.Style.FILL);
        if (!options.reduceTransparency() && material != null && !material.isRecycled()) {
            if (shaderBitmap != material || materialShader == null) {
                shaderBitmap = material;
                materialShader =
                        new BitmapShader(material, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP);
            }
            srcRect.set(0, 0, material.getWidth(), material.getHeight());
            shaderMatrix.setRectToRect(srcRect, rect, Matrix.ScaleToFit.FILL);
            materialShader.setLocalMatrix(shaderMatrix);
            paint.setShader(materialShader);
            paint.setAlpha(opacity);
            canvas.drawRoundRect(rect, corner, corner, paint);
            paint.setShader(null);
        } else {
            paint.setShader(null);
            paint.setColor(GlassworkMaterial.DARK_TINT);
            paint.setAlpha(opacity);
            canvas.drawRoundRect(rect, corner, corner, paint);
        }
        float px = target.getResources().getDisplayMetrics().density;
        if (bevelShader == null || bevelTop != rect.top || bevelBottom != rect.bottom) {
            bevelTop = rect.top;
            bevelBottom = rect.bottom;
            bevelShader =
                    new LinearGradient(
                            0,
                            rect.top,
                            0,
                            rect.bottom,
                            new int[] {0x75ffffff, 0x12ffffff, 0x2effffff},
                            new float[] {0, .45f, 1},
                            Shader.TileMode.CLAMP);
        }
        // Glasswork's narrow white upper bevel and darker lower edge; preserve original radius.
        paint.setShader(bevelShader);
        paint.setAlpha(opacity);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(Math.max(1, px));
        rect.inset(px / 2, px / 2);
        canvas.drawRoundRect(
                rect, Math.max(0, corner - px / 2), Math.max(0, corner - px / 2), paint);
        paint.setShader(null);
        schedule();
    }

    @Override
    public void setAlpha(int alpha) {
        opacity = alpha;
        invalidateSelf();
    }

    @Override
    public void setColorFilter(ColorFilter filter) {
        paint.setColorFilter(filter);
        invalidateSelf();
    }

    @Override
    public int getOpacity() {
        return PixelFormat.TRANSLUCENT;
    }
}
