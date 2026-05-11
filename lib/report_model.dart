import 'package:cloud_firestore/cloud_firestore.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ReportModel — single source of truth from Firestore
// ─────────────────────────────────────────────────────────────────────────────

enum ReportStatus { underReview, validated, rejected }

enum ReportType { phishing, safe }

class ReportModel {
  final String reportId;
  final String messageId;   // matches message['time'] used as unique key
  final String deviceId;
  final String sender;
  final String message;
  final ReportType reportType;       // what the user claimed
  final ReportStatus status;
  final String? decision;            // 'validated' | 'rejected' — set by admin
  final String? reviewedLabel;       // 'safe' | 'phishing' — final label from admin
  final DateTime? reviewedAt;
  final bool isViewed;               // user has pressed "Got it"
  final DateTime reportedAt;
  final String source;               // 'inbox' | 'spam'
  final String reason;

  const ReportModel({
    required this.reportId,
    required this.messageId,
    required this.deviceId,
    required this.sender,
    required this.message,
    required this.reportType,
    required this.status,
    this.decision,
    this.reviewedLabel,
    this.reviewedAt,
    required this.isViewed,
    required this.reportedAt,
    required this.source,
    required this.reason,
  });

  /// Whether this report has been reviewed and the user hasn't seen the result yet.
  bool get hasUnseenReview =>
      (status == ReportStatus.validated || status == ReportStatus.rejected) &&
          !isViewed;

  /// Human-readable status label for the tracker UI.
  String get statusLabel {
    switch (status) {
      case ReportStatus.underReview:
        return 'Under Review';
      case ReportStatus.validated:
        return 'Verified';
      case ReportStatus.rejected:
        return 'Rejected';
    }
  }

  factory ReportModel.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;

    ReportStatus parseStatus(String? s) {
      switch (s) {
        case 'verified':
        case 'validated':
          return ReportStatus.validated;
        case 'rejected':
          return ReportStatus.rejected;
        default:
          return ReportStatus.underReview;
      }
    }

    ReportType parseType(String? t) {
      return t == 'safe' ? ReportType.safe : ReportType.phishing;
    }

    return ReportModel(
      reportId: doc.id,
      messageId: d['messageId'] as String? ?? '',
      deviceId: d['deviceId'] as String? ?? '',
      sender: d['sender'] as String? ?? 'Unknown',
      message: d['message'] as String? ?? '',
      reportType: parseType(d['reportType'] as String?),
      status: parseStatus(d['status'] as String?),
      decision: d['decision'] as String?,
      reviewedLabel: d['reviewedLabel'] as String?,
      reviewedAt: (d['reviewedAt'] as Timestamp?)?.toDate(),
      isViewed: d['isViewed'] as bool? ?? false,
      reportedAt: (d['reportedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      source: d['source'] as String? ?? 'inbox',
      reason: d['reason'] as String? ?? '',
    );
  }

  Map<String, dynamic> toFirestore() => {
    'messageId': messageId,
    'deviceId': deviceId,
    'sender': sender,
    'message': message,
    'reportType': reportType == ReportType.phishing ? 'phishing' : 'safe',
    'status': status == ReportStatus.underReview
        ? 'under_review'
        : status == ReportStatus.validated
        ? 'validated'
        : 'rejected',
    'decision': decision,
    'reviewedLabel': reviewedLabel,
    'reviewedAt': reviewedAt != null ? Timestamp.fromDate(reviewedAt!) : null,
    'isViewed': isViewed,
    'reportedAt': Timestamp.fromDate(reportedAt),
    'source': source,
    'reason': reason,
  };
}