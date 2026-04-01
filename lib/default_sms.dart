import 'package:flutter/material.dart';
import 'services/sms_service.dart';

class DefaultSmsPage extends StatefulWidget {
  final Function(int) onSetDefault;
  final int initialIndex;

  const DefaultSmsPage({
    super.key,
    required this.initialIndex,
    required this.onSetDefault,
  });

  @override
  State<DefaultSmsPage> createState() => _DefaultSmsPageState();
}

class _DefaultSmsPageState extends State<DefaultSmsPage>
    with WidgetsBindingObserver {
  late int selectedIndex;
  String? infoMessage;
  bool _waitingForResult = false;

  @override
  void initState() {
    super.initState();
    selectedIndex = widget.initialIndex;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waitingForResult) {
      _waitingForResult = false;
      SmsService.isDefaultSmsApp().then((isDefault) {
        if (!mounted) return;
        if (isDefault) {
          widget.onSetDefault(0);
        } else {
          setState(() {
            infoMessage = "PhishSense was not set as default. Please try again.";
          });
        }
      });
    }
  }

  Future<void> _handleContinue() async {
    if (selectedIndex == 1) {
      setState(() {
        infoMessage = "Set PhishSense as your default app to continue.";
      });
      return;
    }

    // Check if already default
    final isAlready = await SmsService.isDefaultSmsApp();
    if (!mounted) return;
    if (isAlready) {
      widget.onSetDefault(0);
      return;
    }

    setState(() {
      infoMessage = null;
      _waitingForResult = true;
    });
    final opened = await SmsService.requestDefaultSmsApp();
    if (!mounted) return;
    if (!opened) {
      setState(() {
        _waitingForResult = false;
        infoMessage =
            'Opening Default Apps settings. '
            'Tap "SMS app" and select PhishSense.';
      });
    }
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
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.75),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: const Color(0xFFE5E2D8)),
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
                  const Icon(
                    Icons.sms_outlined,
                    size: 40,
                    color: Color(0xFF1A7A72),
                  ),
                  const SizedBox(height: 16),

                  RichText(
                    textAlign: TextAlign.center,
                    text: const TextSpan(
                      style: TextStyle(
                        fontSize: 24,
                        height: 1.25,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1A7A72),
                      ),
                      children: [
                        TextSpan(text: "Set Phish"),
                        TextSpan(
                          text: "Sense",
                          style: TextStyle(color: Color(0xFFE0A800)),
                        ),
                        TextSpan(text: " as your default SMS app?"),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  const Text(
                    "To detect phishing and suspicious messages in real time, "
                        "PhishSense needs to be your default SMS application.",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.6,
                      color: Color(0xFF6F6F68),
                    ),
                  ),

                  const SizedBox(height: 26),

                  buildOption(
                    index: 0,
                    title: "PhishSense",
                    subtitle: "Recommended for protection",
                    icon: Icons.shield_outlined,
                  ),
                  buildOption(
                    index: 1,
                    title: "Messages",
                    subtitle: "Current default",
                    icon: Icons.message_outlined,
                  ),

                  if (infoMessage != null) ...[
                    const SizedBox(height: 18),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF7F6),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: const Color(0xFF1A7A72).withOpacity(0.25),
                        ),
                      ),
                      child: const Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 18,
                            color: Color(0xFF1A7A72),
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              "Set PhishSense as your default app to continue.",
                              style: TextStyle(
                                fontSize: 13.5,
                                height: 1.4,
                                color: Color(0xFF1A1A1A),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  const SizedBox(height: 26),

                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _waitingForResult ? null : _handleContinue,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1A7A72),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: Text(
                        selectedIndex == 0
                            ? "Set PhishSense as default"
                            : "Continue",
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
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

  Widget buildOption({
    required int index,
    required String title,
    required String subtitle,
    required IconData icon,
  }) {
    final isSelected = selectedIndex == index;

    return GestureDetector(
      onTap: () {
        setState(() {
          selectedIndex = index;
          if (index == 0) {
            infoMessage = null;
          }
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: const EdgeInsets.symmetric(vertical: 7),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF1A7A72).withOpacity(0.08)
              : Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF1A7A72)
                : const Color(0xFFE3DFD4),
            width: isSelected ? 1.6 : 1,
          ),
        ),
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: CircleAvatar(
            radius: 23,
            backgroundColor: isSelected
                ? const Color(0xFF1A7A72).withOpacity(0.12)
                : const Color(0xFFF2EFE7),
            child: Icon(
              icon,
              color: const Color(0xFF1A7A72),
            ),
          ),
          title: Text(
            title,
            style: TextStyle(
              fontSize: 15.5,
              color: const Color(0xFF1A7A72),
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
          subtitle: Text(
            subtitle,
            style: TextStyle(
              color: isSelected
                  ? const Color(0xFF6F6F68)
                  : const Color(0xFF888880),
              fontSize: 12.5,
            ),
          ),
          trailing: Radio<int>(
            value: index,
            groupValue: selectedIndex,
            activeColor: const Color(0xFF1A7A72),
            onChanged: (value) {
              setState(() {
                selectedIndex = value!;
                if (value == 0) {
                  infoMessage = null;
                }
              });
            },
          ),
        ),
      ),
    );
  }
}