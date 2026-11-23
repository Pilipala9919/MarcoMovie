package com.pilipala.marcomovie;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.*;
import java.util.concurrent.*;

public final class ConfigLibraryChecks {
    static int checks;

    static void check(boolean value, String name) {
        if (!value) throw new AssertionError(name);
        checks++;
        System.out.println("PASS " + name);
    }

    public static void main(String[] args) throws Exception {
        File directory = new File(args[0]);
        ConfigLibrary store = new ConfigLibrary(directory);
        String first =
                "{\"spider\":\"./first.jar\",\"sites\":[{\"key\":\"same\",\"api\":\"./first\",\"headers\":{\"X-Fixture\":\"one\"}}]}";
        String second =
                "{\"spider\":\"./second.jar\",\"sites\":[{\"key\":\"same\",\"api\":\"./second\",\"ext\":{\"fixture\":2}}]}";
        check(store.entries().isEmpty(), "fresh library is empty");
        ConfigLibrary.Entry one =
                store.remember(first, "https://one.example/config.json", "First", "same");
        ConfigLibrary.Entry two =
                store.remember(second, "https://two.example/config.json", "Second", "same");
        check(store.entries().size() == 2, "adding another address retains first subscription");
        check(
                first.equals(store.raw(one)) && second.equals(store.raw(two)),
                "each raw config keeps its own jar headers and extension");
        ConfigLibrary reopened = new ConfigLibrary(directory);
        List<ConfigLibrary.Entry> saved = reopened.entries();
        check(
                saved.size() == 2 && reopened.raw(saved.get(0)).equals(first),
                "subscriptions survive process-independent reload");
        check(
                saved.get(0).origin.equals("https://one.example/config.json")
                        && saved.get(0).selected.equals("same"),
                "relative URL origin and selected source persist");
        ConfigLibrary.Entry updated =
                reopened.remember(
                        first + "\n", " https://one.example/config.json ", "Updated", "other");
        check(
                updated.id.equals(one.id) && reopened.entries().size() == 2,
                "same trimmed address updates without duplicating");
        check(
                reopened.entries().get(0).selected.equals("other")
                        && reopened.entries().get(0).name.equals("Updated"),
                "update keeps order and latest selection");
        check(reopened.raw(two).equals(second), "updating one address preserves the other");
        reopened.rememberIfAbsent(first, "https://one.example/config.json", "Stale", "same");
        check(
                reopened.entries().get(0).name.equals("Updated")
                        && reopened.raw(reopened.entries().get(0)).equals(first + "\n"),
                "opening saved sources cannot overwrite a newer import");
        ConfigLibrary.Entry local = reopened.remember(first, "", "Local", "same");
        reopened.remember(first, "", "Local", "same");
        reopened.remember(second, "", "Local two", "same");
        check(
                reopened.entries().size() == 4 && !local.id.equals(one.id),
                "local content deduplicates without merging unrelated configs");
        String path = local.id + "-" + local.digest + ".json";
        Files.write(
                new File(reopened.directory, path).toPath(),
                "broken".getBytes(StandardCharsets.UTF_8));
        boolean corrupt = false;
        try {
            reopened.raw(local);
        } catch (IOException expected) {
            corrupt = true;
        }
        check(
                corrupt && reopened.raw(two).equals(second),
                "damaged entry rejected without damaging others");
        ExecutorService workers = Executors.newFixedThreadPool(2);
        try {
            Future<?> a =
                    workers.submit(
                            () -> {
                                try {
                                    new ConfigLibrary(directory)
                                            .remember(first, "https://three.example", "Three", "");
                                } catch (Exception error) {
                                    throw new RuntimeException(error);
                                }
                            });
            Future<?> b =
                    workers.submit(
                            () -> {
                                try {
                                    new ConfigLibrary(directory)
                                            .remember(second, "https://four.example", "Four", "");
                                } catch (Exception error) {
                                    throw new RuntimeException(error);
                                }
                            });
            a.get();
            b.get();
        } finally {
            workers.shutdownNow();
        }
        check(
                reopened.entries().size() == 6,
                "simultaneous saves from separate callers retain both entries");
        File index = new File(reopened.directory, "index.json");
        Files.write(index.toPath(), "invalid".getBytes(StandardCharsets.UTF_8));
        boolean failed = false;
        try {
            reopened.remember(second, "https://five.example", "Five", "");
        } catch (Exception expected) {
            failed = true;
        }
        check(
                failed
                        && new String(Files.readAllBytes(index.toPath()), StandardCharsets.UTF_8)
                                .equals("invalid")
                        && reopened.raw(two).equals(second),
                "unreadable index is never silently overwritten");
        System.out.println(checks + " saved subscription checks passed");
    }
}
