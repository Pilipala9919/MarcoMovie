// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import com.pilipala.source.Json;
import com.pilipala.source.Warehouse;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import org.json.*;

public final class ConformanceChecks {
    private static int passCount = 0;
    private static int failCount = 0;

    private static Path resolveConformanceDir(Path root) {
        Path[] candidates =
                new Path[] {
                    root.resolve("shared/conformance"),
                    root.resolve("../shared/conformance"),
                    root.resolve("../../shared/conformance"),
                    Paths.get("shared/conformance"),
                    Paths.get("../shared/conformance"),
                };
        for (Path p : candidates) {
            if (Files.isDirectory(p)) return p.toAbsolutePath().normalize();
        }
        throw new IllegalStateException("Cannot locate shared/conformance/ directory from " + root);
    }

    private static String decodeText(byte[] bytes) throws Exception {
        if (bytes.length >= 2 && (bytes[0] & 0xFF) == 0xFF && (bytes[1] & 0xFF) == 0xFE) {
            return new String(bytes, 2, bytes.length - 2, StandardCharsets.UTF_16LE);
        } else if (bytes.length >= 2 && (bytes[0] & 0xFF) == 0xFE && (bytes[1] & 0xFF) == 0xFF) {
            return new String(bytes, 2, bytes.length - 2, StandardCharsets.UTF_16BE);
        }
        String text = new String(bytes, StandardCharsets.UTF_8);
        return text.replaceFirst("^\\uFEFF", "");
    }

    private static JSONObject applyPlatformOverrides(JSONObject expected, String platform)
            throws Exception {
        JSONObject copy = new JSONObject(expected.toString());
        JSONObject overrides = copy.optJSONObject("platformOverrides");
        if (overrides != null) {
            JSONObject platObj = overrides.optJSONObject(platform);
            if (platObj != null) {
                JSONArray overrideSites = platObj.optJSONArray("sites");
                JSONArray expSites = copy.optJSONArray("sites");
                if (overrideSites != null && expSites != null) {
                    for (int i = 0; i < overrideSites.length(); i++) {
                        JSONObject oSite = overrideSites.getJSONObject(i);
                        String key = oSite.optString("key");
                        for (int j = 0; j < expSites.length(); j++) {
                            JSONObject eSite = expSites.getJSONObject(j);
                            if (key.equals(eSite.optString("key"))) {
                                Iterator<String> it = oSite.keys();
                                while (it.hasNext()) {
                                    String k = it.next();
                                    eSite.put(k, oSite.get(k));
                                }
                            }
                        }
                    }
                }
                Iterator<String> topIt = platObj.keys();
                while (topIt.hasNext()) {
                    String k = topIt.next();
                    if (!"sites".equals(k)) {
                        copy.put(k, platObj.get(k));
                    }
                }
            }
        }
        return copy;
    }

    private static JSONObject normalizeConfig(Cms.Config cfg) throws Exception {
        JSONObject out = new JSONObject();
        JSONArray sitesArr = new JSONArray();
        for (Cms.Site s : cfg.sites) {
            JSONObject sObj = new JSONObject();
            sObj.put("key", s.key);
            sObj.put("name", s.name);
            sObj.put("type", s.type);
            sObj.put("api", s.api);
            sObj.put("jar", s.jar == null ? "" : s.jar);
            sObj.put("playUrl", s.playUrl == null ? "" : s.playUrl);
            sObj.put("searchable", s.searchable);
            sObj.put("requiresParser", s.requiresParser);
            sObj.put("extTooLarge", s.isExtTooLarge());
            sObj.put("capabilityStatus", s.capabilityStatus());
            sObj.put("ext", s.ext == null || JSONObject.NULL.equals(s.ext) ? "" : s.ext);
            JSONObject headers = new JSONObject();
            for (Map.Entry<String, String> h : s.headers.entrySet()) {
                headers.put(h.getKey(), h.getValue());
            }
            sObj.put("headers", headers);
            sitesArr.put(sObj);
        }
        out.put("sites", sitesArr);
        if (cfg.depots != null && cfg.depots.length() > 0) {
            out.put("depots", cfg.depots);
        }
        if (cfg.parses != null && !cfg.parses.isEmpty()) {
            JSONArray parsesArr = new JSONArray();
            for (Cms.Parse p : cfg.parses) {
                JSONObject pObj = new JSONObject();
                pObj.put("name", p.name);
                pObj.put("url", p.url);
                pObj.put("type", p.type);
                JSONObject pHeaders = new JSONObject();
                for (Map.Entry<String, String> h : p.headers.entrySet()) {
                    pHeaders.put(h.getKey(), h.getValue());
                }
                pObj.put("headers", pHeaders);
                parsesArr.put(pObj);
            }
            out.put("parses", parsesArr);
        }
        if (cfg.spider != null && !cfg.spider.isEmpty()) {
            out.put("spider", cfg.spider);
        }
        return out;
    }

    private static JSONObject normalizeListing(Cms.Listing listing) throws Exception {
        JSONObject out = new JSONObject();
        out.put("page", listing.page);
        out.put("pageCount", listing.pageCount);
        JSONArray videosArr = new JSONArray();
        for (Cms.Video v : listing.videos) {
            JSONObject vObj = new JSONObject();
            vObj.put("id", v.id == null ? "" : v.id);
            vObj.put("title", v.title == null ? "" : v.title);
            JSONArray linesArr = new JSONArray();
            for (Cms.Line l : v.lines) {
                JSONObject lObj = new JSONObject();
                lObj.put("name", l.name);
                JSONArray epsArr = new JSONArray();
                for (Cms.Episode e : l.episodes) {
                    JSONObject eObj = new JSONObject();
                    eObj.put("name", e.name);
                    eObj.put("url", e.url);
                    epsArr.put(eObj);
                }
                lObj.put("episodes", epsArr);
                linesArr.put(lObj);
            }
            vObj.put("lines", linesArr);
            videosArr.put(vObj);
        }
        out.put("videos", videosArr);
        return out;
    }

    private static void assertConfigMatches(JSONObject actual, JSONObject expected, String caseId)
            throws Exception {
        if (expected.has("sites")) {
            JSONArray expSites = expected.getJSONArray("sites");
            JSONArray actSites = actual.getJSONArray("sites");
            if (expSites.length() != actSites.length()) {
                throw new AssertionError(
                        "["
                                + caseId
                                + "] sites count mismatch: expected "
                                + expSites.length()
                                + ", got "
                                + actSites.length());
            }
            for (int i = 0; i < expSites.length(); i++) {
                JSONObject exp = expSites.getJSONObject(i);
                JSONObject act = actSites.getJSONObject(i);
                Iterator<String> it = exp.keys();
                while (it.hasNext()) {
                    String k = it.next();
                    if ("headers".equals(k)) {
                        JSONObject expH = exp.getJSONObject("headers");
                        JSONObject actH = act.optJSONObject("headers");
                        if (actH == null)
                            throw new AssertionError(
                                    "[" + caseId + "] missing headers in site " + i);
                        Iterator<String> hIt = expH.keys();
                        while (hIt.hasNext()) {
                            String hKey = hIt.next();
                            if (!expH.getString(hKey).equals(actH.optString(hKey))) {
                                throw new AssertionError(
                                        "["
                                                + caseId
                                                + "] site "
                                                + i
                                                + " header "
                                                + hKey
                                                + " mismatch: expected "
                                                + expH.getString(hKey)
                                                + ", got "
                                                + actH.optString(hKey));
                            }
                        }
                    } else if ("ext".equals(k) && exp.get("ext") instanceof JSONObject) {
                        JSONObject expExt = exp.getJSONObject("ext");
                        Object actExtRaw = act.opt("ext");
                        JSONObject actExt =
                                actExtRaw instanceof JSONObject ? (JSONObject) actExtRaw : null;
                        if (actExt == null && actExtRaw instanceof String) {
                            try {
                                actExt = new JSONObject((String) actExtRaw);
                            } catch (Exception ignored) {
                            }
                        }
                        if (actExt == null)
                            throw new AssertionError(
                                    "[" + caseId + "] site " + i + " ext must be JSONObject");
                        Iterator<String> extIt = expExt.keys();
                        while (extIt.hasNext()) {
                            String ek = extIt.next();
                            String ev = String.valueOf(expExt.get(ek));
                            String av = String.valueOf(actExt.opt(ek));
                            if (!ev.equals(av)) {
                                throw new AssertionError(
                                        "["
                                                + caseId
                                                + "] site "
                                                + i
                                                + " ext."
                                                + ek
                                                + " mismatch: expected "
                                                + ev
                                                + ", got "
                                                + av);
                            }
                        }
                    } else if (!"platformOverrides".equals(k)) {
                        String expVal = String.valueOf(exp.get(k));
                        String actVal = String.valueOf(act.opt(k));
                        if (!expVal.equals(actVal)) {
                            throw new AssertionError(
                                    "["
                                            + caseId
                                            + "] site "
                                            + i
                                            + " field "
                                            + k
                                            + " mismatch: expected "
                                            + expVal
                                            + ", got "
                                            + actVal);
                        }
                    }
                }
            }
        }
        if (expected.has("depots")) {
            int expLen = expected.getJSONArray("depots").length();
            int actLen =
                    actual.optJSONArray("depots") == null
                            ? 0
                            : actual.optJSONArray("depots").length();
            if (expLen != actLen) {
                throw new AssertionError("[" + caseId + "] depots length mismatch");
            }
            JSONArray expD = expected.getJSONArray("depots");
            JSONArray actD = actual.getJSONArray("depots");
            for (int i = 0; i < expLen; i++) {
                JSONObject ed = expD.getJSONObject(i);
                JSONObject ad = actD.getJSONObject(i);
                if (!ed.getString("name").equals(ad.getString("name"))) {
                    throw new AssertionError("[" + caseId + "] depot " + i + " name mismatch");
                }
                if (!ed.getString("url").equals(ad.getString("url"))) {
                    throw new AssertionError("[" + caseId + "] depot " + i + " url mismatch");
                }
            }
        }
        if (expected.has("parses")) {
            int expLen = expected.getJSONArray("parses").length();
            int actLen =
                    actual.optJSONArray("parses") == null
                            ? 0
                            : actual.optJSONArray("parses").length();
            if (expLen != actLen) {
                throw new AssertionError("[" + caseId + "] parses length mismatch");
            }
            JSONArray expP = expected.getJSONArray("parses");
            JSONArray actP = actual.getJSONArray("parses");
            for (int i = 0; i < expLen; i++) {
                JSONObject ep = expP.getJSONObject(i);
                JSONObject ap = actP.getJSONObject(i);
                if (!ep.getString("name").equals(ap.getString("name"))) {
                    throw new AssertionError("[" + caseId + "] parse " + i + " name mismatch");
                }
                if (!ep.getString("url").equals(ap.getString("url"))) {
                    throw new AssertionError("[" + caseId + "] parse " + i + " url mismatch");
                }
                if (ep.getInt("type") != ap.getInt("type")) {
                    throw new AssertionError("[" + caseId + "] parse " + i + " type mismatch");
                }
            }
        }
        if (expected.has("spider")) {
            String expSpider = expected.getString("spider");
            String actSpider = actual.optString("spider", "");
            if (!expSpider.equals(actSpider)) {
                throw new AssertionError(
                        "["
                                + caseId
                                + "] spider mismatch: expected "
                                + expSpider
                                + ", got "
                                + actSpider);
            }
        }
    }

    private static void assertListingMatches(JSONObject actual, JSONObject expected, String caseId)
            throws Exception {
        if (expected.has("page") && actual.getInt("page") != expected.getInt("page")) {
            throw new AssertionError("[" + caseId + "] page mismatch");
        }
        if (expected.has("pageCount")
                && actual.getInt("pageCount") != expected.getInt("pageCount")) {
            throw new AssertionError("[" + caseId + "] pageCount mismatch");
        }
        if (expected.has("videos")) {
            JSONArray expV = expected.getJSONArray("videos");
            JSONArray actV = actual.optJSONArray("videos");
            if (actV == null || expV.length() != actV.length()) {
                throw new AssertionError("[" + caseId + "] videos count mismatch");
            }
            for (int i = 0; i < expV.length(); i++) {
                JSONObject eV = expV.getJSONObject(i);
                JSONObject aV = actV.getJSONObject(i);
                if (eV.has("id")) {
                    if (!eV.getString("id").equals(aV.optString("id"))) {
                        throw new AssertionError("[" + caseId + "] video " + i + " id mismatch");
                    }
                }
                if (eV.has("title")) {
                    if (!eV.getString("title").equals(aV.optString("title"))) {
                        throw new AssertionError("[" + caseId + "] video " + i + " title mismatch");
                    }
                }
                if (eV.has("lines")) {
                    JSONArray expL = eV.getJSONArray("lines");
                    JSONArray actL = aV.optJSONArray("lines");
                    if (actL == null || expL.length() != actL.length()) {
                        throw new AssertionError(
                                "[" + caseId + "] video " + i + " lines count mismatch");
                    }
                    for (int j = 0; j < expL.length(); j++) {
                        JSONObject eL = expL.getJSONObject(j);
                        JSONObject aL = actL.getJSONObject(j);
                        if (!eL.getString("name").equals(aL.getString("name"))) {
                            throw new AssertionError(
                                    "["
                                            + caseId
                                            + "] video "
                                            + i
                                            + " line "
                                            + j
                                            + " name mismatch: expected "
                                            + eL.getString("name")
                                            + ", got "
                                            + aL.getString("name"));
                        }
                        if (eL.has("episodes")) {
                            JSONArray expEps = eL.getJSONArray("episodes");
                            JSONArray actEps = aL.optJSONArray("episodes");
                            if (actEps == null || expEps.length() != actEps.length()) {
                                throw new AssertionError(
                                        "["
                                                + caseId
                                                + "] video "
                                                + i
                                                + " line "
                                                + j
                                                + " episodes count mismatch");
                            }
                            for (int k = 0; k < expEps.length(); k++) {
                                JSONObject eEp = expEps.getJSONObject(k);
                                JSONObject aEp = actEps.getJSONObject(k);
                                if (!eEp.getString("name").equals(aEp.getString("name"))) {
                                    throw new AssertionError(
                                            "["
                                                    + caseId
                                                    + "] video "
                                                    + i
                                                    + " line "
                                                    + j
                                                    + " episode "
                                                    + k
                                                    + " name mismatch");
                                }
                                if (!eEp.getString("url").equals(aEp.getString("url"))) {
                                    throw new AssertionError(
                                            "["
                                                    + caseId
                                                    + "] video "
                                                    + i
                                                    + " line "
                                                    + j
                                                    + " episode "
                                                    + k
                                                    + " url mismatch");
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static void verifyAospOrgJsonBehavior() throws Exception {
        JSONObject parsed = new JSONObject("{\"k\":null}");
        String optNull = parsed.optString("k");
        if (!"null".equals(optNull)) {
            throw new AssertionError(
                    "Expected AOSP org.json device behavior where JSONObject.NULL optString returns \"null\", got: "
                            + optNull);
        }
        JSONObject putNull = new JSONObject().put("k", JSONObject.NULL);
        if (!"null".equals(putNull.optString("k"))
                || !"null".equals(putNull.optString("k", "fallback"))) {
            throw new AssertionError(
                    "Expected JSONObject.NULL put() + optString() to return \"null\" under AOSP org.json");
        }
        if (!"".equals(new JSONObject("{}").optString("k"))) {
            throw new AssertionError("Missing key optString() should return empty string");
        }
        if (!"".equals(Json.str(parsed, "k"))) {
            throw new AssertionError("Json.str() must coerce JSONObject.NULL to empty string");
        }
        System.out.println("PASS runtime_aosp_org_json_null_opt_string");
    }

    public static void main(String[] args) throws Exception {
        Path root = Paths.get(args.length > 0 ? args[0] : ".");
        Path conformanceDir = resolveConformanceDir(root);

        File[] caseDirs = conformanceDir.toFile().listFiles(File::isDirectory);
        if (caseDirs == null || caseDirs.length == 0) {
            throw new IllegalStateException("No case directories found in " + conformanceDir);
        }
        Arrays.sort(caseDirs, Comparator.comparing(File::getName));

        System.out.println("=== Tri-Platform Conformance Suite: Android Runner ===");
        System.out.println("Discovered " + caseDirs.length + " cases in " + conformanceDir);
        verifyAospOrgJsonBehavior();

        for (File dir : caseDirs) {
            String caseId = dir.getName();
            if (!caseId.startsWith("case_")) continue;
            try {
                Path inputPath = dir.toPath().resolve("input.bin");
                Path metaPath = dir.toPath().resolve("meta.json");
                Path expectedPath = dir.toPath().resolve("expected.json");

                byte[] inputBytes = Files.readAllBytes(inputPath);
                JSONObject meta =
                        new JSONObject(
                                new String(Files.readAllBytes(metaPath), StandardCharsets.UTF_8));
                JSONObject rawExpected =
                        new JSONObject(
                                new String(
                                        Files.readAllBytes(expectedPath), StandardCharsets.UTF_8));
                JSONObject expected = applyPlatformOverrides(rawExpected, "android");

                String entrypoint =
                        meta.optString("entrypoint", meta.optString("type", "config"))
                                .toLowerCase(Locale.ROOT);
                String origin = meta.optString("origin", "");

                if ("listing".equals(entrypoint) || "lines".equals(entrypoint)) {
                    String text = decodeText(inputBytes);
                    Cms.Listing listing = Cms.listing(text);
                    JSONObject actual = normalizeListing(listing);
                    assertListingMatches(actual, expected, caseId);
                } else {
                    String text = Cms.document(inputBytes);
                    JSONObject rootJson = new JSONObject(Cms.withoutComments(text));
                    Cms.Config config;
                    if (Warehouse.isCatalog(rootJson)) {
                        config = new Cms.Config();
                        config.depots = Warehouse.depots(rootJson, origin);
                    } else {
                        config = Cms.parseConfig(text, origin);
                    }
                    JSONObject actual = normalizeConfig(config);
                    assertConfigMatches(actual, expected, caseId);
                }
                System.out.println("PASS " + caseId);
                passCount++;
            } catch (Throwable t) {
                System.out.println("FAIL " + caseId + ": " + t.getMessage());
                t.printStackTrace(System.out);
                failCount++;
            }
        }

        System.out.println(
                "\nConformance Summary: " + passCount + " PASSED, " + failCount + " FAILED");
        if (failCount > 0) {
            System.exit(1);
        }
    }
}
