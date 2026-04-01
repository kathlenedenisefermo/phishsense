import 'package:flutter/material.dart';

enum PermissionType { sms, contacts, notification }

class PermissionPage extends StatelessWidget {
  final PermissionType type;
  final VoidCallback onAllow;
  final VoidCallback onDeny;

  const PermissionPage({
    super.key,
    required this.type,
    required this.onAllow,
    required this.onDeny,
  });

  static Future<void> show(
      BuildContext context, {
        required PermissionType type,
        required VoidCallback onAllow,
        required VoidCallback onDeny,
      }) {
    return showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      backgroundColor: const Color(0xFFF2F2F2),
      isScrollControlled: true,
      builder: (sheetContext) => PermissionPage(
        type: type,
        onAllow: () {
          Navigator.pop(sheetContext);
          onAllow();
        },
        onDeny: () {
          Navigator.pop(sheetContext);
          onDeny();
        },
      ),
    );
  }

  _PermissionContent get _content {
    switch (type) {
      case PermissionType.sms:
        return _PermissionContent(
          icon: Icons.sms_outlined,
          iconColor: const Color(0xFF1A7A72),
          title: 'Allow SMS Access',
          description:
          'PhishSense needs to read your incoming SMS messages to analyze and detect potential phishing threats in real-time.',
          denyText: "Don't Allow",
        );

      case PermissionType.contacts:
        return _PermissionContent(
          icon: Icons.contacts_outlined,
          iconColor: const Color(0xFF1A7A72),
          title: 'Allow Contacts Access',
          description:
          'PhishSense uses your contacts list to identify trusted senders and reduce false positives in threat detection.',
          denyText: "Don't Allow",
        );

      case PermissionType.notification:
        return _PermissionContent(
          icon: Icons.notifications_outlined,
          iconColor: const Color(0xFFE0A800),
          title: 'Allow Notifications',
          description:
          'PhishSense will send you instant alerts when a suspicious message is detected, even when the app is in the background.',
          denyText: "Not Now",
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = _content;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(28, 28, 28, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: content.iconColor.withOpacity(0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(content.icon, size: 40, color: content.iconColor),
          ),
          const SizedBox(height: 20),
          RichText(
            text: const TextSpan(
              children: [
                TextSpan(
                  text: 'Phish',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A7A72),
                    fontSize: 14,
                  ),
                ),
                TextSpan(
                  text: 'Sense',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFE0A800),
                    fontSize: 14,
                  ),
                ),
                TextSpan(
                  text: ' is requesting permission',
                  style: TextStyle(
                    color: Color(0xFF888880),
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            content.title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A1A),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            content.description,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[600],
              height: 1.5,
            ),
          ),
          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: onAllow,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1A7A72),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
              child: const Text(
                'Allow',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: OutlinedButton(
              onPressed: onDeny,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.grey[600],
                side: BorderSide(color: Colors.grey.shade300),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Text(
                content.denyText,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionContent {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String description;
  final String denyText;

  _PermissionContent({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.description,
    required this.denyText,
  });
}