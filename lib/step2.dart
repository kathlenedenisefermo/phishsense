import 'package:flutter/material.dart';
import 'permission.dart';
import 'error.dart';

class Step2Page extends StatelessWidget {
  final VoidCallback onContinue;
  final VoidCallback onContactsAllowed;

  const Step2Page({
    super.key,
    required this.onContinue,
    required this.onContactsAllowed,
  });

  void _showOptionalNotice(BuildContext context) {
    ErrorPage.show(
      context,
      title: "Optional Permission",
      message:
          "You can allow contacts later in settings. For now, you can continue using PhishSense without it.",
      buttonText: "OK",
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEFEDE8),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'PhishSense Setup',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 4,
                          decoration: BoxDecoration(
                            color: const Color(0xFF1A7A72),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Container(
                          height: 4,
                          decoration: BoxDecoration(
                            color: const Color(0xFF1A7A72),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Container(
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.grey.shade300,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 16),
                    const Text(
                      'Verify Your\nTrusted Contacts',
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A1A1A),
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'PhishSense can use your contacts to identify trusted senders. This step is optional and can be configured later.',
                      style: TextStyle(
                        fontSize: 15,
                        color: Colors.grey[600],
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 28),

                    Center(
                      child: Container(
                        width: 300,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.05),
                              blurRadius: 20,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            _ContactRow(name: 'Mom', verified: true),
                            _ContactRow(name: 'BDO Bank Alert', verified: false),
                            _ContactRow(name: 'John Reyes', verified: true),
                            _ContactRow(name: 'Unknown +63911...', verified: false),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton(
                      onPressed: () {
                        // Simulate allowing contacts (no real permission)
                        onContactsAllowed();
                        onContinue();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1A7A72),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        elevation: 0,
                      ),
                      child: const Text(
                        'Continue',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  TextButton(
                    onPressed: () {
                      _showOptionalNotice(context);
                    },
                    child: const Text(
                      'Set up later',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  final String name;
  final bool verified;

  const _ContactRow({
    required this.name,
    required this.verified,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: verified
                ? const Color(0xFF1A7A72).withOpacity(0.15)
                : Colors.grey.shade200,
            child: Icon(
              Icons.person,
              size: 18,
              color: verified ? const Color(0xFF1A7A72) : Colors.grey,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              name,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Icon(
            verified ? Icons.verified_rounded : Icons.help_outline,
            size: 18,
            color: verified ? const Color(0xFF1A7A72) : Colors.grey,
          ),
        ],
      ),
    );
  }
}
