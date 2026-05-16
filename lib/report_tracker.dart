import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'report_model.dart';
import 'dart:async';

// ─────────────────────────────────────────────────────────────────────────────
// ReportTrackerBody
// Drop-in replacement for the old ReportTrackerBody widget.
// Usage (inbox):
//   ReportTrackerBody(deviceId: _deviceId, source: 'inbox',
//       onOpenConversation: (sender, messageId) { ... })
// Usage (spam):
//   ReportTrackerBody(deviceId: _deviceId, source: 'spam')
// ─────────────────────────────────────────────────────────────────────────────

class ReportTrackerBody extends StatefulWidget {
  final String deviceId;
  final String source;
  final void Function(String sender, String messageId)? onOpenConversation;
  final void Function(void Function())? onToggleHideReviewed;
  final void Function(bool)? onHideReviewedChanged;

  const ReportTrackerBody({
    super.key,
    required this.deviceId,
    required this.source,
    this.onOpenConversation,
    this.onToggleHideReviewed,
    this.onHideReviewedChanged,
  });

  @override
  State<ReportTrackerBody> createState() => _ReportTrackerBodyState();
}

class _ReportTrackerBodyState extends State<ReportTrackerBody> {
  final Map<String, ReportStatus> _prevStatus = {};
  final Set<String> _dialogShownThisSession = {};
  final Set<String> _viewedReportIds = {};
  static const _viewedKey = 'viewed_report_ids';
  bool _hideReviewed = false;

  // Single merged stream — avoids nested StreamBuilders causing rapid
  // double-rebuilds that hit Flutter Web's canvas assertion.
  late final StreamController<_MergedDocs> _mergedController;
  StreamSubscription<QuerySnapshot>? _activeSub;
  StreamSubscription<QuerySnapshot>? _reviewedSub;
  List<QueryDocumentSnapshot> _activeDocs = [];
  List<QueryDocumentSnapshot> _reviewedDocs = [];

  @override
  void initState() {
    super.initState();
    _mergedController = StreamController<_MergedDocs>.broadcast();
    if (widget.deviceId.isNotEmpty) _subscribeStreams();
    _loadViewedIds();
    widget.onToggleHideReviewed?.call(() {
      setState(() => _hideReviewed = !_hideReviewed);
      widget.onHideReviewedChanged?.call(_hideReviewed);
    });
  }

  Future<void> _loadViewedIds() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_viewedKey);
    if (raw != null && raw.isNotEmpty) {
      final list = (jsonDecode(raw) as List).cast<String>();
      if (mounted) setState(() => _viewedReportIds.addAll(list));
    }
  }

  void _subscribeStreams() {
    _activeSub = FirebaseFirestore.instance
        .collection('model_feedback')
        .snapshots()
        .listen((snap) {
      _activeDocs  = snap.docs;
      _reviewedDocs = [];
      _emitMerged();
    });
  }

  void _emitMerged() {
    if (!_mergedController.isClosed) {
      _mergedController.add(_MergedDocs(_activeDocs, _reviewedDocs));
    }
  }

  @override
  void dispose() {
    _activeSub?.cancel();
    _reviewedSub?.cancel();
    _mergedController.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.deviceId.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No reports yet.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF888888), fontSize: 15, height: 1.6),
          ),
        ),
      );
    }
    return StreamBuilder<_MergedDocs>(
      stream: _mergedController.stream,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'No reports yet.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF888888), fontSize: 15, height: 1.6),
              ),
            ),
          );
        }

        const reviewedStatuses = {'trained', 'verified', 'validated', 'rejected'};
        final allDocs = <QueryDocumentSnapshot>[
          ...snap.data!.active,
          ...snap.data!.reviewed,
        ];

        List<QueryDocumentSnapshot> sortByDate(List<QueryDocumentSnapshot> docs) =>
            docs..sort((a, b) {
              final aT = (a.data() as Map<String, dynamic>)['timestamp'] as Timestamp?;
              final bT = (b.data() as Map<String, dynamic>)['timestamp'] as Timestamp?;
              if (aT == null && bT == null) return 0;
              if (aT == null) return 1;
              if (bT == null) return -1;
              return bT.compareTo(aT);
            });

        final pendingDocs = sortByDate(allDocs.where((d) {
          final s = (d.data() as Map<String, dynamic>)['status'] as String? ?? '';
          return !reviewedStatuses.contains(s);
        }).toList());
        final decidedDocs = sortByDate(allDocs.where((d) {
          final s = (d.data() as Map<String, dynamic>)['status'] as String? ?? '';
          return reviewedStatuses.contains(s);
        }).toList());

        if (pendingDocs.isEmpty && decidedDocs.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'No reports submitted yet.\n\nReport a message to track its review status here.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Color(0xFF888888), fontSize: 15, height: 1.6),
              ),
            ),
          );
        }

        final pending = pendingDocs.map((d) => ReportModel.fromFirestore(d)).toList();
        final decided = decidedDocs.map((d) => ReportModel.fromFirestore(d)).toList();

        final unseenReports = [
          ...pending.where((r) =>
          (r.status == ReportStatus.validated || r.status == ReportStatus.rejected) &&
              !_viewedReportIds.contains(r.reportId)),
          ...decided.where((r) =>
          (r.status == ReportStatus.validated || r.status == ReportStatus.rejected) &&
              !_viewedReportIds.contains(r.reportId)),
        ];
        final unseenCount = unseenReports.length;

        final visibleDecided = _hideReviewed
            ? decided.where((r) => !_viewedReportIds.contains(r.reportId)).toList()
            : decided;

        final items = <Object>[
          ...pending,
          ...visibleDecided,
        ];

        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          itemCount: items.length,
          itemBuilder: (ctx, i) {
            final item = items[i];
            if (item is _SectionDivider) return const SizedBox.shrink();
            final report = item as ReportModel;
            final isNew = (report.status == ReportStatus.validated ||
                report.status == ReportStatus.rejected) &&
                !_viewedReportIds.contains(report.reportId);
            final unseenIndex = unseenReports.indexOf(report);
            final unseenPosition = unseenIndex == -1 ? null : unseenIndex + 1;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ReportTrackerCard(
                report: report,
                unseenPosition: unseenPosition,
                unseenCount: unseenCount,
                isNew: isNew,
                onTap: () => _handleTrackerItemTap(report, unseenReports, isNew: isNew),
                onDelete: (reportId) async {
                  final doc = await FirebaseFirestore.instance
                      .collection('model_feedback')
                      .doc(reportId)
                      .get();
                  if (doc.exists) {
                    final data = doc.data() as Map<String, dynamic>;
                    final messageId = (data['messageId'] ?? data['messageTime'] ?? '').toString();
                    final sender    = (data['sender'] ?? '').toString();
                    await FirebaseFirestore.instance
                        .collection('model_feedback')
                        .doc(reportId)
                        .delete();
                    if (messageId.isNotEmpty) {
                      final p = await SharedPreferences.getInstance();
                      final inboxKey = 'report_status_${sender.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';
                      final inboxRaw = p.getString(inboxKey);
                      if (inboxRaw != null && inboxRaw.isNotEmpty) {
                        final map = (jsonDecode(inboxRaw) as Map).cast<String, String>();
                        map.remove(messageId);
                        await p.setString(inboxKey, jsonEncode(map));
                      }
                      final spamKey = 'spam_report_status_${sender.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';
                      final spamRaw = p.getString(spamKey);
                      if (spamRaw != null && spamRaw.isNotEmpty) {
                        final map = (jsonDecode(spamRaw) as Map).cast<String, String>();
                        map.remove(messageId);
                        await p.setString(spamKey, jsonEncode(map));
                      }
                    }
                  }
                },
                onMarkUnseen: () => _markReportUnseen(report.reportId),
              ),
            );
          },
        );
      },
    );
  }

  // ── Tap handler ────────────────────────────────────────────────────────────

  void _handleTrackerItemTap(
      ReportModel report,
      List<ReportModel> unseenReports, {
        bool isNew = false,
      }) {
    if (report.message.isNotEmpty) {
      widget.onOpenConversation?.call('', report.message);
    }
    if (isNew && !_dialogShownThisSession.contains(report.reportId)) {
      _dialogShownThisSession.add(report.reportId);
      Future.delayed(const Duration(milliseconds: 400), () {
        if (!mounted) return;
        _showReviewDialog(context, report, unseenReports);
      });
    }
  }

  // ── Review result dialog ───────────────────────────────────────────────────

  // ── Verification in progress dialog (for under_review reports) ────────────

  void _showVerifInProgressDialog(BuildContext ctx, ReportModel report) {
    showDialog(
      context: ctx,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(.35),
      builder: (dlgCtx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [BoxShadow(
                color: Colors.black.withOpacity(.15),
                blurRadius: 24,
                offset: const Offset(0, 8))],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
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
                  width: 56, height: 56,
                  decoration: BoxDecoration(
                      color: Colors.white.withOpacity(.15),
                      shape: BoxShape.circle),
                  child: const Icon(Icons.hourglass_top_rounded,
                      color: Colors.white, size: 28),
                ),
                const SizedBox(height: 12),
                const Text('Under Review',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
                const SizedBox(height: 4),
                Text('This report is being reviewed',
                    style: TextStyle(
                        fontSize: 13,
                        color: Colors.white.withOpacity(.8))),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF6F4EC),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFDDD8CE)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(report.sender,
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF555555))),
                      const SizedBox(height: 4),
                      Text(
                        report.message.length > 100
                            ? '${report.message.substring(0, 100)}…'
                            : report.message,
                        style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF888888),
                            height: 1.4),
                      ),
                    ]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(dlgCtx),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1A7A72),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    elevation: 0,
                  ),
                  child: const Text('Got it',
                      style: TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 15)),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // ── Review result dialog ───────────────────────────────────────────────────

  // ── Review result dialog with arrow navigation ─────────────────────────────

  void _showReviewDialog(
      BuildContext ctx,
      ReportModel report,
      List<ReportModel> unseenReports, {
        int? overrideIndex,
      }) {
    int currentIndex = overrideIndex ?? unseenReports.indexOf(report);
    if (currentIndex < 0) currentIndex = 0;
    final total = unseenReports.length;
    final current = currentIndex >= 0 && currentIndex < total
        ? unseenReports[currentIndex]
        : report;

    final isValidated = current.status == ReportStatus.validated;
    final isRejected  = current.status == ReportStatus.rejected;
    final reportedAsPhishing = current.reportType == ReportType.phishing;

    // Accepted = validated. Rejected = rejected.
    final accepted = isValidated;
    final color    = accepted ? const Color(0xFF1A7A72) : const Color(0xFFF2554F);

    // Action taken label
    final String actionTaken;
    if (accepted) {
      actionTaken = reportedAsPhishing
          ? 'Label updated to Safe.'
          : 'Label updated to Phishing.';
    } else {
      actionTaken = reportedAsPhishing
          ? 'Label remains Phishing.'
          : 'Label remains Safe.';
    }

    final reportedAsLabel = reportedAsPhishing ? 'Phishing' : 'Safe';

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

            // ── Header ────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
              child: Row(children: [
                Icon(
                    accepted ? Icons.check_circle : Icons.cancel,
                    color: color, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    total > 1
                        ? '$total Reports Reviewed'
                        : 'Report Reviewed',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
              ]),
            ),

            // ── Arrow navigation (only if multiple) ───────────────────────
            if (total > 1) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.chevron_left),
                      color: currentIndex > 0
                          ? const Color(0xFF1A7A72)
                          : const Color(0xFFCCCCCC),
                      onPressed: currentIndex > 0
                          ? () {
                        Navigator.pop(dlgCtx);
                        final prev = unseenReports[currentIndex - 1];
                        widget.onOpenConversation?.call(prev.sender, prev.messageId);
                        Future.delayed(const Duration(milliseconds: 350), () {
                          if (!mounted) return;
                          _showReviewDialog(context, prev, unseenReports,
                              overrideIndex: currentIndex - 1);
                        });
                      }
                          : null,
                    ),
                    Text(
                      '${currentIndex + 1} of $total',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_right),
                      color: currentIndex < total - 1
                          ? const Color(0xFF1A7A72)
                          : const Color(0xFFCCCCCC),
                      onPressed: currentIndex < total - 1
                          ? () {
                        Navigator.pop(dlgCtx);
                        final next = unseenReports[currentIndex + 1];
                        widget.onOpenConversation?.call(next.sender, next.messageId);
                        Future.delayed(const Duration(milliseconds: 350), () {
                          if (!mounted) return;
                          _showReviewDialog(context, next, unseenReports,
                              overrideIndex: currentIndex + 1);
                        });
                      }
                          : null,
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Color(0xFFEEEBE0)),
            ],

            // ── Message preview ───────────────────────────────────────────
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
                  current.message.length > 120
                      ? '${current.message.substring(0, 120)}…'
                      : current.message,
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFF333333), height: 1.5),
                ),
              ),
            ),

            // ── Details rows ──────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Column(children: [
                _dialogRow('Reported as:', reportedAsLabel, bold: true),
                const SizedBox(height: 8),
                _dialogRow('Reason:',
                    current.reason.isEmpty ? 'No reason provided' : current.reason),
                const SizedBox(height: 8),
                _dialogRow('Report Status:', accepted ? 'Accepted' : 'Rejected',
                    valueColor: color, valueIcon: accepted
                        ? Icons.check_circle
                        : Icons.cancel_outlined),
                const SizedBox(height: 8),
                _dialogRow('Action taken:', actionTaken),
              ]),
            ),

            // ── Got it button ─────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(dlgCtx);
                    _markReportViewed(current.reportId, report: current);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: color,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('Got it',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _dialogRow(String label, String value,
      {bool bold = false, Color? valueColor, IconData? valueIcon}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(label,
              style: const TextStyle(
                  fontSize: 13, color: Color(0xFF888888))),
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

  // ── Firebase write: mark viewed ────────────────────────────────────────────
  // This is the ONLY place we write to Firebase from the dialog.
  // It does NOT touch labels or status — those are admin-only fields.

  Future<void> _markReportViewed(String reportId, {ReportModel? report}) async {
    final p = await SharedPreferences.getInstance();
    _viewedReportIds.add(reportId);
    await p.setString(_viewedKey, jsonEncode(_viewedReportIds.toList()));
    if (mounted) setState(() {});
  }

  Future<void> _markReportUnseen(String reportId) async {
    final p = await SharedPreferences.getInstance();
    _viewedReportIds.remove(reportId);
    await p.setString(_viewedKey, jsonEncode(_viewedReportIds.toList()));
    if (mounted) setState(() {});
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _MergedDocs — payload emitted by the merged StreamController
// ─────────────────────────────────────────────────────────────────────────────

class _MergedDocs {
  final List<QueryDocumentSnapshot> active;
  final List<QueryDocumentSnapshot> reviewed;
  const _MergedDocs(this.active, this.reviewed);
}

// ─────────────────────────────────────────────────────────────────────────────
// _SectionDivider — marker used in the flat item list to render a labelled rule
// ─────────────────────────────────────────────────────────────────────────────

class _SectionDivider {
  final String label;
  const _SectionDivider({required this.label});
}

// ─────────────────────────────────────────────────────────────────────────────
// _ReportTrackerCard — individual card in the tracker list
// ─────────────────────────────────────────────────────────────────────────────

class _ReportTrackerCard extends StatefulWidget {
  final ReportModel report;
  final int? unseenPosition;
  final int unseenCount;
  final bool isNew;
  final VoidCallback onTap;
  final Future<void> Function(String reportId)? onDelete;
  final VoidCallback? onMarkUnseen;

  const _ReportTrackerCard({
    required this.report,
    required this.unseenPosition,
    required this.unseenCount,
    required this.isNew,
    required this.onTap,
    this.onDelete,
    this.onMarkUnseen,
  });

  @override
  State<_ReportTrackerCard> createState() => _ReportTrackerCardState();
}

class _ReportTrackerCardState extends State<_ReportTrackerCard> {
  late Timer _timer;
  late String _formattedDate;

  String _buildDate() {
    final now = DateTime.now();
    final dt  = widget.report.reportedAt.toLocal();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return 'Today, ${DateFormat('h:mm a').format(dt)}';
    if (diff.inDays == 1) return 'Yesterday, ${DateFormat('h:mm a').format(dt)}';
    return DateFormat('MMM d, h:mm a').format(dt);
  }

  @override
  void initState() {
    super.initState();
    _formattedDate = _buildDate();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _formattedDate = _buildDate());
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFF6F4EC),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(children: const [
          Icon(Icons.delete_outline, color: Color(0xFFF2554F), size: 22),
          SizedBox(width: 10),
          Text('Retract Report',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
        ]),
        content: const Text(
          'Are you sure you want to retract this report? It will be removed from your report history.',
          style: TextStyle(fontSize: 14, color: Color(0xFF555555), height: 1.5),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: Color(0xFF888888))),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF2554F),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Retract'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.onDelete?.call(widget.report.reportId);
    }
  }

  void _showLongPressSheet(BuildContext context) {
    final isUnderReview = widget.report.status == ReportStatus.underReview;
    final isReviewed    = !isUnderReview;
    final isAlreadySeen = !widget.isNew;

    // Only show sheet if under review OR (reviewed and already seen)
    if (isUnderReview) {
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        useRootNavigator: true,
        useSafeArea: false,
        builder: (_) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(24),
              topRight: Radius.circular(24),
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
            InkWell(
              onTap: () {
                Navigator.pop(context);
                _confirmDelete(context);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Row(children: [
                  Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF2554F).withOpacity(.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.delete_outline,
                        color: Color(0xFFF2554F), size: 20),
                  ),
                  const SizedBox(width: 16),
                  const Text('Retract report',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFFF2554F))),
                ]),
              ),
            ),
            const SizedBox(height: 8),
          ]),
        ),
      );
    } else if (isReviewed && isAlreadySeen) {
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        useRootNavigator: true,
        useSafeArea: false,
        builder: (_) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(24),
              topRight: Radius.circular(24),
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
            InkWell(
              onTap: () {
                Navigator.pop(context);
                widget.onMarkUnseen?.call();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Row(children: [
                  Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A7A72).withOpacity(.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.mark_email_unread_outlined,
                        color: Color(0xFF1A7A72), size: 20),
                  ),
                  const SizedBox(width: 16),
                  const Text('Mark as unseen',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: Colors.black87)),
                ]),
              ),
            ),
            const SizedBox(height: 8),
          ]),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isUnderReview = widget.report.status == ReportStatus.underReview;
    final isValidated   = widget.report.status == ReportStatus.validated;
    final hasUnseen     = widget.isNew;

    final reportType       = widget.report.reportType;
    final isPhishingReport = reportType == ReportType.phishing;
    final chipColor        = isPhishingReport
        ? const Color(0xFF1A7A72)
        : const Color(0xFFF2554F);
    final chipLabel = isPhishingReport ? 'Safe Report' : 'Phishing Report';

    final statusIcon = isUnderReview
        ? Icons.hourglass_bottom_rounded
        : isValidated
        ? Icons.verified_rounded
        : Icons.cancel_outlined;
    final statusLabel = isUnderReview
        ? 'Under Review'
        : isValidated
        ? 'Verified'
        : 'Rejected';
    final statusColor = isUnderReview
        ? const Color(0xFF888888)
        : isValidated
        ? const Color(0xFF1A7A72)
        : const Color(0xFFF2554F);

    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: () => _showLongPressSheet(context),
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE8E4DA)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // ── Top row: chip + NEW badge + date + delete ─────────────────
            Row(children: [
              Container(
                padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: chipColor.withOpacity(.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  chipLabel,
                  style: TextStyle(
                      fontSize: 11,
                      color: chipColor,
                      fontWeight: FontWeight.w600),
                ),
              ),
              if (hasUnseen) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A5C56),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    const Text(
                      'New',
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.white,
                          fontWeight: FontWeight.w700),
                    ),
                  ]),
                ),
              ],
              const Spacer(),
              // ── Real-time date + delete button ────────────────────────
              Text(
                _formattedDate,
                style: const TextStyle(fontSize: 12, color: Color(0xFF999999)),
              ),
              if (widget.onDelete != null) ...[
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: () => _confirmDelete(context),
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    child: const Icon(
                      Icons.delete_outline,
                      size: 17,
                      color: Color(0xFFCCCCCC),
                    ),
                  ),
                ),
              ],
            ]),

            const SizedBox(height: 12),

            // ── Message text ──────────────────────────────────────────────
            Text(
              widget.report.message.length > 120
                  ? '${widget.report.message.substring(0, 120)}…'
                  : widget.report.message,
              style: const TextStyle(
                  fontSize: 15, color: Colors.black87, height: 1.4),
            ),

            const SizedBox(height: 6),

            // ── Reason ────────────────────────────────────────────────────
            Row(children: [
              const Icon(Icons.format_quote_rounded,
                  size: 14, color: Color(0xFFAAAAAA)),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  widget.report.reason.isEmpty
                      ? 'No reason provided'
                      : widget.report.reason,
                  style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF888888),
                      fontStyle: FontStyle.italic),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),

            const SizedBox(height: 12),
            const Divider(height: 1, color: Color(0xFFEEEBE0)),
            const SizedBox(height: 10),

            // ── Status pill ───────────────────────────────────────────────
            Container(
              padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                border:
                Border.all(color: statusColor.withOpacity(.5)),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(statusIcon, size: 13, color: statusColor),
                const SizedBox(width: 5),
                Text(
                  statusLabel,
                  style: TextStyle(
                      fontSize: 12,
                      color: statusColor,
                      fontWeight: FontWeight.w600),
                ),
              ]),
            ),

            const SizedBox(height: 6),

            if (isUnderReview)
              const Text('Waiting for team validation',
                  style:
                  TextStyle(fontSize: 13, color: Color(0xFF888888))),
            if (!isUnderReview)
              (() {
                final isPhishingReport =
                    widget.report.reportType == ReportType.phishing;
                final actionLabel = isPhishingReport
                    ? (isValidated
                    ? 'Label updated to Safe.'
                    : 'Label remains Phishing.')
                    : (isValidated
                    ? 'Label updated to Phishing.'
                    : 'Label remains Safe.');
                return Text(actionLabel,
                    style: TextStyle(
                        fontSize: 13,
                        color: statusColor,
                        fontWeight: FontWeight.w500));
              })(),
          ]),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ReportTrackerPage — standalone full-page version (if needed)
// ─────────────────────────────────────────────────────────────────────────────

class ReportTrackerPage extends StatelessWidget {
  final String deviceId;
  final String source;
  final void Function(String sender, String messageId)? onOpenConversation;

  const ReportTrackerPage({
    super.key,
    required this.deviceId,
    required this.source,
    this.onOpenConversation,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F4EC),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A7A72),
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Report Tracker',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
      ),
      body: ReportTrackerBody(
        deviceId: deviceId,
        source: source,
        onOpenConversation: onOpenConversation,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// submitReport — creates a properly structured report document in Firestore.
// Call this instead of the old _submitReport helper.
// ─────────────────────────────────────────────────────────────────────────────

Future<void> submitReport({
  required String messageBody,
  required String originalLabel,
  required double confidence,
  required String reason,
  String deviceId  = '',
  String sender    = '',
  String messageId = '',
  String source    = 'inbox',
}) async {
  try {
    final messageHash = sha256
        .convert(utf8.encode(messageBody))
        .toString();

    final correctedLabel = originalLabel.toLowerCase() == 'phishing'
        ? 'legitimate'
        : 'phishing';

    await FirebaseFirestore.instance
        .collection('model_feedback')
        .add({
      'confidence'    : confidence,
      'correctedLabel': correctedLabel,
      'messageBody'   : messageBody,
      'messageHash'   : messageHash,
      'originalLabel' : originalLabel,
      'reason'        : reason,
      'status'        : 'pending',
      'timestamp'     : FieldValue.serverTimestamp(),
      'type'          : 'inaccurate_report',
    });
  } catch (e) {
    debugPrint('submitReport failed: $e');
  }
}