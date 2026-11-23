"""Pure-JVM and static thread-safety checks for Android SecureStorage & CloudSyncDialog."""

from pathlib import Path
import os
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
JDK = Path(os.environ.get("MARCOMOVIE_JDK", os.environ.get("JAVA_HOME", "missing-jdk")))
SUFFIX = ".exe" if os.name == "nt" else ""

STUBS = {
    "android/content/Context.java": """package android.content;
public abstract class Context {
    public static final int MODE_PRIVATE = 0;
    public abstract Context getApplicationContext();
    public abstract SharedPreferences getSharedPreferences(String name, int mode);
}
""",
    "android/content/SharedPreferences.java": """package android.content;
import java.util.Map;
import java.util.Set;
public interface SharedPreferences {
    interface OnSharedPreferenceChangeListener {
        void onSharedPreferenceChanged(SharedPreferences sharedPreferences, String key);
    }
    interface Editor {
        Editor putString(String key, String value);
        Editor putStringSet(String key, Set<String> values);
        Editor putInt(String key, int value);
        Editor putLong(String key, long value);
        Editor putFloat(String key, float value);
        Editor putBoolean(String key, boolean value);
        Editor remove(String key);
        Editor clear();
        boolean commit();
        void apply();
    }
    Map<String, ?> getAll();
    String getString(String key, String defValue);
    Set<String> getStringSet(String key, Set<String> defValues);
    int getInt(String key, int defValue);
    long getLong(String key, long defValue);
    float getFloat(String key, float defValue);
    boolean getBoolean(String key, boolean defValue);
    boolean contains(String key);
    Editor edit();
    void registerOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener listener);
    void unregisterOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener listener);
}
""",
    "android/os/Looper.java": """package android.os;
public final class Looper {
    public static Looper getMainLooper() { return null; }
}
""",
    "android/os/Handler.java": """package android.os;
public class Handler {
    public Handler(Looper looper) {}
    public boolean post(Runnable r) {
        if (r != null) r.run();
        return true;
    }
}
""",
    "android/widget/Toast.java": """package android.widget;
import android.content.Context;
public class Toast {
    public static final int LENGTH_LONG = 1;
    public static Toast makeText(Context context, CharSequence text, int duration) {
        return new Toast();
    }
    public void show() {}
}
""",
    "android/security/keystore/KeyProperties.java": """package android.security.keystore;
public final class KeyProperties {
    public static final String KEY_ALGORITHM_AES = "AES";
    public static final int PURPOSE_ENCRYPT = 1;
    public static final int PURPOSE_DECRYPT = 2;
    public static final String BLOCK_MODE_GCM = "GCM";
    public static final String ENCRYPTION_PADDING_NONE = "NoPadding";
}
""",
    "android/security/keystore/KeyGenParameterSpec.java": """package android.security.keystore;
import java.security.spec.AlgorithmParameterSpec;
public final class KeyGenParameterSpec implements AlgorithmParameterSpec {
    public static final class Builder {
        public Builder(String keystoreAlias, int purposes) {}
        public Builder setBlockModes(String... blockModes) { return this; }
        public Builder setEncryptionPaddings(String... paddings) { return this; }
        public Builder setKeySize(int keySize) { return this; }
        public KeyGenParameterSpec build() { return new KeyGenParameterSpec(); }
    }
}
""",
    "android/security/keystore/KeyPermanentlyInvalidatedException.java": """package android.security.keystore;
import java.security.InvalidKeyException;
public class KeyPermanentlyInvalidatedException extends InvalidKeyException {
    public KeyPermanentlyInvalidatedException() { super(); }
    public KeyPermanentlyInvalidatedException(String message) { super(message); }
}
""",
}


def verify_source_invariants() -> None:
    secure_src = (
        ROOT / "android-tv/src/main/java/com/pilipala/marcomovie/SecureStorage.java"
    ).read_text(encoding="utf-8")
    dialog_src = (
        ROOT / "android-tv/src/main/java/com/pilipala/marcomovie/CloudSyncDialog.java"
    ).read_text(encoding="utf-8")

    if "SecretKeySpec" in secure_src or "FALLBACK_KEY" in secure_src:
        raise AssertionError("SecureStorage.java still contains a hardcoded fallback key")
    if ".apply()" in secure_src:
        raise AssertionError("SecureStorage.java must use commit() instead of apply()")
    if "cipher.init(Cipher.ENCRYPT_MODE, key)" not in secure_src:
        raise AssertionError("SecureStorage.java must call cipher.init(Cipher.ENCRYPT_MODE, key)")
    if "cipher.getIV()" not in secure_src:
        raise AssertionError("SecureStorage.java must read IV from cipher.getIV()")

    # Every SecureStorage.(getWebdavPass|setWebdavPass|clearWebdavPass) call in CloudSyncDialog
    # must occur inside a SYNC_EXEC.execute(...) lambda, never directly on the UI thread.
    call_pattern = re.compile(
        r"SecureStorage\.(getWebdavPass|setWebdavPass|clearWebdavPass)\s*\("
    )
    matches = list(call_pattern.finditer(dialog_src))
    if len(matches) < 4:
        raise AssertionError(
            f"Expected >= 4 SecureStorage WebDAV calls in CloudSyncDialog.java, got {len(matches)}"
        )
    for m in matches:
        window_start = max(0, m.start() - 600)
        preceding = dialog_src[window_start : m.start()]
        if "SYNC_EXEC.execute(" not in preceding:
            line_no = dialog_src.count("\n", 0, m.start()) + 1
            raise AssertionError(
                f"CloudSyncDialog.java:{line_no} calls {m.group(0)} outside SYNC_EXEC.execute"
            )
    print(f"PASS CloudSyncDialog thread-safety check ({len(matches)} SYNC_EXEC call sites)")


def run_jvm_checks() -> None:
    javac = str(JDK / "bin" / ("javac" + SUFFIX))
    java = str(JDK / "bin" / ("java" + SUFFIX))
    with tempfile.TemporaryDirectory(prefix="marcomovie-secure-storage-") as tmp:
        tmp_dir = Path(tmp)
        stub_dir = tmp_dir / "stubs"
        class_dir = tmp_dir / "classes"
        class_dir.mkdir(parents=True, exist_ok=True)
        for rel, content in STUBS.items():
            path = stub_dir / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")

        prod_sources = [
            ROOT / "android-tv/src/main/java/com/pilipala/marcomovie" / name
            for name in ("TvLayoutPolicy.java", "Prefs.java", "AppLog.java", "SecureStorage.java")
        ]
        sources = [
            *prod_sources,
            ROOT / "android-tv/tests/SecureStorageChecks.java",
            *sorted(stub_dir.rglob("*.java")),
        ]
        subprocess.run(
            [
                javac,
                "-encoding",
                "UTF-8",
                "-source",
                "8",
                "-target",
                "8",
                "-Xlint:-options",
                "-d",
                str(class_dir),
                *map(str, sources),
            ],
            check=True,
        )
        res = subprocess.run(
            [java, "-cp", str(class_dir), "com.pilipala.marcomovie.SecureStorageChecks"],
            text=True,
            encoding="utf-8",
            capture_output=True,
        )
        if res.stdout:
            print(res.stdout.rstrip())
        if res.stderr:
            print(res.stderr.rstrip())
        if res.returncode != 0:
            raise SystemExit(res.returncode)
        # Pin the exact check count so accidentally skipped or deleted checks fail CI;
        # update this number in lockstep whenever checks are added to or removed from SecureStorageChecks.java.
        assert "ALL PASS (47 checks)" in (res.stdout or ""), (
            f"Expected 'ALL PASS (47 checks)' in SecureStorageChecks output, got:\n{res.stdout}"
        )

        # Verify API 23 bytecode compatibility on compiled SecureStorage classes (no java.util.Base64,
        # java.util.function, or java.util.stream references).
        forbidden_Bytecode = (
            b"java/util/Base64",
            b"java/util/function/",
            b"java/util/stream/",
        )
        for cls_file in sorted((class_dir / "com/pilipala/marcomovie").glob("SecureStorage*.class")):
            if cls_file.name.startswith("SecureStorageChecks"):
                continue
            raw_cls = cls_file.read_bytes()
            for token in forbidden_Bytecode:
                if token in raw_cls:
                    raise AssertionError(
                        f"API 23 forbidden bytecode reference {token!r} in {cls_file.name}"
                    )
        print("PASS API 23 bytecode check on SecureStorage classes")

        # Optional Android SDK 35 compile verification when tools/android-35/android.jar exists
        android_jar = ROOT / "tools/android-35/android.jar"
        if android_jar.exists():
            sdk_classes = tmp_dir / "sdk-classes"
            sdk_classes.mkdir(parents=True, exist_ok=True)
            subprocess.run(
                [
                    javac,
                    "-encoding",
                    "UTF-8",
                    "-source",
                    "8",
                    "-target",
                    "8",
                    "-Xlint:-options",
                    "-classpath",
                    str(android_jar),
                    "-d",
                    str(sdk_classes),
                    *map(str, prod_sources),
                ],
                check=True,
            )
            print("PASS Android SDK 35 javac compile for SecureStorage")


if __name__ == "__main__":
    verify_source_invariants()
    run_jvm_checks()
