import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:media_projection_screenshot/media_projection_screenshot.dart';
import 'package:photo_manager/photo_manager.dart' as pm;
import 'engine.dart';
import 'llm.dart';
import 'recognizer.dart';
import 'overlay.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const App());
}

/// Overlay (floating button) ka entry point — plugin ke liye main.dart mein hona zaruri hai.
@pragma("vm:entry-point")
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: const OverlayRoot(),
  ));
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Chess Agent',
        theme: ThemeData(
          colorSchemeSeed: Colors.green,
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: const Home(),
      );
}

const _order = '.PNBRQKpnbrqk';
const _sym = {
  '.': '',
  'P': '♙',
  'N': '♘',
  'B': '♗',
  'R': '♖',
  'Q': '♕',
  'K': '♔',
  'p': '♟',
  'n': '♞',
  'b': '♝',
  'r': '♜',
  'q': '♛',
  'k': '♚'
};

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  final engine = Engine();
  final picker = ImagePicker();
  Templates? tpl;
  Uint8List? bytes;
  List<String> seen = List.filled(64, '.');
  bool whiteBottom = true, busy = false, hasBoard = false;
  bool? whiteToMove; // null = user ne abhi baari nahi batayi
  bool floatingOn = false;
  StreamSubscription? _overlaySub;
  List<Line> lines = [];
  String? note, why, fen;
  String key = '', model = 'anthropic/claude-3.5-haiku';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SharedPreferences.getInstance().then((p) {
      setState(() {
        key = p.getString('key') ?? '';
        model = p.getString('model') ?? model;
        final t = p.getString('tpl');
        if (t != null) tpl = Templates.decode(t);
      });
    });

    // Overlay se aane wala signal suno
    _overlaySub = FlutterOverlayWindow.overlayListener.listen(_onOverlayMsg);
    FlutterOverlayWindow.isActive().then((a) {
      if (mounted) setState(() => floatingOn = a);
    });
  }

  @override
  void dispose() {
    _overlaySub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // App foreground aayi to floating se aaya signal process ho sakta hai
  }

  // ---------------- Floating popup se aane wale kaam ----------------
  bool _overlayBusy = false;

  void _tell(String type, [Map<String, dynamic> extra = const {}]) {
    FlutterOverlayWindow.shareData(jsonEncode({'t': type, ...extra}));
  }

  void _status(String msg) => _tell('status', {'msg': msg});

  Future<void> _onOverlayMsg(dynamic raw) async {
    Map<String, dynamic> m;
    try {
      m = raw is String
          ? Map<String, dynamic>.from(jsonDecode(raw) as Map)
          : Map<String, dynamic>.from(raw as Map);
    } catch (_) {
      return;
    }
    if (m['t'] == 'analyze') {
      await _runFromOverlay(m['white'] == true, m['flip'] == true);
    } else if (m['t'] == 'closed') {
      if (mounted) setState(() => floatingOn = false);
    }
  }

  /// Gallery ka sabse naya screenshot (bina UI ke).
  Future<Uint8List> _latestScreenshot() async {
    final ps = await pm.PhotoManager.requestPermissionExtend();
    if (!ps.hasAccess) {
      throw 'Photos ki permission nahi hai. Chess Agent app kholo, Floating On karo aur "Allow all" do.';
    }
    final paths = await pm.PhotoManager.getAssetPathList(
      type: pm.RequestType.image,
      onlyAll: true,
      filterOption: pm.FilterOptionGroup()
        ..addOrderOption(pm.OrderOption(type: pm.OrderOptionType.createDate, asc: false)),
    );
    if (paths.isEmpty) throw 'Gallery mein koi screenshot nahi mila.';
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

  Future<void> _runFromOverlay(bool white, bool flip) async {
    if (_overlayBusy) return;
    _overlayBusy = true;
    try {
      _status('Screenshot dhoondh raha hoon...');
      if (tpl == null) {
        _tell('error', {'msg': 'Pehle Chess Agent app mein Calibrate karo (starting position ka screenshot).'});
        return;
      }
      final shot = await _latestScreenshot();

      _status('Board padh raha hoon...');
      await Future.delayed(const Duration(milliseconds: 80));
      final s = tpl!.scan(shot);
      var wb = _detectWhiteBottom(s) ?? true;
      if (flip) wb = !wb;
      final f = toFen(s, wb, white);
      if (mounted) {
        setState(() {
          seen = s;
          hasBoard = true;
          whiteBottom = wb;
          whiteToMove = white;
          fen = f;
          lines = [];
        });
      }
      final err = checkFen(f);
      if (err != null) {
        _tell('error', {
          'msg': '$err\n\nBoard ulta lage to "Board ulta" tick karke dobara try karo. '
              'Ya Chess Agent app mein board kholkar piece theek karo.'
        });
        return;
      }

      _status('Engine soch raha hai...');
      final r = await engine.analyse(f);
      if (r.isEmpty) {
        _tell('error', {'msg': 'Engine ne koi move nahi di. Dobara try karo.'});
        return;
      }
      if (mounted) setState(() => lines = r);
      final m = r.first.move;
      _tell('result', {
        'white': white,
        'san': san(f, m),
        'from': m.substring(0, 2),
        'to': m.substring(2, 4),
        'eval': r.first.score,
        'alts': r.skip(1).map((l) => '${san(f, l.move)}  (${l.score})').toList(),
      });
    } catch (e) {
      _tell('error', {'msg': e is String ? e : 'Masla aaya: $e'});
    } finally {
      _overlayBusy = false;
    }
  }

  Future<void> pick() async {
    if (tpl == null) {
      setState(() => note = 'Pehle Calibrate karo (starting position ka screenshot).');
      return;
    }
    final f = await picker.pickImage(source: ImageSource.gallery);
    if (f == null) return;
    bytes = await f.readAsBytes();
    setState(() {
      busy = true;
      note = null;
      why = null;
    });
    await Future.delayed(const Duration(milliseconds: 50));
    try {
      seen = tpl!.scan(bytes!);
      hasBoard = true;
      whiteBottom = _detectWhiteBottom(seen) ?? whiteBottom;
      whiteToMove = null;
      lines = [];
      fen = null;
      note = 'Board padh liya. Ab neeche batao kiski baari hai.';
    } catch (e) {
      note = 'Image padhne mein masla: $e';
    }
    setState(() => busy = false);
  }

  /// King ki jagah se board ka rukh pata karo: white king neeche wale aadhe mein = white neeche.
  bool? _detectWhiteBottom(List<String> s) {
    final wk = s.indexOf('K'), bk = s.indexOf('k');
    if (wk >= 0) return wk ~/ 8 >= 4;
    if (bk >= 0) return bk ~/ 8 < 4;
    return null;
  }

  Future<void> setTurn(bool white) async {
    setState(() => whiteToMove = white);
    await analyze();
  }

  Future<void> analyze() async {
    if (whiteToMove == null) {
      setState(() => note = 'Pehle batao kiski baari hai (White ya Black).');
      return;
    }
    fen = toFen(seen, whiteBottom, whiteToMove!);
    final err = checkFen(fen!);
    if (err != null) {
      setState(() {
        note = err;
        lines = [];
      });
      return;
    }
    setState(() {
      busy = true;
      note = null;
      why = null;
    });
    final r = await engine.analyse(fen!);
    setState(() {
      lines = r;
      busy = false;
    });
  }

  Future<void> whyTap() async {
    setState(() => busy = true);
    try {
      why = await explain(key, model, fen!, lines);
    } catch (e) {
      why = 'Error: $e';
    }
    setState(() => busy = false);
  }

  Future<void> calibrate() async {
    final t = await Navigator.push<Templates>(
        context, MaterialPageRoute(builder: (_) => Calibrate(initial: tpl?.rect)));
    if (t == null) return;
    final p = await SharedPreferences.getInstance();
    await p.setString('tpl', t.encode());
    setState(() {
      tpl = t;
      note = 'Calibration save ho gayi. Ab screenshot choose karo.';
    });
  }

  Future<void> settings() async {
    final k = TextEditingController(text: key), m = TextEditingController(text: model);
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Settings'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: k,
              decoration: const InputDecoration(labelText: 'OpenRouter API key'),
              obscureText: true),
          TextField(controller: m, decoration: const InputDecoration(labelText: 'Model')),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Save'))],
      ),
    );
    final p = await SharedPreferences.getInstance();
    await p.setString('key', k.text.trim());
    await p.setString('model', m.text.trim());
    setState(() {
      key = k.text.trim();
      model = m.text.trim();
    });
  }

  Future<void> toggleFloating() async {
    if (await FlutterOverlayWindow.isActive()) {
      await FlutterOverlayWindow.closeOverlay();
      setState(() => floatingOn = false);
      return;
    }

    // Permission check
    final granted = await FlutterOverlayWindow.isPermissionGranted();
    if (!granted) {
      final ok = await FlutterOverlayWindow.requestPermission();
      if (ok != true) {
        setState(() => note = 'Overlay permission nahi mili. Settings se "Display over other apps" allow karo.');
        return;
      }
    }

    // Popup screenshot gallery se khud uthata hai — uski permission abhi le lo
    final ps = await pm.PhotoManager.requestPermissionExtend();
    if (!ps.hasAccess) {
      setState(() => note = 'Photos ki permission do (Allow all), warna floating popup screenshot nahi padh payega.');
      return;
    }
    final limited = ps == pm.PermissionState.limited;
    // Screen-capture ki ek-baar permission (system dialog mein "Start now" dabana hai)
    MediaProjectionScreenshot().requestPermission();

    // Floating bubble start
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final px = (96 * dpr).round();
    await FlutterOverlayWindow.showOverlay(
      height: px,
      width: px,
      alignment: OverlayAlignment.topRight,
      enableDrag: true,
      overlayTitle: "Chess Agent",
      overlayContent: "Best move ke liye tap karo",
      flag: OverlayFlag.defaultFlag,
      positionGravity: PositionGravity.auto,
    );
    setState(() {
      floatingOn = true;
      note = limited
          ? 'Floating on, lekin Photos ki "Allow all" access do, warna naye screenshots nahi dikhenge.'
          : 'Floating on. Lichess kholo, screenshot lo (Power+Vol), phir ♟ bubble tap karo.';
    });
  }

  (int, int) _idx(String sq) {
    final n = (8 - int.parse(sq[1])) * 8 + (sq.codeUnitAt(0) - 97);
    return (n, 63 - n);
  }

  Widget boardView() {
    final hl = <int>{};
    if (lines.isNotEmpty) {
      final m = lines.first.move;
      for (final sq in [m.substring(0, 2), m.substring(2, 4)]) {
        final (a, b) = _idx(sq);
        hl.add(whiteBottom ? a : b);
      }
    }
    return AspectRatio(
      aspectRatio: 1,
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 8),
        itemCount: 64,
        itemBuilder: (_, i) {
          final dark = ((i ~/ 8) + (i % 8)) % 2 == 1;
          final bg = hl.contains(i)
              ? Colors.amber.shade600
              : (dark ? const Color(0xFF769656) : const Color(0xFFEEEED2));
          return GestureDetector(
            onTap: () {
              final c = _order.indexOf(seen[i]);
              setState(() => seen[i] = _order[(c + 1) % _order.length]);
            },
            child: Container(
              color: bg,
              alignment: Alignment.center,
              child: Text(_sym[seen[i]]!, style: const TextStyle(fontSize: 30, color: Colors.black)),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chess Agent'),
        actions: [
          IconButton(
            onPressed: toggleFloating,
            icon: Icon(floatingOn ? Icons.bubble_chart : Icons.bubble_chart_outlined),
            tooltip: floatingOn ? 'Floating band karo' : 'Floating button on karo',
          ),
          IconButton(onPressed: settings, icon: const Icon(Icons.settings)),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        // Floating status
        if (floatingOn)
          Card(
            color: Colors.green.shade900,
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Floating ♟ on hai. Lichess mein jab apni baari aaye → ♟ bubble tap karo. Screen khud capture hogi aur best move popup mein dikhegi.',
                style: TextStyle(fontSize: 13),
              ),
            ),
          ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
              child: FilledButton.icon(
                  onPressed: busy ? null : pick,
                  icon: const Icon(Icons.image),
                  label: const Text('Screenshot'))),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: busy ? null : calibrate, child: const Text('Calibrate')),
        ]),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: busy ? null : toggleFloating,
          icon: Icon(floatingOn ? Icons.stop_circle : Icons.play_circle),
          label: Text(floatingOn ? 'Floating Button Band Karo' : 'Floating Button On Karo'),
        ),
        if (note != null)
          Padding(
              padding: const EdgeInsets.all(8),
              child: Text(note!, style: const TextStyle(color: Colors.orangeAccent))),
        if (busy) const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator()),
        if (hasBoard) ...[
          const SizedBox(height: 12),
          boardView(),
          const Text(
              'Board mein galat piece ho to square par tap karke badlo, phir baari wala button dobara dabao. Board mein highlighted squares best move dikhate hain.',
              style: TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          const Text('Kiski baari hai? Tap karo:',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: whiteToMove == true
                  ? FilledButton.icon(
                      style: FilledButton.styleFrom(
                          backgroundColor: Colors.white, foregroundColor: Colors.black),
                      onPressed: busy ? null : () => setTurn(true),
                      icon: const Icon(Icons.circle_outlined),
                      label: const Text('White ki baari'))
                  : OutlinedButton.icon(
                      onPressed: busy ? null : () => setTurn(true),
                      icon: const Icon(Icons.circle_outlined),
                      label: const Text('White ki baari')),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: whiteToMove == false
                  ? FilledButton.icon(
                      style: FilledButton.styleFrom(
                          backgroundColor: Colors.black, foregroundColor: Colors.white),
                      onPressed: busy ? null : () => setTurn(false),
                      icon: const Icon(Icons.circle),
                      label: const Text('Black ki baari'))
                  : OutlinedButton.icon(
                      onPressed: busy ? null : () => setTurn(false),
                      icon: const Icon(Icons.circle),
                      label: const Text('Black ki baari')),
            ),
          ]),
          Wrap(spacing: 8, children: [
            ActionChip(
                label: const Text('Board ulta hai? Flip'),
                onPressed: busy
                    ? null
                    : () {
                        setState(() => whiteBottom = !whiteBottom);
                        if (whiteToMove != null) analyze();
                      }),
          ]),
        ],
        if (lines.isNotEmpty) ...[
          const SizedBox(height: 12),
          Card(
            color: Colors.green.shade800,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                const Text('♟', style: TextStyle(fontSize: 34)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Agli best move', style: TextStyle(fontSize: 13)),
                    Text(san(fen!, lines.first.move),
                        style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold)),
                    Text('${lines.first.move.substring(0, 2)} → ${lines.first.move.substring(2, 4)}   •   eval ${lines.first.score}',
                        style: const TextStyle(fontSize: 13)),
                  ]),
                ),
              ]),
            ),
          ),
          const Text('Doosri options', style: TextStyle(fontSize: 14)),
          for (final l in lines)
            ListTile(
              dense: true,
              leading: Text('${l.rank}', style: const TextStyle(fontSize: 18)),
              title: Text(san(fen!, l.move),
                  style: TextStyle(
                      fontSize: l.rank == 1 ? 22 : 16,
                      fontWeight: l.rank == 1 ? FontWeight.bold : FontWeight.normal)),
              subtitle: Text('eval ${l.score}  •  ${l.pv.take(4).join(' ')}'),
            ),
          FilledButton.tonal(onPressed: busy ? null : whyTap, child: const Text('Kyun?')),
          if (why != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(why!)),
        ],
      ]),
    );
  }
}

class Calibrate extends StatefulWidget {
  final BoardRect? initial;
  const Calibrate({super.key, this.initial});
  @override
  State<Calibrate> createState() => _CalibrateState();
}

class _CalibrateState extends State<Calibrate> {
  Uint8List? bytes;
  double w = 1, h = 1, x = 0, y = 0.2, s = 1;

  @override
  void initState() {
    super.initState();
    final r = widget.initial;
    if (r != null) {
      x = r.x;
      y = r.y;
      s = r.s;
    }
  }

  Future<void> load() async {
    final f = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (f == null) return;
    final b = await f.readAsBytes();
    final im = img.decodeImage(b)!;
    setState(() {
      bytes = b;
      w = im.width.toDouble();
      h = im.height.toDouble();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Calibrate')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        const Text(
            'Lichess par naya game shuru karo (starting position, White neeche), screenshot lo, yahan choose karo. '
            'Phir sliders se grid ko board par bilkul fit karo.'),
        const SizedBox(height: 8),
        FilledButton(onPressed: load, child: const Text('Starting position screenshot choose karo')),
        if (bytes != null) ...[
          const SizedBox(height: 8),
          AspectRatio(
            aspectRatio: w / h,
            child: Stack(fit: StackFit.expand, children: [
              Image.memory(bytes!, fit: BoxFit.fill),
              CustomPaint(painter: _Grid(x, y, s)),
            ]),
          ),
          Text('Left'),
          Slider(value: x, min: 0, max: 0.3, onChanged: (v) => setState(() => x = v)),
          Text('Top'),
          Slider(value: y, min: 0, max: 1, onChanged: (v) => setState(() => y = v)),
          Text('Size'),
          Slider(value: s, min: 0.5, max: 1.0, onChanged: (v) => setState(() => s = v)),
          FilledButton(
            onPressed: () {
              try {
                Navigator.pop(context, Templates.calibrate(bytes!, BoardRect(x, y, s)));
              } catch (e) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text('Calibration fail: $e')));
              }
            },
            child: const Text('Save'),
          ),
        ],
      ]),
    );
  }
}

class _Grid extends CustomPainter {
  final double x, y, s;
  _Grid(this.x, this.y, this.s);
  @override
  void paint(Canvas c, Size size) {
    final p = Paint()
      ..color = Colors.redAccent
      ..strokeWidth = 1;
    final l = x * size.width, t = y * size.height, side = s * size.width;
    for (var i = 0; i <= 8; i++) {
      c.drawLine(Offset(l + i * side / 8, t), Offset(l + i * side / 8, t + side), p);
      c.drawLine(Offset(l, t + i * side / 8), Offset(l + side, t + i * side / 8), p);
    }
  }

  @override
  bool shouldRepaint(_Grid o) => o.x != x || o.y != y || o.s != s;
}
