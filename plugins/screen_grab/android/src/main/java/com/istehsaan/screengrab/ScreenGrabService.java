package com.istehsaan.screengrab;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.graphics.Bitmap;
import android.graphics.PixelFormat;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.Image;
import android.media.ImageReader;
import android.media.projection.MediaProjection;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.util.DisplayMetrics;
import android.view.Display;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;

/**
 * Foreground service: ek baar MediaProjection + ek VirtualDisplay chalu rakhta hai aur
 * hamesha sabse naya frame hold karta hai. Capture = us frame ko JPEG banana.
 * (Android 14+ mein ek projection par bar-bar VirtualDisplay banana allowed nahi, isliye ek hi rakha.)
 */
public class ScreenGrabService extends Service {
    private static final String CHANNEL = "screen_grab_channel";
    private static final int NOTIF_ID = 7312;
    private static final Object LOCK = new Object();
    private static volatile boolean running = false;
    private static Image latest;

    private MediaProjection projection;
    private VirtualDisplay vdisplay;
    private ImageReader reader;
    private HandlerThread thread;
    private Handler handler;

    static boolean isRunning() {
        return running;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null) {
            stopSelf();
            return START_NOT_STICKY;
        }
        try {
            startForegroundNow();

            int code = intent.getIntExtra("code", 0);
            Intent data = intent.getParcelableExtra("data");
            MediaProjectionManager mpm =
                    (MediaProjectionManager) getSystemService(Context.MEDIA_PROJECTION_SERVICE);
            projection = mpm.getMediaProjection(code, data);
            if (projection == null) {
                throw new IllegalStateException("MediaProjection null mila");
            }

            thread = new HandlerThread("screen_grab");
            thread.start();
            handler = new Handler(thread.getLooper());

            // Android 14+: createVirtualDisplay se pehle callback register karna zaruri hai
            projection.registerCallback(new MediaProjection.Callback() {
                @Override
                public void onStop() {
                    cleanup();
                }
            }, handler);

            DisplayMetrics m = new DisplayMetrics();
            DisplayManager dm = (DisplayManager) getSystemService(Context.DISPLAY_SERVICE);
            Display d = dm.getDisplay(Display.DEFAULT_DISPLAY);
            d.getRealMetrics(m);
            final int w = m.widthPixels;
            final int h = m.heightPixels;
            final int dpi = m.densityDpi;

            reader = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 3);
            reader.setOnImageAvailableListener(new ImageReader.OnImageAvailableListener() {
                @Override
                public void onImageAvailable(ImageReader r) {
                    Image img = null;
                    try {
                        img = r.acquireLatestImage();
                    } catch (Exception e) {
                        img = null;
                    }
                    if (img == null) return;
                    synchronized (LOCK) {
                        if (latest != null) {
                            try {
                                latest.close();
                            } catch (Exception ignored) {
                            }
                        }
                        latest = img;
                    }
                }
            }, handler);

            vdisplay = projection.createVirtualDisplay(
                    "screen_grab", w, h, dpi,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                    reader.getSurface(), null, handler);

            running = true;
            ScreenGrabState.complete(true, "");
        } catch (Exception e) {
            ScreenGrabState.complete(false, "Service: " + e);
            cleanup();
            stopSelf();
        }
        return START_NOT_STICKY;
    }

    private void startForegroundNow() {
        NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        Notification.Builder b;
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel ch =
                    new NotificationChannel(CHANNEL, "Screen capture", NotificationManager.IMPORTANCE_LOW);
            nm.createNotificationChannel(ch);
            b = new Notification.Builder(this, CHANNEL);
        } else {
            b = new Notification.Builder(this);
        }
        Notification n = b.setContentTitle("Chess Agent")
                .setContentText("Screen capture on hai (best move ke liye)")
                .setSmallIcon(android.R.drawable.ic_menu_camera)
                .setOngoing(true)
                .build();
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION);
        } else {
            startForeground(NOTIF_ID, n);
        }
    }

    private synchronized void cleanup() {
        running = false;
        try {
            if (vdisplay != null) vdisplay.release();
        } catch (Exception ignored) {
        }
        vdisplay = null;
        try {
            if (reader != null) reader.close();
        } catch (Exception ignored) {
        }
        reader = null;
        synchronized (LOCK) {
            if (latest != null) {
                try {
                    latest.close();
                } catch (Exception ignored) {
                }
                latest = null;
            }
        }
        MediaProjection p = projection;
        projection = null;
        try {
            if (p != null) p.stop();
        } catch (Exception ignored) {
        }
        if (thread != null) {
            thread.quitSafely();
            thread = null;
        }
    }

    @Override
    public void onDestroy() {
        cleanup();
        super.onDestroy();
    }

    /** Sabse naye frame ko JPEG bytes mein badlo (null = abhi koi frame nahi). */
    static byte[] captureJpeg() {
        synchronized (LOCK) {
            if (latest == null) return null;
            Image img = latest;
            Image.Plane plane = img.getPlanes()[0];
            ByteBuffer buf = plane.getBuffer();
            buf.rewind();
            int pixelStride = plane.getPixelStride();
            int rowStride = plane.getRowStride();
            int w = img.getWidth();
            int h = img.getHeight();
            int bmpW = rowStride / pixelStride;
            Bitmap bmp = Bitmap.createBitmap(bmpW, h, Bitmap.Config.ARGB_8888);
            bmp.copyPixelsFromBuffer(buf);
            Bitmap out = (bmpW != w) ? Bitmap.createBitmap(bmp, 0, 0, w, h) : bmp;
            ByteArrayOutputStream bos = new ByteArrayOutputStream(1 << 20);
            out.compress(Bitmap.CompressFormat.JPEG, 95, bos);
            if (out != bmp) out.recycle();
            bmp.recycle();
            return bos.toByteArray();
        }
    }
}
