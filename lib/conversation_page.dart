import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/sms_service.dart';
import 'services/phishing_detector.dart';
import 'services/phishing_indicators.dart';
import 'compose.dart';

class ConversationPage extends StatefulWidget {
  final int threadId;
  final String sender;
  final String displayName;
  final bool spamFolderEnabled;
  final bool restoredFromSpam;

  const ConversationPage({
    super.key,
    required this.threadId,
    required this.sender,
    required this.displayName,
    this.spamFolderEnabled = false,
    this.restoredFromSpam = false,
  });

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  final List<SmsMessage> _messages = [];
  final TextEditingController _replyCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  bool _loading = true;
  bool _sending = false;
  StreamSubscription<SmsMessage>? _smsSub;
  StreamSubscription<Map<String, dynamic>>? _sentStatusSub;

  final Map<String, Map<String, dynamic>> _labelCache = {};
  bool? _autoScanEnabled;
  int _scanCutoffMs = 0;

  // Phishing navigation
  int _phishingNavIndex = 0;
  final Map<String, GlobalKey> _phishingKeys = {};
  bool _phishingBannerExpanded = false;
  final ValueNotifier<String?> _highlightNotifier = ValueNotifier(null);

  // Scroll-to-bottom button
  bool _showScrollToBottom = false;

  // Lazy item list for ListView.builder — invalidated whenever _messages changes.
  // Each entry is either an int (message index) or a DateTime (date separator).
  List<Object>? _cachedItems;

  bool get _isShortCode {
    final digits = widget.sender.replaceAll(RegExp(r'\D'), '');
    return digits.length >= 3 &&
        digits.length <= 6 &&
        !widget.sender.startsWith('+');
  }

  int get _charCount => _replyCtrl.text.length;

  // Cached so repeated calls within a single interaction cost O(1) not O(n).
  List<SmsMessage>? _phishingMessagesCache;
  // When spam folder is enabled and this thread hasn't been restored, phishing
  // messages are hidden in the conversation (they live in the spam folder instead).
  bool get _hidePhishingInView =>
      widget.spamFolderEnabled && !widget.restoredFromSpam;

  List<SmsMessage> get _phishingMessages =>
      _phishingMessagesCache ??= _messages
          .where((m) => !m.isOutgoing && m.isPhishing == true)
          .where((m) => !_hidePhishingInView)
          .toList();

  String _phishingKey(SmsMessage msg) =>
      'phish_${msg.id?.toString() ?? '${msg.sender}_${msg.timestamp}'}';

  // Lazily-computed list of items for ListView.builder.
  // Each entry is an int (index into _messages) or a DateTime (date separator).
  List<Object> get _items {
    if (_cachedItems != null) return _cachedItems!;
    final items = <Object>[];
    for (int i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      // Hide phishing messages in conversation when spam folder is active.
      if (_hidePhishingInView && !m.isOutgoing && m.isPhishing == true) continue;
      items.add(i);
      final dt = DateTime.fromMillisecondsSinceEpoch(_messages[i].timestamp);
      final msgDate = DateTime(dt.year, dt.month, dt.day);
      final bool isOldestOfDay;
      if (i == 0) {
        isOldestOfDay = true;
      } else {
        final prevDt = DateTime.fromMillisecondsSinceEpoch(_messages[i - 1].timestamp);
        isOldestOfDay = msgDate != DateTime(prevDt.year, prevDt.month, prevDt.day);
      }
      if (isOldestOfDay) items.add(dt);
    }
    _cachedItems = items;
    return items;
  }

  Future<void> _scrollToPhishing(int index) async {
    final phishing = _phishingMessages;
    if (phishing.isEmpty || index < 0 || index >= phishing.length) return;
    final msg = phishing[index];
    final keyStr = _phishingKey(msg);

    _highlightNotifier.value = keyStr;
    Future.delayed(const Duration(milliseconds: 2000), () {
      if (mounted && _highlightNotifier.value == keyStr) {
        _highlightNotifier.value = null;
      }
    });

    if (!mounted || !_scrollCtrl.hasClients) return;

    // Fast path: widget already in the render tree.
    final ctx = _phishingKeys[keyStr]?.currentContext;
    if (ctx != null) {
      await Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          alignment: 0.5);
      return;
    }

    // Slow path: widget is outside cacheExtent.
    // Find this message's index in _messages.
    final msgListIdx = _messages
        .indexWhere((m) => m.id == msg.id && m.timestamp == msg.timestamp);
    if (msgListIdx == -1) return;

    // Find its index in _items (newest-first, reverse list).
    final items = _items;
    final itemIdx = items.indexWhere((e) => e is int && e == msgListIdx);
    if (itemIdx == -1) return;

    // Proportional estimate using actual maxScrollExtent — far more accurate
    // than a fixed-px-per-item guess, especially with variable-height bubbles.
    final maxScroll = _scrollCtrl.position.maxScrollExtent;
    final estimated = items.length <= 1
        ? maxScroll
        : (maxScroll * itemIdx / (items.length - 1)).clamp(0.0, maxScroll);

    // Jump instantly (avoids animation overshooting past the target).
    _scrollCtrl.jumpTo(estimated);

    // Retry ensureVisible up to 6 times (~480 ms total).
    // If the widget is still outside cache after the jump, nudge the scroll
    // alternately above/below the estimate until it enters the render tree.
    for (int attempt = 0; attempt < 6; attempt++) {
      await Future.delayed(const Duration(milliseconds: 80));
      if (!mounted || !_scrollCtrl.hasClients) return;

      final ctx2 = _phishingKeys[keyStr]?.currentContext;
      if (ctx2 != null) {
        await Scrollable.ensureVisible(ctx2,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
            alignment: 0.5);
        return;
      }

      // Nudge: scan outward from the estimate on alternate sides.
      final nudge = (attempt + 1) * 800.0 * (attempt.isEven ? 1.0 : -1.0);
      _scrollCtrl.jumpTo((estimated + nudge).clamp(0.0, maxScroll));
    }
  }

  @override
  void initState() {
    super.initState();
    _loadThread();
    _replyCtrl.addListener(() => setState(() {}));
    _scrollCtrl.addListener(() {
      if (!_scrollCtrl.hasClients) return;
      // With reverse:true, position 0 = bottom (latest). Show button when scrolled up > 200px.
      final shouldShow = _scrollCtrl.position.pixels > 200;
      if (shouldShow != _showScrollToBottom) {
        setState(() => _showScrollToBottom = shouldShow);
      }
    });
    _smsSub = SmsService.incomingSms.listen((msg) async {
      if (_normalizeNumber(msg.sender) != _normalizeNumber(widget.sender) &&
          msg.threadId != widget.threadId) return;
      // Deduplicate: if a message with the same sender+timestamp is already
      // in the list (e.g. fired by both SMS_RECEIVED and SMS_DELIVER), ignore it.
      if (_messages.any((m) =>
          !m.isOutgoing &&
          _normalizeNumber(m.sender) == _normalizeNumber(msg.sender) &&
          m.timestamp == msg.timestamp)) return;
      setState(() {
        _phishingMessagesCache = null;
        _cachedItems = null;
        _messages.add(msg);
      });
      _scrollToBottom(postFrame: true);
      await _scanMessage(msg);
    });

    _sentStatusSub = SmsService.sentStatusUpdates.listen((event) {
      final success = event['success'] as bool? ?? true;
      if (success) return;
      final to        = event['to'] as String? ?? '';
      final body      = event['body'] as String? ?? '';
      final timestamp = (event['timestamp'] as num?)?.toInt() ?? 0;
      if (_normalizeNumber(to) != _normalizeNumber(widget.sender)) return;
      setState(() {
        _cachedItems = null;
        final idx = _messages.lastIndexWhere((m) =>
          m.isOutgoing &&
          m.body == body &&
          (m.timestamp - timestamp).abs() < 10000);
        if (idx != -1) {
          _messages[idx] = _messages[idx].copyWith(sendFailed: true);
        }
      });
    });
  }

  @override
  void dispose() {
    _smsSub?.cancel();
    _sentStatusSub?.cancel();
    _replyCtrl.dispose();
    _scrollCtrl.dispose();
    _highlightNotifier.dispose();
    super.dispose();
  }

  static String _normalizeNumber(String number) {
    final digits = number.replaceAll(RegExp(r'\D'), '');
    return digits.length >= 10 ? digits.substring(digits.length - 10) : digits;
  }

  static String _labelKey(SmsMessage msg) =>
      'lbl_${_normalizeNumber(msg.sender)}_${msg.timestamp}';

  Future<void> _loadLabelCache() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      if (!key.startsWith('lbl_')) continue;
      final val = prefs.getString(key);
      if (val == null) continue;
      final parts = val.split(',');
      if (parts.length >= 2) {
        _labelCache[key] = {
          'isPhishing': parts[0] == '1',
          'confidence': double.tryParse(parts[1]) ?? 0.0,
          'verificationPending': parts.length > 2 && parts[2] == '1',
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
          verificationPending: cached['verificationPending'] as bool? ?? false,
        );
      }
    }
  }

  Future<void> _saveLabel(SmsMessage msg, bool isPhishing, double confidence) async {
    if (confidence == 0.0) return;
    final prefs = await SharedPreferences.getInstance();
    final key = _labelKey(msg);
    await prefs.setString(key, '${isPhishing ? '1' : '0'},${confidence.toStringAsFixed(4)}');
    _labelCache[key] = {'isPhishing': isPhishing, 'confidence': confidence};
  }

  // Match a message by id when available, otherwise by sender+timestamp
  // (stream messages have id==null until the DB write completes).
  int _findMsg(SmsMessage msg) {
    if (msg.id != null) {
      final i = _messages.indexWhere((m) => m.id == msg.id);
      if (i != -1) return i;
    }
    return _messages.indexWhere((m) =>
      m.timestamp == msg.timestamp &&
      _normalizeNumber(m.sender) == _normalizeNumber(msg.sender));
  }

  Future<void> _scanMessage(SmsMessage msg) async {
    final idx = _findMsg(msg);
    if (idx == -1) return;
    setState(() {
      _phishingMessagesCache = null;
      _cachedItems = null;
      _messages[idx] = _messages[idx].copyWith(classificationPending: true);
    });
    final result = await PhishingDetector.classify(msg.body);
    if (!mounted) return;
    await _saveLabel(msg, result.isPhishing, result.confidence);
    setState(() {
      _phishingMessagesCache = null;
      _cachedItems = null;
      final i = _findMsg(msg);
      if (i != -1) {
        _messages[i] = _messages[i].copyWith(
          isPhishing: result.confidence > 0.0 ? result.isPhishing : null,
          confidence: result.confidence > 0.0 ? result.confidence : null,
          classificationPending: false,
        );
      }
    });
  }

  Future<void> _scanAllUnscanned() async {
    for (final msg in List<SmsMessage>.from(_messages)) {
      if (msg.isOutgoing || msg.isPhishing != null || msg.classificationPending) continue;
      // Only auto-scan messages within the chosen time range; others get manual scan
      if (_scanCutoffMs > 0 && msg.timestamp < _scanCutoffMs) continue;
      await _scanMessage(msg);
      if (!mounted) return;
    }
  }

  Future<void> _loadThread() async {
    final prefs = await SharedPreferences.getInstance();
    _autoScanEnabled = prefs.getBool('auto_scan_enabled');
    _scanCutoffMs = prefs.getInt('scan_cutoff_ms') ?? 0;

    var msgs = await SmsService.readThread(widget.threadId);
    // If the thread is empty, the SMS_DELIVER DB write may still be in flight.
    // Retry once after a short wait before showing "No messages".
    if (msgs.isEmpty) {
      await Future.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;
      msgs = await SmsService.readThread(widget.threadId);
    }
    if (!mounted) return;

    await _loadLabelCache();
    setState(() {
      _phishingMessagesCache = null;
      _cachedItems = null;
      _messages.addAll(msgs);
      _applyLabels(_messages);
      _loading = false;
    });
    SmsService.markThreadRead(widget.threadId);

    if (_autoScanEnabled == true) {
      await _scanAllUnscanned();
    }

    if (mounted) {
      setState(() => _phishingNavIndex = 0);
      // reverse:true ListView already starts at position 0 (bottom) — no scroll needed
    }
  }

  void _scrollToBottom({bool postFrame = false}) {
    // With reverse:true, position 0.0 is the bottom (latest messages).
    // postFrame:true only when called immediately after setState (e.g. new message received).
    void doScroll() {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          0.0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    }

    if (postFrame) {
      WidgetsBinding.instance.addPostFrameCallback((_) => doScroll());
    } else {
      doScroll();
    }
  }

  Future<void> _send() async {
    final body = _replyCtrl.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final sentAt = DateTime.now().millisecondsSinceEpoch;
      await SmsService.sendSms(widget.sender, body);
      _replyCtrl.clear();
      // Show the message immediately without waiting for the DB
      setState(() {
        _phishingMessagesCache = null;
      _cachedItems = null;
        _messages.add(SmsMessage(
          sender: widget.sender,
          body: body,
          timestamp: sentAt,
          isOutgoing: true,
          threadId: widget.threadId,
        ));
      });
      _scrollToBottom(postFrame: true);
      // Give the SMS content provider time to write the record, then sync.
      // Use merge (not clear+replace) so any stream-received messages still
      // being scanned in the background are not wiped mid-flight.
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      final msgs = await SmsService.readThread(widget.threadId);
      if (!mounted) return;
      setState(() {
        _phishingMessagesCache = null;
      _cachedItems = null;
        // Add DB messages not already present (match by id, or sender+timestamp)
        for (final dbMsg in msgs) {
          final exists = _messages.any((m) =>
            (m.id != null && m.id == dbMsg.id) ||
            (_normalizeNumber(m.sender) == _normalizeNumber(dbMsg.sender) &&
             m.timestamp == dbMsg.timestamp));
          if (!exists) _messages.add(dbMsg);
        }
        // Remove the optimistic outgoing message if the DB version is now present
        _messages.removeWhere((m) =>
          m.id == null && m.isOutgoing &&
          msgs.any((db) =>
            _normalizeNumber(db.sender) == _normalizeNumber(m.sender) &&
            (db.timestamp - m.timestamp).abs() < 5000));
        _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        _applyLabels(_messages);
      });
      if (_autoScanEnabled == true) unawaited(_scanAllUnscanned());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _call() async {
    final status = await Permission.phone.request();
    if (!mounted) return;
    if (status.isGranted) {
      SmsService.makeCall(widget.sender);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Phone call permission is required to make calls.')),
      );
    }
  }

  String _formatTime(int timestampMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inDays < 1) return DateFormat('HH:mm').format(dt);
    if (diff.inDays < 7) return DateFormat('EEE HH:mm').format(dt);
    return DateFormat('MMM d, HH:mm').format(dt);
  }

  Widget _buildDateSeparator(DateTime dt) {
    final now = DateTime.now();
    String label;
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      label = 'Today';
    } else if (dt.year == now.year && now.difference(dt).inDays == 1) {
      label = 'Yesterday';
    } else if (dt.year == now.year) {
      label = DateFormat('MMMM d').format(dt);
    } else {
      label = DateFormat('MMMM d, y').format(dt);
    }
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 12, color: Color(0xFF666666)),
        ),
      ),
    );
  }

  Widget _buildIndicatorChip(PhishingIndicator indicator) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: indicator.color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: indicator.color.withOpacity(0.35), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(indicator.icon, size: 9, color: indicator.color),
          const SizedBox(width: 3),
          Text(
            indicator.label,
            style: TextStyle(
              fontSize: 9,
              color: indicator.color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScanBadge(SmsMessage msg) {
    if (msg.verificationPending) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFF757575),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Text(
          'Verification in Progress',
          style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600),
        ),
      );
    }
    if (msg.classificationPending) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF999999)),
          ),
          SizedBox(width: 5),
          Text('Scanning…', style: TextStyle(fontSize: 10, color: Color(0xFF999999))),
        ],
      );
    }
    if (msg.isPhishing == true) {
      var indicators = PhishingIndicatorDetector.detect(msg.body);
      if (indicators.isEmpty) {
        indicators = [
          const PhishingIndicator(
            label: 'Suspicious content',
            icon: Icons.warning_amber_rounded,
            color: Color(0xFFD32F2F),
          ),
        ];
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () => _showReportDialog(msg),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFF2554F),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.warning_amber_rounded, size: 11, color: Colors.white),
                  const SizedBox(width: 3),
                  Text(
                    msg.confidence != null && msg.confidence! > 0
                        ? 'Phishing (${(msg.confidence! * 100).toStringAsFixed(0)}%)'
                        : 'Phishing Detected',
                    style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            runSpacing: 3,
            children: indicators.map(_buildIndicatorChip).toList(),
          ),
        ],
      );
    }
    if (msg.isPhishing == false) {
      return GestureDetector(
        onTap: () => _showReportDialog(msg),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFF06C85E),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle_outline, size: 11, color: Colors.white),
              const SizedBox(width: 3),
              const Text(
                'Safe',
                style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      );
    }
    // Unscanned in manual mode, or outside the auto-scan time range
    final outsideScanRange = _autoScanEnabled == true &&
        _scanCutoffMs > 0 &&
        msg.timestamp < _scanCutoffMs;
    if (_autoScanEnabled == false || outsideScanRange) {
      return GestureDetector(
        onTap: () => _scanMessage(msg),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFF1A7A72),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.search, size: 11, color: Colors.white),
              SizedBox(width: 3),
              Text(
                'Tap to Scan',
                style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildBubble(SmsMessage msg, int index) {
    final isOutgoing = msg.isOutgoing;

    // Register a GlobalKey for phishing messages so we can scroll to them
    if (!isOutgoing && msg.isPhishing == true) {
      _phishingKeys.putIfAbsent(_phishingKey(msg), () => GlobalKey());
    }

    final bubble = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.75,
      ),
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: isOutgoing ? const Color(0xFF1A7A72) : Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: isOutgoing
              ? const Radius.circular(18)
              : const Radius.circular(4),
          bottomRight: isOutgoing
              ? const Radius.circular(4)
              : const Radius.circular(18),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment:
            isOutgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Text(
            msg.body,
            style: TextStyle(
              fontSize: 15,
              color: isOutgoing ? Colors.white : Colors.black87,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _formatTime(msg.timestamp),
            style: TextStyle(
              fontSize: 11,
              color: isOutgoing ? Colors.white70 : const Color(0xFF999999),
            ),
          ),
        ],
      ),
    );

    final keyedBubble = GestureDetector(
      onLongPress: () => _showMessageOptions(msg),
      child: Align(
        alignment: isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
        child: isOutgoing
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  bubble,
                  if (msg.sendFailed)
                    Padding(
                      padding: const EdgeInsets.only(right: 4, top: 2, bottom: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.error_outline, size: 11, color: Color(0xFFE53935)),
                          SizedBox(width: 3),
                          Text(
                            'Failed to send',
                            style: TextStyle(
                              fontSize: 10,
                              color: Color(0xFFE53935),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  bubble,
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 2),
                    child: _buildScanBadge(msg),
                  ),
                ],
              ),
      ),
    );

    // Build the final widget (with highlight animation for phishing messages)
    Widget result;
    if (!isOutgoing && msg.isPhishing == true) {
      final keyStr = _phishingKey(msg);
      // ValueListenableBuilder means only THIS bubble re-renders when the
      // highlight changes — the rest of the conversation list is untouched.
      result = ValueListenableBuilder<String?>(
        valueListenable: _highlightNotifier,
        builder: (_, highlighted, __) {
          final isHighlighted = highlighted == keyStr;
          return AnimatedContainer(
            key: _phishingKeys[keyStr],
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              color: isHighlighted
                  ? const Color(0xFFF2554F).withOpacity(0.13)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
            ),
            padding: EdgeInsets.all(isHighlighted ? 5 : 0),
            child: keyedBubble,
          );
        },
      );
    } else {
      result = keyedBubble;
    }

    return result;
  }


  void _showReportDialog(SmsMessage msg) {
    final isPhishing = msg.isPhishing == true;
    final reasons = isPhishing
        ? [
            'This is from a trusted sender',
            'This is a legitimate promotional message',
            'This is a known service or OTP message',
            'The link in this message is safe',
            'Other reason',
          ]
        : [
            'This message seems suspicious',
            'Message requests personal information',
            'Message contains suspicious links',
            'Message is impersonating a known brand',
            'Other reason',
          ];

    String? selected;
    final otherCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final isOther = selected == 'Other reason';
          final canSubmit = selected != null && (!isOther || otherCtrl.text.trim().isNotEmpty);
          return AlertDialog(
            title: const Text(
              'Report Inaccurate Detection',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Why do you think this detection is wrong?',
                    style: TextStyle(fontSize: 13, color: Color(0xFF555555)),
                  ),
                  const SizedBox(height: 8),
                  ...reasons.map(
                    (r) => RadioListTile<String>(
                      value: r,
                      groupValue: selected,
                      title: Text(r, style: const TextStyle(fontSize: 13)),
                      onChanged: (v) => setDialogState(() => selected = v),
                      activeColor: const Color(0xFF1A7A72),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    ),
                  ),
                  if (isOther) ...[
                    const SizedBox(height: 6),
                    TextField(
                      controller: otherCtrl,
                      autofocus: true,
                      maxLines: 3,
                      decoration: InputDecoration(
                        hintText: 'Describe the issue…',
                        hintStyle: const TextStyle(fontSize: 13, color: Color(0xFFAAAAAA)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: Color(0xFF1A7A72)),
                        ),
                      ),
                      style: const TextStyle(fontSize: 13),
                      onChanged: (_) => setDialogState(() {}),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel', style: TextStyle(color: Color(0xFF888888))),
              ),
              TextButton(
                onPressed: canSubmit
                    ? () async {
                        final reason = isOther ? otherCtrl.text.trim() : selected!;
                        Navigator.pop(ctx);
                        await _reportInaccurate(msg, reason);
                      }
                    : null,
                child: Text(
                  'Submit',
                  style: TextStyle(
                    color: canSubmit ? const Color(0xFFE53935) : const Color(0xFFBBBBBB),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _reportInaccurate(SmsMessage msg, String reason) async {
    // Persist the report: keep original label, mark as verificationPending
    final prefs = await SharedPreferences.getInstance();
    final key = _labelKey(msg);
    final isPhishing = msg.isPhishing == true;
    final confidence = msg.confidence ?? 0.0;
    await prefs.setString(
      key,
      '${isPhishing ? '1' : '0'},${confidence.toStringAsFixed(4)},1',
    );
    await prefs.setString('${key}_reason', reason);
    _labelCache[key] = {
      'isPhishing': isPhishing,
      'confidence': confidence,
      'verificationPending': true,
    };

    final idx = _messages.indexWhere(
      (m) => m.id == msg.id && m.timestamp == msg.timestamp,
    );
    if (idx != -1 && mounted) {
      setState(() {
        _phishingMessagesCache = null;
      _cachedItems = null;
        _messages[idx] = _messages[idx].copyWith(verificationPending: true);
      });
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Report submitted. We\'ll review this detection.'),
          backgroundColor: Color(0xFF1A7A72),
        ),
      );
    }
  }

  void _showMessageOptions(SmsMessage msg) {
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
              leading: const Icon(Icons.copy_outlined, color: Color(0xFF1A7A72)),
              title: const Text('Copy text'),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: msg.body));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied to clipboard')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.forward_outlined, color: Color(0xFF1A7A72)),
              title: const Text('Forward'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ComposePage(initialBody: msg.body),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Delete message', style: TextStyle(color: Colors.red)),
              onTap: () async {
                Navigator.pop(ctx);
                if (msg.id != null) {
                  await SmsService.deleteMessage(msg.id!);
                  final msgs = await SmsService.readThread(widget.threadId);
                  if (mounted) {
                    setState(() {
                      _phishingMessagesCache = null;
      _cachedItems = null;
                      _messages.clear();
                      _messages.addAll(msgs);
                    });
                  }
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildPhishingBanner() {
    final phishing = _phishingMessages;
    if (phishing.isEmpty) return const SizedBox.shrink();
    final count = phishing.length;
    final current = _phishingNavIndex.clamp(0, count - 1);

    return Container(
      color: const Color(0xFFF2554F),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$count phishing message${count == 1 ? '' : 's'} detected',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (!_phishingBannerExpanded) ...[
            // Collapsed: show View button
            GestureDetector(
              onTap: () {
                setState(() {
                  _phishingBannerExpanded = true;
                  _phishingNavIndex = 0;
                });
                _scrollToPhishing(0);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.22),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'View',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ] else ...[
            // Expanded: < 1/2 > navigation
            GestureDetector(
              onTap: current > 0
                  ? () {
                      final next = current - 1;
                      setState(() => _phishingNavIndex = next);
                      _scrollToPhishing(next);
                    }
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Icon(
                  Icons.chevron_left,
                  size: 22,
                  color: current > 0 ? Colors.white : Colors.white38,
                ),
              ),
            ),
            Text(
              '${current + 1}/$count',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            GestureDetector(
              onTap: current < count - 1
                  ? () {
                      final next = current + 1;
                      setState(() => _phishingNavIndex = next);
                      _scrollToPhishing(next);
                    }
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Icon(
                  Icons.chevron_right,
                  size: 22,
                  color: current < count - 1 ? Colors.white : Colors.white38,
                ),
              ),
            ),
            const SizedBox(width: 4),
            // Close navigation
            GestureDetector(
              onTap: () => setState(() => _phishingBannerExpanded = false),
              child: const Icon(Icons.close, size: 16, color: Colors.white70),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F4EC),
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A7A72),
        foregroundColor: Colors.white,
        elevation: 0,
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.displayName,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            if (widget.displayName != widget.sender)
              Text(
                widget.sender,
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
          ],
        ),
        actions: [
          if (!_isShortCode)
            IconButton(
              icon: const Icon(Icons.call),
              onPressed: _call,
              tooltip: 'Call',
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
        children: [
          if (!_loading) _buildPhishingBanner(),
          Expanded(
            child: Stack(
              children: [
                _loading
                    ? const Center(
                        child: CircularProgressIndicator(color: Color(0xFF1A7A72)),
                      )
                    : _messages.isEmpty
                        ? const Center(
                            child: Text(
                              'No messages in this conversation.',
                              style: TextStyle(color: Color(0xFF888888)),
                            ),
                          )
                        : ListView.builder(
                            controller: _scrollCtrl,
                            reverse: true,
                            cacheExtent: 4000,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 16),
                            itemCount: _items.length,
                            itemBuilder: (context, idx) {
                              final item = _items[idx];
                              if (item is int) {
                                return _buildBubble(_messages[item], item);
                              }
                              return _buildDateSeparator(item as DateTime);
                            },
                          ),
                if (_showScrollToBottom)
                  Positioned(
                    bottom: 12,
                    right: 12,
                    child: GestureDetector(
                      onTap: _scrollToBottom,
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A7A72),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.18),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            color: Colors.white,
            padding: EdgeInsets.only(
              left: 12,
              right: 8,
              top: 8,
              bottom: MediaQuery.of(context).viewInsets.bottom + 8,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFFF3EEE4),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: TextField(
                          controller: _replyCtrl,
                          maxLines: null,
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            hintText: 'Type a message…',
                            hintStyle: TextStyle(color: Color(0xFFBBBBBB)),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _send,
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: const BoxDecoration(
                          color: Color(0xFF1A7A72),
                          shape: BoxShape.circle,
                        ),
                        child: _sending
                            ? const Padding(
                                padding: EdgeInsets.all(10),
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(
                                Icons.send_rounded,
                                color: Colors.white,
                                size: 20,
                              ),
                      ),
                    ),
                  ],
                ),
                if (_replyCtrl.text.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 60, top: 2),
                    child: Text(
                      _charCount > 160
                          ? '$_charCount (${(_charCount / 153).ceil()} SMS)'
                          : '$_charCount/160',
                      style: TextStyle(
                        fontSize: 11,
                        color: _charCount > 160
                            ? Colors.orange
                            : const Color(0xFF999999),
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ),
              ],
            ),
          ),
        ],
        ),
      ),
    );
  }
}

