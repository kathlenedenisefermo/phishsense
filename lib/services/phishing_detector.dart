import 'package:flutter/services.dart';

class PhishingResult {
  final String label;
  final double confidence;

  const PhishingResult({required this.label, required this.confidence});

  bool get isPhishing => label == 'phishing';
}

class PhishingDetector {
  static const _channel = MethodChannel('com.phishsense/inference');

  static Future<String> getModelVersion() async {
    try {
      final v = await _channel.invokeMethod<String>('getModelVersion');
      return v ?? '1.0.0';
    } on PlatformException {
      return '1.0.0';
    }
  }

  static Future<PhishingResult> classify(String text) async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'classifySms',
        {'text': text},
      );
      final label = result?['label'] as String? ?? 'legitimate';
      final confidence = (result?['confidence'] as num?)?.toDouble() ?? 0.0;
      return PhishingResult(label: label, confidence: confidence);
    } on PlatformException {
      // Model not ready or other error — treat as safe to avoid UI crash
      return const PhishingResult(label: 'legitimate', confidence: 0.0);
    }
  }
}
