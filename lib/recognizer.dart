import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

const int G = 24;

/// x, y = board ka top-left (x: width ka hissa, y: height ka hissa), s = board ki side (width ka hissa)
class BoardRect {
  double x, y, s;
  BoardRect(this.x, this.y, this.s);
}

class _Feat {
  final String mask;
  final double fg, lum;
  _Feat(this.mask, this.fg, this.lum);
}

num _med(List<num> l) {
  l.sort();
  return l[l.length ~/ 2];
}

_Feat _feat(img.Image im, BoardRect r, int row, int col) {
  final cell = r.s * im.width / 8;
  final x0 = r.x * im.width + col * cell, y0 = r.y * im.height + row * cell;
  final m = cell * 0.12;
  final w = (cell - 2 * m).round();
  final crop = img.copyCrop(im, x: (x0 + m).round(), y: (y0 + m).round(), width: w, height: w);
  final s = img.copyResize(crop, width: G, height: G, interpolation: img.Interpolation.average);
  final rs = <num>[], gs = <num>[], bs = <num>[];
  for (final cx in [0, G - 3]) {
    for (final cy in [0, G - 3]) {
      for (var dx = 0; dx < 3; dx++) {
        for (var dy = 0; dy < 3; dy++) {
          final p = s.getPixel(cx + dx, cy + dy);
          rs.add(p.r);
          gs.add(p.g);
          bs.add(p.b);
        }
      }
    }
  }
  final br = _med(rs), bg = _med(gs), bb = _med(bs);
  final sb = StringBuffer();
  var n = 0;
  double lum = 0;
  for (var y = 0; y < G; y++) {
    for (var x = 0; x < G; x++) {
      final p = s.getPixel(x, y);
      final d = sqrt(pow(p.r - br, 2) + pow(p.g - bg, 2) + pow(p.b - bb, 2));
      if (d > 50) {
        sb.write('1');
        n++;
        lum += 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      } else {
        sb.write('0');
      }
    }
  }
  return _Feat(sb.toString(), n / (G * G), n == 0 ? 0 : lum / n);
}

class Templates {
  BoardRect rect;
  Map<String, List<String>> masks;
  double thr;
  Templates(this.rect, this.masks, this.thr);

  Map<String, dynamic> toJson() => {
        'r': [rect.x, rect.y, rect.s],
        'm': masks,
        't': thr
      };

  factory Templates.fromJson(Map<String, dynamic> j) {
    final r = (j['r'] as List).map((e) => (e as num).toDouble()).toList();
    return Templates(
      BoardRect(r[0], r[1], r[2]),
      (j['m'] as Map).map((k, v) => MapEntry(k as String, (v as List).cast<String>())),
      (j['t'] as num).toDouble(),
    );
  }

  String encode() => jsonEncode(toJson());
  static Templates decode(String s) => Templates.fromJson(jsonDecode(s));

  /// Starting position ke screenshot (white neeche) se templates seekho.
  static Templates calibrate(Uint8List bytes, BoardRect r) {
    final im = img.decodeImage(bytes)!;
    const back = 'rnbqkbnr';
    final masks = <String, List<String>>{};
    final wl = <double>[], bl = <double>[];
    void add(int row, int col, String t, bool white) {
      final f = _feat(im, r, row, col);
      (masks[t] ??= []).add(f.mask);
      (white ? wl : bl).add(f.lum);
    }

    for (var c = 0; c < 8; c++) {
      add(0, c, back[c], false);
      add(1, c, 'p', false);
      add(6, c, 'p', true);
      add(7, c, back[c], true);
    }
    double avg(List<double> l) => l.reduce((a, b) => a + b) / l.length;
    return Templates(BoardRect(r.x, r.y, r.s), masks, (avg(wl) + avg(bl)) / 2);
  }

  /// Screen par jaisa dikh raha hai, 64 squares (upar-left se), '.' = khali
  List<String> scan(Uint8List bytes) {
    final im = img.decodeImage(bytes)!;
    final out = <String>[];
    for (var row = 0; row < 8; row++) {
      for (var col = 0; col < 8; col++) {
        final f = _feat(im, rect, row, col);
        if (f.fg < 0.04) {
          out.add('.');
          continue;
        }
        var best = 'p', bd = 1 << 30;
        masks.forEach((t, list) {
          for (final m in list) {
            var d = 0;
            for (var i = 0; i < m.length; i++) {
              if (m.codeUnitAt(i) != f.mask.codeUnitAt(i)) d++;
            }
            if (d < bd) {
              bd = d;
              best = t;
            }
          }
        });
        out.add(f.lum > thr ? best.toUpperCase() : best);
      }
    }
    return out;
  }
}

/// seen = screen jaisa; white neeche ho to normalize nahi hota, warna 180 degree ulta
List<String> normalize(List<String> seen, bool whiteBottom) =>
    whiteBottom ? seen : seen.reversed.toList();

String toFen(List<String> seen, bool whiteBottom, bool whiteToMove) {
  final b = normalize(seen, whiteBottom);
  final rows = <String>[];
  for (var r = 0; r < 8; r++) {
    var s = '', e = 0;
    for (var c = 0; c < 8; c++) {
      final p = b[r * 8 + c];
      if (p == '.') {
        e++;
      } else {
        if (e > 0) s += '$e';
        e = 0;
        s += p;
      }
    }
    if (e > 0) s += '$e';
    rows.add(s);
  }
  var c = '';
  if (b[60] == 'K' && b[63] == 'R') c += 'K';
  if (b[60] == 'K' && b[56] == 'R') c += 'Q';
  if (b[4] == 'k' && b[7] == 'r') c += 'k';
  if (b[4] == 'k' && b[0] == 'r') c += 'q';
  if (c.isEmpty) c = '-';
  return '${rows.join('/')} ${whiteToMove ? 'w' : 'b'} $c - 0 1';
}
