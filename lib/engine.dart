import 'dart:async';
import 'package:dartchess/dartchess.dart';
import 'package:stockfish/stockfish.dart';

class Line {
  final int rank;
  final String score;
  final List<String> pv;
  Line(this.rank, this.score, this.pv);
  String get move => pv.first;
}

/// null = FEN theek hai, warna error message
String? checkFen(String fen) {
  try {
    Chess.fromSetup(Setup.parseFen(fen));
    return null;
  } catch (e) {
    return 'Position valid nahi lagti (king/pieces galat padhe gaye?). Square tap karke theek karo.';
  }
}

String san(String fen, String uci) {
  try {
    final pos = Chess.fromSetup(Setup.parseFen(fen));
    final m = Move.parse(uci);
    if (m == null) return uci;
    return pos.makeSan(m).$2;
  } catch (_) {
    return uci;
  }
}

class Engine {
  Stockfish? _sf;

  Future<Stockfish> _get() async {
    if (_sf != null) return _sf!;
    final sf = Stockfish();
    while (sf.state.value != StockfishState.ready) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    sf.stdin = 'uci';
    sf.stdin = 'setoption name MultiPV value 3';
    sf.stdin = 'isready';
    _sf = sf;
    return sf;
  }

  Future<List<Line>> analyse(String fen, {int ms = 1500}) async {
    final sf = await _get();
    final best = <int, Line>{};
    final done = Completer<void>();
    final sub = sf.stdout.listen((l) {
      if (l.startsWith('info') && l.contains(' pv ')) {
        final mp = RegExp(r'multipv (\d+)').firstMatch(l);
        final sc = RegExp(r'score (cp|mate) (-?\d+)').firstMatch(l);
        if (sc == null) return;
        final pv = l.split(' pv ').last.trim().split(' ');
        final v = int.parse(sc.group(2)!);
        final s = sc.group(1) == 'cp' ? '${v >= 0 ? '+' : ''}${(v / 100).toStringAsFixed(2)}' : '#$v';
        final rank = mp == null ? 1 : int.parse(mp.group(1)!);
        best[rank] = Line(rank, s, pv);
      } else if (l.startsWith('bestmove')) {
        if (!done.isCompleted) done.complete();
      }
    });
    sf.stdin = 'position fen $fen';
    sf.stdin = 'go movetime $ms';
    await done.future.timeout(Duration(milliseconds: ms + 8000), onTimeout: () {});
    await sub.cancel();
    final keys = best.keys.toList()..sort();
    return keys.map((k) => best[k]!).toList();
  }
}
