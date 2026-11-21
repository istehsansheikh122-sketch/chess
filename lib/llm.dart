import 'dart:convert';
import 'package:http/http.dart' as http;
import 'engine.dart';

Future<String> explain(String apiKey, String model, String fen, List<Line> lines) async {
  if (apiKey.isEmpty) return 'Settings mein OpenRouter key daalo.';
  final cands = lines
      .map((l) => '${l.rank}. ${san(fen, l.move)} (eval ${l.score}, line: ${l.pv.take(5).join(' ')})')
      .join('\n');
  final prompt = 'Chess position FEN: $fen\nStockfish ki top moves:\n$cands\n\n'
      'Roman Urdu/Hinglish mein 4-5 chhote jumlon mein batao ke pehli move kyun best hai, '
      'opponent ka sabse bada threat kya hai, aur ek plan. Sirf upar di gayi engine lines par bharosa karo.';
  final res = await http.post(
    Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
    headers: {'Authorization': 'Bearer $apiKey', 'Content-Type': 'application/json'},
    body: jsonEncode({
      'model': model,
      'max_tokens': 400,
      'messages': [
        {'role': 'user', 'content': prompt}
      ]
    }),
  );
  if (res.statusCode != 200) return 'OpenRouter error ${res.statusCode}: ${res.body}';
  final j = jsonDecode(res.body);
  return (j['choices'][0]['message']['content'] as String).trim();
}
