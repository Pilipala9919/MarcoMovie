package com.pilipala.marcomovie;

import java.util.*;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Keep the first useful response; expand sequel numeral forms so '2' also matches 'II' / '第二季'. */
final class SearchVariants {
    private static final String[] ROMAN = {
        "", "", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX"
    };
    private static final String[] CN_NUM = {"", "", "二", "三", "四", "五", "六", "七", "八", "九"};

    private static final Pattern TRAILING_ARABIC_SEQUEL =
            Pattern.compile(
                    "^([\\u4e00-\\u9fa5A-Za-z][\\u4e00-\\u9fa5A-Za-z\\s·]{0,18}?[\\u4e00-\\u9fa5A-Za-z])\\s*([2-9])\\s*$");
    private static final Pattern EMBEDDED_ARABIC_SEQUEL =
            Pattern.compile(
                    "^([\\u4e00-\\u9fa5]{2,14})\\s*([2-9])\\s*([：:·\\-—\\s]*[\\u4e00-\\u9fa5]{2,14})$");
    private static final Pattern TRAILING_ROMAN_SEQUEL =
            Pattern.compile(
                    "(?i)^([\\u4e00-\\u9fa5]{2,16})\\s*(VIII|VII|III|IX|IV|VI|II|V)\\s*([：:·\\-—\\s]*[\\u4e00-\\u9fa5]{0,14})\\s*$");
    private static final Pattern EXPLICIT_CN_SEASON =
            Pattern.compile(
                    "^([\\u4e00-\\u9fa5A-Za-z]{2,16})\\s*第\\s*([二三四五六七八九2-9])\\s*[季部]\\s*$");
    private static final Pattern COMIC_OR_DERIVATIVE_PATTERN =
            Pattern.compile("(短漫|漫剧|动态漫|漫画|有声漫|爽文短剧|女频短剧|男频短剧|解说|速看|一口气看完)");

    interface Match {
        boolean test(String title);
    }

    interface Fetch {
        List<Cms.Video> get(String term) throws Exception;
    }

    static String normalizeUnicodeRoman(String s) {
        if (s == null || s.isEmpty()) return "";
        return s.replace("Ⅷ", "VIII")
                .replace("Ⅶ", "VII")
                .replace("Ⅵ", "VI")
                .replace("Ⅳ", "IV")
                .replace("Ⅸ", "IX")
                .replace("Ⅲ", "III")
                .replace("Ⅱ", "II")
                .replace("Ⅴ", "V");
    }

    private static int romanToInt(String r) {
        if (r == null) return 0;
        String u = r.trim().toUpperCase(Locale.ROOT);
        for (int i = 2; i < ROMAN.length; i++) {
            if (ROMAN[i].equals(u)) return i;
        }
        return 0;
    }

    private static int cnOrDigitToInt(String s) {
        if (s == null || s.isEmpty()) return 0;
        char c = s.trim().charAt(0);
        if (c >= '2' && c <= '9') return c - '0';
        for (int i = 2; i < CN_NUM.length; i++) {
            if (CN_NUM[i].charAt(0) == c) return i;
        }
        return 0;
    }

    /**
     * Expand sequel numeral forms (e.g. "斗罗大陆2" -> ["斗罗大陆2", "斗罗大陆II", "斗罗大陆第二季", "斗罗大陆二"]) so
     * literal-substring CMS/netdisk spiders return the canonical anime/series instead of only
     * comic-drama spin-offs.
     */
    static List<String> sequelVariants(String query) {
        LinkedHashSet<String> out = new LinkedHashSet<>();
        if (query == null) return Collections.emptyList();
        String trimmed = query.trim();
        if (trimmed.isEmpty()) return Collections.emptyList();
        out.add(trimmed);
        String norm = normalizeUnicodeRoman(trimmed);
        if (!norm.equals(trimmed)) out.add(norm);

        Matcher mTrail = TRAILING_ARABIC_SEQUEL.matcher(norm);
        if (mTrail.matches()) {
            String prefix = mTrail.group(1).trim();
            int n = mTrail.group(2).charAt(0) - '0';
            if (n >= 2 && n <= 9 && !prefix.matches("(?i).*(?:1080|720|2160|4k)$")) {
                out.add(prefix + ROMAN[n]);
                out.add(prefix + "第" + CN_NUM[n] + "季");
                out.add(prefix + CN_NUM[n]);
            }
            return new ArrayList<>(out);
        }

        Matcher mEmbed = EMBEDDED_ARABIC_SEQUEL.matcher(norm);
        if (mEmbed.matches()) {
            String prefix = mEmbed.group(1).trim();
            int n = mEmbed.group(2).charAt(0) - '0';
            String suffix = mEmbed.group(3).trim();
            String cleanSuffix = suffix.replaceFirst("^[：:·\\-—\\s]+", "");
            if (n >= 2 && n <= 9) {
                out.add(prefix + ROMAN[n] + cleanSuffix);
                out.add(prefix + ROMAN[n]);
            }
            return new ArrayList<>(out);
        }

        Matcher mRoman = TRAILING_ROMAN_SEQUEL.matcher(norm);
        if (mRoman.matches()) {
            String prefix = mRoman.group(1).trim();
            int n = romanToInt(mRoman.group(2));
            String suffix = mRoman.group(3) == null ? "" : mRoman.group(3).trim();
            String cleanSuffix = suffix.replaceFirst("^[：:·\\-—\\s]+", "");
            if (n >= 2 && n <= 9) {
                if (cleanSuffix.isEmpty()) {
                    out.add(prefix + n);
                    out.add(prefix + "第" + CN_NUM[n] + "季");
                } else {
                    out.add(prefix + n + cleanSuffix);
                    out.add(prefix + n);
                }
            }
            return new ArrayList<>(out);
        }

        Matcher mSeason = EXPLICIT_CN_SEASON.matcher(norm);
        if (mSeason.matches()) {
            String prefix = mSeason.group(1).trim();
            int n = cnOrDigitToInt(mSeason.group(2));
            if (n >= 2 && n <= 9) {
                out.add(prefix + n);
                out.add(prefix + ROMAN[n]);
            }
        }
        return new ArrayList<>(out);
    }

    static List<String> mergeTerms(String query, List<String> baseTerms) {
        LinkedHashSet<String> merged = new LinkedHashSet<>(sequelVariants(query));
        if (baseTerms != null) {
            for (String t : baseTerms) {
                if (t != null && !t.trim().isEmpty()) merged.add(t.trim());
            }
        }
        return new ArrayList<>(merged);
    }

    static boolean wantsComicOrShortDrama(String query) {
        if (query == null || query.isEmpty()) return false;
        return COMIC_OR_DERIVATIVE_PATTERN.matcher(query).find() || query.contains("短剧");
    }

    static boolean isComicOrShortDrama(Cms.Video v) {
        return isComicOrShortDrama(v, "");
    }

    static boolean isComicOrShortDrama(Cms.Video v, String siteName) {
        if (v == null) return false;
        String tag = v.tag == null ? "" : v.tag;
        String title = v.title == null ? "" : v.title;
        String remarks = v.remarks == null ? "" : v.remarks;
        if (COMIC_OR_DERIVATIVE_PATTERN.matcher(tag).find() || tag.contains("短剧")) return true;
        if (COMIC_OR_DERIVATIVE_PATTERN.matcher(title).find()) return true;
        if (COMIC_OR_DERIVATIVE_PATTERN.matcher(remarks).find()) return true;
        if (siteName != null && !siteName.isEmpty()) {
            if (siteName.contains("短漫") || siteName.contains("漫剧")) return true;
        }
        return false;
    }

    static String canonicalSearchKey(String text) {
        if (text == null) return "";
        String s = normalizeUnicodeRoman(text.trim());
        // Canonicalize Roman sequel numerals after CJK into Arabic digits for fair comparison
        for (int i = ROMAN.length - 1; i >= 2; i--) {
            s = s.replaceAll("([\\u4e00-\\u9fa5])\\s*" + ROMAN[i] + "(?![A-Za-z])", "$1" + i);
        }
        for (int i = 2; i < CN_NUM.length; i++) {
            s = s.replaceAll("第\\s*" + CN_NUM[i] + "\\s*[季部]", String.valueOf(i));
        }
        s = s.replaceAll("第\\s*([2-9])\\s*[季部]", "$1");
        s =
                s.replaceAll(
                        "(?i)(?<=[\\u4e00-\\u9fa5])\\s*(?:season\\s*0*|s0*)([2-9])(?![0-9A-Za-z])",
                        "$1");
        s = s.replaceAll("第\\s*[一1]\\s*[季部]", "");
        s = s.replaceAll("(?i)(?<=[\\u4e00-\\u9fa5])\\s*(?:season\\s*0*1|s0*1)(?![0-9A-Za-z])", "");
        return s.toLowerCase(Locale.ROOT)
                .replaceAll("[\\s·:：\\-—_（）()【】\\[\\]《》〈〉\"“”'’!！?？,，.。/\\\\]", "");
    }

    static int scoreVideo(String query, Cms.Video v, String siteName, boolean preferredSite) {
        if (v == null) return Integer.MIN_VALUE / 2;
        int score = 0;
        if (preferredSite) score += 180;
        String qKey = canonicalSearchKey(query);
        String tKey = canonicalSearchKey(v.title);
        if (!qKey.isEmpty() && !tKey.isEmpty()) {
            if (tKey.equals(qKey)) score += 320;
            else if (tKey.startsWith(qKey)) score += 240;
            else if (tKey.contains(qKey)) score += 140;
        }
        String tag = v.tag == null ? "" : v.tag;
        if (tag.contains("动漫") || tag.contains("番") || tag.contains("剧") || tag.contains("影")) {
            if (!isComicOrShortDrama(v, siteName)) score += 45;
        }
        if (!wantsComicOrShortDrama(query) && isComicOrShortDrama(v, siteName)) {
            score -= 600;
        }
        return score;
    }

    static void rankVideos(final String query, List<Cms.Video> videos, final String siteName) {
        if (videos == null || videos.size() <= 1) return;
        Collections.sort(
                videos,
                (a, b) ->
                        Integer.compare(
                                scoreVideo(query, b, siteName, false),
                                scoreVideo(query, a, siteName, false)));
    }

    static List<Cms.Video> run(String query, List<String> variants, Match matches, Fetch fetch)
            throws Exception {
        Exception failure = null;
        int attempts = 0;
        Set<String> sequelSet = new LinkedHashSet<>(sequelVariants(query));
        boolean hasSequelForms = sequelSet.size() > 1;
        boolean allowComic = wantsComicOrShortDrama(query);

        List<Cms.Video> merged = new ArrayList<>();
        Set<String> ids = new LinkedHashSet<>();
        boolean foundPrimaryMedia = false;
        int sequelQueriesDone = 0;

        for (String term : variants) {
            if (Thread.currentThread().isInterrupted()) throw new InterruptedException();
            if (++attempts > 3) break;
            boolean isSequelTerm = sequelSet.contains(term);
            try {
                List<Cms.Video> batch = fetch.get(term);
                if (isSequelTerm) sequelQueriesDone++;
                if (batch != null) {
                    for (Cms.Video v : batch) {
                        if (v != null
                                && v.id != null
                                && !v.id.isEmpty()
                                && (term.equalsIgnoreCase(query)
                                        || isSequelTerm
                                        || matches.test(v.title))
                                && ids.add(v.id)) {
                            merged.add(v);
                            if (allowComic || !isComicOrShortDrama(v)) {
                                foundPrimaryMedia = true;
                            }
                        }
                    }
                }
                if (!merged.isEmpty() && foundPrimaryMedia) {
                    rankVideos(query, merged, "");
                    return merged;
                }
                if (!merged.isEmpty() && !hasSequelForms) {
                    rankVideos(query, merged, "");
                    return merged;
                }
            } catch (SearchCoordinator.VerificationRequiredException e) {
                throw e;
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw e;
            } catch (Exception e) {
                if (Thread.currentThread().isInterrupted()) throw new InterruptedException();
                failure = e;
            }
        }
        if (!merged.isEmpty()) {
            rankVideos(query, merged, "");
            return merged;
        }
        if (failure != null) throw failure;
        return Collections.emptyList();
    }
}
