package com.pilipala.marcomovie;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyPermanentlyInvalidatedException;
import android.security.keystore.KeyProperties;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.Key;
import java.security.KeyStore;
import java.security.KeyStoreException;
import java.security.NoSuchAlgorithmException;
import java.security.NoSuchProviderException;
import java.security.UnrecoverableKeyException;
import java.security.spec.AlgorithmParameterSpec;
import java.util.Arrays;
import java.util.Locale;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

public final class SecureStorage {
    private static final String TAG = "SecureStorage";
    private static final String KEYSTORE_PROVIDER = "AndroidKeyStore";
    static final String KEY_ALIAS = "movie_webdav_credential_key";
    static final String PREF_FILE = "movie_secure_credentials";
    static final String KEY_WEBDAV_PASS_ENC = "webdav_pass_enc";
    static final String KEY_KEYSTORE_UNAVAILABLE = "keystore_unavailable";
    static final String KEY_REAUTH_REQUIRED = "webdav_pass_reauth_required";
    static final String REENTER_PASSWORD_MESSAGE = "系统安全密钥已失效，请重新输入 WebDAV 密码";
    static final String AES_GCM_NO_PADDING = "AES/GCM/NoPadding";
    static final int GCM_TAG_LENGTH = 128;
    static final int GCM_IV_LENGTH = 12;

    private static final char[] B64_CHARS =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toCharArray();
    private static final int[] B64_INV = new int[128];

    static {
        Arrays.fill(B64_INV, -1);
        for (int i = 0; i < B64_CHARS.length; i++) {
            B64_INV[B64_CHARS[i]] = i;
        }
    }

    interface CipherAdapter {
        void init(int opmode, Key key) throws Exception;

        void init(int opmode, Key key, AlgorithmParameterSpec params) throws Exception;

        byte[] getIV();

        byte[] doFinal(byte[] input) throws Exception;
    }

    interface CryptoBackend {
        SecretKey getOrCreateKey() throws Exception;

        void deleteKey() throws Exception;

        CipherAdapter createCipher() throws Exception;
    }

    interface PromptListener {
        void onReenterPasswordRequired(Context context, String message);
    }

    static final class KeyStoreUnavailableException extends GeneralSecurityException {
        KeyStoreUnavailableException(Throwable cause) {
            super("AndroidKeyStore is unavailable", cause);
        }
    }

    private static final CryptoBackend DEFAULT_BACKEND =
            new CryptoBackend() {
                @Override
                public SecretKey getOrCreateKey() throws Exception {
                    KeyStore ks = KeyStore.getInstance(KEYSTORE_PROVIDER);
                    ks.load(null);
                    if (ks.containsAlias(KEY_ALIAS)) {
                        Key existing = ks.getKey(KEY_ALIAS, null);
                        if (existing instanceof SecretKey) {
                            return (SecretKey) existing;
                        }
                        throw new UnrecoverableKeyException(
                                "KeyStore entry is not a SecretKey: " + KEY_ALIAS);
                    }
                    KeyGenerator kg =
                            KeyGenerator.getInstance(
                                    KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER);
                    KeyGenParameterSpec spec =
                            new KeyGenParameterSpec.Builder(
                                            KEY_ALIAS,
                                            KeyProperties.PURPOSE_ENCRYPT
                                                    | KeyProperties.PURPOSE_DECRYPT)
                                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                                    .setKeySize(256)
                                    .build();
                    kg.init(spec);
                    return kg.generateKey();
                }

                @Override
                public void deleteKey() throws Exception {
                    KeyStore ks = KeyStore.getInstance(KEYSTORE_PROVIDER);
                    ks.load(null);
                    if (ks.containsAlias(KEY_ALIAS)) {
                        ks.deleteEntry(KEY_ALIAS);
                    }
                }

                @Override
                public CipherAdapter createCipher() throws Exception {
                    final Cipher cipher = Cipher.getInstance(AES_GCM_NO_PADDING);
                    return new CipherAdapter() {
                        @Override
                        public void init(int opmode, Key key) throws Exception {
                            cipher.init(opmode, key);
                        }

                        @Override
                        public void init(int opmode, Key key, AlgorithmParameterSpec params)
                                throws Exception {
                            cipher.init(opmode, key, params);
                        }

                        @Override
                        public byte[] getIV() {
                            return cipher.getIV();
                        }

                        @Override
                        public byte[] doFinal(byte[] input) throws Exception {
                            return cipher.doFinal(input);
                        }
                    };
                }
            };

    interface Clock {
        long nowMs();
    }

    static final long KEYSTORE_UNAVAILABLE_TTL_MS = 5 * 60 * 1000L;

    private static final PromptListener DEFAULT_PROMPT_LISTENER =
            new PromptListener() {
                @Override
                public void onReenterPasswordRequired(Context context, String message) {
                    AppLog.w(TAG, "WebDAV credential re-authentication required: " + message, null);
                }
            };

    private static volatile CryptoBackend backendOverride;
    private static volatile PromptListener promptListenerOverride;
    private static volatile Clock clockOverride;
    private static volatile long keystoreUnavailableUntilMs;
    private static volatile boolean passwordReentryRequired;

    private SecureStorage() {}

    static void setBackendForTest(CryptoBackend backend) {
        backendOverride = backend;
        keystoreUnavailableUntilMs = 0L;
        passwordReentryRequired = false;
    }

    static void setPromptListenerForTest(PromptListener listener) {
        promptListenerOverride = listener;
    }

    static void setClockForTest(Clock clock) {
        clockOverride = clock;
    }

    private static long nowMs() {
        Clock override = clockOverride;
        return override != null ? override.nowMs() : System.currentTimeMillis();
    }

    private static CryptoBackend activeBackend() {
        CryptoBackend override = backendOverride;
        return override != null ? override : DEFAULT_BACKEND;
    }

    private static PromptListener activePromptListener() {
        PromptListener override = promptListenerOverride;
        return override != null ? override : DEFAULT_PROMPT_LISTENER;
    }

    static boolean isKeyStoreUnavailableMarked(Context context) {
        if (context != null) {
            SharedPreferences securePrefs =
                    context.getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE);
            if (securePrefs.contains(KEY_KEYSTORE_UNAVAILABLE)) {
                if (!securePrefs.edit().remove(KEY_KEYSTORE_UNAVAILABLE).commit()) {
                    AppLog.w(TAG, "Failed to clear legacy keystore_unavailable marker");
                }
            }
        }
        long until = keystoreUnavailableUntilMs;
        if (until <= 0L) return false;
        if (nowMs() >= until) {
            keystoreUnavailableUntilMs = 0L;
            return false;
        }
        return true;
    }

    static synchronized boolean consumeReenterPasswordRequired(Context context) {
        boolean mem = passwordReentryRequired;
        passwordReentryRequired = false;
        boolean persisted = false;
        if (context != null) {
            SharedPreferences securePrefs =
                    context.getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE);
            persisted = securePrefs.getBoolean(KEY_REAUTH_REQUIRED, false);
            if (persisted) {
                if (!securePrefs.edit().remove(KEY_REAUTH_REQUIRED).commit()) {
                    AppLog.w(TAG, "Failed to clear password re-entry flag");
                }
            }
        }
        return mem || persisted;
    }

    private static synchronized SecretKey obtainKey() throws Exception {
        try {
            SecretKey key = activeBackend().getOrCreateKey();
            keystoreUnavailableUntilMs = 0L;
            return key;
        } catch (Throwable t) {
            if (isKeyInvalidatedOrUnrecoverable(t)) {
                if (t instanceof Exception) throw (Exception) t;
                throw new GeneralSecurityException("Key invalidated or unrecoverable", t);
            }
            if (isProviderMissing(t)) {
                throw new KeyStoreUnavailableException(t);
            }
            if (t instanceof Exception) throw (Exception) t;
            throw new GeneralSecurityException("Transient KeyStore failure", t);
        }
    }

    static boolean isProviderMissing(Throwable t) {
        Throwable cur = t;
        while (cur != null) {
            if (cur instanceof NoSuchProviderException) {
                return true;
            }
            if (cur instanceof KeyStoreException || cur instanceof NoSuchAlgorithmException) {
                String rawMsg = cur.getMessage();
                if (rawMsg != null) {
                    String msg = rawMsg.toLowerCase(Locale.ROOT);
                    if (msg.contains("no such provider")
                            || msg.contains("not found")
                            || msg.contains("not available")
                            || (msg.contains("provider")
                                    && (msg.contains("missing") || msg.contains("unavailable")))
                            || (msg.contains("keystore") && msg.contains("missing"))) {
                        return true;
                    }
                }
            }
            cur = cur.getCause();
        }
        return false;
    }

    static boolean isKeyInvalidatedOrUnrecoverable(Throwable t) {
        Throwable cur = t;
        while (cur != null) {
            if (cur instanceof UnrecoverableKeyException
                    || cur instanceof KeyPermanentlyInvalidatedException
                    || "android.security.keystore.KeyPermanentlyInvalidatedException"
                            .equals(cur.getClass().getName())) {
                return true;
            }
            cur = cur.getCause();
        }
        return false;
    }

    private static void markKeyStoreUnavailable(SharedPreferences securePrefs, Throwable cause) {
        keystoreUnavailableUntilMs = nowMs() + KEYSTORE_UNAVAILABLE_TTL_MS;
        AppLog.w(
                TAG,
                "AndroidKeyStore unavailable (retryable TTL); continuing with legacy plaintext storage",
                cause);
        if (securePrefs != null && securePrefs.contains(KEY_KEYSTORE_UNAVAILABLE)) {
            if (!securePrefs.edit().remove(KEY_KEYSTORE_UNAVAILABLE).commit()) {
                AppLog.w(TAG, "Failed to clear legacy keystore_unavailable marker");
            }
        }
    }

    private static void savePlaintextFallback(
            SharedPreferences legacyPrefs, SharedPreferences securePrefs, String pass) {
        if (!legacyPrefs.edit().putString(Prefs.WEBDAV_PASS, pass).commit()) {
            AppLog.w(TAG, "Failed to commit plaintext WebDAV password in fallback mode");
        }
        if (securePrefs != null
                && (securePrefs.contains(KEY_WEBDAV_PASS_ENC)
                        || securePrefs.contains(KEY_REAUTH_REQUIRED)
                        || securePrefs.contains(KEY_KEYSTORE_UNAVAILABLE))) {
            boolean cleared =
                    securePrefs
                            .edit()
                            .remove(KEY_WEBDAV_PASS_ENC)
                            .remove(KEY_REAUTH_REQUIRED)
                            .remove(KEY_KEYSTORE_UNAVAILABLE)
                            .commit();
            if (!cleared) {
                AppLog.w(TAG, "Failed to clear stale encrypted WebDAV password after fallback");
            }
        }
        passwordReentryRequired = false;
    }

    private static void handleInvalidatedKey(
            Context context, SharedPreferences securePrefs, Throwable cause) {
        AppLog.w(
                TAG,
                "KeyStore key invalidated or unrecoverable; deleting alias " + KEY_ALIAS,
                cause);
        try {
            activeBackend().deleteKey();
        } catch (Throwable deleteErr) {
            AppLog.w(TAG, "Failed to delete invalidated KeyStore alias " + KEY_ALIAS, deleteErr);
        }
        passwordReentryRequired = true;
        if (securePrefs != null) {
            boolean ok =
                    securePrefs
                            .edit()
                            .remove(KEY_WEBDAV_PASS_ENC)
                            .putBoolean(KEY_REAUTH_REQUIRED, true)
                            .commit();
            if (!ok) {
                AppLog.w(TAG, "Failed to commit key-invalidation cleanup to secure prefs");
            }
        }
        activePromptListener().onReenterPasswordRequired(context, REENTER_PASSWORD_MESSAGE);
    }

    public static String encrypt(String plainText) throws Exception {
        if (plainText == null || plainText.isEmpty()) return "";
        SecretKey key = obtainKey();
        CipherAdapter cipher = activeBackend().createCipher();
        cipher.init(Cipher.ENCRYPT_MODE, key);
        byte[] iv = cipher.getIV();
        if (iv == null || iv.length != GCM_IV_LENGTH) {
            throw new GeneralSecurityException(
                    "Invalid GCM IV from Cipher.getIV(): length=" + (iv == null ? -1 : iv.length));
        }
        byte[] cipherText = cipher.doFinal(plainText.getBytes(StandardCharsets.UTF_8));
        byte[] combined = new byte[iv.length + cipherText.length];
        System.arraycopy(iv, 0, combined, 0, iv.length);
        System.arraycopy(cipherText, 0, combined, iv.length, cipherText.length);
        return encodeBase64(combined);
    }

    public static String decrypt(String base64Payload) throws Exception {
        if (base64Payload == null || base64Payload.isEmpty()) return "";
        byte[] combined = decodeBase64(base64Payload);
        if (combined.length < GCM_IV_LENGTH + (GCM_TAG_LENGTH / 8)) {
            throw new GeneralSecurityException("Encrypted WebDAV credential payload too short");
        }
        byte[] iv = new byte[GCM_IV_LENGTH];
        System.arraycopy(combined, 0, iv, 0, GCM_IV_LENGTH);
        byte[] cipherText = new byte[combined.length - GCM_IV_LENGTH];
        System.arraycopy(combined, GCM_IV_LENGTH, cipherText, 0, cipherText.length);

        SecretKey key = obtainKey();
        CipherAdapter cipher = activeBackend().createCipher();
        cipher.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(GCM_TAG_LENGTH, iv));
        byte[] plain = cipher.doFinal(cipherText);
        return new String(plain, StandardCharsets.UTF_8);
    }

    public static synchronized String getWebdavPass(Context context) {
        if (context == null) return "";
        SharedPreferences legacyPrefs =
                context.getSharedPreferences(Prefs.FILE, Context.MODE_PRIVATE);
        SharedPreferences securePrefs =
                context.getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE);

        boolean degraded = isKeyStoreUnavailableMarked(context);
        String enc = securePrefs.getString(KEY_WEBDAV_PASS_ENC, "");
        boolean hasEnc = enc != null && !enc.isEmpty();

        if (degraded && !hasEnc) {
            String plain = legacyPrefs.getString(Prefs.WEBDAV_PASS, "");
            return plain != null ? plain : "";
        }

        if (!degraded && legacyPrefs.contains(Prefs.WEBDAV_PASS)) {
            String legacyPass = legacyPrefs.getString(Prefs.WEBDAV_PASS, "");
            if (legacyPass == null || legacyPass.isEmpty()) {
                if (securePrefs.edit().remove(KEY_WEBDAV_PASS_ENC).commit()) {
                    if (!legacyPrefs.edit().remove(Prefs.WEBDAV_PASS).commit()) {
                        AppLog.w(TAG, "Failed to remove empty legacy WebDAV password");
                    }
                } else {
                    AppLog.w(TAG, "Failed to clear encrypted WebDAV password for empty legacy key");
                }
                return "";
            }
            try {
                String migratedEnc = encrypt(legacyPass);
                boolean committed =
                        securePrefs
                                .edit()
                                .putString(KEY_WEBDAV_PASS_ENC, migratedEnc)
                                .remove(KEY_KEYSTORE_UNAVAILABLE)
                                .remove(KEY_REAUTH_REQUIRED)
                                .commit();
                if (committed) {
                    passwordReentryRequired = false;
                    keystoreUnavailableUntilMs = 0L;
                    if (!legacyPrefs.edit().remove(Prefs.WEBDAV_PASS).commit()) {
                        AppLog.w(
                                TAG,
                                "Committed encrypted WebDAV password, but failed to remove legacy plaintext");
                    }
                } else {
                    AppLog.w(
                            TAG,
                            "commit() returned false while migrating WebDAV password; keeping plaintext");
                }
            } catch (KeyStoreUnavailableException e) {
                markKeyStoreUnavailable(securePrefs, e);
            } catch (Throwable t) {
                if (isKeyInvalidatedOrUnrecoverable(t)) {
                    handleInvalidatedKey(context, securePrefs, t);
                } else {
                    AppLog.w(
                            TAG,
                            "Failed to migrate WebDAV password to SecureStorage; keeping plaintext",
                            t);
                }
            }
            return legacyPass;
        }

        if (hasEnc) {
            try {
                String decrypted = decrypt(enc);
                keystoreUnavailableUntilMs = 0L;
                return decrypted;
            } catch (KeyStoreUnavailableException e) {
                markKeyStoreUnavailable(securePrefs, e);
            } catch (Throwable t) {
                if (isKeyInvalidatedOrUnrecoverable(t)) {
                    handleInvalidatedKey(context, securePrefs, t);
                } else {
                    AppLog.w(TAG, "Failed to decrypt WebDAV password", t);
                }
            }
        }

        if (legacyPrefs.contains(Prefs.WEBDAV_PASS)) {
            String plain = legacyPrefs.getString(Prefs.WEBDAV_PASS, "");
            return plain != null ? plain : "";
        }
        return "";
    }

    public static synchronized void setWebdavPass(Context context, String pass) {
        if (context == null) return;
        SharedPreferences legacyPrefs =
                context.getSharedPreferences(Prefs.FILE, Context.MODE_PRIVATE);
        SharedPreferences securePrefs =
                context.getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE);

        if (pass == null || pass.isEmpty()) {
            clearWebdavPass(context);
            return;
        }

        if (isKeyStoreUnavailableMarked(context)) {
            savePlaintextFallback(legacyPrefs, securePrefs, pass);
            return;
        }

        String enc = null;
        Throwable encryptError = null;
        try {
            enc = encrypt(pass);
        } catch (KeyStoreUnavailableException e) {
            markKeyStoreUnavailable(securePrefs, e);
            savePlaintextFallback(legacyPrefs, securePrefs, pass);
            return;
        } catch (Throwable t) {
            if (isKeyInvalidatedOrUnrecoverable(t)) {
                AppLog.w(
                        TAG,
                        "KeyStore key invalidated during setWebdavPass; deleting alias "
                                + KEY_ALIAS
                                + " and retrying with a fresh key",
                        t);
                try {
                    activeBackend().deleteKey();
                    enc = encrypt(pass);
                } catch (Throwable retryErr) {
                    encryptError = retryErr;
                }
            } else {
                encryptError = t;
            }
        }

        if (encryptError != null || enc == null) {
            if (encryptError instanceof KeyStoreUnavailableException) {
                markKeyStoreUnavailable(securePrefs, encryptError);
            } else {
                AppLog.w(
                        TAG,
                        "Failed to encrypt WebDAV password; writing to legacy plaintext pref",
                        encryptError);
            }
            savePlaintextFallback(legacyPrefs, securePrefs, pass);
            return;
        }

        boolean committed =
                securePrefs
                        .edit()
                        .putString(KEY_WEBDAV_PASS_ENC, enc)
                        .remove(KEY_KEYSTORE_UNAVAILABLE)
                        .remove(KEY_REAUTH_REQUIRED)
                        .commit();
        if (committed) {
            passwordReentryRequired = false;
            keystoreUnavailableUntilMs = 0L;
            if (legacyPrefs.contains(Prefs.WEBDAV_PASS)) {
                if (!legacyPrefs.edit().remove(Prefs.WEBDAV_PASS).commit()) {
                    AppLog.w(
                            TAG,
                            "Committed encrypted WebDAV password, but failed to delete legacy plaintext");
                }
            }
        } else {
            AppLog.w(
                    TAG,
                    "commit() returned false while saving WebDAV password; keeping existing plaintext");
        }
    }

    public static synchronized void clearWebdavPass(Context context) {
        if (context == null) return;
        SharedPreferences legacyPrefs =
                context.getSharedPreferences(Prefs.FILE, Context.MODE_PRIVATE);
        SharedPreferences securePrefs =
                context.getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE);
        if (!securePrefs.edit().remove(KEY_WEBDAV_PASS_ENC).remove(KEY_REAUTH_REQUIRED).commit()) {
            AppLog.w(TAG, "Failed to commit removal of encrypted WebDAV password");
        }
        if (!legacyPrefs.edit().remove(Prefs.WEBDAV_PASS).commit()) {
            AppLog.w(TAG, "Failed to commit removal of legacy plaintext WebDAV password");
        }
        passwordReentryRequired = false;
    }

    static String encodeBase64(byte[] data) {
        if (data == null || data.length == 0) return "";
        StringBuilder out = new StringBuilder(((data.length + 2) / 3) * 4);
        int i = 0;
        while (i + 2 < data.length) {
            int n = ((data[i++] & 0xff) << 16) | ((data[i++] & 0xff) << 8) | (data[i++] & 0xff);
            out.append(B64_CHARS[(n >>> 18) & 0x3f]);
            out.append(B64_CHARS[(n >>> 12) & 0x3f]);
            out.append(B64_CHARS[(n >>> 6) & 0x3f]);
            out.append(B64_CHARS[n & 0x3f]);
        }
        int rem = data.length - i;
        if (rem == 1) {
            int n = (data[i] & 0xff) << 16;
            out.append(B64_CHARS[(n >>> 18) & 0x3f]);
            out.append(B64_CHARS[(n >>> 12) & 0x3f]);
            out.append("==");
        } else if (rem == 2) {
            int n = ((data[i] & 0xff) << 16) | ((data[i + 1] & 0xff) << 8);
            out.append(B64_CHARS[(n >>> 18) & 0x3f]);
            out.append(B64_CHARS[(n >>> 12) & 0x3f]);
            out.append(B64_CHARS[(n >>> 6) & 0x3f]);
            out.append('=');
        }
        return out.toString();
    }

    static byte[] decodeBase64(String input) {
        if (input == null) throw new IllegalArgumentException("Base64 input is null");
        String trimmed = input.trim();
        if (trimmed.isEmpty()) return new byte[0];
        if ((trimmed.length() & 3) != 0) {
            throw new IllegalArgumentException("Invalid Base64 length: " + trimmed.length());
        }
        int pad = 0;
        if (trimmed.endsWith("==")) pad = 2;
        else if (trimmed.endsWith("=")) pad = 1;
        int outLen = (trimmed.length() / 4) * 3 - pad;
        byte[] out = new byte[outLen];
        int outIdx = 0;
        for (int i = 0; i < trimmed.length(); i += 4) {
            int c0 = b64Val(trimmed.charAt(i));
            int c1 = b64Val(trimmed.charAt(i + 1));
            char ch2 = trimmed.charAt(i + 2);
            char ch3 = trimmed.charAt(i + 3);
            boolean lastBlock = (i + 4 == trimmed.length());
            int c2 = (lastBlock && ch2 == '=') ? 0 : b64Val(ch2);
            int c3 = (lastBlock && ch3 == '=') ? 0 : b64Val(ch3);
            if (lastBlock && ch2 == '=' && ch3 != '=') {
                throw new IllegalArgumentException("Malformed Base64 padding");
            }
            int triple = (c0 << 18) | (c1 << 12) | (c2 << 6) | c3;
            out[outIdx++] = (byte) ((triple >>> 16) & 0xff);
            if (outIdx < outLen) out[outIdx++] = (byte) ((triple >>> 8) & 0xff);
            if (outIdx < outLen) out[outIdx++] = (byte) (triple & 0xff);
        }
        return out;
    }

    private static int b64Val(char c) {
        if (c >= 128 || B64_INV[c] < 0) {
            throw new IllegalArgumentException("Invalid Base64 character: " + c);
        }
        return B64_INV[c];
    }
}
