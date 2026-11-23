package com.pilipala.marcomovie;

import android.graphics.*;
import android.widget.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicReference;
import com.google.zxing.*;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;

/** App-owned QR pairing panel; no external QR service or persistent LAN listener. */
final class PhoneConfigDialog {
    final MainActivity a;
    ConfigTransferServer server;
    AppDialog dialog;
    boolean finished;
    final Runnable expiry = this::expire;

    void expire() {
        if (dialog != null && dialog.isShowing()) {
            dialog.dismiss();
            a.toast("二维码已过期，请重新打开手机配置");
        }
    }

    PhoneConfigDialog(MainActivity host) {
        a = host;
    }

    static String lanAddress() throws Exception {
        List<NetworkInterface> interfaces =
                Collections.list(NetworkInterface.getNetworkInterfaces());
        Collections.sort(
                interfaces,
                (a, b) -> {
                    int pa =
                            a.getName().startsWith("wlan")
                                    ? 0
                                    : a.getName().startsWith("eth") ? 1 : 2;
                    int pb =
                            b.getName().startsWith("wlan")
                                    ? 0
                                    : b.getName().startsWith("eth") ? 1 : 2;
                    return pa < pb ? -1 : (pa > pb ? 1 : 0);
                });
        for (NetworkInterface network : interfaces)
            if (network.isUp() && !network.isLoopback())
                for (InetAddress ip : Collections.list(network.getInetAddresses()))
                    if (ip instanceof Inet4Address && ip.isSiteLocalAddress())
                        return ip.getHostAddress();
        throw new java.io.IOException("No LAN address");
    }

    void show() {
        if (!a.isTvDevice()) {
            MobileShell.showMobileImportDialog(a);
            return;
        }
        try {
            String ip = lanAddress();
            server =
                    ConfigTransferServer.withBatchImporter(
                            (address, appendMerge) -> {
                                List<SubscriptionManager.ImportSpec> specs =
                                        SubscriptionManager.parseImportSpecsStrict(address);
                                if (specs.size() == 1 && !appendMerge) {
                                    String onlyUrl = specs.get(0).url;
                                    Cms.Config config =
                                            Cms.parseConfig(
                                                    SourceController.fetchImport(a, onlyUrl),
                                                    SourceController.importOrigin(onlyUrl));
                                    CountDownLatch applied = new CountDownLatch(1);
                                    AtomicReference<Exception> failure = new AtomicReference<>();
                                    a.ui.post(
                                            () -> {
                                                try {
                                                    if (server.closed
                                                            || a.isFinishing()
                                                            || a.phoneConfig != this)
                                                        throw new java.io.IOException(
                                                                "Session closed");
                                                    a.saveConfig(
                                                            config,
                                                            SourceController.importOrigin(onlyUrl));
                                                    finished = true;
                                                    if (dialog != null) dialog.dismiss();
                                                } catch (Exception e) {
                                                    failure.set(e);
                                                } finally {
                                                    applied.countDown();
                                                }
                                            });
                                    if (!applied.await(20, TimeUnit.SECONDS))
                                        throw new java.io.IOException("Apply timeout");
                                    if (failure.get() != null) throw failure.get();
                                    return;
                                }
                                SubscriptionManager.MergedResult merged =
                                        SourceController.fetchAndMergeImportSpecs(
                                                a, specs, appendMerge);
                                CountDownLatch applied = new CountDownLatch(1);
                                AtomicReference<Exception> failure = new AtomicReference<>();
                                a.ui.post(
                                        () -> {
                                            try {
                                                if (server.closed
                                                        || a.isFinishing()
                                                        || a.phoneConfig != this)
                                                    throw new java.io.IOException("Session closed");
                                                a.saveConfig(merged.config, merged.origin);
                                                a.toast(
                                                        "已导入 "
                                                                + merged.sourceCount
                                                                + " 个源并自动分组（共 "
                                                                + merged.config.sites.size()
                                                                + " 条线路）");
                                                finished = true;
                                                if (dialog != null) dialog.dismiss();
                                            } catch (Exception e) {
                                                failure.set(e);
                                            } finally {
                                                applied.countDown();
                                            }
                                        });
                                if (!applied.await(20, TimeUnit.SECONDS))
                                    throw new java.io.IOException("Apply timeout");
                                if (failure.get() != null) throw failure.get();
                            },
                            CloudSyncDialog.lanSyncHandler(a));
            String address = server.address(ip);
            LinearLayout panel = a.vertical();
            panel.setGravity(android.view.Gravity.CENTER_HORIZONTAL);
            TextView note =
                    a.text(
                            "手机与电视连接同一网络，扫码可粘贴 1 个或多个配置地址（每行一个，支持 分组名,网址），多源导入将自动按源分组。",
                            15,
                            MainActivity.MUTED);
            panel.addView(note);
            a.gap(panel, 12);
            int qrSize =
                    Math.min(a.dp(172), Math.max(a.dp(132), Math.round(a.windowHeight() * 0.29f)));
            BitMatrix matrix =
                    new QRCodeWriter().encode(address, BarcodeFormat.QR_CODE, qrSize, qrSize);
            int[] pixels = new int[qrSize * qrSize];
            for (int y = 0; y < qrSize; y++)
                for (int x = 0; x < qrSize; x++)
                    pixels[y * qrSize + x] = matrix.get(x, y) ? Color.BLACK : Color.WHITE;
            ImageView qr = new ImageView(a);
            qr.setTag("config-qr");
            qr.setContentDescription("手机扫码配置二维码");
            qr.setImageBitmap(Bitmap.createBitmap(pixels, qrSize, qrSize, Bitmap.Config.ARGB_8888));
            panel.addView(qr, new LinearLayout.LayoutParams(qrSize, qrSize));
            TextView url = a.text(address, 12, MainActivity.WHITE);
            url.setTag("config-phone-address");
            url.setGravity(android.view.Gravity.CENTER);
            url.setPadding(0, a.dp(10), 0, 0);
            panel.addView(url);
            LinearLayout mountRow = a.row();
            mountRow.setGravity(android.view.Gravity.CENTER);
            android.widget.Button emby =
                    a.button(
                            "连接 Emby",
                            "config-emby",
                            () -> {
                                if (dialog != null) dialog.dismiss();
                                EmbyEngine.connect(a);
                            });
            emby.setTextSize(13.5f);
            LinearLayout.LayoutParams embyLp = new LinearLayout.LayoutParams(-2, a.dp(40));
            embyLp.rightMargin = a.dp(8);
            mountRow.addView(emby, embyLp);
            android.widget.Button alist =
                    a.button(
                            "挂载 AList",
                            "config-alist",
                            () -> {
                                if (dialog != null) dialog.dismiss();
                                AlistAccounts.openManager(a);
                            });
            alist.setTextSize(13.5f);
            mountRow.addView(alist, new LinearLayout.LayoutParams(-2, a.dp(40)));
            LinearLayout.LayoutParams rowLp = new LinearLayout.LayoutParams(-2, -2);
            rowLp.topMargin = a.dp(10);
            panel.addView(mountRow, rowLp);
            a.gap(panel, 6);
            panel.addView(a.text("二维码有效 5 分钟 · 关闭后停止接收", 12, MainActivity.MUTED));
            dialog =
                    new AppDialog.Builder(a)
                            .setTitle("手机扫码配置")
                            .setView(panel)
                            .setNeutralButton("遥控输入", (d, n) -> a.addressImportDialog())
                            .setPositiveButton("刷新二维码", (d, n) -> a.importDialog())
                            .setNegativeButton("完成", null)
                            .create();
            dialog.setOnDismissListener(
                    d -> {
                        a.ui.removeCallbacks(expiry);
                        if (finished) a.ui.postDelayed(this::close, 2000);
                        else close();
                    });
            dialog.show();
            dialog.getButton(-2).requestFocus();
            a.ui.postDelayed(expiry, TimeUnit.MINUTES.toMillis(5));
        } catch (Exception error) {
            close();
            a.toast("未能打开局域网配置，可先使用遥控输入或本地文件");
            a.addressImportDialog();
        }
    }

    void showLanSyncReceiver(final Runnable onUpdated) {
        if (a.privateMode) {
            a.toast("隐私空间内容严格本机隔离，不参与网络同步");
            return;
        }
        try {
            String ip = lanAddress();
            server =
                    new ConfigTransferServer(
                            null,
                            remoteJson -> {
                                String merged = CloudSyncDialog.lanSyncHandler(a).sync(remoteJson);
                                if (remoteJson != null && onUpdated != null) {
                                    a.ui.post(
                                            () -> {
                                                if (!a.isFinishing()) onUpdated.run();
                                            });
                                }
                                return merged;
                            });
            final String address = server.address(ip);
            LinearLayout panel = a.vertical();
            panel.setGravity(android.view.Gravity.CENTER_HORIZONTAL);
            TextView note =
                    a.text(
                            "保持此窗口打开（5 分钟内有效）。在同局域网的另一台设备打开「多端网络同步 → 连接局域网其他设备」，输入下方地址或扫码获取地址即可双向合并：",
                            13.5f,
                            MainActivity.MUTED);
            note.setLineSpacing(a.dp(3), 1f);
            panel.addView(note);
            a.gap(panel, 12);
            int qrSize =
                    Math.min(a.dp(172), Math.max(a.dp(132), Math.round(a.windowHeight() * 0.29f)));
            BitMatrix matrix =
                    new QRCodeWriter().encode(address, BarcodeFormat.QR_CODE, qrSize, qrSize);
            int[] pixels = new int[qrSize * qrSize];
            for (int y = 0; y < qrSize; y++)
                for (int x = 0; x < qrSize; x++)
                    pixels[y * qrSize + x] = matrix.get(x, y) ? Color.BLACK : Color.WHITE;
            ImageView qr = new ImageView(a);
            qr.setTag("lan-sync-qr");
            qr.setContentDescription("本机局域网同步接收二维码");
            qr.setImageBitmap(Bitmap.createBitmap(pixels, qrSize, qrSize, Bitmap.Config.ARGB_8888));
            panel.addView(qr, new LinearLayout.LayoutParams(qrSize, qrSize));
            TextView url = a.text(address, 12.5f, 0xff5ac8fa);
            url.setTag("lan-sync-address");
            url.setGravity(android.view.Gravity.CENTER);
            url.setPadding(0, a.dp(10), 0, a.dp(4));
            panel.addView(url);
            if (!a.isTvDevice()) {
                android.widget.Button copyBtn =
                        a.navButton(
                                "复制同步地址",
                                "lan-sync-copy",
                                () -> {
                                    android.content.ClipboardManager cm =
                                            (android.content.ClipboardManager)
                                                    a.getSystemService(
                                                            android.content.Context
                                                                    .CLIPBOARD_SERVICE);
                                    if (cm != null) {
                                        cm.setPrimaryClip(
                                                android.content.ClipData.newPlainText(
                                                        "Marco Movie 局域网同步", address));
                                        a.toast("已复制局域网同步地址");
                                    }
                                });
                LinearLayout.LayoutParams cpLp = new LinearLayout.LayoutParams(-2, a.dp(36));
                cpLp.topMargin = a.dp(6);
                panel.addView(copyBtn, cpLp);
            }
            a.gap(panel, 6);
            panel.addView(a.text("接收码有效 5 分钟 · 关闭窗口即停止监听", 12, MainActivity.MUTED));
            dialog =
                    new AppDialog.Builder(a)
                            .setTitle("本机局域网接收码")
                            .setView(panel)
                            .setPositiveButton(
                                    "刷新接收码",
                                    (d, n) -> {
                                        if (a.phoneConfig != null) a.phoneConfig.close();
                                        a.phoneConfig = new PhoneConfigDialog(a);
                                        a.phoneConfig.showLanSyncReceiver(onUpdated);
                                    })
                            .setNegativeButton("完成并关闭", null)
                            .create();
            dialog.setOnDismissListener(
                    d -> {
                        a.ui.removeCallbacks(expiry);
                        close();
                    });
            dialog.show();
            if (a.isTvDevice() && dialog.getButton(-2) != null) {
                dialog.getButton(-2).requestFocus();
            }
            a.ui.postDelayed(expiry, TimeUnit.MINUTES.toMillis(5));
        } catch (Exception error) {
            close();
            a.toast("无法获取本机局域网地址，请确认已连接 Wi-Fi 或有线局域网");
        }
    }

    void close() {
        a.ui.removeCallbacks(expiry);
        if (server != null) server.close();
        if (a.phoneConfig == this) a.phoneConfig = null;
    }
}
