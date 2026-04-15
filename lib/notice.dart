import 'package:flutter/material.dart';

class NoticeDialog extends StatefulWidget {
  final VoidCallback onAccept;
  final VoidCallback onClose;

  const NoticeDialog({
    super.key,
    required this.onAccept,
    required this.onClose,
  });

  static Future<void> show(
      BuildContext context, {
        required VoidCallback onAccept,
        required VoidCallback onClose,
      }) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => NoticeDialog(
        onAccept: onAccept,
        onClose: onClose,
      ),
    );
  }

  @override
  State<NoticeDialog> createState() => _NoticeDialogState();
}

class _NoticeDialogState extends State<NoticeDialog> {

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A7A72).withOpacity(0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.privacy_tip_outlined,
                    color: Color(0xFF1A7A72),
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Data Usage Notice',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                ),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: widget.onClose,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.grey.withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close,
                        size: 18,
                        color: Colors.grey,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.55,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'PhishSense performs manual message scanning to help detect phishing attempts.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[600],
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 14),
                    const _DataPointRow(
                      number: '1',
                      title: 'Manual Scanning',
                      detail:
                          'PhishSense only analyzes messages that you manually paste into the app. We do not access or monitor your SMS automatically.',
                    ),
                    const SizedBox(height: 10),
                    const _DataPointRow(
                      number: '2',
                      title: 'On-Device Privacy',
                      detail:
                          'Your scanned messages are stored locally on your device unless you choose to delete them. We do not collect or access your personal conversations.',
                    ),
                    const SizedBox(height: 10),
                    const _DataPointRow(
                      number: '3',
                      title: 'Model Improvement',
                      detail:
                          'You may optionally submit anonymous feedback on scan results to help improve our detection model. No personal data is included.',
                    ),
                    
                    const SizedBox(height: 10),

                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A7A72).withOpacity(0.07),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.lock_outline,
                            size: 16,
                            color: Color(0xFF1A7A72),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'All sensitive data is processed locally. We do not sell or share your personal information with third parties.',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[700],
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),

            Center(
              child: ElevatedButton(
                onPressed: widget.onAccept, // ALWAYS ENABLED
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A7A72),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                  elevation: 4,
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                ),
                child: const Text(
                  'I Understand & Accept',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
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

class _DataPointRow extends StatelessWidget {
  final String number;
  final String title;
  final String detail;

  const _DataPointRow({
    required this.number,
    required this.title,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: const Color(0xFFE0A800),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Center(
            child: Text(
              number,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1A1A),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                detail,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[600],
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
