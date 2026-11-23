"""Compile real Android Java sources and run Wave 2 Android wiring regression checks."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from android_compile_support import SUFFIX, compile_real_android_sources, ensure_android_jar, resolve_jdk_bin

ROOT = Path(__file__).resolve().parents[2]
JDK = resolve_jdk_bin()

EXTRA_RUNTIME_STUBS = {
    "android/os/Build.java": """package android.os;

public class Build {
    public static class VERSION {
        public static int SDK_INT = 34;
    }
}
""",
    "android/os/IBinder.java": """package android.os;

public interface IBinder {}
""",
    "android/os/Looper.java": """package android.os;

public class Looper {
    private static final Looper MAIN = new Looper();

    public static Looper getMainLooper() {
        return MAIN;
    }
}
""",
    "android/os/SystemClock.java": """package android.os;

public class SystemClock {
    private static long fakeUptimeMs = 1000L;

    public static void advanceUptimeMs(long deltaMs) {
        fakeUptimeMs += deltaMs;
    }

    public static long uptimeMillis() {
        return fakeUptimeMs;
    }

    public static long elapsedRealtime() {
        return fakeUptimeMs;
    }

    public static long elapsedRealtimeNanos() {
        return fakeUptimeMs * 1_000_000L;
    }
}
""",
    "android/os/Handler.java": """package android.os;

import java.util.ArrayList;
import java.util.List;

public class Handler {
    private static final List<Runnable> QUEUE = new ArrayList<>();

    public Handler() {}

    public Handler(Looper looper) {}

    public boolean post(Runnable r) {
        if (r == null) return false;
        synchronized (QUEUE) {
            QUEUE.add(r);
        }
        return true;
    }

    public boolean postDelayed(Runnable r, long delayMillis) {
        return post(r);
    }

    public void removeCallbacks(Runnable r) {
        if (r == null) return;
        synchronized (QUEUE) {
            while (QUEUE.remove(r)) {}
        }
    }

    public static void clearPending() {
        synchronized (QUEUE) {
            QUEUE.clear();
        }
    }

    public static int flushPending() {
        int executed = 0;
        while (true) {
            List<Runnable> batch;
            synchronized (QUEUE) {
                if (QUEUE.isEmpty()) break;
                batch = new ArrayList<>(QUEUE);
                QUEUE.clear();
            }
            for (Runnable r : batch) {
                r.run();
                executed++;
            }
        }
        return executed;
    }
}
""",
    "android/graphics/ColorFilter.java": """package android.graphics;

public class ColorFilter {}
""",
    "android/graphics/PixelFormat.java": """package android.graphics;

public class PixelFormat {
    public static final int TRANSLUCENT = -3;
}
""",
    "android/graphics/Rect.java": """package android.graphics;

public class Rect {
    public int left;
    public int top;
    public int right;
    public int bottom;

    public Rect() {}

    public Rect(int left, int top, int right, int bottom) {
        set(left, top, right, bottom);
    }

    public Rect(Rect r) {
        if (r != null) set(r.left, r.top, r.right, r.bottom);
    }

    public void set(int left, int top, int right, int bottom) {
        this.left = left;
        this.top = top;
        this.right = right;
        this.bottom = bottom;
    }

    public void offset(int dx, int dy) {
        left += dx;
        right += dx;
        top += dy;
        bottom += dy;
    }

    public int width() {
        return right - left;
    }

    public int height() {
        return bottom - top;
    }

    public boolean isEmpty() {
        return left >= right || top >= bottom;
    }
}
""",
    "android/graphics/RectF.java": """package android.graphics;

public class RectF {
    public float left;
    public float top;
    public float right;
    public float bottom;

    public RectF() {}

    public RectF(float left, float top, float right, float bottom) {
        set(left, top, right, bottom);
    }

    public RectF(RectF r) {
        if (r != null) set(r.left, r.top, r.right, r.bottom);
    }

    public RectF(Rect r) {
        if (r != null) set(r.left, r.top, r.right, r.bottom);
    }

    public void set(float left, float top, float right, float bottom) {
        this.left = left;
        this.top = top;
        this.right = right;
        this.bottom = bottom;
    }

    public void set(Rect r) {
        if (r != null) set(r.left, r.top, r.right, r.bottom);
    }

    public void inset(float dx, float dy) {
        left += dx;
        top += dy;
        right -= dx;
        bottom -= dy;
    }

    public float width() {
        return right - left;
    }

    public float height() {
        return bottom - top;
    }
}
""",
    "android/graphics/Matrix.java": """package android.graphics;

public class Matrix {
    public enum ScaleToFit {
        FILL,
        START,
        CENTER,
        END
    }

    public boolean setRectToRect(RectF src, RectF dst, ScaleToFit stf) {
        return true;
    }

    public void reset() {}
}
""",
    "android/graphics/Shader.java": """package android.graphics;

public class Shader {
    public enum TileMode {
        CLAMP,
        REPEAT,
        MIRROR
    }

    public void setLocalMatrix(Matrix localM) {}
}
""",
    "android/graphics/Bitmap.java": """package android.graphics;

import java.util.Arrays;

public class Bitmap {
    public enum Config {
        ARGB_8888
    }

    private final int width;
    private final int height;
    private final int[] pixels;
    private boolean recycled;

    private Bitmap(int width, int height, int[] pixels) {
        this.width = width;
        this.height = height;
        this.pixels = pixels;
    }

    public static Bitmap createBitmap(int width, int height, Config config) {
        int[] data = new int[Math.max(1, width * height)];
        Arrays.fill(data, 0xff223344);
        return new Bitmap(width, height, data);
    }

    public static Bitmap createBitmap(int[] colors, int width, int height, Config config) {
        int[] copy = Arrays.copyOf(colors, width * height);
        return new Bitmap(width, height, copy);
    }

    public int getWidth() {
        return width;
    }

    public int getHeight() {
        return height;
    }

    public boolean isRecycled() {
        return recycled;
    }

    public void recycle() {
        recycled = true;
    }

    public void getPixels(
            int[] outPixels, int offset, int stride, int x, int y, int w, int h) {
        for (int row = 0; row < h; row++) {
            System.arraycopy(
                    pixels, (y + row) * width + x, outPixels, offset + row * stride, w);
        }
    }
}
""",
    "android/graphics/BitmapShader.java": """package android.graphics;

public class BitmapShader extends Shader {
    private final Bitmap bitmap;

    public BitmapShader(Bitmap bitmap, TileMode tileX, TileMode tileY) {
        this.bitmap = bitmap;
    }

    public Bitmap getBitmap() {
        return bitmap;
    }
}
""",
    "android/graphics/LinearGradient.java": """package android.graphics;

public class LinearGradient extends Shader {
    public LinearGradient(
            float x0,
            float y0,
            float x1,
            float y1,
            int[] colors,
            float[] positions,
            TileMode tile) {}
}
""",
    "android/graphics/RuntimeShader.java": """package android.graphics;

import java.util.HashMap;
import java.util.Map;

public class RuntimeShader extends Shader {
    public static RuntimeShader lastCreated;
    public final String source;
    public final Map<String, float[]> floatUniforms = new HashMap<>();
    public final Map<String, Shader> inputShaders = new HashMap<>();

    public RuntimeShader(String shader) {
        this.source = shader;
        lastCreated = this;
    }

    public void setInputShader(String shaderName, Shader shader) {
        inputShaders.put(shaderName, shader);
    }

    public void setFloatUniform(String uniformName, float value) {
        floatUniforms.put(uniformName, new float[] {value});
    }

    public void setFloatUniform(String uniformName, float v1, float v2) {
        floatUniforms.put(uniformName, new float[] {v1, v2});
    }

    public void setFloatUniform(String uniformName, float v1, float v2, float v3, float v4) {
        floatUniforms.put(uniformName, new float[] {v1, v2, v3, v4});
    }
}
""",
    "android/graphics/Paint.java": """package android.graphics;

public class Paint {
    public static final int ANTI_ALIAS_FLAG = 1;
    public static final int FILTER_BITMAP_FLAG = 2;
    public static final int SUBPIXEL_TEXT_FLAG = 128;

    public enum Style {
        FILL,
        STROKE,
        FILL_AND_STROKE
    }

    public enum Join {
        MITER,
        ROUND,
        BEVEL
    }

    public enum Cap {
        BUTT,
        ROUND,
        SQUARE
    }

    private Style style = Style.FILL;
    private Shader shader;
    private int color;
    private int alpha = 255;
    private float textSize = 14f;

    public Paint() {}

    public Paint(int flags) {}

    public void setStyle(Style style) {
        this.style = style;
    }

    public Style getStyle() {
        return style;
    }

    public Shader setShader(Shader shader) {
        this.shader = shader;
        return shader;
    }

    public Shader getShader() {
        return shader;
    }

    public void setColor(int color) {
        this.color = color;
    }

    public int getColor() {
        return color;
    }

    public void setAlpha(int a) {
        this.alpha = a;
    }

    public int getAlpha() {
        return alpha;
    }

    public void setStrokeWidth(float width) {}

    public ColorFilter setColorFilter(ColorFilter filter) {
        return filter;
    }

    public Typeface setTypeface(Typeface typeface) {
        return typeface;
    }

    public void setStrokeJoin(Join join) {}

    public void setStrokeCap(Cap cap) {}

    public void setTextSize(float textSize) {
        this.textSize = textSize;
    }

    public float measureText(String text) {
        return text == null ? 0f : text.length() * textSize;
    }
}
""",
    "android/graphics/Canvas.java": """package android.graphics;

public class Canvas {
    public static final int ALL_SAVE_FLAG = 0x1F;
    private int saveDepth = 0;
    public Shader lastFillShader;
    public int lastFillColor;
    public int fillRoundRectCount;
    public int drawRectCount;
    public int drawTextCount;

    public Canvas() {}

    public Canvas(Bitmap bitmap) {}

    public void drawColor(int color) {}

    public void drawRect(float left, float top, float right, float bottom, Paint paint) {
        drawRectCount++;
    }

    public void drawRoundRect(RectF rect, float rx, float ry, Paint paint) {
        if (paint != null && paint.getStyle() == Paint.Style.FILL) {
            fillRoundRectCount++;
            lastFillShader = paint.getShader();
            lastFillColor = paint.getColor();
        }
    }

    public void drawText(String text, float x, float y, Paint paint) {
        drawTextCount++;
    }

    public void scale(float sx, float sy) {}

    public void translate(float dx, float dy) {}

    public void concat(Matrix matrix) {}

    public int save() {
        return ++saveDepth;
    }

    public int saveLayerAlpha(
            float left, float top, float right, float bottom, int alpha, int saveFlags) {
        return ++saveDepth;
    }

    public void restoreToCount(int saveCount) {
        saveDepth = Math.max(0, saveCount - 1);
    }
}
""",
    "android/graphics/drawable/Drawable.java": """package android.graphics.drawable;

import android.graphics.Canvas;
import android.graphics.ColorFilter;
import android.graphics.Rect;

public abstract class Drawable {
    private final Rect bounds = new Rect();
    public int invalidateSelfCount;

    public Rect getBounds() {
        return bounds;
    }

    public void setBounds(int left, int top, int right, int bottom) {
        bounds.set(left, top, right, bottom);
    }

    public void invalidateSelf() {
        invalidateSelfCount++;
    }

    public abstract void draw(Canvas canvas);

    public abstract void setAlpha(int alpha);

    public abstract void setColorFilter(ColorFilter colorFilter);

    public abstract int getOpacity();
}
""",
    "android/graphics/drawable/BitmapDrawable.java": """package android.graphics.drawable;

import android.content.res.Resources;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.ColorFilter;
import android.graphics.PixelFormat;

public class BitmapDrawable extends Drawable {
    private final Bitmap bitmap;

    public BitmapDrawable(Bitmap bitmap) {
        this.bitmap = bitmap;
    }

    public BitmapDrawable(Resources res, Bitmap bitmap) {
        this.bitmap = bitmap;
    }

    public Bitmap getBitmap() {
        return bitmap;
    }

    @Override
    public void draw(Canvas canvas) {}

    @Override
    public void setAlpha(int alpha) {}

    @Override
    public void setColorFilter(ColorFilter colorFilter) {}

    @Override
    public int getOpacity() {
        return PixelFormat.TRANSLUCENT;
    }
}
""",
    "android/util/DisplayMetrics.java": """package android.util;

public class DisplayMetrics {
    public float density = 2.0f;
    public float scaledDensity = 2.0f;
    public int widthPixels = 1080;
    public int heightPixels = 1920;
    public int densityDpi = 320;
}
""",
    "android/content/res/Resources.java": """package android.content.res;

import android.util.DisplayMetrics;

public class Resources {
    private final DisplayMetrics metrics = new DisplayMetrics();

    public DisplayMetrics getDisplayMetrics() {
        return metrics;
    }
}
""",
    "android/content/Context.java": """package android.content;

import android.content.res.Resources;

public class Context {
    private final Resources resources = new Resources();

    public Resources getResources() {
        return resources;
    }

    public Context getApplicationContext() {
        return this;
    }
}
""",
    "android/view/ViewParent.java": """package android.view;

public interface ViewParent {
    ViewParent getParent();
}
""",
    "android/view/ViewTreeObserver.java": """package android.view;

import java.util.ArrayList;
import java.util.List;

public class ViewTreeObserver {
    public interface OnScrollChangedListener {
        void onScrollChanged();
    }

    public interface OnGlobalLayoutListener {
        void onGlobalLayout();
    }

    public interface OnPreDrawListener {
        boolean onPreDraw();
    }

    private final List<OnScrollChangedListener> scrollListeners = new ArrayList<>();
    private final List<OnGlobalLayoutListener> layoutListeners = new ArrayList<>();
    private final List<OnPreDrawListener> preDrawListeners = new ArrayList<>();

    public boolean isAlive() {
        return true;
    }

    public void addOnScrollChangedListener(OnScrollChangedListener l) {
        if (l != null && !scrollListeners.contains(l)) scrollListeners.add(l);
    }

    public void removeOnScrollChangedListener(OnScrollChangedListener l) {
        scrollListeners.remove(l);
    }

    public void addOnGlobalLayoutListener(OnGlobalLayoutListener l) {
        if (l != null && !layoutListeners.contains(l)) layoutListeners.add(l);
    }

    public void removeGlobalOnLayoutListener(OnGlobalLayoutListener l) {
        layoutListeners.remove(l);
    }

    public void addOnPreDrawListener(OnPreDrawListener l) {
        if (l != null && !preDrawListeners.contains(l)) preDrawListeners.add(l);
    }

    public void removeOnPreDrawListener(OnPreDrawListener l) {
        preDrawListeners.remove(l);
    }
}
""",
    "android/view/View.java": """package android.view;

import android.content.Context;
import android.content.res.Resources;
import android.graphics.Canvas;
import android.graphics.Matrix;
import android.graphics.drawable.Drawable;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import java.util.ArrayList;
import java.util.List;

public class View {
    public static final int VISIBLE = 0;
    public static final int INVISIBLE = 4;
    public static final int GONE = 8;
    public static final int LAYER_TYPE_NONE = 0;
    public static final int LAYER_TYPE_SOFTWARE = 1;
    public static final int LAYER_TYPE_HARDWARE = 2;
    public static final int IMPORTANT_FOR_ACCESSIBILITY_NO = 2;

    private static final IBinder ATTACHED_TOKEN = new IBinder() {};

    public interface OnAttachStateChangeListener {
        void onViewAttachedToWindow(View v);

        void onViewDetachedFromWindow(View v);
    }

    public interface OnClickListener {
        void onClick(View v);
    }

    private final Context context;
    ViewParent parent;
    private Object tag;
    private int visibility = VISIBLE;
    private int layerType = LAYER_TYPE_NONE;
    private float scaleX = 1f;
    private float scaleY = 1f;
    private float translationX = 0f;
    private float translationY = 0f;
    private float alpha = 1f;
    private int left;
    private int top;
    private int right;
    private int bottom;
    private int padLeft;
    private int padTop;
    private int padRight;
    private int padBottom;
    private Drawable background;
    private boolean attachedToWindow;
    private OnClickListener clickListener;
    private final Matrix matrix = new Matrix();
    private final ViewTreeObserver viewTreeObserver = new ViewTreeObserver();
    private final List<OnAttachStateChangeListener> attachListeners = new ArrayList<>();
    public int drawCount;

    public View(Context context) {
        this.context = context != null ? context : new Context();
    }

    public Context getContext() {
        return context;
    }

    public Resources getResources() {
        return context.getResources();
    }

    public ViewParent getParent() {
        return parent;
    }

    public void setTag(Object tag) {
        this.tag = tag;
    }

    public Object getTag() {
        return tag;
    }

    public View findViewWithTag(Object query) {
        if (query != null && query.equals(tag)) return this;
        return null;
    }

    public void setVisibility(int visibility) {
        this.visibility = visibility;
    }

    public int getVisibility() {
        return visibility;
    }

    public void setClickable(boolean clickable) {}

    public void setFocusable(boolean focusable) {}

    public void setImportantForAccessibility(int mode) {}

    public void setOnClickListener(OnClickListener l) {
        this.clickListener = l;
    }

    public boolean performClick() {
        if (clickListener != null) {
            clickListener.onClick(this);
            return true;
        }
        return false;
    }

    public void layout(int l, int t, int r, int b) {
        this.left = l;
        this.top = t;
        this.right = r;
        this.bottom = b;
        if (background != null) {
            background.setBounds(0, 0, Math.max(0, r - l), Math.max(0, b - t));
        }
    }

    public int getLeft() {
        return left;
    }

    public int getTop() {
        return top;
    }

    public int getRight() {
        return right;
    }

    public int getBottom() {
        return bottom;
    }

    public int getWidth() {
        return Math.max(0, right - left);
    }

    public int getHeight() {
        return Math.max(0, bottom - top);
    }

    public int getScrollX() {
        return 0;
    }

    public int getScrollY() {
        return 0;
    }

    public Matrix getMatrix() {
        return matrix;
    }

    public void setPadding(int l, int t, int r, int b) {
        this.padLeft = l;
        this.padTop = t;
        this.padRight = r;
        this.padBottom = b;
    }

    public int getPaddingLeft() {
        return padLeft;
    }

    public int getPaddingTop() {
        return padTop;
    }

    public int getPaddingRight() {
        return padRight;
    }

    public int getPaddingBottom() {
        return padBottom;
    }

    public void setBackground(Drawable bg) {
        setBackgroundDrawable(bg);
    }

    @SuppressWarnings("deprecation")
    public void setBackgroundDrawable(Drawable bg) {
        this.background = bg;
        if (bg != null) {
            bg.setBounds(0, 0, getWidth(), getHeight());
        }
    }

    public Drawable getBackground() {
        return background;
    }

    public void setLayerType(int layerType, android.graphics.Paint paint) {
        this.layerType = layerType;
    }

    public int getLayerType() {
        return layerType;
    }

    public void setScaleX(float v) {
        this.scaleX = v;
    }

    public float getScaleX() {
        return scaleX;
    }

    public void setScaleY(float v) {
        this.scaleY = v;
    }

    public float getScaleY() {
        return scaleY;
    }

    public void setTranslationX(float v) {
        this.translationX = v;
    }

    public float getTranslationX() {
        return translationX;
    }

    public void setTranslationY(float v) {
        this.translationY = v;
    }

    public float getTranslationY() {
        return translationY;
    }

    public void setAlpha(float v) {
        this.alpha = v;
    }

    public float getAlpha() {
        return alpha;
    }

    public ViewTreeObserver getViewTreeObserver() {
        return viewTreeObserver;
    }

    public View getRootView() {
        View cur = this;
        while (cur.parent instanceof View) {
            cur = (View) cur.parent;
        }
        return cur;
    }

    public IBinder getWindowToken() {
        return attachedToWindow ? ATTACHED_TOKEN : null;
    }

    public boolean isShown() {
        View cur = this;
        while (cur != null) {
            if (cur.visibility != VISIBLE) return false;
            if (!(cur.parent instanceof View)) return cur.attachedToWindow;
            cur = (View) cur.parent;
        }
        return false;
    }

    public void getLocationOnScreen(int[] outLocation) {
        int x = 0;
        int y = 0;
        View cur = this;
        while (cur != null) {
            x += cur.left;
            y += cur.top;
            cur = cur.parent instanceof View ? (View) cur.parent : null;
        }
        outLocation[0] = x;
        outLocation[1] = y;
    }

    public void invalidate() {}

    public void postInvalidate() {}

    public void postInvalidateOnAnimation() {}

    public boolean post(Runnable action) {
        return new Handler(Looper.getMainLooper()).post(action);
    }

    public void draw(Canvas canvas) {
        drawCount++;
        if (background != null) {
            background.setBounds(0, 0, getWidth(), getHeight());
            background.draw(canvas);
        }
        onDraw(canvas);
    }

    protected void onDraw(Canvas canvas) {}

    protected void onDetachedFromWindow() {}

    public void addOnAttachStateChangeListener(OnAttachStateChangeListener l) {
        if (l != null && !attachListeners.contains(l)) {
            attachListeners.add(l);
        }
    }

    public void removeOnAttachStateChangeListener(OnAttachStateChangeListener l) {
        attachListeners.remove(l);
    }

    public int getAttachListenerCount() {
        return attachListeners.size();
    }

    public void dispatchAttachedToWindow() {
        attachedToWindow = true;
        for (OnAttachStateChangeListener l : new ArrayList<>(attachListeners)) {
            l.onViewAttachedToWindow(this);
        }
    }

    public void dispatchDetachedFromWindow() {
        attachedToWindow = false;
        onDetachedFromWindow();
        for (OnAttachStateChangeListener l : new ArrayList<>(attachListeners)) {
            l.onViewDetachedFromWindow(this);
        }
    }
}
""",
    "android/view/ViewGroup.java": """package android.view;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Rect;
import java.util.ArrayList;
import java.util.List;

public class ViewGroup extends View implements ViewParent {
    public static class LayoutParams {
        public static final int MATCH_PARENT = -1;
        public static final int WRAP_CONTENT = -2;
        public int width;
        public int height;

        public LayoutParams(int width, int height) {
            this.width = width;
            this.height = height;
        }
    }

    private final List<View> children = new ArrayList<>();

    public ViewGroup(Context context) {
        super(context);
    }

    public int getChildCount() {
        return children.size();
    }

    public View getChildAt(int index) {
        return children.get(index);
    }

    public int indexOfChild(View child) {
        return children.indexOf(child);
    }

    @Override
    public View findViewWithTag(Object query) {
        View self = super.findViewWithTag(query);
        if (self != null) return self;
        for (int i = 0; i < children.size(); i++) {
            View found = children.get(i).findViewWithTag(query);
            if (found != null) return found;
        }
        return null;
    }

    public void offsetDescendantRectToMyCoords(View descendant, Rect rect) {
        int dx = 0;
        int dy = 0;
        View cur = descendant;
        while (cur != null && cur != this) {
            dx += cur.getLeft();
            dy += cur.getTop();
            ViewParent p = cur.getParent();
            cur = p instanceof View ? (View) p : null;
        }
        if (cur != this) {
            throw new IllegalArgumentException("Not a descendant");
        }
        rect.offset(dx, dy);
    }

    public void addView(View child) {
        addView(child, children.size(), null);
    }

    public void addView(View child, LayoutParams params) {
        addView(child, children.size(), params);
    }

    public void addView(View child, int index) {
        addView(child, index, null);
    }

    public void addView(View child, int index, LayoutParams params) {
        if (child.parent != null) {
            throw new IllegalStateException("Child already has a parent");
        }
        if (index < 0 || index > children.size()) {
            children.add(child);
        } else {
            children.add(index, child);
        }
        child.parent = this;
    }

    public void removeView(View child) {
        if (children.remove(child)) {
            child.parent = null;
        }
    }

    @Override
    public void draw(Canvas canvas) {
        super.draw(canvas);
        for (int i = 0; i < children.size(); i++) {
            View child = children.get(i);
            if (child.getVisibility() == VISIBLE) {
                child.draw(canvas);
            }
        }
    }

    @Override
    public void dispatchAttachedToWindow() {
        super.dispatchAttachedToWindow();
        for (int i = 0; i < children.size(); i++) {
            children.get(i).dispatchAttachedToWindow();
        }
    }

    @Override
    public void dispatchDetachedFromWindow() {
        for (int i = 0; i < children.size(); i++) {
            children.get(i).dispatchDetachedFromWindow();
        }
        super.dispatchDetachedFromWindow();
    }
}
""",
    "android/widget/ImageView.java": """package android.widget;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.drawable.BitmapDrawable;
import android.graphics.drawable.Drawable;
import android.view.View;

public class ImageView extends View {
    public enum ScaleType {
        MATRIX,
        FIT_XY,
        FIT_START,
        FIT_CENTER,
        FIT_END,
        CENTER,
        CENTER_CROP,
        CENTER_INSIDE
    }

    private Drawable drawable;

    public ImageView(Context context) {
        super(context);
    }

    public void setScaleType(ScaleType scaleType) {}

    public void setImageDrawable(Drawable drawable) {
        this.drawable = drawable;
    }

    public void setImageBitmap(Bitmap bm) {
        this.drawable = bm != null ? new BitmapDrawable(bm) : null;
    }

    public Drawable getDrawable() {
        return drawable;
    }
}
""",
    "android/widget/FrameLayout.java": """package android.widget;

import android.content.Context;
import android.view.ViewGroup;

public class FrameLayout extends ViewGroup {
    public static class LayoutParams extends ViewGroup.LayoutParams {
        public int gravity;
        public int leftMargin;
        public int topMargin;
        public int rightMargin;
        public int bottomMargin;

        public LayoutParams(int width, int height) {
            super(width, height);
        }

        public LayoutParams(int width, int height, int gravity) {
            super(width, height);
            this.gravity = gravity;
        }
    }

    public FrameLayout(Context context) {
        super(context);
    }
}
""",
    "android/view/animation/Interpolator.java": """package android.view.animation;

import android.animation.TimeInterpolator;

public interface Interpolator extends TimeInterpolator {}
""",
    "android/animation/TimeInterpolator.java": """package android.animation;

public interface TimeInterpolator {
    float getInterpolation(float input);
}
""",
    "android/view/animation/LinearInterpolator.java": """package android.view.animation;

public class LinearInterpolator implements Interpolator {
    @Override
    public float getInterpolation(float input) {
        return input;
    }
}
""",
    "android/view/animation/PathInterpolator.java": """package android.view.animation;

public class PathInterpolator implements Interpolator {
    public PathInterpolator(float x1, float y1, float x2, float y2) {}

    @Override
    public float getInterpolation(float input) {
        return input;
    }
}
""",
    "android/animation/Animator.java": """package android.animation;

import java.util.ArrayList;
import java.util.List;

public abstract class Animator {
    public interface AnimatorListener {
        void onAnimationStart(Animator animation);

        void onAnimationEnd(Animator animation);

        void onAnimationCancel(Animator animation);

        void onAnimationRepeat(Animator animation);
    }

    protected final List<AnimatorListener> listeners = new ArrayList<>();

    public void addListener(AnimatorListener listener) {
        if (listener != null) listeners.add(listener);
    }

    public void removeAllListeners() {
        listeners.clear();
    }

    public abstract void start();

    public abstract void cancel();

    public abstract boolean isRunning();

    public abstract boolean isStarted();
}
""",
    "android/animation/AnimatorListenerAdapter.java": """package android.animation;

public abstract class AnimatorListenerAdapter implements Animator.AnimatorListener {
    @Override
    public void onAnimationStart(Animator animation) {}

    @Override
    public void onAnimationEnd(Animator animation) {}

    @Override
    public void onAnimationCancel(Animator animation) {}

    @Override
    public void onAnimationRepeat(Animator animation) {}
}
""",
    "android/animation/ValueAnimator.java": """package android.animation;

import java.util.ArrayList;
import java.util.List;

public class ValueAnimator extends Animator {
    public interface AnimatorUpdateListener {
        void onAnimationUpdate(ValueAnimator animation);
    }

    private static ValueAnimator lastStarted;
    private final float startVal;
    private final float endVal;
    private float currentVal;
    private long duration;
    private TimeInterpolator interpolator;
    private boolean started;
    private boolean running;
    private final List<AnimatorUpdateListener> updateListeners = new ArrayList<>();

    private ValueAnimator(float startVal, float endVal) {
        this.startVal = startVal;
        this.endVal = endVal;
        this.currentVal = startVal;
    }

    public static ValueAnimator ofFloat(float... values) {
        float s = values.length > 0 ? values[0] : 0f;
        float e = values.length > 1 ? values[values.length - 1] : s;
        return new ValueAnimator(s, e);
    }

    public static void clearLastStarted() {
        lastStarted = null;
    }

    public static ValueAnimator getLastStarted() {
        return lastStarted;
    }

    public ValueAnimator setDuration(long duration) {
        this.duration = duration;
        return this;
    }

    public long getDuration() {
        return duration;
    }

    public void setInterpolator(TimeInterpolator value) {
        this.interpolator = value;
    }

    public void addUpdateListener(AnimatorUpdateListener listener) {
        if (listener != null) updateListeners.add(listener);
    }

    public void removeAllUpdateListeners() {
        updateListeners.clear();
    }

    public Object getAnimatedValue() {
        return Float.valueOf(currentVal);
    }

    @Override
    public void start() {
        started = true;
        running = true;
        lastStarted = this;
        for (AnimatorListener l : new ArrayList<>(listeners)) {
            l.onAnimationStart(this);
        }
    }

    public void stepTo(float fraction) {
        float t = interpolator != null ? interpolator.getInterpolation(fraction) : fraction;
        currentVal = startVal + (endVal - startVal) * t;
        for (AnimatorUpdateListener l : new ArrayList<>(updateListeners)) {
            l.onAnimationUpdate(this);
        }
    }

    public void finish() {
        if (!running) return;
        stepTo(1f);
        running = false;
        started = false;
        for (AnimatorListener l : new ArrayList<>(listeners)) {
            l.onAnimationEnd(this);
        }
    }

    @Override
    public void cancel() {
        if (!started && !running) return;
        running = false;
        started = false;
        for (AnimatorListener l : new ArrayList<>(listeners)) {
            l.onAnimationCancel(this);
        }
    }

    @Override
    public boolean isRunning() {
        return running;
    }

    @Override
    public boolean isStarted() {
        return started;
    }
}
""",
}


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="wave2-android-wire-checks-") as tmp:
        work_dir = Path(tmp)
        classes_dir = work_dir / "classes"
        extra_src_dir = work_dir / "extra-stubs-src"
        extra_cls_dir = work_dir / "extra-stubs-classes"
        extra_cls_dir.mkdir(parents=True, exist_ok=True)

        extra_files = []
        for rel, src in EXTRA_RUNTIME_STUBS.items():
            dst = extra_src_dir / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text(src, encoding="utf-8")
            extra_files.append(str(dst))

        subprocess.run(
            [
                str(JDK / ("javac" + SUFFIX)),
                "-encoding",
                "UTF-8",
                "-source",
                "8",
                "-target",
                "8",
                "-Xlint:-options",
                "-cp",
                str(ensure_android_jar()),
                "-d",
                str(extra_cls_dir),
                *extra_files,
            ],
            check=True,
        )

        # Compile real Android sources against real android.jar + dep jars, and compile the test
        # against both real compiled Android classes and our runtime stubs (for stub helper methods
        # like ValueAnimator.stepTo/finish and View.dispatchDetachedFromWindow).
        runtime_cp = compile_real_android_sources(
            classes_dir=classes_dir,
            work_dir=work_dir,
            test_sources=[],
        )
        test_cls_dir = work_dir / "test-classes"
        test_cls_dir.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [
                str(JDK / ("javac" + SUFFIX)),
                "-encoding",
                "UTF-8",
                "-source",
                "8",
                "-target",
                "8",
                "-Xlint:-options",
                "-cp",
                os.pathsep.join(str(p) for p in [extra_cls_dir, *runtime_cp]),
                "-d",
                str(test_cls_dir),
                str(ROOT / "android-tv/tests/Wave2AndroidWireChecks.java"),
            ],
            check=True,
        )
        subprocess.run(
            [
                str(JDK / ("java" + SUFFIX)),
                "-Dfile.encoding=UTF-8",
                "-cp",
                os.pathsep.join(str(p) for p in [test_cls_dir, extra_cls_dir, *runtime_cp]),
                "com.pilipala.marcomovie.Wave2AndroidWireChecks",
                str(ROOT),
            ],
            cwd=ROOT,
            check=True,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
