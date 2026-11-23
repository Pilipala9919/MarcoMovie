package com.pilipala.marcomovie;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.*;
import android.widget.*;
import com.google.zxing.BarcodeFormat;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;
import org.json.*;
import java.util.*;

/** Dedicated global search page with a local remote-control keyboard. */
public final class GlobalSearchScreen implements AutoCloseable {
    final MainActivity a;
    final String initial;
    PinyinKeyboardModel keyboard;
    EditText input;
    TextView composition, status;
    boolean syncingInput, imeActive;
    int imeConnectionDepth;
    Runnable pendingImeRead;

    private interface ImeEdit {
        boolean run();
    }

    long lastInputClickMs;
    boolean resultPrivateMode;
    TvSearchContext pageContext;
    boolean contextDiscarded;
    final TvSearchPageSlot pageRequests = new TvSearchPageSlot();
    String pageFailureSource = "", pageFailureReason = "";
    final List<Cms.Site> searchSites = new ArrayList<>();
    final Map<String, Integer> sourceScroll = new HashMap<>(), sourceLimits = new HashMap<>();
    final Map<String, String> sourceFocus = new HashMap<>();
    Runnable pendingInputClick;
    LinearLayout candidates, keys, resultBody, sourceFilters;
    SearchCoordinator coordinator, retryCoordinator;
    List<String> searchVariants = Collections.emptyList();
    int sourceCount, columns = 4;
    Button retrySource;
    boolean closed;
    int pageTicket, searchSerial, candidatePage, finished, failed, timedOut, busy, matched;
    String activeFilter = "", submitted = "", edited = "";
    TvSearchImeState imeDraft = new TvSearchImeState();
    Runnable pendingSearch, pendingRender;
    java.util.concurrent.Future<?> expansion;
    java.util.concurrent.Future<?> suggestionWork;
    int suggestionSerial;
    String suggestedQuery;
    HorizontalScrollView suggestionScroll;
    LinearLayout titleSuggestions;
    final Map<String, Button> filterButtons = new LinkedHashMap<>();
    final Map<String, String> filterNames = new HashMap<>();
    final Set<String> displayed = new LinkedHashSet<>();
    LinearLayout resultGrid, lastRow;
    TextView emptyResult, resultHint;
    Button moreResults;
    int shownLimit = 24, renderPasses;
    boolean focusNewResults, restoringResults;
    ScrollView resultScroll;
    int savedResultScroll;
    long resultTime;
    Cms.Config resultConfig;
    final LinkedHashMap<String, SourceResult> results = new LinkedHashMap<>();
    final Map<String, LinearLayout> posterCards = new HashMap<>();
    final Map<PinyinKeyboardModel.Mode, Button> modeButtons = new LinkedHashMap<>();
    SearchInputServer qrServer;
    int qrGeneration;
    String qrAddress = "";
    AppDialog qrDialog;

    private static Snapshot cache;

    private static final class Snapshot {
        final TvSearchContext context;
        final String query, filter;
        final long time;
        final List<String> variants;
        final List<Cms.Site> sites;
        final Map<String, SourceResult> results;
        final Map<String, Integer> scroll, limits;
        final Map<String, String> focus;
        final PinyinKeyboardModel.Snapshot keyboard;
        final TvSearchImeState ime;
        final int candidatePage;

        Snapshot(GlobalSearchScreen screen) {
            context = screen.pageContext;
            query = screen.submitted;
            filter = screen.activeFilter;
            time = screen.resultTime;
            variants = new ArrayList<>(screen.searchVariants);
            sites = new ArrayList<>(screen.searchSites);
            results = new LinkedHashMap<>(screen.results);
            scroll = new HashMap<>(screen.sourceScroll);
            limits = new HashMap<>(screen.sourceLimits);
            focus = new HashMap<>(screen.sourceFocus);
            keyboard = screen.keyboard == null ? null : screen.keyboard.snapshot();
            ime = screen.imeDraft.copy();
            candidatePage = screen.candidatePage;
        }
    }

    static final class SourceResult {
        final Cms.Site site;
        final List<Cms.Video> videos;
        final SearchCoordinator.Outcome outcome;
        final TvSearchPages pages;

        SourceResult(Cms.Site site, List<Cms.Video> videos, SearchCoordinator.Outcome outcome) {
            this(site, videos, outcome, null);
        }

        SourceResult(
                Cms.Site site,
                List<Cms.Video> videos,
                SearchCoordinator.Outcome outcome,
                TvSearchPages pages) {
            this.site = site;
            this.videos = videos;
            this.outcome = outcome;
            this.pages = pages;
        }
    }

    public GlobalSearchScreen(MainActivity activity, String initialKeyword) {
        a = activity;
        initial = initialKeyword == null ? "" : initialKeyword;
    }

    public void show() {
        if (pageContext != null && !contextMatches()) discardContext();
        PinyinKeyboardModel.Snapshot restoredKeyboard =
                keyboard == null ? null : keyboard.snapshot();
        int restoredCandidatePage = candidatePage;
        String restored = keyboard == null ? (contextDiscarded ? "" : initial) : keyboard.query();
        Snapshot saved = cache;
        if (results.isEmpty()
                && saved != null
                && saved.context != null
                && !a.privateMode
                && saved.context.matches(a.config, a.privateMode, a.engineEpoch)
                && System.currentTimeMillis() - saved.time >= 0
                && System.currentTimeMillis() - saved.time < 7200000L
                && (restored.trim().isEmpty() || restored.trim().equals(saved.query))) {
            restored = submitted = saved.query;
            restoredKeyboard = saved.keyboard;
            imeDraft = saved.ime.copy();
            restoredCandidatePage = saved.candidatePage;
            resultConfig = a.config;
            resultPrivateMode = a.privateMode;
            resultTime = saved.time;
            searchVariants = saved.variants;
            results.putAll(saved.results);
            searchSites.addAll(saved.sites);
            sourceCount = searchSites.size();
            activeFilter = saved.filter;
            sourceScroll.putAll(saved.scroll);
            sourceLimits.putAll(saved.limits);
            sourceFocus.putAll(saved.focus);
            shownLimit =
                    sourceLimits.containsKey(activeFilter) ? sourceLimits.get(activeFilter) : 24;
            savedResultScroll =
                    sourceScroll.containsKey(activeFilter) ? sourceScroll.get(activeFilter) : 0;
            recount();
        }
        boolean searchAgain =
                !submitted.isEmpty() || (!contextDiscarded && !initial.trim().isEmpty());
        boolean reuse =
                !results.isEmpty()
                        && submitted.equals(restored.trim())
                        && resultConfig == a.config
                        && resultPrivateMode == a.privateMode
                        && System.currentTimeMillis() - resultTime >= 0
                        && System.currentTimeMillis() - resultTime < 7200000L;
        a.renderPage("", "");
        closed = false;
        edited = "";
        syncingInput = false;
        imeActive = false;
        lastInputClickMs = 0L;
        if (pendingInputClick != null) {
            a.ui.removeCallbacks(pendingInputClick);
            pendingInputClick = null;
        }
        filterButtons.clear();
        displayed.clear();
        posterCards.clear();
        modeButtons.clear();
        resultGrid = null;
        lastRow = null;
        emptyResult = null;
        moreResults = null;
        pageTicket = a.generation;
        pageContext = new TvSearchContext(a.config, a.privateMode, a.engineEpoch);
        if (!a.isTvDevice()) {
            a.root.setBackgroundColor(0xff101013);
            if (a.root.getChildAt(0) instanceof ImageLoader.Atmosphere) a.root.removeViewAt(0);
        }
        a.body.setPadding(a.dp(32), a.dp(14), a.dp(32), a.dp(16));
        try {
            keyboard = new PinyinKeyboardModel(a.getAssets().open("search/pinyin-characters.tsv"));
        } catch (Exception missing) {
            a.paragraph("内置拼音字库无法读取，请重新安装完整版本。");
            return;
        }
        if (restoredKeyboard != null) keyboard.restore(restoredKeyboard);
        else keyboard.set(restored);
        LinearLayout split = a.row();
        split.setGravity(Gravity.TOP);
        int height =
                Math.max(
                        260,
                        Math.round(a.windowHeight() / a.getResources().getDisplayMetrics().density)
                                - 30);
        a.body.addView(split, new LinearLayout.LayoutParams(-1, a.dp(height)));
        LinearLayout left = a.vertical();
        left.setPadding(a.dp(4), a.dp(6), a.dp(30), a.dp(10));
        TvScrollView keyboardScroll = new TvScrollView(a);
        keyboardScroll.setFocusFrameEnabled(false);
        keyboardScroll.setTag("search-keyboard-scroll");
        keyboardScroll.setVerticalScrollBarEnabled(false);
        keyboardScroll.setClipChildren(false);
        keyboardScroll.setClipToPadding(false);
        keyboardScroll.addView(left, new ScrollView.LayoutParams(-1, -2));
        split.addView(keyboardScroll, new LinearLayout.LayoutParams(a.dp(294), -1));
        float availableWidth = a.windowWidth() / a.getResources().getDisplayMetrics().density - 358;
        columns =
                a.isTvDevice()
                        ? Math.max(2, Math.min(6, (int) (availableWidth / 98)))
                        : TvLayoutPolicy.searchColumns(availableWidth);
        LinearLayout headingRow = a.row();
        headingRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView heading = a.text("搜索所有片源", 22, MainActivity.WHITE);
        heading.setTypeface(null, Typeface.BOLD);
        heading.setSingleLine(true);
        headingRow.addView(heading, new LinearLayout.LayoutParams(0, -2, 1));
        Button qrBtn = a.navButton("扫码输入", "search-qr-button", () -> showQrDialog(false));
        qrBtn.setTextSize(12);
        qrBtn.setMinHeight(a.dp(30));
        qrBtn.setMinimumHeight(a.dp(30));
        qrBtn.setPadding(a.dp(10), a.dp(3), a.dp(10), a.dp(3));
        if (!a.isTvDevice()) headingRow.addView(qrBtn, new LinearLayout.LayoutParams(-2, a.dp(30)));
        left.addView(headingRow, new LinearLayout.LayoutParams(-1, -2));
        a.gap(left, 16);
        input =
                new EditText(a) {
                    @Override
                    public android.view.inputmethod.InputConnection onCreateInputConnection(
                            android.view.inputmethod.EditorInfo info) {
                        android.view.inputmethod.InputConnection base =
                                super.onCreateInputConnection(info);
                        if (base == null) return null;
                        final EditText owner = this;
                        return new android.view.inputmethod.InputConnectionWrapper(base, false) {
                            private boolean edit(ImeEdit change) {
                                if (!current() || !imeActive || input != owner) return false;
                                imeConnectionDepth++;
                                try {
                                    return change.run();
                                } finally {
                                    imeConnectionDepth--;
                                    captureImeUpdate();
                                }
                            }

                            @Override
                            public boolean setComposingText(CharSequence text, int cursor) {
                                return edit(() -> super.setComposingText(text, cursor));
                            }

                            @Override
                            public boolean setComposingRegion(int start, int end) {
                                return edit(() -> super.setComposingRegion(start, end));
                            }

                            @Override
                            public boolean commitText(CharSequence text, int cursor) {
                                return edit(() -> super.commitText(text, cursor));
                            }

                            @Override
                            public boolean finishComposingText() {
                                return edit(() -> super.finishComposingText());
                            }

                            @Override
                            public boolean setSelection(int start, int end) {
                                return edit(() -> super.setSelection(start, end));
                            }

                            @Override
                            public boolean deleteSurroundingText(int before, int after) {
                                return edit(() -> super.deleteSurroundingText(before, after));
                            }
                        };
                    }

                    @Override
                    public boolean onKeyPreIme(int keyCode, KeyEvent event) {
                        if (keyCode == KeyEvent.KEYCODE_BACK && imeActive) {
                            if (event.getAction() == KeyEvent.ACTION_UP && !event.isCanceled()) {
                                finishSystemIme(false);
                                hideSystemIme();
                                setCursorVisible(false);
                                setShowSoftInputOnFocus(false);
                            }
                            return true;
                        }
                        return super.onKeyPreIme(keyCode, event);
                    }

                    @Override
                    public boolean onKeyDown(int keyCode, KeyEvent event) {
                        if (keyCode == KeyEvent.KEYCODE_DPAD_CENTER
                                || keyCode == KeyEvent.KEYCODE_ENTER
                                || keyCode == KeyEvent.KEYCODE_NUMPAD_ENTER) {
                            if (event.getRepeatCount() == 0) {
                                FocusMotion.key(a, this, keyCode, event);
                                performClick();
                            }
                            return true;
                        }
                        if (keyCode == KeyEvent.KEYCODE_DPAD_DOWN
                                || keyCode == KeyEvent.KEYCODE_DPAD_UP
                                || (!imeActive
                                        && (keyCode == KeyEvent.KEYCODE_DPAD_LEFT
                                                || keyCode == KeyEvent.KEYCODE_DPAD_RIGHT))) {
                            return false;
                        }
                        return super.onKeyDown(keyCode, event);
                    }

                    @Override
                    public boolean onKeyUp(int keyCode, KeyEvent event) {
                        if (keyCode == KeyEvent.KEYCODE_DPAD_CENTER
                                || keyCode == KeyEvent.KEYCODE_ENTER
                                || keyCode == KeyEvent.KEYCODE_NUMPAD_ENTER) {
                            FocusMotion.key(a, this, keyCode, event);
                            return true;
                        }
                        if (keyCode == KeyEvent.KEYCODE_DPAD_DOWN
                                || keyCode == KeyEvent.KEYCODE_DPAD_UP
                                || (!imeActive
                                        && (keyCode == KeyEvent.KEYCODE_DPAD_LEFT
                                                || keyCode == KeyEvent.KEYCODE_DPAD_RIGHT))) {
                            return false;
                        }
                        return super.onKeyUp(keyCode, event);
                    }
                };
        input.setTextSize(18);
        input.setTextColor(MainActivity.WHITE);
        input.setHintTextColor(MainActivity.MUTED);
        input.setHint("输入片名…（双击调出输入法）");
        input.setGravity(Gravity.CENTER_VERTICAL);
        input.setIncludeFontPadding(false);
        input.setTag("primary");
        input.setContentDescription("搜索内容");
        input.setSingleLine(true);
        input.setInputType(android.text.InputType.TYPE_CLASS_TEXT);
        input.setImeOptions(android.view.inputmethod.EditorInfo.IME_ACTION_SEARCH);
        input.setShowSoftInputOnFocus(false);
        input.setCursorVisible(false);
        input.setEllipsize(android.text.TextUtils.TruncateAt.START);
        input.setPadding(a.dp(14), a.dp(10), a.dp(12), a.dp(10));
        input.setBackground(a.bg(0xff29292e, 10));
        input.setFocusable(true);
        input.setFocusableInTouchMode(true);
        input.setClickable(true);
        input.setOnFocusChangeListener(
                (v, f) -> {
                    if (!f && imeActive) {
                        finishSystemIme(false);
                        input.setCursorVisible(false);
                        input.setShowSoftInputOnFocus(false);
                        hideSystemIme();
                    }
                    FocusMotion.style(
                            a,
                            input,
                            f,
                            0xff29292e,
                            0xff35353e,
                            10,
                            MainActivity.WHITE,
                            MainActivity.WHITE,
                            true,
                            1.01f);
                });
        input.setOnClickListener(v -> handleInputClick());
        input.setOnEditorActionListener(
                (v, actionId, event) -> {
                    finishSystemIme(true);
                    hideSystemIme();
                    submit();
                    return true;
                });
        input.addTextChangedListener(
                new android.text.TextWatcher() {
                    @Override
                    public void beforeTextChanged(
                            CharSequence s, int start, int count, int after) {}

                    @Override
                    public void onTextChanged(CharSequence s, int start, int before, int count) {}

                    @Override
                    public void afterTextChanged(android.text.Editable s) {
                        if (!current() || syncingInput || keyboard == null) return;
                        if (imeActive) {
                            // replace() may notify this watcher before BaseInputConnection sets
                            // spans.
                            if (imeConnectionDepth == 0) {
                                if (pendingImeRead != null) a.ui.removeCallbacks(pendingImeRead);
                                pendingImeRead =
                                        () -> {
                                            pendingImeRead = null;
                                            captureImeUpdate();
                                        };
                                a.ui.post(pendingImeRead);
                            }
                            return;
                        } else {
                            imeDraft.clear();
                            keyboard.set(s == null ? "" : s.toString());
                        }
                        updateAfterImeInput();
                    }
                });
        input.setOnKeyListener((v, key, event) -> physicalKey(key, event));
        if (a.isTvDevice()) {
            LinearLayout inputRow = a.row();
            inputRow.setGravity(Gravity.CENTER_VERTICAL);
            inputRow.setClipChildren(false);
            inputRow.setClipToPadding(false);
            inputRow.setBackground(a.bg(0xff29292e, 12));
            inputRow.addView(input, new LinearLayout.LayoutParams(0, a.dp(48), 1));
            View qrIconBtn = buildTvQrIconButton();
            LinearLayout.LayoutParams qrLp = new LinearLayout.LayoutParams(a.dp(40), a.dp(40));
            qrLp.rightMargin = a.dp(4);
            inputRow.addView(qrIconBtn, qrLp);
            left.addView(inputRow, new LinearLayout.LayoutParams(-1, a.dp(48)));
        } else left.addView(input, new LinearLayout.LayoutParams(-1, a.dp(48)));
        composition = a.text("", 12, MainActivity.MUTED);
        composition.setSingleLine(true);
        composition.setPadding(a.dp(2), a.dp(5), 0, 0);
        left.addView(composition, new LinearLayout.LayoutParams(-1, a.dp(25)));
        candidates = a.row();
        left.addView(candidates, new LinearLayout.LayoutParams(-1, a.dp(34)));
        LinearLayout modes = a.row();
        left.addView(modes, new LinearLayout.LayoutParams(-1, a.dp(38)));
        modeButton(modes, "拼音", PinyinKeyboardModel.Mode.PINYIN);
        modeButton(modes, "字母", PinyinKeyboardModel.Mode.LETTERS);
        modeButton(modes, "数字", PinyinKeyboardModel.Mode.NUMBERS);
        keys = a.vertical();
        left.addView(keys);
        a.gap(left, 5);
        LinearLayout editing = a.row();
        left.addView(editing);
        keyButton(
                editing,
                "空格",
                "search-space",
                () -> {
                    keyboard.space();
                    changed();
                },
                1);
        keyButton(
                editing,
                "删除",
                "search-delete",
                () -> {
                    keyboard.backspace();
                    changed();
                },
                1);
        keyButton(
                editing,
                "清空",
                "search-clear",
                () -> {
                    keyboard.clear();
                    changed();
                },
                1);
        Button submit = a.button("立即搜索", "search-submit", () -> submit());
        submit.setTextSize(15);
        submit.setMinHeight(a.dp(40));
        submit.setMinimumHeight(a.dp(40));
        submit.setPadding(a.dp(8), a.dp(5), a.dp(8), a.dp(5));
        LinearLayout.LayoutParams submitSize = new LinearLayout.LayoutParams(-1, a.dp(42));
        submitSize.topMargin = a.dp(8);
        left.addView(submit, submitSize);
        LinearLayout right = a.vertical();
        split.addView(right, new LinearLayout.LayoutParams(0, -1, 1));
        status = a.text("输入即搜索 · 停顿片刻自动更新结果。", 14, MainActivity.MUTED);
        status.setMinHeight(a.dp(30));
        LinearLayout resultHeader = a.row();
        resultHeader.setGravity(Gravity.CENTER_VERTICAL);
        TextView resultTitle = a.text("搜索结果", 19, MainActivity.WHITE);
        resultTitle.setTypeface(null, Typeface.BOLD);
        if (a.isTvDevice()) resultHeader.addView(resultTitle);
        else right.addView(status);
        HorizontalScrollView filterScroll = new HorizontalScrollView(a);
        filterScroll.setTag("search-source-scroll");
        filterScroll.setHorizontalScrollBarEnabled(false);
        filterScroll.setClipChildren(false);
        filterScroll.setClipToPadding(false);
        sourceFilters = a.row();
        sourceFilters.setClipChildren(false);
        sourceFilters.setClipToPadding(false);
        sourceFilters.setPadding(a.dp(4), a.dp(5), a.dp(4), a.dp(5));
        filterScroll.addView(sourceFilters);
        if (a.isTvDevice()) {
            resultHeader.addView(filterScroll, new LinearLayout.LayoutParams(0, a.dp(46), 1));
            right.addView(resultHeader);
            right.addView(status);
        } else right.addView(filterScroll, new LinearLayout.LayoutParams(-1, a.dp(46)));
        if (a.isTvDevice()) {
            suggestionScroll = new HorizontalScrollView(a);
            suggestionScroll.setTag("search-title-suggestions");
            suggestionScroll.setHorizontalScrollBarEnabled(false);
            suggestionScroll.setClipChildren(false);
            suggestionScroll.setClipToPadding(false);
            titleSuggestions = a.row();
            titleSuggestions.setGravity(Gravity.CENTER_VERTICAL);
            titleSuggestions.setClipChildren(false);
            titleSuggestions.setClipToPadding(false);
            titleSuggestions.setPadding(a.dp(4), a.dp(6), a.dp(8), a.dp(6));
            suggestionScroll.addView(titleSuggestions);
            suggestionScroll.setVisibility(View.GONE);
            LinearLayout.LayoutParams sugLp = new LinearLayout.LayoutParams(-1, a.dp(50));
            sugLp.topMargin = a.dp(4);
            sugLp.bottomMargin = a.dp(4);
            right.addView(suggestionScroll, sugLp);
        }
        resultScroll = new TvScrollView(a);
        resultScroll.setTag("global-search-results");
        resultScroll.setClipToPadding(false);
        resultBody = a.vertical();
        resultBody.setPadding(a.dp(6), a.dp(12), a.dp(6), a.dp(28));
        resultScroll.addView(resultBody);
        right.addView(resultScroll, new LinearLayout.LayoutParams(-1, 0, 1));
        if (!a.privateMode) {
            HotTitleCatalog.ensureLoadedAsync(
                    a,
                    () -> {
                        if (current() && !a.privateMode) {
                            suggestedQuery = null;
                            updateTitleSuggestions();
                        }
                    });
        }
        rebuildKeys();
        if (reuse) {
            edited = restored.trim();
            changed();
            resetGrid();
            restoringResults = true;
            renderFilters();
            renderResults();
            status.setText("已恢复上次结果 · " + matched + " 个来源有结果，可点立即搜索刷新");
        } else {
            changed();
            showHistory();
            if (searchAgain && !restored.trim().isEmpty()) submit();
        }
        candidatePage = restoredCandidatePage;
        renderCandidates();
    }

    boolean contextMatches() {
        return pageContext != null && pageContext.matches(a.config, a.privateMode, a.engineEpoch);
    }

    boolean current() {
        return !closed
                && !a.isFinishing()
                && !a.switchingPrivacy
                && pageTicket == a.generation
                && contextMatches();
    }

    static void invalidateContext(MainActivity activity) {
        TvSearchContext.revokeAll();
        cache = null;
        activity.ui.removeCallbacks(activity.learnPendingTitles);
        activity.pendingTitles.clear();
        if (activity.searchScreen != null) activity.searchScreen.discardContext();
    }

    private void discardContext() {
        close();
        contextDiscarded = true;
        submitted = edited = activeFilter = "";
        keyboard = null;
        imeDraft.clear();
        if (input != null) input.setText("");
        if (composition != null) composition.setText("");
        if (resultBody != null) resultBody.removeAllViews();
        if (sourceFilters != null) sourceFilters.removeAllViews();
        results.clear();
        searchSites.clear();
        searchVariants = Collections.emptyList();
        sourceScroll.clear();
        sourceLimits.clear();
        sourceFocus.clear();
        shownLimit = 24;
        savedResultScroll = 0;
    }

    private void cacheResults() {
        if (contextMatches() && !a.privateMode && !submitted.isEmpty() && !results.isEmpty())
            cache = new Snapshot(this);
    }

    private void recount() {
        finished = results.size();
        failed = timedOut = busy = matched = 0;
        for (SourceResult result : results.values()) {
            if (result.outcome == SearchCoordinator.Outcome.RESULT) matched++;
            if (result.outcome == SearchCoordinator.Outcome.FAILED) failed++;
            if (result.outcome == SearchCoordinator.Outcome.TIMEOUT) timedOut++;
            if (result.outcome == SearchCoordinator.Outcome.BUSY) busy++;
        }
    }

    void modeButton(LinearLayout row, String title, PinyinKeyboardModel.Mode mode) {
        Button b =
                keyButton(
                        row,
                        title,
                        "search-mode:" + mode.name(),
                        () -> {
                            keyboard.mode(mode);
                            candidatePage = 0;
                            rebuildKeys();
                            changed();
                        },
                        1);
        modeButtons.put(mode, b);
    }

    Button keyButton(LinearLayout row, String label, String tag, Runnable action, float weight) {
        Button b =
                a.button(
                        label,
                        tag,
                        () -> {
                            if (!current()) return;
                            if ("search-clear".equals(tag)) imeDraft.clear();
                            if (imeDraft.composing()) {
                                a.toast("输入法文字尚未确认，请双击输入框继续或取消");
                                return;
                            }
                            action.run();
                        });
        b.setMinWidth(0);
        b.setMinimumWidth(0);
        b.setMinHeight(0);
        b.setMinimumHeight(0);
        b.setTextSize(14);
        b.setPadding(a.dp(2), 0, a.dp(2), 0);
        b.setBackground(a.bg(0xff29292e, 7));
        b.setOnFocusChangeListener(
                (v, focus) -> {
                    FocusMotion.style(
                            a,
                            b,
                            focus,
                            0xff29292e,
                            MainActivity.WHITE,
                            7,
                            MainActivity.WHITE,
                            MainActivity.DARK,
                            false,
                            1.08f);
                });
        b.setOnKeyListener((v, key, event) -> physicalKey(key, event));
        LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(0, a.dp(28), weight);
        size.setMargins(a.dp(2), a.dp(2), a.dp(2), a.dp(2));
        row.addView(b, size);
        return b;
    }

    void rebuildKeys() {
        keys.removeAllViews();
        String characters =
                keyboard.mode() == PinyinKeyboardModel.Mode.NUMBERS
                        ? "1234567890-_:.,!?@#&/"
                        : keyboard.mode() == PinyinKeyboardModel.Mode.LETTERS
                                ? "abcdefghijklmnopqrstuvwxyz"
                                : "abcdefghijklmnopqrstuvwxyz'";
        for (int start = 0; start < characters.length(); start += 6) {
            LinearLayout row = a.row();
            keys.addView(row);
            for (int column = 0; column < 6; column++) {
                int index = start + column;
                if (index >= characters.length()) {
                    row.addView(new View(a), new LinearLayout.LayoutParams(0, a.dp(32), 1));
                    continue;
                }
                String letter = characters.substring(index, index + 1);
                keyButton(
                        row,
                        letter.toUpperCase(Locale.ROOT),
                        "search-key:" + letter,
                        () -> {
                            keyboard.input(letter);
                            changed();
                        },
                        1);
            }
        }
        for (Map.Entry<PinyinKeyboardModel.Mode, Button> entry : modeButtons.entrySet())
            entry.getValue()
                    .setText(
                            (entry.getKey() == keyboard.mode() ? "● " : "")
                                    + modeLabel(entry.getKey()));
    }

    String modeLabel(PinyinKeyboardModel.Mode mode) {
        return mode == PinyinKeyboardModel.Mode.PINYIN
                ? "拼音"
                : mode == PinyinKeyboardModel.Mode.LETTERS ? "字母" : "数字";
    }

    void handleInputClick() {
        if (!current()) return;
        long now = android.os.SystemClock.uptimeMillis();
        if (TvV17SearchInput.isDoubleClick(lastInputClickMs, now)) {
            lastInputClickMs = 0L;
            if (pendingInputClick != null) {
                a.ui.removeCallbacks(pendingInputClick);
                pendingInputClick = null;
            }
            openSystemIme();
            return;
        }
        lastInputClickMs = now;
        if (pendingInputClick != null) a.ui.removeCallbacks(pendingInputClick);
        pendingInputClick =
                () -> {
                    pendingInputClick = null;
                    if (!current() || imeActive || !input.hasFocus()) return;
                    View first = a.root.findViewWithTag("search-key:a");
                    if (first != null) first.requestFocus();
                };
        a.ui.postDelayed(pendingInputClick, TvV17SearchInput.DOUBLE_CLICK_MS + 1);
    }

    static int safeSelectionIndex(int requested, int textLength) {
        if (textLength <= 0) return 0;
        return Math.max(0, Math.min(textLength, requested));
    }

    static int computeEffectiveSearchThreads(
            int requestedThreads, boolean tvDevice, boolean lowRamTv) {
        int clamped = Math.max(2, Math.min(6, requestedThreads));
        if (tvDevice && lowRamTv) {
            return Math.min(clamped, 3);
        }
        return clamped;
    }

    static boolean isLowRamMemoryClass(boolean lowRamFlag, int memoryClassMb, long maxHeapBytes) {
        if (lowRamFlag) return true;
        // Standard memoryClass (MB) is unaffected by android:largeHeap="true" (e.g. 192 MB TVs).
        if (memoryClassMb > 0 && memoryClassMb <= 256) return true;
        return maxHeapBytes > 0L && maxHeapBytes <= 256L * 1024L * 1024L;
    }

    private boolean isLowRamTv() {
        boolean lowRamFlag = false;
        int memClassMb = 0;
        try {
            android.app.ActivityManager am =
                    (android.app.ActivityManager)
                            a.getSystemService(android.content.Context.ACTIVITY_SERVICE);
            if (am != null) {
                lowRamFlag = am.isLowRamDevice();
                memClassMb = am.getMemoryClass();
            }
        } catch (Throwable ignored) {
        }
        return isLowRamMemoryClass(lowRamFlag, memClassMb, Runtime.getRuntime().maxMemory());
    }

    void openSystemIme() {
        if (!current() || input == null || keyboard == null) return;
        imeActive = true;
        imeDraft.open(keyboard);
        syncingInput = true;
        String currentText = imeDraft.text == null ? "" : imeDraft.text;
        if (!currentText.equals(input.getText().toString())) {
            input.setText(currentText);
        }
        int actualLen = input.getText() == null ? 0 : input.getText().length();
        try {
            input.setSelection(safeSelectionIndex(imeDraft.selection, actualLen));
        } catch (Exception ignored) {
        }
        if (imeDraft.composing() && imeDraft.start >= 0 && imeDraft.end <= actualLen) {
            try {
                android.view.inputmethod.InputConnection connection =
                        input.onCreateInputConnection(new android.view.inputmethod.EditorInfo());
                if (connection != null) {
                    connection.setComposingRegion(imeDraft.start, imeDraft.end);
                }
            } catch (Exception ignored) {
            }
        }
        syncingInput = false;
        input.setShowSoftInputOnFocus(true);
        input.setCursorVisible(true);
        input.requestFocus();
        try {
            a.getWindow()
                    .setSoftInputMode(
                            WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE
                                    | WindowManager.LayoutParams.SOFT_INPUT_ADJUST_PAN);
        } catch (Exception ignored) {
        }
        android.view.inputmethod.InputMethodManager imm =
                (android.view.inputmethod.InputMethodManager)
                        a.getSystemService(android.content.Context.INPUT_METHOD_SERVICE);
        if (imm != null) {
            if (!imm.showSoftInput(
                    input, android.view.inputmethod.InputMethodManager.SHOW_IMPLICIT)) {
                imm.showSoftInput(input, android.view.inputmethod.InputMethodManager.SHOW_FORCED);
            }
        }
        if (composition != null) composition.setText("已调出电视输入法 · 可直接输入中文或拼音");
    }

    void suspendForIme() {
        cancelSuggestions();
        if (pendingSearch != null) {
            a.ui.removeCallbacks(pendingSearch);
            pendingSearch = null;
        }
        searchSerial++;
        cancelWork();
        edited = ""; // After composition ends, even the same query must replace canceled work.
        status.setText("输入法正在组词，确认后搜索");
        resultBody.setVisibility(View.INVISIBLE);
    }

    void readImeDraft() {
        if (!imeActive || keyboard == null || input == null || !contextMatches()) return;
        android.text.Editable value = input.getText();
        imeDraft.update(
                value.toString(),
                android.view.inputmethod.BaseInputConnection.getComposingSpanStart(value),
                android.view.inputmethod.BaseInputConnection.getComposingSpanEnd(value),
                input.getSelectionEnd(),
                keyboard);
    }

    void captureImeUpdate() {
        if (!current() || !imeActive || syncingInput || imeConnectionDepth != 0) return;
        if (pendingImeRead != null) {
            a.ui.removeCallbacks(pendingImeRead);
            pendingImeRead = null;
        }
        PinyinKeyboardModel.Snapshot previous = keyboard.snapshot();
        readImeDraft();
        if (imeDraft.composing()) suspendForIme();
        else updateAfterImeInput(!TvSearchImeState.sameKeyboard(previous, keyboard.snapshot()));
    }

    void finishSystemIme(boolean commit) {
        if (!imeActive || keyboard == null) return;
        readImeDraft();
        imeActive = false;
        boolean resetCandidates = commit || imeDraft.keyboardChanged(keyboard);
        if (commit) imeDraft.commit(keyboard);
        else imeDraft.close(keyboard);
        if (imeDraft.composing()) {
            suspendForIme();
            return;
        }
        changed(resetCandidates);
    }

    void hideSystemIme() {
        if (input == null) return;
        try {
            android.view.inputmethod.InputMethodManager imm =
                    (android.view.inputmethod.InputMethodManager)
                            a.getSystemService(android.content.Context.INPUT_METHOD_SERVICE);
            if (imm != null) imm.hideSoftInputFromWindow(input.getWindowToken(), 0);
        } catch (Exception ignored) {
        }
    }

    boolean physicalKey(int key, KeyEvent event) {
        if (!current()) return false;
        if (!imeActive && imeDraft.composing()) return false;
        if (imeActive && a.getCurrentFocus() == input) {
            if (key == KeyEvent.KEYCODE_SEARCH && event.getAction() == KeyEvent.ACTION_DOWN) {
                finishSystemIme(true);
                hideSystemIme();
                submit();
                return true;
            }
            return false;
        }
        if (key == KeyEvent.KEYCODE_DPAD_CENTER || key == KeyEvent.KEYCODE_ENTER) {
            View focus = a.getCurrentFocus();
            if (focus != null) FocusMotion.key(a, focus, key, event);
        }
        if (event.getAction() != KeyEvent.ACTION_DOWN) return false;
        if (key == KeyEvent.KEYCODE_DEL) {
            keyboard.backspace();
            changed();
            return true;
        }
        if (key == KeyEvent.KEYCODE_SPACE) {
            keyboard.space();
            changed();
            return true;
        }
        if (key == KeyEvent.KEYCODE_SEARCH) {
            submit();
            return true;
        }
        int unicode = event.getUnicodeChar();
        if (unicode >= 32
                && unicode < 127
                && key != KeyEvent.KEYCODE_DPAD_CENTER
                && key != KeyEvent.KEYCODE_ENTER) {
            keyboard.input(String.valueOf((char) unicode).toLowerCase(Locale.ROOT));
            changed();
            return true;
        }
        return false;
    }

    void changed() {
        changed(true);
    }

    void changed(boolean resetCandidates) {
        if (!current() || input == null || keyboard == null) return;
        String display =
                imeDraft.composing()
                        ? imeDraft.text
                        : keyboard.query().isEmpty()
                                ? ""
                                : keyboard.committed()
                                        + (keyboard.composition().isEmpty()
                                                ? ""
                                                : "  " + keyboard.composition());
        syncingInput = true;
        if (!display.equals(input.getText().toString())) {
            input.setText(display);
            int actualLen = input.getText() == null ? 0 : input.getText().length();
            try {
                input.setSelection(safeSelectionIndex(display.length(), actualLen));
            } catch (Exception ignored) {
            }
        }
        syncingInput = false;
        updateAfterImeInput(resetCandidates);
    }

    void updateAfterImeInput() {
        updateAfterImeInput(true);
    }

    void updateAfterImeInput(boolean resetCandidates) {
        if (!current() || keyboard == null || composition == null) return;
        if (imeDraft.composing()) {
            composition.setText("输入法文字未确认，双击继续输入");
            suspendForIme();
            return;
        }
        resultBody.setVisibility(View.VISIBLE);
        composition.setText(
                keyboard.composition().isEmpty()
                        ? (keyboard.mode() == PinyinKeyboardModel.Mode.PINYIN
                                ? "默认识别首拼 / 全拼 · 双击输入框调出电视输入法"
                                : "直接输入字母、首字母或数字 · 双击输入框调出输入法")
                        : "拼音  " + keyboard.composition());
        if (resetCandidates) candidatePage = 0;
        renderCandidates();
        updateTitleSuggestions();
        scheduleSearch();
    }

    void cancelSuggestions() {
        suggestionSerial++;
        suggestedQuery = null;
        if (suggestionWork != null) {
            suggestionWork.cancel(true);
            suggestionWork = null;
        }
        if (titleSuggestions != null) titleSuggestions.removeAllViews();
        if (suggestionScroll != null) suggestionScroll.setVisibility(View.GONE);
    }

    void updateTitleSuggestions() {
        if (suggestionScroll == null || !current() || keyboard == null) return;
        // The shared index contains public history. Never display it inside a private space.
        if (a.privateMode || imeDraft.composing()) {
            cancelSuggestions();
            return;
        }
        final String query = keyboard.query().trim();
        if (query.equals(suggestedQuery)) return;
        cancelSuggestions();
        suggestedQuery = query;
        if (query.isEmpty()) return;
        final int ticket = suggestionSerial;
        try {
            suggestionWork =
                    a.phoneticWork.submit(
                            () -> {
                                if (a.phonetic == null)
                                    try {
                                        a.phoneticReady.await(
                                                8, java.util.concurrent.TimeUnit.SECONDS);
                                    } catch (InterruptedException cancelled) {
                                        Thread.currentThread().interrupt();
                                        return;
                                    }
                                if (Thread.currentThread().isInterrupted()) return;
                                PhoneticSearchIndex index = a.phonetic;
                                final List<String> values =
                                        index == null
                                                ? Collections.emptyList()
                                                : index.suggestTitles(query, 8);
                                a.ui.post(
                                        () -> {
                                            if (!acceptsTitleSuggestions(ticket, query)) return;
                                            titleSuggestions.removeAllViews();
                                            if (values.isEmpty()) return;
                                            TextView label = a.text("热门联想", 12.5f, 0xa8ebebf5);
                                            label.setTypeface(null, Typeface.BOLD);
                                            label.setPadding(0, 0, a.dp(10), 0);
                                            titleSuggestions.addView(label);
                                            for (String title : values) {
                                                Button choice =
                                                        a.button(
                                                                title,
                                                                "search-title:" + title,
                                                                () -> {
                                                                    if (!current()
                                                                            || ticket
                                                                                    != suggestionSerial
                                                                            || a.privateMode
                                                                            || imeDraft.composing())
                                                                        return;
                                                                    input.requestFocus();
                                                                    imeDraft.clear();
                                                                    keyboard.set(title);
                                                                    changed();
                                                                    submit(true);
                                                                });
                                                choice.setTag("search-title:" + title);
                                                UiCompat.setDefaultFocusHighlightEnabled(
                                                        choice, false);
                                                choice.setTextSize(13.5f);
                                                choice.setSingleLine(true);
                                                choice.setMaxWidth(a.dp(220));
                                                choice.setEllipsize(
                                                        android.text.TextUtils.TruncateAt.END);
                                                choice.setMinWidth(0);
                                                choice.setMinimumWidth(0);
                                                choice.setMinHeight(0);
                                                choice.setMinimumHeight(0);
                                                choice.setPadding(a.dp(14), 0, a.dp(14), 0);
                                                choice.setBackground(
                                                        TvV17Surface.rounded(
                                                                0x28ffffff,
                                                                a.dp(18),
                                                                0x38ffffff,
                                                                a.dp(1)));
                                                choice.setTextColor(0xf2ffffff);
                                                choice.setOnFocusChangeListener(
                                                        (v, focused) -> {
                                                            FocusMotion.unclipAncestors(choice);
                                                            choice.setBackground(
                                                                    TvV17Surface.rounded(
                                                                            focused
                                                                                    ? 0xfff5f5f7
                                                                                    : 0x28ffffff,
                                                                            a.dp(18),
                                                                            focused
                                                                                    ? 0xffffffff
                                                                                    : 0x38ffffff,
                                                                            a.dp(1)));
                                                            choice.setTextColor(
                                                                    focused
                                                                            ? 0xff0b0e14
                                                                            : 0xf2ffffff);
                                                            choice.animate()
                                                                    .scaleX(focused ? 1.05f : 1f)
                                                                    .scaleY(focused ? 1.05f : 1f)
                                                                    .setDuration(120)
                                                                    .start();
                                                        });
                                                LinearLayout.LayoutParams size =
                                                        new LinearLayout.LayoutParams(-2, a.dp(36));
                                                size.rightMargin = a.dp(8);
                                                titleSuggestions.addView(choice, size);
                                            }
                                            suggestionScroll.scrollTo(0, 0);
                                            suggestionScroll.setVisibility(View.VISIBLE);
                                        });
                            });
        } catch (java.util.concurrent.RejectedExecutionException ignored) {
            suggestionWork = null;
        }
    }

    boolean acceptsTitleSuggestions(int ticket, String query) {
        return current()
                && ticket == suggestionSerial
                && !a.privateMode
                && !imeDraft.composing()
                && keyboard != null
                && query.equals(keyboard.query().trim());
    }

    void renderCandidates() {
        candidates.removeAllViews();
        List<PinyinKeyboardModel.Candidate> values = keyboard.candidates();
        if (values.isEmpty()) {
            TextView hint =
                    a.text(
                            keyboard.composition().isEmpty() ? "" : "继续输入拼音，或切到字母搜索",
                            12,
                            MainActivity.MUTED);
            candidates.addView(hint);
            return;
        }
        int pages = (values.size() + 5) / 6;
        candidatePage = Math.max(0, Math.min(candidatePage, pages - 1));
        final int page = candidatePage;
        keyButton(
                        candidates,
                        "‹",
                        "candidate-previous",
                        () -> {
                            candidatePage = Math.max(0, candidatePage - 1);
                            renderCandidates();
                        },
                        1)
                .setEnabled(page > 0);
        for (int i = page * 6; i < Math.min(values.size(), page * 6 + 6); i++) {
            PinyinKeyboardModel.Candidate candidate = values.get(i);
            keyButton(
                    candidates,
                    candidate.text,
                    "candidate:" + candidate.text,
                    () -> {
                        keyboard.select(candidate);
                        changed();
                        View first = a.root.findViewWithTag("search-key:a");
                        if (first != null) first.requestFocus();
                    },
                    1);
        }
        keyButton(
                        candidates,
                        "›",
                        "candidate-next",
                        () -> {
                            candidatePage = Math.min(pages - 1, candidatePage + 1);
                            renderCandidates();
                        },
                        1)
                .setEnabled(page < pages - 1);
    }

    void scheduleSearch() {
        if (!current() || keyboard == null || imeDraft.composing()) return;
        String query = keyboard.query().trim();
        if (query.equals(edited)) return;
        edited = query;
        if (pendingSearch != null) a.ui.removeCallbacks(pendingSearch);
        pendingSearch = null;
        ++searchSerial;
        restoringResults = false;
        cancelWork();
        // Old results must never be shown under a newly edited query during debounce.
        if (!query.equals(submitted)) {
            cache = null;
            results.clear();
            searchSites.clear();
            sourceScroll.clear();
            sourceFocus.clear();
            sourceLimits.clear();
            clearCards();
            filterButtons.clear();
            sourceFilters.removeAllViews();
            resultBody.removeAllViews();
            resultGrid = null;
        }
        if (query.isEmpty()) {
            submitted = "";
            results.clear();
            clearCards();
            filterButtons.clear();
            sourceFilters.removeAllViews();
            resultBody.removeAllViews();
            resultGrid = null;
        }

        if (query.isEmpty()) {
            status.setText("输入即搜索 · 支持中文、首拼和全拼");
            showHistory();
            return;
        }
        status.setText("正在输入… 停顿后自动搜索");
        pendingSearch =
                () -> {
                    pendingSearch = null;
                    if (current() && query.equals(keyboard.query().trim())) submit(false);
                };
        a.ui.postDelayed(pendingSearch, 650);
    }

    void submit() {
        submit(true);
    }

    void submit(boolean remember) {
        if (!current()) return;
        if (imeDraft.composing()) {
            a.toast("请先在输入法确认组词");
            return;
        }
        if (pendingSearch != null) {
            a.ui.removeCallbacks(pendingSearch);
            pendingSearch = null;
        }
        String query = keyboard.query().trim();
        if (query.isEmpty()) {
            status.setText("先输入一个片名。也可以搜索英文、首字母或数字。");
            return;
        }
        cancelWork();
        restoringResults = false;
        submitted = query;
        resultConfig = a.config;
        resultPrivateMode = a.privateMode;
        resultTime = System.currentTimeMillis();
        if (remember) saveHistory(query);
        if (coordinator != null) coordinator.close();
        results.clear();
        clearCards();
        finished = failed = timedOut = busy = matched = 0;
        activeFilter = "";
        filterButtons.clear();
        sourceFilters.removeAllViews();
        shownLimit = 24;
        searchSites.clear();
        sourceScroll.clear();
        sourceFocus.clear();
        sourceLimits.clear();
        resetGrid();
        final int serial = ++searchSerial;
        List<Cms.Site> sources = new ArrayList<>();
        if (a.config != null)
            for (Cms.Site site : SourcePreferences.prioritized(a, a.config.sites))
                if (site.searchable && a.available(site)) sources.add(site);
        // Only changes scheduling order; every available searchable source participates.
        final String selected = a.prefs.getString(Prefs.SELECTED_SITE, "");
        Collections.sort(
                sources,
                (x, y) -> Boolean.compare(!x.key.equals(selected), !y.key.equals(selected)));
        final int total = sources.size();
        sourceCount = total;
        searchSites.addAll(sources);
        renderFilters();
        status.setText(total == 0 ? "没有可搜索来源，请先导入配置并启用来源扩展。" : "正在搜索全部 " + total + " 个来源…");
        if (total == 0) return;
        try {
            expansion =
                    a.phoneticWork.submit(
                            () -> {
                                if (a.phonetic == null)
                                    try {
                                        a.phoneticReady.await(
                                                8, java.util.concurrent.TimeUnit.SECONDS);
                                    } catch (InterruptedException cancelled) {
                                        Thread.currentThread().interrupt();
                                        return;
                                    }
                                if (Thread.currentThread().isInterrupted()) return;
                                final PhoneticSearchIndex index = a.phonetic;
                                final List<String> baseVariants =
                                        index == null
                                                ? Collections.singletonList(query)
                                                : index.searchTerms(query);
                                final List<String> variants =
                                        SearchVariants.mergeTerms(query, baseVariants);
                                a.ui.post(
                                        () -> {
                                            if (current() && serial == searchSerial) {
                                                if (index != null
                                                        && !resultPrivateMode
                                                        && !query.matches("[A-Za-z0-9' -]+"))
                                                    index.prefer(query);
                                                startSources(sources, query, variants, serial);
                                            }
                                        });
                            });
        } catch (java.util.concurrent.RejectedExecutionException ignored) {
            expansion = null;
            startSources(sources, query, SearchVariants.mergeTerms(query, null), serial);
        }
    }

    void startSources(List<Cms.Site> sources, String query, List<String> variants, int serial) {
        if (!current() || serial != searchSerial) return;
        final TvSearchContext context = pageContext;
        final Map<String, TvSearchPages> batches = new java.util.concurrent.ConcurrentHashMap<>();
        final int total = sources.size();
        searchVariants = variants;
        if (variants.size() > 1) {
            String joined =
                    variants.size() >= 2
                            ? variants.get(0) + " / " + variants.get(1)
                            : variants.get(0);
            status.setText("搜索全部 " + total + " 个来源 · 自动匹配 " + joined);
        }
        boolean lowRam = isLowRamTv();
        int effectiveThreads =
                computeEffectiveSearchThreads(
                        a.prefs.getInt(Prefs.SEARCH_THREADS, 6), a.isTvDevice(), lowRam);
        SearchCoordinator.onLowMemoryHook =
                () ->
                        ImmersivePoster.trimMemory(
                                android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL);
        SearchCoordinator.configureMaxPoolThreads(a.isTvDevice() ? (lowRam ? 6 : 8) : 14);
        SearchCoordinator.configureThreads(effectiveThreads);
        coordinator =
                new SearchCoordinator(
                        (site, keyword) -> firstPage(context, site, query, variants, batches),
                        (site, videos, outcome) ->
                                a.ui.post(
                                        () -> {
                                            if (!current()
                                                    || serial != searchSerial
                                                    || resultConfig != a.config
                                                    || resultPrivateMode != a.privateMode) return;
                                            a.learnTitles(videos);
                                            SourceResult source =
                                                    new SourceResult(
                                                            site,
                                                            videos,
                                                            outcome,
                                                            outcome
                                                                                    == SearchCoordinator
                                                                                            .Outcome
                                                                                            .RESULT
                                                                            || outcome
                                                                                    == SearchCoordinator
                                                                                            .Outcome
                                                                                            .EMPTY
                                                                    ? batches.get(site.key)
                                                                    : null);
                                            results.put(site.key, source);
                                            finished++;
                                            if (outcome == SearchCoordinator.Outcome.RESULT)
                                                matched++;
                                            if (outcome == SearchCoordinator.Outcome.FAILED)
                                                failed++;
                                            if (outcome == SearchCoordinator.Outcome.TIMEOUT)
                                                timedOut++;
                                            if (outcome == SearchCoordinator.Outcome.BUSY) busy++;
                                            cacheResults();
                                            updateStatus(total);
                                            scheduleRender();
                                        }),
                        Prefs.clampSearchTimeoutSeconds(a.prefs.getInt(Prefs.SEARCH_TIMEOUT, 20))
                                * 1000L,
                        90000L,
                        a.isTvDevice() ? TvSearchPages.MAX_RESULTS : 24);
        coordinator.start(sources, query);
    }

    List<Cms.Video> searchSource(Cms.Site site, String query, List<String> variants)
            throws Exception {
        return SearchVariants.run(
                query,
                variants,
                title ->
                        !query.matches("[A-Za-z0-9' -]+")
                                || a.phonetic == null
                                || a.phonetic.matches(title, query),
                term -> {
                    try {
                        return Cms.listing(a.engine(site).search(term, 1)).videos;
                    } catch (com.pilipala.catpaw.CatPawHost.DrpySourceException error) {
                        if ("drpy_verification_required".equals(error.code))
                            throw new SearchCoordinator.VerificationRequiredException();
                        throw error;
                    }
                });
    }

    List<Cms.Video> firstPage(
            TvSearchContext context,
            Cms.Site site,
            String query,
            List<String> variants,
            Map<String, TvSearchPages> batches)
            throws Exception {
        if (!a.isTvDevice()) return searchSource(site, query, variants);
        TvSearchPages pages =
                TvSearchPages.first(
                        query,
                        variants,
                        title -> matchesTitle(title, query),
                        (term, page) -> fetchSearchPage(context, site, term, page));
        batches.put(site.key, pages);
        return pages.videos;
    }

    boolean matchesTitle(String title, String query) {
        return !query.matches("[A-Za-z0-9' -]+")
                || a.phonetic == null
                || a.phonetic.matches(title, query);
    }

    Cms.Listing fetchSearchPage(TvSearchContext context, Cms.Site site, String term, int page)
            throws Exception {
        if (!context.matches(a.config, a.privateMode, a.engineEpoch)
                || Thread.currentThread().isInterrupted()) throw new InterruptedException();
        // Initialization may block; never hold the Activity monitor across SingleFlight.get().
        final SourceEngine engine = SourceController.engine(a, site, context);
        if (!context.matches(a.config, a.privateMode, a.engineEpoch)
                || Thread.currentThread().isInterrupted()) throw new InterruptedException();
        try {
            return Cms.listing(engine.search(term, page));
        } catch (com.pilipala.catpaw.CatPawHost.DrpySourceException error) {
            if ("drpy_verification_required".equals(error.code))
                throw new SearchCoordinator.VerificationRequiredException();
            throw error;
        }
    }

    SourceResult nextPageSource() {
        for (SourceResult result : results.values())
            if ((activeFilter.isEmpty() || activeFilter.equals(result.site.key))
                    && result.pages != null
                    && result.pages.hasMore()) return result;
        return null;
    }

    void loadNextPage() {
        if (!current() || pageRequests.get() != null) return;
        final SourceResult source = nextPageSource();
        if (source == null) return;
        final int serial = searchSerial;
        final TvSearchContext context = pageContext;
        final java.util.concurrent.atomic.AtomicReference<TvSearchPages> completed =
                new java.util.concurrent.atomic.AtomicReference<>();
        pageFailureSource = pageFailureReason = "";
        final SearchCoordinator[] owner = new SearchCoordinator[1];
        owner[0] =
                new SearchCoordinator(
                        (site, query) -> {
                            TvSearchPages next =
                                    source.pages.next(
                                            title -> matchesTitle(title, source.pages.query),
                                            (term, page) ->
                                                    fetchSearchPage(context, site, term, page));
                            completed.set(next);
                            return next.videos;
                        },
                        (site, videos, outcome) ->
                                a.ui.post(
                                        () -> {
                                            if (!pageRequests.finish(owner[0])) return;
                                            if (!current() || serial != searchSerial) return;
                                            if (results.get(site.key) != source) {
                                                renderResults();
                                                return;
                                            }
                                            if (completed.get() != null
                                                    && (outcome == SearchCoordinator.Outcome.RESULT
                                                            || outcome
                                                                    == SearchCoordinator.Outcome
                                                                            .EMPTY)) {
                                                TvSearchPages next = completed.get();
                                                results.put(
                                                        site.key,
                                                        new SourceResult(
                                                                site, next.videos, outcome, next));
                                                if (activeFilter.isEmpty()
                                                        || activeFilter.equals(site.key)) {
                                                    shownLimit =
                                                            Math.min(
                                                                            Integer.MAX_VALUE - 24,
                                                                            shownLimit)
                                                                    + 24;
                                                    focusNewResults = true;
                                                }
                                                recount();
                                                cacheResults();
                                            } else {
                                                pageFailureSource = site.key;
                                                pageFailureReason =
                                                        outcome == SearchCoordinator.Outcome.TIMEOUT
                                                                ? "下一页超时"
                                                                : outcome
                                                                                == SearchCoordinator
                                                                                        .Outcome
                                                                                        .VERIFICATION_REQUIRED
                                                                        ? "下一页需网站验证码"
                                                                        : outcome
                                                                                        == SearchCoordinator
                                                                                                .Outcome
                                                                                                .BUSY
                                                                                ? "下一页未完成"
                                                                                : "下一页请求失败";
                                            }
                                            updateStatus(sourceCount);
                                            scheduleRender();
                                        }),
                        Prefs.clampSearchTimeoutSeconds(a.prefs.getInt(Prefs.SEARCH_TIMEOUT, 20))
                                * 1000L,
                        40000L,
                        TvSearchPages.MAX_RESULTS);
        pageRequests.bind(owner[0]);
        owner[0].start(Collections.singletonList(source.site), submitted);
        renderResults();
    }

    void retrySelected() {
        SourceResult selected = results.get(activeFilter);
        if (!current() || selected == null || retryCoordinator != null) return;
        pageRequests.cancel();
        pageFailureSource = pageFailureReason = "";
        final TvSearchContext context = pageContext;
        final Map<String, TvSearchPages> batches = new java.util.concurrent.ConcurrentHashMap<>();
        final String query = submitted;
        final List<String> variants = new ArrayList<>(searchVariants);
        final int serial = searchSerial;
        if (retrySource != null) retrySource.setEnabled(false);
        if (emptyResult != null) emptyResult.setText("正在重新搜索此源…");
        retryCoordinator =
                new SearchCoordinator(
                        (site, ignored) -> firstPage(context, site, query, variants, batches),
                        (site, videos, outcome) ->
                                a.ui.post(
                                        () -> {
                                            if (!current()
                                                    || serial != searchSerial
                                                    || resultConfig != a.config
                                                    || resultPrivateMode != a.privateMode) return;
                                            if (retryCoordinator != null) {
                                                retryCoordinator.close();
                                                retryCoordinator = null;
                                            }
                                            SourceResult old = results.get(site.key);
                                            if (old != null) {
                                                if (old.outcome == SearchCoordinator.Outcome.RESULT)
                                                    matched--;
                                                if (old.outcome == SearchCoordinator.Outcome.FAILED)
                                                    failed--;
                                                if (old.outcome
                                                        == SearchCoordinator.Outcome.TIMEOUT)
                                                    timedOut--;
                                                if (old.outcome == SearchCoordinator.Outcome.BUSY)
                                                    busy--;
                                            }
                                            results.put(
                                                    site.key,
                                                    new SourceResult(
                                                            site,
                                                            videos,
                                                            outcome,
                                                            outcome
                                                                                    == SearchCoordinator
                                                                                            .Outcome
                                                                                            .RESULT
                                                                            || outcome
                                                                                    == SearchCoordinator
                                                                                            .Outcome
                                                                                            .EMPTY
                                                                    ? batches.get(site.key)
                                                                    : null));
                                            if (outcome == SearchCoordinator.Outcome.RESULT)
                                                matched++;
                                            if (outcome == SearchCoordinator.Outcome.FAILED)
                                                failed++;
                                            if (outcome == SearchCoordinator.Outcome.TIMEOUT)
                                                timedOut++;
                                            if (outcome == SearchCoordinator.Outcome.BUSY) busy++;
                                            cacheResults();
                                            updateStatus(sourceCount);
                                            scheduleRender();
                                        }),
                        Prefs.clampSearchTimeoutSeconds(a.prefs.getInt(Prefs.SEARCH_TIMEOUT, 20))
                                * 1000L,
                        40000L,
                        a.isTvDevice() ? TvSearchPages.MAX_RESULTS : 24);
        retryCoordinator.start(Collections.singletonList(selected.site), submitted);
    }

    void updateStatus(int total) {
        String text =
                (finished == total ? "搜索结束" : "搜索中")
                        + " · "
                        + finished
                        + " / "
                        + total
                        + " 个来源已处理 · "
                        + matched
                        + " 个有结果";
        if (timedOut > 0) text += " · " + timedOut + " 个超时";
        if (failed > 0) text += " · " + failed + " 个暂不可用";
        if (busy > 0) text += " · " + busy + " 个未完成";
        int verification = 0;
        for (SourceResult result : results.values())
            if (result.outcome == SearchCoordinator.Outcome.VERIFICATION_REQUIRED) verification++;
        if (verification > 0) text += " · " + verification + " 个需网站验证码";
        status.setText(text);
    }

    void cancelWork() {
        pageRequests.cancel();
        pageFailureSource = pageFailureReason = "";
        if (retryCoordinator != null) {
            retryCoordinator.close();
            retryCoordinator = null;
        }
        if (expansion != null) {
            expansion.cancel(true);
            expansion = null;
        }
        if (coordinator != null) {
            coordinator.close();
            coordinator = null;
        }
        if (pendingRender != null) {
            a.ui.removeCallbacks(pendingRender);
            pendingRender = null;
        }
    }

    void clearCards() {
        for (LinearLayout card : posterCards.values())
            if (card.getChildCount() > 0) card.getChildAt(0).setTag(null);
        posterCards.clear();
    }

    void scheduleRender() {
        if (pendingRender != null) return;
        final int serial = searchSerial;
        pendingRender =
                () -> {
                    pendingRender = null;
                    if (!current() || serial != searchSerial) return;
                    renderFilters();
                    renderResults();
                };
        a.ui.postDelayed(pendingRender, 100);
    }

    void renderFilters() {
        if (!filterButtons.containsKey("")) addFilter("全部", "");
        if (!searchSites.isEmpty()) {
            for (Cms.Site site : searchSites)
                if (!filterButtons.containsKey(site.key)) addFilter(clean(site.name), site.key);
        } else
            for (SourceResult source : results.values())
                if (!filterButtons.containsKey(source.site.key))
                    addFilter(clean(source.site.name), source.site.key);
        updateFilterLabels();
    }

    void addFilter(String label, String key) {
        Button b =
                a.button(
                        label,
                        "search-filter:" + key,
                        () -> {
                            if (a.isTvDevice()) focusSelectedResults();
                            else selectFilter(key);
                        });
        b.setTextSize(12);
        b.setMinWidth(a.dp(64));
        b.setMinimumWidth(a.dp(64));
        b.setMinHeight(0);
        b.setMinimumHeight(0);
        b.setPadding(a.dp(15), 0, a.dp(15), 0);
        b.setSingleLine(true);
        b.setGravity(Gravity.CENTER);
        b.setContentDescription(label);
        b.setOnFocusChangeListener(
                (v, focus) -> {
                    if (focus && a.isTvDevice()) selectFilter(key);
                    styleFilter(b, key, focus);
                });
        if (a.isTvDevice())
            b.setOnKeyListener(
                    (v, keyCode, event) -> {
                        if (keyCode == KeyEvent.KEYCODE_DPAD_DOWN
                                && event.getAction() == KeyEvent.ACTION_DOWN) {
                            focusSelectedResults();
                            return true;
                        }
                        return false;
                    });
        LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(-2, a.dp(34));
        size.setMargins(a.dp(2), 0, a.dp(8), 0);
        sourceFilters.addView(b, size);
        filterButtons.put(key, b);
        filterNames.put(key, label);
        styleFilter(b, key, false);
    }

    void rememberSourcePosition() {
        if (resultScroll == null) return;
        sourceScroll.put(activeFilter, resultScroll.getScrollY());
        sourceLimits.put(activeFilter, shownLimit);
        String tag = focusedTag(resultGrid);
        if (tag != null) sourceFocus.put(activeFilter, tag);
    }

    void selectFilter(String key) {
        if (!current()) return;
        if (key.equals(activeFilter)) return;
        rememberSourcePosition();
        focusNewResults = false;
        activeFilter = key;
        shownLimit = sourceLimits.containsKey(key) ? sourceLimits.get(key) : 24;
        updateFilterLabels();
        resetGrid();
        renderResults();
        final int scroll = sourceScroll.containsKey(key) ? sourceScroll.get(key) : 0;
        final int serial = searchSerial;
        resultScroll.post(
                () -> {
                    if (current() && serial == searchSerial && key.equals(activeFilter))
                        resultScroll.scrollTo(0, scroll);
                });
    }

    void focusSelectedResults() {
        if (!current()) return;
        String tag = sourceFocus.get(activeFilter);
        View target = tag == null ? null : a.root.findViewWithTag(tag);
        if (target == null && !displayed.isEmpty())
            target = posterCards.get(displayed.iterator().next());
        if (target != null) target.requestFocus();
        else if (retrySource != null && retrySource.getVisibility() == View.VISIBLE)
            retrySource.requestFocus();
    }

    void styleFilter(Button b, String key, boolean focused) {
        boolean selected = key.equals(activeFilter);
        b.setSelected(selected);
        b.setTypeface(null, selected ? Typeface.BOLD : Typeface.NORMAL);
        FocusMotion.style(
                a,
                b,
                focused,
                selected ? 0xff465c76 : 0xff272f3a,
                MainActivity.WHITE,
                17,
                selected ? MainActivity.WHITE : 0xffc2cbd7,
                MainActivity.DARK,
                true,
                1.035f);
    }

    boolean hasVerification() {
        for (SourceResult result : results.values())
            if (result.outcome == SearchCoordinator.Outcome.VERIFICATION_REQUIRED) return true;
        return false;
    }

    void updateFilterLabels() {
        for (Map.Entry<String, Button> entry : filterButtons.entrySet()) {
            Button b = entry.getValue();
            String key = entry.getKey();
            if (a.isTvDevice()) {
                String suffix;
                if (key.isEmpty()) {
                    int count = 0;
                    for (SourceResult result : results.values()) count += result.videos.size();
                    suffix =
                            finished < sourceCount
                                    ? " · 搜索中"
                                    : count == 0
                                                    && (failed > 0
                                                            || timedOut > 0
                                                            || busy > 0
                                                            || hasVerification())
                                            ? " · 未完成"
                                            : " " + count;
                } else {
                    SourceResult result = results.get(key);
                    suffix =
                            result == null
                                    ? " · 搜索中"
                                    : result.outcome == SearchCoordinator.Outcome.RESULT
                                                    || result.outcome
                                                            == SearchCoordinator.Outcome.EMPTY
                                            ? " " + result.videos.size()
                                            : result.outcome == SearchCoordinator.Outcome.TIMEOUT
                                                    ? " · 超时"
                                                    : result.outcome
                                                                    == SearchCoordinator.Outcome
                                                                            .VERIFICATION_REQUIRED
                                                            ? " · 验证"
                                                            : result.outcome
                                                                            == SearchCoordinator
                                                                                    .Outcome.BUSY
                                                                    ? " · 未完成"
                                                                    : " · 失败";
                }
                b.setText(filterNames.get(key) + suffix);
            }
            styleFilter(b, key, b.hasFocus());
        }
    }

    void resetGrid() {
        resultBody.removeAllViews();
        displayed.clear();
        lastRow = null;
        resultGrid = a.vertical();
        resultGrid.setClipChildren(false);
        resultBody.addView(resultGrid);
        emptyResult = a.text("等待匹配结果…", 15, MainActivity.MUTED);
        emptyResult.setPadding(a.dp(8), a.dp(24), 0, 0);
        resultBody.addView(emptyResult);
        retrySource = a.navButton("重新搜索此源", "search-retry-source", this::retrySelected);
        retrySource.setVisibility(View.GONE);
        a.addButton(resultBody, retrySource);
        moreResults =
                a.navButton(
                        "显示更多结果",
                        "search-more-results",
                        () -> {
                            if (!current()) return;
                            int available = 0;
                            for (SourceResult r : results.values())
                                if (activeFilter.isEmpty() || activeFilter.equals(r.site.key))
                                    available += r.videos.size();
                            if (available <= shownLimit) loadNextPage();
                            else {
                                shownLimit =
                                        shownLimit > Integer.MAX_VALUE - 24
                                                ? Integer.MAX_VALUE
                                                : shownLimit + 24;
                                focusNewResults = true;
                                renderResults();
                            }
                        });
        moreResults.setVisibility(View.GONE);
        a.addButton(resultBody, moreResults);
        resultHint = a.text("已显示当前取得的结果。", 12, MainActivity.MUTED);
        resultHint.setVisibility(View.GONE);
        resultBody.addView(resultHint);
    }

    void renderResults() {
        if (resultGrid == null) return;
        renderFilters();
        renderPasses++;
        int available = 0, added = 0;
        boolean remaining = false;
        for (SourceResult source : results.values())
            if (activeFilter.isEmpty() || source.site.key.equals(activeFilter))
                for (int i = 0; i < source.videos.size(); i++) {
                    available++;
                    if (available > shownLimit) continue;
                    Cms.Video video = source.videos.get(i);
                    String key = source.site.key + ":" + video.id;
                    if (displayed.contains(key)) continue;
                    if (added >= 4) {
                        remaining = true;
                        continue;
                    }
                    if (displayed.size() % columns == 0 || lastRow == null) {
                        lastRow = a.row();
                        lastRow.setGravity(Gravity.TOP);
                        lastRow.setClipChildren(false);
                        resultGrid.addView(lastRow);
                        for (int column = 0; column < columns; column++) {
                            LinearLayout.LayoutParams blank =
                                    new LinearLayout.LayoutParams(0, 1, 1);
                            blank.setMargins(a.dp(3), a.dp(3), a.dp(8), a.dp(13));
                            lastRow.addView(new View(a), blank);
                        }
                    }
                    LinearLayout card = posterCards.get(key);
                    if (card == null) {
                        card = makeCard(source, video);
                        posterCards.put(key, card);
                    }
                    if (card.getParent() instanceof ViewGroup)
                        ((ViewGroup) card.getParent()).removeView(card);
                    int column = displayed.size() % columns;
                    LinearLayout.LayoutParams cell = new LinearLayout.LayoutParams(0, -2, 1);
                    cell.setMargins(a.dp(3), a.dp(3), a.dp(8), a.dp(13));
                    if (column < lastRow.getChildCount()) {
                        lastRow.removeViewAt(column);
                        lastRow.addView(card, column, cell);
                    } else {
                        lastRow.addView(card, cell);
                    }
                    displayed.add(key);
                    added++;
                    if (focusNewResults) {
                        card.requestFocus();
                        focusNewResults = false;
                    }
                }
        emptyResult.setVisibility(displayed.isEmpty() ? View.VISIBLE : View.GONE);
        if (displayed.isEmpty()) {
            SourceResult selected = results.get(activeFilter);
            emptyResult.setText(
                    selected == null
                            ? (!activeFilter.isEmpty() || finished < sourceCount
                                    ? "正在等待此来源的搜索结果…"
                                    : "本次未获得可显示的结果。可选择上方来源查看具体状态。")
                            : selected.outcome == SearchCoordinator.Outcome.VERIFICATION_REQUIRED
                                    ? "此片源搜索需要完成网站验证码，暂时无法返回结果。可先选择其他片源。"
                                    : selected.outcome == SearchCoordinator.Outcome.FAILED
                                            ? "此源请求失败或返回无效响应，并非确认没有内容。可重试或检查配置。"
                                            : selected.outcome == SearchCoordinator.Outcome.TIMEOUT
                                                    ? "此源搜索超时，可单独重试。"
                                                    : selected.outcome
                                                                    == SearchCoordinator.Outcome
                                                                            .BUSY
                                                            ? "此源尚未完成，可单独重试。"
                                                            : "此源已响应，但没有匹配结果。可更换关键词再试。");
        }
        retrySource.setVisibility(
                !activeFilter.isEmpty() && results.containsKey(activeFilter) && displayed.isEmpty()
                        ? View.VISIBLE
                        : View.GONE);
        retrySource.setEnabled(retryCoordinator == null);
        boolean localMore = available > shownLimit;
        SourceResult next = nextPageSource();
        moreResults.setVisibility(
                localMore || next != null || pageRequests.get() != null ? View.VISIBLE : View.GONE);
        moreResults.setEnabled(pageRequests.get() == null || localMore);
        moreResults.setText(
                localMore
                        ? "显示更多已取得结果"
                        : pageRequests.get() != null
                                ? "正在读取下一页…"
                                : next != null && next.site.key.equals(pageFailureSource)
                                        ? pageFailureReason + " · 重试"
                                        : "读取来源下一页");
        boolean limited = false;
        for (SourceResult r : results.values())
            if ((activeFilter.isEmpty() || activeFilter.equals(r.site.key))
                    && r.pages != null
                    && r.pages.limited) limited = true;
        resultHint.setText(limited ? "部分来源已达5000条保留上限，请缩小关键词继续查找。" : "已显示当前取得的结果；没有更多已确认的来源分页。");
        resultHint.setVisibility(
                !remaining && !localMore && next == null && finished >= sourceCount
                        ? View.VISIBLE
                        : View.GONE);
        if (!remaining && restoringResults) {
            restoringResults = false;
            View saved =
                    a.current == null || a.current.focus == null
                            ? null
                            : a.root.findViewWithTag(a.current.focus);
            if (saved != null) saved.requestFocus();
            final int scroll = savedResultScroll;
            final int serial = searchSerial;
            resultScroll.post(
                    () -> {
                        if (current() && serial == searchSerial) resultScroll.scrollTo(0, scroll);
                    });
        }
        if (remaining && pendingRender == null) {
            final int serial = searchSerial;
            pendingRender =
                    () -> {
                        pendingRender = null;
                        if (current() && serial == searchSerial) renderResults();
                    };
            a.ui.postDelayed(pendingRender, 16);
        }
    }

    LinearLayout makeCard(SourceResult source, Cms.Video video) {
        LinearLayout card = a.vertical();
        card.setPadding(a.dp(4), a.dp(4), a.dp(4), a.dp(8));
        ImageView poster = new ImageView(a);
        if (a.isTvDevice()) TvV17PosterCard.artwork(a, poster);
        else {
            poster.setScaleType(ImageView.ScaleType.CENTER_CROP);
            poster.setBackground(a.bg(0xff25252a, 9));
            poster.setClipToOutline(true);
        }
        int posterWidth =
                a.isTvDevice()
                        ? Math.max(
                                70,
                                Math.min(
                                        110,
                                        (int)
                                                        ((a.windowWidth()
                                                                                / a.getResources()
                                                                                        .getDisplayMetrics()
                                                                                        .density
                                                                        - 360)
                                                                / columns)
                                                - 15))
                        : 110;
        LinearLayout.LayoutParams posterSize =
                new LinearLayout.LayoutParams(a.dp(posterWidth), a.dp(posterWidth * 3 / 2));
        posterSize.gravity = Gravity.CENTER_HORIZONTAL;
        boolean showDoubanBadge = !SourceController.isConfigOrNetdiskActionCard(source.site, video);
        FrameLayout posterWrap =
                TvV17PosterCard.wrapArtworkWithDoubanBadge(a, poster, video, showDoubanBadge);
        card.addView(posterWrap, posterSize);
        a.poster(video.poster, poster);
        TextView title = a.text(video.title, 14, MainActivity.WHITE);
        title.setSingleLine(true);
        title.setEllipsize(android.text.TextUtils.TruncateAt.END);
        title.setPadding(a.dp(2), a.dp(6), 0, 0);
        card.addView(title);
        TextView origin = a.text(clean(source.site.name), 11, MainActivity.MUTED);
        origin.setSingleLine(true);
        origin.setEllipsize(android.text.TextUtils.TruncateAt.END);
        card.addView(origin);
        card.setTag("global-result:" + source.site.key + ":" + video.id);
        card.setFocusable(a.isTvDevice());
        card.setFocusableInTouchMode(a.isTvDevice());
        card.setClickable(true);
        if (a.isTvDevice()) TvFocusFrame.attachCard(card, "search-results-grid");
        a.pressFeedback(card);
        final String query = submitted;
        card.setOnClickListener(
                view -> {
                    if (!current()) return;
                    saveHistory(query);
                    a.openListing(source.site, video);
                });
        card.setOnFocusChangeListener(
                (view, selected) -> {
                    if (selected) sourceFocus.put(activeFilter, String.valueOf(card.getTag()));
                    if (a.isTvDevice()) TvV17PosterCard.focus(a, card, title, selected);
                    else
                        FocusMotion.style(
                                a,
                                card,
                                selected,
                                Color.TRANSPARENT,
                                0xff393940,
                                11,
                                MainActivity.WHITE,
                                MainActivity.WHITE,
                                true,
                                1.035f);
                });
        if (a.isTvDevice())
            card.setOnKeyListener(
                    (v, key, event) -> {
                        if (key == KeyEvent.KEYCODE_DPAD_UP
                                && event.getAction() == KeyEvent.ACTION_DOWN) {
                            int index =
                                    new ArrayList<>(displayed)
                                            .indexOf(source.site.key + ":" + video.id);
                            if (index >= 0 && index < columns) {
                                Button tab = filterButtons.get(activeFilter);
                                if (tab != null) {
                                    tab.requestFocus();
                                    return true;
                                }
                            }
                        }
                        return false;
                    });
        return card;
    }

    String focusedTag(ViewGroup group) {
        View focus = a.getCurrentFocus();
        if (focus == null || focus.getTag() == null) return null;
        View parent = focus;
        while (parent != null) {
            if (parent == group) return String.valueOf(focus.getTag());
            if (!(parent.getParent() instanceof View)) break;
            parent = (View) parent.getParent();
        }
        return null;
    }

    String clean(String title) {
        return title == null
                ? "来源"
                : title.replaceAll("[\\p{So}\\p{Cs}]", "").replace('┃', ' ').trim();
    }

    String ensureQrServer(boolean forceRefresh) throws Exception {
        if (!forceRefresh
                && qrServer != null
                && !qrServer.expired()
                && qrAddress != null
                && !qrAddress.isEmpty()) {
            return qrAddress;
        }
        closeQrServer();
        String ip = PhoneConfigDialog.lanAddress();
        final int generation = qrGeneration;
        qrServer =
                new SearchInputServer(
                        new SearchInputServer.Listener() {
                            @Override
                            public void onKeyword(String keyword, boolean submitNow) {
                                a.ui.post(
                                        () -> {
                                            if (!current()
                                                    || keyboard == null
                                                    || generation != qrGeneration
                                                    || qrServer == null
                                                    || qrServer.expired()) return;
                                            if (submitNow) {
                                                if (qrDialog != null && qrDialog.isShowing()) {
                                                    qrDialog.dismiss();
                                                }
                                                TvQrInputHelper.dismissActive();
                                            }
                                            imeDraft.clear();
                                            keyboard.set(keyword == null ? "" : keyword);
                                            changed();
                                            if (submitNow
                                                    && keyword != null
                                                    && !keyword.isEmpty()) {
                                                submit(true);
                                                a.toast("已接收手机输入：" + keyword);
                                            } else if (keyword == null || keyword.isEmpty()) {
                                                a.toast("已清空电视搜索框");
                                            } else {
                                                a.toast("已同步文字：" + keyword);
                                            }
                                        });
                            }

                            @Override
                            public List<String> recentKeywords() {
                                return !current() || generation != qrGeneration || a.privateMode
                                        ? Collections.emptyList()
                                        : history();
                            }

                            @Override
                            public String currentKeyword() {
                                return !current() || generation != qrGeneration || keyboard == null
                                        ? ""
                                        : keyboard.query().trim();
                            }
                        });
        qrAddress = qrServer.address(ip);
        return qrAddress;
    }

    Bitmap createQrBitmap(String content, int sizePx) throws Exception {
        int px = Math.max(96, sizePx);
        BitMatrix matrix = new QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, px, px);
        int[] pixels = new int[px * px];
        for (int y = 0; y < px; y++) {
            for (int x = 0; x < px; x++) {
                pixels[y * px + x] = matrix.get(x, y) ? Color.BLACK : Color.WHITE;
            }
        }
        return Bitmap.createBitmap(pixels, px, px, Bitmap.Config.ARGB_8888);
    }

    void showQrDialog(boolean forceRefresh) {
        if (!current()) return;
        if (qrDialog != null && qrDialog.isShowing()) {
            qrDialog.dismiss();
            qrDialog = null;
        }
        try {
            String address = ensureQrServer(forceRefresh);
            LinearLayout panel = a.vertical();
            panel.setGravity(Gravity.CENTER_HORIZONTAL);
            TextView note =
                    a.text(
                            "手机与电视连接同一局域网，用手机相机或浏览器扫码即可直接输入中文、英文或拼音并推送到电视全站搜索。",
                            14,
                            MainActivity.MUTED);
            note.setLineSpacing(a.dp(4), 1f);
            panel.addView(note);
            a.gap(panel, 12);
            int qrSize = a.dp(186);
            ImageView qr = new ImageView(a);
            qr.setTag("search-qr-dialog-image");
            qr.setContentDescription("手机扫码输入搜索词二维码");
            qr.setImageBitmap(createQrBitmap(address, qrSize));
            qr.setPadding(a.dp(8), a.dp(8), a.dp(8), a.dp(8));
            qr.setBackground(a.bg(Color.WHITE, 12));
            panel.addView(qr, new LinearLayout.LayoutParams(qrSize + a.dp(16), qrSize + a.dp(16)));
            TextView url = a.text(address, 12, 0xff7cb8ff);
            url.setTag("search-qr-dialog-address");
            url.setGravity(Gravity.CENTER);
            url.setPadding(0, a.dp(10), 0, a.dp(4));
            panel.addView(url);
            panel.addView(a.text("二维码 10 分钟内有效 · 退出搜索页后自动停止监听", 12, MainActivity.MUTED));
            qrDialog =
                    new AppDialog.Builder(a)
                            .setTitle("手机扫码输入搜索词")
                            .setView(panel)
                            .setPositiveButton("刷新二维码", (d, w) -> showQrDialog(true))
                            .setNegativeButton("关闭", null)
                            .create();
            qrDialog.show();
            if (qrDialog.getButton(-2) != null) qrDialog.getButton(-2).requestFocus();
        } catch (Exception error) {
            a.toast("未检测到局域网连接，请确认电视已连接 Wi-Fi 或有线网络");
        }
    }

    void closeQrServer() {
        qrGeneration++;
        if (qrServer != null) {
            qrServer.close();
            qrServer = null;
        }
        qrAddress = "";
    }

    void showHistory() {
        if (!current()) return;
        resultBody.removeAllViews();
        try {
            String address = ensureQrServer(false);
            LinearLayout card = a.row();
            card.setTag("search-inline-qr-card");
            card.setGravity(Gravity.CENTER_VERTICAL);
            card.setPadding(a.dp(14), a.dp(12), a.dp(16), a.dp(12));
            GradientDrawable cardBg = a.bg(0xff1b1d25, 14);
            cardBg.setStroke(Math.max(1, a.dp(1)), 0x22ffffff);
            card.setBackground(cardBg);
            int qrSize = a.dp(104);
            ImageView qr = new ImageView(a);
            qr.setTag("search-inline-qr");
            qr.setContentDescription("手机扫码输入二维码");
            qr.setImageBitmap(createQrBitmap(address, qrSize));
            qr.setPadding(a.dp(5), a.dp(5), a.dp(5), a.dp(5));
            qr.setBackground(a.bg(Color.WHITE, 9));
            card.addView(qr, new LinearLayout.LayoutParams(qrSize + a.dp(10), qrSize + a.dp(10)));
            LinearLayout info = a.vertical();
            info.setPadding(a.dp(16), 0, 0, 0);
            TextView title = a.text("手机扫码打字输入", 16, MainActivity.WHITE);
            title.setTypeface(null, Typeface.BOLD);
            info.addView(title);
            TextView desc =
                    a.text("手机与电视连接同一 Wi-Fi / 局域网，扫码即可在手机上输入片名并直接在电视搜索。", 13, MainActivity.MUTED);
            desc.setLineSpacing(a.dp(3), 1f);
            desc.setPadding(0, a.dp(4), 0, a.dp(6));
            info.addView(desc);
            TextView addrView = a.text(address, 11.5f, 0xff7cb8ff);
            addrView.setSingleLine(true);
            addrView.setEllipsize(android.text.TextUtils.TruncateAt.MIDDLE);
            info.addView(addrView);
            card.addView(info, new LinearLayout.LayoutParams(0, -2, 1));
            LinearLayout.LayoutParams cardLp = new LinearLayout.LayoutParams(-1, -2);
            cardLp.bottomMargin = a.dp(16);
            resultBody.addView(card, cardLp);
        } catch (Exception ignored) {
        }
        resultBody.addView(a.text("最近搜索", 17, MainActivity.WHITE));
        List<String> history = history();
        if (history.isEmpty()) {
            TextView hint =
                    a.text(
                            "支持中文、首拼和全拼，例如 st / santi。\n也可以输入字母、数字、选择拼音候选字，或使用手机扫码直接打字。",
                            15,
                            MainActivity.MUTED);
            hint.setLineSpacing(a.dp(6), 1);
            hint.setPadding(0, a.dp(18), 0, 0);
            resultBody.addView(hint);
            return;
        }
        for (String value : history) {
            Button recent =
                    a.navButton(
                            value,
                            "search-history:" + value,
                            () -> {
                                if (!current()) return;
                                imeDraft.clear();
                                keyboard.set(value);
                                changed();
                                submit();
                            });
            a.addButton(resultBody, recent);
        }
        Button clear =
                a.navButton(
                        "清除搜索记录",
                        "search-clear-history",
                        () -> {
                            if (!current()) return;
                            a.prefs.edit().remove(Prefs.GLOBAL_SEARCH_HISTORY).apply();
                            showHistory();
                        });
        a.addButton(resultBody, clear);
    }

    List<String> history() {
        List<String> out = new ArrayList<>();
        if (!current() || a.privateMode) return out;
        try {
            JSONArray list = new JSONArray(a.prefs.getString(Prefs.GLOBAL_SEARCH_HISTORY, "[]"));
            for (int i = 0; i < Math.min(8, list.length()); i++) {
                String text = list.optString(i);
                if (!text.isEmpty()) out.add(text);
            }
        } catch (Exception ignored) {
        }
        return out;
    }

    void saveHistory(String query) {
        if (!current() || a.privateMode) return;
        List<String> previous = history();
        previous.remove(query);
        previous.add(0, query);
        JSONArray list = new JSONArray();
        for (int i = 0; i < Math.min(8, previous.size()); i++) list.put(previous.get(i));
        a.prefs.edit().putString(Prefs.GLOBAL_SEARCH_HISTORY, list.toString()).apply();
    }

    private View buildTvQrIconButton() {
        final View iconBtn =
                new View(a) {
                    private final Paint strokePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
                    private final Paint fillPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
                    private final RectF box = new RectF();

                    @Override
                    protected void onDraw(Canvas canvas) {
                        super.onDraw(canvas);
                        int w = getWidth();
                        int h = getHeight();
                        if (w <= 0 || h <= 0) return;
                        int tint = hasFocus() ? 0xff0b0e14 : 0xf2f5f5f7;
                        float s = Math.min(w, h) * 0.56f;
                        float ox = (w - s) * 0.5f;
                        float oy = (h - s) * 0.5f;
                        float unit = s / 7f;
                        float sw = Math.max(1.5f, unit * 0.62f);
                        float cr = unit * 0.35f;

                        strokePaint.setStyle(Paint.Style.STROKE);
                        strokePaint.setStrokeWidth(sw);
                        strokePaint.setColor(tint);
                        fillPaint.setStyle(Paint.Style.FILL);
                        fillPaint.setColor(tint);

                        // Top-left finder
                        drawFinder(canvas, ox, oy, unit * 3f, cr);
                        // Top-right finder
                        drawFinder(canvas, ox + unit * 4f, oy, unit * 3f, cr);
                        // Bottom-left finder
                        drawFinder(canvas, ox, oy + unit * 4f, unit * 3f, cr);

                        // Bottom-right QR data modules
                        drawDot(canvas, ox + unit * 4.0f, oy + unit * 4.0f, unit * 1.1f);
                        drawDot(canvas, ox + unit * 5.9f, oy + unit * 4.0f, unit * 1.1f);
                        drawDot(canvas, ox + unit * 4.95f, oy + unit * 4.95f, unit * 1.1f);
                        drawDot(canvas, ox + unit * 4.0f, oy + unit * 5.9f, unit * 1.1f);
                        drawDot(canvas, ox + unit * 5.9f, oy + unit * 5.9f, unit * 1.1f);
                    }

                    private void drawFinder(
                            Canvas canvas, float x, float y, float size, float radius) {
                        float inset = strokePaint.getStrokeWidth() * 0.5f;
                        box.set(x + inset, y + inset, x + size - inset, y + size - inset);
                        canvas.drawRoundRect(box, radius, radius, strokePaint);
                        float pip = size * 0.34f;
                        float px = x + (size - pip) * 0.5f;
                        float py = y + (size - pip) * 0.5f;
                        box.set(px, py, px + pip, py + pip);
                        canvas.drawRoundRect(box, radius * 0.5f, radius * 0.5f, fillPaint);
                    }

                    private void drawDot(Canvas canvas, float x, float y, float size) {
                        box.set(x, y, x + size, y + size);
                        canvas.drawRoundRect(box, size * 0.25f, size * 0.25f, fillPaint);
                    }
                };
        iconBtn.setTag("search-qr-button");
        iconBtn.setContentDescription("手机扫码输入");
        iconBtn.setFocusable(true);
        iconBtn.setFocusableInTouchMode(true);
        iconBtn.setClickable(true);
        UiCompat.setDefaultFocusHighlightEnabled(iconBtn, false);
        iconBtn.setBackground(TvV17Surface.rounded(0x26ffffff, a.dp(10), 0x34ffffff, a.dp(1)));
        a.pressFeedback(iconBtn);
        iconBtn.setOnClickListener(
                v -> {
                    try {
                        String address = ensureQrServer(false);
                        TvQrInputHelper.showSearchBubble(a, v, address);
                    } catch (Exception error) {
                        a.toast("未检测到局域网连接，请确认电视已连接 Wi-Fi 或有线网络");
                    }
                });
        iconBtn.setOnFocusChangeListener(
                (v, focused) -> {
                    FocusMotion.unclipAncestors(iconBtn);
                    iconBtn.setBackground(
                            TvV17Surface.rounded(
                                    focused ? 0xffffffff : 0x26ffffff,
                                    a.dp(10),
                                    focused ? 0xffffffff : 0x34ffffff,
                                    a.dp(1)));
                    UiCompat.setElevation(iconBtn, focused ? a.dp(6) : 0);
                    iconBtn.animate()
                            .scaleX(focused ? 1.07f : 1f)
                            .scaleY(focused ? 1.07f : 1f)
                            .setDuration(a.reduced ? 0 : 120)
                            .start();
                    iconBtn.invalidate();
                });
        return iconBtn;
    }

    @Override
    public void close() {
        cancelSuggestions();
        if (imeActive && keyboard != null && contextMatches()) {
            readImeDraft();
            imeDraft.close(keyboard);
        }
        imeActive = false;
        if (pendingImeRead != null) {
            a.ui.removeCallbacks(pendingImeRead);
            pendingImeRead = null;
        }
        closed = true;
        if (qrDialog != null && qrDialog.isShowing()) {
            qrDialog.dismiss();
        }
        qrDialog = null;
        TvQrInputHelper.dismissActive();
        closeQrServer();
        rememberSourcePosition();
        if (resultScroll != null) savedResultScroll = resultScroll.getScrollY();
        if (pendingInputClick != null) {
            a.ui.removeCallbacks(pendingInputClick);
            pendingInputClick = null;
        }
        hideSystemIme();
        if (pendingSearch != null) {
            a.ui.removeCallbacks(pendingSearch);
            pendingSearch = null;
        }
        clearCards();
        searchSerial++;
        cancelWork();
        // Requests cancelled while opening another page remain retryable on return.
        if (contextMatches()
                && !submitted.isEmpty()
                && resultConfig == a.config
                && resultPrivateMode == a.privateMode) {
            for (Cms.Site site : searchSites)
                if (!results.containsKey(site.key)) {
                    results.put(
                            site.key,
                            new SourceResult(
                                    site, Collections.emptyList(), SearchCoordinator.Outcome.BUSY));
                    finished++;
                    busy++;
                }
        }
        cacheResults();
    }
}
