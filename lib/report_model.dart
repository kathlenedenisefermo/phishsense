import 'package:cloud_firestore/cloud_firestore.dart';

enum ReportStatus { underReview, validated, rejected }

enum ReportType { phishing, safe }

class ReportModel {
  final String reportId;
  final String message;
  final String originalLabel;
  final String correctedLabel;
  final double confidence;
  final String reason;
  final ReportStatus status;
  final DateTime reportedAt;
  final String type;

  const ReportModel({
    required this.reportId,
    required this.message,
    required this.originalLabel,
    required this.correctedLabel,
    required this.confidence,
    required this.reason,
    required this.status,
    required this.reportedAt,
    required this.type,
  });

  // Derived getters — computed from the 9 fields
  String get messageId => '';
  String get deviceId  => '';
  String get sender    => 'Unknown';
  String get source    => 'inbox';
  bool   get isViewed  => false;
  DateTime? get reviewedAt => null;
  String? get decision => null;

  ReportType get reportType =>
      correctedLabel == 'phishing' ? ReportType.phishing : ReportType.safe;

  String? get reviewedLabel {
    if (status == ReportStatus.underReview) return null;
    final wasPhishing = originalLabel.toLowerCase() == 'phishing';
    final validated   = status == ReportStatus.validated;
    if (wasPhishing) return validated ? 'Safe'     : 'Phishing';
    else             return validated ? 'Phishing' : 'Safe';
  }

  bool get hasUnseenReview =>
      status == ReportStatus.validated || status == ReportStatus.rejected;

  String get statusLabel {
    switch (status) {
      case ReportStatus.underReview: return 'Under Review';
      case ReportStatus.validated:   return 'Verified';
      case ReportStatus.rejected:    return 'Rejected';
    }
  }

  factory ReportModel.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;

    ReportStatus parseStatus(String? s) {
      switch (s) {
        case 'trained':
        case 'verified':
        case 'validated': return ReportStatus.validated;
        case 'rejected':  return ReportStatus.rejected;
        default:          return ReportStatus.underReview;
      }
    }

    return ReportModel(
      reportId      : doc.id,
      message       : d['messageBody'] as String? ?? '',
      originalLabel : d['originalLabel'] as String? ?? '',
      correctedLabel: d['correctedLabel'] as String? ?? '',
      confidence    : (d['confidence'] as num?)?.toDouble() ?? 0.0,
      reason        : d['reason'] as String? ?? '',
      status        : parseStatus(d['status'] as String?),
      reportedAt    : (d['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
      type          : d['type'] as String? ?? 'inaccurate_report',
    );
  }
}