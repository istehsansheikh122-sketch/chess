import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:photo_manager/photo_manager.dart' as pm;
import 'package:shared_preferences/shared_preferences.dart';
import 'engine.dart';
import 'recognizer.dart';

/// Floating popup (overlay). Collapsed = chhota ♟ bubble, tap par bada panel khulta hai:
/// baari chuno -> "Best move batao" -> loading -> move isi panel mein.
/// NOTE: overlayMain() main.dart mein hai (plugin ki shart).
enum _Phase { idle, loading, result, error }

class OverlayRoot extends StatefulWidget {
  const OverlayRoot({super.key});
  @override
  State<OverlayRoot> createState() => _OverlayRootState();
}

class _OverlayRootState extends State<OverlayRoot> {
  bool expanded = false;
  bool? whiteTurn;
  bool flip = false;
  _Phase phase = _Phase.idle;
  String status = '';
  String errorMsg = '';
  Map<String, dynamic>? result;
  final Engine engine = Engine();
  bool _running = false;

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
    double sw = 360;
    try {
      final s = await FlutterOverlayWindow.getScreenSize();
      sw = s.x.toDouble();
    } catch (_) {}
    final w = (sw - 16).clamp(260.0, 340.0).round();
    await _setSize(w, 440, drag: false);
    if (mounted) setState(() => expanded = true);
  }

  Future<void> _collapse() async {
    if (mounted) setState(() => expanded = false);
    await _setSize(96, 96);
  }

  // ---------------- Poora kaam isi popup ke andar (main app ki zarurat nahi) ----------------

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
      throw 'Sabse naya screenshot ${age.inMinutes} minute purana hai. '
          'Pehle naya screenshot lo (Power+Vol), phir dobara dabao. '
          'Agar abhi liya tha to Photos ki "Allow all" permission check karo.';
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

  Future<void> _start() async {
    if (whiteTurn == null || _running) return;
    _running = true;
    final white = whiteTurn!;
    var stage = 'shuru';
    try {
      _setStatus('Screenshot dhoondh raha hoon...');

      stage = 'calibration load';
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final ts = prefs.getString('tpl');
      if (ts == null) {
        _fail('Pehle Chess Agent app mein Calibrate karo (starting position ka screenshot).');
        return;
      }
      final tpl = Templates.decode(ts);

      stage = 'screenshot dhoondhna';
      final shot = await _latestScreenshot();

      stage = 'board padhna';
      _setStatus('Board padh raha hoon...');
      await Future.delayed(const Duration(milliseconds: 80));
      final seen = await Isolate.run(() => tpl.scan(shot));
      var wb = _detectWhiteBottom(seen) ?? true;
      if (flip) wb = !wb;
      final f = toFen(seen, wb, white);
      final err = checkFen(f);
      if (err != null) {
        _fail('$err\n\nBoard ulta lage to "Board ulta" tick karke dobara try karo.');
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
          'san': san(f, m),
          'from': m.substring(0, 2),
          'to': m.substring(2, 4),
          'eval': r.first.score,
          'alts': r.skip(1).map((l) => '${san(f, l.move)}  (${l.score})').toList(),
        };
      });
    } catch (e) {
      _fail('[$stage] ${e is String ? e : e.toString()}');
    } finally {
      _running = false;
    }
  }

  Future<void> _close() async {
    try {
      await FlutterOverlayWindow.shareData(jsonEncode({'t': 'closed'}));
    } catch (_) {}
    await FlutterOverlayWindow.closeOverlay();
  }

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
        onTap: _expand,
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.green.shade700,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.4),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
            border: Border.all(color: Colors.white70, width: 2),
          ),
          child: const Center(
            child: Text('♟', style: TextStyle(fontSize: 32, color: Colors.white)),
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
                  onPressed: _collapse,
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
          SizedBox(
            width: double.infinity,
            child: FilledButton(
                onPressed: () => setState(() => phase = _Phase.idle),
                child: const Text('Dobara try karo')),
          ),
        ]);
      case _Phase.idle:
        return _setupView();
    }
  }

  Widget _setupView() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text(
          '1) Lichess ka screenshot lo (Power+Vol)\n2) Baari chuno\n3) Neeche button dabao',
          style: TextStyle(fontSize: 13, color: Colors.white70)),
      const SizedBox(height: 12),
      const Text('Kiski baari hai?', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      Row(children: [
        Expanded(child: _turnBtn(true)),
        const SizedBox(width: 8),
        Expanded(child: _turnBtn(false)),
      ]),
      const SizedBox(height: 4),
      InkWell(
        onTap: () => setState(() => flip = !flip),
        child: Row(children: [
          Checkbox(value: flip, onChanged: (v) => setState(() => flip = v ?? false)),
          const Expanded(
              child: Text('Board ulta padha jaye to tick karo',
                  style: TextStyle(fontSize: 12, color: Colors.white70))),
        ]),
      ),
      const SizedBox(height: 6),
      SizedBox(
        width: double.infinity,
        height: 48,
        child: FilledButton.icon(
          onPressed: whiteTurn == null ? null : _start,
          icon: const Icon(Icons.bolt),
          label: const Text('Best move batao', style: TextStyle(fontSize: 16)),
        ),
      ),
    ]);
  }

  Widget _turnBtn(bool white) {
    final selected = whiteTurn == white;
    final label = Text(white ? 'White' : 'Black');
    if (selected) {
      return FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: white ? Colors.white : Colors.black,
          foregroundColor: white ? Colors.black : Colors.white,
          side: const BorderSide(color: Colors.greenAccent, width: 2),
        ),
        onPressed: () => setState(() => whiteTurn = white),
        child: label,
      );
    }
    return OutlinedButton(
      style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
      onPressed: () => setState(() => whiteTurn = white),
      child: label,
    );
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
        ]),
      ),
      if (alts.isNotEmpty) ...[
        const SizedBox(height: 10),
        const Text('Doosri options:', style: TextStyle(fontSize: 12, color: Colors.white70)),
        for (final a in alts) Text('• $a', style: const TextStyle(fontSize: 14)),
      ],
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
          onPressed: () => setState(() => phase = _Phase.idle),
          icon: const Icon(Icons.refresh),
          label: const Text('Naya screenshot / agli baari'),
        ),
      ),
    ]);
  }
}
