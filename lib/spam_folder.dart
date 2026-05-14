import 'report_tracker.dart';

// ─────────────────────────────────────────────────────────────────────────────
// PATCH: Replace the SpamFolderPage StatefulWidget + State class in
//        ios_messages_page.dart with this version.
//
// Changes:
//   • Added `_activeTab` (0 = Smishing, 1 = Reports) to state
//   • Scaffold body now switches between the spam list and ReportTrackerBody
//   • Added _buildBottomNav() and _buildNavTab() helpers (same style as inbox)
//   • AppBar "Report Tracker" icon removed (now lives in the Reports tab)
// ─────────────────────────────────────────────────────────────────────────────

class SpamFolderPage extends StatefulWidget {
  final String Function(String?) formatTime;
  final String deviceId;
  final VoidCallback? onOpenReportTracker; // kept for API compat, unused now

  const SpamFolderPage({
    super.key,
    required this.formatTime,
    required this.deviceId,
    this.onOpenReportTracker,
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

  static const _deletionOptions = [
    (label: 'Never', days: -1),
    (label: '7 days', days: 7),
    (label: '14 days', days: 14),
    (label: '30 days', days: 30)
  ];
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

  // ── All existing methods remain unchanged ─────────────────────────────────
  // (_startReviewListener, _applyReviewDecision, _loadPref, _savePref,
  //  _applyAutoDeletion, _loadSpam, _persistSpam, _buildThreads,
  //  _autoDeletionLabel, _restoreToInbox, _deleteFromSpam, _confirmDelete,
  //  _deleteAll, _showSpamOptions, _showReportSheet, _showVerificationDialog,
  //  _showDeletionDropdown)
  // KEEP THEM ALL AS-IS — only build() and the two new helpers are new.

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
    var msgs  = raw != null && raw.isNotEmpty
        ? (jsonDecode(raw) as List).cast<Map<String, dynamic>>()
        : <Map<String, dynamic>>[];
    msgs = _applyAutoDeletion(msgs);
    if (mounted) setState(() {
      _spamMessages = msgs;
      _threads      = _buildThreads(msgs);
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
        'sender': e.key,
        'messages': sorted,
        'latest': sorted.first,
        'count': sorted.length
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
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF2554F), foregroundColor: Colors.white,
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
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF2554F), foregroundColor: Colors.white,
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
      'Other reason'
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
                    Container(
                      width: 56, height: 56,
                      decoration: BoxDecoration(color: const Color(0xFFF2554F).withOpacity(.12), shape: BoxShape.circle),
                      child: const Icon(Icons.flag_rounded, color: Color(0xFFF2554F), size: 28),
                    ),
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
                        onPressed: () {
                          Navigator.pop(dlgCtx);
                          onReported?.call();
                          _showVerificationDialog(ctx);
                          final msgs = _spamMessages.where((m) => (m['sender'] ?? '') == sender).toList();
                          final sample = msgs.isNotEmpty ? msgs.first : <String, dynamic>{};
                          submitReport(
                            messageBody: sample['message']?.toString() ?? '',
                            originalLabel: 'phishing',
                            confidence: ((sample['confidence'] as num?)?.toDouble() ?? 0.0),
                            reason: selected == 'Other reason' ? otherCtrl.text.trim() : selected!,
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
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(.12), blurRadius: 20, offset: const Offset(0, 6))],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8F6F0),
                  borderRadius: const BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
                  border: Border(bottom: BorderSide(color: const Color(0xFFE0DAD0))),
                ),
                child: Row(children: [
                  Container(width: 40, height: 40,
                    decoration: BoxDecoration(color: const Color(0xFFF2554F).withOpacity(.10), borderRadius: BorderRadius.circular(10)),
                    child: const Icon(Icons.flag_outlined, color: Color(0xFFF2554F), size: 22),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Report Inaccurate Detection', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    SizedBox(height: 2),
                    Text('Why do you think this detection is wrong?', style: TextStyle(fontSize: 12, color: Color(0xFF888888))),
                  ])),
                ]),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Column(children: [
                    ...reasons.map((r) {
                      final isSelected = selected == r;
                      return GestureDetector(
                        onTap: () => set(() => selected = r),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: isSelected ? const Color(0xFF1A7A72).withOpacity(.07) : const Color(0xFFF8F6F0),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isSelected ? const Color(0xFF1A7A72) : const Color(0xFFE0DAD0),
                              width: isSelected ? 1.5 : 1,
                            ),
                          ),
                          child: Row(children: [
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              width: 20, height: 20,
                              decoration: BoxDecoration(shape: BoxShape.circle,
                                color: isSelected ? const Color(0xFF1A7A72) : Colors.white,
                                border: Border.all(color: isSelected ? const Color(0xFF1A7A72) : const Color(0xFFCCCCCC), width: 2),
                              ),
                              child: isSelected ? const Icon(Icons.check, size: 12, color: Colors.white) : null,
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: Text(r, style: TextStyle(
                              fontSize: 14,
                              color: isSelected ? const Color(0xFF1A7A72) : const Color(0xFF333333),
                              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                            ))),
                          ]),
                        ),
                      );
                    }),
                    if (selected == 'Other reason')
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: TextField(controller: otherCtrl, maxLines: 3,
                          style: const TextStyle(fontSize: 14),
                          decoration: InputDecoration(
                            hintText: 'Describe your reason…',
                            hintStyle: const TextStyle(color: Color(0xFFAAAAAA), fontSize: 13),
                            filled: true, fillColor: const Color(0xFFF8F6F0),
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
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                child: Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(dlgCtx),
                      style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF666666),
                          side: const BorderSide(color: Color(0xFFDDD8CE)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(vertical: 13)),
                      child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: selected == null ? null : () => set(() => showConfirm = true),
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1A7A72), foregroundColor: Colors.white,
                          disabledBackgroundColor: const Color(0xFF1A7A72).withOpacity(.35),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(vertical: 13), elevation: 0),
                      child: const Text('Next', style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ),
                ]),
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
                  child: const Icon(Icons.hourglass_top_rounded, color: Colors.white, size: 32),
                ),
                const SizedBox(height: 14),
                const Text('Verification in Progress', textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
                const SizedBox(height: 6),
                Text('Your report has been submitted', style: TextStyle(fontSize: 13, color: Colors.white.withOpacity(.8))),
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

  // ── NEW: Reports tab body ─────────────────────────────────────────────────

  Widget _buildReportsTab() {
    if (widget.deviceId.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF1A7A72)));
    }
    return ReportTrackerBody(
      key: ValueKey('spam_reports_${widget.deviceId}_$_activeTab'),
      deviceId: widget.deviceId,
      source: 'spam',
    );
  }

  // ── NEW: Bottom nav ───────────────────────────────────────────────────────

  Widget _buildBottomNav() {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Color(0x1A000000), blurRadius: 12, offset: Offset(0, -4))],
        borderRadius: BorderRadius.only(
            topLeft: Radius.circular(24), topRight: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            decoration: BoxDecoration(
                color: const Color(0xFFECE9DF),
                borderRadius: BorderRadius.circular(14)),
            padding: const EdgeInsets.all(4),
            child: Row(children: [
              _buildNavTab(
                index: 0,
                icon: Icons.folder_outlined,
                label: 'Smishing',
                badge: _threads.length,
              ),
              _buildNavTab(
                index: 1,
                icon: Icons.assignment_outlined,
                label: 'Reports',
              ),
            ]),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  Widget _buildNavTab({
    required int index,
    required IconData icon,
    required String label,
    int? badge,
  }) {
    final isActive = _activeTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _activeTab = index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          decoration: BoxDecoration(
            color: isActive ? const Color(0xFF1A7A72) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(icon,
                      size: 16,
                      color: isActive ? Colors.white : const Color(0xFF888888)),
                  if (badge != null && badge > 0)
                    Positioned(
                      top: -6,
                      right: -8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF2554F),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          badge > 99 ? '99+' : '$badge',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isActive ? Colors.white : const Color(0xFF888888),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
          if (_activeTab == 0 && !_loading && _spamMessages.isNotEmpty)
            IconButton(
                tooltip: 'Delete all',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: _deleteAll),
        ],
      ),
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          // ── Tab content (fills available space) ──────────────────────────
          Expanded(
            child: _activeTab == 1
                ? _buildReportsTab()
                : _loading
                ? const Center(
                child: CircularProgressIndicator(color: Color(0xFF1A7A72)))
                : Column(children: [
              if (_spamMessages.isNotEmpty) ...[
                Container(
                  width: double.infinity,
                  color: const Color(0xFFF6F4EC),
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                  child: Row(children: [
                    Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                            color: const Color(0xFFF2554F).withOpacity(.12),
                            borderRadius: BorderRadius.circular(20)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.warning_rounded,
                              size: 13, color: Color(0xFFF2554F)),
                          const SizedBox(width: 5),
                          Text(
                              '$phishingCount phishing message${phishingCount != 1 ? 's' : ''}',
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFFF2554F),
                                  fontWeight: FontWeight.w600)),
                        ])),
                    const SizedBox(width: 8),
                    Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                            color: const Color(0xFF1A7A72).withOpacity(.10),
                            borderRadius: BorderRadius.circular(20)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.person,
                              size: 13, color: Color(0xFF1A7A72)),
                          const SizedBox(width: 5),
                          Text(
                              '$senderCount sender${senderCount != 1 ? 's' : ''}',
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF1A7A72),
                                  fontWeight: FontWeight.w600)),
                        ])),
                  ]),
                ),
                const Divider(height: 1, color: Color(0xFFDDD8CE)),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(children: [
                  const Icon(Icons.timer_outlined,
                      size: 16, color: Color(0xFF1A7A72)),
                  const SizedBox(width: 8),
                  const Text('Auto-delete spam after',
                      style: TextStyle(fontSize: 14, color: Colors.black87)),
                  const Spacer(),
                  Builder(builder: (btnCtx) => GestureDetector(
                    onTap: () => _showDeletionDropdown(btnCtx),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                          color: const Color(0xFF1A7A72),
                          borderRadius: BorderRadius.circular(8)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(_autoDeletionLabel,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(width: 4),
                        const Icon(Icons.arrow_drop_down,
                            color: Colors.white, size: 18),
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
                            style: TextStyle(
                                color: Color(0xFF888888),
                                fontSize: 15,
                                height: 1.6))))
                    : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
                    itemCount: _threads.length,
                    separatorBuilder: (_, __) =>
                    const Divider(height: 1, color: Color(0xFFEEEBE0)),
                    itemBuilder: (ctx, i) {
                      final thread = _threads[i];
                      final sender = thread['sender'] as String;
                      final latest =
                      thread['latest'] as Map<String, dynamic>;
                      final count  = thread['count'] as int;
                      final time   = widget.formatTime(
                          latest['time'] as String?);
                      return GestureDetector(
                        onLongPress: () =>
                            _showSpamOptions(ctx, sender),
                        child: InkWell(
                          onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) =>
                                      _SpamConversationPage(
                                        messages: thread['messages']
                                        as List<
                                            Map<String, dynamic>>,
                                        sender: sender,
                                        formatTime: widget.formatTime,
                                        onRestore: () =>
                                            _restoreToInbox(sender),
                                        onDelete: () =>
                                            _deleteFromSpam(sender),
                                        onConfirmDelete: () =>
                                            _confirmDelete(sender),
                                        onReport: (onReported) =>
                                            _showReportSheet(
                                                ctx, sender, onReported),
                                        deviceId: widget.deviceId,
                                      ))).then((_) => _loadSpam()),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(
                                16, 12, 16, 12),
                            child: Row(
                                crossAxisAlignment:
                                CrossAxisAlignment.start,
                                children: [
                                  Container(
                                      width: 46,
                                      height: 46,
                                      decoration: BoxDecoration(
                                          color:
                                          const Color(0xFFE8E4DA),
                                          borderRadius:
                                          BorderRadius.circular(
                                              23)),
                                      child: const Icon(Icons.person,
                                          color: Color(0xFF999999),
                                          size: 26)),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                        crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                        children: [
                                          Row(children: [
                                            Expanded(
                                                child: Text(sender,
                                                    style: const TextStyle(
                                                        fontSize: 15,
                                                        fontWeight:
                                                        FontWeight
                                                            .w600),
                                                    overflow:
                                                    TextOverflow
                                                        .ellipsis)),
                                            if (count > 0)
                                              Container(
                                                  margin:
                                                  const EdgeInsets
                                                      .only(
                                                      left: 6,
                                                      right: 6),
                                                  width: 20,
                                                  height: 20,
                                                  decoration: const BoxDecoration(
                                                      color: Color(
                                                          0xFFF2554F),
                                                      shape: BoxShape
                                                          .circle),
                                                  child: Center(
                                                      child: Text(
                                                          count > 9
                                                              ? '9+'
                                                              : '$count',
                                                          style: const TextStyle(
                                                              color: Colors
                                                                  .white,
                                                              fontSize:
                                                              10,
                                                              fontWeight:
                                                              FontWeight.w700)))),
                                            Text(time,
                                                style: const TextStyle(
                                                    fontSize: 12,
                                                    color: Color(
                                                        0xFF999999))),
                                          ]),
                                          const SizedBox(height: 3),
                                          Text(
                                              (latest['message'] ?? '')
                                                  .toString(),
                                              maxLines: 2,
                                              overflow: TextOverflow
                                                  .ellipsis,
                                              style: const TextStyle(
                                                  fontSize: 13,
                                                  color: Color(
                                                      0xFF666666),
                                                  height: 1.4)),
                                        ]),
                                  ),
                                ]),
                          ),
                        ),
                      );
                    }),
              ),
            ]),
          ),

          // ── Bottom nav — exact copy of IOSMessagesPage._buildBottomNav() ──
          _buildBottomNav(),
        ]),
      ),
    );
  }

  // ── Reports tab body ──────────────────────────────────────────────────────

  Widget _buildReportsTab() {
    if (widget.deviceId.isEmpty) {
      return const Center(
          child: CircularProgressIndicator(color: Color(0xFF1A7A72)));
    }
    return ReportTrackerBody(
      key: ValueKey(widget.deviceId),
      deviceId: widget.deviceId,
      source: 'spam',
    );
  }

  // ── Bottom nav — matches screenshot design exactly ────────────────────────

  Widget _buildBottomNav() {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Color(0x1A000000),
              blurRadius: 12,
              offset: Offset(0, -4)),
        ],
        borderRadius: BorderRadius.only(
            topLeft: Radius.circular(24), topRight: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(
            children: [
              _buildNavTab(
                index: 0,
                icon: Icons.phishing,           // fishing hook — matches screenshot
                label: 'Smishing',
              ),
              _buildNavTab(
                index: 1,
                icon: Icons.fact_check_outlined, // checklist — matches screenshot
                label: 'Reports',
              ),
            ],
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  // Active tab: light warm-grey rounded pill + teal text/icon
  // Inactive tab: transparent + grey text/icon
  Widget _buildNavTab({
    required int index,
    required IconData icon,
    required String label,
  }) {
    final isActive = _activeTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _activeTab = index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
          decoration: BoxDecoration(
            color: isActive ? const Color(0xFFE8E5DC) : Colors.transparent,
            borderRadius: BorderRadius.circular(30),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 18,
                color: isActive
                    ? const Color(0xFF1A7A72)
                    : const Color(0xFF999999),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: isActive
                        ? const Color(0xFF1A7A72)
                        : const Color(0xFF999999),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── build() ───────────────────────────────────────────────────────────────

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
          if (_activeTab == 0 && !_loading && _spamMessages.isNotEmpty)
            IconButton(
                tooltip: 'Delete all',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: _deleteAll),
        ],
      ),
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          // ── Tab content ──────────────────────────────────────────────────
          Expanded(
            child: _activeTab == 1
                ? _buildReportsTab()
                : _loading
                ? const Center(
                child: CircularProgressIndicator(
                    color: Color(0xFF1A7A72)))
                : Column(children: [
              // "N phishing messages from N senders" line
              if (_spamMessages.isNotEmpty) ...[
                Padding(
                  padding:
                  const EdgeInsets.fromLTRB(16, 14, 16, 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '$phishingCount phishing message${phishingCount != 1 ? 's' : ''} from $senderCount sender${senderCount != 1 ? 's' : ''}',
                      style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF666666)),
                    ),
                  ),
                ),
                const Divider(height: 1, color: Color(0xFFDDD8CE)),
              ],

              // Auto-delete row
              Container(
                color: Colors.white,
                padding:
                const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Row(children: [
                  const Icon(Icons.timer_outlined,
                      size: 16, color: Color(0xFF1A7A72)),
                  const SizedBox(width: 8),
                  const Text('Auto-delete messages after',
                      style: TextStyle(
                          fontSize: 14, color: Colors.black87)),
                  const Spacer(),
                  Builder(builder: (btnCtx) => GestureDetector(
                    onTap: () =>
                        _showDeletionDropdown(btnCtx),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                          color: const Color(0xFF1A7A72),
                          borderRadius:
                          BorderRadius.circular(8)),
                      child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_autoDeletionLabel,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight:
                                    FontWeight.w600)),
                            const SizedBox(width: 4),
                            const Icon(Icons.arrow_drop_down,
                                color: Colors.white,
                                size: 18),
                          ]),
                    ),
                  )),
                ]),
              ),
              const Divider(height: 1, color: Color(0xFFDDD8CE)),

              // Thread list
              Expanded(
                child: _threads.isEmpty
                    ? const Center(
                    child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text(
                            'No spam messages yet.\n\nPhishing messages will appear here.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Color(0xFF888888),
                                fontSize: 15,
                                height: 1.6))))
                    : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(
                        0, 4, 0, 8),
                    itemCount: _threads.length,
                    separatorBuilder: (_, __) =>
                    const Divider(
                        height: 1,
                        color: Color(0xFFEEEBE0)),
                    itemBuilder: (ctx, i) {
                      final thread = _threads[i];
                      final sender =
                      thread['sender'] as String;
                      final latest = thread['latest']
                      as Map<String, dynamic>;
                      final count =
                      thread['count'] as int;
                      final time = widget.formatTime(
                          latest['time'] as String?);
                      return GestureDetector(
                        onLongPress: () =>
                            _showSpamOptions(ctx, sender),
                        child: InkWell(
                          onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) =>
                                      _SpamConversationPage(
                                        messages: thread[
                                        'messages']
                                        as List<Map<String,
                                            dynamic>>,
                                        sender: sender,
                                        formatTime: widget
                                            .formatTime,
                                        onRestore: () =>
                                            _restoreToInbox(
                                                sender),
                                        onDelete: () =>
                                            _deleteFromSpam(
                                                sender),
                                        onConfirmDelete:
                                            () => _confirmDelete(
                                            sender),
                                        onReport: (onReported) =>
                                            _showReportSheet(
                                                ctx,
                                                sender,
                                                onReported),
                                        deviceId:
                                        widget.deviceId,
                                      ))).then(
                                  (_) => _loadSpam()),
                          child: Padding(
                            padding:
                            const EdgeInsets.fromLTRB(
                                16, 12, 16, 12),
                            child: Row(
                                crossAxisAlignment:
                                CrossAxisAlignment
                                    .start,
                                children: [
                                  // Avatar with red border (phishing indicator)
                                  Container(
                                      width: 46,
                                      height: 46,
                                      decoration: BoxDecoration(
                                          color: const Color(
                                              0xFFEDE8DF),
                                          borderRadius:
                                          BorderRadius
                                              .circular(
                                              23),
                                          border: Border.all(
                                              color: const Color(
                                                  0xFFF2554F)
                                                  .withOpacity(
                                                  .4),
                                              width: 1.5)),
                                      child: const Icon(
                                          Icons.person,
                                          color: Color(
                                              0xFF999999),
                                          size: 26)),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                        crossAxisAlignment:
                                        CrossAxisAlignment
                                            .start,
                                        children: [
                                          Row(children: [
                                            Expanded(
                                                child: Text(
                                                    sender,
                                                    style: const TextStyle(
                                                        fontSize:
                                                        15,
                                                        fontWeight:
                                                        FontWeight
                                                            .w600),
                                                    overflow:
                                                    TextOverflow
                                                        .ellipsis)),
                                            if (count > 0)
                                              Container(
                                                  margin: const EdgeInsets.only(
                                                      left:
                                                      6,
                                                      right:
                                                      6),
                                                  width: 22,
                                                  height:
                                                  22,
                                                  decoration: const BoxDecoration(
                                                      color: Color(
                                                          0xFFF2554F),
                                                      shape:
                                                      BoxShape.circle),
                                                  child: Center(
                                                      child: Text(
                                                          count > 9 ? '9+' : '$count',
                                                          style: const TextStyle(
                                                              color: Colors.white,
                                                              fontSize: 10,
                                                              fontWeight: FontWeight.w700)))),
                                            Text(time,
                                                style: const TextStyle(
                                                    fontSize:
                                                    12,
                                                    color: Color(
                                                        0xFF999999))),
                                          ]),
                                          const SizedBox(
                                              height: 3),
                                          Text(
                                              (latest['message'] ??
                                                  '')
                                                  .toString(),
                                              maxLines: 2,
                                              overflow:
                                              TextOverflow
                                                  .ellipsis,
                                              style: const TextStyle(
                                                  fontSize:
                                                  13,
                                                  color: Color(
                                                      0xFF666666),
                                                  height:
                                                  1.4)),
                                        ]),
                                  ),
                                  // Chevron
                                  const Padding(
                                    padding: EdgeInsets.only(
                                        top: 2, left: 4),
                                    child: Icon(
                                        Icons
                                            .chevron_right_rounded,
                                        size: 18,
                                        color: Color(
                                            0xFFCCCCCC)),
                                  ),
                                ]),
                          ),
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

  Widget _buildReportsTab() {
    if (widget.deviceId.isEmpty) {
      return const Center(
          child: CircularProgressIndicator(color: Color(0xFF1A7A72)));
    }
    return ReportTrackerBody(
      key: ValueKey(widget.deviceId),
      deviceId: widget.deviceId,
      source: 'spam',
    );
  }