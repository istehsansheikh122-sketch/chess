package com.istehsaan.screengrab;

import android.content.Context;
import android.content.Intent;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

public class ScreenGrabPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
    private MethodChannel channel;
    private Context ctx;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        ctx = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "screen_grab");
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        if (channel != null) channel.setMethodCallHandler(null);
        channel = null;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull final MethodChannel.Result result) {
        switch (call.method) {
            case "isReady":
                result.success(ScreenGrabService.isRunning());
                break;
            case "lastError":
                result.success(ScreenGrabState.lastError);
                break;
            case "requestPermission":
                if (ScreenGrabService.isRunning()) {
                    result.success(true);
                    break;
                }
                ScreenGrabState.setPending(result);
                try {
                    Intent i = new Intent(ctx, PermissionActivity.class);
                    i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    ctx.startActivity(i);
                } catch (Exception e) {
                    ScreenGrabState.complete(false, "Activity start: " + e);
                }
                break;
            case "capture": {
                final Handler main = new Handler(Looper.getMainLooper());
                new Thread(new Runnable() {
                    @Override
                    public void run() {
                        byte[] bytes = null;
                        String err = null;
                        try {
                            bytes = ScreenGrabService.captureJpeg();
                        } catch (Throwable t) {
                            err = String.valueOf(t);
                        }
                        final byte[] outBytes = bytes;
                        final String outErr = err;
                        main.post(new Runnable() {
                            @Override
                            public void run() {
                                if (outErr != null) {
                                    result.error("CAPTURE", outErr, null);
                                } else {
                                    result.success(outBytes);
                                }
                            }
                        });
                    }
                }).start();
                break;
            }
            case "stop":
                ctx.stopService(new Intent(ctx, ScreenGrabService.class));
                result.success(true);
                break;
            default:
                result.notImplemented();
        }
    }
}
