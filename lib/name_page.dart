import 'package:flutter/material.dart';

class NamePage extends StatefulWidget {
  final Function(String) onContinue;

  const NamePage({super.key, required this.onContinue});

  @override
  State<NamePage> createState() => _NamePageState();
}

class _NamePageState extends State<NamePage> {
  final TextEditingController firstName = TextEditingController();
  final TextEditingController lastName = TextEditingController();

  String? firstNameError;

  void continuePressed() {
    final first = firstName.text.trim();
    final last = lastName.text.trim();

    if (first.isEmpty) {
      setState(() {
        firstNameError = "Please enter your first name";
      });
      return;
    }

    setState(() {
      firstNameError = null;
    });

    final fullName = last.isEmpty ? first : "$first $last";
    widget.onContinue(fullName);
  }

  InputDecoration inputStyle(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(
        color: Color(0xFF6F6F68),
      ),
      floatingLabelStyle: const TextStyle(
        color: Color(0xFF1A7A72),
        fontWeight: FontWeight.w600,
      ),
      filled: true,
      fillColor: Colors.white.withOpacity(0.85),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE1DDD2)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE1DDD2)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(
          color: Color(0xFF1A7A72),
          width: 1.8,
        ),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(
          color: Color(0xFFC94C4C),
          width: 1.4,
        ),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(
          color: Color(0xFFC94C4C),
          width: 1.8,
        ),
      ),
      errorStyle: const TextStyle(
        fontSize: 12,
        color: Color(0xFFC94C4C),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F4EC),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Container(
              width: 460,
              padding: const EdgeInsets.all(30),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.75),
                border: Border.all(color: const Color(0xFFE5E2D8)),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.06),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Icon(
                        Icons.phishing,
                        color: Color(0xFF888880),
                        size: 28,
                      ),
                      SizedBox(width: 8),
                      Text(
                        "Phish",
                        style: TextStyle(
                          fontSize: 27,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1A7A72),
                        ),
                      ),
                      Text(
                        "Sense",
                        style: TextStyle(
                          fontSize: 27,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFE0A800),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 30),

                  const Text(
                    "What’s your name?",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 29,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1F1F1B),
                    ),
                  ),

                  const SizedBox(height: 10),

                  const Text(
                    "Enter the name you want to use in PhishSense",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFF6F6F68),
                      fontSize: 14.5,
                      height: 1.5,
                    ),
                  ),

                  const SizedBox(height: 30),

                  TextField(
                    controller: firstName,
                    decoration: inputStyle("First name").copyWith(
                      errorText: firstNameError,
                    ),
                  ),

                  const SizedBox(height: 18),

                  TextField(
                    controller: lastName,
                    decoration: inputStyle("Last name (optional)"),
                  ),

                  const SizedBox(height: 28),

                  Align(
                    alignment: Alignment.centerRight,
                    child: ElevatedButton(
                      onPressed: continuePressed,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1A7A72),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text(
                        "Next",
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}