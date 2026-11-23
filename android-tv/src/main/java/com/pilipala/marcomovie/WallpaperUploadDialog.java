package com.pilipala.marcomovie;

import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.Typeface;
import android.view.Gravity;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import com.google.zxing.BarcodeFormat;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;
import java.io.ByteArrayInputStream;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/** TV QR-code pairing dialog for uploading a custom home wallpaper from a phone on the same LAN. */
final class WallpaperUploadDialog {
    final MainActivity a;
    final Runnable onUploaded;
    WallpaperUploadServer server;
    AppDialog dialog;
    boolean finished;
    final Runnable expiry = this::expire;

    WallpaperUploadDialog(MainActivity host, Runnable onUploaded) {
        this.a = host;
        this.onUploaded = onUploaded;
    }

    void expire() {
        if (dialog != null && dialog.isShowing()) {
            dialog.dismiss();
            a.toast("壁纸上传二维码已过期，请重新打开");
        }
    }

    void show() {
        try {
            String ip = PhoneConfigDialog.lanAddress();
            server =
                    new WallpaperUploadServer(
                            imageBytes -> {
                                CountDownLatch latch = new CountDownLatch(1);
                                AtomicReference<Exception> failure = new AtomicReference<>();
                                try {
                                    SettingsScreen.saveWallpaper(
                                            a, new ByteArrayInputStream(imageBytes));
                                } catch (Exception e) {
                                    throw e;
                                }
                                a.ui.post(
                                        () -> {
                                            try {
                                                if (server == null
                                                        || server.closed
                                                        || a.isFinishing()) {
                                                    throw new java.io.IOException("Session closed");
                                                }
                                                a.prefs
                                                        .edit()
                                                        .putInt(
                                                                Prefs.TV_BG_MODE,
                                                                Prefs.BG_MODE_WALLPAPER)
                                                        .putBoolean(Prefs.WALLPAPER_ENABLED, true)
                                                        .apply();
                                                finished = true;
                                                if (dialog != null) dialog.dismiss();
                                                if (onUploaded != null) onUploaded.run();
                                                else a.refresh();
                                                a.toast("壁纸已上传并替换成功");
                                            } catch (Exception e) {
                                                failure.set(e);
                                            } finally {
                                                latch.countDown();
                                            }
                                        });
                                if (!latch.await(15, TimeUnit.SECONDS)) {
                                    throw new java.io.IOException("Apply timeout");
                                }
                                if (failure.get() != null) throw failure.get();
                            });

            String urlStr = server.address(ip);
            LinearLayout panel = a.vertical();
            panel.setGravity(Gravity.CENTER_HORIZONTAL);
            panel.setPadding(a.dp(8), a.dp(4), a.dp(8), a.dp(4));

            TextView note =
                    a.text("请确保手机与电视连接同一 Wi-Fi，使用微信或相机扫码后从相册挑选高清图片上传。", 14, MainActivity.MUTED);
            note.setGravity(Gravity.CENTER);
            panel.addView(note);
            a.gap(panel, 14);

            int qrSize =
                    Math.min(a.dp(176), Math.max(a.dp(136), Math.round(a.windowHeight() * 0.30f)));
            BitMatrix matrix =
                    new QRCodeWriter().encode(urlStr, BarcodeFormat.QR_CODE, qrSize, qrSize);
            int[] pixels = new int[qrSize * qrSize];
            for (int y = 0; y < qrSize; y++) {
                for (int x = 0; x < qrSize; x++) {
                    pixels[y * qrSize + x] = matrix.get(x, y) ? Color.BLACK : Color.WHITE;
                }
            }
            LinearLayout qrCard = a.vertical();
            qrCard.setGravity(Gravity.CENTER);
            qrCard.setPadding(a.dp(12), a.dp(12), a.dp(12), a.dp(12));
            qrCard.setBackground(a.bg(Color.WHITE, 18));
            ImageView qr = new ImageView(a);
            qr.setTag("wallpaper-upload-qr");
            qr.setContentDescription("手机扫码上传壁纸二维码");
            qr.setImageBitmap(Bitmap.createBitmap(pixels, qrSize, qrSize, Bitmap.Config.ARGB_8888));
            qrCard.addView(qr, new LinearLayout.LayoutParams(qrSize, qrSize));
            panel.addView(qrCard, new LinearLayout.LayoutParams(-2, -2));

            TextView urlView = a.text(urlStr, 12, MainActivity.WHITE);
            urlView.setTypeface(Typeface.MONOSPACE);
            urlView.setGravity(Gravity.CENTER);
            urlView.setPadding(0, a.dp(12), 0, 0);
            panel.addView(urlView);

            TextView tip =
                    a.text("支持 JPG / PNG / WebP（≤ 16 MB）· 二维码 5 分钟内有效", 12, MainActivity.MUTED);
            tip.setGravity(Gravity.CENTER);
            tip.setPadding(0, a.dp(6), 0, 0);
            panel.addView(tip);

            dialog =
                    new AppDialog.Builder(a)
                            .setTitle("手机扫码上传首页壁纸")
                            .setView(panel)
                            .setNegativeButton("关闭", null)
                            .create();
            dialog.setOnDismissListener(
                    d -> {
                        a.ui.removeCallbacks(expiry);
                        if (finished) a.ui.postDelayed(this::close, 2000);
                        else close();
                    });
            dialog.show();
            a.ui.postDelayed(expiry, TimeUnit.MINUTES.toMillis(5));
        } catch (Exception error) {
            close();
            a.notice("未能获取电视局域网地址，请检查电视 Wi-Fi 或有线网络连接后重试。");
        }
    }

    void close() {
        a.ui.removeCallbacks(expiry);
        if (server != null) {
            server.close();
            server = null;
        }
    }
}
