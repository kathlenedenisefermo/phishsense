import 'dart:convert';
import 'package:flutter/services.dart';

class _Piece {
  final int id;
  final double score;
  const _Piece(this.id, this.score);
}

/// Unigram (SentencePiece-style) tokenizer backed by the bundled tokenizerr.json.
///
/// Matches the HuggingFace tokenizers behaviour used by the Python backend:
///   normalizer  → strip trailing whitespace, collapse 2+ spaces to ▁
///   pre-tokenizer → whitespace split + Metaspace (prepend ▁ to every word)
///   model       → Unigram (Viterbi segmentation)
///   post-processor → <s> … </s>
///   truncation  → right, max_length 128
///   padding     → right, pad_id 1, to length 128
class SmsTokenizer {
  static SmsTokenizer? _instance;

  final Map<String, _Piece> _vocab;
  final int _maxPieceLen;

  static const int _bosId = 0; // <s>
  static const int _padId = 1; // <pad>
  static const int _eosId = 2; // </s>
  static const int _unkId = 3; // <unk>

  SmsTokenizer._(this._vocab, this._maxPieceLen);

  static Future<SmsTokenizer> getInstance() async {
    return _instance ??= await _build();
  }

  static Future<SmsTokenizer> _build() async {
    final raw = await rootBundle.loadString('assets/tokenizer.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final vocabList =
        (json['model'] as Map<String, dynamic>)['vocab'] as List<dynamic>;

    final vocab = <String, _Piece>{};
    int maxLen = 1;

    for (int i = 0; i < vocabList.length; i++) {
      final entry = vocabList[i] as List<dynamic>;
      final token = entry[0] as String;
      final score = (entry[1] as num).toDouble();
      vocab[token] = _Piece(i, score);
      if (token.length > maxLen) maxLen = token.length;
    }

    return SmsTokenizer._(vocab, maxLen);
  }

  /// Returns (input_ids, attention_mask), both padded to [maxLength].
  (List<int>, List<int>) encode(String text, {int maxLength = 128}) {
    // Normalize
    String s = text.trimRight();
    s = s.replaceAll(RegExp(r' {2,}'), '▁');

    // Pre-tokenize: split on whitespace, prepend ▁ to each word
    final words = s.split(RegExp(r'\s+'));
    final ids = <int>[];
    for (final word in words) {
      final piece = '▁$word';
      if (piece == '▁') continue;
      ids.addAll(_tokenizeWord(piece));
    }

    // Post-process: BOS + (up to maxLength-2 content tokens) + EOS
    final content = ids.length > maxLength - 2
        ? ids.sublist(0, maxLength - 2)
        : ids;
    final full = [_bosId, ...content, _eosId];

    // Pad to maxLength
    final inputIds = List<int>.filled(maxLength, _padId);
    final mask = List<int>.filled(maxLength, 0);
    for (int i = 0; i < full.length; i++) {
      inputIds[i] = full[i];
      mask[i] = 1;
    }

    return (inputIds, mask);
  }

  List<int> _tokenizeWord(String word) {
    final n = word.length;
    // dp scores and back-pointers for Viterbi segmentation
    final scores = List<double>.filled(n + 1, double.negativeInfinity);
    final backs = List<int>.filled(n + 1, -1);
    scores[0] = 0.0;

    for (int i = 1; i <= n; i++) {
      final jStart = (i - _maxPieceLen).clamp(0, i);
      for (int j = jStart; j < i; j++) {
        if (scores[j] == double.negativeInfinity) continue;
        final p = _vocab[word.substring(j, i)];
        if (p != null) {
          final candidate = scores[j] + p.score;
          if (candidate > scores[i]) {
            scores[i] = candidate;
            backs[i] = j;
          }
        }
      }
      // Fallback: unknown single character — keeps segmentation connected
      if (scores[i] == double.negativeInfinity &&
          scores[i - 1] != double.negativeInfinity) {
        scores[i] = scores[i - 1] - 100.0;
        backs[i] = i - 1;
      }
    }

    // Backtrack
    final pieces = <String>[];
    var pos = n;
    while (pos > 0 && backs[pos] >= 0) {
      pieces.add(word.substring(backs[pos], pos));
      pos = backs[pos];
    }
    if (pieces.isEmpty) return [_unkId];

    return pieces.reversed.map((p) => _vocab[p]?.id ?? _unkId).toList();
  }
}
