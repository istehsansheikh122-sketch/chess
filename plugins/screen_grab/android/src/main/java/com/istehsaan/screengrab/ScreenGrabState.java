package com.istehsaan.screengrab;

import android.os.Handler;
import android.os.Looper;

import io.flutter.plugin.common.MethodChannel;

/** Process-wide shared state (main engine aur overlay engine dono ek hi process mein hain). */
final class ScreenGrabState {
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static MethodChannel.Result pending;
    static volatile String lastError = "";

    private ScreenGrabState() {}

    static synchronized void setPending(MethodChannel.Result r) {
        if (pending != null) {
            final MethodChannel.Result old = pending;
            MAIN.post(() -> old.success(false));
        }
        pending = r;
    }

    static synchronized void complete(final boolean ok, String error) {
        lastError = error == null ? "" : error;
        final MethodChannel.Result r = pending;
        pending = null;
        if (r == null) return;
        MAIN.post(() -> r.success(ok));
    }
}
