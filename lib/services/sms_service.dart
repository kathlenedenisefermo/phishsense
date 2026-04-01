import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SmsMessage {
  final int? id;
  final int? threadId;
  final String sender;
  final String body;
  final int timestamp;
  final bool isOutgoing;
  final bool? isPhishing;
  final double? confidence;
  final bool classificationPending;
  final bool isRead;
  final bool verificationPending;
  final bool sendFailed;

  const SmsMessage({
    this.id,
    this.threadId,
    required this.sender,
    required this.body,
    required this.timestamp,
    this.isOutgoing = false,
    this.isPhishing,
    this.confidence,
    this.classificationPending = false,
    this.isRead = true,
    this.verificationPending = false,
    this.sendFailed = false,
  });

  SmsMessage copyWith({
    bool? isPhishing,
    double? confidence,
    bool? classificationPending,
    String? sender,
    int? threadId,
    bool? isOutgoing,
    bool? isRead,
    bool? verificationPending,
    bool? sendFailed,
  }) {
    return SmsMessage(
      id: id,
      threadId: threadId ?? this.threadId,
      sender: sender ?? this.sender,
      body: body,
      timestamp: timestamp,
      isOutgoing: isOutgoing ?? this.isOutgoing,
      isPhishing: isPhishing ?? this.isPhishing,
      confidence: confidence ?? this.confidence,
      classificationPending: classificationPending ?? this.classificationPending,
      isRead: isRead ?? this.isRead,
      verificationPending: verificationPending ?? this.verificationPending,
      sendFailed: sendFailed ?? this.sendFailed,
    );
  }
}

class SmsService {
  static const _stream = EventChannel('com.phishsense/sms_stream');
  static const _sentStatusChannel = EventChannel('com.phishsense/sms_sent_status');
  static const _mgr = MethodChannel('com.phishsense/sms_manager');

  // Single broadcast stream shared by all listeners — calling
  // receiveBroadcastStream() more than once would cancel the previous
  // native EventChannel connection and drop incoming messages.
  static final Stream<SmsMessage> incomingSms = _stream
      .receiveBroadcastStream()
      .map((raw) {
        final map = Map<String, dynamic>.from(raw as Map);
        return SmsMessage(
          sender: map['sender'] as String? ?? 'Unknown',
          body: map['body'] as String? ?? '',
          timestamp: (map['timestamp'] as num?)?.toInt() ?? 0,
          threadId: (map['threadId'] as num?)?.toInt(),
          classificationPending: true,
        );
      })
      .asBroadcastStream();

  static Stream<Map<String, dynamic>>? _sentStatusStream;
  static Stream<Map<String, dynamic>> get sentStatusUpdates {
    _sentStatusStream ??= _sentStatusChannel
        .receiveBroadcastStream()
        .map((raw) => Map<String, dynamic>.from(raw as Map))
        .asBroadcastStream();
    return _sentStatusStream!;
  }

  static Future<List<SmsMessage>> readInbox({int limit = 500}) async {
    try {
      final result = await _mgr.invokeListMethod<Object>('readInbox', {'limit': limit});
      return (result ?? []).map((item) {
        final m = Map<String, dynamic>.from(item as Map);
        return SmsMessage(
          id: (m['id'] as num?)?.toInt(),
          threadId: (m['threadId'] as num?)?.toInt(),
          sender: m['sender'] as String? ?? 'Unknown',
          body: m['body'] as String? ?? '',
          timestamp: (m['timestamp'] as num?)?.toInt() ?? 0,
          isOutgoing: m['isOutgoing'] as bool? ?? false,
          isRead: m['isRead'] as bool? ?? true,
        );
      }).toList();
    } on PlatformException {
      return [];
    }
  }

  static Future<List<SmsMessage>> readThread(int threadId) async {
    try {
      final result = await _mgr.invokeListMethod<Object>('readThread', {'threadId': threadId});
      return (result ?? []).map((item) {
        final m = Map<String, dynamic>.from(item as Map);
        return SmsMessage(
          id: (m['id'] as num?)?.toInt(),
          threadId: (m['threadId'] as num?)?.toInt(),
          sender: m['sender'] as String? ?? 'Unknown',
          body: m['body'] as String? ?? '',
          timestamp: (m['timestamp'] as num?)?.toInt() ?? 0,
          isOutgoing: m['isOutgoing'] as bool? ?? false,
          isRead: m['isRead'] as bool? ?? true,
        );
      }).toList();
    } on PlatformException {
      return [];
    }
  }

  static Future<void> sendSms(String to, String body) async {
    await _mgr.invokeMethod('sendSms', {'to': to, 'body': body});
  }

  static Future<bool> isDefaultSmsApp() async {
    return await _mgr.invokeMethod<bool>('isDefaultSmsApp') ?? false;
  }

  static Future<bool> requestDefaultSmsApp() async {
    try {
      await _mgr.invokeMethod('requestDefaultSmsApp');
      return true;
    } on PlatformException catch (e) {
      debugPrint('requestDefaultSmsApp PlatformException: ${e.code} — ${e.message}');
      return false;
    } catch (e) {
      debugPrint('requestDefaultSmsApp unexpected error: $e');
      return false;
    }
  }

  static Future<void> openDefaultAppsSettings() async {
    try {
      await _mgr.invokeMethod('openDefaultAppsSettings');
    } catch (_) {}
  }

  static Future<String?> lookupContactName(String number) async {
    try {
      return await _mgr.invokeMethod<String>('lookupContactName', {'number': number});
    } on PlatformException {
      return null;
    }
  }

  static Future<void> makeCall(String number) async {
    try {
      await _mgr.invokeMethod('makeCall', {'number': number});
    } catch (_) {}
  }

  static Future<void> deleteThread(int threadId) async {
    await _mgr.invokeMethod('deleteThread', {'threadId': threadId});
  }

  static Future<void> deleteMessage(int id) async {
    await _mgr.invokeMethod('deleteMessage', {'id': id});
  }

  static Future<void> markThreadRead(int threadId) async {
    try {
      await _mgr.invokeMethod('markThreadRead', {'threadId': threadId});
    } catch (_) {}
  }

  static Future<Map<String, int>> getUnreadCounts() async {
    try {
      final result = await _mgr.invokeMethod<Map>('getUnreadCounts');
      if (result == null) return {};
      return result.map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
    } on PlatformException {
      return {};
    }
  }

  static Future<List<SmsMessage>> searchMessages(String query) async {
    try {
      final result = await _mgr.invokeListMethod<Object>('searchMessages', {'query': query});
      return (result ?? []).map((item) {
        final m = Map<String, dynamic>.from(item as Map);
        return SmsMessage(
          id: (m['id'] as num?)?.toInt(),
          threadId: (m['threadId'] as num?)?.toInt(),
          sender: m['sender'] as String? ?? 'Unknown',
          body: m['body'] as String? ?? '',
          timestamp: (m['timestamp'] as num?)?.toInt() ?? 0,
          isOutgoing: m['isOutgoing'] as bool? ?? false,
        );
      }).toList();
    } on PlatformException {
      return [];
    }
  }

  static Future<List<Map<String, String>>> getAllContacts() async {
    try {
      final result = await _mgr.invokeListMethod<Object>('getAllContacts');
      return (result ?? []).map((item) {
        final m = Map<String, dynamic>.from(item as Map);
        return {'name': m['name'] as String? ?? '', 'number': m['number'] as String? ?? ''};
      }).toList();
    } on PlatformException {
      return [];
    }
  }
}
