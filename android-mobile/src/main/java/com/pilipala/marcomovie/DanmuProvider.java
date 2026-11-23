// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import java.util.regex.Pattern;
import java.util.regex.PatternSyntaxException;

/**
 * Clean-room segmented danmu provider contract shared across Android runtime and pure-JVM offline
 * checks. Contains zero Android framework dependencies and zero hardcoded server addresses or keys.
 */
public interface DanmuProvider {

    final class CancellationToken {
        private final AtomicBoolean cancelled = new AtomicBoolean(false);
        private final List<Runnable> hooks = new ArrayList<>();

        public boolean isCancelled() {
            return cancelled.get();
        }

        public void cancel() {
            if (!cancelled.compareAndSet(false, true)) return;
            List<Runnable> snapshot;
            synchronized (hooks) {
                snapshot = new ArrayList<>(hooks);
                hooks.clear();
            }
            for (Runnable hook : snapshot) {
                try {
                    hook.run();
                } catch (Throwable ignored) {
                }
            }
        }

        public void onCancel(Runnable hook) {
            if (hook == null) return;
            boolean runNow = false;
            synchronized (hooks) {
                if (cancelled.get()) {
                    runNow = true;
                } else {
                    hooks.add(hook);
                }
            }
            if (runNow) {
                try {
                    hook.run();
                } catch (Throwable ignored) {
                }
            }
        }

        public void removeCancelHook(Runnable hook) {
            if (hook == null) return;
            synchronized (hooks) {
                hooks.remove(hook);
            }
        }

        public void throwIfCancelled() throws IOException {
            if (cancelled.get()) {
                throw new CancelledException("Danmu request cancelled");
            }
        }
    }

    final class CancelledException extends IOException {
        public CancelledException(String message) {
            super(message);
        }
    }

    final class HttpStatusException extends IOException {
        public final int statusCode;
        public final long retryAfterMs;

        public HttpStatusException(int statusCode, String message) {
            this(statusCode, message, 0L);
        }

        public HttpStatusException(int statusCode, String message, long retryAfterMs) {
            super(message);
            this.statusCode = statusCode;
            this.retryAfterMs = Math.max(0L, retryAfterMs);
        }
    }

    final class MatchQuery {
        public final String title;
        public final String episodeTitle;
        public final int episodeIndex;
        public final long durationSec;

        public MatchQuery(String title, String episodeTitle, int episodeIndex, long durationSec) {
            this.title = title == null ? "" : title;
            this.episodeTitle = episodeTitle == null ? "" : episodeTitle;
            this.episodeIndex = episodeIndex;
            this.durationSec = Math.max(0L, durationSec);
        }
    }

    final class Candidate {
        public final String sourceOrigin;
        public final String animeId;
        public final String animeTitle;
        public final String boundEpisodeId; // mmdanmu://v1?src=...&ep=...
        public final String episodeTitle;
        public final double confidence;

        public Candidate(
                String sourceOrigin,
                String animeId,
                String animeTitle,
                String boundEpisodeId,
                String episodeTitle,
                double confidence) {
            this.sourceOrigin = sourceOrigin == null ? "" : sourceOrigin;
            this.animeId = animeId == null ? "" : animeId;
            this.animeTitle = animeTitle == null ? "" : animeTitle;
            this.boundEpisodeId = boundEpisodeId == null ? "" : boundEpisodeId;
            this.episodeTitle = episodeTitle == null ? "" : episodeTitle;
            this.confidence = confidence;
        }
    }

    final class SegmentDescriptor {
        public final long startMs;
        public final long endMs;
        public final String segmentUrl;

        public SegmentDescriptor(long startMs, long endMs, String segmentUrl) {
            this.startMs = startMs;
            this.endMs = endMs;
            this.segmentUrl = segmentUrl == null ? "" : segmentUrl;
        }
    }

    final class EpisodeSession {
        public final String boundEpisodeId;
        public final boolean segmented;
        public final List<SegmentDescriptor> segments; // empty when FULL_EPISODE
        public final List<DanmuItem> preloadComments; // populated when FULL_EPISODE

        public EpisodeSession(
                String boundEpisodeId,
                boolean segmented,
                List<SegmentDescriptor> segments,
                List<DanmuItem> preloadComments) {
            this.boundEpisodeId = boundEpisodeId == null ? "" : boundEpisodeId;
            this.segmented = segmented;
            this.segments =
                    segments == null
                            ? Collections.<SegmentDescriptor>emptyList()
                            : Collections.unmodifiableList(new ArrayList<>(segments));
            this.preloadComments =
                    preloadComments == null
                            ? Collections.<DanmuItem>emptyList()
                            : Collections.unmodifiableList(new ArrayList<>(preloadComments));
        }
    }

    final class DanmuItem {
        public final String id;
        public final long timeMs;
        public final int mode; // 1=scroll, 4=bottom, 5=top
        public final int rgbColor;
        public final String text;

        public DanmuItem(String id, long timeMs, int mode, int rgbColor, String text) {
            this.id = id == null ? "" : id;
            this.timeMs = timeMs;
            this.mode = mode;
            this.rgbColor = rgbColor & 0xFFFFFF;
            this.text = text == null ? "" : text;
        }
    }

    /**
     * O(N) user block filter with strict whitelist recursive-descent static ReDoS rejection for
     * {@code re:} rules. Keeps validation semantics 100% identical to Dart {@code DanmuBlockFilter}.
     */
    final class BlockFilter {
        public static final int MAX_RULES = 100;
        public static final int MAX_REGEX_LENGTH = 120;
        public static final int MAX_WILDCARDS = 3;
        public static final int MAX_GROUP_DEPTH = 6;
        public static final int MAX_QUANTIFIER_BOUND = 20;
        public static final int MAX_UNBOUNDED_PER_BRANCH = 1;
        public static final int MAX_DET_UNBOUNDED_PER_BRANCH = 1;
        public static final int MAX_TOTAL_UNBOUNDED = 2;
        public static final int MAX_VAR_QUANTS_PER_BRANCH = 2;
        public static final int MAX_ALT_GROUPS_PER_BRANCH = 2;
        public static final int MAX_BRANCH_EXPANDED_LEN = 28;
        public static final int MAX_POST_UNBOUNDED_LITERALS = 10;
        public static final int MAX_POST_UNBOUNDED_SAME_CHAR = 4;
        public static final int MAX_POST_UNBOUNDED_NON_LITERAL = 2;
        public static final int MAX_BOUNDED_BRANCH_CHOICES = 16;
        public static final int MAX_BRANCH_CHOICES = 550;
        public static final int MAX_TOTAL_CHOICES = 600;
        public static final int MAX_BOUNDED_BRANCH_WORK = 100;
        public static final int MAX_TOTAL_BOUNDED_WORK = 160;
        public static final int MAX_BRANCH_WORK = 620;
        public static final int MAX_TOTAL_WORK = 900;
        private static final int UNBOUNDED_CHOICE_COST = 181;
        private static final int WORK_CAP = MAX_TOTAL_WORK + 1;
        public static final BlockFilter EMPTY = new BlockFilter(new String[0], new Pattern[0]);

        public static final class ValidationResult {
            public final boolean valid;
            public final String error;

            public ValidationResult(boolean valid, String error) {
                this.valid = valid;
                this.error = error == null ? "" : error;
            }

            public static ValidationResult ok() {
                return new ValidationResult(true, "");
            }

            public static ValidationResult fail(String reason) {
                return new ValidationResult(false, reason);
            }
        }

        private static final class BranchStats {
            final int unboundedQuants;
            final int detUnboundedQuants;
            final int totalUnboundedQuants;
            final int varQuants;
            final int altGroups;
            final int choices;
            final int maxExpandedLen;
            final int work;

            BranchStats(
                    int unboundedQuants,
                    int detUnboundedQuants,
                    int totalUnboundedQuants,
                    int varQuants,
                    int altGroups,
                    int choices,
                    int maxExpandedLen,
                    int work) {
                this.unboundedQuants = unboundedQuants;
                this.detUnboundedQuants = detUnboundedQuants;
                this.totalUnboundedQuants = totalUnboundedQuants;
                this.varQuants = varQuants;
                this.altGroups = altGroups;
                this.choices = choices;
                this.maxExpandedLen = maxExpandedLen;
                this.work = work;
            }
        }

        private static final class QuantStats {
            static final QuantStats NONE = new QuantStats(0, 0, 1, 1, false);
            final int unbounded;
            final int varQuant;
            final int choices;
            final int maxLen;
            final boolean lazy;

            QuantStats(int unbounded, int varQuant, int choices, int maxLen, boolean lazy) {
                this.unbounded = unbounded;
                this.varQuant = varQuant;
                this.choices = choices;
                this.maxLen = maxLen;
                this.lazy = lazy;
            }
        }

        private static final class AtomInfo {
            static final int KIND_OTHER = 0;
            static final int KIND_LITERAL = 1;
            static final int KIND_DIGIT = 2;
            static final int KIND_SPACE = 3;
            static final int KIND_WORD = 4;
            static final int KIND_ASCII_CLASS = 5;

            static final AtomInfo OTHER = new AtomInfo(KIND_OTHER, -1, null, false);
            static final AtomInfo DOT = new AtomInfo(KIND_OTHER, -1, null, true);
            static final AtomInfo DIGIT = new AtomInfo(KIND_DIGIT, -1, null, false);
            static final AtomInfo SPACE = new AtomInfo(KIND_SPACE, -1, null, false);
            static final AtomInfo WORD = new AtomInfo(KIND_WORD, -1, null, false);

            final int kind;
            final int literalCode;
            final int[] asciiMask; // 4 x 32-bit ints for 0..127
            final boolean isDot;

            AtomInfo(int kind, int literalCode, int[] asciiMask, boolean isDot) {
                this.kind = kind;
                this.literalCode = literalCode;
                this.asciiMask = asciiMask;
                this.isDot = isDot;
            }

            static AtomInfo literal(int code) {
                return new AtomInfo(KIND_LITERAL, code, null, false);
            }

            static AtomInfo asciiClass(int[] mask) {
                return new AtomInfo(KIND_ASCII_CLASS, -1, mask, false);
            }

            boolean isDisjointFromLiteral(int sepCode) {
                switch (kind) {
                    case KIND_LITERAL:
                        if (literalCode >= 128
                                && sepCode >= 128
                                && !isCaselessCjk(literalCode)
                                && !isCaselessCjk(sepCode)) {
                            return false;
                        }
                        return foldAsciiLower(literalCode) != foldAsciiLower(sepCode);
                    case KIND_DIGIT:
                        return sepCode < '0' || sepCode > '9';
                    case KIND_SPACE:
                        return !isRegexWhitespace(sepCode);
                    case KIND_WORD:
                        return !((sepCode >= '0' && sepCode <= '9')
                                || (sepCode >= 'A' && sepCode <= 'Z')
                                || (sepCode >= 'a' && sepCode <= 'z')
                                || sepCode == '_');
                    case KIND_ASCII_CLASS:
                        if (sepCode < 0 || sepCode >= 128) return true;
                        int folded = foldAsciiLower(sepCode);
                        boolean matchRaw = (asciiMask[sepCode >>> 5] & (1 << (sepCode & 31))) != 0;
                        boolean matchFold = (asciiMask[folded >>> 5] & (1 << (folded & 31))) != 0;
                        return !matchRaw && !matchFold;
                    default:
                        return false;
                }
            }

            static boolean isCaselessCjk(int ch) {
                return (ch >= 0x4E00 && ch <= 0x9FFF)
                        || (ch >= 0x3400 && ch <= 0x4DBF)
                        || (ch >= 0x3040 && ch <= 0x30FF);
            }

            private static int foldAsciiLower(int ch) {
                return (ch >= 'A' && ch <= 'Z') ? (ch + 32) : ch;
            }

            private static boolean isRegexWhitespace(int ch) {
                return ch == ' '
                        || ch == '\t'
                        || ch == '\n'
                        || ch == '\r'
                        || ch == '\f'
                        || ch == 0x0B
                        || ch == 0x00A0
                        || ch == 0x1680
                        || (ch >= 0x2000 && ch <= 0x200A)
                        || ch == 0x2028
                        || ch == 0x2029
                        || ch == 0x202F
                        || ch == 0x205F
                        || ch == 0x3000
                        || ch == 0xFEFF;
            }
        }

        private static final class SafeRegexValidator {
            private final String expr;
            private final int len;
            private int pos;
            private int wildcardCount;
            private int groupDepth;
            private String error;

            SafeRegexValidator(String expr) {
                this.expr = expr;
                this.len = expr.length();
            }

            ValidationResult validate() {
                for (int i = 0; i < len; i++) {
                    if (isSurrogateCodeUnit(expr.charAt(i))) {
                        return ValidationResult.fail("正则表达式不支持代理项或扩展平面字符");
                    }
                }
                BranchStats root = parseAlternation(true);
                if (error != null) {
                    return ValidationResult.fail(error);
                }
                if (pos != len) {
                    return ValidationResult.fail("正则表达式包含多余的闭合括号");
                }
                if (root == null || root.choices > MAX_TOTAL_CHOICES) {
                    return ValidationResult.fail("正则表达式总回溯分支复杂度过高");
                }
                if (root.totalUnboundedQuants > MAX_TOTAL_UNBOUNDED) {
                    return ValidationResult.fail("正则表达式无界量词总数超过安全上限");
                }
                if (root.work > MAX_TOTAL_WORK) {
                    return ValidationResult.fail("正则表达式总回溯工作量超过安全上限");
                }
                return ValidationResult.ok();
            }

            private void fail(String reason) {
                if (error == null) {
                    error = reason;
                }
            }

            private static boolean isSurrogateCodeUnit(int codeUnit) {
                return codeUnit >= 0xD800 && codeUnit <= 0xDFFF;
            }

            private static int satAdd(int a, int b) {
                long s = (long) a + (long) b;
                return s >= WORK_CAP ? WORK_CAP : (int) s;
            }

            private static int satMul(int a, int b) {
                long p = (long) a * (long) b;
                return p >= WORK_CAP ? WORK_CAP : (int) p;
            }

            private static boolean isQuantStart(char ch) {
                return ch == '*' || ch == '+' || ch == '?' || ch == '{';
            }

            private static boolean isHexDigit(char ch) {
                return (ch >= '0' && ch <= '9')
                        || (ch >= 'a' && ch <= 'f')
                        || (ch >= 'A' && ch <= 'F');
            }

            private static boolean isAsciiPunctuation(char ch) {
                if (ch < 0x21 || ch > 0x7E) return false;
                if (ch >= '0' && ch <= '9') return false;
                if (ch >= 'a' && ch <= 'z') return false;
                if (ch >= 'A' && ch <= 'Z') return false;
                return ch != '_';
            }

            private static int foldAsciiLower(int ch) {
                return (ch >= 'A' && ch <= 'Z') ? (ch + 32) : ch;
            }

            private int peekUnquantifiedLiteralCode() {
                if (pos >= len) return -1;
                char c = expr.charAt(pos);
                if (c == '|' || c == ')' || c == '(' || c == '[' || c == ']' || c == '{' || c == '}'
                        || c == '*' || c == '+' || c == '?' || c == '^' || c == '$' || c == '.') {
                    return -1;
                }
                int code;
                int afterPos;
                if (c == '\\') {
                    if (pos + 1 >= len) return -1;
                    char next = expr.charAt(pos + 1);
                    if (next == 't') {
                        code = '\t';
                        afterPos = pos + 2;
                    } else if (next == 'n') {
                        code = '\n';
                        afterPos = pos + 2;
                    } else if (next == 'r') {
                        code = '\r';
                        afterPos = pos + 2;
                    } else if (next == 'f') {
                        code = '\f';
                        afterPos = pos + 2;
                    } else if (isAsciiPunctuation(next)) {
                        code = next;
                        afterPos = pos + 2;
                    } else {
                        return -1;
                    }
                } else {
                    code = c;
                    afterPos = pos + 1;
                }
                if (afterPos < len && isQuantStart(expr.charAt(afterPos))) {
                    return -1;
                }
                return code;
            }

            private BranchStats parseAlternation(boolean isTopLevel) {
                BranchStats first = parseBranch();
                if (error != null) return null;
                int maxUnbounded = first.unboundedQuants;
                int maxDetUnbounded = first.detUnboundedQuants;
                int sumTotalUnbounded = first.totalUnboundedQuants;
                int maxVar = first.varQuants;
                int maxAltGroups = first.altGroups;
                int sumChoices = first.choices;
                int maxExpandedLen = first.maxExpandedLen;
                int sumWork = first.work;
                int sumBoundedWork =
                        (first.totalUnboundedQuants == 0 && first.choices > 1) ? first.work : 0;
                int branchCount = 1;
                if (isTopLevel) {
                    if (!checkTopLevelTotals(
                            sumChoices, sumTotalUnbounded, sumBoundedWork, sumWork)) {
                        return null;
                    }
                }
                while (pos < len && expr.charAt(pos) == '|') {
                    pos++;
                    BranchStats next = parseBranch();
                    if (error != null) return null;
                    branchCount++;
                    if (next.unboundedQuants > maxUnbounded) {
                        maxUnbounded = next.unboundedQuants;
                    }
                    if (next.detUnboundedQuants > maxDetUnbounded) {
                        maxDetUnbounded = next.detUnboundedQuants;
                    }
                    sumTotalUnbounded = satAdd(sumTotalUnbounded, next.totalUnboundedQuants);
                    if (next.varQuants > maxVar) {
                        maxVar = next.varQuants;
                    }
                    if (next.altGroups > maxAltGroups) {
                        maxAltGroups = next.altGroups;
                    }
                    if (next.maxExpandedLen > maxExpandedLen) {
                        maxExpandedLen = next.maxExpandedLen;
                    }
                    sumChoices = satAdd(sumChoices, next.choices);
                    sumWork = satAdd(sumWork, next.work);
                    if (next.totalUnboundedQuants == 0 && next.choices > 1) {
                        sumBoundedWork = satAdd(sumBoundedWork, next.work);
                    }
                    if (isTopLevel) {
                        if (!checkTopLevelTotals(
                                sumChoices, sumTotalUnbounded, sumBoundedWork, sumWork)) {
                            return null;
                        }
                    }
                }
                int reportedAltGroups =
                        (!isTopLevel && branchCount > 1) ? maxAltGroups + 1 : maxAltGroups;
                return new BranchStats(
                        maxUnbounded,
                        maxDetUnbounded,
                        sumTotalUnbounded,
                        maxVar,
                        reportedAltGroups,
                        sumChoices,
                        maxExpandedLen,
                        sumWork);
            }

            private boolean checkTopLevelTotals(
                    int sumChoices, int sumTotalUnbounded, int sumBoundedWork, int sumWork) {
                if (sumChoices > MAX_TOTAL_CHOICES) {
                    fail("正则表达式总回溯分支复杂度过高");
                    return false;
                }
                if (sumTotalUnbounded > MAX_TOTAL_UNBOUNDED) {
                    fail("正则表达式无界量词总数超过安全上限");
                    return false;
                }
                if (sumBoundedWork > MAX_TOTAL_BOUNDED_WORK) {
                    fail("正则表达式总回溯工作量超过安全上限");
                    return false;
                }
                if (sumWork > MAX_TOTAL_WORK) {
                    fail("正则表达式总回溯工作量超过安全上限");
                    return false;
                }
                return true;
            }

            private BranchStats parseBranch() {
                int unbounded = 0;
                int detUnbounded = 0;
                int totalUnbounded = 0;
                int varQuants = 0;
                int altGroups = 0;
                int choices = 1;
                int maxExpandedLen = 0;
                int work = 0;
                int atomCount = 0;
                int postUnboundedLiterals = 0;
                int postUnboundedNonLiteral = 0;
                int[] postUnboundedLitCodes = new int[MAX_POST_UNBOUNDED_LITERALS];
                int postUnboundedLitCount = 0;

                while (pos < len) {
                    char ch = expr.charAt(pos);
                    if (ch == '|' || ch == ')') {
                        break;
                    }
                    atomCount++;

                    if (ch == '(') {
                        pos++;
                        if (pos < len && expr.charAt(pos) == '?') {
                            if (pos + 1 < len && expr.charAt(pos + 1) == ':') {
                                pos += 2;
                            } else if (pos + 1 < len) {
                                char m = expr.charAt(pos + 1);
                                if (m == '<') {
                                    fail("禁止使用正则后行断言");
                                } else if (m == '-'
                                        || (m >= 'a' && m <= 'z')
                                        || (m >= 'A' && m <= 'Z')) {
                                    fail("禁止使用正则内联修饰符");
                                } else if (m == '=' || m == '!') {
                                    fail("禁止使用正则环视断言");
                                } else {
                                    fail("禁止使用不受支持的正则扩展分组");
                                }
                                return null;
                            } else {
                                fail("正则表达式语法错误: 未闭合分组");
                                return null;
                            }
                        }
                        groupDepth++;
                        if (groupDepth > MAX_GROUP_DEPTH) {
                            fail("正则分组嵌套层数超过上限");
                            return null;
                        }
                        BranchStats inner = parseAlternation(false);
                        if (error != null) return null;
                        groupDepth--;
                        if (pos >= len || expr.charAt(pos) != ')') {
                            fail("正则表达式语法错误: 未闭合括号");
                            return null;
                        }
                        pos++;
                        if (pos < len && isQuantStart(expr.charAt(pos))) {
                            fail("禁止闭合括号后紧跟量词以防回溯风险");
                            return null;
                        }
                        if (unbounded > 0) {
                            postUnboundedNonLiteral =
                                    satAdd(postUnboundedNonLiteral, inner.maxExpandedLen);
                            if (postUnboundedNonLiteral > MAX_POST_UNBOUNDED_NON_LITERAL) {
                                fail("正则表达式无界量词后的非字面后缀超过安全上限");
                                return null;
                            }
                        }
                        work = satAdd(work, satMul(choices, inner.work));
                        unbounded += inner.unboundedQuants;
                        detUnbounded += inner.detUnboundedQuants;
                        totalUnbounded += inner.totalUnboundedQuants;
                        varQuants += inner.varQuants;
                        altGroups += inner.altGroups;
                        choices = satMul(choices, inner.choices);
                        maxExpandedLen = satAdd(maxExpandedLen, inner.maxExpandedLen);
                        if (!checkBranchBudget(
                                unbounded,
                                detUnbounded,
                                totalUnbounded,
                                varQuants,
                                altGroups,
                                choices,
                                maxExpandedLen,
                                work)) {
                            return null;
                        }
                        continue;
                    }

                    if (isQuantStart(ch)) {
                        fail("量词缺少前置匹配项");
                        return null;
                    }
                    if (ch == '}' || ch == ']') {
                        fail("正则表达式包含未转义的闭合符号");
                        return null;
                    }
                    if (ch == '^' || ch == '$') {
                        pos++;
                        if (pos < len && isQuantStart(expr.charAt(pos))) {
                            fail("禁止对零宽断言使用量词");
                            return null;
                        }
                        continue;
                    }

                    AtomInfo atom;
                    if (ch == '[') {
                        atom = parseCharClass();
                        if (error != null) return null;
                    } else if (ch == '\\') {
                        atom = parseOutsideEscape();
                        if (error != null) return null;
                        if (atom == null) {
                            if (pos < len && isQuantStart(expr.charAt(pos))) {
                                fail("禁止对零宽断言使用量词");
                                return null;
                            }
                            continue;
                        }
                    } else if (ch == '.') {
                        pos++;
                        atom = AtomInfo.DOT;
                    } else {
                        pos++;
                        atom = AtomInfo.literal(ch);
                    }

                    QuantStats q = parseQuantifier(atom.isDot);
                    if (error != null) return null;

                    boolean isUnquantifiedLiteral =
                            atom.kind == AtomInfo.KIND_LITERAL
                                    && q.unbounded == 0
                                    && q.varQuant == 0
                                    && q.maxLen == 1;

                    if (q.unbounded > 0) {
                        int nextLit = q.lazy ? -1 : peekUnquantifiedLiteralCode();
                        boolean deterministic = nextLit >= 0 && atom.isDisjointFromLiteral(nextLit);
                        work = satAdd(work, satMul(choices, UNBOUNDED_CHOICE_COST));
                        totalUnbounded += 1;
                        varQuants += 1;
                        maxExpandedLen = satAdd(maxExpandedLen, q.maxLen);
                        if (deterministic) {
                            detUnbounded += 1;
                        } else {
                            unbounded += 1;
                            choices = satMul(choices, q.choices);
                        }
                    } else if (q.varQuant > 0) {
                        if (unbounded > 0) {
                            postUnboundedNonLiteral = satAdd(postUnboundedNonLiteral, q.maxLen);
                            if (postUnboundedNonLiteral > MAX_POST_UNBOUNDED_NON_LITERAL) {
                                fail("正则表达式无界量词后的非字面后缀超过安全上限");
                                return null;
                            }
                        }
                        work = satAdd(work, satMul(choices, satMul(q.choices, q.maxLen)));
                        varQuants += 1;
                        choices = satMul(choices, q.choices);
                        maxExpandedLen = satAdd(maxExpandedLen, q.maxLen);
                    } else if (unbounded > 0 && isUnquantifiedLiteral) {
                        postUnboundedLiterals++;
                        if (postUnboundedLiterals > MAX_POST_UNBOUNDED_LITERALS) {
                            fail("正则表达式无界量词后的字面后缀超过安全上限");
                            return null;
                        }
                        int folded =
                                (atom.literalCode >= 128
                                                && !AtomInfo.isCaselessCjk(atom.literalCode))
                                        ? 0xFFFD
                                        : foldAsciiLower(atom.literalCode);
                        int sameCount = 1;
                        for (int k = 0; k < postUnboundedLitCount; k++) {
                            if (postUnboundedLitCodes[k] == folded) {
                                sameCount++;
                            }
                        }
                        if (sameCount > MAX_POST_UNBOUNDED_SAME_CHAR) {
                            fail("正则表达式无界量词后的重复字符后缀超过安全上限");
                            return null;
                        }
                        postUnboundedLitCodes[postUnboundedLitCount++] = folded;
                        int litCost = (choices + 3) / 4;
                        work = satAdd(work, litCost);
                        maxExpandedLen = satAdd(maxExpandedLen, 1);
                    } else {
                        if (unbounded > 0) {
                            postUnboundedNonLiteral = satAdd(postUnboundedNonLiteral, q.maxLen);
                            if (postUnboundedNonLiteral > MAX_POST_UNBOUNDED_NON_LITERAL) {
                                fail("正则表达式无界量词后的非字面后缀超过安全上限");
                                return null;
                            }
                        }
                        work = satAdd(work, satMul(choices, q.maxLen));
                        maxExpandedLen = satAdd(maxExpandedLen, q.maxLen);
                    }

                    if (!checkBranchBudget(
                            unbounded,
                            detUnbounded,
                            totalUnbounded,
                            varQuants,
                            altGroups,
                            choices,
                            maxExpandedLen,
                            work)) {
                        return null;
                    }
                }

                if (atomCount == 0) {
                    fail("正则表达式禁止空分支或空分组");
                    return null;
                }
                return new BranchStats(
                        unbounded,
                        detUnbounded,
                        totalUnbounded,
                        varQuants,
                        altGroups,
                        choices,
                        maxExpandedLen,
                        work);
            }

            private boolean checkBranchBudget(
                    int unbounded,
                    int detUnbounded,
                    int totalUnbounded,
                    int varQuants,
                    int altGroups,
                    int choices,
                    int maxExpandedLen,
                    int work) {
                if (unbounded > MAX_UNBOUNDED_PER_BRANCH) {
                    fail("禁止同分支内组合多个无界量词以防回溯风险");
                    return false;
                }
                if (detUnbounded > MAX_DET_UNBOUNDED_PER_BRANCH) {
                    fail("禁止同分支内组合多个无界量词以防回溯风险");
                    return false;
                }
                if (totalUnbounded > MAX_TOTAL_UNBOUNDED) {
                    fail("正则表达式无界量词总数超过安全上限");
                    return false;
                }
                if (varQuants > MAX_VAR_QUANTS_PER_BRANCH) {
                    fail("禁止同分支内组合过多可变长量词以防回溯风险");
                    return false;
                }
                if (altGroups > MAX_ALT_GROUPS_PER_BRANCH) {
                    fail("禁止同分支内串联过多交替分组以防回溯风险");
                    return false;
                }
                int lenLimit =
                        (varQuants > 0 || altGroups > 0)
                                ? MAX_BRANCH_EXPANDED_LEN
                                : MAX_REGEX_LENGTH;
                if (maxExpandedLen > lenLimit) {
                    fail("正则表达式分支展开长度超过安全上限");
                    return false;
                }
                int choiceLimit = unbounded == 0 ? MAX_BOUNDED_BRANCH_CHOICES : MAX_BRANCH_CHOICES;
                if (choices > choiceLimit) {
                    fail("正则表达式回溯复杂度过高");
                    return false;
                }
                int workLimit =
                        totalUnbounded > 0
                                ? MAX_BRANCH_WORK
                                : (choices == 1 ? MAX_REGEX_LENGTH : MAX_BOUNDED_BRANCH_WORK);
                if (work > workLimit) {
                    fail("正则表达式回溯工作量超过安全上限");
                    return false;
                }
                return true;
            }

            private QuantStats parseQuantifier(boolean isDot) {
                if (pos >= len) return QuantStats.NONE;
                char q = expr.charAt(pos);
                if (q == '*' || q == '+') {
                    pos++;
                    if (isDot) {
                        wildcardCount++;
                        if (wildcardCount > MAX_WILDCARDS) {
                            fail("通配符 .* / .+ 超过 3 次上限");
                            return null;
                        }
                    }
                    boolean lazy = false;
                    if (pos < len && expr.charAt(pos) == '?') {
                        pos++;
                        lazy = true;
                    }
                    if (pos < len && isQuantStart(expr.charAt(pos))) {
                        fail("禁止堆叠或占有型量词");
                        return null;
                    }
                    return new QuantStats(1, 1, UNBOUNDED_CHOICE_COST, 1, lazy);
                }
                if (q == '?') {
                    pos++;
                    if (pos < len && isQuantStart(expr.charAt(pos))) {
                        fail("禁止堆叠或占有型量词");
                        return null;
                    }
                    return new QuantStats(0, 1, 2, 1, false);
                }
                if (q == '{') {
                    pos++;
                    int minVal = parseBoundedInt();
                    if (error != null) return null;
                    if (pos >= len) {
                        fail("正则表达式量词花括号未闭合");
                        return null;
                    }
                    char sep = expr.charAt(pos);
                    if (sep == '}') {
                        pos++;
                        if (minVal == 0) {
                            fail("禁止使用零次量词");
                            return null;
                        }
                        if (pos < len && isQuantStart(expr.charAt(pos))) {
                            fail("禁止堆叠或占有型量词");
                            return null;
                        }
                        return new QuantStats(0, 0, 1, minVal, false);
                    }
                    if (sep == ',') {
                        pos++;
                        if (pos < len && expr.charAt(pos) == '}') {
                            pos++;
                            if (isDot) {
                                wildcardCount++;
                                if (wildcardCount > MAX_WILDCARDS) {
                                    fail("通配符 .* / .+ 超过 3 次上限");
                                    return null;
                                }
                            }
                            boolean lazy = false;
                            if (pos < len && expr.charAt(pos) == '?') {
                                pos++;
                                lazy = true;
                            }
                            if (pos < len && isQuantStart(expr.charAt(pos))) {
                                fail("禁止堆叠或占有型量词");
                                return null;
                            }
                            return new QuantStats(
                                    1, 1, UNBOUNDED_CHOICE_COST, Math.max(1, minVal), lazy);
                        }
                        int maxVal = parseBoundedInt();
                        if (error != null) return null;
                        if (pos >= len || expr.charAt(pos) != '}') {
                            fail("正则表达式量词花括号格式无效");
                            return null;
                        }
                        pos++;
                        if (maxVal < minVal) {
                            fail("正则表达式量词上限小于下限");
                            return null;
                        }
                        if (maxVal == 0) {
                            fail("禁止使用零次量词");
                            return null;
                        }
                        if (maxVal == minVal) {
                            if (pos < len && isQuantStart(expr.charAt(pos))) {
                                fail("禁止堆叠或占有型量词");
                                return null;
                            }
                            return new QuantStats(0, 0, 1, maxVal, false);
                        }
                        boolean lazy = false;
                        if (pos < len && expr.charAt(pos) == '?') {
                            pos++;
                            lazy = true;
                        }
                        if (pos < len && isQuantStart(expr.charAt(pos))) {
                            fail("禁止堆叠或占有型量词");
                            return null;
                        }
                        return new QuantStats(0, 1, maxVal - minVal + 1, maxVal, lazy);
                    }
                    fail("正则表达式量词花括号格式无效");
                    return null;
                }
                return QuantStats.NONE;
            }

            private int parseBoundedInt() {
                int start = pos;
                int val = 0;
                while (pos < len) {
                    char d = expr.charAt(pos);
                    if (d < '0' || d > '9') break;
                    val = val * 10 + (d - '0');
                    if (val > MAX_QUANTIFIER_BOUND) {
                        fail("正则表达式量词数值超过 20 上限");
                        return -1;
                    }
                    pos++;
                }
                if (pos == start) {
                    fail("正则表达式量词花括号缺少数字");
                    return -1;
                }
                return val;
            }

            private AtomInfo parseOutsideEscape() {
                pos++; // consume '\'
                if (pos >= len) {
                    fail("正则表达式以未闭合转义符结尾");
                    return null;
                }
                char next = expr.charAt(pos);
                if ((next >= '1' && next <= '9') || next == 'k') {
                    fail("禁止使用正则反向引用");
                    return null;
                }
                if (next == 'b' || next == 'B') {
                    pos++;
                    return null;
                }
                if (next == 'd') {
                    pos++;
                    return AtomInfo.DIGIT;
                }
                if (next == 's') {
                    pos++;
                    return AtomInfo.SPACE;
                }
                if (next == 'w') {
                    pos++;
                    return AtomInfo.WORD;
                }
                if (next == 'D' || next == 'W' || next == 'S') {
                    pos++;
                    return AtomInfo.OTHER;
                }
                if (next == 't') {
                    pos++;
                    return AtomInfo.literal('\t');
                }
                if (next == 'n') {
                    pos++;
                    return AtomInfo.literal('\n');
                }
                if (next == 'r') {
                    pos++;
                    return AtomInfo.literal('\r');
                }
                if (next == 'f') {
                    pos++;
                    return AtomInfo.literal('\f');
                }
                if (next == 'x') {
                    pos++;
                    int code = parseFixedHexEscape(2);
                    return error != null ? null : AtomInfo.literal(code);
                }
                if (next == 'u') {
                    pos++;
                    int code = parseFixedHexEscape(4);
                    return error != null ? null : AtomInfo.literal(code);
                }
                if (isAsciiPunctuation(next)) {
                    pos++;
                    return AtomInfo.literal(next);
                }
                fail("禁止使用不受支持的正则转义序列");
                return null;
            }

            private int parseFixedHexEscape(int digits) {
                if (pos + digits > len) {
                    fail("正则十六进制转义位数不足");
                    return -1;
                }
                int value = 0;
                for (int i = 0; i < digits; i++) {
                    char h = expr.charAt(pos + i);
                    if (!isHexDigit(h)) {
                        fail("正则十六进制转义格式无效");
                        return -1;
                    }
                    int nibble =
                            h <= '9' ? (h - '0') : (h <= 'F' ? (h - 'A' + 10) : (h - 'a' + 10));
                    value = (value << 4) | nibble;
                }
                pos += digits;
                if (digits == 4 && isSurrogateCodeUnit(value)) {
                    fail("正则表达式不支持代理项或扩展平面字符");
                    return -1;
                }
                return value;
            }

            private static void setAsciiMaskBit(int[] mask, int code) {
                if (code >= 0 && code < 128) {
                    mask[code >>> 5] |= (1 << (code & 31));
                    int folded = foldAsciiLower(code);
                    mask[folded >>> 5] |= (1 << (folded & 31));
                }
            }

            private AtomInfo parseCharClass() {
                pos++; // consume '['
                boolean negated = false;
                if (pos < len && expr.charAt(pos) == '^') {
                    pos++;
                    negated = true;
                }
                int itemCount = 0;
                boolean prevWasSingleChar = false;
                int prevCharCode = -1;
                boolean pendingRange = false;
                boolean trackAsciiMask = !negated;
                int[] asciiMask = trackAsciiMask ? new int[4] : null;

                while (pos < len && expr.charAt(pos) != ']') {
                    char c = expr.charAt(pos);
                    if (c == '[') {
                        fail("禁止在字符类中使用未转义的 [");
                        return null;
                    }
                    if (c == '&' && pos + 1 < len && expr.charAt(pos + 1) == '&') {
                        fail("禁止在字符类中使用交集语法");
                        return null;
                    }
                    if (c == '-'
                            && !pendingRange
                            && itemCount > 0
                            && pos + 1 < len
                            && expr.charAt(pos + 1) != ']') {
                        if (!prevWasSingleChar) {
                            fail("字符类范围不能以简写字符类作为起点");
                            return null;
                        }
                        pos++;
                        pendingRange = true;
                        continue;
                    }

                    boolean isSingleChar;
                    int charCode;
                    if (c == '\\') {
                        pos++;
                        if (pos >= len) {
                            fail("正则表达式以未闭合转义符结尾");
                            return null;
                        }
                        char next = expr.charAt(pos);
                        if (next == 'd'
                                || next == 'D'
                                || next == 'w'
                                || next == 'W'
                                || next == 's'
                                || next == 'S') {
                            pos++;
                            isSingleChar = false;
                            charCode = -1;
                            trackAsciiMask = false;
                        } else if (next == 't') {
                            pos++;
                            isSingleChar = true;
                            charCode = '\t';
                        } else if (next == 'n') {
                            pos++;
                            isSingleChar = true;
                            charCode = '\n';
                        } else if (next == 'r') {
                            pos++;
                            isSingleChar = true;
                            charCode = '\r';
                        } else if (next == 'f') {
                            pos++;
                            isSingleChar = true;
                            charCode = '\f';
                        } else if (next == 'x') {
                            pos++;
                            charCode = parseFixedHexEscape(2);
                            if (error != null) return null;
                            isSingleChar = true;
                        } else if (next == 'u') {
                            pos++;
                            charCode = parseFixedHexEscape(4);
                            if (error != null) return null;
                            isSingleChar = true;
                        } else if (isAsciiPunctuation(next)) {
                            pos++;
                            isSingleChar = true;
                            charCode = next;
                        } else {
                            fail("禁止在字符类中使用不受支持的转义序列");
                            return null;
                        }
                    } else {
                        pos++;
                        isSingleChar = true;
                        charCode = c;
                    }

                    if (pendingRange) {
                        if (!isSingleChar) {
                            fail("字符类范围不能以简写字符类作为终点");
                            return null;
                        }
                        if (charCode < prevCharCode) {
                            fail("字符类范围起点大于终点");
                            return null;
                        }
                        if (trackAsciiMask) {
                            if (prevCharCode >= 0 && charCode < 128) {
                                for (int k = prevCharCode; k <= charCode; k++) {
                                    setAsciiMaskBit(asciiMask, k);
                                }
                            } else {
                                trackAsciiMask = false;
                            }
                        }
                        pendingRange = false;
                        prevWasSingleChar = false;
                    } else {
                        if (trackAsciiMask && isSingleChar) {
                            if (charCode >= 0 && charCode < 128) {
                                setAsciiMaskBit(asciiMask, charCode);
                            } else {
                                trackAsciiMask = false;
                            }
                        }
                        prevWasSingleChar = isSingleChar;
                        prevCharCode = charCode;
                    }
                    itemCount++;
                }

                if (pos >= len || expr.charAt(pos) != ']') {
                    fail("字符类未闭合");
                    return null;
                }
                pos++; // consume ']'
                if (itemCount == 0) {
                    fail("字符类不能为空");
                    return null;
                }
                return trackAsciiMask ? AtomInfo.asciiClass(asciiMask) : AtomInfo.OTHER;
            }
        }

        private static final Object REGEX_WARMUP_LOCK = new Object();
        private static volatile boolean regexEngineWarmed = false;

        private final String[] plainLowerRules;
        private final Pattern[] regexRules;
        private final AtomicLong evaluationCount = new AtomicLong();

        private BlockFilter(String[] plainLowerRules, Pattern[] regexRules) {
            this.plainLowerRules = plainLowerRules;
            this.regexRules = regexRules;
        }

        private static String repeatChar180(char ch, char tail) {
            char[] buf = new char[180];
            Arrays.fill(buf, 0, 179, ch);
            buf[179] = tail;
            return new String(buf);
        }

        /**
         * Warms shared java.util.regex bytecode paths once per JVM so the first user-visible or
         * test regex evaluation avoids cold-interpreter latency spikes.
         */
        private static void warmRegexEngineIfNeeded() {
            if (regexEngineWarmed) return;
            synchronized (REGEX_WARMUP_LOCK) {
                if (regexEngineWarmed) return;
                String asciiSample = repeatChar180('a', '!');
                String cjkSample = repeatChar180('\u4e00', '!');
                String digitSample = repeatChar180('1', '!');
                Pattern[] warmupPatterns =
                        new Pattern[] {
                            Pattern.compile(
                                    "[^x]{20}[^x]+y|[^x]{20}[^x]+z", Pattern.CASE_INSENSITIVE),
                            Pattern.compile("[a-z]+z|[a-z]+z", Pattern.CASE_INSENSITIVE),
                            Pattern.compile("[a-z]+[a-z]{2}z", Pattern.CASE_INSENSITIVE),
                            Pattern.compile(".*剧透预警", Pattern.CASE_INSENSITIVE),
                            Pattern.compile("a.*b|c.*d", Pattern.CASE_INSENSITIVE),
                            Pattern.compile("[a-z]+\\.com", Pattern.CASE_INSENSITIVE),
                            Pattern.compile(
                                    "(a|aa)(a|aa)z|[a-z]{1,4}[0-9]{1,4}", Pattern.CASE_INSENSITIVE)
                        };
                for (Pattern p : warmupPatterns) {
                    for (int i = 0; i < 600; i++) {
                        p.matcher(asciiSample).find();
                        p.matcher(cjkSample).find();
                        p.matcher(digitSample).find();
                    }
                }
                regexEngineWarmed = true;
            }
        }

        private static boolean isRuleWhitespace(char ch) {
            return ch <= 0x20
                    || ch == 0x0085
                    || ch == 0x00A0
                    || ch == 0x1680
                    || (ch >= 0x2000 && ch <= 0x200A)
                    || ch == 0x2028
                    || ch == 0x2029
                    || ch == 0x202F
                    || ch == 0x205F
                    || ch == 0x3000
                    || ch == 0xFEFF;
        }

        private static String trimRule(String raw) {
            int start = 0;
            int end = raw.length();
            while (start < end && isRuleWhitespace(raw.charAt(start))) {
                start++;
            }
            while (end > start && isRuleWhitespace(raw.charAt(end - 1))) {
                end--;
            }
            return (start == 0 && end == raw.length()) ? raw : raw.substring(start, end);
        }

        public static ValidationResult validateRule(String rawRule) {
            if (rawRule == null) return ValidationResult.fail("屏蔽规则不能为空");
            String trimmed = trimRule(rawRule);
            if (trimmed.isEmpty()) return ValidationResult.fail("屏蔽规则不能为空");
            if (!trimmed.startsWith("re:")) {
                return ValidationResult.ok();
            }
            String expr = trimmed.substring(3);
            if (expr.isEmpty()) return ValidationResult.fail("正则表达式不能为空");
            if (expr.length() > MAX_REGEX_LENGTH) {
                return ValidationResult.fail("正则表达式长度超过 120 字符上限");
            }
            ValidationResult staticCheck = new SafeRegexValidator(expr).validate();
            if (!staticCheck.valid) {
                return staticCheck;
            }
            try {
                Pattern.compile(expr, Pattern.CASE_INSENSITIVE);
            } catch (PatternSyntaxException e) {
                return ValidationResult.fail("正则表达式语法错误: " + e.getDescription());
            }
            return ValidationResult.ok();
        }

        public static BlockFilter compile(List<String> rawRules) {
            if (rawRules == null || rawRules.isEmpty()) return EMPTY;
            List<String> plains = new ArrayList<>();
            List<Pattern> regexes = new ArrayList<>();
            int accepted = 0;
            for (String raw : rawRules) {
                if (accepted >= MAX_RULES) break;
                if (raw == null) continue;
                String trimmed = trimRule(raw);
                if (trimmed.isEmpty()) continue;
                ValidationResult vr = validateRule(trimmed);
                if (!vr.valid) continue;
                if (trimmed.startsWith("re:")) {
                    regexes.add(Pattern.compile(trimmed.substring(3), Pattern.CASE_INSENSITIVE));
                } else {
                    plains.add(trimmed.toLowerCase(Locale.ROOT));
                }
                accepted++;
            }
            if (plains.isEmpty() && regexes.isEmpty()) return EMPTY;
            if (!regexes.isEmpty()) {
                warmRegexEngineIfNeeded();
            }
            return new BlockFilter(plains.toArray(new String[0]), regexes.toArray(new Pattern[0]));
        }

        public boolean isEmpty() {
            return plainLowerRules.length == 0 && regexRules.length == 0;
        }

        public int ruleCount() {
            return plainLowerRules.length + regexRules.length;
        }

        public boolean isBlocked(String text) {
            if (text == null || text.isEmpty() || isEmpty()) return false;
            evaluationCount.incrementAndGet();
            if (plainLowerRules.length > 0) {
                String lower = text.toLowerCase(Locale.ROOT);
                for (int i = 0; i < plainLowerRules.length; i++) {
                    if (lower.contains(plainLowerRules[i])) return true;
                }
            }
            for (int i = 0; i < regexRules.length; i++) {
                if (regexRules[i].matcher(text).find()) return true;
            }
            return false;
        }

        /** Total number of non-empty candidate texts evaluated against active rules. */
        public long getEvaluationCount() {
            return evaluationCount.get();
        }

        /** Structural equality of compiled rules to skip redundant window re-filtering. */
        public boolean sameRules(BlockFilter other) {
            if (this == other) return true;
            if (other == null) return false;
            if (!Arrays.equals(plainLowerRules, other.plainLowerRules)) return false;
            if (regexRules.length != other.regexRules.length) return false;
            for (int i = 0; i < regexRules.length; i++) {
                if (regexRules[i].flags() != other.regexRules[i].flags()
                        || !regexRules[i].pattern().equals(other.regexRules[i].pattern())) {
                    return false;
                }
            }
            return true;
        }
    }

    List<Candidate> matchOrSearch(MatchQuery query, CancellationToken token) throws IOException;

    List<Candidate> listEpisodes(String sourceOrigin, String animeId, CancellationToken token)
            throws IOException;

    EpisodeSession openSession(String boundEpisodeId, CancellationToken token) throws IOException;

    List<DanmuItem> fetchWindow(EpisodeSession session, int windowIndex, CancellationToken token)
            throws IOException;
}
