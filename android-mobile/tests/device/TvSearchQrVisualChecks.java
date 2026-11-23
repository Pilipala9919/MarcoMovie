package com.pilipala.marcomovie;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Rect;
import android.text.Layout;
import android.view.View;
import android.widget.Button;
import org.json.JSONObject;

/** Read-only checks for an already approved isolated search screen. Never launches or clicks. */
public final class TvSearchQrVisualChecks {
    public static JSONObject inspect(View root, boolean expectedFocused) throws Exception {
        View view = root.findViewWithTag("search-qr-button");
        if (!(view instanceof Button)) throw new AssertionError("QR button missing");
        Button b = (Button) view;
        Layout layout = b.getLayout();
        int content = b.getWidth() - b.getCompoundPaddingLeft() - b.getCompoundPaddingRight();
        float text = b.getPaint().measureText(b.getText().toString());
        Rect visible = new Rect();
        boolean entire =
                b.getLocalVisibleRect(visible)
                        && visible.left <= 0
                        && visible.top <= 0
                        && visible.right >= b.getWidth()
                        && visible.bottom >= b.getHeight();
        JSONObject result =
                new JSONObject()
                        .put("text", b.getText())
                        .put("width", b.getWidth())
                        .put("text_width", text)
                        .put("content_width", content)
                        .put("text_color", b.getCurrentTextColor())
                        .put("focused", b.hasFocus())
                        .put("entirely_visible", entire);
        if (!"扫码".contentEquals(b.getText())
                || !b.isShown()
                || b.getAlpha() <= 0
                || b.hasFocus() != expectedFocused
                || !entire
                || content < Math.ceil(text)
                || layout == null
                || layout.getLineCount() != 1
                || layout.getEllipsisCount(0) != 0
                || layout.getHeight()
                        > b.getHeight()
                                - b.getCompoundPaddingTop()
                                - b.getCompoundPaddingBottom()) {
            throw new AssertionError(result.toString());
        }
        return result;
    }

    /** Widget-only raster for comparison with the full native screen; no screenshot permission. */
    public static Bitmap render(View root) {
        View b = root.findViewWithTag("search-qr-button");
        if (b == null || b.getWidth() <= 0 || b.getHeight() <= 0)
            throw new AssertionError("QR button not laid out");
        Bitmap bitmap = Bitmap.createBitmap(b.getWidth(), b.getHeight(), Bitmap.Config.ARGB_8888);
        b.draw(new Canvas(bitmap));
        return bitmap;
    }
}
