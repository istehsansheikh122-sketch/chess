import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:image/image.dart' as img;
import 'package:media_projection_screenshot/media_projection_screenshot.dart';
import 'package:photo_manager/photo_manager.dart' as pm;
import 'package:shared_preferences/shared_preferences.dart';
import 'engine.dart';
import 'recognizer.dart';

/// Floating popup (overlay). Bubble tap = poora kaam:
/// panel chhupao -> screen capture -> board padho -> engine -> panel mein best move.
/// NOTE: overlayMain() main.dart mein hai (plugin ki shart).
enum _Phase { idle, loading, result, error }

/// Board padhna alag thread par. Top-level function hai taake widget/State
/// closure ke saath isolate ko na bheja jaye.
Future<List<String>> scanInBackground(String tplJson, Uint8List bytes) {
  return Isolate.run(() => Templates.decode(tplJson).scan(bytes));
}

/// MediaProjection se aayi raw RGBA pixels ko JPEG banao (alag thread par).
Future<Uint8List> rawToJpg(Uint8List raw, int w, int h, int rowStride) {
  return Isolate.run(() {
    final im = img.Image.fromBytes(
      width: w,
      height: h,
      bytes: raw.buffer,
      rowStride: rowStride > 0 ? rowStride : w * 4,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    return Uint8List.fromList(img.encodeJpg(im, quality: 92));
  });
}

bool _looksLikeImageFile(Uint8List b) {
  if (b.length < 4) return false;
  final png = b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;
  final jpg = b[0] == 0xFF && b[1] == 0xD8;
  return png || jpg;
}

class OverlayRoot extends StatefulWidget {
  const OverlayRoot({super.key});
  @override
  State<OverlayRoot> createState() => _OverlayRootState();
}

class _OverlayRootState extends State<OverlayRoot> {
  bool expanded = false;
  bool running = false;
  bool flip = false;
  _Phase phase = _Phase.idle;
  String status = '';
  String errorMsg = '';
  String captureNote = '';
  Map<String, dynamic>? result;
  final Engine engine = Engine();
  final MediaProjectionScreenshot _projection = MediaProjectionScreenshot();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _setSize(96, 96));
  }

  /// Window ka size set karo. Plugin dp lega ya px, ye device par check karke theek kar leta hai.
  Future<void> _setSize(int w, int h, {bool drag = true}) async {
    try {
      final view = PlatformDispatcher.instance.views.first;
      final dpr = view.devicePixelRatio;
      await FlutterOverlayWindow.resizeOverlay(w, h, drag);
      await Future.delayed(const Duration(milliseconds: 350));
      final logicalW = view.physicalSize.width / dpr;
      if (logicalW < w * 0.75) {
        await FlutterOverlayWindow.resizeOverlay((w * dpr).round(), (h * dpr).round(), drag);
      }
    } catch (_) {}
  }

  Future<void> _expand() async {
    if (expanded) return;
    double sw = 360;
    try {
      final s = await FlutterOverlayWindow.getScreenSize();
      sw = s.x.toDouble();
    } catch (_) {}
    final w = (sw - 16).clamp(260.0, 340.0).round();
    await _setSize(w, 460, drag: false);
    if (mounted) setState(() => expanded = true);
  }

  Future<void> _collapse() async {
    if (mounted) setState(() => expanded = false);
    await _setSize(96, 96);
  }

  void _setStatus(String s) {
    if (mounted) {
      setState(() {
        phase = _Phase.loading;
        status = s;
      });
    }
  }

  void _fail(String msg) {
    if (mounted) {
      setState(() {
        phase = _Phase.error;
        errorMsg = msg;
      });
    }
  }

  // ---------------- Screen lena ----------------

  /// Pehle auto screen-capture (MediaProjection). Na chale to gallery ka naya screenshot.
  Future<Uint8List> _grabScreen() async {
    captureNote = '';
    try {
      final d = PlatformDispatcher.instance.views.first.display;
      final w = d.size.width.round(), h = d.size.height.round();
      final r = await _projection
          .takeCapture(x: 0, y: 0, width: w, height: h)
          .timeout(const Duration(seconds: 8));
      if (r != null && r.bytes.isNotEmpty) {
        if (_looksLikeImageFile(r.bytes)) return r.bytes;
        return await rawToJpg(r.bytes, r.width, r.height, r.rowStride);
      }
      captureNote = 'Auto-capture se kuch nahi mila, gallery screenshot use hua.';
    } catch (e) {
      captureNote = 'Auto-capture nahi hua ($e). Gallery ka naya screenshot use hua.';
    }
    return _latestScreenshot();
  }

  /// Gallery ka sabse naya screenshot (bina UI ke).
  Future<Uint8List> _latestScreenshot() async {
    final paths = await pm.PhotoManager.getAssetPathList(
      type: pm.RequestType.image,
      onlyAll: true,
      filterOption: pm.FilterOptionGroup()
        ..addOrderOption(pm.OrderOption(type: pm.OrderOptionType.createDate, asc: false)),
    );
    if (paths.isEmpty) {
      throw 'Gallery se koi photo nahi mili. Chess Agent app mein Photos ki "Allow all" permission do.';
    }
    final list = await paths.first.getAssetListRange(start: 0, end: 1);
    if (list.isEmpty) throw 'Gallery mein koi screenshot nahi mila.';
    final a = list.first;
    final age = DateTime.now().difference(a.createDateTime);
    if (age.inMinutes >= 3) {
      throw 'Auto-capture nahi chala aur gallery ka sabse naya screenshot ${age.inMinutes} minute purana hai. '
          'App mein "Floating Button On" karte waqt screen-capture ka "Start now" allow karo.';
    }
    final bytes = await a.originBytes;
    if (bytes == null) throw 'Screenshot khul nahi saka.';
    return bytes;
  }

  bool? _detectWhiteBottom(List<String> s) {
    final wk = s.indexOf('K'), bk = s.indexOf('k');
    if (wk >= 0) return wk ~/ 8 >= 4;
    if (bk >= 0) return bk ~/ 8 < 4;
    return null;
  }

  // ---------------- Poora kaam ----------------

  /// opponent=false: meri (neeche wali side ki) baari. true: opponent ki baari.
  Future<void> _run({bool opponent = false}) async {
    if (running) return;
    if (mounted) setState(() => running = true);
    var stage = 'shuru';
    try {
      stage = 'calibration load';
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final ts = prefs.getString('tpl');
      if (ts == null) {
        await _expand();
        _fail('Pehle Chess Agent app mein Calibrate karo (starting position ka screenshot).');
        return;
      }

      // Panel board ko dhak leta hai, isliye capture se pehle chhupao.
      if (expanded) await _collapse();
      await Future.delayed(const Duration(milliseconds: 250));

      stage = 'screen capture';
      final shot = await _grabScreen();

      await _expand();
      stage = 'board padhna';
      _setStatus('Board padh raha hoon...');
      await Future.delayed(const Duration(milliseconds: 80));
      final seen = await scanInBackground(ts, shot);
      var wb = _detectWhiteBottom(seen) ?? true;
      if (flip) wb = !wb;
      final white = opponent ? !wb : wb; // neeche wali side meri hai
      final f = toFen(seen, wb, white);
      final err = checkFen(f);
      if (err != null) {
        _fail('$err\n\nBoard ulta lage to neeche "Board ulta" tick karke dobara try karo.');
        return;
      }

      stage = 'engine';
      _setStatus('Engine soch raha hai...');
      final r = await engine.analyse(f).timeout(const Duration(seconds: 30));
      if (r.isEmpty) {
        _fail('Engine ne koi move nahi di. Dobara try karo.');
        return;
      }
      final m = r.first.move;
      if (!mounted) return;
      setState(() {
        phase = _Phase.result;
        result = {
          'white': white,
          'info': '${wb ? 'White' : 'Black'} neeche${opponent ? ' • opponent ki baari' : ''}',
          'san': san(f, m),
          'from': m.substring(0, 2),
          'to': m.substring(2, 4),
          'eval': r.first.score,
          'alts': r.skip(1).map((l) => '${san(f, l.move)}  (${l.score})').toList(),
        };
      });
    } catch (e) {
      try {
        await _expand();
      } catch (_) {}
      _fail('[$stage] ${e is String ? e : e.toString()}');
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  Future<void> _close() async {
    try {
      await FlutterOverlayWindow.shareData(jsonEncode({'t': 'closed'}));
    } catch (_) {}
    await FlutterOverlayWindow.closeOverlay();
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: expanded ? _panel() : _bubble(),
    );
  }

  Widget _bubble() {
    return Center(
      child: GestureDetector(
        onTap: running ? null : () => _run(),
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: running ? Colors.orange.shade700 : Colors.green.shade700,
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
            child: running
                ? const SizedBox(
                    width: 30,
                    height: 30,
                    child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white))
                : const Text('♟', style: TextStyle(fontSize: 32, color: Colors.white)),
          ),
        ),
      ),
    );
  }

  Widget _panel() {
    return Container(
      margin: const EdgeInsets.all(4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xF212201A),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white24),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(color: Colors.white, fontSize: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Text('♟ Chess Agent',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: running ? null : _collapse,
                  icon: const Icon(Icons.remove, color: Colors.white)),
              IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: _close,
                  icon: const Icon(Icons.close, color: Colors.white)),
            ]),
            const Divider(color: Colors.white24, height: 8),
            const SizedBox(height: 6),
            Expanded(child: SingleChildScrollView(child: _body())),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    switch (phase) {
      case _Phase.loading:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 36),
          child: Center(
            child: Column(children: [
              const SizedBox(
                  width: 46,
                  height: 46,
                  child: CircularProgressIndicator(strokeWidth: 4, color: Colors.greenAccent)),
              const SizedBox(height: 16),
              Text(status, textAlign: TextAlign.center, style: const TextStyle(fontSize: 15)),
            ]),
          ),
        );
      case _Phase.result:
        return _resultView();
      case _Phase.error:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(errorMsg, style: const TextStyle(color: Colors.orangeAccent, fontSize: 14)),
          const SizedBox(height: 14),
          _actions(),
        ]);
      case _Phase.idle:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Lichess par apni baari aaye to bas ♟ bubble tap karo.',
              style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 14),
          _actions(),
        ]);
    }
  }

  Widget _actions() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: running ? null : () => _run(),
            icon: const Icon(Icons.bolt),
            label: const Text('Best move'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
            onPressed: running ? null : () => _run(opponent: true),
            child: const Text('Opponent ki baari', textAlign: TextAlign.center),
          ),
        ),
      ]),
      InkWell(
        onTap: () => setState(() => flip = !flip),
        child: Row(children: [
          Checkbox(value: flip, onChanged: (v) => setState(() => flip = v ?? false)),
          const Expanded(
              child: Text('Board ulta (galat padha jaye to tick karo)',
                  style: TextStyle(fontSize: 12, color: Colors.white70))),
        ]),
      ),
    ]);
  }

  Widget _resultView() {
    final r = result ?? {};
    final alts = (r['alts'] as List?) ?? const [];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: Colors.green.shade800, borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(r['white'] == true ? 'White ki best move' : 'Black ki best move',
              style: const TextStyle(fontSize: 13)),
          Text('${r['san']}',
              style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold)),
          Text('${r['from']} → ${r['to']}   •   eval ${r['eval']}',
              style: const TextStyle(fontSize: 13)),
          Text('${r['info']}', style: const TextStyle(fontSize: 11, color: Colors.white70)),
        ]),
      ),
      if (alts.isNotEmpty) ...[
        const SizedBox(height: 10),
        const Text('Doosri options:', style: TextStyle(fontSize: 12, color: Colors.white70)),
        for (final a in alts) Text('• $a', style: const TextStyle(fontSize: 14)),
      ],
      if (captureNote.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(captureNote, style: const TextStyle(fontSize: 11, color: Colors.orangeAccent)),
      ],
      const SizedBox(height: 10),
      _actions(),
    ]);
  }
}
