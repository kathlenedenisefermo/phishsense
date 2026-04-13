import 'dart:convert';
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

  List<Map<String, dynamic>> _allMessages     = [];
  List<Map<String, dynamic>> _threads         = [];
  List<Map<String, dynamic>> _filteredThreads = [];

  bool   _loading     = true;
  bool   _spamEnabled = true;
  String _searchQuery = '';
  final  _searchCtrl  = TextEditingController();
  final  _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    _loadSpamEnabled();
    _loadMessages();
    _searchCtrl.addListener(() {
      setState(() {
        _searchQuery     = _searchCtrl.text.toLowerCase();
        _filteredThreads = _applySearch(_threads);
      });
    });
  }

  @override
  void dispose() { _searchCtrl.dispose(); super.dispose(); }

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
    Navigator.push(context, MaterialPageRoute(builder: (_) => SpamFolderPage(formatTime: _formatTime)))
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
              icon: Icon(Icons.folder_special_outlined, color: _spamEnabled ? const Color(0xFF1A7A72) : const Color(0xFFBBBBBB)),
              onPressed: _openSpamFolder),
            IconButton(
              tooltip: 'Profile',
              icon: const Icon(Icons.person_outline, color: Color(0xFF1A7A72)),
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
                              sender: sender, formatTime: _formatTime,
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
  const _ConversationPage({required this.messages, required this.sender, required this.formatTime, required this.onDeleteThread});
  @override
  State<_ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<_ConversationPage> {
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  late final List<GlobalKey> _itemKeys;
  bool   _searchActive = false;
  String _query        = '';
  final Set<int> _reportedIndices = {};
  String get _reportedKey => 'reported_msgs_${widget.sender.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';

  @override
  void initState() { super.initState(); _itemKeys = List.generate(widget.messages.length, (_) => GlobalKey()); _loadReported(); }

  @override
  void dispose() { _searchCtrl.dispose(); _scrollCtrl.dispose(); super.dispose(); }

  Future<void> _loadReported() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_reportedKey);
    if (raw != null && raw.isNotEmpty) {
      final list = (jsonDecode(raw) as List).cast<int>();
      if (mounted) setState(() => _reportedIndices.addAll(list));
    }
  }

  Future<void> _saveReported() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_reportedKey, jsonEncode(_reportedIndices.toList()));
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
    final isPhishing = (msg['label'] ?? '').toString().toLowerCase() == 'phishing';
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
              Navigator.pop(dlgCtx);
              // Only fires on Submit — marks reported, persists, shows dialog
              setState(() => _reportedIndices.add(index));
              _saveReported();
              _showVerificationDialog(ctx);
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
          final msg        = widget.messages[i];
          final isPhishing = (msg['label'] ?? '').toString().toLowerCase() == 'phishing';
          final message    = (msg['message'] ?? '').toString();
          final time       = widget.formatTime(msg['time'] as String?);
          final reported   = _reportedIndices.contains(i);

          return Container(
            key: _itemKeys[i],
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(color: const Color(0xFFF3EEE4), borderRadius: BorderRadius.circular(14)),
            clipBehavior: Clip.hardEdge,
            child: IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(width: 5, color: isPhishing ? const Color(0xFFF2554F) : const Color(0xFF06C85E)),
              Expanded(child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 14, 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _highlightText(message, _query),
                  const SizedBox(height: 10),
                  if (reported) ...[
                    // Verification badge replaces label — only after Submit
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A7A72).withOpacity(.08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF1A7A72).withOpacity(.25))),
                      child: Row(children: const [
                        Icon(Icons.hourglass_top_rounded, size: 14, color: Color(0xFF1A7A72)),
                        SizedBox(width: 6),
                        Expanded(child: Text('Verification in Progress',
                            style: TextStyle(fontSize: 12, color: Color(0xFF1A7A72), fontWeight: FontWeight.w600))),
                      ])),
                    const SizedBox(height: 4),
                    Align(alignment: Alignment.centerRight,
                        child: Text(time, style: const TextStyle(fontSize: 11, color: Color(0xFF777777)))),
                  ] else
                    Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: isPhishing ? const Color(0xFFF2554F) : const Color(0xFF06C85E),
                          borderRadius: BorderRadius.circular(20)),
                        child: Text(isPhishing ? 'Phishing' : 'Safe',
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600))),
                      const SizedBox(width: 8),
                      Expanded(child: GestureDetector(
                        onTap: () => _showReportSheet(ctx, i),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.flag_outlined, size: 13, color: Color(0xFFAAAAAA)),
                          const SizedBox(width: 4),
                          Flexible(child: Text(isPhishing ? 'Report Inaccurate Detection' : 'Report as Phishing',
                              style: const TextStyle(fontSize: 12, color: Color(0xFFAAAAAA)), overflow: TextOverflow.ellipsis)),
                        ]))),
                      Text(time, style: const TextStyle(fontSize: 11, color: Color(0xFF777777))),
                    ]),
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
  const SpamFolderPage({super.key, required this.formatTime});
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

  @override
  void initState() { super.initState(); _loadPref(); _loadSpam(); }

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
              onReported?.call(); // fires only here — on Submit
              _showVerificationDialog(ctx);
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
                        const Icon(Icons.person_outline, size: 13, color: Color(0xFF1A7A72)),
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
  const _SpamConversationPage({
    required this.messages, required this.sender, required this.formatTime,
    required this.onRestore, required this.onDelete, required this.onConfirmDelete, required this.onReport});
  @override
  State<_SpamConversationPage> createState() => _SpamConversationPageState();
}

class _SpamConversationPageState extends State<_SpamConversationPage> {
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  late final List<GlobalKey> _itemKeys;
  bool   _searchActive    = false;
  String _query           = '';
  bool   _senderReported  = false;

  String get _spamReportedKey => 'spam_reported_${widget.sender.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';

  @override
  void initState() { super.initState(); _itemKeys = List.generate(widget.messages.length, (_) => GlobalKey()); _loadSenderReported(); }

  @override
  void dispose() { _searchCtrl.dispose(); _scrollCtrl.dispose(); super.dispose(); }

  Future<void> _loadSenderReported() async {
    final p = await SharedPreferences.getInstance();
    if (mounted) setState(() => _senderReported = p.getBool(_spamReportedKey) ?? false);
  }

  Future<void> _saveSenderReported() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_spamReportedKey, true);
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
              // Pass a callback that fires ONLY when the user taps Submit in the dialog
              widget.onReport(() {
                if (mounted) {
                  setState(() => _senderReported = true);
                  _saveSenderReported();
                }
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
  String _extractLabelDetail(Map<String, dynamic> msg) {
    for (final key in ['sublabel', 'sub_label', 'type', 'category', 'subtype', 'phishing_type', 'attack_type']) {
      final v = (msg[key] ?? '').toString().trim();
      if (v.isNotEmpty && v.toLowerCase() != 'unknown') return v;
    }
    final conf = msg['confidence'];
    if (conf != null) return '${conf.toString()}% confidence';
    return '';
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

            // Detail sub-line: specific phishing type from XLM-R model
            final labelDetail = _extractLabelDetail(msg);

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

                    // Verification replaces label — ONLY after Submit is tapped
                    if (_senderReported) ...[
                      Align(
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
                      ),
                    ] else ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF2554F),
                          borderRadius: BorderRadius.circular(20)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: const [
                          Icon(Icons.warning_rounded, size: 13, color: Colors.white),
                          SizedBox(width: 5),
                          Text('Phishing Detected',
                              style: TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
                        ])),
                      if (labelDetail.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4, left: 6),
                          child: Text(labelDetail,
                              style: TextStyle(fontSize: 11, color: const Color(0xFFF2554F).withOpacity(.85)))),
                    ],

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
        _field(_senderCtrl, hint: 'Sender name or number (optional)', icon: Icons.person_outline, maxLines: 1),
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
