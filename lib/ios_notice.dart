import 'package:flutter/material.dart';

class IOSNoticePage extends StatelessWidget {
  final VoidCallback onContinue;

  const IOSNoticePage({super.key, required this.onContinue});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F4EC),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.info_outline,
                size: 64,
                color: Color(0xFF1A7A72),
              ),
              const SizedBox(height: 24),

              const Text(
                "iOS Notice",
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1A1A),
                ),
              ),
              const SizedBox(height: 16),

              const Text(
                "Due to Apple’s privacy restrictions, PhishSense cannot directly access or scan your SMS inbox on iOS devices.\n\n"
                "Instead, PhishSense uses iOS-supported message filtering to help identify suspicious messages from unknown senders.\n\n"
                "Some features available on Android, such as real-time inbox scanning, are not supported on iOS.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.6,
                  color: Color(0xFF666666),
                ),
              ),

              const SizedBox(height: 32),

              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: onContinue,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1A7A72),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text(
                    "Continue",
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
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
}
