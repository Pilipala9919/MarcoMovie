package com.pilipala.marcomovie;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyPermanentlyInvalidatedException;
import java.security.InvalidAlgorithmParameterException;
import java.security.Key;
import java.security.KeyStoreException;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.security.UnrecoverableKeyException;
import java.security.spec.AlgorithmParameterSpec;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.NoSuchPaddingException;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

public final class SecureStorageChecks {
    private static int checks = 0;

    private SecureStorageChecks() {}

    private static void check(boolean ok, String label) {
        if (!ok) {
            throw new AssertionError("FAILED: " + label);
        }
        checks++;
        System.out.println("PASS " + label);
    }

    /**
     * Simulates AndroidKeyStore AES/GCM Cipher where randomizedEncryptionRequired=true: caller-
     * provided IV / AlgorithmParameterSpec in ENCRYPT_MODE throws
     * InvalidAlgorithmParameterException, while init(ENCRYPT_MODE, key) generates a random 12-byte
     * IV retrievable via getIV().
     */
    private static final class StrictKeyStoreCipher implements SecureStorage.CipherAdapter {
        private final Cipher delegate;

        StrictKeyStoreCipher() throws NoSuchAlgorithmException, NoSuchPaddingException {
            this.delegate = Cipher.getInstance(SecureStorage.AES_GCM_NO_PADDING);
        }

        @Override
        public void init(int opmode, Key key) throws Exception {
            delegate.init(opmode, key);
        }

        @Override
        public void init(int opmode, Key key, AlgorithmParameterSpec params) throws Exception {
            if (opmode == Cipher.ENCRYPT_MODE && params != null) {
                throw new InvalidAlgorithmParameterException(
                        "Caller-provided IV not permitted by AndroidKeyStore");
            }
            delegate.init(opmode, key, params);
        }

        @Override
        public byte[] getIV() {
            return delegate.getIV();
        }

        @Override
        public byte[] doFinal(byte[] input) throws Exception {
            return delegate.doFinal(input);
        }
    }

    private static final class InMemoryPrefs implements SharedPreferences {
        private final Map<String, Object> map = new HashMap<>();
        boolean failCommit = false;

        @Override
        public synchronized Map<String, ?> getAll() {
            return new HashMap<>(map);
        }

        @Override
        public synchronized String getString(String key, String defValue) {
            Object v = map.get(key);
            return v instanceof String ? (String) v : defValue;
        }

        @Override
        @SuppressWarnings("unchecked")
        public synchronized Set<String> getStringSet(String key, Set<String> defValues) {
            Object v = map.get(key);
            return v instanceof Set ? new HashSet<>((Set<String>) v) : defValues;
        }

        @Override
        public synchronized int getInt(String key, int defValue) {
            Object v = map.get(key);
            return v instanceof Integer ? (Integer) v : defValue;
        }

        @Override
        public synchronized long getLong(String key, long defValue) {
            Object v = map.get(key);
            return v instanceof Long ? (Long) v : defValue;
        }

        @Override
        public synchronized float getFloat(String key, float defValue) {
            Object v = map.get(key);
            return v instanceof Float ? (Float) v : defValue;
        }

        @Override
        public synchronized boolean getBoolean(String key, boolean defValue) {
            Object v = map.get(key);
            return v instanceof Boolean ? (Boolean) v : defValue;
        }

        @Override
        public synchronized boolean contains(String key) {
            return map.containsKey(key);
        }

        @Override
        public Editor edit() {
            return new EditorImpl();
        }

        @Override
        public void registerOnSharedPreferenceChangeListener(
                OnSharedPreferenceChangeListener listener) {}

        @Override
        public void unregisterOnSharedPreferenceChangeListener(
                OnSharedPreferenceChangeListener listener) {}

        private final class EditorImpl implements Editor {
            private final Map<String, Object> staged = new HashMap<>();
            private final Set<String> removals = new HashSet<>();
            private boolean clearAll = false;

            @Override
            public Editor putString(String key, String value) {
                staged.put(key, value);
                removals.remove(key);
                return this;
            }

            @Override
            public Editor putStringSet(String key, Set<String> values) {
                staged.put(key, values == null ? null : new HashSet<>(values));
                removals.remove(key);
                return this;
            }

            @Override
            public Editor putInt(String key, int value) {
                staged.put(key, value);
                removals.remove(key);
                return this;
            }

            @Override
            public Editor putLong(String key, long value) {
                staged.put(key, value);
                removals.remove(key);
                return this;
            }

            @Override
            public Editor putFloat(String key, float value) {
                staged.put(key, value);
                removals.remove(key);
                return this;
            }

            @Override
            public Editor putBoolean(String key, boolean value) {
                staged.put(key, value);
                removals.remove(key);
                return this;
            }

            @Override
            public Editor remove(String key) {
                removals.add(key);
                staged.remove(key);
                return this;
            }

            @Override
            public Editor clear() {
                clearAll = true;
                staged.clear();
                removals.clear();
                return this;
            }

            @Override
            public boolean commit() {
                synchronized (InMemoryPrefs.this) {
                    if (failCommit) {
                        return false;
                    }
                    applyLocked();
                    return true;
                }
            }

            @Override
            public void apply() {
                synchronized (InMemoryPrefs.this) {
                    if (!failCommit) {
                        applyLocked();
                    }
                }
            }

            private void applyLocked() {
                if (clearAll) {
                    map.clear();
                }
                for (String k : removals) {
                    map.remove(k);
                }
                for (Map.Entry<String, Object> e : staged.entrySet()) {
                    if (e.getValue() == null) {
                        map.remove(e.getKey());
                    } else {
                        map.put(e.getKey(), e.getValue());
                    }
                }
            }
        }
    }

    private static final class FakeContext extends Context {
        private final Map<String, InMemoryPrefs> files = new HashMap<>();

        @Override
        public Context getApplicationContext() {
            return this;
        }

        @Override
        public synchronized InMemoryPrefs getSharedPreferences(String name, int mode) {
            InMemoryPrefs p = files.get(name);
            if (p == null) {
                p = new InMemoryPrefs();
                files.put(name, p);
            }
            return p;
        }
    }

    private static SecretKey generateJvmAesKey() throws NoSuchAlgorithmException {
        KeyGenerator kg = KeyGenerator.getInstance("AES");
        kg.init(256);
        return kg.generateKey();
    }

    public static void main(String[] args) throws Exception {
        testBase64Parity();
        testStrictKeyStoreCipherRejectsCallerIvAndRoundtrips();
        testEncryptionFailurePreservesPlaintextAndLogs();
        testCommitFalsePreservesPlaintextAndLogs();
        testKeyStoreUnavailableFallsBackToPlaintextWithMarker();
        testInvalidatedAndUnrecoverableKeysDeleteAliasAndPrompt();
        System.out.println("ALL PASS (" + checks + " checks)");
    }

    private static void testBase64Parity() {
        SecureRandom rng = new SecureRandom();
        for (int len = 0; len <= 96; len++) {
            byte[] raw = new byte[len];
            rng.nextBytes(raw);
            String expected = java.util.Base64.getEncoder().encodeToString(raw);
            String actual = SecureStorage.encodeBase64(raw);
            if (!expected.equals(actual)) {
                throw new AssertionError("Base64 encode mismatch at len=" + len);
            }
            byte[] decoded = SecureStorage.decodeBase64(actual);
            if (!Arrays.equals(raw, decoded)) {
                throw new AssertionError("Base64 decode mismatch at len=" + len);
            }
        }
        check(true, "Base64 encode/decode matches RFC 4648 across byte lengths 0..96");
    }

    private static void testStrictKeyStoreCipherRejectsCallerIvAndRoundtrips() throws Exception {
        final SecretKey key = generateJvmAesKey();

        // 1. Verify StrictKeyStoreCipher actually rejects caller-provided IV in ENCRYPT_MODE
        SecureStorage.CipherAdapter probe = new StrictKeyStoreCipher();
        boolean callerIvRejected = false;
        try {
            probe.init(
                    Cipher.ENCRYPT_MODE,
                    key,
                    new GCMParameterSpec(SecureStorage.GCM_TAG_LENGTH, new byte[12]));
        } catch (InvalidAlgorithmParameterException expected) {
            callerIvRejected = true;
        }
        check(callerIvRejected, "StrictKeyStoreCipher rejects caller-provided IV in ENCRYPT_MODE");

        // 2. Inject StrictKeyStoreCipher into SecureStorage and verify migration + roundtrip
        SecureStorage.setBackendForTest(
                new SecureStorage.CryptoBackend() {
                    @Override
                    public SecretKey getOrCreateKey() {
                        return key;
                    }

                    @Override
                    public void deleteKey() {}

                    @Override
                    public SecureStorage.CipherAdapter createCipher() throws Exception {
                        return new StrictKeyStoreCipher();
                    }
                });

        FakeContext ctx = new FakeContext();
        InMemoryPrefs legacy = ctx.getSharedPreferences(Prefs.FILE, Context.MODE_PRIVATE);
        InMemoryPrefs secure =
                ctx.getSharedPreferences(SecureStorage.PREF_FILE, Context.MODE_PRIVATE);
        legacy.edit().putString(Prefs.WEBDAV_PASS, "jianguoyun_app_secret_123").commit();

        String migrated = SecureStorage.getWebdavPass(ctx);
        check(
                "jianguoyun_app_secret_123".equals(migrated),
                "Migration reads legacy WebDAV password under StrictKeyStoreCipher");
        check(
                !legacy.contains(Prefs.WEBDAV_PASS),
                "Legacy plaintext pref removed after encrypted commit() succeeds");
        String enc1 = secure.getString(SecureStorage.KEY_WEBDAV_PASS_ENC, "");
        check(
                !enc1.isEmpty() && !enc1.contains("jianguoyun_app_secret_123"),
                "Encrypted WebDAV password stored in secure prefs");
        check(
                "jianguoyun_app_secret_123".equals(SecureStorage.getWebdavPass(ctx)),
                "Subsequent getWebdavPass decrypts using GCMParameterSpec");

        SecureStorage.setWebdavPass(ctx, "same_secret_for_iv_check");
        String ctA = secure.getString(SecureStorage.KEY_WEBDAV_PASS_ENC, "");
        SecureStorage.setWebdavPass(ctx, "same_secret_for_iv_check");
        String ctB = secure.getString(SecureStorage.KEY_WEBDAV_PASS_ENC, "");
        check(
                !ctA.isEmpty() && !ctB.isEmpty() && !ctA.equals(ctB),
                "Each encryption uses a fresh Cipher-generated IV");
        check(
                "same_secret_for_iv_check".equals(SecureStorage.getWebdavPass(ctx)),
                "Updated password decrypts cleanly");
    }

    private static void testEncryptionFailurePreservesPlaintextAndLogs() throws Exception {
        final SecretKey key = generateJvmAesKey();
        // Simulate a broken Cipher that throws during encrypt (e.g. if caller IV were rejected or
        // hardware crypto failed)
        SecureStorage.setBackendForTest(
                new SecureStorage.CryptoBackend() {
                    @Override
                    public SecretKey getOrCreateKey() {
                        return key;
                    }

                    @Override
                    public void deleteKey() {}

                    @Override
                    public SecureStorage.CipherAdapter createCipher() throws Exception {
                        throw new InvalidAlgorithmParameterException(
                                "Simulated caller-provided IV rejection");
                    }
                });

        FakeContext ctx = new FakeContext();
        InMemoryPrefs legacy = ctx.getSharedPreferences(Prefs.FILE, Context.MODE_PRIVATE);
        legacy.edit().putString(Prefs.WEBDAV_PASS, "must_survive_cipher_failure").commit();

        AppLog.clear();
        String duringMigration = SecureStorage.getWebdavPass(ctx);
        check(
                "must_survive_cipher_failure".equals(duringMigration),
                "getWebdavPass still returns legacy password when encryption fails");
        check(
                "must_survive_cipher_failure".equals(legacy.getString(Prefs.WEBDAV_PASS, "")),
                "Plaintext pref is preserved when migration encryption fails");
        check(
                AppLog.dump().contains("W/SecureStorage"),
                "AppLog records warning when migration encryption fails");

        AppLog.clear();
        SecureStorage.setWebdavPass(ctx, "new_pass_that_fails_to_encrypt");
        check(
                "new_pass_that_fails_to_encrypt".equals(legacy.getString(Prefs.WEBDAV_PASS, "")),
                "setWebdavPass writes new password to legacy plaintext pref when encryption fails");
        check(
                "new_pass_that_fails_to_encrypt".equals(SecureStorage.getWebdavPass(ctx)),
                "getWebdavPass returns new fallback plaintext password after encryption failure");
        check(
                AppLog.dump().contains("W/SecureStorage"),
                "AppLog records warning when setWebdavPass encryption fails");
    }

    private static void testCommitFalsePreservesPlaintextAndLogs() throws Exception {
        final SecretKey key = generateJvmAesKey();
        SecureStorage.setBackendForTest(
                new SecureStorage.CryptoBackend() {
                    @Override
                    public SecretKey getOrCreateKey() {
                        return key;
                    }

                    @Override
                    public void deleteKey() {}

                    @Override
                    public SecureStorage.CipherAdapter createCipher() throws Exception {
                        return new StrictKeyStoreCipher();
                    }
                });

        FakeContext ctx = new FakeContext();
        InMemoryPrefs legacy = ctx.getSharedPreferences(Prefs.FILE, Context.MODE_PRIVATE);
        InMemoryPrefs secure =
                ctx.getSharedPreferences(SecureStorage.PREF_FILE, Context.MODE_PRIVATE);
        legacy.edit().putString(Prefs.WEBDAV_PASS, "must_survive_commit_false").commit();
        secure.failCommit = true;

        AppLog.clear();
        String val = SecureStorage.getWebdavPass(ctx);
        check(
                "must_survive_commit_false".equals(val),
                "getWebdavPass returns legacy password when securePrefs.commit() returns false");
        check(
                "must_survive_commit_false".equals(legacy.getString(Prefs.WEBDAV_PASS, "")),
                "Plaintext pref preserved when securePrefs.commit() returns false during migration");
        check(
                AppLog.dump().contains("commit() returned false"),
                "AppLog records commit() failure during migration");

        AppLog.clear();
        SecureStorage.setWebdavPass(ctx, "unsaved_pass");
        check(
                "must_survive_commit_false".equals(legacy.getString(Prefs.WEBDAV_PASS, "")),
                "Plaintext pref preserved when securePrefs.commit() returns false in setWebdavPass");

        // Once commit() succeeds again, migration completes and deletes legacy plaintext
        secure.failCommit = false;
        check(
                "must_survive_commit_false".equals(SecureStorage.getWebdavPass(ctx)),
                "Migration succeeds once commit() recovers");
        check(
                !legacy.contains(Prefs.WEBDAV_PASS),
                "Legacy plaintext removed once commit() returns true");
    }

    private static void testKeyStoreUnavailableFallsBackToPlaintextWithMarker() throws Exception {
        final long[] nowHolder = new long[] {1_000_000L};
        SecureStorage.setClockForTest(() -> nowHolder[0]);
        try {
            // Passing null restores DEFAULT_BACKEND, which tries
            // KeyStore.getInstance("AndroidKeyStore")
            // and fails on JVM because AndroidKeyStore provider is absent — exercising the real
            // unavailable path!
            SecureStorage.setBackendForTest(null);

            FakeContext ctx = new FakeContext();
            InMemoryPrefs legacy = ctx.getSharedPreferences(Prefs.FILE, Context.MODE_PRIVATE);
            InMemoryPrefs secure =
                    ctx.getSharedPreferences(SecureStorage.PREF_FILE, Context.MODE_PRIVATE);
            // Simulate a legacy permanent marker from an older release as well
            secure.edit().putBoolean(SecureStorage.KEY_KEYSTORE_UNAVAILABLE, true).commit();
            legacy.edit().putString(Prefs.WEBDAV_PASS, "legacy_tv_box_pass").commit();

            AppLog.clear();
            String readBack = SecureStorage.getWebdavPass(ctx);
            check(
                    "legacy_tv_box_pass".equals(readBack),
                    "When AndroidKeyStore is unavailable, legacy plaintext password remains readable");
            check(
                    SecureStorage.isKeyStoreUnavailableMarked(ctx)
                            && !secure.contains(SecureStorage.KEY_KEYSTORE_UNAVAILABLE),
                    "KeyStore unavailable marker is in-memory retryable and cleans up legacy permanent pref");
            check(
                    !secure.contains(SecureStorage.KEY_WEBDAV_PASS_ENC),
                    "No hardcoded constant fallback key is used when KeyStore is unavailable");
            check(
                    "legacy_tv_box_pass".equals(legacy.getString(Prefs.WEBDAV_PASS, "")),
                    "Plaintext password remains in legacy prefs when KeyStore is unavailable");
            check(
                    AppLog.dump().contains("AndroidKeyStore unavailable"),
                    "AppLog warns when AndroidKeyStore is unavailable");

            SecureStorage.setWebdavPass(ctx, "updated_plaintext_fallback_pass");
            check(
                    "updated_plaintext_fallback_pass".equals(SecureStorage.getWebdavPass(ctx)),
                    "setWebdavPass continues using legacy plaintext storage when KeyStore is unavailable");

            // TTL expiry allows retrying KeyStore
            nowHolder[0] += SecureStorage.KEYSTORE_UNAVAILABLE_TTL_MS + 1L;
            check(
                    !SecureStorage.isKeyStoreUnavailableMarked(ctx),
                    "KeyStore unavailable marker expires after TTL so KeyStore can be retried");

            // Degraded mode MUST still attempt decrypt whenever webdav_pass_enc exists
            final SecretKey validKey = generateJvmAesKey();
            final AtomicBoolean failProviderMissing = new AtomicBoolean(false);
            SecureStorage.setBackendForTest(
                    new SecureStorage.CryptoBackend() {
                        @Override
                        public SecretKey getOrCreateKey() throws Exception {
                            if (failProviderMissing.get()) {
                                throw new KeyStoreException("Hardware keystore missing");
                            }
                            return validKey;
                        }

                        @Override
                        public void deleteKey() {}

                        @Override
                        public SecureStorage.CipherAdapter createCipher() throws Exception {
                            return new StrictKeyStoreCipher();
                        }
                    });
            FakeContext ctxEnc = new FakeContext();
            SecureStorage.setWebdavPass(ctxEnc, "encrypted_secret_not_masked");
            // Force degraded marker while webdav_pass_enc exists, then let KeyStore work again
            failProviderMissing.set(true);
            FakeContext otherCtx = new FakeContext();
            SecureStorage.setWebdavPass(otherCtx, "triggers_degraded_marker");
            check(
                    SecureStorage.isKeyStoreUnavailableMarked(ctxEnc),
                    "Missing provider sets retryable degraded marker");
            failProviderMissing.set(false);
            check(
                    "encrypted_secret_not_masked".equals(SecureStorage.getWebdavPass(ctxEnc)),
                    "Degraded mode still attempts decrypt when webdav_pass_enc exists");

            // Transient KeyStore failure (e.g. daemon not ready at boot) must NOT mark unavailable
            final AtomicBoolean daemonNotReady = new AtomicBoolean(true);
            SecureStorage.setBackendForTest(
                    new SecureStorage.CryptoBackend() {
                        @Override
                        public SecretKey getOrCreateKey() throws Exception {
                            if (daemonNotReady.get()) {
                                throw new KeyStoreException("Keystore daemon not ready");
                            }
                            return validKey;
                        }

                        @Override
                        public void deleteKey() {}

                        @Override
                        public SecureStorage.CipherAdapter createCipher() throws Exception {
                            return new StrictKeyStoreCipher();
                        }
                    });
            check(
                    "".equals(SecureStorage.getWebdavPass(ctxEnc)),
                    "Transient KeyStore daemon error fails cleanly without crashing");
            check(
                    !SecureStorage.isKeyStoreUnavailableMarked(ctxEnc),
                    "Transient non-provider KeyStore error does NOT mark KeyStore unavailable");
            daemonNotReady.set(false);
            check(
                    "encrypted_secret_not_masked".equals(SecureStorage.getWebdavPass(ctxEnc)),
                    "Subsequent call immediately decrypts once transient KeyStore failure clears");

            // Explicit missing-provider KeyStoreException marks unavailable and falls back to
            // plaintext
            failProviderMissing.set(true);
            SecureStorage.setBackendForTest(
                    new SecureStorage.CryptoBackend() {
                        @Override
                        public SecretKey getOrCreateKey() throws Exception {
                            throw new KeyStoreException("Hardware keystore missing");
                        }

                        @Override
                        public void deleteKey() {}

                        @Override
                        public SecureStorage.CipherAdapter createCipher() throws Exception {
                            return new StrictKeyStoreCipher();
                        }
                    });
            FakeContext ctx2 = new FakeContext();
            SecureStorage.setWebdavPass(ctx2, "fresh_user_no_keystore");
            check(
                    "fresh_user_no_keystore".equals(SecureStorage.getWebdavPass(ctx2))
                            && SecureStorage.isKeyStoreUnavailableMarked(ctx2),
                    "New password on device without KeyStore falls back to plaintext with retryable marker");
        } finally {
            SecureStorage.setClockForTest(null);
            SecureStorage.setBackendForTest(null);
        }
    }

    private static void testInvalidatedAndUnrecoverableKeysDeleteAliasAndPrompt() throws Exception {
        final AtomicBoolean throwInvalidated = new AtomicBoolean(false);
        final AtomicBoolean throwUnrecoverable = new AtomicBoolean(false);
        final AtomicInteger deleteAliasCount = new AtomicInteger(0);
        final SecretKey[] currentKey = new SecretKey[] {generateJvmAesKey()};
        final List<String> prompts = Collections.synchronizedList(new ArrayList<>());

        SecureStorage.setPromptListenerForTest((context, message) -> prompts.add(message));
        try {
            SecureStorage.setBackendForTest(
                    new SecureStorage.CryptoBackend() {
                        @Override
                        public SecretKey getOrCreateKey() throws Exception {
                            if (throwUnrecoverable.get()) {
                                throw new UnrecoverableKeyException("Key blob corrupted");
                            }
                            if (currentKey[0] == null) {
                                currentKey[0] = generateJvmAesKey();
                            }
                            return currentKey[0];
                        }

                        @Override
                        public void deleteKey() {
                            deleteAliasCount.incrementAndGet();
                            currentKey[0] = null;
                        }

                        @Override
                        public SecureStorage.CipherAdapter createCipher() throws Exception {
                            if (throwInvalidated.get()) {
                                throw new KeyPermanentlyInvalidatedException(
                                        "Lock screen credentials changed");
                            }
                            return new StrictKeyStoreCipher();
                        }
                    });

            FakeContext ctx = new FakeContext();
            SecureStorage.setWebdavPass(ctx, "initial_valid_secret");
            check(
                    "initial_valid_secret".equals(SecureStorage.getWebdavPass(ctx)),
                    "Initial password encrypted and decrypted before key invalidation");

            // Case A: KeyPermanentlyInvalidatedException
            throwInvalidated.set(true);
            prompts.clear();
            String afterInvalidation = SecureStorage.getWebdavPass(ctx);
            check(
                    "".equals(afterInvalidation),
                    "Invalidated key returns empty string instead of crashing");
            check(
                    deleteAliasCount.get() == 1,
                    "KeyPermanentlyInvalidatedException deletes the KeyStore alias");
            check(
                    prompts.size() == 1
                            && SecureStorage.REENTER_PASSWORD_MESSAGE.equals(prompts.get(0)),
                    "KeyPermanentlyInvalidatedException notifies user to re-enter password");
            check(
                    SecureStorage.consumeReenterPasswordRequired(ctx),
                    "consumeReenterPasswordRequired returns true after key invalidation");
            check(
                    !SecureStorage.consumeReenterPasswordRequired(ctx),
                    "consumeReenterPasswordRequired clears flag after consumption");

            // Recover by entering a new password (generates fresh key under alias)
            throwInvalidated.set(false);
            SecureStorage.setWebdavPass(ctx, "reentered_secret_after_invalidation");
            check(
                    "reentered_secret_after_invalidation".equals(SecureStorage.getWebdavPass(ctx)),
                    "Re-entering password after alias deletion generates fresh key and succeeds");

            // Case B: UnrecoverableKeyException
            throwUnrecoverable.set(true);
            prompts.clear();
            String afterUnrecoverable = SecureStorage.getWebdavPass(ctx);
            check(
                    "".equals(afterUnrecoverable),
                    "UnrecoverableKeyException returns empty string safely");
            check(
                    deleteAliasCount.get() == 2,
                    "UnrecoverableKeyException deletes the KeyStore alias");
            check(
                    prompts.size() == 1
                            && SecureStorage.REENTER_PASSWORD_MESSAGE.equals(prompts.get(0))
                            && SecureStorage.consumeReenterPasswordRequired(ctx),
                    "UnrecoverableKeyException prompts user to re-enter password");

            // Case C (9b): setWebdavPass encounters invalidated key on first encrypt, deletes
            // alias and retries once with a new key
            final AtomicBoolean failOnceInSet = new AtomicBoolean(true);
            throwUnrecoverable.set(false);
            SecureStorage.setBackendForTest(
                    new SecureStorage.CryptoBackend() {
                        @Override
                        public SecretKey getOrCreateKey() throws Exception {
                            if (failOnceInSet.getAndSet(false)) {
                                throw new UnrecoverableKeyException("Stale alias during save");
                            }
                            if (currentKey[0] == null) {
                                currentKey[0] = generateJvmAesKey();
                            }
                            return currentKey[0];
                        }

                        @Override
                        public void deleteKey() {
                            deleteAliasCount.incrementAndGet();
                            currentKey[0] = null;
                        }

                        @Override
                        public SecureStorage.CipherAdapter createCipher() throws Exception {
                            return new StrictKeyStoreCipher();
                        }
                    });
            int beforeDeleteCount = deleteAliasCount.get();
            SecureStorage.setWebdavPass(ctx, "retried_with_fresh_key_in_one_save");
            check(
                    deleteAliasCount.get() == beforeDeleteCount + 1,
                    "setWebdavPass deletes invalidated alias before retrying encryption");
            check(
                    "retried_with_fresh_key_in_one_save".equals(SecureStorage.getWebdavPass(ctx)),
                    "setWebdavPass succeeds in one call after deleting invalidated alias and regenerating key");

            // Case D (9c): DEFAULT_PROMPT_LISTENER logs warning instead of showing duplicate Toast,
            // leaving CloudSyncDialog's consumeReenterPasswordRequired notice as the single prompt
            SecureStorage.setPromptListenerForTest(null);
            final AtomicBoolean alwaysInvalid = new AtomicBoolean(true);
            SecureStorage.setBackendForTest(
                    new SecureStorage.CryptoBackend() {
                        @Override
                        public SecretKey getOrCreateKey() throws Exception {
                            if (alwaysInvalid.get()) {
                                throw new KeyPermanentlyInvalidatedException("Invalidated");
                            }
                            return generateJvmAesKey();
                        }

                        @Override
                        public void deleteKey() {
                            deleteAliasCount.incrementAndGet();
                        }

                        @Override
                        public SecureStorage.CipherAdapter createCipher() throws Exception {
                            return new StrictKeyStoreCipher();
                        }
                    });
            alwaysInvalid.set(false);
            FakeContext ctxDefaultPrompt = new FakeContext();
            SecureStorage.setWebdavPass(ctxDefaultPrompt, "before_default_prompt_check");
            alwaysInvalid.set(true);
            AppLog.clear();
            check(
                    "".equals(SecureStorage.getWebdavPass(ctxDefaultPrompt)),
                    "Invalidated key with default listener returns empty string");
            check(
                    AppLog.dump().contains("re-authentication required")
                            && SecureStorage.consumeReenterPasswordRequired(ctxDefaultPrompt),
                    "Default prompt listener logs once and sets single re-auth flag for CloudSyncDialog");
        } finally {
            SecureStorage.setPromptListenerForTest(null);
            SecureStorage.setBackendForTest(null);
        }
    }
}
