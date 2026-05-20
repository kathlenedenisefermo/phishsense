import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PhishingResult {
  final String label;
  final double confidence;

  const PhishingResult({required this.label, required this.confidence});

  bool get isPhishing => label == 'phishing';
}

class PhishingDetector {
  static const _channel          = MethodChannel('com.phishsense/inference');
  static const _templateCacheKey = 'otp_template_cache';

  // Replaces standalone 4-8 digit sequences (OTP codes) with [CODE] so
  // messages that share the same template but differ only in the OTP
  // produce the same cache key.
  static String normalizeOtp(String text) =>
      text.trim().toLowerCase().replaceAll(RegExp(r'\b\d{4,8}\b'), '[code]');

  static Future<PhishingResult?> _cachedResult(String normalized) async {
    final p   = await SharedPreferences.getInstance();
    final raw = p.getString(_templateCacheKey);
    if (raw == null) return null;
    final entry = (jsonDecode(raw) as Map<String, dynamic>)[normalized];
    if (entry == null) return null;
    return PhishingResult(
      label:      entry['label']      as String,
      confidence: (entry['confidence'] as num).toDouble(),
    );
  }

  static Future<void> _cacheResult(String normalized, PhishingResult r) async {
    final p     = await SharedPreferences.getInstance();
    final raw   = p.getString(_templateCacheKey);
    final cache = raw != null
        ? (jsonDecode(raw) as Map<String, dynamic>)
        : <String, dynamic>{};
    cache[normalized] = {'label': r.label, 'confidence': r.confidence};
    // Cap at 500 entries to avoid unbounded growth.
    if (cache.length > 500) {
      final stale = cache.keys.take(cache.length - 400).toList();
      for (final k in stale) { cache.remove(k); }
    }
    await p.setString(_templateCacheKey, jsonEncode(cache));
  }

  static Future<String> getModelVersion() async {
    try {
      final v = await _channel.invokeMethod<String>('getModelVersion');
      return v ?? '1.0.0';
    } on PlatformException {
      return '1.0.0';
    }
  }

  static Future<PhishingResult> classify(String text) async {
    final normalized = normalizeOtp(text);
    final cached     = await _cachedResult(normalized);
    if (cached != null) return cached;

    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'classifySms',
        {'text': text},
      );
      final label      = result?['label']      as String? ?? 'legitimate';
      final confidence = (result?['confidence'] as num?)?.toDouble() ?? 0.0;
      final r          = PhishingResult(label: label, confidence: confidence);
      await _cacheResult(normalized, r);
      return r;
    } on PlatformException {
      return const PhishingResult(label: 'legitimate', confidence: 0.0);
    }
  }
}
