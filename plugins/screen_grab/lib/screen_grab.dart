import 'dart:typed_data';
import 'package:flutter/services.dart';

/// Screen capture (MediaProjection). Main app aur overlay, dono isolate se chalta hai
/// (native state process-wide shared hai).
class ScreenGrab {
  static const MethodChannel _ch = MethodChannel('screen_grab');

  /// System dialog dikhata hai ("Start now"). true = capture chalu.
  static Future<bool> requestPermission() async {
    final r = await _ch.invokeMethod('requestPermission').timeout(const Duration(seconds: 90));
    return r == true;
  }

  static Future<bool> isReady() async => (await _ch.invokeMethod('isReady')) == true;

  /// Latest screen frame JPEG bytes (null agar abhi koi frame nahi).
  static Future<Uint8List?> capture() => _ch.invokeMethod<Uint8List>('capture');

  static Future<String> lastError() async => '${await _ch.invokeMethod('lastError') ?? ''}';

  static Future<void> stop() async {
    await _ch.invokeMethod('stop');
  }
}
