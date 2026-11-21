import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

/// Floating bubble jo doosri apps ke upar dikhta hai.
/// Tap karne par main app ko "analyze" signal bhejta hai.
@pragma("vm:entry-point")
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: OverlayBubble(),
  ));
}

class OverlayBubble extends StatefulWidget {
  const OverlayBubble({super.key});
  @override
  State<OverlayBubble> createState() => _OverlayBubbleState();
}

class _OverlayBubbleState extends State<OverlayBubble> {
  bool busy = false;

  Future<void> onTap() async {
    if (busy) return;
    setState(() => busy = true);
    // Main app ko signal bhejo ke ab analyse karo
    await FlutterOverlayWindow.shareData("analyze");
    // Thodi der baad bubble ko thoda chhota feel do
    await Future.delayed(const Duration(milliseconds: 400));
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
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
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    "♟",
                    style: TextStyle(fontSize: 32),
                  ),
          ),
        ),
      ),
    );
  }
}
