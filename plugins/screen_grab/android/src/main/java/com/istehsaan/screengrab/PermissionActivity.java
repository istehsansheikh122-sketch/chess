package com.istehsaan.screengrab;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.Bundle;

/** Transparent activity: MediaProjection ka system dialog dikhata hai. */
public class PermissionActivity extends Activity {
    private static final int REQ = 7311;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        if (savedInstanceState != null) {
            return; // activity dobara bani (rotation) - dialog pehle se chal raha hai
        }
        try {
            MediaProjectionManager mpm =
                    (MediaProjectionManager) getSystemService(Context.MEDIA_PROJECTION_SERVICE);
            startActivityForResult(mpm.createScreenCaptureIntent(), REQ);
        } catch (Exception e) {
            ScreenGrabState.complete(false, "PermissionActivity: " + e);
            finish();
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQ && resultCode == RESULT_OK && data != null) {
            Intent svc = new Intent(this, ScreenGrabService.class);
            svc.putExtra("code", resultCode);
            svc.putExtra("data", data);
            try {
                if (Build.VERSION.SDK_INT >= 26) {
                    startForegroundService(svc);
                } else {
                    startService(svc);
                }
            } catch (Exception e) {
                ScreenGrabState.complete(false, "Service start: " + e);
            }
        } else {
            ScreenGrabState.complete(false, "Screen capture permission nahi di gayi");
        }
        finish();
    }
}
