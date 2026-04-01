import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'services/sms_service.dart';

class LabelDetectionPage extends StatefulWidget {
  final String sender;
  final String displayName;
  final String message;
  final String time;
  final bool isPhishing;
  final double confidence;

  final bool shareAnonymousData;
  final bool showDetectionPopup;
  final ValueChanged<bool> onChangeShareAnonymousData;
  final ValueChanged<bool> onChangeShowDetectionPopup;

  const LabelDetectionPage({
    super.key,
    required this.sender,
    this.displayName = '',
    required this.message,
    required this.time,
    required this.isPhishing,
    this.confidence = 0.0,
    required this.shareAnonymousData,
    required this.showDetectionPopup,
    required this.onChangeShareAnonymousData,
    required this.onChangeShowDetectionPopup,
  });

  @override
  State<LabelDetectionPage> createState() => _LabelDetectionPageState();
}

class _LabelDetectionPageState extends State<LabelDetectionPage> {
  late bool shareMessage;
  bool dontShowAgain = false;
  late bool showOverlay;
  final TextEditingController _replyCtrl = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    shareMessage = widget.shareAnonymousData;
    showOverlay = widget.showDetectionPopup;
  }

  @override
  void dispose() {
    _replyCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendReply() async {
    final body = _replyCtrl.text.trim();
    if (body.isEmpty) return;
    setState(() => _sending = true);
    try {
      await SmsService.sendSms(widget.sender, body);
      _replyCtrl.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Message sent')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _makeCall() async {
    final uri = Uri.parse('tel:${widget.sender}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  List<String> get phishingReasons {
    final text = widget.message.toLowerCase();
    final reasons = <String>[];

    if (text.contains("full name") ||
        text.contains("home address") ||
        text.contains("date of birth") ||
        text.contains("valid id")) {
      reasons.add("Asks for personal info");
    }

    if (text.contains("act fast") ||
        text.contains("reply now") ||
        text.contains("urgent")) {
      reasons.add("Urgent tone");
    }

    if (text.contains("won") ||
        text.contains("lottery") ||
        text.contains("\$1,000,000") ||
        text.contains("prize")) {
      reasons.add("Unrealistic Reward");
    }

    if (text.contains("http://") || text.contains("https://")) {
      reasons.add("Suspicious link");
    }

    return reasons;
  }

  List<String> get safeReasons => ["Known Contact"];

  @override
  Widget build(BuildContext context) {
    final bool isPhishing = widget.isPhishing;

    final Color statusColor =
    isPhishing ? const Color(0xFFD80E0E) : const Color(0xFF50BF32);

    final String statusText =
    isPhishing ? "Phishing Detected" : "Safe Message";

    final String subtitleText = isPhishing
        ? "This message shows signs of a phishing attempt. Do not click links or share personal information."
        : "This message is from a saved contact. However, always remain cautious of suspicious links or requests.";

    final List<String> labels = isPhishing ? phishingReasons : safeReasons;

    return Scaffold(
      backgroundColor: const Color(0xFFF6F4EC),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(
                          Icons.arrow_back_ios_new,
                          color: Color(0xFF17202A),
                          size: 24,
                        ),
                      ),
                      Expanded(
                        child: Column(
                          children: [
                            const CircleAvatar(
                              radius: 24,
                              backgroundColor: Color(0xFFE4E5EA),
                              child: Icon(
                                Icons.person,
                                size: 32,
                                color: Color(0xFFA8ADB8),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              widget.displayName.isNotEmpty
                                  ? widget.displayName
                                  : widget.sender,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF17202A),
                              ),
                              textAlign: TextAlign.center,
                            ),
                            if (widget.displayName.isNotEmpty)
                              Text(
                                widget.sender,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF888888),
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.phone, size: 26),
                        color: const Color(0xFF1A7A72),
                        onPressed: _makeCall,
                        tooltip: 'Call',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  height: 1.2,
                  color: const Color(0xFF204760),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Text(
                    subtitleText,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF707070),
                      height: 1.35,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  width: 220,
                  height: 40,
                  decoration: BoxDecoration(
                    color: statusColor,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        statusText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        isPhishing ? "⚠️" : "✅",
                        style: const TextStyle(fontSize: 16),
                      ),
                    ],
                  ),
                ),
                if (widget.confidence > 0.0)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      "Confidence: ${(widget.confidence * 100).toStringAsFixed(1)}%",
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF888888),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                const SizedBox(height: 25),
                Text(
                  widget.time,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF6C6C6C),
                  ),
                ),
                const SizedBox(height: 22),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Container(
                              constraints: const BoxConstraints(maxWidth: 270),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Text(
                                widget.message,
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: Colors.black87,
                                  height: 1.35,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                widget.time,
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: Color(0xFF6C6C6C),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            constraints: const BoxConstraints(maxWidth: 270),
                            child: Wrap(
                              alignment: WrapAlignment.start,
                              spacing: 8,
                              runSpacing: 6,
                              children: labels
                                  .map(
                                    (reason) => _ReasonChip(
                                  label: reason,
                                  isSafe: !isPhishing,
                                ),
                              )
                                  .toList(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 44),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF0EADB),
                            borderRadius: BorderRadius.circular(22),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
                          child: TextField(
                            controller: _replyCtrl,
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              hintText: "Enter your message...",
                              hintStyle: TextStyle(
                                color: Color(0xFF9A9A9A),
                                fontSize: 15,
                              ),
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(vertical: 10),
                            ),
                            style: const TextStyle(
                              color: Color(0xFF17202A),
                              fontSize: 15,
                            ),
                            maxLines: null,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      GestureDetector(
                        onTap: _sending ? null : _sendReply,
                        child: _sending
                            ? const SizedBox(
                                width: 30,
                                height: 30,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFF1A7A72),
                                ),
                              )
                            : const Icon(
                                Icons.send_rounded,
                                size: 34,
                                color: Color(0xFF17202A),
                              ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (showOverlay)
              Positioned.fill(
                child: Container(
                  color: Colors.black.withOpacity(0.08),
                  child: Center(
                    child: Container(
                      width: MediaQuery.of(context).size.width * 0.78,
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF496376).withOpacity(.95),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Stack(
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                isPhishing
                                    ? const _PhishingTriangleIcon()
                                    : const _SmallSafeIconWidget(),
                                const SizedBox(height: 8),
                                Container(
                                  width: double.infinity,
                                  height: 34,
                                  decoration: BoxDecoration(
                                    color: statusColor,
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    statusText,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                    children: [
                                      Checkbox(
                                        value: shareMessage,
                                        onChanged: (value) {
                                          final bool newValue = value ?? false;
                                          setState(() {
                                            shareMessage = newValue;
                                          });
                                          widget.onChangeShareAnonymousData(
                                            newValue,
                                          );
                                        },
                                        activeColor: const Color(0xFF7DBD52),
                                        materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      const SizedBox(width: 2),
                                      const Expanded(
                                        child: Padding(
                                          padding: EdgeInsets.only(top: 4),
                                          child: Text(
                                            "Share this message to contribute\nto model improvement",
                                            style: TextStyle(
                                              fontSize: 12.5,
                                              color: Colors.black87,
                                              height: 1.2,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 10),
                                SizedBox(
                                  width: double.infinity,
                                  height: 38,
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      elevation: 0,
                                      backgroundColor: const Color(0xFF0E3550),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      padding: EdgeInsets.zero,
                                    ),
                                    onPressed: () {},
                                    child: const Text(
                                      "❌ Report as inaccurate",
                                      style: TextStyle(
                                        fontSize: 14.5,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                InkWell(
                                  onTap: () {
                                    setState(() {
                                      dontShowAgain = !dontShowAgain;
                                    });

                                    if (dontShowAgain) {
                                      widget.onChangeShareAnonymousData(true);
                                      widget.onChangeShowDetectionPopup(false);
                                    } else {
                                      widget.onChangeShowDetectionPopup(true);
                                    }
                                  },
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        dontShowAgain
                                            ? Icons.check_box
                                            : Icons.check_box_outline_blank,
                                        size: 15,
                                        color: Colors.white,
                                      ),
                                      const SizedBox(width: 6),
                                      const Text(
                                        "Do not show this again",
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          decoration:
                                          TextDecoration.underline,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Positioned(
                            top: -2,
                            right: -2,
                            child: InkWell(
                              onTap: () {
                                setState(() {
                                  showOverlay = false;
                                });
                              },
                              child: const Icon(
                                Icons.close,
                                size: 28,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
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

class _ReasonChip extends StatelessWidget {
  final String label;
  final bool isSafe;

  const _ReasonChip({
    required this.label,
    this.isSafe = false,
  });

  @override
  Widget build(BuildContext context) {
    Color chipColor = const Color(0xFFF5A623);

    if (isSafe) {
      chipColor = const Color(0xFF63DE44);
    } else if (label == "Asks for personal info" || label == "Urgent tone") {
      chipColor = const Color(0xFFE30000);
    } else if (label == "Unrealistic Reward") {
      chipColor = const Color(0xFFFF8C00);
    } else if (label == "Suspicious link") {
      chipColor = const Color(0xFFF8B233);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: chipColor,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: 13,
          height: 1,
        ),
      ),
    );
  }
}

class _SmallSafeIconWidget extends StatelessWidget {
  const _SmallSafeIconWidget();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 82,
      height: 66,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(
            Icons.shield_rounded,
            size: 58,
            color: Colors.green.shade700,
          ),
          const Icon(
            Icons.check_rounded,
            size: 28,
            color: Colors.white,
          ),
        ],
      ),
    );
  }
}

class _PhishingTriangleIcon extends StatelessWidget {
  const _PhishingTriangleIcon();

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.warning_amber_rounded,
      size: 60,
      color: Colors.red.shade400,
    );
  }
}