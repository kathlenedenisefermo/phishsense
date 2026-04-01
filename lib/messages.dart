import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/sms_service.dart';
import 'services/phishing_detector.dart';
import 'spam_folder.dart';
import 'profile.dart';
import 'conversation_page.dart';
import 'compose.dart';
import 'contacts_page.dart';

class MessagesPage extends StatefulWidget {
  final String name;
  final int defaultSmsIndex;
  final bool notificationPermission;
  final bool spamFolderEnabled;
  final bool shareAnonymousData;
  final bool showDetectionPopup;
  final ValueChanged<bool> onChangeShareAnonymousData;
  final ValueChanged<bool> onChangeShowDetectionPopup;

  const MessagesPage({
    super.key,
    required this.name,
    required this.defaultSmsIndex,
    required this.notificationPermission,
    required this.spamFolderEnabled,
    required this.shareAnonymousData,
    required this.showDetectionPopup,
    required this.onChangeShareAnonymousData,
    required this.onChangeShowDetectionPopup,
  });

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _Thread {
  final int threadId;
  final String sender;
  final SmsMessage latestMessage;

  const _Thread({
    required this.threadId,
    required this.sender,
    required this.latestMessage,
  });
}

class _MessagesPageState extends State<MessagesPage>
    with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> scaffoldKey = GlobalKey<ScaffoldState>();

  late int _defaultSmsIndex;
  late bool _notificationPermission;
  late bool _spamFolderEnabled;
  late bool _shareAnonymousData;
  late bool _showDetectionPopup;

  final List<SmsMessage> _messages = [];
  StreamSubscription<SmsMessage>? _smsSub;

  final Map<String, String> _contactNames = {};

  bool _isDefaultSmsApp = true;
  bool _waitingForDefault = false;

  Map<String, int> _unreadCounts = {};
  final Map<String, Map<String, dynamic>> _labelCache = {};
  bool? _autoScanEnabled; // null = never asked, true = auto-scan, false = manual
  int _scanCutoffMs = 0;  // timestamp of the oldest message included in the chosen scan range
  double? _scanProgress; // null = not scanning, 0.0–1.0 = in progress

  /// Thread IDs the user has manually restored from the spam folder.
  /// These threads appear in the main inbox even though their messages
  /// are still classified as phishing.
  Set<int> _restoredSpamThreadIds = {};

  bool _searching = false;
  String _searchQuery = '';
  List<SmsMessage> _searchResults = [];
  bool _searchLoading = false;
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _searchDebounce;

  int _selectedTab = 0;

  @override
  void initState() {
    super.initState();
    _defaultSmsIndex = widget.defaultSmsIndex;
    _notificationPermission = widget.notificationPermission;
    _spamFolderEnabled = widget.spamFolderEnabled;
    _shareAnonymousData = widget.shareAnonymousData;
    _showDetectionPopup = widget.showDetectionPopup;

    WidgetsBinding.instance.addObserver(this);
    _smsSub = SmsService.incomingSms.listen(_onSmsReceived);
    _loadInbox();
    _checkDefaultSmsApp();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waitingForDefault) {
      _waitingForDefault = false;
      _checkDefaultSmsApp();
    }
  }

  Future<void> _checkDefaultSmsApp() async {
    final isDefault = await SmsService.isDefaultSmsApp();
    if (mounted) setState(() => _isDefaultSmsApp = isDefault);
  }

  Future<void> _requestDefaultSmsApp() async {
    setState(() => _waitingForDefault = true);
    final opened = await SmsService.requestDefaultSmsApp();
    if (!mounted) return;
    if (!opened) {
      setState(() => _waitingForDefault = false);
      _showSetDefaultDialog();
    }
  }

  void _showSetDefaultDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Set PhishSense as Default',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'The automatic dialog could not be opened on your device.\n\n'
          'To set PhishSense as your default SMS app manually:\n\n'
          '1. Open Settings\n'
          '2. Tap Apps (or Application Manager)\n'
          '3. Tap Default apps\n'
          '4. Tap SMS app\n'
          '5. Select PhishSense',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              SmsService.openDefaultAppsSettings();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A7A72),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  // Normalise a phone number to its last 10 digits so that +639277709835
  // and 09277709835 resolve to the same key. Short codes (< 10 digits) are
  // kept as-is.
  static String _normalizeNumber(String number) {
    final digits = number.replaceAll(RegExp(r'\D'), '');
    return digits.length >= 10 ? digits.substring(digits.length - 10) : digits;
  }

  // Always use normalised-sender + timestamp so the key is identical whether
  // the message came from the EventChannel (id==null) or from the SMS database.
  static String _labelKey(SmsMessage msg) =>
      'lbl_${_normalizeNumber(msg.sender)}_${msg.timestamp}';

  Future<void> _loadLabelCache() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      if (!key.startsWith('lbl_')) continue;
      final val = prefs.getString(key);
      if (val == null) continue;
      final parts = val.split(',');
      if (parts.length == 2) {
        _labelCache[key] = {
          'isPhishing': parts[0] == '1',
          'confidence': double.tryParse(parts[1]) ?? 0.0,
        };
      }
    }
  }

  void _applyLabels(List<SmsMessage> messages) {
    for (int i = 0; i < messages.length; i++) {
      final cached = _labelCache[_labelKey(messages[i])];
      if (cached != null && messages[i].isPhishing == null) {
        messages[i] = messages[i].copyWith(
          isPhishing: cached['isPhishing'] as bool,
          confidence: cached['confidence'] as double,
        );
      }
    }
  }

  Future<void> _saveLabel(SmsMessage msg, bool isPhishing, double confidence) async {
    // Confidence of 0.0 means the model wasn't ready yet (safe-default fallback).
    // Don't cache these so the message can be re-scanned once the model is loaded.
    if (confidence == 0.0) return;
    final prefs = await SharedPreferences.getInstance();
    final key = _labelKey(msg);
    await prefs.setString(key, '${isPhishing ? '1' : '0'},${confidence.toStringAsFixed(4)}');
    _labelCache[key] = {'isPhishing': isPhishing, 'confidence': confidence};
  }

  Future<void> _scanSingleMessage(SmsMessage msg) async {
    final idx = _messages.indexWhere(
      (m) => m.id == msg.id && m.timestamp == msg.timestamp,
    );
    if (idx == -1) return;
    setState(() => _messages[idx] = _messages[idx].copyWith(classificationPending: true));
    final result = await PhishingDetector.classify(msg.body);
    if (!mounted) return;
    await _saveLabel(msg, result.isPhishing, result.confidence);
    setState(() {
      final i = _messages.indexWhere(
        (m) => m.id == msg.id && m.timestamp == msg.timestamp,
      );
      if (i != -1) {
        _messages[i] = _messages[i].copyWith(
          isPhishing: result.confidence > 0.0 ? result.isPhishing : null,
          confidence: result.confidence > 0.0 ? result.confidence : null,
          classificationPending: false,
        );
      }
    });
  }

  Future<void> _scanThread(int threadId) async {
    final toScan = _messages
        .where((m) =>
            (m.threadId ?? 0) == threadId &&
            !m.isOutgoing &&
            !m.classificationPending)
        .toList();
    for (final msg in toScan) {
      if (!mounted) return;
      await _scanSingleMessage(msg);
    }
  }

  Future<void> _loadInbox() async {
    final prefs = await SharedPreferences.getInstance();
    _autoScanEnabled = prefs.getBool('auto_scan_enabled');
    _scanCutoffMs = prefs.getInt('scan_cutoff_ms') ?? 0;
    final restoredRaw = prefs.getString('spam_restored_thread_ids') ?? '';
    if (restoredRaw.isNotEmpty) {
      _restoredSpamThreadIds = restoredRaw
          .split(',')
          .map(int.tryParse)
          .whereType<int>()
          .toSet();
    }

    final inbox = await SmsService.readInbox(limit: 500);
    if (!mounted) return;

    final uniqueSenders = inbox.map((m) => m.sender).toSet();
    for (final number in uniqueSenders) {
      final name = await SmsService.lookupContactName(number);
      if (name != null && name.isNotEmpty) _contactNames[number] = name;
    }

    await _loadLabelCache();
    setState(() {
      _messages.addAll(inbox);
      _applyLabels(_messages);
    });

    final counts = await SmsService.getUnreadCounts();
    if (mounted) setState(() => _unreadCounts = counts);

    await _checkModelVersion();
    _showScanPrompt();
  }

  Future<void> _refresh() async {
    final inbox = await SmsService.readInbox(limit: 500);
    final counts = await SmsService.getUnreadCounts();
    if (!mounted) return;
    // Resolve new contact names
    final newSenders = inbox.map((m) => m.sender).toSet()
        .difference(_contactNames.keys.toSet());
    for (final number in newSenders) {
      final name = await SmsService.lookupContactName(number);
      if (name != null && name.isNotEmpty) _contactNames[number] = name;
    }
    setState(() {
      // Keep stream-received messages that haven't been written to DB yet
      // (id == null) so they don't vanish on refresh if the DB write is still
      // in flight. They will be naturally replaced once they appear in inbox.
      final pendingStream = _messages.where((m) =>
        m.id == null &&
        !m.isOutgoing &&
        !inbox.any((db) =>
          _normalizeNumber(db.sender) == _normalizeNumber(m.sender) &&
          (db.timestamp - m.timestamp).abs() < 5000)).toList();
      _messages.clear();
      _messages.addAll(inbox);
      _messages.addAll(pendingStream);
      _applyLabels(_messages);
      _unreadCounts = counts;
    });
  }

  void _doSearch(String query) {
    _searchDebounce?.cancel();
    final q = query.trim();
    if (q.isEmpty) {
      setState(() { _searchResults = []; _searchLoading = false; });
      return;
    }

    // ── Immediate pass: filter already-loaded thread previews by contact name ──
    // This gives instant results while the DB query runs in the background.
    final qLower = q.toLowerCase();
    final localMatches = _messages.where((m) {
      final name = _displayName(m.sender).toLowerCase();
      return name.contains(qLower) && !m.isOutgoing;
    }).toList();
    setState(() {
      _searchLoading = true;
      _searchResults = localMatches;
    });

    // ── Debounced DB pass: body + address search ──────────────────────────────
    _searchDebounce = Timer(const Duration(milliseconds: 200), () async {
      final dbResults = await SmsService.searchMessages(q);

      // Resolve contact names for any new senders in DB results.
      for (final msg in dbResults) {
        if (!_contactNames.containsKey(msg.sender)) {
          final name = await SmsService.lookupContactName(msg.sender);
          if (name != null && name.isNotEmpty) _contactNames[msg.sender] = name;
        }
      }

      if (!mounted) return;

      // Merge: start with DB results, then add local name-only matches that
      // aren't already covered (dedup by sender+timestamp).
      final seen = <String>{};
      final merged = <SmsMessage>[];
      for (final m in dbResults) {
        final key = '${m.sender}_${m.timestamp}';
        if (seen.add(key)) merged.add(m);
      }
      for (final m in localMatches) {
        final key = '${m.sender}_${m.timestamp}';
        if (seen.add(key)) merged.add(m);
      }

      setState(() { _searchResults = merged; _searchLoading = false; });
    });
  }

  // Build a RichText where every occurrence of [query] is highlighted.
  Widget _highlightText(String text, String query,
      {TextStyle? base, int maxLines = 2}) {
    final q = query.trim();
    if (q.isEmpty) {
      return Text(text,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          style: base);
    }
    final lower = text.toLowerCase();
    final lowerQ = q.toLowerCase();
    final spans = <TextSpan>[];
    int start = 0;
    while (true) {
      final idx = lower.indexOf(lowerQ, start);
      if (idx == -1) {
        if (start < text.length) spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (idx > start) spans.add(TextSpan(text: text.substring(start, idx)));
      spans.add(TextSpan(
        text: text.substring(idx, idx + q.length),
        style: const TextStyle(
          backgroundColor: Color(0xFFFFE57F),
          color: Colors.black,
          fontWeight: FontWeight.bold,
        ),
      ));
      start = idx + q.length;
    }
    return RichText(
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(style: base ?? const TextStyle(color: Colors.black87, fontSize: 14), children: spans),
    );
  }

  // Returns a snippet of [text] centred around the first match of [query].
  String _matchSnippet(String text, String query) {
    if (query.isEmpty) return text;
    final idx = text.toLowerCase().indexOf(query.toLowerCase());
    if (idx == -1) return text;
    final start = (idx - 35).clamp(0, text.length);
    final end   = (idx + query.length + 65).clamp(0, text.length);
    return '${start > 0 ? '…' : ''}${text.substring(start, end)}${end < text.length ? '…' : ''}';
  }

  Future<void> _showScanPrompt() async {
    // Not first launch — auto-scan unscanned messages within the chosen range
    if (_autoScanEnabled == true) {
      await _scanExistingMessages(cutoffMs: _scanCutoffMs);
      return;
    }
    // "Skip for Now" was chosen — incoming SMS auto-scanned via _onSmsReceived;
    // existing messages show manual "Tap to Scan" buttons.
    if (_autoScanEnabled == false) return;

    // ── First launch ──────────────────────────────────────────────────────
    if (!mounted || _messages.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();

    // Step 1: ask whether to scan existing messages
    final wantScan = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Scan Existing Messages?',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'Would you like to scan your existing messages for phishing threats?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Skip for Now', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A7A72),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Scan Recent Messages'),
          ),
        ],
      ),
    );

    if (wantScan != true) {
      // Skip for Now — real-time incoming SMS is still always auto-scanned.
      // Existing unscanned messages show a "Tap to Scan" badge.
      await prefs.setBool('auto_scan_enabled', false);
      if (mounted) setState(() => _autoScanEnabled = false);
      return;
    }

    // Step 2: choose how far back to scan
    if (!mounted) return;
    final period = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'How far back?',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: const Text('Select the time range of messages to scan.\nMessages outside this range can be scanned manually.'),
        actions: [
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, '1'),
                style: TextButton.styleFrom(foregroundColor: const Color(0xFF1A7A72)),
                child: const Text('1 Day'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, '3'),
                style: TextButton.styleFrom(foregroundColor: const Color(0xFF1A7A72)),
                child: const Text('3 Days'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, '5'),
                style: TextButton.styleFrom(foregroundColor: const Color(0xFF1A7A72)),
                child: const Text('5 Days'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, '7'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A7A72),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('7 Days'),
              ),
            ],
          ),
        ],
      ),
    );

    if (period == null || !mounted) return;

    final days = int.parse(period);
    final cutoffMs = DateTime.now()
        .subtract(Duration(days: days))
        .millisecondsSinceEpoch;

    await prefs.setBool('auto_scan_enabled', true);
    await prefs.setInt('scan_cutoff_ms', cutoffMs);
    setState(() {
      _autoScanEnabled = true;
      _scanCutoffMs = cutoffMs;
    });
    await _scanExistingMessages(cutoffMs: cutoffMs);
  }

  Future<void> _checkModelVersion() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('model_version');
    final current = await PhishingDetector.getModelVersion();
    if (stored == null) {
      await prefs.setString('model_version', current);
      return;
    }
    if (stored != current) {
      await prefs.setString('model_version', current);
      if (mounted) await _showRescanPrompt();
    }
  }

  Future<void> _showRescanPrompt() async {
    if (!mounted) return;
    final rescan = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'New Detection Model Available',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'A new phishing detection model is available. '
          'Would you like to re-scan your messages with the updated model?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not Now', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A7A72),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Re-scan'),
          ),
        ],
      ),
    );
    if (rescan == true && mounted) {
      await _clearAllLabels();
      await _scanExistingMessages(cutoffMs: _scanCutoffMs);
    }
  }

  Future<void> _clearAllLabels() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().where((k) => k.startsWith('lbl_')).toList()) {
      await prefs.remove(key);
    }
    _labelCache.clear();
    if (mounted) {
      setState(() {
        for (int i = 0; i < _messages.length; i++) {
          if (_messages[i].isPhishing != null) {
            _messages[i] = _messages[i].copyWith(isPhishing: null, confidence: null);
          }
        }
      });
    }
  }

  // Processes messages in batches of 10 to keep the UI responsive.
  // [cutoffMs] is the oldest timestamp to include (0 = all messages).
  // Messages older than [cutoffMs] are skipped and get manual "Tap to Scan".
  Future<void> _scanExistingMessages({int cutoffMs = 0}) async {
    final toScan = _messages
        .where((m) =>
            !m.isOutgoing &&
            m.isPhishing == null &&
            !m.classificationPending &&
            m.timestamp >= cutoffMs)
        .toList();

    if (toScan.isEmpty) {
      setState(() => _scanProgress = null);
      return;
    }

    setState(() => _scanProgress = 0.0);

    const batchSize = 10;
    for (int i = 0; i < toScan.length; i++) {
      if (!mounted) return;
      final msg = toScan[i];

      final idx = _messages.indexWhere(
        (m) => m.id == msg.id && m.timestamp == msg.timestamp,
      );
      if (idx == -1 || _messages[idx].isPhishing != null) {
        setState(() => _scanProgress = (i + 1) / toScan.length);
        continue;
      }

      setState(() => _messages[idx] = _messages[idx].copyWith(classificationPending: true));

      final result = await PhishingDetector.classify(msg.body);
      if (!mounted) return;

      await _saveLabel(msg, result.isPhishing, result.confidence);
      setState(() {
        final ci = _messages.indexWhere(
          (m) => m.id == msg.id && m.timestamp == msg.timestamp,
        );
        if (ci != -1) {
          _messages[ci] = _messages[ci].copyWith(
            isPhishing: result.confidence > 0.0 ? result.isPhishing : null,
            confidence: result.confidence > 0.0 ? result.confidence : null,
            classificationPending: false,
          );
        }
        _scanProgress = (i + 1) / toScan.length;
      });

      // Yield between batches to keep the UI responsive
      if ((i + 1) % batchSize == 0) {
        await Future.delayed(const Duration(milliseconds: 16));
      }
    }

    if (mounted) setState(() => _scanProgress = null);
  }

  void _onSmsReceived(SmsMessage msg) async {
    // Deduplicate using normalised numbers so +639... and 09... are treated
    // as the same sender (avoids double-insertion when both SMS_RECEIVED and
    // SMS_DELIVER fire for the same message).
    final normSender = _normalizeNumber(msg.sender);
    final isDuplicate = _messages.any((m) =>
      _normalizeNumber(m.sender) == normSender &&
      m.body == msg.body &&
      (m.timestamp - msg.timestamp).abs() < 5000,
    );
    if (isDuplicate) return;

    // Resolve the correct threadId before inserting.
    // The stream message may carry threadId=null or 0 if the broadcast arrived
    // before getOrCreateThreadId succeeded. If we fall back to 0, the message
    // would be grouped into a phantom "thread 0" instead of the real thread,
    // and the badge would appear on the wrong (invisible) card.
    // Look up the real threadId from the existing DB messages for this sender.
    int? resolvedThreadId = (msg.threadId ?? 0) != 0 ? msg.threadId : null;
    if (resolvedThreadId == null) {
      for (final m in _messages) {
        if (_normalizeNumber(m.sender) == normSender &&
            m.id != null &&
            (m.threadId ?? 0) != 0) {
          resolvedThreadId = m.threadId;
          break;
        }
      }
    }
    final msgToInsert = (resolvedThreadId != null && resolvedThreadId != msg.threadId)
        ? msg.copyWith(threadId: resolvedThreadId)
        : msg;

    // Show immediately — no async work before this setState.
    setState(() {
      _messages.insert(0, msgToInsert);
      final tid = (resolvedThreadId ?? 0).toString();
      _unreadCounts = {..._unreadCounts, tid: (_unreadCounts[tid] ?? 0) + 1};
    });

    // Resolve contact name in the background and refresh display name if found.
    final name = await SmsService.lookupContactName(msg.sender);
    if (name != null && name.isNotEmpty && mounted) {
      _contactNames[msg.sender] = name;
      setState(() {});
    }

    final result = await PhishingDetector.classify(msgToInsert.body);
    if (!mounted) return;

    await _saveLabel(msgToInsert, result.isPhishing, result.confidence);
    if (!mounted) return;

    setState(() {
      final idx = _messages.indexWhere((m) =>
        _normalizeNumber(m.sender) == normSender &&
        m.timestamp == msgToInsert.timestamp,
      );
      if (idx != -1) {
        _messages[idx] = _messages[idx].copyWith(
          isPhishing: result.confidence > 0.0 ? result.isPhishing : null,
          confidence: result.confidence > 0.0 ? result.confidence : null,
          classificationPending: false,
        );
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _smsSub?.cancel();
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  String _displayName(String sender) => _contactNames[sender] ?? sender;

  bool _isShortCode(String number) {
    final digits = number.replaceAll(RegExp(r'\D'), '');
    return digits.length >= 3 && digits.length <= 6 && !number.startsWith('+');
  }

  List<_Thread> get _threads {
    final Map<int, List<SmsMessage>> grouped = {};
    for (final msg in _messages) {
      final tid = msg.threadId ?? 0;
      grouped.putIfAbsent(tid, () => []).add(msg);
    }
    final threads = grouped.entries.map((e) {
      final msgs = e.value;
      final latest = msgs.reduce(
        (a, b) => a.timestamp > b.timestamp ? a : b,
      );
      final sender = latest.sender;
      return _Thread(
        threadId: e.key,
        sender: sender,
        latestMessage: latest,
      );
    }).where((t) {
      // Hide thread only when every incoming message is confirmed phishing.
      // Unscanned (null) messages keep the thread visible until classified.
      // When all unscanned messages are later detected as phishing the thread
      // automatically moves to spam. Restored threads always stay visible.
      if (_spamFolderEnabled && !_restoredSpamThreadIds.contains(t.threadId)) {
        final msgs = grouped[t.threadId] ?? [];
        final hasSafeMsg = msgs.any((m) => m.isOutgoing || m.isPhishing != true);
        if (!hasSafeMsg) return false;
      }
      return true;
    }).toList();
    threads.sort(
      (a, b) => b.latestMessage.timestamp.compareTo(a.latestMessage.timestamp),
    );
    return threads;
  }

  /// All phishing messages that belong in the spam folder (excludes restored).
  List<SmsMessage> get _spamMessages => _messages
      .where((m) =>
          !m.isOutgoing &&
          m.isPhishing == true &&
          !_restoredSpamThreadIds.contains(m.threadId))
      .toList();

  /// Report a spam message as inaccurately detected: clears the phishing
  /// label (marks as safe) and moves the thread back to the inbox.
  Future<void> _reportInaccurate(SmsMessage msg) async {
    final prefs = await SharedPreferences.getInstance();
    // Mark every phishing message in this thread as safe so auto-scan skips them.
    final tid = msg.threadId;
    for (final m in _messages) {
      if ((m.threadId == tid || (m.sender == msg.sender && tid == null)) &&
          !m.isOutgoing &&
          m.isPhishing == true) {
        final key = 'lbl_${_normalizeNumber(m.sender)}_${m.timestamp}';
        await prefs.setString(key, '0,0.0001'); // safe, low confidence
      }
    }
    if (tid != null && tid != 0) {
      _restoredSpamThreadIds.add(tid);
      await prefs.setString(
          'spam_restored_thread_ids', _restoredSpamThreadIds.join(','));
    }
    if (!mounted) return;
    setState(() {
      for (int i = 0; i < _messages.length; i++) {
        if ((_messages[i].threadId == tid ||
                (_messages[i].sender == msg.sender && tid == null)) &&
            !_messages[i].isOutgoing &&
            _messages[i].isPhishing == true) {
          _messages[i] = _messages[i].copyWith(
            isPhishing: false,
            classificationPending: false,
          );
        }
      }
    });
  }

  /// Restore a spam message: keep the phishing label intact but move the
  /// thread back to the main inbox by adding it to the restored set.
  Future<void> _restoreFromSpam(SmsMessage msg) async {
    final tid = msg.threadId;
    if (tid == null || tid == 0) return;
    final prefs = await SharedPreferences.getInstance();
    _restoredSpamThreadIds.add(tid);
    await prefs.setString(
      'spam_restored_thread_ids',
      _restoredSpamThreadIds.join(','),
    );
    if (!mounted) return;
    setState(() {}); // rebuild threads / spamMessages
  }

  /// Permanently delete a spam message's thread.
  Future<void> _deleteSpamThread(SmsMessage msg) async {
    final tid = msg.threadId;
    if (tid != null && tid != 0) {
      await SmsService.deleteThread(tid);
    }
    if (!mounted) return;
    setState(() {
      _messages.removeWhere((m) => m.threadId == tid);
    });
  }

  /// Delete all spam messages (one thread per unique threadId).
  Future<void> _deleteAllSpam() async {
    final spam = _spamMessages; // excludes restored
    final threadIds = spam
        .map((m) => m.threadId)
        .whereType<int>()
        .toSet();
    for (final tid in threadIds) {
      await SmsService.deleteThread(tid);
    }
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    _restoredSpamThreadIds.removeAll(threadIds);
    await prefs.setString(
        'spam_restored_thread_ids', _restoredSpamThreadIds.join(','));
    setState(() {
      _messages.removeWhere((m) => threadIds.contains(m.threadId));
    });
  }

  void _showCenterNote(String message) {
    showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withOpacity(.15),
      builder: (_) {
        return Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 40),
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(40),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(.12),
                  offset: const Offset(0, 4),
                  blurRadius: 12,
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.info_outline, color: Color(0xFF1A7A72), size: 22),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    message,
                    style: const TextStyle(
                      color: Color(0xFF333333),
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).maybePop();
    });
  }

  void _showThreadOptions(_Thread thread) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 10),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.mark_chat_read_outlined, color: Color(0xFF1A7A72)),
              title: const Text('Mark as read'),
              onTap: () async {
                Navigator.pop(ctx);
                await SmsService.markThreadRead(thread.threadId);
                setState(() => _unreadCounts.remove(thread.threadId.toString()));
              },
            ),
            if (!_isShortCode(thread.sender))
              ListTile(
                leading: const Icon(Icons.call_outlined, color: Color(0xFF1A7A72)),
                title: const Text('Call'),
                onTap: () {
                  Navigator.pop(ctx);
                  SmsService.makeCall(thread.sender);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Delete conversation', style: TextStyle(color: Colors.red)),
              onTap: () async {
                Navigator.pop(ctx);
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (d) => AlertDialog(
                    title: const Text('Delete conversation?'),
                    content: Text('Delete all messages with ${_displayName(thread.sender)}?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
                      TextButton(
                        onPressed: () => Navigator.pop(d, true),
                        child: const Text('Delete', style: TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
                );
                if (confirm == true) {
                  await SmsService.deleteThread(thread.threadId);
                  await _refresh();
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final threads = _threads;
    final pendingCount = _messages.where((m) => m.classificationPending).length;

    return Scaffold(
      key: scaffoldKey,
      endDrawer: ProfileSidebar(
        name: widget.name,
        defaultSmsIndex: _defaultSmsIndex,
        notificationPermission: _notificationPermission,
        spamFolderEnabled: _spamFolderEnabled,
        shareAnonymousData: _shareAnonymousData,
        showDetectionPopup: _showDetectionPopup,
        onChangeDefaultSms: (index) => setState(() => _defaultSmsIndex = index),
        onChangeNotificationPermission: (v) =>
            setState(() => _notificationPermission = v),
        onChangeSpamFolder: (v) => setState(() => _spamFolderEnabled = v),
        onChangeShareAnonymousData: (v) {
          setState(() => _shareAnonymousData = v);
          widget.onChangeShareAnonymousData(v);
        },
        onChangeShowDetectionPopup: (v) {
          setState(() => _showDetectionPopup = v);
          widget.onChangeShowDetectionPopup(v);
        },
      ),
      backgroundColor: const Color(0xFFF6F4EC),
      floatingActionButton: _selectedTab == 0
          ? FloatingActionButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ComposePage()),
              ),
              backgroundColor: const Color(0xFF1A7A72),
              foregroundColor: Colors.white,
              child: const Icon(Icons.edit_outlined),
            )
          : null,
      bottomNavigationBar: _CustomNavBar(
        selectedIndex: _selectedTab,
        onTap: (i) => setState(() => _selectedTab = i),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const _TopHeader(),
            if (!_isDefaultSmsApp)
              _DefaultSmsBanner(onSetDefault: _requestDefaultSmsApp),
            if (_scanProgress != null)
              _ScanProgressBanner(progress: _scanProgress!),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _selectedTab == 0 ? "Messaging" : "Contacts",
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w500,
                            color: Colors.black,
                          ),
                        ),
                        if (_selectedTab == 0) ...[
                          const SizedBox(height: 2),
                          Text(
                            threads.isEmpty
                                ? "No conversations"
                                : pendingCount > 0
                                    ? "Scanning $pendingCount message${pendingCount == 1 ? '' : 's'}…"
                                    : "${threads.length} conversation${threads.length == 1 ? '' : 's'}",
                            style: const TextStyle(
                              fontSize: 14,
                              color: Color(0xFF666666),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      _spamFolderEnabled ? Icons.folder : Icons.folder_off,
                      size: 35,
                    ),
                    color: _spamFolderEnabled
                        ? const Color(0xFF1A7A72)
                        : Colors.grey.withOpacity(.5),
                    onPressed: () {
                      if (_spamFolderEnabled) {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => SpamFolderPage(
                              spamMessages: _spamMessages,
                              contactNames: Map.of(_contactNames),
                              onRestore: _restoreFromSpam,
                              onReport: _reportInaccurate,
                              onDelete: _deleteSpamThread,
                              onDeleteAll: _deleteAllSpam,
                            ),
                          ),
                        );
                      } else {
                        _showCenterNote("Spam Folder is disabled.");
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.person, size: 30),
                    color: const Color(0xFF1A7A72),
                    onPressed: () => scaffoldKey.currentState?.openEndDrawer(),
                  ),
                ],
              ),
            ),
            if (_selectedTab == 0) const SizedBox(height: 18),
            if (_selectedTab == 0) Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: _searching
                  ? Container(
                      height: 50,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF3EEE4),
                        borderRadius: BorderRadius.circular(28),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          const Icon(Icons.search, size: 24, color: Color(0xFF7A7A7A)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _searchCtrl,
                              autofocus: true,
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                hintText: 'Search messages…',
                                hintStyle: TextStyle(color: Color(0xFF9C9C9C), fontSize: 15),
                              ),
                              onChanged: (q) {
                                setState(() => _searchQuery = q);
                                _doSearch(q);
                              },
                            ),
                          ),
                          GestureDetector(
                            onTap: () {
                              setState(() {
                                _searching = false;
                                _searchQuery = '';
                                _searchResults = [];
                                _searchCtrl.clear();
                              });
                            },
                            child: const Icon(Icons.close, size: 20, color: Color(0xFF7A7A7A)),
                          ),
                        ],
                      ),
                    )
                  : GestureDetector(
                      onTap: () => setState(() => _searching = true),
                      child: Container(
                        height: 50,
                        decoration: BoxDecoration(
                          color: const Color(0xFFF3EEE4),
                          borderRadius: BorderRadius.circular(28),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: const Row(
                          children: [
                            Icon(Icons.search, size: 28, color: Color(0xFF7A7A7A)),
                            SizedBox(width: 10),
                            Text("Search", style: TextStyle(color: Color(0xFF9C9C9C), fontSize: 16)),
                          ],
                        ),
                      ),
                    ),
            ),
            if (_selectedTab == 0) const SizedBox(height: 14),
            Expanded(
              child: IndexedStack(
                index: _selectedTab,
                children: [
                  // ── Tab 0: Conversations ──────────────────────────────
                  _searching && _searchQuery.isNotEmpty
                  ? _searchLoading
                      ? const Center(child: CircularProgressIndicator(color: Color(0xFF1A7A72)))
                      : _searchResults.isEmpty
                          ? Center(
                              child: Text(
                                'No results for "$_searchQuery"',
                                style: const TextStyle(color: Color(0xFF888888)),
                              ),
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.only(bottom: 80),
                              itemCount: _searchResults.length,
                              separatorBuilder: (_, __) => const Divider(
                                height: 1,
                                thickness: 1,
                                indent: 18,
                                endIndent: 18,
                                color: Color(0xFFDDD8CE),
                              ),
                              itemBuilder: (context, index) {
                                final msg = _searchResults[index];
                                final name = _displayName(msg.sender);
                                final snippet = _matchSnippet(msg.body, _searchQuery);
                                return ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: const Color(0xFF1A7A72).withOpacity(0.12),
                                    child: Text(
                                      name.isNotEmpty ? name[0].toUpperCase() : '?',
                                      style: const TextStyle(
                                        color: Color(0xFF1A7A72),
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  title: _highlightText(
                                    name,
                                    _searchQuery,
                                    base: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 15,
                                      color: Colors.black87,
                                    ),
                                    maxLines: 1,
                                  ),
                                  subtitle: _highlightText(
                                    snippet,
                                    _searchQuery,
                                    base: const TextStyle(
                                      fontSize: 13,
                                      color: Color(0xFF666666),
                                    ),
                                    maxLines: 2,
                                  ),
                                  onTap: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => ConversationPage(
                                        threadId: msg.threadId ?? 0,
                                        sender: msg.sender,
                                        displayName: name,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            )
                  : threads.isEmpty
                      ? const Center(
                          child: Text(
                            "No messages yet.\nSend one or wait for incoming SMS.",
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Color(0xFF888888), fontSize: 15),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: 80),
                          itemCount: threads.length,
                          separatorBuilder: (_, __) => const Divider(
                            height: 1,
                            thickness: 1,
                            indent: 18,
                            endIndent: 18,
                            color: Color(0xFFDDD8CE),
                          ),
                          itemBuilder: (context, index) {
                            final thread = threads[index];
                            return Dismissible(
                              key: ValueKey(thread.threadId),
                              direction: DismissDirection.endToStart,
                              background: Container(
                                alignment: Alignment.centerRight,
                                padding: const EdgeInsets.only(right: 20),
                                color: Colors.red,
                                child: const Icon(Icons.delete, color: Colors.white),
                              ),
                              confirmDismiss: (_) async {
                                return await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('Delete conversation?'),
                                    content: Text(
                                        'Delete all messages with ${_displayName(thread.sender)}?'),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(ctx, false),
                                        child: const Text('Cancel'),
                                      ),
                                      TextButton(
                                        onPressed: () => Navigator.pop(ctx, true),
                                        child: const Text('Delete',
                                            style: TextStyle(color: Colors.red)),
                                      ),
                                    ],
                                  ),
                                );
                              },
                              onDismissed: (_) async {
                                await SmsService.deleteThread(thread.threadId);
                                await _refresh();
                              },
                              child: GestureDetector(
                                onLongPress: () => _showThreadOptions(thread),
                                child: _ThreadCard(
                                  thread: thread,
                                  threadMessages: _messages
                                      .where((m) => (m.threadId ?? 0) == thread.threadId)
                                      // When spam is enabled, exclude spam messages from
                                      // badge calculation so the thread shows "Safe Thread".
                                      .where((m) {
                                        if (_spamFolderEnabled &&
                                            m.isPhishing == true &&
                                            !m.isOutgoing &&
                                            !_restoredSpamThreadIds.contains(m.threadId)) {
                                          return false;
                                        }
                                        return true;
                                      })
                                      .toList(),
                                  displayName: _displayName(thread.sender),
                                  unreadCount: _unreadCounts[thread.threadId.toString()] ?? 0,
                                  shareAnonymousData: _shareAnonymousData,
                                  showDetectionPopup: _showDetectionPopup,
                                  autoScanEnabled: _autoScanEnabled,
                                  scanCutoffMs: _scanCutoffMs,
                                  onScan: () => _scanThread(thread.threadId),
                                  onTap: () async {
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => ConversationPage(
                                          threadId: thread.threadId,
                                          sender: thread.sender,
                                          displayName: _displayName(thread.sender),
                                          spamFolderEnabled: _spamFolderEnabled,
                                          restoredFromSpam: _restoredSpamThreadIds.contains(thread.threadId),
                                        ),
                                      ),
                                    );
                                    _refresh(); // refresh after returning
                                  },
                                  onChangeShareAnonymousData: (v) {
                                    setState(() => _shareAnonymousData = v);
                                    widget.onChangeShareAnonymousData(v);
                                  },
                                  onChangeShowDetectionPopup: (v) {
                                    setState(() => _showDetectionPopup = v);
                                    widget.onChangeShowDetectionPopup(v);
                                  },
                                ),
                              ),
                            );
                          },
                        ),
                  // ── Tab 1: Contacts ───────────────────────────────────
                  const ContactsPage(embedded: true),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Custom animated pill-style bottom navigation bar ──────────────────────────

class _CustomNavBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onTap;

  const _CustomNavBar({required this.selectedIndex, required this.onTap});

  static const _items = [
    (icon: Icons.chat_bubble_outline, activeIcon: Icons.chat_bubble, label: 'Conversations'),
    (icon: Icons.contacts_outlined, activeIcon: Icons.contacts, label: 'Contacts'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF0EDE3),
        border: Border(
          top: BorderSide(color: Color(0xFFDDD8CE), width: 1),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (int i = 0; i < _items.length; i++)
                _NavPill(
                  icon: _items[i].icon,
                  activeIcon: _items[i].activeIcon,
                  label: _items[i].label,
                  selected: selectedIndex == i,
                  onTap: () => onTap(i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavPill extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NavPill({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeInOut,
        padding: EdgeInsets.symmetric(
          horizontal: selected ? 18 : 14,
          vertical: 10,
        ),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF1A7A72).withOpacity(0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(30),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Icon(
                selected ? activeIcon : icon,
                key: ValueKey(selected),
                size: 22,
                color: selected
                    ? const Color(0xFF1A7A72)
                    : const Color(0xFF9E9E9E),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeInOut,
              child: selected
                  ? Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        label,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1A7A72),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────

class _TopHeader extends StatelessWidget {
  const _TopHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1A7A72),
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 16),
      child: const Row(
        children: [
          Icon(Icons.phishing, color: Color(0xFF888880), size: 28),
          SizedBox(width: 6),
          Text(
            "Phish",
            style: TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.bold,
              shadows: [Shadow(blurRadius: 6, color: Colors.black26, offset: Offset(0, 2))],
            ),
          ),
          Text(
            "Sense",
            style: TextStyle(
              color: Color(0xFFE0A800),
              fontSize: 28,
              fontWeight: FontWeight.bold,
              shadows: [Shadow(blurRadius: 6, color: Colors.black26, offset: Offset(0, 2))],
            ),
          ),
        ],
      ),
    );
  }
}

class _DefaultSmsBanner extends StatelessWidget {
  final VoidCallback onSetDefault;

  const _DefaultSmsBanner({required this.onSetDefault});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFFFFF3CD),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: Color(0xFF856404), size: 20),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              "PhishSense is not your default SMS app",
              style: TextStyle(
                color: Color(0xFF856404),
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          TextButton(
            onPressed: onSetDefault,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF1A7A72),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text(
              "Set Default",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanProgressBanner extends StatelessWidget {
  final double progress;

  const _ScanProgressBanner({required this.progress});

  @override
  Widget build(BuildContext context) {
    final pct = (progress * 100).round();
    return Container(
      width: double.infinity,
      color: const Color(0xFFE8F5E9),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.security_outlined, color: Color(0xFF1A7A72), size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Scanning messages… $pct%',
                  style: const TextStyle(
                    color: Color(0xFF1A7A72),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Text(
                '$pct%',
                style: const TextStyle(
                  color: Color(0xFF1A7A72),
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: const Color(0xFFB2DFDB),
              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF1A7A72)),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThreadCard extends StatelessWidget {
  final _Thread thread;
  final List<SmsMessage> threadMessages;
  final String displayName;
  final int unreadCount;
  final bool shareAnonymousData;
  final bool showDetectionPopup;
  final bool? autoScanEnabled;
  final int scanCutoffMs;
  final VoidCallback onTap;
  final VoidCallback? onScan;
  final ValueChanged<bool> onChangeShareAnonymousData;
  final ValueChanged<bool> onChangeShowDetectionPopup;

  const _ThreadCard({
    required this.thread,
    required this.threadMessages,
    required this.displayName,
    required this.unreadCount,
    required this.shareAnonymousData,
    required this.showDetectionPopup,
    this.autoScanEnabled,
    this.scanCutoffMs = 0,
    required this.onTap,
    this.onScan,
    required this.onChangeShareAnonymousData,
    required this.onChangeShowDetectionPopup,
  });

  String _formatTime(int timestampMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return DateFormat('MMM d').format(dt);
  }

  @override
  Widget build(BuildContext context) {
    // Use latest visible message for preview (threadMessages already excludes
    // phishing when spam folder is enabled).
    final msg = threadMessages.isNotEmpty
        ? threadMessages.reduce((a, b) => a.timestamp > b.timestamp ? a : b)
        : thread.latestMessage;
    final hasUnread = unreadCount > 0;

    final incomingMsgs = threadMessages.where((m) => !m.isOutgoing).toList();
    final isPending = incomingMsgs.any((m) => m.classificationPending);
    final anyUnscanned = !isPending && incomingMsgs.any((m) => m.isPhishing == null);
    final isPhishing = incomingMsgs.any((m) => m.isPhishing == true);
    final isUnscanned = anyUnscanned;

    final outsideScanRange = autoScanEnabled == true &&
        scanCutoffMs > 0 &&
        incomingMsgs.any((m) => m.timestamp < scanCutoffMs && m.isPhishing == null);
    final showScanButton = isUnscanned &&
        onScan != null &&
        (autoScanEnabled == false || outsideScanRange);

    final badgeColor = isPending
        ? Colors.grey
        : isUnscanned
            ? const Color(0xFF9E9E9E)
            : isPhishing
                ? const Color(0xFFF2554F)
                : const Color(0xFF06C85E);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 10, 0, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            displayName,
                            style: TextStyle(
                              fontSize: 15,
                              color: const Color(0xFF5A5A5A),
                              fontWeight: hasUnread ? FontWeight.bold : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (hasUnread) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1A7A72),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '$unreadCount',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: showScanButton ? onScan : null,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: showScanButton ? const Color(0xFF1A7A72) : badgeColor,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: isPending
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (showScanButton)
                                  const Padding(
                                    padding: EdgeInsets.only(right: 4),
                                    child: Icon(Icons.search, size: 12, color: Colors.white),
                                  ),
                                Text(
                                  showScanButton
                                      ? "Scan this thread"
                                      : isUnscanned
                                          ? "Not Scanned"
                                          : isPhishing
                                              ? "Phishing Detected"
                                              : "Safe Thread",
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w500,
                                    height: 1,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFF3EEE4),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(width: 10, color: badgeColor),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 12, 16, 10),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Expanded(
                                  child: Text(
                                    msg.isOutgoing ? 'You: ${msg.body}' : msg.body,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      height: 1.4,
                                      color: Colors.black87,
                                      fontWeight: hasUnread ? FontWeight.bold : FontWeight.normal,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  _formatTime(msg.timestamp),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF666666),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
