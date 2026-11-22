import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

/// Floating bubble jo doosri apps ke upar dikhta hai.
/// NOTE: overlayMain() ab main.dart mein hai (plugin ki shart).
class OverlayBubble extends StatefulWidget {
  const OverlayBubble({super.key});
  @override
  State<OverlayBubble> createState() => _OverlayBubbleState();
}

class _OverlayBubbleState extends State<OverlayBubble> {
  bool busy = false;

  Future<void> _openMainApp() async {
    try {
      const intent = AndroidIntent(
        action: 'android.intent.action.MAIN',
        category: 'android.intent.category.LAUNCHER',
        package: 'com.istehsaan.chess_agent',
        componentName: 'com.istehsaan.chess_agent.MainActivity',
        flags: <int>[
          Flag.FLAG_ACTIVITY_NEW_TASK,
          Flag.FLAG_ACTIVITY_REORDER_TO_FRONT,
        ],
      );
      await intent.launch();
    } catch (_) {
      // Agar overlay se app open na ho sake to bhi signal bhej denge.
    }
  }

  Future<void> onTap() async {
    if (busy) return;
    setState(() => busy = true);
    await _openMainApp();
    await Future.delayed(const Duration(milliseconds: 700));
    await FlutterOverlayWindow.shareData("analyze");
    await Future.delayed(const Duration(milliseconds: 400));
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Center(
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: busy ? Colors.orange.shade700 : Colors.green.shade700,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.4),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
              border: Border.all(color: Colors.white70, width: 2),
            ),
            child: Center(
              child: busy
                  ? const SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                    )
                  : const Text("♟", style: TextStyle(fontSize: 32, color: Colors.white)),
            ),
          ),
        ),
      ),
    );
  }
}
