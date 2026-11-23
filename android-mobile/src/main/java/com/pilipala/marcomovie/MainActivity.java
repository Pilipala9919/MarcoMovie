package com.pilipala.marcomovie;

import android.app.*;
import android.content.*;
import android.graphics.*;
import android.graphics.drawable.*;
import android.media.*;
import android.net.Uri;
import android.os.*;
import android.view.*;
import android.view.animation.DecelerateInterpolator;
import android.widget.*;
import android.util.LruCache;
import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;

/** Independent first native build. No original APK code or artwork is embedded. */
public final class MainActivity extends Activity {
    static final int WHITE = 0xfff5f5f7, MUTED = 0xffa1a1aa, DARK = 0xff101013;
    final Handler ui = new Handler(Looper.getMainLooper());
    final ExecutorService worker = Executors.newFixedThreadPool(4);
    final ExecutorService details = Executors.newFixedThreadPool(4);
    final DetailCache detailCache = new DetailCache();
    final SingleFlight<String> detailFlights = new SingleFlight<>();
    Future<?> detailPrefetch;
    final List<Future<?>> pageRequests = new ArrayList<>();
    final ExecutorService artwork = Executors.newFixedThreadPool(8);
    final List<Future<?>> artworkRequests = new ArrayList<>();
    final ExecutorService phoneticWork = Executors.newSingleThreadExecutor();
    final LinkedHashSet<String> pendingTitles = new LinkedHashSet<>();
    final Runnable learnPendingTitles = this::learnPendingTitles;

    void learnPendingTitles() {
        SourceController.learnPendingTitles(this);
    }

    UpdateScreen updateScreen;
    final Runnable automaticUpdate =
            new Runnable() {
                public void run() {
                    if (!foreground) return;
                    if (current != null && current.home && appDialog == null) {
                        UpdateManager updates = UpdateManager.get(MainActivity.this);
                        updates.automatic();
                        if (updates.consumeNotice()) toast("发现新版，可在设置 → 软件更新查看");
                    }
                    ui.postDelayed(this, 60000);
                }
            };
    PlaybackLoading playbackLoading;
    View playbackLoadingFocus;
    int playbackResolveSerial;
    GlobalSearchScreen searchScreen;
    Dialog sourceDialog, accountDialog;
    MagnetStream magnetStream;
    // Assets only. Never publish an Activity's learned/private index into this template.
    private static volatile PhoneticSearchIndex sharedPhoneticDictionary;
    volatile PhoneticSearchIndex phonetic;
    final CountDownLatch phoneticReady = new CountDownLatch(1);
    ConfigStore configStore;
    PhoneConfigDialog phoneConfig;
    CastService castService;
    CastScreen activeCastScreen;
    SpiderGatewayServer spiderGateway;
    LiveSession liveSession;
    final Runnable tuneLiveNumber = this::commitLiveNumber;
    LocalProxy localProxy;
    WebResolver webResolver;
    PlaybackControls playbackControls;
    TvMarkerHost markerHost;
    Cms.Line activeLine;
    Cms.Episode activeEpisode;
    int resumeAt;
    WatchHistory.Entry playingBookmark;
    WatchHistory.Entry historyFallbackBookmark;
    boolean historyFallbackInFlight;
    String migratingHistoryOldKey;
    long lastBookmarkSave;
    final ArrayDeque<Screen> back = new ArrayDeque<>();
    final LruCache<String, Bitmap> images =
            new LruCache<String, Bitmap>(10 * 1024 * 1024) {
                protected int sizeOf(String k, Bitmap b) {
                    return b.getByteCount();
                }
            };
    final HomeKeyTracker homeKeys = new HomeKeyTracker();
    Screen shortcutScreen;

    static final class GlassFreezeController implements PlayerTransitionHelper.GlassFreezeCallback {
        private static final class DeferredFrame {
            final GlassFreezeFrameLayout host;
            final Runnable ready;

            DeferredFrame(GlassFreezeFrameLayout host, Runnable ready) {
                this.host = host;
                this.ready = ready;
            }
        }

        private int freezeDepth;
        private final Runnable onUnfreeze;
        private final List<DeferredFrame> deferredFrames = new ArrayList<>();

        GlassFreezeController(Runnable onUnfreeze) {
            this.onUnfreeze = onUnfreeze;
        }

        @Override
        public void setGlassFrozen(boolean frozen) {
            List<DeferredFrame> toResume = null;
            boolean unfroze = false;
            synchronized (this) {
                if (frozen) {
                    freezeDepth++;
                } else if (freezeDepth > 0) {
                    freezeDepth--;
                    if (freezeDepth == 0) {
                        unfroze = true;
                        if (!deferredFrames.isEmpty()) {
                            toResume = new ArrayList<>(deferredFrames);
                            deferredFrames.clear();
                        }
                    }
                }
            }
            if (unfroze) {
                if (onUnfreeze != null) {
                    onUnfreeze.run();
                }
                resumeDeferred(toResume);
            }
        }

        void forceUnfreeze() {
            List<DeferredFrame> toResume = null;
            boolean unfroze = false;
            synchronized (this) {
                if (freezeDepth > 0) {
                    freezeDepth = 0;
                    unfroze = true;
                    if (!deferredFrames.isEmpty()) {
                        toResume = new ArrayList<>(deferredFrames);
                        deferredFrames.clear();
                    }
                }
            }
            if (unfroze) {
                if (onUnfreeze != null) {
                    onUnfreeze.run();
                }
                resumeDeferred(toResume);
            }
        }

        synchronized boolean isFrozen() {
            return freezeDepth > 0;
        }

        /**
         * Preserves real user {@code Prefs.REDUCED_TRANSPARENCY} without forcing frozen glass
         * surfaces to snap from their cached blurred {@code material} bitmaps to solid {@code
         * DARK_TINT}. Backdrop resampling is intercepted via {@link GlassFreezeFrameLayout}
         * ({@link com.pilipala.glass.GlassworkSurface.FrameSource}).
         */
        boolean shouldReduceTransparency(boolean userReducedTransparency) {
            return userReducedTransparency;
        }

        boolean deferCaptureIfFrozen(GlassFreezeFrameLayout host, Runnable ready) {
            if (ready == null) return false;
            synchronized (this) {
                if (freezeDepth <= 0) {
                    return false;
                }
                deferredFrames.add(new DeferredFrame(host, ready));
                return true;
            }
        }

        synchronized void clearDeferredForHost(GlassFreezeFrameLayout host) {
            for (int i = deferredFrames.size() - 1; i >= 0; i--) {
                if (deferredFrames.get(i).host == host) {
                    deferredFrames.remove(i);
                }
            }
        }

        synchronized int getDeferredCaptureCount() {
            return deferredFrames.size();
        }

        private void resumeDeferred(List<DeferredFrame> toResume) {
            if (toResume == null) return;
            for (int i = 0; i < toResume.size(); i++) {
                DeferredFrame item = toResume.get(i);
                if (isFrozen()) {
                    synchronized (this) {
                        for (int j = i; j < toResume.size(); j++) {
                            deferredFrames.add(toResume.get(j));
                        }
                    }
                    return;
                }
                item.host.dispatchUnfrozenFrame(item.ready);
            }
        }
    }

    /**
     * Root backdrop container implementing {@link com.pilipala.glass.GlassworkSurface.FrameSource}
     * so transitions freeze backdrop resampling before bitmap capture/blur while keeping existing
     * cached {@code material} bitmaps rendered smoothly on every child view (including independent
     * API 23+ hardware DisplayLists) and keeping {@code target.getBackground() instanceof
     * GlassworkSurface} intact.
     */
    static class GlassFreezeFrameLayout extends FrameLayout
            implements com.pilipala.glass.GlassworkSurface.FrameSource {
        private final GlassFreezeController freezeController;

        GlassFreezeFrameLayout(Context context, GlassFreezeController freezeController) {
            super(context);
            this.freezeController = freezeController;
        }

        @Override
        public void prepareGlassFrame(Runnable ready) {
            if (ready == null) return;
            if (freezeController != null && freezeController.deferCaptureIfFrozen(this, ready)) {
                return;
            }
            dispatchUnfrozenFrame(ready);
        }

        @Override
        public boolean glassFrameAdvancing() {
            if (freezeController != null && freezeController.isFrozen()) {
                return false;
            }
            com.pilipala.glass.GlassworkSurface.FrameSource child = findDescendantFrameSource(this);
            return child != null && child.glassFrameAdvancing();
        }

        void dispatchUnfrozenFrame(Runnable ready) {
            if (ready == null) return;
            com.pilipala.glass.GlassworkSurface.FrameSource child = findDescendantFrameSource(this);
            if (child != null) {
                child.prepareGlassFrame(ready);
            } else {
                ready.run();
            }
        }

        @Override
        protected void onDetachedFromWindow() {
            if (freezeController != null) {
                freezeController.clearDeferredForHost(this);
            }
            super.onDetachedFromWindow();
        }

        private static com.pilipala.glass.GlassworkSurface.FrameSource findDescendantFrameSource(
                ViewGroup group) {
            if (group == null) return null;
            for (int i = 0; i < group.getChildCount(); i++) {
                com.pilipala.glass.GlassworkSurface.FrameSource found =
                        findFrameSourceInSubtree(group.getChildAt(i));
                if (found != null) return found;
            }
            return null;
        }

        private static com.pilipala.glass.GlassworkSurface.FrameSource findFrameSourceInSubtree(
                View view) {
            if (view == null || view.getVisibility() != View.VISIBLE) return null;
            if (view instanceof com.pilipala.glass.GlassworkSurface.FrameSource) {
                return (com.pilipala.glass.GlassworkSurface.FrameSource) view;
            }
            if (view instanceof ViewGroup) {
                ViewGroup vg = (ViewGroup) view;
                for (int i = 0; i < vg.getChildCount(); i++) {
                    com.pilipala.glass.GlassworkSurface.FrameSource found =
                            findFrameSourceInSubtree(vg.getChildAt(i));
                    if (found != null) return found;
                }
            }
            return null;
        }
    }

    FrameLayout newGlassBackdropRoot() {
        return new GlassFreezeFrameLayout(this, glassFreezeController);
    }

    final GlassFreezeController glassFreezeController =
            new GlassFreezeController(this::invalidateGlassBackdrop);

    private void invalidateGlassBackdrop() {
        if (root != null) {
            com.pilipala.glass.GlassworkSurface.invalidateBackdrop(root);
        }
    }

    Rect pendingDetailOrigin;
    PlayerTransitionHelper.TransitionHandle activeTransition;
    boolean pendingPlayerTransition;
    int transitionSerial;
    OnboardingScreen activeOnboarding;
    AuroraSurfaceView onboardingAurora;
    final Map<ViewGroup, Integer> savedOnboardingFocusability = new IdentityHashMap<>();
    final Map<View, Boolean> savedOnboardingViewFocusable = new IdentityHashMap<>();
    StartupIntro startupIntro;
    boolean introSkipKey;
    HomeAmbient homeAmbient;
    HomeDock homeDock;
    FrameLayout root;
    LinearLayout body;
    ScrollView scroll;
    Screen current;
    Cms.Config config;
    android.content.SharedPreferences prefs;
    boolean privateMode, switchingPrivacy;

    @Override
    public File getFilesDir() {
        File base = super.getFilesDir();
        if (!privateMode) return base;
        File scoped = new File(base, "private-space");
        scoped.mkdirs();
        return scoped;
    }

    @Override
    public File getCacheDir() {
        File base = super.getCacheDir();
        if (!privateMode) return base;
        File scoped = new File(base, "private-space");
        scoped.mkdirs();
        return scoped;
    }

    static final int REQ_STORAGE_PERMISSION = 1409;
    private Runnable pendingStorageAction;

    static boolean isManageAllFilesAction(String action) {
        return "android.settings.MANAGE_APP_ALL_FILES_ACCESS_PERMISSION".equals(action)
                || "android.settings.MANAGE_ALL_FILES_ACCESS_PERMISSION".equals(action);
    }

    static List<String> storagePermissionFallbackActions(int sdkInt) {
        List<String> actions = new ArrayList<>();
        if (sdkInt >= 30) {
            actions.add("android.settings.MANAGE_APP_ALL_FILES_ACCESS_PERMISSION");
            actions.add("android.settings.MANAGE_ALL_FILES_ACCESS_PERMISSION");
        }
        actions.add(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
        return actions;
    }

    boolean hasFullStoragePermission() {
        if (Build.VERSION.SDK_INT >= 30) {
            try {
                if (android.os.Environment.isExternalStorageManager()) return true;
            } catch (Throwable ignored) {
            }
            return false;
        }
        if (Build.VERSION.SDK_INT >= 23) {
            return super.checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE)
                            == android.content.pm.PackageManager.PERMISSION_GRANTED
                    && super.checkSelfPermission(android.Manifest.permission.READ_EXTERNAL_STORAGE)
                            == android.content.pm.PackageManager.PERMISSION_GRANTED;
        }
        return true;
    }

    boolean hasLegacyStorageWritePermission() {
        if (hasFullStoragePermission()) return true;
        if (Build.VERSION.SDK_INT >= 23
                && super.checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE)
                        != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            return false;
        }
        try {
            File tvDir = new File(android.os.Environment.getExternalStorageDirectory(), "TV");
            if (!tvDir.exists()) tvDir.mkdirs();
            if (!tvDir.isDirectory() || !tvDir.canWrite()) return false;
            File probe = new File(tvDir, ".mm_perm_probe");
            if (probe.createNewFile() || probe.exists()) {
                probe.delete();
                return true;
            }
        } catch (Throwable ignored) {
        }
        return false;
    }

    String storagePermissionStatusText() {
        if (hasFullStoragePermission()) return "已授权（扫码 Cookie 可正常保存）";
        if (hasLegacyStorageWritePermission()) return "已授权文件读写（部分扩展可能仍需「管理所有文件」）";
        return Build.VERSION.SDK_INT >= 30
                ? "未开启「管理所有文件」权限，扫码 Cookie 可能无法保存"
                : "未开启存储权限，扫码 Cookie 可能无法保存";
    }

    void requestRuntimeStoragePermission(Runnable onAfter) {
        pendingStorageAction = onAfter;
        if (Build.VERSION.SDK_INT < 23) {
            CspEngine.prepareHostStorage(getApplication());
            Runnable next = pendingStorageAction;
            pendingStorageAction = null;
            if (next != null) next.run();
            return;
        }
        if (super.checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE)
                        == android.content.pm.PackageManager.PERMISSION_GRANTED
                && super.checkSelfPermission(android.Manifest.permission.READ_EXTERNAL_STORAGE)
                        == android.content.pm.PackageManager.PERMISSION_GRANTED) {
            CspEngine.prepareHostStorage(getApplication());
            Runnable next = pendingStorageAction;
            pendingStorageAction = null;
            if (next != null) next.run();
            return;
        }
        try {
            requestPermissions(
                    new String[] {
                        android.Manifest.permission.READ_EXTERNAL_STORAGE,
                        android.Manifest.permission.WRITE_EXTERNAL_STORAGE
                    },
                    REQ_STORAGE_PERMISSION);
        } catch (Throwable t) {
            AppLog.w("StoragePerm", "requestPermissions failed", t);
            pendingStorageAction = null;
            openTvStoragePermissionSettings();
        }
    }

    boolean openTvStoragePermissionSettings() {
        android.net.Uri pkgUri = android.net.Uri.parse("package:" + getPackageName());
        for (String action : storagePermissionFallbackActions(Build.VERSION.SDK_INT)) {
            Intent intent =
                    "android.settings.MANAGE_ALL_FILES_ACCESS_PERMISSION".equals(action)
                            ? new Intent(action)
                            : new Intent(action, pkgUri);
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            try {
                if (intent.resolveActivity(getPackageManager()) == null) continue;
                super.startActivity(intent, null);
                if (android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS.equals(action)) {
                    toast("请在「权限 → 文件和媒体 / 存储」中选择「始终允许」，完成后按返回键");
                } else {
                    toast("请开启 Marco Movie 的「允许管理所有文件」开关，完成后按返回键");
                }
                return true;
            } catch (Throwable ignored) {
            }
        }
        toast("当前电视系统未开放文件管理设置页，正在申请应用存储权限…");
        requestRuntimeStoragePermission(null);
        return false;
    }

    void ensureStoragePermissionForNetdisk(final Runnable proceed) {
        if (proceed == null) return;
        if (hasFullStoragePermission()) {
            CspEngine.prepareHostStorage(getApplication());
            proceed.run();
            return;
        }
        if (Build.VERSION.SDK_INT < 30) {
            requestRuntimeStoragePermission(proceed);
            return;
        }
        if (hasLegacyStorageWritePermission()) {
            CspEngine.prepareHostStorage(getApplication());
            proceed.run();
            return;
        }
        new AppDialog.Builder(this)
                .setTitle("需要存储权限以保存扫码 Cookie")
                .setMessage(
                        "网盘扫码登录获得的 Cookie 需要写入本机存储目录（/sdcard/TV），未授权时电视端会提示无法保存。\n\n"
                                + "• Android 11 及以上电视：点击「开启文件权限」并在系统页中允许「管理所有文件」或「权限 → 文件和媒体 → 始终允许」\n"
                                + "• 若电视精简了系统设置页，可点击「快速申请读写」尝试系统授权弹窗")
                .setPositiveButton("开启文件权限", (d, w) -> openTvStoragePermissionSettings())
                .setNeutralButton("快速申请读写", (d, w) -> requestRuntimeStoragePermission(proceed))
                .setNegativeButton("仍要继续", (d, w) -> proceed.run())
                .show();
    }

    @Override
    public void startActivity(Intent intent, Bundle options) {
        if (intent != null && isManageAllFilesAction(intent.getAction())) {
            try {
                if (intent.resolveActivity(getPackageManager()) != null) {
                    super.startActivity(intent, options);
                    return;
                }
            } catch (Throwable ignored) {
            }
            if (openTvStoragePermissionSettings()) {
                return;
            }
        }
        super.startActivity(intent, options);
    }

    @Override
    public void onRequestPermissionsResult(
            int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQ_STORAGE_PERMISSION) {
            boolean granted = false;
            if (grantResults != null && grantResults.length > 0) {
                granted = true;
                for (int r : grantResults) {
                    if (r != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                        granted = false;
                        break;
                    }
                }
            }
            if (granted) {
                CspEngine.prepareHostStorage(getApplication());
                toast("存储权限已开启，现在可正常保存扫码 Cookie");
            } else {
                toast("未获得存储权限，可在系统「应用详情 → 权限 → 存储」中手动开启");
            }
            Runnable next = pendingStorageAction;
            pendingStorageAction = null;
            if (next != null) ui.post(next);
        }
    }

    @Override
    public int checkSelfPermission(String permission) {
        if (CspEngine.isStoragePermission(permission) && CspEngine.hasGrantedAllFilesAccess()) {
            return android.content.pm.PackageManager.PERMISSION_GRANTED;
        }
        return super.checkSelfPermission(permission);
    }

    @Override
    public int checkPermission(String permission, int pid, int uid) {
        if (CspEngine.isStoragePermission(permission) && CspEngine.hasGrantedAllFilesAccess()) {
            return android.content.pm.PackageManager.PERMISSION_GRANTED;
        }
        return super.checkPermission(permission, pid, uid);
    }

    boolean reduced, prepared, playing, foreground;
    int generation;
    static final int MAX_HOME_SNAPSHOTS = 8;
    final Map<String, SourceEngine> engines = new HashMap<>();
    final SingleFlight<SourceEngine> engineInitializations = new SingleFlight<>();
    final Map<String, HomeScreen.Snapshot> homeData =
            Collections.synchronizedMap(
                    new LinkedHashMap<String, HomeScreen.Snapshot>(16, 0.75f, true) {
                        @Override
                        protected boolean removeEldestEntry(
                                Map.Entry<String, HomeScreen.Snapshot> eldest) {
                            return size() > MAX_HOME_SNAPSHOTS;
                        }
                    });
    AppDialog appDialog;
    FrameLayout playbackLayer;
    MiniDetails miniDetails;
    boolean miniMode;
    boolean changingMiniEpisode;
    FrameLayout playerOverlay;
    boolean controlsVisible = true;
    boolean playerLocked;
    Runnable hideControls;
    Runnable hideLockButton;
    static final String TOOL_DECLARATION =
            "本产品仅为播放工具，不内置、不提供、不托管任何影视资源或配置地址。请自行合法获取内容与配置，并确保拥有相应使用权。";
    MobileRootShell mobileShell;
    MobileInlinePlayer inlinePlayer;
    MobilePlayerOverlay mobilePlayerOverlay;
    private android.content.SharedPreferences cachedMobilePrefs;
    private android.content.SharedPreferences cachedSecretsPrefs;

    android.content.SharedPreferences mobilePrefs() {
        String targetName = privateMode ? "movie_mobile_private" : Prefs.MOBILE_FILE;
        if (cachedMobilePrefs == null) {
            cachedMobilePrefs = getSharedPreferences(targetName, MODE_PRIVATE);
        }
        return cachedMobilePrefs;
    }

    android.content.SharedPreferences secretsPrefs() {
        if (cachedSecretsPrefs == null) {
            cachedSecretsPrefs = getSharedPreferences(Prefs.SECRETS_FILE, MODE_PRIVATE);
        }
        return cachedSecretsPrefs;
    }

    int mobileAccentColor() {
        return Prefs.accentColorForPreset(mobilePrefs().getInt(Prefs.ACCENT_PRESET, 0));
    }

    boolean isReducedTransparency() {
        return prefs != null && prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false);
    }

    boolean enterAppPip() {
        if (android.os.Build.VERSION.SDK_INT < 26) return false;
        try {
            android.app.PictureInPictureParams.Builder b =
                    new android.app.PictureInPictureParams.Builder();
            b.setAspectRatio(new android.util.Rational(16, 9));
            return enterPictureInPictureMode(b.build());
        } catch (Throwable ignored) {
            return false;
        }
    }

    TouchPlayerGesture touchPlayerGesture;
    PlayerChrome playerChrome;
    MoviePlayer player;
    com.pilipala.emby.EmbyLibrary.Reporter embyReporter;
    String configOrigin = "";
    TextView playStatus, playClock;
    final SeekGesture seekGesture = new SeekGesture();
    String seekStatus = "";
    final Runnable seekPulse =
            new Runnable() {
                public void run() {
                    if (!seekGesture.active) return;
                    if (player == null
                            || !prepared
                            || current == null
                            || !current.player
                            || miniMode
                            || !foreground) {
                        finishSeek(false);
                        return;
                    }
                    seekGesture.advance(SystemClock.uptimeMillis());
                    previewSeek();
                    scheduleHide();
                    ui.postDelayed(this, 100);
                }
            };

    static final class Screen {
        MobileRootShell mobileHome;
        Runnable render;
        String focus, homeReturnFocus;
        int scroll;
        int episodeFocus = -1;
        String episodeFocusLine = "";
        final EpisodeSelection selection = new EpisodeSelection();
        boolean player, home;
        HomeScreen.State homeState;
        HomeScreen retainedHome;

        /** True while a listing redirect (folder / action / cross-search) has not drawn a page. */
        boolean redirect;

        Screen(Runnable r) {
            render = r;
        }
    }

    /** Foreground activity that source extensions may need for dialogs; cleared on destroy. */
    static volatile MainActivity activeActivity;

    /**
     * Extension background threads must never take the whole app down. Main-thread errors and
     * crashes without extension frames still reach the system handler unchanged.
     */
    static boolean isPluginBackgroundCrash(Thread thread, Throwable error, Thread mainThread) {
        return ListingRoute.isPluginBackgroundCrash(thread, error, mainThread);
    }

    private static volatile boolean crashGuardInstalled;

    static void installPluginCrashGuard() {
        ProxyAddress.ensureLoopbackDirectProxySelector();
        if (crashGuardInstalled) return;
        crashGuardInstalled = true;
        final Thread.UncaughtExceptionHandler previous =
                Thread.getDefaultUncaughtExceptionHandler();
        final Thread main = android.os.Looper.getMainLooper().getThread();
        Thread.setDefaultUncaughtExceptionHandler(
                (thread, error) -> {
                    boolean pluginTrace =
                            ListingRoute.hasPluginFrame(error) || hasDexClassLoaderFrame(error);
                    boolean bgPlugin =
                            isPluginBackgroundCrash(thread, error, main)
                                    || (thread != null
                                            && thread != main
                                            && (pluginTrace
                                                    || thread.getContextClassLoader()
                                                            instanceof
                                                            dalvik.system.DexClassLoader));
                    if (bgPlugin) {
                        AppLog.w(
                                "PluginGuard",
                                "extension thread failed: " + thread.getName(),
                                error);
                        MainActivity activity = activeActivity;
                        if (activity != null)
                            activity.ui.post(
                                    () -> {
                                        if (!activity.isFinishing())
                                            activity.toast("来源扩展出错，已拦截，应用继续运行");
                                    });
                        return;
                    }
                    if (thread == main && pluginTrace) {
                        AppLog.w("PluginGuard", "extension main-thread callback failed", error);
                        MainActivity activity = activeActivity;
                        if (activity != null && activity.prefs != null) {
                            activity.prefs.edit().putString(Prefs.LOADING_SITE, "").commit();
                            activity.ui.post(
                                    () -> {
                                        if (!activity.isFinishing()) activity.toast("扩展操作未能完成，请重试");
                                    });
                        }
                        while (true) {
                            try {
                                android.os.Looper.loop();
                                return;
                            } catch (Throwable nextError) {
                                if (!ListingRoute.hasPluginFrame(nextError)
                                        && !hasDexClassLoaderFrame(nextError)) {
                                    CrashReportStore.recordUncaughtCrash(
                                            activeActivity, thread, nextError);
                                    if (previous != null)
                                        previous.uncaughtException(thread, nextError);
                                    return;
                                }
                                AppLog.w(
                                        "PluginGuard",
                                        "extension main-thread follow-up error",
                                        nextError);
                            }
                        }
                    }
                    AppLog.w(
                            "FatalCrash",
                            "uncaught on " + (thread == null ? "?" : thread.getName()),
                            error);
                    MainActivity activity = activeActivity;
                    CrashReportStore.recordUncaughtCrash(activity, thread, error);
                    if (activity != null && activity.prefs != null) {
                        String currentSite = activity.prefs.getString(Prefs.SELECTED_SITE, "");
                        if (currentSite != null && !currentSite.isEmpty()) {
                            activity.prefs
                                    .edit()
                                    .putString(Prefs.LOADING_SITE, currentSite)
                                    .commit();
                        }
                    }
                    if (previous != null) previous.uncaughtException(thread, error);
                });
    }

    static boolean hasDexClassLoaderFrame(Throwable error) {
        if (error == null) return false;
        LinkedHashSet<ClassLoader> loaders = new LinkedHashSet<>(CspEngine.LOADERS.values());
        synchronized (CspEngine.ALL_PLUGIN_LOADERS) {
            loaders.addAll(CspEngine.ALL_PLUGIN_LOADERS);
        }
        if (loaders.isEmpty()) return false;
        int depth = 0;
        for (Throwable t = error; t != null && depth < 12; t = t.getCause(), depth++) {
            for (StackTraceElement e : t.getStackTrace()) {
                String cls = e.getClassName();
                if (cls == null
                        || cls.startsWith("android.")
                        || cls.startsWith("java.")
                        || cls.startsWith("javax.")
                        || cls.startsWith("dalvik.")
                        || cls.startsWith("com.android.")
                        || cls.startsWith("com.pilipala.")) continue;
                for (ClassLoader loader : loaders) {
                    try {
                        Class<?> loaded = Class.forName(cls, false, loader);
                        ClassLoader loadedCl = loaded.getClassLoader();
                        if (loadedCl == loader
                                || (loadedCl instanceof dalvik.system.BaseDexClassLoader
                                        && loadedCl != MainActivity.class.getClassLoader())) {
                            return true;
                        }
                    } catch (Throwable ignored) {
                    }
                }
            }
            if (t.getCause() == t) break;
        }
        return false;
    }

    /** Opens a list card without leaving an invisible redirect page in the back stack. */
    void openListing(Cms.Site s, Cms.Video v) {
        if (v == null) return;
        if (v.action != null && !v.action.isEmpty()) {
            sourceAction(s, v.action);
            return;
        }
        if ("action".equalsIgnoreCase(v.tag) && v.id != null && !v.id.isEmpty()) {
            sourceAction(s, v.id);
            return;
        }
        if ("folder".equalsIgnoreCase(v.tag)) {
            open(new Screen(() -> videos(s, v.id, v.title, 1, null)), true);
            return;
        }
        if (v.id != null && v.id.startsWith("msearch:")) {
            crossSearch(Cms.searchTitle(v));
            return;
        }
        if (SourceController.isConfigOrNetdiskActionCard(s, v)) {
            SourceController.sourceAction(this, s, v.id, true);
            return;
        }
        open(new Screen(() -> detail(s, v)), true);
    }

    /**
     * Called by a detail redirect that will not draw its own page. Restores the page underneath
     * so Back never re-runs the redirect forever.
     */
    void dropRedirect() {
        if (current != null && current.redirect && !back.isEmpty()) current = back.pop();
    }

    static boolean isRedirectListing(Cms.Video v) {
        return v != null && ListingRoute.isRedirect(v.tag, v.action, v.id);
    }

    /**
     * Detail pages reached for a folder, action or cross-search card hand over to the real page.
     * The invisible detail screen is removed first, so Back returns to the list instead of
     * re-opening the folder in a loop.
     */
    boolean redirectListing(Cms.Site s, Cms.Video v) {
        if (!isRedirectListing(v) && !SourceController.isConfigOrNetdiskActionCard(s, v)) {
            return false;
        }
        if (current != null) current.redirect = true;
        if (back.isEmpty() && "folder".equalsIgnoreCase(v.tag)) {
            open(new Screen(() -> videos(s, v.id, v.title, 1, null)), false);
            return true;
        }
        dropRedirect();
        openListing(s, v);
        return true;
    }

    interface Work<T> {
        T run() throws Exception;
    }

    interface Done<T> {
        void accept(T value) throws Exception;
    }

    static int[] viewportHint;
    boolean layoutReady, layoutIntro;
    int usableWidth, usableHeight;
    int formFactor = TvLayoutPolicy.FORM_PHONE;

    static int detectFormFactor(Context base, int widthPixels, int heightPixels, int densityDpi) {
        int smallestDp =
                densityDpi > 0
                        ? Math.round(Math.min(widthPixels, heightPixels) * 160f / densityDpi)
                        : 360;
        return smallestDp >= 600 ? TvLayoutPolicy.FORM_TABLET : TvLayoutPolicy.FORM_PHONE;
    }

    boolean isTvDevice() {
        return formFactor == TvLayoutPolicy.FORM_TV;
    }

    boolean isPortrait() {
        return TvLayoutPolicy.isPortrait(windowWidth(), windowHeight());
    }

    boolean useBottomDock() {
        return TvLayoutPolicy.useBottomDock(windowWidth(), windowHeight(), formFactor);
    }

    boolean useTopDock() {
        return isTvDevice() && !useLeftDock();
    }

    boolean useLeftDock() {
        return isTvDevice() && prefs.getInt(Prefs.TV_NAVIGATION_MODE, 0) == 1;
    }

    void applyMobileSystemBars(boolean fullscreenPlayer) {
        if (isTvDevice()) return;
        try {
            Window w = getWindow();
            if (w == null) return;
            WindowManager.LayoutParams lp = w.getAttributes();
            try {
                java.lang.reflect.Field f = lp.getClass().getField("layoutInDisplayCutoutMode");
                // 1 == WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                if (f.getInt(lp) != 1) {
                    f.setInt(lp, 1);
                    w.setAttributes(lp);
                }
            } catch (Throwable ignored) {
            }
            if (fullscreenPlayer) {
                w.addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN);
                w.getDecorView().setSystemUiVisibility(5894);
            } else {
                w.clearFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN);
                w.clearFlags(WindowManager.LayoutParams.FLAG_TRANSLUCENT_STATUS);
                w.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS);
                w.getDecorView()
                        .setSystemUiVisibility(
                                View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                                        | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN);
                w.setStatusBarColor(Color.TRANSPARENT);
                w.setNavigationBarColor(0xff060a08);
            }
        } catch (Throwable ignored) {
        }
    }

    int navigationBarHeight() {
        if (isTvDevice()) return 0;
        try {
            Window w = getWindow();
            if (w == null || root == null) return 0;
            android.util.DisplayMetrics dm = new android.util.DisplayMetrics();
            if (android.os.Build.VERSION.SDK_INT >= 17) {
                getWindowManager().getDefaultDisplay().getRealMetrics(dm);
            } else {
                getWindowManager().getDefaultDisplay().getMetrics(dm);
            }
            int[] loc = new int[2];
            root.getLocationOnScreen(loc);
            int rootBottom = loc[1] + root.getHeight();
            // Only return bottom inset when the view actually extends into the system bar zone
            if (root.getHeight() > 0 && dm.heightPixels - rootBottom >= dp(24)) {
                return 0;
            }
            if (android.os.Build.VERSION.SDK_INT >= 23) {
                android.view.WindowInsets insets = w.getDecorView().getRootWindowInsets();
                if (insets != null) {
                    return Math.max(0, Math.min(dp(48), insets.getSystemWindowInsetBottom()));
                }
            }
        } catch (Throwable ignored) {
        }
        return 0;
    }

    void togglePlayerOrientation() {
        if (isTvDevice() || playerLocked) return;
        if (isPortrait()) {
            setRequestedOrientation(
                    android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE);
        } else {
            setRequestedOrientation(android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT);
        }
        if (playerChrome != null) playerChrome.relayout();
    }

    int windowWidth() {
        return usableWidth > 0 ? usableWidth : getResources().getDisplayMetrics().widthPixels;
    }

    int windowHeight() {
        return usableHeight > 0 ? usableHeight : getResources().getDisplayMetrics().heightPixels;
    }

    @Override
    protected void attachBaseContext(Context base) {
        android.util.DisplayMetrics screen = new android.util.DisplayMetrics();
        ((WindowManager) base.getSystemService(Context.WINDOW_SERVICE))
                .getDefaultDisplay()
                .getMetrics(screen);
        int detectedForm =
                detectFormFactor(base, screen.widthPixels, screen.heightPixels, screen.densityDpi);
        int percent =
                Prefs.clampMobileUiScale(
                        base.getSharedPreferences(Prefs.MOBILE_FILE, 0)
                                .getInt(Prefs.MOBILE_UI_SCALE_PERCENT, 100));
        int[] hint = viewportHint;
        if (hint != null && hint[0] == screen.widthPixels && hint[1] == screen.heightPixels) {
            screen.widthPixels = hint[2];
            screen.heightPixels = hint[3];
        }
        android.content.res.Configuration layout =
                new android.content.res.Configuration(base.getResources().getConfiguration());
        layout.densityDpi =
                TvLayoutPolicy.deviceDensityDpi(
                        screen.widthPixels, screen.heightPixels, percent, detectedForm);
        float density = layout.densityDpi / 160f;
        if (detectedForm == TvLayoutPolicy.FORM_TV) {
            layout.screenWidthDp =
                    Math.round(Math.max(screen.widthPixels, screen.heightPixels) / density);
            layout.screenHeightDp =
                    Math.round(Math.min(screen.widthPixels, screen.heightPixels) / density);
        } else {
            layout.screenWidthDp = Math.round(screen.widthPixels / density);
            layout.screenHeightDp = Math.round(screen.heightPixels / density);
        }
        layout.smallestScreenWidthDp = Math.min(layout.screenWidthDp, layout.screenHeightDp);
        super.attachBaseContext(base.createConfigurationContext(layout));
    }

    @Override
    public void onCreate(Bundle b) {
        super.onCreate(b);
        privateMode = PrivacySpace.active;
        if (privateMode) getWindow().addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE);
        activeActivity = this;
        installPluginCrashGuard();
        android.util.DisplayMetrics rawScreen = new android.util.DisplayMetrics();
        getWindowManager().getDefaultDisplay().getMetrics(rawScreen);
        formFactor =
                detectFormFactor(
                        this, rawScreen.widthPixels, rawScreen.heightPixels, rawScreen.densityDpi);
        setRequestedOrientation(
                isTvDevice()
                        ? android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                        : android.content.pm.ActivityInfo.SCREEN_ORIENTATION_USER);
        configStore = new ConfigStore(getFilesDir());
        if (isTvDevice()) {
            getWindow().getDecorView().setSystemUiVisibility(5894);
        } else {
            applyMobileSystemBars(false);
        }
        prefs = getSharedPreferences(privateMode ? "movie-private" : Prefs.FILE, MODE_PRIVATE);
        final int priorBootCrashes = recordStartupBootGuard(getCacheDir());
        final boolean priorLoadingCrash = !prefs.getString(Prefs.LOADING_SITE, "").isEmpty();
        if (priorBootCrashes >= 1 || priorLoadingCrash) {
            purgeVolatileCrashCaches(getCacheDir());
            if (priorBootCrashes >= 2) {
                clearRecoveredCrashSite(prefs);
            }
        }
        if (isTvDevice() && !prefs.getBoolean("tv_top_nav_default_v1", false)) {
            prefs.edit()
                    .putInt(Prefs.TV_NAVIGATION_MODE, 0)
                    .putInt(Prefs.TV_DOCK_POSITION, 1)
                    .putBoolean("tv_top_nav_default_v1", true)
                    .apply();
        }
        WatchHistory.historyCorrupted = prefs.getBoolean(WatchHistory.CORRUPTED_PREF, false);
        if (WatchHistory.historyCorrupted) {
            ui.post(() -> toast("检测到观看历史数据损坏，已自动备份至本地。为保护数据，已暂停历史更新与云端覆盖。"));
        }
        reduced = prefs.getBoolean(Prefs.REDUCED, false);
        configOrigin = prefs.getString("origin", "");
        try {
            ActivityManager am = (ActivityManager) getSystemService(Context.ACTIVITY_SERVICE);
            if (am != null) {
                int memClass = am.getMemoryClass();
                images.resize(ImageDecodePolicy.cacheBytes(memClass));
                ImmersivePoster.applyMemoryBudget(memClass);
            }
        } catch (Exception ignored) {
        }
        try {
            File f = new File(getFilesDir(), "config.json");
            if (f.exists())
                try (InputStream i = new FileInputStream(f)) {
                    config = Cms.parseConfig(Cms.read(i, Cms.MAX_JSON), configOrigin);
                    SourcePicker.applyEdits(this, config, configOrigin);
                    if (priorBootCrashes == 0 && !priorLoadingCrash) {
                        SourcePreferences.restoreDefault(this);
                    }
                }
        } catch (Exception e) {
            AppLog.w("MainActivity", "load saved config failed", e);
            config = null;
        }
        // Phone / tablet only: restore the offline download queue (never started on TV).
        if (!isTvDevice()) DownloadManager.get(this);
        initializePhonetic();
        layoutIntro = b == null || b.getBoolean("layout_initial_launch", false);
        root = newGlassBackdropRoot();
        root.setBackgroundColor(DARK);
        setContentView(root);
        root.addOnLayoutChangeListener(
                new View.OnLayoutChangeListener() {
                    public void onLayoutChange(
                            View view,
                            int l,
                            int t,
                            int r,
                            int bottom,
                            int ol,
                            int ot,
                            int or,
                            int ob) {
                        int width = r - l, height = bottom - t;
                        if (width <= 0 || height <= 0) return;
                        view.removeOnLayoutChangeListener(this);
                        usableWidth = width;
                        usableHeight = height;
                        int expected =
                                TvLayoutPolicy.deviceDensityDpi(
                                        width,
                                        height,
                                        Prefs.clampMobileUiScale(
                                                mobilePrefs()
                                                        .getInt(
                                                                Prefs.MOBILE_UI_SCALE_PERCENT,
                                                                100)),
                                        formFactor);
                        if (viewportHint == null
                                && expected != getResources().getDisplayMetrics().densityDpi) {
                            android.util.DisplayMetrics display = new android.util.DisplayMetrics();
                            getWindowManager().getDefaultDisplay().getMetrics(display);
                            viewportHint =
                                    new int[] {
                                        display.widthPixels, display.heightPixels, width, height
                                    };
                            recreate();
                            return;
                        }
                        ui.post(
                                () -> {
                                    if (isFinishing() || isDestroyed()) return;
                                    String crashedSite = prefs.getString(Prefs.LOADING_SITE, "");
                                    boolean recoveredFromCrash =
                                            crashedSite != null && !crashedSite.isEmpty();
                                    if (recoveredFromCrash) {
                                        clearRecoveredCrashSite(prefs);
                                    }
                                    worker.execute(
                                            () ->
                                                    MagnetStream.cleanStaleSessions(
                                                            MainActivity.this));
                                    if (!reduced
                                            && !recoveredFromCrash
                                            && priorBootCrashes == 0
                                            && config != null) {
                                        final String savedKey =
                                                prefs.getString(Prefs.SELECTED_SITE, "");
                                        if (savedKey != null && !savedKey.isEmpty()) {
                                            for (final Cms.Site s : config.sites) {
                                                if (s != null
                                                        && savedKey.equals(s.key)
                                                        && available(s)
                                                        && shouldPrewarmSiteOnStartup(s)) {
                                                    worker.execute(
                                                            () -> {
                                                                try {
                                                                    engine(s);
                                                                } catch (Throwable ignored) {
                                                                }
                                                            });
                                                    break;
                                                }
                                            }
                                        }
                                    }
                                    open(new Screen(() -> home()), false);
                                    layoutReady = true;
                                    ui.postDelayed(
                                            () -> clearStartupBootGuard(getCacheDir()), 3500);
                                    if (!privateMode) {
                                        CloudSyncDialog.pullOnStartup(MainActivity.this);
                                        CrashReportDialog.maybePromptOnStartup(MainActivity.this);
                                        if (priorBootCrashes < 2) {
                                            ui.postDelayed(
                                                    () ->
                                                            SourceController
                                                                    .runDailyAutoUpdateIfNeeded(
                                                                            MainActivity.this,
                                                                            false),
                                                    3800);
                                        }
                                    }
                                    if (recoveredFromCrash) {
                                        toast("上次加载该片源时异常退出，已自动重置片源选择");
                                    } else if (priorBootCrashes >= 2) {
                                        toast("检测到连续异常退出，已清理临时缓存并重置片源");
                                    } else if (priorBootCrashes == 1) {
                                        toast("检测到上次异常退出，已自动清理临时缓存");
                                    } else if (!privateMode
                                            && OnboardingScreen.shouldShow(MainActivity.this)) {
                                        showOnboarding(false);
                                    } else if (layoutIntro && isTvDevice()) {
                                        StartupIntro.show(MainActivity.this);
                                    }
                                });
                    }
                });
    }

    @Override
    public void onConfigurationChanged(android.content.res.Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        if (!layoutReady || root == null) return;
        if (!isTvDevice() && usableWidth > 0 && usableHeight > 0 && newConfig != null) {
            boolean configPortrait =
                    newConfig.orientation == android.content.res.Configuration.ORIENTATION_PORTRAIT;
            boolean configLandscape =
                    newConfig.orientation
                            == android.content.res.Configuration.ORIENTATION_LANDSCAPE;
            if ((configPortrait && usableWidth > usableHeight)
                    || (configLandscape && usableWidth < usableHeight)) {
                int tmp = usableWidth;
                usableWidth = usableHeight;
                usableHeight = tmp;
                if (current != null && current.player) {
                    if (playerChrome != null) playerChrome.scheduleLayout();
                } else if (current != null) {
                    refresh();
                }
            }
        }
        root.post(this::syncRootDimensions);
        ui.postDelayed(this::syncRootDimensions, 140);
    }

    void syncRootDimensions() {
        if (isFinishing() || isDestroyed() || root == null || !layoutReady) return;
        int w = root.getWidth(), h = root.getHeight();
        if (w <= 0 || h <= 0) return;
        boolean orientationFlipped = (w < h) != (usableWidth < usableHeight);
        if (w != usableWidth || h != usableHeight) {
            usableWidth = w;
            usableHeight = h;
            if (current != null && current.player) {
                if (playerChrome != null) playerChrome.relayout();
                if (playbackControls != null)
                    playbackControls.resize(
                            playbackControls.videoWidth, playbackControls.videoHeight);
            } else if (current != null && orientationFlipped) {
                refresh();
            }
        }
    }

    void watchRootLayout(FrameLayout targetRoot) {
        if (targetRoot == null) return;
        targetRoot.addOnLayoutChangeListener(
                (view, l, t, r, b, ol, ot, or, ob) -> {
                    int w = r - l, h = b - t;
                    if (w <= 0 || h <= 0 || !layoutReady || view != root) return;
                    if (w != usableWidth || h != usableHeight) {
                        ui.post(this::syncRootDimensions);
                    }
                });
    }

    @Override
    protected void onSaveInstanceState(Bundle out) {
        out.putBoolean("layout_initial_launch", !layoutReady && layoutIntro);
        super.onSaveInstanceState(out);
    }

    int dp(float x) {
        return Math.round(x * getResources().getDisplayMetrics().density);
    }

    void glass(View view, float radius) {
        com.pilipala.glass.GlassworkSurface.attach(
                view,
                root,
                dp(radius),
                () ->
                        glassFreezeController.shouldReduceTransparency(
                                prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false)));
    }

    GradientDrawable bg(int color, float radius) {
        GradientDrawable d = new GradientDrawable();
        d.setColor(color);
        d.setCornerRadius(dp(radius));
        return d;
    }

    TextView text(String s, float size, int color) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextColor(color);
        t.setTextSize(size);
        t.setFontFeatureSettings("kern");
        return t;
    }

    LinearLayout vertical() {
        LinearLayout v = new LinearLayout(this);
        v.setOrientation(LinearLayout.VERTICAL);
        return v;
    }

    LinearLayout row() {
        LinearLayout v = new LinearLayout(this);
        v.setOrientation(LinearLayout.HORIZONTAL);
        v.setGravity(Gravity.CENTER_VERTICAL);
        return v;
    }

    void gap(LinearLayout p, int n) {
        View v = new View(this);
        p.addView(v, new LinearLayout.LayoutParams(1, dp(n)));
    }

    void paragraph(String s) {
        TextView t = text(s, 16, MUTED);
        t.setLineSpacing(dp(5), 1);
        body.addView(t);
        gap(body, 14);
    }

    Button button(String label, String key, Runnable action) {
        Button b = new Button(this);
        b.setText(label);
        b.setTextSize(15);
        b.setTextColor(WHITE);
        b.setAllCaps(false);
        b.setGravity(Gravity.CENTER);
        b.setIncludeFontPadding(false);
        b.setStateListAnimator(null);
        b.setOutlineProvider(null);
        b.setMinHeight(dp(48));
        b.setMinimumHeight(dp(48));
        b.setPadding(dp(20), dp(9), dp(20), dp(9));
        b.setBackground(bg(0xff242429, 12));
        b.setTag(key);
        UiCompat.setDefaultFocusHighlightEnabled(b, false);
        b.setFocusable(true);
        b.setFocusableInTouchMode(isTvDevice());
        b.setOnClickListener(v -> action.run());
        pressFeedback(b);
        b.setOnFocusChangeListener(
                (v, f) ->
                        FocusMotion.style(
                                this, b, f, 0xff242429, WHITE, 12, WHITE, DARK, false, 1.025f));
        return b;
    }

    void pressFeedback(View view) {
        view.setOnTouchListener(
                (v, event) -> {
                    if (!isTvDevice()) {
                        if (event.getAction() == android.view.MotionEvent.ACTION_DOWN) {
                            v.setAlpha(0.75f);
                        } else if (event.getAction() == android.view.MotionEvent.ACTION_UP
                                || event.getAction() == android.view.MotionEvent.ACTION_CANCEL) {
                            v.setAlpha(1.0f);
                        }
                        return false;
                    }
                    if (event.getAction() == android.view.MotionEvent.ACTION_DOWN) {
                        v.requestFocus();
                        FocusMotion.press(this, v, true);
                    } else if (event.getAction() == android.view.MotionEvent.ACTION_UP
                            || event.getAction() == android.view.MotionEvent.ACTION_CANCEL)
                        FocusMotion.press(this, v, false);
                    return false;
                });
        view.setOnKeyListener(
                (v, key, event) -> {
                    FocusMotion.key(this, v, key, event);
                    return false;
                });
    }

    Button navButton(String label, String key, Runnable action) {
        Button b = button(label, key, action);
        b.setTextSize(13.5f);
        b.setSingleLine(true);
        b.setEllipsize(android.text.TextUtils.TruncateAt.END);
        b.setMinWidth(0);
        b.setMinimumWidth(0);
        b.setPadding(dp(14), dp(6), dp(14), dp(6));
        b.setMinHeight(dp(38));
        b.setMinimumHeight(dp(38));
        GradientDrawable pill = bg(0xff282832, 19);
        pill.setStroke(Math.max(1, dp(1)), 0x26ffffff);
        b.setBackground(pill);
        b.setTextColor(0xffe6e6ee);
        b.setOnFocusChangeListener(
                (v, f) ->
                        FocusMotion.style(
                                this, b, f, 0xff282832, WHITE, 19, 0xffe6e6ee, DARK, false, 1.02f));
        return b;
    }

    void chooseOrImport() {
        if (config == null) importDialog();
        else chooseSources();
    }

    void addButton(LinearLayout p, Button b) {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
        lp.setMargins(dp(4), dp(5), dp(10), dp(8));
        p.addView(b, lp);
    }

    int statusBarHeight() {
        int best = isTvDevice() ? 0 : dp(38);
        try {
            if (getWindow() != null && getWindow().getDecorView() != null) {
                WindowInsets insets = getWindow().getDecorView().getRootWindowInsets();
                if (insets != null) {
                    best = Math.max(best, insets.getSystemWindowInsetTop());
                    if (Build.VERSION.SDK_INT >= 28 && insets.getDisplayCutout() != null) {
                        best = Math.max(best, insets.getDisplayCutout().getSafeInsetTop());
                    }
                }
            }
        } catch (Exception ignored) {
        }
        try {
            int resId =
                    android.content.res.Resources.getSystem()
                            .getIdentifier("status_bar_height", "dimen", "android");
            if (resId > 0) {
                best =
                        Math.max(
                                best,
                                android.content.res.Resources.getSystem()
                                        .getDimensionPixelSize(resId));
            }
        } catch (Exception ignored) {
        }
        try {
            int resId = getResources().getIdentifier("status_bar_height", "dimen", "android");
            if (resId > 0) {
                best = Math.max(best, getResources().getDimensionPixelSize(resId));
            }
        } catch (Exception ignored) {
        }
        return best;
    }

    void renderPage(String title, String eyebrow) {
        renderPage(title, eyebrow, false);
    }

    void preparePage(boolean navigation) {
        cancelActiveTransition();
        dismissOnboarding();
        clearPlaybackLoading();
        cancelArtwork();
        cancelPageRequests();
        if (current != null) current.home = navigation;
        activeCastScreen = null;
        if (searchScreen != null) {
            searchScreen.close();
            searchScreen = null;
        }
        stopWeb();
        stopMagnet();
        releasePlayer();
        if (!isTvDevice()) {
            applyMobileSystemBars(false);
        }
        generation++;
    }

    void renderPage(String title, String eyebrow, boolean navigation) {
        preparePage(navigation);
        root = newGlassBackdropRoot();
        root.setClipChildren(false);
        root.setClipToPadding(false);
        root.setBackgroundColor(isTvDevice() ? 0xff0d0f14 : DARK);
        int tvBgMode = HomeAmbient.effectiveBgMode(this);
        if (!isTvDevice() || tvBgMode == Prefs.BG_MODE_WALLPAPER) {
            root.addView(ImageLoader.createAtmosphere(this), new FrameLayout.LayoutParams(-1, -1));
        }
        homeAmbient = null;
        boolean wantAmbient =
                isTvDevice()
                        ? (tvBgMode == Prefs.BG_MODE_ADAPTIVE || tvBgMode == Prefs.BG_MODE_GRADIENT)
                        : (navigation
                                && prefs.getBoolean(Prefs.HOME_AMBIENT, true)
                                && !prefs.getBoolean(Prefs.WALLPAPER_ENABLED, false));
        if (wantAmbient) {
            homeAmbient = new HomeAmbient(this);
            root.addView(homeAmbient, new FrameLayout.LayoutParams(-1, -1));
        }
        if (!isTvDevice() && navigation)
            root.addView(homeGradient(), new FrameLayout.LayoutParams(-1, -1));
        scroll = new TvScrollView(this);
        scroll.setClipChildren(false);
        scroll.setClipToPadding(false);
        scroll.setFillViewport(true);
        body = vertical();
        body.setClipChildren(false);
        body.setClipToPadding(false);
        if (!isTvDevice()) {
            int sidePad = isPortrait() ? dp(18) : dp(28);
            body.setPadding(sidePad, statusBarHeight() + dp(16), sidePad, dp(48));
        } else {
            body.setPadding(dp(46), dp(26), dp(46), dp(44));
        }
        scroll.addView(body, new ScrollView.LayoutParams(-1, -2));
        root.addView(scroll, new FrameLayout.LayoutParams(-1, -1));
        setContentView(root);
        watchRootLayout(root);
        homeDock = null;
        if (navigation) {
            homeDock = new HomeDock(this);
            if (useBottomDock()) {
                body.setPadding(dp(18), statusBarHeight() + dp(14), dp(18), dp(86));
            } else if (homeDock.tvTopLabeled) {
                body.setPadding(
                        homeDock.leftSafeInsetPx(),
                        homeDock.topSafeInsetPx(),
                        homeDock.rightSafeInsetPx(),
                        dp(36));
            } else if (useTopDock()) {
                body.setPadding(dp(34), dp(18), dp(34), dp(36));
            } else if (useLeftDock()) {
                body.setPadding(
                        homeDock.leftSafeInsetPx(), dp(18), homeDock.rightSafeInsetPx(), dp(36));
            } else {
                body.setPadding(dp(34), dp(18), dp(34), dp(36));
            }
            if (!homeDock.tvLeft && !homeDock.tvTopLabeled) {
                LinearLayout brandRow = row();
                brandRow.setTag("home-brand");
                brandRow.setGravity(Gravity.CENTER_VERTICAL);
                ImageView brandMark = new ImageView(this);
                brandMark.setImageResource(R.drawable.logo_mark);
                LinearLayout.LayoutParams brandSize = new LinearLayout.LayoutParams(dp(30), dp(30));
                brandSize.rightMargin = dp(10);
                brandRow.addView(brandMark, brandSize);
                TextView brand = text("MARCO MOVIE", 14, WHITE);
                brand.setIncludeFontPadding(false);
                brand.setSingleLine(true);
                brand.setLetterSpacing(.10f);
                brand.setTypeface(null, Typeface.BOLD);
                brandRow.addView(brand);
                if (homeDock.topMode) {
                    int dockLeftPx = Math.max(0, (windowWidth() - dp(homeDock.mainDp)) / 2);
                    int maxBrandWidth = dockLeftPx - dp(34 + 14);
                    if (maxBrandWidth < dp(90)) {
                        brand.setVisibility(View.GONE);
                    } else {
                        brand.setMaxWidth(Math.max(dp(50), maxBrandWidth - dp(40)));
                        brand.setEllipsize(android.text.TextUtils.TruncateAt.END);
                    }
                    FrameLayout.LayoutParams brandLayout =
                            new FrameLayout.LayoutParams(
                                    ViewGroup.LayoutParams.WRAP_CONTENT,
                                    dp(homeDock.crossDp),
                                    Gravity.LEFT | Gravity.TOP);
                    brandLayout.leftMargin = dp(34);
                    brandLayout.topMargin = dp(16);
                    root.addView(brandRow, brandLayout);
                    if (!title.isEmpty()) gap(body, 14);
                } else {
                    body.addView(brandRow);
                    gap(body, title.isEmpty() ? 14 : 22);
                }
            }
        }
        if (!title.isEmpty()) {
            TextView eye = text(eyebrow, 12, 0xffa9c9f3);
            eye.setLetterSpacing(.15f);
            body.addView(eye);
            gap(body, 10);
            TextView heading = text(title, 36, WHITE);
            heading.setTypeface(null, Typeface.BOLD);
            body.addView(heading);
            gap(body, 16);
        }
        if (!reduced) {
            body.setTranslationY(dp(4));
            body.animate()
                    .translationY(0)
                    .setDuration(140)
                    .setInterpolator(new DecelerateInterpolator())
                    .start();
        }
    }

    /**
     * Soft home backdrop: a cool light from the top, deepening toward the bottom, with gentle
     * side shading. Sits above the poster colors or wallpaper and below all content.
     */
    View homeGradient() {
        boolean glowActive = homeAmbient != null && homeAmbient.getVisibility() == View.VISIBLE;
        GradientDrawable vertical =
                new GradientDrawable(
                        GradientDrawable.Orientation.TOP_BOTTOM,
                        glowActive
                                ? new int[] {
                                    0x10000000, 0x00000000, 0x08060910, 0x22060910, 0x48060910
                                }
                                : new int[] {
                                    0x1c000000, 0x00000000, 0x18080a0f, 0x66080a0f, 0xb8080a0f
                                });
        GradientDrawable sides =
                new GradientDrawable(
                        GradientDrawable.Orientation.LEFT_RIGHT,
                        glowActive
                                ? new int[] {0x22000000, 0x00000000, 0x00000000, 0x14000000}
                                : new int[] {0x38000000, 0x00000000, 0x00000000, 0x26000000});
        View scrim = new View(this);
        scrim.setTag("home-gradient");
        scrim.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        scrim.setBackground(
                new android.graphics.drawable.LayerDrawable(
                        new android.graphics.drawable.Drawable[] {vertical, sides}));
        return scrim;
    }

    boolean available(Cms.Site s) {
        return SourceController.available(this, s);
    }

    int engineEpoch;

    SourceEngine engine(Cms.Site s) throws Exception {
        return SourceController.engine(this, s);
    }

    synchronized void ensureProxy(Cms.Config snapshot) throws IOException {
        SourceController.ensureProxy(this, snapshot);
    }

    void closeEngines() {
        SourceController.closeEngines(this);
    }

    void capturePendingDetailOrigin(View sourceCard) {
        if (isTvDevice()
                || reduced
                || root == null
                || sourceCard == null
                || sourceCard.getWidth() <= 0
                || sourceCard.getHeight() <= 0) {
            pendingDetailOrigin = null;
            return;
        }
        Rect rect = new Rect();
        PlayerTransitionHelper.resolveDescendantRectInRoot(root, sourceCard, rect);
        pendingDetailOrigin = rect.width() > 0 && rect.height() > 0 ? rect : null;
    }

    Rect consumePendingDetailOrigin() {
        Rect rect = pendingDetailOrigin;
        pendingDetailOrigin = null;
        return rect;
    }

    void cancelActiveTransition() {
        transitionSerial++;
        pendingPlayerTransition = false;
        PlayerTransitionHelper.TransitionHandle handle = activeTransition;
        activeTransition = null;
        if (handle != null) {
            handle.cancel();
        }
        glassFreezeController.forceUnfreeze();
    }

    static final class DetailPortalSelection {
        final View ambientPosterView;
        final View portalCardView;
        final RectF posterOriginPx;
        final Bitmap posterBitmap;

        DetailPortalSelection(
                View ambientPosterView,
                View portalCardView,
                RectF posterOriginPx,
                Bitmap posterBitmap) {
            this.ambientPosterView = ambientPosterView;
            this.portalCardView = portalCardView;
            this.posterOriginPx = posterOriginPx;
            this.posterBitmap = posterBitmap;
        }
    }

    private static boolean isIndependentPosterCardCandidate(View view) {
        if (view == null
                || view.getVisibility() != View.VISIBLE
                || view.getWidth() <= 0
                || view.getHeight() <= 0) {
            return false;
        }
        if (view instanceof MobileDetailScreen.PortraitBackdropView
                || view instanceof MobileDetailScreen.PosterHookImageView
                || view instanceof ImmersivePoster.Backdrop) {
            return false;
        }
        if (view instanceof ImmersivePoster && ((ImmersivePoster) view).immersiveMode) {
            return false;
        }
        return true;
    }

    static DetailPortalSelection resolveDetailPortalSelection(View detailLayer) {
        if (detailLayer == null) {
            return new DetailPortalSelection(null, null, new RectF(0f, 0f, 0f, 0f), null);
        }
        View explicitCard = detailLayer.findViewWithTag("detail-poster-card");
        View coverView = detailLayer.findViewWithTag("detail-cover");
        View backdropView = detailLayer.findViewWithTag("detail-backdrop");

        View ambientPosterView = null;
        if (isIndependentPosterCardCandidate(explicitCard)) {
            ambientPosterView = explicitCard;
        } else if (backdropView != null
                && backdropView.getVisibility() == View.VISIBLE
                && backdropView.getWidth() > 0
                && backdropView.getHeight() > 0) {
            ambientPosterView = backdropView;
        } else if (isIndependentPosterCardCandidate(coverView)) {
            ambientPosterView = coverView;
        }

        View portalCard = null;
        if (isIndependentPosterCardCandidate(explicitCard)) {
            portalCard = explicitCard;
        } else if (isIndependentPosterCardCandidate(coverView)) {
            portalCard = coverView;
        }

        RectF originPx = new RectF(0f, 0f, 0f, 0f);
        Bitmap posterBitmap = null;
        if (portalCard != null) {
            Rect cardRect = new Rect();
            PlayerTransitionHelper.resolveDescendantRectInRoot(detailLayer, portalCard, cardRect);
            RectF candidateRect = new RectF(cardRect);
            if (PlayerTransitionHelper.isBoundedPosterCardRect(
                    candidateRect, detailLayer.getWidth(), detailLayer.getHeight())) {
                Bitmap extracted = extractDetailPosterBitmap(portalCard);
                if (extracted != null && !extracted.isRecycled()) {
                    originPx = candidateRect;
                    posterBitmap = extracted;
                }
            } else {
                portalCard = null;
            }
        }
        return new DetailPortalSelection(ambientPosterView, portalCard, originPx, posterBitmap);
    }

    static Bitmap extractDetailPosterBitmap(View posterView) {
        if (posterView instanceof MobileDetailScreen.PortraitBackdropView) {
            Bitmap bmp = ((MobileDetailScreen.PortraitBackdropView) posterView).getPosterBitmap();
            return (bmp != null && !bmp.isRecycled()) ? bmp : null;
        }
        if (posterView instanceof ImmersivePoster.Backdrop) {
            ImmersivePoster.Backdrop b = (ImmersivePoster.Backdrop) posterView;
            if (b.wideBitmap != null && !b.wideBitmap.isRecycled()) return b.wideBitmap;
            if (b.rawBitmap != null && !b.rawBitmap.isRecycled()) return b.rawBitmap;
        }
        if (posterView instanceof ImmersivePoster) {
            ImmersivePoster ip = (ImmersivePoster) posterView;
            Bitmap fromImage = extractImageViewBitmap(ip.image);
            if (fromImage != null) return fromImage;
            if (ip.backdrop != null
                    && ip.backdrop.rawBitmap != null
                    && !ip.backdrop.rawBitmap.isRecycled()) {
                return ip.backdrop.rawBitmap;
            }
            return null;
        }
        if (posterView instanceof ImageView) {
            return extractImageViewBitmap((ImageView) posterView);
        }
        return null;
    }

    private static Bitmap extractImageViewBitmap(ImageView imageView) {
        if (imageView == null) return null;
        Drawable d = imageView.getDrawable();
        if (d instanceof BitmapDrawable) {
            Bitmap bmp = ((BitmapDrawable) d).getBitmap();
            return (bmp != null && !bmp.isRecycled()) ? bmp : null;
        }
        return null;
    }

    void openScreenNow(Screen s, boolean history) {
        capture();
        if (history && current != null) back.push(current);
        current = s;
        s.render.run();
        restore(s);
    }

    void open(Screen s, boolean history) {
        dismissOnboarding();
        cancelActiveTransition();
        boolean detailToPlayer =
                s != null
                        && s.player
                        && current != null
                        && !current.player
                        && !miniMode
                        && layoutReady
                        && root != null
                        && root.getWidth() > 0
                        && root.getHeight() > 0;
        if (!detailToPlayer) {
            openScreenNow(s, history);
            return;
        }

        final View detailLayer = root;
        DetailPortalSelection portal = resolveDetailPortalSelection(detailLayer);
        RectF posterOriginPx = portal.posterOriginPx;
        float posterRadiusPx = portal.posterBitmap != null ? dp(16) : 0f;
        Rect safeInsetsPx = new Rect(0, statusBarHeight(), 0, navigationBarHeight());

        if (Build.VERSION.SDK_INT >= 33 && !isTvDevice() && !reduced) {
            Bitmap backdrop = PlayerTransitionHelper.captureDownsampledBackdrop(detailLayer);
            if (backdrop != null) {
                openScreenNow(s, history);
                activeTransition =
                        PlayerTransitionHelper.startDetailToPlayerTransition(
                                root,
                                null,
                                null,
                                backdrop,
                                true,
                                portal.posterBitmap,
                                posterOriginPx,
                                posterRadiusPx,
                                safeInsetsPx,
                                false,
                                false,
                                glassFreezeController,
                                () -> activeTransition = null);
                return;
            }
        }

        final int serial = ++transitionSerial;
        pendingPlayerTransition = true;
        PlayerTransitionHelper.TransitionHandle handle =
                PlayerTransitionHelper.startDetailToPlayerTransition(
                        null,
                        detailLayer,
                        portal.ambientPosterView,
                        null,
                        false,
                        null,
                        posterOriginPx,
                        posterRadiusPx,
                        safeInsetsPx,
                        isTvDevice(),
                        reduced,
                        glassFreezeController,
                        () -> {
                            pendingPlayerTransition = false;
                            if (serial != transitionSerial
                                    || isFinishing()
                                    || (Build.VERSION.SDK_INT >= 17 && isDestroyed())) {
                                return;
                            }
                            activeTransition = null;
                            openScreenNow(s, history);
                        });
        if (serial == transitionSerial && pendingPlayerTransition) {
            activeTransition = handle;
        }
    }

    static boolean shouldPostOnboardingContainerFocus(boolean tvMode) {
        return !tvMode;
    }

    static final class OnboardingFinishCoordinator {
        private final int initialScale;
        private boolean followUpActionRequested;
        private boolean recreateScheduled;
        private boolean recreateExecuted;

        OnboardingFinishCoordinator(int initialScale) {
            this.initialScale = initialScale;
        }

        boolean onFinished(int currentScale, Runnable postDeferredRecreate, Runnable restoreFocus) {
            if (currentScale != initialScale) {
                if (!followUpActionRequested && !recreateScheduled) {
                    recreateScheduled = true;
                    if (postDeferredRecreate != null) {
                        postDeferredRecreate.run();
                    }
                }
                return true;
            }
            if (!followUpActionRequested && restoreFocus != null) {
                restoreFocus.run();
            }
            return false;
        }

        boolean runDeferredRecreateIfStillNeeded(boolean activityAlive, Runnable recreateAction) {
            if (followUpActionRequested || recreateExecuted || !activityAlive) {
                recreateScheduled = false;
                return false;
            }
            recreateScheduled = false;
            recreateExecuted = true;
            if (recreateAction != null) {
                recreateAction.run();
            }
            return true;
        }

        boolean beginFollowUpAction(boolean activityAlive) {
            followUpActionRequested = true;
            recreateScheduled = false;
            return activityAlive && !recreateExecuted;
        }

        boolean isRecreateScheduled() {
            return recreateScheduled;
        }

        boolean isRecreateExecuted() {
            return recreateExecuted;
        }
    }

    void showOnboarding(boolean isReplay) {
        if (isFinishing() || (Build.VERSION.SDK_INT >= 17 && isDestroyed())) return;
        if (root == null) return;
        if (current != null && current.player && !miniMode) return;
        dismissOnboarding();
        cancelActiveTransition();

        final int initialScale = prefs.getInt(Prefs.UI_SCALE_PERCENT, 100);
        final OnboardingFinishCoordinator finishCoordinator =
                new OnboardingFinishCoordinator(initialScale);
        boolean reduceTransparency = prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false);
        OnboardingScreen screen =
                new OnboardingScreen(
                        this,
                        isTvDevice(),
                        reduced,
                        reduceTransparency,
                        initialScale,
                        new OnboardingScreen.Callbacks() {
                            @Override
                            public void onImportConfig(String initialEmptyUrl) {
                                if (activeOnboarding != null) {
                                    activeOnboarding.getController().complete(false);
                                }
                                dismissOnboarding();
                                boolean alive =
                                        !isFinishing()
                                                && (Build.VERSION.SDK_INT < 17 || !isDestroyed());
                                if (finishCoordinator.beginFollowUpAction(alive)) {
                                    importDialog();
                                }
                            }

                            @Override
                            public void onOpenSync() {
                                if (activeOnboarding != null) {
                                    activeOnboarding.getController().complete(false);
                                }
                                dismissOnboarding();
                                boolean alive =
                                        !isFinishing()
                                                && (Build.VERSION.SDK_INT < 17 || !isDestroyed());
                                if (finishCoordinator.beginFollowUpAction(alive) && !privateMode) {
                                    CloudSyncDialog.show(
                                            MainActivity.this, MainActivity.this::refresh);
                                }
                            }

                            @Override
                            public void onPersonalizationChanged(
                                    boolean reduceMotion,
                                    boolean nextReduceTransparency,
                                    int uiScalePercent) {
                                prefs.edit()
                                        .putBoolean(Prefs.REDUCED, reduceMotion)
                                        .putBoolean(
                                                Prefs.REDUCED_TRANSPARENCY, nextReduceTransparency)
                                        .putInt(Prefs.UI_SCALE_PERCENT, uiScalePercent)
                                        .apply();
                                reduced = reduceMotion;
                                if (onboardingAurora != null) {
                                    onboardingAurora.setReducedMotion(reduceMotion);
                                }
                                if (root != null) {
                                    com.pilipala.glass.GlassworkSurface.invalidateBackdrop(root);
                                }
                            }

                            @Override
                            public void onFinished(boolean skipped) {
                                dismissOnboarding();
                                int nextScale = prefs.getInt(Prefs.UI_SCALE_PERCENT, 100);
                                finishCoordinator.onFinished(
                                        nextScale,
                                        () ->
                                                ui.post(
                                                        () -> {
                                                            boolean alive =
                                                                    !isFinishing()
                                                                            && (Build.VERSION
                                                                                                    .SDK_INT
                                                                                            < 17
                                                                                    || !isDestroyed());
                                                            finishCoordinator
                                                                    .runDeferredRecreateIfStillNeeded(
                                                                            alive,
                                                                            MainActivity.this
                                                                                    ::recreate);
                                                        }),
                                        () -> {
                                            if (current != null) {
                                                restore(current);
                                            }
                                        });
                            }
                        });
        screen.setTag("onboarding-screen");
        if (isTvDevice()) {
            screen.setDescendantFocusability(ViewGroup.FOCUS_AFTER_DESCENDANTS);
        } else {
            AuroraSurfaceView aurora = new AuroraSurfaceView(this);
            aurora.setReducedMotion(reduced);
            onboardingAurora = aurora;
            screen.setBackgroundLayer(aurora);
        }

        savedOnboardingFocusability.clear();
        savedOnboardingViewFocusable.clear();
        for (int i = 0; i < root.getChildCount(); i++) {
            View child = root.getChildAt(i);
            if (child instanceof ViewGroup) {
                ViewGroup vg = (ViewGroup) child;
                savedOnboardingFocusability.put(vg, vg.getDescendantFocusability());
                vg.setDescendantFocusability(ViewGroup.FOCUS_BLOCK_DESCENDANTS);
            } else if (child.isFocusable()) {
                savedOnboardingViewFocusable.put(child, Boolean.TRUE);
                child.setFocusable(false);
            }
        }
        activeOnboarding = screen;
        root.addView(screen, new FrameLayout.LayoutParams(-1, -1));
        if (shouldPostOnboardingContainerFocus(isTvDevice())) {
            screen.post(screen::requestFocus);
        }
    }

    void dismissOnboarding() {
        OnboardingScreen screen = activeOnboarding;
        activeOnboarding = null;
        if (onboardingAurora != null) {
            onboardingAurora.setActive(false);
            onboardingAurora = null;
        }
        if (screen != null && screen.getParent() instanceof ViewGroup) {
            ((ViewGroup) screen.getParent()).removeView(screen);
        }
        for (Map.Entry<ViewGroup, Integer> entry : savedOnboardingFocusability.entrySet()) {
            entry.getKey().setDescendantFocusability(entry.getValue());
        }
        savedOnboardingFocusability.clear();
        for (Map.Entry<View, Boolean> entry : savedOnboardingViewFocusable.entrySet()) {
            entry.getKey().setFocusable(entry.getValue());
        }
        savedOnboardingViewFocusable.clear();
    }

    void capture() {
        if (current != null) {
            View f = getCurrentFocus();
            if (f != null && f.getTag() instanceof String) current.focus = (String) f.getTag();
            if (scroll != null) current.scroll = scroll.getScrollY();
        }
    }

    /** Last focus placed by the app rather than the user; late content may replace only this. */
    View autoFocus;

    void restore(Screen s) {
        ui.post(
                () -> {
                    if (current != s) return;
                    if (scroll != null) scroll.scrollTo(0, s.scroll);
                    if (!isTvDevice()) return;
                    View target = s.focus == null ? null : root.findViewWithTag(s.focus);
                    if (target != null
                            && (!target.isShown() || !target.isFocusable() || !target.isEnabled()))
                        target = null;
                    if (target != null) {
                        target.requestFocus();
                        autoFocus = target;
                    } else {
                        View first = root.findViewWithTag("primary");
                        if (first == null) first = root.findViewWithTag("detail-play");
                        if (first == null && s.home) {
                            first = s.retainedHome == null ? null : s.retainedHome.topTarget();
                            if (first == null) first = root.findViewWithTag("home-tab:0");
                            if (first == null) first = root.findViewWithTag("source-switcher");
                        }
                        if (first != null
                                && (!first.isShown() || !first.isFocusable() || !first.isEnabled()))
                            first = null;
                        if (first == null) first = root.findViewWithTag("nav-home");
                        if (first == null) {
                            ArrayList<View> available = new ArrayList<>();
                            body.addFocusables(available, View.FOCUS_FORWARD);
                            if (!available.isEmpty()) first = available.get(0);
                        }
                        if (first != null) first.requestFocus();
                        autoFocus = first;
                    }
                });
    }

    void refresh() {
        capture();
        Screen s = current;
        s.render.run();
        restore(s);
    }

    void renderReturn(Screen screen) {
        if (!isTvDevice() && screen.mobileHome != null && screen.mobileHome.resume()) return;
        if (isTvDevice() && screen.retainedHome != null && screen.retainedHome.resume()) return;
        screen.render.run();
    }

    @Override
    public void onBackPressed() {
        if (activeOnboarding != null) {
            activeOnboarding.handleBackPressed();
            return;
        }
        if (pendingPlayerTransition) {
            cancelActiveTransition();
            return;
        }
        cancelActiveTransition();
        if (markerHost != null) {
            markerHost.cancel();
            return;
        }
        if (current != null && current.player && !miniMode && playerLocked) {
            PlaybackController.revealLockedHint(this);
            return;
        }
        if (playbackLoading != null) {
            changingMiniEpisode = false;
            clearPlaybackLoading();
            cancelPageRequests();
            stopWeb();
            if (current != null && current.player && !prepared) {
                if (playerChrome != null) playerChrome.setLoading(false);
                if (playStatus != null) playStatus.setText("已取消加载");
                showControls(true);
            }
            return;
        }
        if (current != null && current.player) {
            if (!miniMode && playbackControls != null) {
                if (controlsVisible) showControls(false);
                else if (isLive() || isCast() || !isTvDevice()) leavePlayback();
                else minimizePlayback();
                return;
            }
            if (miniMode) {
                releasePlayer();
                if (!back.isEmpty()) back.pop();
                if (!back.isEmpty()) {
                    current = back.pop();
                    renderReturn(current);
                    restore(current);
                } else {
                    current = new Screen(this::home);
                    renderReturn(current);
                }
                return;
            }
        }
        if (current != null && current.home) {
            if (!back.isEmpty()) {
                capture();
                current = back.pop();
                renderReturn(current);
                restore(current);
                return;
            }
            if (mobileShell != null && mobileShell.handleBack()) {
                return;
            }
            releasePlayer();
            exitApp();
            return;
        }
        if (!back.isEmpty()) {
            capture();
            current = back.pop();
            renderReturn(current);
            restore(current);
        } else if (isTvDevice()) {
            confirmExitApp();
        } else {
            releasePlayer();
            exitApp();
        }
    }

    void confirmExitApp() {
        if (appDialog != null && appDialog.isShowing()) return;
        AppDialog dialog =
                new AppDialog.Builder(this)
                        .setTitle("退出应用")
                        .setMessage("确定要退出 Marco Movie 吗？")
                        .setNegativeButton("取消", null)
                        .setPositiveButton(
                                "退出应用",
                                (d, w) -> {
                                    releasePlayer();
                                    exitApp();
                                })
                        .show();
        Button cancelBtn = dialog.getButton(android.content.DialogInterface.BUTTON_NEGATIVE);
        Button exitBtn = dialog.getButton(android.content.DialogInterface.BUTTON_POSITIVE);
        if (cancelBtn != null && exitBtn != null) {
            cancelBtn.setNextFocusLeftId(cancelBtn.getId());
            cancelBtn.setNextFocusRightId(exitBtn.getId());
            cancelBtn.setNextFocusUpId(cancelBtn.getId());
            cancelBtn.setNextFocusDownId(cancelBtn.getId());
            exitBtn.setNextFocusLeftId(cancelBtn.getId());
            exitBtn.setNextFocusRightId(exitBtn.getId());
            exitBtn.setNextFocusUpId(exitBtn.getId());
            exitBtn.setNextFocusDownId(exitBtn.getId());
        }
        if (cancelBtn != null) {
            cancelBtn.requestFocus();
        }
    }

    volatile boolean allowSystemFinish;

    void exitApp() {
        allowSystemFinish = true;
        super.finish();
    }

    static boolean shouldPopScreenOnPluginFinish(
            boolean isHome, boolean isPlayer, boolean hasBackStack) {
        return !isHome && !isPlayer && hasBackStack;
    }

    private void interceptPluginFinish() {
        AppLog.w(
                "PluginGuard",
                "intercepted unexpected Activity.finish() from extension",
                new Throwable());
        // Never disrupt an active playback session when a background spider/netdisk extension
        // unexpectedly calls Activity.finish().
        if (current != null && current.player) {
            return;
        }
        generation++;
        ui.post(
                () -> {
                    if (isDestroyed() || allowSystemFinish) return;
                    if (current != null
                            && shouldPopScreenOnPluginFinish(
                                    current.home, current.player, !back.isEmpty())) {
                        cancelPageRequests();
                        generation++;
                        current = back.pop();
                        renderReturn(current);
                        restore(current);
                    }
                });
    }

    @Override
    public void finish() {
        if (allowSystemFinish || switchingPrivacy) {
            super.finish();
            return;
        }
        interceptPluginFinish();
    }

    @Override
    public void finishAffinity() {
        if (allowSystemFinish || switchingPrivacy) {
            super.finishAffinity();
            return;
        }
        interceptPluginFinish();
    }

    @Override
    public void finishAndRemoveTask() {
        if (allowSystemFinish || switchingPrivacy) {
            super.finishAndRemoveTask();
            return;
        }
        interceptPluginFinish();
    }

    void minimizePlayback() {
        PlaybackController.minimizePlayback(this);
    }

    void expandPlayback() {
        PlaybackController.expandPlayback(this);
    }

    /**
     * Pure-JVM toast layout policy returning {@code {bottomMargin, rightMargin, maxWidth}}.
     *
     * <p>Prevents two layout bugs: (1) computing maxWidth from an unlaid-out root ({@code parentW
     * == 0}) which collapsed toasts into an 80dp-wide vertical column, and (2) subtracting a
     * full-width top dock's width as {@code rightMargin} as if it were a right vertical rail.
     */
    static int[] computeToastLayout(
            int containerW,
            int dockW,
            int dockH,
            int dockGravity,
            int dockBottomMargin,
            int dockRightMargin,
            int dp10,
            int dp24,
            int dp32,
            int minWidthPx,
            int maxCapPx) {
        int safeW = Math.max(dp32 * 4, containerW);
        int bottomMargin = dp24;
        int rightMargin = 0;
        if (dockW > 0 || dockH > 0) {
            int vGrav = dockGravity & Gravity.VERTICAL_GRAVITY_MASK;
            int hGrav = dockGravity & Gravity.HORIZONTAL_GRAVITY_MASK;
            if (vGrav == Gravity.BOTTOM) {
                bottomMargin = Math.max(bottomMargin, dockH + dockBottomMargin + dp10);
            } else if (vGrav != Gravity.TOP
                    && hGrav == Gravity.RIGHT
                    && dockW > 0
                    && dockW < safeW / 2) {
                rightMargin = dockW + dockRightMargin + dp10;
            }
        }
        int availW = Math.max(dp32 * 3, safeW - rightMargin - dp32);
        int preferredCap = Math.min(maxCapPx, Math.round(availW * 0.78f));
        int maxWidth = Math.min(availW, Math.max(minWidthPx, preferredCap));
        return new int[] {bottomMargin, rightMargin, maxWidth};
    }

    void toast(String message) {
        final FrameLayout parent = root;
        if (parent == null) return;
        View previous = parent.findViewWithTag("app-toast");
        if (previous != null && previous.getParent() == parent) parent.removeView(previous);
        TextView tip = text(message, 14.5f, WHITE);
        tip.setTypeface(
                android.graphics.Typeface.create(
                        "sans-serif-medium", android.graphics.Typeface.NORMAL));
        tip.setGravity(Gravity.CENTER);
        tip.setMaxLines(3);
        tip.setLineSpacing(dp(2.5f), 1f);
        tip.setPadding(dp(24), dp(12), dp(24), dp(12));
        GradientDrawable pillBg = bg(0xeb141922, 999);
        pillBg.setStroke(Math.max(1, dp(1)), 0x3bffffff);
        tip.setBackground(pillBg);
        UiCompat.setElevation(tip, dp(20));
        tip.setTag("app-toast");
        FrameLayout.LayoutParams size =
                new FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        int containerW = parent.getWidth() > 0 ? parent.getWidth() : windowWidth();
        int containerH = parent.getHeight() > 0 ? parent.getHeight() : windowHeight();
        int dockW = 0;
        int dockH = 0;
        int dockGravity = 0;
        int dockBottomMargin = 0;
        int dockRightMargin = 0;
        View dock = parent.findViewWithTag("home-dock");
        if (dock != null
                && dock.getVisibility() == View.VISIBLE
                && dock.getLayoutParams() instanceof FrameLayout.LayoutParams) {
            FrameLayout.LayoutParams rail = (FrameLayout.LayoutParams) dock.getLayoutParams();
            dockW = Math.max(dock.getWidth(), rail.width > 0 ? rail.width : 0);
            dockH = Math.max(dock.getHeight(), rail.height > 0 ? rail.height : 0);
            dockGravity = rail.gravity;
            dockBottomMargin = rail.bottomMargin;
            dockRightMargin = rail.rightMargin;
            UiCompat.setElevation(tip, Math.max(dp(20), dock.getElevation() + dp(4)));
        }
        int[] layout =
                computeToastLayout(
                        containerW,
                        dockW,
                        dockH,
                        dockGravity,
                        dockBottomMargin,
                        dockRightMargin,
                        dp(10),
                        dp(28),
                        dp(40),
                        dp(260),
                        dp(560));
        size.bottomMargin = layout[0];
        size.rightMargin = layout[1];
        android.graphics.Rect visible = new android.graphics.Rect();
        parent.getWindowVisibleDisplayFrame(visible);
        if (parent.getHeight() > 0 && visible.bottom > 0) {
            int[] xy = new int[2];
            parent.getLocationOnScreen(xy);
            int keyboardInset = xy[1] + containerH - visible.bottom;
            if (keyboardInset > dp(48) && keyboardInset < containerH) {
                size.bottomMargin = Math.max(size.bottomMargin, keyboardInset + dp(12));
            }
        }
        tip.setMaxWidth(layout[2]);
        parent.addView(tip, size);
        ui.postDelayed(() -> parent.removeView(tip), 2600);
    }

    void cancelPageRequests() {
        for (Future<?> request : pageRequests) request.cancel(true);
        pageRequests.clear();
        ((ThreadPoolExecutor) worker).purge();
        ((ThreadPoolExecutor) details).purge();
    }

    Future<?> submitPage(Runnable task) {
        Future<?> request = RequestScope.submit(worker, task);
        for (int i = pageRequests.size() - 1; i >= 0; i--) {
            if (pageRequests.get(i).isDone()) pageRequests.remove(i);
        }
        pageRequests.add(request);
        return request;
    }

    void loadDetail(Cms.Site site, String id, Done<Cms.Video> done) {
        SourceController.loadDetail(this, site, id, done);
    }

    void loadDetail(Cms.Site site, String id, Done<Cms.Video> done, Done<Throwable> onError) {
        SourceController.loadDetail(this, site, id, done, onError);
    }

    <T> void load(String label, Work<T> task, Done<T> done) {
        SourceController.load(this, label, task, done);
    }

    String message(Throwable e) {
        return SourceController.message(e);
    }

    void notice(String s) {
        new AppDialog.Builder(this).setMessage(s).setPositiveButton("知道了", null).show();
    }

    void learnTitles(List<Cms.Video> videos) {
        SourceController.learnTitles(this, videos);
    }

    void initializePhonetic() {
        final boolean publicSpace = !privateMode;
        final SharedPreferences target = prefs;
        worker.execute(
                () -> {
                    try {
                        PhoneticSearchIndex dictionary;
                        synchronized (MainActivity.class) {
                            if (sharedPhoneticDictionary == null)
                                sharedPhoneticDictionary =
                                        new PhoneticSearchIndex(
                                                getAssets().open("search/pinyin-characters.tsv"),
                                                getAssets().open("search/pinyin-phrases.dict.yaml"),
                                                getAssets().open("search/title-phrases.txt"));
                            dictionary = sharedPhoneticDictionary;
                        }
                        final PhoneticSearchIndex index = dictionary.newSession(publicSpace);
                        // Old cache/history stay byte-for-byte intact. They have no learning
                        // provenance,
                        // so rebuild suggestions from newly observed public titles instead of
                        // importing.
                        if (publicSpace)
                            try {
                                org.json.JSONArray saved =
                                        new org.json.JSONArray(
                                                target.getString(
                                                        Prefs.PHONETIC_PUBLIC_TITLES_V2, "[]"));
                                for (int i = 0; i < saved.length(); i++)
                                    index.learn(saved.optString(i));
                            } catch (Exception ignored) {
                            }
                        ui.post(
                                () -> {
                                    try {
                                        if (!isDestroyed()
                                                && !isFinishing()
                                                && !switchingPrivacy
                                                && publicSpace == !privateMode
                                                && prefs == target) phonetic = index;
                                    } finally {
                                        phoneticReady.countDown();
                                    }
                                });
                    } catch (Exception ignored) {
                        phoneticReady.countDown();
                    }
                });
    }

    void sourceAction(Cms.Site site, String action) {
        SourceController.sourceAction(this, site, action);
    }

    void pickDanmaku() {
        SourceController.pickDocument(this, 43, "当前设备没有系统文件选择器，请先安装文件管理器。");
    }

    void pickSubtitle() {
        SourceController.pickDocument(this, 42, "当前设备没有系统文件选择器，可安装文件管理器后再导入字幕。");
    }

    static final String FIRST_RUN_DECLARATION =
            "本产品仅为播放工具，不内置、不提供、不托管任何影视资源或配置地址。请自行合法获取内容与配置，并确保拥有相应使用权。";

    void home() {
        if (current != null) current.home = true;
        if (!isTvDevice()) {
            MobileShell.show(this);
            return;
        }
        Cms.Site selected = null;
        if (config != null)
            for (Cms.Site s : config.sites)
                if (s.key.equals(prefs.getString(Prefs.SELECTED_SITE, "")) && available(s))
                    selected = s;
        if (selected != null) {
            contentHome(selected);
            return;
        }
        new TvV17WelcomeHomeScreen(this).show();
    }

    void contentHome(Cms.Site site) {
        if (!isTvDevice()) {
            MobileShell.show(this);
            return;
        }
        new HomeScreen(this, site).show();
    }

    void chooseSources() {
        SourcePicker.show(this);
    }

    void importDialog() {
        if (!isTvDevice()) {
            MobileShell.showMobileImportDialog(this);
            return;
        }
        if (phoneConfig != null) phoneConfig.close();
        phoneConfig = new PhoneConfigDialog(this);
        phoneConfig.show();
    }

    void addressImportDialog() {
        SourceController.addressImportDialog(this);
    }

    void pickConfig() {
        SourceController.pickDocument(this, 41, "当前设备没有系统文件选择器。请安装文件管理器，或使用配置地址导入。");
    }

    @Override
    protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        SourceController.onActivityResult(this, request, result, data);
    }

    void saveConfig(Cms.Config c, String origin) throws Exception {
        SourceController.saveConfig(this, c, origin);
    }

    void categories(Cms.Site s) {
        CatalogScreen.categories(this, s);
    }

    void searchDialog(Cms.Site s) {
        globalSearchDialog();
    }

    void videos(Cms.Site s, String cat, String title, int page, String search) {
        CatalogScreen.videos(this, s, cat, title, page, search);
    }

    void cancelArtwork() {
        ImageLoader.cancel(this);
    }

    void poster(String address, ImageView image) {
        poster(address, image, false);
    }

    void poster(String address, ImageView image, boolean detail) {
        ImageLoader.poster(this, address, image, detail);
    }

    void detail(Cms.Site s, Cms.Video listing) {
        detail(s, listing, null);
    }

    void detail(Cms.Site s, Cms.Video listing, Cms.Video ready) {
        if (!isTvDevice()) {
            MobileDetailScreen.show(this, s, listing, ready);
            return;
        }
        DetailScreen.show(this, s, listing, ready);
        if (root != null && android.os.Build.VERSION.SDK_INT > 23) {
            activeTransition = PlayerTransitionHelper.animateTvPageFade(root, true, reduced, null);
        }
    }

    void renderEpisodes(
            Cms.Site site, Cms.Video video, int lineIndex, int page, LinearLayout panel) {
        DetailScreen.renderEpisodes(this, site, video, lineIndex, page, panel, null);
    }

    void liveSources() {
        if (!isTvDevice()) {
            MobileShell.activeTab = 2;
            open(new Screen(this::home), false);
            return;
        }
        LiveController.liveSources(this);
    }

    void playLive(
            LiveCatalog.Source source, LiveCatalog.Channel channel, LiveCatalog.Stream stream) {
        LiveController.playLive(this, source, channel, stream);
    }

    boolean isLive() {
        return LiveController.isLive(this);
    }

    boolean isCast() {
        return playbackControls != null
                && playbackControls.site != null
                && "cast".equals(playbackControls.site.key);
    }

    void castScreen() {
        CastScreen screen = new CastScreen(this);
        activeCastScreen = screen;
        screen.show();
    }

    private volatile int castServiceEpoch;
    private boolean castServiceStarting;

    synchronized void syncCastService() {
        if (!isTvDevice()
                || privateMode
                || prefs == null
                || !prefs.getBoolean(Prefs.CAST_ENABLED, true)) {
            castServiceStarting = false;
            castServiceEpoch++;
            stopCastService();
            return;
        }
        if ((castService != null && !castService.closed) || castServiceStarting) return;
        castServiceStarting = true;
        final int epoch = ++castServiceEpoch;
        worker.execute(
                () -> {
                    CastService started = null;
                    try {
                        started =
                                CastService.startForActivity(
                                        this,
                                        () -> {
                                            if (activeCastScreen != null) {
                                                activeCastScreen.refreshLiveStatus();
                                            }
                                        });
                    } catch (Throwable ignored) {
                    }
                    final CastService ready = started;
                    synchronized (MainActivity.this) {
                        if (epoch == castServiceEpoch) {
                            castServiceStarting = false;
                        }
                        if (epoch != castServiceEpoch
                                || isFinishing()
                                || isDestroyed()
                                || privateMode
                                || prefs == null
                                || !prefs.getBoolean(Prefs.CAST_ENABLED, true)) {
                            if (ready != null) ready.close();
                            return;
                        }
                        if (castService != null && castService != ready) {
                            castService.close();
                        }
                        castService = ready;
                    }
                    ui.post(
                            () -> {
                                if (!isFinishing() && activeCastScreen != null) {
                                    activeCastScreen.onServiceReady();
                                }
                            });
                });
    }

    synchronized void restartCastService() {
        castServiceStarting = false;
        castServiceEpoch++;
        stopCastService();
        syncCastService();
    }

    synchronized void stopCastService() {
        castServiceStarting = false;
        if (castService != null) {
            castService.close();
            castService = null;
        }
    }

    private volatile int spiderGatewayEpoch;
    private boolean spiderGatewayStarting;

    synchronized void syncSpiderGateway() {
        if (privateMode
                || prefs == null
                || !prefs.getBoolean(Prefs.SPIDER_GATEWAY_ENABLED, false)) {
            spiderGatewayStarting = false;
            spiderGatewayEpoch++;
            stopSpiderGateway();
            return;
        }
        if ((spiderGateway != null && !spiderGateway.closed) || spiderGatewayStarting) return;
        spiderGatewayStarting = true;
        final int epoch = ++spiderGatewayEpoch;
        worker.execute(
                () -> {
                    SpiderGatewayServer started = null;
                    try {
                        started = SpiderGatewayServer.startForActivity(this, null);
                    } catch (Throwable err) {
                        AppLog.w("MainActivity", "spider gateway start failed", err);
                    }
                    final SpiderGatewayServer ready = started;
                    synchronized (MainActivity.this) {
                        if (epoch == spiderGatewayEpoch) {
                            spiderGatewayStarting = false;
                        }
                        if (epoch != spiderGatewayEpoch
                                || isFinishing()
                                || isDestroyed()
                                || privateMode
                                || prefs == null
                                || !prefs.getBoolean(Prefs.SPIDER_GATEWAY_ENABLED, false)) {
                            if (ready != null) ready.close();
                            return;
                        }
                        if (spiderGateway != null && spiderGateway != ready) {
                            spiderGateway.close();
                        }
                        spiderGateway = ready;
                    }
                });
    }

    synchronized void restartSpiderGateway() {
        spiderGatewayStarting = false;
        spiderGatewayEpoch++;
        stopSpiderGateway();
        syncSpiderGateway();
    }

    synchronized void stopSpiderGateway() {
        spiderGatewayStarting = false;
        if (spiderGateway != null) {
            spiderGateway.close();
            spiderGateway = null;
        }
    }

    boolean liveStep(int direction) {
        return LiveController.liveStep(this, direction);
    }

    void chooseLiveChannel() {
        LiveController.chooseLiveChannel(this);
    }

    void chooseLiveStream() {
        LiveController.chooseLiveStream(this);
    }

    void clearLiveNumber() {
        LiveController.clearLiveNumber(this);
    }

    void commitLiveNumber() {
        LiveController.commitLiveNumber(this);
    }

    boolean liveKey(KeyEvent event) {
        return LiveController.liveKey(this, event);
    }

    void globalSearchDialog() {
        openSearch("");
    }

    void openSearch(String initial) {
        if (config == null) {
            importDialog();
            return;
        }
        if (!isTvDevice()) {
            MobileShell.openSearchTab(this, initial);
            return;
        }
        GlobalSearchScreen screen = new GlobalSearchScreen(this, initial);
        open(
                new Screen(
                        () -> {
                            screen.show();
                            searchScreen = screen;
                        }),
                true);
    }

    void crossSearch(String keyword) {
        openSearch(keyword);
    }

    void minePage() {
        if (isTvDevice()) new TvV17MineScreen(this).show();
        else new FavoritesScreen(this).show();
    }

    void stopMagnet() {
        PlaybackController.stopMagnet(this);
    }

    void stopWeb() {
        PlaybackController.stopWeb(this);
    }

    void resolvePlayer(Cms.Site s, Cms.Video v, Cms.Line line, Cms.Episode ep) {
        PlaybackController.resolvePlayer(this, s, v, line, ep);
    }

    void clearPlaybackLoading() {
        PlaybackController.clearPlaybackLoading(this);
    }

    void openPlayer(Cms.Site s, Cms.Video v, Cms.Episode e) {
        PlaybackController.openPlayer(this, s, v, e);
    }

    void playerPage(Cms.Site s, Cms.Video v, Cms.Episode ep) {
        PlaybackController.playerPage(this, s, v, ep);
    }

    void changeEpisode(
            Cms.Site site, Cms.Video video, Cms.Line line, Cms.Episode episode, int position) {
        PlaybackController.changeEpisode(this, site, video, line, episode, position);
    }

    void leavePlayback() {
        PlaybackController.leavePlayback(this);
    }

    void showControls(boolean visible) {
        PlaybackController.showControls(this, visible);
    }

    void scheduleHide() {
        PlaybackController.scheduleHide(this);
    }

    String time(int ms) {
        return PlaybackController.formatTime(ms);
    }

    void togglePlayback() {
        PlaybackController.togglePlayback(this);
    }

    void beginSeek(int direction) {
        PlaybackController.beginSeek(this, direction);
    }

    void previewSeek() {
        PlaybackController.previewSeek(this);
    }

    void finishSeek(boolean commit) {
        PlaybackController.finishSeek(this, commit);
    }

    static final String STARTUP_BOOT_GUARD_FILE = "startup_boot_guard_v1";

    static boolean shouldPrewarmSiteOnStartup(Cms.Site s) {
        return s != null && (s.supported() || HttpT4Engine.eligible(s));
    }

    static int recordStartupBootGuard(File cacheDir) {
        if (cacheDir == null) return 0;
        File guard = new File(cacheDir, STARTUP_BOOT_GUARD_FILE);
        int prior = 0;
        if (guard.isFile()) {
            try (InputStream in = new FileInputStream(guard)) {
                int b = in.read();
                if (b >= '1' && b <= '9') prior = b - '0';
                else prior = 1;
            } catch (Throwable ignored) {
                prior = 1;
            }
        }
        int next = Math.min(9, prior + 1);
        try {
            if (!cacheDir.exists()) cacheDir.mkdirs();
            try (FileOutputStream out = new FileOutputStream(guard)) {
                out.write('0' + next);
                out.flush();
            }
        } catch (Throwable ignored) {
        }
        return prior;
    }

    static void clearStartupBootGuard(File cacheDir) {
        if (cacheDir == null) return;
        try {
            File guard = new File(cacheDir, STARTUP_BOOT_GUARD_FILE);
            if (guard.exists()) guard.delete();
        } catch (Throwable ignored) {
        }
    }

    static void purgeVolatileCrashCaches(File cacheDir) {
        if (cacheDir == null || !cacheDir.isDirectory()) return;
        try {
            File[] entries = cacheDir.listFiles();
            if (entries == null) return;
            for (File f : entries) {
                String name = f.getName();
                if ("home_snap_v1".equals(name)
                        || "detail_v1".equals(name)
                        || "posters_v2".equals(name)
                        || "tv_curated_home_v1.json".equals(name)
                        || name.startsWith("tv_wide_v5_")
                        || name.startsWith("mob_hd_poster_v4_")) {
                    deleteRecursivelyQuiet(f);
                }
            }
        } catch (Throwable ignored) {
        }
    }

    private static void deleteRecursivelyQuiet(File target) {
        if (target == null || !target.exists()) return;
        if (target.isDirectory()) {
            File[] children = target.listFiles();
            if (children != null) {
                for (File child : children) deleteRecursivelyQuiet(child);
            }
        }
        try {
            target.delete();
        } catch (Throwable ignored) {
        }
    }

    static void clearRecoveredCrashSite(SharedPreferences prefs) {
        if (prefs == null) return;
        String crashed = prefs.getString(Prefs.LOADING_SITE, "");
        String selected = prefs.getString(Prefs.SELECTED_SITE, "");
        String preferred = prefs.getString(Prefs.PREFERRED_SITE, "");
        SharedPreferences.Editor editor =
                prefs.edit().putString(Prefs.LOADING_SITE, "").putString(Prefs.SELECTED_SITE, "");
        if (preferred != null && !preferred.isEmpty()) {
            String badKey = crashed != null && !crashed.isEmpty() ? crashed : selected;
            if (badKey != null
                    && !badKey.isEmpty()
                    && (preferred.equals(badKey) || preferred.startsWith(badKey + "\n"))) {
                editor.putString(Prefs.PREFERRED_SITE, "");
            }
        }
        editor.commit();
    }

    WatchHistory.Persistence historyPersistence() {
        final SharedPreferences targetPrefs = prefs;
        return new WatchHistory.Persistence() {
            @Override
            public String readRaw() {
                return targetPrefs == null
                        ? "[]"
                        : targetPrefs.getString(Prefs.WATCH_HISTORY, "[]");
            }

            @Override
            public boolean readCorruptedPref() {
                return targetPrefs != null
                        && targetPrefs.getBoolean(WatchHistory.CORRUPTED_PREF, false);
            }

            @Override
            public void writeState(String historyJson, boolean corrupted) {
                if (targetPrefs == null) return;
                targetPrefs
                        .edit()
                        .putString(Prefs.WATCH_HISTORY, historyJson)
                        .putBoolean(WatchHistory.CORRUPTED_PREF, corrupted)
                        .apply();
            }
        };
    }

    java.util.List<WatchHistory.Entry> watchHistory() {
        if (privateMode) return java.util.Collections.emptyList();
        if (prefs.getBoolean(WatchHistory.CORRUPTED_PREF, false)) {
            WatchHistory.setCorrupted(true);
        }
        return WatchHistory.read(
                prefs.getString(Prefs.WATCH_HISTORY, "[]"),
                (key, raw) -> {
                    if (!prefs.getBoolean(WatchHistory.CORRUPTED_PREF, false)) {
                        prefs.edit()
                                .putString(key, raw)
                                .putBoolean(WatchHistory.CORRUPTED_PREF, true)
                                .apply();
                    }
                });
    }

    void clearWatchHistory() {
        clearWatchHistory(null);
    }

    void clearWatchHistory(final Runnable onUiComplete) {
        WatchHistory.setCorrupted(false);
        WatchHistory.enqueueClear(
                historyPersistence(),
                onUiComplete == null
                        ? null
                        : () ->
                                ui.post(
                                        () -> {
                                            if (!isFinishing() && !isDestroyed()) {
                                                onUiComplete.run();
                                            }
                                        }));
    }

    void removeWatchHistory(final String key, final Runnable onUiComplete) {
        WatchHistory.enqueueRemove(
                historyPersistence(),
                key,
                onUiComplete == null
                        ? null
                        : () ->
                                ui.post(
                                        () -> {
                                            if (!isFinishing() && !isDestroyed()) {
                                                onUiComplete.run();
                                            }
                                        }));
    }

    boolean overwriteWatchHistory(String validJson) {
        String validated = WatchHistory.validateBackupJson(validJson);
        if (validated == null) return false;
        WatchHistory.enqueueBackupRestore(historyPersistence(), validated, null);
        return true;
    }

    void savePlaybackHistory(boolean force) {
        PlaybackController.savePlaybackHistory(this, force);
    }

    String historyLabel(WatchHistory.Entry e) {
        return CatalogScreen.historyLabel(e);
    }

    void resumeHistory(WatchHistory.Entry e) {
        CatalogScreen.resumeHistory(this, e);
    }

    void playBookmark(Cms.Site site, Cms.Video video, WatchHistory.Entry bookmark) {
        CatalogScreen.playBookmark(this, site, video, bookmark);
    }

    void historyPage() {
        CatalogScreen.historyPage(this);
    }

    void releasePlayer() {
        PlaybackController.releasePlayer(this);
    }

    void smoothHomeScroll(int y) {
        if (scroll instanceof TvScrollView) ((TvScrollView) scroll).moveTo(y);
        else if (reduced) scroll.scrollTo(0, y);
        else scroll.smoothScrollTo(0, y);
    }

    void jumpHomeTop() {
        if (current == null || !current.home || scroll == null) return;
        View target = current.retainedHome == null ? null : current.retainedHome.topTarget();
        if (target == null) target = root.findViewWithTag("home-history:0");
        if (target == null) target = root.findViewWithTag("home-tab:0");
        if (target == null) target = root.findViewWithTag("source-switcher");
        if (target == null) target = root.findViewWithTag("primary");
        if (target != null && target.isShown() && target.isFocusable() && target.isEnabled()) {
            target.requestFocus();
            current.focus = String.valueOf(target.getTag());
        }
        current.scroll = 0;
        smoothHomeScroll(0);
    }

    static boolean isMenuShortPress(int action, boolean canceled, int flags) {
        if (action != KeyEvent.ACTION_UP) return false;
        // Xiaomi MiTV firmware re-injects short-press KEYCODE_MENU with internal flag 0x7531
        // (30001), whose bits overlap KeyEvent.FLAG_CANCELED (0x20) despite being a valid tap.
        boolean mitvSynthetic = (flags & 0x7531) == 0x7531;
        return !canceled || mitvSynthetic;
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        if (introSkipKey && event.getAction() == KeyEvent.ACTION_UP) {
            introSkipKey = false;
            return true;
        }
        if (startupIntro != null) {
            int key = event.getKeyCode();
            if (event.getAction() == KeyEvent.ACTION_DOWN
                    && (key == KeyEvent.KEYCODE_DPAD_CENTER
                            || key == KeyEvent.KEYCODE_ENTER
                            || key == KeyEvent.KEYCODE_BACK)) {
                introSkipKey = true;
                startupIntro.finish(true);
            }
            return true;
        }
        if (activeOnboarding != null) {
            return super.dispatchKeyEvent(event);
        }
        if (current != null && current.player && !miniMode && playerLocked) {
            if (event.getAction() == KeyEvent.ACTION_DOWN && event.getRepeatCount() == 0) {
                PlaybackController.revealLockedHint(this);
            }
            return true;
        }

        if (markerHost != null && markerHost.key(event)) return true;

        if (!isTvDevice() && shortcutScreen != current) {
            homeKeys.reset();
            shortcutScreen = current;
        }
        if (current != null && current.home) {
            int key = event.getKeyCode();
            if (key == KeyEvent.KEYCODE_MENU) {
                homeKeys.reset();
                if (isMenuShortPress(event.getAction(), event.isCanceled(), event.getFlags())) {
                    if (isTvDevice() && homeDock != null && homeDock.topMode) {
                        homeDock.focusFromMenuKey();
                    } else {
                        chooseSources();
                    }
                }
                return true;
            }
            // TV directional taps always follow focus; the legacy non-TV shortcut is unchanged.
            if (!isTvDevice() && event.getAction() == KeyEvent.ACTION_DOWN) {
                if (key == KeyEvent.KEYCODE_DPAD_UP) {
                    if (homeKeys.up(event.getEventTime(), event.getRepeatCount())) {
                        jumpHomeTop();
                        return true;
                    }
                } else homeKeys.reset();
            }
        }
        if (liveKey(event)) return true;
        View feedbackFocus = getCurrentFocus();
        if (feedbackFocus != null) FocusMotion.key(this, feedbackFocus, event.getKeyCode(), event);
        if (current != null && current.home && homeDock != null && homeDock.key(event)) return true;
        if (current != null && current.home && HomeScreen.navigationKey(this, event)) return true;
        if (PlaybackController.dispatchPlaybackKey(this, event)) return true;
        return super.dispatchKeyEvent(event);
    }

    @Override
    public void onWindowFocusChanged(boolean focus) {
        super.onWindowFocusChanged(focus);
        if (!focus) {
            if (markerHost != null) markerHost.abort();
            if (playerChrome != null) playerChrome.cancelEpisodeHoldSwitch();
            finishSeek(false);
            PluginDialogStyler.watch(this);
        }
        SourceController.onActivityFocusChanged(this, focus);
    }

    @Override
    public void onTrimMemory(int level) {
        super.onTrimMemory(level);
        ImageLoader.trimMemory(this, level);
        ImmersivePoster.trimMemory(level);
    }

    @Override
    public void onLowMemory() {
        super.onLowMemory();
        images.evictAll();
        ImmersivePoster.trimMemory(TRIM_MEMORY_COMPLETE);
    }

    @Override
    protected void onStart() {
        super.onStart();
        activeActivity = this;
        foreground = true;
        CspEngine.syncAllPluginActivities(this);
        syncCastService();
        syncSpiderGateway();
        UpdateManager.get(this)
                .listen(
                        () -> {
                            if (updateScreen != null) updateScreen.refresh();
                            if (foreground
                                    && current != null
                                    && current.home
                                    && appDialog == null
                                    && UpdateManager.get(this).consumeNotice())
                                toast("发现新版，可在设置 → 软件更新查看");
                        });
        ui.removeCallbacks(automaticUpdate);
        ui.postDelayed(automaticUpdate, 4000);
    }

    @Override
    protected void onResume() {
        super.onResume();
        activeActivity = this;
        foreground = true;
        CspEngine.syncAllPluginActivities(this);
        syncCastService();
        syncSpiderGateway();
        if (layoutReady && !privateMode) {
            SourceController.runDailyAutoUpdateIfNeeded(this, false);
        }
    }

    @Override
    protected void onUserLeaveHint() {
        super.onUserLeaveHint();
        if (playing
                && current != null
                && current.player
                && mobilePrefs().getBoolean(Prefs.AUTO_PIP, false)) {
            enterAppPip();
        }
    }

    @Override
    protected void onPause() {
        clearStartupBootGuard(getCacheDir());
        cancelActiveTransition();
        if (markerHost != null) markerHost.abort();
        if (playerChrome != null) playerChrome.cancelEpisodeHoldSwitch();
        savePlaybackHistory(true);
        super.onPause();
    }

    @Override
    protected void onStop() {
        clearStartupBootGuard(getCacheDir());
        cancelActiveTransition();
        PrivacySpace.cancelPrompt(this);
        if (playerChrome != null) playerChrome.cancelEpisodeHoldSwitch();
        finishSeek(false);
        if (playbackLoading != null) {
            clearPlaybackLoading();
            cancelPageRequests();
            stopWeb();
        }
        UpdateManager.get(this).listen(null);
        ui.removeCallbacks(automaticUpdate);
        if (phoneConfig != null) {
            PhoneConfigDialog session = phoneConfig;
            session.close();
            if (session.dialog != null) session.dialog.dismiss();
        }
        CrashReportDialog.closeActiveShareSession();
        TvQrInputHelper.dismissActive();
        if (searchScreen != null) {
            searchScreen.closeQrServer();
            if (searchScreen.qrDialog != null && searchScreen.qrDialog.isShowing()) {
                searchScreen.qrDialog.dismiss();
            }
        }
        stopCastService();
        clearLiveNumber();
        if (startupIntro != null) startupIntro.cancel();
        introSkipKey = false;
        savePlaybackHistory(true);
        if (isFinishing() && !privateMode && !switchingPrivacy) {
            CloudSyncDialog.pushOnExit(this);
        }
        foreground = false;
        super.onStop();
        boolean keepBgPlay =
                (android.os.Build.VERSION.SDK_INT >= 24 && isInPictureInPictureMode())
                        || mobilePrefs().getBoolean(Prefs.BACKGROUND_PLAY, false);
        if (player != null && !keepBgPlay)
            try {
                player.pause();
                playing = false;
                if (embyReporter != null) embyReporter.update(player.getCurrentPosition(), true);
                if (playStatus != null) playStatus.setText("已暂停");
            } catch (Exception e) {
                AppLog.w("MainActivity", "pause player onStop failed", e);
            }
    }

    @Override
    protected void onDestroy() {
        if (inlinePlayer != null) {
            inlinePlayer.detach();
            inlinePlayer = null;
        }
        CloudSyncDialog.cancel(this);
        if (isTvDevice() && privateMode && !switchingPrivacy) VideoMarkerRepository.clearPrivate();
        if (privateMode && isFinishing() && !switchingPrivacy) {
            MobileShell.clearSearchSession();
            VideoSkipStore.clearPrivateRecords();
            SubtitlePreferenceStore.clearPrivateRecords();
            VideoMarkerRepository.clearPrivate();
            PrivacySpace.active = false;
        }
        if (activeActivity == this) activeActivity = null;
        cancelActiveTransition();
        dismissOnboarding();
        clearPlaybackLoading();
        TvQrInputHelper.dismissActive();
        if (phoneConfig != null) phoneConfig.close();
        stopCastService();
        stopSpiderGateway();
        if (startupIntro != null) startupIntro.cancel();
        if (searchScreen != null) searchScreen.close();
        stopWeb();
        stopMagnet();
        generation++;
        releasePlayer();
        if (!privateMode && !switchingPrivacy && (isFinishing() || activeActivity == null)) {
            CloudSyncDialog.pushOnExit(this);
        }
        closeEngines();
        cancelArtwork();
        cancelPageRequests();
        details.shutdownNow();
        worker.shutdownNow();
        artwork.shutdownNow();
        phoneticWork.shutdownNow();
        ui.removeCallbacksAndMessages(null);
        images.evictAll();
        ImmersivePoster.trimMemory(TRIM_MEMORY_COMPLETE);
        clearStartupBootGuard(getCacheDir());
        super.onDestroy();
    }

    void settings() {
        MobileRootShell.openTab(this, MobileRootShell.TAB_SETTINGS);
    }
}
