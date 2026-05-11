import 'package:flutter/material.dart';

class PrivacyPolicyDialog {
  static void show(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF6F7F5),
            borderRadius: BorderRadius.circular(28),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [

              /// TOP HEADER
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 28),
                decoration: const BoxDecoration(
                  color: Color(0xFF0F8A7B),
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(28),
                  ),
                ),
                child: Column(
                  children: const [
                    CircleAvatar(
                      radius: 32,
                      backgroundColor: Color(0x339FFFFFF),
                      child: Icon(
                        Icons.shield_outlined,
                        color: Colors.white,
                        size: 34,
                      ),
                    ),

                    SizedBox(height: 14),

                    Text(
                      "Privacy Policy",
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),

              /// BODY
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [

                      /// INFO BOX
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEAF4F1),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: const Color(0xFFD2E6DF),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: const [
                            Icon(
                              Icons.info_outline,
                              color: Color(0xFF0F8A7B),
                            ),

                            SizedBox(width: 12),

                            Expanded(
                              child: Text(
                                "PhishSense is built to protect you — not to collect your data. Here's exactly what happens with your information.",
                                style: TextStyle(
                                  fontSize: 15,
                                  height: 1.5,
                                  color: Color(0xFF29524A),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 26),

                      /// PERMISSIONS
                      _sectionTitle(
                        Icons.checklist_rounded,
                        "Permissions We Request",
                      ),

                      const SizedBox(height: 14),

                      _bullet(
                        "SMS",
                        "Scans incoming messages on your device to detect phishing threats.",
                      ),

                      _bullet(
                        "Contacts",
                        "Identifies messages from known contacts for better context.",
                      ),

                      _bullet(
                        "Notifications",
                        "Alerts you when a suspicious message is detected.",
                      ),

                      const SizedBox(height: 30),

                      /// LOCAL SCANNING
                      _sectionTitle(
                        Icons.phone_android_rounded,
                        "All Scanning Stays on Your Device",
                      ),

                      const SizedBox(height: 12),

                      const Text(
                        "PhishSense does not collect, store, or transmit your SMS messages. Every message is scanned locally using an on-device AI model — your conversations never leave your phone.",
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.7,
                          color: Color(0xFF444444),
                        ),
                      ),

                      const SizedBox(height: 30),

                      /// SERVERS
                      _sectionTitle(
                        Icons.cloud_outlined,
                        "What Gets Sent to Our Servers",
                      ),

                      const SizedBox(height: 12),

                      const Text(
                        "The only data ever sent is feedback you choose to submit by tapping “Report as inaccurate.” This includes:",
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.7,
                          color: Color(0xFF444444),
                        ),
                      ),

                      const SizedBox(height: 14),

                      _simpleBullet("The reported message text"),
                      _simpleBullet(
                        "The original detection result (phishing or safe)",
                      ),
                      _simpleBullet(
                        "Your correction and the reason you selected",
                      ),

                      const SizedBox(height: 16),

                      const Text(
                        "This feedback is voluntary, used only to improve detection accuracy, and is never linked to your identity, phone number, or personal information.",
                        style: TextStyle(
                          fontSize: 14,
                          fontStyle: FontStyle.italic,
                          height: 1.6,
                          color: Color(0xFF7A7A7A),
                        ),
                      ),

                      const SizedBox(height: 30),

                      /// USER CONTROL
                      _sectionTitle(
                        Icons.tune_rounded,
                        "Your Control",
                      ),

                      const SizedBox(height: 14),

                      _simpleBullet(
                        "Manage or revoke any permission at any time through your device settings.",
                      ),

                      _simpleBullet(
                        "Feedback reports are entirely optional — you are never required to submit one.",
                      ),

                      const SizedBox(height: 40),

                      const Center(
                        child: Text(
                          "Thank you for using PhishSense.",
                          style: TextStyle(
                            fontSize: 15,
                            fontStyle: FontStyle.italic,
                            color: Color(0xFF7A7A7A),
                          ),
                        ),
                      ),

                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),

              /// BUTTON
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
                child: SizedBox(
                  width: double.infinity,
                  height: 58,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0F8A7B),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    onPressed: () {
                      Navigator.pop(context);
                    },
                    child: const Text(
                      "Got It",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _sectionTitle(IconData icon, String title) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFFEAF4F1),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(
            icon,
            color: const Color(0xFF0F8A7B),
            size: 22,
          ),
        ),

        const SizedBox(width: 14),

        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1E1E1E),
            ),
          ),
        ),
      ],
    );
  }

  static Widget _bullet(String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 7),
            child: Icon(
              Icons.circle,
              size: 8,
              color: Color(0xFF0F8A7B),
            ),
          ),

          const SizedBox(width: 12),

          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(
                  fontSize: 15,
                  height: 1.7,
                  color: Color(0xFF444444),
                ),
                children: [
                  TextSpan(
                    text: "$title  ",
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
                  TextSpan(text: subtitle),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _simpleBullet(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 7),
            child: Icon(
              Icons.circle,
              size: 8,
              color: Color(0xFF0F8A7B),
            ),
          ),

          const SizedBox(width: 12),

          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 15,
                height: 1.7,
                color: Color(0xFF444444),
              ),
            ),
          ),
        ],
      ),
    );
  }
}