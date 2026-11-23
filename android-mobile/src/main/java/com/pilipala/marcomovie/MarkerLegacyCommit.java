package com.pilipala.marcomovie;

import android.content.SharedPreferences;
import java.io.IOException;

final class MarkerLegacyCommit {
    static void clear(SharedPreferences capturedPrefs) throws IOException {
        MarkerClearTask.requireWorker();
        if (!capturedPrefs.edit().remove(Prefs.VIDEO_SKIP_RECORDS).commit())
            throw new IOException("旧记录写盘未确认，请重新检查");
    }
}
