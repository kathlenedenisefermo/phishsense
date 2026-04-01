import 'dart:async';
import 'package:flutter/material.dart';

class SyncPage extends StatefulWidget {
  final VoidCallback onDone;

  const SyncPage({
    super.key,
    required this.onDone,
  });

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  @override
  void initState() {
    super.initState();
    Timer(const Duration(seconds: 2), widget.onDone);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F4EC),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.sync,
                  size: 64,
                  color: Color(0xFF1A7A72),
                ),
                const SizedBox(height: 24),
                const Text(
                  "Syncing Your Messages",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A1A1A),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  "PhishSense is preparing your inbox and scanning recent messages for suspicious activity.",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.5,
                    color: Color(0xFF666666),
                  ),
                ),
                const SizedBox(height: 28),
                const SizedBox(
                  width: 42,
                  height: 42,
                  child: CircularProgressIndicator(
                    strokeWidth: 3.5,
                    color: Color(0xFF1A7A72),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}