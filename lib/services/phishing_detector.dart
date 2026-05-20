import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sms_tokenizer.dart';

class PhishingResult {
  final String label;
  final double confidence;

  const PhishingResult({required this.label, required this.confidence});

  bool get isPhishing => label == 'phishing';
}

class PhishingDetector {
  static const _cacheKey = 'otp_template_cache_v2';
  static OrtSession? _session;
  static bool _envInit = false;

  static String normalizeOtp(String text) =>
      text.trim().toLowerCase().replaceAll(RegExp(r'\b\d{4,8}\b'), '[code]');

  static Future<void> _ensureSession() async {
    if (_session != null) return;
    if (!_envInit) {
      OrtEnv.instance.init(level: OrtLoggingLevel.warning);
      _envInit = true;
    }
    final raw = await rootBundle.load('assets/phishsense_model.onnx');
    debugPrint('[PhishingDetector] Loading model (${(raw.lengthInBytes / 1e6).toStringAsFixed(0)} MB)…');
    _session = OrtSession.fromBuffer(
      raw.buffer.asUint8List(),
      OrtSessionOptions(),
    );
    debugPrint('[PhishingDetector] Model loaded. Inputs: ${_session!.inputNames}');
  }

  static Future<PhishingResult?> _cachedResult(String key) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_cacheKey);
    if (raw == null) return null;
    final entry = (jsonDecode(raw) as Map<String, dynamic>)[key];
    if (entry == null) return null;
    double confidence = (entry['confidence'] as num).toDouble();
    // Normalise legacy entries stored as 0-100 rather than 0-1
    if (confidence > 1.0) confidence /= 100.0;
    return PhishingResult(
      label: entry['label'] as String,
      confidence: confidence.clamp(0.0, 1.0),
    );
  }

  static Future<void> _cacheResult(String key, PhishingResult r) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_cacheKey);
    final cache = raw != null
        ? (jsonDecode(raw) as Map<String, dynamic>)
        : <String, dynamic>{};
    cache[key] = {'label': r.label, 'confidence': r.confidence};
    if (cache.length > 500) {
      final stale = cache.keys.take(cache.length - 400).toList();
      for (final k in stale) {
        cache.remove(k);
      }
    }
    await p.setString(_cacheKey, jsonEncode(cache));
  }

  static Future<String> getModelVersion() async => '2.0.0';

  static Future<PhishingResult> classify(String text) async {
    final cacheKey = normalizeOtp(text);
    final cached = await _cachedResult(cacheKey);
    if (cached != null) return cached;

    try {
      final tokenizer = await SmsTokenizer.getInstance();
      await _ensureSession();

      final (inputIds, mask) = tokenizer.encode(text);

      // Wrap in a List so element() resolves to Int64List → int64 tensor type
      final idTensor = OrtValueTensor.createTensorWithDataList(
        [Int64List.fromList(inputIds)],
        [1, 128],
      );
      final maskTensor = OrtValueTensor.createTensorWithDataList(
        [Int64List.fromList(mask)],
        [1, 128],
      );
      final runOptions = OrtRunOptions();

      final outputs = _session!.run(runOptions, {
        'input_ids': idTensor,
        'attention_mask': maskTensor,
      });

      idTensor.release();
      maskTensor.release();
      runOptions.release();

      // outputs[0].value for a float [1,2] tensor → List<List<double>>
      final logits = _extractLogits(outputs);
      for (final v in outputs) {
        v?.release();
      }

      if (logits.length < 2) {
        return const PhishingResult(label: 'legitimate', confidence: 0.0);
      }

      // Softmax over [legitimate, phishing]
      final maxL = logits.reduce(math.max);
      final exps = logits.map((l) => math.exp(l - maxL)).toList();
      final sum = exps.fold(0.0, (a, b) => a + b);
      final probs = exps.map((e) => e / sum).toList();

      final cls = probs[1] > probs[0] ? 1 : 0;
      final result = PhishingResult(
        label: cls == 1 ? 'phishing' : 'legitimate',
        confidence: probs[cls],
      );
      debugPrint('[PhishingDetector] → ${result.label} (${(result.confidence * 100).toStringAsFixed(1)}%)');

      await _cacheResult(cacheKey, result);
      return result;
    } catch (e) {
      debugPrint('[PhishingDetector] ERROR: $e');
      return const PhishingResult(label: 'legitimate', confidence: 0.0);
    }
  }

  static List<double> _extractLogits(List<OrtValue?> outputs) {
    final raw = outputs.firstOrNull?.value;
    final result = <double>[];
    void visit(dynamic v) {
      if (v is List) {
        for (final item in v) { visit(item); }
      } else if (v is num) {
        result.add(v.toDouble());
      }
    }
    visit(raw);
    return result;
  }
}
