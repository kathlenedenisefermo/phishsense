import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'profile.dart';
import 'report_tracker.dart';
import 'package:share_plus/share_plus.dart';
import 'customize_chatroom.dart';
import 'report_model.dart';
import 'services/phishing_detector.dart';

const String kSpamWallpaperDefault = '8';

class IOSMessagesPage extends StatefulWidget {
  final String name;
  const IOSMessagesPage({super.key, required this.name});
  @override
  State<IOSMessagesPage> createState() => _IOSMessagesPageState();
}

class _IOSMessagesPageState extends State<IOSMessagesPage> {
  static const _channel        = MethodChannel('com.phishsense/appgroup');
  static const _manualKey      = 'manual_scan_logs';
  static const _spamKey        = 'spam_folder_logs';
  static const _spamEnabledKey = 'spam_folder_enabled';
  static const _deviceIdKey    = 'phishsense_device_id';

  List<Map<String, dynamic>> _allMessages     = [];
  List<Map<String, dynamic>> _threads         = [];
  List<Map<String, dynamic>> _filteredThreads = [];

  bool   _loading     = true;
  bool   _spamEnabled = false;
  int    _activeTab   = 0;
  String _searchQuery = '';
  String _deviceId    = '';
  final  _searchCtrl  = TextEditingController();
  final  _scaffoldKey = GlobalKey<ScaffoldState>();
  StreamSubscription<QuerySnapshot>? _globalReportSub;
  StreamSubscription<QuerySnapshot>? _reportBadgeSub;
  List<QueryDocumentSnapshot>? _cachedReportDocs;
  int _unviewedReportCount = 0;

  @override
  void initState() {
    super.initState();
    _loadSpamEnabled();
    _loadMessages();
    _initDeviceAndCheckReports();
    _searchCtrl.addListener(() {
      setState(() {
        _searchQuery     = _searchCtrl.text.toLowerCase();
        _filteredThreads = _applySearch(_threads);
      });
    });
  }

  @override
  void dispose() {
    _globalReportSub?.cancel();
    _reportBadgeSub?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── Device ID + report status check ───────────────────────────────────────

  Future<void> _initDeviceAndCheckReports() async {
    final p  = await SharedPreferences.getInstance();
    var id   = p.getString(_deviceIdKey);
    if (id == null || id.isEmpty) {
      id = DateTime.now().millisecondsSinceEpoch.toString() +
          '_' + (1000 + (DateTime.now().microsecond % 9000)).toString();
      await p.setString(_deviceIdKey, id);
    }
    if (mounted) setState(() => _deviceId = id!);
    _startGlobalReportListener(id!);
    _startReportBadgeListener(id!);
  }

  void _startReportBadgeListener(String deviceId) {
    _reportBadgeSub?.cancel();
    if (deviceId.isEmpty) return;
    _reportBadgeSub = FirebaseFirestore.instance
        .collection('model_feedback')
        .where('deviceId', isEqualTo: deviceId)
        .snapshots()
        .listen((snap) {
      _cachedReportDocs = snap.docs;
      _refreshInboxBadge();
      _applyLabelUpdatesFromSnapshot(snap.docs);
    }, onError: (e) => debugPrint('Report badge listener error: $e'));
  }

  // Applies corrected labels from reviewed Firestore reports directly to the
  // in-memory thread list so the thread badge (Safe Thread / Phishing Detected)
  // reflects the latest developer decision without requiring the user to open
  // and close the conversation page.
  Future<void> _applyLabelUpdatesFromSnapshot(
      List<QueryDocumentSnapshot> docs) async {
    if (_spamEnabled) return; // spam folder handles its own label logic
    const reviewedStatuses = {'verified', 'validated', 'trained'};
    bool changed = false;
    for (final doc in docs) {
      final data          = doc.data() as Map<String, dynamic>;
      final status        = data['status']?.toString() ?? '';
      if (!reviewedStatuses.contains(status)) continue;
      final msgTime       = (data['messageId'] ?? data['messageTime'] ?? '').toString();
      final originalLabel = (data['originalLabel'] ?? '').toString().toLowerCase();
      if (msgTime.isEmpty) continue;
      final finalLabel = originalLabel == 'phishing' ? 'Safe' : 'Phishing';
      for (final msg in _allMessages) {
        if (msg['time']?.toString() == msgTime &&
            (msg['label'] ?? '').toString() != finalLabel) {
          msg['label'] = finalLabel;
          changed = true;
        }
      }
    }
    if (changed && mounted) {
      setState(() {
        _threads         = _buildThreads(_allMessages);
        _filteredThreads = _applySearch(_threads);
      });
      await _persistManualScans(_allMessages);
    }
  }

  Future<void> _refreshInboxBadge() async {
    final docs = _cachedReportDocs;
    if (docs == null) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('viewed_report_ids');
    final viewed = raw != null && raw.isNotEmpty
        ? (jsonDecode(raw) as List).cast<String>().toSet()
        : <String>{};
    const reviewedStatuses = {'trained', 'verified', 'validated', 'rejected'};
    final count = docs.where((doc) {
      final data   = doc.data() as Map<String, dynamic>;
      final status = data['status']?.toString() ?? '';
      final src    = (data['source'] ?? 'inbox').toString();
      final isInboxReport = src == 'inbox' || !_spamEnabled;
      return reviewedStatuses.contains(status)
          && !viewed.contains(doc.id)
          && isInboxReport;
    }).length;
    if (mounted) setState(() => _unviewedReportCount = count);
  }

  void _startGlobalReportListener(String deviceId) {
    // No per-message tracking without messageId in Firebase
    _globalReportSub?.cancel();
  }

  Future<void> _applyLabelFromFirebase({
    required String messageId,
    required String newLabel,
  }) async {
    final p = await SharedPreferences.getInstance();
    final manRaw = p.getString(_manualKey);
    if (manRaw != null && manRaw.isNotEmpty) {
      final man = (jsonDecode(manRaw) as List).cast<Map<String, dynamic>>();
      bool changed = false;
      for (final m in man) {
        if (m['time']?.toString() == messageId) {
          m['label'] = newLabel;
          changed = true;
        }
      }
      if (changed) await p.setString(_manualKey, jsonEncode(man));
    }
    final spamRaw = p.getString(_spamKey);
    if (spamRaw != null && spamRaw.isNotEmpty) {
      final spam = (jsonDecode(spamRaw) as List).cast<Map<String, dynamic>>();
      bool changed = false;
      for (final m in spam) {
        if (m['time']?.toString() == messageId) {
          m['label'] = newLabel;
          changed = true;
        }
      }
      if (changed) await p.setString(_spamKey, jsonEncode(spam));
    }
  }

  Future<void> _loadSpamEnabled() async {
    final p = await SharedPreferences.getInstance();
    if (mounted) setState(() => _spamEnabled = p.getBool(_spamEnabledKey) ?? false);
  }

  Future<void> _onSpamToggled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_spamEnabledKey, v);
    if (v) {
      final man    = await _getManualScans();
      final toSpam = man.where((m) => (m['label'] ?? '').toString().toLowerCase() == 'phishing').toList();
      for (final m in toSpam) await saveSpamMessage(m);
      final remaining = man.where((m) => (m['label'] ?? '').toString().toLowerCase() != 'phishing').toList();
      await p.setString(_manualKey, jsonEncode(remaining));
    } else {
      final spam = await getSpamMessages();
      final man  = await _getManualScans();
      man.insertAll(0, spam);
      if (man.length > 200) man.removeRange(200, man.length);
      await p.setString(_manualKey, jsonEncode(man));
      await p.setString(_spamKey, jsonEncode([]));
    }
    if (mounted) {
      setState(() => _spamEnabled = v);
      if (_scaffoldKey.currentState?.isEndDrawerOpen == true) Navigator.of(context).pop();
      await _loadMessages();
    }
  }

  void _showCenterNotice(String msg) {
    showDialog(
      context: context, barrierDismissible: true, barrierColor: Colors.black.withOpacity(.15),
      builder: (_) => Material(
        color: Colors.transparent,
        child: Center(child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 48),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(40),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(.12), blurRadius: 12, offset: const Offset(0, 4))]),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.info_outline, color: Color(0xFF1A7A72), size: 20),
            const SizedBox(width: 10),
            Flexible(child: Text(msg, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500,
                color: Color(0xFF333333), decoration: TextDecoration.none))),
          ]),
        )),
      ),
    );
    Future.delayed(const Duration(milliseconds: 2000), () {
      if (mounted) Navigator.of(context, rootNavigator: true).maybePop();
    });
  }

  List<Map<String, dynamic>> _applySearch(List<Map<String, dynamic>> t) {
    if (_searchQuery.isEmpty) return t;
    return t.where((th) {
      final s = (th['sender'] as String).toLowerCase();
      if (s.contains(_searchQuery)) return true;
      final msgs = th['messages'] as List<Map<String, dynamic>>? ?? [];
      return msgs.any((msg) =>
          (msg['message'] ?? '').toString().toLowerCase().contains(_searchQuery));
    }).toList();
  }

  Widget _highlightText(String text, String query, {TextStyle? baseStyle, int? maxLines}) {
    final base = baseStyle ?? const TextStyle(fontSize: 15, color: Colors.black87);
    if (query.isEmpty) return Text(text, style: base, maxLines: maxLines, overflow: maxLines != null ? TextOverflow.ellipsis : null);
    final lower = text.toLowerCase();
    final lowerQ = query.toLowerCase();
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
        text: text.substring(idx, idx + query.length),
        style: const TextStyle(backgroundColor: Color(0xFFFFE57F), color: Colors.black, fontWeight: FontWeight.bold),
      ));
      start = idx + query.length;
    }
    return RichText(
      text: TextSpan(style: base, children: spans),
      maxLines: maxLines,
      overflow: maxLines != null ? TextOverflow.ellipsis : TextOverflow.clip,
    );
  }

  Future<List<Map<String, dynamic>>> _getManualScans() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_manualKey);
    if (raw == null || raw.isEmpty) return [];
    return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  }

  Future<void> _saveManualScan(Map<String, dynamic> e) async {
    final p  = await SharedPreferences.getInstance();
    final ex = await _getManualScans();
    ex.insert(0, e);
    if (ex.length > 100) ex.removeRange(100, ex.length);
    await p.setString(_manualKey, jsonEncode(ex));
  }

  Future<void> _persistManualScans(List<Map<String, dynamic>> list) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_manualKey, jsonEncode(list.where((e) => (e['source'] ?? '') == 'manual').toList()));
  }

  static Future<List<Map<String, dynamic>>> getSpamMessages() async {
    final p   = await SharedPreferences.getInstance();
    final raw = p.getString(_spamKey);
    if (raw == null || raw.isEmpty) return [];
    return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  }

  static Future<void> saveSpamMessage(Map<String, dynamic> e) async {
    final p  = await SharedPreferences.getInstance();
    final ex = await getSpamMessages();
    if (!ex.any((m) => m['time'] == e['time'])) {
      ex.insert(0, e);
      if (ex.length > 200) ex.removeRange(200, ex.length);
      await p.setString(_spamKey, jsonEncode(ex));
    }
  }

  Future<void> _loadMessages() async {
    List<Map<String, dynamic>> ext = [], man = [];
    if (!kIsWeb) {
      try {
        final json = await _channel.invokeMethod<String>('getFilteredLogs');
        if (json != null && json.isNotEmpty) ext = (jsonDecode(json) as List).cast<Map<String, dynamic>>();
      } catch (_) {}
    }
    try { man = await _getManualScans(); } catch (_) {}
    final spamTimes = (await getSpamMessages()).map((m) => m['time']?.toString() ?? '').toSet();
    final all = [...ext, ...man]
        .where((m) => !spamTimes.contains(m['time']?.toString() ?? ''))
        .toList()
      ..sort((a, b) {
        final ta = DateTime.tryParse(a['time'] ?? '') ?? DateTime(0);
        final tb = DateTime.tryParse(b['time'] ?? '') ?? DateTime(0);
        return tb.compareTo(ta);
      });
    if (mounted) setState(() {
      _allMessages = all; _threads = _buildThreads(all);
      _filteredThreads = _applySearch(_threads); _loading = false;
    });
  }

  List<Map<String, dynamic>> _buildThreads(List<Map<String, dynamic>> msgs) {
    final Map<String, List<Map<String, dynamic>>> g = {};
    for (final m in msgs) g.putIfAbsent((m['sender'] ?? 'Unknown').toString(), () => []).add(m);
    return g.entries.map((e) {
      final sorted = List<Map<String, dynamic>>.from(e.value)
        ..sort((a, b) {
          final ta = DateTime.tryParse(a['time'] ?? '') ?? DateTime(0);
          final tb = DateTime.tryParse(b['time'] ?? '') ?? DateTime(0);
          return tb.compareTo(ta);
        });
      return {
        'sender': e.key, 'messages': sorted, 'latest': sorted.first, 'count': sorted.length,
        'hasPhishing': sorted.any((m) => (m['label'] ?? '').toString().toLowerCase() == 'phishing'),
        'phishingCount': sorted.where((m) => (m['label'] ?? '').toString().toLowerCase() == 'phishing').length,
      };
    }).toList()
      ..sort((a, b) {
        final ta = DateTime.tryParse((a['latest'] as Map)['time'] ?? '') ?? DateTime(0);
        final tb = DateTime.tryParse((b['latest'] as Map)['time'] ?? '') ?? DateTime(0);
        return tb.compareTo(ta);
      });
  }

  Future<void> _deleteThread(String sender) async {
    final updated = _allMessages.where((m) => (m['sender'] ?? '').toString() != sender).toList();
    setState(() { _allMessages = updated; _threads = _buildThreads(updated); _filteredThreads = _applySearch(_threads); });
    await _persistManualScans(updated);
  }

  Future<bool> _confirmDeleteThread(String sender) async {
    bool confirmed = false;
    await showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFFF6F4EC),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: const Text('Delete Conversation', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
      content: Text('Delete all messages from "$sender"?', style: const TextStyle(fontSize: 14, color: Color(0xFF555555))),
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      actions: [
        TextButton(onPressed: () { confirmed = false; Navigator.pop(ctx); },
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF1A7A72)))),
        ElevatedButton(onPressed: () { confirmed = true; Navigator.pop(ctx); },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF2554F), foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            child: const Text('Delete')),
      ],
    ));
    return confirmed;
  }

  /// Strips non-digit characters and normalises a Philippine mobile number to
  /// the `09XXXXXXXXX` (11-digit) form.  Returns null if [s] is not a PH number.
  static String? _normalizePHNumber(String s) {
    final d = s.replaceAll(RegExp(r'\D'), '');
    if (d.startsWith('639') && d.length == 12) return '0${d.substring(2)}';
    if (d.startsWith('9')   && d.length == 10) return '0$d';
    if (d.startsWith('0')   && d.length == 11) return d;
    return null;
  }

  /// Returns the canonical sender already stored in [_allMessages] that is
  /// equivalent to [entered], or [entered] itself if no match is found.
  /// Equivalence rules:
  ///   • PH phone numbers: normalised to `09XXXXXXXXX` before comparing.
  ///   • Names: case-insensitive.
  String _canonicalSender(String entered) {
    if (entered.isEmpty) return entered;
    final enteredPhone = _normalizePHNumber(entered);
    final enteredLower = entered.toLowerCase();
    for (final msg in _allMessages) {
      final existing = (msg['sender'] ?? '').toString();
      if (existing.isEmpty) continue;
      final existingPhone = _normalizePHNumber(existing);
      if (enteredPhone != null && existingPhone != null &&
          enteredPhone == existingPhone) return existing;
      if (enteredPhone == null && existingPhone == null &&
          existing.toLowerCase() == enteredLower) return existing;
    }
    return entered;
  }

  void _openScanSheet() {
    showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (_) => _ScanBottomSheet(onResult: (result) async {
        // Resolve to the canonical sender already in the inbox (handles
        // case differences and PH number format variants).
        final rawSender = (result['sender'] ?? '').toString();
        final canonical = _canonicalSender(rawSender);
        result['sender'] = canonical;

        final isPhishing = (result['label'] as String).toLowerCase() == 'phishing';
        if (isPhishing && _spamEnabled) {
          await saveSpamMessage(result);
          if (mounted) _showPhishingPopup(result);
        } else {
          await _saveManualScan(result);
          if (mounted) setState(() {
            _allMessages.insert(0, result);
            _threads = _buildThreads(_allMessages);
            _filteredThreads = _applySearch(_threads);
          });
        }
      }),
    );
  }

  void _showPhishingPopup(Map<String, dynamic> result) {
    showDialog(context: context, builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(color: const Color(0xFFF6F4EC), borderRadius: BorderRadius.circular(24)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 64, height: 64,
              decoration: BoxDecoration(color: const Color(0xFFF2554F).withOpacity(.12), shape: BoxShape.circle),
              child: const Icon(Icons.warning_rounded, color: Color(0xFFF2554F), size: 36)),
          const SizedBox(height: 16),
          const Text('Phishing Detected', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('This message from "${result['sender']}" was flagged as phishing and moved to your Spam Folder.',
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, color: Color(0xFF555555), height: 1.5)),
          const SizedBox(height: 20),
          SizedBox(width: double.infinity, height: 46,
              child: ElevatedButton(
                  onPressed: () { Navigator.pop(ctx); _openSpamFolder(); },
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1A7A72), foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                  child: const Text('View Spam Folder', style: TextStyle(fontWeight: FontWeight.w600)))),
          const SizedBox(height: 10),
          SizedBox(width: double.infinity, height: 46,
              child: OutlinedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF1A7A72),
                      side: const BorderSide(color: Color(0xFF1A7A72)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                  child: const Text('Dismiss'))),
        ]),
      ),
    ));
  }

  void _openSpamFolder() {
    if (!_spamEnabled) { _showCenterNotice('Spam Folder is disabled.'); return; }
    Navigator.push(context, MaterialPageRoute(
        builder: (_) => SpamFolderPage(
          formatTime: _formatTime,
          deviceId: _deviceId,
          spamEnabled: _spamEnabled,
          onOpenConversation: _openConversationFromReport,
          onOpenReportTracker: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ReportTrackerPage(
                deviceId: _deviceId,
                source: 'spam',
              ),
            ),
          ),
        )))
        .then((_) => _loadMessages());
  }

  String _formatTime(String? iso) {
    if (iso == null) return '';
    try {
      final dt = DateTime.parse(iso).toLocal();
      final diff = DateTime.now().difference(dt);
      if (diff.inMinutes < 1) return 'now';
      if (diff.inHours < 1)   return '${diff.inMinutes}m ago';
      if (diff.inDays < 1)    return '${diff.inHours}h ago';
      if (diff.inDays < 7)    return '${diff.inDays}d ago';
      return DateFormat('MMM d').format(dt);
    } catch (_) { return ''; }
  }

  // ── Navigate to conversation from report card ─────────────────────────────

  void _openConversationFromReport(String sender, String messageBody) async {
    await _loadMessages();

    Map<String, dynamic>? matchedThread;
    String? matchedMessageTime;

    // Search by sender first
    for (final t in _threads) {
      if (sender.isNotEmpty && (t['sender'] as String) != sender) continue;
      final msgs = t['messages'] as List<Map<String, dynamic>>;
      for (final m in msgs) {
        final body = (m['message'] ?? '').toString().trim();
        if (body == messageBody.trim()) {
          matchedThread = t;
          matchedMessageTime = m['time']?.toString();
          break;
        }
      }
      if (matchedThread != null) break;
    }

    // Fallback: search all threads ignoring sender
    if (matchedThread == null) {
      for (final t in _threads) {
        final msgs = t['messages'] as List<Map<String, dynamic>>;
        for (final m in msgs) {
          final body = (m['message'] ?? '').toString().trim();
          if (body == messageBody.trim()) {
            matchedThread = t;
            matchedMessageTime = m['time']?.toString();
            break;
          }
        }
        if (matchedThread != null) break;
      }
    }

    if (matchedThread == null) {
      _showCenterNotice('Conversation not found.');
      return;
    }

    if (!mounted) return;

    final threadSender = matchedThread['sender'] as String;
    final threadMessages = List<Map<String, dynamic>>.from(
        matchedThread['messages'] as List<Map<String, dynamic>>);

    if (!mounted) return;
    Navigator.of(_scaffoldKey.currentContext!, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => _ConversationPage(
          messages: threadMessages,
          sender: threadSender,
          formatTime: _formatTime,
          deviceId: _deviceId,
          highlightMessageTime: matchedMessageTime,
          spamFolderEnabled: false,
          onDeleteThread: () async {
            if (await _confirmDeleteThread(threadSender)) {
              await _deleteThread(threadSender);
              if (mounted) Navigator.pop(context);
            }
          },
          onDeleteMessages: (times) async {
            final updated = _allMessages.where((m) => !times.contains(m['time']?.toString())).toList();
            if (mounted) setState(() {
              _allMessages     = updated;
              _threads         = _buildThreads(updated);
              _filteredThreads = _applySearch(_threads);
            });
            await _persistManualScans(updated);
          },
        ),
      ),
    ).then((_) => _loadMessages());
  }

  @override
  Widget build(BuildContext context) {
    final threadCount = _filteredThreads.length;
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: const Color(0xFFF6F4EC),
      endDrawer: SizedBox(
        width: MediaQuery.of(context).size.width * 0.82,
        child: ProfilePage(name: widget.name, spamFolderEnabled: _spamEnabled, onSpamToggled: _onSpamToggled),
      ),
      body: SafeArea(bottom: false, child: Column(children: [
        Container(color: const Color(0xFF1A7A72), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(children: [Image.asset('assets/images/phishsense_logo.png', height: 56, fit: BoxFit.contain)])),
        if (_activeTab == 0)
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 12, 8, 0),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Messaging', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w500)),
              if (!_loading) Text(
                  threadCount == 0 ? 'No conversations' : '$threadCount conversation${threadCount == 1 ? '' : 's'}',
                  style: const TextStyle(fontSize: 13, color: Color(0xFF888888))),
            ]),
            const Spacer(),
            IconButton(
                tooltip: _spamEnabled ? 'Spam Folder' : 'Spam Folder (disabled)',
                icon: Icon(Icons.folder, color: _spamEnabled ? const Color(0xFF1A7A72) : const Color(0xFFBBBBBB)),
                onPressed: _openSpamFolder),
            IconButton(
                tooltip: 'Profile',
                icon: const Icon(Icons.person, color: Color(0xFF1A7A72)),
                onPressed: () => _scaffoldKey.currentState?.openEndDrawer()),
          ]),
        ),
        const SizedBox(height: 10),
        if (_activeTab == 0)
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
          child: Container(
            decoration: BoxDecoration(color: const Color(0xFFECE9DF), borderRadius: BorderRadius.circular(14)),
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(fontSize: 15),
              decoration: InputDecoration(
                hintText: 'Search',
                hintStyle: const TextStyle(color: Color(0xFF999999), fontSize: 15),
                prefixIcon: const Icon(Icons.search, color: Color(0xFF999999), size: 20),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close, color: Color(0xFF999999), size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() {
                            _searchQuery = '';
                            _filteredThreads = _applySearch(_threads);
                          });
                        },
                      )
                    : null,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
            ),
          ),
        ),
        Expanded(child: _activeTab == 1 ? _buildReportsTab() : _loading
            ? const Center(child: CircularProgressIndicator(color: Color(0xFF1A7A72)))
            : _filteredThreads.isEmpty
            ? Center(child: Padding(padding: const EdgeInsets.all(32),
            child: Text(
                _searchQuery.isNotEmpty ? 'No results for "$_searchQuery".'
                    : 'No scanned messages yet.\n\nUse the Scan Message button below.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF888888), fontSize: 15, height: 1.6))))
            : ListView.separated(
            padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
            itemCount: _filteredThreads.length,
            separatorBuilder: (_, __) => const Divider(height: 1, indent: 20, endIndent: 20, color: Color(0xFFDDD8CE)),
            itemBuilder: (ctx, i) {
              final thread      = _filteredThreads[i];
              final sender        = thread['sender'] as String;
              final latest        = thread['latest'] as Map<String, dynamic>;
              final count         = thread['count'] as int;
              final hasPhishing   = thread['hasPhishing'] as bool;
              final phishingCount = (thread['phishingCount'] as int? ?? 0);
              final labelText = count >= 2
                  ? (hasPhishing ? 'Phishing Detected ($phishingCount)' : 'Safe Thread')
                  : (hasPhishing ? 'Phishing' : 'Safe');
              final allMsgs     = thread['messages'] as List<Map<String, dynamic>>? ?? [];
              final previewMsg  = _searchQuery.isNotEmpty
                  ? (allMsgs.firstWhere(
                      (m) => (m['message'] ?? '').toString().toLowerCase().contains(_searchQuery),
                      orElse: () => latest,
                    ))
                  : latest;
              final time        = _formatTime(previewMsg['time'] as String?);
              final message     = (previewMsg['message'] ?? '').toString();
              return Dismissible(
                key: ValueKey('thread_$sender'),
                direction: DismissDirection.endToStart,
                background: Container(
                    color: const Color(0xFFF2554F), alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: const [
                      Icon(Icons.delete_outline, color: Colors.white, size: 28),
                      SizedBox(height: 4),
                      Text('Delete', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                    ])),
                confirmDismiss: (_) async {
                  if (await _confirmDeleteThread(sender)) { await _deleteThread(sender); return true; }
                  return false;
                },
                child: InkWell(
                  onLongPress: () {
                    showModalBottomSheet(
                      context: context,
                      backgroundColor: Colors.transparent,
                      builder: (_) => _OptionsSheet(children: [
                        _SheetAction(
                          icon: Icons.delete_outline,
                          iconColor: const Color(0xFFF2554F),
                          label: 'Delete Conversation',
                          labelColor: const Color(0xFFF2554F),
                          onTap: () async {
                            Navigator.pop(context);
                            if (await _confirmDeleteThread(sender)) {
                              await _deleteThread(sender);
                            }
                          },
                        ),
                      ]),
                    );
                  },
                  onTap: () => Navigator.push(context, MaterialPageRoute(
                      builder: (_) => _ConversationPage(
                          messages: thread['messages'] as List<Map<String, dynamic>>,
                          sender: sender, formatTime: _formatTime, deviceId: _deviceId,
                          onDeleteThread: () async {
                            if (await _confirmDeleteThread(sender)) {
                              await _deleteThread(sender);
                              if (mounted) Navigator.pop(context);
                            }
                          },
                          onDeleteMessages: (times) async {
                            final updated = _allMessages.where((m) => !times.contains(m['time']?.toString())).toList();
                            if (mounted) setState(() {
                              _allMessages     = updated;
                              _threads         = _buildThreads(updated);
                              _filteredThreads = _applySearch(_threads);
                            });
                            await _persistManualScans(updated);
                          },
                          ))).then((_) => _loadMessages()),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        _highlightText(sender, _searchQuery,
                            baseStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w400, color: Colors.black87)),
                        if (count > 1) ...[
                          const SizedBox(width: 6),
                          Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(color: const Color(0xFF1A7A72), borderRadius: BorderRadius.circular(10)),
                              child: Text('$count', style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600))),
                        ],
                        const Spacer(),
                        Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            decoration: BoxDecoration(
                                color: hasPhishing ? const Color(0xFFF2554F) : const Color(0xFF06C85E),
                                borderRadius: BorderRadius.circular(20)),
                            child: Text(labelText,
                                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600))),
                      ]),
                      const SizedBox(height: 8),
                      Container(
                        decoration: BoxDecoration(color: const Color(0xFFF3EEE4), borderRadius: BorderRadius.circular(14)),
                        clipBehavior: Clip.hardEdge,
                        child: IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Container(width: 5, color: hasPhishing ? const Color(0xFFF2554F) : const Color(0xFF06C85E)),
                          Expanded(child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              child: Row(children: [
                                Expanded(child: _highlightText(message, _searchQuery,
                                    baseStyle: const TextStyle(fontSize: 14, color: Colors.black87, fontWeight: FontWeight.w400),
                                    maxLines: 2)),
                                const SizedBox(width: 8),
                                Text(time, style: const TextStyle(fontSize: 12, color: Color(0xFF999999))),
                              ]))),
                        ])),
                      ),
                    ]),
                  ),
                ),
              );
            })),
        _buildBottomNav(),
      ])),
      floatingActionButtonAnimator: FloatingActionButtonAnimator.scaling,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: _activeTab == 1 ? null : Padding(
        padding: const EdgeInsets.only(bottom: 65),
        child: FloatingActionButton.extended(
            onPressed: _openScanSheet, backgroundColor: const Color(0xFF1A7A72),
            icon: const Icon(Icons.search, color: Colors.white),
            label: const Text('Scan Message', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600))),
      ),
    );
  }

  Widget _buildReportsTab() {
    if (_deviceId.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF1A7A72)));
    }
    return Material(
      color: Colors.transparent,
      child: RefreshIndicator(
        color: const Color(0xFF1A7A72),
        onRefresh: () async => setState(() {}),
        child: ReportTrackerBody(
          deviceId: _deviceId,
          source: 'inbox',
          spamFolderEnabled: _spamEnabled,
          showHeader: true,
          onOpenConversation: _openConversationFromReport,
          onHideReviewedChanged: (_) {},
          onViewedChanged: _refreshInboxBadge,
        ),
      ),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Color(0x1A000000), blurRadius: 12, offset: Offset(0, -4))],
        borderRadius: BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            _buildNavTab(index: 0, icon: Icons.chat_bubble_outline, label: 'Messages',
                badge: _threads.length),
            _buildNavTab(index: 1, icon: Icons.assignment_outlined, label: 'Reports', badge: _unviewedReportCount),
          ]),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  Widget _buildNavTab({required int index, required IconData icon, required String label, int? badge}) {
    final isActive = _activeTab == index;
    final hasBadge = badge != null && badge > 0;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _activeTab = index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          decoration: BoxDecoration(
            color: isActive ? const Color(0xFF1A7A72).withOpacity(.15) : Colors.transparent,
            borderRadius: BorderRadius.circular(30),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Padding(
                    padding: EdgeInsets.only(top: hasBadge ? 6 : 0, right: hasBadge ? 8 : 0),
                    child: Icon(icon, size: 16, color: isActive ? const Color(0xFF1A7A72) : const Color(0xFF888888)),
                  ),
                  if (hasBadge)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF2554F),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          badge > 99 ? '99+' : '$badge',
                          style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(label, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                      color: isActive ? const Color(0xFF1A7A72) : const Color(0xFF888888)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Phishing keyword highlighter
// ─────────────────────────────────────────────────────────────────────────────

/// Highlights phishing-related keywords in message text with bold red styling.
Widget buildPhishingHighlightedText(String text) {
  // Common phishing trigger words/patterns
  final phishingKeywords = [
    // Financial / payment
    'gcash', 'maya', 'paypal', 'credit card', 'debit card', 'bank account',
    'transfer', 'withdraw', 'deposit', 'load', 'wallet',
    // Action urgency
    'click here', 'click the link', 'tap here', 'tap the link',
    'verify now', 'confirm now', 'claim now', 'redeem now', 'act now',
    'limited time', 'expires', 'urgent', 'immediately', 'asap',
    // Rewards / prizes
    'you won', "you've won", 'congratulations', 'winner', 'prize',
    'reward', 'free', 'gift', 'cash', 'piso', 'php',
    // Credentials
    'password', 'otp', 'one-time', 'pin', 'passcode', 'username',
    'login', 'log in', 'sign in', 'verify', 'verification',
    // Suspicious links
    'http://', 'bit.ly', 'tinyurl', 't.co',
    // Impersonation
    'google_ph', 'gcash', 'dito', 'smart', 'globe', 'sun cellular',
    'sss', 'pagibig', 'philhealth', 'bir', 'lto', 'nbi',
    'shopee', 'lazada', 'grab', 'foodpanda',
  ];

  final lowerText = text.toLowerCase();

  // Find all keyword matches with their positions
  final List<_KeywordMatch> matches = [];
  for (final kw in phishingKeywords) {
    int start = 0;
    while (true) {
      final idx = lowerText.indexOf(kw, start);
      if (idx == -1) break;
      // Check not already covered
      final end = idx + kw.length;
      final overlaps = matches.any((m) =>
      (idx >= m.start && idx < m.end) ||
          (end > m.start && end <= m.end));
      if (!overlaps) {
        matches.add(_KeywordMatch(start: idx, end: end));
      }
      start = idx + 1;
    }
  }

  if (matches.isEmpty) {
    return Text(text, style: const TextStyle(fontSize: 14, color: Colors.black87, height: 1.5));
  }

  matches.sort((a, b) => a.start.compareTo(b.start));

  final spans = <TextSpan>[];
  int cursor = 0;
  for (final m in matches) {
    if (m.start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, m.start)));
    }
    spans.add(TextSpan(
      text: text.substring(m.start, m.end),
      style: const TextStyle(
        color: Color(0xFFF2554F),
        fontWeight: FontWeight.w700,
      ),
    ));
    cursor = m.end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor)));
  }

  return RichText(
    text: TextSpan(
      style: const TextStyle(fontSize: 14, color: Colors.black87, height: 1.5),
      children: spans,
    ),
  );
}

class _KeywordMatch {
  final int start;
  final int end;
  const _KeywordMatch({required this.start, required this.end});
}

// ─────────────────────────────────────────────────────────────────────────────
// Conversation Page (Main Inbox)
// ─────────────────────────────────────────────────────────────────────────────

class _ConversationPage extends StatefulWidget {
  final List<Map<String, dynamic>> messages;
  final String sender;
  final String Function(String?) formatTime;
  final VoidCallback onDeleteThread;
  final Future<void> Function(List<String> times) onDeleteMessages;
  final String deviceId;
  final String? highlightMessageTime; // <── new: scroll to this message

  final bool spamFolderEnabled;

  const _ConversationPage({
    required this.messages,
    required this.sender,
    required this.formatTime,
    required this.onDeleteThread,
    required this.onDeleteMessages,
    required this.deviceId,
    this.highlightMessageTime,
    this.spamFolderEnabled = false,
  });
  @override
  State<_ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<_ConversationPage> {
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  late final List<GlobalKey> _itemKeys;
  bool   _searchActive   = false;
  String _query          = '';
  bool   _showScrollDown = false;
  int    _currentMatchIdx = 0;

  final Map<String, String> _reportStatus  = {};
  String get _statusKey => 'report_status_${widget.sender.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';
  final Map<String, String> _correctedLabel = {};
  final Set<String> _dismissedNotes = {};
  // Tracks which message is currently "reported-highlighted" from report card tap
  String? _reportHighlightTime;
  String get _correctedLabelKey  => 'corrected_label_${widget.sender.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';
  String get _dismissedNotesKey  => 'dismissed_notes_${widget.sender.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';
  StreamSubscription<QuerySnapshot>? _firestoreSub;

  bool _selectMode = false;
  final Set<int> _selectedIndices = {};
  final Set<int> _starredIndices = {};

  Color  _themeColor   = const Color(0xFF1A7A72);
  String _wallpaperKey = 'background';

  bool    _phishingNavActive    = false;
  int     _phishingNavIdx       = 0;
  String? _phishingHighlightTime;

  late List<Map<String, dynamic>> _localMessages;

  @override
  void initState() {
    super.initState();
    _localMessages = List.from(widget.messages);
    _itemKeys = List.generate(_localMessages.length, (_) => GlobalKey());
    _reportHighlightTime = widget.highlightMessageTime;
    _loadChatroomPrefs();
    _loadStatus().then((_) => _startRealtimeListener());
    _scrollCtrl.addListener(() {
      if (!_scrollCtrl.hasClients) return;
      final atBottom = _scrollCtrl.offset >= _scrollCtrl.position.maxScrollExtent - 80;
      if (mounted && _showScrollDown == atBottom) {
        setState(() => _showScrollDown = !atBottom);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.highlightMessageTime != null) {
        _scrollToHighlightedMessage();
      } else if (mounted && _scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  void _scrollToHighlightedMessage() {
    // Find index of the highlighted message in the reversed list
    final reversedMsgs = _localMessages.reversed.toList();
    final revIdx = reversedMsgs.indexWhere(
            (m) => m['time']?.toString() == widget.highlightMessageTime);
    if (revIdx == -1) {
      if (mounted && _scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
      return;
    }
    // origIdx in original list
    final origIdx = _localMessages.length - 1 - revIdx;
    final ctx = _itemKeys[origIdx].currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
        alignment: 0.3,
      );
    }
    // After a moment, pulse-clear the highlight
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _reportHighlightTime = null);
    });
  }

  @override
  void dispose() {
    _firestoreSub?.cancel();
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    _phishingHighlightTime = null;
    super.dispose();
  }

  void _startRealtimeListener() {
    if (widget.deviceId.isEmpty) return;
    _firestoreSub = FirebaseFirestore.instance
        .collection('model_feedback')
        .where('deviceId', isEqualTo: widget.deviceId)
        .where('sender', isEqualTo: widget.sender)
        .snapshots()
        .listen((snap) async {
      bool changed = false;
      const reviewedStatuses = {'verified', 'validated', 'trained', 'rejected'};

      final activeMessageIds = <String>{};
      for (final doc in snap.docs) {
        final data         = doc.data() as Map<String, dynamic>;
        final msgTime      = (data['messageId'] ?? data['messageTime'] ?? '').toString();
        final status       = data['status']?.toString() ?? 'under_review';
        final originalLabel = (data['originalLabel'] ?? '').toString().toLowerCase();
        if (msgTime.isNotEmpty) {
          activeMessageIds.add(msgTime);
          final prevStatus = _reportStatus[msgTime];
          if (prevStatus != status) {
            _reportStatus[msgTime] = status;
            changed = true;

            // Apply label + move when a review decision just arrived
            if (reviewedStatuses.contains(status) &&
                !reviewedStatuses.contains(prevStatus ?? '')) {
              await _applyReviewDecision(msgTime, status, originalLabel);
            }
          }
        }
      }

      // Remove any messageIds that no longer exist in Firestore (deleted without review)
      final deletedKeys = _reportStatus.keys
          .where((k) => !activeMessageIds.contains(k))
          .toList();
      for (final key in deletedKeys) {
        _reportStatus.remove(key);
        _correctedLabel.remove(key); // revert any corrected label too
        changed = true;
      }

      if (changed && mounted) {
        setState(() {});
        await _saveStatus();
      }
    }, onError: (e) => debugPrint('Realtime listener error: $e'));
  }

  Future<void> _loadChatroomPrefs() async {
    if (widget.spamFolderEnabled) {
      if (mounted) setState(() => _wallpaperKey = kSpamWallpaperDefault);
      return;
    }
    final prefs = await loadChatroomPrefs(widget.sender);
    if (!mounted) return;
    Color color = const Color(0xFF1A7A72);
    for (final t in kThemes) {
      if (t.key == prefs.theme) { color = t.color; break; }
    }
    setState(() {
      _themeColor   = color;
      _wallpaperKey = prefs.wallpaper;
    });
  }

  Color _wallpaperColorFromKey(String key) {
    for (final w in kWallpapers) {
      if (w.key == key) return w.color;
    }
    return const Color(0xFFF0EDE6);
  }

  Future<void> _loadStatus() async {
    final p    = await SharedPreferences.getInstance();
    final raw  = p.getString(_statusKey);
    final raw2 = p.getString(_correctedLabelKey);
    if (raw != null && raw.isNotEmpty) {
      final map = (jsonDecode(raw) as Map).cast<String, String>();
      if (mounted) setState(() { _reportStatus.clear(); _reportStatus.addAll(map); });
    }
    if (raw2 != null && raw2.isNotEmpty) {
      final map2 = (jsonDecode(raw2) as Map).cast<String, String>();
      if (mounted) setState(() { _correctedLabel.clear(); _correctedLabel.addAll(map2); });
    }
    final raw3 = p.getString(_dismissedNotesKey);
    if (raw3 != null && raw3.isNotEmpty) {
      final list3 = (jsonDecode(raw3) as List).cast<String>();
      if (mounted) setState(() { _dismissedNotes.clear(); _dismissedNotes.addAll(list3); });
    }
    await _syncStatusFromFirestore();
  }

  Future<void> _syncStatusFromFirestore() async {
    if (widget.deviceId.isEmpty) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('model_feedback')
          .where('deviceId', isEqualTo: widget.deviceId)
          .where('sender', isEqualTo: widget.sender)
          .get();
      bool changed = false;
      const reviewedStatuses = {'verified', 'validated', 'trained', 'rejected'};
      for (final doc in snap.docs) {
        final data          = doc.data() as Map<String, dynamic>;
        final msgTime       = (data['messageId'] ?? data['messageTime'] ?? '').toString();
        final status        = data['status']?.toString() ?? 'under_review';
        final originalLabel = (data['originalLabel'] ?? '').toString().toLowerCase();
        final prevStatus    = _reportStatus[msgTime];
        if (msgTime.isNotEmpty) {
          if (prevStatus != status) {
            _reportStatus[msgTime] = status;
            changed = true;
          }
          // If already reviewed but _correctedLabel not yet applied (e.g. app was
          // closed before the decision arrived, or report was validated via spam
          // folder page which never writes _correctedLabel), apply it now so the
          // bubble reflects the correct colour instead of the stale original label.
          if (reviewedStatuses.contains(status) && !_correctedLabel.containsKey(msgTime)) {
            await _applyReviewDecision(msgTime, status, originalLabel);
            changed = true;
          }
        }
      }
      if (changed && mounted) {
        setState(() {});
        await _saveStatus();
      }
    } catch (e) { debugPrint('Firestore sync error: $e'); }
  }

  Future<void> _applyReviewDecision(String msgTime, String status, String originalLabel) async {
    try {
      final p           = await SharedPreferences.getInstance();
      const spamKey     = 'spam_folder_logs';
      const manualKey   = 'manual_scan_logs';

      final spamRaw = p.getString(spamKey);
      final manRaw  = p.getString(manualKey);
      final spam    = spamRaw != null && spamRaw.isNotEmpty ? (jsonDecode(spamRaw) as List).cast<Map<String, dynamic>>() : <Map<String, dynamic>>[];
      final man     = manRaw  != null && manRaw.isNotEmpty  ? (jsonDecode(manRaw)  as List).cast<Map<String, dynamic>>() : <Map<String, dynamic>>[];

      final inboxIdx = man.indexWhere((m) => m['time']?.toString() == msgTime);
      final spamIdx  = spam.indexWhere((m) => m['time']?.toString() == msgTime);

      Map<String, dynamic>? entry;
      bool wasInInbox = false;
      if (inboxIdx != -1) { entry = Map<String, dynamic>.from(man[inboxIdx]);  wasInInbox = true; }
      else if (spamIdx != -1) { entry = Map<String, dynamic>.from(spam[spamIdx]); wasInInbox = false; }
      if (entry == null) return;

      entry['verifiedByCrew'] = true;
      final bool wasPhishing = originalLabel == 'phishing';
      final bool verified    = status == 'verified' || status == 'validated';
      final String finalLabel = verified
          ? (wasPhishing ? 'Safe' : 'Phishing')
          : (wasPhishing ? 'Phishing' : 'Safe');
      entry['label'] = finalLabel;
      _correctedLabel[msgTime] = finalLabel;
      final bool shouldBeInInbox = finalLabel.toLowerCase() == 'safe';

      if (wasInInbox) {
        man.removeAt(inboxIdx);
        if (shouldBeInInbox) {
          man.insert(0, entry);
          if (man.length > 200) man.removeRange(200, man.length);
          await p.setString(manualKey, jsonEncode(man));
        } else {
          await p.setString(manualKey, jsonEncode(man));
          if (!spam.any((m) => m['time']?.toString() == msgTime)) {
            spam.insert(0, entry);
            if (spam.length > 200) spam.removeRange(200, spam.length);
            await p.setString(spamKey, jsonEncode(spam));
          }
        }
      } else {
        spam.removeAt(spamIdx);
        if (shouldBeInInbox) {
          await p.setString(spamKey, jsonEncode(spam));
          if (!man.any((m) => m['time']?.toString() == msgTime)) {
            man.insert(0, entry);
            if (man.length > 200) man.removeRange(200, man.length);
            await p.setString(manualKey, jsonEncode(man));
          }
        } else {
          spam.insert(0, entry);
          if (spam.length > 200) spam.removeRange(200, spam.length);
          await p.setString(spamKey, jsonEncode(spam));
        }
      }
    } catch (e) { debugPrint('Apply review decision error: $e'); }
  }

  Future<void> _saveStatus() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_statusKey, jsonEncode(_reportStatus));
    await p.setString(_correctedLabelKey, jsonEncode(_correctedLabel));
    await p.setString(_dismissedNotesKey, jsonEncode(_dismissedNotes.toList()));
  }

  String? _statusFor(int i) {
    final time = _localMessages[i]['time']?.toString() ?? '';
    return _reportStatus[time];
  }

  String _labelFor(int i) {
    final time = _localMessages[i]['time']?.toString() ?? '';
    return _correctedLabel[time] ?? (_localMessages[i]['label'] ?? '').toString();
  }

  List<int> get _matchIndices {
    if (_query.isEmpty) return [];
    return List.generate(_localMessages.length, (i) => i)
        .where((i) => (_localMessages[i]['message'] ?? '').toString().toLowerCase().contains(_query.toLowerCase()))
        .toList();
  }

  List<int> get _phishingIndices =>
      List.generate(_localMessages.length, (i) => i)
          .where((i) => _labelFor(i).toLowerCase() == 'phishing')
          .toList();

  void _scrollToPhishingIdx(int idx) {
    final indices = _phishingIndices;
    if (indices.isEmpty) return;
    final origIdx   = indices[idx.clamp(0, indices.length - 1)];
    final msgTime   = _localMessages[origIdx]['time']?.toString();
    if (mounted) setState(() => _phishingHighlightTime = msgTime);
    final ctx = _itemKeys[origIdx].currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut, alignment: 0.1);
  }

  void _scrollToFirst() {
    _currentMatchIdx = 0;
    _scrollToMatchIdx(_currentMatchIdx);
  }

  void _scrollToMatchIdx(int idx) {
    final matches = _matchIndices;
    if (matches.isEmpty) return;
    final clampedIdx = idx.clamp(0, matches.length - 1);
    final ctx = _itemKeys[matches[clampedIdx]].currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
  }

  void _scrollToNext() {
    final matches = _matchIndices;
    if (matches.isEmpty) return;
    setState(() => _currentMatchIdx = (_currentMatchIdx + 1) % matches.length);
    _scrollToMatchIdx(_currentMatchIdx);
  }

  void _scrollToPrev() {
    final matches = _matchIndices;
    if (matches.isEmpty) return;
    setState(() => _currentMatchIdx = (_currentMatchIdx - 1 + matches.length) % matches.length);
    _scrollToMatchIdx(_currentMatchIdx);
  }

  Widget _highlightSearchText(String text, String query) {
    if (query.isEmpty) {
      // Use phishing keyword highlighting when not in search mode
      return buildPhishingHighlightedText(text);
    }
    final lower = text.toLowerCase(); final lowerQ = query.toLowerCase();
    final spans = <TextSpan>[]; int start = 0;
    while (true) {
      final idx = lower.indexOf(lowerQ, start);
      if (idx == -1) { if (start < text.length) spans.add(TextSpan(text: text.substring(start))); break; }
      if (idx > start) spans.add(TextSpan(text: text.substring(start, idx)));
      spans.add(TextSpan(text: text.substring(idx, idx + query.length),
          style: const TextStyle(backgroundColor: Color(0xFFFFE57F), color: Colors.black, fontWeight: FontWeight.bold)));
      start = idx + query.length;
    }
    return RichText(text: TextSpan(style: const TextStyle(fontSize: 14, color: Colors.black87, height: 1.5), children: spans));
  }

  // ── Redesigned Verification in Progress dialog ────────────────────────────

  void _showVerificationDialog(BuildContext ctx) {
    showDialog(
      context: ctx,
      barrierColor: Colors.black.withOpacity(.35),
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(0),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(.15), blurRadius: 24, offset: const Offset(0, 8))],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // ── Top colored header ──
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
              decoration: const BoxDecoration(
                color: Color(0xFF1A7A72),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(24),
                  topRight: Radius.circular(24),
                ),
              ),
              child: Column(children: [
                Container(
                  width: 60, height: 60,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.hourglass_top_rounded, color: Colors.white, size: 32),
                ),
                const SizedBox(height: 14),
                const Text('Verification in Progress',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
                const SizedBox(height: 6),
                Text('Your report has been submitted',
                    style: TextStyle(fontSize: 13, color: Colors.white.withOpacity(.8))),
              ]),
            ),

            // ── Body ──
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
              child: Column(children: [
                // Step indicators
                _VerifStep(
                  icon: Icons.check_circle_rounded,
                  iconColor: const Color(0xFF1A7A72),
                  title: 'Report Submitted',
                  subtitle: 'Your report has been received.',
                  done: true,
                ),
                _VerifStep(
                  icon: Icons.manage_search_rounded,
                  iconColor: const Color(0xFFE0A800),
                  title: 'Under Review',
                  subtitle: 'Our team is reviewing the detection.',
                  done: false,
                  active: true,
                ),
                _VerifStep(
                  icon: Icons.verified_rounded,
                  iconColor: const Color(0xFF888888),
                  title: 'Decision',
                  subtitle: 'Label will be updated once reviewed.',
                  done: false,
                  isLast: true,
                ),

                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1A7A72),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                    ),
                    child: const Text('Got it', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  void _showAlreadyReviewedDialog(
      BuildContext ctx,
      ReportModel report, {
        bool spamEnabled = false,
      }) {
    final isValidated          = report.status == ReportStatus.validated;
    final color                = isValidated ? const Color(0xFF1A7A72) : const Color(0xFFF2554F);
    final wasOriginallyPhishing = report.originalLabel.toLowerCase() == 'phishing';
    final reportedAsLabel      = wasOriginallyPhishing ? 'Safe' : 'Phishing';

    final String actionTaken;
    if (isValidated) {
      if (wasOriginallyPhishing) {
        actionTaken = 'Label updated to Safe — Moved to inbox';
      } else {
        actionTaken = spamEnabled
            ? 'Label updated to Phishing — Moved to spam'
            : 'Label updated to Phishing.';
      }
    } else {
      actionTaken = wasOriginallyPhishing
          ? 'Label remains Phishing.'
          : 'Label remains Safe.';
    }

    showDialog(
      context: ctx,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(.4),
      builder: (dlgCtx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF6F4EC),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [BoxShadow(
                color: Colors.black.withOpacity(.15),
                blurRadius: 24,
                offset: const Offset(0, 8))],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
              child: Row(children: [
                Icon(isValidated ? Icons.check_circle : Icons.cancel,
                    color: color, size: 28),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('Report Reviewed',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: color.withOpacity(.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: color.withOpacity(.2)),
                ),
                child: Text(
                  report.message.length > 120
                      ? '${report.message.substring(0, 120)}…'
                      : report.message,
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFF333333), height: 1.5),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Column(children: [
                _dialogDetailRow('Reported as:', reportedAsLabel, bold: true),
                const SizedBox(height: 8),
                _dialogDetailRow('Report Status:',
                    isValidated ? 'Accepted' : 'Rejected',
                    valueColor: color,
                    valueIcon: isValidated
                        ? Icons.check_circle
                        : Icons.cancel_outlined),
                const SizedBox(height: 8),
                _dialogDetailRow('Action taken:', actionTaken),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Column(children: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pop(dlgCtx);
                      final wasPhishing = report.originalLabel.toLowerCase() == 'phishing';
                      final isValidated = report.status == ReportStatus.validated;
                      // validated+wasPhishing = moved to inbox (safe)
                      // validated+!wasPhishing = moved to spam (phishing)
                      final movedToInbox = isValidated && wasPhishing;
                      final movedToSpam  = isValidated && !wasPhishing;

                      if (movedToInbox || movedToSpam) {
                        // Message was moved — navigate to where it now lives
                        // Pop back to root inbox first, then open conversation
                        Navigator.of(context).popUntil((route) => route.isFirst);
                        Future.delayed(const Duration(milliseconds: 300), () {
                          // Use the root-level openConversation via scaffold key
                          final rootState = context.findAncestorStateOfType<_IOSMessagesPageState>();
                          rootState?._openConversationFromReport(report.sender, report.message);
                        });
                      } else {
                        // Message stayed here — just scroll and highlight
                        setState(() => _reportHighlightTime = _localMessages
                            .firstWhere(
                              (m) => (m['message'] ?? '').toString().trim() ==
                              report.message.trim(),
                          orElse: () => {},
                        )['time']?.toString());
                        Future.delayed(const Duration(milliseconds: 200), () {
                          if (mounted) _scrollToHighlightedMessage();
                        });
                      }
                    },
                    icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                    label: const Text('Go to message',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 15)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: color,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(dlgCtx),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: color,
                      side: BorderSide(color: color.withOpacity(.5)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Got it',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 15)),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  // Helper for detail rows inside the already-reviewed dialog
  Widget _dialogDetailRow(String label, String value,
      {bool bold = false, Color? valueColor, IconData? valueIcon}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(label,
              style: const TextStyle(fontSize: 13, color: Color(0xFF888888))),
        ),
        Expanded(
          child: Row(children: [
            if (valueIcon != null) ...[
              Icon(valueIcon, size: 14, color: valueColor),
              const SizedBox(width: 4),
            ],
            Expanded(
              child: Text(value,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                      color: valueColor ?? Colors.black87)),
            ),
          ]),
        ),
      ],
    );
  }

  // ── Redesigned Confirm Report / Report sheet ──────────────────────────────

  void _showReportSheet(BuildContext ctx, int index) {
    final msg        = _localMessages[index];
    final isPhishing = _labelFor(index).toLowerCase() == 'phishing';
    final reasons  = isPhishing
        ? ['This is from a trusted sender', 'This is a legitimate promotional message',
      'This is a known service or OTP message', 'The link in this message is safe', 'Other reason']
        : ['This message seems suspicious', 'Message requests personal information',
      'Message contains suspicious links', 'Message is impersonating a known brand', 'Other reason'];
    final otherCtrl  = TextEditingController();

    showDialog(context: ctx, builder: (dlgCtx) {
      String? selected;

      return StatefulBuilder(builder: (dlgCtx, set) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
          child: Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 420),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [BoxShadow(
                color: Colors.black.withOpacity(.12),
                blurRadius: 20,
                offset: const Offset(0, 6),
              )],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // ── Header ──
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text('Report Inaccurate Detection',
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87)),
                    SizedBox(height: 6),
                    Text('Why do you think this detection is wrong?',
                        style: TextStyle(fontSize: 14, color: Color(0xFF999999))),
                  ],
                ),
              ),
              // ── Radio options ──
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                  child: Column(children: [
                    ...reasons.map((r) => GestureDetector(
                      onTap: () => set(() => selected = r),
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                        child: Row(children: [
                          Radio<String>(
                            value: r,
                            groupValue: selected,
                            activeColor: const Color(0xFF1A7A72),
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            onChanged: (v) => set(() => selected = v),
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: Text(r,
                              style: const TextStyle(fontSize: 15, color: Colors.black87, height: 1.4))),
                        ]),
                      ),
                    )),
                    if (selected == 'Other reason')
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                        child: TextField(
                          controller: otherCtrl,
                          maxLines: 3,
                          style: const TextStyle(fontSize: 14),
                          onChanged: (_) => set(() {}),
                          decoration: InputDecoration(
                            hintText: 'Describe your reason…',
                            hintStyle: const TextStyle(
                                color: Color(0xFFAAAAAA), fontSize: 13),
                            filled: true,
                            fillColor: const Color(0xFFF6F4EC),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: Color(0xFFE0DAD0)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(
                                  color: Color(0xFF1A7A72), width: 1.5),
                            ),
                            contentPadding: const EdgeInsets.all(12),
                          ),
                        ),
                      ),
                  ]),
                ),
              ),
              // ── Cancel / Submit row ──
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 16, 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(dlgCtx),
                      child: const Text('Cancel',
                          style: TextStyle(color: Color(0xFF888888), fontSize: 15)),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: (selected == null ||
                            (selected == 'Other reason' &&
                                otherCtrl.text.trim().isEmpty))
                            ? const Color(0xFFDDDDDD)
                            : const Color(0xFFF2554F),
                        foregroundColor: (selected == null ||
                            (selected == 'Other reason' &&
                                otherCtrl.text.trim().isEmpty))
                            ? const Color(0xFF999999)
                            : Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: (selected == null ||
                          (selected == 'Other reason' &&
                              otherCtrl.text.trim().isEmpty))
                          ? null
                          : () {
                        // Confirm then submit
                        showDialog(
                          context: dlgCtx,
                          barrierColor: Colors.black.withOpacity(.35),
                          builder: (confirmCtx) => AlertDialog(
                            backgroundColor: const Color(0xFFF0EDE6),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                            title: Row(children: const [
                              Icon(Icons.warning_amber_rounded, color: Color(0xFFE0A800), size: 26),
                              SizedBox(width: 10),
                              Text('Confirm Report',
                                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                            ]),
                            content: const Text(
                              'This action cannot be undone. Are you sure you want to flag this detection as inaccurate?',
                              style: TextStyle(fontSize: 14, color: Color(0xFF555555), height: 1.5),
                            ),
                            actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(confirmCtx),
                                child: const Text('Cancel',
                                    style: TextStyle(color: Color(0xFF888888), fontWeight: FontWeight.w500)),
                              ),
                              ElevatedButton(
                                onPressed: () async {
                                  final msgTime = msg['time']?.toString() ?? '';
                                  Navigator.pop(confirmCtx);
                                  Navigator.pop(dlgCtx);

                                  final messageHash = sha256
                                      .convert(utf8.encode(PhishingDetector.normalizeOtp(msg['message']?.toString() ?? '')))
                                      .toString();

                                  () async {
                                    final existing = await FirebaseFirestore.instance
                                        .collection('model_feedback')
                                        .where('messageHash', isEqualTo: messageHash)
                                        .get();
                                    if (!mounted) return;

                                    if (existing.docs.isNotEmpty) {
                                      final doc = existing.docs.first.data();
                                      final status = doc['status']?.toString() ?? '';
                                      final existingReportId = existing.docs.first.id;
                                      const reviewedStatuses = ['trained', 'verified', 'validated', 'rejected'];

                                      if (reviewedStatuses.contains(status)) {
                                        setState(() => _reportStatus[msgTime] = status);
                                        await _saveStatus();
                                        final currentLabel = (doc['originalLabel'] ?? '').toString().toLowerCase() == 'phishing'
                                            ? 'phishing' : 'legitimate';
                                        await _applyReviewDecision(msgTime, status, currentLabel);
                                        final p2 = await SharedPreferences.getInstance();
                                        final spamEnabled = p2.getBool('spam_folder_enabled') ?? false;

                                        // Mark this report as unviewed so the NEW badge appears
                                        final viewedRaw = p2.getString('viewed_report_ids');
                                        final viewed = viewedRaw != null && viewedRaw.isNotEmpty
                                            ? (jsonDecode(viewedRaw) as List).cast<String>().toSet()
                                            : <String>{};
                                        viewed.remove(existingReportId);
                                        await p2.setString('viewed_report_ids', jsonEncode(viewed.toList()));

                                        final tempReport = ReportModel(
                                          reportId      : existingReportId,
                                          message       : msg['message']?.toString() ?? '',
                                          originalLabel : currentLabel,
                                          correctedLabel: currentLabel == 'phishing' ? 'legitimate' : 'phishing',
                                          confidence    : 0,
                                          reason        : doc['reason']?.toString() ?? '',
                                          status        : status == 'rejected'
                                              ? ReportStatus.rejected
                                              : ReportStatus.validated,
                                          reportedAt    : DateTime.now(),
                                          type          : 'inaccurate_report',
                                        );
                                        if (mounted) {
                                          _showAlreadyReviewedDialog(
                                            ctx,
                                            tempReport,
                                            spamEnabled: spamEnabled,
                                          );
                                        }
                                        return;
                                      }
                                      // Still pending
                                      if (mounted) setState(() => _reportStatus[msgTime] = 'pending');
                                      await _saveStatus();
                                      if (mounted) _showVerificationDialog(ctx);
                                      return;
                                    }

                                    // Fresh report
                                    if (mounted) setState(() => _reportStatus[msgTime] = 'pending');
                                    await _saveStatus();
                                    if (mounted) _showVerificationDialog(ctx);
                                    submitReport(
                                      messageBody: msg['message']?.toString() ?? '',
                                      originalLabel: isPhishing ? 'phishing' : 'legitimate',
                                      confidence: ((msg['confidence'] as num?)?.toDouble() ?? 0.0),
                                      reason: selected == 'Other reason' ? otherCtrl.text.trim() : selected!,
                                      deviceId: widget.deviceId,
                                      sender: widget.sender,
                                      messageId: msg['time']?.toString() ?? '',
                                      source: 'inbox',
                                    );
                                  }();
                                },
                                style: ElevatedButton.styleFrom(   // keep your existing style unchanged
                                  backgroundColor: const Color(0xFFF2554F),
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                  elevation: 0,
                                ),
                                child: const Text('Submit Report',
                                    style: TextStyle(fontWeight: FontWeight.w600)),
                              ),
                            ],
                          ),
                        );
                      },
                      child: const Text('Submit',
                          style: TextStyle(fontSize: 15)),
                    ),
                  ],
                ),
              ),
            ]),
          ),
        );
      });
    });
  }

  // ── Message Details dialog ────────────────────────────────────────────────

  void _showMessageDetails(BuildContext ctx, int index) {
    final msg            = _localMessages[index];
    final message        = (msg['message'] ?? '').toString();
    final sender         = (msg['sender'] ?? widget.sender).toString();
    final timeRaw        = msg['time']?.toString() ?? '';
    final effectiveLabel = _labelFor(index);
    final isPhishing     = effectiveLabel.toLowerCase() == 'phishing';
    final rawConf        = msg['confidence'];
    final confidenceText = rawConf != null
        ? '${(rawConf as num).toDouble().toStringAsFixed(1)}% confidence'
        : '99.9% confidence';

    String formattedDate = '';
    String formattedTime = '';
    try {
      final dt = DateTime.parse(timeRaw).toLocal();
      formattedDate = DateFormat('MMMM d, yyyy').format(dt);
      formattedTime = DateFormat('h:mm a').format(dt);
    } catch (_) {}

    final indicators = isPhishing ? PhishingIndicator.detect(message) : <PhishingIndicator>[];

    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(24),
            topRight: Radius.circular(24),
          ),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // ── Handle ──
          Container(
            width: 40, height: 4,
            margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFCCCCCC),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // ── Title ──
                const Text('Message Details',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.black87)),
                const SizedBox(height: 20),

                // ── Detection card ──
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: isPhishing
                        ? const Color(0xFFFFEBEE)
                        : const Color(0xFFE8F5E9),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isPhishing
                          ? const Color(0xFFFFCDD2)
                          : const Color(0xFFC8E6C9),
                    ),
                  ),
                  child: Row(children: [
                    Container(
                      width: 44, height: 44,
                      decoration: BoxDecoration(
                        color: isPhishing
                            ? const Color(0xFFFFCDD2)
                            : const Color(0xFFC8E6C9),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isPhishing ? Icons.warning_rounded : Icons.check_circle_rounded,
                        color: isPhishing ? const Color(0xFFD32F2F) : const Color(0xFF2E7D32),
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                        isPhishing ? 'Phishing Detected' : 'Legitimate',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: isPhishing ? const Color(0xFFD32F2F) : const Color(0xFF2E7D32),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(confidenceText,
                          style: TextStyle(
                            fontSize: 13,
                            color: isPhishing ? const Color(0xFFE57373) : const Color(0xFF66BB6A),
                          )),
                    ]),
                  ]),
                ),
                const SizedBox(height: 16),

                // ── Info rows ──
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F5F5),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(children: [
                    _detailRowNew(Icons.person_outline_rounded, 'Sender', sender),
                    const Divider(height: 1, indent: 56, color: Color(0xFFE0E0E0)),
                    _detailRowNew(Icons.access_time_rounded, 'Date & Time', '$formattedDate • $formattedTime'),
                    const Divider(height: 1, indent: 56, color: Color(0xFFE0E0E0)),
                    _detailRowNew(Icons.text_fields_rounded, 'Characters', message.length.toString()),
                  ]),
                ),

                // ── Why flagged section (phishing only) ──
                if (isPhishing && indicators.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Row(children: [
                    Container(width: 4, height: 20,
                        decoration: const BoxDecoration(color: Color(0xFFD32F2F), borderRadius: BorderRadius.all(Radius.circular(2)))),
                    const SizedBox(width: 10),
                    const Text('Why this was flagged',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87)),
                  ]),
                  const SizedBox(height: 12),
                  ...indicators.map((ind) => Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    decoration: BoxDecoration(
                      color: ind.color.withOpacity(0.07),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: ind.color.withOpacity(0.18)),
                    ),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Container(
                        width: 42, height: 42,
                        decoration: BoxDecoration(
                          color: ind.color.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(ind.icon, color: ind.color, size: 22),
                      ),
                      const SizedBox(width: 14),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(ind.label,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: ind.color,
                            )),
                        const SizedBox(height: 4),
                        Text(ind.description,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.black54,
                              height: 1.4,
                            )),
                      ])),
                    ]),
                  )),
                ],
              ],
            )),
          ),
        ]),
      ),
    );
  }

  Widget _detailRowNew(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(children: [
        Icon(icon, size: 22, color: const Color(0xFF9E9E9E)),
        const SizedBox(width: 18),
        Text(label, style: const TextStyle(fontSize: 14, color: Color(0xFF9E9E9E))),
        const Spacer(),
        Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.black87)),
      ]),
    );
  }

  Widget _detailRow(String label, String value, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 100,
          child: Text(label,
              style: const TextStyle(fontSize: 14, color: Color(0xFF888888))),
        ),
        Expanded(
          child: Text(value,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                  color: Colors.black87)),
        ),
      ]),
    );
  }

  // ── Long-press bottom sheet ───────────────────────────────────────────────

  void _showMessageOptions(BuildContext ctx, int index) {
    final msg      = _localMessages[index];
    final message  = (msg['message'] ?? '').toString();
    final isStarred = _starredIndices.contains(index);

    showModalBottomSheet(
      context: ctx,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.only(
              topLeft: Radius.circular(20), topRight: Radius.circular(20)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 40, height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                  color: const Color(0xFFCCCCC0),
                  borderRadius: BorderRadius.circular(2))),
          _msgOption(Icons.check_box_outline_blank, 'Select text', () {
            Navigator.pop(ctx);
            setState(() {
              _selectMode = true;
              _selectedIndices.clear();
              _selectedIndices.add(index);
            });
          }),
          _msgOption(
            isStarred ? Icons.star : Icons.star_outline,
            isStarred ? 'Unstar message' : 'Star message',
                () {
              Navigator.pop(ctx);
              setState(() {
                if (isStarred) {
                  _starredIndices.remove(index);
                } else {
                  _starredIndices.add(index);
                }
              });
            },
          ),
          _msgOption(Icons.info_outline, 'View details', () {
            Navigator.pop(ctx);
            _showMessageDetails(ctx, index);
          }),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Builder(builder: (context) {
              final msgTime = _localMessages[index]['time']?.toString() ?? '';
              final status = _reportStatus[msgTime];
              final isUnderReview = status == 'pending' || status == 'under_review';
              return OutlinedButton.icon(
                onPressed: isUnderReview ? null : () {
                  Navigator.pop(ctx);
                  _showReportSheet(ctx, index);
                },
                icon: Icon(Icons.flag_outlined,
                    color: isUnderReview ? const Color(0xFFBBBBBB) : const Color(0xFFF2554F)),
                label: Text(
                  isUnderReview ? 'Already Under Review' : 'Report Inaccurate Detection',
                  style: TextStyle(
                      color: isUnderReview ? const Color(0xFFBBBBBB) : const Color(0xFFF2554F),
                      fontWeight: FontWeight.w600),
                ),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 50),
                  side: BorderSide(color: isUnderReview ? const Color(0xFFDDDDDD) : const Color(0xFFF2554F)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              );
            }),
          ),
          const Divider(height: 1),
          SafeArea(
            top: false,
            child: Row(children: [
              _bottomAction(Icons.copy_outlined, 'Copy text', () {
                Clipboard.setData(ClipboardData(text: message));
                Navigator.pop(ctx);
              }),
              _bottomAction(Icons.share_outlined, 'Share', () {
                Navigator.pop(ctx);
                Share.share(message);
              }),
              _bottomAction(Icons.delete_outline, 'Delete', () async {
                Navigator.pop(ctx);
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (dctx) => AlertDialog(
                    backgroundColor: const Color(0xFFF6F4EC),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18)),
                    title: const Text('Delete Message',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 17)),
                    content: const Text(
                        'Are you sure you want to delete this message?',
                        style: TextStyle(
                            fontSize: 14, color: Color(0xFF555555))),
                    actionsPadding:
                    const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dctx, false),
                          child: const Text('Cancel',
                              style:
                              TextStyle(color: Color(0xFF1A7A72)))),
                      ElevatedButton(
                          onPressed: () => Navigator.pop(dctx, true),
                          style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFF2554F),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                  borderRadius:
                                  BorderRadius.circular(10))),
                          child: const Text('Delete')),
                    ],
                  ),
                );
                if (confirmed == true && mounted) {
                  final time = _localMessages[index]['time']?.toString() ?? '';
                  setState(() => _localMessages.removeWhere(
                      (m) => m['time']?.toString() == time));
                  await widget.onDeleteMessages([time]);
                }
              }, color: const Color(0xFFF2554F)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _msgOption(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Row(children: [
          Icon(icon, size: 22, color: const Color(0xFF444444)),
          const SizedBox(width: 16),
          Text(label, style: const TextStyle(fontSize: 16, color: Color(0xFF222222))),
        ]),
      ),
    );
  }

  Widget _bottomAction(IconData icon, String label, VoidCallback onTap,
      {Color color = const Color(0xFF444444)}) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(children: [
            Icon(icon, size: 24, color: color),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 12, color: color)),
          ]),
        ),
      ),
    );
  }

  // ── 3-dot menu ────────────────────────────────────────────────────────────

  void _showThreeDotMenu(BuildContext ctx) {
    showMenu(
      context: ctx,
      position: const RelativeRect.fromLTRB(1000, 56, 8, 0),
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: [
        _menuItem(Icons.search, 'Search messages', () {
          setState(() => _searchActive = true);
        }),
        _menuItem(Icons.delete_outline, 'Delete conversation', () {
          widget.onDeleteThread();
        }),
        _menuItem(Icons.palette_outlined, 'Customize chatroom', () {
          Navigator.push(
            ctx,
            MaterialPageRoute(
              builder: (_) => CustomizeChatroomPage(
                senderName: widget.sender,
              ),
            ),
          ).then((_) {
            if (mounted) _loadChatroomPrefs();
          });
        }),
      ],
    );
  }

  PopupMenuItem _menuItem(IconData icon, String label, VoidCallback onTap) {
    return PopupMenuItem(
      onTap: onTap,
      child: Row(children: [
        Icon(icon, size: 20, color: const Color(0xFF444444)),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(fontSize: 15)),
      ]),
    );
  }

  Widget _buildBubble({
    required BuildContext ctx,
    required int origIdx,
    required Map<String, dynamic> msg,
    required String message,
    required String time,
    required String msgTime,
    required String? status,
    required bool displayPhishing,
    required Color labelColor,
    required String labelText,
    required bool isSearchMatch,
    required bool isReportHighlight,
    required bool isSelected,
    required bool isStarred,
    bool isPhishingHighlight = false,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      GestureDetector(
          key: _itemKeys[origIdx],
          onLongPress: _selectMode ? null : () => _showMessageOptions(ctx, origIdx),
          child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          margin: const EdgeInsets.only(bottom: 10),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(ctx).size.width * 0.82),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFFD0EAE6)
                : (displayPhishing ? const Color(0xFFFFCDD2) : const Color(0xFFD6F0E8)),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(4),
              topRight: Radius.circular(18),
              bottomLeft: Radius.circular(18),
              bottomRight: Radius.circular(18),
            ),
            border: isSelected
                ? Border.all(color: const Color(0xFF1A7A72), width: 1.5)
                : isSearchMatch
                ? Border.all(color: const Color(0xFFFFE57F), width: 1.5)
                : null,
            boxShadow: null,
          ),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _query.isNotEmpty
                ? _highlightSearchText(message, _query)
                : (displayPhishing
                ? buildPhishingHighlightedText(message)
                : Text(message,
                style: const TextStyle(fontSize: 14, color: Colors.black87, height: 1.5))),
            const SizedBox(height: 8),
            Text(time, style: const TextStyle(fontSize: 11, color: Color(0xFF888888))),
            const SizedBox(height: 6),
            if (status == 'pending' || status == 'under_review')
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFF555555),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: const [
                  Icon(Icons.hourglass_top_rounded, size: 12, color: Colors.white),
                  SizedBox(width: 5),
                  Text('Verification in Progress',
                      style: TextStyle(
                          fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600)),
                ]),
              )
            else
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  GestureDetector(
                    onTap: () => _showReportSheet(ctx, origIdx),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                      decoration:
                      BoxDecoration(color: labelColor, borderRadius: BorderRadius.circular(20)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(
                            displayPhishing ? Icons.warning_rounded : Icons.shield_outlined,
                            size: 13,
                            color: Colors.white),
                        const SizedBox(width: 5),
                        Text(labelText,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
                      ]),
                    ),
                  ),
                  if (isStarred) ...[
                    const SizedBox(width: 6),
                    const Icon(Icons.star_rounded, size: 16, color: Color(0xFFFFB300)),
                  ],
                ]),
                if (displayPhishing) ...[
                  const SizedBox(height: 6),
                  Builder(builder: (_) {
                    final text = message.toLowerCase();
                    final tags = <Map<String, dynamic>>[];
                    if (RegExp(r'https?://|bit\.ly|tinyurl|t\.co|click.*link|tap.*link|link.*below').hasMatch(text)) tags.add({'label': 'Suspicious URL', 'icon': Icons.link});
                    if (RegExp(r'prize|reward|won|winner|claim|free|gift|cash|piso|pesos|spins?|\d+\s*(pesos?|php|\$)').hasMatch(text)) tags.add({'label': 'Fake Rewards', 'icon': Icons.card_giftcard});
                    if (RegExp(r'login|log in|sign in|password|username|credentials|verif|otp|one.time|confirm|code|pin|passcode').hasMatch(text)) tags.add({'label': 'Sensitive Info', 'icon': Icons.key});
                    if (RegExp(r'bank|gcash|maya|paypal|credit|debit|transfer|withdraw|deposit').hasMatch(text)) tags.add({'label': 'Financial Fraud', 'icon': Icons.account_balance_wallet});
                    if (RegExp(r'parcel|package|deliver|shipment|courier|postal|tracking').hasMatch(text)) tags.add({'label': 'Fake Delivery', 'icon': Icons.local_shipping});
                    if (RegExp(r'sss|philhealth|pagibig|bir|lto|nbi|dfa|passport|clearance').hasMatch(text)) tags.add({'label': 'Gov. Impersonation', 'icon': Icons.account_balance});
                    if (RegExp(r'job|hiring|apply|salary|earn|work from home|income|negosyo').hasMatch(text)) tags.add({'label': 'Fake Job Offer', 'icon': Icons.work_outline});
                    if (tags.isEmpty) tags.add({'label': 'Suspicious Message', 'icon': Icons.warning_amber_rounded});
                    return Wrap(spacing: 6, runSpacing: 4,
                      children: tags.map((tag) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFFF2554F).withOpacity(.55)),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(tag['icon'] as IconData, size: 11, color: const Color(0xFFF2554F)),
                          const SizedBox(width: 4),
                          Text(tag['label'] as String,
                              style: const TextStyle(fontSize: 11, color: Color(0xFFF2554F), fontWeight: FontWeight.w500)),
                        ]),
                      )).toList(),
                    );
                  }),
                ],
              ]),
            if ((status == 'verified' || status == 'rejected') &&
                !_dismissedNotes.contains(msgTime)) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                decoration: BoxDecoration(
                  color: status == 'verified'
                      ? const Color(0xFF1A7A72).withOpacity(.08)
                      : const Color(0xFFF2554F).withOpacity(.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: status == 'verified'
                        ? const Color(0xFF1A7A72).withOpacity(.3)
                        : const Color(0xFFF2554F).withOpacity(.3),
                  ),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(
                    status == 'verified' ? Icons.verified_outlined : Icons.cancel_outlined,
                    size: 13,
                    color: status == 'verified'
                        ? const Color(0xFF1A7A72)
                        : const Color(0xFFF2554F),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    status == 'verified'
                        ? 'Reviewed & Verified by Developers'
                        : 'Reviewed & Rejected by Developers',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: status == 'verified'
                          ? const Color(0xFF1A7A72)
                          : const Color(0xFFF2554F),
                    ),
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: () {
                      final t = msgTime;
                      setState(() => _dismissedNotes.add(t));
                      _saveStatus();
                    },
                    child: const Icon(Icons.close, size: 13, color: Color(0xFFAAAAAA)),
                  ),
                ]),
              ),
            ],
          ]),
        ),
      ),
    ]);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext ctx) {
    final matches    = _matchIndices;
    final matchCount = matches.length;

    return Scaffold(
      backgroundColor: null,
      appBar: _selectMode
          ? AppBar(
        backgroundColor: _themeColor,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => setState(() {
            _selectMode = false;
            _selectedIndices.clear();
          }),
        ),
        title: Text(
          '${_selectedIndices.length} selected',
          style: const TextStyle(
              fontWeight: FontWeight.w600, fontSize: 17),
        ),
        actions: [
          // Select all
          IconButton(
            tooltip: 'Select all',
            icon: const Icon(Icons.select_all),
            onPressed: () => setState(() {
              _selectedIndices.addAll(
                  List.generate(_localMessages.length, (i) => i));
            }),
          ),
          // Delete selected
          IconButton(
            tooltip: 'Delete selected',
            icon: const Icon(Icons.delete_outline),
            onPressed: _selectedIndices.isEmpty
                ? null
                : () async {
              bool confirmed = false;
              await showDialog(
                context: ctx,
                builder: (dctx) => AlertDialog(
                  backgroundColor: const Color(0xFFF6F4EC),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18)),
                  title: const Text('Delete Messages',
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 17)),
                  content: Text(
                      'Delete ${_selectedIndices.length} selected message${_selectedIndices.length == 1 ? '' : 's'}?',
                      style: const TextStyle(
                          fontSize: 14,
                          color: Color(0xFF555555))),
                  actionsPadding:
                  const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  actions: [
                    TextButton(
                        onPressed: () {
                          confirmed = false;
                          Navigator.pop(dctx);
                        },
                        child: const Text('Cancel',
                            style: TextStyle(
                                color: Color(0xFF1A7A72)))),
                    ElevatedButton(
                        onPressed: () {
                          confirmed = true;
                          Navigator.pop(dctx);
                        },
                        style: ElevatedButton.styleFrom(
                            backgroundColor:
                            const Color(0xFFF2554F),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                                borderRadius:
                                BorderRadius.circular(10))),
                        child: const Text('Delete')),
                  ],
                ),
              );
              if (confirmed) {
                final times = _selectedIndices
                    .map((i) => _localMessages[i]['time']?.toString() ?? '')
                    .where((t) => t.isNotEmpty)
                    .toList();
                if (mounted) setState(() {
                  _localMessages.removeWhere(
                      (m) => times.contains(m['time']?.toString()));
                  _selectMode = false;
                  _selectedIndices.clear();
                });
                await widget.onDeleteMessages(times);
              }
            },
          ),
        ],
      )
          : AppBar(
        backgroundColor: _themeColor,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        title: Text(widget.sender,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
        actions: [
          if (!_searchActive)
            IconButton(
              icon: const Icon(Icons.more_vert),
              onPressed: () => _showThreeDotMenu(ctx),
            ),
        ],
        bottom: _searchActive
            ? PreferredSize(
                preferredSize: const Size.fromHeight(58),
                child: Container(
                  color: _themeColor,
                  padding: const EdgeInsets.fromLTRB(12, 0, 8, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 42,
                          decoration: BoxDecoration(
                            color: _themeColor.withOpacity(0.7),
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: TextField(
                            controller: _searchCtrl,
                            autofocus: true,
                            style: const TextStyle(color: Colors.white, fontSize: 15),
                            decoration: const InputDecoration(
                              hintText: 'Search...',
                              hintStyle: TextStyle(color: Colors.white54, fontSize: 15),
                              prefixIcon: Icon(Icons.search, color: Colors.white54, size: 20),
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(vertical: 12),
                            ),
                            onChanged: (v) {
                              setState(() { _query = v; _currentMatchIdx = 0; });
                              Future.delayed(const Duration(milliseconds: 100), _scrollToFirst);
                            },
                          ),
                        ),
                      ),
                      if (_query.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(Icons.chevron_left, color: Colors.white, size: 22),
                          onPressed: _scrollToPrev,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                        Text(
                          '${matchCount == 0 ? 0 : _currentMatchIdx + 1}/$matchCount',
                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                        ),
                        IconButton(
                          icon: const Icon(Icons.chevron_right, color: Colors.white, size: 22),
                          onPressed: _scrollToNext,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white, size: 20),
                        onPressed: () => setState(() {
                          _searchActive = false;
                          _query = '';
                          _currentMatchIdx = 0;
                          _searchCtrl.clear();
                        }),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ),
              )
            : null,
      ),
      body: Builder(builder: (ctx2) {
        final msgs = _localMessages.reversed.toList();
        final phishingIndices = _phishingIndices;
        final phishingCount   = phishingIndices.length;
        return Stack(children: [
        Column(
          children: [
            if (phishingCount > 0)
              Container(
                color: const Color(0xFFE53935),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$phishingCount phishing message${phishingCount == 1 ? '' : 's'} detected',
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  ),
                  if (_phishingNavActive) ...[
                    IconButton(
                      icon: const Icon(Icons.chevron_left, color: Colors.white, size: 20),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () {
                        setState(() => _phishingNavIdx = (_phishingNavIdx - 1 + phishingCount) % phishingCount);
                        _scrollToPhishingIdx(_phishingNavIdx);
                      },
                    ),
                    Text('${_phishingNavIdx + 1}/$phishingCount',
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                    IconButton(
                      icon: const Icon(Icons.chevron_right, color: Colors.white, size: 20),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () {
                        setState(() => _phishingNavIdx = (_phishingNavIdx + 1) % phishingCount);
                        _scrollToPhishingIdx(_phishingNavIdx);
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white, size: 18),
                      padding: const EdgeInsets.only(left: 4),
                      constraints: const BoxConstraints(),
                      onPressed: () => setState(() { _phishingNavActive = false; _phishingHighlightTime = null; }),
                    ),
                  ] else
                    TextButton(
                      onPressed: () {
                        setState(() { _phishingNavActive = true; _phishingNavIdx = 0; });
                        _scrollToPhishingIdx(0);
                        Future.delayed(const Duration(milliseconds: 100), () => _scrollToPhishingIdx(0));
                      },
                      style: TextButton.styleFrom(
                        backgroundColor: Colors.white24,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      ),
                      child: const Text('View', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                ]),
              ),
            Expanded(child: Stack(
              children: [
                Positioned.fill(
                  child: _wallpaperKey.startsWith('gallery_file:')
                      ? Image.file(File(_wallpaperKey.substring('gallery_file:'.length)), fit: BoxFit.cover)
                      : kWallpaperImages.contains(_wallpaperKey)
                          ? Image.asset('assets/images/$_wallpaperKey.png', fit: BoxFit.cover)
                          : ColoredBox(color: _wallpaperColorFromKey(_wallpaperKey)),
                ),
                ListView.builder(
                  controller: _scrollCtrl,
              padding: const EdgeInsets.only(top: 16, bottom: 32),
              itemCount: msgs.length,
              itemBuilder: (_, i) {
            final origIdx         = _localMessages.length - 1 - i;
            final msg             = msgs[i];
            final msgTime         = msg['time']?.toString() ?? '';
            final status          = _statusFor(origIdx);
            final effectiveLabel  = _labelFor(origIdx).toLowerCase();
            final displayPhishing = effectiveLabel == 'phishing';
            final message         = (msg['message'] ?? '').toString();
            final time            = widget.formatTime(msg['time'] as String?);
            final labelColor      = displayPhishing
                ? const Color(0xFFF2554F)
                : const Color(0xFF2E7D5E);
            final labelText       = displayPhishing ? 'Phishing' : 'Safe';
            final isSearchMatch   =
                _query.isNotEmpty && matches.contains(origIdx);
            final isReportHighlight = _reportHighlightTime != null &&
                msgTime == _reportHighlightTime;
            final isPhishingHighlight = _phishingHighlightTime != null &&
                msgTime == _phishingHighlightTime;
            final isSelected      = _selectedIndices.contains(origIdx);
            final isStarred       = _starredIndices.contains(origIdx);

            DateTime? msgDate;
            bool showDate = false;
            try {
              msgDate  = DateTime.parse(msg['time'] ?? '').toLocal();
              showDate = i == 0 || (() {
                final prev =
                DateTime.parse(msgs[i - 1]['time'] ?? '').toLocal();
                return prev.day != msgDate!.day ||
                    prev.month != msgDate.month ||
                    prev.year != msgDate.year;
              })();
            } catch (_) {}

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showDate && msgDate != null)
                  Center(
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 14),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                      decoration: BoxDecoration(
                        color: const Color(0xFFBBB8B0),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        DateFormat('MMMM d').format(msgDate),
                        style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ),
            SizedBox(
              width: double.infinity,
              child: ColoredBox(
                color: (isReportHighlight || isPhishingHighlight) ? labelColor.withOpacity(.10) : Colors.transparent,
                child: Padding(
                  padding: EdgeInsets.only(
                    left: 16,
                    right: 16,
                    top: (isReportHighlight || isPhishingHighlight) ? 8 : 0,
                  ),
                  child: GestureDetector(
            onTap: _selectMode
                      ? () => setState(() {
                    if (isSelected) {
                      _selectedIndices.remove(origIdx);
                    } else {
                      _selectedIndices.add(origIdx);
                    }
                  })
                      : null,
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            // Select mode row
                      if (_selectMode)
                        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isSelected
                                    ? const Color(0xFF1A7A72)
                                    : Colors.white,
                                border: Border.all(
                                  color: isSelected
                                      ? const Color(0xFF1A7A72)
                                      : const Color(0xFFCCCCCC),
                                  width: 2,
                                ),
                              ),
                              child: isSelected
                                  ? const Icon(Icons.check,
                                  size: 14, color: Colors.white)
                                  : null,
                            ),
                          ),
                          Expanded(child: _buildBubble(
                            ctx: ctx,
                            origIdx: origIdx,
                            msg: msg,
                            message: message,
                            time: time,
                            msgTime: msgTime,
                            status: status,
                            displayPhishing: displayPhishing,
                            labelColor: labelColor,
                            labelText: labelText,
                            isSearchMatch: isSearchMatch,
                            isReportHighlight: isReportHighlight,
                            isSelected: isSelected,
                            isStarred: isStarred,
                            isPhishingHighlight: isPhishingHighlight,
                          )),
                        ])
                      else
                        _buildBubble(
                          ctx: ctx,
                          origIdx: origIdx,
                          msg: msg,
                          message: message,
                          time: time,
                          msgTime: msgTime,
                          status: status,
                          displayPhishing: displayPhishing,
                          labelColor: labelColor,
                          labelText: labelText,
                          isSearchMatch: isSearchMatch,
                          isReportHighlight: isReportHighlight,
                          isSelected: isSelected,
                          isStarred: isStarred,
                          isPhishingHighlight: isPhishingHighlight,
                        ),
                    ]),
                    ),
                  ),
                  ),
                ),
              ],
            );
          },
        ),
        if (_showScrollDown)
        Positioned(
        right: 16,
        bottom: 20,
        child: FloatingActionButton.small(
        heroTag: 'scrollDown',
        onPressed: () => _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        ),
        backgroundColor: const Color(0xFF1A7A72),
        foregroundColor: Colors.white,
        elevation: 4,
        shape: const CircleBorder(),
        child: const Icon(Icons.keyboard_arrow_down, size: 28),
        ),
        ),
        ],
        )),
          ],
        ),
        ]);
      }),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Verification step widget
// ─────────────────────────────────────────────────────────────────────────────

class _VerifStep extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final bool done;
  final bool active;
  final bool isLast;

  const _VerifStep({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    this.done = false,
    this.active = false,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Icon + line
        Column(children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: done
                  ? const Color(0xFF1A7A72).withOpacity(.12)
                  : active
                  ? const Color(0xFFE0A800).withOpacity(.12)
                  : const Color(0xFFF0EDE6),
              shape: BoxShape.circle,
              border: Border.all(
                color: done
                    ? const Color(0xFF1A7A72).withOpacity(.4)
                    : active
                    ? const Color(0xFFE0A800).withOpacity(.5)
                    : const Color(0xFFDDD8CE),
              ),
            ),
            child: Icon(icon, size: 18,
              color: done
                  ? const Color(0xFF1A7A72)
                  : active
                  ? const Color(0xFFE0A800)
                  : const Color(0xFFBBBBBB),
            ),
          ),
          if (!isLast)
            Expanded(
              child: Container(
                width: 2,
                margin: const EdgeInsets.symmetric(vertical: 2),
                color: done ? const Color(0xFF1A7A72).withOpacity(.25) : const Color(0xFFE0DAD0),
              ),
            ),
        ]),
        const SizedBox(width: 14),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: isLast ? 0 : 16, top: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600,
                color: active ? const Color(0xFF333333) : (done ? const Color(0xFF1A7A72) : const Color(0xFFAAAAAA)),
              )),
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(fontSize: 12, color: Color(0xFF888888))),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Spam Folder Page
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// Spam Folder Page
// ─────────────────────────────────────────────────────────────────────────────

class SpamFolderPage extends StatefulWidget {
  final String Function(String?) formatTime;
  final String deviceId;
  final VoidCallback? onOpenReportTracker;
  final bool spamEnabled;
  final void Function(String sender, String messageBody)? onOpenConversation;

  const SpamFolderPage({
    super.key,
    required this.formatTime,
    required this.deviceId,
    required this.spamEnabled,
    this.onOpenReportTracker,
    this.onOpenConversation,
  });

  @override
  State<SpamFolderPage> createState() => _SpamFolderPageState();
}

class _SpamFolderPageState extends State<SpamFolderPage> {
  static const _spamKey         = 'spam_folder_logs';
  static const _autoDeletionKey = 'spam_auto_deletion_days';
  static const _manualKey       = 'manual_scan_logs';

  List<Map<String, dynamic>> _spamMessages = [];
  List<Map<String, dynamic>> _threads      = [];
  bool _loading   = true;
  int  _activeTab = 0; // 0 = Smishing, 1 = Reports
  int? _autoDeletionDays;

  int _spamReportCount = 0;
  StreamSubscription<QuerySnapshot>? _spamReportBadgeSub;
  List<QueryDocumentSnapshot>? _cachedSpamReportDocs;

  bool _selectMode = false;
  String _query = '';
  late final List<GlobalKey> _itemKeys;

  static const _deletionOptions = [
    (label: 'Never', days: -1),
    (label: '7 days', days: 7),
    (label: '14 days', days: 14),
    (label: '30 days', days: 30),
  ];
  StreamSubscription<QuerySnapshot>? _reviewSub;

  @override
  void initState() {
    super.initState();
    _loadPref();
    _loadSpam();
    _startReviewListener();
    _startSpamReportBadgeListener();
  }

  Widget _dialogDetailRow(String label, String value,
      {bool bold = false, Color? valueColor, IconData? valueIcon}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 110, child: Text(label, style: const TextStyle(fontSize: 13, color: Color(0xFF888888)))),
        Expanded(child: Row(children: [
          if (valueIcon != null) ...[Icon(valueIcon, size: 14, color: valueColor), const SizedBox(width: 4)],
          Expanded(child: Text(value, style: TextStyle(fontSize: 13, fontWeight: bold ? FontWeight.w700 : FontWeight.w500, color: valueColor ?? Colors.black87))),
        ])),
      ],
    );
  }

  Widget _highlightSearchText(String text, String query) {
    if (query.isEmpty) return buildPhishingHighlightedText(text);
    final lower = text.toLowerCase();
    final lowerQ = query.toLowerCase();
    final spans = <TextSpan>[];
    int start = 0;
    while (true) {
      final idx = lower.indexOf(lowerQ, start);
      if (idx == -1) { if (start < text.length) spans.add(TextSpan(text: text.substring(start))); break; }
      if (idx > start) spans.add(TextSpan(text: text.substring(start, idx)));
      spans.add(TextSpan(
        text: text.substring(idx, idx + query.length),
        style: const TextStyle(backgroundColor: Color(0xFFFFE57F), color: Colors.black, fontWeight: FontWeight.bold),
      ));
      start = idx + query.length;
    }
    return RichText(text: TextSpan(
      style: const TextStyle(fontSize: 14, color: Colors.black87, height: 1.5),
      children: spans,
    ));
  }

  @override
  void dispose() {
    _reviewSub?.cancel();
    _spamReportBadgeSub?.cancel(); // add this
    super.dispose();
  }

  void _startSpamReportBadgeListener() {
    _spamReportBadgeSub?.cancel();
    if (widget.deviceId.isEmpty) return;
    _spamReportBadgeSub = FirebaseFirestore.instance
        .collection('model_feedback')
        .where('deviceId', isEqualTo: widget.deviceId)
        .snapshots()
        .listen((snap) {
      _cachedSpamReportDocs = snap.docs;
      _refreshSpamBadge();
    }, onError: (e) => debugPrint('Spam report badge error: $e'));
  }

  Future<void> _refreshSpamBadge() async {
    final docs = _cachedSpamReportDocs;
    if (docs == null) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('viewed_report_ids');
    final viewed = raw != null && raw.isNotEmpty
        ? (jsonDecode(raw) as List).cast<String>().toSet()
        : <String>{};
    const reviewedStatuses = {'trained', 'verified', 'validated', 'rejected'};
    final count = docs.where((doc) {
      final data   = doc.data() as Map<String, dynamic>;
      final status = data['status']?.toString() ?? '';
      final src    = (data['source'] ?? 'inbox').toString();
      return reviewedStatuses.contains(status)
          && src == 'spam'
          && !viewed.contains(doc.id);
    }).length;
    if (mounted) setState(() => _spamReportCount = count);
  }

  void _startReviewListener() {
    _reviewSub?.cancel();
    final Map<String, String> _prevStatuses = {};
    _reviewSub = FirebaseFirestore.instance
        .collection('model_feedback')
        .snapshots()
        .listen((snap) async {
      const reviewedStatuses = {'verified', 'validated', 'trained', 'rejected'};
      for (final doc in snap.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final status = data['status']?.toString() ?? '';
        final src = (data['source'] ?? 'inbox').toString();
        final msgTime = (data['messageId'] ?? data['messageTime'] ?? '').toString();
        final originalLabel = (data['originalLabel'] ?? '').toString().toLowerCase();
        final prevStatus = _prevStatuses[doc.id];

        if (src == 'spam' &&
            reviewedStatuses.contains(status) &&
            !reviewedStatuses.contains(prevStatus ?? '')) {
          // New review decision just arrived — apply the move
          if (msgTime.isNotEmpty) {
            await _applyReviewDecision(msgTime, status, originalLabel);
          }
        }
        _prevStatuses[doc.id] = status;
      }
      await _loadSpam();
    });
  }

  Future<void> _saveStatus() async {
    // SpamFolderPage stores dismissed notes per-thread in _SpamConversationPage.
    // This is a no-op at the folder level; dismissal is handled in the conversation.
  }

  Future<bool> _applyReviewDecision(
      String msgTime, String status, String originalLabel) async {
    try {
      final p       = await SharedPreferences.getInstance();
      final spamRaw = p.getString(_spamKey);
      final manRaw  = p.getString(_manualKey);
      final spam    = spamRaw != null && spamRaw.isNotEmpty
          ? (jsonDecode(spamRaw) as List).cast<Map<String, dynamic>>()
          : <Map<String, dynamic>>[];
      final man     = manRaw != null && manRaw.isNotEmpty
          ? (jsonDecode(manRaw) as List).cast<Map<String, dynamic>>()
          : <Map<String, dynamic>>[];

      final spamIdx  = spam.indexWhere((m) => m['time']?.toString() == msgTime);
      final inboxIdx = man.indexWhere((m) => m['time']?.toString() == msgTime);

      Map<String, dynamic>? entry;
      bool wasInSpam = false;
      if (spamIdx != -1) {
        entry = Map<String, dynamic>.from(spam[spamIdx]);
        wasInSpam = true;
      } else if (inboxIdx != -1) {
        entry = Map<String, dynamic>.from(man[inboxIdx]);
        wasInSpam = false;
      }
      if (entry == null) return false;

      entry['verifiedByCrew'] = true;
      final bool wasPhishing  = originalLabel == 'phishing';
      final bool verified     = status == 'verified' || status == 'validated';
      final String finalLabel = verified
          ? (wasPhishing ? 'Safe' : 'Phishing')
          : (wasPhishing ? 'Phishing' : 'Safe');
      entry['label'] = finalLabel;
      final bool shouldBeInInbox = finalLabel.toLowerCase() == 'safe';

      if (wasInSpam) {
        spam.removeAt(spamIdx);
        if (shouldBeInInbox) {
          await p.setString(_spamKey, jsonEncode(spam));
          if (!man.any((m) => m['time']?.toString() == msgTime)) {
            man.insert(0, entry);
            if (man.length > 200) man.removeRange(200, man.length);
            await p.setString(_manualKey, jsonEncode(man));
          }
          return true;
        } else {
          spam.insert(0, entry);
          if (spam.length > 200) spam.removeRange(200, spam.length);
          await p.setString(_spamKey, jsonEncode(spam));
          return false;
        }
      } else {
        man.removeAt(inboxIdx);
        if (shouldBeInInbox) {
          man.insert(0, entry);
          if (man.length > 200) man.removeRange(200, man.length);
          await p.setString(_manualKey, jsonEncode(man));
        } else {
          await p.setString(_manualKey, jsonEncode(man));
          if (!spam.any((m) => m['time']?.toString() == msgTime)) {
            spam.insert(0, entry);
            if (spam.length > 200) spam.removeRange(200, spam.length);
            await p.setString(_spamKey, jsonEncode(spam));
          }
        }
        return false;
      }
    } catch (e) {
      debugPrint('SpamFolder apply review decision error: $e');
      return false;
    }
  }

  Future<void> _loadPref() async {
    final p = await SharedPreferences.getInstance();
    if (mounted) setState(() => _autoDeletionDays = p.getInt(_autoDeletionKey));
  }

  Future<void> _savePref(int? days) async {
    final p = await SharedPreferences.getInstance();
    if (days == null) await p.remove(_autoDeletionKey);
    else await p.setInt(_autoDeletionKey, days);
    setState(() => _autoDeletionDays = days);
  }

  List<Map<String, dynamic>> _applyAutoDeletion(List<Map<String, dynamic>> l) {
    if (_autoDeletionDays == null) return l;
    final cutoff = DateTime.now().subtract(Duration(days: _autoDeletionDays!));
    return l.where((e) {
      final t = DateTime.tryParse(e['time'] ?? '');
      return t != null && t.isAfter(cutoff);
    }).toList();
  }

  Future<void> _loadSpam() async {
    final p   = await SharedPreferences.getInstance();
    final raw = p.getString(_spamKey);
    final msgs = raw != null && raw.isNotEmpty
        ? (jsonDecode(raw) as List).cast<Map<String, dynamic>>()
        : <Map<String, dynamic>>[];
    final filtered = _applyAutoDeletion(msgs);
    if (filtered.length < msgs.length) {
      await p.setString(_spamKey, jsonEncode(filtered));
    }
    if (mounted) setState(() {
      _spamMessages = filtered;
      _threads      = _buildThreads(filtered);
      _loading      = false;
    });
  }

  Future<void> _persistSpam(List<Map<String, dynamic>> l) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_spamKey, jsonEncode(l));
  }

  List<Map<String, dynamic>> _buildThreads(List<Map<String, dynamic>> msgs) {
    final Map<String, List<Map<String, dynamic>>> g = {};
    for (final m in msgs) g.putIfAbsent((m['sender'] ?? 'Unknown').toString(), () => []).add(m);
    return g.entries.map((e) {
      final sorted = List<Map<String, dynamic>>.from(e.value)
        ..sort((a, b) {
          final ta = DateTime.tryParse(a['time'] ?? '') ?? DateTime(0);
          final tb = DateTime.tryParse(b['time'] ?? '') ?? DateTime(0);
          return tb.compareTo(ta);
        });
      return {
        'sender'  : e.key,
        'messages': sorted,
        'latest'  : sorted.first,
        'count'   : sorted.length,
      };
    }).toList()
      ..sort((a, b) {
        final ta = DateTime.tryParse((a['latest'] as Map)['time'] ?? '') ?? DateTime(0);
        final tb = DateTime.tryParse((b['latest'] as Map)['time'] ?? '') ?? DateTime(0);
        return tb.compareTo(ta);
      });
  }

  String get _autoDeletionLabel =>
      _autoDeletionDays == null ? 'Never' : '$_autoDeletionDays days';

  Future<void> _restoreToInbox(String sender) async {
    final toRestore = _spamMessages.where((m) => (m['sender'] ?? '') == sender).toList();
    final updated   = _spamMessages.where((m) => (m['sender'] ?? '') != sender).toList();
    await _persistSpam(updated);
    final p   = await SharedPreferences.getInstance();
    final raw = p.getString(_manualKey);
    final man = raw != null && raw.isNotEmpty
        ? (jsonDecode(raw) as List).cast<Map<String, dynamic>>()
        : <Map<String, dynamic>>[];
    man.insertAll(0, toRestore);
    if (man.length > 200) man.removeRange(200, man.length);
    await p.setString(_manualKey, jsonEncode(man));
    setState(() {
      _spamMessages = updated;
      _threads      = _buildThreads(updated);
    });
  }

  Future<void> _deleteFromSpam(String sender) async {
    final updated = _spamMessages.where((m) => (m['sender'] ?? '') != sender).toList();
    await _persistSpam(updated);
    setState(() {
      _spamMessages = updated;
      _threads      = _buildThreads(updated);
    });
  }

  Future<void> _deleteMessageFromSpam(String time) async {
    final updated = _spamMessages.where((m) => m['time']?.toString() != time).toList();
    await _persistSpam(updated);
    setState(() {
      _spamMessages = updated;
      _threads      = _buildThreads(updated);
    });
  }

  Future<bool> _confirmDelete(String sender) async {
    bool confirmed = false;
    await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFFF6F4EC),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: const Text('Delete', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
          content: Text('Delete all messages from "$sender"?',
              style: const TextStyle(fontSize: 14, color: Color(0xFF555555))),
          actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          actions: [
            TextButton(onPressed: () { confirmed = false; Navigator.pop(ctx); },
                child: const Text('Cancel', style: TextStyle(color: Color(0xFF1A7A72)))),
            ElevatedButton(onPressed: () { confirmed = true; Navigator.pop(ctx); },
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF2554F),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                child: const Text('Delete')),
          ],
        ));
    return confirmed;
  }

  Future<void> _deleteAll() async {
    bool confirmed = false;
    await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFFF6F4EC),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: const Text('Delete All', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
          content: Text('Permanently delete all ${_spamMessages.length} phishing messages?',
              style: const TextStyle(fontSize: 14, color: Color(0xFF555555))),
          actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          actions: [
            TextButton(onPressed: () { confirmed = false; Navigator.pop(ctx); },
                child: const Text('Cancel', style: TextStyle(color: Color(0xFF1A7A72)))),
            ElevatedButton(onPressed: () { confirmed = true; Navigator.pop(ctx); },
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF2554F),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                child: const Text('Delete All')),
          ],
        ));
    if (confirmed) {
      await _persistSpam([]);
      setState(() { _spamMessages = []; _threads = []; });
    }
  }

  void _showSpamOptions(BuildContext ctx, String sender) {
    showModalBottomSheet(
        context: ctx,
        backgroundColor: Colors.transparent,
        builder: (_) => _OptionsSheet(children: [
          _SheetAction(
              icon: Icons.move_to_inbox_outlined,
              iconColor: const Color(0xFF1A7A72),
              label: 'Move to Inbox',
              onTap: () async { Navigator.pop(ctx); await _restoreToInbox(sender); }),
          _SheetAction(
              icon: Icons.flag_outlined,
              iconColor: const Color(0xFFE0A800),
              label: 'Report Inaccurate Detection',
              onTap: () { Navigator.pop(ctx); _showReportSheet(ctx, sender); }),
          _SheetAction(
              icon: Icons.delete_outline,
              iconColor: const Color(0xFFF2554F),
              label: 'Delete',
              labelColor: const Color(0xFFF2554F),
              onTap: () async {
                Navigator.pop(ctx);
                if (await _confirmDelete(sender)) await _deleteFromSpam(sender);
              }),
        ]));
  }

  void _showReportSheet(BuildContext ctx, String sender, [VoidCallback? onReported]) {
    const reasons = [
      'This is from a trusted sender',
      'This is a legitimate promotional message',
      'This is a known service or OTP message',
      'The link in this message is safe',
      'Other reason',
    ];
    final otherCtrl = TextEditingController();
    showDialog(context: ctx, builder: (dlgCtx) {
      String? selected;
      bool showConfirm = false;
      return StatefulBuilder(builder: (dlgCtx, set) {
        if (showConfirm) {
          return Dialog(
            backgroundColor: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(.12), blurRadius: 20, offset: const Offset(0, 6))],
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3F3),
                    borderRadius: const BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
                    border: Border(bottom: BorderSide(color: const Color(0xFFF2554F).withOpacity(.15))),
                  ),
                  child: Column(children: [
                    Container(width: 56, height: 56,
                        decoration: BoxDecoration(color: const Color(0xFFF2554F).withOpacity(.12), shape: BoxShape.circle),
                        child: const Icon(Icons.flag_rounded, color: Color(0xFFF2554F), size: 28)),
                    const SizedBox(height: 12),
                    const Text('Confirm Report', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    const Text('Are you sure you want to submit this report?',
                        textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Color(0xFF777777))),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                  child: Container(
                    width: double.infinity, padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: const Color(0xFFF8F6F0), borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFE0DAD0))),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Your reason', style: TextStyle(fontSize: 11, color: Color(0xFF999999), fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      Text(selected == 'Other reason' ? otherCtrl.text.trim() : selected!,
                          style: const TextStyle(fontSize: 14, color: Color(0xFF333333), fontWeight: FontWeight.w500)),
                    ]),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                  child: Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => set(() => showConfirm = false),
                        style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF666666),
                            side: const BorderSide(color: Color(0xFFDDD8CE)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(vertical: 13)),
                        child: const Text('Back', style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          Navigator.pop(dlgCtx);
                          final msgs   = _spamMessages.where((m) => (m['sender'] ?? '') == sender).toList();
                          final sample = msgs.isNotEmpty ? msgs.first : <String, dynamic>{};
                          final msgBody = sample['message']?.toString() ?? '';
                          final msgTime = sample['time']?.toString() ?? '';
                          final messageHash = sha256.convert(utf8.encode(PhishingDetector.normalizeOtp(msgBody))).toString();
                          final existing = await FirebaseFirestore.instance
                              .collection('model_feedback')
                              .where('messageHash', isEqualTo: messageHash)
                              .get();
                          const reviewedStatuses = ['trained', 'verified', 'validated', 'rejected'];
                          if (existing.docs.isNotEmpty) {
                            final doc = existing.docs.first.data();
                            final status = doc['status']?.toString() ?? '';
                            if (reviewedStatuses.contains(status)) {
                              final currentLabel = (doc['originalLabel'] ?? sample['label'] ?? 'phishing').toString().toLowerCase() == 'phishing' ? 'phishing' : 'legitimate';
                              await _applyReviewDecision(msgTime, status, currentLabel);
                              await _loadSpam();
                              return;
                            }
                          }
                          onReported?.call();
                          _showVerificationDialog(ctx);
                          _submitReport(
                            sender       : sender,
                            message      : msgBody,
                            originalLabel: 'Phishing',
                            confidence   : ((sample['confidence'] as num?)?.toDouble() ?? 0.0),
                            reason       : selected == 'Other reason' ? otherCtrl.text.trim() : selected!,
                            type         : 'inaccurate_detection',
                            source       : widget.spamEnabled ? 'spam' : 'inbox',
                            deviceId     : widget.deviceId,
                            messageTime  : msgTime,
                          );
                        },
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF2554F), foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(vertical: 13), elevation: 0),
                        child: const Text('Submit Report', style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ]),
                ),
              ]),
            ),
          );
        }

        return Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(minHeight: 420),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(.12), blurRadius: 20, offset: const Offset(0, 6))],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text('Report Inaccurate Detection',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black87)),
                    SizedBox(height: 6),
                    Text('Why do you think this detection is wrong?',
                        style: TextStyle(fontSize: 14, color: Color(0xFF999999))),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                  child: Column(children: [
                    ...reasons.map((r) => GestureDetector(
                      onTap: () => set(() => selected = r),
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                        child: Row(children: [
                          Radio<String>(
                            value: r,
                            groupValue: selected,
                            activeColor: const Color(0xFF1A7A72),
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            onChanged: (v) => set(() => selected = v),
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: Text(r, style: const TextStyle(fontSize: 15, color: Colors.black87, height: 1.4))),
                        ]),
                      ),
                    )),
                    if (selected == 'Other reason')
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                        child: TextField(controller: otherCtrl, maxLines: 3,
                          style: const TextStyle(fontSize: 14),
                          onChanged: (_) => set(() {}),
                          decoration: InputDecoration(
                            hintText: 'Describe your reason…',
                            hintStyle: const TextStyle(color: Color(0xFFAAAAAA), fontSize: 13),
                            filled: true, fillColor: Colors.white,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE0DAD0))),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF1A7A72), width: 1.5)),
                            contentPadding: const EdgeInsets.all(12),
                          ),
                        ),
                      ),
                  ]),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 16, 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(dlgCtx),
                      child: const Text('Cancel', style: TextStyle(color: Color(0xFF888888), fontSize: 15)),
                    ),
                    TextButton(
                      onPressed: (selected == null || (selected == 'Other reason' && otherCtrl.text.trim().isEmpty))
                          ? null
                          : () {
                        // Push confirm dialog on top — reason dialog stays underneath
                        showDialog(
                          context: dlgCtx,
                          barrierColor: Colors.black.withOpacity(.35),
                          builder: (confirmCtx) => AlertDialog(
                            backgroundColor: const Color(0xFFF0EDE6),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                            title: Row(children: const [
                              Icon(Icons.warning_amber_rounded, color: Color(0xFFE0A800), size: 26),
                              SizedBox(width: 10),
                              Text('Confirm Report',
                                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                            ]),
                            content: const Text(
                              'This action cannot be undone. Are you sure you want to flag this detection as inaccurate?',
                              style: TextStyle(fontSize: 14, color: Color(0xFF555555), height: 1.5),
                            ),
                            actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(confirmCtx),
                                child: const Text('Cancel',
                                    style: TextStyle(color: Color(0xFF888888), fontWeight: FontWeight.w500)),
                              ),
                              ElevatedButton(
                                onPressed: () async {
                                  final msgs   = _spamMessages.where((m) => (m['sender'] ?? '') == sender).toList();
                                  final sample = msgs.isNotEmpty ? msgs.first : <String, dynamic>{};
                                  final msgBody = sample['message']?.toString() ?? '';
                                  final msgTime = sample['time']?.toString() ?? '';
                                  final messageHash = sha256.convert(utf8.encode(PhishingDetector.normalizeOtp(msgBody))).toString();
                                  final existing = await FirebaseFirestore.instance
                                      .collection('model_feedback')
                                      .where('messageHash', isEqualTo: messageHash)
                                      .get();
                                  Navigator.pop(confirmCtx);
                                  Navigator.pop(dlgCtx);
                                  const reviewedStatuses = ['trained', 'verified', 'validated', 'rejected'];
                                  if (existing.docs.isNotEmpty) {
                                    final doc = existing.docs.first.data();
                                    final status = doc['status']?.toString() ?? '';
                                    if (reviewedStatuses.contains(status)) {
                                      // Don't re-apply — the label is already correct in local storage.
                                      // Just read the current actual label and show the dialog.
                                      final currentLabel = (doc['originalLabel'] ?? sample['label'] ?? 'phishing').toString().toLowerCase() == 'phishing' ? 'phishing' : 'legitimate';
                                      await _applyReviewDecision(msgTime, status, currentLabel);
                                      await _loadSpam();

                                      final p2 = await SharedPreferences.getInstance();
                                      final existingReportId = existing.docs.first.id;
                                      final spamEnabled = p2.getBool('spam_folder_enabled') ?? false;

                                      final viewedRaw = p2.getString('viewed_report_ids');
                                      final viewed = viewedRaw != null && viewedRaw.isNotEmpty
                                          ? (jsonDecode(viewedRaw) as List).cast<String>().toSet()
                                          : <String>{};
                                      viewed.remove(existingReportId);
                                      await p2.setString('viewed_report_ids', jsonEncode(viewed.toList()));

                                      final tempReport = ReportModel(
                                        reportId      : existingReportId,
                                        message       : msgBody,
                                        originalLabel : currentLabel,
                                        correctedLabel: currentLabel,
                                        confidence    : 0,
                                        reason        : doc['reason']?.toString() ?? '',
                                        status        : ReportStatus.validated,
                                        reportedAt    : DateTime.now(),
                                        type          : 'inaccurate_report',
                                      );

                                      if (mounted) {
                                        // Find the _SpamConversationPageState to show the dialog
                                        if (mounted) {
                                          showDialog(
                                            context: context,
                                            barrierDismissible: false,
                                            barrierColor: Colors.black.withOpacity(.4),
                                            builder: (dlgCtx) {
                                              final isValidated = tempReport.status == ReportStatus.validated;
                                              final color = isValidated ? const Color(0xFF1A7A72) : const Color(0xFFF2554F);
                                              final wasOriginallyPhishing = tempReport.originalLabel.toLowerCase() == 'phishing';
                                              final reportedAsLabel = wasOriginallyPhishing ? 'Safe' : 'Phishing';
                                              final String actionTaken = wasOriginallyPhishing
                                                  ? 'Label remains Phishing — already reviewed.'
                                                  : 'Label remains Safe — already reviewed.';

                                              return Dialog(
                                                backgroundColor: Colors.transparent,
                                                child: Container(
                                                  decoration: BoxDecoration(
                                                    color: const Color(0xFFF6F4EC),
                                                    borderRadius: BorderRadius.circular(24),
                                                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(.15), blurRadius: 24, offset: const Offset(0, 8))],
                                                  ),
                                                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                                                    Padding(
                                                      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
                                                      child: Row(children: [
                                                        Icon(isValidated ? Icons.check_circle : Icons.cancel, color: color, size: 28),
                                                        const SizedBox(width: 10),
                                                        const Expanded(child: Text('Report Reviewed', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
                                                      ]),
                                                    ),
                                                    Padding(
                                                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                                                      child: Container(
                                                        width: double.infinity,
                                                        padding: const EdgeInsets.all(14),
                                                        decoration: BoxDecoration(
                                                          color: color.withOpacity(.08),
                                                          borderRadius: BorderRadius.circular(14),
                                                          border: Border.all(color: color.withOpacity(.2)),
                                                        ),
                                                        child: Text(
                                                          tempReport.message.length > 120 ? '${tempReport.message.substring(0, 120)}…' : tempReport.message,
                                                          style: const TextStyle(fontSize: 13, color: Color(0xFF333333), height: 1.5),
                                                        ),
                                                      ),
                                                    ),
                                                    Padding(
                                                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                                                      child: Column(children: [
                                                        _dialogDetailRow('Reported as:', reportedAsLabel, bold: true),
                                                        const SizedBox(height: 8),
                                                        _dialogDetailRow('Report Status:', isValidated ? 'Accepted' : 'Rejected', valueColor: color, valueIcon: isValidated ? Icons.check_circle : Icons.cancel_outlined),
                                                        const SizedBox(height: 8),
                                                        _dialogDetailRow('Action taken:', actionTaken),
                                                      ]),
                                                    ),
                                                    Padding(
                                                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                                                      child: Column(children: [
                                                        SizedBox(
                                                          width: double.infinity,
                                                          child: ElevatedButton.icon(
                                                            onPressed: () {
                                                              Navigator.pop(dlgCtx);
                                                              Navigator.of(context).popUntil((route) => route.isFirst);
                                                              Future.delayed(const Duration(milliseconds: 300), () {
                                                                widget.onOpenConversation?.call(sender, tempReport.message);
                                                              });
                                                            },
                                                            icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                                                            label: const Text('Go to message', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                                                            style: ElevatedButton.styleFrom(
                                                              backgroundColor: color, foregroundColor: Colors.white,
                                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                                              elevation: 0, padding: const EdgeInsets.symmetric(vertical: 14),
                                                            ),
                                                          ),
                                                        ),
                                                        const SizedBox(height: 10),
                                                        SizedBox(
                                                          width: double.infinity,
                                                          child: OutlinedButton(
                                                            onPressed: () => Navigator.pop(dlgCtx),
                                                            style: OutlinedButton.styleFrom(
                                                              foregroundColor: color,
                                                              side: BorderSide(color: color.withOpacity(.5)),
                                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                                              padding: const EdgeInsets.symmetric(vertical: 14),
                                                            ),
                                                            child: const Text('Got it', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                                                          ),
                                                        ),
                                                      ]),
                                                    ),
                                                  ]),
                                                ),
                                              );
                                            },
                                          );
                                        }
                                      }
                                      return;
                                    }
                                  }
                                  onReported?.call();
                                  _showVerificationDialog(ctx);
                                  _submitReport(
                                    message      : msgBody,
                                    originalLabel: 'phishing',
                                    confidence   : ((sample['confidence'] as num?)?.toDouble() ?? 0.0),
                                    reason       : selected == 'Other reason' ? otherCtrl.text.trim() : selected!,
                                    source       : widget.spamEnabled ? 'spam' : 'inbox',
                                    deviceId     : widget.deviceId,
                                    sender       : sender,
                                    messageTime  : msgTime,
                                  );
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFF2554F),
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                  elevation: 0,
                                ),
                                child: const Text('Submit Report',
                                    style: TextStyle(fontWeight: FontWeight.w600)),
                              ),
                            ],
                          ),
                        );
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF888888),
                        disabledForegroundColor: const Color(0xFFBBBBBB),
                      ),
                      child: const Text('Submit', style: TextStyle(fontSize: 15)),
                    ),
                  ],
                ),
              ),
            ]),
          ),
        );
      });
    });
  }

  void _showVerificationDialog(BuildContext ctx) {
    showDialog(
      context: ctx,
      barrierColor: Colors.black.withOpacity(.35),
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(.15), blurRadius: 24, offset: const Offset(0, 8))],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
              decoration: const BoxDecoration(
                color: Color(0xFF1A7A72),
                borderRadius: BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
              ),
              child: Column(children: [
                Container(width: 60, height: 60,
                    decoration: BoxDecoration(color: Colors.white.withOpacity(.15), shape: BoxShape.circle),
                    child: const Icon(Icons.hourglass_top_rounded, color: Colors.white, size: 32)),
                const SizedBox(height: 14),
                const Text('Verification in Progress', textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
                const SizedBox(height: 6),
                Text('Your report has been submitted',
                    style: TextStyle(fontSize: 13, color: Colors.white.withOpacity(.8))),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
              child: Column(children: [
                _VerifStep(icon: Icons.check_circle_rounded, iconColor: const Color(0xFF1A7A72),
                    title: 'Report Submitted', subtitle: 'Your report has been received.', done: true),
                _VerifStep(icon: Icons.manage_search_rounded, iconColor: const Color(0xFFE0A800),
                    title: 'Under Review', subtitle: 'Our team is reviewing the detection.', done: false, active: true),
                _VerifStep(icon: Icons.verified_rounded, iconColor: const Color(0xFF888888),
                    title: 'Decision', subtitle: 'Label will be updated once reviewed.', done: false, isLast: true),
                const SizedBox(height: 20),
                SizedBox(width: double.infinity, height: 46,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1A7A72), foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)), elevation: 0),
                    child: const Text('Got it', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  void _showDeletionDropdown(BuildContext btnCtx) {
    final box     = btnCtx.findRenderObject() as RenderBox;
    final overlay = Navigator.of(btnCtx).overlay!.context.findRenderObject() as RenderBox;
    final pos = RelativeRect.fromRect(
        Rect.fromPoints(
            box.localToGlobal(Offset.zero, ancestor: overlay),
            box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay)),
        Offset.zero & overlay.size);
    showMenu<int>(
      context: btnCtx,
      position: pos,
      color: const Color(0xFF1A7A72),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      items: _deletionOptions.map((opt) => PopupMenuItem<int>(
          value: opt.days,
          child: Text(opt.label, style: TextStyle(fontSize: 14, color: Colors.white,
              fontWeight: (_autoDeletionDays == opt.days || (opt.days == -1 && _autoDeletionDays == null))
                  ? FontWeight.w600 : FontWeight.normal)))).toList(),
    ).then((val) async {
      if (val == null) return;
      final days = val == -1 ? null : val;
      await _savePref(days);
      final updated = _applyAutoDeletion(_spamMessages);
      await _persistSpam(updated);
      setState(() { _spamMessages = updated; _threads = _buildThreads(updated); });
    });
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final phishingCount = _spamMessages.length;
    final senderCount   = _threads.length;
    return Scaffold(
      backgroundColor: const Color(0xFFF6F4EC),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A7A72),
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        title: const Text('Spam Folder',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
        actions: [
          if (_activeTab == 0) ...[
            IconButton(
              tooltip: 'Search',
              icon: const Icon(Icons.search),
              onPressed: () {
                showSearch(
                  context: context,
                  delegate: _SpamSearchDelegate(
                    threads: _threads,
                    formatTime: widget.formatTime,
                    deviceId: widget.deviceId,
                    onRestore: _restoreToInbox,
                    onDelete: _deleteFromSpam,
                    onConfirmDelete: _confirmDelete,
                    onDeleteMessage: _deleteMessageFromSpam,
                    onReport: (sender, onReported) =>
                        _showReportSheet(context, sender, onReported),
                  ),
                );
              },
            ),
            if (!_loading && _spamMessages.isNotEmpty)
              IconButton(
                  tooltip: 'Delete all',
                  icon: const Icon(Icons.delete_sweep_outlined),
                  onPressed: _deleteAll),
          ],
        ],
      ),
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          Expanded(
            child: _activeTab == 1
                ? _buildReportsTab()
                : _loading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF1A7A72)))
                : Column(children: [
              if (_spamMessages.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                  child: Text(
                    '$phishingCount phishing message${phishingCount != 1 ? 's' : ''} from $senderCount sender${senderCount != 1 ? 's' : ''}',
                    style: const TextStyle(fontSize: 13, color: Color(0xFF888888)),
                  ),
                ),
                const Divider(height: 1, color: Color(0xFFDDD8CE)),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(children: [
                  const Icon(Icons.timer_outlined, size: 16, color: Color(0xFF1A7A72)),
                  const SizedBox(width: 8),
                  const Text('Auto-delete spam after',
                      style: TextStyle(fontSize: 14, color: Colors.black87)),
                  const Spacer(),
                  Builder(builder: (btnCtx) => GestureDetector(
                    onTap: () => _showDeletionDropdown(btnCtx),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                          color: const Color(0xFF1A7A72),
                          borderRadius: BorderRadius.circular(8)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(_autoDeletionLabel,
                            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                        const SizedBox(width: 4),
                        const Icon(Icons.arrow_drop_down, color: Colors.white, size: 18),
                      ]),
                    ),
                  )),
                ]),
              ),
              const Divider(height: 1, color: Color(0xFFDDD8CE)),
              Expanded(
                child: _threads.isEmpty
                    ? const Center(
                    child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text(
                            'No spam messages yet.\n\nPhishing messages will appear here.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Color(0xFF888888), fontSize: 15, height: 1.6))))
                    : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
                    itemCount: _threads.length,
                    separatorBuilder: (_, __) =>
                    const Divider(height: 1, color: Color(0xFFEEEBE0)),
                    itemBuilder: (ctx, i) {
                      final thread = _threads[i];
                      final sender = thread['sender'] as String;
                      final latest = thread['latest'] as Map<String, dynamic>;
                      final count  = thread['count'] as int;
                      final time   = widget.formatTime(latest['time'] as String?);
                      return InkWell(
                          onLongPress: () => _showSpamOptions(ctx, sender),
                          onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => _SpamConversationPage(
                                    messages: thread['messages'] as List<Map<String, dynamic>>,
                                    sender: sender,
                                    formatTime: widget.formatTime,
                                    onRestore: () => _restoreToInbox(sender),
                                    onDelete: () => _deleteFromSpam(sender),
                                    onConfirmDelete: () => _confirmDelete(sender),
                                    onDeleteMessage: _deleteMessageFromSpam,
                                    onReport: (onReported) =>
                                        _showReportSheet(context, sender, onReported),
                                    deviceId: widget.deviceId,
                                    spamEnabled: widget.spamEnabled,
                                  ))).then((_) => _loadSpam()),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              // Avatar with red border
                              Container(
                                width: 46, height: 46,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEDE8DF),
                                  borderRadius: BorderRadius.circular(23),
                                  border: Border.all(
                                      color: const Color(0xFFF2554F).withOpacity(.5),
                                      width: 1.5),
                                ),
                                child: const Icon(Icons.person,
                                    color: Color(0xFF999999), size: 26),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Row(children: [
                                    Expanded(
                                        child: Text(sender,
                                            style: const TextStyle(
                                                fontSize: 15, fontWeight: FontWeight.w600),
                                            overflow: TextOverflow.ellipsis)),
                                    // Warning badge beside time
                                    if (count > 0)
                                      Container(
                                        margin: const EdgeInsets.only(right: 6),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 7, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFF2554F).withOpacity(.15),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                                          const Icon(Icons.warning_amber_rounded,
                                              size: 11, color: Color(0xFFF2554F)),
                                          const SizedBox(width: 3),
                                          Text(
                                            '$count',
                                            style: const TextStyle(
                                                color: Color(0xFFF2554F),
                                                fontSize: 11,
                                                fontWeight: FontWeight.w700),
                                          ),
                                        ]),
                                      ),
                                    Text(time,
                                        style: const TextStyle(
                                            fontSize: 12, color: Color(0xFF999999))),
                                  ]),
                                  const SizedBox(height: 3),
                                  Text((latest['message'] ?? '').toString(),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 13,
                                          color: Color(0xFF666666),
                                          height: 1.4)),
                                ]),
                              ),
                            ]),
                          ),
                      );
                    }),
              ),
            ]),
          ),

          // ── Bottom nav ───────────────────────────────────────────────────
          _buildBottomNav(),
        ]),
      ),
    );
  }

  // ── Reports tab ───────────────────────────────────────────────────────────

  bool _hideReviewedSpam = false;

  Widget _buildReportsTab() {
    if (widget.deviceId.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF1A7A72)));
    }
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(children: [
          // Report count on the left
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('model_feedback')
                  .snapshots(),
              builder: (context, snap) {
                final count = snap.data?.docs.where((doc) {
                  final data = doc.data() as Map<String, dynamic>;
                  final status = data['status']?.toString() ?? '';
                  return status == 'pending' || status == 'under_review';
                }).length ?? 0;
                return Text(
                  count == 0
                      ? 'No reports yet'
                      : '$count inaccurate detection report${count == 1 ? '' : 's'}',
                  style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF888888),
                      fontWeight: FontWeight.w500),
                );
              },
            ),
          ),
          // Hide reviewed button on the right
          GestureDetector(
            onTap: () => setState(() => _hideReviewedSpam = !_hideReviewedSpam),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFF1A7A72), width: 1.5),
                borderRadius: BorderRadius.circular(30),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(
                  _hideReviewedSpam ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                  size: 16, color: const Color(0xFF1A7A72),
                ),
                const SizedBox(width: 6),
                Text(
                  _hideReviewedSpam ? 'Show all' : 'Hide reviewed',
                  style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF1A7A72),
                      fontWeight: FontWeight.w600),
                ),
              ]),
            ),
          ),
        ]),
      ),
      Expanded(
        child: RefreshIndicator(
          color: const Color(0xFF1A7A72),
          onRefresh: () async => setState(() {}),
          child: ReportTrackerBody(
            deviceId: widget.deviceId,
            source: 'spam',
            spamFolderEnabled: widget.spamEnabled,
            onOpenConversation: (sender, messageBody) async {
              Navigator.of(context).popUntil((route) => route.isFirst);
              await Future.delayed(const Duration(milliseconds: 300));
              widget.onOpenConversation?.call(sender, messageBody);
            },
            onToggleHideReviewed: null,
            onHideReviewedChanged: null,
            onViewedChanged: _refreshSpamBadge,
          ),
        ),
      ),
    ]);
  }

  // ── Bottom nav ────────────────────────────────────────────────────────────

  Widget _buildBottomNav() {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Color(0x1A000000), blurRadius: 12, offset: Offset(0, -4))],
        borderRadius: BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            _buildNavTab(index: 0, icon: Icons.phishing, label: 'Smishing', badge: _threads.length),
            _buildNavTab(index: 1, icon: Icons.assignment_outlined, label: 'Reports', badge: _spamReportCount),
          ]),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  Widget _buildNavTab({required int index, required IconData icon, required String label, int? badge}) {
    final isActive = _activeTab == index;
    final hasBadge = badge != null && badge > 0;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _activeTab = index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          decoration: BoxDecoration(
            color: isActive ? const Color(0xFF1A7A72).withOpacity(.15) : Colors.transparent,
            borderRadius: BorderRadius.circular(30),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Padding(
                    padding: EdgeInsets.only(
                      top: hasBadge ? 6 : 0,
                      right: hasBadge ? 10 : 0,
                    ),
                    child: Icon(icon, size: 16, color: isActive ? const Color(0xFF1A7A72) : const Color(0xFF888888)),
                  ),
                  if (hasBadge)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF2554F),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          badge > 99 ? '99+' : '$badge',
                          style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(label, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                      color: isActive ? const Color(0xFF1A7A72) : const Color(0xFF888888)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Spam Search Delegate
// ─────────────────────────────────────────────────────────────────────────────

class _SpamSearchDelegate extends SearchDelegate<String> {
  final List<Map<String, dynamic>> threads;
  final String Function(String?) formatTime;
  final String deviceId;
  final Future<void> Function(String) onRestore;
  final Future<void> Function(String) onDelete;
  final Future<bool> Function(String) onConfirmDelete;
  final Future<void> Function(String) onDeleteMessage;
  final void Function(String sender, VoidCallback onReported) onReport;

  _SpamSearchDelegate({
    required this.threads,
    required this.formatTime,
    required this.deviceId,
    required this.onRestore,
    required this.onDelete,
    required this.onConfirmDelete,
    required this.onDeleteMessage,
    required this.onReport,
  });

  @override
  String get searchFieldLabel => 'Search spam messages…';

  @override
  List<Widget> buildActions(BuildContext context) => [
    if (query.isNotEmpty)
      IconButton(
        icon: const Icon(Icons.clear),
        onPressed: () => query = '',
      ),
  ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
    icon: const Icon(Icons.arrow_back),
    onPressed: () => close(context, ''),
  );

  @override
  Widget buildResults(BuildContext context) => _buildList(context);

  @override
  Widget buildSuggestions(BuildContext context) => _buildList(context);

  Widget _buildList(BuildContext context) {
    final q = query.toLowerCase();
    final results = threads.where((t) {
      final sender = (t['sender'] as String).toLowerCase();
      if (sender.contains(q)) return true;
      final msgs = t['messages'] as List<Map<String, dynamic>>;
      return msgs.any((m) =>
          (m['message'] ?? '').toString().toLowerCase().contains(q));
    }).toList();

    if (results.isEmpty) {
      return Center(
        child: Text(q.isEmpty ? 'Type to search' : 'No results for "$query"',
            style: const TextStyle(color: Color(0xFF888888))),
      );
    }

    return ListView.separated(
      itemCount: results.length,
      separatorBuilder: (_, __) =>
      const Divider(height: 1, color: Color(0xFFEEEBE0)),
      itemBuilder: (ctx, i) {
        final thread = results[i];
        final sender = thread['sender'] as String;
        final latest = thread['latest'] as Map<String, dynamic>;
        final count = thread['count'] as int;
        final time = formatTime(latest['time'] as String?);
        final preview = (latest['message'] ?? '').toString();

        return ListTile(
          leading: Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: const Color(0xFFEDE8DF),
              borderRadius: BorderRadius.circular(23),
              border: Border.all(
                  color: const Color(0xFFF2554F).withOpacity(.4), width: 1.5),
            ),
            child: const Icon(Icons.person, color: Color(0xFF999999), size: 26),
          ),
          title: Text(sender,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
          subtitle: Text(preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Color(0xFF666666))),
          trailing: Text(time,
              style: const TextStyle(fontSize: 12, color: Color(0xFF999999))),
          onTap: () {
            close(context, sender);
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => _SpamConversationPage(
                  messages: thread['messages'] as List<Map<String, dynamic>>,
                  sender: sender,
                  formatTime: formatTime,
                  onRestore: () => onRestore(sender),
                  onDelete: () => onDelete(sender),
                  onConfirmDelete: () => onConfirmDelete(sender),
                  onDeleteMessage: onDeleteMessage,
                  onReport: (onReported) => onReport(sender, onReported),
                  deviceId: deviceId,
                  spamEnabled: true,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Spam Conversation Page
// ─────────────────────────────────────────────────────────────────────────────

class _SpamConversationPage extends StatefulWidget {
  final List<Map<String, dynamic>> messages;
  final String sender;
  final String Function(String?) formatTime;
  final VoidCallback onRestore;
  final VoidCallback onDelete;
  final Future<bool> Function() onConfirmDelete;
  final Future<void> Function(String time) onDeleteMessage;
  final void Function(VoidCallback onReported) onReport;
  final String deviceId;
  final bool spamEnabled;
  const _SpamConversationPage({
    required this.messages,
    required this.sender,
    required this.formatTime,
    required this.onRestore,
    required this.onDelete,
    required this.onConfirmDelete,
    required this.onDeleteMessage,
    required this.onReport,
    required this.deviceId,
    required this.spamEnabled,
  });
  @override
  State<_SpamConversationPage> createState() => _SpamConversationPageState();
}

class _SpamConversationPageState extends State<_SpamConversationPage> {
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  late final List<GlobalKey> _itemKeys;
  bool _selectMode = false;
  bool   _searchActive    = false;
  String _query           = '';
  int    _currentMatchIdx = 0;
  Color  _themeColor   = const Color(0xFF1A7A72);
  String _wallpaperKey = 'background';

  final Map<String, String> _reportStatus  = {};
  final Set<String> _dismissedNotes        = {};
  String get _statusKey =>
      'spam_report_status_${widget.sender.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';
  String get _dismissedNotesKey =>
      'spam_dismissed_notes_${widget.sender.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';
  StreamSubscription<QuerySnapshot>? _firestoreSub;

  late List<Map<String, dynamic>> _localMessages;

  @override
  void initState() {
    super.initState();
    _localMessages = List.from(widget.messages);
    _itemKeys = List.generate(_localMessages.length, (_) => GlobalKey());
    _loadChatroomPrefs();
    _loadAndSyncStatus().then((_) => _startRealtimeListener());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _firestoreSub?.cancel();
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _startRealtimeListener() {
    _firestoreSub?.cancel();
    if (widget.deviceId.isEmpty) return;
    _firestoreSub = FirebaseFirestore.instance
        .collection('model_feedback')
        .snapshots()
        .listen((snap) async {
      bool changed = false;
      const reviewedStatuses = {'verified', 'validated', 'trained', 'rejected'};

      final activeMessageIds = <String>{};
      for (final doc in snap.docs) {
        final data          = doc.data() as Map<String, dynamic>;
        final msgTime       = (data['messageId'] ?? data['messageTime'] ?? '').toString();
        final status        = data['status']?.toString() ?? 'under_review';
        final originalLabel = (data['originalLabel'] ?? '').toString().toLowerCase();
        if (msgTime.isNotEmpty) {
          activeMessageIds.add(msgTime);
          final prevStatus = _reportStatus[msgTime];
          if (prevStatus != status) {
            _reportStatus[msgTime] = status;
            changed = true;

            // Apply label + move when a review decision just arrived
            if (reviewedStatuses.contains(status) &&
                !reviewedStatuses.contains(prevStatus ?? '')) {
              await _applyReviewDecision(msgTime, status, originalLabel);
            }
          }
        }
      }

      // Remove deleted reports (deleted without review — revert to original label)
      final deletedKeys = _reportStatus.keys
          .where((k) => !activeMessageIds.contains(k))
          .toList();
      for (final key in deletedKeys) {
        _reportStatus.remove(key);
        changed = true;
      }

      if (changed && mounted) {
        setState(() {});
        await _saveStatus();
      }
    }, onError: (e) => debugPrint('Spam realtime listener error: $e'));
  }

  Future<void> _loadChatroomPrefs() async {
    if (widget.spamEnabled) {
      if (mounted) setState(() => _wallpaperKey = '8');
      return;
    }
    final prefs = await loadChatroomPrefs(widget.sender);
    if (!mounted) return;
    Color color = const Color(0xFF1A7A72);
    for (final t in kThemes) {
      if (t.key == prefs.theme) { color = t.color; break; }
    }
    setState(() {
      _themeColor   = color;
      _wallpaperKey = prefs.wallpaper;
    });
  }

  Color _wallpaperColorFromKey(String key) {
    for (final w in kWallpapers) {
      if (w.key == key) return w.color;
    }
    return const Color(0xFFF0EDE6);
  }

  Future<void> _loadAndSyncStatus() async {
    final p    = await SharedPreferences.getInstance();
    final raw  = p.getString(_statusKey);
    final raw2 = p.getString(_dismissedNotesKey);
    if (raw != null && raw.isNotEmpty) {
      final map = (jsonDecode(raw) as Map).cast<String, String>();
      if (mounted) setState(() { _reportStatus.clear(); _reportStatus.addAll(map); });
    }
    if (raw2 != null && raw2.isNotEmpty) {
      final list = (jsonDecode(raw2) as List).cast<String>();
      if (mounted) setState(() { _dismissedNotes.clear(); _dismissedNotes.addAll(list); });
    }
    await _syncStatusFromFirestore();
  }

  Future<void> _syncStatusFromFirestore() async {
    // No per-message sync without messageId field in Firebase
  }

  void _showLocalReportResultNotice(String sender, String message, String status,
      {String originalLabel = '', bool popToInbox = false}) {
    final isVerified       = status == 'verified';
    final wasPhishing      = originalLabel == 'phishing';
    final bool finallyPhishing = isVerified ? !wasPhishing : wasPhishing;
    final bool movedToInbox    = !finallyPhishing;
    final color    = movedToInbox ? const Color(0xFF1A7A72) : const Color(0xFFF2554F);
    final icon     = movedToInbox ? Icons.check_circle_outline : Icons.cancel_outlined;
    final title    = isVerified ? 'Report Verified' : 'Report Reviewed';
    final subtitle = movedToInbox
        ? 'The message from "$sender" is confirmed safe and has been moved to your inbox.'
        : 'The message from "$sender" is confirmed phishing. It remains in the Spam Folder.';
    final preview  = message.length > 80 ? '${message.substring(0, 80)}…' : message;
    final nav      = Navigator.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(.2),
      builder: (dlgCtx) => Material(
        color: Colors.transparent,
        child: Center(child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 28),
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(.12), blurRadius: 16, offset: const Offset(0, 4))]),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: color, size: 40),
            const SizedBox(height: 12),
            Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: color, decoration: TextDecoration.none)),
            const SizedBox(height: 8),
            Text(subtitle, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Color(0xFF555555), height: 1.5, decoration: TextDecoration.none)),
            const SizedBox(height: 10),
            Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(color: const Color(0xFFF6F4EC), borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFDDD8CE))),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(sender, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF555555), decoration: TextDecoration.none)),
                  const SizedBox(height: 4),
                  Text(preview, style: const TextStyle(fontSize: 12, color: Color(0xFF888888), height: 1.4, decoration: TextDecoration.none)),
                ])),
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, height: 42,
                child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(dlgCtx).pop();
                      if (popToInbox) nav.popUntil((route) => route.isFirst);
                    },
                    style: ElevatedButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                    child: const Text('OK', style: TextStyle(fontWeight: FontWeight.w600)))),
          ]),
        )),
      ),
    );
  }

  Future<bool> _applyReviewDecision(String msgTime, String status, String originalLabel) async {
    try {
      final p           = await SharedPreferences.getInstance();
      const spamKey     = 'spam_folder_logs';
      const manualKey   = 'manual_scan_logs';
      final spamRaw = p.getString(spamKey);
      final manRaw  = p.getString(manualKey);
      final spam    = spamRaw != null && spamRaw.isNotEmpty ? (jsonDecode(spamRaw) as List).cast<Map<String, dynamic>>() : <Map<String, dynamic>>[];
      final man     = manRaw  != null && manRaw.isNotEmpty  ? (jsonDecode(manRaw)  as List).cast<Map<String, dynamic>>() : <Map<String, dynamic>>[];
      final inboxIdx = man.indexWhere((m) => m['time']?.toString() == msgTime);
      final spamIdx  = spam.indexWhere((m) => m['time']?.toString() == msgTime);
      Map<String, dynamic>? entry;
      bool wasInInbox = false;
      if (inboxIdx != -1) { entry = Map<String, dynamic>.from(man[inboxIdx]);  wasInInbox = true; }
      else if (spamIdx != -1) { entry = Map<String, dynamic>.from(spam[spamIdx]); wasInInbox = false; }
      if (entry == null) return false;
      entry['verifiedByCrew'] = true;
      final bool wasPhishing     = originalLabel == 'phishing';
      final bool verified        = status == 'verified' || status == 'validated';
      final String finalLabel    = verified ? (wasPhishing ? 'Safe' : 'Phishing') : (wasPhishing ? 'Phishing' : 'Safe');
      entry['label'] = finalLabel;
      final bool shouldBeInInbox = finalLabel.toLowerCase() == 'safe';
      if (wasInInbox) {
        man.removeAt(inboxIdx);
        if (shouldBeInInbox) {
          man.insert(0, entry); if (man.length > 200) man.removeRange(200, man.length);
          await p.setString(manualKey, jsonEncode(man));
        } else {
          await p.setString(manualKey, jsonEncode(man));
          if (!spam.any((m) => m['time']?.toString() == msgTime)) {
            spam.insert(0, entry); if (spam.length > 200) spam.removeRange(200, spam.length);
            await p.setString(spamKey, jsonEncode(spam));
          }
        }
        return false;
      } else {
        spam.removeAt(spamIdx);
        if (shouldBeInInbox) {
          await p.setString(spamKey, jsonEncode(spam));
          if (!man.any((m) => m['time']?.toString() == msgTime)) {
            man.insert(0, entry); if (man.length > 200) man.removeRange(200, man.length);
            await p.setString(manualKey, jsonEncode(man));
          }
          return true;
        } else {
          spam.insert(0, entry); if (spam.length > 200) spam.removeRange(200, spam.length);
          await p.setString(spamKey, jsonEncode(spam));
          return false;
        }
      }
    } catch (e) { debugPrint('Spam apply review decision error: $e'); return false; }
  }

  String? _statusFor(int i) {
    final time = _localMessages[i]['time']?.toString() ?? '';
    return _reportStatus[time];
  }

  List<int> get _matchIndices {
    if (_query.isEmpty) return [];
    return List.generate(_localMessages.length, (i) => i)
        .where((i) => (_localMessages[i]['message'] ?? '').toString().toLowerCase().contains(_query.toLowerCase()))
        .toList();
  }

  void _scrollToFirst() {
    _currentMatchIdx = 0;
    _scrollToMatchIdx(_currentMatchIdx);
  }

  void _scrollToMatchIdx(int idx) {
    final matches = _matchIndices;
    if (matches.isEmpty) return;
    final clampedIdx = idx.clamp(0, matches.length - 1);
    final ctx = _itemKeys[matches[clampedIdx]].currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
  }

  void _scrollToNext() {
    final matches = _matchIndices;
    if (matches.isEmpty) return;
    setState(() => _currentMatchIdx = (_currentMatchIdx + 1) % matches.length);
    _scrollToMatchIdx(_currentMatchIdx);
  }

  void _scrollToPrev() {
    final matches = _matchIndices;
    if (matches.isEmpty) return;
    setState(() => _currentMatchIdx = (_currentMatchIdx - 1 + matches.length) % matches.length);
    _scrollToMatchIdx(_currentMatchIdx);
  }

  Widget _highlightText(String text, String query) {
    if (query.isEmpty) return buildPhishingHighlightedText(text);
    final lower = text.toLowerCase(); final lowerQ = query.toLowerCase();
    final spans = <TextSpan>[]; int start = 0;
    while (true) {
      final idx = lower.indexOf(lowerQ, start);
      if (idx == -1) { if (start < text.length) spans.add(TextSpan(text: text.substring(start))); break; }
      if (idx > start) spans.add(TextSpan(text: text.substring(start, idx)));
      spans.add(TextSpan(text: text.substring(idx, idx + query.length),
          style: const TextStyle(backgroundColor: Color(0xFFFFE57F), color: Colors.black, fontWeight: FontWeight.bold)));
      start = idx + query.length;
    }
    return RichText(text: TextSpan(style: const TextStyle(fontSize: 14, color: Colors.black87, height: 1.5), children: spans));
  }

  void _showMessageOptions(BuildContext ctx, int origIdx) {
    final msg = _localMessages[origIdx];
    final message = (msg['message'] ?? '').toString();
    final msgTime = msg['time']?.toString() ?? '';
    final status = _reportStatus[msgTime];
    final isUnderReview = status == 'pending' || status == 'under_review';

    showModalBottomSheet(
      context: ctx,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
          ),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40, height: 4,
            margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFCCCCC0),
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // View details
          _sheetActionTile(
            icon: Icons.info_outline,
            iconColor: const Color(0xFF1A7A72),
            label: 'View details',
            onTap: () {
              Navigator.pop(ctx);
              _showMessageDetails(ctx, origIdx);
            },
          ),

          // Restore to Inbox
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                widget.onRestore();
                if (mounted) Navigator.pop(context);
              },
              icon: const Icon(Icons.move_to_inbox_outlined,
                  color: Color(0xFF1A7A72)),
              label: const Text('Restore to Inbox',
                  style: TextStyle(
                      color: Color(0xFF1A7A72), fontWeight: FontWeight.w600)),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 50),
                side: const BorderSide(color: Color(0xFF1A7A72)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),

          // Report Inaccurate Detection
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: OutlinedButton.icon(
              onPressed: isUnderReview
                  ? null
                  : () {
                Navigator.pop(ctx);
                widget.onReport(() {
                  setState(() {
                    if (msgTime.isNotEmpty) _reportStatus[msgTime] = 'pending';
                  });
                });
              },
              icon: Icon(Icons.flag_outlined,
                  color: isUnderReview
                      ? const Color(0xFFBBBBBB)
                      : const Color(0xFFF2554F)),
              label: Text(
                isUnderReview
                    ? 'Already Under Review'
                    : 'Report Inaccurate Detection',
                style: TextStyle(
                    color: isUnderReview
                        ? const Color(0xFFBBBBBB)
                        : const Color(0xFFF2554F),
                    fontWeight: FontWeight.w600),
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 50),
                side: BorderSide(
                    color: isUnderReview
                        ? const Color(0xFFDDDDDD)
                        : const Color(0xFFF2554F)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),

          const Divider(height: 1),

          // Bottom row: Copy / Share / Delete
          SafeArea(
            top: false,
            child: Row(children: [
              _bottomAction(Icons.copy_outlined, 'Copy text', () {
                Clipboard.setData(ClipboardData(text: message));
                Navigator.pop(ctx);
              }),
              _bottomAction(Icons.share_outlined, 'Share', () {
                Navigator.pop(ctx);
                Share.share(message);
              }),
              _bottomAction(Icons.delete_outline, 'Delete', () async {
                Navigator.pop(ctx);
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (dctx) => AlertDialog(
                    backgroundColor: const Color(0xFFF6F4EC),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    title: const Text('Delete Message',
                        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
                    content: const Text('Are you sure you want to delete this message?',
                        style: TextStyle(fontSize: 14, color: Color(0xFF555555))),
                    actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dctx, false),
                          child: const Text('Cancel',
                              style: TextStyle(color: Color(0xFF1A7A72)))),
                      ElevatedButton(
                          onPressed: () => Navigator.pop(dctx, true),
                          style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFF2554F),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10))),
                          child: const Text('Delete')),
                    ],
                  ),
                );
                if (confirmed == true && mounted) {
                  final time = _localMessages[origIdx]['time']?.toString() ?? '';
                  setState(() => _localMessages.removeWhere(
                      (m) => m['time']?.toString() == time));
                  await widget.onDeleteMessage(time);
                }
              }, color: const Color(0xFFF2554F)),
            ]),
          ),
        ]),
      ),
    );
  }

  /// Compact icon+label row used inside the long-press sheet.
  Widget _sheetActionTile({
    required IconData icon,
    required Color iconColor,
    required String label,
    required VoidCallback onTap,
    Color? labelColor,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: iconColor.withOpacity(.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 16),
          Text(label,
              style: TextStyle(
                  fontSize: 15,
                  color: labelColor ?? Colors.black87,
                  fontWeight: FontWeight.w400)),
        ]),
      ),
    );
  }

  void _showMessageDetails(BuildContext ctx, int index) {
    final msg = _localMessages[index];
    final message = (msg['message'] ?? '').toString();
    final sender = widget.sender;
    final timeRaw = msg['time']?.toString() ?? '';
    final isPhishing = true; // spam folder messages are always phishing

    String formattedDate = '';
    String formattedTime = '';
    try {
      final dt = DateTime.parse(timeRaw).toLocal();
      formattedDate = DateFormat('MMMM d, yyyy').format(dt);
      formattedTime = DateFormat('h:mm a').format(dt);
    } catch (_) {}

    final rawConf = msg['confidence'];
    final confidenceText = rawConf != null
        ? '${(rawConf as num).toDouble().toStringAsFixed(1)}% confidence'
        : '99.9% confidence';

    final indicators = PhishingIndicator.detect(message, maxCount: 4);

    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius:
          BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40, height: 4,
            margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
                color: const Color(0xFFCCCCCC), borderRadius: BorderRadius.circular(2)),
          ),
          ConstrainedBox(
            constraints:
            BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Message Details',
                    style: TextStyle(
                        fontSize: 22, fontWeight: FontWeight.bold, color: Colors.black87)),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFEBEE),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFFFCDD2)),
                  ),
                  child: Row(children: [
                    Container(
                      width: 44, height: 44,
                      decoration: const BoxDecoration(
                          color: Color(0xFFFFCDD2), shape: BoxShape.circle),
                      child: const Icon(Icons.warning_rounded,
                          color: Color(0xFFD32F2F), size: 24),
                    ),
                    const SizedBox(width: 14),
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Phishing Detected',
                          style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFFD32F2F))),
                      const SizedBox(height: 2),
                      Text(confidenceText,
                          style: const TextStyle(
                              fontSize: 13, color: Color(0xFFE57373))),
                    ]),
                  ]),
                ),
                const SizedBox(height: 16),
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F5F5),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(children: [
                    _detailRowNew(Icons.person_outline_rounded, 'Sender', sender),
                    const Divider(height: 1, indent: 56, color: Color(0xFFE0E0E0)),
                    _detailRowNew(Icons.access_time_rounded, 'Date & Time',
                        '$formattedDate • $formattedTime'),
                    const Divider(height: 1, indent: 56, color: Color(0xFFE0E0E0)),
                    _detailRowNew(
                        Icons.text_fields_rounded, 'Characters', message.length.toString()),
                  ]),
                ),
                if (indicators.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Row(children: [
                    Container(
                        width: 4, height: 20,
                        decoration: const BoxDecoration(
                            color: Color(0xFFD32F2F),
                            borderRadius: BorderRadius.all(Radius.circular(2)))),
                    const SizedBox(width: 10),
                    const Text('Why this was flagged',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87)),
                  ]),
                  const SizedBox(height: 12),
                  ...indicators.map((ind) => Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    decoration: BoxDecoration(
                      color: ind.color.withOpacity(0.07),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: ind.color.withOpacity(0.18)),
                    ),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Container(
                        width: 42, height: 42,
                        decoration: BoxDecoration(
                          color: ind.color.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(ind.icon, color: ind.color, size: 22),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(ind.label,
                                    style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                        color: ind.color)),
                                const SizedBox(height: 4),
                                Text(ind.description,
                                    style: const TextStyle(
                                        fontSize: 13,
                                        color: Colors.black54,
                                        height: 1.4)),
                              ])),
                    ]),
                  )),
                ],
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _detailRowNew(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(children: [
        Icon(icon, size: 22, color: const Color(0xFF9E9E9E)),
        const SizedBox(width: 18),
        Text(label, style: const TextStyle(fontSize: 14, color: Color(0xFF9E9E9E))),
        const Spacer(),
        Text(value,
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600, color: Colors.black87)),
      ]),
    );
  }

  // Add this method to _SpamConversationPageState
  Widget _highlightSearchText(String text, String query) {
    if (query.isEmpty) return buildPhishingHighlightedText(text);
    final lower = text.toLowerCase();
    final lowerQ = query.toLowerCase();
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
        text: text.substring(idx, idx + query.length),
        style: const TextStyle(
            backgroundColor: Color(0xFFFFE57F),
            color: Colors.black,
            fontWeight: FontWeight.bold),
      ));
      start = idx + query.length;
    }
    return RichText(
      text: TextSpan(
        style: const TextStyle(fontSize: 14, color: Colors.black87, height: 1.5),
        children: spans,
      ),
    );
  }

  Widget _msgOption(IconData icon, String label, VoidCallback onTap) {
    return InkWell(onTap: onTap, child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(children: [
        Icon(icon, size: 22, color: const Color(0xFF444444)),
        const SizedBox(width: 16),
        Text(label, style: const TextStyle(fontSize: 16, color: Color(0xFF222222))),
      ]),
    ));
  }

  Widget _bottomAction(IconData icon, String label, VoidCallback onTap, {Color color = const Color(0xFF444444)}) {
    return Expanded(child: InkWell(onTap: onTap, child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(children: [
        Icon(icon, size: 24, color: color),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(fontSize: 12, color: color)),
      ]),
    )));
  }

  void _showThreeDotMenu(BuildContext ctx) {
    showMenu(
      context: ctx,
      position: const RelativeRect.fromLTRB(1000, 56, 8, 0),
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: [
        _menuItem(Icons.search, 'Search messages', () { setState(() => _searchActive = true); }),
        _menuItem(Icons.move_to_inbox_outlined, 'Move to Inbox', () { widget.onRestore(); if (mounted) Navigator.pop(context); }),
        _menuItem(Icons.delete_outline, 'Delete conversation', () async {
          if (await widget.onConfirmDelete()) { widget.onDelete(); if (mounted) Navigator.pop(context); }
        }),
        _menuItem(Icons.notifications_off_outlined, 'Mute notifications', () {}),
      ],
    );
  }

  PopupMenuItem _menuItem(IconData icon, String label, VoidCallback onTap) {
    return PopupMenuItem(onTap: onTap, child: Row(children: [
      Icon(icon, size: 20, color: const Color(0xFF444444)),
      const SizedBox(width: 12),
      Text(label, style: const TextStyle(fontSize: 15)),
    ]));
  }

  List<Map<String, dynamic>> _extractLabelDetails(Map<String, dynamic> msg) {
    for (final key in ['sublabel', 'sub_label', 'type', 'category', 'subtype', 'phishing_type', 'attack_type']) {
      final v = (msg[key] ?? '').toString().trim();
      if (v.isNotEmpty && v.toLowerCase() != 'unknown') {
        return [{'label': v, 'icon': Icons.warning_amber_rounded}];
      }
    }
    final text = (msg['message'] ?? '').toString().toLowerCase();
    final tags = <Map<String, dynamic>>[];
    if (RegExp(r'https?://|bit\.ly|tinyurl|t\.co|click.*link|tap.*link|link.*below').hasMatch(text)) tags.add({'label': 'Suspicious URL', 'icon': Icons.link});
    if (RegExp(r'prize|reward|won|winner|claim|free|gift|cash|piso|pesos|spins?|\d+\s*(pesos?|php|\$)').hasMatch(text)) tags.add({'label': 'Fake Rewards', 'icon': Icons.card_giftcard});
    if (RegExp(r'login|log in|sign in|password|username|credentials|verif|otp|one.time|confirm|code|pin|passcode').hasMatch(text)) tags.add({'label': 'Sensitive info request', 'icon': Icons.key});
    if (RegExp(r'bank|gcash|maya|paypal|credit|debit|transfer|withdraw|deposit').hasMatch(text)) tags.add({'label': 'Financial Fraud', 'icon': Icons.account_balance_wallet});
    if (RegExp(r'parcel|package|deliver|shipment|courier|postal|tracking').hasMatch(text)) tags.add({'label': 'Fake Delivery', 'icon': Icons.local_shipping});
    if (RegExp(r'sss|philhealth|pagibig|bir|lto|nbi|dfa|passport|clearance').hasMatch(text)) tags.add({'label': 'Gov. Impersonation', 'icon': Icons.account_balance});
    if (RegExp(r'job|hiring|apply|salary|earn|work from home|income|negosyo').hasMatch(text)) tags.add({'label': 'Fake Job Offer', 'icon': Icons.work_outline});
    if (tags.isNotEmpty) return tags;
    return [{'label': 'Suspicious Message', 'icon': Icons.warning_amber_rounded}];
  }

  void _showAlreadyReviewedDialog(
      ReportModel report, {
        bool spamEnabled = false,
      }) {
    final isValidated = report.status == ReportStatus.validated;
    final color = isValidated ? const Color(0xFF1A7A72) : const Color(0xFFF2554F);
    final wasOriginallyPhishing = report.originalLabel.toLowerCase() == 'phishing';
    final reportedAsLabel = wasOriginallyPhishing ? 'Safe' : 'Phishing';

    final String actionTaken;
    if (isValidated) {
      if (wasOriginallyPhishing) {
        actionTaken = 'Label updated to Safe — Moved to inbox';
      } else {
        actionTaken = spamEnabled
            ? 'Label updated to Phishing — Moved to spam'
            : 'Label updated to Phishing.';
      }
    } else {
      actionTaken = wasOriginallyPhishing
          ? 'Label remains Phishing.'
          : 'Label remains Safe.';
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(.4),
      builder: (dlgCtx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF6F4EC),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [BoxShadow(
                color: Colors.black.withOpacity(.15),
                blurRadius: 24,
                offset: const Offset(0, 8))],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
              child: Row(children: [
                Icon(isValidated ? Icons.check_circle : Icons.cancel,
                    color: color, size: 28),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('Report Reviewed',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: color.withOpacity(.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: color.withOpacity(.2)),
                ),
                child: Text(
                  report.message.length > 120
                      ? '${report.message.substring(0, 120)}…'
                      : report.message,
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFF333333), height: 1.5),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Column(children: [
                _dialogDetailRow('Reported as:', reportedAsLabel, bold: true),
                const SizedBox(height: 8),
                _dialogDetailRow('Report Status:',
                    isValidated ? 'Accepted' : 'Rejected',
                    valueColor: color,
                    valueIcon: isValidated
                        ? Icons.check_circle
                        : Icons.cancel_outlined),
                const SizedBox(height: 8),
                _dialogDetailRow('Action taken:', actionTaken),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Column(children: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pop(dlgCtx);
                      Navigator.of(context).popUntil((route) => route.isFirst);
                      Future.delayed(const Duration(milliseconds: 300), () {
                        final rootState = context.findAncestorStateOfType<_IOSMessagesPageState>();
                        rootState?._openConversationFromReport(report.sender, report.message);
                      });
                    },
                    icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                    label: const Text('Go to message',
                        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: color,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () {
                      Navigator.pop(dlgCtx);
                      final wasPhishing = report.originalLabel.toLowerCase() == 'phishing';
                      final movedToInbox = report.status == ReportStatus.validated && wasPhishing;
                      if (movedToInbox) {
                        Navigator.of(context).popUntil((route) => route.isFirst);
                      }
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: color,
                      side: BorderSide(color: color.withOpacity(.5)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Got it',
                        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _dialogDetailRow(String label, String value,
      {bool bold = false, Color? valueColor, IconData? valueIcon}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(label,
              style: const TextStyle(fontSize: 13, color: Color(0xFF888888))),
        ),
        Expanded(
          child: Row(children: [
            if (valueIcon != null) ...[
              Icon(valueIcon, size: 14, color: valueColor),
              const SizedBox(width: 4),
            ],
            Expanded(
              child: Text(value,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                      color: valueColor ?? Colors.black87)),
            ),
          ]),
        ),
      ],
    );
  }

  // Add this method to _SpamConversationPageState
  Future<void> _saveStatus() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_statusKey, jsonEncode(_reportStatus));
    await p.setString(_dismissedNotesKey, jsonEncode(_dismissedNotes.toList()));
  }

  Widget _buildBubble({
    required BuildContext ctx,
    required int origIdx,
    required Map<String, dynamic> msg,
    required String message,
    required String time,
    required String msgTime,
    required String? status,
    required bool displayPhishing,
    required Color labelColor,
    required String labelText,
    required bool isSearchMatch,
    required bool isReportHighlight,
    required bool isSelected,
    required bool isStarred,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: isReportHighlight ? double.infinity : null,
        decoration: isReportHighlight ? BoxDecoration(
          color: labelColor.withOpacity(.10),
        ) : null,
        padding: isReportHighlight
            ? const EdgeInsets.symmetric(vertical: 6, horizontal: 6)
            : EdgeInsets.zero,
        child: GestureDetector(
          key: _itemKeys[origIdx],
          onLongPress: _selectMode ? null : () => _showMessageOptions(ctx, origIdx),
          child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          margin: const EdgeInsets.only(bottom: 10),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(ctx).size.width * 0.82),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFFD0EAE6)
                : isReportHighlight
                ? const Color(0xFFFFEC6E)
                : (displayPhishing ? const Color(0xFFFFCDD2) : const Color(0xFFD6F0E8)),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(4),
              topRight: Radius.circular(18),
              bottomLeft: Radius.circular(18),
              bottomRight: Radius.circular(18),
            ),
            border: isSelected
                ? Border.all(color: const Color(0xFF1A7A72), width: 1.5)
                : isReportHighlight
                ? Border.all(color: const Color(0xFFFFCC00), width: 2)
                : isSearchMatch
                ? Border.all(color: const Color(0xFFFFE57F), width: 1.5)
                : null,
            boxShadow: isReportHighlight
                ? [BoxShadow(color: const Color(0xFFFFCC00).withOpacity(.3), blurRadius: 12, spreadRadius: 1)]
                : null,
          ),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _query.isNotEmpty
                ? _highlightSearchText(message, _query)
                : (displayPhishing
                ? buildPhishingHighlightedText(message)
                : Text(message, style: const TextStyle(fontSize: 14, color: Colors.black87, height: 1.5))),
            const SizedBox(height: 8),
            Text(time, style: const TextStyle(fontSize: 11, color: Color(0xFF888888))),
            const SizedBox(height: 6),
            if (status == 'pending')
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFF555555),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: const [
                  Icon(Icons.hourglass_top_rounded, size: 12, color: Colors.white),
                  SizedBox(width: 5),
                  Text('Verification in Progress',
                      style: TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600)),
                ]),
              )
            else
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(color: labelColor, borderRadius: BorderRadius.circular(20)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(displayPhishing ? Icons.warning_rounded : Icons.shield_outlined,
                        size: 13, color: Colors.white),
                    const SizedBox(width: 5),
                    Text(labelText,
                        style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
                  ]),
                ),
                if (isStarred) ...[
                  const SizedBox(width: 6),
                  const Icon(Icons.star_rounded, size: 16, color: Color(0xFFFFB300)),
                ],
              ]),
            if ((status == 'verified' || status == 'rejected') &&
                !_dismissedNotes.contains(msgTime)) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                decoration: BoxDecoration(
                  color: status == 'verified'
                      ? const Color(0xFF1A7A72).withOpacity(.08)
                      : const Color(0xFFF2554F).withOpacity(.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: status == 'verified'
                        ? const Color(0xFF1A7A72).withOpacity(.3)
                        : const Color(0xFFF2554F).withOpacity(.3),
                  ),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(
                    status == 'verified' ? Icons.verified_outlined : Icons.cancel_outlined,
                    size: 13,
                    color: status == 'verified' ? const Color(0xFF1A7A72) : const Color(0xFFF2554F),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    status == 'verified'
                        ? 'Reviewed & Verified by Developers'
                        : 'Reviewed & Rejected by Developers',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: status == 'verified' ? const Color(0xFF1A7A72) : const Color(0xFFF2554F),
                    ),
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: () {
                      final t = msgTime;
                      setState(() => _dismissedNotes.add(t));
                      _saveStatus();
                    },
                    child: const Icon(Icons.close, size: 13, color: Color(0xFFAAAAAA)),
                  ),
                ]),
              ),
            ],
          ]),
        ),
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext ctx) {
    final matches    = _matchIndices;
    final matchCount = matches.length;
    return Scaffold(
      backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: _themeColor,
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: false,
          title: Text(widget.sender, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
          actions: [
            if (!_searchActive) ...[
              IconButton(
                icon: const Icon(Icons.search),
                tooltip: 'Search',
                onPressed: () => setState(() => _searchActive = true),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete conversation',
                onPressed: () async {
                  if (await widget.onConfirmDelete()) {
                    widget.onDelete();
                    if (mounted) Navigator.pop(context);
                  }
                },
              ),
            ],
          ],
        bottom: _searchActive
            ? PreferredSize(
                preferredSize: const Size.fromHeight(58),
                child: Container(
                  color: _themeColor,
                  padding: const EdgeInsets.fromLTRB(12, 0, 8, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 42,
                          decoration: BoxDecoration(
                            color: _themeColor.withOpacity(0.7),
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: TextField(
                            controller: _searchCtrl,
                            autofocus: true,
                            style: const TextStyle(color: Colors.white, fontSize: 15),
                            decoration: const InputDecoration(
                              hintText: 'Search...',
                              hintStyle: TextStyle(color: Colors.white54, fontSize: 15),
                              prefixIcon: Icon(Icons.search, color: Colors.white54, size: 20),
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(vertical: 12),
                            ),
                            onChanged: (v) {
                              setState(() { _query = v; _currentMatchIdx = 0; });
                              Future.delayed(const Duration(milliseconds: 100), _scrollToFirst);
                            },
                          ),
                        ),
                      ),
                      if (_query.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(Icons.chevron_left, color: Colors.white, size: 22),
                          onPressed: _scrollToPrev,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                        Text(
                          '${matchCount == 0 ? 0 : _currentMatchIdx + 1}/$matchCount',
                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                        ),
                        IconButton(
                          icon: const Icon(Icons.chevron_right, color: Colors.white, size: 22),
                          onPressed: _scrollToNext,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white, size: 20),
                        onPressed: () => setState(() {
                          _searchActive = false;
                          _query = '';
                          _currentMatchIdx = 0;
                          _searchCtrl.clear();
                        }),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ),
              )
            : null,
      ),
        body: Builder(builder: (_) {
          final msgs = _localMessages.reversed.toList();
          return Stack(children: [
            Positioned.fill(
              child: _wallpaperKey.startsWith('gallery_file:')
                  ? Image.file(File(_wallpaperKey.substring('gallery_file:'.length)), fit: BoxFit.cover)
                  : kWallpaperImages.contains(_wallpaperKey)
                      ? Image.asset('assets/images/$_wallpaperKey.png', fit: BoxFit.cover)
                      : ColoredBox(color: _wallpaperColorFromKey(_wallpaperKey)),
            ),
            ListView.builder(
            controller: _scrollCtrl,
          padding: const EdgeInsets.fromLTRB(0, 16, 0, 32),
          itemCount: msgs.length,
          itemBuilder: (_, i) {
            final origIdx   = _localMessages.length - 1 - i;
            final msg       = msgs[i];
            final msgTime   = msg['time']?.toString() ?? '';
            final msgStatus = _reportStatus[msgTime];
            final message   = (msg['message'] ?? '').toString();
            final time      = widget.formatTime(msg['time'] as String?);
            final isMatch   = _query.isNotEmpty && matches.contains(origIdx);
            final labelTags = _extractLabelDetails(msg);

            final isVerifiedSafe  = msgStatus == 'verified';
            final isRejected      = msgStatus == 'rejected';
            final isPending       = msgStatus == 'pending';
            final displayPhishing = !(isVerifiedSafe);
            final labelColor      = displayPhishing ? const Color(0xFFF2554F) : const Color(0xFF2E7D5E);

            DateTime? msgDate; bool showDate = false;
            try {
              msgDate  = DateTime.parse(msg['time'] ?? '').toLocal();
              showDate = i == 0 || (() {
                final prev = DateTime.parse(msgs[i - 1]['time'] ?? '').toLocal();
                return prev.day != msgDate!.day || prev.month != msgDate.month || prev.year != msgDate.year;
              })();
            } catch (_) {}

            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (showDate && msgDate != null)
                Center(child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 14),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                  decoration: BoxDecoration(color: const Color(0xFFBBB8B0), borderRadius: BorderRadius.circular(20)),
                  child: Text(DateFormat('MMMM d').format(msgDate),
                      style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w500)),
                )),
              GestureDetector(
                key: _itemKeys[origIdx],
                onLongPress: () => _showMessageOptions(ctx, origIdx),
                child: Container(
                  margin: const EdgeInsets.only(left: 16, bottom: 10),
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(ctx).size.width * 0.82),
                  decoration: BoxDecoration(
                    color: isMatch ? const Color(0xFFFFF8E1) : (displayPhishing ? const Color(0xFFFFCDD2) : const Color(0xFFD6F0E8)),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(4), topRight: Radius.circular(18),
                      bottomLeft: Radius.circular(18), bottomRight: Radius.circular(18),
                    ),
                    border: isMatch ? Border.all(color: const Color(0xFFFFE57F), width: 1.5) : null,
                  ),
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _highlightText(message, _query),
                    const SizedBox(height: 8),
                    Text(time, style: const TextStyle(fontSize: 11, color: Color(0xFF888888))),
                    const SizedBox(height: 6),
                    if (isPending)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: const Color(0xFF555555),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: const [
                          Icon(Icons.hourglass_top_rounded, size: 12, color: Colors.white),
                          SizedBox(width: 5),
                          Text('Verification in Progress',
                              style: TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600)),
                        ]),
                      )
                    else
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                          decoration: BoxDecoration(color: labelColor, borderRadius: BorderRadius.circular(20)),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(displayPhishing ? Icons.warning_rounded : Icons.shield_outlined, size: 13, color: Colors.white),
                            const SizedBox(width: 5),
                            Text(displayPhishing ? 'Phishing Detected' : 'Safe',
                                style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
                          ]),
                        ),
                        if (displayPhishing && labelTags.isNotEmpty && !isRejected) ...[
                          const SizedBox(height: 6),
                          Wrap(spacing: 6, runSpacing: 4,
                            children: labelTags.map((tag) => Container(
                              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                              decoration: BoxDecoration(borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: const Color(0xFFF2554F).withOpacity(.55))),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Icon(tag['icon'] as IconData, size: 11, color: const Color(0xFFF2554F)),
                                const SizedBox(width: 4),
                                Text(tag['label'] as String, style: const TextStyle(fontSize: 11, color: Color(0xFFF2554F), fontWeight: FontWeight.w500)),
                              ]),
                            )).toList(),
                          ),
                        ],
                      ]),
                    if ((isVerifiedSafe || isRejected) && !_dismissedNotes.contains(msgTime)) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                        decoration: BoxDecoration(
                          color: isVerifiedSafe ? const Color(0xFF1A7A72).withOpacity(.08) : const Color(0xFFF2554F).withOpacity(.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: isVerifiedSafe ? const Color(0xFF1A7A72).withOpacity(.3) : const Color(0xFFF2554F).withOpacity(.3)),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Icon(isVerifiedSafe ? Icons.verified_outlined : Icons.cancel_outlined, size: 13,
                              color: isVerifiedSafe ? const Color(0xFF1A7A72) : const Color(0xFFF2554F)),
                          const SizedBox(width: 6),
                          Text(
                            isVerifiedSafe ? 'Reviewed & Verified by Developers' : 'Reviewed & Rejected by Developers',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                                color: isVerifiedSafe ? const Color(0xFF1A7A72) : const Color(0xFFF2554F)),
                          ),
                          const SizedBox(width: 6),
                          GestureDetector(
                            onTap: () async {
                              setState(() => _dismissedNotes.add(msgTime));
                              final p = await SharedPreferences.getInstance();
                              await p.setString(_dismissedNotesKey, jsonEncode(_dismissedNotes.toList()));
                            },
                            child: const Icon(Icons.close, size: 13, color: Color(0xFFAAAAAA)),
                          ),
                        ]),
                      ),
                    ],
                  ]),
                ),
              ),
            ]);
          },
            ),
          ]);   // closes Stack children + Stack
        }),      // closes Builder
    );           // closes Scaffold
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Firestore report helper
// ─────────────────────────────────────────────────────────────────────────────

Future<void> _submitReport({
  required String message,
  required String originalLabel,
  required double confidence,
  required String reason,
  String sender      = '',
  String type        = '',
  String source      = '',
  String deviceId    = '',
  String messageTime = '',
}) async {
  await submitReport(
    messageBody   : message,
    originalLabel : originalLabel.toLowerCase(),
    confidence    : confidence,
    reason        : reason,
    sender        : sender,
    source        : source,
    deviceId      : deviceId,
    messageId     : messageTime,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Scan Bottom Sheet
// ─────────────────────────────────────────────────────────────────────────────

class _ScanBottomSheet extends StatefulWidget {
  final void Function(Map<String, dynamic>) onResult;
  const _ScanBottomSheet({required this.onResult});
  @override
  State<_ScanBottomSheet> createState() => _ScanBottomSheetState();
}

class _ScanBottomSheetState extends State<_ScanBottomSheet> {
  final _senderCtrl  = TextEditingController();
  final _messageCtrl = TextEditingController();
  bool    _scanning = false;
  String? _error;

  Future<void> _scan() async {
    final sender = _senderCtrl.text.trim();
    final text   = _messageCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() { _scanning = true; _error = null; });

    try {
      final detection = await PhishingDetector.classify(text);
      final label = detection.label;
      final conf  = detection.confidence * 100;
      final result = <String, dynamic>{
        'sender'    : sender.isEmpty ? 'Unknown' : sender,
        'message'   : text,
        'label'     : label[0].toUpperCase() + label.substring(1),
        'confidence': double.parse(conf.toStringAsFixed(1)),
        'time'      : DateTime.now().toIso8601String(),
        'source'    : 'manual',
      };
      widget.onResult(result);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      setState(() { _error = 'Scan failed. Please try again.'; _scanning = false; });
    }
  }

  @override
  void dispose() { _senderCtrl.dispose(); _messageCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final bi = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      decoration: BoxDecoration(color: const Color(0xFFF6F4EC), borderRadius: BorderRadius.circular(24)),
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + bi),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(color: const Color(0xFFCCCCC0), borderRadius: BorderRadius.circular(2)))),
        const Text('Scan a Message', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500)),
        const SizedBox(height: 4),
        const Text("Paste an SMS to check if it's safe or phishing.", style: TextStyle(fontSize: 13, color: Color(0xFF888888))),
        const SizedBox(height: 16),
        _field(_senderCtrl, hint: 'Sender name or number (optional)', icon: Icons.person, maxLines: 1),
        const SizedBox(height: 10),
        _field(_messageCtrl, hint: 'Paste the message here...', maxLines: 5, minLines: 3),
        const SizedBox(height: 12),
        SizedBox(width: double.infinity, height: 48,
            child: ElevatedButton(
                onPressed: _scanning ? null : _scan,
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1A7A72), foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    disabledBackgroundColor: const Color(0xFF1A7A72).withOpacity(.5)),
                child: _scanning
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text('Scan', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)))),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Container(width: double.infinity, padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: const Color(0xFFFFF0F0), borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFF2554F).withOpacity(.3))),
              child: Text(_error!, style: const TextStyle(color: Color(0xFFF2554F), fontSize: 14))),
        ],
        const SizedBox(height: 8),
      ]),
    );
  }

  Widget _field(TextEditingController ctrl, {required String hint, IconData? icon, int maxLines = 1, int minLines = 1}) {
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFDDD8CE))),
      child: TextField(controller: ctrl, maxLines: maxLines, minLines: minLines,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(hintText: hint, hintStyle: const TextStyle(color: Color(0xFFAAAAAA)),
              contentPadding: icon != null ? const EdgeInsets.symmetric(horizontal: 14, vertical: 12) : const EdgeInsets.all(14),
              border: InputBorder.none,
              prefixIcon: icon != null ? Icon(icon, color: const Color(0xFFAAAAAA), size: 20) : null)),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared helpers
// ─────────────────────────────────────────────────────────────────────────────

class _OptionsSheet extends StatelessWidget {
  final List<Widget> children;
  const _OptionsSheet({required this.children});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 40, height: 4, margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(color: const Color(0xFFCCCCC0), borderRadius: BorderRadius.circular(2))),
        ...children,
        const SizedBox(height: 8),
      ]),
    );
  }
}

class _SheetAction extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final Color? labelColor;
  final VoidCallback onTap;
  const _SheetAction({
    required this.icon,
    required this.iconColor,
    required this.label,
    this.labelColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(children: [
          Container(
              width: 36, height: 36,
              decoration: BoxDecoration(color: iconColor.withOpacity(.1), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: iconColor, size: 20)),
          const SizedBox(width: 16),
          Text(label, style: TextStyle(fontSize: 15, color: labelColor ?? Colors.black87, fontWeight: FontWeight.w400)),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Phishing Indicator Model + Detector
// ─────────────────────────────────────────────────────────────────────────────

class PhishingIndicator {
  final String label;
  final String description;
  final IconData icon;
  final Color color;

  const PhishingIndicator({
    required this.label,
    required this.description,
    required this.icon,
    required this.color,
  });

  static List<PhishingIndicator> detect(String body, {int maxCount = 4}) {
    final lower = body.toLowerCase();
    final results = <PhishingIndicator>[];

    if (_hasUrl(lower)) results.add(const PhishingIndicator(label: 'Suspicious link', description: 'Contains a link that may lead to a fake or harmful website.', icon: Icons.link_rounded, color: Color(0xFFD32F2F)));
    if (_hasGamblingScam(lower)) results.add(const PhishingIndicator(label: 'Online gambling scam', description: 'Promotes illegal or fake online gambling platforms to steal money or personal info.', icon: Icons.casino_outlined, color: Color(0xFFD32F2F)));
    if (_hasThreat(lower)) results.add(const PhishingIndicator(label: 'Threats or legal warnings', description: 'Uses threats of arrest, legal action, or account suspension to pressure you.', icon: Icons.gpp_bad_outlined, color: Color(0xFFD32F2F)));
    if (_hasFear(lower)) results.add(const PhishingIndicator(label: 'Scare tactics', description: 'Warns that your account or service will be closed or blocked to frighten you.', icon: Icons.warning_amber_rounded, color: Color(0xFFD32F2F)));
    if (_requestsInfo(lower)) results.add(const PhishingIndicator(label: 'Asks for personal info', description: 'Requests sensitive details like your password, PIN, OTP, or ID number.', icon: Icons.lock_outline_rounded, color: Color(0xFFE64A19)));
    if (_hasAccountUpdate(lower)) results.add(const PhishingIndicator(label: 'Fake account alert', description: 'Claims you need to verify or update your account — a common trick to steal your details.', icon: Icons.manage_accounts_outlined, color: Color(0xFFE64A19)));
    if (_impersonatesBank(lower)) results.add(const PhishingIndicator(label: 'Bank or e-wallet impersonation', description: 'Appears to come from a bank or e-wallet like GCash, BDO, or Maya.', icon: Icons.account_balance_outlined, color: Color(0xFF7B1FA2)));
    if (_impersonatesGov(lower)) results.add(const PhishingIndicator(label: 'Government impersonation', description: 'Falsely claims to represent a government institution to gain trust or manipulate recipients.', icon: Icons.account_balance_wallet_outlined, color: Color(0xFF7B1FA2)));
    if (_impersonatesDelivery(lower)) results.add(const PhishingIndicator(label: 'Fake delivery notice', description: 'Claims a package is on hold or a delivery failed to get you to click a link.', icon: Icons.local_shipping_outlined, color: Color(0xFF7B1FA2)));
    if (_impersonatesOther(lower)) results.add(const PhishingIndicator(label: 'Impersonates a known brand', description: 'Uses the identity of a recognized company or service provider to gain trust and mislead recipients.', icon: Icons.business_outlined, color: Color(0xFF7B1FA2)));
    if (_hasUrgency(lower)) results.add(const PhishingIndicator(label: 'False urgency', description: 'Pressures you to act immediately with deadlines or time limits.', icon: Icons.timer_outlined, color: Color(0xFFF57C00)));
    if (_hasPrizeLure(lower)) results.add(const PhishingIndicator(label: 'Fake prize or reward', description: 'Claims you won a prize, cash, or free credits to trick you into giving your information.', icon: Icons.card_giftcard_outlined, color: Color(0xFFF57C00)));
    if (_hasLinkBait(lower)) results.add(const PhishingIndicator(label: 'Suspicious click request', description: 'Tells you to click a link or download something, often leading to a harmful site.', icon: Icons.touch_app_outlined, color: Color(0xFFE64A19)));
    if (_hasSimScam(lower)) results.add(const PhishingIndicator(label: 'Fake SIM registration', description: 'Falsely claims your SIM card needs to be registered or it will be deactivated.', icon: Icons.sim_card_alert_outlined, color: Color(0xFFD32F2F)));
    if (_hasMessengerRedirect(lower)) results.add(const PhishingIndicator(label: 'Redirects to FB/Messenger', description: 'Tries to move the conversation to Facebook Messenger to avoid detection.', icon: Icons.chat_bubble_outline_rounded, color: Color(0xFFF57C00)));

    return results.take(maxCount).toList();
  }

  static bool _hasUrl(String t) => RegExp(r'https?://|bit\.ly|tinyurl|t\.co|click.*link|tap.*link|link.*below').hasMatch(t);
  static bool _hasGamblingScam(String t) => RegExp(r'casino|slots|bet|jackpot|lotto|lucky spin|free spins|swerte').hasMatch(t);
  static bool _hasThreat(String t) => RegExp(r'arrest|warrant|legal action|court|suspend|terminated|blocked|deactivat').hasMatch(t);
  static bool _hasFear(String t) => RegExp(r'account.*clos|clos.*account|will be blocked|access.*revoked|service.*cut').hasMatch(t);
  static bool _requestsInfo(String t) => RegExp(r'password|otp|one.time|pin\b|passcode|id number|cvv|credit card number|enter your').hasMatch(t);
  static bool _hasAccountUpdate(String t) => RegExp(r'verify your account|update your (account|info|details)|confirm your (account|identity)|reactivate').hasMatch(t);
  static bool _impersonatesBank(String t) => RegExp(r'gcash|maya|bdo|bpi|metrobank|unionbank|landbank|pnb|security bank|ewallet|e-wallet|palawan').hasMatch(t);
  static bool _impersonatesGov(String t) => RegExp(r'sss\b|pagibig|pag-ibig|philhealth|bir\b|lto\b|nbi\b|dfa\b|dswd|comelec|psa\b').hasMatch(t);
  static bool _impersonatesDelivery(String t) => RegExp(r'parcel|package|shipment|courier|delivery|j&t|jnt|lbc|dhl|fedex|postal|tracking number').hasMatch(t);
  static bool _impersonatesOther(String t) => RegExp(r'shopee|lazada|grab|foodpanda|netflix|globe|smart|dito|pldt|meralco|maynilad').hasMatch(t);
  static bool _hasUrgency(String t) => RegExp(r'act now|limited time|expires|expiring|within \d+ (hour|minute|day)|today only|last chance|immediately|asap').hasMatch(t);
  static bool _hasPrizeLure(String t) => RegExp(r'you (won|have won|are selected)|congratulations|winner|claim (your |now)|free (gift|load|data|cash)|cash prize').hasMatch(t);
  static bool _hasLinkBait(String t) => RegExp(r'click (here|the link|below)|tap (here|the link)|open the link|visit.*link|go to.*link').hasMatch(t);
  static bool _hasSimScam(String t) => RegExp(r'sim.*regist|regist.*sim|sim.*deactivat|sim.*expir|national.*id.*sim').hasMatch(t);
  static bool _hasMessengerRedirect(String t) => RegExp(r'messenger|facebook\.com|fb\.com|message us on fb|chat us on messenger').hasMatch(t);
}