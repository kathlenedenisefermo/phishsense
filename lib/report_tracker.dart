import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'report_model.dart';

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
  final String source; // 'inbox' | 'spam'
  final void Function(String sender, String messageId)? onOpenConversation;

  const ReportTrackerBody({
    super.key,
    required this.deviceId,
    required this.source,
    this.onOpenConversation,
  });

  @override
  State<ReportTrackerBody> createState() => _ReportTrackerBodyState();
}

class _ReportTrackerBodyState extends State<ReportTrackerBody> {
  final Map<String, ReportStatus> _prevStatus = {};
  final Set<String> _dialogShownThisSession = {};

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
  }

  void _subscribeStreams() {
    final fs = FirebaseFirestore.instance;
    _activeSub = fs
        .collection('reports')
        .where('deviceId', isEqualTo: widget.deviceId)
        .where('source', isEqualTo: widget.source)
        .snapshots()
        .listen((snap) {
      _activeDocs = snap.docs;
      _emitMerged();
    });
    _reviewedSub = fs
        .collection('reviewed')
        .where('deviceId', isEqualTo: widget.deviceId)
        .where('source', isEqualTo: widget.source)
        .snapshots()
        .listen((snap) {
      _reviewedDocs = snap.docs;
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
          child: CircularProgressIndicator(color: Color(0xFF1A7A72)));
    }
    return StreamBuilder<_MergedDocs>(
      stream: _mergedController.stream,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(
              child: CircularProgressIndicator(color: Color(0xFF1A7A72)));
        }

        const reviewedStatuses = {'verified', 'validated', 'rejected'};
        final allDocs = <QueryDocumentSnapshot>[
          ...snap.data!.active,
          ...snap.data!.reviewed,
        ];

        List<QueryDocumentSnapshot> sortByDate(List<QueryDocumentSnapshot> docs) =>
            docs..sort((a, b) {
              final aT = (a.data() as Map<String, dynamic>)['reportedAt'] as Timestamp?;
              final bT = (b.data() as Map<String, dynamic>)['reportedAt'] as Timestamp?;
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
          ...pending.where((r) => r.hasUnseenReview),
          ...decided.where((r) => r.hasUnseenReview),
        ];
        final unseenCount = unseenReports.length;

        final items = <Object>[
          ...pending,
          if (decided.isNotEmpty) const _SectionDivider(label: 'Reviewed'),
          ...decided,
        ];

        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          itemCount: items.length,
          itemBuilder: (ctx, i) {
            final item = items[i];
            if (item is _SectionDivider) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 0, 12),
                child: Row(children: [
                  const Expanded(child: Divider(color: Color(0xFFDDD8CE))),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      item.label,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF999999),
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const Expanded(child: Divider(color: Color(0xFFDDD8CE))),
                ]),
              );
            }
            final report = item as ReportModel;
            final unseenIndex = unseenReports.indexOf(report);
            final unseenPosition = unseenIndex == -1 ? null : unseenIndex + 1;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ReportTrackerCard(
                report: report,
                unseenPosition: unseenPosition,
                unseenCount: unseenCount,
                isNew: report.hasUnseenReview,
                onTap: () => _handleTrackerItemTap(report, unseenReports),
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
      List<ReportModel> unseenReports,
      ) async {
    if (widget.onOpenConversation != null) {
      widget.onOpenConversation!(report.sender, report.messageId);
    }
    await Future.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;

    if (report.hasUnseenReview) {
      if (!_dialogShownThisSession.contains(report.reportId)) {
        _dialogShownThisSession.add(report.reportId);
        try {
          final firestore = FirebaseFirestore.instance;
          final results = await Future.wait([
            firestore
                .collection('reports')
                .where('deviceId', isEqualTo: widget.deviceId)
                .where('isViewed', isEqualTo: false)
                .get(),
            firestore
                .collection('reviewed')
                .where('deviceId', isEqualTo: widget.deviceId)
                .where('isViewed', isEqualTo: false)
                .get(),
          ]);
          final allUnseen = [
            ...results[0].docs,
            ...results[1].docs,
          ]
              .map((d) => ReportModel.fromFirestore(d))
              .where((r) => r.hasUnseenReview)
              .toList();
          if (mounted) _showReviewDialog(context, report, allUnseen.isNotEmpty ? allUnseen : unseenReports);
        } catch (_) {
          if (mounted) _showReviewDialog(context, report, unseenReports);
        }
      }
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
    try {
      final firestore = FirebaseFirestore.instance;
      final reportRef   = firestore.collection('reports').doc(reportId);
      final reviewedRef = firestore.collection('reviewed').doc(reportId);

      // Resolve new label and derive which tab the report now belongs in.
      // Phishing → spam tab, Safe → inbox tab. Only update source when the
      // label actually flips (verified decision); rejected keeps original source.
      final update = <String, dynamic>{'isViewed': true};
      if (report != null) {
        final newLabel = resolveLabel(report);
        if (newLabel == 'Phishing') update['source'] = 'spam';
        else if (newLabel == 'Safe') update['source'] = 'inbox';
      }

      final snap = await reportRef.get();
      if (snap.exists) {
        await reportRef.update(update);
      } else {
        await reviewedRef.update(update);
      }

      if (report != null) {
        final newLabel = resolveLabel(report);
        if (newLabel.isNotEmpty && report.messageId.isNotEmpty) {
          await _applyLabelLocally(
            messageId: report.messageId,
            newLabel: newLabel,
          );
        }
      }
    } catch (e) {
      debugPrint('Failed to mark report viewed: $e');
    }
  }

  Future<void> _applyLabelLocally({
    required String messageId,
    required String newLabel,
  }) async {
    try {
      final p = await SharedPreferences.getInstance();
      const manualKey = 'manual_scan_logs';
      const spamKey = 'spam_folder_logs';

      final manRaw = p.getString(manualKey);
      if (manRaw != null && manRaw.isNotEmpty) {
        final man = (jsonDecode(manRaw) as List).cast<Map<String, dynamic>>();
        bool changed = false;
        for (final m in man) {
          if (m['time']?.toString() == messageId) {
            m['label'] = newLabel;
            changed = true;
          }
        }
        if (changed) await p.setString(manualKey, jsonEncode(man));
      }

      final spamRaw = p.getString(spamKey);
      if (spamRaw != null && spamRaw.isNotEmpty) {
        final spam = (jsonDecode(spamRaw) as List).cast<Map<String, dynamic>>();
        bool changed = false;
        for (final m in spam) {
          if (m['time']?.toString() == messageId) {
            m['label'] = newLabel;
            changed = true;
          }
        }
        if (changed) await p.setString(spamKey, jsonEncode(spam));
      }
    } catch (e) {
      debugPrint('Failed to apply label locally: $e');
    }
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

class _ReportTrackerCard extends StatelessWidget {
  final ReportModel report;
  final int? unseenPosition;
  final int unseenCount;
  final bool isNew;
  final VoidCallback onTap;

  const _ReportTrackerCard({
    required this.report,
    required this.unseenPosition,
    required this.unseenCount,
    required this.isNew,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isUnderReview = report.status == ReportStatus.underReview;
    final isValidated   = report.status == ReportStatus.validated;
    final hasUnseen     = isNew;

    // Report type label chip color
    final reportType        = report.reportType;
    final isPhishingReport  = reportType == ReportType.phishing;
    final chipColor         = isPhishingReport
        ? const Color(0xFF1A7A72)
        : const Color(0xFFF2554F);
    final chipLabel         = isPhishingReport ? 'Safe Report' : 'Phishing Report';

    // Status
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

    // Date
    final formattedDate = report.reviewedAt != null
        ? (() {
      final now = DateTime.now();
      final dt  = report.reportedAt.toLocal();
      final diff = now.difference(dt);
      if (diff.inDays == 0) return 'Today, ${DateFormat('h:mm a').format(dt)}';
      if (diff.inDays == 1) return 'Yesterday, ${DateFormat('h:mm a').format(dt)}';
      return DateFormat('MMM d, h:mm a').format(dt);
    })()
        : (() {
      final now  = DateTime.now();
      final dt   = report.reportedAt.toLocal();
      final diff = now.difference(dt);
      if (diff.inDays == 0) return 'Today, ${DateFormat('h:mm a').format(dt)}';
      if (diff.inDays == 1) return 'Yesterday, ${DateFormat('h:mm a').format(dt)}';
      return DateFormat('MMM d, h:mm a').format(dt);
    })();

    return GestureDetector(
      onTap: onTap,
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
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

            // ── Top row: report type chip + NEW badge + date ──────────────
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A7A72).withOpacity(.75),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    'NEW',
                    style: const TextStyle(
                        fontSize: 10,
                        color: Colors.white,
                        fontWeight: FontWeight.w700),
                  ),
                ),
              ],
              const Spacer(),
              Text(
                formattedDate,
                style: const TextStyle(fontSize: 12, color: Color(0xFF999999)),
              ),
            ]),

            const SizedBox(height: 12),

            // ── Message text ──────────────────────────────────────────────
            Text(
              report.message.length > 120
                  ? '${report.message.substring(0, 120)}…'
                  : report.message,
              style: const TextStyle(
                  fontSize: 15,
                  color: Colors.black87,
                  height: 1.4),
            ),

            const SizedBox(height: 6),

            // ── Reason ────────────────────────────────────────────────────
            Row(children: [
              const Icon(Icons.format_quote_rounded,
                  size: 14, color: Color(0xFFAAAAAA)),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  report.reason.isEmpty ? 'No reason provided' : report.reason,
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

            // ── Status row ────────────────────────────────────────────────
            Row(children: [
              Icon(statusIcon, size: 15, color: statusColor),
              const SizedBox(width: 6),
              Text(
                statusLabel,
                style: TextStyle(
                    fontSize: 13,
                    color: statusColor,
                    fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (isUnderReview)
                const Text(
                  'Waiting for team validation',
                  style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
                ),
              if (!isUnderReview && report.reviewedLabel != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: report.reviewedLabel!.toLowerCase() == 'phishing'
                        ? const Color(0xFFF2554F)
                        : const Color(0xFF1A7A72),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    report.reviewedLabel!.toLowerCase() == 'phishing'
                        ? 'Phishing'
                        : 'Safe',
                    style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white,
                        fontWeight: FontWeight.w600),
                  ),
                ),
            ]),
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
  required String sender,
  required String message,
  required String messageId,   // use message['time'] as the unique id
  required String reportType,  // 'phishing' | 'safe'
  required String reason,
  required String source,      // 'inbox' | 'spam'
  required String deviceId,
}) async {
  try {
    await FirebaseFirestore.instance.collection('reports').add({
      'sender': sender,
      'message': message,
      'messageId': messageId,
      'reportType': reportType,
      'reason': reason,
      'source': source,
      'deviceId': deviceId,
      // Admin-set fields — initialised to null/defaults
      'status': 'under_review',
      'decision': null,
      'reviewedLabel': null,
      'reviewedAt': null,
      // User view state
      'isViewed': false,
      'reportedAt': FieldValue.serverTimestamp(),
    });
  } catch (e) {
    debugPrint('submitReport failed: $e');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// updateReportStatus — updates a report's status and moves it to the
// `reviewed` collection when the status is verified, validated, or rejected.
// ─────────────────────────────────────────────────────────────────────────────

Future<void> updateReportStatus({
  required String reportId,
  required String newStatus,
}) async {
  try {
    final firestore = FirebaseFirestore.instance;
    final reportRef = firestore.collection('reports').doc(reportId);
    final snap = await reportRef.get();
    if (!snap.exists) return;

    final data = Map<String, dynamic>.from(snap.data()!);
    data['status'] = newStatus;
    data['reviewedAt'] = Timestamp.now();

    const reviewedStatuses = ['verified', 'validated', 'rejected'];
    if (reviewedStatuses.contains(newStatus)) {
      data['movedToReviewedAt'] = Timestamp.now();
      await firestore.collection('reviewed').doc(reportId).set(data);
      await reportRef.delete();
    } else {
      await reportRef.update({
        'status': newStatus,
        'reviewedAt': Timestamp.now(),
      });
    }
  } catch (e) {
    debugPrint('updateReportStatus failed: $e');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// applyFirebaseLabel — reads the latest reviewed label for a messageId
// from Firestore and applies it to local SharedPreferences storage.
//
// Call this from your global listener in IOSMessagesPage when a report
// transitions to validated or rejected.
// ─────────────────────────────────────────────────────────────────────────────

// Label update logic — pure function, no side effects.
// Given a report, returns the label the message should now display.
String resolveLabel(ReportModel report) {
  // While under review:
  // DO NOT change the label yet.
  // Caller should continue using the existing/current message label.
  if (report.status == ReportStatus.underReview) {
    return '';
  }


  final reportedPhishing =
      report.reportType == ReportType.phishing;

  final validated =
      report.status == ReportStatus.validated;

  // CASE 1:
  // Safe message reported as phishing
  //
  // validated -> phishing
  // rejected  -> safe

  // CASE 2:
  // Phishing message reported as safe
  //
  // validated -> safe
  // rejected  -> phishing

  if (reportedPhishing) {
    // User reported as phishing (original label was Safe)
    // verified → Phishing confirmed   rejected → stays Safe
    return validated ? 'Phishing' : 'Safe';
  } else {
    // User reported as safe (original label was Phishing)
    // verified → Safe confirmed   rejected → stays Phishing
    return validated ? 'Safe' : 'Phishing';
  }
}