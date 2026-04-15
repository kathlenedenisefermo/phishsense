import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'profile.dart';

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
  static const _seenReportsKey = 'phishsense_seen_reports';

  List<Map<String, dynamic>> _allMessages     = [];
  List<Map<String, dynamic>> _threads         = [];
  List<Map<String, dynamic>> _filteredThreads = [];

  bool   _loading     = true;
  bool   _spamEnabled = true;
  String _searchQuery = '';
  String _deviceId    = '';
  final  _searchCtrl  = TextEditingController();
  final  _scaffoldKey = GlobalKey<ScaffoldState>();
  StreamSubscription<QuerySnapshot>? _globalReportSub;

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
    // One-time check on launch for already-reviewed reports
    await _checkReportStatuses(id!);
    // Start real-time listener so notices fire instantly while app is open
    _startGlobalReportListener(id!);
  }

  void _startGlobalReportListener(String deviceId) {
    _globalReportSub?.cancel();
    _globalReportSub = FirebaseFirestore.instance
        .collection('reports')
        .where('deviceId', isEqualTo: deviceId)
        .where('status', whereIn: ['verified', 'rejected'])
        .snapshots()
        .listen((snap) async {
      final p       = await SharedPreferences.getInstance();
      final seenRaw = p.getString(_seenReportsKey);
      final seen    = seenRaw != null
          ? (jsonDecode(seenRaw) as List).cast<String>().toSet()
          : <String>{};

      bool messagesChanged = false;
      final Set<String> newIds = {};
      for (final doc in snap.docs) {
        if (seen.contains(doc.id)) continue;
        final data          = doc.data() as Map<String, dynamic>;
        final status        = data['status']?.toString() ?? '';
        final msgTime       = data['messageTime']?.toString() ?? '';
        final originalLabel = data['originalLabel']?.toString().toLowerCase() ?? '';
        newIds.add(doc.id);
        seen.add(doc.id);
        if (msgTime.isNotEmpty) {
          await _applyReviewDecisionGlobal(msgTime, status, originalLabel);
          messagesChanged = true;
        }
      }

      await p.setString(_seenReportsKey, jsonEncode(seen.toList()));
      if (messagesChanged && mounted) await _loadMessages();

      // Show notice only for newly-seen reports
      for (final doc in snap.docs) {
        if (!newIds.contains(doc.id)) continue;
        final data          = doc.data() as Map<String, dynamic>;
        final status        = data['status']?.toString() ?? '';
        final sender        = data['sender']?.toString() ?? 'Unknown';
        final message       = data['message']?.toString() ?? '';
        final originalLabel = data['originalLabel']?.toString().toLowerCase() ?? '';
        if ((status == 'verified' || status == 'rejected') && mounted) {
          _showReportResultNotice(sender, message, status, originalLabel: originalLabel);
        }
      }
    }, onError: (e) => debugPrint('Global report listener error: $e'));
  }

  Future<void> _checkReportStatuses(String deviceId) async {
    try {
      final p        = await SharedPreferences.getInstance();
      final seenRaw  = p.getString(_seenReportsKey);
      final seen     = seenRaw != null ? (jsonDecode(seenRaw) as List).cast<String>().toSet() : <String>{};

      final snap = await FirebaseFirestore.instance
          .collection('reports')
          .where('deviceId', isEqualTo: deviceId)
          .where('status', whereIn: ['verified', 'rejected'])
          .get();

      bool anyApplied = false;
      final Set<String> newIds = {};
      for (final doc in snap.docs) {
        final data          = doc.data();
        final status        = data['status'] as String;
        final originalLabel = data['originalLabel']?.toString().toLowerCase() ?? '';
        final msgTime       = data['messageTime']?.toString() ?? '';

        if (msgTime.isNotEmpty) {
          await _applyReviewDecisionGlobal(msgTime, status, originalLabel);
          anyApplied = true;
        }

        if (!seen.contains(doc.id)) {
          newIds.add(doc.id);
          seen.add(doc.id);
        }
      }

      await p.setString(_seenReportsKey, jsonEncode(seen.toList()));
      if (anyApplied && mounted) await _loadMessages();

      // Show notice only for reports the user hasn't seen yet
      for (final doc in snap.docs) {
        if (!newIds.contains(doc.id)) continue;
        final data      = doc.data();
        final status    = data['status'] as String;
        final sender    = data['sender']?.toString() ?? 'Unknown';
        final message   = data['message']?.toString() ?? '';
        final origLabel = data['originalLabel']?.toString().toLowerCase() ?? '';
        if (mounted) _showReportResultNotice(sender, message, status, originalLabel: origLabel);
      }
    } catch (e) {
      debugPrint('Report status check failed: $e');
    }
  }

  /// Auto-applies the review decision to local SharedPreferences on app launch.
  /// This ensures messages move to the correct folder without requiring the
  /// user to open the conversation page.
  Future<void> _applyReviewDecisionGlobal(String msgTime, String status, String originalLabel) async {
    try {
      final p       = await SharedPreferences.getInstance();
      final spamRaw = p.getString(_spamKey);
      final manRaw  = p.getString(_manualKey);
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
      final bool wasPhishing  = originalLabel == 'phishing';
      final bool verified     = status == 'verified';
      final String finalLabel = verified
          ? (wasPhishing ? 'Safe' : 'Phishing')
          : (wasPhishing ? 'Phishing' : 'Safe');
      entry['label'] = finalLabel;
      final bool shouldBeInInbox = finalLabel.toLowerCase() == 'safe';

      if (wasInInbox) {
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
      } else {
        spam.removeAt(spamIdx);
        if (shouldBeInInbox) {
          await p.setString(_spamKey, jsonEncode(spam));
          if (!man.any((m) => m['time']?.toString() == msgTime)) {
            man.insert(0, entry);
            if (man.length > 200) man.removeRange(200, man.length);
            await p.setString(_manualKey, jsonEncode(man));
          }
        } else {
          spam.insert(0, entry);
          if (spam.length > 200) spam.removeRange(200, spam.length);
          await p.setString(_spamKey, jsonEncode(spam));
        }
      }
    } catch (e) { debugPrint('Auto apply review decision error: $e'); }
  }

  void _showReportResultNotice(String sender, String message, String status,
      {String originalLabel = ''}) {
    final isVerified      = status == 'verified';
    final wasPhishing     = originalLabel == 'phishing';
    // Final classification = what the message ACTUALLY IS after review
    // verified + wasPhishing  → report confirmed → message is Safe
    // verified + wasSafe      → report confirmed → message is Phishing
    // rejected + wasPhishing  → report wrong     → message stays Phishing
    // rejected + wasSafe      → report wrong     → message stays Safe
    final bool finallyPhishing = isVerified ? !wasPhishing : wasPhishing;
    final bool movedToInbox    = !finallyPhishing;
    final color   = movedToInbox ? const Color(0xFF1A7A72) : const Color(0xFFF2554F);
    final icon    = movedToInbox ? Icons.check_circle_outline : Icons.cancel_outlined;
    final title   = isVerified ? 'Report Verified' : 'Report Reviewed';
    final subtitle = movedToInbox
        ? 'The message from "$sender" is confirmed safe and has been moved to your inbox.'
        : 'The message from "$sender" is confirmed phishing. It remains in the Spam Folder.';
    final preview = message.length > 80 ? '${message.substring(0, 80)}…' : message;

    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(.2),
      builder: (_) => Material(
        color: Colors.transparent,
        child: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 28),
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(.12), blurRadius: 16, offset: const Offset(0, 4))],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, color: color, size: 40),
              const SizedBox(height: 12),
              Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: color,
                  decoration: TextDecoration.none)),
              const SizedBox(height: 8),
              Text(subtitle, textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: Color(0xFF555555), height: 1.5,
                      decoration: TextDecoration.none)),
              const SizedBox(height: 10),
              // Message preview box
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF6F4EC),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFDDD8CE))),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(sender, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                      color: Color(0xFF555555), decoration: TextDecoration.none)),
                  const SizedBox(height: 4),
                  Text(preview, style: const TextStyle(fontSize: 12, color: Color(0xFF888888),
                      height: 1.4, decoration: TextDecoration.none)),
                ])),
              const SizedBox(height: 16),
              SizedBox(width: double.infinity, height: 42,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                  style: ElevatedButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  child: const Text('OK', style: TextStyle(fontWeight: FontWeight.w600)))),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _loadSpamEnabled() async {
    final p = await SharedPreferences.getInstance();
    if (mounted) setState(() => _spamEnabled = p.getBool(_spamEnabledKey) ?? true);
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
      _showCenterNotice(v ? 'Spam Folder enabled.' : 'Spam Folder disabled.');
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
      final m = (th['latest'] as Map)['message']?.toString().toLowerCase() ?? '';
      return s.contains(_searchQuery) || m.contains(_searchQuery);
    }).toList();
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
    try {
      final json = await _channel.invokeMethod<String>('getFilteredLogs');
      if (json != null && json.isNotEmpty) ext = (jsonDecode(json) as List).cast<Map<String, dynamic>>();
    } catch (_) {}
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

  void _openScanSheet() {
    showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (_) => _ScanBottomSheet(onResult: (result) async {
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
    Navigator.push(context, MaterialPageRoute(builder: (_) => SpamFolderPage(formatTime: _formatTime, deviceId: _deviceId)))
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
      body: SafeArea(child: Column(children: [
        Container(color: const Color(0xFF1A7A72), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(children: [Image.asset('assets/images/phishsense_logo.png', height: 56, fit: BoxFit.contain)])),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 12, 8, 0),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Messages', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w500)),
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
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
          child: Container(
            decoration: BoxDecoration(color: const Color(0xFFECE9DF), borderRadius: BorderRadius.circular(14)),
            child: TextField(controller: _searchCtrl, style: const TextStyle(fontSize: 15),
              decoration: const InputDecoration(
                hintText: 'Search', hintStyle: TextStyle(color: Color(0xFF999999), fontSize: 15),
                prefixIcon: Icon(Icons.search, color: Color(0xFF999999), size: 20),
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12))),
          ),
        ),
        Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator(color: Color(0xFF1A7A72)))
            : _filteredThreads.isEmpty
                ? Center(child: Padding(padding: const EdgeInsets.all(32),
                    child: Text(
                      _searchQuery.isNotEmpty ? 'No results for "$_searchQuery".'
                          : 'No filtered messages yet.\n\nUse the Scan Message button below.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xFF888888), fontSize: 15, height: 1.6))))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(0, 4, 0, 100),
                    itemCount: _filteredThreads.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, indent: 20, endIndent: 20, color: Color(0xFFDDD8CE)),
                    itemBuilder: (ctx, i) {
                      final thread      = _filteredThreads[i];
                      final sender      = thread['sender'] as String;
                      final latest      = thread['latest'] as Map<String, dynamic>;
                      final count       = thread['count'] as int;
                      final hasPhishing = thread['hasPhishing'] as bool;
                      final time        = _formatTime(latest['time'] as String?);
                      final message     = (latest['message'] ?? '').toString();
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
                          onTap: () => Navigator.push(context, MaterialPageRoute(
                            builder: (_) => _ConversationPage(
                              messages: thread['messages'] as List<Map<String, dynamic>>,
                              sender: sender, formatTime: _formatTime, deviceId: _deviceId,
                              onDeleteThread: () async {
                                if (await _confirmDeleteThread(sender)) {
                                  await _deleteThread(sender);
                                  if (mounted) Navigator.pop(context);
                                }
                              }))),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Row(children: [
                                Text(sender, style: TextStyle(fontSize: 15, fontWeight: hasPhishing ? FontWeight.w700 : FontWeight.w400)),
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
                                  child: Text(hasPhishing ? 'Phishing' : 'Safe',
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
                                      Expanded(child: Text(message, maxLines: 2, overflow: TextOverflow.ellipsis,
                                          style: TextStyle(fontSize: 14, color: Colors.black87,
                                              fontWeight: hasPhishing ? FontWeight.w600 : FontWeight.w400))),
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
      ])),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openScanSheet, backgroundColor: const Color(0xFF1A7A72),
        icon: const Icon(Icons.search, color: Colors.white),
        label: const Text('Scan Message', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600))),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Conversation Page (Main Inbox)
// ─────────────────────────────────────────────────────────────────────────────

class _ConversationPage extends StatefulWidget {
  final List<Map<String, dynamic>> messages;
  final String sender;
  final String Function(String?) formatTime;
  final VoidCallback onDeleteThread;
  final String deviceId;
  const _ConversationPage({required this.messages, required this.sender, required this.formatTime, required this.onDeleteThread, required this.deviceId});
  @override
  State<_ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<_ConversationPage> {
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  late final List<GlobalKey> _itemKeys;
  bool   _searchActive = false;
  String _query        = '';

  // Map of message time → status: 'pending' | 'verified' | 'rejected' | null
  final Map<String, String> _reportStatus = {};
  String get _statusKey => 'report_status_${widget.sender.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';
  final Map<String, String> _correctedLabel = {};
  final Set<String> _dismissedNotes = {};
  String get _correctedLabelKey  => 'corrected_label_${widget.sender.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';
  String get _dismissedNotesKey  => 'dismissed_notes_${widget.sender.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';
  StreamSubscription<QuerySnapshot>? _firestoreSub;

  @override
  void initState() {
    super.initState();
    _itemKeys = List.generate(widget.messages.length, (_) => GlobalKey());
    _loadStatus();
    _startRealtimeListener();
  }

  @override
  void dispose() {
    _firestoreSub?.cancel();
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _startRealtimeListener() {
    if (widget.deviceId.isEmpty) return;
    _firestoreSub = FirebaseFirestore.instance
        .collection('reports')
        .where('deviceId', isEqualTo: widget.deviceId)
        .where('sender', isEqualTo: widget.sender)
        .snapshots()
        .listen((snap) async {
      bool changed = false;
      for (final doc in snap.docs) {
        final data        = doc.data() as Map<String, dynamic>;
        final msgTime     = data['messageTime']?.toString() ?? '';
        final status      = data['status']?.toString() ?? 'pending';
        final prevStatus  = _reportStatus[msgTime];
        if (msgTime.isNotEmpty && prevStatus != status) {
          _reportStatus[msgTime] = status;
          changed = true;
          final originalLabel = (data['originalLabel'] ?? '').toString().toLowerCase();
          if (status == 'verified' || status == 'rejected') {
            await _applyReviewDecision(msgTime, status, originalLabel);
          }
        }
      }
      if (changed && mounted) {
        setState(() {});
        await _saveStatus();
      }
    }, onError: (e) => debugPrint('Realtime listener error: $e'));
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
    // Also check Firestore for any status updates
    await _syncStatusFromFirestore();
  }

  Future<void> _syncStatusFromFirestore() async {
    if (widget.deviceId.isEmpty) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('reports')
          .where('deviceId', isEqualTo: widget.deviceId)
          .where('sender', isEqualTo: widget.sender)
          .get();
      bool changed = false;
      for (final doc in snap.docs) {
        final data        = doc.data();
        final msgTime     = data['messageTime']?.toString() ?? '';
        final status      = data['status']?.toString() ?? 'pending';
        final prevStatus  = _reportStatus[msgTime];
        if (msgTime.isNotEmpty && prevStatus != status) {
          _reportStatus[msgTime] = status;
          changed = true;
          // originalLabel is what the message was labeled BEFORE the report
          final originalLabel = (data['originalLabel'] ?? '').toString().toLowerCase();
          await _applyReviewDecision(msgTime, status, originalLabel);
        }
      }
      if (changed && mounted) {
        setState(() {});
        await _saveStatus();
      }
    } catch (e) { debugPrint('Firestore sync error: $e'); }
  }

  /// Applies the developer's review decision to local storage.
  ///
  /// Logic matrix:
  ///   originalLabel=phishing + verified  → label was wrong → flip to Safe  → move inbox→inbox (already there, just relabel) or spam→inbox
  ///   originalLabel=phishing + rejected  → label was right → keep Phishing → move inbox→spam (was incorrectly in inbox)
  ///   originalLabel=safe     + verified  → label was wrong → flip to Phishing → move inbox→spam
  ///   originalLabel=safe     + rejected  → label was right → keep Safe     → stays in inbox
  Future<void> _applyReviewDecision(String msgTime, String status, String originalLabel) async {
    try {
      final p           = await SharedPreferences.getInstance();
      const spamKey     = 'spam_folder_logs';
      const manualKey   = 'manual_scan_logs';

      final spamRaw = p.getString(spamKey);
      final manRaw  = p.getString(manualKey);
      final spam    = spamRaw != null && spamRaw.isNotEmpty ? (jsonDecode(spamRaw) as List).cast<Map<String, dynamic>>() : <Map<String, dynamic>>[];
      final man     = manRaw  != null && manRaw.isNotEmpty  ? (jsonDecode(manRaw)  as List).cast<Map<String, dynamic>>() : <Map<String, dynamic>>[];

      // Find the message in whichever list it currently lives in
      final inboxIdx = man.indexWhere((m) => m['time']?.toString() == msgTime);
      final spamIdx  = spam.indexWhere((m) => m['time']?.toString() == msgTime);

      Map<String, dynamic>? entry;
      bool wasInInbox = false;
      if (inboxIdx != -1) { entry = Map<String, dynamic>.from(man[inboxIdx]);  wasInInbox = true; }
      else if (spamIdx != -1) { entry = Map<String, dynamic>.from(spam[spamIdx]); wasInInbox = false; }
      if (entry == null) return;

      entry['verifiedByCrew'] = true;

      // Determine the final correct label
      final bool wasPhishing = originalLabel == 'phishing';
      final bool verified    = status == 'verified';

      // verified = report was correct, so original label was WRONG → flip it
      // rejected = report was wrong, so original label was RIGHT → keep it
      final String finalLabel = verified
          ? (wasPhishing ? 'Safe' : 'Phishing')  // flip
          : (wasPhishing ? 'Phishing' : 'Safe');  // keep original

      entry['label'] = finalLabel;
      // Store corrected label in memory so the bubble reads the right label
      // even though widget.messages is stale (passed in from parent, not refreshed)
      _correctedLabel[msgTime] = finalLabel;
      final bool shouldBeInInbox = finalLabel.toLowerCase() == 'safe';

      if (wasInInbox) {
        man.removeAt(inboxIdx);
        if (shouldBeInInbox) {
          // Stay in inbox with corrected label
          man.insert(0, entry);
          if (man.length > 200) man.removeRange(200, man.length);
          await p.setString(manualKey, jsonEncode(man));
        } else {
          // Move inbox → spam
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
          // Move spam → inbox
          await p.setString(spamKey, jsonEncode(spam));
          if (!man.any((m) => m['time']?.toString() == msgTime)) {
            man.insert(0, entry);
            if (man.length > 200) man.removeRange(200, man.length);
            await p.setString(manualKey, jsonEncode(man));
          }
        } else {
          // Stay in spam with corrected label
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
    final time = widget.messages[i]['time']?.toString() ?? '';
    return _reportStatus[time];
  }

  /// Returns the corrected label for a message if it has been reviewed,
  /// otherwise returns the original label from widget.messages.
  String _labelFor(int i) {
    final time = widget.messages[i]['time']?.toString() ?? '';
    return _correctedLabel[time] ?? (widget.messages[i]['label'] ?? '').toString();
  }

  List<int> get _matchIndices {
    if (_query.isEmpty) return [];
    return List.generate(widget.messages.length, (i) => i)
        .where((i) => (widget.messages[i]['message'] ?? '').toString().toLowerCase().contains(_query.toLowerCase()))
        .toList();
  }

  void _scrollToFirst() {
    final matches = _matchIndices;
    if (matches.isEmpty) return;
    final ctx = _itemKeys[matches.first].currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
  }

  Widget _highlightText(String text, String query) {
    if (query.isEmpty) return Text(text, style: const TextStyle(fontSize: 14, color: Colors.black87, height: 1.5));
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

  void _showVerificationDialog(BuildContext ctx) {
    showDialog(context: ctx, builder: (_) => Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(color: const Color(0xFFF6F4EC), borderRadius: BorderRadius.circular(24)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 64, height: 64,
              decoration: BoxDecoration(color: const Color(0xFF1A7A72).withOpacity(.12), shape: BoxShape.circle),
              child: const Icon(Icons.hourglass_top_rounded, color: Color(0xFF1A7A72), size: 36)),
          const SizedBox(height: 16),
          const Text('Verification in Progress',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          const Text(
            'Your report has been submitted. This message will remain in the Spam Folder while our team reviews the detection.\n\nOnce verified, the label will be updated and the message will be moved to your inbox if the detection is confirmed as inaccurate.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Color(0xFF555555), height: 1.55)),
          const SizedBox(height: 20),
          SizedBox(width: double.infinity, height: 46,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1A7A72), foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              child: const Text('Got it', style: TextStyle(fontWeight: FontWeight.w600)))),
        ]),
      ),
    ));
  }

  void _showReportSheet(BuildContext ctx, int index) {
    final msg        = widget.messages[index];
    // Use _labelFor so we always report against the current effective label,
    // not the stale widget data (e.g. after a previous review corrected it).
    final isPhishing = _labelFor(index).toLowerCase() == 'phishing';
    final title      = isPhishing ? 'Report Inaccurate Detection' : 'Report as Phishing';
    final subtitle   = isPhishing ? 'Why do you think this detection is wrong?' : 'Why do you think this message is phishing?';
    final reasons    = isPhishing
        ? ['This is from a trusted sender', 'This is a legitimate promotional message',
           'This is a known service or OTP message', 'The link in this message is safe', 'Other reason']
        : ['Message seems suspicious', 'Requests personal information',
           'Contains suspicious links', 'Impersonating a known brand', 'Other reason'];
    final otherCtrl  = TextEditingController();
    showDialog(context: ctx, builder: (dlgCtx) {
      String? selected;
      return StatefulBuilder(builder: (dlgCtx, set) => AlertDialog(
        backgroundColor: const Color(0xFFF6F4EC),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
        contentPadding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
        actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(subtitle, style: const TextStyle(fontSize: 13, color: Color(0xFF666666), fontWeight: FontWeight.w400)),
        ]),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          ...reasons.map((r) => RadioListTile<String>(
            value: r, groupValue: selected, activeColor: const Color(0xFF1A7A72),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            title: Text(r, style: const TextStyle(fontSize: 14)),
            onChanged: (v) => set(() => selected = v))),
          if (selected == 'Other reason')
            Padding(padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: TextField(controller: otherCtrl, maxLines: 3,
                decoration: InputDecoration(
                  hintText: 'Describe your reason…', hintStyle: const TextStyle(color: Color(0xFFAAAAAA), fontSize: 13),
                  filled: true, fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFDDD8CE))),
                  contentPadding: const EdgeInsets.all(12)))),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dlgCtx), child: const Text('Cancel', style: TextStyle(color: Color(0xFF888888)))),
          ElevatedButton(
            onPressed: selected == null ? null : () {
              final msgTime = msg['time']?.toString() ?? '';
              Navigator.pop(dlgCtx);
              setState(() => _reportStatus[msgTime] = 'pending');
              _saveStatus();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _showVerificationDialog(ctx);
              });
              _submitReport(
                sender       : msg['sender']?.toString() ?? 'Unknown',
                message      : msg['message']?.toString() ?? '',
                originalLabel: _labelFor(index),
                reason       : selected == 'Other reason' ? otherCtrl.text.trim() : selected!,
                type         : isPhishing ? 'inaccurate_detection' : 'reported_as_phishing',
                deviceId     : widget.deviceId,
                messageTime  : msgTime,
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1A7A72), foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFF1A7A72).withOpacity(.4),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            child: const Text('Submit')),
        ],
      ));
    });
  }

  @override
  Widget build(BuildContext ctx) {
    final matches    = _matchIndices;
    final matchCount = matches.length;
    return Scaffold(
      backgroundColor: const Color(0xFFF6F4EC),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A7A72), foregroundColor: Colors.white, elevation: 0, centerTitle: false,
        title: _searchActive
            ? TextField(
                controller: _searchCtrl, autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                decoration: InputDecoration(
                  hintText: 'Search in conversation…', hintStyle: const TextStyle(color: Colors.white70),
                  border: InputBorder.none,
                  suffixText: _query.isNotEmpty ? '$matchCount found' : null,
                  suffixStyle: const TextStyle(color: Colors.white70, fontSize: 13)),
                onChanged: (v) { setState(() => _query = v); Future.delayed(const Duration(milliseconds: 100), _scrollToFirst); })
            : Text(widget.sender, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
        actions: [
          if (_searchActive)
            IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() { _searchActive = false; _query = ''; _searchCtrl.clear(); }))
          else ...[
            IconButton(icon: const Icon(Icons.search), onPressed: () => setState(() => _searchActive = true)),
            IconButton(icon: const Icon(Icons.delete_outline), onPressed: widget.onDeleteThread),
          ],
        ],
      ),
      body: ListView.builder(
        controller: _scrollCtrl,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        itemCount: widget.messages.length,
        itemBuilder: (_, i) {
          final msg             = widget.messages[i];
          final status          = _statusFor(i); // null | 'pending' | 'verified' | 'rejected'
          // Use _labelFor so we always get the corrected label after review,
          // since widget.messages is stale (the parent passed it in and never refreshes it).
          final effectiveLabel     = _labelFor(i).toLowerCase();
          final originalMsgLabel   = (msg['label'] ?? '').toString().toLowerCase();
          final originallyPhishing = originalMsgLabel == 'phishing';
          // The label to display is the effective (possibly corrected) one
          final displayPhishing = effectiveLabel == 'phishing';
          final message         = (msg['message'] ?? '').toString();
          final time            = widget.formatTime(msg['time'] as String?);
          final labelColor      = displayPhishing ? const Color(0xFFF2554F) : const Color(0xFF06C85E);
          final labelText       = displayPhishing ? 'Phishing' : 'Safe';
          final oldLabelText    = originallyPhishing ? 'Phishing' : 'Safe';
          final newLabelText    = labelText;

          return Container(
            key: _itemKeys[i],
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(color: const Color(0xFFF3EEE4), borderRadius: BorderRadius.circular(14)),
            clipBehavior: Clip.hardEdge,
            child: IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(width: 5, color: labelColor),
              Expanded(child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 14, 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _highlightText(message, _query),
                  const SizedBox(height: 10),

                  // ── Status row ──────────────────────────────────────────
                  if (status == 'pending') ...[
                    // Pending: show hourglass, block re-reporting
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A7A72).withOpacity(.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF1A7A72).withOpacity(.25))),
                        child: Row(mainAxisSize: MainAxisSize.min, children: const [
                          Icon(Icons.hourglass_top_rounded, size: 14, color: Color(0xFF1A7A72)),
                          SizedBox(width: 6),
                          Text('Verification in Progress',
                              style: TextStyle(fontSize: 12, color: Color(0xFF1A7A72), fontWeight: FontWeight.w600)),
                        ]))),
                    const SizedBox(height: 4),
                    Align(alignment: Alignment.centerRight,
                        child: Text(time, style: const TextStyle(fontSize: 11, color: Color(0xFF777777)))),

                  ] else if (status == 'verified' || status == 'rejected') ...[
                    // Reviewed: label + time row
                    Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: labelColor, borderRadius: BorderRadius.circular(20)),
                        child: Text(labelText,
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600))),
                      const Spacer(),
                      Text(time, style: const TextStyle(fontSize: 11, color: Color(0xFF777777))),
                    ]),
                    const SizedBox(height: 6),
                    // Developer-reviewed banner (dismissible)
                    if (!_dismissedNotes.contains(msg['time']?.toString() ?? '')) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                        decoration: BoxDecoration(
                          color: status == 'verified'
                              ? const Color(0xFF1A7A72).withOpacity(.08)
                              : const Color(0xFFF2554F).withOpacity(.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: status == 'verified'
                                ? const Color(0xFF1A7A72).withOpacity(.30)
                                : const Color(0xFFF2554F).withOpacity(.30))),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Icon(
                            status == 'verified' ? Icons.verified_outlined : Icons.cancel_outlined,
                            size: 14,
                            color: status == 'verified' ? const Color(0xFF1A7A72) : const Color(0xFFF2554F)),
                          const SizedBox(width: 7),
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(
                              status == 'verified' ? 'Reviewed & Verified by Developers' : 'Reviewed & Rejected by Developers',
                              style: TextStyle(
                                fontSize: 11, fontWeight: FontWeight.w700,
                                color: status == 'verified' ? const Color(0xFF1A7A72) : const Color(0xFFF2554F))),
                            const SizedBox(height: 2),
                            Text(
                              status == 'verified'
                                  ? 'Our team confirmed your report was accurate. This message has been reclassified from $oldLabelText to $newLabelText.'
                                  : 'Our team reviewed your report and confirmed this message is $oldLabelText. The original classification was correct.',
                              style: const TextStyle(fontSize: 11, color: Color(0xFF666666), height: 1.4)),
                          ])),
                          GestureDetector(
                            onTap: () {
                              final t = msg['time']?.toString() ?? '';
                              setState(() => _dismissedNotes.add(t));
                              _saveStatus();
                            },
                            child: const Padding(
                              padding: EdgeInsets.only(left: 4),
                              child: Icon(Icons.close, size: 14, color: Color(0xFFAAAAAA)))),
                        ])),
                      const SizedBox(height: 6),
                    ],
                    // Re-enable report button after review
                    GestureDetector(
                      onTap: () => _showReportSheet(ctx, i),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.flag_outlined, size: 13, color: Color(0xFFAAAAAA)),
                        const SizedBox(width: 4),
                        Text(displayPhishing ? 'Report Inaccurate Detection' : 'Report as Phishing',
                            style: const TextStyle(fontSize: 12, color: Color(0xFFAAAAAA))),
                      ])),

                  ] else ...[
                    // No report yet: show label + report button
                    Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: labelColor, borderRadius: BorderRadius.circular(20)),
                        child: Text(labelText,
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600))),
                      const SizedBox(width: 8),
                      Expanded(child: GestureDetector(
                        onTap: () => _showReportSheet(ctx, i),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.flag_outlined, size: 13, color: Color(0xFFAAAAAA)),
                          const SizedBox(width: 4),
                          Flexible(child: Text(originallyPhishing ? 'Report Inaccurate Detection' : 'Report as Phishing',
                              style: const TextStyle(fontSize: 12, color: Color(0xFFAAAAAA)), overflow: TextOverflow.ellipsis)),
                        ]))),
                      Text(time, style: const TextStyle(fontSize: 11, color: Color(0xFF777777))),
                    ]),
                  ],
                ]),
              )),
            ])),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Spam Folder Page
// ─────────────────────────────────────────────────────────────────────────────

class SpamFolderPage extends StatefulWidget {
  final String Function(String?) formatTime;
  final String deviceId;
  const SpamFolderPage({super.key, required this.formatTime, required this.deviceId});
  @override
  State<SpamFolderPage> createState() => _SpamFolderPageState();
}

class _SpamFolderPageState extends State<SpamFolderPage> {
  static const _spamKey         = 'spam_folder_logs';
  static const _autoDeletionKey = 'spam_auto_deletion_days';
  static const _manualKey       = 'manual_scan_logs';
  List<Map<String, dynamic>> _spamMessages = [];
  List<Map<String, dynamic>> _threads      = [];
  bool _loading = true;
  int? _autoDeletionDays;
  static const _deletionOptions = [(label: 'Never', days: -1), (label: '7 days', days: 7), (label: '14 days', days: 14), (label: '30 days', days: 30)];
  StreamSubscription<QuerySnapshot>? _reviewSub;

  @override
  void initState() {
    super.initState();
    _loadPref();
    _loadSpam();
    _startReviewListener();
  }

  @override
  void dispose() {
    _reviewSub?.cancel();
    super.dispose();
  }

  /// Listens for any report on this device transitioning to verified/rejected.
  /// When one does, apply the decision to local storage first, then reload so
  /// the UI reflects the move-to-inbox immediately without a race condition.
  void _startReviewListener() {
    if (widget.deviceId.isEmpty) return;
    _reviewSub = FirebaseFirestore.instance
        .collection('reports')
        .where('deviceId', isEqualTo: widget.deviceId)
        .where('status', whereIn: ['verified', 'rejected'])
        .snapshots()
        .listen((snap) async {
      bool anyMoved = false;
      for (final doc in snap.docs) {
        final data          = doc.data() as Map<String, dynamic>;
        final msgTime       = data['messageTime']?.toString() ?? '';
        final status        = data['status']?.toString() ?? '';
        final originalLabel = data['originalLabel']?.toString().toLowerCase() ?? '';
        if (msgTime.isNotEmpty) {
          final movedToInbox = await _applyReviewDecision(msgTime, status, originalLabel);
          if (movedToInbox) anyMoved = true;
        }
      }
      if (mounted) {
        await _loadSpam();
        // Show snackbar on the spam list after reload — message is already gone from list
        if (anyMoved) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Row(children: [
              Icon(Icons.check_circle_outline, color: Colors.white, size: 18),
              SizedBox(width: 10),
              Expanded(child: Text('Message confirmed safe and moved to Inbox',
                  style: TextStyle(fontWeight: FontWeight.w600))),
            ]),
            backgroundColor: const Color(0xFF1A7A72),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ));
        }
      }
    }, onError: (e) => debugPrint('SpamFolder review listener error: $e'));
  }

  /// Mirrors the logic of IOSMessagesPage._applyReviewDecisionGlobal so that
  /// SpamFolderPage can update SharedPreferences without depending on the
  /// parent page's listener running first.
  /// Returns true if the message was moved out of spam to inbox.
  Future<bool> _applyReviewDecision(String msgTime, String status, String originalLabel) async {
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
      if (spamIdx != -1)  { entry = Map<String, dynamic>.from(spam[spamIdx]);  wasInSpam = true; }
      else if (inboxIdx != -1) { entry = Map<String, dynamic>.from(man[inboxIdx]); wasInSpam = false; }
      if (entry == null) return false;
      if (entry['verifiedByCrew'] == true) return false;

      entry['verifiedByCrew'] = true;
      final bool wasPhishing = originalLabel == 'phishing';
      final bool verified    = status == 'verified';
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
          return true; // moved from spam to inbox
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
    } catch (e) { debugPrint('SpamFolder apply review decision error: $e'); return false; }
  }

  Future<void> _loadPref() async {
    final p = await SharedPreferences.getInstance();
    if (mounted) setState(() => _autoDeletionDays = p.getInt(_autoDeletionKey));
  }

  Future<void> _savePref(int? days) async {
    final p = await SharedPreferences.getInstance();
    if (days == null) await p.remove(_autoDeletionKey); else await p.setInt(_autoDeletionKey, days);
    setState(() => _autoDeletionDays = days);
  }

  List<Map<String, dynamic>> _applyAutoDeletion(List<Map<String, dynamic>> l) {
    if (_autoDeletionDays == null) return l;
    final cutoff = DateTime.now().subtract(Duration(days: _autoDeletionDays!));
    return l.where((e) { final t = DateTime.tryParse(e['time'] ?? ''); return t != null && t.isAfter(cutoff); }).toList();
  }

  Future<void> _loadSpam() async {
    final p   = await SharedPreferences.getInstance();
    final raw = p.getString(_spamKey);
    var msgs  = raw != null && raw.isNotEmpty ? (jsonDecode(raw) as List).cast<Map<String, dynamic>>() : <Map<String, dynamic>>[];
    msgs = _applyAutoDeletion(msgs);
    if (mounted) setState(() { _spamMessages = msgs; _threads = _buildThreads(msgs); _loading = false; });
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
      return {'sender': e.key, 'messages': sorted, 'latest': sorted.first, 'count': sorted.length};
    }).toList()
      ..sort((a, b) {
        final ta = DateTime.tryParse((a['latest'] as Map)['time'] ?? '') ?? DateTime(0);
        final tb = DateTime.tryParse((b['latest'] as Map)['time'] ?? '') ?? DateTime(0);
        return tb.compareTo(ta);
      });
  }

  String get _autoDeletionLabel => _autoDeletionDays == null ? 'Never' : '$_autoDeletionDays days';

  Future<void> _restoreToInbox(String sender) async {
    final toRestore = _spamMessages.where((m) => (m['sender'] ?? '') == sender).toList();
    final updated   = _spamMessages.where((m) => (m['sender'] ?? '') != sender).toList();
    await _persistSpam(updated);
    final p   = await SharedPreferences.getInstance();
    final raw = p.getString(_manualKey);
    final man = raw != null && raw.isNotEmpty ? (jsonDecode(raw) as List).cast<Map<String, dynamic>>() : <Map<String, dynamic>>[];
    man.insertAll(0, toRestore);
    if (man.length > 200) man.removeRange(200, man.length);
    await p.setString(_manualKey, jsonEncode(man));
    setState(() { _spamMessages = updated; _threads = _buildThreads(updated); });
  }

  Future<void> _deleteFromSpam(String sender) async {
    final updated = _spamMessages.where((m) => (m['sender'] ?? '') != sender).toList();
    await _persistSpam(updated);
    setState(() { _spamMessages = updated; _threads = _buildThreads(updated); });
  }

  Future<bool> _confirmDelete(String sender) async {
    bool confirmed = false;
    await showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFFF6F4EC),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: const Text('Delete', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
      content: Text('Delete all messages from "$sender"?', style: const TextStyle(fontSize: 14, color: Color(0xFF555555))),
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      actions: [
        TextButton(onPressed: () { confirmed = false; Navigator.pop(ctx); }, child: const Text('Cancel', style: TextStyle(color: Color(0xFF1A7A72)))),
        ElevatedButton(onPressed: () { confirmed = true; Navigator.pop(ctx); },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF2554F), foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            child: const Text('Delete')),
      ],
    ));
    return confirmed;
  }

  Future<void> _deleteAll() async {
    bool confirmed = false;
    await showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFFF6F4EC),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: const Text('Delete All', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
      content: Text('Permanently delete all ${_spamMessages.length} phishing messages?', style: const TextStyle(fontSize: 14, color: Color(0xFF555555))),
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      actions: [
        TextButton(onPressed: () { confirmed = false; Navigator.pop(ctx); }, child: const Text('Cancel', style: TextStyle(color: Color(0xFF1A7A72)))),
        ElevatedButton(onPressed: () { confirmed = true; Navigator.pop(ctx); },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF2554F), foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            child: const Text('Delete All')),
      ],
    ));
    if (confirmed) { await _persistSpam([]); setState(() { _spamMessages = []; _threads = []; }); }
  }

  void _showSpamOptions(BuildContext ctx, String sender) {
    showModalBottomSheet(context: ctx, backgroundColor: Colors.transparent,
      builder: (_) => _OptionsSheet(children: [
        _SheetAction(icon: Icons.move_to_inbox_outlined, iconColor: const Color(0xFF1A7A72),
            label: 'Move to Inbox', onTap: () async { Navigator.pop(ctx); await _restoreToInbox(sender); }),
        _SheetAction(icon: Icons.flag_outlined, iconColor: const Color(0xFFE0A800),
            label: 'Report Inaccurate Detection', onTap: () { Navigator.pop(ctx); _showReportSheet(ctx, sender); }),
        _SheetAction(icon: Icons.delete_outline, iconColor: const Color(0xFFF2554F),
            label: 'Delete', labelColor: const Color(0xFFF2554F),
            onTap: () async { Navigator.pop(ctx); if (await _confirmDelete(sender)) await _deleteFromSpam(sender); }),
      ]));
  }

  // onReported is called ONLY when Submit is tapped — not when the sheet opens
  void _showReportSheet(BuildContext ctx, String sender, [VoidCallback? onReported]) {
    const reasons = ['This is from a trusted sender', 'This is a legitimate promotional message',
      'This is a known service or OTP message', 'The link in this message is safe', 'Other reason'];
    final otherCtrl = TextEditingController();
    showDialog(context: ctx, builder: (dlgCtx) {
      String? selected;
      return StatefulBuilder(builder: (dlgCtx, set) => AlertDialog(
        backgroundColor: const Color(0xFFF6F4EC),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
        contentPadding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
        actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        title: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Report Inaccurate Detection', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          SizedBox(height: 6),
          Text('Why do you think this detection is wrong?', style: TextStyle(fontSize: 13, color: Color(0xFF666666), fontWeight: FontWeight.w400)),
        ]),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          ...reasons.map((r) => RadioListTile<String>(
            value: r, groupValue: selected, activeColor: const Color(0xFF1A7A72),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            title: Text(r, style: const TextStyle(fontSize: 14)),
            onChanged: (v) => set(() => selected = v))),
          if (selected == 'Other reason')
            Padding(padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: TextField(controller: otherCtrl, maxLines: 3,
                decoration: InputDecoration(
                  hintText: 'Describe your reason…', hintStyle: const TextStyle(color: Color(0xFFAAAAAA), fontSize: 13),
                  filled: true, fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFDDD8CE))),
                  contentPadding: const EdgeInsets.all(12)))),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dlgCtx), child: const Text('Cancel', style: TextStyle(color: Color(0xFF888888)))),
          ElevatedButton(
            onPressed: selected == null ? null : () {
              Navigator.pop(dlgCtx);
              onReported?.call();
              _showVerificationDialog(ctx);
              final msgs   = _spamMessages.where((m) => (m['sender'] ?? '') == sender).toList();
              final sample = msgs.isNotEmpty ? msgs.first : <String, dynamic>{};
              _submitReport(
                sender       : sender,
                message      : sample['message']?.toString() ?? '',
                originalLabel: 'Phishing',
                reason       : selected == 'Other reason' ? otherCtrl.text.trim() : selected!,
                type         : 'inaccurate_detection',
                deviceId     : widget.deviceId,
                messageTime  : sample['time']?.toString() ?? '',
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1A7A72), foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFF1A7A72).withOpacity(.4),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            child: const Text('Submit')),
        ],
      ));
    });
  }

  void _showVerificationDialog(BuildContext ctx) {
    showDialog(context: ctx, builder: (_) => Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(color: const Color(0xFFF6F4EC), borderRadius: BorderRadius.circular(24)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 64, height: 64,
              decoration: BoxDecoration(color: const Color(0xFF1A7A72).withOpacity(.12), shape: BoxShape.circle),
              child: const Icon(Icons.hourglass_top_rounded, color: Color(0xFF1A7A72), size: 36)),
          const SizedBox(height: 16),
          const Text('Verification in Progress', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          const Text(
            'Your report has been submitted. This message will remain in the Spam Folder while our team reviews the detection.\n\nOnce verified, the label will be updated and the message will be moved to your inbox if the detection is confirmed as inaccurate.',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Color(0xFF555555), height: 1.55)),
          const SizedBox(height: 20),
          SizedBox(width: double.infinity, height: 46,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1A7A72), foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              child: const Text('Got it', style: TextStyle(fontWeight: FontWeight.w600)))),
        ]),
      ),
    ));
  }

  void _showDeletionDropdown(BuildContext btnCtx) {
    final box     = btnCtx.findRenderObject() as RenderBox;
    final overlay = Navigator.of(btnCtx).overlay!.context.findRenderObject() as RenderBox;
    final pos = RelativeRect.fromRect(
      Rect.fromPoints(box.localToGlobal(Offset.zero, ancestor: overlay),
          box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay)),
      Offset.zero & overlay.size);
    showMenu<int>(context: btnCtx, position: pos, color: const Color(0xFF1A7A72),
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

  @override
  Widget build(BuildContext context) {
    final phishingCount = _spamMessages.length;
    final senderCount   = _threads.length;
    return Scaffold(
      backgroundColor: const Color(0xFFF6F4EC),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A7A72), foregroundColor: Colors.white, elevation: 0, centerTitle: false,
        title: const Text('Spam Folder', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
        actions: [
          if (!_loading && _spamMessages.isNotEmpty)
            IconButton(tooltip: 'Delete all', icon: const Icon(Icons.delete_sweep_outlined), onPressed: _deleteAll),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF1A7A72)))
          : Column(children: [
              if (_spamMessages.isNotEmpty) Container(
                width: double.infinity, color: const Color(0xFFF6F4EC),
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(color: const Color(0xFFF2554F).withOpacity(.12), borderRadius: BorderRadius.circular(20)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.warning_rounded, size: 13, color: Color(0xFFF2554F)),
                        const SizedBox(width: 5),
                        Text('$phishingCount phishing message${phishingCount != 1 ? 's' : ''}',
                            style: const TextStyle(fontSize: 12, color: Color(0xFFF2554F), fontWeight: FontWeight.w600)),
                      ])),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(color: const Color(0xFF1A7A72).withOpacity(.10), borderRadius: BorderRadius.circular(20)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.person, size: 13, color: Color(0xFF1A7A72)),
                        const SizedBox(width: 5),
                        Text('$senderCount sender${senderCount != 1 ? 's' : ''}',
                            style: const TextStyle(fontSize: 12, color: Color(0xFF1A7A72), fontWeight: FontWeight.w600)),
                      ])),
                  ]),
                  const SizedBox(height: 8),
                ])),
              if (_spamMessages.isNotEmpty) const Divider(height: 1, color: Color(0xFFDDD8CE)),
              Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(children: [
                  const Icon(Icons.timer_outlined, size: 16, color: Color(0xFF1A7A72)),
                  const SizedBox(width: 8),
                  const Text('Auto-delete spam after', style: TextStyle(fontSize: 14, color: Colors.black87)),
                  const Spacer(),
                  Builder(builder: (btnCtx) => GestureDetector(
                    onTap: () => _showDeletionDropdown(btnCtx),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(color: const Color(0xFF1A7A72), borderRadius: BorderRadius.circular(8)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(_autoDeletionLabel, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                        const SizedBox(width: 4),
                        const Icon(Icons.arrow_drop_down, color: Colors.white, size: 18),
                      ])))),
                ])),
              const Divider(height: 1, color: Color(0xFFDDD8CE)),
              Expanded(child: _threads.isEmpty
                  ? const Center(child: Padding(padding: EdgeInsets.all(32),
                      child: Text('No spam messages yet.\n\nPhishing messages will appear here.',
                          textAlign: TextAlign.center, style: TextStyle(color: Color(0xFF888888), fontSize: 15, height: 1.6))))
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 32),
                      itemCount: _threads.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFFEEEBE0)),
                      itemBuilder: (ctx, i) {
                        final thread = _threads[i];
                        final sender = thread['sender'] as String;
                        final latest = thread['latest'] as Map<String, dynamic>;
                        final count  = thread['count'] as int;
                        final time   = widget.formatTime(latest['time'] as String?);
                        return GestureDetector(
                          onLongPress: () => _showSpamOptions(ctx, sender),
                          child: InkWell(
                            onTap: () => Navigator.push(context, MaterialPageRoute(
                              builder: (_) => _SpamConversationPage(
                                messages: thread['messages'] as List<Map<String, dynamic>>,
                                sender: sender, formatTime: widget.formatTime,
                                onRestore: () => _restoreToInbox(sender),
                                onDelete: () => _deleteFromSpam(sender),
                                onConfirmDelete: () => _confirmDelete(sender),
                                onReport: (onReported) => _showReportSheet(ctx, sender, onReported),
                                deviceId: widget.deviceId,
                              ))).then((_) => _loadSpam()),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Container(width: 46, height: 46,
                                    decoration: BoxDecoration(color: const Color(0xFFE8E4DA), borderRadius: BorderRadius.circular(23)),
                                    child: const Icon(Icons.person, color: Color(0xFF999999), size: 26)),
                                const SizedBox(width: 12),
                                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Row(children: [
                                    Expanded(child: Text(sender,
                                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
                                    if (count > 0) Container(
                                      margin: const EdgeInsets.only(left: 6, right: 6),
                                      width: 20, height: 20,
                                      decoration: const BoxDecoration(color: Color(0xFFF2554F), shape: BoxShape.circle),
                                      child: Center(child: Text(count > 9 ? '9+' : '$count',
                                          style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)))),
                                    Text(time, style: const TextStyle(fontSize: 12, color: Color(0xFF999999))),
                                  ]),
                                  const SizedBox(height: 3),
                                  Text((latest['message'] ?? '').toString(), maxLines: 2, overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 13, color: Color(0xFF666666), height: 1.4)),
                                ])),
                              ]),
                            ),
                          ),
                        );
                      })),
            ]),
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
  final void Function(VoidCallback onReported) onReport;
  final String deviceId;
  const _SpamConversationPage({
    required this.messages, required this.sender, required this.formatTime,
    required this.onRestore, required this.onDelete, required this.onConfirmDelete,
    required this.onReport, required this.deviceId});
  @override
  State<_SpamConversationPage> createState() => _SpamConversationPageState();
}

class _SpamConversationPageState extends State<_SpamConversationPage> {
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  late final List<GlobalKey> _itemKeys;
  bool   _searchActive    = false;
  String _query           = '';
  // Per-message report status keyed by message time
  final Map<String, String> _reportStatus = {};
  final Set<String> _dismissedNotes = {};
  String get _statusKey         => 'spam_report_status_${widget.sender.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';
  String get _dismissedNotesKey => 'spam_dismissed_notes_${widget.sender.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';
  StreamSubscription<QuerySnapshot>? _firestoreSub;

  @override
  void initState() {
    super.initState();
    _itemKeys = List.generate(widget.messages.length, (_) => GlobalKey());
    _loadAndSyncStatus();
    _startRealtimeListener();
  }

  @override
  void dispose() {
    _firestoreSub?.cancel();
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _startRealtimeListener() {
    if (widget.deviceId.isEmpty) return;
    final messageTimes = widget.messages
        .map((m) => m['time']?.toString() ?? '')
        .where((t) => t.isNotEmpty)
        .toList();
    if (messageTimes.isEmpty) return;
    _firestoreSub = FirebaseFirestore.instance
        .collection('reports')
        .where('deviceId', isEqualTo: widget.deviceId)
        .where('messageTime', whereIn: messageTimes)
        .snapshots()
        .listen((snap) async {
      bool changed = false;
      for (final doc in snap.docs) {
        final data          = doc.data() as Map<String, dynamic>;
        final msgTime       = data['messageTime']?.toString() ?? '';
        final status        = data['status']?.toString() ?? 'pending';
        final prevStatus    = _reportStatus[msgTime];
        if (msgTime.isNotEmpty && prevStatus != status) {
          _reportStatus[msgTime] = status;
          changed = true;
          final originalLabel = (data['originalLabel'] ?? '').toString().toLowerCase();
          final sender        = data['sender']?.toString() ?? 'Unknown';
          final message       = data['message']?.toString() ?? '';
          if (status == 'verified' || status == 'rejected') {
            final movedOut = await _applyReviewDecision(msgTime, status, originalLabel);
            if (mounted) {
              _showLocalReportResultNotice(sender, message, status,
                  originalLabel: originalLabel, popToInbox: movedOut);
            }
          }
        }
      }
      if (!mounted) return;
      if (changed) {
        setState(() {});
        final p = await SharedPreferences.getInstance();
        await p.setString(_statusKey, jsonEncode(_reportStatus));
      }
    }, onError: (e) => debugPrint('Spam realtime listener error: $e'));
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
    if (widget.deviceId.isEmpty) return;
    try {
      final messageTimes = widget.messages
          .map((m) => m['time']?.toString() ?? '')
          .where((t) => t.isNotEmpty)
          .toList();
      if (messageTimes.isEmpty) return;
      final snap = await FirebaseFirestore.instance
          .collection('reports')
          .where('deviceId', isEqualTo: widget.deviceId)
          .where('messageTime', whereIn: messageTimes)
          .get();
      bool changed        = false;
      bool noticeMovedOut = false;
      String noticeSender = '', noticeMessage = '', noticeStatus = '', noticeLabel = '';
      for (final doc in snap.docs) {
        final data          = doc.data();
        final msgTime       = data['messageTime']?.toString() ?? '';
        final status        = data['status']?.toString() ?? 'pending';
        final originalLabel = (data['originalLabel'] ?? '').toString().toLowerCase();
        if (msgTime.isNotEmpty && _reportStatus[msgTime] != status) {
          _reportStatus[msgTime] = status;
          changed = true;
          if (status == 'verified' || status == 'rejected') {
            final movedOut = await _applyReviewDecision(msgTime, status, originalLabel);
            if (movedOut) noticeMovedOut = true;
            noticeSender  = data['sender']?.toString() ?? 'Unknown';
            noticeMessage = data['message']?.toString() ?? '';
            noticeStatus  = status;
            noticeLabel   = originalLabel;
          }
        }
      }
      if (changed && mounted) {
        setState(() {});
        final p = await SharedPreferences.getInstance();
        await p.setString(_statusKey, jsonEncode(_reportStatus));
        await p.setString(_dismissedNotesKey, jsonEncode(_dismissedNotes.toList()));
        if (noticeStatus.isNotEmpty) {
          _showLocalReportResultNotice(noticeSender, noticeMessage, noticeStatus,
              originalLabel: noticeLabel, popToInbox: noticeMovedOut);
        }
      }
    } catch (e) { debugPrint('Spam Firestore sync error: $e'); }
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
    final preview  = message.length > 80 ? '\${message.substring(0, 80)}…' : message;
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

  /// Returns true if the message was moved OUT of spam (so the page should pop).
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
      final bool verified        = status == 'verified';
      final String finalLabel    = verified
          ? (wasPhishing ? 'Safe' : 'Phishing')
          : (wasPhishing ? 'Phishing' : 'Safe');
      entry['label'] = finalLabel;
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
        return false; // was in inbox, didn't move out of spam view
      } else {
        spam.removeAt(spamIdx);
        if (shouldBeInInbox) {
          await p.setString(spamKey, jsonEncode(spam));
          if (!man.any((m) => m['time']?.toString() == msgTime)) {
            man.insert(0, entry);
            if (man.length > 200) man.removeRange(200, man.length);
            await p.setString(manualKey, jsonEncode(man));
          }
          return true; // was in spam, now moved to inbox → pop the page
        } else {
          spam.insert(0, entry);
          if (spam.length > 200) spam.removeRange(200, spam.length);
          await p.setString(spamKey, jsonEncode(spam));
          return false; // stayed in spam
        }
      }
    } catch (e) {
      debugPrint('Spam apply review decision error: $e');
      return false;
    }
  }

  String? _statusFor(int i) {
    final time = widget.messages[i]['time']?.toString() ?? '';
    return _reportStatus[time];
  }

  List<int> get _matchIndices {
    if (_query.isEmpty) return [];
    return List.generate(widget.messages.length, (i) => i)
        .where((i) => (widget.messages[i]['message'] ?? '').toString().toLowerCase().contains(_query.toLowerCase()))
        .toList();
  }

  void _scrollToFirst() {
    final matches = _matchIndices;
    if (matches.isEmpty) return;
    final ctx = _itemKeys[matches.first].currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
  }

  Widget _highlightText(String text, String query) {
    if (query.isEmpty) return Text(text, style: const TextStyle(fontSize: 14, color: Colors.black87, height: 1.5));
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

  void _showLongPressSheet(BuildContext ctx) {
    showModalBottomSheet(context: ctx, backgroundColor: Colors.transparent,
      builder: (_) => _OptionsSheet(children: [
        _SheetAction(icon: Icons.move_to_inbox_outlined, iconColor: const Color(0xFF1A7A72),
            label: 'Move to Inbox', onTap: () { Navigator.pop(ctx); widget.onRestore(); Navigator.pop(ctx); }),
        _SheetAction(icon: Icons.flag_outlined, iconColor: const Color(0xFFE0A800),
            label: 'Report Inaccurate Detection',
            onTap: () {
              Navigator.pop(ctx);
              widget.onReport(() {
                // Set pending status for all messages from this sender immediately
                setState(() {
                  for (final msg in widget.messages) {
                    final t = msg['time']?.toString() ?? '';
                    if (t.isNotEmpty) _reportStatus[t] = 'pending';
                  }
                });
              });
            }),
        _SheetAction(icon: Icons.delete_outline, iconColor: const Color(0xFFF2554F),
            label: 'Delete', labelColor: const Color(0xFFF2554F),
            onTap: () async {
              Navigator.pop(ctx);
              if (await widget.onConfirmDelete()) { widget.onDelete(); if (mounted) Navigator.pop(context); }
            }),
      ]));
  }

  /// Tries every field name the XLM-R backend might use.
  /// Add debugPrint('API: $data') in _scan() to discover the exact key.
  List<Map<String, dynamic>> _extractLabelDetails(Map<String, dynamic> msg) {
    for (final key in ['sublabel', 'sub_label', 'type', 'category', 'subtype', 'phishing_type', 'attack_type']) {
      final v = (msg[key] ?? '').toString().trim();
      if (v.isNotEmpty && v.toLowerCase() != 'unknown') {
        return [{'label': v, 'icon': Icons.warning_amber_rounded}];
      }
    }
    final text = (msg['message'] ?? '').toString().toLowerCase();
    final tags = <Map<String, dynamic>>[];
    if (RegExp(r'https?://|bit\.ly|tinyurl|t\.co|click.*link|tap.*link|link.*below').hasMatch(text)) {
      tags.add({'label': 'Suspicious URL', 'icon': Icons.link});
    }
    if (RegExp(r'prize|reward|won|winner|claim|free|gift|cash|piso|pesos|spins?|\d+\s*(pesos?|php|\$)').hasMatch(text)) {
      tags.add({'label': 'Fake Rewards', 'icon': Icons.card_giftcard});
    }
    if (RegExp(r'login|log in|sign in|password|username|credentials|verif|otp|one.time|confirm|code|pin|passcode').hasMatch(text)) {
      tags.add({'label': 'Sensitive info request', 'icon': Icons.key});
    }
    if (RegExp(r'bank|gcash|maya|paypal|credit|debit|transfer|withdraw|deposit').hasMatch(text)) {
      tags.add({'label': 'Financial Fraud', 'icon': Icons.account_balance_wallet});
    }
    if (RegExp(r'parcel|package|deliver|shipment|courier|postal|tracking').hasMatch(text)) {
      tags.add({'label': 'Fake Delivery', 'icon': Icons.local_shipping});
    }
    if (RegExp(r'sss|philhealth|pagibig|bir|lto|nbi|dfa|passport|clearance').hasMatch(text)) {
      tags.add({'label': 'Gov. Impersonation', 'icon': Icons.account_balance});
    }
    if (RegExp(r'job|hiring|apply|salary|earn|work from home|income|negosyo').hasMatch(text)) {
      tags.add({'label': 'Fake Job Offer', 'icon': Icons.work_outline});
    }
    if (tags.isNotEmpty) return tags;
    return [{'label': 'Suspicious Message', 'icon': Icons.warning_amber_rounded}];
  }

  @override
  Widget build(BuildContext ctx) {
    final matches    = _matchIndices;
    final matchCount = matches.length;
    return Scaffold(
      backgroundColor: const Color(0xFFF6F4EC),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A7A72), foregroundColor: Colors.white, elevation: 0, centerTitle: false,
        title: _searchActive
            ? TextField(
                controller: _searchCtrl, autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                decoration: InputDecoration(
                  hintText: 'Search in conversation…', hintStyle: const TextStyle(color: Colors.white70),
                  border: InputBorder.none,
                  suffixText: _query.isNotEmpty ? '$matchCount found' : null,
                  suffixStyle: const TextStyle(color: Colors.white70, fontSize: 13)),
                onChanged: (v) { setState(() => _query = v); Future.delayed(const Duration(milliseconds: 100), _scrollToFirst); })
            : Text(widget.sender, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
        actions: [
          if (_searchActive)
            IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() { _searchActive = false; _query = ''; _searchCtrl.clear(); }))
          else ...[
            IconButton(icon: const Icon(Icons.search), onPressed: () => setState(() => _searchActive = true)),
            IconButton(icon: const Icon(Icons.delete_outline),
                onPressed: () async { if (await widget.onConfirmDelete()) { widget.onDelete(); if (mounted) Navigator.pop(context); } }),
          ],
        ],
      ),
      body: GestureDetector(
        onLongPress: () => _showLongPressSheet(ctx),
        child: ListView.builder(
          controller: _scrollCtrl,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          itemCount: widget.messages.length,
          itemBuilder: (_, i) {
            final msg     = widget.messages[i];
            final message = (msg['message'] ?? '').toString();
            final time    = widget.formatTime(msg['time'] as String?);
            final isMatch = _query.isNotEmpty && matches.contains(i);

            // Detail tags: specific phishing types from XLM-R model
            final labelTags = _extractLabelDetails(msg);

            DateTime? msgDate; bool showDate = false;
            try {
              msgDate = DateTime.parse(msg['time'] ?? '').toLocal();
              showDate = i == 0 || (() {
                final prev = DateTime.parse(widget.messages[i - 1]['time'] ?? '').toLocal();
                return prev.day != msgDate!.day || prev.month != msgDate.month || prev.year != msgDate.year;
              })();
            } catch (_) {}

            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (showDate && msgDate != null)
                Padding(padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(child: Text(DateFormat('MMM d, yyyy').format(msgDate),
                      style: const TextStyle(fontSize: 12, color: Color(0xFF999999))))),
              GestureDetector(
                key: _itemKeys[i],
                onLongPress: () => _showLongPressSheet(ctx),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 14),
                  padding: const EdgeInsets.all(14),
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(ctx).size.width * 0.9),
                  decoration: BoxDecoration(
                    color: isMatch ? const Color(0xFFFFF8E1) : const Color(0xFFFDE8E8),
                    border: isMatch ? Border.all(color: const Color(0xFFFFE57F), width: 1.5) : null,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(4), topRight: Radius.circular(18),
                      bottomLeft: Radius.circular(18), bottomRight: Radius.circular(18))),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _highlightText(message, _query),
                    const SizedBox(height: 10),

                    // Status display per message
                    Builder(builder: (_) {
                      final msgTime   = msg['time']?.toString() ?? '';
                      final msgStatus = _reportStatus[msgTime]; // null | 'pending' | 'verified' | 'rejected'

                      if (msgStatus == 'verified' || msgStatus == 'rejected') {
                        final isVerified = msgStatus == 'verified';
                        final color      = isVerified ? const Color(0xFF1A7A72) : const Color(0xFFF2554F);
                        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          // Corrected label chip
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(color: isVerified ? const Color(0xFF06C85E) : const Color(0xFFF2554F), borderRadius: BorderRadius.circular(20)),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(isVerified ? Icons.check_circle : Icons.warning_rounded, size: 13, color: Colors.white),
                              const SizedBox(width: 5),
                              Text(isVerified ? 'Safe' : 'Phishing Detected',
                                  style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
                            ])),
                          const SizedBox(height: 6),
                          // Developer-reviewed banner (dismissible)
                          if (!_dismissedNotes.contains(msgTime))
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                              decoration: BoxDecoration(
                                color: color.withOpacity(.08),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: color.withOpacity(.30))),
                              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Icon(isVerified ? Icons.verified_outlined : Icons.cancel_outlined, size: 14, color: color),
                                const SizedBox(width: 7),
                                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(
                                    isVerified ? 'Reviewed & Verified by Developers' : 'Reviewed & Rejected by Developers',
                                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
                                  const SizedBox(height: 2),
                                  Text(
                                    isVerified
                                        ? 'Our team confirmed your report was accurate. This message has been reclassified as Safe and moved to your inbox.'
                                        : 'Our team reviewed your report and confirmed this message is Phishing. It will remain in the Spam Folder.',
                                    style: const TextStyle(fontSize: 11, color: Color(0xFF666666), height: 1.4)),
                                ])),
                                GestureDetector(
                                  onTap: () async {
                                    setState(() => _dismissedNotes.add(msgTime));
                                    final p = await SharedPreferences.getInstance();
                                    await p.setString(_dismissedNotesKey, jsonEncode(_dismissedNotes.toList()));
                                  },
                                  child: const Padding(
                                    padding: EdgeInsets.only(left: 4),
                                    child: Icon(Icons.close, size: 14, color: Color(0xFFAAAAAA)))),
                              ])),
                        ]);
                      }

                      if (msgStatus == 'pending') {
                        return Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1A7A72).withOpacity(.08),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: const Color(0xFF1A7A72).withOpacity(.25))),
                            child: Row(mainAxisSize: MainAxisSize.min, children: const [
                              Icon(Icons.hourglass_top_rounded, size: 14, color: Color(0xFF1A7A72)),
                              SizedBox(width: 6),
                              Text('Verification in Progress',
                                  style: TextStyle(fontSize: 12, color: Color(0xFF1A7A72), fontWeight: FontWeight.w600)),
                            ])),
                        );
                      }

                      // Default: Phishing label + sub-tags
                      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(color: const Color(0xFFF2554F), borderRadius: BorderRadius.circular(20)),
                          child: Row(mainAxisSize: MainAxisSize.min, children: const [
                            Icon(Icons.warning_rounded, size: 13, color: Colors.white),
                            SizedBox(width: 5),
                            Text('Phishing Detected',
                                style: TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
                          ])),
                        if (labelTags.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Wrap(spacing: 6, runSpacing: 4,
                              children: labelTags.map((tag) => Container(
                                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.transparent,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: const Color(0xFFF2554F).withOpacity(.55), width: 1)),
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                                  Icon(tag['icon'] as IconData, size: 11, color: const Color(0xFFF2554F)),
                                  const SizedBox(width: 4),
                                  Text(tag['label'] as String,
                                      style: const TextStyle(fontSize: 11, color: Color(0xFFF2554F), fontWeight: FontWeight.w500)),
                                ]))).toList())),
                      ]);
                    }),

                    const SizedBox(height: 8),
                    Align(alignment: Alignment.bottomRight,
                        child: Text(time, style: const TextStyle(fontSize: 11, color: Color(0xFF999999)))),
                  ]),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Firestore report helper
// ─────────────────────────────────────────────────────────────────────────────

Future<void> _submitReport({
  required String sender,
  required String message,
  required String originalLabel,
  required String reason,
  required String type,
  required String deviceId,
  String messageTime = '',
}) async {
  try {
    await FirebaseFirestore.instance.collection('reports').add({
      'sender'       : sender,
      'message'      : message,
      'originalLabel': originalLabel,
      'reason'       : reason,
      'type'         : type,
      'status'       : 'pending',
      'deviceId'     : deviceId,
      'messageTime'  : messageTime,
      'reportedAt'   : FieldValue.serverTimestamp(),
    });
  } catch (e) {
    debugPrint('Failed to submit report: $e');
  }
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
  static const _apiUrl = 'https://phishsense-backend-production.up.railway.app/predict';

  Future<void> _scan() async {
    final sender = _senderCtrl.text.trim();
    final text   = _messageCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() { _scanning = true; _error = null; });
    try {
      final res = await http.post(Uri.parse(_apiUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'message': text})).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);

        // ── Print full API response so you can find the XLM-R sub-type field name ──
        debugPrint('PhishSense API response: $data');
        // ─────────────────────────────────────────────────────────────────────────

        final label   = (data['label'] ?? 'Unknown').toString();
        final rawConf = data['confidence'] ?? 0.0;
        final conf    = (rawConf is num) ? rawConf.toDouble() * (rawConf <= 1.0 ? 100 : 1) : 0.0;

        // Try every possible sub-type field name. Replace with the correct one
        // once you see it printed above in the debug console.
        String sublabel = '';
        for (final key in ['sublabel', 'sub_label', 'type', 'category', 'subtype', 'phishing_type', 'attack_type']) {
          final v = (data[key] ?? '').toString().trim();
          if (v.isNotEmpty && v.toLowerCase() != 'unknown') { sublabel = v; break; }
        }

        final result = <String, dynamic>{
          'sender'    : sender.isEmpty ? 'Unknown' : sender,
          'message'   : text,
          'label'     : label[0].toUpperCase() + label.substring(1),
          'confidence': double.parse(conf.toStringAsFixed(1)),
          'time'      : DateTime.now().toIso8601String(),
          'source'    : 'manual',
        };
        if (sublabel.isNotEmpty) result['sublabel'] = sublabel[0].toUpperCase() + sublabel.substring(1);

        widget.onResult(result);
        if (mounted) Navigator.of(context).pop();
      } else {
        setState(() { _error = 'Server error (${res.statusCode}).'; _scanning = false; });
      }
    } catch (_) {
      setState(() { _error = 'Could not reach the server. Check your connection.'; _scanning = false; });
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
  final IconData icon; final Color iconColor; final String label;
  final Color? labelColor; final VoidCallback onTap;
  const _SheetAction({required this.icon, required this.iconColor, required this.label, this.labelColor, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(onTap: onTap,
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(children: [
          Container(width: 36, height: 36,
              decoration: BoxDecoration(color: iconColor.withOpacity(.1), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: iconColor, size: 20)),
          const SizedBox(width: 16),
          Text(label, style: TextStyle(fontSize: 15, color: labelColor ?? Colors.black87, fontWeight: FontWeight.w400)),
        ])));
  }
}
