import 'package:flutter/material.dart';

class PrivacyPolicyDialog {
  static void show(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        child: Container(
          padding: const EdgeInsets.all(20),
          height: 450,
          child: Column(
            children: [
              const Text(
                "Privacy & Policy",
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A7A72),
                ),
              ),

              const SizedBox(height: 10),

              const Expanded(
                child: SingleChildScrollView(
                  child: Text(
                    '''
Last Updated: March 2026

PhishSense respects your privacy. This app is designed to help detect phishing messages while protecting user data.

Information We Collect
• SMS Permission – Used to scan incoming messages for phishing threats.
• Contacts Permission – Helps identify messages from known contacts.
• Notification Permission – Used to alert users when suspicious messages are detected.

How We Use Your Information
• Detect phishing or scam messages
• Provide security alerts
• Improve phishing detection accuracy

Data Privacy
PhishSense does not sell or share personal data. Message analysis is performed only to detect phishing threats.

Anonymous Data
If enabled, the app may collect anonymous detection results to improve system performance.

User Control
Users can manage permissions anytime through the device settings.

Changes to This Policy
This policy may be updated when necessary.

Thank you for using PhishSense.
''',
                    style: TextStyle(fontSize: 14),
                  ),
                ),
              ),

              const SizedBox(height: 10),

              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A7A72),
                ),
                onPressed: () {
                  Navigator.pop(context);
                },
                child: const Text("Close",
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                    color: Colors.white,
                  )
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}